# -*- coding: utf-8 -*-
"""Moteur de projets : conservation (90 jours), espace disque par client, plafond d'étapes, jalons (contrôles tôt), alerte de dépense anormale,
nettoyage des fichiers orphelins chez le fournisseur d'IA. Faux lanceur, aucun réseau.

    python tests/projects/test_housekeeping.py"""
import copy
import json
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine_harness import CLIENT, CLIENT_B, Env, iso  # noqa: E402
import fake_runner  # noqa: E402
import projects_store as ps  # noqa: E402

WRITE = lambda p, c="<h1>x</h1> contenu": [  # noqa: E731
    {"tool": "workspace_write", "input": {"path": p, "mode": "overwrite", "content": c}}, {"tool": "deliverable_register", "input": {"path": p, "title": p}}]


def wrong_index(extra=None):
    """S1 écrit « site/idx.html » au lieu de « site/index.html » : le contrôle typé C1 échouera."""
    return {"actions": WRITE("site/idx.html"), "complete": {"status": "DONE", "summary": "Page ecrite.", "deliverables": [{"path": "site/idx.html", "title": "Accueil"}]}}


class HousekeepingTests(unittest.TestCase):
    def env(self, **kw):
        e = Env(**kw)
        self.addCleanup(e.close)
        return e

    # ------------------------------------------------------------------ plafond d'étapes par projet
    def test_a_project_never_grows_beyond_its_step_cap_and_the_client_decides_instead(self):
        e = self.env(scenario={"S1": wrong_index()}, limits={"step": {"maxStepsPerProject": 7}})
        pid = e.create()
        st = e.drive(pid, lambda s: s["status"] == "WAITING_INPUT" and s.get("waitingFor") == "CRITERIA_FAILED", timeout=60)
        self.assertLessEqual(len(st["steps"]), 7)
        self.assertEqual(st["counters"]["fixRounds"], 0)                                   # pas de place pour une correction : on ne la crée pas
        self.assertNotIn("FIX1-1", st["steps"])
        d = e.svc.get_detail(CLIENT, pid)
        self.assertTrue(d["capabilities"]["canAcceptGaps"])                                # le client peut accepter l'état, guider ou annuler

    def test_a_question_is_refused_when_the_step_cap_is_reached(self):
        e = self.env(limits={"step": {"maxStepsPerProject": 5}})
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        with self.assertRaises(ps.ProjectError) as cm:
            for _ in range(3):
                e.svc.post_message(CLIENT, pid, "question", "Ou en est-on ?")
        self.assertEqual(cm.exception.code, "TOO_LARGE")

    # ------------------------------------------------------------------ jalons
    def test_a_failing_milestone_creates_its_fix_step_before_the_last_step_ends(self):
        plan = copy.deepcopy(fake_runner.default_plan({}))
        plan["milestones"] = [{"id": "M1", "afterSteps": ["S1"], "criteriaIds": ["C1"]}]
        fix = {"actions": WRITE("site/index.html", "<h1>Accueil corrige</h1> bonjour"), "complete": {"status": "DONE", "summary": "Corrige.",
                                                                                                "deliverables": [{"path": "site/index.html", "title": "Accueil"}]}}
        e = self.env(scenario={"plan": {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": plan}}], "complete": {"status": "DONE", "summary": "Plan pret."}},
                               "S1": wrong_index(), "S2": {"sleep": 1.5}, "fix": fix})
        pid = e.create()
        st = e.drive(pid, lambda s: "FIXM1-1" in s["steps"], timeout=60)
        self.assertEqual(st["steps"]["S1"]["status"], "DONE")
        self.assertNotEqual(st["steps"]["S3"]["status"], "DONE")                           # détecté avant la fin du projet
        self.assertEqual(st["steps"]["FIXM1-1"]["kind"], "fix")
        self.assertEqual(st["steps"]["FIXM1-1"]["worker"], "lucas")                        # le Worker propriétaire du critère
        self.assertEqual(st["milestones"]["M1"]["failed"], ["C1"])
        self.assertTrue(any(x["type"] == "verification_result" and (x.get("data") or {}).get("scope") == "milestone" for x in e.events(pid)))
        pdir = e.svc.store.project_dir(pid)
        self.assertEqual(json.load(open(os.path.join(pdir, "verification", "m-M1", "milestone.json"), encoding="utf-8"))["overall"], "FAIL")
        final = e.run_to_done(pid)
        self.assertEqual(final["status"], "DONE")
        self.assertEqual(final["counters"]["fixRounds"], 0)                                # la vérification finale n'a plus rien à corriger
        self.assertEqual(final["counters"]["milestoneFixes"], 1)

    def test_a_milestone_that_passes_costs_nothing_and_is_checked_once(self):
        plan = copy.deepcopy(fake_runner.default_plan({}))
        plan["milestones"] = [{"id": "M1", "afterSteps": ["S1"], "criteriaIds": ["C1"]}]
        e = self.env(scenario={"plan": {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": plan}}], "complete": {"status": "DONE", "summary": "Plan pret."}}})
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        self.assertEqual(st["milestones"]["M1"]["failed"], [])
        self.assertEqual(len([x for x in e.events(pid) if (x.get("data") or {}).get("scope") == "milestone"]), 1)
        self.assertEqual(st["counters"].get("milestoneFixes", 0), 0)

    # ------------------------------------------------------------------ conservation
    def test_workspaces_are_purged_after_ninety_days_but_the_report_stays(self):
        e = self.env()
        pid = e.create()
        e.run_to_done(pid)
        pdir = e.svc.store.project_dir(pid)
        self.assertTrue(os.path.isdir(os.path.join(pdir, "workspace")))
        now = time.time()
        self.assertEqual(e.svc.retention_sweep(now + 80 * 86400), 0)                       # trop tôt
        self.assertTrue(os.path.isdir(os.path.join(pdir, "workspace")))
        self.assertEqual(e.svc.retention_sweep(now + 91 * 86400), 1)
        self.assertFalse(os.path.exists(os.path.join(pdir, "workspace")))
        self.assertTrue(os.path.isfile(os.path.join(pdir, "final-report.md")))
        self.assertTrue(os.path.isfile(os.path.join(pdir, "state.json")))
        self.assertTrue(os.path.isfile(os.path.join(pdir, "events.jsonl")))
        d = e.svc.get_detail(CLIENT, pid)
        self.assertTrue(d["workspacePurged"])
        self.assertEqual(d["status"], "DONE")
        with self.assertRaises(ps.ProjectNotFound):
            e.svc.resolve_download(CLIENT, pid, "site/index.html")                         # plus téléchargeable : 404, pas une erreur interne
        e.svc.resolve_download(CLIENT, pid, "final-report.md")
        self.assertEqual(e.svc.retention_sweep(now + 200 * 86400), 0)                      # une seule fois

    def test_a_cancelled_project_stays_downloadable_for_seven_days_only(self):
        e = self.env(scenario={"S1": {"sleep": 3}})
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING")
        e.svc.cancel(CLIENT, pid)
        now = time.time()
        self.assertEqual(e.svc.retention_sweep(now + 6 * 86400), 0)
        self.assertEqual(e.svc.retention_sweep(now + 8 * 86400), 1)

    def test_a_running_project_is_never_purged(self):
        e = self.env()
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        self.assertEqual(e.svc.retention_sweep(time.time() + 400 * 86400), 0)
        self.assertTrue(os.path.isdir(os.path.join(e.svc.store.project_dir(pid), "workspace")))

    def test_the_supervisor_runs_the_sweep_by_itself_once_an_hour(self):
        e = self.env()
        pid = e.create()
        e.run_to_done(pid)
        e.svc._last_housekeeping = 0.0
        e.svc.now = lambda: time.time() + 100 * 86400
        e.svc.tick()
        self.assertTrue(e.state(pid).get("workspacePurgedUtc"))

    # ------------------------------------------------------------------ espace disque du client
    def test_a_client_whose_storage_is_full_cannot_create_another_project(self):
        e = self.env(limits={"clientDiskMb": {"default": 1}})
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        with open(os.path.join(e.svc.store.project_dir(pid), "workspace", "gros.csv"), "wb") as f:
            f.write(b"x" * (2 * 1024 * 1024))
        e.svc._disk_cache.clear()
        with self.assertRaises(ps.ProjectError) as cm:
            e.create(auto_start=False)
        self.assertEqual(cm.exception.code, "WORKSPACE_FULL")
        self.assertEqual(cm.exception.extra["limitMb"], 1)
        e2 = self.env(limits={"clientDiskMb": {"default": 1}}, client=CLIENT_B)
        e2.create(auto_start=False)                                                         # un autre client n'est pas touché

    # ------------------------------------------------------------------ dépense anormale
    def test_an_abnormal_daily_spend_alerts_the_owner_once_a_day(self):
        alerts = []
        e = self.env()
        e.svc.owner_alert = alerts.append
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        now = time.time()
        for d in range(2, 8):                                                               # 0,10 CHF par jour pendant 6 jours
            e.svc.store.append_jsonl(pid, "cost-ledger.jsonl", {"ts": iso(now - d * 86400 - 3600), "stepId": "S1", "chf": 0.10, "credits": 3, "cumulativeCredits": 3})
        e.svc.store.append_jsonl(pid, "cost-ledger.jsonl", {"ts": iso(now - 600), "stepId": "S2", "chf": 0.05, "credits": 2, "cumulativeCredits": 5})
        self.assertEqual(e.svc.spend_spike_sweep(now), 0)                                   # dépense normale
        e.svc.store.append_jsonl(pid, "cost-ledger.jsonl", {"ts": iso(now - 300), "stepId": "S3", "chf": 6.0, "credits": 160, "cumulativeCredits": 165})
        self.assertEqual(e.svc.spend_spike_sweep(now), 1)
        self.assertIn(CLIENT, alerts[0])
        self.assertEqual(e.svc.spend_spike_sweep(now + 60), 0)                              # une alerte par client et par jour
        self.assertEqual(len(alerts), 1)

    # ------------------------------------------------------------------ fichiers distants orphelins
    def test_orphan_remote_files_are_removed_by_the_cleanup_script_and_recent_ones_are_left(self):
        e = self.env()
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        proj = e.svc.store.project_dir(pid)
        calls = []

        def make(step, att, data, age):
            d = os.path.join(proj, "steps", step, str(att))
            os.makedirs(d, exist_ok=True)
            p = os.path.join(d, "files-api.json")
            with open(p, "w", encoding="utf-8") as f:
                json.dump(data, f)
            os.utime(p, (time.time() - age, time.time() - age))
            return p
        old = make("S1", 1, {"uploaded": ["file_up_000001"], "produced": ["file_pr_000002"]}, 3600)
        recent = make("S2", 1, {"uploaded": ["file_up_recent"], "produced": []}, 30)
        clean = make("S3", 1, {"uploaded": [], "produced": []}, 7200)
        script = os.path.join(e.root, "fake_cleanup.py")
        with open(script, "w", encoding="utf-8") as f:
            f.write("import json,sys\nids=json.load(open(sys.argv[1]))['ids']\nopen(sys.argv[2],'a').write(json.dumps(ids)+'\\n')\n")
        log = os.path.join(e.root, "cleanup.log")
        e.svc.files_cleanup_cmd = lambda ids_path: [sys.executable, script, ids_path, log]
        self.assertEqual(e.svc.reap_files_api(), 2)
        self.assertEqual(json.loads(open(log, encoding="utf-8").read().strip()), ["file_pr_000002", "file_up_000001"])
        self.assertEqual(json.load(open(old, encoding="utf-8")), {"uploaded": [], "produced": []})
        self.assertEqual(json.load(open(recent, encoding="utf-8"))["uploaded"], ["file_up_recent"])      # l'étape peut encore tourner : on n'y touche pas
        self.assertEqual(e.svc.reap_files_api(), 0)                                          # plus rien à faire
        # un nettoyage en échec laisse les identifiants pour la prochaine passe
        old = make("S1", 2, {"uploaded": ["file_up_failed"], "produced": []}, 3600)
        e.svc.files_cleanup_cmd = lambda ids_path: [sys.executable, "-c", "import sys; sys.exit(12)"]
        self.assertEqual(e.svc.reap_files_api(), 0)
        self.assertEqual(json.load(open(old, encoding="utf-8"))["uploaded"], ["file_up_failed"])

    def test_a_running_step_files_are_never_touched(self):
        e = self.env(scenario={"S1": {"hang": True}})
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING")
        d = os.path.join(e.svc.store.project_dir(pid), "steps", "S1", "1")
        p = os.path.join(d, "files-api.json")
        with open(p, "w", encoding="utf-8") as f:
            json.dump({"uploaded": ["file_up_live"], "produced": []}, f)
        os.utime(p, (time.time() - 7200, time.time() - 7200))
        self.assertEqual(e.svc._orphan_file_ids(time.time()), {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
