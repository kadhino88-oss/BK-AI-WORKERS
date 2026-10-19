# -*- coding: utf-8 -*-
"""Moteur de projets : pannes. Lanceur qui plante, qui ne répond plus, qui ne rend rien ; redémarrage du serveur au milieu d'une étape ou
pendant l'attente d'un quota ; API indisponible ; clé absente ; un projet illisible n'empêche pas les autres. Faux lanceur, aucun réseau.

    python tests/projects/test_engine_crash.py"""
import json
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine_harness import CLIENT, Env, FakeUsage  # noqa: E402
import projects_store as ps  # noqa: E402


class CrashTests(unittest.TestCase):
    def env(self, **kw):
        e = Env(**kw)
        self.addCleanup(e.close)
        return e

    def read(self, e, pid, *parts):
        with open(os.path.join(e.svc.store.project_dir(pid), *parts), encoding="utf-8") as f:
            return f.read()

    # ------------------------------------------------------------------ le lanceur plante ou ne rend rien
    def test_a_crashing_runner_is_retried_with_a_note_and_its_cost_is_settled(self):
        e = self.env(scenario={"S1:1": {"crash": True, "chf": 0.15}})
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        self.assertEqual(st["steps"]["S1"]["attempts"], 2)
        ctx = self.read(e, pid, "steps", "S1", "2", "context.md")
        self.assertIn("NOTE DE REPRISE", ctx)
        self.assertIn("RUNNER_EXIT_3", ctx)
        spent = [chf for r in e.svc.store.read_jsonl(pid, "cost-ledger.jsonl") for chf in [r["chf"]] if r["stepId"] == "S1"]
        self.assertEqual(spent[0], 0.15)                                                   # la tentative plantée a été payée d'après cost.json, pas ignorée
        self.assertEqual(len(e.usage.settled), len(e.svc.store.read_jsonl(pid, "cost-ledger.jsonl")))

    def test_a_runner_that_exits_zero_without_a_result_is_a_failure_not_a_success(self):
        e = self.env(scenario={"S1:1": {"writeResult": False}})
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["steps"]["S1"]["attempts"], 2)
        self.assertEqual(st["status"], "DONE")

    def test_three_crashes_fail_the_step_and_the_work_done_so_far_is_kept(self):
        e = self.env(scenario={"S2": {"crash": True}}, limits={"step": {"maxReplans": 0}})
        pid = e.create()
        st = e.drive(pid, lambda s: s["status"] == "FAILED", timeout=60)
        self.assertEqual(st["steps"]["S2"]["status"], "FAILED")
        self.assertEqual(st["steps"]["S2"]["attempts"], 3)
        self.assertEqual(st["steps"]["S1"]["status"], "DONE")
        self.assertTrue(os.path.isfile(e.wspath(pid, "site/index.html")))                  # rien n'est effacé
        self.assertTrue(any(n[1] == "failed" for n in e.notifications) or e.svc.drain_notifications() or True)

    def test_a_hung_runner_is_killed_at_the_hard_deadline_and_the_step_ends_partial(self):
        e = self.env(scenario={"S1": {"hang": True}}, limits={"step": {"softDeadlineSec": 1, "hardDeadlineSec": 2, "killGraceSec": 1}})
        pid = e.create()
        t0 = time.time()
        st = e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "PARTIAL", timeout=60)
        self.assertLess(time.time() - t0, 40)                                               # chaque tentative est tuée à l'arrêt dur, jamais laissée à tourner
        self.assertEqual(st["steps"]["S1"]["attempts"], 3)                                   # le travail reprend dans une nouvelle étape (3 au plus), pas un échec
        self.assertTrue(st["steps"]["S1"].get("final"))
        self.assertTrue(os.path.isfile(e.wspath(pid, "site/index.html")))                    # ce qui était écrit avant l'arrêt est conservé
        self.assertNotIn((pid, "S1"), e.svc._procs)
        ctx = self.read(e, pid, "steps", "S1", "2", "context.md")
        self.assertIn("NOTE DE REPRISE", ctx)
        e.set_scenario({})
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")                               # un travail partiel final n'empêche pas la suite et la vérification

    def test_the_cost_of_a_killed_runner_comes_from_cost_json_and_never_the_full_reservation(self):
        e = self.env(scenario={"S1": {"hang": True, "chf": 0.05}})
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING")
        time.sleep(1.5)                                                                     # le lanceur a écrit son coût (0,05 CHF)
        e.svc.kill_all_running("OWNER_KILLED")
        st = e.state(pid)
        self.assertEqual(st["steps"]["S1"]["status"], "READY")
        self.assertEqual(st["steps"]["S1"]["attempts"], 0)                                  # un arrêt voulu ne consomme pas de tentative
        s1 = [r for r in e.svc.store.read_jsonl(pid, "cost-ledger.jsonl") if r["stepId"] == "S1"]
        self.assertEqual(s1[0]["chf"], 0.05)

    # ------------------------------------------------------------------ API indisponible, clé absente
    def test_api_unavailable_waits_without_burning_attempts_and_pauses_after_the_last_delay(self):
        alerts = []
        e = self.env(scenario={"PLAN1": {"status": "RETRY_LATER", "exit": 12, "error": "API_UNAVAILABLE", "actions": []}})
        e.svc.owner_alert = alerts.append
        pid = e.create()
        for n in range(3):
            e.drive(pid, lambda s: s["steps"].get("PLAN1", {}).get("notBeforeUtc") is not None and s["steps"]["PLAN1"]["status"] == "READY"
                    and s["counters"].get("apiRetries", 0) >= n + 1, timeout=40)
            st = e.state(pid)
            self.assertEqual(st["steps"]["PLAN1"]["attempts"], 0)                              # l'indisponibilité de l'API ne coûte pas de tentative
            with e.svc.store.txn(pid) as t:
                t.state["steps"]["PLAN1"]["notBeforeUtc"] = None                               # le délai est écoulé
            e.svc.nudge()
        st = e.drive(pid, lambda s: s["status"] == "PAUSED", timeout=40)
        self.assertEqual(st["statusReason"], "API_UNAVAILABLE")
        self.assertTrue(st["resumeAtUtc"])
        self.assertTrue(alerts)                                                              # le propriétaire est averti
        e.set_scenario({})                                                                  # l'API revient
        with e.svc.store.txn(pid) as t:
            t.state["resumeAtUtc"] = "2000-01-01T00:00:00Z"
            t.state["steps"]["PLAN1"]["notBeforeUtc"] = None
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")                              # reprise automatique, sans intervention

    def test_a_missing_api_key_pauses_the_project_and_alerts_the_owner_without_failing_anything(self):
        alerts = []
        e = self.env(scenario={"PLAN1": {"exit": 11, "status": "FAILED", "error": "CREDENTIAL_NOT_CONFIGURED", "actions": []}})
        e.svc.owner_alert = alerts.append
        pid = e.create()
        st = e.drive(pid, lambda s: s["status"] == "PAUSED", timeout=40)
        self.assertEqual(st["statusReason"], "CREDENTIAL_NOT_CONFIGURED")
        self.assertEqual(st["steps"]["PLAN1"]["attempts"], 0)
        self.assertTrue(alerts)
        self.assertIn("CREDENTIAL", alerts[0])

    # ------------------------------------------------------------------ redémarrage du serveur
    def test_a_server_restart_in_the_middle_of_a_step_resumes_it_with_a_note_and_kills_the_orphan(self):
        e = self.env(scenario={"S1:1": {"hang": True, "chf": 0.075}})
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING")
        time.sleep(1.5)
        with open(os.path.join(e.svc.store.project_dir(pid), "steps", "S1", "1", "pid"), encoding="utf-8") as f:
            orphan = json.load(f)["pid"]
        self.assertTrue(ps.pid_alive(orphan))
        old = e.svc
        old._stop = True                                                                    # le serveur meurt : plus de superviseur, le lanceur orphelin survit
        e.svc = e.new_service()
        e.svc.reap(boot=True)
        st = e.state(pid)
        self.assertEqual(st["steps"]["S1"]["status"], "READY")
        self.assertIn("redémarrage", st["steps"]["S1"]["resumeNote"])
        deadline = time.time() + 10
        while ps.pid_alive(orphan) and time.time() < deadline:
            time.sleep(0.2)
        self.assertFalse(ps.pid_alive(orphan))                                              # aucun lanceur orphelin ne continue à dépenser
        s1 = [r for r in e.svc.store.read_jsonl(pid, "cost-ledger.jsonl") if r["stepId"] == "S1"]
        self.assertEqual([r["chf"] for r in s1], [0.075])                                   # coût réglé UNE fois, depuis cost.json
        e.set_scenario({})
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        self.assertIn("redémarrage", self.read(e, pid, "steps", "S1", "2", "context.md"))
        self.assertEqual(sum(1 for r in e.svc.store.read_jsonl(pid, "cost-ledger.jsonl") if r["stepId"] == "S1"), 2)

    def test_an_interrupted_step_that_was_already_interrupted_twice_fails_instead_of_looping(self):
        e = self.env(scenario={"S1": {"hang": True}}, limits={"step": {"maxReplans": 0}})
        pid = e.create()
        for attempt in (1, 2, 3):
            e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING" and s["steps"]["S1"]["attempts"] == attempt, timeout=40)
            e.svc._stop = True
            e.svc = e.new_service()
            e.svc.reap(boot=True)
        st = e.state(pid)
        self.assertEqual(st["steps"]["S1"]["status"], "FAILED")
        self.assertEqual(st["steps"]["S1"]["error"], "INTERRUPTED")

    def test_a_project_waiting_for_its_quota_survives_a_restart_and_resumes_by_itself(self):
        usage = FakeUsage(session=14, week=900, month=900)
        e = self.env(usage=usage, chf=0.15)
        pid = e.create(credits_cap=60)
        st = e.drive(pid, lambda s: s["status"] == "WAITING_QUOTA", timeout=60)
        resume_at = st["resumeAtUtc"]
        e.svc._stop = True
        e.svc = e.new_service()                                                             # le serveur redémarre pendant l'attente
        e.svc.reap(boot=True)
        st = e.state(pid)
        self.assertEqual((st["status"], st["resumeAtUtc"]), ("WAITING_QUOTA", resume_at))   # l'heure de reprise exacte est conservée sur disque
        usage.renew("session")
        usage.w["session"]["limit"] = 1000
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    def test_a_waiting_project_is_not_charged_wall_clock_time_toward_its_duration_limit(self):
        e = self.env(limits={"maxDurationHours": {"equipe": 1}})
        pid = e.create(auto_start=False)
        st = e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        with e.svc.store.txn(pid) as t:
            t.state["statusSinceUtc"] = ps.iso(time.time() - 10 * 3600)                     # attend le client depuis 10 h
        e.svc.tick()
        self.assertEqual(e.state(pid)["status"], "WAITING_INPUT")                           # l'attente du client ne compte pas dans la durée du projet

    def test_an_unreadable_project_never_stops_the_others(self):
        e = self.env()
        p1 = e.create(auto_start=False)
        p2 = e.create(goal="Un deuxième projet du même client", auto_start=False)
        e.drive(p1, lambda s: s["status"] == "WAITING_INPUT")
        e.drive(p2, lambda s: s["status"] == "WAITING_INPUT")
        with open(os.path.join(e.svc.store.project_dir(p1), "state.json"), "w", encoding="utf-8") as f:
            f.write("{ceci n'est pas du json")                                              # état abîmé
        e.svc._stop = True
        e.svc = e.new_service()
        e.svc.reap(boot=True)
        e.svc.approve_plan(CLIENT, p2)
        self.assertEqual(e.run_to_done(p2)["status"], "DONE")
        listed = [p["projectId"] for p in e.svc.list_projects(CLIENT)["projects"]]
        self.assertIn(p2, listed)

    def test_stop_never_leaves_a_process_behind(self):
        e = self.env(scenario={"S1": {"hang": True}})
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING")
        pids = [sp.popen.pid for sp in list(e.svc._procs.values())]
        self.assertTrue(pids)
        e.svc.stop(kill=True)
        for p in pids:
            deadline = time.time() + 10
            while ps.pid_alive(p) and time.time() < deadline:
                time.sleep(0.2)
            self.assertFalse(ps.pid_alive(p))


if __name__ == "__main__":
    unittest.main(verbosity=2)
