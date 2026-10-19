# -*- coding: utf-8 -*-
"""File d'approbations d'un projet (docs/AUTONOMY-ENGINE.md, section 5) : articles, classes de risque, validation à l'ingestion, décisions,
exécution une seule fois, expiration, rappels.

Principe : toute action SORTANTE (envoi, publication, paiement, suppression, appel, dépense, modification d'un site en ligne) exige la validation
explicite du client. Un projet met l'action en file et continue ; le client valide en lots ; le moteur exécute par le chemin existant
(run_connector_dispatch_bridge -> Confirm-Connector-Action.ps1), UNE fois : le statut EXECUTING est écrit sur disque AVANT l'appel et un
EXECUTING trouvé au démarrage devient UNKNOWN_CHECK_MANUALLY (jamais rejoué : un double envoi est pire qu'une attente).

Statuts : PENDING -> APPROVED -> EXECUTING -> EXECUTED | FAILED | UNKNOWN_CHECK_MANUALLY ; REJECTED, EXPIRED, SUPERSEDED.
Module PUR : le serveur injecte run_connector, notify et l'horloge.
"""
import collections
import fnmatch
import hashlib
import json
import os
import queue
import re
import secrets
import sys
import threading
import time

import projects_config as cfg
import projects_store as ps

STATUSES = ("PENDING", "APPROVED", "EXECUTING", "EXECUTED", "FAILED", "UNKNOWN_CHECK_MANUALLY", "REJECTED", "EXPIRED", "SUPERSEDED")
OPEN_STATUSES = frozenset(("PENDING", "APPROVED", "EXECUTING"))
SATISFIED_STATUSES = frozenset(("EXECUTED", "REJECTED", "SUPERSEDED", "FAILED", "UNKNOWN_CHECK_MANUALLY"))   # un étape dépendante peut continuer
KINDS = ("connector_action", "manual_action", "site_publish")
RISK_ORDER = {"low": 0, "medium": 1, "high": 2}
ID_RE = re.compile(r"^APR-[0-9a-f]{8}\Z")
CONFIRM_TEXT = "J'autorise"

_DEFAULTS = cfg.DEFAULT_LIMITS["approvals"]
PENDING_PER_PROJECT = _DEFAULTS["pendingPerProject"]
PENDING_PER_CLIENT = _DEFAULTS["pendingPerClient"]
TTL_DAYS = _DEFAULTS["ttlDays"]
PARAMS_MAX_BYTES = _DEFAULTS["paramsMaxBytes"]
BATCH_MAX = _DEFAULTS["batchMax"]

_SENSITIVE_PARAM_HINTS = ("token", "secret", "password", "apikey", "api_key", "authorization", "auth", "bearer", "key", "credential",
                          "signature", "hash")
_MASKED = "•••masqué•••"
_PARAM_VALUE_MAX = 2000
_EMAIL_RE = re.compile(r"[^\s,;<>]+@[^\s,;<>]+")


# ------------------------------------------------------------------ connecteurs et opérations réelles
_OPS_CACHE = {}


def connector_ops(root):
    """{connecteur: ensemble d'opérations} lu dans core/integrations/Connector-Dispatch.ps1 ($Script:OperationTable) et dans les fichiers
    qui l'étendent (Connector-Site-Publish.ps1). La table PowerShell reste la seule source : aucune liste n'est recopiée ici."""
    paths = [os.path.join(root, "core", "integrations", n) for n in ("Connector-Dispatch.ps1", "Connector-Site-Publish.ps1")]
    key = tuple((p, os.path.getmtime(p) if os.path.isfile(p) else 0) for p in paths)
    hit = _OPS_CACHE.get(root)
    if hit and hit[0] == key:
        return hit[1]
    ops = {"slack": {"SEARCH_MESSAGES", "DRAFT_MESSAGE", "POST_MESSAGE"}, "twilio": {"PLACE_CALL"}}      # gérés à part dans Invoke-ConnectorAction
    main = paths[0]
    try:
        with open(main, encoding="utf-8-sig") as f:
            current = None
            in_ops = False
            for line in f:
                m = re.match(r'^    "([a-z_0-9]+)"\s*=\s*@\{', line)
                if m:
                    current = m.group(1)
                    ops.setdefault(current, set())
                    in_ops = False
                    continue
                if current and re.match(r"^\s{8}Operations\s*=\s*@\{", line):
                    in_ops = True
                    continue
                if current and in_ops:
                    m = re.match(r'^\s{12}"([A-Z][A-Z0-9_]+)"\s*=', line)
                    if m:
                        ops[current].add(m.group(1))
    except OSError:
        pass
    extra = paths[1]
    try:
        with open(extra, encoding="utf-8-sig") as f:
            for m in re.finditer(r'OperationTable\["([a-z_0-9]+)"\]\.Operations\["([A-Z][A-Z0-9_]+)"\]', f.read()):
                ops.setdefault(m.group(1), set()).add(m.group(2))
    except OSError:
        pass
    _OPS_CACHE[root] = (key, ops)
    return ops


def active_connectors(root, client_id):
    """Connecteurs que CE client a activés (core/connectors/data/<ClientId>.json), sans le suffixe « .controlled »."""
    if not ps.CLIENT_ID_RE.match(client_id or ""):
        return []
    data = cfg.read_json(os.path.join(root, "core", "connectors", "data", client_id + ".json"), []) or []
    return sorted({re.sub(r"\.controlled\Z", "", str(c)).lower() for c in data if isinstance(c, str)})


def is_read_only(op):
    return str(op).startswith(("READ_", "SEARCH_")) or op == "TEST_CONNECTION"


def connector_problem(root, client_id, conn, op):
    """None si (connecteur activé pour ce client ET opération réelle d'écriture) ; sinon (code, message français)."""
    if not re.match(r"^[a-z0-9_]{1,40}\Z", str(conn)) or not re.match(r"^[A-Z][A-Z0-9_]{1,60}\Z", str(op)):
        return ("INVALID_INPUT", "connectorId ou operation invalide.")
    if conn not in active_connectors(root, client_id):
        return ("CONNECTOR_MISSING", f"Le connecteur « {conn} » n'est pas connecté à ce compte : demande au client de le connecter "
                "(terminer l'étape avec step_blocked, raison CONNECTOR) ; ne prétends pas avoir agi.")
    table = connector_ops(root)
    if conn not in table or op not in table[conn]:
        return ("UNSUPPORTED_OPERATION", f"L'opération « {op} » n'existe pas pour « {conn} ».")
    if is_read_only(op):
        return ("NOT_AN_ACTION", f"« {op} » est une lecture : elle s'exécute tout de suite avec use_connector, sans approbation.")
    return None


# ------------------------------------------------------------------ risque (core/projects/APPROVAL-RISK.json)
_RISK_CACHE = {}


def risk_table(root):
    path = os.path.join(root, "core", "projects", "APPROVAL-RISK.json")
    mt = os.path.getmtime(path) if os.path.isfile(path) else 0
    hit = _RISK_CACHE.get(root)
    if hit and hit[0] == mt:
        return hit[1]
    data = cfg.read_json(path, {}) or {}
    data.setdefault("unknownWrite", "medium")
    data.setdefault("highRecipientsThreshold", 20)
    for k in ("low", "medium", "high", "irreversible", "autoApproveSafeOps"):
        data.setdefault(k, [])
    data.setdefault("whatItDoes", {})
    _RISK_CACHE[root] = (mt, data)
    return data


def _entry_match(entry, conn, op):
    """Nombre de jokers de l'entrée « connecteur:OPERATION » si elle s'applique, sinon None (moins de jokers = plus précis)."""
    if ":" not in entry:
        return None
    ec, eo = entry.split(":", 1)
    if not (ec == "*" or ec == conn):
        return None
    if not (eo == "*" or fnmatch.fnmatchcase(op, eo)):
        return None
    return int(ec == "*") + int("*" in eo)


def _best(entries, conn, op):
    best = None
    for e in entries:
        w = _entry_match(e, conn, op)
        if w is not None and (best is None or w < best):
            best = w
    return best


def count_recipients(params, hint=None):
    if isinstance(hint, int) and not isinstance(hint, bool) and hint >= 0:
        return hint
    n = 0
    for k, v in (params or {}).items():
        if str(k).lower() in ("to", "cc", "bcc", "recipients", "emails", "receiver") and isinstance(v, (str, list)):
            text = " ".join(str(x) for x in v) if isinstance(v, list) else v
            n += max(len(_EMAIL_RE.findall(text)), 1 if text.strip() else 0)
    return n


def classify_risk(root, conn, op, params=None, recipients=None):
    """low | medium | high. La règle la plus précise gagne (moins de jokers) ; à précision égale, la classe la plus sévère. Une écriture absente
    de la table vaut « medium » ; plus de 20 destinataires = high."""
    tab = risk_table(root)
    found = []
    for cls in ("low", "medium", "high"):
        w = _best(tab[cls], conn, op)
        if w is not None:
            found.append((w, -RISK_ORDER[cls], cls))
    cls = min(found)[2] if found else str(tab.get("unknownWrite") or "medium")
    if cls not in RISK_ORDER:
        cls = "medium"
    if count_recipients(params, recipients) > int(tab.get("highRecipientsThreshold") or 20):
        cls = "high"
    return cls


def is_reversible(root, conn, op):
    return _best(risk_table(root)["irreversible"], conn, op) is None


def default_what(conn, op, root=None):
    tab = risk_table(root) if root else {"whatItDoes": {}}
    what = tab.get("whatItDoes") or {}
    best, best_w = None, None
    for entry, text in what.items():
        w = _entry_match(entry, conn, op)
        if w is not None and (best_w is None or w < best_w):
            best, best_w = text, w
    return best or f"Exécute l'action {op} sur {conn} une fois que vous l'avez validée."


def is_safe_draft(root, conn, op):
    return f"{conn}|{op}" in (risk_table(root).get("autoApproveSafeOps") or [])


# ------------------------------------------------------------------ paramètres affichés
def safe_value(value, depth=0):
    if isinstance(value, str):
        return value[:_PARAM_VALUE_MAX] + " …(tronqué)" if len(value) > _PARAM_VALUE_MAX else value
    if isinstance(value, dict) and depth == 0:
        return safe_params(value, depth + 1)
    return value


def safe_params(params, depth=0):
    """Copie assainie des paramètres d'une action pour l'AFFICHAGE : masque les clés qui ressemblent à un secret, tronque les textes longs."""
    if not isinstance(params, dict):
        return {}
    out = {}
    for k, v in params.items():
        out[k] = _MASKED if any(h in str(k).lower() for h in _SENSITIVE_PARAM_HINTS) else safe_value(v, depth)
    return out


def editable_fields(item):
    if item.get("kind") != "connector_action":
        return []
    return [k for k in (item.get("params") or {}) if not any(h in str(k).lower() for h in _SENSITIVE_PARAM_HINTS)]


def effective_params(item):
    p = dict(item.get("params") or {})
    p.update(item.get("editedParams") or {})
    return p


def public_view(item):
    ex = item.get("execution") or {}
    return {
        "id": item["id"], "batchId": item.get("batchId"), "stepId": item.get("stepId"), "worker": item.get("worker"), "kind": item.get("kind"),
        "connectorId": item.get("connectorId"), "operation": item.get("operation"), "display": item.get("display") or {},
        "status": item.get("status"), "risk": item.get("risk"), "reversible": bool(item.get("reversible")),
        "params": safe_params(effective_params(item)), "editableFields": editable_fields(item),
        "editedFields": sorted((item.get("editedParams") or {}).keys()),
        "recipients": (item.get("display") or {}).get("recipients"), "spendChf": (item.get("display") or {}).get("spendChf"),
        "createdUtc": item.get("createdUtc"), "expiresUtc": item.get("expiresUtc"), "validUntilUtc": item.get("validUntilUtc"),
        "decision": item.get("decision"), "decidedUtc": item.get("decidedUtc"), "autoApproved": bool(item.get("autoApproved")),
        "supersedes": item.get("supersedes"),
        "execution": {"startedUtc": ex.get("startedUtc"), "finishedUtc": ex.get("finishedUtc"), "connectorStatus": ex.get("connectorStatus"),
                      "detail": str(ex.get("detail") or "")[:300]} if ex else None,
    }


# ------------------------------------------------------------------ lecture / écriture du registre
def load_items(store, pid):
    data = store.read_json(pid, "approvals.json", {}) or {}
    items = data.get("items") if isinstance(data, dict) else None
    return items if isinstance(items, list) else []


def save_items(store, pid, items):
    store.write_json(pid, "approvals.json", {"schema": "BK-APPROVALS-V1", "items": items})


def counts(items):
    c = collections.Counter(i.get("status") for i in items)
    return {s: c[s] for s in STATUSES if c.get(s)}


def pending_count(items):
    return sum(1 for i in items if i.get("status") == "PENDING")


def secret_like(text):
    try:
        import installations
        return bool(installations.contains_secret(text))
    except ImportError:  # pragma: no cover
        return False


# ------------------------------------------------------------------ ingestion du spool (les articles écrits par le lanceur / les outils)
def spool_files(project_dir):
    sp = os.path.join(project_dir, "spool")
    try:
        names = sorted(n for n in os.listdir(sp) if n.startswith("approvals-") and n.endswith(".jsonl"))
    except OSError:
        return []
    return [os.path.join(sp, n) for n in names]


def read_spool_items(project_dir):
    rows = []
    for p in spool_files(project_dir):
        try:
            with open(p, encoding="utf-8") as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(rec, dict):
                        rows.append(rec)
        except OSError:
            continue
    return rows


def validate_item(root, client_id, item, existing, client_pending, limits=None, now=None):
    """Validation AUTORITAIRE d'un article du spool. Renvoie (None, item_normalisé) ou (code, détail). `existing` : articles déjà enregistrés
    (dédoublonnage et plafonds) ; `client_pending` : nombre d'articles PENDING de tous les projets de ce client."""
    lim = (limits or cfg.DEFAULT_LIMITS)["approvals"]
    if not isinstance(item, dict) or not ID_RE.match(str(item.get("id") or "")):
        return ("APPROVAL_INVALID", "identifiant d'article invalide")
    kind = item.get("kind")
    if kind not in KINDS:
        return ("APPROVAL_INVALID", "sorte d'article inconnue")
    disp = item.get("display") if isinstance(item.get("display"), dict) else {}
    if not str(disp.get("what") or "").strip():
        return ("APPROVAL_INVALID", "display.what est obligatoire (ce que l'action fait réellement)")
    if not str(disp.get("title") or "").strip():
        return ("APPROVAL_INVALID", "display.title est obligatoire")
    risk = item.get("risk") if item.get("risk") in RISK_ORDER else "medium"
    params = item.get("params") if isinstance(item.get("params"), dict) else {}
    raw = json.dumps(params, ensure_ascii=False, sort_keys=True)
    if len(raw.encode("utf-8")) > int(lim["paramsMaxBytes"]):
        return ("TOO_LARGE", "paramètres trop gros")
    if secret_like(raw):
        return ("SECRET_REFUSED", "les paramètres ressemblent à un secret")
    if kind == "connector_action":
        problem = connector_problem(root, client_id, str(item.get("connectorId") or ""), str(item.get("operation") or ""))
        if problem:
            return problem
        # Le risque est RECALCULÉ ici : un article ne peut pas se déclarer moins risqué que la table.
        calc = classify_risk(root, item["connectorId"], item["operation"], params, disp.get("recipients"))
        if RISK_ORDER[calc] > RISK_ORDER[risk]:
            risk = calc
    status = item.get("status") if item.get("status") in ("PENDING", "EXECUTED") else "PENDING"
    downgraded = False
    if status == "EXECUTED" and not (kind == "connector_action" and item.get("autoApproved") is True and is_safe_draft(root, item.get("connectorId"), item.get("operation"))):
        status, downgraded = "PENDING", True     # seul un vrai brouillon pré-autorisé naît « exécuté » : tout le reste attend la validation du client
    if status == "PENDING":
        if any(e.get("dedupKey") and e.get("dedupKey") == item.get("dedupKey") for e in existing):
            return ("APPROVAL_DUPLICATE", "action déjà préparée")
        if pending_count(existing) >= int(lim["pendingPerProject"]):
            return ("APPROVAL_QUEUE_FULL", "trop d'actions en attente dans ce projet")
        if client_pending >= int(lim["pendingPerClient"]):
            return ("APPROVAL_QUEUE_FULL", "trop d'actions en attente pour ce compte")
    out = dict(item)
    out["risk"] = risk
    out["status"] = status
    out["params"] = params
    if downgraded:
        out.update(autoApproved=False, decision=None, decidedUtc=None, execution=None)
    out["display"] = {"title": str(disp.get("title"))[:200], "what": str(disp.get("what"))[:600], "why": str(disp.get("why") or "")[:600],
                      "recipients": disp.get("recipients") if isinstance(disp.get("recipients"), int) and not isinstance(disp.get("recipients"), bool)
                      else (count_recipients(params) or None),
                      "spendChf": disp.get("spendChf") if isinstance(disp.get("spendChf"), (int, float)) and not isinstance(disp.get("spendChf"), bool)
                      else None}
    if kind == "connector_action":
        out["batchId"] = f"BAT-{item.get('stepId')}-{item.get('connectorId')}-{item.get('operation')}"
    return (None, out)


def ingest_spool(store, pid, root, client_pending_other, limits, rename=False):
    """Valide et enregistre les articles du spool pas encore connus. À appeler DANS un txn du projet (le verrou est tenu). Renvoie
    (nouveaux articles, rejetés [(id, code, détail)]). `rename` : à la fin d'une étape, range les fichiers du spool dans spool/done/."""
    project_dir = store.project_dir(pid)
    items = load_items(store, pid)
    known_ids = {i.get("id") for i in items}
    state = store.state(pid)
    client_id = state["clientId"]
    new, rejected = [], []
    for rec in read_spool_items(project_dir):
        if rec.get("id") in known_ids:
            continue
        known_ids.add(rec.get("id"))
        err, norm = validate_item(root, client_id, rec, items, client_pending_other + pending_count(items), limits)
        if err:
            rejected.append((rec.get("id"), err, norm))
            continue
        items.append(norm)
        new.append(norm)
    if new:
        save_items(store, pid, items)
    if rename:
        done = os.path.join(project_dir, "spool", "done")
        os.makedirs(done, exist_ok=True)
        for p in spool_files(project_dir):
            try:
                os.replace(p, os.path.join(done, os.path.basename(p)[:-6] + "-" + secrets.token_hex(3) + ".jsonl"))
            except OSError:
                pass
    return new, rejected


def new_manual_expiry(now, ttl_days):
    return ps.iso(now + ttl_days * 86400)


# ------------------------------------------------------------------ décisions
class ApprovalError(ps.ProjectError):
    pass


def _find(items, aid):
    for i in items:
        if i.get("id") == aid:
            return i
    return None


def decide_approve(items, aid, now, params_edits=None, confirm=None):
    """Passe un article PENDING à EXECUTING (connecteur) ou EXECUTED (action manuelle déjà faite par le client). Lève ApprovalError.
    Renvoie (article, dispatch) : dispatch = True si l'exécuteur doit appeler le connecteur."""
    it = _find(items, aid)
    if not it:
        raise ApprovalError("NOT_FOUND", "Article introuvable.")
    if it.get("status") == "EXPIRED":
        raise ApprovalError("APPROVAL_EXPIRED", "Cette action a expiré : demandez au Worker de la représenter à jour.")
    if it.get("status") != "PENDING":
        raise ApprovalError("APPROVAL_NOT_PENDING", "Cette action n'est plus en attente.", status=it.get("status"))
    exp = ps.parse_iso(it.get("expiresUtc"))
    valid = ps.parse_iso(it.get("validUntilUtc"))
    if (exp and now >= exp) or (valid and now >= valid):
        it["status"] = "EXPIRED"
        raise ApprovalError("APPROVAL_EXPIRED", "Cette action a expiré : demandez au Worker de la représenter à jour.")
    if it.get("risk") == "high" and confirm != CONFIRM_TEXT:
        raise ApprovalError("CONFIRM_REQUIRED", f"Action à risque élevé : saisissez « {CONFIRM_TEXT} » pour la confirmer.")
    if params_edits:
        if it.get("kind") != "connector_action":
            raise ApprovalError("INVALID_INPUT", "Seule une action de connecteur peut être modifiée.", field="params")
        allowed = set(editable_fields(it))
        edits = {}
        for k, v in params_edits.items():
            if k not in allowed:
                raise ApprovalError("INVALID_INPUT", f"Le paramètre « {str(k)[:40]} » n'est pas modifiable.", field="params")
            if not isinstance(v, (str, int, float, bool)) and v is not None:
                raise ApprovalError("INVALID_INPUT", f"Valeur invalide pour « {str(k)[:40]} ».", field="params")
            edits[k] = v
        merged = dict(it.get("params") or {})
        merged.update(edits)
        raw = json.dumps(merged, ensure_ascii=False, sort_keys=True)
        if len(raw.encode("utf-8")) > PARAMS_MAX_BYTES:
            raise ApprovalError("TOO_LARGE", "Paramètres trop gros.")
        if secret_like(raw):
            raise ApprovalError("SECRET_REFUSED", "Les paramètres ressemblent à un secret : rien n'est envoyé.")
        it["editedParams"] = {**(it.get("editedParams") or {}), **edits}
    it["decision"] = "approve"
    it["decidedUtc"] = ps.iso(now)
    if it.get("kind") == "connector_action":
        it["status"] = "EXECUTING"
        it["execution"] = {"startedUtc": None, "finishedUtc": None, "connectorStatus": None, "detail": "", "executionId": "EX-" + secrets.token_hex(4)}
        return it, True
    it["status"] = "EXECUTED"
    it["execution"] = {"startedUtc": ps.iso(now), "finishedUtc": ps.iso(now), "connectorStatus": "MANUAL", "detail": "Confirmée par le client.",
                       "executionId": "EX-" + secrets.token_hex(4)}
    return it, False


def decide_reject(items, aid, now, reason=None):
    it = _find(items, aid)
    if not it:
        raise ApprovalError("NOT_FOUND", "Article introuvable.")
    if it.get("status") == "EXPIRED":
        raise ApprovalError("APPROVAL_EXPIRED", "Cette action a déjà expiré.")
    if it.get("status") != "PENDING":
        raise ApprovalError("APPROVAL_NOT_PENDING", "Cette action n'est plus en attente.", status=it.get("status"))
    it["status"] = "REJECTED"
    it["decision"] = "reject"
    it["decidedUtc"] = ps.iso(now)
    it["rejectReason"] = str(reason or "")[:500]
    return it


def expire_due(items, now):
    """Articles PENDING arrivés à échéance (7 jours ou validUntilUtc) -> EXPIRED. Renvoie la liste des articles expirés."""
    out = []
    for it in items:
        if it.get("status") != "PENDING":
            continue
        exp = ps.parse_iso(it.get("expiresUtc"))
        valid = ps.parse_iso(it.get("validUntilUtc"))
        if (exp and now >= exp) or (valid and now >= valid):
            it["status"] = "EXPIRED"
            it["decision"] = "expired"
            it["decidedUtc"] = ps.iso(now)
            out.append(it)
    return out


def reminders_due(items, now, days=(1, 3)):
    """Articles PENDING dont l'âge a franchi un seuil de rappel (J+1, J+3) pas encore envoyé. Marque `remindersSent` et renvoie la liste."""
    out = []
    for it in items:
        if it.get("status") != "PENDING":
            continue
        created = ps.parse_iso(it.get("createdUtc"))
        if not created:
            continue
        age_days = (now - created) / 86400.0
        sent = it.setdefault("remindersSent", [])
        for d in days:
            if age_days >= d and d not in sent:
                sent.append(d)
                out.append(it)
                break
    return out


def mark_boot_recovery(items, now):
    """Au démarrage : EXECUTING dont l'appel a été lancé -> UNKNOWN_CHECK_MANUALLY (jamais rejoué) ; EXECUTING jamais lancé -> à remettre en file.
    Renvoie (inconnus, à_relancer)."""
    unknown, requeue = [], []
    for it in items:
        if it.get("status") != "EXECUTING":
            continue
        ex = it.get("execution") or {}
        if ex.get("dispatchedUtc") or ex.get("startedUtc"):
            it["status"] = "UNKNOWN_CHECK_MANUALLY"
            ex["finishedUtc"] = ps.iso(now)
            ex["connectorStatus"] = "UNKNOWN"
            ex["detail"] = "Le service a redémarré pendant l'exécution : vérifiez dans votre outil si l'action est partie. Elle ne sera pas rejouée."
            it["execution"] = ex
            unknown.append(it)
        else:
            requeue.append(it)
    return unknown, requeue


# ------------------------------------------------------------------ exécution (un thread, jamais le thread HTTP)
class RateWindow:
    """Au plus N exécutions par minute et par client."""

    def __init__(self, per_minute, now=time.time):
        self.n = per_minute
        self.now = now
        self.rows = collections.defaultdict(collections.deque)

    def wait_needed(self, client_id):
        q = self.rows[client_id]
        t = self.now()
        while q and t - q[0] >= 60:
            q.popleft()
        if len(q) < self.n:
            return 0.0
        return max(0.0, 60 - (t - q[0]))

    def note(self, client_id):
        self.rows[client_id].append(self.now())


class ApprovalExecutor:
    """File d'exécution des articles approuvés. `finish(pid, aid, result)` est appelé après chaque appel (le service met l'article à jour sous
    verrou) ; `begin(pid, aid)` met l'article en EXECUTING avec dispatchedUtc AVANT l'appel et renvoie (client_id, connectorId, operation,
    params) ou None si l'article n'est plus à exécuter."""

    def __init__(self, begin, run_connector, finish, limits, now=time.time, sleep=time.sleep):
        self.begin = begin
        self.run_connector = run_connector
        self.finish = finish
        self.q = queue.Queue()
        self.now = now
        self.sleep = sleep
        a = limits["approvals"]
        self.spacing = float(a["executeSpacingSec"])
        self.rate = RateWindow(int(a["executePerMinutePerClient"]), now)
        self.thread = None
        self.guard = threading.Lock()
        self.stopped = False
        self.idle = threading.Event()
        self.idle.set()
        self._pending = 0

    def submit(self, pid, aid):
        with self.guard:
            self._pending += 1
            self.idle.clear()
            if self.thread is None or not self.thread.is_alive():
                self.thread = threading.Thread(target=self._loop, name="projects-approvals", daemon=True)
                self.thread.start()
        self.q.put((pid, aid))

    def wait_idle(self, timeout=30):
        return self.idle.wait(timeout)

    def stop(self):
        self.stopped = True
        self.q.put(None)

    def _loop(self):
        while not self.stopped:
            try:
                job = self.q.get(timeout=2)
            except queue.Empty:
                continue
            if job is None:
                break
            pid, aid = job
            try:
                self._run_one(pid, aid)
            except Exception as e:  # noqa: BLE001 - un échec ne doit jamais tuer le thread
                sys.stderr.write(f"projects approvals executor: {type(e).__name__}: {e}\n")
            finally:
                with self.guard:
                    self._pending -= 1
                    if self._pending <= 0:
                        self._pending = 0
                        self.idle.set()

    def _run_one(self, pid, aid):
        ctx = self.begin(pid, aid)
        if not ctx:
            return
        client_id, conn, op, params = ctx
        w = self.rate.wait_needed(client_id)
        if w > 0:
            self.sleep(w)
        self.rate.note(client_id)
        try:
            res = self.run_connector(conn, op, params, client_id)
        except Exception as e:  # noqa: BLE001
            res = {"Status": "ERROR", "Detail": f"{type(e).__name__}"}
        self.finish(pid, aid, res if isinstance(res, dict) else {"Status": "ERROR", "Detail": "réponse illisible"})
        if self.spacing > 0:
            self.sleep(self.spacing)


def result_to_status(res):
    """(statut de l'article, statut connecteur, détail sans secret) d'après la réponse de Confirm-Connector-Action.ps1."""
    st = str((res or {}).get("Status") or "ERROR").upper()
    detail = str((res or {}).get("Detail") or "")[:300]
    if secret_like(detail):
        detail = "(détail masqué)"
    return ("EXECUTED" if st in ("SUCCESS", "PREPARED_ONLY") else "FAILED"), st, detail


def dedup_key(step_id, conn, op, params):
    raw = json.dumps(params or {}, ensure_ascii=False, sort_keys=True)
    return f"{step_id}|{conn}|{op}|{hashlib.sha256(raw.encode('utf-8')).hexdigest()[:16]}"
