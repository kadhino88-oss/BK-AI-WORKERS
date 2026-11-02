# -*- coding: utf-8 -*-
"""Validation du plan BK-PROJECT-PLAN-V1 (docs/AUTONOMY-ENGINE.md, section 1.2) et chemins sûrs.

Lancer : python tests/projects/test_plan.py
"""
import copy
import json
import os
import sys
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import projects  # noqa: E402
import project_paths as pp  # noqa: E402

SCOPE = {"chloe": True, "allowed": ["lucas", "lea", "emma", "seoya"], "denied": [], "hireOffer": False}


def good_plan():
    return {
        "schema": "BK-PROJECT-PLAN-V1", "version": 1, "goal": "Créer le site vitrine de mon cabinet de physiothérapie à Lausanne, FR + EN",
        "language": "fr", "recipeId": "lucas/site-vitrine-pro",
        "assumptions": [{"id": "A1", "text": "5 pages : accueil, soins, équipe, tarifs, contact"}],
        "criteria": [
            {"id": "C1", "text": "Le site contient les 5 pages en FR et EN, sans lien cassé", "kind": "auto",
             "check": {"type": "file_exists", "path": "site/index.html", "minBytes": 100}},
            {"id": "C2", "text": "Chaque page a un titre", "kind": "auto", "check": {"type": "site_check", "must": ["meta"]}},
            {"id": "C3", "text": "Le ton est professionnel", "kind": "rubric", "rubric": "Aucune promesse de guérison."},
        ],
        "steps": [
            {"id": "S1", "title": "Cadrage", "worker": "lucas", "goal": "Arborescence", "dependsOn": [], "criteriaIds": ["C1"],
             "expectedOutputs": ["site/ARBORESCENCE.md"], "effort": "normal", "estimateCredits": 6},
            {"id": "S2", "title": "Charte", "worker": "lea", "goal": "Styles", "dependsOn": ["S1"], "criteriaIds": ["C2"], "estimateCredits": 10},
            {"id": "S3", "title": "Textes", "worker": "emma", "goal": "Textes", "dependsOn": ["S1"], "criteriaIds": ["C3"], "estimateCredits": 12},
            {"id": "S4", "title": "Pages", "worker": "lucas", "goal": "HTML", "dependsOn": ["S2", "S3"], "criteriaIds": ["C1"], "estimateCredits": 18},
        ],
        "estimate": {"creditsMin": 40, "creditsMax": 70, "hoursMin": 1.5, "hoursMax": 4},
        "needsFromClient": [{"id": "Q1", "question": "Adresse exacte ?", "blocking": False, "default": "[À COMPLÉTER : adresse]"}],
        "risks": ["Mentions légales"],
    }


class PlanValidation(unittest.TestCase):
    def test_good_plan_is_valid_and_normalised(self):
        # dans le serveur, l'atelier de sites (site_factory) enregistre site_check a son import : ici on teste le moteur SEUL, type non enregistre
        projects_plan = sys.modules["projects_plan"]
        was_registered = "site_check" in projects_plan._EXTRA_CHECK_TYPES
        projects_plan._EXTRA_CHECK_TYPES.discard("site_check")
        if was_registered:
            self.addCleanup(projects_plan.register_check_type, "site_check")
        r = projects.validate_plan(good_plan(), SCOPE)
        self.assertTrue(r.ok, r.errors)
        self.assertEqual(len(r.plan["steps"]), 4)
        self.assertEqual(r.plan["steps"][1]["effort"], "normal")
        # site_check n'est pas enregistre : le critere auto devient une grille, avec un avertissement
        c2 = next(c for c in r.plan["criteria"] if c["id"] == "C2")
        self.assertEqual(c2["kind"], "rubric")
        self.assertTrue(any(w["code"] == "CRITERION_AUTO_TO_RUBRIC" for w in r.warnings))

    def test_site_check_stays_auto_once_registered(self):
        projects.register_check_type("site_check")
        try:
            r = projects.validate_plan(good_plan(), SCOPE)
            self.assertEqual(next(c for c in r.plan["criteria"] if c["id"] == "C2")["kind"], "auto")
        finally:
            projects_plan = sys.modules["projects_plan"]
            projects_plan._EXTRA_CHECK_TYPES.discard("site_check")

    def test_cycle_is_rejected(self):
        p = good_plan()
        p["steps"][0]["dependsOn"] = ["S4"]
        r = projects.validate_plan(p, SCOPE)
        self.assertFalse(r.ok)
        self.assertIn("STEP_CYCLE", [e["code"] for e in r.errors])

    def test_unknown_dependency_and_self_dependency(self):
        p = good_plan()
        p["steps"][1]["dependsOn"] = ["S9", "S2"]
        r = projects.validate_plan(p, SCOPE)
        codes = [e["code"] for e in r.errors]
        self.assertIn("STEP_DEPENDENCY_UNKNOWN", codes)
        self.assertIn("STEP_SELF_DEPENDENCY", codes)

    def test_uncovered_criterion_is_rejected(self):
        p = good_plan()
        p["criteria"].append({"id": "C4", "text": "Autre", "kind": "rubric", "rubric": "x"})
        r = projects.validate_plan(p, SCOPE)
        self.assertIn("CRITERION_NOT_COVERED", [e["code"] for e in r.errors])

    def test_worker_outside_scope(self):
        p = good_plan()
        p["steps"][2]["worker"] = "clara"
        r = projects.validate_plan(p, SCOPE)
        self.assertIn("WORKER_NOT_IN_SCOPE", [e["code"] for e in r.errors])
        # Chloe n'est un executant valide que si son droit est actif
        p = good_plan()
        p["steps"][2]["worker"] = "chloe"
        self.assertTrue(projects.validate_plan(p, SCOPE).ok)
        self.assertIn("WORKER_NOT_IN_SCOPE", [e["code"] for e in projects.validate_plan(p, dict(SCOPE, chloe=False)).errors])

    def test_limits_on_steps_and_criteria(self):
        p = good_plan()
        p["steps"] = [{"id": f"S{i}", "title": "t", "worker": "lucas", "goal": "g", "criteriaIds": ["C1", "C2", "C3"]} for i in range(1, 42)]
        r = projects.validate_plan(p, SCOPE)
        self.assertIn("TOO_MANY_STEPS", [e["code"] for e in r.errors])
        p = good_plan()
        p["criteria"] = [{"id": f"C{i}", "text": "x", "kind": "rubric"} for i in range(1, 27)]
        self.assertIn("TOO_MANY_CRITERIA", [e["code"] for e in projects.validate_plan(p, SCOPE).errors])

    def test_hostile_values_do_not_crash(self):
        for bad in (None, [], "x", 5, {"steps": "x", "criteria": 3}, {"goal": "g", "criteria": [None, 3], "steps": [None, {"id": 7}]}):
            r = projects.validate_plan(bad, SCOPE)
            self.assertFalse(r.ok)

    def test_output_paths_are_checked(self):
        p = good_plan()
        p["steps"][0]["expectedOutputs"] = ["../etc/passwd"]
        self.assertIn("OUTPUT_PATH_INVALID", [e["code"] for e in projects.validate_plan(p, SCOPE).errors])

    def test_estimate_is_computed_when_missing(self):
        p = good_plan()
        del p["estimate"]
        r = projects.validate_plan(p, SCOPE)
        self.assertTrue(r.ok)
        self.assertGreater(r.plan["estimate"]["creditsMax"], 0)

    def test_critical_path_and_percent(self):
        r = projects.validate_plan(good_plan(), SCOPE)
        cp = projects.critical_path_lengths(r.plan["steps"])
        self.assertEqual(cp["S1"], 3)
        self.assertEqual(cp["S4"], 1)
        done = {"S1": "DONE", "S2": "DONE"}
        pct = projects.percent_done(r.plan["steps"], lambda i: done.get(i, "PENDING"))
        self.assertEqual(pct, round(100 * 16 / 46))

    def test_consistency_review_needed_with_two_producing_workers(self):
        p = good_plan()
        p["steps"][0]["expectedOutputs"] = ["a.md"]
        p["steps"][1]["expectedOutputs"] = ["b.md"]
        self.assertTrue(projects.needs_consistency_review(projects.validate_plan(p, SCOPE).plan))
        p = good_plan()
        self.assertFalse(projects.needs_consistency_review(projects.validate_plan(p, SCOPE).plan))

    def test_schema_files_are_valid_json(self):
        d = os.path.join(REPO, "core", "projects", "schemas")
        names = sorted(os.listdir(d))
        self.assertEqual(len(names), 6, names)
        for n in names:
            with open(os.path.join(d, n), encoding="utf-8") as f:
                self.assertTrue(json.load(f)["$id"].startswith("BK-"))


class SafePaths(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.ws = tempfile.mkdtemp(prefix="bkpaths-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.ws, ignore_errors=True))

    def bad(self, path, **kw):
        with self.assertRaises(pp.PathError) as cm:
            pp.resolve(self.ws, path, **kw)
        return cm.exception.code

    def test_syntax_corpus(self):
        for p in ("", "/etc/passwd", "../x", "a/../b", "a//b", "a/./b", ".hidden", "a/.env", "a b.txt", "a\\b", "C:/x", "a/b/c/d/e/f/g/h/i.txt",
                  "x" * 200, "a\x00b", "a\nb", "nul.txt", "CON", "%2e%2e/x", "a/" + "n" * 65, "é.txt"):
            self.assertEqual(self.bad(p), "PATH_INVALID", repr(p))
        self.assertEqual(self.bad(123), "PATH_INVALID")
        for ok in ("a.txt", "site/index.html", "data/prospects-2026.csv", "a/b/c/d/e/f/g/h.md"):
            pp.split_rel(ok)

    def test_extension_allowlist(self):
        self.assertEqual(self.bad("run.exe", allowed_ext=pp.WRITE_EXT), "EXT_NOT_ALLOWED")
        self.assertEqual(self.bad("x.png", allowed_ext=pp.WRITE_EXT), "EXT_NOT_ALLOWED")
        self.assertEqual(self.bad("noext", allowed_ext=pp.WRITE_EXT), "EXT_NOT_ALLOWED")
        pp.resolve(self.ws, "x.png", allowed_ext=pp.IMPORT_EXT)

    def test_symlink_component_is_refused(self):
        outside = __import__("tempfile").mkdtemp(prefix="bkoutside-")
        self.addCleanup(lambda: __import__("shutil").rmtree(outside, ignore_errors=True))
        with open(os.path.join(outside, "secret.txt"), "w") as f:
            f.write("secret")
        try:
            os.symlink(outside, os.path.join(self.ws, "link"), target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks non disponibles")
        self.assertEqual(self.bad("link/secret.txt"), "PATH_INVALID")
        self.assertEqual(self.bad("link"), "PATH_INVALID")
        try:
            os.symlink(os.path.join(outside, "secret.txt"), os.path.join(self.ws, "f.txt"))
            self.assertEqual(self.bad("f.txt"), "PATH_INVALID")
        except (OSError, NotImplementedError):
            pass

    def test_usage_counts_files(self):
        os.makedirs(os.path.join(self.ws, "a"))
        with open(os.path.join(self.ws, "a", "x.txt"), "w") as f:
            f.write("12345")
        self.assertEqual(pp.usage(self.ws), (1, 5))

    def test_atomic_write_leaves_no_temp_file(self):
        full = pp.resolve(self.ws, "d/x.txt")
        pp.atomic_write_bytes(full, b"hello")
        self.assertEqual(os.listdir(os.path.dirname(full)), ["x.txt"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
