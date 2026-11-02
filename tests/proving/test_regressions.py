# -*- coding: utf-8 -*-
"""Régressions trouvées par le banc de preuve (docs/PROVING-REPORT.md). Chaque test échoue sur le code d'avant le correctif.

    python tests/proving/test_regressions.py"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tests", "projects"))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
from engine_harness import Env  # noqa: E402


class RecipeBlockTests(unittest.TestCase):
    """Le planificateur choisit une recette : elle est inscrite dans plan.recipeId, pas dans state.recipeId (réservé à une recette imposée à la création).
    Les étapes d'exécution doivent recevoir le guide de CETTE recette (render_for_step), sinon seule la planification profite des recettes."""

    def setUp(self):
        self.env = Env()
        self.addCleanup(self.env.close)

    def test_step_gets_the_recipe_chosen_by_the_planner(self):
        svc = self.env.svc
        state = {"recipeId": None, "leadWorker": "lucas", "goal": "site vitrine", "language": "fr", "clientId": self.env.client}
        plan = {"recipeId": "lucas/site-vitrine-pro", "steps": [{"id": "S1"}]}
        block = svc._recipe_block(state, plan, "execute", {"id": "S1"})
        self.assertTrue(block and "S1" in block, block)

    def test_recipe_forced_at_creation_still_wins(self):
        svc = self.env.svc
        state = {"recipeId": "alex/gestion-prospects", "leadWorker": "lucas", "goal": "x", "language": "fr", "clientId": self.env.client}
        plan = {"recipeId": "lucas/site-vitrine-pro", "steps": [{"id": "S1"}]}
        block = svc._recipe_block(state, plan, "execute", {"id": "S1"})
        self.assertIn("Cadrage", block)                          # étape S1 de la recette de prospects

    def test_no_recipe_anywhere_gives_empty_block(self):
        svc = self.env.svc
        state = {"recipeId": None, "leadWorker": "lucas", "goal": "x", "language": "fr", "clientId": self.env.client}
        self.assertEqual(svc._recipe_block(state, {"steps": [{"id": "S1"}]}, "execute", {"id": "S1"}), "")


class AtomicWriteTests(unittest.TestCase):
    """Windows : un lecteur qui tient state.json au moment du remplacement faisait échouer l'écriture (WinError 5) : la fin d'étape était perdue et l'étape
    restait RUNNING. server._write_json_atomic (écrivain de projects_store) doit réessayer, comme project_paths.atomic_write_bytes."""

    def test_replace_denied_twice_then_ok(self):
        import importlib.util
        import json
        import shutil
        import tempfile
        spec = importlib.util.spec_from_file_location("pricing_common_p", os.path.join(REPO, "tests", "pricing", "common.py"))
        pc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(pc)
        server, root = pc.load_server("bk_server_proving_regress")
        tmp = tempfile.mkdtemp(prefix="bkreg-")
        self.addCleanup(shutil.rmtree, tmp, True)
        real = os.replace
        calls = {"n": 0}

        def flaky(a, b):
            calls["n"] += 1
            if calls["n"] <= 2:
                raise PermissionError(13, "Accès refusé")
            return real(a, b)
        target = os.path.join(tmp, "state.json")
        os.replace = flaky
        try:
            server._write_json_atomic(target, {"status": "RUNNING"})
        finally:
            os.replace = real
        with open(target, encoding="utf-8") as f:
            self.assertEqual(json.load(f), {"status": "RUNNING"})
        self.assertEqual(calls["n"], 3)
        self.assertEqual([n for n in os.listdir(tmp) if n.startswith(".tmp-")], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
