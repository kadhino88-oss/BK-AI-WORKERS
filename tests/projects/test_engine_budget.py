# -*- coding: utf-8 -*-
"""Moteur de projets : budget, quota, droits, installation en pause, plafonds de concurrence, interrupteurs, limites de creation.

    python tests/projects/test_engine_budget.py"""
import json
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine_harness import CLIENT, CLIENT_B, Env, FakeUsage, Scope, WORKERS_17, iso  # noqa: E402
import projects_store as ps  # noqa: E402


class BudgetTests(unittest.TestCase):
    def env(self, **kw):
        e = Env(**kw)
        self.addCleanup(e.close)
        return e

    # ------------------------------------------------------------------ plafond du projet
    def test_project_cap_reached_stops_cleanly_and_raising_the_cap_resumes(self):
        e = self.env(chf=0.15)                                           # 0,15 CHF par etape = 4 credits
        pid = e.create(credits_cap=12)                                    # le plan seul consomme deja ; le plafond sera atteint en route
        st = e.drive(pid, lambda s: s["status"] in ("BUDGET_REACHED", "DONE"), timeout=60)
        self.assertEqual(st["status"], "BUDGET_REACHED")
        self.assertEqual(st["waitingFor"], "BUDGET")
        d = e.svc.get_detail(CLIENT, pid)
        self.assertTrue(d["capabilities"]["canAcceptGaps"])
        self.assertIsNotNone(d["budget"]["costToFinishCredits"])
        self.assertIn("budget_reached", [x["type"] for x in e.events(pid)])
        self.assertTrue(any(n[1] == "budget_reached" for n in e.notifications))
        charged = st["budget"]["creditsCharged"]
        self.assertLessEqual(charged, 12 + 6)                             # jamais de depassement massif : le plafond d'une etape est borne
        time.sleep(0.3)
        e.svc.tick()
        self.assertEqual(e.state(pid)["status"], "BUDGET_REACHED")        # rien ne repart tout seul : c'est une decision du client
        out = e.svc.set_budget(CLIENT, pid, 150)
        self.assertEqual(out["status"], "RUNNING")
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    def test_accepting_the_gaps_at_the_cap_finishes_with_an_honest_report(self):
        e = self.env(chf=0.15)
        pid = e.create(credits_cap=12)
        e.drive(pid, lambda s: s["status"] == "BUDGET_REACHED", timeout=60)
        out = e.svc.accept_gaps(CLIENT, pid)
        st = e.state(pid)
        report = open(os.path.join(e.svc.store.project_dir(pid), "final-report.md"), encoding="utf-8").read()
        self.assertIn("accepté en l'état", report)
        self.assertIn(st["status"], ("DONE", "WAITING_INPUT"))
        if st["status"] == "WAITING_INPUT":
            self.assertTrue(st["doneProblems"])                           # jamais « termine » avec un trou cache

    def test_a_step_is_never_launched_with_less_than_the_minimum_credits_left_in_the_cap(self):
        e = self.env(chf=0.15)
        pid = e.create(credits_cap=7)
        st = e.drive(pid, lambda s: s["status"] == "BUDGET_REACHED", timeout=60)
        running = [k for k, v in st["steps"].items() if v["status"] == "RUNNING"]
        self.assertEqual(running, [])

    # ------------------------------------------------------------------ fenetres d'usage : WAITING_QUOTA et reprise automatique
    def test_session_window_reached_waits_with_the_renewal_time_and_resumes_by_itself(self):
        usage = FakeUsage(session=14, week=500, month=900)
        e = self.env(usage=usage, chf=0.15)                                          # 4 credits par etape : la session de 14 s'epuise avant la fin
        pid = e.create(credits_cap=60)
        st = e.drive(pid, lambda s: s["status"] == "WAITING_QUOTA", timeout=60)
        self.assertEqual(st["statusReason"], "SESSION")
        self.assertEqual(st["waitingFor"], "QUOTA")
        self.assertEqual(st["resumeAtUtc"], usage.w["session"]["resetsAtUtc"])      # l'heure EXACTE de renouvellement
        d = e.svc.get_detail(CLIENT, pid)
        self.assertEqual(d["usage"]["binding"], "session")
        self.assertEqual(e.svc.progress(CLIENT, pid)["resumeAtUtc"], st["resumeAtUtc"])
        self.assertIn("quota_wait", [x["type"] for x in e.events(pid)])
        e.svc.drain_notifications()
        self.assertEqual([n[1] for n in e.notifications].count("quota_waiting"), 1)   # un seul e-mail
        ready = [k for k, v in st["steps"].items() if v["status"] in ("READY", "PENDING")]
        self.assertTrue(ready)                                                       # rien n'est perdu : l'etape reste prete
        for _ in range(8):
            e.svc.tick()
            time.sleep(0.05)
        self.assertEqual(e.state(pid)["status"], "WAITING_QUOTA")                    # tant que la fenetre n'est pas renouvelee
        self.assertFalse(any(s["status"] == "RUNNING" for s in e.state(pid)["steps"].values()))
        usage.renew("session")                                                       # la fenetre se renouvelle
        st = e.drive(pid, lambda s: s["status"] in ("RUNNING", "PLANNING", "DONE"))
        self.assertIn("quota_resume", [x["type"] for x in e.events(pid)])
        usage.w["session"]["limit"] = 14                                             # (la session suivante est identique)
        usage.w["session"]["limit"] = 1000
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    def test_resume_at_the_simulated_resume_time_even_without_renewal_data(self):
        usage = FakeUsage(session=14)
        e = self.env(usage=usage, chf=0.15)
        pid = e.create(credits_cap=60)
        st = e.drive(pid, lambda s: s["status"] == "WAITING_QUOTA", timeout=60)
        with e.svc.store.txn(pid) as t:
            t.state["resumeAtUtc"] = iso(time.time() - 1)                            # l'heure de reprise est passee
        usage.w["session"]["limit"] = 1000
        e.drive(pid, lambda s: s["status"] != "WAITING_QUOTA")

    def test_an_upgrade_resumes_the_project_at_once(self):
        usage = FakeUsage(session=14, week=500, month=900)
        e = self.env(usage=usage, chf=0.15)
        pid = e.create(credits_cap=60)
        e.drive(pid, lambda s: s["status"] == "WAITING_QUOTA", timeout=60)
        usage.w["session"]["limit"] = 115                                            # montee en gamme : la fenetre s'elargit tout de suite
        usage.w["week"]["limit"] = 287
        e.svc.nudge()
        e.drive(pid, lambda s: s["status"] != "WAITING_QUOTA")
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    def test_week_and_month_windows_bind_too(self):
        for name, reason in (("week", "WEEK"), ("month", "MONTH")):
            usage = FakeUsage(session=1000, week=14 if name == "week" else 1000, month=14 if name == "month" else 1000)
            e = self.env(usage=usage, chf=0.15)
            pid = e.create(credits_cap=60)
            st = e.drive(pid, lambda s: s["status"] == "WAITING_QUOTA", timeout=60)
            self.assertEqual(st["statusReason"], reason)
            self.assertEqual(st["resumeAtUtc"], usage.w[name]["resetsAtUtc"])

    def test_a_running_step_is_never_interrupted_by_a_window(self):
        usage = FakeUsage(session=40)
        e = self.env(usage=usage, scenario={"S1": {"sleep": 1.0}})
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING")
        usage.w["session"]["limit"] = 0                                              # la fenetre se ferme pendant l'etape
        st = e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "DONE")
        self.assertEqual(st["steps"]["S1"]["status"], "DONE")

    def test_the_step_ceiling_passed_to_the_runner_is_the_reserved_credits(self):
        usage = FakeUsage(session=14)                                                # 14 credits : l'etape recoit 14 x 0,0375 CHF
        e = self.env(usage=usage)
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("PLAN1", {}).get("status") == "RUNNING")
        inp = json.load(open(os.path.join(e.svc.store.project_dir(pid), "steps", "PLAN1", "1", "input.json"), encoding="utf-8"))
        self.assertAlmostEqual(inp["ceilingChf"], 14 * 0.0375, places=4)
        self.assertEqual(inp["phase"], "plan")
        self.assertEqual(inp["model"], "claude-opus-5-5")                            # planification et verification : toujours le niveau fort

    def test_phases_choose_the_model_and_level_upgrade_moves_execute_to_opus(self):
        e = self.env()
        pid = e.create(level="approfondi")
        st = e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING", timeout=60)
        inp = json.load(open(os.path.join(e.svc.store.project_dir(pid), "steps", "S1", "1", "input.json"), encoding="utf-8"))
        self.assertEqual(inp["model"], "claude-opus-5-5")
        e2 = self.env()
        pid2 = e2.create(level="standard")
        e2.drive(pid2, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING", timeout=60)
        inp2 = json.load(open(os.path.join(e2.svc.store.project_dir(pid2), "steps", "S1", "1", "input.json"), encoding="utf-8"))
        self.assertEqual(inp2["model"], "claude-sonnet-5-5")

    # ------------------------------------------------------------------ droits du forfait, installation en pause
    def test_a_worker_leaving_the_plan_blocks_its_step_and_the_project_waits_then_resumes(self):
        e = self.env(scenario={"S2": {"sleep": 0.0}})
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        e.scope.allowed = [w for w in WORKERS_17 if w != "emma"]                      # rétrogradation : Emma n'est plus incluse
        e.svc.scope_of(CLIENT, fresh=True)
        e.svc.approve_plan(CLIENT, pid)
        st = e.drive(pid, lambda s: s["steps"].get("S2", {}).get("status") == "BLOCKED")
        self.assertEqual(st["steps"]["S2"]["blockedReason"], "WORKER_NOT_INCLUDED")
        self.assertEqual(st["steps"]["S1"]["status"] in ("DONE", "RUNNING", "READY"), True)
        st = e.drive(pid, lambda s: s["status"] == "WAITING_INPUT" and s["steps"]["S1"]["status"] == "DONE")
        e.scope.allowed = list(WORKERS_17)                                           # le client réembauche Emma
        e.svc.scope_of(CLIENT, fresh=True)
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    def test_a_plan_with_a_worker_outside_the_scope_is_refused_and_the_planner_retries(self):
        bad = {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": {
            "goal": "x", "criteria": [{"id": "C1", "text": "t", "kind": "rubric"}],
            "steps": [{"id": "S1", "title": "t", "worker": "clara", "goal": "g", "criteriaIds": ["C1"]}]}}}], "complete": {"status": "DONE", "summary": "plan"}}
        e = self.env(scope=Scope(allowed=["lucas", "emma", "lea"]), scenario={"plan:PLAN1:1": bad})
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        self.assertEqual(st["steps"]["PLAN1"]["attempts"], 2)                         # 1re tentative refusee par le moteur, 2e conforme
        ctx = open(os.path.join(e.svc.store.project_dir(pid), "steps", "PLAN1", "2", "context.md"), encoding="utf-8").read()
        self.assertIn("NOTE DE REPRISE", ctx)
        self.assertIn("lucas", ctx)                                                   # la liste des Workers autorisés est donnée au planificateur

    def test_the_planner_sees_which_workers_are_not_available(self):
        e = self.env(scope=Scope(allowed=["lucas", "emma", "lea"]))
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("PLAN1", {}).get("status") == "DONE")
        ctx = open(os.path.join(e.svc.store.project_dir(pid), "steps", "PLAN1", "1", "context.md"), encoding="utf-8").read()
        self.assertIn("NON disponibles", ctx)
        self.assertIn("clara", ctx)
        self.assertIn("unassignable", ctx)

    def test_paused_installation_blocks_its_steps(self):
        e = self.env(paused={(CLIENT, "emma")})
        pid = e.create()
        st = e.drive(pid, lambda s: s["steps"].get("S2", {}).get("status") == "BLOCKED")
        self.assertEqual(st["steps"]["S2"]["blockedReason"], "INSTALLATION_PAUSED")
        e.paused.clear()
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    def test_chloe_is_refused_without_the_entitlement_and_a_worker_page_project_works(self):
        e = self.env(scope=Scope(allowed=["lucas"], chloe=False))
        with self.assertRaises(ps.ProjectError) as cm:
            e.create(worker="chloe")
        self.assertEqual(cm.exception.code, "WORKER_NOT_INCLUDED")
        with self.assertRaises(ps.ProjectError) as cm:
            e.create(worker="clara")
        self.assertEqual(cm.exception.code, "WORKER_NOT_INCLUDED")
        pid = e.create(worker="lucas")
        self.assertEqual(e.state(pid)["leadWorker"], "lucas")

    # ------------------------------------------------------------------ creation : forfait, file, limites par jour
    def test_trial_plan_has_no_projects(self):
        e = self.env(plan="essai")
        with self.assertRaises(ps.ProjectError) as cm:
            e.create()
        self.assertEqual(cm.exception.code, "PROJECT_NOT_IN_PLAN")
        self.assertEqual(cm.exception.extra["upgrade"]["planId"], "pro")

    def test_allowlist_limits_the_rollout(self):
        e = self.env(allowlist="CLI-CUST-CCCCCCCC")
        with self.assertRaises(ps.ProjectError) as cm:
            e.create()
        self.assertEqual(cm.exception.code, "PROJECT_NOT_IN_PLAN")

    def test_active_project_limit_queues_then_refuses_beyond_the_queue(self):
        e = self.env(plan="solo", limits={"createPerDay": {"solo": 50}}, scenario={"PLAN1": {"hang": True, "actions": []}})
        p1 = e.create()
        out2 = e.svc.create_project(CLIENT, "Deuxieme projet", "chloe")
        self.assertEqual((out2["status"], out2["queuePosition"]), ("QUEUED", 1))
        out3 = e.svc.create_project(CLIENT, "Troisieme projet", "chloe")
        self.assertEqual((out3["status"], out3["queuePosition"]), ("QUEUED", 2))
        out4 = e.svc.create_project(CLIENT, "Quatrieme projet", "chloe")
        self.assertEqual(out4["queuePosition"], 3)
        with self.assertRaises(ps.ProjectError) as cm:                                  # la file est pleine : seul refus
            e.svc.create_project(CLIENT, "Cinquieme projet", "chloe")
        self.assertEqual(cm.exception.code in ("PROJECT_LIMIT_REACHED", "RATE_LIMITED"), True)
        self.assertEqual(e.svc.progress(CLIENT, out3["projectId"])["queuePosition"], 2)
        self.assertEqual(e.state(out2["projectId"])["status"], "QUEUED")

    def test_a_queued_project_starts_when_a_slot_is_free(self):
        e = self.env(plan="solo")
        p1 = e.create()
        p2 = e.svc.create_project(CLIENT, "Deuxieme projet", "chloe", auto_start=True)["projectId"]
        self.assertEqual(e.state(p2)["status"], "QUEUED")
        e.run_to_done(p1)
        st = e.drive(p2, lambda s: s["status"] != "QUEUED", timeout=60)
        self.assertIn(st["status"], ("PLANNING", "RUNNING", "WAITING_INPUT", "DONE"))

    def test_creations_per_day_are_limited(self):
        e = self.env(plan="solo", limits={"queuedProjects": 50, "activeProjects": {"solo": 50}, "createPerDay": {"solo": 3}}, scenario={"PLAN1": {"hang": True, "actions": []}})
        for i in range(3):
            e.svc.create_project(CLIENT, f"Projet numero {i}", "chloe")
        with self.assertRaises(ps.ProjectError) as cm:
            e.svc.create_project(CLIENT, "Projet de trop", "chloe")
        self.assertEqual(cm.exception.code, "RATE_LIMITED")
        self.assertTrue(cm.exception.extra.get("retryAfterSec"))

    def test_goal_validation(self):
        e = self.env()
        for goal, code in (("", "GOAL_REQUIRED"), ("   ", "GOAL_REQUIRED"), ("x" * 4001, "GOAL_TOO_LONG"), ("mon mot de passe: hunter2xyzabc", "INVALID_INPUT")):
            with self.assertRaises(ps.ProjectError, msg=goal[:20]) as cm:
                e.svc.create_project(CLIENT, goal, "chloe")
            self.assertEqual(cm.exception.code, code)
        with self.assertRaises(ps.ProjectError) as cm:
            e.svc.create_project(CLIENT, "ok", "chloe", level="turbo")
        self.assertEqual(cm.exception.code, "INVALID_INPUT")

    def test_creation_is_blocked_when_the_window_is_empty_with_the_renewal_time(self):
        usage = FakeUsage(session=0, week=500, month=900)
        e = self.env(usage=usage)
        with self.assertRaises(ps.ProjectError) as cm:
            e.create()
        self.assertEqual(cm.exception.code, "USAGE_LIMIT_REACHED")
        self.assertEqual(cm.exception.extra["limit"], "session")
        self.assertEqual(cm.exception.extra["resetsAtUtc"], usage.w["session"]["resetsAtUtc"])
        self.assertEqual(cm.exception.extra["upgrade"]["planId"], "pro")
        usage2 = FakeUsage(session=100, week=500, month=0)
        e2 = self.env(usage=usage2)
        with self.assertRaises(ps.ProjectError) as cm:
            e2.create()
        self.assertEqual(cm.exception.code, "SUBSCRIPTION_REQUIRED")

    def test_a_plan_whose_minimum_exceeds_the_monthly_balance_needs_a_decision(self):
        usage = FakeUsage(session=1000, week=1000, month=7)
        e = self.env(usage=usage, scenario={"plan": {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": {
            "goal": "x", "criteria": [{"id": "C1", "text": "t", "kind": "rubric"}],
            "steps": [{"id": "S1", "title": "t", "worker": "lucas", "goal": "g", "criteriaIds": ["C1"], "estimateCredits": 90}],
            "estimate": {"creditsMin": 70, "creditsMax": 140, "hoursMin": 1, "hoursMax": 3}}}}], "complete": {"status": "DONE", "summary": "plan"}}})
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        with self.assertRaises(ps.ProjectError) as cm:
            e.svc.approve_plan(CLIENT, pid)
        self.assertEqual(cm.exception.code, "PROJECT_EXCEEDS_QUOTA")
        self.assertEqual(cm.exception.extra["remaining"], 7 - e.state(pid)["budget"]["creditsCharged"])      # le solde mensuel apres le plan
        self.assertEqual(cm.exception.extra["estimate"]["creditsMin"], 70)
        self.assertEqual(len(cm.exception.extra["options"]), 3)
        self.assertEqual(e.state(pid)["status"], "WAITING_INPUT")                    # le client choisit : rien n'est parti

    def test_the_default_cap_follows_the_estimate_and_the_monthly_balance(self):
        usage = FakeUsage(session=1000, week=1000, month=40)
        e = self.env(usage=usage)
        pid = e.create(auto_start=False)
        st = e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        self.assertLessEqual(st["budget"]["creditsCap"], 40 + st["budget"]["creditsCharged"])
        usage2 = FakeUsage()
        e2 = self.env(usage=usage2)
        pid2 = e2.create(auto_start=False)
        st2 = e2.drive(pid2, lambda s: s["status"] == "WAITING_INPUT")
        self.assertEqual(st2["budget"]["creditsCap"], 34)                              # ceil(creditsMax 16 x 1,25) + 14 de part fixe du moteur (planification, verification, rapport)
        self.assertAlmostEqual(st2["budget"]["chfCeiling"], 34 * 0.0375, places=4)

    def test_absolute_cap_per_plan(self):
        e = self.env(plan="solo")
        with self.assertRaises(ps.ProjectError) as cm:
            e.svc.create_project(CLIENT, "x", "chloe", credits_cap=1000)
            pid = e.svc.list_projects(CLIENT)["projects"][0]["projectId"]
            e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
            e.svc.approve_plan(CLIENT, pid, credits_cap=1000)
        self.assertEqual(cm.exception.code, "INVALID_INPUT")

    # ------------------------------------------------------------------ cout reel : plafond atteint = PARTIAL, le travail est garde
    def test_cost_ceiling_makes_a_step_partial_and_it_continues_later_with_its_files(self):
        e = self.env(scenario={"S1:1": {"actions": [{"tool": "workspace_write", "input": {"path": "site/index.html", "mode": "overwrite", "content": "<h1>debut</h1> partie 1"}}],
                                        "complete": {"status": "PARTIAL", "summary": "Moitie faite.", "remaining": ["Finir la page"]}, "capped": True,
                                        "exitReason": "cost_ceiling", "chf": 0.3}})
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        self.assertGreaterEqual(st["steps"]["S1"]["attempts"], 2)                      # reprise en continuation
        ctx = open(os.path.join(e.svc.store.project_dir(pid), "steps", "S1", "2", "context.md"), encoding="utf-8").read()
        self.assertIn("Finir la page", ctx)
        self.assertGreaterEqual(st["budget"]["creditsCharged"], 8)                     # 0,3 CHF = 8 credits regles
        self.assertEqual(st["steps"]["S1"]["credits"] >= 8, True)

    def test_credits_are_ceil_of_the_cumulative_chf_never_rounded_per_step(self):
        e = self.env(scenario={"": {}, "S1": {"chf": 0.01, "actions": []}, "S2": {"chf": 0.01, "actions": []}})
        # deux etapes a 0,01 CHF : 0,02 CHF cumules = 1 credit au total, pas 2
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        st = e.state(pid)
        self.assertEqual(st["budget"]["creditsCharged"], 1)                            # le plan seul : 0,02 CHF = 1 credit
        self.assertEqual(sum(a for _r, a in e.usage.settled), 1)

    # ------------------------------------------------------------------ concurrence et interrupteurs
    def test_global_and_per_client_runner_caps(self):
        e = self.env(plan="pro", scenario={"S1": {"sleep": 1.2}, "S2": {"sleep": 1.2}})
        p1 = e.create()
        e.drive(p1, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING")
        self.assertEqual(e.svc.running_count(CLIENT), 1)
        for _ in range(10):
            e.svc.tick()
            self.assertLessEqual(e.svc.running_count(CLIENT), 1)                          # un lanceur par client (Pro)
            time.sleep(0.05)

    def test_kill_all_stops_every_runner_and_nothing_restarts(self):
        e = self.env(scenario={"S1": {"hang": True, "actions": []}})
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING")
        e.svc.write_control({"killAll": True, "pausedClients": []})
        e.svc.tick()
        self.assertEqual(e.svc.running_count(), 0)
        st = e.state(pid)
        self.assertEqual(st["steps"]["S1"]["status"], "READY")                              # rien n'est perdu : l'etape reprendra
        for _ in range(10):
            e.svc.tick()
            time.sleep(0.03)
        self.assertEqual(e.svc.running_count(), 0)
        e.set_scenario({})
        e.svc.write_control({"killAll": False, "pausedClients": []})
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    def test_pausing_a_client_pauses_its_projects_and_unpausing_resumes_them(self):
        e = self.env()
        pid = e.create()
        e.svc.admin_pause_client(CLIENT, True)
        st = e.drive(pid, lambda s: s["status"] == "PAUSED")
        self.assertEqual(st["statusReason"], "OWNER_PAUSED")
        with self.assertRaises(ps.ProjectError):
            e.svc.resume(CLIENT, pid)                                                        # le client ne peut pas lever la pause du proprietaire
        e.svc.admin_pause_client(CLIENT, False)
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    def test_disabled_service_does_nothing(self):
        e = self.env(enabled=False)
        with self.assertRaises(ps.ProjectError) as cm:
            e.create()
        self.assertEqual(cm.exception.code, "PROJECTS_DISABLED")
        e.svc.tick()
        e.svc.reap(boot=True)
        e.svc.start_supervisor()
        self.assertIsNone(e.svc._thread)

    def test_low_memory_prevents_new_steps(self):
        e = self.env()
        e.svc.mem_available = lambda: 300
        pid = e.create()
        for _ in range(10):
            e.svc.tick()
            time.sleep(0.03)
        self.assertEqual(e.svc.running_count(), 0)
        self.assertEqual(e.state(pid)["steps"]["PLAN1"]["status"], "READY")                 # la file s'allonge, aucune erreur
        e.svc.mem_available = lambda: 4000
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    def test_maximum_duration_ends_a_project_that_never_finishes(self):
        e = self.env(limits={"maxDurationHours": {"equipe": 0.0001}}, scenario={"S1": {"sleep": 0.5}})
        pid = e.create()
        st = e.drive(pid, lambda s: s["status"] in ("FAILED", "DONE"), timeout=60)
        self.assertEqual(st["status"], "FAILED")
        self.assertEqual(st["statusReason"], "MAX_DURATION")


if __name__ == "__main__":
    unittest.main(verbosity=2)
