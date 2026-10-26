# -*- coding: utf-8 -*-
"""Routeur de moteurs IA (2026-10-25) : UN seul endroit decide quel moteur repond a une mission.

Decision du proprietaire (2026-10-25) : le moteur d'IA devient un CHOIX, jamais un remplacement global.
  1. essai gratuit et demonstrations : modele LOCAL (Ollama sur sa machine), cout nul, aucune donnee client reelle ;
  2. clients payants : Claude (ou un hote suisse), dont le cout est deja dans le prix du forfait (docs/PRICING.md, IA <= 35 %) ;
  3. cle personnelle (BYOK) pour une entreprise : son propre compte Anthropic / compatible OpenAI, elle paie le fournisseur, jamais nous ;
  4. plafond de depense Claude (jour / mois) : le credit ne peut plus s'epuiser en silence.

Rien ne change tant que le proprietaire n'a pas choisi : sans BK_AI_PROVIDER, sans reglage enregistre, sans plafond ni cle client, resolve_plan()
renvoie un plan « implicite » (explicit = False) et le serveur ne pose AUCUNE variable : le chemin Claude tourne exactement comme avant.

Ce module ne fait aucun appel reseau. Il lit :
  core/ai/data/engine-settings.json   reglages du proprietaire (route POST /api/admin/engine) ; aucun secret
  core/ai/LEVELS.json                 chaine facultative `providers` par niveau
  runtime/engine/health.json          disjoncteur : un moteur qui repond « credit / authentification / connexion » est mis de cote quelques minutes
  runtime/engine/spend.json           depense Claude du jour et du mois (ecrite par l'executeur PowerShell, Invoke-EngineChain.ps1)
  core/ai/data/byok/<ClientId>.json   description NON secrete de la cle personnelle d'un client (la cle elle-meme est dans le coffre chiffre)
et l'executeur PowerShell (core/ai/Invoke-EngineChain.ps1) suit le plan : variables BK_ENGINE_PLAN (JSON) et BK_ENGINE_BUDGET_CHF.
Variables d'environnement du serveur (noms seulement, aucun secret ici) : BK_AI_PROVIDER, BK_OLLAMA_URL, BK_OLLAMA_MODEL, BK_OLLAMA_TIMEOUT_SEC,
BK_SWISS_URL, BK_SWISS_MODEL, BK_CLAUDE_DAILY_CHF, BK_CLAUDE_MONTHLY_CHF ; jetons : BK_SECRET_SWISS, BK_SECRET_OLLAMA (voir BK-Secret.ps1).
"""
import datetime
import json
import os
import re
import secrets
import threading
import time

import net_policy

SCHEMA_VERSION = 1
BREAKER_SECONDS = 300                       # un moteur « credit / authentification / connexion » est mis de cote 5 minutes
ALERT_RATIO = 0.8                           # e-mail au proprietaire a 80 % du plafond
PROVIDER_IDS = ("anthropic", "ollama", "swiss")
FREE_PROVIDER_IDS = ("ollama",)
DEFAULT_CHAIN = ["anthropic"]
DEFAULT_OLLAMA_MODEL = "llama3:latest"
BYOK_KINDS = ("anthropic", "openai_compat")
BYOK_DEFAULT_HOSTS = ("api.openai.com", "api.mistral.ai", "api.groq.com", "api.together.xyz", "openrouter.ai", "api.infomaniak.com", "api.anthropic.com")
_LOCK = threading.RLock()


# ---------------------------------------------------------------------------------------------------------------------------------
# Capacites : ce que chaque moteur sait faire, SANS promesse
# ---------------------------------------------------------------------------------------------------------------------------------
CAPABILITY_KEYS = ("webSearch", "webFetch", "codeExecution", "officeFiles", "textFiles", "toolUse", "longProjects")

_CAPS = {
    "anthropic": {
        "webSearch": True, "webFetch": True, "codeExecution": True, "officeFiles": True, "textFiles": True,
        "toolUse": "reliable", "longProjects": True,
        "languageNote": "Très bon en français, anglais, espagnol, allemand, italien, portugais et arabe.",
    },
    "ollama": {
        "webSearch": False, "webFetch": True, "codeExecution": False, "officeFiles": False, "textFiles": True,
        "toolUse": "weak", "longProjects": False,
        "languageNote": "Correct en anglais ; en français les réponses sont plus simples et se trompent plus souvent (faits, chiffres). Un petit modèle local peut inventer : relisez.",
    },
    "swiss": {
        "webSearch": False, "webFetch": True, "codeExecution": False, "officeFiles": False, "textFiles": True,
        "toolUse": "fair", "longProjects": False,
        "languageNote": "Modèle ouvert hébergé en Suisse : bon en français et en anglais, moins fin que Claude sur les demandes longues ou techniques.",
    },
    "byok-anthropic": {
        "webSearch": True, "webFetch": True, "codeExecution": True, "officeFiles": True, "textFiles": True,
        "toolUse": "reliable", "longProjects": True,
        "languageNote": "Claude avec votre propre clé : mêmes capacités que le moteur Claude de la plateforme.",
    },
    "byok-openai_compat": {
        "webSearch": False, "webFetch": True, "codeExecution": False, "officeFiles": False, "textFiles": True,
        "toolUse": "fair", "longProjects": False,
        "languageNote": "Modèle de votre fournisseur : la qualité dépend du modèle choisi.",
    },
}
_WEBFETCH_NOTE = "Lecture de pages web publiques en https seulement, texte uniquement (pas de PDF, pas de pages qui exigent JavaScript)."
_SEARCH_NOTE = "Recherche web par le point de recherche que le propriétaire a configuré : extraits de résultats seulement, plus limitée que celle de Claude."
_LIMIT_NAMES = {
    "webSearch": "recherche web", "codeExecution": "exécution de code", "officeFiles": "fichiers Office (Excel, Word, PowerPoint, PDF)",
    "longProjects": "projets de plusieurs heures",
}
_NEED_TEXT = {
    "webSearch": "la recherche sur le web", "officeFiles": "des fichiers Office (Excel, Word, PowerPoint, PDF)", "codeExecution": "l'exécution de code",
}


def _caps_key(engine_id, byok_kind=None):
    if engine_id == "byok":
        return "byok-" + (byok_kind if byok_kind in BYOK_KINDS else "openai_compat")
    return engine_id if engine_id in _CAPS else "swiss"


def capabilities_for(engine_id, byok_kind=None, search_endpoint=False):
    """Matrice de capacites d'UN moteur (dictionnaire pret a servir en JSON).

    API stable pour le mode projet (docs/AUTONOMY-ENGINE.md, branche ws/chantier-design) : appeler capabilities_for(<moteur>) ou
    engine_supports(<moteur>, "officeFiles") AVANT de promettre une tache longue ou un livrable. Un mode projet ne doit jamais lancer
    sur un moteur local un chantier qui demande des fichiers Office, du code ou plusieurs heures de travail.
    toolUse : 'reliable' (outils fiables) | 'fair' (correct) | 'weak' (le modele ignore ou invente ses appels d'outils : verifie en reel le 2026-10-25)."""
    key = _caps_key(engine_id, byok_kind)
    caps = dict(_CAPS[key])
    if search_endpoint and not caps["webSearch"]:
        caps["webSearch"] = True
    caps["engine"] = engine_id
    caps["webFetchNote"] = None if key.endswith("anthropic") or key == "anthropic" else _WEBFETCH_NOTE
    caps["webSearchNote"] = (_SEARCH_NOTE if search_endpoint and not key.endswith("anthropic") and key != "anthropic" else None)
    limits = [_LIMIT_NAMES[k] for k in ("webSearch", "codeExecution", "officeFiles", "longProjects") if not caps[k]]
    if caps["toolUse"] == "weak":
        limits.append("branchement d'outils peu fiable")
    caps["limitsFr"] = limits
    return caps


def capability_matrix(search_endpoint=False):
    """Toutes les matrices, par moteur : {anthropic, ollama, swiss, byok-anthropic, byok-openai_compat}."""
    out = {}
    for key in _CAPS:
        eng, _, kind = key.partition("-")
        out[key] = capabilities_for(eng if eng != "byok" else "byok", kind or None, search_endpoint)
    return out


def engine_supports(engine_id, capability, byok_kind=None):
    """True si le moteur sait faire `capability` (webSearch, webFetch, codeExecution, officeFiles, textFiles, longProjects) ; toolUse : True si 'reliable'."""
    caps = capabilities_for(engine_id, byok_kind)
    if capability not in CAPABILITY_KEYS:
        return False
    value = caps[capability]
    return value == "reliable" if capability == "toolUse" else bool(value)


_NEEDS_PATTERNS = (
    ("officeFiles", re.compile(r"\b(excel|xlsx|tableur|spreadsheet|powerpoint|pptx|docx|word\b|\.pdf|en pdf|fichier pdf|pdf\b)", re.I)),
    ("webSearch", re.compile(r"(cherche\w*\s+(sur\s+)?(le\s+)?(web|internet|google)|recherche\w*\s+(web|en ligne|sur internet|google)|search (the )?(web|online|google)|google\b|derni[eè]res? (nouvelles|actualit)|latest news|actualit[ée]s? (du jour|r[ée]centes?)|veille concurrentielle)", re.I)),
    ("codeExecution", re.compile(r"(ex[ée]cute\w*\s+(du\s+|le\s+|un\s+)?(code|script)|run (the |some )?(code|script)|script python|python script)", re.I)),
)


def needs_from_objective(text):
    """Capacites que la DEMANDE du client semble exiger (heuristique prudente) : sert a dire honnetement qu'un moteur ne peut pas les fournir."""
    t = str(text or "")[:4000]
    return [name for name, rx in _NEEDS_PATTERNS if rx.search(t)]


# ---------------------------------------------------------------------------------------------------------------------------------
# Libelles lisibles
# ---------------------------------------------------------------------------------------------------------------------------------
def friendly_model(model):
    m = str(model or "").strip()
    if not m:
        return "modèle local"
    base = m.split(":")[0].split("/")[-1]
    low = base.lower()
    for key, name in (("llama3.1", "Llama 3.1"), ("llama3.2", "Llama 3.2"), ("llama3.3", "Llama 3.3"), ("llama3", "Llama 3"), ("llama-3", "Llama 3"),
                      ("qwen2.5", "Qwen 2.5"), ("qwen3", "Qwen 3"), ("mistral", "Mistral"), ("mixtral", "Mixtral"), ("gemma", "Gemma"), ("phi", "Phi"),
                      ("apertus", "Apertus"), ("gpt-4o-mini", "GPT-4o mini"), ("gpt-4o", "GPT-4o"), ("claude", "Claude")):
        if low.startswith(key):
            return name
    return base[:40]


def engine_label(engine_id, model="", byok_kind=None):
    if engine_id == "anthropic":
        return "Claude"
    if engine_id == "ollama":
        return "Moteur local (" + friendly_model(model) + ")"
    if engine_id == "swiss":
        return "Moteur hébergé en Suisse (" + friendly_model(model) + ")"
    if engine_id == "byok":
        return "Votre clé (" + ("Claude" if byok_kind == "anthropic" else friendly_model(model)) + ")"
    return "Réponse de secours"


def engine_summary(engine_id, model="", byok_kind=None):
    """Phrase en francais simple, affichee pres de la zone de mission et sur la page du Worker."""
    if engine_id == "anthropic":
        return "Moteur : Claude"
    if engine_id == "ollama":
        return "Moteur local (" + friendly_model(model) + ") : réponses plus simples, pas de recherche web ni de fichiers Office"
    if engine_id == "swiss":
        return "Moteur hébergé en Suisse (" + friendly_model(model) + ") : réponses plus simples que Claude, pas de recherche web ni de fichiers Office"
    if engine_id == "byok":
        if byok_kind == "anthropic":
            return "Moteur : Claude (votre propre clé)"
        return "Moteur : " + friendly_model(model) + " (votre propre clé) : pas de recherche web ni de fichiers Office"
    return "Aucun moteur disponible : réponse de secours"


def gap_note(engine_label_text, needs, caps):
    """Remarque francaise quand la demande exige une capacite que le moteur n'a pas ('' si rien ne manque)."""
    missing = [n for n in needs if not caps.get(n)]
    if not missing:
        return ""
    items = " et ".join(_NEED_TEXT[n] for n in missing if n in _NEED_TEXT)
    return ("Remarque sur le moteur utilisé (" + engine_label_text + ") : votre demande semble avoir besoin de " + items +
            ", que ce moteur ne sait pas faire. Cette partie n'a PAS été réalisée ; ce qui précède vient uniquement de ce que le modèle sait déjà.")


# ---------------------------------------------------------------------------------------------------------------------------------
# Fichiers de reglages, de sante et de depense
# ---------------------------------------------------------------------------------------------------------------------------------
def settings_path(root):
    return os.path.join(root, "core", "ai", "data", "engine-settings.json")


def health_path(root):
    return os.path.join(root, "runtime", "engine", "health.json")


def spend_path(root):
    return os.path.join(root, "runtime", "engine", "spend.json")


def alerts_path(root):
    return os.path.join(root, "runtime", "engine", "alerts.json")


def byok_meta_path(root, client_id):
    safe = re.sub(r"[^A-Za-z0-9_-]", "", str(client_id or ""))
    return os.path.join(root, "core", "ai", "data", "byok", safe + ".json")


def _load(path, default):
    try:
        with open(path, encoding="utf-8-sig") as f:
            data = json.load(f)
        return data if isinstance(data, type(default)) else default
    except (OSError, ValueError):
        return default


def _write_atomic(path, data):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".tmp-" + os.path.basename(path) + "-" + secrets.token_hex(6))
    try:
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def load_settings(root):
    s = _load(settings_path(root), {})
    return s if isinstance(s, dict) else {}


def _env(env, name, default=""):
    src = env if env is not None else os.environ
    return str(src.get(name, default) or "").strip()


PROVIDER_ALIASES = {"claude": "anthropic", "local": "ollama", "suisse": "swiss"}      # BK_AI_PROVIDER=local, claude,local...


def parse_chain(text):
    """'ollama,anthropic' -> ['ollama', 'anthropic'] (identifiants inconnus ou en double ignores ; alias : local, claude, suisse)."""
    out = []
    for part in re.split(r"[,\s;>]+", str(text or "").lower()):
        part = PROVIDER_ALIASES.get(part, part)
        if part in PROVIDER_IDS and part not in out:
            out.append(part)
    return out


def token_present(name, env=None):
    """Un jeton existe-t-il pour ce moteur (variable BK_SECRET_<NOM> ou fichier du dossier BK_SECRETS_DIR) ? Ne lit JAMAIS la valeur."""
    key = re.sub(r"[^a-z0-9_]", "", str(name or "").lower())
    if not key:
        return False
    if _env(env, "BK_SECRET_" + key.upper()):
        return True
    d = _env(env, "BK_SECRETS_DIR")
    return bool(d) and os.path.isfile(os.path.join(d, key + ".secret"))


def default_chain(settings, env=None):
    chain = settings.get("defaultChain") if isinstance(settings.get("defaultChain"), list) else None
    if chain:
        chain = [c for c in chain if c in PROVIDER_IDS]
    if not chain:
        chain = parse_chain(_env(env, "BK_AI_PROVIDER"))
    return chain or list(DEFAULT_CHAIN)


def free_chain(settings):
    chain = settings.get("freeChain") if isinstance(settings.get("freeChain"), list) else None
    if chain is None:
        return list(FREE_PROVIDER_IDS)
    return [c for c in chain if c in FREE_PROVIDER_IDS]


def endpoint_config(engine_id, settings, env=None):
    """{url, model, timeoutSec, toolMode, secret} d'un moteur a adresse (ollama, swiss), ou None s'il n'est pas configure."""
    if engine_id not in ("ollama", "swiss"):
        return None
    cfg = (settings.get("endpoints") or {}).get(engine_id) or {}
    prefix = "BK_OLLAMA" if engine_id == "ollama" else "BK_SWISS"
    url = str(cfg.get("url") or _env(env, prefix + "_URL")).strip()
    model = str(cfg.get("model") or _env(env, prefix + "_MODEL") or (DEFAULT_OLLAMA_MODEL if engine_id == "ollama" else "")).strip()
    if not url or not model:
        return None
    try:
        timeout = int(cfg.get("timeoutSec") or _env(env, prefix + "_TIMEOUT_SEC") or (300 if engine_id == "ollama" else 120))
    except (TypeError, ValueError):
        timeout = 300
    mode = str(cfg.get("toolMode") or "auto")
    return {"url": url, "model": model, "timeoutSec": max(20, min(timeout, 900)), "toolMode": mode if mode in ("auto", "native", "json") else "auto",
            "secret": engine_id}


def search_url(settings, env=None):
    """Adresse du point de recherche web COMPATIBLE SearXNG (GET <adresse>/search?q=...&format=json) que le proprietaire a configure (reglage `search.url`, sinon
    BK_SEARCH_URL), ou '' si aucune / adresse non permise. Sans cela, un moteur local n'a AUCUNE recherche web (il ne la simule pas)."""
    cfg = settings.get("search") if isinstance(settings.get("search"), dict) else {}
    url = str(cfg.get("url") or _env(env, "BK_SEARCH_URL")).strip()
    return url if url and endpoint_structurally_ok(url, "search", env) else ""


def endpoint_structurally_ok(url, secret_name, env=None):
    """Controle SANS reseau (sert a decider si un moteur est « configure ») : schema, identifiants, adresse IP litterale, jeton pour https.
    Les noms d'hote sont verifies a l'appel par l'adaptateur (resolution reelle), jamais ici."""
    parts = net_policy.split_url(url)
    if not parts or parts["scheme"] not in ("http", "https") or parts["userinfo"]:
        return False
    host = parts["host"]
    try:
        import ipaddress
        ipaddress.ip_address(host)
        literal = True
    except ValueError:
        literal = False
    if literal:
        cls = net_policy.ip_class(host)
        if cls == "blocked":
            return False
        if (parts["scheme"] == "http" or secret_name == "ollama") and cls not in net_policy.PRIVATE_OK:
            return False                                         # le moteur local n'est jamais sur une adresse publique (kind « local »)
    if parts["scheme"] == "https" and not token_present(secret_name, env):
        return False
    return True


# -- disjoncteur --------------------------------------------------------------------------------------------------------------------
def health_snapshot(root, now=None):
    now = time.time() if now is None else now
    data = _load(health_path(root), {})
    out = {}
    for pid, rec in data.items():
        if isinstance(rec, dict) and isinstance(rec.get("until"), (int, float)) and rec["until"] > now:
            out[pid] = {"reason": str(rec.get("reason") or ""), "until": rec["until"], "retryInSec": int(rec["until"] - now)}
    return out


def mark_unhealthy(root, provider, reason, now=None, seconds=BREAKER_SECONDS):
    """Ecriture cote Python (tests, outil du proprietaire) ; l'executeur PowerShell ecrit le meme fichier avec le meme schema."""
    now = time.time() if now is None else now
    with _LOCK:
        data = _load(health_path(root), {})
        data[provider] = {"until": now + seconds, "reason": str(reason)[:40], "at": now}
        _write_atomic(health_path(root), data)


def clear_health(root, provider=None):
    with _LOCK:
        data = _load(health_path(root), {})
        if provider is None:
            data = {}
        else:
            data.pop(provider, None)
        _write_atomic(health_path(root), data)


# -- depense Claude -----------------------------------------------------------------------------------------------------------------
def _day_key(now):
    return datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime("%Y-%m-%d")


def read_spend(root, now=None):
    now = time.time() if now is None else now
    data = _load(spend_path(root), {})
    days, months = data.get("days") or {}, data.get("months") or {}
    dk = _day_key(now)
    day_chf = float((days.get(dk) or {}).get("chf") or 0)
    month_chf = float((months.get(dk[:7]) or {}).get("chf") or 0)
    return {"dayKey": dk, "monthKey": dk[:7], "dayChf": round(day_chf, 4), "monthChf": round(month_chf, 4)}


def ceiling_config(settings, env=None):
    c = settings.get("ceiling") if isinstance(settings.get("ceiling"), dict) else {}

    def num(v, env_name):
        raw = v if v not in (None, "") else _env(env, env_name)
        try:
            f = float(raw)
            return f if f > 0 else None
        except (TypeError, ValueError):
            return None
    return {"dailyChf": num(c.get("dailyChf"), "BK_CLAUDE_DAILY_CHF"), "monthlyChf": num(c.get("monthlyChf"), "BK_CLAUDE_MONTHLY_CHF"),
            "alert": bool(c.get("alert", True))}


def ceiling_status(root, settings, now=None, env=None):
    """{configured, reached, remainingChf, dayChf, monthChf, dailyChf, monthlyChf, ratio, which} (remainingChf = le plus petit reste des plafonds)."""
    cfg = ceiling_config(settings, env)
    spend = read_spend(root, now)
    out = {"configured": bool(cfg["dailyChf"] or cfg["monthlyChf"]), "reached": False, "remainingChf": None, "ratio": 0.0, "which": None,
           "dayChf": spend["dayChf"], "monthChf": spend["monthChf"], "dailyChf": cfg["dailyChf"], "monthlyChf": cfg["monthlyChf"], "alert": cfg["alert"]}
    if not out["configured"]:
        return out
    parts = []
    if cfg["dailyChf"]:
        parts.append(("day", cfg["dailyChf"] - spend["dayChf"], spend["dayChf"] / cfg["dailyChf"]))
    if cfg["monthlyChf"]:
        parts.append(("month", cfg["monthlyChf"] - spend["monthChf"], spend["monthChf"] / cfg["monthlyChf"]))
    which, remaining, _ = min(parts, key=lambda p: p[1])
    out["remainingChf"] = round(max(0.0, remaining), 4)
    out["ratio"] = round(max(p[2] for p in parts), 4)
    out["reached"] = remaining <= 0
    out["which"] = which
    return out


def maybe_alert(root, settings, now=None, notify=None, env=None):
    """E-mail au proprietaire quand la depense Claude atteint 80 % d'un plafond (jour ou mois), puis une seconde fois quand il est ATTEINT : au plus deux
    e-mails par plafond et par periode. `notify(subject, text)` est fourni par le serveur (courrier existant). Renvoie la liste des alertes envoyees
    (pour les tests et le journal)."""
    now = time.time() if now is None else now
    cfg = ceiling_config(settings, env)
    if not cfg["alert"] or not (cfg["dailyChf"] or cfg["monthlyChf"]):
        return []
    spend = read_spend(root, now)
    sent = []
    with _LOCK:
        marks = _load(alerts_path(root), {})
        for scope, key, spent, cap in (("day", spend["dayKey"], spend["dayChf"], cfg["dailyChf"]), ("month", spend["monthKey"], spend["monthChf"], cfg["monthlyChf"])):
            if not cap or spent < ALERT_RATIO * cap:
                continue
            reached = spent >= cap
            mark = scope + ":" + key + (":100" if reached else ":80")
            if marks.get(mark):
                continue
            subject = ("Plafond de dépense Claude ATTEINT (" if reached else "Plafond de dépense Claude à 80 % (") + ("jour " if scope == "day" else "mois ") + key + ")"
            text = (f"Dépense Claude {'du jour' if scope == 'day' else 'du mois'} : {spent:.2f} CHF sur un plafond de {cap:.2f} CHF.\n"
                    + ("Le plafond est atteint : les missions passent maintenant sur la chaîne gratuite (moteur local), avec une mention honnête dans la réponse.\n"
                       if reached else "À 100 %, les missions passent automatiquement sur la chaîne gratuite (moteur local).\n")
                    + "Réglage : POST /api/admin/engine (ceiling), ou la carte « Moteur d'IA » de la vue Admin.")
            marks[mark] = {"at": now, "spentChf": spent, "capChf": cap}
            sent.append({"scope": scope, "key": key, "subject": subject, "text": text, "reached": reached})
        if sent:
            while len(marks) > 60:                     # on ne garde que les 60 dernieres marques
                marks.pop(sorted(marks, key=lambda x: marks[x].get("at", 0))[0], None)
            _write_atomic(alerts_path(root), marks)
    if notify:
        for a in sent:
            try:
                notify(a["subject"], a["text"])
            except Exception:  # noqa: BLE001 - une alerte perdue ne doit jamais bloquer une mission
                pass
    return sent


# -- cle personnelle (BYOK) : description non secrete -------------------------------------------------------------------------------
def load_byok_meta(root, client_id):
    m = _load(byok_meta_path(root, client_id), {})
    return m if m.get("kind") in BYOK_KINDS else None


def save_byok_meta(root, client_id, kind, host, endpoint, model, enabled=True):
    meta = {"kind": kind, "host": host, "endpoint": endpoint, "model": model, "enabled": bool(enabled),
            "savedAtUtc": datetime.datetime.utcnow().isoformat() + "Z"}
    _write_atomic(byok_meta_path(root, client_id), meta)
    return meta


def delete_byok_meta(root, client_id):
    try:
        os.remove(byok_meta_path(root, client_id))
        return True
    except OSError:
        return False


def byok_public_view(meta):
    """Ce que le client peut revoir : jamais la cle, pas meme un fragment."""
    if not meta:
        return {"configured": False}
    return {"configured": True, "kind": meta["kind"], "host": meta.get("host"), "model": meta.get("model") or None,
            "enabled": bool(meta.get("enabled", True)), "savedAtUtc": meta.get("savedAtUtc")}


_KEY_ANTHROPIC = re.compile(r"^sk-ant-[A-Za-z0-9_\-]{20,300}$")
_KEY_GENERIC = re.compile(r"^[A-Za-z0-9_\-\.=+/]{16,400}$")
_MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_\-\.:/]{0,99}$")


def byok_allowed_hosts(settings):
    extra = settings.get("byokAllowedHosts") if isinstance(settings.get("byokAllowedHosts"), list) else []
    hosts = list(BYOK_DEFAULT_HOSTS)
    for h in extra:
        h = str(h).strip().lower()
        if re.fullmatch(r"[a-z0-9][a-z0-9.\-]{1,200}", h) and h not in hosts:
            hosts.append(h)
    return hosts


def validate_byok(settings, kind, key, endpoint="", model="", resolver=None):
    """Validation par la FORME seulement (aucun appel reel, aucun cout). Renvoie (ok, erreur, meta_publique) ; ne garde et ne renvoie jamais la cle.

    anthropic : cle sk-ant-..., adresse fixe api.anthropic.com. openai_compat : adresse https d'un hote de la liste blanche
    (BYOK_DEFAULT_HOSTS + byokAllowedHosts du proprietaire), publique, modele obligatoire, cle de 16 a 400 caracteres sans espace."""
    key = str(key or "").strip()
    model = str(model or "").strip()
    if kind not in BYOK_KINDS:
        return False, {"field": "kind", "message": "Type de fournisseur inconnu (anthropic ou openai_compat)."}, None
    if model and not _MODEL_RE.match(model):
        return False, {"field": "model", "message": "Nom de modèle invalide."}, None
    if kind == "anthropic":
        if not _KEY_ANTHROPIC.match(key):
            return False, {"field": "key", "message": "Une clé Anthropic commence par « sk-ant- » (copiez-la depuis console.anthropic.com)."}, None
        return True, None, {"kind": kind, "host": "api.anthropic.com", "endpoint": "https://api.anthropic.com", "model": model}
    if not _KEY_GENERIC.match(key):
        return False, {"field": "key", "message": "Clé invalide : 16 à 400 caractères, sans espace."}, None
    if not model:
        return False, {"field": "model", "message": "Indiquez le nom du modèle (par exemple gpt-4o-mini)."}, None
    ok, code, message, info = net_policy.check_endpoint(endpoint, kind="byok", has_token=True, resolver=resolver or (lambda h, p: ["93.184.216.34"]),
                                                       allowed_hosts=byok_allowed_hosts(settings))
    if not ok:
        return False, {"field": "endpoint", "message": message, "code": code}, None
    parsed = net_policy.split_url(endpoint)
    return True, None, {"kind": kind, "host": parsed["host"], "endpoint": str(endpoint).strip().rstrip("/"), "model": model}


# ---------------------------------------------------------------------------------------------------------------------------------
# Reglages du proprietaire (POST /api/admin/engine)
# ---------------------------------------------------------------------------------------------------------------------------------
def _num(v, lo, hi):
    if v is None or v == "":
        return None
    f = float(v)
    if not (lo < f <= hi):
        raise ValueError
    return round(f, 2)


def apply_settings(root, patch, levels=None, env=None, resolver=None):
    """Valide et enregistre un changement de reglages (champs facultatifs, fusion). Renvoie (reglages, erreurs). Rien n'est ecrit s'il y a une erreur."""
    errors = []
    cur = load_settings(root)
    new = json.loads(json.dumps(cur))
    if not isinstance(patch, dict):
        return cur, [{"field": "body", "message": "Un objet JSON est attendu."}]

    def chain_of(name, value, allowed, min_len=1):
        if not isinstance(value, list) or len(value) > 3 or len(value) < min_len or any(c not in allowed for c in value) or len(set(value)) != len(value):
            errors.append({"field": name, "message": "Liste de moteurs invalide (" + ", ".join(allowed) + ", sans doublon, 3 au plus)."})
            return None
        return list(value)

    if "defaultChain" in patch:
        if patch["defaultChain"] is None:
            new.pop("defaultChain", None)
        else:
            v = chain_of("defaultChain", patch["defaultChain"], PROVIDER_IDS)
            if v is not None:
                new["defaultChain"] = v
    if "freeChain" in patch:
        if patch["freeChain"] is None:
            new.pop("freeChain", None)
        else:
            v = chain_of("freeChain", patch["freeChain"], FREE_PROVIDER_IDS, min_len=0)
            if v is not None:
                new["freeChain"] = v
    if "levelChains" in patch:
        lc = patch["levelChains"]
        if not isinstance(lc, dict):
            errors.append({"field": "levelChains", "message": "Un objet {niveau: [moteurs]} est attendu."})
        else:
            target = dict(new.get("levelChains") or {})
            for lvl, chain in lc.items():
                if levels is not None and lvl not in levels:
                    errors.append({"field": "levelChains." + str(lvl), "message": "Niveau inconnu."})
                    continue
                if chain is None:
                    target.pop(lvl, None)
                    continue
                v = chain_of("levelChains." + str(lvl), chain, PROVIDER_IDS)
                if v is not None:
                    target[lvl] = v
            new["levelChains"] = target
    if "endpoints" in patch:
        ep = patch["endpoints"]
        if not isinstance(ep, dict):
            errors.append({"field": "endpoints", "message": "Un objet {moteur: {url, model}} est attendu."})
        else:
            target = dict(new.get("endpoints") or {})
            for eid, cfg in ep.items():
                if eid not in ("ollama", "swiss"):
                    errors.append({"field": "endpoints." + str(eid), "message": "Moteur à adresse inconnu (ollama ou swiss)."})
                    continue
                if cfg is None:
                    target.pop(eid, None)
                    continue
                if not isinstance(cfg, dict):
                    errors.append({"field": "endpoints." + eid, "message": "Un objet {url, model} est attendu."})
                    continue
                merged = dict(target.get(eid) or {})
                merged.update({k: cfg[k] for k in ("url", "model", "timeoutSec", "toolMode") if k in cfg})
                url = str(merged.get("url") or "").strip()
                model = str(merged.get("model") or "").strip()
                if not url:
                    errors.append({"field": "endpoints." + eid + ".url", "message": "Adresse obligatoire."})
                    continue
                # Moteur local : reseau prive seulement (la page Securite le promet) ; hote suisse : https public avec jeton permis.
                ok, code, message, _ = net_policy.check_endpoint(url, kind="local" if eid == "ollama" else "owner", has_token=token_present(eid, env), resolver=resolver)
                if not ok:
                    if code == "TOKEN_REQUIRED":
                        message += " Enregistrez d'abord le jeton sur le serveur (variable BK_SECRET_" + eid.upper() + ")."
                    errors.append({"field": "endpoints." + eid + ".url", "message": message, "code": code})
                    continue
                if model and not _MODEL_RE.match(model):
                    errors.append({"field": "endpoints." + eid + ".model", "message": "Nom de modèle invalide."})
                    continue
                if eid == "swiss" and not model:
                    errors.append({"field": "endpoints.swiss.model", "message": "Modèle obligatoire pour l'hôte suisse."})
                    continue
                entry = {"url": url, "model": model or (DEFAULT_OLLAMA_MODEL if eid == "ollama" else "")}
                if "timeoutSec" in merged:
                    try:
                        entry["timeoutSec"] = max(20, min(int(merged["timeoutSec"]), 900))
                    except (TypeError, ValueError):
                        errors.append({"field": "endpoints." + eid + ".timeoutSec", "message": "Délai invalide (20 à 900 secondes)."})
                        continue
                if merged.get("toolMode") in ("auto", "native", "json"):
                    entry["toolMode"] = merged["toolMode"]
                target[eid] = entry
            new["endpoints"] = target
    if "ceiling" in patch:
        c = patch["ceiling"]
        if c is None:
            new.pop("ceiling", None)
        elif not isinstance(c, dict):
            errors.append({"field": "ceiling", "message": "Un objet {dailyChf, monthlyChf, alert} est attendu."})
        else:
            tgt = dict(new.get("ceiling") or {})
            for fld in ("dailyChf", "monthlyChf"):
                if fld in c:
                    try:
                        val = _num(c[fld], 0, 100000)
                    except (TypeError, ValueError):
                        errors.append({"field": "ceiling." + fld, "message": "Montant invalide (CHF, plus que 0, au plus 100 000)."})
                        continue
                    if val is None:
                        tgt.pop(fld, None)
                    else:
                        tgt[fld] = val
            if "alert" in c:
                tgt["alert"] = bool(c["alert"])
            new["ceiling"] = tgt
    if "search" in patch:
        sv = patch["search"]
        if sv is None:
            new.pop("search", None)
        elif not isinstance(sv, dict) or not isinstance(sv.get("url"), str):
            errors.append({"field": "search", "message": "Un objet {url} est attendu (point de recherche compatible SearXNG)."})
        else:
            ok, code, message, _ = net_policy.check_endpoint(sv["url"].strip(), kind="owner", has_token=token_present("search", env), resolver=resolver)
            if not ok:
                if code == "TOKEN_REQUIRED":
                    message += " Enregistrez d'abord le jeton sur le serveur (variable BK_SECRET_SEARCH)."
                errors.append({"field": "search.url", "message": message, "code": code})
            else:
                new["search"] = {"url": sv["url"].strip()}
    if "byokAllowedHosts" in patch:
        h = patch["byokAllowedHosts"]
        if not isinstance(h, list) or len(h) > 30 or any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.\-]{1,200}", str(x)) for x in h):
            errors.append({"field": "byokAllowedHosts", "message": "Liste de noms d'hôtes (30 au plus)."})
        else:
            new["byokAllowedHosts"] = sorted({str(x).lower() for x in h})
    unknown = [k for k in patch if k not in ("defaultChain", "freeChain", "levelChains", "endpoints", "ceiling", "byokAllowedHosts", "search")]
    for k in unknown:
        errors.append({"field": str(k)[:40], "message": "Réglage inconnu."})
    if errors:
        return cur, errors
    new["version"] = SCHEMA_VERSION
    new["updatedAtUtc"] = datetime.datetime.utcnow().isoformat() + "Z"
    with _LOCK:
        _write_atomic(settings_path(root), new)
    return new, []


def settings_view(root, env=None, now=None):
    """Vue pour le proprietaire : reglages effectifs (jamais de jeton), sante, depense, plafond."""
    s = load_settings(root)
    eps = {}
    for eid in ("ollama", "swiss"):
        cfg = endpoint_config(eid, s, env)
        eps[eid] = ({"url": cfg["url"], "model": cfg["model"], "timeoutSec": cfg["timeoutSec"], "toolMode": cfg["toolMode"],
                     "tokenPresent": token_present(eid, env), "source": "reglage" if (s.get("endpoints") or {}).get(eid) else "environnement"}
                    if cfg else None)
    return {"defaultChain": default_chain(s, env), "defaultChainSource": "reglage" if s.get("defaultChain") else ("environnement" if _env(env, "BK_AI_PROVIDER") else "defaut"),
            "freeChain": free_chain(s), "levelChains": s.get("levelChains") or {}, "endpoints": eps,
            "search": ({"url": search_url(s, env), "tokenPresent": token_present("search", env)} if search_url(s, env) else None),
            "ceiling": ceiling_status(root, s, now, env), "byokAllowedHosts": byok_allowed_hosts(s),
            "health": health_snapshot(root, now), "providers": list(PROVIDER_IDS), "updatedAtUtc": s.get("updatedAtUtc")}


# ---------------------------------------------------------------------------------------------------------------------------------
# Le routeur
# ---------------------------------------------------------------------------------------------------------------------------------
def _entry(engine_id, settings, level_cfg, env, search_endpoint=False):
    """(entree de chaine, motif de rejet). Rejet 'not-configured' si le moteur n'a pas d'adresse / de modele / de jeton."""
    if engine_id == "anthropic":
        model = (level_cfg or {}).get("model") or None
        caps = capabilities_for("anthropic")
        return {"id": "anthropic", "adapter": "anthropic", "model": model, "local": False, "free": False, "label": "Claude", "caps": _caps_for_plan(caps),
                "summary": engine_summary("anthropic")}, None
    cfg = endpoint_config(engine_id, settings, env)
    if not cfg or not endpoint_structurally_ok(cfg["url"], cfg["secret"], env):
        return None, "not-configured"
    search = search_url(settings, env)
    caps = capabilities_for(engine_id, search_endpoint=bool(search) or search_endpoint)
    return {"id": engine_id, "adapter": "openai_compat", "model": cfg["model"], "url": cfg["url"], "secret": cfg["secret"], "timeoutSec": cfg["timeoutSec"],
            "toolMode": cfg["toolMode"], "local": engine_id == "ollama", "free": engine_id in FREE_PROVIDER_IDS, "searchUrl": search or None,
            "label": engine_label(engine_id, cfg["model"]), "caps": _caps_for_plan(caps), "summary": engine_summary(engine_id, cfg["model"])}, None


def _caps_for_plan(caps):
    return {k: caps[k] for k in CAPABILITY_KEYS}


def resolve_plan(root, client_id, level, objective="", *, trial=False, byok=None, now=None, env=None, levels=None, notify=None):
    """Le plan de moteur d'UNE mission.

    trial : le compte est a l'essai (forfait Essai ou essai public) -> chaine GRATUITE seulement, jamais Claude, des qu'une chaine gratuite existe ;
    byok  : description non secrete de la cle personnelle du client (load_byok_meta) ou None ;
    level : identifiant de niveau (rapide...) ou '' ; levels : {id: configuration} de core/ai/LEVELS.json.
    Renvoie un dictionnaire ; plan['explicit'] = False signifie « comportement d'avant » (le serveur ne pose aucune variable)."""
    now = time.time() if now is None else now
    settings = load_settings(root)
    level_cfg = (levels or {}).get(level) if level else None
    needs = needs_from_objective(objective)
    plan = {"v": SCHEMA_VERSION, "explicit": False, "reason": "default", "level": level or "", "preferred": None, "chain": [], "skipped": [], "byok": False,
            "needs": needs, "budgetChf": None, "creditsFreeOnFailover": True, "degradedReason": ""}
    health = health_snapshot(root, now)

    # 1) cle personnelle du client : SA chaine, sans repli vers nos moteurs (son compte, son cout ; un repli sur le notre serait une depense cachee)
    if byok and byok.get("enabled", True) and client_id and client_id != "CLI-TRIAL-PUBLIC":
        kind = byok["kind"]
        label = engine_label("byok", byok.get("model"), kind)
        entry = {"id": "byok", "adapter": kind, "model": byok.get("model") or ((level_cfg or {}).get("model") if kind == "anthropic" else None),
                 "local": False, "free": False, "byok": True, "kind": kind, "label": label,
                 "caps": _caps_for_plan(capabilities_for("byok", kind, search_endpoint=bool(search_url(settings, env)) and kind == "openai_compat")),
                 "summary": engine_summary("byok", byok.get("model"), kind), "timeoutSec": 180,
                 "url": byok.get("endpoint"), "allowedHosts": byok_allowed_hosts(settings),
                 "searchUrl": (search_url(settings, env) or None) if kind == "openai_compat" else None}
        plan.update(explicit=True, reason="byok", preferred="byok", chain=[entry], byok=True, creditsFreeOnFailover=False)
        return plan

    ceiling = ceiling_status(root, settings, now, env)
    if ceiling["configured"]:
        maybe_alert(root, settings, now, notify, env)

    # 2) essai : chaine gratuite seulement
    if trial:
        free_ids = free_chain(settings)
        entries, skipped = [], []
        for pid in free_ids:
            e, why = _entry(pid, settings, level_cfg, env)
            if e is None:
                skipped.append({"id": pid, "why": why})
            else:
                entries.append(e)
        if entries:                                    # le proprietaire a installe un moteur gratuit : l'essai n'utilise JAMAIS Claude
            plan.update(explicit=True, reason="trial", preferred=entries[0]["id"], skipped=skipped)
            for e in entries:
                if e["id"] in health:
                    plan["skipped"].append({"id": e["id"], "why": "circuit-open:" + health[e["id"]]["reason"]})
                else:
                    plan["chain"].append(e)
            if not plan["chain"]:
                plan["degradedReason"] = "free-chain-unavailable"
            return plan
        # pas de moteur gratuit configure : l'essai garde le comportement d'avant (le proprietaire n'a pas encore choisi)

    # 3) chaine du niveau, sinon chaine par defaut
    base = None
    if level and isinstance(settings.get("levelChains"), dict) and settings["levelChains"].get(level):
        base = [c for c in settings["levelChains"][level] if c in PROVIDER_IDS]
        plan["reason"] = "level"
    elif level_cfg and isinstance(level_cfg.get("providers"), list) and level_cfg["providers"]:
        base = [c for c in level_cfg["providers"] if c in PROVIDER_IDS]
        plan["reason"] = "level"
    if not base:
        base = default_chain(settings, env)
        if base != DEFAULT_CHAIN:
            plan["reason"] = "default-chain"
    entries, skipped = [], []
    for pid in base:
        e, why = _entry(pid, settings, level_cfg, env)
        if e is None:
            skipped.append({"id": pid, "why": why})
        else:
            entries.append(e)
    if entries:
        plan["preferred"] = entries[0]["id"]
    chain = []
    for e in entries:
        if e["id"] in health:
            skipped.append({"id": e["id"], "why": "circuit-open:" + health[e["id"]]["reason"]})
            continue
        if e["id"] == "anthropic" and ceiling["configured"] and ceiling["reached"]:
            skipped.append({"id": "anthropic", "why": "spending-ceiling"})
            continue
        chain.append(e)
    # le plafond reduit aussi le budget de l'appel Claude lui-meme (verifie avant CHAQUE appel dans la boucle de l'adaptateur)
    if ceiling["configured"] and any(e["id"] == "anthropic" for e in chain):
        plan["budgetChf"] = ceiling["remainingChf"]
    if ceiling["configured"] and ceiling["reached"] and not any(e["id"] == "anthropic" for e in chain) and not chain:
        # Claude est coupe par le plafond et la chaine du client n'a rien d'autre : on bascule sur la chaine GRATUITE avec un libelle honnete
        for pid in free_chain(settings):
            e, why = _entry(pid, settings, level_cfg, env)
            if e is not None and e["id"] not in health:
                chain.append(e)
        if chain:
            plan["reason"] = "spending-ceiling"
    plan["chain"], plan["skipped"] = chain, skipped
    if not chain:
        plan["degradedReason"] = "no-engine-available"
    # explicite des qu'un choix du proprietaire existe (chaine, plafond, disjoncteur) ; sinon comportement d'avant
    plan["explicit"] = (base != DEFAULT_CHAIN) or ceiling["configured"] or bool(skipped) or plan["reason"] != "default"
    return plan


def plan_env(plan):
    """Variables d'environnement a poser sur le processus PowerShell de la mission ({} = comportement d'avant)."""
    if not plan or not plan.get("explicit"):
        return {}
    out = {"BK_ENGINE_PLAN": json.dumps(plan, ensure_ascii=False, separators=(",", ":"))}
    if plan.get("budgetChf") is not None:
        out["BK_ENGINE_BUDGET_CHF"] = "%.4f" % plan["budgetChf"]
    return out


PLAN_ENV_NAMES = ("BK_ENGINE_PLAN", "BK_ENGINE_BUDGET_CHF", "BK_ENGINE_BYOK")


def engine_view(plan, byok_meta=None):
    """Reponse de GET /api/engine : le moteur que CE compte utilisera pour sa prochaine mission, ses capacites, sa chaine de repli."""
    chain = plan.get("chain") or []
    first = chain[0] if chain else None
    out = {"explicit": bool(plan.get("explicit")), "reason": plan.get("reason"), "byok": byok_public_view(byok_meta),
           "chain": [{"provider": e["id"], "model": e.get("model"), "local": bool(e.get("local")), "label": e["label"]} for e in chain],
           "skipped": plan.get("skipped") or [], "degraded": not chain}
    if first:
        out.update(provider=first["id"], model=first.get("model"), local=bool(first.get("local")), label=first["label"], summary=first["summary"],
                   capabilities=capabilities_for(first["id"], first.get("kind"), search_endpoint=bool(first.get("searchUrl"))))
        # le libelle de capacites des moteurs a adresse : webFetch limite, etc.
    else:
        out.update(provider="none", model=None, local=False, label="Réponse de secours", summary=engine_summary("none"), capabilities=None)
    out["failoverNote"] = ("Si ce moteur est indisponible, la mission passe sur : " + ", ".join(e["label"] for e in chain[1:]) + ". La réponse le dira.") if len(chain) > 1 else ""
    return out
