# -*- coding: utf-8 -*-
"""
BK-AI-WORKERS — Dashboard local.
Sert la page (catalogue + fiche Worker) et une petite API qui lit les
VRAIES donnees du projet (identity.json, SKILLS-REGISTRY.json,
CAPABILITY-MATRIX.json, taches reellement executees dans runtime/tasks/)
et peut soumettre une vraie tache via Submit-Task.ps1.
Aucune dependance externe : http.server de la bibliotheque standard.
"""

import json
import os
import re
import mimetypes
import subprocess
import datetime
import hashlib
import hmac
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, unquote, parse_qs, urlencode
import seo_pages
import pwa_static
import trust_pages

# ---------------------------------------------------------------------
# Ecritures concurrentes (2026-09-28) : le serveur traite les requetes en
# parallele (un thread par requete). Plusieurs fonctions relisent, modifient
# puis reecrivent un fichier JSON commun (comptes, journal, facturation...).
# Sans protection, deux requetes simultanees pouvaient perdre une mise a
# jour, ou pire : lire un fichier a moitie ecrit, le prendre pour vide
# (load_json renvoie la valeur par defaut) et le reecrire -> perte de TOUS
# les comptes. Deux protections :
#  - _STATE_LOCK : verrou unique (reentrant) autour de chaque lecture ->
#    modification -> ecriture ;
#  - _write_json_atomic : ecriture dans un fichier temporaire du meme
#    dossier puis remplacement atomique (os.replace) -> jamais de fichier
#    a moitie ecrit, meme pour un lecteur non verrouille.
# ---------------------------------------------------------------------
_STATE_LOCK = threading.RLock()


def _state_locked(fn):
    import functools

    @functools.wraps(fn)
    def wrapper(*a, **kw):
        with _STATE_LOCK:
            return fn(*a, **kw)
    return wrapper


def _write_json_atomic(path, data, **dump_kwargs):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".tmp-" + os.path.basename(path) + "-" + secrets.token_hex(6))
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, **dump_kwargs)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass

ROOT = os.environ.get("BK_ROOT") or (
    r"C:\Users\FEUCOM\BK-AI-WORKERS" if os.name == "nt"
    else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
# Interpreteur PowerShell : Windows PowerShell en local, PowerShell 7 (pwsh) sous Linux/Docker.
PS_CMD = [os.environ.get("BK_PWSH") or ("powershell" if os.name == "nt" else "pwsh"), "-NoProfile"] + (
    ["-ExecutionPolicy", "Bypass"] if os.name == "nt" else []
)
DASHBOARD_DIR = os.path.join(ROOT, "dashboard")
WORKERS_DIR = os.path.join(ROOT, "workers")
CHLOE_DIR = os.path.join(ROOT, "chloe")
TASKS_DIR = os.path.join(ROOT, "runtime", "tasks")
TASK_FILES_DIR = os.path.join(ROOT, "runtime", "task-files")
ASYNC_JOBS_DIR = os.path.join(ROOT, "runtime", "async-jobs")
CAPABILITY_MATRIX_PATH = os.path.join(ROOT, "core", "permissions", "capability-matrix", "CAPABILITY-MATRIX.json")
SUBMIT_SCRIPT = os.path.join(DASHBOARD_DIR, "Submit-Task.ps1")
AUTOMATION_BRIDGE_SCRIPT = os.path.join(DASHBOARD_DIR, "Automation-Bridge.ps1")
STRIPE_BRIDGE_SCRIPT = os.path.join(DASHBOARD_DIR, "Stripe-Bridge.ps1")
WORKER_RUNTIME_REGISTRY_PATH = os.path.join(ROOT, "core", "runtime", "worker-runtime", "WORKER-REGISTRY.json")
CONNECTOR_CATALOG_PATH = os.path.join(ROOT, "core", "runtime", "controlled-connectors", "CONTROLLED-CONNECTOR-CATALOG.json")
CONNECTOR_DISPATCH_SCRIPT = os.path.join(ROOT, "core", "integrations", "Connector-Dispatch.ps1")
PENDING_ACTIONS_DIR = os.path.join(ROOT, "memory", "runtime")

# Identite du compte "operateur" (Kader lui-meme, via son mot de passe de
# porte historique) — distincte des comptes clients (CLI-CUST-...) crees
# via /api/account/signup. Definie tot : utilisee comme valeur par
# defaut par PROFILE/BILLING/ANALYTICS plus bas dans le fichier.
DASHBOARD_CLIENT_ID = "CLI-DASHBOARD"

# ---------------------------------------------------------------------
# PORTE D'ACCES (gate) — protege les vues/API operationnelles (soumettre
# une mission, facturation, automatisations, analytics) d'un visiteur
# quelconque atteignant ce serveur. La vitrine publique (accueil,
# catalogue en lecture, tarifs, FAQ, legal) reste ouverte sans porte.
# Mot de passe defini par Kader lui-meme via
# .secrets\Set-DashboardGate.ps1 (jamais vu par Claude) — seul un hash
# sale (PBKDF2-SHA256) est stocke sur disque, jamais le mot de passe.
# Si aucun hash n'existe encore, la porte est desactivee (confort dev).
# ---------------------------------------------------------------------

GATE_HASH_PATH = os.path.join(DASHBOARD_DIR, ".gate", "password.hash")
# Hebergement : URL publique (retours Stripe) et port configurables ; en production
# BK_REQUIRE_GATE=1 interdit de demarrer sans mot de passe d'acces.
PUBLIC_BASE_URL = os.environ.get("BK_PUBLIC_URL", "http://127.0.0.1:8787").rstrip("/")
# Cookies de session en Lax (et Secure en https) : Strict empechait le retour
# de Google ("Se connecter avec Google") de reconnaitre la session -> SESSION_MISMATCH.
COOKIE_SECURE = "; Secure" if PUBLIC_BASE_URL.startswith("https") else ""
REQUIRE_GATE = os.environ.get("BK_REQUIRE_GATE") == "1"
GATE_SESSION_TTL_SECONDS = 60 * 60 * 12  # 12h
GATE_SESSIONS = {}  # sha256(token) -> expiry (epoch seconds)

# Corrige le 2026-09-22 : Kader ne veut plus que ses clients aient besoin
# de SON mot de passe pour utiliser le produit — le modele devient "compte
# client + abonnement obligatoire", comme sur un SaaS classique (voir
# ACCOUNT_* plus bas). La porte historique (mot de passe unique) ne
# protege donc plus qu'un apercu sans compte du plan de Chloe. Les
# Automatisations sont desormais en libre-service comme le reste
# (Chloe/mission/profil/facturation/analytics) : protegees par un compte
# client (verifie route par route, pas via ce tuple — chaque client ne
# doit voir/executer que SES propres automatisations, jamais celles d'un
# autre).
GATE_PROTECTED_PREFIXES = ()  # plus rien : /api/chloe/plan est protege par compte client (2026-09-25)


def gate_hash_line():
    """Hash de la porte : variable BK_GATE_HASH (Docker) sinon fichier .gate/password.hash."""
    env_hash = os.environ.get("BK_GATE_HASH", "").strip()
    if env_hash:
        return env_hash
    try:
        with open(GATE_HASH_PATH, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def gate_is_enabled():
    return bool(gate_hash_line())


def verify_gate_password(password):
    try:
        salt_hex, hash_hex, iterations = gate_hash_line().split(":")
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(hash_hex)
        computed = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, int(iterations), dklen=32)
        return hmac.compare_digest(computed, expected)
    except Exception:
        return False


def gate_create_session():
    token = secrets.token_urlsafe(32)
    GATE_SESSIONS[_session_key(token)] = time.time() + GATE_SESSION_TTL_SECONDS
    _persist_sessions()
    return token


def gate_check_session(token):
    if not token:
        return False
    expiry = GATE_SESSIONS.get(_session_key(token))
    if not expiry:
        return False
    if time.time() > expiry:
        GATE_SESSIONS.pop(_session_key(token), None)
        return False
    return True


def gate_clear_session(token):
    GATE_SESSIONS.pop(_session_key(token), None)
    _persist_sessions()


def route_requires_gate(path):
    if not gate_is_enabled():
        return False
    return path.startswith(GATE_PROTECTED_PREFIXES)


# ---------------------------------------------------------------------
# COMPTES CLIENTS (2026-09-22). Un client s'inscrit librement (gratuit,
# aucune carte), obtient son propre espace isole (ClientId dedie : son
# profil, sa facturation/credits, ses missions/analytics n'existent que
# pour lui), et doit avoir un abonnement actif (ou du credit d'essai
# restant) pour faire executer une vraie mission — voir
# _require_subscription() plus bas. Meme mecanique de hash de mot de
# passe que la porte historique de Kader (PBKDF2-SHA256, jamais en clair).
# ---------------------------------------------------------------------

ACCOUNTS_PATH = os.path.join(ROOT, "core", "accounts", "data", "accounts.json")
ACCOUNT_SESSION_TTL_SECONDS = 60 * 60 * 24 * 30  # 30 jours — un client ne doit pas se reconnecter sans arret
ACCOUNT_SESSIONS = {}  # sha256(token) -> {"clientId":..., "email":..., "expiry":...}

# Sessions sauvegardees sur disque (volume /data) pour survivre aux
# redemarrages/deploiements : plus personne n'est deconnecte a chaque mise
# a jour. Seuls les EMPREINTES sha256 des jetons sont ecrites — le jeton
# reel n'existe que dans le cookie du navigateur, un fichier vole ne
# permet donc pas de se faire passer pour quelqu'un.
SESSIONS_PATH = os.path.join(ROOT, "core", "accounts", "data", "sessions.json")
_SESSIONS_LOCK = threading.Lock()


def _session_key(token):
    return hashlib.sha256((token or "").encode("utf-8")).hexdigest()


def _persist_sessions():
    with _SESSIONS_LOCK:
        now = time.time()
        payload = {
            "gate": {k: v for k, v in GATE_SESSIONS.items() if v > now},
            "account": {k: v for k, v in ACCOUNT_SESSIONS.items() if v["expiry"] > now},
        }
        try:
            os.makedirs(os.path.dirname(SESSIONS_PATH), exist_ok=True)
            tmp = SESSIONS_PATH + ".tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(payload, f)
            os.replace(tmp, SESSIONS_PATH)
        except OSError:
            pass  # pire cas : les sessions redeviennent volatiles


def _load_sessions():
    try:
        with open(SESSIONS_PATH, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return
    now = time.time()
    for k, v in (data.get("gate") or {}).items():
        if isinstance(v, (int, float)) and v > now:
            GATE_SESSIONS[k] = v
    for k, v in (data.get("account") or {}).items():
        if isinstance(v, dict) and v.get("expiry", 0) > now and v.get("clientId"):
            ACCOUNT_SESSIONS[k] = v


def _load_accounts():
    return load_json(ACCOUNTS_PATH, []) or []


def _save_accounts(accounts):
    os.makedirs(os.path.dirname(ACCOUNTS_PATH), exist_ok=True)
    _write_json_atomic(ACCOUNTS_PATH, accounts, ensure_ascii=False, indent=2)


ACTIVITY_LOG_PATH = os.path.join(ROOT, "core", "accounts", "data", "activity-log.json")


@_state_locked
def log_activity(kind, **fields):
    """Journal d'activite du createur (2026-09-25) : inscriptions et
    connexions — les seuls evenements qui n'etaient enregistres nulle
    part. Les missions et changements de plan ont deja leurs propres
    traces (runtime/tasks, historique de facturation) et sont fusionnes
    par get_admin_activity(). Ne doit jamais faire echouer une requete."""
    try:
        events = load_json(ACTIVITY_LOG_PATH, []) or []
        events.append({"atUtc": datetime.datetime.utcnow().isoformat() + "Z", "kind": kind, **fields})
        os.makedirs(os.path.dirname(ACTIVITY_LOG_PATH), exist_ok=True)
        _write_json_atomic(ACTIVITY_LOG_PATH, events[-1000:], ensure_ascii=False)
    except Exception:
        pass


def _find_account_by_email(email):
    email = (email or "").strip().lower()
    for acc in _load_accounts():
        if acc.get("email", "").lower() == email:
            return acc
    return None


def _hash_password(password):
    salt = os.urandom(16)
    h = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 200000, dklen=32)
    return f"{salt.hex()}:{h.hex()}:200000"


def _verify_password(password, hash_line):
    try:
        salt_hex, hash_hex, iterations = hash_line.split(":")
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(hash_hex)
        computed = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, int(iterations), dklen=32)
        return hmac.compare_digest(computed, expected)
    except Exception:
        return False


@_state_locked
def create_account(email, password, company_name):
    email = (email or "").strip().lower()
    if "@" not in email or "." not in email.split("@")[-1]:
        return None, "EMAIL_INVALID"
    if len(password or "") < 8:
        return None, "PASSWORD_TOO_SHORT"
    if _find_account_by_email(email):
        return None, "EMAIL_ALREADY_USED"

    accounts = _load_accounts()
    client_id = "CLI-CUST-" + secrets.token_hex(4).upper()
    account = {
        "accountId": client_id,
        "email": email,
        "passwordHash": _hash_password(password),
        "clientId": client_id,
        "companyName": (company_name or "").strip()[:120],
        "createdAtUtc": datetime.datetime.utcnow().isoformat() + "Z",
        "emailVerified": False,
    }
    accounts.append(account)
    _save_accounts(accounts)
    log_activity("signup", email=email, clientId=client_id, companyName=account["companyName"])

    if account["companyName"]:
        save_company_profile({"companyName": account["companyName"]}, client_id=client_id)
    # Demarre le plan Essai des l'inscription (memes credits/duree que le
    # plan affiche sur la page Tarifs) — get_billing() le fait deja par
    # defaut au premier appel, cet appel rend juste l'historique explicite.
    get_billing(client_id)

    return account, None


def account_create_session(account):
    token = secrets.token_urlsafe(32)
    ACCOUNT_SESSIONS[_session_key(token)] = {
        "clientId": account["clientId"],
        "email": account["email"],
        "expiry": time.time() + ACCOUNT_SESSION_TTL_SECONDS,
    }
    _persist_sessions()
    return token


def account_check_session(token):
    if not token:
        return None
    session = ACCOUNT_SESSIONS.get(_session_key(token))
    if not session:
        return None
    if time.time() > session["expiry"]:
        ACCOUNT_SESSIONS.pop(_session_key(token), None)
        return None
    return session


def account_clear_session(token):
    ACCOUNT_SESSIONS.pop(_session_key(token), None)
    _persist_sessions()

# Regroupement par categorie pour le filtre du catalogue — decision de
# presentation (pas dans un fichier source), basee sur les vrais roles
# de chaque Worker (identity.json). A ajuster si Kader prefere un autre
# decoupage.
WORKER_CATEGORIES = {
    "alex":   "Ventes & Prospection",
    "maya":   "Marketing & Growth",
    "emma":   "Contenu & Réseaux sociaux",
    "lea":    "Design & Branding",
    "lucas":  "Développement Web",
    "seoya":  "SEO & Search Intelligence",
    "rayan":  "Automatisation & Intégrations",
    "noah":   "Administration & Organisation",
    "sophie": "RH & Recrutement — Agent ATS IA",
    "yanis":  "Gestion de projet",
    "sam":    "IT & Cybersécurité",
    "nora":   "Support Client",
    "dario":  "Finance & Contrôle de gestion",
    "ines":   "Data & Analytics",
    "clara":  "Juridique & Contrats",
    "amina":  "Research & Intelligence",
    "thomas": "E-commerce & Marketplace",
}

# Types de worker exclus du catalogue commercial (ex: ATLAS = trading
# personnel de Kader, jamais mélangé au produit commercial). Corrige
# le 2026-09-14 : cette liste était codée en dur ["alex","emma",...],
# ce qui obligeait à modifier ce fichier pour chaque nouveau Worker.
# Elle est maintenant lue dynamiquement depuis le registre central —
# ajouter un Worker au registre suffit à le faire apparaître ici.
EXCLUDED_FROM_CATALOG_TYPES = {"trading", "orchestrator-interface"}


def get_worker_ids():
    registry = load_json(WORKER_RUNTIME_REGISTRY_PATH, {"workers": {}})
    return [
        wid for wid, wtype in registry.get("workers", {}).items()
        if wtype not in EXCLUDED_FROM_CATALOG_TYPES
    ]


def load_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return default


def get_capability_matrix():
    return load_json(CAPABILITY_MATRIX_PATH, {"workers": []})


def get_worker_capabilities(worker_id_upper, matrix):
    for w in matrix.get("workers", []):
        if w.get("workerId") == worker_id_upper:
            return w.get("capabilities", [])
    return []


def worker_base_dir(worker_id):
    return CHLOE_DIR if worker_id == "chloe" else os.path.join(WORKERS_DIR, worker_id)


def portrait_url(worker_id):
    """Prefere le portrait 3D genere s'il existe, sinon le badge SVG."""
    base = worker_base_dir(worker_id)
    if os.path.isfile(os.path.join(base, "identity", "portrait-3d.jpg")):
        return f"/portraits/{worker_id}.jpg"
    return f"/portraits/{worker_id}.svg"


def build_worker_summary(worker_id):
    base = worker_base_dir(worker_id)
    identity_path = os.path.join(base, "identity", "identity.json")
    identity = load_json(identity_path, {})
    skills_path = os.path.join(base, "skills", "SKILLS-REGISTRY.json")
    skills = load_json(skills_path, {"skills": {}})
    matrix = get_capability_matrix()
    caps = get_worker_capabilities(worker_id.upper(), matrix)

    has_intro_video = os.path.isfile(os.path.join(base, "identity", "generated", "intro.mp4"))

    return {
        "id": worker_id,
        "workerId": worker_id.upper(),
        "name": identity.get("name", worker_id.capitalize()),
        "role": identity.get("role", ""),
        "category": WORKER_CATEGORIES.get(worker_id, identity.get("role", "")),
        "personality": identity.get("personality", ""),
        "communicationStyle": identity.get("communication_style", ""),
        "visualIdentity": identity.get("visual_identity", {}),
        "portraitUrl": portrait_url(worker_id),
        "introVideoUrl": f"/videos/{worker_id}.mp4" if has_intro_video else None,
        "skillCount": len(skills.get("skills", {})),
        "topSkills": list(skills.get("skills", {}).keys())[:6],
        "allSkills": list(skills.get("skills", {}).keys()),
        "tools": [c.get("tool") for c in caps],
    }


def get_worker_activity(worker_id_upper, client_id, limit=8):
    """Lit les vraies taches deja produites par le systeme (runtime/tasks/*.json),
    UNIQUEMENT celles du client demandeur — sans ce filtre, un client verrait
    les demandes/reponses (potentiellement privees) des autres clients."""
    records = []
    if os.path.isdir(TASKS_DIR):
        for fname in os.listdir(TASKS_DIR):
            if not fname.startswith("TASK-") or not fname.endswith(".json"):
                continue
            data = load_json(os.path.join(TASKS_DIR, fname))
            if not data or data.get("Worker") != worker_id_upper:
                continue
            if data.get("ClientId") != client_id:
                continue
            records.append({
                "taskId": data.get("TaskId"),
                "request": data.get("Request"),
                "status": data.get("Status"),
                "authorized": data.get("Authorized"),
                "createdAtUtc": data.get("CreatedAtUtc"),
                "answer": (data.get("Result") or {}).get("Answer"),
                "executionNote": data.get("ExecutionNote"),
            })
    records.sort(key=lambda r: r.get("createdAtUtc") or "", reverse=True)
    return records[:limit]



# ---------------------------------------------------------------------
# Detection de la langue du client (2026-09-26) : un message anglais qui
# cite une ville francaise ("bakery in Lyon") faisait repondre en francais.
# Petite heuristique par mots courants (aucun appel externe) ; sur doute,
# aucune consigne n'est ajoutee et le modele decide seul.
# ---------------------------------------------------------------------
_LANG_WORDS = {
    "English": "the and for with you your that this what how can please write need want make about from have are is my me our new of to on at an be we it do by or if welcome email customers small help create draft plan idea ideas list message post text price".split(),
    "French": "le la les des une un et pour avec vous votre que qui est sont mon ma mes nos je j'ai ce cette dans sur pas plus comment rédige besoin veux faire nouveau client clients".split(),
    "Spanish": "el la los las una un para con usted tu que qué es son mi mis necesito quiero cómo por esta este del en nuevos clientes ideas escribe".split(),
    "German": "der die das und für mit sie ihr ich ist sind ein eine mein meine wie nicht auf von zu bitte erstelle brauche möchte neue kunden".split(),
    "Portuguese": "os as uma um para com você seu sua que é são meu minha preciso quero como por não do da em novos clientes você escreva".split(),
    "Italian": "il lo gli le una un per con tu suo che è sono mio mia ho bisogno voglio come non del della nuovi clienti scrivi".split(),
}


def detect_reply_language(text):
    import re as _re
    words = _re.findall(r"[a-zà-ÿ']+", (text or "").lower())
    if len(words) < 3:
        return None
    scores = {lang: sum(1 for w in words if w in set(vocab)) for lang, vocab in _LANG_WORDS.items()}
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    best, second = ranked[0], ranked[1]
    if best[1] >= 2 and best[1] >= second[1] + 2:
        return best[0]
    return None


def submit_task(worker_hint_text, worker_id="", plan_only=False, client_id=""):
    """Appelle le vrai pipeline via Submit-Task.ps1 (PowerShell).
    Le resultat est ecrit par le script dans un fichier temporaire
    dedie (evite tout parsing fragile de stdout, pollue par les
    bannieres Write-Host des scripts imbriques)."""
    import tempfile, uuid

    out_file = os.path.join(tempfile.gettempdir(), f"bkaiw-dashboard-{uuid.uuid4().hex}.json")
    try:
        cmd = [
            *PS_CMD,
            "-File", SUBMIT_SCRIPT,
            "-Request", worker_hint_text,
            "-OutFile", out_file,
        ]
        if worker_id:
            cmd += ["-WorkerId", worker_id]
        if plan_only:
            cmd += ["-PlanOnly"]
        if client_id:
            cmd += ["-ClientId", client_id]
        child_env = dict(os.environ)
        reply_lang = detect_reply_language(worker_hint_text)
        if reply_lang:
            child_env["BK_REPLY_LANG"] = reply_lang
        else:
            child_env.pop("BK_REPLY_LANG", None)
        proc = subprocess.run(
            cmd,
            capture_output=True, timeout=600, env=child_env
        )
        stderr = (proc.stderr or b"").decode("utf-8", errors="replace")
        stdout = (proc.stdout or b"").decode("utf-8", errors="replace")

        if os.path.isfile(out_file):
            with open(out_file, encoding="utf-8-sig") as f:
                result = json.load(f)
            if not plan_only:
                dispatch_webhook_if_configured(client_id, result)
            return result

        return {"error": "SUBMIT_FAILED", "detail": stderr.strip() or stdout.strip() or f"exit code {proc.returncode}"}
    except subprocess.TimeoutExpired:
        return {"error": "SUBMIT_TIMEOUT"}
    except Exception as e:
        return {"error": "SUBMIT_EXCEPTION", "detail": str(e)}
    finally:
        try:
            if os.path.isfile(out_file):
                os.remove(out_file)
        except Exception:
            pass


ASYNC_JOB_ID_PATTERN = re.compile(r"^JOB-[A-F0-9]{32}$")


def _async_job_path(job_id):
    return os.path.join(ASYNC_JOBS_DIR, f"{job_id}.json")


def _write_async_job(data):
    os.makedirs(ASYNC_JOBS_DIR, exist_ok=True)
    _write_json_atomic(_async_job_path(data["jobId"]), data, ensure_ascii=False, indent=2)


ASYNC_JOB_MAX_RUNNING_SECONDS = 11 * 60   # submit_task a un delai de 600 s : au-dela, le job est mort


def read_async_job(job_id):
    if not ASYNC_JOB_ID_PATTERN.match(job_id or ""):
        return None
    path = _async_job_path(job_id)
    job = load_json(path)
    if isinstance(job, dict) and job.get("status") == "RUNNING":
        try:
            if time.time() - os.path.getmtime(path) > ASYNC_JOB_MAX_RUNNING_SECONDS:
                job = dict(job, status="ERROR", error="La mission a pris trop de temps ou a été interrompue. Relancez-la.")
        except OSError:
            pass
    return job


# Plafonds de missions en arriere-plan (petit serveur : 2 vCPU / 3,8 Go). Sans plafond, un client pouvait
# lancer des dizaines de missions simultanees (un PowerShell + un appel modele chacune) et saturer le serveur.
ASYNC_MAX_PER_CLIENT = int(os.environ.get("BK_ASYNC_MAX_PER_CLIENT", "2"))
ASYNC_MAX_GLOBAL = int(os.environ.get("BK_ASYNC_MAX_GLOBAL", "6"))
ASYNC_STALE_SECONDS = 20 * 60          # un job RUNNING plus vieux que ca a ete tue par un redemarrage
ASYNC_KEEP_DAYS = 7
_ASYNC_ACTIVE = {}                      # client_id -> nombre de missions en cours
_ASYNC_ACTIVE_LOCK = threading.Lock()


def _async_acquire(client_id):
    """Reserve une place. Renvoie None si OK, sinon le message (francais) du refus."""
    with _ASYNC_ACTIVE_LOCK:
        total = sum(_ASYNC_ACTIVE.values())
        mine = _ASYNC_ACTIVE.get(client_id, 0)
        if mine >= ASYNC_MAX_PER_CLIENT:
            return f"Vous avez déjà {mine} mission(s) en cours. Attendez qu'une se termine avant d'en lancer une autre."
        if total >= ASYNC_MAX_GLOBAL:
            return "Le service traite beaucoup de missions en ce moment. Réessayez dans une minute."
        _ASYNC_ACTIVE[client_id] = mine + 1
    return None


def _async_release(client_id):
    with _ASYNC_ACTIVE_LOCK:
        left = _ASYNC_ACTIVE.get(client_id, 0) - 1
        if left > 0:
            _ASYNC_ACTIVE[client_id] = left
        else:
            _ASYNC_ACTIVE.pop(client_id, None)


def reap_async_jobs(now=None, boot=False):
    """Au demarrage : un job RUNNING trop vieux a ete interrompu par un redemarrage -> ERROR (le client n'attend
    plus pour rien) ; les jobs termines depuis plus de ASYNC_KEEP_DAYS jours sont supprimes."""
    now = now if now is not None else time.time()
    try:
        names = os.listdir(ASYNC_JOBS_DIR)
    except OSError:
        return
    for name in names:
        if not name.endswith(".json"):
            continue
        p = os.path.join(ASYNC_JOBS_DIR, name)
        try:
            age = now - os.path.getmtime(p)
            if age > ASYNC_KEEP_DAYS * 86400:
                os.remove(p)
                continue
            job = load_json(p)
            if isinstance(job, dict) and job.get("status") == "RUNNING" and (boot or age > ASYNC_STALE_SECONDS):
                job.update(status="ERROR", error="Mission interrompue par un redémarrage du service. Relancez-la.",
                           finishedAtUtc=datetime.datetime.utcnow().isoformat() + "Z")
                _write_async_job(job)
        except Exception:
            continue


def submit_task_limited(objective, **kw):
    """submit_task avec le MEME plafond que les missions en arriere-plan (endpoints synchrones, API publique)."""
    cid = kw.get("client_id", "")
    refusal = _async_acquire(cid)
    if refusal:
        return {"error": "TOO_MANY_RUNNING_MISSIONS", "detail": refusal}
    try:
        return submit_task(objective, **kw)
    finally:
        _async_release(cid)


def submit_task_async(objective, worker_id="", client_id="", plan_only=False):
    """Lance une mission en arriere-plan, renvoie un jobId a interroger.
    Le job (runtime/async-jobs/<jobId>.json) passe de RUNNING a DONE/ERROR.
    IMPORTANT : le job n'est PAS un TASK-*.json -> aucun double comptage de
    credits (le pipeline ecrit son propre TASK-*.json, compte une seule fois).

    submit_task garde EXACTEMENT sa signature synchrone
    (worker_hint_text, worker_id, plan_only, client_id) : on se contente de
    la lancer dans un thread demon pour debloquer la connexion HTTP."""
    refusal = _async_acquire(client_id)
    if refusal:
        return {"error": "TOO_MANY_RUNNING_MISSIONS", "detail": refusal}
    job_id = "JOB-" + secrets.token_hex(16).upper()
    now = datetime.datetime.utcnow().isoformat() + "Z"
    base = {"jobId": job_id, "status": "RUNNING", "clientId": client_id,
            "worker": worker_id or "chloe", "objective": objective,
            "planOnly": bool(plan_only), "createdAtUtc": now}
    _write_async_job(base)

    def _run():
        record = dict(base)
        try:
            result = submit_task(objective, worker_id=worker_id,
                                 plan_only=plan_only, client_id=client_id)
            if not plan_only:
                try:
                    result = attach_pending_action(result)
                except Exception:
                    pass
            record.update(status="DONE",
                          finishedAtUtc=datetime.datetime.utcnow().isoformat() + "Z",
                          result=result)
        except Exception as exc:  # noqa: BLE001
            record.update(status="ERROR",
                          finishedAtUtc=datetime.datetime.utcnow().isoformat() + "Z",
                          error=str(exc))
        try:
            # L'ecriture finale du statut ne doit jamais etre perdue (sinon le client attendrait un job
            # "en cours" a jamais) : quelques essais, un lecteur concurrent peut verrouiller le fichier.
            for attempt in range(6):
                try:
                    _write_async_job(record)
                    break
                except Exception:
                    time.sleep(0.2 * (attempt + 1))
        finally:
            _async_release(client_id)

    threading.Thread(target=_run, daemon=True).start()
    return {"jobId": job_id, "status": "RUNNING"}


TASK_ID_PATTERN = re.compile(r"^TASK-[A-F0-9]{32}$")


def _pending_action_path(task_id):
    # task_id vient du corps de la requete (client) : sans ce controle
    # strict, une valeur du type "../../autre-fichier" permettrait de
    # lire ou supprimer un fichier hors de memory/runtime/.
    if not TASK_ID_PATTERN.match(task_id or ""):
        return None
    return os.path.join(PENDING_ACTIONS_DIR, f"PENDING-ACTION-{task_id}.json")


_SENSITIVE_PARAM_HINTS = (
    "token", "secret", "password", "apikey", "api_key", "authorization",
    "auth", "bearer", "key", "credential", "signature", "hash",
)
_PARAM_VALUE_MAX = 2000
_MASKED = "•••masqué•••"


def _safe_param_value(value, _depth=0):
    """Nettoie une valeur de parametre avant de la renvoyer au client :
    tronque les chaines trop longues. Les dicts sont parcourus sur un
    seul niveau supplementaire (pas d'over-engineering)."""
    if isinstance(value, str):
        if len(value) > _PARAM_VALUE_MAX:
            return value[:_PARAM_VALUE_MAX] + " …(tronqué)"
        return value
    if isinstance(value, dict) and _depth == 0:
        return _safe_action_params(value, _depth + 1)
    return value


def _safe_action_params(params, _depth=0):
    """Copie peu profonde et assainie des parametres d'une action en
    attente : masque toute valeur dont la cle ressemble a un secret
    (token/secret/password/cle/signature…) et tronque les chaines trop
    longues. Ne JAMAIS renvoyer les parametres bruts : le fichier
    PENDING-ACTION peut contenir des jetons ou identifiants."""
    if not isinstance(params, dict):
        return {}
    safe = {}
    for key, value in params.items():
        lowered = str(key).lower()
        if any(hint in lowered for hint in _SENSITIVE_PARAM_HINTS):
            safe[key] = _MASKED
        else:
            safe[key] = _safe_param_value(value, _depth)
    return safe


def attach_pending_action(result):
    """Si la mission qu'on vient de traiter a demande a Claude d'utiliser
    un connecteur en ECRITURE, ANTHROPIC-ADAPTER.ps1 a ecrit un fichier
    PENDING-ACTION-<TaskId>.json (jamais execute automatiquement — voir
    ce fichier). On l'attache au resultat renvoye au client sous
    pendingAction, pour que le dashboard puisse proposer de confirmer
    ou d'annuler. N'efface rien : seul /api/connector-action/confirm ou
    /cancel efface le fichier.

    2026-09-29 : une mission passee par Chloe (orchestration multi-Worker,
    /api/chloe/task) n'a PAS de TaskId au premier niveau — seulement un par
    Worker dans result["Results"][i]["TaskId"]. Avant ce correctif, la carte
    de confirmation n'apparaissait donc JAMAIS pour une action preparee via
    Chloe (le point d'entree principal du produit) : l'action restait ecrite
    sur disque, jamais visible, jamais confirmable. On cherche maintenant
    aussi dans Results[]. S'il y a plusieurs actions en attente, on les
    attache toutes (pendingActions), et pendingAction pointe sur la premiere
    pour rester compatible avec l'interface existante."""
    if not isinstance(result, dict):
        return result

    candidate_ids = []
    top_level = result.get("TaskId")
    if top_level:
        candidate_ids.append(top_level)
    for item in (result.get("Results") or []):
        if isinstance(item, dict) and item.get("TaskId"):
            candidate_ids.append(item["TaskId"])

    found = []
    for task_id in candidate_ids:
        pending = load_json(_pending_action_path(task_id))
        if pending:
            entry = {
                "taskId": pending.get("taskId"),
                "connectorId": pending.get("connectorId"),
                "operation": pending.get("operation"),
                "reason": pending.get("reason"),
            }
            # Contenu exact qui sera envoye (destinataire, objet, corps,
            # montant…), remonte depuis le fichier PENDING-ACTION, avec
            # masquage des secrets et troncature des champs trop longs.
            raw_params = pending.get("params")
            if isinstance(raw_params, dict) and raw_params:
                entry["params"] = _safe_action_params(raw_params)
            found.append(entry)
    if found:
        result["pendingAction"] = found[0]
        result["pendingActions"] = found
    return result


CONFIRM_CONNECTOR_ACTION_SCRIPT = os.path.join(DASHBOARD_DIR, "Confirm-Connector-Action.ps1")
STORE_CLIENT_CREDENTIAL_SCRIPT = os.path.join(DASHBOARD_DIR, "Store-Client-Credential-Bridge.ps1")
GOOGLE_OAUTH_SCRIPT = os.path.join(DASHBOARD_DIR, "Google-OAuth-Bridge.ps1")

# "Se connecter avec Google" (2026-09-25) : le client se connecte avec SON
# compte Google sur l'ecran de consentement de Google, sans jamais voir ni
# coller de jeton. Un jeu de permissions minimal par outil.
GOOGLE_OAUTH_SCOPES = {
    "gmail": ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.compose"],
    "google_calendar": ["https://www.googleapis.com/auth/calendar.events", "https://www.googleapis.com/auth/calendar.readonly"],
    "google_drive": ["https://www.googleapis.com/auth/drive.readonly"],
    "google_search_console": ["https://www.googleapis.com/auth/webmasters.readonly"],
}
MICROSOFT_OAUTH_SCOPES = {
    "outlook_mail": ["Mail.ReadWrite"],
    "outlook_calendar": ["Calendars.ReadWrite"],
    "teams": ["Chat.ReadWrite", "ChannelMessage.Send"],
    "onedrive": ["Files.Read"],
}
# Registre "Se connecter avec ..." : ajouter un fournisseur = une entree ici
# + son application enregistree chez lui (client_id/secret dans le coffre).
OAUTH_VENDORS = {
    "google": {
        "authUrl": "https://accounts.google.com/o/oauth2/v2/auth",
        "scopes": GOOGLE_OAUTH_SCOPES,
        "base": ["openid", "email"],
        "extra": {"access_type": "offline", "prompt": "consent", "include_granted_scopes": "false"},
    },
    "microsoft": {
        "authUrl": "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
        "scopes": MICROSOFT_OAUTH_SCOPES,
        "base": ["openid", "email", "offline_access", "User.Read"],
        "extra": {"prompt": "consent", "response_mode": "query"},
    },
}
OAUTH_STATES = {}  # state -> {"clientId", "provider", "vendor", "expiry"}
OAUTH_APP_CACHE = {}  # vendor -> client_id public de l'application

# Autres fournisseurs (Slack, HubSpot, Dropbox...) : declares dans
# core/integrations/oauth-vendors.json, application OAuth fournie par les
# variables d'environnement OAUTH_<FOURNISSEUR>_CLIENT_ID / _CLIENT_SECRET.
for _name, _v in (load_json(os.path.join(ROOT, "core", "integrations", "oauth-vendors.json"), {}) or {}).items():
    if _name.startswith("_") or _name in OAUTH_VENDORS:
        continue
    OAUTH_VENDORS[_name] = {"authUrl": _v["authUrl"], "scopes": _v["providers"], "base": _v.get("base", []),
                            "extra": _v.get("extra", {}), "env": True, "label": _v.get("label", _name)}


def oauth_vendor_ready(vendor):
    """Google/Microsoft : application deja dans le coffre du proprietaire.
    Les autres : n'apparaissent en 'un clic' que si leurs variables sont posees."""
    cfg = OAUTH_VENDORS.get(vendor)
    if not cfg:
        return False
    if not cfg.get("env"):
        return True
    key = vendor.upper()
    return bool(os.environ.get(f"OAUTH_{key}_CLIENT_ID") and os.environ.get(f"OAUTH_{key}_CLIENT_SECRET"))


def run_google_oauth_bridge(payload):  # pont OAuth generique (google, microsoft)
    import tempfile, uuid
    in_file = os.path.join(tempfile.gettempdir(), f"bkaiw-goauth-in-{uuid.uuid4().hex}.json")
    out_file = os.path.join(tempfile.gettempdir(), f"bkaiw-goauth-out-{uuid.uuid4().hex}.json")
    try:
        with open(in_file, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
        proc = subprocess.run([*PS_CMD, "-File", GOOGLE_OAUTH_SCRIPT, "-InFile", in_file, "-OutFile", out_file],
                              capture_output=True, timeout=60)
        if os.path.isfile(out_file):
            with open(out_file, encoding="utf-8-sig") as f:
                return json.load(f)
        return {"ok": False, "error": (proc.stderr or proc.stdout or b"").decode("utf-8", errors="replace").strip()[:200] or "BRIDGE_FAILED"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "GOOGLE_OAUTH_TIMEOUT"}
    except Exception as e:
        return {"ok": False, "error": str(e)[:200]}
    finally:
        for p in (in_file, out_file):
            try:
                if os.path.isfile(p):
                    os.remove(p)
            except Exception:
                pass

CLIENT_CREDENTIALS_DIR = os.path.join(ROOT, "core", "connectors", "client-credentials", "data")

# Meme liste que .secrets/Store-Credential.ps1 / deploy/set-connector-secrets.py
# (hors financiers, hors did/elevenlabs/openai/anthropic/stripe — ceux-la
# restent la cle plateforme de Kader, pas un identifiant par client).
CLIENT_CONNECTOR_PROVIDERS = {
    "slack", "trello", "asana", "monday", "zendesk", "intercom", "figma",
    "hubspot", "pipedrive", "webflow", "shopify", "woocommerce", "wordpress",
    "dropbox", "linkedin", "facebook", "instagram", "tiktok", "x_twitter",
    "meta_ads", "whatsapp_business", "gmail", "google_calendar", "google_drive",
    "google_search_console", "google_ads", "outlook_mail", "outlook_calendar",
    "teams", "onedrive", "salesforce", "twilio", "uptimerobot", "bamboohr",
}

# Le connectorId du catalogue ("calendar") ne correspond pas toujours au
# nom de fichier d'identifiant ("google_calendar", voir OAuth2-Adapter.ps1
# $Script:OAuthConnectorConfig) — seule cette entree differe, toutes les
# autres sont identiques (verifie contre core/integrations/*.ps1).
CONNECTOR_ID_TO_CREDENTIAL_PROVIDER = {
    "calendar": "google_calendar",
    # 2026-09-30 : le connecteur catalogue garde son nom generique
    # (le security gate en depend pour certains Workers), mais le VRAI
    # fournisseur choisi par Kader a son propre fichier d'identifiant.
    "monitoring": "uptimerobot",
    "calendar_hr": "bamboohr",
}

# Connexion guidee des outils pour les CLIENTS (2026-10-06, demande de Kader :
# "les clients doivent connecter tous leurs outils le plus facilement possible").
import connect_guides
connect_guides.load_guides(os.path.join(ROOT, "core", "integrations", "connect-guides.json"))
CRED_SAVE_RATE = {}            # client_id -> [timestamps]
CRED_SAVE_MAX_PER_HOUR = 40


def connector_id_for_provider(provider):
    reverse = {v: k for k, v in CONNECTOR_ID_TO_CREDENTIAL_PROVIDER.items()}
    return reverse.get(provider, provider) + ".controlled"


def verify_client_tool(client_id, provider, just_saved=False):
    """Un appel de LECTURE inoffensif chez le fournisseur (connect-guides.json, cle "test").
    Retourne (payload, http_status). Jamais de donnees du fournisseur dans la reponse."""
    guide = connect_guides.guide_for(provider) or {}
    label = guide.get("label", provider)
    connector_id = connector_id_for_provider(provider)
    res = run_connector_dispatch_bridge(connector_id, "TEST_CONNECTION", {}, client_id)
    if str(res.get("Status")) == "SUCCESS":
        return {"ok": True, "connected": True, "verified": True, "message": f"{label} est connecté."}, 200
    kind, message = connect_guides.classify_test_error(label, str(res.get("Detail") or ""))
    if just_saved and kind in ("auth", "notfound"):
        # Identifiants ou adresse faux : on n'en garde rien (sinon "Connecte" s'afficherait a tort).
        store_client_connector_credential(client_id, provider, "")
        toggle_client_connector(client_id, connector_id, False)
        return {"ok": False, "error": "VERIFY_FAILED", "kind": kind, "message": message, "removed": True}, 200
    return {"ok": just_saved, "connected": True, "verified": False, "kind": kind, "message": message}, 200


CONNECTOR_INTEREST_PATH = os.path.join(ROOT, "core", "connectors", "data", "connector-interest.json")


@_state_locked
def record_connector_interest(client_id, provider):
    """Bouton "Me prevenir" : l'outil n'est pas encore connectable (application a enregistrer
    chez le fournisseur) — on garde qui le demande, pour prioriser et prevenir."""
    data = load_json(CONNECTOR_INTEREST_PATH, {})
    if not isinstance(data, dict):
        data = {}
    ids = data.setdefault(provider, [])
    if client_id not in ids:
        ids.append(client_id)
    _write_json_atomic(CONNECTOR_INTEREST_PATH, data, ensure_ascii=False, indent=2)
    return len(ids)


def connect_client_tool(client_id, provider, fields):
    if provider not in CLIENT_CONNECTOR_PROVIDERS or not connect_guides.guide_for(provider):
        return {"ok": False, "error": "NO_GUIDE"}, 404
    rows = _recent(CRED_SAVE_RATE, client_id, 3600)
    if len(rows) >= CRED_SAVE_MAX_PER_HOUR:
        return {"ok": False, "error": "RATE_LIMITED", "message": "Trop de tentatives. Réessayez dans une heure."}, 429
    rows.append(time.time())
    secret, err = connect_guides.build_secret(provider, fields)
    if err:
        return {"ok": False, "error": "INVALID_FIELD", "field": err["field"], "message": err["message"]}, 400
    saved = store_client_connector_credential(client_id, provider, secret)
    secret = None
    if not saved.get("ok"):
        return {"ok": False, "error": "STORE_FAILED", "message": "Enregistrement impossible pour le moment. Réessayez."}, 500
    toggle_client_connector(client_id, connector_id_for_provider(provider), True)
    return verify_client_tool(client_id, provider, just_saved=True)


def get_client_configured_providers(client_id):
    """Connecteurs pour lesquels CE client a deja enregistre son propre
    identifiant (fichier present, pas son contenu — jamais dechiffre ici)."""
    cred_dir = os.path.join(CLIENT_CREDENTIALS_DIR, client_id)
    try:
        return {f[:-5] for f in os.listdir(cred_dir) if f.endswith(".json")}
    except Exception:
        return set()


def store_client_connector_credential(client_id, provider, value):
    """Appelle Store-Client-Credential-Bridge.ps1 pour chiffrer et
    enregistrer (ou supprimer si value est vide) l'identifiant DE CE
    CLIENT pour ce connecteur. Passe par un fichier JSON, jamais par une
    commande PowerShell interpolee (meme raison que le pont de confirmation)."""
    import tempfile, uuid

    if provider not in CLIENT_CONNECTOR_PROVIDERS:
        return {"ok": False, "error": "UNKNOWN_PROVIDER"}

    in_file = os.path.join(tempfile.gettempdir(), f"bkaiw-cred-in-{uuid.uuid4().hex}.json")
    out_file = os.path.join(tempfile.gettempdir(), f"bkaiw-cred-out-{uuid.uuid4().hex}.json")
    try:
        with open(in_file, "w", encoding="utf-8") as f:
            json.dump({"clientId": client_id, "provider": provider, "value": value or ""}, f, ensure_ascii=False)
        cmd = [*PS_CMD, "-File", STORE_CLIENT_CREDENTIAL_SCRIPT, "-InFile", in_file, "-OutFile", out_file]
        proc = subprocess.run(cmd, capture_output=True, timeout=20)
        stderr = (proc.stderr or b"").decode("utf-8", errors="replace")
        stdout = (proc.stdout or b"").decode("utf-8", errors="replace")
        if os.path.isfile(out_file):
            with open(out_file, encoding="utf-8-sig") as f:
                return json.load(f)
        return {"ok": False, "error": stderr.strip() or stdout.strip() or f"exit code {proc.returncode}"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "STORE_CREDENTIAL_TIMEOUT"}
    except Exception as e:
        return {"ok": False, "error": str(e)}
    finally:
        for f in (in_file, out_file):
            try:
                os.remove(f)
            except Exception:
                pass


def run_connector_dispatch_bridge(connector_id, operation, params, client_id):
    """Appelle Confirm-Connector-Action.ps1 pour EXECUTER REELLEMENT une
    action de connecteur deja proposee et confirmee explicitement par le
    client (jamais appele automatiquement pendant une mission).
    ConnectorId/Operation/ClientId/Params passent par un fichier JSON,
    jamais interpoles dans une commande PowerShell — evite tout risque
    d'injection si l'un de ces champs contenait un caractere special
    PowerShell ($, backtick...)."""
    import tempfile, uuid

    in_file = os.path.join(tempfile.gettempdir(), f"bkaiw-connector-in-{uuid.uuid4().hex}.json")
    out_file = os.path.join(tempfile.gettempdir(), f"bkaiw-connector-out-{uuid.uuid4().hex}.json")
    try:
        with open(in_file, "w", encoding="utf-8") as f:
            json.dump({"connectorId": connector_id, "operation": operation, "clientId": client_id, "params": params or {}}, f, ensure_ascii=False)

        cmd = [*PS_CMD, "-File", CONFIRM_CONNECTOR_ACTION_SCRIPT, "-InFile", in_file, "-OutFile", out_file]
        proc = subprocess.run(cmd, capture_output=True, timeout=30)
        stderr = (proc.stderr or b"").decode("utf-8", errors="replace")
        stdout = (proc.stdout or b"").decode("utf-8", errors="replace")
        if os.path.isfile(out_file):
            with open(out_file, encoding="utf-8-sig") as f:
                return json.load(f)
        return {"Status": "ERROR", "Detail": stderr.strip() or stdout.strip() or f"exit code {proc.returncode}"}
    except subprocess.TimeoutExpired:
        return {"Status": "ERROR", "Detail": "CONNECTOR_DISPATCH_TIMEOUT"}
    except Exception as e:
        return {"Status": "ERROR", "Detail": str(e)}
    finally:
        for f in (in_file, out_file):
            try:
                if os.path.isfile(f):
                    os.remove(f)
            except Exception:
                pass


def run_automation_bridge(action, **kwargs):
    """Appelle Automation-Bridge.ps1 (creer/lister/activer/executer une
    automatisation). Meme convention que submit_task : resultat ecrit
    dans un fichier temporaire dedie plutot que parse depuis stdout."""
    import tempfile, uuid

    out_file = os.path.join(tempfile.gettempdir(), f"bkaiw-automation-{uuid.uuid4().hex}.json")
    try:
        cmd = [
            *PS_CMD,
            "-File", AUTOMATION_BRIDGE_SCRIPT,
            "-Action", action,
            "-OutFile", out_file,
        ]
        if kwargs.get("worker_id"):
            cmd += ["-WorkerId", kwargs["worker_id"]]
        if kwargs.get("objective"):
            cmd += ["-Objective", kwargs["objective"]]
        if kwargs.get("frequency_minutes"):
            cmd += ["-FrequencyMinutes", str(kwargs["frequency_minutes"])]
        if kwargs.get("automation_id"):
            cmd += ["-Id", kwargs["automation_id"]]
        if "enabled" in kwargs:
            cmd += ["-Enabled", "1" if kwargs["enabled"] else "0"]
        if "notify_slack" in kwargs:
            cmd += ["-NotifySlack", "1" if kwargs["notify_slack"] else "0"]
        if kwargs.get("client_id"):
            cmd += ["-ClientId", kwargs["client_id"]]

        proc = subprocess.run(cmd, capture_output=True, timeout=90)
        stderr = (proc.stderr or b"").decode("utf-8", errors="replace")
        stdout = (proc.stdout or b"").decode("utf-8", errors="replace")

        if os.path.isfile(out_file):
            with open(out_file, encoding="utf-8-sig") as f:
                return json.load(f)

        return {"error": "AUTOMATION_BRIDGE_FAILED", "detail": stderr.strip() or stdout.strip() or f"exit code {proc.returncode}"}
    except subprocess.TimeoutExpired:
        return {"error": "AUTOMATION_BRIDGE_TIMEOUT"}
    except Exception as e:
        return {"error": "AUTOMATION_BRIDGE_EXCEPTION", "detail": str(e)}
    finally:
        try:
            if os.path.isfile(out_file):
                os.remove(out_file)
        except Exception:
            pass


def run_stripe_bridge(action, **kwargs):
    """Appelle Stripe-Bridge.ps1 (statut / creation de Checkout Session /
    confirmation apres paiement). Meme convention que run_automation_bridge :
    resultat ecrit dans un fichier temporaire dedie. Aucune donnee de
    carte ne transite jamais par ce serveur — Stripe heberge le
    paiement lui-meme, ce pont ne fait que creer/relire des sessions."""
    import tempfile, uuid

    out_file = os.path.join(tempfile.gettempdir(), f"bkaiw-stripe-{uuid.uuid4().hex}.json")
    try:
        cmd = [
            *PS_CMD,
            "-File", STRIPE_BRIDGE_SCRIPT,
            "-Action", action,
            "-OutFile", out_file,
        ]
        if kwargs.get("plan_id"):
            cmd += ["-PlanId", kwargs["plan_id"]]
        if kwargs.get("session_id"):
            cmd += ["-SessionId", kwargs["session_id"]]
        if kwargs.get("success_url"):
            cmd += ["-SuccessUrl", kwargs["success_url"]]
        if kwargs.get("cancel_url"):
            cmd += ["-CancelUrl", kwargs["cancel_url"]]
        if kwargs.get("subscription_id"):
            cmd += ["-SubscriptionId", kwargs["subscription_id"]]
        if kwargs.get("interval"):
            cmd += ["-Interval", kwargs["interval"]]
        if kwargs.get("client_id"):
            cmd += ["-ClientId", kwargs["client_id"]]

        proc = subprocess.run(cmd, capture_output=True, timeout=30)
        stderr = (proc.stderr or b"").decode("utf-8", errors="replace")
        stdout = (proc.stdout or b"").decode("utf-8", errors="replace")

        if os.path.isfile(out_file):
            with open(out_file, encoding="utf-8-sig") as f:
                return json.load(f)

        return {"Status": "ERROR", "Detail": stderr.strip() or stdout.strip() or f"exit code {proc.returncode}"}
    except subprocess.TimeoutExpired:
        return {"Status": "ERROR", "Detail": "STRIPE_BRIDGE_TIMEOUT"}
    except Exception as e:
        return {"Status": "ERROR", "Detail": str(e)}
    finally:
        try:
            if os.path.isfile(out_file):
                os.remove(out_file)
        except Exception:
            pass


# Connecteurs actives par client (2026-09-22) : quels TYPES de
# connecteurs un client a choisi pour son propre compte, comme il gere
# ses propres automatisations — un fichier par ClientId, meme
# convention que le profil/la facturation. N'active JAMAIS d'appel
# externe reel : liveExecutionEnabled reste un interrupteur GLOBAL
# (catalogue), pas un choix par client — un client ne peut jamais
# activer un acces reel a Gmail/Slack/etc. par lui-meme, seulement
# indiquer son intention pour quand Kader branchera un vrai adaptateur.
CONNECTORS_DATA_DIR = os.path.join(ROOT, "core", "connectors", "data")


def _client_connectors_path(client_id):
    return os.path.join(CONNECTORS_DATA_DIR, f"{client_id}.json")


def _load_client_connectors(client_id):
    if not client_id:
        return set()
    ids = load_json(_client_connectors_path(client_id), [])
    return set(ids) if isinstance(ids, list) else set()


def _save_client_connectors(client_id, ids):
    os.makedirs(CONNECTORS_DATA_DIR, exist_ok=True)
    _write_json_atomic(_client_connectors_path(client_id), sorted(ids), ensure_ascii=False, indent=2)


# Pre-autorisation globale (2026-09-23, sur demande explicite du client
# pouvant "donner l'autorisation au depart sur tout") : quand active, une
# action de connecteur en ECRITURE proposee par un Worker s'execute pour
# de vrai immediatement (voir ANTHROPIC-ADAPTER.ps1), sans passer par la
# carte de confirmation manuelle. Desactive par defaut — c'est un choix
# explicite du client, jamais une valeur par defaut.
def _client_autoapprove_path(client_id):
    return os.path.join(CONNECTORS_DATA_DIR, f"{client_id}.autoapprove.json")


def _load_client_autoapprove(client_id):
    if not client_id:
        return False
    return bool(load_json(_client_autoapprove_path(client_id), {}).get("autoApprove"))


@_state_locked
def _save_client_autoapprove(client_id, enabled):
    os.makedirs(CONNECTORS_DATA_DIR, exist_ok=True)
    _write_json_atomic(_client_autoapprove_path(client_id), {"autoApprove": bool(enabled)}, ensure_ascii=False, indent=2)


# =====================================================================
# INTEGRATIONS GENERIQUES (2026-09-30, demande explicite de Kader :
# "fait l'integration generique compatible [Zapier/Make]"). Plutot que
# de construire une app dediee dans le magasin Zapier/Make (ce qui
# exigerait un compte developpeur a LUI et une revue de plateforme),
# on expose les deux briques universelles que Zapier ET Make savent
# deja parler nativement via leurs modules "Webhooks"/"HTTP" :
#   - une cle API par client -> un Zap/scenario peut DECLENCHER une
#     mission (POST /api/public/v1/missions), sans jamais toucher au
#     mot de passe du compte.
#   - une URL de webhook par client -> BK notifie ce Zap/scenario a la
#     fin de CHAQUE mission (quelle que soit son origine), pour s'en
#     servir comme declencheur ("New Mission Completed").
# Meme isolation stricte que le reste de la plateforme : une cle ne
# donne jamais acces qu'aux missions de SON PROPRE client.
# =====================================================================

def _client_apikey_path(client_id):
    return os.path.join(CONNECTORS_DATA_DIR, f"{client_id}.apikey.json")


def _client_webhook_path(client_id):
    return os.path.join(CONNECTORS_DATA_DIR, f"{client_id}.webhook.json")


def _generate_api_key():
    raw = "bkw_live_" + secrets.token_urlsafe(32)
    key_hash = hashlib.sha256(raw.encode("utf-8")).hexdigest()
    return raw, key_hash


@_state_locked
def _save_client_apikey(client_id, key_hash, key_prefix):
    os.makedirs(CONNECTORS_DATA_DIR, exist_ok=True)
    _write_json_atomic(_client_apikey_path(client_id), {
        "keyHash": key_hash,
        "keyPrefix": key_prefix,
        "createdAtUtc": datetime.datetime.utcnow().isoformat() + "Z",
    }, ensure_ascii=False, indent=2)


def _load_client_apikey(client_id):
    if not client_id:
        return None
    return load_json(_client_apikey_path(client_id), None)


@_state_locked
def _remove_client_apikey(client_id):
    try:
        os.remove(_client_apikey_path(client_id))
    except OSError:
        pass


def _find_client_by_api_key(raw_key):
    """Retrouve le ClientId proprietaire d'une cle API presentee par un
    appelant externe (Zapier, Make, ou tout autre outil). Jamais de cle
    en clair stockee sur disque : seul son hash SHA-256 est compare,
    avec hmac.compare_digest pour eviter une fuite par timing."""
    if not raw_key or not raw_key.startswith("bkw_"):
        return None
    key_hash = hashlib.sha256(raw_key.encode("utf-8")).hexdigest()
    try:
        files = os.listdir(CONNECTORS_DATA_DIR)
    except OSError:
        return None
    for fname in files:
        if not fname.endswith(".apikey.json"):
            continue
        data = load_json(os.path.join(CONNECTORS_DATA_DIR, fname), None)
        if data and hmac.compare_digest(str(data.get("keyHash", "")), key_hash):
            return fname[: -len(".apikey.json")]
    return None


@_state_locked
def _save_client_webhook(client_id, url):
    os.makedirs(CONNECTORS_DATA_DIR, exist_ok=True)
    existing = load_json(_client_webhook_path(client_id), {}) or {}
    secret = existing.get("secret") or secrets.token_hex(32)
    _write_json_atomic(_client_webhook_path(client_id), {
        "url": url,
        "secret": secret,
        "createdAtUtc": existing.get("createdAtUtc") or (datetime.datetime.utcnow().isoformat() + "Z"),
    }, ensure_ascii=False, indent=2)
    return secret


def _load_client_webhook(client_id):
    if not client_id:
        return None
    return load_json(_client_webhook_path(client_id), None)


@_state_locked
def _remove_client_webhook(client_id):
    try:
        os.remove(_client_webhook_path(client_id))
    except OSError:
        pass


def _summarize_mission_result(result):
    """Meme resultat, mis a plat pour un appelant externe (Zapier/Make) :
    gere aussi bien une mission Worker directe (TaskId au premier niveau)
    qu'une orchestration Chloe (un TaskId par Worker dans Results[])."""
    if not isinstance(result, dict):
        return {"status": "ERROR", "error": "UNEXPECTED_RESULT"}
    if result.get("error"):
        return {"status": "ERROR", "error": result.get("error")}
    if result.get("Results"):
        return {
            "status": result.get("Status"),
            "results": [
                {
                    "taskId": r.get("TaskId"),
                    "worker": r.get("Worker"),
                    "status": r.get("Status"),
                    "answer": (r.get("Result") or {}).get("Answer"),
                    "files": (r.get("Result") or {}).get("Files"),
                }
                for r in result.get("Results", []) if isinstance(r, dict)
            ],
        }
    return {
        "taskId": result.get("TaskId"),
        "worker": result.get("Worker"),
        "status": result.get("Status"),
        "answer": (result.get("Result") or {}).get("Answer"),
        "files": (result.get("Result") or {}).get("Files"),
    }


PUBLIC_API_CALLS = {}   # clientId -> [timestamps]
PUBLIC_API_WINDOW = 60
PUBLIC_API_MAX_PER_MINUTE = 20


def public_api_throttled(client_id):
    rows = _recent(PUBLIC_API_CALLS, client_id, PUBLIC_API_WINDOW)
    if len(rows) >= PUBLIC_API_MAX_PER_MINUTE:
        return True
    rows.append(time.time())
    PUBLIC_API_CALLS[client_id] = rows
    return False


def dispatch_webhook_if_configured(client_id, result):
    """Notifie l'automatisation externe du client (Zapier/Make/autre) a
    la fin d'une mission, quelle que soit son origine (dashboard ou API
    publique). Best-effort et en arriere-plan : une URL lente ou en
    panne chez le client ne doit jamais ralentir ni faire echouer la
    reponse de la mission elle-meme."""
    if not client_id:
        return
    cfg = _load_client_webhook(client_id)
    if not cfg or not cfg.get("url"):
        return
    summary = _summarize_mission_result(result)

    def _send():
        import urllib.request
        try:
            payload = {
                "event": "mission.completed",
                "clientId": client_id,
                "createdAtUtc": datetime.datetime.utcnow().isoformat() + "Z",
                **summary,
            }
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            signature = hmac.new(cfg["secret"].encode("utf-8"), body, hashlib.sha256).hexdigest()
            req = urllib.request.Request(
                cfg["url"], data=body, method="POST",
                headers={"Content-Type": "application/json", "X-BK-Signature": f"sha256={signature}"},
            )
            urllib.request.urlopen(req, timeout=10).read()
        except Exception:
            pass

    threading.Thread(target=_send, daemon=True).start()


def get_connector_catalog(client_id=None):
    """Lit le VRAI catalogue de connecteurs (aucun appel externe reel
    n'est jamais fait tant que liveExecutionEnabled est false — voir
    core/runtime/controlled-connectors/CONTROLLED-CONNECTOR-CATALOG.json).
    Si client_id est fourni, ajoute l'etat d'activation PROPRE a ce
    client (jamais partage entre clients, comme ses automatisations)."""
    data = load_json(CONNECTOR_CATALOG_PATH, {"liveExecutionEnabled": False, "connectors": []})
    # Doublons purs (2026-09-30, demande explicite de Kader) : ces 3
    # categories generiques ne designent aucun produit et font double
    # emploi avec des connecteurs reels deja lister a cote (crm ->
    # Salesforce/HubSpot/Pipedrive, social_media -> LinkedIn/Instagram/
    # Facebook/TikTok/X, design -> Figma). On les retire entierement de
    # l'affichage (pas seulement "Bientot") : leur entree CATALOGUE reste
    # enabled=true (le security gate en depend toujours pour certains
    # Workers), seul ce qui est montre au client change.
    HIDDEN_DUPLICATE_CONNECTORS = {"crm.controlled", "social_media.controlled", "design.controlled"}
    connectors = [c for c in data.get("connectors", []) if c.get("connectorId") not in HIDDEN_DUPLICATE_CONNECTORS]
    activated = _load_client_connectors(client_id) if client_id else set()
    # 2026-09-24 : "configure" = ce client a enregistre SON PROPRE
    # identifiant (fichier present dans son espace chiffre) — distinct
    # de "activatedByClient" qui est juste l'intention ("je veux pouvoir
    # utiliser ce connecteur"). Un connecteur peut etre active sans etre
    # configure (le client n'a pas encore colle son jeton).
    configured_providers = get_client_configured_providers(client_id) if client_id else set()
    by_category = {}
    for c in connectors:
        id_base = (c.get("connectorId") or "").removesuffix(".controlled")
        cred_key = CONNECTOR_ID_TO_CREDENTIAL_PROVIDER.get(id_base, id_base)
        by_category.setdefault(c.get("category", "AUTRE"), []).append({
            "connectorId": c.get("connectorId"),
            "provider": c.get("provider"),
            "enabled": c.get("enabled", False),
            # "enabled" reste un etat interne (le Capability Matrix /
            # security gate s'en sert pour resoudre l'outil par defaut de
            # certains Workers — voir Resolve-FullAuthorizationChain.ps1 —
            # y toucher a deja casse 13 Workers sur 17 le 2026-09-30).
            # "realIntegration" est la question honnete distincte que se
            # pose un CLIENT : existe-t-il un vrai adaptateur derriere ce
            # connecteur (realAdapter present dans le catalogue), ou est-ce
            # une categorie generique (CRM, Reseaux sociaux, Design,
            # Canva, Monitoring, RH, Analytics) qui ne designe encore aucun
            # produit reel ? Seul ce champ pilote l'affichage cote client.
            "realIntegration": bool(c.get("realAdapter")),
            "operations": c.get("operations", []),
            "activatedByClient": c.get("connectorId") in activated if client_id else None,
            "configuredByClient": cred_key in configured_providers if client_id else None,
            "clientCanConfigure": cred_key in CLIENT_CONNECTOR_PROVIDERS,
            "credentialProvider": cred_key,
            "oauthProvider": next((v for v, cfg in OAUTH_VENDORS.items() if cred_key in cfg["scopes"] and oauth_vendor_ready(v)), None),
            "connectGuide": connect_guides.public_guide(cred_key) if cred_key in CLIENT_CONNECTOR_PROVIDERS else None,
        })
    return {
        "liveExecutionEnabled": data.get("liveExecutionEnabled", False),
        "totalConnectors": len(connectors),
        "enabledConnectors": len([c for c in connectors if c.get("enabled")]),
        # Chiffre honnete affiche au client : combien de connecteurs ont un
        # VRAI adaptateur derriere, pas juste une entree "enabled" dans le
        # catalogue (qui sert aussi de bookkeeping interne, voir plus haut).
        "realConnectorsCount": len([c for c in connectors if c.get("realAdapter")]),
        # Nombre de connecteurs REELLEMENT configures (un vrai secret
        # existe dans .secrets/, pas juste "autorise" dans le catalogue)
        # — c'est ce chiffre-la qui a du sens pour une preuve de
        # confiance publique, pas le total de types supportes.
        "configuredReal": get_configured_connectors_count(),
        "activatedByClientCount": len(activated) if client_id else None,
        "autoApprove": _load_client_autoapprove(client_id) if client_id else None,
        "categories": by_category,
    }


@_state_locked
def toggle_client_connector(client_id, connector_id, enabled):
    data = load_json(CONNECTOR_CATALOG_PATH, {"connectors": []})
    known_ids = {c.get("connectorId") for c in data.get("connectors", [])}
    if connector_id not in known_ids:
        return {"error": "UNKNOWN_CONNECTOR"}
    activated = _load_client_connectors(client_id)
    if enabled:
        activated.add(connector_id)
    else:
        activated.discard(connector_id)
    _save_client_connectors(client_id, activated)
    return get_connector_catalog(client_id)


def get_configured_connectors_count():
    """2026-09-24 : les identifiants vivent desormais par client
    (core/connectors/client-credentials/data/<clientId>/), plus dans
    .secrets/*.dpapi (Windows uniquement, jamais present sur le VPS).
    Ce chiffre public reste celui du compte proprietaire (CLI-DASHBOARD)
    — une preuve de confiance sur ce que la plateforme fait tourner
    reellement, pas un total tous-clients confondus (prive par client)."""
    cred_dir = os.path.join(ROOT, "core", "connectors", "client-credentials", "data", "CLI-DASHBOARD")
    try:
        return len([f for f in os.listdir(cred_dir) if f.endswith(".json")])
    except Exception:
        return 0


# Hypothese de temps manuel evite par mission traitee par un Worker —
# volontairement conservatrice et affichee comme estimation, jamais
# comme un fait mesure (aucun chronometrage reel n'existe cote client).
ESTIMATED_MINUTES_SAVED_PER_MISSION = 12


# Tarifs publics indicatifs (USD par million de tokens : entree, sortie).
# Tarifs API Anthropic de premiere partie + OpenAI (indicatifs, 2026).
# Un modele absent de cette table n'a PAS de cout affiche (jamais devine).
# La table couvre desormais les modeles "forts" (Fable/Opus/Sonnet), pas
# seulement Haiku : basculer un Worker sur un modele fort donne ainsi un
# cout mesure et non "sans prix".
MODEL_PRICING_USD_PER_MTOK = {
    # Anthropic — famille Claude
    "claude-fable-5-1": (10.00, 50.00),
    "claude-fable-5": (10.00, 50.00),
    "claude-opus-5-5": (4.00, 20.00),
    "claude-opus-5": (5.00, 25.00),
    "claude-opus-4-8": (5.00, 25.00),
    "claude-opus-4-7": (5.00, 25.00),
    "claude-opus-4-6": (5.00, 25.00),
    "claude-sonnet-5-5": (2.00, 10.00),
    "claude-sonnet-5": (2.00, 10.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-haiku-5-5": (0.10, 0.50),
    "claude-haiku-4-5": (1.00, 5.00),
    # OpenAI
    "gpt-4o": (2.50, 10.00),
    "gpt-4o-mini": (0.15, 0.60),
}


def price_for_model(model_id):
    """Tarif (entree, sortie) pour un identifiant de modele, tolerant aux
    suffixes de date ('claude-opus-4-8-20260101', 'claude-opus-4-5@20251101')
    et rapproche par famille. Renvoie None si aucun tarif connu."""
    if not model_id:
        return None
    m = str(model_id).strip().lower()
    price = MODEL_PRICING_USD_PER_MTOK.get(m)
    if price:
        return price
    base = re.sub(r"[-@]\d{6,8}$", "", m)
    price = MODEL_PRICING_USD_PER_MTOK.get(base)
    if price:
        return price
    for key in sorted(MODEL_PRICING_USD_PER_MTOK, key=len, reverse=True):
        if base.startswith(key) or m.startswith(key):
            return MODEL_PRICING_USD_PER_MTOK[key]
    return None
AI_PROVIDERS_PATH = os.path.join(ROOT, "core", "ai", "AI-PROVIDERS.json")


def configured_model_for(provider):
    """Modele reellement utilise par defaut par un fournisseur (adaptateurs)."""
    cfg = load_json(AI_PROVIDERS_PATH, {}) or {}
    if provider == "ANTHROPIC":
        return ((cfg.get("providers") or {}).get("anthropic") or {}).get("model") or "claude-haiku-4-5-20251001"
    if provider == "OPENAI":
        return "gpt-4o-mini"
    return None


def get_ai_cost_summary(client_id=DASHBOARD_CLIENT_ID):
    """Tokens reellement consommes (releves dans les reponses des
    fournisseurs) et cout ESTIME au tarif public — pas une facture."""
    input_tokens = output_tokens = missions = 0
    cost_usd = 0.0
    unpriced = 0
    if os.path.isdir(TASKS_DIR):
        for fname in os.listdir(TASKS_DIR):
            if not fname.startswith("TASK-") or not fname.endswith(".json"):
                continue
            data = load_json(os.path.join(TASKS_DIR, fname)) or {}
            if data.get("ClientId") != client_id:
                continue
            res = data.get("Result") or {}
            usage = res.get("Usage") if isinstance(res, dict) else None
            if not usage:
                continue
            i, o = int(usage.get("input_tokens") or 0), int(usage.get("output_tokens") or 0)
            input_tokens += i
            output_tokens += o
            missions += 1
            model_used = res.get("Model") or res.get("model")
            if str(model_used or "").strip().upper() in ("", "NONE"):
                model_used = configured_model_for(res.get("Provider"))
            price = price_for_model(model_used)
            if price:
                cost_usd += (i * price[0] + o * price[1]) / 1_000_000
            else:
                unpriced += 1
    return {
        "aiCalls": missions,
        "inputTokens": input_tokens,
        "outputTokens": output_tokens,
        "estimatedCostUsd": round(cost_usd, 4),
        "avgCostUsdPerCall": round(cost_usd / missions, 4) if missions else 0,
        "callsWithoutPrice": unpriced,
        "note": "Estimation au tarif public du fournisseur (tokens reels releves dans les reponses) — pas une facture.",
    }


def get_analytics(client_id=DASHBOARD_CLIENT_ID):
    """Agrege les VRAIES donnees d'usage (runtime/tasks/, automatisations)
    d'UN client (les autres n'y apparaissent jamais). Rien n'est invente :
    chaque chiffre vient d'un fichier reellement ecrit par le systeme. Le
    seul chiffre "estime" (temps gagne) est explicitement marque comme
    tel, jamais presente comme mesure."""
    by_status = {}
    by_worker = {}
    timeline = {}  # "YYYY-MM-DD" -> count
    total_missions = 0

    if os.path.isdir(TASKS_DIR):
        for fname in os.listdir(TASKS_DIR):
            if not fname.startswith("TASK-") or not fname.endswith(".json"):
                continue
            data = load_json(os.path.join(TASKS_DIR, fname))
            if not data:
                continue
            if data.get("ClientId") != client_id:
                continue
            total_missions += 1
            status = data.get("Status", "INCONNU")
            worker = data.get("Worker", "INCONNU")
            by_status[status] = by_status.get(status, 0) + 1
            by_worker[worker] = by_worker.get(worker, 0) + 1
            created = data.get("CreatedAtUtc", "")
            day = created[:10] if len(created) >= 10 else "inconnu"
            timeline[day] = timeline.get(day, 0) + 1

    # Automatisations : cloisonnees par client comme le reste (2026-09-22).
    # Une automatisation creee avant l'isolation par client n'a pas de
    # champ clientId — elle est traitee comme appartenant a Kader
    # (CLI-DASHBOARD), seul a pouvoir en creer a l'epoque.
    automations = []
    try:
        with open(os.path.join(ROOT, "core", "automation", "data", "automations.json"), encoding="utf-8-sig") as f:
            all_automations = json.load(f) or []
        automations = [a for a in all_automations if (a.get("clientId") or DASHBOARD_CLIENT_ID) == client_id]
    except Exception:
        automations = []

    total_automation_runs = sum(int(a.get("runCount") or 0) for a in automations)
    executed_count = by_status.get("EXECUTED", 0) + by_status.get("SUCCESS", 0)

    return {
        "totalMissions": total_missions,
        "byStatus": by_status,
        "byWorker": by_worker,
        "distinctWorkersUsed": len([w for w in by_worker if w and w != "INCONNU"]),
        "timeline": dict(sorted(timeline.items())),
        "automationsActive": len([a for a in automations if a.get("enabled")]),
        "automationsTotal": len(automations),
        "automationRunsTotal": total_automation_runs,
        "aiCost": get_ai_cost_summary(client_id),
        "estimatedMinutesSaved": executed_count * ESTIMATED_MINUTES_SAVED_PER_MISSION,
        "estimatedMinutesSavedNote": f"Estimation indicative : {ESTIMATED_MINUTES_SAVED_PER_MISSION} min/mission traitee (hypothese conservatrice, non mesuree individuellement).",
    }


# ---------------------------------------------------------------------
# ADMIN (2026-09-23). Vue d'ensemble reservee au proprietaire (Kader,
# via la porte historique _gate_authenticated() — jamais accessible a
# un compte client). Agrege les VRAIS comptes de core/accounts/data/
# accounts.json + le compte historique de Kader lui-meme, avec pour
# chacun ses VRAIES missions/automatisations (get_analytics) et son
# VRAI plan (get_billing) — rien n'est invente ni estime globalement.
# ---------------------------------------------------------------------

def get_admin_activity(limit=80):
    """Flux d'activite reel de TOUTE la plateforme (createur uniquement) :
    inscriptions, connexions, missions, changements d'abonnement."""
    labels = {DASHBOARD_CLIENT_ID: "Kader (propriétaire)"}
    accounts = _load_accounts()
    for acc in accounts:
        labels[acc.get("clientId")] = acc.get("companyName") or acc.get("email") or acc.get("clientId")
    events = []
    for e in (load_json(ACTIVITY_LOG_PATH, []) or []):
        who = e.get("email") or labels.get(e.get("clientId")) or e.get("clientId")
        if e.get("kind") == "signup":
            events.append({"atUtc": e["atUtc"], "kind": "signup", "who": who, "text": "Nouvelle inscription" + (f" — {e['companyName']}" if e.get("companyName") else "")})
        elif e.get("kind") == "demo":
            events.append({"atUtc": e["atUtc"], "kind": "demo", "who": e.get("email") or e.get("name"), "text": "Demande de démo — " + (e.get("name") or "") + (f" ({e['company']})" if e.get("company") else "")})
        elif e.get("kind") == "login":
            events.append({"atUtc": e["atUtc"], "kind": "login", "who": who, "text": "Connexion" + (f" ({e['ip']})" if e.get("ip") else "")})
    # comptes anterieurs au journal : leur inscription reste visible
    logged_signups = {e.get("clientId") for e in (load_json(ACTIVITY_LOG_PATH, []) or []) if e.get("kind") == "signup"}
    for acc in accounts:
        if acc.get("clientId") not in logged_signups and acc.get("createdAtUtc"):
            events.append({"atUtc": acc["createdAtUtc"], "kind": "signup", "who": acc.get("email") or acc.get("clientId"), "text": "Inscription" + (f" — {acc['companyName']}" if acc.get("companyName") else "")})
    if os.path.isdir(TASKS_DIR):
        for fname in os.listdir(TASKS_DIR):
            if not fname.startswith("TASK-") or not fname.endswith(".json"):
                continue
            data = load_json(os.path.join(TASKS_DIR, fname))
            if not data or not data.get("CreatedAtUtc"):
                continue
            cid = data.get("ClientId")
            events.append({"atUtc": data["CreatedAtUtc"], "kind": "mission", "who": labels.get(cid) or cid,
                           "text": f"Mission → {data.get('Worker')} : " + str(data.get("Request") or "")[:90]})
    for cid in list(labels.keys()):
        try:
            state = _billing_load(cid)
        except Exception:
            continue
        for h in state.get("history", []):
            ev = str(h.get("event") or "")
            if ev.startswith("Changement de plan") or "abonnement" in ev.lower():
                events.append({"atUtc": h.get("dateUtc"), "kind": "plan", "who": labels.get(cid) or cid, "text": ev})
    events = [e for e in events if e.get("atUtc")]
    events.sort(key=lambda e: e["atUtc"], reverse=True)
    now = datetime.datetime.utcnow()
    def within_day(e):
        try:
            return (now - datetime.datetime.fromisoformat(e["atUtc"].replace("Z", "").split("+")[0])).total_seconds() < 86400
        except Exception:
            return False
    day = [e for e in events if within_day(e)]
    return {
        "events": events[:limit],
        "last24h": {
            "signups": sum(1 for e in day if e["kind"] == "signup"),
            "logins": sum(1 for e in day if e["kind"] == "login"),
            "missions": sum(1 for e in day if e["kind"] == "mission"),
            "planChanges": sum(1 for e in day if e["kind"] == "plan"),
            "demos": sum(1 for e in day if e["kind"] == "demo"),
        },
    }


# ---------------------------------------------------------------------
# Demandes de demo (2026-09-25) : formulaire public "Reserver une demo",
# meme principe que chez Limova (un formulaire, pas d'agenda tiers).
# Stockees dans core/accounts/data/demo-requests.json, visibles par le
# proprietaire dans le tableau de bord admin.
# ---------------------------------------------------------------------
DEMO_REQUESTS_PATH = os.path.join(ROOT, "core", "accounts", "data", "demo-requests.json")
DEMO_RATE = {}  # ip -> [timestamps]
DEMO_MAX_PER_IP_PER_HOUR = 4
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$")


@_state_locked
def submit_demo_request(body, ip):
    if (body.get("website") or "").strip():
        return {"ok": True}, 200  # champ piege rempli : robot, on fait semblant
    name = (body.get("name") or "").strip()[:120]
    email = (body.get("email") or "").strip()[:200]
    if len(name) < 2:
        return {"error": "NAME_REQUIRED"}, 400
    if not _EMAIL_RE.match(email):
        return {"error": "EMAIL_INVALID"}, 400
    now = time.time()
    recent = [t for t in DEMO_RATE.get(ip, []) if now - t < 3600]
    if len(recent) >= DEMO_MAX_PER_IP_PER_HOUR:
        return {"error": "RATE_LIMITED"}, 429
    DEMO_RATE[ip] = recent + [now]
    rec = {
        "id": "DEMO-" + secrets.token_hex(4).upper(),
        "atUtc": datetime.datetime.utcnow().isoformat() + "Z",
        "name": name,
        "email": email,
        "company": (body.get("company") or "").strip()[:160],
        "phone": (body.get("phone") or "").strip()[:40],
        "slot": (body.get("slot") or "").strip()[:60],
        "timezone": (body.get("timezone") or "").strip()[:60],
        "lang": (body.get("lang") or "").strip()[:12],
        "message": (body.get("message") or "").strip()[:1500],
        "status": "new",
    }
    rows = load_json(DEMO_REQUESTS_PATH, []) or []
    rows.append(rec)
    os.makedirs(os.path.dirname(DEMO_REQUESTS_PATH), exist_ok=True)
    _write_json_atomic(DEMO_REQUESTS_PATH, rows[-500:], ensure_ascii=False)
    log_activity("demo", email=email, name=name, company=rec["company"])
    return {"ok": True, "id": rec["id"]}, 200


def get_demo_requests():
    rows = load_json(DEMO_REQUESTS_PATH, []) or []
    return {"requests": list(reversed(rows))[:200]}


# ---------------------------------------------------------------------
# Canal WhatsApp (voir whatsapp_channel.py)
# ---------------------------------------------------------------------
import whatsapp_channel as wa

WA_STORE = wa.Store(os.path.join(ROOT, "core", "accounts", "data", "whatsapp-links.json"), lambda p, d=None: load_json(p, d))


def _wa_deps():
    return {"submit_task": submit_task, "attach_pending_action": attach_pending_action,
            "subscription_blocks_mission": subscription_blocks_mission, "log_activity": log_activity}


def whatsapp_status(client_id):
    phone = WA_STORE.phone_for(client_id)
    return {"enabled": wa.is_enabled(), "linked": bool(phone),
            "phone": wa.mask_phone(phone) if phone else None, "number": wa.display_number()}


# ---------------------------------------------------------------------
# Securite des comptes (2026-09-26) : anti force-brute, mot de passe
# oublie (email), export et suppression de compte (droit d'acces /
# d'effacement, nLPD/RGPD).
# ---------------------------------------------------------------------
import shutil
import mailer

MAILER_SCRIPT = os.path.join(DASHBOARD_DIR, "Mailer-Bridge.ps1")
AUTH_FAILS = {}      # cle -> [timestamps]
AUTH_WINDOW = 15 * 60
AUTH_MAX_PER_ACCOUNT = 8
AUTH_MAX_PER_IP = 40
# Porte proprietaire ("Acces administrateur") : comptee comme un compte a part,
# donc 8 echecs / 15 min par adresse IP, comme la connexion client.
OWNER_GATE_THROTTLE_KEY = "__owner_gate__"
SIGNUP_RATE = {}     # ip -> [timestamps]
SIGNUP_MAX_PER_IP_PER_HOUR = 10
RESET_RATE = {}      # cle -> [timestamps]
RESET_TTL_SECONDS = 3600
RESET_PATH = os.path.join(ROOT, "core", "accounts", "data", "password-resets.json")
CLIENT_ID_RE = re.compile(r"^CLI-CUST-[A-F0-9]{8}$")


def run_mailer_bridge(payload):
    import tempfile, uuid
    in_file = os.path.join(tempfile.gettempdir(), f"bkaiw-mail-in-{uuid.uuid4().hex}.json")
    out_file = os.path.join(tempfile.gettempdir(), f"bkaiw-mail-out-{uuid.uuid4().hex}.json")
    try:
        with open(in_file, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
        subprocess.run([*PS_CMD, "-File", MAILER_SCRIPT, "-InFile", in_file, "-OutFile", out_file],
                       capture_output=True, timeout=60)
        if os.path.isfile(out_file):
            with open(out_file, encoding="utf-8-sig") as f:
                return json.load(f)
        return {"ok": False, "error": "BRIDGE_FAILED"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "MAIL_TIMEOUT"}
    finally:
        for p in (in_file, out_file):
            try:
                os.remove(p)
            except OSError:
                pass


import phone_agent


def _notify_owner_email(to, subject, html_body, text):
    ok, err = mailer.send_email(to, subject, html_body, text, gmail_bridge=run_mailer_bridge)
    print("[phone] email au proprietaire : " + ("envoye" if ok else f"ECHEC ({err})"), flush=True)


PHONE_AGENT = phone_agent.PhoneAgent(ROOT, PS_CMD, notify=_notify_owner_email)
# warm_up() (lecture du jeton Twilio par PowerShell + purge des transcriptions) ne se lance que dans le
# vrai serveur (bloc __main__) : dashboard/quota-check.py fait `import server` a chaque passage d'une
# automatisation et ne doit pas declencher de PowerShell a chaque import.

# Programme pilote (dashboard/pilot_program.py) : candidatures de premiers clients reels. Meme chemin d'email
# que le standard telephonique (mailer.send_email -> SMTP dedie ou pont Gmail) ; ecriture sous _STATE_LOCK.
import pilot_program


def _notify_pilot_email(to, subject, html_body, text):
    ok, err = mailer.send_email(to, subject, html_body, text, gmail_bridge=run_mailer_bridge)
    print("[pilot] email au proprietaire : " + ("envoye" if ok else f"ECHEC ({err})"), flush=True)


PILOT = pilot_program.PilotService(ROOT, PUBLIC_BASE_URL, lock=_STATE_LOCK, write_json=_write_json_atomic,
                                   notify=_notify_pilot_email)


def _recent(bucket, key, window):
    now = time.time()
    rows = [t for t in bucket.get(key, []) if now - t < window]
    bucket[key] = rows
    return rows


def auth_throttled(ip, email):
    email = (email or "").strip().lower()
    return (len(_recent(AUTH_FAILS, f"a|{ip}|{email}", AUTH_WINDOW)) >= AUTH_MAX_PER_ACCOUNT
            or len(_recent(AUTH_FAILS, f"i|{ip}", AUTH_WINDOW)) >= AUTH_MAX_PER_IP)


def auth_record_fail(ip, email):
    email = (email or "").strip().lower()
    for key in (f"a|{ip}|{email}", f"i|{ip}"):
        AUTH_FAILS.setdefault(key, []).append(time.time())


def auth_clear(ip, email):
    AUTH_FAILS.pop(f"a|{ip}|{(email or '').strip().lower()}", None)


def signup_rate_ok(ip):
    rows = _recent(SIGNUP_RATE, ip, 3600)
    if len(rows) >= SIGNUP_MAX_PER_IP_PER_HOUR:
        return False
    SIGNUP_RATE[ip] = rows + [time.time()]
    return True


def account_clear_all_sessions(client_id):
    for k in [k for k, v in ACCOUNT_SESSIONS.items() if v.get("clientId") == client_id]:
        ACCOUNT_SESSIONS.pop(k, None)
    _persist_sessions()


def _reset_read():
    now = time.time()
    return {k: v for k, v in (load_json(RESET_PATH, {}) or {}).items() if v.get("expiry", 0) > now}


def _reset_write(data):
    os.makedirs(os.path.dirname(RESET_PATH), exist_ok=True)
    _write_json_atomic(RESET_PATH, data)


@_state_locked
def request_password_reset(email, ip):
    """Reponse identique que le compte existe ou non (pas d'enumeration).
    L'envoi se fait en arriere-plan pour ne pas trahir l'existence par le delai."""
    email = (email or "").strip().lower()
    if not mailer.is_valid_address(email):
        print("[forgot] ignored: invalid address", flush=True)
        return
    if len(_recent(RESET_RATE, f"i|{ip}", 3600)) >= 6 or len(_recent(RESET_RATE, f"e|{email}", 3600)) >= 3:
        print("[forgot] ignored: rate limited", flush=True)
        return
    RESET_RATE.setdefault(f"i|{ip}", []).append(time.time())
    RESET_RATE.setdefault(f"e|{email}", []).append(time.time())
    account = _find_account_by_email(email)
    print(f"[forgot] request accepted, account_found={bool(account)}", flush=True)
    if not account:
        return
    token = secrets.token_urlsafe(32)
    data = _reset_read()
    data = {k: v for k, v in data.items() if v.get("clientId") != account["clientId"]}
    data[_session_key(token)] = {"clientId": account["clientId"], "expiry": time.time() + RESET_TTL_SECONDS}
    _reset_write(data)
    link = f"{PUBLIC_BASE_URL}/?reset={token}"
    html = mailer.brand_email(
        "Réinitialiser votre mot de passe",
        "<p>Vous avez demandé à réinitialiser le mot de passe de votre compte BK-AI-WORKERS. "
        "Ce lien est valable 1 heure et ne fonctionne qu'une fois.</p>"
        "<p style=\"color:#5a5d66\">You asked to reset your BK-AI-WORKERS password. This link is valid for 1 hour and can be used once.</p>",
        "Choisir un nouveau mot de passe", link,
        "Vous n'êtes pas à l'origine de cette demande ? Ignorez cet email : votre mot de passe reste inchangé.<br>"
        "Didn't ask for this? Ignore this email — your password stays the same.")
    def _send():
        ok, err = mailer.send_email(email, "Réinitialiser votre mot de passe / Reset your password", html,
                                    gmail_bridge=run_mailer_bridge)
        log_activity("mail", template="password_reset", ok=bool(ok), error=err, clientId=account["clientId"])
        print(f"[mail] password_reset ok={ok} error={err}", flush=True)
    threading.Thread(target=_send, daemon=True).start()


@_state_locked
def reset_password_with_token(token, new_password):
    if len(new_password or "") < 8:
        return "PASSWORD_TOO_SHORT"
    data = _reset_read()
    entry = data.pop(_session_key(token or ""), None)
    _reset_write(data)
    if not entry:
        return "RESET_LINK_INVALID"
    accounts = _load_accounts()
    for acc in accounts:
        if acc.get("clientId") == entry["clientId"]:
            acc["passwordHash"] = _hash_password(new_password)
            _save_accounts(accounts)
            account_clear_all_sessions(acc["clientId"])
            log_activity("password_reset", clientId=acc["clientId"], email=acc.get("email"))
            return None
    return "RESET_LINK_INVALID"


def export_account_data(client_id):
    acc = next((a for a in _load_accounts() if a.get("clientId") == client_id), None) or {}
    providers = []
    cdir = os.path.join(CLIENT_CREDENTIALS_DIR, client_id)
    if os.path.isdir(cdir):
        providers = sorted(f[:-5] for f in os.listdir(cdir) if f.endswith(".json"))
    all_auto = []
    try:
        with open(os.path.join(ROOT, "core", "automation", "data", "automations.json"), encoding="utf-8-sig") as f:
            all_auto = [a for a in (json.load(f) or []) if a.get("clientId") == client_id]
    except Exception:
        pass
    wa = WA_STORE.phone_for(client_id)
    return {
        "exportedAtUtc": datetime.datetime.utcnow().isoformat() + "Z",
        "account": {k: v for k, v in acc.items() if k != "passwordHash"},
        "companyProfile": get_company_profile(client_id),
        "billing": _billing_load(client_id),
        "missions": get_client_missions(client_id, limit=1000),
        "automations": all_auto,
        "connectedTools": providers,
        "whatsappLinked": bool(wa),
        "note": "Les jetons et identifiants de vos outils connectés sont chiffrés et ne sont pas exportés.",
    }


TASK_FILES_KEEP_DAYS = 30


def purge_old_task_files(now=None):
    """Les fichiers generes par les Workers sont gardes TASK_FILES_KEEP_DAYS jours (puis supprimes) : disque partage."""
    now = now if now is not None else time.time()
    try:
        names = os.listdir(TASK_FILES_DIR)
    except OSError:
        return 0
    removed = 0
    for name in names:
        p = os.path.join(TASK_FILES_DIR, name)
        try:
            if os.path.isdir(p) and now - os.path.getmtime(p) > TASK_FILES_KEEP_DAYS * 86400:
                shutil.rmtree(p, ignore_errors=True)
                removed += 1
        except OSError:
            continue
    return removed


def _purge_client_mission_artifacts(client_id, task_ids):
    """Suppression de compte : fichiers generes, jobs en arriere-plan et actions en attente du client."""
    for tid in task_ids:
        if TASK_ID_PATTERN.match(tid or ""):
            shutil.rmtree(os.path.join(TASK_FILES_DIR, tid), ignore_errors=True)
            try:
                os.remove(_pending_action_path(tid))
            except OSError:
                pass
    try:
        for name in os.listdir(ASYNC_JOBS_DIR):
            if not name.endswith(".json"):
                continue
            p = os.path.join(ASYNC_JOBS_DIR, name)
            job = load_json(p)
            if isinstance(job, dict) and job.get("clientId") == client_id:
                try:
                    os.remove(p)
                except OSError:
                    pass
    except OSError:
        pass


@_state_locked
def delete_account(client_id, password):
    if not CLIENT_ID_RE.match(client_id or ""):
        return "NOT_ALLOWED"
    accounts = _load_accounts()
    acc = next((a for a in accounts if a.get("clientId") == client_id), None)
    if not acc or not _verify_password(password or "", acc.get("passwordHash", "")):
        return "INVALID_PASSWORD"
    if (_billing_load(client_id) or {}).get("stripeSubscriptionId"):
        return "ACTIVE_SUBSCRIPTION"
    _save_accounts([a for a in accounts if a.get("clientId") != client_id])
    account_clear_all_sessions(client_id)
    WA_STORE.unlink_client(client_id)
    cdir = os.path.join(CLIENT_CREDENTIALS_DIR, client_id)
    if os.path.isdir(cdir):
        shutil.rmtree(cdir, ignore_errors=True)
    try:
        path = os.path.join(ROOT, "core", "automation", "data", "automations.json")
        with open(path, encoding="utf-8-sig") as f:
            autos = json.load(f) or []
        _write_json_atomic(path, [a for a in autos if a.get("clientId") != client_id], ensure_ascii=False, indent=2)
    except Exception:
        pass
    try:
        os.remove(os.path.join(PROFILE_DIR, f"{client_id}.json"))
    except OSError:
        pass
    _remove_client_apikey(client_id)
    _remove_client_webhook(client_id)
    deleted_task_ids = []
    if os.path.isdir(TASKS_DIR):
        for fname in os.listdir(TASKS_DIR):
            if fname.startswith("TASK-") and fname.endswith(".json"):
                p = os.path.join(TASKS_DIR, fname)
                data = load_json(p)
                if data and data.get("ClientId") == client_id:
                    deleted_task_ids.append(fname[:-5])
                    try:
                        os.remove(p)
                    except OSError:
                        pass
    _purge_client_mission_artifacts(client_id, deleted_task_ids)
    log_activity("account_deleted", clientId=client_id)
    return None


SITEMAP_PATHS = ['/', '/workers.html', '/tarifs.html', '/faq.html', '/chloe.html', '/demarrer.html', '/automatisations.html', '/analytics.html', '/facturation.html', '/cgv.html', '/mentions-legales.html', '/cookies.html', '/confidentialite.html']
# Pages de confiance + mesure de disponibilite (dashboard/trust_pages.py, status_monitor.py).
SITEMAP_PATHS.extend(p for p in trust_pages.SITEMAP_PATHS if p not in SITEMAP_PATHS)
TRUST = trust_pages.TrustService(ROOT, PUBLIC_BASE_URL)

# ---------------------------------------------------------------------
# Temoignages clients (2026-09-26) : AUCUN avis n'est invente. Seul le
# proprietaire peut en ajouter, et uniquement en confirmant qu'il a l'accord
# de la personne pour publier. La section n'apparait sur le site que
# lorsqu'au moins un temoignage existe.
# ---------------------------------------------------------------------
TESTIMONIALS_PATH = os.path.join(ROOT, "core", "accounts", "data", "testimonials.json")


def get_testimonials():
    return [t for t in (load_json(TESTIMONIALS_PATH, []) or []) if isinstance(t, dict)]


def public_testimonials():
    return [{"id": t["id"], "name": t.get("name", ""), "role": t.get("role", ""), "company": t.get("company", ""),
             "text": t.get("text", ""), "rating": t.get("rating")} for t in get_testimonials()]


@_state_locked
def add_testimonial(body):
    name = str(body.get("name") or "").strip()[:80]
    text = str(body.get("text") or "").strip()
    if len(name) < 2:
        return None, "NAME_REQUIRED"
    if not 20 <= len(text) <= 600:
        return None, "TEXT_LENGTH"
    if body.get("consent") is not True:
        return None, "CONSENT_REQUIRED"
    rating = body.get("rating")
    rating = int(rating) if str(rating).isdigit() and 1 <= int(rating) <= 5 else None
    rec = {"id": "TSM-" + secrets.token_hex(4).upper(), "name": name, "role": str(body.get("role") or "").strip()[:80],
           "company": str(body.get("company") or "").strip()[:80], "text": text, "rating": rating,
           "consentConfirmedAtUtc": datetime.datetime.utcnow().isoformat() + "Z"}
    rows = get_testimonials() + [rec]
    os.makedirs(os.path.dirname(TESTIMONIALS_PATH), exist_ok=True)
    _write_json_atomic(TESTIMONIALS_PATH, rows[-60:], ensure_ascii=False, indent=2)
    return rec, None


@_state_locked
def delete_testimonial(tid):
    rows = get_testimonials()
    kept = [t for t in rows if t.get("id") != tid]
    if len(kept) == len(rows):
        return False
    _write_json_atomic(TESTIMONIALS_PATH, kept, ensure_ascii=False, indent=2)
    return True


# ---------------------------------------------------------------------
# Verification de l'email (2026-09-26) : email de bienvenue avec lien de
# confirmation (valable 7 jours). Les comptes anterieurs sont consideres
# comme verifies. Un compte non verifie peut utiliser l'essai mais ne peut
# pas souscrire un plan payant (evite les fautes de frappe et les faux comptes).
# ---------------------------------------------------------------------
VERIFY_PATH = os.path.join(ROOT, "core", "accounts", "data", "email-verifications.json")
VERIFY_TTL_SECONDS = 7 * 24 * 3600
VERIFY_RATE = {}


def account_email_verified(client_id):
    acc = next((a for a in _load_accounts() if a.get("clientId") == client_id), None)
    return True if acc is None else bool(acc.get("emailVerified", True))


def _verify_read():
    now = time.time()
    return {k: v for k, v in (load_json(VERIFY_PATH, {}) or {}).items() if v.get("expiry", 0) > now}


def _verify_write(data):
    os.makedirs(os.path.dirname(VERIFY_PATH), exist_ok=True)
    _write_json_atomic(VERIFY_PATH, data)


@_state_locked
def send_verification_email(account, force=False):
    """Envoie (en arriere-plan) le lien de confirmation. Renvoie False si limite atteinte."""
    email = account.get("email", "")
    if not mailer.is_valid_address(email):
        return False
    if not force and len(_recent(VERIFY_RATE, account["clientId"], 3600)) >= 3:
        return False
    VERIFY_RATE.setdefault(account["clientId"], []).append(time.time())
    token = secrets.token_urlsafe(32)
    data = {k: v for k, v in _verify_read().items() if v.get("clientId") != account["clientId"]}
    data[_session_key(token)] = {"clientId": account["clientId"], "expiry": time.time() + VERIFY_TTL_SECONDS}
    _verify_write(data)
    link = f"{PUBLIC_BASE_URL}/api/account/verify?token={token}"
    html = mailer.brand_email(
        "Bienvenue sur BK-AI-WORKERS — confirmez votre email",
        "<p>Votre compte est créé. Confirmez votre adresse email pour pouvoir souscrire un plan et recevoir "
        "les messages importants (réinitialisation de mot de passe…). Ce lien est valable 7 jours.</p>"
        "<p style=\"color:#5a5d66\">Your account is ready. Please confirm your email address so you can subscribe to a plan "
        "and receive important messages. This link is valid for 7 days.</p>",
        "Confirmer mon email / Confirm my email", link,
        "Vous n'avez pas créé ce compte ? Ignorez cet email. / Didn't create this account? Just ignore this email.")

    def _send():
        ok, err = mailer.send_email(email, "Confirmez votre email / Confirm your email — BK-AI-WORKERS", html,
                                    gmail_bridge=run_mailer_bridge)
        log_activity("mail", template="verify_email", ok=bool(ok), error=err, clientId=account["clientId"])
        print(f"[mail] verify_email ok={ok} error={err}", flush=True)
    threading.Thread(target=_send, daemon=True).start()
    return True


@_state_locked
def verify_email_token(token):
    data = _verify_read()
    entry = data.pop(_session_key(token or ""), None)
    _verify_write(data)
    if not entry:
        return False
    accounts = _load_accounts()
    for acc in accounts:
        if acc.get("clientId") == entry["clientId"]:
            acc["emailVerified"] = True
            _save_accounts(accounts)
            log_activity("email_verified", clientId=acc["clientId"], email=acc.get("email"))
            return True
    return False


FX_CACHE = {"at": 0, "data": None}
# Repli si le service de taux est injoignable : ordres de grandeur pour
# 1 CHF (affichage indicatif uniquement, jamais utilise pour facturer).
FX_FALLBACK = {"CHF": 1.0, "EUR": 1.06, "USD": 1.16, "GBP": 0.91, "CAD": 1.60, "AUD": 1.78,
               "JPY": 168.0, "CNY": 8.3, "INR": 97.0, "BRL": 6.5, "MXN": 22.0, "SEK": 11.9,
               "NOK": 12.3, "DKK": 7.9, "PLN": 4.6, "CZK": 26.5, "HUF": 420.0, "TRY": 40.0,
               "ZAR": 21.0, "SGD": 1.5, "HKD": 9.0, "KRW": 1600.0, "NZD": 1.95}


def get_fx_rates():
    """Taux de change depuis le CHF (devise de facturation), pour afficher
    les prix dans la devise du visiteur (2026-09-25). Source : BCE via
    frankfurter.dev (gratuit, sans cle), mis en cache 12 h ; repli statique."""
    import time, urllib.request
    now = time.time()
    if FX_CACHE["data"] and now - FX_CACHE["at"] < 12 * 3600:
        return FX_CACHE["data"]
    try:
        req = urllib.request.Request("https://api.frankfurter.dev/v1/latest?base=CHF",
                                     headers={"User-Agent": "BK-AI-WORKERS/1.0 (+https://bk-ai-workers.com)"})
        with urllib.request.urlopen(req, timeout=6) as r:
            j = json.loads(r.read().decode("utf-8"))
        rates = dict(j.get("rates") or {})
        rates["CHF"] = 1.0
        data = {"base": "CHF", "rates": rates, "asOf": j.get("date"), "source": "ECB"}
        FX_CACHE.update({"at": now, "data": data})
        return data
    except Exception:
        return {"base": "CHF", "rates": FX_FALLBACK, "asOf": None, "source": "fallback"}


def get_client_missions(client_id, limit=25):
    """Comme get_worker_activity, mais toutes missions d'un client tous
    Workers confondus (y compris Chloe) — utilise par le detail admin
    quand Kader clique sur un compte pour voir ses vraies missions."""
    records = []
    if os.path.isdir(TASKS_DIR):
        for fname in os.listdir(TASKS_DIR):
            if not fname.startswith("TASK-") or not fname.endswith(".json"):
                continue
            data = load_json(os.path.join(TASKS_DIR, fname))
            if not data or data.get("ClientId") != client_id:
                continue
            records.append({
                "taskId": data.get("TaskId"),
                "worker": data.get("Worker"),
                "request": data.get("Request"),
                "status": data.get("Status"),
                "authorized": data.get("Authorized"),
                "createdAtUtc": data.get("CreatedAtUtc"),
                "answer": (data.get("Result") or {}).get("Answer"),
                "executionNote": data.get("ExecutionNote"),
            })
    records.sort(key=lambda r: r.get("createdAtUtc") or "", reverse=True)
    return records[:limit]


def get_admin_overview():
    clients = [{
        "clientId": DASHBOARD_CLIENT_ID,
        "label": "Kader (compte propriétaire)",
        "email": None,
        "companyName": None,
        "createdAtUtc": None,
        "isOwner": True,
    }]
    for acc in _load_accounts():
        clients.append({
            "clientId": acc.get("clientId"),
            "label": acc.get("companyName") or acc.get("email") or acc.get("clientId"),
            "email": acc.get("email"),
            "companyName": acc.get("companyName"),
            "createdAtUtc": acc.get("createdAtUtc"),
            "isOwner": False,
        })

    rows = []
    total_missions = 0
    total_automations_active = 0
    for c in clients:
        analytics = get_analytics(c["clientId"])
        billing = get_billing(c["clientId"])
        total_missions += analytics["totalMissions"]
        total_automations_active += analytics["automationsActive"]
        rows.append({
            **c,
            "totalMissions": analytics["totalMissions"],
            "distinctWorkersUsed": analytics["distinctWorkersUsed"],
            "automationsActive": analytics["automationsActive"],
            "planId": billing["planId"],
            "planName": billing["planName"],
            "creditsUsed": billing["creditsUsed"],
            # Le proprietaire n'est jamais soumis a un quota (voir
            # subscription_blocks_mission, bypass CLI-DASHBOARD) : le
            # plan Essai stocke encore un creditsTotal residuel, mais
            # l'afficher ici induirait Kader en erreur sur sa propre
            # limite reelle (aucune) — on le masque a la source.
            "creditsTotal": None if c["isOwner"] else billing["creditsTotal"],
        })

    rows.sort(key=lambda r: r["totalMissions"], reverse=True)

    return {
        "totalClients": len(clients),
        "totalRealClients": len(clients) - 1,  # hors compte proprietaire
        "totalMissionsAllClients": total_missions,
        "totalAutomationsActiveAllClients": total_automations_active,
        "clients": rows,
    }


# ---------------------------------------------------------------------
# BILLING (socle reel : plan actif + quota + historique, persiste sur
# disque). Deux modes selon que Stripe est configure ou non (voir
# Stripe-Bridge.ps1 / PAID_PLANS_WITH_CHECKOUT) :
#   - Stripe configure : un changement vers un plan payant cree une
#     VRAIE Checkout Session Stripe (paiement heberge par Stripe) et
#     le plan local n'est active qu'APRES verification serveur du
#     paiement (/api/billing/stripe-confirm). Rien n'est jamais debite
#     par ce fichier lui-meme.
#   - Stripe non configure : comportement de simulation locale d'origine
#     (bascule instantanee, aucun paiement, clairement etiquete comme
#     tel dans l'historique) — utile pour tester le parcours avant de
#     brancher un vrai PSP.
# ---------------------------------------------------------------------

# Un fichier de facturation par ClientId (comme le profil d'entreprise) —
# avant le 2026-09-22 il n'y avait qu'un seul fichier partage (le compte
# de Kader). BILLING_DATA_LEGACY_PATH sert a migrer son historique dans
# son propre fichier par ClientId la premiere fois, sans rien perdre.
BILLING_DATA_DIR = os.path.join(ROOT, "core", "billing", "data")
BILLING_DATA_LEGACY_PATH = os.path.join(BILLING_DATA_DIR, "subscription.json")


def _billing_path(client_id):
    return os.path.join(BILLING_DATA_DIR, f"{client_id}.json")

# Quota de missions inclus par cycle, par plan (1 mission traitee = 1
# credit consomme). Purement indicatif tant qu'aucun PSP n'est branche.
PLAN_CATALOG = {
    "essai":      {"name": "Essai",      "credits": 15},
    "starter":    {"name": "Starter",    "credits": 150},
    "business":   {"name": "Business",   "credits": 600},
    "pro":        {"name": "Pro",        "credits": 1500},
    "scale":      {"name": "Scale",      "credits": 4000},
    "enterprise": {"name": "Enterprise", "credits": None},  # illimite, sur devis
}

# Plans qui passent par une vraie Checkout Session Stripe quand Stripe
# est configure (Essai = gratuit, Enterprise = sur devis -> jamais de
# checkout self-service pour ces deux-la).
PAID_PLANS_WITH_CHECKOUT = {"starter", "business", "pro", "scale"}


def _billing_default_state():
    now = datetime.datetime.utcnow().isoformat() + "Z"
    return {
        "planId": "essai",
        "cycleStartUtc": now,
        "extraCredits": 0,
        "history": [
            {"dateUtc": now, "event": "Compte cree — plan Essai (3 jours, gratuit, sans carte)."},
        ],
    }


@_state_locked
def _billing_load(client_id=DASHBOARD_CLIENT_ID):
    path = _billing_path(client_id)
    state = load_json(path)
    if not state and client_id == DASHBOARD_CLIENT_ID and os.path.isfile(BILLING_DATA_LEGACY_PATH):
        # Migration one-shot : l'historique/plan de Kader vivait dans
        # l'unique fichier partage d'avant les comptes clients.
        state = load_json(BILLING_DATA_LEGACY_PATH)
    if not state or "planId" not in state:
        state = _billing_default_state()
        _billing_save(state, client_id)
    return state


def _billing_save(state, client_id=DASHBOARD_CLIENT_ID):
    os.makedirs(BILLING_DATA_DIR, exist_ok=True)
    _write_json_atomic(_billing_path(client_id), state, ensure_ascii=False, indent=2)


def get_billing(client_id=DASHBOARD_CLIENT_ID):
    state = _billing_load(client_id)
    plan_id = state.get("planId", "essai")
    plan = PLAN_CATALOG.get(plan_id, PLAN_CATALOG["essai"])
    cycle_start = state.get("cycleStartUtc", "")

    used = 0
    if os.path.isdir(TASKS_DIR):
        for fname in os.listdir(TASKS_DIR):
            if not fname.startswith("TASK-") or not fname.endswith(".json"):
                continue
            data = load_json(os.path.join(TASKS_DIR, fname))
            if not data:
                continue
            # Chaque client ne consomme que ses propres credits — sans ce
            # filtre, les missions de tous les clients se melangeaient.
            if data.get("ClientId") != client_id:
                continue
            created = data.get("CreatedAtUtc", "")
            if cycle_start and created and created < cycle_start:
                continue
            used += 1

    base_credits = plan["credits"]
    extra = int(state.get("extraCredits") or 0)
    total_credits = None if base_credits is None else base_credits + extra
    remaining = None if total_credits is None else max(0, total_credits - used)
    percent_used = None if total_credits in (None, 0) else round((used / total_credits) * 100)

    return {
        "planId": plan_id,
        "planName": plan["name"],
        "cycleStartUtc": cycle_start,
        "creditsTotal": total_credits,
        "creditsUsed": used,
        "creditsRemaining": remaining,
        "percentUsed": percent_used,
        "alertThresholdReached": percent_used is not None and percent_used >= 80,
        "unlimited": total_credits is None,
        "history": list(reversed(state.get("history", [])))[:20],
        "availablePlans": [{"planId": pid, "name": p["name"], "credits": p["credits"]} for pid, p in PLAN_CATALOG.items()],
    }


@_state_locked
def set_billing_plan(plan_id, via_stripe=False, stripe_subscription_id=None, client_id=DASHBOARD_CLIENT_ID):
    if plan_id not in PLAN_CATALOG:
        return {"error": "UNKNOWN_PLAN"}
    state = _billing_load(client_id)
    old_name = PLAN_CATALOG.get(state.get("planId", "essai"), PLAN_CATALOG["essai"])["name"]
    new_name = PLAN_CATALOG[plan_id]["name"]
    now = datetime.datetime.utcnow().isoformat() + "Z"
    state["planId"] = plan_id
    state["cycleStartUtc"] = now
    state["extraCredits"] = 0
    # Un changement simule (ou vers Essai/Enterprise) n'a pas de vrai
    # abonnement Stripe derriere : on efface toute reference precedente
    # pour ne jamais tenter d'annuler un abonnement qui n'est plus le
    # plan actif.
    state["stripeSubscriptionId"] = stripe_subscription_id if via_stripe else None
    label = "paiement Stripe confirme" if via_stripe else "simulation, aucun paiement reel"
    state.setdefault("history", []).append({
        "dateUtc": now,
        "event": f"Changement de plan : {old_name} -> {new_name} ({label}).",
    })
    _billing_save(state, client_id)
    return get_billing(client_id)


def cancel_billing_plan(client_id=DASHBOARD_CLIENT_ID):
    # L'annulation Stripe (appel reseau de plusieurs secondes) se fait HORS
    # du verrou ; seule la mise a jour du fichier de facturation est verrouillee.
    subscription_id = _billing_load(client_id).get("stripeSubscriptionId")
    label = "simulation, aucun paiement reel"
    if subscription_id:
        # Un vrai abonnement Stripe est derriere ce plan : "annuler"
        # doit reellement l'annuler cote Stripe, pas seulement basculer
        # l'affichage local — sinon Stripe continuerait a le renouveler.
        cancellation = run_stripe_bridge("cancel-subscription", subscription_id=subscription_id)
        if cancellation.get("Status") == "SUCCESS":
            label = "abonnement Stripe reellement annule"
        else:
            label = f"ECHEC annulation Stripe ({cancellation.get('Detail') or cancellation.get('Status')}) — verifier manuellement dans le dashboard Stripe"

    with _STATE_LOCK:
        state = _billing_load(client_id)
        old_name = PLAN_CATALOG.get(state.get("planId", "essai"), PLAN_CATALOG["essai"])["name"]
        now = datetime.datetime.utcnow().isoformat() + "Z"
        state["planId"] = "essai"
        state["cycleStartUtc"] = now
        state["extraCredits"] = 0
        state["stripeSubscriptionId"] = None
        state.setdefault("history", []).append({
            "dateUtc": now,
            "event": f"Abonnement annule ({old_name}) — retour au plan Essai ({label}).",
        })
        _billing_save(state, client_id)
    return get_billing(client_id)


def subscription_blocks_mission(client_id):
    """None si le client peut lancer une vraie mission, sinon un message
    a renvoyer tel quel (credits d'essai epuises ou plan sans quota
    restant — l'abonnement devient alors obligatoire, comme demande).
    2026-09-24 : DASHBOARD_CLIENT_ID n'est JAMAIS attribue a une
    inscription client (voir create_account, toujours "CLI-CUST-...") —
    ne peut donc etre resolu que via la porte proprietaire (Kader
    lui-meme). Il ne doit jamais dependre d'un quota/abonnement, comme
    n'importe quel client, pour lancer une mission."""
    if client_id == DASHBOARD_CLIENT_ID:
        return None
    billing = get_billing(client_id)
    if billing["unlimited"]:
        return None
    if (billing["creditsRemaining"] or 0) > 0:
        return None
    return "Votre quota est épuisé. Souscrivez un abonnement pour continuer à confier des missions."


@_state_locked
def recharge_billing_credits(amount, client_id=DASHBOARD_CLIENT_ID):
    """2026-09-29 : cette recharge n'a JAMAIS ete reliee a un vrai paiement
    (voir le texte "simulation" ci-dessous, present depuis le debut). Tant
    qu'aucun vrai paiement Stripe pour l'achat de credits n'existe, l'ouvrir
    a un client reel reviendrait a lui donner un nombre illimite de credits
    gratuits (verifie : un client peut se recharger seul autant de fois
    qu'il veut). Reserve au proprietaire, pour ses propres tests, comme le
    collage de cle/jeton (meme principe, meme endroit du fichier)."""
    if client_id != DASHBOARD_CLIENT_ID:
        return {"error": "RECHARGE_NOT_AVAILABLE",
                "detail": "L'achat de crédits supplémentaires n'est pas encore relié à un vrai paiement — indisponible pour le moment."}
    state = _billing_load(client_id)
    now = datetime.datetime.utcnow().isoformat() + "Z"
    state["extraCredits"] = int(state.get("extraCredits") or 0) + amount
    state.setdefault("history", []).append({
        "dateUtc": now,
        "event": f"Recharge volontaire de {amount} credits (simulation, aucun paiement reel — pas de majoration automatique).",
    })
    _billing_save(state, client_id)
    return get_billing(client_id)


# ---------------------------------------------------------------------
# PROFIL ENTREPRISE (contexte transmis aux Workers dans leurs prompts).
# Un fichier par ClientId (core/profile/data/<ClientId>.json) : aujourd'hui
# un seul client (CLI-DASHBOARD), mais deja pret pour du multi-clients.
# ---------------------------------------------------------------------

PROFILE_DIR = os.path.join(ROOT, "core", "profile", "data")
PROFILE_FIELDS = {"companyName": 120, "sector": 120, "description": 600}


def get_company_profile(client_id=DASHBOARD_CLIENT_ID):
    return load_json(os.path.join(PROFILE_DIR, f"{client_id}.json"), {}) or {}


@_state_locked
def save_company_profile(data, client_id=DASHBOARD_CLIENT_ID):
    profile = {}
    for key, max_len in PROFILE_FIELDS.items():
        value = str(data.get(key) or "").strip()[:max_len]
        if value:
            profile[key] = value
    profile["updatedAtUtc"] = datetime.datetime.utcnow().isoformat() + "Z"
    os.makedirs(PROFILE_DIR, exist_ok=True)
    _write_json_atomic(os.path.join(PROFILE_DIR, f"{client_id}.json"), profile, ensure_ascii=False, indent=2)
    return profile


# ---------------------------------------------------------------------
# DEMANDES D'ACCES (lead capture publique, sans porte). Corrige le
# 2026-09-22 : le bouton "Demarrer" ouvrait l'onboarding interne
# (edite le profil d'entreprise partage et lance de vraies missions
# sur les credits/l'API de Kader) — bloque a raison par la porte, mais
# ca laissait n'importe quel visiteur face a "Acces protege" des le
# premier clic, sans aucun moyen de laisser ses coordonnees. Tant que
# la plateforme reste mono-client (phase accompagnee), la demande
# d'un visiteur est juste enregistree ici ; Kader la traite lui-meme.
# ---------------------------------------------------------------------

LEADS_DIR = os.path.join(ROOT, "core", "leads", "data")
LEADS_PATH = os.path.join(LEADS_DIR, "leads.jsonl")
LEAD_FIELD_MAX = {"name": 120, "email": 180, "company": 120, "message": 1000}


def save_lead(data):
    name = str(data.get("name") or "").strip()[:LEAD_FIELD_MAX["name"]]
    email = str(data.get("email") or "").strip()[:LEAD_FIELD_MAX["email"]]
    if not name or "@" not in email or "." not in email.split("@")[-1]:
        return None
    record = {
        "name": name,
        "email": email,
        "company": str(data.get("company") or "").strip()[:LEAD_FIELD_MAX["company"]],
        "message": str(data.get("message") or "").strip()[:LEAD_FIELD_MAX["message"]],
        "createdAtUtc": datetime.datetime.utcnow().isoformat() + "Z",
    }
    os.makedirs(LEADS_DIR, exist_ok=True)
    with open(LEADS_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    return record


def get_leads():
    if not os.path.isfile(LEADS_PATH):
        return []
    leads = []
    with open(LEADS_PATH, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                leads.append(json.loads(line))
            except Exception:
                continue
    leads.sort(key=lambda r: r.get("createdAtUtc", ""), reverse=True)
    return leads


# ---------------------------------------------------------------------
# ESSAI PUBLIC (une vraie mission, gratuite, sans porte). Corrige le
# 2026-09-22 : Kader veut que les visiteurs puissent parler a Chloe et
# tester un Worker sans son mot de passe — c'est le produit, pas juste
# la vitrine. Contrepartie non negociable : chaque appel utilise sa
# vraie cle Anthropic (facturee reellement), donc sans plafond un bot
# pourrait faire exploser la facture en quelques heures. D'ou :
#   - ClientId separe (CLI-TRIAL-PUBLIC) : ne touche jamais le profil
#     d'entreprise reel de Kader, ne pollue jamais ses analytics/credits
#     (la trace runtime/tasks est supprimee juste apres l'appel).
#   - Reponse tronquee (voir TRIAL_ANSWER_CHAR_CAP) : correspond a la
#     consigne de Kader ("une mission bien limitee qui ne peut aller
#     au bout sans avoir souscrit").
#   - Plafond global par jour ET plafond par IP par jour : protege la
#     facture reelle sans dependre uniquement du localStorage cote
#     navigateur (efface en 2 clics).
# ---------------------------------------------------------------------

TRIAL_LOG_DIR = os.path.join(ROOT, "core", "trial", "data")
TRIAL_LOG_PATH = os.path.join(TRIAL_LOG_DIR, "trial-missions.jsonl")
TRIAL_CLIENT_ID = "CLI-TRIAL-PUBLIC"
TRIAL_ANSWER_CHAR_CAP = 480
TRIAL_DAILY_GLOBAL_CAP = 80
TRIAL_DAILY_PER_IP_CAP = 3
TRIAL_OBJECTIVE_MAX_LEN = 500


def _trial_log_today():
    today = datetime.datetime.utcnow().date().isoformat()
    if not os.path.isfile(TRIAL_LOG_PATH):
        return []
    rows = []
    with open(TRIAL_LOG_PATH, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            if str(row.get("createdAtUtc", "")).startswith(today):
                rows.append(row)
    return rows


def _trial_log_append(ip, worker_id):
    os.makedirs(TRIAL_LOG_DIR, exist_ok=True)
    record = {"ip": ip, "worker": worker_id, "createdAtUtc": datetime.datetime.utcnow().isoformat() + "Z"}
    with open(TRIAL_LOG_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def get_trial_log():
    if not os.path.isfile(TRIAL_LOG_PATH):
        return []
    rows = []
    with open(TRIAL_LOG_PATH, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                continue
    rows.sort(key=lambda r: r.get("createdAtUtc", ""), reverse=True)
    return rows


def _cleanup_trial_task(task_id):
    if not task_id:
        return
    for p in (
        os.path.join(TASKS_DIR, f"{task_id}.json"),
        os.path.join(ROOT, "memory", "runtime", f"PROVIDER-{task_id}.json"),
    ):
        try:
            if os.path.isfile(p):
                os.remove(p)
        except Exception:
            pass


def run_trial_mission(worker_id, objective, client_ip):
    today_rows = _trial_log_today()
    if len(today_rows) >= TRIAL_DAILY_GLOBAL_CAP:
        return {"error": "TRIAL_DAILY_LIMIT_REACHED"}, 429
    if client_ip and sum(1 for r in today_rows if r.get("ip") == client_ip) >= TRIAL_DAILY_PER_IP_CAP:
        return {"error": "TRIAL_IP_LIMIT_REACHED"}, 429

    result = submit_task(objective, worker_id=worker_id, client_id=TRIAL_CLIENT_ID)

    if result.get("error"):
        return {"error": "TRIAL_FAILED", "detail": result.get("detail")}, 502

    # Chloe (orchestration multi-Workers) et un Worker direct ne renvoient
    # pas la meme forme : Chloe n'a pas de "Result.Answer" unique, mais
    # une "FinalSynthesis" et un tableau "Results" (une trace runtime/tasks
    # par Worker reellement execute — toutes a nettoyer, pas une seule).
    if worker_id == "chloe":
        answer = str(result.get("FinalSynthesis") or "")
        provider, degraded = None, False
        for item in (result.get("Results") or []):
            _cleanup_trial_task(item.get("TaskId"))
            item_result = item.get("Result") or {}
            if provider is None and item_result.get("Provider"):
                provider = item_result.get("Provider")
            degraded = degraded or bool(item_result.get("Degraded"))
        if not answer.strip() and result.get("Status") == "NO_WORKER_MATCHED":
            # Routage par mots-cles de Chloe : aucun Worker identifie pour
            # cette formulation precise (aucun appel IA reel n'a eu lieu —
            # ne consomme donc pas l'essai du visiteur, voir plus bas).
            return {
                "ok": True,
                "answer": "Je n'ai pas identifié de Worker pour cette demande précise. "
                          "Essayez de préciser le domaine (marketing, ventes, RH, finance, juridique, support...) "
                          "ou reformulez en une phrase plus concrète.",
                "limited": True,
                "truncated": False,
                "provider": None,
                "degraded": False,
                "retry": True,
            }, 200
    else:
        inner = result.get("Result") or {}
        answer = str(inner.get("Answer") or "")
        provider = inner.get("Provider")
        degraded = bool(inner.get("Degraded"))
        _cleanup_trial_task(result.get("TaskId"))

    if not answer.strip():
        return {"error": "TRIAL_EMPTY_ANSWER"}, 502

    truncated = len(answer) > TRIAL_ANSWER_CHAR_CAP
    if truncated:
        cut = answer[:TRIAL_ANSWER_CHAR_CAP]
        last_space = cut.rfind(" ")
        if last_space > TRIAL_ANSWER_CHAR_CAP * 0.6:
            cut = cut[:last_space]
        answer = cut.rstrip() + "…"

    _trial_log_append(client_ip, worker_id)

    return {
        "ok": True,
        "answer": answer,
        "limited": True,
        "truncated": truncated,
        "provider": provider,
        "degraded": degraded,
    }, 200


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # silence par defaut, evite le bruit console

    def _send_json(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path, content_type):
        if not os.path.isfile(path):
            self._send_json({"error": "NOT_FOUND"}, 404)
            return
        file_size = os.path.getsize(path)

        # Aucun header de cache n'etait jamais envoye : un navigateur
        # pouvait garder en cache un ancien app.js/index.html apres un
        # deploiement, et executer du JS perime contre le nouveau DOM
        # (echec silencieux de TOUS les boutons — signale par Kader en
        # conditions reelles le 2026-09-24, plusieurs deploiements
        # coup sur coup dans la meme session). no-cache force une
        # revalidation a chaque requete (304 si inchange) sans perdre
        # le benefice du cache pour les gros fichiers (portraits/videos).
        #
        # Support des requetes Range (2026-09-24) : les navigateurs
        # demandent TOUJOURS une balise <video> avec un en-tete Range
        # (meme au tout premier chargement), pour verifier que le
        # serveur sait faire du seek. Repondre 200 avec le fichier
        # ENTIER (comme avant ce correctif) au lieu de 206 avec juste
        # la plage demandee desoriente le pipeline video de Chrome : la
        # video restait bloquee en pause sans jamais demarrer, alors
        # que tout le reste (portrait statique, JSON, JS, CSS) n'est
        # jamais demande avec Range et n'etait donc jamais affecte.
        range_header = self.headers.get("Range")
        if range_header and range_header.startswith("bytes="):
            try:
                start_str, end_str = range_header[6:].split("-", 1)
                start = int(start_str) if start_str else 0
                end = int(end_str) if end_str else file_size - 1
                end = min(end, file_size - 1)
            except (ValueError, IndexError):
                start, end = 0, file_size - 1
            if start > end or start >= file_size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{file_size}")
                self.end_headers()
                return
            chunk_size = end - start + 1
            with open(path, "rb") as f:
                f.seek(start)
                body = f.read(chunk_size)
            self.send_response(206)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(chunk_size))
            self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Cache-Control", "no-cache, must-revalidate")
            self.end_headers()
            self.wfile.write(body)
            return

        with open(path, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-cache, must-revalidate")
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send_html(self, html_str):
        body = html_str.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache, must-revalidate")
        self.end_headers()
        self.wfile.write(body)

    def _cookie(self, name):
        cookie_header = self.headers.get("Cookie", "")
        prefix = name + "="
        for part in cookie_header.split(";"):
            part = part.strip()
            if part.startswith(prefix):
                return part[len(prefix):]
        return None

    def _gate_token_from_cookie(self):
        return self._cookie("bk_session")

    def _gate_authenticated(self):
        return gate_check_session(self._gate_token_from_cookie())

    def _send_gate_required(self):
        self._send_json({"error": "GATE_REQUIRED"}, 401)

    def _account_session(self):
        return account_check_session(self._cookie("bk_account"))

    def _resolve_client_id(self):
        """ClientId pour lequel agir sur cette requete : un compte client
        connecte (bk_account) prioritaire, sinon Kader lui-meme via son
        propre mot de passe historique (bk_session -> CLI-DASHBOARD, pour
        qu'il garde son acces sans devoir s'inscrire comme son propre
        client). None si ni l'un ni l'autre n'est present/valide."""
        session = self._account_session()
        if session:
            return session["clientId"]
        if self._gate_authenticated():
            return DASHBOARD_CLIENT_ID
        return None

    def _send_account_required(self):
        self._send_json({"error": "ACCOUNT_REQUIRED"}, 401)

    def _public_api_key(self):
        """Cle API pour /api/public/v1/* : header Authorization: Bearer
        <cle> (convention Zapier/Make "API Key" standard) ou X-Api-Key,
        jamais un cookie de session — cet appelant n'est pas un
        navigateur connecte au compte."""
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return (self.headers.get("X-Api-Key") or "").strip()

    def _client_ip(self):
        # Derriere Caddy (reverse_proxy), self.client_address est l'IP
        # interne du conteneur Caddy pour TOUTES les requetes : sans lire
        # X-Forwarded-For, le plafond par IP de l'essai public ne
        # limiterait jamais rien (tout le monde aurait la meme IP).
        forwarded = self.headers.get("X-Forwarded-For", "")
        if forwarded:
            return forwarded.split(",")[0].strip()
        return self.client_address[0]

    def do_GET(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)

        if route_requires_gate(path) and not self._gate_authenticated():
            self._send_gate_required()
            return

        if TRUST.handle_get(self, path):  # /securite.html /status.html /api/status /api/health /.well-known/security.txt
            return

        if path == "/" or path == "/index.html":
            self._send_file(os.path.join(DASHBOARD_DIR, "index.html"), "text/html; charset=utf-8")
        elif path == "/style.css":
            self._send_file(os.path.join(DASHBOARD_DIR, "style.css"), "text/css; charset=utf-8")
        elif path in ("/i18n.js", "/i18n-en.js", "/i18n-en-legal.js", "/i18n-en-app.js"):
            self._send_file(os.path.join(DASHBOARD_DIR, path.lstrip("/")), "application/javascript; charset=utf-8")
        elif path == "/particles.js":
            self._send_file(os.path.join(DASHBOARD_DIR, "particles.js"), "application/javascript; charset=utf-8")
        elif path == "/app.js":
            self._send_file(os.path.join(DASHBOARD_DIR, "app.js"), "application/javascript; charset=utf-8")
        elif path == "/favicon.svg" or path == "/favicon.ico":
            self._send_file(os.path.join(DASHBOARD_DIR, "favicon.svg"), "image/svg+xml")
        elif pwa_static.handles(path) or path.startswith("/icons/"):
            # App installable (PWA) : manifest, service worker, page hors connexion, icones,
            # page "supprimer mon compte". Types MIME et en-tetes de cache : pwa_static.py.
            if not pwa_static.serve(self, path, DASHBOARD_DIR):
                self._send_json({"error": "NOT_FOUND"}, 404)
        elif path.startswith("/portraits/") and path.endswith(".svg"):
            wid = path.split("/")[-1].replace(".svg", "")
            if wid in get_worker_ids() or wid == "chloe":
                self._send_file(os.path.join(worker_base_dir(wid), "identity", "portrait.svg"), "image/svg+xml")
            else:
                self._send_json({"error": "NOT_FOUND"}, 404)
        elif path.startswith("/portraits/") and path.endswith(".jpg"):
            wid = path.split("/")[-1].replace(".jpg", "")
            if wid in get_worker_ids() or wid == "chloe":
                self._send_file(os.path.join(worker_base_dir(wid), "identity", "portrait-3d.jpg"), "image/jpeg")
            else:
                self._send_json({"error": "NOT_FOUND"}, 404)
        elif path.startswith("/videos/") and path.endswith(".mp4"):
            wid = path.split("/")[-1].replace(".mp4", "")
            if wid in get_worker_ids() or wid == "chloe":
                self._send_file(os.path.join(worker_base_dir(wid), "identity", "generated", "intro.mp4"), "video/mp4")
            else:
                self._send_json({"error": "NOT_FOUND"}, 404)
        elif path == "/confidentialite.html" or path == "/confidentialite":
            self._send_file(os.path.join(DASHBOARD_DIR, "confidentialite.html"), "text/html; charset=utf-8")
        elif path == "/robots.txt":
            body = ("User-agent: *\nAllow: /\nDisallow: /api/\nDisallow: /oauth/\nDisallow: /webhooks/\n"
                    f"Sitemap: {PUBLIC_BASE_URL}/sitemap.xml\n").encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "public, max-age=3600")
            self.end_headers()
            self.wfile.write(body)
        elif path == "/sitemap.xml":
            urls = "".join(f"<url><loc>{PUBLIC_BASE_URL}{p}</loc></url>" for p in SITEMAP_PATHS + [q for q in pilot_program.SITEMAP_PATHS if q not in SITEMAP_PATHS])
            body = ('<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
                    + urls + "</urlset>").encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/xml; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "public, max-age=3600")
            self.end_headers()
            self.wfile.write(body)
        elif path == "/ads.txt":
            self._send_file(os.path.join(DASHBOARD_DIR, "ads.txt"), "text/plain; charset=utf-8")
        elif path == "/workers.html":
            workers = [build_worker_summary(w) for w in get_worker_ids()]
            self._send_html(seo_pages.render_workers_page(workers))
        elif path == "/demarrer.html":
            self._send_html(seo_pages.render_demarrer_page())
        elif path == "/chloe.html":
            self._send_html(seo_pages.render_chloe_page())
        elif path == "/automatisations.html":
            self._send_html(seo_pages.render_automatisations_page())
        elif path == "/analytics.html":
            self._send_html(seo_pages.render_analytics_page())
        elif path == "/facturation.html":
            self._send_html(seo_pages.render_facturation_page())
        elif path == "/tarifs.html":
            self._send_html(seo_pages.render_tarifs_page())
        elif path == "/faq.html":
            self._send_html(seo_pages.render_faq_page())
        elif path == "/cgv.html":
            self._send_html(seo_pages.render_cgv_page())
        elif path == "/mentions-legales.html":
            self._send_html(seo_pages.render_mentions_page())
        elif path == "/cookies.html":
            self._send_html(seo_pages.render_cookies_page())
        elif path == "/api/workers":
            self._send_json({"workers": [build_worker_summary(w) for w in get_worker_ids()]})
        elif path == "/api/categories":
            workers = [build_worker_summary(w) for w in get_worker_ids()]
            counts = {}
            for w in workers:
                counts[w["category"]] = counts.get(w["category"], 0) + 1
            self._send_json({"total": len(workers), "categories": counts})
        elif path == "/api/chloe":
            self._send_json(build_worker_summary("chloe"))
        elif path.startswith("/api/workers/") and path.endswith("/activity"):
            wid = path.split("/")[3]
            if wid not in get_worker_ids() and wid != "chloe":
                self._send_json({"error": "UNKNOWN_WORKER"}, 404)
                return
            client_id = self._resolve_client_id()
            if not client_id:
                # Pas d'erreur bruyante : la fiche Worker est publique,
                # seul son historique (prive) exige un compte — un
                # visiteur non connecte voit juste "aucune activite".
                self._send_json({"activity": []})
                return
            self._send_json({"activity": get_worker_activity(wid.upper(), client_id)})
        elif path.startswith("/api/workers/"):
            wid = path.split("/")[3]
            if wid not in get_worker_ids():
                self._send_json({"error": "UNKNOWN_WORKER"}, 404)
                return
            self._send_json(build_worker_summary(wid))
        elif path == "/api/connectors":
            # Le catalogue reste visible sans compte (comme le catalogue
            # de Workers) : c'est de la lecture, aucune donnee client
            # n'est exposee. L'etat d'activation PAR CLIENT (champ
            # activatedByClient) n'apparait que si un compte est
            # reconnu, sinon il reste a null pour tout le monde.
            client_id = self._resolve_client_id()
            self._send_json(get_connector_catalog(client_id))
        elif path == "/api/integrations/apikey":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            existing = _load_client_apikey(client_id)
            self._send_json({"exists": bool(existing), "keyPrefix": (existing or {}).get("keyPrefix")})
        elif path == "/api/integrations/webhook":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            cfg = _load_client_webhook(client_id)
            self._send_json({"url": (cfg or {}).get("url"), "secret": (cfg or {}).get("secret")})
        elif path.startswith("/api/public/v1/missions/"):
            raw_key = self._public_api_key()
            client_id = _find_client_by_api_key(raw_key)
            if not client_id:
                self._send_json({"error": "INVALID_API_KEY"}, 401)
                return
            task_id = path.split("/")[-1]
            if not TASK_ID_PATTERN.match(task_id or ""):
                self._send_json({"error": "INVALID_TASK_ID"}, 400)
                return
            data = load_json(os.path.join(TASKS_DIR, f"{task_id}.json"))
            if not data or data.get("ClientId") != client_id:
                self._send_json({"error": "NOT_FOUND"}, 404)
                return
            self._send_json(_summarize_mission_result(data))
        elif path.startswith("/api/missions/") and "/files/" in path:
            # Telechargement securise d'un fichier produit par un Worker
            # (voir ANTHROPIC-ADAPTER.ps1 : capture via code execution,
            # depose dans runtime/task-files/<TaskId>/<name>). Reserve au
            # client proprietaire de la mission (ou a Kader/CLI-DASHBOARD).
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            rest = path[len("/api/missions/"):]
            task_id, _, name = rest.partition("/files/")
            name = unquote(name)
            if not TASK_ID_PATTERN.match(task_id or ""):
                self._send_json({"error": "NOT_FOUND"}, 404)
                return
            # name doit etre un pur basename, sans separateur ni ./..
            if not (os.path.basename(name) == name and name not in ("", ".", "..")
                    and "/" not in name and "\\" not in name):
                self._send_json({"error": "NOT_FOUND"}, 404)
                return
            rec = load_json(os.path.join(TASKS_DIR, f"{task_id}.json"))
            if not rec:
                self._send_json({"error": "NOT_FOUND"}, 404)
                return
            if rec.get("ClientId") != client_id and client_id != DASHBOARD_CLIENT_ID:
                self._send_json({"error": "FORBIDDEN"}, 403)
                return
            fpath = os.path.join(TASK_FILES_DIR, task_id, name)
            # Defense en profondeur : le chemin reel doit rester CONFINE
            # dans le dossier de la tache (aucune remontee ../ possible).
            task_dir_real = os.path.realpath(os.path.join(TASK_FILES_DIR, task_id))
            if not os.path.realpath(fpath).startswith(task_dir_real + os.sep):
                self._send_json({"error": "NOT_FOUND"}, 404)
                return
            if not os.path.isfile(fpath):
                self._send_json({"error": "NOT_FOUND"}, 404)
                return
            ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
            size = os.path.getsize(fpath)
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Cache-Control", "no-cache, must-revalidate")
            self.end_headers()
            with open(fpath, "rb") as f:
                shutil.copyfileobj(f, self.wfile, 64 * 1024)   # par blocs : jamais le fichier entier en memoire
        elif path.startswith("/api/missions/async/"):
            # Interrogation du statut d'une mission lancee en arriere-plan.
            # Reserve au client proprietaire du job (ou a Kader/CLI-DASHBOARD).
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            job_id = path.split("/")[-1]
            if not ASYNC_JOB_ID_PATTERN.match(job_id or ""):
                self._send_json({"error": "NOT_FOUND"}, 404)
                return
            job = read_async_job(job_id)
            if job is None:
                self._send_json({"error": "NOT_FOUND"}, 404)
                return
            if job.get("clientId") != client_id and client_id != DASHBOARD_CLIENT_ID:
                self._send_json({"error": "FORBIDDEN"}, 403)
                return
            self._send_json(job)
        elif path == "/api/admin/overview":
            # Reserve au proprietaire : la porte historique uniquement,
            # jamais une session de compte client (meme un client tres
            # actif ne doit jamais voir les autres comptes).
            if not self._gate_authenticated():
                self._send_gate_required()
                return
            self._send_json(get_admin_overview())
        elif path.startswith("/oauth/") and (path.endswith("/start") or path.endswith("/callback")):
            parts = path.strip("/").split("/")  # ["oauth", vendor, "start"|"callback"]
            vendor = parts[1] if len(parts) == 3 else ""
            cfg = OAUTH_VENDORS.get(vendor)
            if not cfg:
                self._redirect("/?oauth=error&reason=UNKNOWN_VENDOR")
                return
            q = parse_qs(parsed.query)
            redirect_uri = f"{PUBLIC_BASE_URL}/oauth/{vendor}/callback"
            if parts[2] == "start":
                provider = (q.get("provider") or [""])[0]
                client_id = self._resolve_client_id()
                if not client_id:
                    self._redirect("/?oauth=login")
                    return
                if provider not in cfg["scopes"]:
                    self._redirect("/?oauth=error&reason=UNKNOWN_PROVIDER")
                    return
                if cfg.get("env") and not oauth_vendor_ready(vendor):
                    self._redirect("/?oauth=error&reason=" + vendor.upper() + "_APP_NOT_CONFIGURED")
                    return
                if cfg.get("env"):
                    OAUTH_APP_CACHE[vendor] = os.environ.get(f"OAUTH_{vendor.upper()}_CLIENT_ID")
                if not OAUTH_APP_CACHE.get(vendor):
                    app_info = run_google_oauth_bridge({"action": "app", "vendor": vendor})
                    if not app_info.get("ok"):
                        self._redirect("/?oauth=error&reason=" + vendor.upper() + "_APP_NOT_CONFIGURED")
                        return
                    OAUTH_APP_CACHE[vendor] = app_info["clientId"]
                now = time.time()
                for k in [k for k, v in OAUTH_STATES.items() if v["expiry"] < now]:
                    OAUTH_STATES.pop(k, None)
                state = secrets.token_urlsafe(24)
                OAUTH_STATES[state] = {"clientId": client_id, "provider": provider, "vendor": vendor, "expiry": now + 600}
                params = {
                    "client_id": OAUTH_APP_CACHE[vendor],
                    "redirect_uri": redirect_uri,
                    "response_type": "code",
                    "state": state,
                    **cfg["extra"],
                }
                scope_str = " ".join(cfg["scopes"][provider] + cfg["base"])
                if scope_str:
                    params["scope"] = scope_str
                self._redirect(cfg["authUrl"] + "?" + urlencode(params))
            else:
                state = (q.get("state") or [""])[0]
                pending = OAUTH_STATES.pop(state, None)
                if q.get("error"):
                    self._redirect("/?oauth=cancelled")
                    return
                if not pending or pending["expiry"] < time.time() or pending["vendor"] != vendor:
                    self._redirect("/?oauth=error&reason=STATE_EXPIRED")
                    return
                # La session du navigateur doit etre celle qui a demarre le
                # flux (empeche de rattacher un compte tiers a un autre client).
                if self._resolve_client_id() != pending["clientId"]:
                    self._redirect("/?oauth=error&reason=SESSION_MISMATCH")
                    return
                res = run_google_oauth_bridge({
                    "action": "exchange", "vendor": vendor, "clientId": pending["clientId"],
                    "code": (q.get("code") or [""])[0], "redirectUri": redirect_uri,
                    "providers": [pending["provider"]],
                    "scope": " ".join(cfg["scopes"][pending["provider"]] + cfg["base"]),
                })
                if res.get("ok"):
                    try:
                        for c in (load_json(CONNECTOR_CATALOG_PATH, {}) or {}).get("connectors", []):
                            base = (c.get("connectorId") or "").removesuffix(".controlled")
                            if CONNECTOR_ID_TO_CREDENTIAL_PROVIDER.get(base, base) == pending["provider"]:
                                toggle_client_connector(pending["clientId"], c.get("connectorId"), True)
                    except Exception:
                        pass
                    log_activity("connector", clientId=pending["clientId"], provider=pending["provider"], email=res.get("email"))
                    self._redirect(f"/?oauth=ok&vendor={vendor}&provider={pending['provider']}" + ("&email=" + res["email"] if res.get("email") else ""))
                else:
                    self._redirect("/?oauth=error&reason=" + str(res.get("error") or "UNKNOWN")[:60].replace(" ", "_"))
        elif path == "/api/fx":
            self._send_json(get_fx_rates())
        elif path == "/webhooks/whatsapp":
            challenge = wa.verify_challenge(parse_qs(parsed.query))
            if challenge is None:
                self._send_json({"error": "FORBIDDEN"}, 403)
                return
            data = challenge.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif path == "/api/whatsapp/status":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            self._send_json(whatsapp_status(client_id))
        elif PILOT.handle_get(self, path):   # programme pilote : /pilote.html, ses scripts, GET /api/pilot/applications (operateur)
            pass
        elif path == "/api/testimonials":
            self._send_json({"testimonials": public_testimonials()})
        elif path == "/api/admin/demo-requests":
            if not self._gate_authenticated():
                self._send_gate_required()
                return
            self._send_json(get_demo_requests())
        elif path == "/api/admin/activity":
            if not self._gate_authenticated():
                self._send_gate_required()
                return
            self._send_json(get_admin_activity())
        elif path.startswith("/api/admin/client/") and path.endswith("/activity"):
            # Detail des missions d'UN compte, reserve au proprietaire —
            # meme garde que /api/admin/overview.
            if not self._gate_authenticated():
                self._send_gate_required()
                return
            target_client_id = path.split("/")[4]
            self._send_json({"activity": get_client_missions(target_client_id)})
        elif path == "/api/analytics":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            self._send_json(get_analytics(client_id))
        elif path == "/api/billing":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            self._send_json(get_billing(client_id))
        elif path == "/api/profile":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            self._send_json(get_company_profile(client_id))
        elif path == "/api/account/verify":
            ok = verify_email_token((parse_qs(parsed.query).get("token") or [""])[0])
            self._redirect("/?verified=" + ("1" if ok else "0"))
        elif path == "/api/account/me":
            session = self._account_session()
            if session:
                self._send_json({"loggedIn": True, "email": session["email"], "clientId": session["clientId"],
                                 "emailVerified": account_email_verified(session["clientId"])})
            elif self._gate_authenticated():
                self._send_json({"loggedIn": True, "email": None, "clientId": DASHBOARD_CLIENT_ID, "operator": True})
            else:
                self._send_json({"loggedIn": False})
        elif path == "/api/billing/stripe-status":
            result = run_stripe_bridge("status")
            self._send_json(result)
        elif path == "/api/automations":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            result = run_automation_bridge("list", client_id=client_id)
            self._send_json({"automations": result} if isinstance(result, list) else result)
        elif path.startswith("/api/automations/") and path.endswith("/runs"):
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            automation_id = path.split("/")[3]
            result = run_automation_bridge("runs", automation_id=automation_id, client_id=client_id)
            self._send_json({"runs": result} if isinstance(result, list) else result)
        elif path == "/api/gate/status":
            self._send_json({"enabled": gate_is_enabled(), "authenticated": self._gate_authenticated()})
        elif path == "/api/leads":
            # Lecture protegee "a la main" (pas via GATE_PROTECTED_PREFIXES,
            # qui gate aussi le POST public utilise par le formulaire de contact).
            if gate_is_enabled() and not self._gate_authenticated():
                self._send_gate_required()
                return
            self._send_json({"leads": get_leads()})
        elif path == "/api/trial/log":
            # Meme logique que /api/leads : lecture protegee a la main
            # (le POST /api/trial/mission, lui, doit rester public).
            if gate_is_enabled() and not self._gate_authenticated():
                self._send_gate_required()
                return
            self._send_json({"missions": get_trial_log(), "dailyCap": TRIAL_DAILY_GLOBAL_CAP, "perIpCap": TRIAL_DAILY_PER_IP_CAP})
        else:
            self._send_json({"error": "NOT_FOUND"}, 404)

    def do_HEAD(self):
        # Sondes de surveillance externes (HEAD) : seulement les routes de trust_pages.py, sans corps.
        if not TRUST.handle_head(self, unquote(urlparse(self.path).path)):
            self.send_error(501, "Unsupported method ('HEAD')")

    def do_POST(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)

        if route_requires_gate(path) and not self._gate_authenticated():
            self._send_gate_required()
            return

        if TRUST.handle_post(self, path):  # journal d'incidents (proprietaire)
            return

        if path == "/api/gate/login":
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            password = body.get("password") or ""
            if not gate_is_enabled():
                self._send_json({"ok": True, "note": "Porte desactivee (aucun mot de passe defini)."})
                return
            # Sans limite, le mot de passe administrateur pouvait etre devine
            # par essais repetes : meme regle que la connexion client.
            ip = self._client_ip()
            if auth_throttled(ip, OWNER_GATE_THROTTLE_KEY):
                self._send_json({"error": "TOO_MANY_ATTEMPTS"}, 429)
                return
            if not verify_gate_password(password):
                auth_record_fail(ip, OWNER_GATE_THROTTLE_KEY)
                self._send_json({"error": "INVALID_PASSWORD"}, 401)
                return
            auth_clear(ip, OWNER_GATE_THROTTLE_KEY)
            token = gate_create_session()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Set-Cookie", f"bk_session={token}; HttpOnly; SameSite=Lax; Path=/; Max-Age={GATE_SESSION_TTL_SECONDS}{COOKIE_SECURE}")
            body_bytes = json.dumps({"ok": True}).encode("utf-8")
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            self.wfile.write(body_bytes)
            return
        elif path == "/api/gate/logout":
            gate_clear_session(self._gate_token_from_cookie())
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Set-Cookie", f"bk_session=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0{COOKIE_SECURE}")
            body_bytes = json.dumps({"ok": True}).encode("utf-8")
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            self.wfile.write(body_bytes)
            return
        elif path == "/webhooks/twilio/voice":
            # Standard telephonique (phone_agent.py). Public par nature : la
            # protection est la signature Twilio, verifiee cote PowerShell.
            try:
                length = int(self.headers.get("Content-Length", 0) or 0)
            except ValueError:
                length = -1
            if length < 0 or length > phone_agent.MAX_BODY_BYTES:
                status, xml = 413, phone_agent.REJECT_TWIML
            else:
                raw = self.rfile.read(length) if length else b""
                host = (self.headers.get("X-Forwarded-Host") or self.headers.get("Host") or "").split(",")[0].strip()
                proto = (self.headers.get("X-Forwarded-Proto") or "https").split(",")[0].strip()
                urls = [phone_agent.DEFAULT_WEBHOOK_URL]
                if re.fullmatch(r"[A-Za-z0-9.\-]+(:\d+)?", host) and proto in ("http", "https"):
                    derived = f"{proto}://{host}/webhooks/twilio/voice"
                    if derived not in urls:
                        urls.append(derived)
                status, xml = PHONE_AGENT.handle(raw, self.headers.get("X-Twilio-Signature", ""), urls)
            body_bytes = xml.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "text/xml; charset=utf-8")
            self.send_header("Content-Length", str(len(body_bytes)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body_bytes)
        elif path == "/webhooks/whatsapp":
            length = int(self.headers.get("Content-Length", 0))
            if length > 200000:
                self._send_json({"error": "TOO_LARGE"}, 413)
                return
            raw = self.rfile.read(length) if length else b""
            if not wa.is_enabled() or not wa.verify_signature(raw, self.headers.get("X-Hub-Signature-256", "")):
                self._send_json({"error": "FORBIDDEN"}, 403)
                return
            try:
                payload = json.loads(raw.decode("utf-8"))
            except Exception:
                payload = {}
            wa.handle_webhook_payload(payload if isinstance(payload, dict) else {}, WA_STORE, _wa_deps())
            self._send_json({"ok": True})
        elif path == "/api/whatsapp/link-code":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            if not wa.is_enabled():
                self._send_json({"error": "WHATSAPP_NOT_AVAILABLE"}, 503)
                return
            code = WA_STORE.create_code(client_id)
            self._send_json({"code": code, "number": wa.display_number(), "expiresInSeconds": wa.CODE_TTL_SECONDS})
        elif path == "/api/whatsapp/unlink":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            WA_STORE.unlink_client(client_id)
            self._send_json(whatsapp_status(client_id))
        elif path in ("/api/admin/testimonials", "/api/admin/testimonials/delete"):
            if not self._gate_authenticated():
                self._send_gate_required()
                return
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(min(length, 10000)).decode("utf-8")) if length else {}
            except Exception:
                body = {}
            body = body if isinstance(body, dict) else {}
            if path.endswith("/delete"):
                self._send_json({"ok": delete_testimonial(str(body.get("id") or ""))})
            else:
                rec, err = add_testimonial(body)
                if err:
                    self._send_json({"error": err}, 400)
                else:
                    self._send_json({"ok": True, "testimonial": rec})
        elif PILOT.handle_post(self, path):  # programme pilote : POST /api/pilot/apply (public), .../applications/delete (operateur)
            pass
        elif path == "/api/demo-request":
            length = int(self.headers.get("Content-Length", 0))
            if length > 20000:
                self._send_json({"error": "TOO_LARGE"}, 413)
                return
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            payload, status = submit_demo_request(body if isinstance(body, dict) else {}, self._client_ip())
            self._send_json(payload, status)
        elif path == "/api/account/signup":
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            if not signup_rate_ok(self._client_ip()):
                self._send_json({"error": "RATE_LIMITED"}, 429)
                return
            account, error = create_account(body.get("email"), body.get("password"), body.get("companyName"))
            if error:
                self._send_json({"error": error}, 400)
                return
            log_activity("login", email=account.get("email"), clientId=account.get("clientId"),
                         ip=(self.headers.get("X-Forwarded-For") or self.client_address[0]).split(",")[0].strip())
            send_verification_email(account, force=True)
            token = account_create_session(account)
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Set-Cookie", f"bk_account={token}; HttpOnly; SameSite=Lax; Path=/; Max-Age={ACCOUNT_SESSION_TTL_SECONDS}{COOKIE_SECURE}")
            body_bytes = json.dumps({"ok": True, "clientId": account["clientId"]}).encode("utf-8")
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            self.wfile.write(body_bytes)
            return
        elif path == "/api/account/login":
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            ip = self._client_ip()
            if auth_throttled(ip, body.get("email")):
                self._send_json({"error": "TOO_MANY_ATTEMPTS"}, 429)
                return
            account = _find_account_by_email(body.get("email"))
            if not account or not _verify_password(body.get("password") or "", account.get("passwordHash", "")):
                auth_record_fail(ip, body.get("email"))
                self._send_json({"error": "INVALID_CREDENTIALS"}, 401)
                return
            auth_clear(ip, body.get("email"))
            log_activity("login", email=account.get("email"), clientId=account.get("clientId"), ip=ip)
            token = account_create_session(account)
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Set-Cookie", f"bk_account={token}; HttpOnly; SameSite=Lax; Path=/; Max-Age={ACCOUNT_SESSION_TTL_SECONDS}{COOKIE_SECURE}")
            body_bytes = json.dumps({"ok": True, "clientId": account["clientId"]}).encode("utf-8")
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            self.wfile.write(body_bytes)
            return
        elif path == "/api/account/resend-verification":
            client_id = self._resolve_client_id()
            acc = next((a for a in _load_accounts() if a.get("clientId") == client_id), None)
            if not acc:
                self._send_account_required()
                return
            if account_email_verified(client_id):
                self._send_json({"ok": True, "alreadyVerified": True})
                return
            self._send_json({"ok": send_verification_email(acc)})
        elif path == "/api/account/forgot":
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(min(length, 5000)).decode("utf-8")) if length else {}
            except Exception:
                body = {}
            request_password_reset(body.get("email") if isinstance(body, dict) else "", self._client_ip())
            self._send_json({"ok": True})
        elif path == "/api/account/reset":
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(min(length, 5000)).decode("utf-8")) if length else {}
            except Exception:
                body = {}
            body = body if isinstance(body, dict) else {}
            if auth_throttled(self._client_ip(), "reset"):
                self._send_json({"error": "TOO_MANY_ATTEMPTS"}, 429)
                return
            err = reset_password_with_token(body.get("token"), body.get("password"))
            if err:
                auth_record_fail(self._client_ip(), "reset")
                self._send_json({"error": err}, 400)
                return
            self._send_json({"ok": True})
        elif path == "/api/account/export":
            client_id = self._resolve_client_id()
            if not client_id or not CLIENT_ID_RE.match(client_id):
                self._send_account_required()
                return
            data = json.dumps(export_account_data(client_id), ensure_ascii=False, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Disposition", 'attachment; filename="bk-ai-workers-mes-donnees.json"')
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif path == "/api/account/delete":
            client_id = self._resolve_client_id()
            if not client_id or not CLIENT_ID_RE.match(client_id):
                self._send_account_required()
                return
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(min(length, 5000)).decode("utf-8")) if length else {}
            except Exception:
                body = {}
            if auth_throttled(self._client_ip(), "del|" + client_id):
                self._send_json({"error": "TOO_MANY_ATTEMPTS"}, 429)
                return
            err = delete_account(client_id, (body or {}).get("password"))
            if err:
                if err == "INVALID_PASSWORD":
                    auth_record_fail(self._client_ip(), "del|" + client_id)
                self._send_json({"error": err}, 400 if err != "ACTIVE_SUBSCRIPTION" else 409)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Set-Cookie", f"bk_account=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0{COOKIE_SECURE}")
            out = b'{"ok": true}'
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
        elif path == "/api/account/logout":
            account_clear_session(self._cookie("bk_account"))
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Set-Cookie", f"bk_account=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0{COOKIE_SECURE}")
            body_bytes = json.dumps({"ok": True}).encode("utf-8")
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            self.wfile.write(body_bytes)
            return

        if path == "/api/chloe/task":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            block = subscription_blocks_mission(client_id)
            if block:
                self._send_json({"error": "SUBSCRIPTION_REQUIRED", "detail": block}, 402)
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            objective = (body.get("objective") or "").strip()
            if not objective:
                self._send_json({"error": "OBJECTIVE_REQUIRED"}, 400)
                return
            result = submit_task_limited(objective, worker_id="chloe", client_id=client_id)
            self._send_json(attach_pending_action(result))
        elif path == "/api/chloe/task/async":
            # Variante asynchrone de /api/chloe/task : memes gardes (compte,
            # abonnement, objectif requis) verifiees AVANT de lancer le thread
            # (quota controle en amont, une seule fois). Renvoie un jobId (202)
            # a interroger via GET /api/missions/async/<jobId> ; le thread
            # demon execute submit_task identiquement a la version synchrone.
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            block = subscription_blocks_mission(client_id)
            if block:
                self._send_json({"error": "SUBSCRIPTION_REQUIRED", "detail": block}, 402)
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            objective = (body.get("objective") or "").strip()
            if not objective:
                self._send_json({"error": "OBJECTIVE_REQUIRED"}, 400)
                return
            res = submit_task_async(objective, worker_id="chloe", client_id=client_id)
            self._send_json(res, 429 if res.get("error") else 202)
        elif path == "/api/chloe/plan":
            # Etape "Demander a Chloe" du parcours Demarrer : reservee aux
            # comptes clients (plus au mot de passe proprietaire, qui
            # affichait a un client une demande de mot de passe/"token"
            # incomprehensible — signale par Kader, 2026-09-25).
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            objective = (body.get("objective") or "").strip()
            if not objective:
                self._send_json({"error": "OBJECTIVE_REQUIRED"}, 400)
                return
            result = submit_task(objective, worker_id="chloe", plan_only=True, client_id=client_id)
            self._send_json(result)
        elif path.startswith("/api/workers/") and path.endswith("/task"):
            wid = path.split("/")[3]
            if wid not in get_worker_ids():
                self._send_json({"error": "UNKNOWN_WORKER"}, 404)
                return
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            block = subscription_blocks_mission(client_id)
            if block:
                self._send_json({"error": "SUBSCRIPTION_REQUIRED", "detail": block}, 402)
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            objective = (body.get("objective") or "").strip()
            if not objective:
                self._send_json({"error": "OBJECTIVE_REQUIRED"}, 400)
                return
            result = submit_task_limited(objective, worker_id=wid, client_id=client_id)
            self._send_json(attach_pending_action(result))
        elif path.startswith("/api/workers/") and path.endswith("/task/async"):
            # Variante asynchrone de /api/workers/<id>/task : memes gardes
            # (worker connu, compte, abonnement, objectif requis) verifiees
            # AVANT de lancer le thread. Renvoie un jobId (202) a interroger
            # via GET /api/missions/async/<jobId>.
            wid = path.split("/")[3]
            if wid not in get_worker_ids():
                self._send_json({"error": "UNKNOWN_WORKER"}, 404)
                return
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            block = subscription_blocks_mission(client_id)
            if block:
                self._send_json({"error": "SUBSCRIPTION_REQUIRED", "detail": block}, 402)
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            objective = (body.get("objective") or "").strip()
            if not objective:
                self._send_json({"error": "OBJECTIVE_REQUIRED"}, 400)
                return
            res = submit_task_async(objective, worker_id=wid, client_id=client_id)
            self._send_json(res, 429 if res.get("error") else 202)
        elif path == "/api/connector-action/confirm":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            task_id = (body.get("taskId") or "").strip()
            pending = load_json(_pending_action_path(task_id)) if task_id else None
            if not pending:
                self._send_json({"error": "PENDING_ACTION_NOT_FOUND"}, 404)
                return
            # Une action en attente n'appartient qu'au client pour qui elle
            # a ete proposee — sans ce controle, un autre client connu
            # devinant le TaskId pourrait declencher l'envoi reel de
            # quelqu'un d'autre.
            if pending.get("clientId") != client_id:
                self._send_json({"error": "PENDING_ACTION_NOT_FOUND"}, 404)
                return
            result = run_connector_dispatch_bridge(pending.get("connectorId"), pending.get("operation"), pending.get("params"), pending.get("clientId"))
            try:
                os.remove(_pending_action_path(task_id))
            except Exception:
                pass
            self._send_json(result)
        elif path == "/api/connector-action/cancel":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            task_id = (body.get("taskId") or "").strip()
            pending = load_json(_pending_action_path(task_id)) if task_id else None
            if pending and pending.get("clientId") == client_id:
                try:
                    os.remove(_pending_action_path(task_id))
                except Exception:
                    pass
            self._send_json({"ok": True})
        elif path == "/api/automations":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            block = subscription_blocks_mission(client_id)
            if block:
                self._send_json({"error": "SUBSCRIPTION_REQUIRED", "detail": block}, 402)
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            worker_id = (body.get("workerId") or "").strip().lower()
            objective = (body.get("objective") or "").strip()
            frequency_minutes = body.get("frequencyMinutes")
            if worker_id != "chloe" and worker_id not in get_worker_ids():
                self._send_json({"error": "UNKNOWN_WORKER"}, 404)
                return
            if not objective:
                self._send_json({"error": "OBJECTIVE_REQUIRED"}, 400)
                return
            try:
                frequency_minutes = int(frequency_minutes)
                if frequency_minutes < 5:
                    raise ValueError()
            except Exception:
                self._send_json({"error": "INVALID_FREQUENCY"}, 400)
                return
            result = run_automation_bridge(
                "create", worker_id=worker_id, objective=objective,
                frequency_minutes=frequency_minutes, enabled=True,
                notify_slack=bool(body.get("notifySlack")), client_id=client_id,
            )
            self._send_json(result)
        elif path.startswith("/api/automations/") and path.endswith("/toggle"):
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            automation_id = path.split("/")[3]
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            enabled = bool(body.get("enabled"))
            if enabled:
                block = subscription_blocks_mission(client_id)
                if block:
                    self._send_json({"error": "SUBSCRIPTION_REQUIRED", "detail": block}, 402)
                    return
            result = run_automation_bridge("toggle", automation_id=automation_id, enabled=enabled, client_id=client_id)
            self._send_json({"automations": result} if isinstance(result, list) else result)
        elif path.startswith("/api/automations/") and path.endswith("/run"):
            # "Executer maintenant" reel : force CETTE automatisation
            # tout de suite, sans regarder son echeance (voir Automation-
            # Bridge.ps1 -Action run) — avant ce correctif, le bouton
            # passait par tick, qui ignore silencieusement une
            # automatisation pas encore due (ex : deja executee par le
            # cron dans les 15 dernieres minutes), et le clic ne
            # produisait alors aucun effet visible ni message d'erreur.
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            block = subscription_blocks_mission(client_id)
            if block:
                self._send_json({"error": "SUBSCRIPTION_REQUIRED", "detail": block}, 402)
                return
            automation_id = path.split("/")[3]
            result = run_automation_bridge("run", automation_id=automation_id, client_id=client_id)
            self._send_json(result)
        elif path == "/api/automations/tick":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            block = subscription_blocks_mission(client_id)
            if block:
                self._send_json({"error": "SUBSCRIPTION_REQUIRED", "detail": block}, 402)
                return
            result = run_automation_bridge("tick", client_id=client_id)
            self._send_json({"ran": result} if isinstance(result, list) else result)
        elif path == "/api/integrations/apikey/generate":
            # Regenerer REVOQUE l'ancienne cle immediatement (un seul
            # jeton actif a la fois, comme un mot de passe d'application) :
            # la valeur en clair n'est renvoyee qu'UNE FOIS, jamais
            # re-consultable ensuite (seul le prefixe reste affiche).
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            raw_key, key_hash = _generate_api_key()
            _save_client_apikey(client_id, key_hash, raw_key[:12] + "…")
            self._send_json({"apiKey": raw_key})
        elif path == "/api/integrations/apikey/revoke":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            _remove_client_apikey(client_id)
            self._send_json({"ok": True})
        elif path == "/api/integrations/webhook":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            url = (body.get("url") or "").strip()
            if not url:
                _remove_client_webhook(client_id)
                self._send_json({"url": None, "secret": None})
                return
            if not (url.startswith("https://") or url.startswith("http://")):
                self._send_json({"error": "INVALID_URL"}, 400)
                return
            if len(url) > 2000:
                self._send_json({"error": "VALUE_TOO_LONG"}, 400)
                return
            secret = _save_client_webhook(client_id, url)
            self._send_json({"url": url, "secret": secret})
        elif path == "/api/public/v1/missions":
            # Point d'entree Zapier/Make (et tout outil generique compatible
            # webhooks/HTTP) : une mission reelle, soumise avec la meme cle
            # API que le client a generee depuis son tableau de bord — memes
            # regles que le reste de la plateforme (abonnement/credits,
            # isolation stricte par client), juste un autre point d'entree
            # que le navigateur.
            raw_key = self._public_api_key()
            client_id = _find_client_by_api_key(raw_key)
            if not client_id:
                self._send_json({"error": "INVALID_API_KEY"}, 401)
                return
            if public_api_throttled(client_id):
                self._send_json({"error": "TOO_MANY_REQUESTS"}, 429)
                return
            block = subscription_blocks_mission(client_id)
            if block:
                self._send_json({"error": "SUBSCRIPTION_REQUIRED", "detail": block}, 402)
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            objective = (body.get("request") or body.get("objective") or "").strip()
            if not objective:
                self._send_json({"error": "REQUEST_REQUIRED"}, 400)
                return
            worker_id = (body.get("worker") or "").strip().lower()
            if worker_id and worker_id not in get_worker_ids():
                self._send_json({"error": "UNKNOWN_WORKER"}, 404)
                return
            result = submit_task_limited(objective, worker_id=worker_id or "chloe", client_id=client_id)
            self._send_json(_summarize_mission_result(result))
        elif path == "/api/connectors/auto-approve/toggle":
            # Pre-autorisation globale : quand activee, les actions
            # d'ecriture proposees par un Worker s'executent pour de vrai
            # sans attendre de confirmation manuelle a chaque fois — un
            # choix explicite et reversible du client, jamais la valeur
            # par defaut.
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            _save_client_autoapprove(client_id, bool(body.get("enabled")))
            self._send_json({"autoApprove": _load_client_autoapprove(client_id)})
        elif path.startswith("/api/connectors/") and path.endswith("/toggle"):
            # Choisir quels connecteurs on veut pour son compte est une
            # preference, pas une mission executee : compte requis (comme
            # le profil), mais pas de credit consomme ni de blocage
            # d'abonnement — aucun appel externe reel n'est jamais
            # declenche par cette action (liveExecutionEnabled reste
            # global, decide par Kader, jamais par un client).
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            connector_id = path.split("/")[3]
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            result = toggle_client_connector(client_id, connector_id, bool(body.get("enabled")))
            self._send_json(result, 404 if result.get("error") == "UNKNOWN_CONNECTOR" else 200)
        elif path.startswith("/api/connectors/") and path.endswith("/credential"):
            # Le client connecte SON PROPRE compte (Slack, HubSpot, Gmail...) :
            # la valeur est chiffree immediatement (Store-Client-Credential-
            # Bridge.ps1) puis jamais renvoyee en clair, meme a lui-meme.
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            provider = path.split("/")[3]
            if provider not in CLIENT_CONNECTOR_PROVIDERS:
                self._send_json({"error": "UNKNOWN_PROVIDER"}, 404)
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            if isinstance(body.get("fields"), dict):
                payload, status = connect_client_tool(client_id, provider, body["fields"])
                self._send_json(payload, status)
                return
            value = (body.get("value") or "").strip()
            if len(value) > 4000:
                self._send_json({"error": "VALUE_TOO_LONG"}, 400)
                return
            # Coller une cle/un jeton est reserve au proprietaire : les
            # clients ne sont pas informaticiens et se connectent avec
            # leur propre compte (OAuth, /oauth/<fournisseur>/start).
            # Deconnecter (valeur vide) reste permis a tous.
            if value and client_id != DASHBOARD_CLIENT_ID:
                self._send_json({"error": "MANUAL_KEY_NOT_ALLOWED"}, 403)
                return
            result = store_client_connector_credential(client_id, provider, value)
            self._send_json(result, 200 if result.get("ok") else 400)
        elif path.startswith("/api/connectors/") and path.endswith("/interest"):
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            provider = path.split("/")[3]
            if provider not in CLIENT_CONNECTOR_PROVIDERS:
                self._send_json({"error": "UNKNOWN_PROVIDER"}, 404)
                return
            record_connector_interest(client_id, provider)
            self._send_json({"ok": True})
        elif path.startswith("/api/connectors/") and path.endswith("/test"):
            # Re-verifie une connexion deja enregistree (bouton "Tester").
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            provider = path.split("/")[3]
            if provider not in CLIENT_CONNECTOR_PROVIDERS or provider not in get_client_configured_providers(client_id):
                self._send_json({"error": "NOT_CONNECTED"}, 404)
                return
            payload, status = verify_client_tool(client_id, provider, just_saved=False)
            self._send_json(payload, status)
        elif path == "/api/billing/plan":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            plan_id = (body.get("planId") or "").strip().lower()
            interval = (body.get("interval") or "month").strip().lower()
            if interval not in ("month", "year"):
                interval = "month"
            if plan_id not in PLAN_CATALOG:
                self._send_json({"error": "UNKNOWN_PLAN"}, 400)
                return
            if plan_id in PAID_PLANS_WITH_CHECKOUT and client_id != DASHBOARD_CLIENT_ID and not account_email_verified(client_id):
                self._send_json({"error": "EMAIL_NOT_VERIFIED"}, 403)
                return

            # Plans payants : si Stripe est configure, on passe par une
            # vraie Checkout Session hebergee par Stripe (le plan local
            # n'est active qu'APRES confirmation du paiement, voir
            # /api/billing/stripe-confirm) plutot que de basculer le
            # plan instantanement. Essai (gratuit) et Enterprise (sur
            # devis) restent toujours en bascule directe.
            if plan_id in PAID_PLANS_WITH_CHECKOUT:
                stripe_status = run_stripe_bridge("status")
                if stripe_status.get("Configured"):
                    success_url = PUBLIC_BASE_URL + "/?billing_checkout=success&session_id={CHECKOUT_SESSION_ID}"
                    cancel_url = PUBLIC_BASE_URL + "/?billing_checkout=cancel"
                    checkout = run_stripe_bridge(
                        "create-checkout", plan_id=plan_id,
                        success_url=success_url, cancel_url=cancel_url,
                        interval=interval, client_id=client_id,
                    )
                    if checkout.get("Status") == "SUCCESS":
                        self._send_json({"checkoutUrl": checkout["CheckoutUrl"], "sessionId": checkout["SessionId"]})
                    else:
                        self._send_json({"error": "STRIPE_CHECKOUT_FAILED", "detail": checkout.get("Detail") or checkout.get("Status")}, 400)
                    return

            result = set_billing_plan(plan_id, client_id=client_id)
            if "error" in result:
                self._send_json(result, 400)
            else:
                self._send_json(result)
        elif path == "/api/billing/stripe-confirm":
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            session_id = (body.get("sessionId") or "").strip()
            if not session_id:
                self._send_json({"error": "SESSION_ID_REQUIRED"}, 400)
                return
            confirmation = run_stripe_bridge("confirm", session_id=session_id)
            if confirmation.get("Status") != "SUCCESS":
                self._send_json({"error": "STRIPE_CONFIRM_FAILED", "detail": confirmation.get("Detail") or confirmation.get("Status")}, 400)
                return
            if not confirmation.get("Paid") or confirmation.get("PlanId") not in PLAN_CATALOG:
                self._send_json({"error": "PAYMENT_NOT_CONFIRMED", "detail": confirmation.get("PaymentStatus")}, 400)
                return
            # Le ClientId qui a paye vient des metadata Stripe (fiable, pose
            # a la creation de la session) — le cookie de session encore
            # present sert seulement de repli pour d'anciennes sessions
            # creees avant ce champ.
            client_id = confirmation.get("ClientId") or self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            self._send_json(set_billing_plan(
                confirmation["PlanId"], via_stripe=True,
                stripe_subscription_id=confirmation.get("SubscriptionId"),
                client_id=client_id,
            ))
        elif path == "/api/profile":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            self._send_json(save_company_profile(body, client_id=client_id))
        elif path == "/api/trial/mission":
            # Public, sans porte (voir commentaire pres de run_trial_mission) :
            # execute une VRAIE mission, plafonnee, sur un ClientId isole.
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            worker_id = (body.get("workerId") or "chloe").strip().lower()
            objective = (body.get("objective") or "").strip()[:TRIAL_OBJECTIVE_MAX_LEN]
            if not objective:
                self._send_json({"error": "OBJECTIVE_REQUIRED"}, 400)
                return
            if worker_id != "chloe" and worker_id not in get_worker_ids():
                self._send_json({"error": "UNKNOWN_WORKER"}, 404)
                return
            payload, status = run_trial_mission(worker_id, objective, self._client_ip())
            self._send_json(payload, status)
        elif path == "/api/billing/cancel":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            self._send_json(cancel_billing_plan(client_id))
        elif path == "/api/billing/recharge":
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            try:
                amount = int(body.get("amount"))
                if amount <= 0:
                    raise ValueError()
            except Exception:
                self._send_json({"error": "INVALID_AMOUNT"}, 400)
                return
            result = recharge_billing_credits(amount, client_id)
            self._send_json(result, 403 if result.get("error") else 200)
        else:
            self._send_json({"error": "NOT_FOUND"}, 404)

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)

        if route_requires_gate(path) and not self._gate_authenticated():
            self._send_gate_required()
            return

        if path.startswith("/api/automations/"):
            client_id = self._resolve_client_id()
            if not client_id:
                self._send_account_required()
                return
            automation_id = path.split("/")[3]
            result = run_automation_bridge("delete", automation_id=automation_id, client_id=client_id)
            self._send_json(result)
        else:
            self._send_json({"error": "NOT_FOUND"}, 404)


if __name__ == "__main__":
    port = int(os.environ.get("BK_PORT", "8787"))
    if REQUIRE_GATE and not gate_is_enabled():
        raise SystemExit("BK_REQUIRE_GATE=1 mais aucune porte d'acces definie (BK_GATE_HASH ou dashboard/.gate/password.hash) : demarrage refuse.")
    _load_sessions()
    reap_async_jobs(boot=True)
    purge_old_task_files()
    server = ThreadingHTTPServer((os.environ.get("BK_LISTEN_HOST", "127.0.0.1"), port), Handler)
    print(f"BK-AI-WORKERS dashboard sur http://{os.environ.get('BK_LISTEN_HOST', '127.0.0.1')}:{port}")
    if not gate_is_enabled():
        print("ATTENTION : aucune porte d'acces definie (.secrets\\Set-DashboardGate.ps1) — les vues operationnelles sont ouvertes a quiconque atteint ce serveur.")
    PHONE_AGENT.warm_up()
    TRUST.start(port, os.environ.get("BK_LISTEN_HOST", "127.0.0.1"))  # mesure de disponibilite toutes les 60 s
    server.serve_forever()
