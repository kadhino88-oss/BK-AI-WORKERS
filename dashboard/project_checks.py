# -*- coding: utf-8 -*-
"""Contrôles typés exécutés par le MOTEUR, sans LLM (docs/AUTONOMY-ENGINE.md, sections 4.1 et 4.2).

Ce sont les preuves les plus fortes : rapides, gratuites, reproductibles. Un critère « auto » n'est PASS que si son contrôle rend ok:true ;
le vérificateur (modèle) ne peut pas passer outre. Types de ce module : file_exists, file_contains, xlsx_check, docx_check, csv_check,
json_schema, approval_executed, count_matches. Le type site_check est fourni par l'atelier de sites (dashboard/site_factory.py) via
register_check(). Bibliothèque standard seulement.

Résultat enregistré (verification/<tour>/checks/CHK-<8 hex>.json) :
  {"id","type","ranUtc","ok","score","findings":[{"rule","severity","file","detail"}],"inputs":[{"path","sha256"}],"check":{...}}
"""
import csv
import datetime
import io
import json
import os
import re
import secrets
import time

import project_paths as pp

MAX_READ_BYTES = 5 * 1024 * 1024
CHECK_ID_RE = re.compile(r"^CHK-[0-9a-f]{8}\Z")
CHECKS = {}            # type -> fn(ctx, check, res)
_ERROR_VALUE_RE = re.compile(r"#(?:REF|DIV/0|NAME|VALUE|N/A|NUM|NULL)[!?]?")


class CheckCtx:
    def __init__(self, workspace, project_dir=None):
        self.workspace = workspace
        self.project_dir = project_dir


class Res:
    """Accumulateur d'un contrôle : assertions réussies/échouées, constats, fichiers lus."""

    def __init__(self):
        self.findings = []
        self.inputs = []
        self.passed = 0
        self.total = 0
        self._seen_inputs = set()

    def ok(self):
        self.total += 1
        self.passed += 1

    def fail(self, rule, detail, file=None, severity="error"):
        self.total += 1
        self.findings.append({"rule": rule, "severity": severity, "file": file, "detail": str(detail)[:500]})
        if severity != "error":      # un avertissement ne fait pas échouer le contrôle
            self.passed += 1

    def info(self, rule, detail, file=None):
        self.findings.append({"rule": rule, "severity": "info", "file": file, "detail": str(detail)[:500]})

    def note_input(self, rel, full):
        if rel in self._seen_inputs:
            return
        self._seen_inputs.add(rel)
        try:
            self.inputs.append({"path": rel, "sha256": pp.sha256_file(full)})
        except OSError:
            pass


def register_check(name, fn):
    """Enregistre un type de contrôle (atelier de sites : site_check). fn(ctx, check, res)."""
    CHECKS[name] = fn
    try:
        import projects_plan
        projects_plan.register_check_type(name)
    except ImportError:
        pass


def _file(ctx, res, check, key="path", exts=None, must_exist=True):
    """Chemin absolu sûr du fichier visé par le contrôle, ou None (constat enregistré)."""
    rel = check.get(key)
    try:
        full = pp.resolve(ctx.workspace, rel, kind="file", must_exist=must_exist, allowed_ext=exts)
    except pp.PathError as e:
        res.fail("path.invalid" if e.code != "NOT_FOUND" else "file.missing", e.detail, file=str(rel)[:180])
        return None, None
    if must_exist and not os.path.isfile(full):
        res.fail("file.missing", f"Fichier absent : {rel}", file=rel)
        return None, None
    res.note_input(rel, full)
    return rel, full


def _read_text(full):
    with open(full, "rb") as f:
        raw = f.read(MAX_READ_BYTES)
    for enc in ("utf-8-sig", "cp1252"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def _num(value, default=0):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else default


# ------------------------------------------------------------------ file_exists / file_contains / count_matches
def check_file_exists(ctx, check, res):
    rel, full = _file(ctx, res, check)
    if full is None:
        return
    size = os.path.getsize(full)
    min_bytes = max(1, int(_num(check.get("minBytes"), 1)))
    if size < min_bytes:
        res.fail("file.too_small", f"{rel} fait {size} octet(s), au moins {min_bytes} attendu(s).", file=rel)
    else:
        res.ok()


# Garde de premier niveau (rapide, pas une preuve) : quantificateur dans un groupe lui-même quantifié, ou alternation dans un groupe quantifié
# ((a|aa)+). La vraie protection est le sous-processus à délai de _regex_run : aucune expression ne tourne dans le processus du serveur.
_NESTED_QUANT = re.compile(r"\((?:[^()]*[+*][^()]*|[^()]*\|[^()]*)\)[+*{]")

REGEX_TIMEOUT_SEC = 3.0
REGEX_MAX_TEXT = 200_000      # le texte testé par une expression est borné (le reste du fichier n'est pas examiné)

_REGEX_WORKER = (
    "import json, re, sys\n"
    "d = json.loads(sys.stdin.buffer.read().decode('utf-8'))\n"
    "try:\n"
    "    rx = re.compile(d['pattern'], d['flags'])\n"
    "    out = {'r': rx.search(d['text']) is not None} if d['op'] == 'search' else {'r': len(rx.findall(d['text']))}\n"
    "except re.error as e:\n"
    "    out = {'err': str(e)[:120]}\n"
    "sys.stdout.write(json.dumps(out))\n"
)


class RegexRefused(Exception):
    """Expression inutilisable (trop longue, dangereuse, invalide, trop lente). Le message est montrable au Worker."""


def _regex_run(op, pattern, text, flags=0, timeout=None):
    """Exécute re.search (op='search' -> bool) ou re.findall (op='count' -> entier) dans un SOUS-PROCESSUS avec délai dur : un plan écrit par un
    modèle (ou du contenu injecté) ne peut pas figer le serveur. Lève RegexRefused."""
    import subprocess
    import sys
    if not isinstance(pattern, str) or not pattern or len(pattern) > 300:
        raise RegexRefused("Expression régulière absente ou trop longue.")
    if _NESTED_QUANT.search(pattern):
        raise RegexRefused("Expression régulière refusée (quantificateurs ou alternation imbriqués).")
    payload = json.dumps({"op": op, "pattern": pattern, "flags": int(flags), "text": text[:REGEX_MAX_TEXT]}).encode("utf-8")
    env = {k: v for k, v in os.environ.items() if k in ("SYSTEMROOT", "PATH", "LANG", "LC_ALL", "TEMP", "TMP")}
    try:
        p = subprocess.run([sys.executable, "-I", "-c", _REGEX_WORKER], input=payload, capture_output=True, env=env,
                           timeout=timeout or REGEX_TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        raise RegexRefused("Expression régulière interrompue (trop lente).")
    except OSError:
        raise RegexRefused("Expression régulière non évaluée (sous-processus indisponible).")
    try:
        out = json.loads(p.stdout.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise RegexRefused("Expression régulière non évaluée.")
    if "err" in out:
        raise RegexRefused(f"Expression régulière invalide : {out['err']}")
    return out["r"]


def _match(text, pattern):
    """Texte simple (insensible à la casse) ou « re:<expression> ». Les expressions viennent d'un plan écrit par un modèle : elles tournent dans
    un sous-processus à délai (_regex_run), jamais dans le serveur. Lève RegexRefused si l'expression est inutilisable."""
    if pattern.startswith("re:"):
        return _regex_run("search", pattern[3:], text, re.MULTILINE | re.IGNORECASE)
    return pattern.lower() in text.lower()


def check_file_contains(ctx, check, res):
    rel, full = _file(ctx, res, check)
    if full is None:
        return
    text = _read_text(full)
    must = [m for m in (check.get("mustContain") or []) if isinstance(m, str)]
    must_not = [m for m in (check.get("mustNotContain") or []) if isinstance(m, str)]
    if not must and not must_not:
        res.fail("check.empty", "Aucune condition (mustContain / mustNotContain) dans ce contrôle.", file=rel)
        return
    try:
        for m in must:
            if _match(text, m):
                res.ok()
            else:
                res.fail("content.missing", f"Texte attendu absent de {rel} : « {m[:80]} »", file=rel)
        for m in must_not:
            if _match(text, m):
                res.fail("content.forbidden", f"Texte interdit présent dans {rel} : « {m[:80]} »", file=rel)
            else:
                res.ok()
    except RegexRefused as e:
        res.fail("check.invalid", str(e), file=rel)


def check_count_matches(ctx, check, res):
    rel, full = _file(ctx, res, check)
    if full is None:
        return
    pattern = check.get("regex")
    if not isinstance(pattern, str) or not pattern or len(pattern) > 300:
        res.fail("check.invalid", "Expression régulière absente ou trop longue.", file=rel)
        return
    try:
        n = _regex_run("count", pattern, _read_text(full), re.MULTILINE)
    except RegexRefused as e:
        res.fail("check.invalid", str(e), file=rel)
        return
    minimum = int(_num(check.get("min"), 1))
    if n >= minimum:
        res.ok()
    else:
        res.fail("count.too_low", f"{rel} : {n} occurrence(s), au moins {minimum} attendue(s).", file=rel)


# ------------------------------------------------------------------ csv_check
def check_csv_check(ctx, check, res):
    rel, full = _file(ctx, res, check)
    if full is None:
        return
    text = _read_text(full)
    head = text[:4000]
    delim = ";" if head.count(";") > head.count(",") and head.count(";") >= head.count("\t") else ("\t" if head.count("\t") > head.count(",") else ",")
    rows = list(csv.reader(io.StringIO(text), delimiter=delim))
    if not rows:
        res.fail("csv.empty", f"{rel} est vide.", file=rel)
        return
    header = [h.strip() for h in rows[0]]
    data = [r for r in rows[1:] if any(c.strip() for c in r)]
    for col in [c for c in (check.get("columns") or []) if isinstance(c, str)]:
        if col in header:
            res.ok()
        else:
            res.fail("csv.column_missing", f"Colonne absente de {rel} : « {col} » (colonnes : {', '.join(header)[:200]}).", file=rel)
    min_rows = int(_num(check.get("minRows"), 0))
    if min_rows:
        if len(data) >= min_rows:
            res.ok()
        else:
            res.fail("csv.too_few_rows", f"{rel} : {len(data)} ligne(s) de données, au moins {min_rows} attendue(s).", file=rel)
    uniq = check.get("unique")
    if isinstance(uniq, str) and uniq:
        if uniq in header:
            idx = header.index(uniq)
            seen, dup = set(), []
            for r in data:
                v = (r[idx].strip().lower() if idx < len(r) else "")
                if v and v in seen:
                    dup.append(v)
                seen.add(v)
            if dup:
                res.fail("csv.duplicates", f"{rel} : {len(dup)} doublon(s) dans la colonne « {uniq} » (ex. {dup[0][:60]}).", file=rel)
            else:
                res.ok()
        else:
            res.fail("csv.column_missing", f"Colonne d'unicité absente de {rel} : « {uniq} ».", file=rel)
    for col in [c for c in (check.get("noEmpty") or []) if isinstance(c, str)]:
        if col not in header:
            res.fail("csv.column_missing", f"Colonne absente de {rel} : « {col} ».", file=rel)
            continue
        idx = header.index(col)
        empty = sum(1 for r in data if idx >= len(r) or not r[idx].strip())
        if empty:
            res.fail("csv.empty_cells", f"{rel} : {empty} ligne(s) avec « {col} » vide (sur {len(data)}).", file=rel)
        else:
            res.ok()


# ------------------------------------------------------------------ xlsx_check / docx_check (via file_preview, module existant)
def _preview(full, name):
    import file_preview
    return file_preview.build_preview(full, name)


def check_xlsx_check(ctx, check, res):
    rel, full = _file(ctx, res, check, exts={"xlsx"})
    if full is None:
        return
    try:
        pv = _preview(full, rel)
    except Exception as e:  # noqa: BLE001 - PreviewError ou fichier corrompu
        res.fail("xlsx.unreadable", f"Classeur illisible ({e}).", file=rel)
        return
    sheets = pv.get("sheets") or []
    res.ok()
    names = [s.get("name") for s in sheets]
    for want in [s for s in (check.get("sheets") or []) if isinstance(s, str)]:
        if want in names:
            res.ok()
        else:
            res.fail("xlsx.sheet_missing", f"Feuille absente de {rel} : « {want} » (feuilles : {', '.join(map(str, names))[:200]}).", file=rel)
    formulas = sum(int(s.get("formulaCells") or 0) for s in sheets)
    minf = int(_num(check.get("minFormulas"), 0))
    if minf:
        if formulas >= minf:
            res.ok()
        else:
            res.fail("xlsx.hardcoded_values", f"{rel} : {formulas} formule(s) vivante(s), au moins {minf} attendue(s) "
                     "(des valeurs figées à la place des formules ne sont pas acceptées).", file=rel)
    if check.get("noErrors", True):
        bad = []
        for s in sheets:
            for ri, row in enumerate(s.get("rows") or []):
                for ci, cell in enumerate(row):
                    if isinstance(cell, str) and _ERROR_VALUE_RE.search(cell):
                        bad.append(f"{s.get('name')}!{chr(65 + ci) if ci < 26 else ci}{ri + 1}")
        if bad:
            res.fail("xlsx.error_values", f"{rel} : valeur d'erreur dans {len(bad)} cellule(s) (ex. {', '.join(bad[:3])}).", file=rel)
        else:
            res.ok()


def check_docx_check(ctx, check, res):
    rel, full = _file(ctx, res, check, exts={"docx"})
    if full is None:
        return
    try:
        pv = _preview(full, rel)
    except Exception as e:  # noqa: BLE001
        res.fail("docx.unreadable", f"Document illisible ({e}).", file=rel)
        return
    res.ok()
    blocks = pv.get("blocks") or []
    words = 0
    heads = []
    for b in blocks:
        if b.get("type") in ("p", "h"):
            words += len(str(b.get("text") or "").split())
            if b.get("type") == "h":
                heads.append(str(b.get("text") or "").strip().lower())
        elif b.get("type") == "table":
            for row in b.get("rows") or []:
                for c in row:
                    words += len(str(c).split())
    minw = int(_num(check.get("minWords"), 0))
    if minw:
        if words >= minw:
            res.ok()
        else:
            res.fail("docx.too_short", f"{rel} : {words} mot(s), au moins {minw} attendu(s).", file=rel)
    for h in [h for h in (check.get("headings") or []) if isinstance(h, str)]:
        if any(h.strip().lower() in x for x in heads):
            res.ok()
        else:
            res.fail("docx.heading_missing", f"Titre absent de {rel} : « {h[:80]} ».", file=rel)


# ------------------------------------------------------------------ json_schema (sous-ensemble : type, required, properties, items, enum, const, bornes)
def _type_ok(value, t):
    return {"object": isinstance(value, dict), "array": isinstance(value, list), "string": isinstance(value, str),
            "integer": isinstance(value, int) and not isinstance(value, bool),
            "number": isinstance(value, (int, float)) and not isinstance(value, bool),
            "boolean": isinstance(value, bool), "null": value is None}.get(t, False)


def validate_schema(value, schema, path="$", out=None, depth=0):
    out = out if out is not None else []
    if depth > 12 or not isinstance(schema, dict) or len(out) >= 20:
        return out
    t = schema.get("type")
    if t is not None:
        types = t if isinstance(t, list) else [t]
        if not any(_type_ok(value, x) for x in types):
            out.append(f"{path} : type attendu {t}")
            return out
    if "const" in schema and value != schema["const"]:
        out.append(f"{path} : valeur attendue {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        out.append(f"{path} : valeur hors de la liste autorisée")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            out.append(f"{path} : trop court")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            out.append(f"{path} : trop long")
        if isinstance(schema.get("pattern"), str):
            try:
                if not _regex_run("search", schema["pattern"], value[:20000]):
                    out.append(f"{path} : format invalide")
            except RegexRefused:
                out.append(f"{path} : expression régulière refusée (trop longue, dangereuse, invalide ou trop lente)")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            out.append(f"{path} : inférieur au minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            out.append(f"{path} : supérieur au maximum {schema['maximum']}")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            out.append(f"{path} : au moins {schema['minItems']} élément(s) attendu(s)")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            out.append(f"{path} : au plus {schema['maxItems']} élément(s)")
        if isinstance(schema.get("items"), dict):
            for i, v in enumerate(value[:200]):
                validate_schema(v, schema["items"], f"{path}[{i}]", out, depth + 1)
    if isinstance(value, dict):
        for k in schema.get("required") or []:
            if k not in value:
                out.append(f"{path} : champ requis « {k} » absent")
        props = schema.get("properties") or {}
        for k, sub in props.items():
            if k in value:
                validate_schema(value[k], sub, f"{path}.{k}", out, depth + 1)
        if schema.get("additionalProperties") is False:
            for k in value:
                if k not in props:
                    out.append(f"{path} : champ non prévu « {k} »")
    return out


def check_json_schema(ctx, check, res):
    rel, full = _file(ctx, res, check)
    if full is None:
        return
    try:
        data = json.loads(_read_text(full))
    except ValueError as e:
        res.fail("json.invalid", f"{rel} n'est pas un JSON valide ({e}).", file=rel)
        return
    errs = validate_schema(data, check.get("schema") or {})
    if errs:
        for e in errs[:10]:
            res.fail("json.schema", e, file=rel)
    else:
        res.ok()


# ------------------------------------------------------------------ approval_executed
def check_approval_executed(ctx, check, res):
    approvals = []
    if ctx.project_dir:
        try:
            with open(os.path.join(ctx.project_dir, "approvals.json"), encoding="utf-8") as f:
                approvals = json.load(f).get("items") or []
        except (OSError, ValueError, AttributeError):
            approvals = []
    kind = str(check.get("kind") or "")
    minimum = int(_num(check.get("minCount"), 1))
    n = 0
    for a in approvals:
        if not isinstance(a, dict) or a.get("status") != "EXECUTED":
            continue
        key1 = str(a.get("connectorId") or "")
        key2 = f"{key1}:{a.get('operation')}"
        if not kind or kind in (key1, key2, a.get("kind")):
            n += 1
    if n >= minimum:
        res.ok()
    else:
        res.fail("approval.not_executed", f"{n} action(s) exécutée(s) de type « {kind or 'toutes'} », au moins {minimum} attendue(s).")


CHECKS.update({
    "file_exists": check_file_exists, "file_contains": check_file_contains, "xlsx_check": check_xlsx_check,
    "docx_check": check_docx_check, "csv_check": check_csv_check, "json_schema": check_json_schema,
    "approval_executed": check_approval_executed, "count_matches": check_count_matches,
})


def _now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_check_id():
    return "CHK-" + secrets.token_hex(4)


def run_check(ctx, check, out_dir=None):
    """Exécute un contrôle typé. Ne lève jamais : toute erreur devient un constat. Si out_dir est donné, le résultat y est écrit
    (CHK-xxxxxxxx.json). Renvoie le dict du résultat."""
    res = Res()
    ctype = check.get("type") if isinstance(check, dict) else None
    started = time.time()
    if ctype not in CHECKS:
        res.fail("check.unknown_type", f"Type de contrôle inconnu ou indisponible : {str(ctype)[:40]}")
    else:
        try:
            CHECKS[ctype](ctx, check, res)
        except Exception as e:  # noqa: BLE001 - un contrôle ne doit jamais faire tomber le moteur
            res.fail("check.exception", f"Contrôle interrompu : {type(e).__name__}")
    errors = [f for f in res.findings if f["severity"] == "error"]
    out = {
        "id": new_check_id(), "type": ctype if isinstance(ctype, str) else None, "ranUtc": _now_iso(),
        "ok": not errors, "score": round(res.passed / res.total, 3) if res.total else (0.0 if errors else 1.0),
        "findings": res.findings[:60], "inputs": res.inputs[:40], "durationMs": int((time.time() - started) * 1000),
        "check": _safe_check_echo(check),
    }
    if out_dir:
        try:
            os.makedirs(out_dir, exist_ok=True)
            tmp = os.path.join(out_dir, "." + out["id"] + ".tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(out, f, ensure_ascii=False, indent=1)
            os.replace(tmp, os.path.join(out_dir, out["id"] + ".json"))
        except OSError:
            pass
    return out


def _safe_check_echo(check):
    if not isinstance(check, dict):
        return {}
    try:
        return json.loads(json.dumps(check, default=str)[:4000])
    except ValueError:
        return {"type": str(check.get("type"))[:40]}


def load_check(dir_path, check_id):
    """Résultat d'un contrôle déjà exécuté (None si absent ou identifiant invalide)."""
    if not isinstance(check_id, str) or not CHECK_ID_RE.match(check_id):
        return None
    try:
        with open(os.path.join(dir_path, check_id + ".json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None
