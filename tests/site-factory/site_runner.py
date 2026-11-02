# -*- coding: utf-8 -*-
"""Faux lanceur d'étape AVEC les outils de l'atelier : enregistre site_* (comme le fait dashboard/project-tool.py pour le vrai lanceur) puis
exécute tests/projects/fake_runner.py. Aucun modèle, aucun réseau.

    python site_runner.py <input.json> <result.json>"""
import os
import runpy
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import site_tools  # noqa: E402,F401  (registre des outils site_*)

sys.argv = [os.path.join(REPO, "tests", "projects", "fake_runner.py")] + sys.argv[1:3]
runpy.run_path(sys.argv[0], run_name="__main__")
