# -*- coding: utf-8 -*-
"""Recettes de projets (schema BK-RECIPE-V1, docs/AUTONOMY-ENGINE.md section 9) : lecture, choix, rendu pour le planificateur, controle d'integrite.

Une recette est un GUIDE de metier (definition de « termine », etapes, controles, livrables, approbations, budget typique), jamais un carcan :
le planificateur peut l'adapter et doit dire pourquoi (plan.recipeDeviations). Les recettes vivent dans workers/<id>/recipes/<slug>.json et
chloe/recipes/<slug>.json ; l'identifiant est « <worker>/<slug> ». Le moteur importe ce module en try/except ImportError.

Module PUR : stdlib seule, aucune dependance au serveur. Aucun appel reseau, aucun modele.
"""
import json
import os
import re
import threading
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAN_ORDER = ("essai", "solo", "starter", "trio", "business", "equipe", "pro", "scale", "enterprise")
PLAN_RANK = {"essai": 0, "solo": 1, "starter": 1, "trio": 2, "business": 3, "equipe": 3, "pro": 4, "scale": 5, "enterprise": 6}
MAX_PLANNING_CHARS = 9000        # ~2 500 jetons
MAX_STEP_CHARS = 2400            # ~600 jetons
MIN_SCORE = 2
RECIPE_ID_RE = re.compile(r"^[a-z0-9_-]+/[a-z0-9_-]+\Z")
SECRET_RE = re.compile(r"(sk-ant-[A-Za-z0-9_-]{10,}|sk_live_[A-Za-z0-9]{8,}|AKIA[0-9A-Z]{12,}|-----BEGIN [A-Z ]*PRIVATE KEY|Bearer\s+[A-Za-z0-9._-]{20,})")
CONNECTOR_FILE = os.path.join("core", "integrations", "Connector-Dispatch.ps1")
SOURCES_FILE = os.path.join("core", "projects", "RECIPE-SOURCES.json")
_lock = threading.Lock()
_cache = {"sig": None, "recipes": {}}


# ------------------------------------------------------------------ chargement
def _recipe_files(root=None):
    root = root or ROOT
    out = []
    workers = os.path.join(root, "workers")
    if os.path.isdir(workers):
        for w in sorted(os.listdir(workers)):
            d = os.path.join(workers, w, "recipes")
            if os.path.isdir(d):
                out += [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".json")]
    d = os.path.join(root, "chloe", "recipes")
    if os.path.isdir(d):
        out += [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".json")]
    return out


def _load_file(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def load_all(root=None, refresh=False):
    """{id: recette}. Mise en cache, rechargee quand un fichier change (taille + date). Une recette illisible est ignoree (jamais fatale)."""
    root = root or ROOT
    files = _recipe_files(root)
    sig = tuple((p, os.path.getmtime(p), os.path.getsize(p)) for p in files)
    with _lock:
        if not refresh and _cache["sig"] == (root, sig):
            return _cache["recipes"]
        out = {}
        for p in files:
            try:
                r = _load_file(p)
            except (OSError, ValueError):
                continue
            if isinstance(r, dict) and RECIPE_ID_RE.match(str(r.get("id") or "")):
                r["_path"] = os.path.relpath(p, root).replace("\\", "/")
                out[r["id"]] = r
        _cache["sig"] = (root, sig)
        _cache["recipes"] = out
        return out


def get(recipe_id):
    return load_all().get(str(recipe_id or "").strip().lower())


def list_for_worker(worker_id):
    w = str(worker_id or "").strip().lower()
    return [r for r in load_all().values() if r.get("workerId") == w]


def list_all():
    return sorted(load_all().values(), key=lambda r: r["id"])


# ------------------------------------------------------------------ choix
def _norm(text):
    t = unicodedata.normalize("NFKD", str(text or "").lower())
    return "".join(c for c in t if not unicodedata.combining(c))


def _words(text):
    return {w for w in re.findall(r"[a-z0-9]{4,}", _norm(text))}


def _score(recipe, goal_n, goal_words, plan_id):
    trig = recipe.get("triggers") or {}
    hits = sum(1 for k in trig.get("keywords") or [] if _norm(k) and _norm(k) in goal_n)
    ex_words = set()
    for e in trig.get("examples") or []:
        ex_words |= _words(e)
    overlap = len(goal_words & ex_words)
    score = 2 * hits + min(overlap // 2, 3)
    if score and PLAN_RANK.get(str(plan_id or "equipe").lower(), 3) >= PLAN_RANK.get(str(recipe.get("minPlan") or "solo").lower(), 1):
        score += 1
    return score


def candidates(worker_id, goal, language="fr", plan_id="equipe"):
    """[(recette, score)] triees (score decroissant). Un Worker voit ses recettes ; Chloe (ou pas de Worker) voit toutes les recettes, celles qui
    sont multi-Workers comprises. Seuil minimal : au moins un mot-cle ou un net recouvrement avec les exemples."""
    w = str(worker_id or "").strip().lower()
    goal_n = _norm(goal)
    gw = _words(goal)
    pool = list_all() if w in ("", "chloe") else [r for r in list_all() if r.get("workerId") == w or w in (r.get("supportingWorkers") or [])]
    lang = str(language or "fr").lower()[:2]
    out = []
    for r in pool:
        langs = [str(x).lower()[:2] for x in r.get("languages") or []]
        if langs and lang not in langs:
            continue
        s = _score(r, goal_n, gw, plan_id)
        if s >= MIN_SCORE:
            out.append((r, s))
    out.sort(key=lambda x: (-x[1], 0 if x[0].get("workerId") == w else 1, x[0]["id"]))
    return out


# ------------------------------------------------------------------ rendu
def _crit_line(c):
    how = ""
    if c.get("kind") == "auto" and isinstance(c.get("check"), dict):
        how = " [controle moteur : %s]" % c["check"].get("type")
    elif c.get("rubric"):
        how = " [grille : %s]" % str(c["rubric"])[:220]
    return "- %s : %s%s" % (c["id"], c["text"], how)


def _clip(text, limit):
    return text if len(text) <= limit else text[: limit - 40].rstrip() + "\n[... recette abregee ...]"


def render_for_planning(recipe, usage_view=None):
    if not recipe:
        return ""
    b = recipe.get("budget") or {}
    L = ["RECETTE « %s » (%s) : un GUIDE de metier, pas un carcan. Adapte-la au projet et note chaque ecart dans plan.recipeDeviations avec sa raison." % (recipe["title"], recipe["id"]),
         "recipeId a reprendre dans le plan : %s. Budget typique : %s-%s credits, %s-%s h." % (recipe["id"], *(b.get("typicalCredits") or ["?", "?"]), *(b.get("typicalHours") or ["?", "?"]))]
    if isinstance(usage_view, dict) and usage_view.get("allowedNow") is not None:
        L.append("Credits disponibles maintenant : %s." % usage_view.get("allowedNow"))
    L.append("Definition de « termine » (reprends ces criteres) :")
    L += [_crit_line(c) for c in recipe.get("definitionOfDone") or []]
    L.append("Etapes proposees :")
    for s in recipe.get("steps") or []:
        L.append("- %s [%s, %s] %s | depend de : %s | ~%s cr. | %s" % (s["id"], s.get("worker"), s.get("effort", "normal"), s["title"], ",".join(s.get("dependsOn") or []) or "-",
                                                                     s.get("estimateCredits", "?"), _clip(str(s.get("goal") or ""), 260)))
    L.append("Livrables : " + "; ".join("%s (%s)" % (d["path"], d["title"]) for d in recipe.get("deliverables") or []))
    if recipe.get("approvals"):
        L.append("Approbations du client (jamais auto, tu les prepares a l'identique) : " + "; ".join(
            "%s:%s [%s] %s" % (a["connector"], a["operation"], a.get("risk", "?"), a.get("when", "")) for a in recipe["approvals"]))
    if recipe.get("needsFromClient"):
        L.append("A demander au client (non bloquant sauf mention) : " + " | ".join(
            "%s%s (defaut : %s)" % (q["question"], " [BLOQUANT]" if q.get("blocking") else "", q.get("default", "-")) for q in recipe["needsFromClient"]))
    L.append("Guide : " + str(recipe.get("guidance") or ""))
    if recipe.get("forbidden"):
        L.append("Interdit : " + "; ".join(recipe["forbidden"]))
    if recipe.get("legalNotice"):
        L.append("Droit : " + str(recipe["legalNotice"]))
    return _clip("\n".join(L), MAX_PLANNING_CHARS)


def render_for_step(recipe, step_id):
    if not recipe:
        return ""
    step = next((s for s in recipe.get("steps") or [] if s["id"] == step_id), None)
    if step is None:
        return ""
    crit = {c["id"]: c for c in recipe.get("definitionOfDone") or []}
    L = ["RECETTE « %s » - etape %s : %s" % (recipe["title"], step["id"], step["title"]), "Objectif : " + str(step.get("goal") or "")]
    if step.get("expectedOutputs"):
        L.append("Sorties attendues : " + ", ".join(step["expectedOutputs"]))
    mine = [crit[c] for c in step.get("criteriaIds") or [] if c in crit]
    if mine:
        L.append("Criteres que cette etape doit satisfaire :")
        L += [_crit_line(c) for c in mine]
    L.append("Guide : " + str(recipe.get("guidance") or ""))
    if recipe.get("forbidden"):
        L.append("Interdit : " + "; ".join(recipe["forbidden"]))
    return _clip("\n".join(L), MAX_STEP_CHARS)


def public_summary(recipe):
    b = recipe.get("budget") or {}
    return {"id": recipe["id"], "title": recipe["title"], "description": str(recipe.get("summary") or recipe.get("guidance") or "")[:240],
            "workerId": recipe.get("workerId"), "supportingWorkers": list(recipe.get("supportingWorkers") or []), "minPlan": recipe.get("minPlan", "solo"),
            "languages": list(recipe.get("languages") or ["fr"]), "typicalCredits": list(b.get("typicalCredits") or []), "typicalHours": list(b.get("typicalHours") or []),
            "deliverables": [d["title"] for d in recipe.get("deliverables") or []],
            "needsFromClient": [q["question"] for q in recipe.get("needsFromClient") or []],
            "approvals": [{"connector": a["connector"], "operation": a["operation"], "risk": a.get("risk")} for a in recipe.get("approvals") or []]}


# ------------------------------------------------------------------ integrite
def operation_table(root=None):
    """{connecteur: [OPERATIONS]} lu dans $Script:OperationTable (sans executer PowerShell)."""
    p = os.path.join(root or ROOT, CONNECTOR_FILE)
    text = open(p, encoding="utf-8-sig").read()
    i = text.index("$Script:OperationTable = @{")
    cur, table = None, {}
    for line in text[i:].split("\n"):
        a = re.match(r'^    "([a-z_0-9]+)" = @\{', line)
        if a:
            cur = a.group(1)
            table[cur] = []
            continue
        b = re.match(r'^            "([A-Z_]+)"\s*=', line)
        if b and cur:
            table[cur].append(b.group(1))
        if line.startswith("}") and cur:
            break
    return table


def known_workers(root=None):
    d = os.path.join(root or ROOT, "workers")
    return {w for w in os.listdir(d) if os.path.isdir(os.path.join(d, w, "identity"))} - {"atlas"} | {"chloe"}


def source_ids(root=None):
    try:
        return set((_load_file(os.path.join(root or ROOT, SOURCES_FILE)).get("sources") or {}).keys())
    except (OSError, ValueError):
        return set()


def validate(recipe, *, root=None, op_table=None, workers=None, check_types=None, sources=None):
    """Liste d'erreurs (francais) ; vide = recette valide. Regles : champs obligatoires, DAG, couverture des criteres, types de controle connus,
    Workers existants, operations de connecteur existantes, somme des estimations dans la fourchette +-30 %, aucun secret, variantes coherentes."""
    import projects_plan as pp
    err = []
    if not isinstance(recipe, dict):
        return ["La recette doit etre un objet JSON."]
    if recipe.get("schema") != "BK-RECIPE-V1":
        err.append("schema doit valoir BK-RECIPE-V1.")
    for k in ("id", "version", "title", "workerId", "definitionOfDone", "steps", "deliverables", "budget", "guidance"):
        if recipe.get(k) in (None, "", [], {}):
            err.append("Champ obligatoire absent : %s." % k)
    rid = str(recipe.get("id") or "")
    if not RECIPE_ID_RE.match(rid):
        err.append("Identifiant invalide : %r." % rid)
    elif rid.split("/")[0] != recipe.get("workerId"):
        err.append("L'identifiant doit commencer par le workerId (%s)." % recipe.get("workerId"))
    ws = workers if workers is not None else known_workers(root)
    for w in [recipe.get("workerId")] + list(recipe.get("supportingWorkers") or []):
        if w not in ws:
            err.append("Worker inconnu : %s." % w)
    if str(recipe.get("minPlan") or "solo") not in PLAN_RANK:
        err.append("minPlan inconnu : %s." % recipe.get("minPlan"))
    types = check_types if check_types is not None else (set(pp.BUILTIN_CHECK_TYPES) | set(pp.SITE_CHECK_TYPES))
    crits = recipe.get("definitionOfDone") or []
    cids = []
    for c in crits:
        if not isinstance(c, dict) or not c.get("id") or not c.get("text"):
            err.append("Critere invalide : %r." % (c,))
            continue
        cids.append(c["id"])
        if c.get("kind") == "auto":
            if not isinstance(c.get("check"), dict) or c["check"].get("type") not in types:
                err.append("Critere %s : type de controle inconnu (%s)." % (c["id"], (c.get("check") or {}).get("type")))
        elif c.get("kind") == "rubric":
            if not str(c.get("rubric") or "").strip():
                err.append("Critere %s : grille (rubric) vide." % c["id"])
        else:
            err.append("Critere %s : kind doit valoir auto ou rubric." % c["id"])
    if len(set(cids)) != len(cids):
        err.append("Identifiants de criteres en double.")
    steps = recipe.get("steps") or []
    sids = [s.get("id") for s in steps if isinstance(s, dict)]
    if len(set(sids)) != len(sids):
        err.append("Identifiants d'etapes en double.")
    covered = set()
    total = 0.0
    for s in steps:
        if not isinstance(s, dict):
            err.append("Etape invalide.")
            continue
        if not s.get("title") or not s.get("goal"):
            err.append("Etape %s : titre ou objectif manquant." % s.get("id"))
        if s.get("worker") not in ws:
            err.append("Etape %s : Worker inconnu %s." % (s.get("id"), s.get("worker")))
        for d in s.get("dependsOn") or []:
            if d not in sids:
                err.append("Etape %s : dependance inconnue %s." % (s.get("id"), d))
        for c in s.get("criteriaIds") or []:
            if c not in cids:
                err.append("Etape %s : critere inconnu %s." % (s.get("id"), c))
        covered |= set(s.get("criteriaIds") or [])
        for a in s.get("requiresApprovalsFrom") or []:
            if a not in sids:
                err.append("Etape %s : requiresApprovalsFrom inconnu %s." % (s.get("id"), a))
        if s.get("effort", "normal") not in ("normal", "bulk", "deep"):
            err.append("Etape %s : effort invalide." % s.get("id"))
        total += float(s.get("estimateCredits") or 0)
    if sids and not err_has(err, "dependance inconnue") and pp.topological_order([{"id": s["id"], "dependsOn": s.get("dependsOn") or []} for s in steps if isinstance(s, dict) and s.get("id")]) is None:
        err.append("Les etapes forment un cycle.")
    for c in cids:
        if c not in covered:
            err.append("Critere %s : aucune etape ne le vise." % c)
    if len(steps) > 40 or len(crits) > 25:
        err.append("Au plus 40 etapes et 25 criteres.")
    tc = (recipe.get("budget") or {}).get("typicalCredits")
    if not (isinstance(tc, list) and len(tc) == 2 and 0 < tc[0] <= tc[1]):
        err.append("budget.typicalCredits doit etre [min, max].")
    elif not (tc[0] * 0.7 <= total <= tc[1] * 1.3):
        err.append("Somme des estimateCredits (%s) hors de typicalCredits %s +-30 %%." % (total, tc))
    for name, v in ((recipe.get("budget") or {}).get("variants") or {}).items():
        for d in v.get("drop") or []:
            if d not in sids:
                err.append("Variante %s : etape inconnue %s." % (name, d))
    ot = op_table if op_table is not None else operation_table(root)
    for a in recipe.get("approvals") or []:
        if a.get("connector") not in ot or a.get("operation") not in ot.get(a.get("connector"), []):
            err.append("Approbation %s:%s absente de $Script:OperationTable." % (a.get("connector"), a.get("operation")))
        if a.get("risk") not in ("low", "medium", "high"):
            err.append("Approbation %s:%s : risk invalide." % (a.get("connector"), a.get("operation")))
    conn = recipe.get("connectors") or {}
    for c in list(conn.get("required") or []) + list(conn.get("optional") or []):
        if c not in ot and c != "slack":
            err.append("Connecteur inconnu : %s." % c)
    if not recipe.get("deliverables"):
        err.append("Au moins un livrable est requis.")
    for d in recipe.get("deliverables") or []:
        if not d.get("path") or not d.get("title"):
            err.append("Livrable invalide : %r." % (d,))
    for q in recipe.get("needsFromClient") or []:
        if not q.get("id") or not q.get("question"):
            err.append("needsFromClient invalide : %r." % (q,))
    if SECRET_RE.search(json.dumps(recipe, ensure_ascii=False)):
        err.append("Un motif de secret a ete detecte dans la recette.")
    src = sources if sources is not None else source_ids(root)
    for sid in recipe.get("sources") or []:
        if sid not in src:
            err.append("Source inconnue (RECIPE-SOURCES.json) : %s." % sid)
    return err


def err_has(errors, needle):
    return any(needle in e for e in errors)
