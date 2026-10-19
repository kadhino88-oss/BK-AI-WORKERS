# -*- coding: utf-8 -*-
"""Réglages du moteur de projets (docs/AUTONOMY-ENGINE.md, sections 2.5, 3.7, 6) : PROJECT-LIMITS.json, PROJECT-PHASES.json, LEVELS.json.

Tout est lu à la demande depuis les fichiers versionnés (le propriétaire règle ces fichiers sans toucher au code). Chaque valeur a une
valeur par défaut sûre ici : un fichier absent ou illisible ne désactive jamais un plafond. Module PUR (aucune dépendance au serveur).
"""
import json
import math
import os

DEFAULT_LIMITS = {
    "runners": {"global": 2, "perClient": 1, "perClientByPlan": {"scale": 2, "enterprise": 2}},
    "minAvailableMemoryMb": 700,
    "activeProjects": {"essai": 0, "solo": 1, "trio": 1, "equipe": 2, "pro": 3, "scale": 6, "enterprise": 10, "starter": 1, "business": 2},
    "queuedProjects": 3,
    "createPerDay": {"essai": 0, "solo": 3, "trio": 5, "equipe": 8, "pro": 12, "scale": 30, "enterprise": 60, "starter": 3, "business": 8},
    "maxDurationHours": {"essai": 0, "solo": 72, "trio": 72, "equipe": 168, "pro": 168, "scale": 336, "enterprise": 336, "starter": 72, "business": 168},
    "absoluteMaxChf": {"essai": 0, "solo": 8, "trio": 12, "equipe": 20, "pro": 30, "scale": 120, "enterprise": 200, "starter": 8, "business": 20},
    "workspaceMb": {"default": 100, "scale": 300, "enterprise": 300},
    "clientDiskMb": {"default": 1024, "scale": 5120, "enterprise": 5120},
    "chloeDelegation": {"trio": "hired_only", "default": "all"},
    "step": {"softDeadlineSec": 480, "hardDeadlineSec": 540, "maxAttempts": 3, "maxStepsPerProject": 120, "maxPlanSteps": 40,
             "maxCriteria": 25, "maxAddedSteps": 8, "maxReplans": 3, "maxFixRounds": 2, "noProgressLimit": 3,
             "retryLaterDelaysSec": [60, 300, 1200], "heartbeatSec": 20, "noHeartbeatSec": 120, "killGraceSec": 15},
    "budget": {"creditCostChf": 0.0375, "minStartCredits": 6, "capMargin": 1.25, "defaultCap": {"standard": 150, "approfondi": 300},
               "verifyShareOfCap": 0.15},
    "input": {"goalMaxChars": 4000, "messageMaxChars": 4000, "inputFilesMax": 10, "inputFilesMaxBytes": 10485760,
              "inputFileExtensions": ["txt", "csv", "md", "json", "pdf", "docx", "xlsx", "png", "jpg", "jpeg", "webp", "svg"]},
    "approvals": {"ttlDays": 7, "reminderDays": [1, 3], "pendingPerProject": 50, "pendingPerClient": 200, "paramsMaxBytes": 8192,
                  "batchMax": 50, "executeSpacingSec": 1.0, "executePerMinutePerClient": 25, "highRecipients": 20},
    "lifecycle": {"idleExpiryDays": 14, "idleReminderDays": [3, 10], "retentionDays": 90, "cancelledDownloadDays": 7},
    "rates": {"create": [6, 3600], "messages": [60, 3600], "approvals": [300, 3600], "control": [60, 3600], "progress": [120, 60],
              "get": [120, 60], "download": [120, 3600], "zip": [10, 3600], "sitePreview": [20, 3600], "triage": [20, 3600]},
    "notifications": {"perTypePerProjectPerHourMax": 1, "perClientPerDayMax": 10, "approvalNeededMinGapMin": 30},
    "abuse": {"spendSpikeFactor": 3.0, "capFractionAlert": 0.8, "capFractionWindowMin": 30},
}

DEFAULT_PHASES = {
    "phases": {
        "plan": {"levelRef": "approfondi", "maxIterations": 8, "maxCostChf": 0.60, "webMaxUses": 6, "callTimeoutSec": 420},
        "execute": {"levelRef": "equilibre", "maxIterations": 24, "maxCostChf": 0.80, "webMaxUses": 8, "callTimeoutSec": 300},
        "execute_bulk": {"levelRef": "rapide", "maxIterations": 30, "maxCostChf": 0.25, "webMaxUses": 6, "callTimeoutSec": 180},
        "execute_deep": {"levelRef": "approfondi", "maxIterations": 20, "maxCostChf": 1.50, "webMaxUses": 12, "callTimeoutSec": 420},
        "verify": {"levelRef": "approfondi", "maxIterations": 16, "maxCostChf": 0.80, "webMaxUses": 4, "callTimeoutSec": 420},
        "replan": {"levelRef": "approfondi", "maxIterations": 6, "maxCostChf": 0.40, "webMaxUses": 4, "callTimeoutSec": 420},
        "consolidate": {"levelRef": "equilibre", "maxIterations": 8, "maxCostChf": 0.40, "webMaxUses": 0, "callTimeoutSec": 300},
    },
    "kindToPhase": {"plan": "plan", "execute": "execute", "fix": "execute", "verify": "verify", "replan": "replan",
                    "consolidate": "consolidate", "answer": "execute_bulk"},
    "answer": {"maxIterations": 4, "maxCostChf": 0.10},
    "levelUpgrade": {"approfondi": {"execute": "approfondi"}},
    "stepCeilingMinChf": 0.05,
}

DEFAULT_LEVELS = {
    "rapide": {"model": "claude-haiku-5-5", "effort": "low"},
    "equilibre": {"model": "claude-sonnet-5-5", "effort": "medium"},
    "approfondi": {"model": "claude-opus-5-5", "effort": "high"},
}


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _merge(base, over):
    """Fusion récursive : les clés du fichier remplacent celles par défaut ; une clé absente garde sa valeur par défaut."""
    if not isinstance(base, dict) or not isinstance(over, dict):
        return over if over is not None else base
    out = dict(base)
    for k, v in over.items():
        if k.startswith("_"):
            continue
        out[k] = _merge(base[k], v) if k in base and isinstance(base[k], dict) and isinstance(v, dict) else v
    return out


def load_limits(root, env=None):
    env = os.environ if env is None else env
    lim = _merge(DEFAULT_LIMITS, read_json(os.path.join(root, "core", "projects", "PROJECT-LIMITS.json"), {}) or {})
    for var, path in (("BK_PROJECT_STEPS_GLOBAL", ("runners", "global")), ("BK_PROJECT_STEPS_PER_CLIENT", ("runners", "perClient"))):
        raw = str(env.get(var) or "").strip()
        if raw.isdigit() and int(raw) >= 1:
            lim[path[0]][path[1]] = int(raw)
    return lim


def load_phases(root):
    return _merge(DEFAULT_PHASES, read_json(os.path.join(root, "core", "ai", "PROJECT-PHASES.json"), {}) or {})


def load_levels(root):
    data = read_json(os.path.join(root, "core", "ai", "LEVELS.json"), {}) or {}
    lv = dict(DEFAULT_LEVELS)
    for name, cfg in (data.get("levels") or {}).items():
        if isinstance(cfg, dict) and cfg.get("model"):
            lv[name] = {"model": str(cfg["model"]), "effort": cfg.get("effort")}
    return lv


def plan_value(table, plan_id, default=0):
    """Valeur d'une table « par forfait » (activeProjects…) ; forfait inconnu = valeur du plus restreint connu, jamais illimité."""
    if not isinstance(table, dict):
        return default
    if plan_id in table:
        return table[plan_id]
    if "default" in table:
        return table["default"]
    return default


def runners_per_client(limits, plan_id):
    r = limits["runners"]
    return int((r.get("perClientByPlan") or {}).get(plan_id, r["perClient"]))


def credits_for_chf(chf, credit_cost):
    """Crédits cumulés = ceil(CHF / coût du crédit) ; jamais de crédit fractionnaire (docs 6.1)."""
    if not chf or chf <= 0:
        return 0
    return int(math.ceil(round(float(chf) / float(credit_cost), 9)))


def phase_for(root_cfg, kind, effort="normal", level="standard"):
    """Phase, modèle, effort et plafonds d'une étape.

    root_cfg = {"phases","levels"} (load_phases / load_levels). kind : plan, execute, fix, verify, replan, consolidate, answer.
    effort : normal, bulk ou deep (champ de l'étape du plan). level : standard ou approfondi (niveau choisi pour le projet)."""
    phases = root_cfg["phases"]
    name = phases["kindToPhase"].get(kind, "execute")
    if kind in ("execute", "fix"):
        if effort == "bulk":
            name = "execute_bulk"
        elif effort == "deep":
            name = "execute_deep"
    cfg = dict(phases["phases"][name])
    if kind == "answer":
        cfg.update({k: v for k, v in (phases.get("answer") or {}).items() if k in ("maxIterations", "maxCostChf")})
        cfg["webMaxUses"] = 0
    up = (phases.get("levelUpgrade") or {}).get(level) or {}
    if name in up:
        cfg["levelRef"] = up[name]
    lvl = root_cfg["levels"].get(cfg["levelRef"]) or DEFAULT_LEVELS.get(cfg["levelRef"]) or DEFAULT_LEVELS["equilibre"]
    cfg.update({"phase": name, "model": lvl["model"], "effort": lvl.get("effort")})
    return cfg
