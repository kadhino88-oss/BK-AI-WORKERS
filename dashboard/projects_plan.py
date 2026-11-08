# -*- coding: utf-8 -*-
"""Plan d'un projet (schéma BK-PROJECT-PLAN-V1, docs/AUTONOMY-ENGINE.md section 1.2) : validation, normalisation, graphe.

Les règles du plan sont appliquées par le MOTEUR, pas par la bonne volonté du modèle : au plus 40 étapes et 25 critères ; chaque étape a un
Worker valide dans la portée du client ; dependsOn forme un graphe sans cycle ; chaque critère est couvert par au moins une étape ; chaque
critère « auto » a un contrôle d'un type connu du moteur, sinon il devient « rubric » (grille écrite appliquée par le vérificateur).

validate_plan(plan, scope) est aussi utilisé par le planificateur de Chloé (chloe/Chloe-Planner.ps1) : il renvoie la liste des erreurs en
français pour un nouvel essai du modèle. Module PUR : aucune dépendance au serveur.
"""
import copy
import re

import project_paths

SCHEMA = "BK-PROJECT-PLAN-V1"
MAX_STEPS = 40
MAX_CRITERIA = 25
STEP_ID_RE = re.compile(r"^S[0-9]{1,3}\Z")
CRITERION_ID_RE = re.compile(r"^C[A-Za-z0-9-]{0,18}\Z")
WORKER_RE = re.compile(r"^[a-z]{2,20}\Z")
EFFORTS = ("normal", "bulk", "deep")
BUILTIN_CHECK_TYPES = ("file_exists", "file_contains", "xlsx_check", "docx_check", "csv_check", "json_schema", "approval_executed", "count_matches")
SITE_CHECK_TYPES = ("site_check",)
_EXTRA_CHECK_TYPES = set()          # types ajoutés par d'autres modules (atelier de sites : site_check) via register_check_type


def register_check_type(name):
    _EXTRA_CHECK_TYPES.add(str(name))


def known_check_types():
    return set(BUILTIN_CHECK_TYPES) | _EXTRA_CHECK_TYPES


class PlanResult:
    def __init__(self, plan, errors, warnings):
        self.plan = plan
        self.errors = errors            # [{"code","path","detail"}] ; vide = valide
        self.warnings = warnings        # [{"code","path","detail"}] : corrections silencieuses du moteur (ex. critère auto -> rubric)

    @property
    def ok(self):
        return not self.errors

    def messages(self):
        return [e["detail"] for e in self.errors]

    def to_dict(self):
        return {"ok": self.ok, "errors": self.errors, "warnings": self.warnings}


def _s(value, limit):
    return str(value or "").strip()[:limit]


def _err(errors, code, path, detail):
    errors.append({"code": code, "path": path, "detail": detail})


def _str_list(value, limit_items, limit_chars):
    if not isinstance(value, list):
        return []
    out = []
    for v in value:
        if isinstance(v, str) and v.strip():
            out.append(v.strip()[:limit_chars])
        if len(out) >= limit_items:
            break
    return out


def topological_order(steps):
    """Ordre topologique (liste d'identifiants) d'étapes {id, dependsOn} ; None s'il y a un cycle. Stable : à égalité, l'ordre du plan."""
    ids = [s["id"] for s in steps]
    deps = {s["id"]: [d for d in s.get("dependsOn", []) if d in ids] for s in steps}
    indeg = {i: len(deps[i]) for i in ids}
    children = {i: [] for i in ids}
    for i in ids:
        for d in deps[i]:
            children[d].append(i)
    ready = [i for i in ids if indeg[i] == 0]
    order = []
    while ready:
        cur = ready.pop(0)
        order.append(cur)
        for c in children[cur]:
            indeg[c] -= 1
            if indeg[c] == 0:
                ready.append(c)
    return order if len(order) == len(ids) else None


def critical_path_lengths(steps):
    """Longueur (en nombre d'étapes) du chemin le plus long qui part de chaque étape vers l'aval : sert à trier les étapes prêtes."""
    ids = [s["id"] for s in steps]
    children = {i: [] for i in ids}
    for s in steps:
        for d in s.get("dependsOn", []):
            if d in children:
                children[d].append(s["id"])
    memo = {}

    def depth(i, stack=()):
        if i in memo:
            return memo[i]
        if i in stack:
            return 0
        best = 0
        for c in children[i]:
            best = max(best, depth(c, stack + (i,)))
        memo[i] = best + 1
        return memo[i]

    return {i: depth(i) for i in ids}


def validate_plan(plan, scope=None, *, known_workers=None, known_check_types_override=None, limits=None):
    """Valide et normalise un plan. `scope` = {"chloe": bool, "allowed": [ids], ...} (None : portée non vérifiée). `known_workers` : ensemble
    des identifiants de Workers qui existent (None : seul le format est vérifié). Renvoie un PlanResult ; .plan est la copie normalisée."""
    lim = limits or {}
    max_steps = int(lim.get("maxPlanSteps", MAX_STEPS))
    max_criteria = int(lim.get("maxCriteria", MAX_CRITERIA))
    errors, warnings = [], []
    if not isinstance(plan, dict):
        _err(errors, "PLAN_NOT_OBJECT", "plan", "Le plan doit être un objet JSON.")
        return PlanResult({}, errors, warnings)
    checks = set(known_check_types_override) if known_check_types_override is not None else known_check_types()
    allowed_workers = None
    if isinstance(scope, dict) and scope.get("allowed") is not None:
        allowed_workers = {str(w).lower() for w in scope.get("allowed") or []}
        if scope.get("chloe"):
            allowed_workers.add("chloe")
    out = {
        "schema": SCHEMA,
        "version": int(plan["version"]) if isinstance(plan.get("version"), int) and plan["version"] >= 1 else 1,
        "goal": _s(plan.get("goal"), 4000),
        "language": _s(plan.get("language"), 20) or "fr",
        "recipeId": _s(plan.get("recipeId"), 80) or None,
        "assumptions": [], "criteria": [], "steps": [], "milestones": [], "needsFromClient": [], "risks": [], "unassignable": [],
    }
    if not out["goal"]:
        _err(errors, "GOAL_REQUIRED", "goal", "Le plan doit reformuler l'objectif du projet (champ « goal »).")
    for i, a in enumerate(plan.get("assumptions") or []):
        if isinstance(a, dict) and _s(a.get("text"), 500):
            out["assumptions"].append({"id": _s(a.get("id"), 20) or f"A{i + 1}", "text": _s(a.get("text"), 500)})
        elif isinstance(a, str) and a.strip():
            out["assumptions"].append({"id": f"A{i + 1}", "text": a.strip()[:500]})

    # ---- critères
    raw_criteria = plan.get("criteria")
    crit_ids = []
    if not isinstance(raw_criteria, list) or not raw_criteria:
        _err(errors, "CRITERIA_REQUIRED", "criteria", "Le plan doit contenir au moins un critère d'acceptation vérifiable.")
        raw_criteria = []
    if len(raw_criteria) > max_criteria:
        _err(errors, "TOO_MANY_CRITERIA", "criteria", f"Au plus {max_criteria} critères (le plan en a {len(raw_criteria)}) : regroupez-les.")
        raw_criteria = raw_criteria[:max_criteria]
    for i, c in enumerate(raw_criteria):
        path = f"criteria[{i}]"
        if not isinstance(c, dict):
            _err(errors, "CRITERION_INVALID", path, "Un critère doit être un objet.")
            continue
        cid = _s(c.get("id"), 20)
        if not CRITERION_ID_RE.match(cid):
            _err(errors, "CRITERION_ID_INVALID", path + ".id", f"Identifiant de critère invalide : « {cid} » (attendu : C1, C2, …).")
            continue
        if cid in crit_ids:
            _err(errors, "CRITERION_ID_DUPLICATE", path + ".id", f"Identifiant de critère en double : {cid}.")
            continue
        text = _s(c.get("text"), 500)
        if not text:
            _err(errors, "CRITERION_TEXT_REQUIRED", path + ".text", f"Le critère {cid} n'a pas de texte.")
            continue
        kind = c.get("kind") if c.get("kind") in ("auto", "rubric") else "rubric"
        crit = {"id": cid, "text": text, "kind": kind}
        if kind == "auto":
            chk = c.get("check")
            weak = None
            if isinstance(chk, dict) and chk.get("type") in checks:
                import project_checks
                weak = project_checks.weakness(chk)
            if isinstance(chk, dict) and chk.get("type") in checks and not weak:
                crit["check"] = copy.deepcopy(chk)
            elif weak:
                warnings.append({"code": "CRITERION_AUTO_VACUOUS", "path": path, "detail":
                                 f"Le contrôle du critère {cid} ne vérifie rien de précis ({weak}) : il est vérifié par grille (« rubric »)."})
                crit["kind"] = "rubric"
            else:
                warnings.append({"code": "CRITERION_AUTO_TO_RUBRIC", "path": path, "detail":
                                 f"Le critère {cid} n'a pas de contrôle automatique connu : il est vérifié par grille (« rubric »)."})
                crit["kind"] = "rubric"
        if crit["kind"] == "rubric":
            crit["rubric"] = _s(c.get("rubric"), 1500) or text
        crit_ids.append(cid)
        out["criteria"].append(crit)

    # ---- étapes
    raw_steps = plan.get("steps")
    step_ids = []
    if not isinstance(raw_steps, list) or not raw_steps:
        _err(errors, "STEPS_REQUIRED", "steps", "Le plan doit contenir au moins une étape.")
        raw_steps = []
    if len(raw_steps) > max_steps:
        _err(errors, "TOO_MANY_STEPS", "steps", f"Au plus {max_steps} étapes (le plan en a {len(raw_steps)}) : regroupez-les.")
        raw_steps = raw_steps[:max_steps]
    for i, s in enumerate(raw_steps):
        path = f"steps[{i}]"
        if not isinstance(s, dict):
            _err(errors, "STEP_INVALID", path, "Une étape doit être un objet.")
            continue
        sid = _s(s.get("id"), 10)
        if not STEP_ID_RE.match(sid):
            _err(errors, "STEP_ID_INVALID", path + ".id", f"Identifiant d'étape invalide : « {sid} » (attendu : S1, S2, …).")
            continue
        if sid in step_ids:
            _err(errors, "STEP_ID_DUPLICATE", path + ".id", f"Identifiant d'étape en double : {sid}.")
            continue
        worker = _s(s.get("worker"), 20).lower()
        if not WORKER_RE.match(worker):
            _err(errors, "WORKER_INVALID", path + ".worker", f"Étape {sid} : Worker invalide « {worker} ».")
        elif known_workers is not None and worker not in known_workers and worker != "chloe":
            _err(errors, "WORKER_UNKNOWN", path + ".worker", f"Étape {sid} : le Worker « {worker} » n'existe pas.")
        elif allowed_workers is not None and worker not in allowed_workers:
            _err(errors, "WORKER_NOT_IN_SCOPE", path + ".worker",
                 f"Étape {sid} : le Worker « {worker} » ne fait pas partie des Workers que ce client peut utiliser ; réaffectez l'étape à un Worker autorisé "
                 f"({', '.join(sorted(allowed_workers))}) ou déclarez-la dans « unassignable ».")
        title = _s(s.get("title"), 160)
        goal = _s(s.get("goal"), 2000)
        if not title:
            _err(errors, "STEP_TITLE_REQUIRED", path + ".title", f"Étape {sid} : titre manquant.")
        if not goal:
            _err(errors, "STEP_GOAL_REQUIRED", path + ".goal", f"Étape {sid} : objectif manquant (« goal »).")
        effort = s.get("effort") if s.get("effort") in EFFORTS else "normal"
        est = s.get("estimateCredits")
        est = float(est) if isinstance(est, (int, float)) and not isinstance(est, bool) and est >= 0 else None
        outputs = []
        for o in _str_list(s.get("expectedOutputs"), 20, 180):
            try:
                project_paths.split_rel(o, allow_trailing_slash=True)
                outputs.append(o)
            except project_paths.PathError as e:
                _err(errors, "OUTPUT_PATH_INVALID", path + ".expectedOutputs", f"Étape {sid} : sortie attendue invalide « {o} » ({e.detail})")
        inputs = []
        for o in _str_list(s.get("inputs"), 20, 180):
            try:
                project_paths.split_rel(o, allow_trailing_slash=True)
                inputs.append(o)
            except project_paths.PathError as e:
                _err(errors, "INPUT_PATH_INVALID", path + ".inputs", f"Étape {sid} : entrée invalide « {o} » ({e.detail})")
        step = {
            "id": sid, "title": title, "worker": worker, "goal": goal,
            "dependsOn": _str_list(s.get("dependsOn"), 40, 10), "criteriaIds": _str_list(s.get("criteriaIds"), 25, 20),
            "inputs": inputs, "expectedOutputs": outputs, "effort": effort,
            "connectors": [c.lower() for c in _str_list(s.get("connectors"), 10, 40) if re.match(r"^[a-z0-9_]+\Z", c.lower())],
            "requiresApprovalsFrom": _str_list(s.get("requiresApprovalsFrom"), 20, 10),
            "estimateCredits": est,
        }
        step_ids.append(sid)
        out["steps"].append(step)

    for s in out["steps"]:
        sid = s["id"]
        for d in s["dependsOn"]:
            if d == sid:
                _err(errors, "STEP_SELF_DEPENDENCY", f"steps.{sid}.dependsOn", f"Étape {sid} : dépend d'elle-même.")
            elif d not in step_ids:
                _err(errors, "STEP_DEPENDENCY_UNKNOWN", f"steps.{sid}.dependsOn", f"Étape {sid} : dépend de « {d} » qui n'existe pas.")
        for a in s["requiresApprovalsFrom"]:
            if a not in step_ids:
                _err(errors, "APPROVAL_SOURCE_UNKNOWN", f"steps.{sid}.requiresApprovalsFrom", f"Étape {sid} : exige les approbations de « {a} » qui n'existe pas.")
        for cid in s["criteriaIds"]:
            if cid not in crit_ids:
                _err(errors, "STEP_CRITERION_UNKNOWN", f"steps.{sid}.criteriaIds", f"Étape {sid} : vise le critère « {cid} » qui n'existe pas.")
    if out["steps"] and not any(e["code"] in ("STEP_SELF_DEPENDENCY", "STEP_DEPENDENCY_UNKNOWN") for e in errors):
        if topological_order(out["steps"]) is None:
            _err(errors, "STEP_CYCLE", "steps", "Les dépendances des étapes forment un cycle : un plan doit être un graphe sans boucle.")
    covered = {cid for s in out["steps"] for cid in s["criteriaIds"]}
    for cid in crit_ids:
        if cid not in covered:
            _err(errors, "CRITERION_NOT_COVERED", f"criteria.{cid}", f"Le critère {cid} n'est visé par aucune étape (champ « criteriaIds ») : "
                 "chaque critère doit être traité par au moins une étape.")

    # ---- jalons, estimation, besoins du client, risques, non attribuables
    for m in plan.get("milestones") or []:
        if not isinstance(m, dict):
            continue
        mid = _s(m.get("id"), 20)
        after = [x for x in _str_list(m.get("afterSteps"), 40, 10) if x in step_ids]
        cids = [x for x in _str_list(m.get("criteriaIds"), 25, 20) if x in crit_ids]
        if mid and after and cids:
            out["milestones"].append({"id": mid, "afterSteps": after, "criteriaIds": cids})
    total = sum(s["estimateCredits"] for s in out["steps"] if s["estimateCredits"] is not None)
    est = plan.get("estimate") if isinstance(plan.get("estimate"), dict) else {}

    def _num(name, default):
        v = est.get(name)
        return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 else default

    default_n = len(out["steps"])
    cmin = _num("creditsMin", round(total * 0.7) if total else default_n * 5)
    cmax = _num("creditsMax", max(round(total * 1.4), cmin) if total else default_n * 10)
    if cmax < cmin:
        cmin, cmax = cmax, cmin
    hmin = _num("hoursMin", round(default_n * 0.1, 1))
    hmax = _num("hoursMax", max(round(default_n * 0.4, 1), hmin))
    out["estimate"] = {"creditsMin": cmin, "creditsMax": cmax, "hoursMin": hmin, "hoursMax": max(hmax, hmin)}
    for i, q in enumerate(plan.get("needsFromClient") or []):
        if isinstance(q, dict) and _s(q.get("question"), 500):
            out["needsFromClient"].append({"id": _s(q.get("id"), 20) or f"Q{i + 1}", "question": _s(q.get("question"), 500),
                                           "blocking": bool(q.get("blocking", False)), "default": _s(q.get("default"), 500)})
    out["risks"] = _str_list(plan.get("risks"), 10, 300)
    for u in plan.get("unassignable") or []:
        if isinstance(u, dict) and _s(u.get("capability"), 200):
            out["unassignable"].append({"capability": _s(u.get("capability"), 200), "bestWorker": _s(u.get("bestWorker"), 20).lower(),
                                        "reason": _s(u.get("reason"), 300)})
    if isinstance(plan.get("delegation"), dict):
        out["delegation"] = copy.deepcopy(plan["delegation"])
    if plan.get("fallback"):
        out["fallback"] = True
    return PlanResult(out, errors, warnings)


def needs_consistency_review(plan):
    """Vrai quand au moins deux Workers produisent des contenus destinés au même public (6c.7) : le moteur ajoute alors une relecture de
    cohérence. Heuristique volontairement simple : au moins deux Workers distincts ont une étape qui produit des fichiers."""
    workers = {s["worker"] for s in plan.get("steps", []) if s.get("expectedOutputs")}
    return len(workers) >= 2


COHERENCE_ID = "C-coherence"
COHERENCE_TEXT = "Les contenus destinés au même public et produits par des Workers différents ne se contredisent pas (mêmes faits, mêmes promesses, ton et marque cohérents)."
COHERENCE_RUBRIC = ("Compare les fiches de faits de chaque livrable : nom de l'entreprise, adresse, téléphone, prix, offres, dates, promesses, ton, couleurs et "
                    "typographie. FAIL si deux livrables se contredisent (même prix différent, une promesse absente du site, un ton incompatible).")


def with_coherence(plan):
    """Plan normalisé + critère implicite « C-coherence » (rubric) quand au moins deux Workers produisent des contenus destinés au même public (6c.7).
    Idempotent ; sans effet si le plan a déjà 25 critères."""
    if not needs_consistency_review(plan) or any(c.get("id") == COHERENCE_ID for c in plan.get("criteria") or []):
        return plan
    if len(plan.get("criteria") or []) >= MAX_CRITERIA:
        return plan
    out = dict(plan)
    out["criteria"] = list(plan.get("criteria") or []) + [{"id": COHERENCE_ID, "text": COHERENCE_TEXT, "kind": "rubric", "rubric": COHERENCE_RUBRIC, "implicit": True}]
    return out


def percent_done(steps, status_of, cap=95):
    """Avancement (0-100) : somme des estimateCredits des étapes terminées ÷ somme totale ; étape sans estimation : poids 1."""
    total = 0.0
    done = 0.0
    for s in steps:
        w = s["estimateCredits"] if s.get("estimateCredits") not in (None, 0) else 1.0
        total += w
        if status_of(s["id"]) in ("DONE", "SKIPPED"):
            done += w
    if total <= 0:
        return 0
    return min(cap, int(round(100.0 * done / total)))
