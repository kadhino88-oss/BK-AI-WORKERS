# -*- coding: utf-8 -*-
"""Relecture de cohérence entre Workers (docs/AUTONOMY-ENGINE.md, 6c.7) : critère implicite « C-coherence », étape de vérification de portée
« consistency », écarts rendus à leur Worker propriétaire, fichier verification/<tour>/consistency.json. Faux lanceur, aucun réseau.

    python tests/projects/test_consistency.py"""
import copy
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine_harness import CLIENT, Env  # noqa: E402
import fake_runner  # noqa: E402
import projects_plan as plans  # noqa: E402

VERIFY_FAIL = {"complete": {"status": "DONE", "summary": "Contradiction relevee.", "verification": {
    "criteria": [{"id": "C-coherence", "verdict": "FAIL", "note": "Le prix de la seance differe entre deux pages.", "fixHint": "Aligner le prix",
                  "evidence": [{"type": "file", "ref": "site/about.html"}]}],
    "consistency": [{"worker": "emma", "files": ["site/about.html"], "issue": "A propos annonce 90 CHF, l'accueil annonce 80 CHF", "fixHint": "Mettre 80 CHF partout"}],
    "overall": "FAIL", "summary": "Un ecart."}}}


def plan_set(plan):
    return {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": plan}}], "complete": {"status": "DONE", "summary": "Plan pret."}}


class ConsistencyTests(unittest.TestCase):
    def env(self, **kw):
        e = Env(**kw)
        self.addCleanup(e.close)
        return e

    def verdicts(self, e, pid, rnd):
        v = json.load(open(os.path.join(e.svc.store.project_dir(pid), "verification", str(rnd), "verification.json"), encoding="utf-8"))
        return {c["id"]: c["verdict"] for c in v["criteria"]}

    def test_the_plan_helper_adds_the_criterion_only_when_two_workers_produce_and_only_once(self):
        two = {"criteria": [{"id": "C1", "text": "t", "kind": "rubric"}], "steps": [{"id": "S1", "worker": "lucas", "expectedOutputs": ["a.html"]},
                                                                                       {"id": "S2", "worker": "emma", "expectedOutputs": ["b.md"]}]}
        out = plans.with_coherence(two)
        self.assertEqual([c["id"] for c in out["criteria"]], ["C1", "C-coherence"])
        self.assertTrue(out["criteria"][1]["implicit"])
        self.assertEqual(out["criteria"][1]["kind"], "rubric")
        self.assertEqual(len(plans.with_coherence(out)["criteria"]), 2)                      # idempotent
        one = {"criteria": [{"id": "C1", "text": "t", "kind": "rubric"}], "steps": [{"id": "S1", "worker": "lucas", "expectedOutputs": ["a.html"]},
                                                                                       {"id": "S2", "worker": "lucas", "expectedOutputs": ["b.md"]}]}
        self.assertEqual(plans.with_coherence(one), one)
        silent = {"criteria": [], "steps": [{"id": "S1", "worker": "lucas", "expectedOutputs": ["a"]}, {"id": "S2", "worker": "emma"}]}
        self.assertEqual(plans.with_coherence(silent), silent)                                # un Worker qui ne produit aucun fichier ne compte pas
        full = {"criteria": [{"id": f"C{i}", "text": "t", "kind": "rubric"} for i in range(25)], "steps": two["steps"]}
        self.assertEqual(len(plans.with_coherence(full)["criteria"]), 25)                     # jamais au-delà de la limite

    def test_a_multi_worker_project_gets_the_criterion_a_second_verifier_and_the_consistency_file(self):
        e = self.env()
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        self.assertEqual({sid for sid in st["steps"] if sid.startswith("VER")}, {"VER1", "VERC1"})
        self.assertEqual(st["steps"]["VERC1"]["spec"]["scope"], "consistency")
        plan = e.svc.read_plan(pid)
        self.assertIn("C-coherence", [c["id"] for c in plan["criteria"]])
        self.assertEqual(self.verdicts(e, pid, 1), {"C1": "PASS", "C2": "PASS", "C-coherence": "PASS"})
        cons = json.load(open(os.path.join(e.svc.store.project_dir(pid), "verification", "1", "consistency.json"), encoding="utf-8"))
        self.assertEqual((cons["scope"], cons["verdict"], cons["issues"]), ("consistency", "PASS", []))
        inp1 = json.load(open(os.path.join(e.svc.store.project_dir(pid), "steps", "VER1", "1", "input.json"), encoding="utf-8"))
        inp2 = json.load(open(os.path.join(e.svc.store.project_dir(pid), "steps", "VERC1", "1", "input.json"), encoding="utf-8"))
        self.assertEqual((inp1["scope"], inp2["scope"]), ("final", "consistency"))
        ctx1 = open(os.path.join(e.svc.store.project_dir(pid), "steps", "VER1", "1", "context.md"), encoding="utf-8").read()
        ctx2 = open(os.path.join(e.svc.store.project_dir(pid), "steps", "VERC1", "1", "context.md"), encoding="utf-8").read()
        self.assertNotIn("C-coherence", ctx1.split("Dossier de vérification")[1].split("## 8.")[0])      # chaque contrôleur ne voit que SES critères
        dossier2 = ctx2.split("Dossier de vérification")[1].split("## 8.")[0]
        self.assertIn("C-coherence", dossier2)
        self.assertNotIn("C1 [", dossier2)
        self.assertIn("fiche de faits", ctx2)                                                # la mission de la relecture est dans la section « Étape »
        report = open(os.path.join(e.svc.store.project_dir(pid), "final-report.md"), encoding="utf-8").read()
        self.assertIn("C-coherence", report)

    def test_a_single_worker_project_has_no_consistency_step(self):
        plan = copy.deepcopy(fake_runner.default_plan({}))
        for s in plan["steps"]:
            s["worker"] = "lucas"
        e = self.env(scenario={"plan": plan_set(plan)})
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        self.assertNotIn("VERC1", st["steps"])
        self.assertNotIn("C-coherence", [c["id"] for c in e.svc.read_plan(pid)["criteria"]])

    def test_a_contradiction_becomes_a_fix_step_for_the_owner_then_the_second_round_passes(self):
        e = self.env(scenario={"VERC1": VERIFY_FAIL})
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        fix = st["steps"]["FIX1-1"]
        self.assertEqual((fix["kind"], fix["worker"]), ("fix", "emma"))                    # le Worker propriétaire du fichier, pas le chef de projet
        self.assertIn("80 CHF", fix["fixHint"])
        self.assertIn("site/about.html", fix["fixHint"])
        self.assertEqual(self.verdicts(e, pid, 1)["C-coherence"], "FAIL")
        self.assertEqual(self.verdicts(e, pid, 2)["C-coherence"], "PASS")
        self.assertEqual({"VER2", "VERC2"} <= set(st["steps"]), True)
        cons1 = json.load(open(os.path.join(e.svc.store.project_dir(pid), "verification", "1", "consistency.json"), encoding="utf-8"))
        self.assertEqual(cons1["verdict"], "FAIL")
        self.assertEqual(cons1["issues"][0]["worker"], "emma")
        self.assertEqual(st["counters"]["fixRounds"], 1)

    def test_an_issue_naming_a_worker_outside_the_plan_goes_to_the_project_lead(self):
        bad = copy.deepcopy(VERIFY_FAIL)
        bad["complete"]["verification"]["consistency"][0]["worker"] = "atlas"
        e = self.env(scenario={"VERC1": bad})
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["steps"]["FIX1-1"]["worker"], "chloe")

    def test_a_planner_that_declares_the_criterion_itself_does_not_duplicate_it(self):
        plan = copy.deepcopy(fake_runner.default_plan({}))
        plan["criteria"].append({"id": "C-coherence", "text": "Coherence", "kind": "rubric", "rubric": "x"})
        e = self.env(scenario={"plan": plan_set(plan)})
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        self.assertEqual([c["id"] for c in e.svc.read_plan(pid)["criteria"]].count("C-coherence"), 1)

    def test_removing_steps_at_validation_drops_the_criterion_when_only_one_worker_remains(self):
        e = self.env()
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        self.assertIn("C-coherence", [c["id"] for c in e.svc.read_plan(pid)["criteria"]])
        e.svc.approve_plan(CLIENT, pid, remove_steps=["S2"])
        plan = e.svc.read_plan(pid)
        self.assertNotIn("C-coherence", [c["id"] for c in plan["criteria"]])                # un seul Worker produit encore : plus rien à comparer
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    def test_a_worker_adding_a_step_does_not_break_the_implicit_criterion(self):
        add = {"actions": [{"tool": "workspace_write", "input": {"path": "site/index.html", "mode": "overwrite", "content": "<h1>x</h1> contenu"}},
                           {"tool": "deliverable_register", "input": {"path": "site/index.html", "title": "x"}},
                           {"tool": "project_plan", "input": {"action": "add_step", "step": {"title": "Mentions legales", "goal": "Ecrire les mentions", "worker": "lea",
                                                                                              "expectedOutputs": ["site/legal.html"]}}}]}
        e = self.env(scenario={"S1": add})
        pid = e.create()
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        plan = e.svc.read_plan(pid)
        self.assertEqual(len(plan["steps"]), 4)
        self.assertEqual([c["id"] for c in plan["criteria"]].count("C-coherence"), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
