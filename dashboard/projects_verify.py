# -*- coding: utf-8 -*-
"""Vérification d'un projet (docs/AUTONOMY-ENGINE.md, section 4) : contrôles typés exécutés par le moteur, preuves RÉSOLUES par le moteur,
verdicts, étapes de correction, définition de « terminé », rapport final.

Principe : « terminé » ne dépend ni de l'enthousiasme de l'exécutant ni de la complaisance du vérificateur. Les revendications des Workers ne
changent JAMAIS le statut d'un critère ; seuls (a) un contrôle typé qui rend ok:true et (b) un verdict PASS du vérificateur appuyé sur au moins
une preuve valide peuvent passer un critère à PASS. Un critère « auto » n'est PASS que si son contrôle est ok:true.

Module PUR : aucune dépendance au serveur.
"""
import json
import os
import re

import project_checks as pc
import project_paths as pp
import projects_store as ps

EVIDENCE_TYPES = ("file", "check", "excerpt", "fetch", "approval")
VERDICTS = ("PASS", "FAIL", "UNVERIFIABLE")
SCHEMA = "BK-PROJECT-VERIFICATION-V1"
COHERENCE_ID = "C-coherence"


def round_dir(project_dir, rnd):
    return os.path.join(project_dir, "verification", str(int(rnd)))


def run_auto_checks(project_dir, plan, rnd, only_ids=None):
    """Exécute, SANS modèle, le contrôle typé de chaque critère « auto ». Renvoie {criterionId: résultat CHK-…} (écrits dans
    verification/<tour>/checks/)."""
    ws = os.path.join(project_dir, "workspace")
    out_dir = os.path.join(round_dir(project_dir, rnd), "checks")
    results = {}
    for c in plan.get("criteria") or []:
        if c.get("kind") != "auto" or not isinstance(c.get("check"), dict):
            continue
        if only_ids is not None and c["id"] not in only_ids:
            continue
        results[c["id"]] = pc.run_check(pc.CheckCtx(ws, project_dir), c["check"], out_dir=out_dir)
    return results


def run_milestone_checks(project_dir, plan, milestone):
    """Contrôles typés d'un JALON (4.5) : les critères « auto » que le jalon vise, SANS modèle. Résultats écrits dans verification/m-<jalon>/ ;
    renvoie {criterionId: résultat CHK-…}. Un jalon ne rend aucun verdict final : il fait remonter tôt ce qu'une vérification finale trouverait tard."""
    mid = re.sub(r"[^A-Za-z0-9_-]", "_", str(milestone.get("id") or "m"))[:20] or "m"
    base = os.path.join(project_dir, "verification", f"m-{mid}")
    ws = os.path.join(project_dir, "workspace")
    wanted = set(milestone.get("criteriaIds") or [])
    results = {}
    for c in plan.get("criteria") or []:
        if c["id"] in wanted and c.get("kind") == "auto" and isinstance(c.get("check"), dict):
            results[c["id"]] = pc.run_check(pc.CheckCtx(ws, project_dir), c["check"], out_dir=os.path.join(base, "checks"))
    os.makedirs(base, exist_ok=True)
    pp.atomic_write_bytes(os.path.join(base, "milestone.json"), json.dumps(
        {"schema": SCHEMA, "scope": "milestone", "milestone": milestone.get("id"), "criteria": [{"id": cid, "ok": bool(r.get("ok")), "check": r["id"]} for cid, r in results.items()],
         "overall": "PASS" if all(r.get("ok") for r in results.values()) else "FAIL"}, ensure_ascii=False, indent=2).encode("utf-8"))
    return results


def milestone_failures(results):
    """Constat de verdict FAIL (forme d'une vérification) pour les contrôles de jalon en échec : alimente plan_fix_steps."""
    out = []
    for cid, r in results.items():
        if r.get("ok"):
            continue
        errs = [f for f in r.get("findings") or [] if f.get("severity") == "error"]
        out.append({"id": cid, "verdict": "FAIL", "note": "; ".join(f"{f.get('rule')}: {f.get('detail')}" for f in errs)[:600],
                    "fixHint": "Corriger : " + "; ".join(str(f.get("detail", "")) for f in errs)[:500], "evidence": [{"type": "check", "ref": r["id"]}]})
    return out


def _lines_of(full):
    return pc._read_text(full).splitlines()


def resolve_evidence(project_dir, rnd, verdict, evidence, approvals, step_dirs=None):
    """Valide les preuves données par le vérificateur. Renvoie (preuves valides enrichies, [raison de rejet]). Types : file (existe, > 0,
    sha256 enregistré), check (CHK présent dans CE tour et cohérent avec le verdict), excerpt (citation <= 300 car. littéralement dans les lignes
    indiquées), fetch (enregistrement de preview_fetch, statut 200), approval (article EXECUTED)."""
    ws = os.path.join(project_dir, "workspace")
    valid, bad = [], []
    for e in (evidence or [])[:12]:
        if not isinstance(e, dict) or e.get("type") not in EVIDENCE_TYPES:
            bad.append("type de preuve inconnu")
            continue
        t, ref = e["type"], str(e.get("ref") or "")
        if t == "file":
            try:
                full = pp.resolve(ws, ref, must_exist=True, allow_trailing_slash=True)
            except pp.PathError as ex:
                bad.append(f"fichier {ref[:60]} : {ex.detail}")
                continue
            if os.path.isdir(full):
                n = pp.usage(full)[0]
                if n == 0:
                    bad.append(f"dossier vide : {ref[:60]}")
                    continue
                valid.append({"type": "file", "ref": ref, "files": n})
            elif os.path.getsize(full) <= 0:
                bad.append(f"fichier vide : {ref[:60]}")
            else:
                valid.append({"type": "file", "ref": ref, "bytes": os.path.getsize(full), "sha256": pp.sha256_file(full)})
        elif t == "check":
            chk = pc.load_check(os.path.join(round_dir(project_dir, rnd), "checks"), ref)
            if not chk:
                bad.append(f"contrôle {ref[:20]} absent de ce tour")
            elif verdict == "PASS" and not chk.get("ok"):
                bad.append(f"contrôle {ref[:20]} en échec : il ne peut pas appuyer un PASS")
            elif verdict == "FAIL" and chk.get("ok"):
                bad.append(f"contrôle {ref[:20]} réussi : il ne peut pas appuyer un FAIL")
            else:
                valid.append({"type": "check", "ref": ref, "ok": bool(chk.get("ok"))})
        elif t == "excerpt":
            quote = str(e.get("quote") or "")
            if not quote or len(quote) > 300:
                bad.append("citation vide ou trop longue (300 caractères au plus)")
                continue
            try:
                full = pp.resolve(ws, ref, kind="file", must_exist=True)
            except pp.PathError as ex:
                bad.append(f"citation dans {ref[:60]} : {ex.detail}")
                continue
            lines = _lines_of(full)
            span = e.get("lines")
            lo, hi = 1, len(lines)
            if isinstance(span, list) and len(span) == 2 and all(isinstance(x, int) and not isinstance(x, bool) for x in span):
                lo, hi = max(1, span[0]), min(len(lines), max(span[0], span[1]))
            hay = "\n".join(lines[lo - 1:hi])
            norm = lambda s: re.sub(r"\s+", " ", s).strip()  # noqa: E731
            if norm(quote) and norm(quote) in norm(hay):
                valid.append({"type": "excerpt", "ref": ref, "lines": [lo, hi], "quote": quote})
            else:
                bad.append(f"la citation n'apparaît pas dans {ref[:60]} (lignes {lo}-{hi})")
        elif t == "fetch":
            rec = None
            for d in step_dirs or []:
                fp = os.path.join(d, "fetches", ref + ".json")
                if re.match(r"^FET-[0-9a-f]{8}\Z", ref) and os.path.isfile(fp):
                    try:
                        with open(fp, encoding="utf-8") as f:
                            rec = json.load(f)
                    except (OSError, ValueError):
                        rec = None
                    break
            if rec and rec.get("status") == 200:
                valid.append({"type": "fetch", "ref": ref, "path": rec.get("path"), "status": 200, "title": rec.get("title")})
            else:
                bad.append(f"récupération {ref[:20]} absente ou en échec")
        elif t == "approval":
            it = next((a for a in approvals or [] if a.get("id") == ref), None)
            if it and it.get("status") == "EXECUTED":
                valid.append({"type": "approval", "ref": ref})
            else:
                bad.append(f"article {ref[:20]} absent ou non exécuté")
    return valid, bad


def resolve_verification(plan, verifier_report, auto_results, project_dir, rnd, approvals, step_dirs=None, scope="final"):
    """Verdicts FINAUX d'un tour : le moteur tranche. `verifier_report` : {criteria:[{id,verdict,note,evidence,fixHint}], overall, summary} ou None
    (le vérificateur a échoué : seuls les contrôles typés comptent, tout le reste est UNVERIFIABLE)."""
    given = {}
    for c in (verifier_report or {}).get("criteria") or []:
        if isinstance(c, dict) and isinstance(c.get("id"), str):
            given[c["id"]] = c
    out_criteria = []
    for c in plan.get("criteria") or []:
        cid = c["id"]
        v = given.get(cid)
        auto = auto_results.get(cid)
        verdict_in = v.get("verdict") if v else None
        note = str((v or {}).get("note") or "")[:600]
        fix = str((v or {}).get("fixHint") or "")[:600]
        valid, bad = resolve_evidence(project_dir, rnd, verdict_in, (v or {}).get("evidence"), approvals, step_dirs) if v else ([], [])
        verdict = "UNVERIFIABLE"
        if c.get("kind") == "auto" and auto is not None:
            if not auto.get("ok"):
                verdict = "FAIL"
                note = note or "; ".join(f"{f.get('rule')}: {f.get('detail')}" for f in (auto.get("findings") or []) if f.get("severity") == "error")[:600]
                fix = fix or "Corriger : " + "; ".join(f.get("detail", "") for f in (auto.get("findings") or []) if f.get("severity") == "error")[:500]
            elif verdict_in == "FAIL":
                verdict = "FAIL"      # le vérificateur a trouvé ce qu'un contrôle typé ne voit pas : la réfutation l'emporte
            else:
                verdict = "PASS"
            valid = [{"type": "check", "ref": auto["id"], "ok": bool(auto.get("ok"))}] + [e for e in valid if not (e["type"] == "check" and e["ref"] == auto["id"])]
        elif verdict_in == "FAIL":
            verdict = "FAIL"
        elif verdict_in == "PASS":
            if valid:
                verdict = "PASS"
            else:
                verdict = "UNVERIFIABLE"
                note = (note + " " if note else "") + "(PASS rétrogradé par le moteur : aucune preuve valide" + (f" ; {bad[0]}" if bad else "") + ")"
        elif verdict_in == "UNVERIFIABLE":
            verdict = "UNVERIFIABLE"
        else:
            note = note or "Le vérificateur n'a pas rendu de verdict pour ce critère."
        out_criteria.append({"id": cid, "verdict": verdict, "note": note[:600], "evidence": valid, "fixHint": fix,
                             "invalidEvidence": bad[:5]})
    overall = "PASS"
    if any(x["verdict"] == "FAIL" for x in out_criteria):
        overall = "FAIL"
    elif any(x["verdict"] == "UNVERIFIABLE" for x in out_criteria):
        overall = "UNVERIFIABLE"
    return {"schema": SCHEMA, "round": int(rnd), "scope": scope, "criteria": out_criteria, "overall": overall,
            "unverifiable": [x["id"] for x in out_criteria if x["verdict"] == "UNVERIFIABLE"],
            "summary": str((verifier_report or {}).get("summary") or "")[:1500], "verifierRan": verifier_report is not None}


def write_verification(project_dir, rnd, data):
    d = round_dir(project_dir, rnd)
    os.makedirs(d, exist_ok=True)
    pp.atomic_write_bytes(os.path.join(d, "verification.json"), json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8"))


def write_part(project_dir, rnd, step_id, part):
    """Rapport d'UNE étape de vérification, gardé en attendant les autres étapes du même tour (critères, cohérence)."""
    d = os.path.join(round_dir(project_dir, rnd), "parts")
    os.makedirs(d, exist_ok=True)
    pp.atomic_write_bytes(os.path.join(d, re.sub(r"[^A-Za-z0-9-]", "_", step_id) + ".json"), json.dumps(part, ensure_ascii=False).encode("utf-8"))


def read_part(project_dir, rnd, step_id):
    try:
        with open(os.path.join(round_dir(project_dir, rnd), "parts", re.sub(r"[^A-Za-z0-9-]", "_", step_id) + ".json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_consistency(project_dir, rnd, criterion, issues):
    """verification/<tour>/consistency.json : verdict du critère C-coherence et écarts relevés (4.6 / 6c.7)."""
    clean = []
    for i in (issues or [])[:20]:
        if isinstance(i, dict):
            clean.append({"worker": str(i.get("worker") or "")[:20].lower(), "files": [str(f)[:180] for f in (i.get("files") or [])[:6] if isinstance(f, str)],
                          "issue": str(i.get("issue") or "")[:600], "fixHint": str(i.get("fixHint") or "")[:600]})
    d = round_dir(project_dir, rnd)
    os.makedirs(d, exist_ok=True)
    pp.atomic_write_bytes(os.path.join(d, "consistency.json"), json.dumps(
        {"schema": SCHEMA, "scope": "consistency", "round": int(rnd), "verdict": criterion.get("verdict"), "note": criterion.get("note"),
         "evidence": criterion.get("evidence") or [], "issues": clean}, ensure_ascii=False, indent=2).encode("utf-8"))


def read_verification(project_dir, rnd):
    try:
        with open(os.path.join(round_dir(project_dir, rnd), "verification.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def latest_round(project_dir):
    base = os.path.join(project_dir, "verification")
    try:
        rounds = [int(d) for d in os.listdir(base) if d.isdigit() and os.path.isfile(os.path.join(base, d, "verification.json"))]
    except OSError:
        return 0
    return max(rounds) if rounds else 0


# ------------------------------------------------------------------ étapes de correction
def owner_of_criterion(plan, state_steps, cid, lead="chloe"):
    """Worker propriétaire d'un critère : celui de la dernière étape terminée qui le vise (sinon le Worker de la dernière étape qui le vise)."""
    best = None
    for s in plan.get("steps") or []:
        if cid in (s.get("criteriaIds") or []):
            done = (state_steps.get(s["id"]) or {}).get("status") in ("DONE", "PARTIAL")
            if best is None or done or not best[1]:
                best = (s, done)
    return (best[0]["worker"], best[0]["id"]) if best else (lead, None)


def plan_fix_steps(plan, state_steps, verification, rnd, lead="chloe", consistency=None, worker_ok=None):
    """Une étape `fix` par Worker propriétaire des critères en échec, avec le fixHint et les preuves d'échec. Pour le critère de cohérence, chaque écart
    relevé va au Worker désigné par la relecture (`consistency` : [{worker, files, issue, fixHint}]) s'il est utilisable (`worker_ok`), sinon au chef de projet."""
    groups = {}
    crit = {c["id"]: c for c in plan.get("criteria") or []}
    for vc in verification.get("criteria") or []:
        if vc["verdict"] != "FAIL":
            continue
        if vc["id"] == COHERENCE_ID and consistency:
            for iss in consistency:
                w = str(iss.get("worker") or "").lower()
                w = w if w and (worker_ok is None or worker_ok(w)) else lead
                g = groups.setdefault(w, {"criteria": [], "src": set()})
                g["criteria"].append({"id": vc["id"], "verdict": "FAIL", "note": str(iss.get("issue") or vc.get("note") or "")[:600],
                                      "fixHint": str(iss.get("fixHint") or vc.get("fixHint") or "")[:600],
                                      "evidence": [{"type": "file", "ref": f} for f in (iss.get("files") or [])[:4] if isinstance(f, str)]})
            continue
        worker, src = owner_of_criterion(plan, state_steps, vc["id"], lead)
        g = groups.setdefault(worker, {"criteria": [], "src": set()})
        g["criteria"].append(vc)
        if src:
            g["src"].add(src)
    fixes = []
    for n, (worker, g) in enumerate(sorted(groups.items()), 1):
        lines = []
        for vc in g["criteria"]:
            c = crit.get(vc["id"]) or {}
            ev = ", ".join(f"{e.get('type')}:{e.get('ref')}" for e in vc.get("evidence") or [])
            lines.append(f"- {vc['id']} : {c.get('text', '')}\n  Constat : {vc.get('note') or '(voir contrôle)'}\n  À faire : {vc.get('fixHint') or 'corriger puis revérifier'}"
                         + (f"\n  Preuves de l'échec : {ev}" if ev else ""))
        ids = []
        for v in g["criteria"]:
            if v["id"] not in ids:
                ids.append(v["id"])
        fixes.append({"id": f"FIX{rnd}-{n}", "kind": "fix", "title": f"Corriger {', '.join(ids)}", "worker": worker,
                      "goal": "Le contrôleur qualité a relevé des critères en échec. Corrige-les dans l'espace de travail (n'écris pas de nouveau "
                              "projet : modifie ce qui existe), puis rends compte :\n" + "\n".join(lines),
                      "criteriaIds": ids, "dependsOn": [], "inputs": [], "expectedOutputs": [],
                      "effort": "normal", "connectors": [], "requiresApprovalsFrom": [], "estimateCredits": 6, "round": rnd})
    return fixes


# ------------------------------------------------------------------ dossier du vérificateur
def verification_dossier(plan, auto_results, deliverables, claims, fence_fn):
    lines = ["Critères à vérifier (tu dois essayer de les RÉFUTER ; ouvre les vrais fichiers, ne te fie à aucun rapport) :"]
    for c in plan.get("criteria") or []:
        lines.append(f"- {c['id']} [{c.get('kind')}] {c.get('text')}" + (f"\n  grille : {c.get('rubric')}" if c.get("rubric") else ""))
        a = auto_results.get(c["id"])
        if a:
            errs = [f"{f.get('rule')}: {f.get('detail')}" for f in a.get("findings") or [] if f.get("severity") == "error"]
            lines.append(f"  contrôle automatique {a['id']} (déjà exécuté par le moteur) : " + ("OK" if a.get("ok") else "ÉCHEC — " + " | ".join(errs[:6])))
    blocks = ["\n".join(lines)]
    if deliverables:
        blocks.append("Livrables déclarés :\n" + "\n".join(f"- {d.get('path')} ({d.get('bytes')} o) {d.get('title') or ''}" for d in deliverables[:60]))
    if claims:
        blocks.append("Revendications des Workers (NON FIABLES : à vérifier, jamais à croire) :\n" +
                      fence_fn("worker_claims", "\n".join(f"- {sid}: {json.dumps(c, ensure_ascii=False)[:500]}" for sid, c in claims.items())))
    return "\n\n".join(blocks)


# ------------------------------------------------------------------ définition de « terminé » (1.1)
def required_approval_steps(plan):
    return {sid for s in plan.get("steps") or [] for sid in (s.get("requiresApprovalsFrom") or [])}


def definition_of_done(plan, verification, deliverables, approvals, workspace, accepted_gaps=None, final_report_exists=True):
    """Liste des manques (vide = « terminé » permis)."""
    problems = []
    accepted = set(accepted_gaps or [])
    vmap = {c["id"]: c for c in (verification or {}).get("criteria") or []}
    for c in plan.get("criteria") or []:
        v = vmap.get(c["id"])
        if c["id"] in accepted:
            continue
        if not v or v["verdict"] != "PASS":
            problems.append(f"critère {c['id']} non vérifié ({(v or {}).get('verdict', 'aucun verdict')})")
        elif not v.get("evidence"):
            problems.append(f"critère {c['id']} sans preuve")
    for d in deliverables or []:
        try:
            full = pp.resolve(workspace, d.get("path"), must_exist=True, allow_trailing_slash=True)
            empty = (os.path.isdir(full) and pp.usage(full)[0] == 0) or (os.path.isfile(full) and os.path.getsize(full) <= 0)
        except pp.PathError:
            empty = True
        if empty:
            problems.append(f"livrable {d.get('path')} absent ou vide")
    req = required_approval_steps(plan)
    for a in approvals or []:
        if a.get("stepId") in req and a.get("status") in ("PENDING", "APPROVED", "EXECUTING"):
            problems.append(f"action {a.get('id')} en attente de validation")
    if not final_report_exists:
        problems.append("rapport final absent")
    return problems


# ------------------------------------------------------------------ rapport final (gabarit fixe en 8 parties)
_CLAIM_RE = re.compile(r"\b(C[A-Za-z0-9-]{0,18})\b[^\n|]{0,40}\bPASS\b")


def message_claims_ok(text, verification):
    """Le message de livraison du Worker ne doit affirmer aucun PASS absent de verification.json."""
    passed = {c["id"] for c in (verification or {}).get("criteria") or [] if c["verdict"] == "PASS"}
    for m in _CLAIM_RE.finditer(str(text or "")):
        if m.group(1) not in passed:
            return False
    return True


def build_final_report(state, plan, verification, deliverables, approvals, delivery_message, accepted_gaps, now_iso):
    vmap = {c["id"]: c for c in (verification or {}).get("criteria") or []}
    b = state.get("budget") or {}
    L = []
    L.append(f"# Rapport final — {state.get('title') or state.get('projectId')}")
    L.append("")
    L.append(f"Projet {state.get('projectId')} — établi le {now_iso} — statut : **{state.get('status')}**")
    L.append("")
    L.append("## 1. Ce qui a été demandé")
    L.append("")
    L.append((plan.get("goal") or state.get("goal") or "").strip())
    L.append("")
    L.append("## 2. Ce qui est livré")
    L.append("")
    if deliverables:
        for d in deliverables:
            L.append(f"- `{d.get('path')}` — {d.get('title') or d.get('path')} ({d.get('bytes')} octets, étape {d.get('stepId')})")
    else:
        L.append("- Aucun livrable enregistré.")
    L.append("")
    L.append("## 3. Critères d'acceptation, verdicts et preuves")
    L.append("")
    L.append("| Critère | Verdict | Preuve |")
    L.append("|---|---|---|")
    gaps = set(accepted_gaps or [])
    for c in plan.get("criteria") or []:
        v = vmap.get(c["id"]) or {}
        verdict = v.get("verdict", "AUCUN")
        if c["id"] in gaps:
            verdict += " (accepté en l'état par le client)"
        ev = "; ".join(f"{e.get('type')}:{e.get('ref')}" for e in v.get("evidence") or []) or "—"
        L.append(f"| {c['id']} — {str(c.get('text'))[:120].replace('|', '/')} | {verdict} | {ev[:160].replace('|', '/')} |")
    L.append("")
    L.append("## 4. Hypothèses retenues")
    L.append("")
    for a in plan.get("assumptions") or []:
        L.append(f"- {a.get('id')} : {a.get('text')}")
    if not plan.get("assumptions"):
        L.append("- Aucune hypothèse particulière.")
    L.append("")
    L.append("## 5. Ce que vous devez encore faire")
    L.append("")
    todo = []
    for q in plan.get("needsFromClient") or []:
        todo.append(f"{q.get('question')}" + (f" (valeur par défaut : {q.get('default')})" if q.get("default") else ""))
    pend = [a for a in approvals if a.get("status") == "PENDING"]
    if pend:
        todo.append(f"Valider ou rejeter {len(pend)} action(s) en attente dans l'onglet Validations.")
    for t in todo:
        L.append(f"- {t}")
    if not todo:
        L.append("- Rien d'obligatoire.")
    L.append("")
    L.append("## 6. Actions sortantes")
    L.append("")
    if approvals:
        for a in approvals:
            L.append(f"- {a.get('id')} — {(a.get('display') or {}).get('title')} : **{a.get('status')}**" + (" (automatique)" if a.get("autoApproved") else ""))
    else:
        L.append("- Aucune action sortante n'a été préparée.")
    L.append("")
    L.append("## 7. Coût et durée")
    L.append("")
    steps = state.get("steps") or {}
    L.append(f"- Crédits consommés : {b.get('creditsCharged', 0)} (plafond du projet : {b.get('creditsCap')})")
    L.append(f"- Étapes exécutées : {sum(1 for s in steps.values() if s.get('status') in ('DONE', 'PARTIAL'))} sur {len(steps)}")
    L.append(f"- Durée de travail : {round(float(state.get('activeSeconds') or 0) / 60)} minutes")
    L.append("")
    L.append("## 8. Limites et ce que je n'ai pas pu vérifier")
    L.append("")
    lim = [c for c in (verification or {}).get("criteria") or [] if c["verdict"] != "PASS"]
    for c in lim:
        L.append(f"- {c['id']} : {c['verdict']} — {c.get('note') or 'non vérifié'}")
    if gaps:
        L.append(f"- Critères acceptés en l'état par le client : {', '.join(sorted(gaps))}.")
    if not lim and not gaps:
        L.append("- Tous les critères ont été vérifiés. Les contenus destinés au public restent à relire par vous avant toute publication.")
    if delivery_message:
        L.append("")
        L.append("## Message du Worker")
        L.append("")
        L.append(delivery_message.strip())
    L.append("")
    return "\n".join(L)
