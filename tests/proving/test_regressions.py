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


class SmallProjectBudgetTests(unittest.TestCase):
    """Le plafond suit l'estimation du plan (travail seul). Sans part fixe pour la planification, la vérification et le rapport final, un petit projet
    atteignait BUDGET_REACHED APRÈS avoir fini son travail."""

    def test_one_step_project_reaches_done_within_its_default_cap(self):
        plan = {"goal": "Petit livrable", "language": "fr", "assumptions": [{"id": "A1", "text": "x"}],
                "criteria": [{"id": "C1", "text": "Le fichier existe", "kind": "auto", "check": {"type": "file_exists", "path": "notes/S1.md", "minBytes": 5}}],
                "steps": [{"id": "S1", "title": "Ecrire", "worker": "lucas", "goal": "Ecrire la note", "criteriaIds": ["C1"], "expectedOutputs": ["notes/S1.md"], "estimateCredits": 4}],
                "estimate": {"creditsMin": 4, "creditsMax": 12, "hoursMin": 0.1, "hoursMax": 0.2}}
        scenario = {"plan": {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": plan}}], "complete": {"status": "DONE", "summary": "Plan prêt."}}}
        e = Env(scenario=scenario, chf=0.15)                      # 4 crédits par étape (planification, travail, vérification, rapport)
        self.addCleanup(e.close)
        pid = e.create(goal="Ecrire une petite note pour le client", worker="lucas")
        st = e.drive(pid, lambda s: s["status"] in ("DONE", "BUDGET_REACHED", "FAILED"), timeout=90)
        self.assertEqual(st["status"], "DONE", (st["status"], st.get("statusReason"), st["budget"]))
        self.assertGreaterEqual(st["budget"]["creditsCap"], 15 + 14)


class QuotaViewTests(unittest.TestCase):
    """La progression met la vue d'usage en cache 5 s. Au moment où le projet passe en WAITING_QUOTA, le client doit voir la fenêtre PLEINE, pas la vue d'avant la dernière étape."""

    def test_progress_shows_the_full_window_at_the_moment_of_the_pause(self):
        from engine_harness import FakeUsage, CLIENT
        usage = FakeUsage(session=14, week=500, month=900)
        e = Env(usage=usage, chf=0.15)
        self.addCleanup(e.close)
        pid = e.create(credits_cap=60)
        e.drive(pid, lambda s: (e.svc.usage_cached(CLIENT), s["status"] == "WAITING_QUOTA")[1], timeout=60)
        shown = e.svc.progress(CLIENT, pid)["usage"]["allowedNow"]
        self.assertEqual(shown, usage.remaining(CLIENT).allowedNow)
        self.assertLess(shown, 6)


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
