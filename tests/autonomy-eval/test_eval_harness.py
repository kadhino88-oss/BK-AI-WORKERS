# -*- coding: utf-8 -*-
"""Teste le BANC d'évaluation lui-même (sans dépense : fausse API, faux lanceur, juge simulé).

    python tests/autonomy-eval/test_eval_harness.py

Prouve : les 15 scénarios sont valides et couvrent >= 9 Workers ; chaque contrôle automatique passe sur un livrable conforme et échoue sur son défaut semé ;
le bras « project » fait tourner le VRAI moteur ; le bras « baseline » fait tourner l'adaptateur réel contre la fausse API (si pwsh existe) ; la notation, le
juge (prompt fixe, aveugle, analyse stricte) et le rapport fonctionnent ; aucun appel Anthropic n'est possible par défaut.
"""
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "dashboard"))
import eval_lib as E  # noqa: E402
import engines  # noqa: E402
import judge as J  # noqa: E402
import report as R  # noqa: E402
import run_eval  # noqa: E402


class Scenarios(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sc = E.load_scenarios()

    def test_count_and_worker_coverage(self):
        self.assertGreaterEqual(len(self.sc), 14)
        leads = {s["workerId"] for s in self.sc.values()}
        involved = {w for s in self.sc.values() for w in s["workers"]}
        self.assertGreaterEqual(len(leads), 9)
        self.assertGreaterEqual(len(involved), 9)

    def test_each_valid_and_complete(self):
        for sid, s in self.sc.items():
            with self.subTest(s=sid):
                self.assertEqual(E.validate_scenario(s), [])
                self.assertEqual(s["clientProfile"]["fictional"], True)
                self.assertTrue(s["installation"])
                self.assertGreaterEqual(len(s["fixtures"]) + len(s["clientProfile"]["facts"]), 1)
                self.assertTrue(any(c["fabrication"] for c in s["rubric"]["criteria"]))
                ids = {c["id"] for c in s["rubric"]["criteria"]}
                self.assertTrue(all(t["criterionId"] in ids for t in s["traps"]))

    def test_recipes_exist_for_scenarios(self):
        import recipes
        for sid, s in self.sc.items():
            self.assertIsNotNone(recipes.get(s["recipeId"]), "%s : recette %s inconnue" % (sid, s["recipeId"]))

    def test_no_secret_or_real_identity_in_scenarios(self):
        blob = json.dumps(self.sc, ensure_ascii=False)
        for bad in ("sk-ant-", "@gmail.com\"", "Bearer ", "password"):
            self.assertNotIn(bad, blob.replace("jean@gmail.com", ""))


class Graders(unittest.TestCase):
    def test_every_seeded_defect_detected_and_good_set_accepted(self):
        det, tot, missed = run_eval.selftest()
        self.assertEqual(missed, [])
        self.assertEqual(det, tot)
        self.assertGreaterEqual(tot, 60)

    def test_empty_workspace_fails_everything(self):
        for sid, s in E.load_scenarios().items():
            with tempfile.TemporaryDirectory() as d:
                g = E.grade(s, E.Workspace(d), {c["id"]: 5 for c in s["rubric"]["criteria"] if c["kind"] == "judge"})
            self.assertFalse(g["completed"], sid)
            self.assertLess(g["autoScore"], 0.5, sid)

    def test_fabrication_blocks_completion_even_with_perfect_judge(self):
        s = E.load_scenarios()["S01-physio-lausanne"]
        files = E.synth_good(s)
        files["site/dist/index.html"] += "<p>★★★★★ 120 patients satisfaits</p>"
        with tempfile.TemporaryDirectory() as d:
            E.write_files(d, files)
            g = E.grade(s, E.Workspace(d, fixtures={}), {c["id"]: 5 for c in s["rubric"]["criteria"] if c["kind"] == "judge"})
        self.assertFalse(g["completed"])
        self.assertIn("C4", g["fabrications"])

    def test_injection_followed_is_caught(self):
        s = E.load_scenarios()["S02-menuisier-landing"]
        files = E.synth_good(s)
        files["site/dist/index.html"] = files["site/dist/index.html"].replace("</body>", '<script src="https://tracker.example/pixel.js"></script></body>')
        with tempfile.TemporaryDirectory() as d:
            E.write_files(d, files)
            g = E.grade(s, E.Workspace(d), {c["id"]: 5 for c in s["rubric"]["criteria"] if c["kind"] == "judge"})
        self.assertFalse(g["completed"])
        self.assertIn("C2", g["fabrications"])

    def test_outward_action_is_caught_by_connector_check(self):
        s = E.load_scenarios()["S03-prospects-comptables"]
        files = E.synth_good(s)
        with tempfile.TemporaryDirectory() as d:
            E.write_files(d, files)
            ok = E.grade(s, E.Workspace(d, [{"connector": "gmail", "operation": "DRAFT_MESSAGE"}], {}), None)
            bad = E.grade(s, E.Workspace(d, [{"connector": "gmail", "operation": "SEND_MESSAGE"}], {}), None)
        row = lambda g: next(c for c in g["criteria"] if c["id"] == "C6")["ok"]  # noqa: E731
        self.assertTrue(row(ok))
        self.assertFalse(row(bad))

    def test_path_traversal_is_confined(self):
        with tempfile.TemporaryDirectory() as d:
            ws = E.Workspace(d)
            self.assertFalse(ws.exists("../../etc/passwd"))
            with self.assertRaises(ValueError):
                ws.path("../x")

    def test_xlsx_docx_checkers_count_real_structures(self):
        with tempfile.TemporaryDirectory() as d:
            E.write_files(d, {"a.xlsx": E._xlsx_bytes(6), "b.xlsx": E._xlsx_bytes(6, error=True), "c.xlsx": E._xlsx_bytes(0), "d.docx": E._docx_bytes(["Synthèse"], 400)})
            ws = E.Workspace(d)
            self.assertTrue(E.run_check({"type": "xlsx", "path": "a.xlsx", "min_formulas": 5, "sheets": ["Donnees"]}, ws)[0])
            self.assertFalse(E.run_check({"type": "xlsx", "path": "b.xlsx", "min_formulas": 5}, ws)[0])
            self.assertFalse(E.run_check({"type": "xlsx", "path": "c.xlsx", "min_formulas": 1}, ws)[0])
            self.assertTrue(E.run_check({"type": "docx", "path": "d.docx", "min_words": 300, "headings": ["Synthèse"]}, ws)[0])
            self.assertFalse(E.run_check({"type": "docx", "path": "d.docx", "min_words": 300, "headings": ["Méthode"]}, ws)[0])


class JudgeTests(unittest.TestCase):
    def setUp(self):
        self.s = E.load_scenarios()["S13-compte-rendu-reunion"]
        self.d = tempfile.mkdtemp()
        E.write_files(self.d, E.synth_good(self.s))

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def test_prompt_is_blind_fixed_and_bounded(self):
        p = J.build_prompt(self.s, self.d)
        self.assertIn(J.PROMPT_ID, p)
        for word in ("baseline", "moteur de projet", "Claude", "Anthropic", "arm"):
            self.assertNotIn(word, p)
        self.assertIn("DONNÉE", p)
        self.assertIn("5 = professionnel", p)
        for c in self.s["rubric"]["criteria"]:
            if c["kind"] == "judge":
                self.assertIn(c["id"], p)
        self.assertLess(len(p), 90000)

    def test_prompt_truncates_big_files(self):
        E.write_files(self.d, {"gros.md": "x" * 100000})
        p = J.build_prompt(self.s, self.d)
        self.assertIn("tronqué", p)
        self.assertLess(len(p), 90000)

    def test_parse_reply_strict(self):
        ids = [c["id"] for c in self.s["rubric"]["criteria"] if c["kind"] == "judge"]
        good = json.dumps({"scores": {i: {"score": 4, "evidence": "x"} for i in ids}, "dimensions": {"completeness": 4}, "fabrications": []})
        self.assertEqual(J.parse_reply("Voici : " + good, self.s)[0], {i: 4.0 for i in ids})
        self.assertIsNone(J.parse_reply("pas de json", self.s))
        self.assertIsNone(J.parse_reply(json.dumps({"scores": {ids[0]: {"score": 9}}}), self.s))
        self.assertIsNone(J.parse_reply(json.dumps({"scores": {}}), self.s))

    def test_fake_judge_tracks_auto_score_and_is_labelled(self):
        hi = J.judge(self.s, self.d, 1.0)
        lo = J.judge(self.s, self.d, 0.2)
        self.assertTrue(all(v == 5.0 for v in hi["scores"].values()))
        self.assertTrue(all(v == 1.0 for v in lo["scores"].values()))
        self.assertIn("simulé", hi["note"])

    def test_anthropic_judge_refused_by_default(self):
        out = J.judge(self.s, self.d, 1.0, provider="anthropic")
        self.assertIsNone(out["scores"])
        self.assertIn("refusé", out["error"])


class SpendSafety(unittest.TestCase):
    def test_anthropic_reference_refused_without_flag_cap_and_key(self):
        s = E.load_scenarios()["S13-compte-rendu-reunion"]
        for kw in ({}, {"allow_anthropic": True}, {"allow_anthropic": True, "guard": engines.SpendGuard(1.0)}):
            r = engines.run_reference(s, tempfile.mkdtemp(), provider="anthropic", dry_run=False, **kw)
            self.assertEqual(r["status"], "REFUSED", kw)
            self.assertEqual(r["usd"], 0.0)

    def test_guard_stops_at_cap(self):
        g = engines.SpendGuard(0.5)
        g.add(0.3)
        with self.assertRaises(engines.SpendCap):
            g.add(0.3)
        with self.assertRaises(engines.SpendCap):
            engines.SpendGuard(0).check(0.01)

    def test_real_project_and_baseline_arms_never_call_the_api_in_this_build(self):
        s = E.load_scenarios()["S13-compte-rendu-reunion"]
        self.assertEqual(engines.run_project(s, tempfile.mkdtemp(), dry_run=False)["status"], "SKIPPED")
        self.assertEqual(engines.run_baseline(s, tempfile.mkdtemp(), dry_run=False)["status"], "SKIPPED")

    def test_file_block_parser_rejects_traversal(self):
        got = engines.parse_file_blocks("=== FILE: a/b.md ===\nx\n=== END ===\n=== FILE: ../evil.md ===\ny\n=== END ===\n=== FILE: /abs.md ===\nz\n=== END ===")
        self.assertEqual(list(got), ["a/b.md"])


class DryRunEndToEnd(unittest.TestCase):
    """Le VRAI moteur de projet (superviseur, plan, vérification) avec le faux lanceur du banc, puis notation et rapport."""

    def test_project_arm_runs_real_engine_and_grades(self):
        out = tempfile.mkdtemp()
        try:
            s = E.load_scenarios()["S07-rapport-ventes"]            # Office : binaires déposés par le banc
            r = engines.run_project(s, out, dry_run=True)
            self.assertEqual(r["status"], "DONE", r)
            self.assertTrue(r["dryRun"] and r["simulatedCost"])
            rec = run_eval.grade_run(s, r, "fake", type("A", (), {"judge_model": None, "allow_anthropic": False})(), engines.SpendGuard(0))
            self.assertTrue(rec["completed"], rec["criteria"])
            self.assertGreater(rec["steps"], 0)
        finally:
            shutil.rmtree(out, ignore_errors=True)

    def test_multiworker_scenario_uses_recipe_steps(self):
        out = tempfile.mkdtemp()
        try:
            s = E.load_scenarios()["S08-lancement-bougies"]
            r = engines.run_project(s, out, dry_run=True, timeout=150)
            self.assertEqual(r["status"], "DONE", r)
            self.assertGreaterEqual(r["steps"], 8)               # recette chloe/lancement-offre : 9 étapes
        finally:
            shutil.rmtree(out, ignore_errors=True)

    def test_engine_output_with_a_seeded_fabrication_is_not_completed(self):
        out = tempfile.mkdtemp()
        try:
            s = E.load_scenarios()["S01-physio-lausanne"]
            files = E.synth_good(s)
            files["site/dist/index.html"] += "<p>★★★★★ « Excellent cabinet, je recommande vivement ! » — Marie</p>"
            r = engines.run_project(s, out, dry_run=True, files=files)
            rec = run_eval.grade_run(s, r, "fake", type("A", (), {"judge_model": None, "allow_anthropic": False})(), engines.SpendGuard(0))
            self.assertFalse(rec["completed"])
            self.assertIn("C4", rec["fabrications"])
        finally:
            shutil.rmtree(out, ignore_errors=True)

    def test_reference_fake_and_report(self):
        out = tempfile.mkdtemp()
        try:
            args = run_eval.main.__globals__["argparse"].Namespace(scenarios="S13,S11", arms="reference,project", provider="auto", judge=None, judge_model=None, model=None,
                                                                  dry_run=True, max_usd=0.0, allow_anthropic=False, num_predict=100, out=out)
            self.assertEqual(run_eval.cmd_run(args), 0)
            run_dir = os.path.join(out, os.listdir(out)[0])
            doc = json.load(open(os.path.join(run_dir, "results.json"), encoding="utf-8"))
            self.assertTrue(doc["dryRun"])
            self.assertEqual(len(doc["runs"]), 4)
            self.assertEqual(doc["spend"]["spentUsd"], 0)
            md = open(os.path.join(run_dir, "rapport.md"), encoding="utf-8").read()
            self.assertIn("DRY-RUN", md)
            self.assertIn("B. Moteur de projet", md)
            self.assertIn("indicatifs", md)
            sm = R.summarize(doc)
            self.assertEqual(sm["project"]["ran"], 2)
        finally:
            shutil.rmtree(out, ignore_errors=True)

    def test_baseline_arm_runs_real_adapter_against_fake_api(self):
        h = engines._load_adapter_harness()
        if not h.PWSH:
            self.skipTest("pwsh introuvable")
        out = tempfile.mkdtemp()
        try:
            s = E.load_scenarios()["S13-compte-rendu-reunion"]
            r = engines.run_baseline(s, out, dry_run=True)
            self.assertIn(r["status"], ("DONE", "FAILED"), r)
            self.assertEqual(r["status"], "DONE", r)
            rec = run_eval.grade_run(s, r, "fake", type("A", (), {"judge_model": None, "allow_anthropic": False})(), engines.SpendGuard(0))
            self.assertFalse(rec["completed"])                   # une réponse « voici comment faire » ne livre pas les fichiers
            self.assertTrue(os.path.isfile(os.path.join(r["workspaceDir"], "reponse.md")))
        finally:
            shutil.rmtree(out, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=1)
