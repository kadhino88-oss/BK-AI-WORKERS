# -*- coding: utf-8 -*-
"""Moteur de projets, parcours complets avec un faux lanceur : plan -> etapes -> verification -> correction -> rapport final -> DONE.

    python tests/projects/test_engine_flow.py"""
import json
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine_harness import CLIENT, CLIENT_B, Env, FakeUsage, Scope  # noqa: E402
import projects_store as ps  # noqa: E402


class FlowTests(unittest.TestCase):
    def env(self, **kw):
        e = Env(**kw)
        self.addCleanup(e.close)
        return e

    # ------------------------------------------------------------------ le parcours nominal
    def test_full_project_plans_works_verifies_and_completes(self):
        e = self.env()
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE", st)
        plan = e.svc.read_plan(pid)
        self.assertEqual([s["id"] for s in plan["steps"]], ["S1", "S2", "S3"])
        for rel in ("site/index.html", "site/about.html", "site/links.html"):
            self.assertTrue(os.path.isfile(e.wspath(pid, rel)), rel)
        deliverables = e.svc.store.read_json(pid, "deliverables.json")["items"]
        self.assertEqual(sorted(d["path"] for d in deliverables), ["site/about.html", "site/index.html", "site/links.html"])
        # relais : le rapport de S1 est ecrit pour S3, la verification a tourne, le rapport final cite les preuves
        self.assertTrue(os.path.isfile(e.wspath(pid, "handoff/S1.md")))
        ver = json.load(open(os.path.join(e.svc.store.project_dir(pid), "verification", "1", "verification.json"), encoding="utf-8"))
        self.assertEqual(ver["overall"], "PASS")
        self.assertEqual({c["id"]: c["verdict"] for c in ver["criteria"]}, {"C1": "PASS", "C2": "PASS", "C-coherence": "PASS"})   # lucas + emma : relecture de coherence
        report = open(os.path.join(e.svc.store.project_dir(pid), "final-report.md"), encoding="utf-8").read()
        self.assertIn("Rapport final", report)
        self.assertIn("| C1", report)
        self.assertIn("PASS", report)
        # budget : cout mesure, regle dans les fenetres d'usage, une ligne de journal par etape
        b = st["budget"]
        self.assertGreater(b["creditsCharged"], 0)
        self.assertEqual(sum(a for _r, a in e.usage.settled), b["creditsCharged"])
        self.assertEqual(e.usage.w["month"]["reserved"], 0)
        ledger = e.svc.store.read_jsonl(pid, "cost-ledger.jsonl")
        self.assertGreaterEqual(len(ledger), 6)
        types_ = [x["type"] for x in e.events(pid)]
        for t in ("project_created", "plan_ready", "plan_approved", "step_started", "step_finished", "deliverable_added", "verification_started", "verification_result", "done"):
            self.assertIn(t, types_)
        self.assertEqual([x for x in e.events(pid, ["status_changed"]) if "DONE" in x["text"]][-1]["data"]["to"], "DONE")
        self.assertTrue(any(n[1] == "done" for n in e.notifications))
        e.svc.drain_notifications()

    def test_each_step_runs_with_its_own_worker_and_the_plan_has_a_hand_off(self):
        e = self.env()
        pid = e.create()
        st = e.run_to_done(pid)
        who = {sid: s["worker"] for sid, s in st["steps"].items() if sid.startswith("S")}
        self.assertEqual(who, {"S1": "lucas", "S2": "emma", "S3": "lucas"})
        inp = json.load(open(os.path.join(e.svc.store.project_dir(pid), "steps", "S3", "1", "input.json"), encoding="utf-8"))
        self.assertEqual(inp["worker"], "lucas")
        ctx = open(inp["paths"]["context"], encoding="utf-8").read()
        self.assertIn("Fichiers : site/index.html", ctx)               # note de relais de S1 dans le contexte de S3
        self.assertIn("Fichiers : site/about.html", ctx)               # et celle de S2, un AUTRE Worker

    def test_plan_waits_for_the_client_without_auto_start_and_costs_only_the_plan(self):
        e = self.env()
        pid = e.create(auto_start=False)
        st = e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        self.assertEqual(st["waitingFor"], "PLAN_VALIDATION")
        self.assertEqual([k for k, v in st["steps"].items() if v["status"] == "DONE"], ["PLAN1"])
        before = st["budget"]["creditsCharged"]
        time.sleep(0.3)
        e.svc.tick()
        self.assertEqual(e.state(pid)["status"], "WAITING_INPUT")       # rien ne demarre sans le « go »
        out = e.svc.approve_plan(CLIENT, pid)
        self.assertEqual(out["status"], "RUNNING")
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        self.assertGreater(st["budget"]["creditsCharged"], before)

    def test_approve_plan_can_remove_a_step_and_its_criteria_are_dropped_with_a_note(self):
        e = self.env()
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        e.svc.approve_plan(CLIENT, pid, remove_steps=["S2"])
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        self.assertEqual(st["steps"]["S2"]["status"], "SKIPPED")
        plan = e.svc.read_plan(pid)
        self.assertEqual([c["id"] for c in plan["criteria"]], ["C1"])
        self.assertFalse(os.path.exists(e.wspath(pid, "site/about.html")))
        self.assertTrue(any("Retiré" in a["text"] for a in plan["assumptions"]))

    def test_plan_rejection_replans_with_the_feedback(self):
        e = self.env()
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        out = e.svc.reject_plan(CLIENT, pid, "Je veux une page tarifs en plus")
        self.assertEqual(out["status"], "PLANNING")
        st = e.drive(pid, lambda s: s["status"] == "WAITING_INPUT" and s["planVersion"] == 2)
        self.assertEqual(st["counters"]["replans"], 1)
        ctx = open(os.path.join(e.svc.store.project_dir(pid), "steps", "REPLAN1", "1", "context.md"), encoding="utf-8").read()
        self.assertIn("page tarifs", ctx)
        self.assertIn("plan_rejected", [x["type"] for x in e.events(pid)])

    # ------------------------------------------------------------------ la verification echoue une fois, la correction passe
    def test_a_failed_criterion_is_fixed_once_then_verified(self):
        e = self.env(scenario={
            "verify:VER1": {"complete": {"status": "DONE", "summary": "Un defaut.", "verification": {"criteria": [
                {"id": "C1", "verdict": "PASS", "note": "ok", "evidence": [{"type": "file", "ref": "site/index.html"}]},
                {"id": "C2", "verdict": "FAIL", "note": "Un temoignage invente dans about.html", "evidence": [{"type": "file", "ref": "site/about.html"}],
                 "fixHint": "Retirer le temoignage de Mme Dupont"}], "overall": "FAIL", "summary": "1 echec"}}},
            "fix": {"actions": [{"tool": "workspace_write", "input": {"path": "site/about.html", "mode": "overwrite", "content": "<h1>A propos corrige</h1>"}}],
                    "complete": {"status": "DONE", "summary": "Temoignage retire.", "deliverables": [{"path": "site/about.html", "title": "A propos"}]}},
        })
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE", st)
        self.assertEqual(st["counters"]["fixRounds"], 1)
        self.assertEqual(st["counters"]["verifyRounds"], 2)
        fix = [s for s in st["steps"].values() if s["kind"] == "fix"]
        self.assertEqual(len(fix), 1)
        self.assertEqual(fix[0]["worker"], "emma")                      # la correction va au Worker proprietaire du critere en echec
        self.assertEqual(fix[0]["status"], "DONE")
        self.assertEqual(open(e.wspath(pid, "site/about.html"), encoding="utf-8").read(), "<h1>A propos corrige</h1>")
        ctx = open(os.path.join(e.svc.store.project_dir(pid), "steps", fix[0]["id"], "1", "context.md"), encoding="utf-8").read()
        self.assertIn("Retirer le temoignage de Mme Dupont", ctx)       # le fixHint est dans le contexte de la correction
        v1 = json.load(open(os.path.join(e.svc.store.project_dir(pid), "verification", "1", "verification.json"), encoding="utf-8"))
        v2 = json.load(open(os.path.join(e.svc.store.project_dir(pid), "verification", "2", "verification.json"), encoding="utf-8"))
        self.assertEqual((v1["overall"], v2["overall"]), ("FAIL", "PASS"))

    def test_after_two_failed_fix_rounds_the_client_chooses_and_can_accept_the_gaps(self):
        always_fail = {"complete": {"status": "DONE", "summary": "Toujours un defaut.", "verification": {"criteria": [
            {"id": "C1", "verdict": "PASS", "note": "ok", "evidence": [{"type": "file", "ref": "site/index.html"}]},
            {"id": "C2", "verdict": "FAIL", "note": "Ton non professionnel", "evidence": [{"type": "file", "ref": "site/about.html"}], "fixHint": "Reformuler"},
            {"id": "C-coherence", "verdict": "PASS", "note": "ok", "evidence": [{"type": "file", "ref": "site/index.html"}]}],
            "overall": "FAIL", "summary": "echec"}}}
        e = self.env(scenario={"verify": always_fail})
        pid = e.create()
        st = e.drive(pid, lambda s: s["status"] == "WAITING_INPUT" and s.get("waitingFor") == "CRITERIA_FAILED")
        self.assertEqual(st["counters"]["fixRounds"], 2)                 # jamais plus de 2 tours, aucune boucle infinie
        detail = e.svc.get_detail(CLIENT, pid)
        self.assertTrue(detail["capabilities"]["canAcceptGaps"])
        self.assertEqual({c["id"]: c["verdict"] for c in detail["plan"]["criteria"]}["C2"], "FAIL")
        out = e.svc.accept_gaps(CLIENT, pid)
        self.assertEqual(out["status"], "DONE")
        st = e.state(pid)
        self.assertEqual(st["acceptedGaps"], ["C2"])
        report = open(os.path.join(e.svc.store.project_dir(pid), "final-report.md"), encoding="utf-8").read()
        self.assertIn("accepté en l'état", report)
        self.assertIn("C2", report)

    def test_an_auto_criterion_cannot_pass_if_its_typed_check_fails_even_if_the_verifier_says_pass(self):
        e = self.env(scenario={"S1": {"actions": [{"tool": "workspace_write", "input": {"path": "site/index.html", "mode": "overwrite", "content": "x"}}],
                                      "complete": {"status": "DONE", "summary": "fait", "deliverables": [{"path": "site/index.html", "title": "i"}]}}})
        # index.html fait 1 octet : le controle file_exists minBytes 5 echoue, quoi que dise le verificateur
        pid = e.create()
        st = e.drive(pid, lambda s: s["status"] == "WAITING_INPUT" and s.get("waitingFor") == "CRITERIA_FAILED", timeout=90)
        v = json.load(open(os.path.join(e.svc.store.project_dir(pid), "verification", "1", "verification.json"), encoding="utf-8"))
        self.assertEqual({c["id"]: c["verdict"] for c in v["criteria"]}["C1"], "FAIL")
        self.assertNotEqual(st["status"], "DONE")

    def test_a_pass_without_valid_evidence_is_downgraded_to_unverifiable(self):
        e = self.env(scenario={"verify": {"complete": {"status": "DONE", "summary": "ok", "verification": {"criteria": [
            {"id": "C1", "verdict": "PASS", "note": "ok", "evidence": [{"type": "file", "ref": "site/index.html"}]},
            {"id": "C2", "verdict": "PASS", "note": "ok", "evidence": [{"type": "file", "ref": "site/n-existe-pas.html"}]}], "overall": "PASS"}}}})
        pid = e.create()
        st = e.drive(pid, lambda s: s["status"] == "WAITING_INPUT" and s.get("waitingFor") == "CRITERIA_FAILED", timeout=90)
        v = json.load(open(os.path.join(e.svc.store.project_dir(pid), "verification", "1", "verification.json"), encoding="utf-8"))
        c2 = {c["id"]: c for c in v["criteria"]}["C2"]
        self.assertEqual(c2["verdict"], "UNVERIFIABLE")
        self.assertIn("rétrogradé", c2["note"])
        self.assertNotEqual(st["status"], "DONE")                       # jamais « termine » sur une preuve introuvable

    # ------------------------------------------------------------------ le client parle au projet
    def test_a_blocking_question_pauses_only_its_step_and_the_answer_resumes_it(self):
        e = self.env(scenario={"S2": {"actions": [{"tool": "request_input", "input": {"question": "Quel est le numero de telephone ?", "blocking": True}}],
                                      "complete": {"status": "NEEDS_INPUT", "summary": "En attente du telephone."}}})
        pid = e.create()
        st = e.drive(pid, lambda s: s["status"] == "WAITING_INPUT" and s.get("waitingFor") == "INPUT")
        self.assertEqual(st["steps"]["S2"]["status"], "BLOCKED")
        self.assertEqual(st["steps"]["S1"]["status"], "DONE")           # l'etape independante a continue
        qs = e.svc.get_detail(CLIENT, pid)["questions"]
        self.assertEqual(len(qs), 1)
        e.set_scenario({})
        e.svc.answer_input(CLIENT, pid, qs[0]["id"], "021 555 12 34")
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        ctx = open(os.path.join(e.svc.store.project_dir(pid), "steps", "S2", "2", "context.md"), encoding="utf-8").read()
        self.assertIn("021 555 12 34", ctx)                              # la reponse est dans le contexte de la reprise

    def test_a_question_is_answered_even_while_the_project_is_paused(self):
        e = self.env(scenario={"S1": {"sleep": 1.5}})
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING")
        e.svc.pause(CLIENT, pid)
        out = e.svc.post_message(CLIENT, pid, "question", "Ou en est le site ?")
        self.assertIn("messageId", out)
        e.drive(pid, lambda s: any(x["kind"] == "answer" and x["status"] == "DONE" for x in s["steps"].values()))
        self.assertEqual(e.state(pid)["status"], "PAUSED")               # toujours en pause
        msgs = e.svc.list_messages(CLIENT, pid)["messages"]
        self.assertEqual([m["type"] for m in msgs], ["question", "answer"])
        self.assertIn("reponse", msgs[1]["text"])

    def test_a_change_message_triggers_a_visible_replan(self):
        e = self.env()
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "DONE")
        out = e.svc.post_message(CLIENT, pid, "change", "Ajoutez une page contact")
        self.assertTrue(out["willReplan"])
        st = e.drive(pid, lambda s: s["counters"]["replans"] == 1 and any(x["kind"] == "replan" and x["status"] == "DONE" for x in s["steps"].values()))
        self.assertIn("replan", [x["type"] for x in e.events(pid)])
        e.run_to_done(pid)

    def test_a_note_is_given_to_the_next_step(self):
        e = self.env(scenario={"S1": {"sleep": 1.0}})
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING")
        e.svc.post_message(CLIENT, pid, "note", "Utilisez le vouvoiement partout")
        e.set_scenario({})
        e.run_to_done(pid)
        ctx = open(os.path.join(e.svc.store.project_dir(pid), "steps", "S2", "1", "context.md"), encoding="utf-8").read()
        self.assertIn("vouvoiement", ctx)

    # ------------------------------------------------------------------ pause, annulation, relance
    def test_pause_stops_new_steps_and_resume_continues(self):
        e = self.env(scenario={"S1": {"sleep": 0.8}})
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING")
        e.svc.pause(CLIENT, pid)
        e.drive(pid, lambda s: s["steps"]["S1"]["status"] == "DONE", timeout=30)         # l'etape lancee se termine (la duree depend de la machine)
        for _ in range(10):
            e.svc.tick()
            time.sleep(0.05)
        st = e.state(pid)
        self.assertEqual(st["status"], "PAUSED")
        self.assertEqual(st["steps"]["S1"]["status"], "DONE")           # l'etape lancee se termine
        self.assertNotIn(st["steps"]["S2"]["status"], ("RUNNING", "DONE"))   # rien d'autre ne demarre
        e.svc.resume(CLIENT, pid)
        e.set_scenario({})
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    def test_cancel_kills_the_running_step_and_rejects_pending_approvals(self):
        e = self.env(scenario={"S1": {"hang": True, "actions": []}})
        pid = e.create()
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "RUNNING")
        self.assertEqual(e.svc.running_count(), 1)
        e.svc.cancel(CLIENT, pid, "plus besoin")
        st = e.state(pid)
        self.assertEqual(st["status"], "CANCELLED")
        self.assertEqual(e.svc.running_count(), 0)                      # le processus est arrete
        self.assertEqual(st["steps"]["S1"]["status"], "SKIPPED")
        with self.assertRaises(ps.ProjectError):
            e.svc.resume(CLIENT, pid)

    def test_three_steps_without_any_progress_pause_the_project(self):
        nothing = {"actions": [], "complete": {"status": "DONE", "summary": "Rien a faire."}}
        e = self.env(scenario={"S1": nothing, "S2": nothing, "S3": nothing})
        pid = e.create()
        st = e.drive(pid, lambda s: s["status"] == "PAUSED")
        self.assertEqual(st["statusReason"], "NO_PROGRESS")
        e.svc.resume(CLIENT, pid)
        self.assertIn(e.state(pid)["status"], ("RUNNING", "VERIFYING"))          # reprise : tout est fait, la verification peut commencer
        self.assertEqual(e.state(pid)["counters"]["noProgress"], 0)

    def test_a_step_that_fails_three_times_blocks_its_dependents_and_asks_for_a_replan(self):
        e = self.env(scenario={"S2": {"status": "FAILED", "error": "BOOM", "actions": []}})
        pid = e.create()
        st = e.drive(pid, lambda s: s["steps"].get("S2", {}).get("status") == "FAILED")
        self.assertEqual(st["steps"]["S2"]["attempts"], 3)
        self.assertEqual(st["steps"]["S1"]["status"], "DONE")
        st = e.drive(pid, lambda s: s["counters"]["replans"] >= 1)
        self.assertEqual(st["steps"]["S3"]["status"] in ("BLOCKED", "PENDING"), True)
        self.assertIn("replan", [x["type"] for x in e.events(pid)])

    def test_retry_step_gives_a_failed_step_a_fresh_start(self):
        e = self.env(scenario={"S2": {"status": "FAILED", "error": "BOOM"}}, limits={"step": {"maxReplans": 0}})
        pid = e.create()
        st = e.drive(pid, lambda s: s["status"] == "FAILED")
        self.assertEqual(st["steps"]["S2"]["status"], "FAILED")
        e.set_scenario({})
        e.svc.retry_step(CLIENT, pid, "S2")
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    # ------------------------------------------------------------------ isolation entre clients
    def test_a_project_of_another_client_is_invisible_everywhere(self):
        e = self.env()
        pid = e.create()
        for fn, args in ((e.svc.get_detail, ()), (e.svc.progress, (0,)), (e.svc.list_approvals, ()), (e.svc.list_deliverables, ()), (e.svc.list_messages, ()),
                         (e.svc.pause, ()), (e.svc.cancel, ()), (e.svc.resume, ()), (e.svc.get_log, ())):
            with self.assertRaises(ps.ProjectNotFound, msg=fn.__name__):
                fn(CLIENT_B, pid, *args)
        self.assertEqual(e.svc.list_projects(CLIENT_B)["projects"], [])
        self.assertEqual(len(e.svc.list_projects(CLIENT)["projects"]), 1)
        with self.assertRaises(ps.ProjectNotFound):
            e.svc.resolve_download(CLIENT_B, pid, "final-report.md")
        with self.assertRaises(ps.ProjectNotFound):
            e.svc.owned_state(CLIENT, "PRJ-" + "0" * 32)
        e.drive(pid, lambda s: s["steps"].get("S1", {}).get("status") == "DONE")


if __name__ == "__main__":
    unittest.main(verbosity=2)
