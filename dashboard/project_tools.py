# -*- coding: utf-8 -*-
"""Outils côté client d'une étape de projet (docs/AUTONOMY-ENGINE.md, sections 3.3, 3.4 et 7.7).

Les outils qui touchent des fichiers ou l'état sont implémentés UNE seule fois, ici, en Python (testé), et appelés par le lanceur
PowerShell via `python dashboard/project-tool.py <outil>` : JSON sur l'entrée standard, JSON sur la sortie, aucune surface HTTP (donc aucun
risque d'accès externe ni de SSRF). Le chemin sûr (project_paths.py) est ainsi codé et testé une seule fois, pas deux.

Entrée : {"projectDir","stepDir","stepId","kind","worker","input":{...}}
Sortie : {"ok":true,"result":{...}} ou {"ok":false,"error":"CODE","detail":"..."} (messages en français, jamais d'exception brute).

UN SEUL ÉCRIVAIN : ces outils n'écrivent que dans workspace/, spool/ et (contrôles) verification/<tour>/checks/. state.json, plan.json,
approvals.json, deliverables.json sont écrits par projects.py ; les outils d'état (plan, approbations, questions, livrables, décisions)
ajoutent des lignes au spool, que Python valide et ingère.
"""
import base64
import datetime
import hashlib
import json
import os
import re
import secrets
import shutil
import sys
import time

import project_checks
import project_paths as pp
import projects_plan

ROOT = os.environ.get("BK_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_ID_RE = re.compile(r"^PRJ-[0-9A-F]{32}\Z")
STEP_ID_RE = re.compile(r"^[A-Za-z][A-Za-z0-9-]{0,20}\Z")
KINDS = ("plan", "execute", "fix", "verify", "replan", "consolidate", "answer")
READ_CHARS_MAX = 20000
WRITE_BYTES_MAX = 2 * 1024 * 1024
APPEND_FILE_MAX = 5 * 1024 * 1024
IMAGE_BYTES_MAX = 1536 * 1024
LIST_ENTRIES_MAX = 500
SEARCH_SECONDS = 2.0
SEARCH_FILE_BYTES = 1024 * 1024
MAX_INPUT_QUESTIONS_PER_STEP = 3
MAX_ADDED_STEPS = 8
DEFAULT_WORKSPACE_MB = 100

# Outils présents selon la sorte d'étape (liste fermée, 3.3). Le lanceur construit ses définitions d'après cette table ; l'outil
# lui-même la fait respecter (un vérificateur ne peut pas écrire, même si le modèle invente l'appel).
READ_TOOLS = ("workspace_list", "workspace_read", "workspace_search")
TOOLS_BY_KIND = {
    "plan": READ_TOOLS + ("project_plan", "request_input", "note_decision", "step_complete"),
    "replan": READ_TOOLS + ("project_plan", "request_input", "note_decision", "step_complete"),
    "execute": READ_TOOLS + ("workspace_view_image", "workspace_write", "workspace_append", "workspace_delete", "deliverable_register",
                             "project_plan", "request_input", "request_approval", "note_decision", "step_complete", "step_blocked"),
    "fix": READ_TOOLS + ("workspace_view_image", "workspace_write", "workspace_append", "workspace_delete", "deliverable_register",
                         "project_plan", "request_input", "request_approval", "note_decision", "step_complete", "step_blocked"),
    "verify": READ_TOOLS + ("workspace_view_image", "check_run", "preview_fetch", "step_complete"),
    "consolidate": READ_TOOLS + ("workspace_write", "workspace_append", "deliverable_register", "step_complete"),
    "answer": READ_TOOLS + ("workspace_view_image",),
}
# Outils réservés au lanceur ou appelés par lui seul (jamais proposés au modèle) :
RUNNER_ONLY = ("import_file",)


class ToolError(Exception):
    def __init__(self, code, detail, **extra):
        super().__init__(detail)
        self.code = code
        self.detail = detail
        self.extra = extra


REGISTRY = {}        # nom -> {"fn": callable(ctx, input) -> dict, "kinds": None | ensemble}


def register_tool(name, fn, kinds=None):
    """Enregistre un outil (atelier de sites : site_*). kinds = ensemble de sortes d'étape autorisées (None : execute, fix)."""
    REGISTRY[name] = {"fn": fn, "kinds": frozenset(kinds) if kinds else frozenset(("execute", "fix"))}


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


class ToolCtx:
    def __init__(self, payload):
        if not isinstance(payload, dict):
            raise ToolError("INVALID_INPUT", "Entrée invalide.")
        self.project_dir = str(payload.get("projectDir") or "")
        self.step_dir = str(payload.get("stepDir") or "")
        self.step_id = str(payload.get("stepId") or "")
        self.kind = str(payload.get("kind") or "")
        self.worker = str(payload.get("worker") or "")
        self.input = payload.get("input") if isinstance(payload.get("input"), dict) else {}
        if not PROJECT_ID_RE.match(os.path.basename(self.project_dir.rstrip("/\\"))) or not os.path.isdir(self.project_dir):
            raise ToolError("INVALID_INPUT", "Projet introuvable.")
        if not STEP_ID_RE.match(self.step_id):
            raise ToolError("INVALID_INPUT", "Identifiant d'étape invalide.")
        if self.kind not in KINDS:
            raise ToolError("INVALID_INPUT", "Sorte d'étape invalide.")
        self.workspace = os.path.join(self.project_dir, "workspace")
        self.spool = os.path.join(self.project_dir, "spool")
        os.makedirs(self.workspace, exist_ok=True)
        os.makedirs(self.spool, exist_ok=True)
        self._state = None
        self._limits = None

    def state(self):
        if self._state is None:
            self._state = _read_json(os.path.join(self.project_dir, "state.json"), {}) or {}
        return self._state

    def limits(self):
        if self._limits is None:
            self._limits = _read_json(os.path.join(self.project_dir, "limits.json"), {}) or {}
        return self._limits

    def workspace_cap_bytes(self):
        mb = self.limits().get("workspaceMb")
        return int((mb if isinstance(mb, (int, float)) and mb > 0 else DEFAULT_WORKSPACE_MB) * 1024 * 1024)

    def spool_path(self, name, ext="jsonl"):
        return os.path.join(self.spool, f"{name}-{self.step_id}.{ext}")

    def spool_append(self, name, obj):
        path = self.spool_path(name)
        line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
        with open(path, "a", encoding="utf-8") as f:
            f.write(line)
            f.flush()
            os.fsync(f.fileno())

    def spool_lines(self, pattern_prefix):
        """Toutes les lignes JSON des fichiers du spool dont le nom commence par `pattern_prefix` (toutes étapes confondues)."""
        out = []
        try:
            names = sorted(os.listdir(self.spool))
        except OSError:
            return out
        for n in names:
            if n.startswith(pattern_prefix) and n.endswith(".jsonl"):
                try:
                    with open(os.path.join(self.spool, n), encoding="utf-8") as f:
                        for line in f:
                            try:
                                out.append(json.loads(line))
                            except ValueError:
                                continue
                except OSError:
                    continue
        return out

    def check_dirs(self):
        """Dossiers où chercher un résultat de contrôle : l'étape elle-même, puis les tours de vérification (le plus récent d'abord)."""
        dirs = [os.path.join(self.step_dir, "checks")] if self.step_dir else []
        vdir = os.path.join(self.project_dir, "verification")
        try:
            rounds = sorted((d for d in os.listdir(vdir) if d.isdigit()), key=int, reverse=True)
        except OSError:
            rounds = []
        dirs += [os.path.join(vdir, r, "checks") for r in rounds]
        return dirs

    def find_check(self, check_id):
        for d in self.check_dirs():
            c = project_checks.load_check(d, check_id)
            if c:
                return c
        return None


def _text_ok(value, name, limit, required=False):
    if value is None or value == "":
        if required:
            raise ToolError("INVALID_INPUT", f"Le champ « {name} » est obligatoire.")
        return ""
    if not isinstance(value, str):
        raise ToolError("INVALID_INPUT", f"Le champ « {name} » doit être du texte.")
    return value[:limit]


def _contains_secret(text):
    try:
        import installations
        return installations.contains_secret(text)
    except ImportError:  # pragma: no cover - installations.py est dans le même dossier
        return False


def _decode_text(raw):
    for enc in ("utf-8-sig", "cp1252"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def _path_error(e):
    return ToolError(e.code, e.detail)


def _resolve(ctx, path, **kw):
    try:
        return pp.resolve(ctx.workspace, path, **kw)
    except pp.PathError as e:
        raise _path_error(e)


# ------------------------------------------------------------------ outils de l'espace de travail
def tool_workspace_list(ctx, inp):
    path = inp.get("path", "")
    depth = inp.get("depth", 2)
    depth = depth if isinstance(depth, int) and not isinstance(depth, bool) and 1 <= depth <= 6 else 2
    base = _resolve(ctx, path or "", kind="dir", must_exist=bool(path), allow_trailing_slash=True, allow_empty=True)
    if not os.path.isdir(base):
        return {"entries": [], "truncated": False}
    real_ws = os.path.realpath(ctx.workspace)
    base_depth = base.rstrip(os.sep).count(os.sep)
    entries, truncated = [], False
    for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and not pp._is_link_or_reparse(os.path.join(dirpath, d)))
        level = dirpath.rstrip(os.sep).count(os.sep) - base_depth
        if level >= depth:
            dirnames[:] = []
        for d in dirnames:
            entries.append({"path": pp.rel_of(real_ws, os.path.join(dirpath, d)) + "/", "type": "dir"})
        for fn in sorted(filenames):
            fp = os.path.join(dirpath, fn)
            if fn.startswith(".") or pp._is_link_or_reparse(fp):
                continue
            try:
                st = os.stat(fp)
            except OSError:
                continue
            entries.append({"path": pp.rel_of(real_ws, fp), "type": "file", "bytes": st.st_size,
                            "modifiedUtc": datetime.datetime.fromtimestamp(st.st_mtime, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
        if len(entries) >= LIST_ENTRIES_MAX:
            truncated = True
            entries = entries[:LIST_ENTRIES_MAX]
            break
    entries.sort(key=lambda e: e["path"])
    return {"entries": entries, "truncated": truncated}


def _preview_text(full, rel):
    """Texte d'un classeur / document / présentation, via file_preview (module existant, formules recalculées)."""
    import file_preview
    pv = file_preview.build_preview(full, rel)
    kind = pv.get("kind")
    lines = []
    if kind == "table":
        for sh in pv.get("sheets") or []:
            lines.append(f"## Feuille « {sh.get('name')} » ({sh.get('formulaCells', 0)} formule(s), {sh.get('computedCells', 0)} calculée(s))")
            for row in sh.get("rows") or []:
                lines.append(" | ".join(str(c) for c in row))
    elif kind == "document":
        for b in pv.get("blocks") or []:
            if b.get("type") == "table":
                for row in b.get("rows") or []:
                    lines.append(" | ".join(str(c) for c in row))
            else:
                lines.append(("# " if b.get("type") == "h" else "") + str(b.get("text") or ""))
    elif kind == "slides":
        for s in pv.get("slides") or []:
            lines.append(f"## Diapositive {s.get('n')}")
            lines.extend(s.get("lines") or [])
    elif kind == "text":
        lines.append(str(pv.get("text") or ""))
    else:
        raise ToolError("BINARY_FILE", f"« {rel} » ne se lit pas comme du texte.")
    return "\n".join(lines)


def tool_workspace_read(ctx, inp):
    full = _resolve(ctx, inp.get("path"), kind="file", must_exist=True, allowed_ext=pp.IMPORT_EXT)
    rel = pp.rel_of(ctx.workspace, full)
    ext = pp.ext_of(rel)
    total = os.path.getsize(full)
    offset = inp.get("offset", 0)
    offset = offset if isinstance(offset, int) and not isinstance(offset, bool) and offset >= 0 else 0
    limit = inp.get("limit", READ_CHARS_MAX)
    limit = limit if isinstance(limit, int) and not isinstance(limit, bool) and 1 <= limit <= READ_CHARS_MAX else READ_CHARS_MAX
    if ext in ("xlsx", "docx", "pptx"):
        try:
            text = _preview_text(full, rel)
        except ToolError:
            raise
        except Exception:  # noqa: BLE001
            raise ToolError("UNREADABLE", f"« {rel} » est illisible (fichier corrompu ?).")
    elif ext in pp.WRITE_EXT:
        with open(full, "rb") as f:
            text = _decode_text(f.read(WRITE_BYTES_MAX * 2))
    elif ext in pp.IMAGE_EXT:
        raise ToolError("BINARY_FILE", f"« {rel} » est une image : utilisez workspace_view_image.")
    else:
        raise ToolError("BINARY_FILE", f"« {rel} » est un fichier binaire ({ext}) qui ne se lit pas comme du texte.")
    chunk = text[offset:offset + limit]
    eof = offset + limit >= len(text)
    out = {"path": rel, "offset": offset, "text": chunk, "eof": eof, "totalBytes": total, "totalChars": len(text)}
    if not eof:
        out["nextOffset"] = offset + limit
    return out


def tool_workspace_view_image(ctx, inp):
    full = _resolve(ctx, inp.get("path"), kind="file", must_exist=True, allowed_ext=set(pp.IMAGE_EXT))
    size = os.path.getsize(full)
    if size > IMAGE_BYTES_MAX:
        raise ToolError("TOO_LARGE", f"Image trop lourde ({size} octets, maximum {IMAGE_BYTES_MAX}).")
    with open(full, "rb") as f:
        raw = f.read()
    return {"path": pp.rel_of(ctx.workspace, full), "mediaType": pp.IMAGE_EXT[pp.ext_of(full)], "bytes": size,
            "base64": base64.b64encode(raw).decode("ascii")}


def _check_capacity(ctx, add_bytes, new_file):
    files, total = pp.usage(ctx.workspace)
    if new_file and files + 1 > pp.MAX_FILES:
        raise ToolError("WORKSPACE_FULL", f"Espace de travail plein ({pp.MAX_FILES} fichiers) : supprimez ou regroupez des fichiers.")
    if total + add_bytes > ctx.workspace_cap_bytes():
        raise ToolError("WORKSPACE_FULL", "Espace de travail plein (taille maximale atteinte) : supprimez ou compressez des fichiers.")


def _content_arg(inp, name="content"):
    content = inp.get(name)
    if not isinstance(content, str):
        raise ToolError("INVALID_INPUT", f"Le champ « {name} » doit être du texte.")
    data = content.encode("utf-8")
    if len(data) > WRITE_BYTES_MAX:
        raise ToolError("TOO_LARGE", f"Contenu trop gros ({len(data)} octets, maximum {WRITE_BYTES_MAX}).")
    if _contains_secret(content):
        raise ToolError("SECRET_REFUSED", "Le contenu ressemble à un secret (mot de passe, clé, jeton, IBAN ou numéro de carte) : "
                        "remplacez-le par un champ « [À COMPLÉTER : ...] ». Aucun secret n'est stocké dans un projet.")
    return data


def tool_workspace_write(ctx, inp):
    full = _resolve(ctx, inp.get("path"), kind="file", allowed_ext=set(pp.WRITE_EXT))
    mode = inp.get("mode", "create")
    if mode not in ("create", "overwrite"):
        raise ToolError("INVALID_INPUT", "mode : « create » ou « overwrite ».")
    data = _content_arg(inp)
    exists = os.path.isfile(full)
    if exists and mode == "create":
        raise ToolError("EXISTS", f"« {inp.get('path')} » existe déjà : lisez-le, puis utilisez mode « overwrite » pour le remplacer "
                        "ou workspace_append pour le compléter.")
    _check_capacity(ctx, max(0, len(data) - (os.path.getsize(full) if exists else 0)), not exists)
    pp.atomic_write_bytes(full, data)
    return {"path": pp.rel_of(ctx.workspace, full), "bytes": len(data), "created": not exists}


def tool_workspace_append(ctx, inp):
    full = _resolve(ctx, inp.get("path"), kind="file", allowed_ext=set(pp.WRITE_EXT))
    data = _content_arg(inp)
    exists = os.path.isfile(full)
    if exists and os.path.getsize(full) + len(data) > APPEND_FILE_MAX:
        raise ToolError("TOO_LARGE", "Ce fichier atteindrait la taille maximale : créez un second fichier.")
    _check_capacity(ctx, len(data), not exists)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "ab") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    return {"path": pp.rel_of(ctx.workspace, full), "appendedBytes": len(data), "totalBytes": os.path.getsize(full)}


def tool_workspace_delete(ctx, inp):
    path = inp.get("path")
    full = _resolve(ctx, path, must_exist=True, allow_trailing_slash=True)
    rel = pp.rel_of(ctx.workspace, full)
    if rel == "." or os.path.realpath(full) == os.path.realpath(ctx.workspace):
        raise ToolError("PATH_INVALID", "On ne supprime pas l'espace de travail lui-même.")
    if (rel == "inputs" or rel.startswith("inputs/")) and inp.get("confirm") is not True:
        raise ToolError("CONFIRM_REQUIRED", "Les fichiers fournis par le client (inputs/) ne se suppriment qu'avec confirm:true.")
    if os.path.isdir(full):
        shutil.rmtree(full, ignore_errors=True)
        return {"deleted": rel + "/", "type": "dir"}
    os.remove(full)
    return {"deleted": rel, "type": "file"}


_NESTED_QUANT = re.compile(r"\([^()]*[+*][^()]*\)[+*{]")


def tool_workspace_search(ctx, inp):
    query = inp.get("query")
    if not isinstance(query, str) or not query or len(query) > 200:
        raise ToolError("INVALID_INPUT", "query : texte de 1 à 200 caractères.")
    use_re = inp.get("regex") is True
    if use_re:
        if _NESTED_QUANT.search(query):
            raise ToolError("INVALID_INPUT", "Expression régulière refusée (quantificateurs imbriqués).")
        try:
            rx = re.compile(query, re.IGNORECASE)
        except re.error as e:
            raise ToolError("INVALID_INPUT", f"Expression régulière invalide : {e}")
    else:
        rx = re.compile(re.escape(query), re.IGNORECASE)
    path = inp.get("path", "")
    base = _resolve(ctx, path or "", kind="dir", must_exist=bool(path), allow_trailing_slash=True, allow_empty=True)
    glob = inp.get("glob")
    glob_rx = None
    if isinstance(glob, str) and glob:
        import fnmatch
        glob_rx = re.compile(fnmatch.translate(glob[:60]), re.IGNORECASE)
    max_matches = inp.get("maxMatches", 50)
    max_matches = max_matches if isinstance(max_matches, int) and not isinstance(max_matches, bool) and 1 <= max_matches <= 200 else 50
    deadline = time.time() + SEARCH_SECONDS
    matches, timed_out = [], False
    real_ws = os.path.realpath(ctx.workspace)
    for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and not pp._is_link_or_reparse(os.path.join(dirpath, d)))
        for fn in sorted(filenames):
            fp = os.path.join(dirpath, fn)
            if fn.startswith(".") or pp._is_link_or_reparse(fp) or pp.ext_of(fn) not in pp.WRITE_EXT:
                continue
            if glob_rx and not glob_rx.match(fn):
                continue
            try:
                with open(fp, "rb") as f:
                    text = _decode_text(f.read(SEARCH_FILE_BYTES))
            except OSError:
                continue
            for ln, line in enumerate(text.splitlines(), 1):
                if time.time() > deadline:
                    timed_out = True
                    break
                if rx.search(line[:2000]):
                    matches.append({"path": pp.rel_of(real_ws, fp), "line": ln, "text": line.strip()[:200]})
                    if len(matches) >= max_matches:
                        return {"matches": matches, "truncated": True}
            if timed_out:
                break
        if timed_out:
            break
    return {"matches": matches, "truncated": timed_out, "timedOut": timed_out}


# ------------------------------------------------------------------ outils d'état (écrivent dans le spool)
def tool_deliverable_register(ctx, inp):
    full = _resolve(ctx, inp.get("path"), must_exist=True, allow_trailing_slash=True)
    rel = pp.rel_of(ctx.workspace, full)
    if os.path.isdir(full):
        files, size = pp.usage(full)
        if files == 0:
            raise ToolError("EMPTY", f"Le dossier « {rel} » est vide : rien à livrer.")
        rel_out, kind_default = rel + "/", "site"
    else:
        if os.path.getsize(full) <= 0:
            raise ToolError("EMPTY", f"« {rel} » est vide : un livrable vide n'est pas un livrable.")
        rel_out, kind_default = rel, "document"
    kind = inp.get("kind") if inp.get("kind") in ("site", "document", "table", "image", "export", "other") else kind_default
    rec = {"id": "DLV-" + secrets.token_hex(4), "type": "deliverable", "path": rel_out, "title": _text_ok(inp.get("title"), "title", 160) or rel_out,
           "kind": kind, "description": _text_ok(inp.get("description"), "description", 400), "stepId": ctx.step_id, "worker": ctx.worker, "ts": now_iso()}
    ctx.spool_append("deliverables", rec)
    return {"registered": rel_out, "kind": kind}


def tool_request_input(ctx, inp):
    question = _text_ok(inp.get("question"), "question", 500, required=True)
    asked = [r for r in ctx.spool_lines("inputs-") if r.get("stepId") == ctx.step_id]
    if len(asked) >= MAX_INPUT_QUESTIONS_PER_STEP:
        raise ToolError("TOO_MANY_QUESTIONS", f"{MAX_INPUT_QUESTIONS_PER_STEP} questions au plus par étape : choisissez les plus décisives, "
                        "prenez une hypothèse étiquetée pour le reste.")
    choices = [c.strip()[:120] for c in (inp.get("choices") or []) if isinstance(c, str) and c.strip()][:6] if isinstance(inp.get("choices"), list) else []
    blocking = inp.get("blocking") is not False
    rec = {"id": "Q-" + secrets.token_hex(4), "type": "input", "stepId": ctx.step_id, "worker": ctx.worker, "question": question,
           "why": _text_ok(inp.get("why"), "why", 400), "blocking": blocking, "default": _text_ok(inp.get("default"), "default", 400),
           "choices": choices, "ts": now_iso()}
    ctx.spool_append("inputs", rec)
    note = ("Question enregistrée. Elle bloque cette étape : termine avec step_complete (status NEEDS_INPUT) après avoir fait tout ce qui ne dépend pas de la réponse."
            if blocking else "Question enregistrée (non bloquante). Continue avec ta valeur par défaut, étiquetée comme hypothèse dans ton rapport.")
    return {"questionId": rec["id"], "blocking": blocking, "note": note}


def tool_note_decision(ctx, inp):
    rec = {"id": "DEC-" + secrets.token_hex(4), "type": "decision", "stepId": ctx.step_id, "worker": ctx.worker,
           "decision": _text_ok(inp.get("decision"), "decision", 500, required=True), "why": _text_ok(inp.get("why"), "why", 500), "ts": now_iso()}
    if _contains_secret(rec["decision"] + rec["why"]):
        raise ToolError("SECRET_REFUSED", "La décision ressemble à un secret : reformulez sans donnée confidentielle.")
    ctx.spool_append("decisions", rec)
    return {"noted": True}


def _safe_step_spec(step):
    if not isinstance(step, dict):
        raise ToolError("INVALID_INPUT", "step : objet attendu.")
    out = {
        "title": _text_ok(step.get("title"), "title", 160, required=True), "goal": _text_ok(step.get("goal"), "goal", 2000, required=True),
        "worker": _text_ok(step.get("worker"), "worker", 20, required=True).lower(),
        "dependsOn": [d for d in (step.get("dependsOn") or []) if isinstance(d, str)][:20],
        "criteriaIds": [d for d in (step.get("criteriaIds") or []) if isinstance(d, str)][:25],
        "expectedOutputs": [d for d in (step.get("expectedOutputs") or []) if isinstance(d, str)][:20],
        "inputs": [d for d in (step.get("inputs") or []) if isinstance(d, str)][:20],
        "connectors": [d for d in (step.get("connectors") or []) if isinstance(d, str)][:10],
        "effort": step.get("effort") if step.get("effort") in projects_plan.EFFORTS else "normal",
    }
    if not projects_plan.WORKER_RE.match(out["worker"]):
        raise ToolError("INVALID_INPUT", "worker : identifiant de Worker invalide.")
    est = step.get("estimateCredits")
    out["estimateCredits"] = float(est) if isinstance(est, (int, float)) and not isinstance(est, bool) and est >= 0 else None
    return out


def tool_project_plan(ctx, inp):
    action = inp.get("action")
    if action == "get":
        plan = (_read_json(os.path.join(ctx.project_dir, "plan.json"), {}) or {}).get("plan") or {}
        steps = ctx.state().get("steps") or {}
        return {"goal": plan.get("goal") or ctx.state().get("goal"),
                "criteria": [{"id": c.get("id"), "text": c.get("text"), "kind": c.get("kind")} for c in plan.get("criteria") or []],
                "steps": [{"id": s.get("id"), "title": s.get("title"), "worker": s.get("worker"), "dependsOn": s.get("dependsOn"),
                           "status": (steps.get(s.get("id")) or {}).get("status", "PENDING")} for s in plan.get("steps") or []],
                "version": plan.get("version")}
    if action == "set":
        if ctx.kind not in ("plan", "replan"):
            raise ToolError("NOT_ALLOWED", "Seule une étape de planification peut remplacer le plan (project_plan set).")
        plan = inp.get("plan")
        st = ctx.state()
        sc = st.get("scope") or {}
        scope = {"chloe": bool(sc.get("chloe")), "allowed": sc.get("allowedWorkers")} if sc.get("allowedWorkers") is not None else None
        res = projects_plan.validate_plan(plan, scope, limits=ctx.limits().get("planLimits"))
        if not res.ok:
            raise ToolError("PLAN_INVALID", "Le plan est invalide : corrige-le et rappelle project_plan set.", problems=res.messages()[:25])
        tmp = ctx.spool_path("plan", "json")
        pp.atomic_write_bytes(tmp, json.dumps({"plan": res.plan, "ts": now_iso(), "stepId": ctx.step_id}, ensure_ascii=False).encode("utf-8"))
        return {"saved": True, "steps": len(res.plan["steps"]), "criteria": len(res.plan["criteria"]),
                "warnings": [w["detail"] for w in res.warnings][:10], "next": "Termine avec step_complete une fois le plan définitif."}
    if action == "add_step":
        if ctx.kind not in ("execute", "fix"):
            raise ToolError("NOT_ALLOWED", "Seule une étape de travail peut ajouter une étape.")
        added = ctx.spool_lines("plan-addstep-")
        existing = sum(1 for s in (ctx.state().get("steps") or {}).values() if isinstance(s, dict) and s.get("addedBy"))
        if len(added) + existing >= MAX_ADDED_STEPS:
            raise ToolError("TOO_MANY_STEPS", f"{MAX_ADDED_STEPS} étapes ajoutées au plus par projet : terminez le travail avec les étapes existantes.")
        spec = _safe_step_spec(inp.get("step"))
        spec.update({"id": "ADD-" + secrets.token_hex(3), "addedBy": ctx.step_id, "ts": now_iso()})
        ctx.spool_append("plan-addstep", spec)
        return {"queued": True, "note": "L'étape sera validée et ajoutée par le moteur."}
    if action == "note":
        rec = {"id": "PLN-" + secrets.token_hex(4), "type": "plan_note", "stepId": ctx.step_id, "target": _text_ok(inp.get("stepId"), "stepId", 10),
               "text": _text_ok(inp.get("text"), "text", 600, required=True), "ts": now_iso()}
        ctx.spool_append("plan-notes", rec)
        return {"noted": True}
    if action == "request_replan":
        rec = {"id": "RPL-" + secrets.token_hex(4), "type": "replan_request", "stepId": ctx.step_id,
               "reason": _text_ok(inp.get("reason"), "reason", 800, required=True), "ts": now_iso()}
        ctx.spool_append("plan-replan", rec)
        return {"requested": True, "note": "Une replanification sera proposée au client si elle est justifiée."}
    raise ToolError("INVALID_INPUT", "action : get, set, add_step, note ou request_replan.")


# ------------------------------------------------------------------ approbations (écrites par request_approval, ingérées par Python)
def _ops_snapshot():
    return _read_json(os.path.join(ROOT, "core", "projects", "CONNECTOR-OPS.json"), {}) or {}


def tool_request_approval(ctx, inp):
    import projects_approvals as pa
    kind = inp.get("kind", "connector")
    st = ctx.state()
    client_id = str(st.get("clientId") or "")
    existing = (_read_json(os.path.join(ctx.project_dir, "approvals.json"), {}) or {}).get("items") or []
    spooled = ctx.spool_lines("approvals-")
    pending = sum(1 for a in existing if isinstance(a, dict) and a.get("status") == "PENDING")
    seen_ids = {a.get("id") for a in existing if isinstance(a, dict)}
    pending += sum(1 for a in spooled if a.get("id") not in seen_ids)
    if pending >= pa.PENDING_PER_PROJECT:
        raise ToolError("APPROVAL_QUEUE_FULL", f"{pa.PENDING_PER_PROJECT} actions déjà en attente de validation : regroupe-les ou termine l'étape.")
    title = _text_ok(inp.get("title"), "title", 200, required=True)
    what = _text_ok(inp.get("what") or inp.get("details"), "what", 600)
    why = _text_ok(inp.get("why") or inp.get("reason"), "why", 600)
    now = datetime.datetime.now(datetime.timezone.utc)
    ttl_days = ctx.limits().get("approvalTtlDays") or pa.TTL_DAYS
    item = {"id": "APR-" + secrets.token_hex(4), "batchId": None, "projectId": os.path.basename(ctx.project_dir), "stepId": ctx.step_id,
            "worker": ctx.worker, "createdUtc": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "expiresUtc": (now + datetime.timedelta(days=ttl_days)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "validUntilUtc": None, "status": "PENDING", "decision": None, "decidedUtc": None, "editedParams": None, "execution": None,
            "supersedes": _text_ok(inp.get("supersedes"), "supersedes", 20) or None, "autoApproved": False}
    if kind == "manual":
        if not what:
            raise ToolError("INVALID_INPUT", "Une action manuelle doit dire ce que le client doit faire (champ « details » ou « what »).")
        risk = inp.get("risk") if inp.get("risk") in ("low", "medium", "high") else "medium"
        item.update({"kind": "manual_action", "connectorId": None, "operation": None, "params": {},
                     "display": {"title": title, "what": what, "why": why, "recipients": None, "spendChf": None},
                     "risk": risk, "reversible": inp.get("reversible") is not False,
                     "dedupKey": f"{ctx.step_id}|manual|{hashlib.sha256((title + what).encode('utf-8')).hexdigest()[:16]}"})
    elif kind == "connector":
        conn = _text_ok(inp.get("connectorId"), "connectorId", 40, required=True).lower()
        op = _text_ok(inp.get("operation"), "operation", 60, required=True).upper()
        params = inp.get("params") if isinstance(inp.get("params"), dict) else {}
        raw = json.dumps(params, ensure_ascii=False, sort_keys=True)
        if len(raw.encode("utf-8")) > pa.PARAMS_MAX_BYTES:
            raise ToolError("TOO_LARGE", f"Paramètres trop gros (maximum {pa.PARAMS_MAX_BYTES} octets) : une action par destinataire, contenu plus court.")
        if _contains_secret(raw):
            raise ToolError("SECRET_REFUSED", "Les paramètres ressemblent à un secret : une action sortante n'en contient jamais.")
        problem = pa.connector_problem(ROOT, client_id, conn, op)
        if problem:
            raise ToolError(problem[0], problem[1])
        if not what:
            what = pa.default_what(conn, op)
        risk = pa.classify_risk(ROOT, conn, op, params, recipients=inp.get("recipients"))
        item.update({"kind": "connector_action", "connectorId": conn, "operation": op, "params": params,
                     "display": {"title": title, "what": what, "why": why,
                                 "recipients": int(inp["recipients"]) if isinstance(inp.get("recipients"), int) and not isinstance(inp.get("recipients"), bool) else None,
                                 "spendChf": float(inp["spendChf"]) if isinstance(inp.get("spendChf"), (int, float)) and not isinstance(inp.get("spendChf"), bool) else None},
                     "risk": risk, "reversible": pa.is_reversible(ROOT, conn, op),
                     "dedupKey": f"{ctx.step_id}|{conn}|{op}|{hashlib.sha256(raw.encode('utf-8')).hexdigest()[:16]}"})
    else:
        raise ToolError("INVALID_INPUT", "kind : « connector » ou « manual ».")
    item["idempotencyKey"] = hashlib.sha256((item["projectId"] + item["dedupKey"]).encode("utf-8")).hexdigest()[:32]
    for a in list(existing) + spooled:
        if isinstance(a, dict) and a.get("dedupKey") == item["dedupKey"]:
            return {"queued": True, "approvalId": a.get("id"), "duplicate": True,
                    "note": f"QUEUED:{a.get('id')} (cette action était déjà préparée ; rien n'est ajouté)."}
    if inp.get("autoApproved") is True and kind == "connector":
        ex = inp.get("execution") if isinstance(inp.get("execution"), dict) else {}
        item.update({"autoApproved": True, "status": "EXECUTED", "decision": "auto", "decidedUtc": item["createdUtc"],
                     "execution": {"startedUtc": item["createdUtc"], "finishedUtc": item["createdUtc"],
                                   "connectorStatus": _text_ok(ex.get("connectorStatus"), "connectorStatus", 40),
                                   "detail": _text_ok(ex.get("detail"), "detail", 300)}})
    ctx.spool_append("approvals", item)
    return {"queued": True, "approvalId": item["id"], "risk": item["risk"], "note": f"QUEUED:{item['id']}"}


# ------------------------------------------------------------------ step_complete / step_blocked
def _normalise_report(ctx, rep):
    if not isinstance(rep, dict):
        raise ToolError("INVALID_INPUT", "Le rapport d'étape doit être un objet.")
    problems = []
    status = rep.get("status", "DONE")
    if status not in ("DONE", "PARTIAL", "BLOCKED", "NEEDS_INPUT"):
        problems.append("status : DONE, PARTIAL, BLOCKED ou NEEDS_INPUT.")
        status = "DONE"
    summary = rep.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        problems.append("summary : une ou deux phrases sur ce qui a été fait est obligatoire.")
        summary = ""
    out = {"status": status, "summary": summary.strip()[:3000], "deliverables": [], "criteriaClaims": [], "remaining": [], "summaryUpdate": "",
           "decisions": [], "inputQuestions": [], "nextSuggestions": [], "handoffNote": "", "ignoredInstructions": []}
    for d in (rep.get("deliverables") or [])[:40] if isinstance(rep.get("deliverables"), list) else []:
        if not isinstance(d, dict):
            continue
        p = d.get("path")
        try:
            full = pp.resolve(ctx.workspace, p, must_exist=True, allow_trailing_slash=True)
        except pp.PathError as e:
            problems.append(f"livrable « {str(p)[:80]} » : {e.detail}")
            continue
        if os.path.isdir(full):
            if pp.usage(full)[0] == 0:
                problems.append(f"livrable « {p} » : dossier vide.")
                continue
        elif os.path.getsize(full) <= 0:
            problems.append(f"livrable « {p} » : fichier vide (un livrable vide n'est pas un livrable).")
            continue
        out["deliverables"].append({"path": p, "title": _text_ok(d.get("title"), "title", 160) or p})
    for c in (rep.get("criteriaClaims") or [])[:30] if isinstance(rep.get("criteriaClaims"), list) else []:
        if not isinstance(c, dict) or not isinstance(c.get("criterionId"), str):
            continue
        ev_ok = []
        for e in (c.get("evidence") or [])[:10] if isinstance(c.get("evidence"), list) else []:
            if not isinstance(e, dict):
                continue
            t, ref = e.get("type"), e.get("ref")
            if t == "file":
                try:
                    full = pp.resolve(ctx.workspace, ref, must_exist=True, allow_trailing_slash=True)
                    if (os.path.isfile(full) and os.path.getsize(full) > 0) or (os.path.isdir(full) and pp.usage(full)[0] > 0):
                        ev_ok.append({"type": "file", "ref": ref})
                        continue
                except pp.PathError:
                    pass
                problems.append(f"preuve fichier introuvable ou vide : « {str(ref)[:80]} » (critère {c['criterionId']}).")
            elif t == "check":
                if ctx.find_check(ref):
                    ev_ok.append({"type": "check", "ref": ref})
                else:
                    problems.append(f"preuve « {str(ref)[:20]} » inconnue : un contrôle doit avoir été exécuté pendant cette étape.")
            else:
                problems.append(f"type de preuve non accepté dans un rapport d'étape : « {str(t)[:20]} » (fichier ou contrôle).")
        out["criteriaClaims"].append({"criterionId": c["criterionId"][:20], "claim": _text_ok(c.get("claim"), "claim", 300) or "met", "evidence": ev_ok})
    for key, lim, n in (("remaining", 300, 20), ("nextSuggestions", 300, 10), ("ignoredInstructions", 300, 10)):
        v = rep.get(key)
        if isinstance(v, list):
            out[key] = [x.strip()[:lim] for x in v if isinstance(x, str) and x.strip()][:n]
    out["summaryUpdate"] = _text_ok(rep.get("summaryUpdate"), "summaryUpdate", 2400)
    out["handoffNote"] = _text_ok(rep.get("handoffNote"), "handoffNote", 2000)
    for d in (rep.get("decisions") or [])[:15] if isinstance(rep.get("decisions"), list) else []:
        if isinstance(d, dict) and isinstance(d.get("decision"), str):
            out["decisions"].append({"decision": d["decision"][:500], "why": _text_ok(d.get("why"), "why", 500)})
    for q in (rep.get("inputQuestions") or [])[:5] if isinstance(rep.get("inputQuestions"), list) else []:
        if isinstance(q, dict) and isinstance(q.get("question"), str):
            out["inputQuestions"].append({"question": q["question"][:500], "why": _text_ok(q.get("why"), "why", 300), "blocking": q.get("blocking") is not False})
    if ctx.kind == "verify":
        v = rep.get("verification")
        if not isinstance(v, dict) or not isinstance(v.get("criteria"), list) or not v["criteria"]:
            problems.append("verification : objet {criteria:[{id, verdict, note, evidence, fixHint}], overall, summary} obligatoire pour une étape de vérification.")
        else:
            out["verification"] = _clean_verification(v, problems)
    return out, problems


def _clean_verification(v, problems):
    crit = []
    for c in v["criteria"][:40]:
        if not isinstance(c, dict) or not isinstance(c.get("id"), str):
            continue
        verdict = c.get("verdict")
        if verdict not in ("PASS", "FAIL", "UNVERIFIABLE"):
            problems.append(f"verification : verdict invalide pour {str(c.get('id'))[:20]} (PASS, FAIL ou UNVERIFIABLE).")
            continue
        ev = []
        for e in (c.get("evidence") or [])[:10] if isinstance(c.get("evidence"), list) else []:
            if isinstance(e, dict) and e.get("type") in ("file", "check", "excerpt", "fetch", "approval") and isinstance(e.get("ref"), str):
                item = {"type": e["type"], "ref": e["ref"][:200]}
                if isinstance(e.get("lines"), list):
                    item["lines"] = [x for x in e["lines"][:2] if isinstance(x, int) and not isinstance(x, bool)]
                if isinstance(e.get("quote"), str):
                    item["quote"] = e["quote"][:300]
                ev.append(item)
        crit.append({"id": c["id"][:20], "verdict": verdict, "note": _text_ok(c.get("note"), "note", 600), "evidence": ev,
                     "fixHint": _text_ok(c.get("fixHint"), "fixHint", 600)})
    return {"criteria": crit, "overall": v.get("overall") if v.get("overall") in ("PASS", "FAIL", "UNVERIFIABLE") else "FAIL",
            "unverifiable": [x[:20] for x in (v.get("unverifiable") or []) if isinstance(x, str)][:20] if isinstance(v.get("unverifiable"), list) else [],
            "summary": _text_ok(v.get("summary"), "summary", 1500)}


def tool_step_complete(ctx, inp):
    out, problems = _normalise_report(ctx, inp)
    if problems:
        raise ToolError("STEP_REPORT_INVALID", "Le rapport d'étape est refusé : corrige ces points puis rappelle step_complete.", problems=problems[:20])
    return {"accepted": True, "report": out}


def tool_step_blocked(ctx, inp):
    reason = inp.get("reason")
    if reason not in ("INPUT", "APPROVAL", "CONNECTOR", "OTHER"):
        raise ToolError("INVALID_INPUT", "reason : INPUT, APPROVAL, CONNECTOR ou OTHER.")
    return {"accepted": True, "blocked": {"reason": reason, "detail": _text_ok(inp.get("detail"), "detail", 800, required=True),
                                          "resumeHint": _text_ok(inp.get("resumeHint"), "resumeHint", 400)}}


# ------------------------------------------------------------------ contrôles et aperçu (vérificateur)
def tool_check_run(ctx, inp):
    check = inp.get("check")
    if not isinstance(check, dict):
        raise ToolError("INVALID_INPUT", "check : objet {type, ...} attendu.")
    vinfo = _read_json(os.path.join(ctx.step_dir, "verify.json"), {}) or {}
    rnd = vinfo.get("round")
    out_dir = os.path.join(ctx.project_dir, "verification", str(rnd), "checks") if isinstance(rnd, int) else os.path.join(ctx.step_dir, "checks")
    res = project_checks.run_check(project_checks.CheckCtx(ctx.workspace, ctx.project_dir), check, out_dir=out_dir)
    return {"id": res["id"], "type": res["type"], "ok": res["ok"], "score": res["score"], "findings": res["findings"][:30]}


def tool_preview_fetch(ctx, inp):
    """Récupération locale d'une page du site construit (workspace/site/dist/) : statut, taille, titre, liens, texte. Aucun réseau.
    L'atelier de sites (B5) le remplace par la version à jeton d'aperçu (register_tool('preview_fetch', ...))."""
    path = inp.get("path") or "index.html"
    if isinstance(path, str) and path.endswith("/"):
        path += "index.html"
    try:
        full = pp.resolve(ctx.workspace, "site/dist/" + path.lstrip("/"), kind="file", must_exist=True, allowed_ext={"html", "htm", "css", "js", "json", "xml", "txt", "svg"})
    except pp.PathError as e:
        return {"status": 404, "detail": e.detail}
    with open(full, "rb") as f:
        raw = f.read(1024 * 1024)
    text = _decode_text(raw)
    title = re.search(r"<title[^>]*>(.*?)</title>", text, re.IGNORECASE | re.DOTALL)
    links = re.findall(r'<a\s[^>]*href="([^"#][^"]*)"', text, re.IGNORECASE)[:60]
    body = re.sub(r"<script.*?</script>|<style.*?</style>|<[^>]+>", " ", text, flags=re.IGNORECASE | re.DOTALL)
    rec = {"id": "FET-" + secrets.token_hex(4), "path": pp.rel_of(ctx.workspace, full), "status": 200, "bytes": len(raw),
           "title": (title.group(1).strip()[:200] if title else ""), "links": links, "text": re.sub(r"\s+", " ", body).strip()[:4000]}
    if ctx.step_dir:
        try:
            os.makedirs(os.path.join(ctx.step_dir, "fetches"), exist_ok=True)
            with open(os.path.join(ctx.step_dir, "fetches", rec["id"] + ".json"), "w", encoding="utf-8") as f:
                json.dump({k: v for k, v in rec.items() if k != "text"}, f, ensure_ascii=False)
        except OSError:
            pass
    return rec


# ------------------------------------------------------------------ import d'un fichier du bac à sable (lanceur seulement)
def tool_import_file(ctx, inp):
    """Copie un fichier téléchargé par le lanceur (stepDir/downloads/) dans l'espace de travail, par le chemin sûr : un nom
    « a__b__c.png » est rangé en « a/b/c.png ». Extension, taille, nombre de fichiers : contrôlés ici, pas par le lanceur."""
    src = str(inp.get("srcPath") or "")
    real_src = os.path.realpath(src)
    dl = os.path.realpath(os.path.join(ctx.step_dir, "downloads"))
    if not real_src.startswith(dl + os.sep) or not os.path.isfile(real_src) or pp._is_link_or_reparse(src):
        raise ToolError("PATH_INVALID", "Fichier source invalide.")
    name = str(inp.get("destName") or os.path.basename(real_src))
    rel = name.replace("__", "/")
    full = _resolve(ctx, rel, kind="file", allowed_ext=set(pp.IMPORT_EXT))
    size = os.path.getsize(real_src)
    if size > 25 * 1024 * 1024:
        raise ToolError("TOO_LARGE", "Fichier trop gros (25 Mo maximum).")
    exists = os.path.isfile(full)
    _check_capacity(ctx, max(0, size - (os.path.getsize(full) if exists else 0)), not exists)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(real_src, "rb") as f:
        pp.atomic_write_bytes(full, f.read())
    return {"path": pp.rel_of(ctx.workspace, full), "bytes": size, "replaced": exists}


for _name, _fn in (
        ("workspace_list", tool_workspace_list), ("workspace_read", tool_workspace_read), ("workspace_view_image", tool_workspace_view_image),
        ("workspace_write", tool_workspace_write), ("workspace_append", tool_workspace_append), ("workspace_delete", tool_workspace_delete),
        ("workspace_search", tool_workspace_search), ("deliverable_register", tool_deliverable_register), ("request_input", tool_request_input),
        ("note_decision", tool_note_decision), ("project_plan", tool_project_plan), ("request_approval", tool_request_approval),
        ("step_complete", tool_step_complete), ("step_blocked", tool_step_blocked), ("check_run", tool_check_run),
        ("preview_fetch", tool_preview_fetch), ("import_file", tool_import_file)):
    REGISTRY[_name] = {"fn": _fn, "kinds": None}


def run_tool(name, payload):
    """Point d'entrée unique : exécute un outil et renvoie TOUJOURS un dict JSON ({"ok":true,"result":..} ou {"ok":false,"error":..})."""
    try:
        ent = REGISTRY.get(name)
        if ent is None:
            raise ToolError("UNKNOWN_TOOL", f"Outil inconnu : {str(name)[:40]}")
        ctx = ToolCtx(payload)
        if name not in RUNNER_ONLY:
            if ent["kinds"] is None:
                if name not in TOOLS_BY_KIND.get(ctx.kind, ()):
                    raise ToolError("NOT_ALLOWED", f"L'outil « {name} » n'est pas disponible dans une étape « {ctx.kind} ».")
            elif ctx.kind not in ent["kinds"]:
                raise ToolError("NOT_ALLOWED", f"L'outil « {name} » n'est pas disponible dans une étape « {ctx.kind} ».")
        return {"ok": True, "result": ent["fn"](ctx, ctx.input)}
    except ToolError as e:
        out = {"ok": False, "error": e.code, "detail": e.detail}
        out.update(e.extra)
        return out
    except pp.PathError as e:
        return {"ok": False, "error": e.code, "detail": e.detail}
    except Exception as e:  # noqa: BLE001 - jamais de trace brute vers le modèle
        sys.stderr.write(f"project_tools {name}: {type(e).__name__}: {e}\n")
        return {"ok": False, "error": "INTERNAL", "detail": "Erreur interne de l'outil."}
