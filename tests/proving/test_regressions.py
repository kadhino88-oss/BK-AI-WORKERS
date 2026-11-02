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


if __name__ == "__main__":
    unittest.main(verbosity=2)
