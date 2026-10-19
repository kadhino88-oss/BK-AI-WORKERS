# -*- coding: utf-8 -*-
"""Essai de fumée AVEC LA VRAIE API (modèle Haiku 5.5 uniquement) : un petit projet de bout en bout (plan, travail, vérification, livraison) piloté par le
moteur Python et le vrai lanceur PowerShell. À lancer À LA MAIN, jamais par une suite automatique : il dépense de l'argent du propriétaire.

La clé n'est JAMAIS lue ni affichée par ce script : le processus appelant la place dans la variable d'environnement BK_SECRET_ANTHROPIC (PowerShell :
`$env:BK_SECRET_ANTHROPIC = Get-BKSecretValue -Name anthropic`), le lanceur PowerShell la lit en mémoire comme en production.

    python tests/projects/smoke_real_api.py [--cap-usd 3] [--report chemin.json]

Plafond : le projet reçoit un plafond de crédits correspondant au budget ; le script arrête tout (interrupteur général) si le coût estimé dépasse --cap-usd.
Sortie : un tableau des dépenses estimées par étape (USD, CHF, crédits, tours, modèle), l'état final et les livrables."""
import argparse
import json
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import runner_harness as rh  # noqa: E402
from engine_harness import CLIENT, Env  # noqa: E402

GOAL = ("Crée une mini page d'accueil pour un cabinet de physiothérapie à Lausanne. Deux fichiers seulement : site/index.html (un titre, une courte phrase de "
        "présentation, une section « Horaires » avec la mention [A COMPLETER : horaires] puisque je ne les ai pas donnés) et site/contact.html (un formulaire de "
        "contact simple : nom, e-mail, message ; aucun champ de mot de passe). Pas d'autre page, pas de publication, pas de recherche sur le web.")


class RealEnv(Env):
    """Moteur de projets complet dont le lanceur est le VRAI script PowerShell (aucun faux lanceur)."""

    def __init__(self, **kw):
        kw["runner_cmd"] = None
        super().__init__(**kw)
        tpl = rh._template()
        for dp, _dirs, files in os.walk(tpl):
            rel = os.path.relpath(dp, tpl)
            os.makedirs(os.path.join(self.root, rel), exist_ok=True)
            for f in files:
                dst = os.path.join(self.root, rel, f)
                if not os.path.exists(dst):
                    shutil.copy2(os.path.join(dp, f), dst)
        for w in ("chloe", "lucas", "emma", "lea", "seoya"):
            src = os.path.join(rh.REPO, "chloe" if w == "chloe" else os.path.join("workers", w), "identity")
            dst = os.path.join(self.root, "chloe" if w == "chloe" else os.path.join("workers", w), "identity")
            if os.path.isdir(src) and not os.path.isdir(dst):
                shutil.copytree(src, dst)
        for sub in ("runtime/tasks", "memory/runtime"):
            os.makedirs(os.path.join(self.root, sub), exist_ok=True)
        # Haiku 5.5 pour TOUTES les phases (essai de fumée peu coûteux) : seule la copie jetable est modifiée
        ph = os.path.join(self.root, "core", "ai", "PROJECT-PHASES.json")
        with open(ph, encoding="utf-8-sig") as f:
            data = json.load(f)
        for p in data["phases"].values():
            p["levelRef"] = "rapide"
        data["levelUpgrade"] = {}
        with open(ph, "w", encoding="utf-8") as f:
            json.dump(data, f)
        self.svc = self.new_service()

    def new_service(self):
        import projects
        svc = super().new_service()
        svc.ps_cmd = [rh.PWSH, "-NoProfile", "-NonInteractive"]
        svc.runner_cmd = None
        svc.python = sys.executable
        return svc


def spent_usd(env, pid):
    total = 0.0
    sd = os.path.join(env.svc.store.project_dir(pid), "steps")
    for dp, _d, files in os.walk(sd):
        if "cost.json" in files:
            try:
                with open(os.path.join(dp, "cost.json"), encoding="utf-8-sig") as f:
                    total += float((json.load(f).get("usage") or {}).get("estimated_cost_usd") or 0)
            except (OSError, ValueError):
                pass
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cap-usd", type=float, default=3.0)
    ap.add_argument("--report", default="")
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()
    if not os.environ.get("BK_SECRET_ANTHROPIC"):
        print("BK_SECRET_ANTHROPIC absente : placez la clé dans cette variable d'environnement (sans l'afficher) avant de lancer.")
        return 2
    if not rh.PWSH:
        print("pwsh (PowerShell 7) introuvable.")
        return 2
    os.environ["BK_PROJECT_BACKOFF_SCALE"] = "1"
    cap_credits = int(args.cap_usd * 0.83107 / 0.0375)                         # USD -> CHF -> crédits
    e = RealEnv(tick_sec=0.5)
    started = time.time()
    status_log = []
    stopped_by_cap = False
    try:
        pid = e.create(goal=GOAL, worker="chloe", auto_start=True, credits_cap=min(cap_credits, 80))
        last = None
        while time.time() - started < args.timeout:
            e.svc.tick()
            st = e.state(pid)
            cur = (st["status"], tuple(sorted((k, v["status"]) for k, v in st["steps"].items())))
            if cur != last:
                print(f"[{int(time.time() - started):4d}s] {st['status']:<16} " + " ".join(f"{k}={v['status']}" for k, v in st["steps"].items()), flush=True)
                status_log.append({"t": int(time.time() - started), "status": st["status"], "steps": {k: v["status"] for k, v in st["steps"].items()}})
                last = cur
            if st["status"] in ("DONE", "FAILED", "CANCELLED", "BUDGET_REACHED", "WAITING_INPUT", "WAITING_QUOTA", "PAUSED"):
                if st["status"] == "WAITING_INPUT" and st.get("waitingFor") == "PLAN_VALIDATION":
                    e.svc.approve_plan(CLIENT, pid)
                    continue
                break
            if spent_usd(e, pid) >= args.cap_usd:
                print(f"PLAFOND DE {args.cap_usd} USD ATTEINT : arrêt.", flush=True)
                e.svc.write_control({"killAll": True, "pausedClients": []})
                e.svc.tick()
                stopped_by_cap = True
                break
            time.sleep(0.5)
        st = e.state(pid)
        total_usd = spent_usd(e, pid)
        rows = []
        for r in e.svc.store.read_jsonl(pid, "cost-ledger.jsonl"):
            rows.append(r)
        print("\n== RESULTAT ==")
        print("statut final :", st["status"], "| raison :", st.get("statusReason"), "| durée :", int(time.time() - started), "s")
        print("étapes :")
        for sid, s in st["steps"].items():
            inp = os.path.join(e.svc.store.project_dir(pid), "steps", sid, str(max(1, s.get("attempts") or 1)), "input.json")
            model = None
            try:
                with open(inp, encoding="utf-8") as f:
                    model = json.load(f).get("model")
            except (OSError, ValueError):
                pass
            print(f"  {sid:<8} {s['kind']:<12} {str(s.get('worker')):<8} {s['status']:<8} tentatives={s.get('attempts')} crédits={s.get('credits')} chf={s.get('chf')} modèle={model}")
        print("\n== DEPENSES (estimation, tarifs de core/ai/AI-PRICING.json) ==")
        print(f"  total estimé : {total_usd:.4f} USD ; {st['budget'].get('chfSpent')} CHF ; {st['budget'].get('creditsCharged')} crédits (plafond du projet : {st['budget'].get('creditsCap')})")
        for r in rows:
            print(f"  {r.get('stepId'):<8} tentative {r.get('attempt')} : {r.get('chf')} CHF -> {r.get('credits')} crédit(s)")
        print("\n== LIVRABLES ==")
        for d in (e.svc.store.read_json(pid, "deliverables.json", {}) or {}).get("items", []):
            print(f"  {d['path']} ({d['bytes']} o) — {d['title']}")
            full = os.path.join(e.svc.store.project_dir(pid), "workspace", *d["path"].split("/"))
            try:
                with open(full, encoding="utf-8") as f:
                    print("    " + f.read(500).replace("\n", "\n    "))
            except OSError:
                pass
        vdir = os.path.join(e.svc.store.project_dir(pid), "verification")
        if os.path.isdir(vdir):
            for rnd in sorted(os.listdir(vdir)):
                vp = os.path.join(vdir, rnd, "verification.json")
                if os.path.isfile(vp):
                    with open(vp, encoding="utf-8") as f:
                        v = json.load(f)
                    print(f"\n== VERIFICATION tour {rnd} : {v['overall']} ==")
                    for c in v["criteria"]:
                        print(f"  {c['id']} {c['verdict']} — {str(c.get('note'))[:140]}")
        report = {"status": st["status"], "reason": st.get("statusReason"), "seconds": int(time.time() - started), "estimatedUsd": round(total_usd, 4),
                  "chf": st["budget"].get("chfSpent"), "credits": st["budget"].get("creditsCharged"), "stoppedByCap": stopped_by_cap, "timeline": status_log,
                  "steps": {k: {"kind": v["kind"], "worker": v.get("worker"), "status": v["status"], "attempts": v.get("attempts"), "chf": v.get("chf")} for k, v in st["steps"].items()}}
        if args.report:
            with open(args.report, "w", encoding="utf-8") as f:
                json.dump(report, f, ensure_ascii=False, indent=2)
        return 0 if st["status"] == "DONE" else 1
    finally:
        e.close()


if __name__ == "__main__":
    sys.exit(main())
