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
import subprocess
import datetime
import hashlib
import hmac
import secrets
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, unquote

ROOT = r"C:\Users\FEUCOM\BK-AI-WORKERS"
DASHBOARD_DIR = os.path.join(ROOT, "dashboard")
WORKERS_DIR = os.path.join(ROOT, "workers")
CHLOE_DIR = os.path.join(ROOT, "chloe")
TASKS_DIR = os.path.join(ROOT, "runtime", "tasks")
CAPABILITY_MATRIX_PATH = os.path.join(ROOT, "core", "permissions", "capability-matrix", "CAPABILITY-MATRIX.json")
SUBMIT_SCRIPT = os.path.join(DASHBOARD_DIR, "Submit-Task.ps1")
AUTOMATION_BRIDGE_SCRIPT = os.path.join(DASHBOARD_DIR, "Automation-Bridge.ps1")
STRIPE_BRIDGE_SCRIPT = os.path.join(DASHBOARD_DIR, "Stripe-Bridge.ps1")
WORKER_RUNTIME_REGISTRY_PATH = os.path.join(ROOT, "core", "runtime", "worker-runtime", "WORKER-REGISTRY.json")
CONNECTOR_CATALOG_PATH = os.path.join(ROOT, "core", "runtime", "controlled-connectors", "CONTROLLED-CONNECTOR-CATALOG.json")

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
REQUIRE_GATE = os.environ.get("BK_REQUIRE_GATE") == "1"
GATE_SESSION_TTL_SECONDS = 60 * 60 * 12  # 12h
GATE_SESSIONS = {}  # token -> expiry (epoch seconds)

GATE_PROTECTED_PREFIXES = (
    "/api/chloe/task",
    "/api/chloe/plan",
    "/api/automations",
    "/api/billing",
    "/api/analytics",
    "/api/profile",
)
# /api/workers/<id>/task et /task est protege, mais /api/workers/<id>
# (fiche) et /api/workers (catalogue) restent publics — verifie via une
# fonction dediee plutot qu'un prefixe, car ils partagent la racine.


def gate_is_enabled():
    return os.path.isfile(GATE_HASH_PATH)


def verify_gate_password(password):
    try:
        with open(GATE_HASH_PATH, encoding="utf-8") as f:
            salt_hex, hash_hex, iterations = f.read().strip().split(":")
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(hash_hex)
        computed = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, int(iterations), dklen=32)
        return hmac.compare_digest(computed, expected)
    except Exception:
        return False


def gate_create_session():
    token = secrets.token_urlsafe(32)
    GATE_SESSIONS[token] = time.time() + GATE_SESSION_TTL_SECONDS
    return token


def gate_check_session(token):
    if not token:
        return False
    expiry = GATE_SESSIONS.get(token)
    if not expiry:
        return False
    if time.time() > expiry:
        del GATE_SESSIONS[token]
        return False
    return True


def gate_clear_session(token):
    GATE_SESSIONS.pop(token, None)


def route_requires_gate(path):
    if not gate_is_enabled():
        return False
    if path.startswith(GATE_PROTECTED_PREFIXES):
        return True
    if path.startswith("/api/workers/") and path.endswith("/task"):
        return True
    return False

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
    "sophie": "RH & Recrutement",
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
        "tools": [c.get("tool") for c in caps],
    }


def get_worker_activity(worker_id_upper, limit=8):
    """Lit les vraies taches deja produites par le systeme (runtime/tasks/*.json)."""
    records = []
    if os.path.isdir(TASKS_DIR):
        for fname in os.listdir(TASKS_DIR):
            if not fname.startswith("TASK-") or not fname.endswith(".json"):
                continue
            data = load_json(os.path.join(TASKS_DIR, fname))
            if not data or data.get("Worker") != worker_id_upper:
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


def submit_task(worker_hint_text, worker_id="", plan_only=False):
    """Appelle le vrai pipeline via Submit-Task.ps1 (PowerShell).
    Le resultat est ecrit par le script dans un fichier temporaire
    dedie (evite tout parsing fragile de stdout, pollue par les
    bannieres Write-Host des scripts imbriques)."""
    import tempfile, uuid

    out_file = os.path.join(tempfile.gettempdir(), f"bkaiw-dashboard-{uuid.uuid4().hex}.json")
    try:
        cmd = [
            "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", SUBMIT_SCRIPT,
            "-Request", worker_hint_text,
            "-OutFile", out_file,
        ]
        if worker_id:
            cmd += ["-WorkerId", worker_id]
        if plan_only:
            cmd += ["-PlanOnly"]
        proc = subprocess.run(
            cmd,
            capture_output=True, timeout=60
        )
        stderr = (proc.stderr or b"").decode("utf-8", errors="replace")
        stdout = (proc.stdout or b"").decode("utf-8", errors="replace")

        if os.path.isfile(out_file):
            with open(out_file, encoding="utf-8-sig") as f:
                return json.load(f)

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


def run_automation_bridge(action, **kwargs):
    """Appelle Automation-Bridge.ps1 (creer/lister/activer/executer une
    automatisation). Meme convention que submit_task : resultat ecrit
    dans un fichier temporaire dedie plutot que parse depuis stdout."""
    import tempfile, uuid

    out_file = os.path.join(tempfile.gettempdir(), f"bkaiw-automation-{uuid.uuid4().hex}.json")
    try:
        cmd = [
            "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
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
            "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
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


def get_connector_catalog():
    """Lit le VRAI catalogue de connecteurs (aucun appel externe reel
    n'est jamais fait tant que liveExecutionEnabled est false — voir
    core/runtime/controlled-connectors/CONTROLLED-CONNECTOR-CATALOG.json)."""
    data = load_json(CONNECTOR_CATALOG_PATH, {"liveExecutionEnabled": False, "connectors": []})
    connectors = data.get("connectors", [])
    by_category = {}
    for c in connectors:
        by_category.setdefault(c.get("category", "AUTRE"), []).append({
            "connectorId": c.get("connectorId"),
            "provider": c.get("provider"),
            "enabled": c.get("enabled", False),
            "operations": c.get("operations", []),
        })
    return {
        "liveExecutionEnabled": data.get("liveExecutionEnabled", False),
        "totalConnectors": len(connectors),
        "enabledConnectors": len([c for c in connectors if c.get("enabled")]),
        # Nombre de connecteurs REELLEMENT configures (un vrai secret
        # existe dans .secrets/, pas juste "autorise" dans le catalogue)
        # — c'est ce chiffre-la qui a du sens pour une preuve de
        # confiance publique, pas le total de types supportes.
        "configuredReal": get_configured_connectors_count(),
        "categories": by_category,
    }


def get_configured_connectors_count():
    secrets_dir = os.path.join(ROOT, ".secrets")
    try:
        return len([f for f in os.listdir(secrets_dir) if f.endswith(".secret.dpapi")])
    except Exception:
        return 0


# Hypothese de temps manuel evite par mission traitee par un Worker —
# volontairement conservatrice et affichee comme estimation, jamais
# comme un fait mesure (aucun chronometrage reel n'existe cote client).
ESTIMATED_MINUTES_SAVED_PER_MISSION = 12


# Tarifs publics indicatifs (USD par million de tokens : entree, sortie).
# Un modele absent de cette table n'a PAS de cout affiche (jamais devine).
MODEL_PRICING_USD_PER_MTOK = {
    "claude-haiku-4-5-20251001": (1.00, 5.00),
    "gpt-4o-mini": (0.15, 0.60),
}
AI_PROVIDERS_PATH = os.path.join(ROOT, "core", "ai", "AI-PROVIDERS.json")


def configured_model_for(provider):
    """Modele reellement utilise par defaut par un fournisseur (adaptateurs)."""
    cfg = load_json(AI_PROVIDERS_PATH, {}) or {}
    if provider == "ANTHROPIC":
        return ((cfg.get("providers") or {}).get("anthropic") or {}).get("model") or "claude-haiku-4-5-20251001"
    if provider == "OPENAI":
        return "gpt-4o-mini"
    return None


def get_ai_cost_summary():
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
            res = data.get("Result") or {}
            usage = res.get("Usage") if isinstance(res, dict) else None
            if not usage:
                continue
            i, o = int(usage.get("input_tokens") or 0), int(usage.get("output_tokens") or 0)
            input_tokens += i
            output_tokens += o
            missions += 1
            price = MODEL_PRICING_USD_PER_MTOK.get(configured_model_for(res.get("Provider")))
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


def get_analytics():
    """Agrege les VRAIES donnees d'usage (runtime/tasks/, automatisations).
    Rien n'est invente : chaque chiffre vient d'un fichier reellement
    ecrit par le systeme. Le seul chiffre "estime" (temps gagne) est
    explicitement marque comme tel, jamais presente comme mesure."""
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
            total_missions += 1
            status = data.get("Status", "INCONNU")
            worker = data.get("Worker", "INCONNU")
            by_status[status] = by_status.get(status, 0) + 1
            by_worker[worker] = by_worker.get(worker, 0) + 1
            created = data.get("CreatedAtUtc", "")
            day = created[:10] if len(created) >= 10 else "inconnu"
            timeline[day] = timeline.get(day, 0) + 1

    automations = []
    try:
        with open(os.path.join(ROOT, "core", "automation", "data", "automations.json"), encoding="utf-8-sig") as f:
            automations = json.load(f) or []
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
        "aiCost": get_ai_cost_summary(),
        "estimatedMinutesSaved": executed_count * ESTIMATED_MINUTES_SAVED_PER_MISSION,
        "estimatedMinutesSavedNote": f"Estimation indicative : {ESTIMATED_MINUTES_SAVED_PER_MISSION} min/mission traitee (hypothese conservatrice, non mesuree individuellement).",
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

BILLING_DATA_PATH = os.path.join(ROOT, "core", "billing", "data", "subscription.json")

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


def _billing_load():
    state = load_json(BILLING_DATA_PATH)
    if not state or "planId" not in state:
        state = _billing_default_state()
        _billing_save(state)
    return state


def _billing_save(state):
    os.makedirs(os.path.dirname(BILLING_DATA_PATH), exist_ok=True)
    with open(BILLING_DATA_PATH, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)


def get_billing():
    state = _billing_load()
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


def set_billing_plan(plan_id, via_stripe=False, stripe_subscription_id=None):
    if plan_id not in PLAN_CATALOG:
        return {"error": "UNKNOWN_PLAN"}
    state = _billing_load()
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
    _billing_save(state)
    return get_billing()


def cancel_billing_plan():
    state = _billing_load()
    old_name = PLAN_CATALOG.get(state.get("planId", "essai"), PLAN_CATALOG["essai"])["name"]
    now = datetime.datetime.utcnow().isoformat() + "Z"

    subscription_id = state.get("stripeSubscriptionId")
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

    state["planId"] = "essai"
    state["cycleStartUtc"] = now
    state["extraCredits"] = 0
    state["stripeSubscriptionId"] = None
    state.setdefault("history", []).append({
        "dateUtc": now,
        "event": f"Abonnement annule ({old_name}) — retour au plan Essai ({label}).",
    })
    _billing_save(state)
    return get_billing()


def recharge_billing_credits(amount):
    state = _billing_load()
    now = datetime.datetime.utcnow().isoformat() + "Z"
    state["extraCredits"] = int(state.get("extraCredits") or 0) + amount
    state.setdefault("history", []).append({
        "dateUtc": now,
        "event": f"Recharge volontaire de {amount} credits (simulation, aucun paiement reel — pas de majoration automatique).",
    })
    _billing_save(state)
    return get_billing()


# ---------------------------------------------------------------------
# PROFIL ENTREPRISE (contexte transmis aux Workers dans leurs prompts).
# Un fichier par ClientId (core/profile/data/<ClientId>.json) : aujourd'hui
# un seul client (CLI-DASHBOARD), mais deja pret pour du multi-clients.
# ---------------------------------------------------------------------

PROFILE_DIR = os.path.join(ROOT, "core", "profile", "data")
DASHBOARD_CLIENT_ID = "CLI-DASHBOARD"
PROFILE_FIELDS = {"companyName": 120, "sector": 120, "description": 600}


def get_company_profile(client_id=DASHBOARD_CLIENT_ID):
    return load_json(os.path.join(PROFILE_DIR, f"{client_id}.json"), {}) or {}


def save_company_profile(data, client_id=DASHBOARD_CLIENT_ID):
    profile = {}
    for key, max_len in PROFILE_FIELDS.items():
        value = str(data.get(key) or "").strip()[:max_len]
        if value:
            profile[key] = value
    profile["updatedAtUtc"] = datetime.datetime.utcnow().isoformat() + "Z"
    os.makedirs(PROFILE_DIR, exist_ok=True)
    with open(os.path.join(PROFILE_DIR, f"{client_id}.json"), "w", encoding="utf-8") as f:
        json.dump(profile, f, ensure_ascii=False, indent=2)
    return profile


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
        with open(path, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _gate_token_from_cookie(self):
        cookie_header = self.headers.get("Cookie", "")
        for part in cookie_header.split(";"):
            part = part.strip()
            if part.startswith("bk_session="):
                return part[len("bk_session="):]
        return None

    def _gate_authenticated(self):
        return gate_check_session(self._gate_token_from_cookie())

    def _send_gate_required(self):
        self._send_json({"error": "GATE_REQUIRED"}, 401)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)

        if route_requires_gate(path) and not self._gate_authenticated():
            self._send_gate_required()
            return

        if path == "/" or path == "/index.html":
            self._send_file(os.path.join(DASHBOARD_DIR, "index.html"), "text/html; charset=utf-8")
        elif path == "/style.css":
            self._send_file(os.path.join(DASHBOARD_DIR, "style.css"), "text/css; charset=utf-8")
        elif path == "/app.js":
            self._send_file(os.path.join(DASHBOARD_DIR, "app.js"), "application/javascript; charset=utf-8")
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
            if wid not in get_worker_ids():
                self._send_json({"error": "UNKNOWN_WORKER"}, 404)
                return
            self._send_json({"activity": get_worker_activity(wid.upper())})
        elif path.startswith("/api/workers/"):
            wid = path.split("/")[3]
            if wid not in get_worker_ids():
                self._send_json({"error": "UNKNOWN_WORKER"}, 404)
                return
            self._send_json(build_worker_summary(wid))
        elif path == "/api/connectors":
            self._send_json(get_connector_catalog())
        elif path == "/api/analytics":
            self._send_json(get_analytics())
        elif path == "/api/billing":
            self._send_json(get_billing())
        elif path == "/api/profile":
            self._send_json(get_company_profile())
        elif path == "/api/billing/stripe-status":
            result = run_stripe_bridge("status")
            self._send_json(result)
        elif path == "/api/automations":
            result = run_automation_bridge("list")
            self._send_json({"automations": result} if isinstance(result, list) else result)
        elif path.startswith("/api/automations/") and path.endswith("/runs"):
            automation_id = path.split("/")[3]
            result = run_automation_bridge("runs", automation_id=automation_id)
            self._send_json({"runs": result} if isinstance(result, list) else result)
        elif path == "/api/gate/status":
            self._send_json({"enabled": gate_is_enabled(), "authenticated": self._gate_authenticated()})
        else:
            self._send_json({"error": "NOT_FOUND"}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)

        if route_requires_gate(path) and not self._gate_authenticated():
            self._send_gate_required()
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
            if not verify_gate_password(password):
                self._send_json({"error": "INVALID_PASSWORD"}, 401)
                return
            token = gate_create_session()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Set-Cookie", f"bk_session={token}; HttpOnly; SameSite=Strict; Path=/; Max-Age={GATE_SESSION_TTL_SECONDS}")
            body_bytes = json.dumps({"ok": True}).encode("utf-8")
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            self.wfile.write(body_bytes)
            return
        elif path == "/api/gate/logout":
            gate_clear_session(self._gate_token_from_cookie())
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Set-Cookie", "bk_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0")
            body_bytes = json.dumps({"ok": True}).encode("utf-8")
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            self.wfile.write(body_bytes)
            return

        if path == "/api/chloe/task":
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
            result = submit_task(objective, worker_id="chloe")
            self._send_json(result)
        elif path == "/api/chloe/plan":
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
            result = submit_task(objective, worker_id="chloe", plan_only=True)
            self._send_json(result)
        elif path.startswith("/api/workers/") and path.endswith("/task"):
            wid = path.split("/")[3]
            if wid not in get_worker_ids():
                self._send_json({"error": "UNKNOWN_WORKER"}, 404)
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
            result = submit_task(objective, worker_id=wid)
            self._send_json(result)
        elif path == "/api/automations":
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
                notify_slack=bool(body.get("notifySlack")),
            )
            self._send_json(result)
        elif path.startswith("/api/automations/") and path.endswith("/toggle"):
            automation_id = path.split("/")[3]
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            result = run_automation_bridge("toggle", automation_id=automation_id, enabled=bool(body.get("enabled")))
            self._send_json({"automations": result} if isinstance(result, list) else result)
        elif path == "/api/automations/tick":
            result = run_automation_bridge("tick")
            self._send_json({"ran": result} if isinstance(result, list) else result)
        elif path == "/api/billing/plan":
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            plan_id = (body.get("planId") or "").strip().lower()
            if plan_id not in PLAN_CATALOG:
                self._send_json({"error": "UNKNOWN_PLAN"}, 400)
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
                    )
                    if checkout.get("Status") == "SUCCESS":
                        self._send_json({"checkoutUrl": checkout["CheckoutUrl"], "sessionId": checkout["SessionId"]})
                    else:
                        self._send_json({"error": "STRIPE_CHECKOUT_FAILED", "detail": checkout.get("Detail") or checkout.get("Status")}, 400)
                    return

            result = set_billing_plan(plan_id)
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
            self._send_json(set_billing_plan(
                confirmation["PlanId"], via_stripe=True,
                stripe_subscription_id=confirmation.get("SubscriptionId"),
            ))
        elif path == "/api/profile":
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {}
            self._send_json(save_company_profile(body))
        elif path == "/api/billing/cancel":
            self._send_json(cancel_billing_plan())
        elif path == "/api/billing/recharge":
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
            self._send_json(recharge_billing_credits(amount))
        else:
            self._send_json({"error": "NOT_FOUND"}, 404)

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)

        if route_requires_gate(path) and not self._gate_authenticated():
            self._send_gate_required()
            return

        if path.startswith("/api/automations/"):
            automation_id = path.split("/")[3]
            result = run_automation_bridge("delete", automation_id=automation_id)
            self._send_json(result)
        else:
            self._send_json({"error": "NOT_FOUND"}, 404)


if __name__ == "__main__":
    port = 8787
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"BK-AI-WORKERS dashboard sur http://127.0.0.1:{port}")
    if not gate_is_enabled():
        print("ATTENTION : aucune porte d'acces definie (.secrets\\Set-DashboardGate.ps1) — les vues operationnelles sont ouvertes a quiconque atteint ce serveur.")
    server.serve_forever()
