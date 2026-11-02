# -*- coding: utf-8 -*-
"""Lance les tests de l'interface des projets (Node requis). python tests/projects-ui/run_all.py
Les fixtures reelles (fixtures/real-*.json) viennent de capture_fixtures.py sur un serveur de tests/projects-ui/live_server.py (a refaire quand l'API change)."""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
node = shutil.which("node")
if not node:
    print("Node absent : tests de l'interface des projets ignores")
    sys.exit(0)
bad = 0
for t in ("test_pure_logic.js", "test_i18n.js", "test_static_guards.js", "test_contract.js"):
    r = subprocess.run([node, os.path.join(HERE, t)], capture_output=True, text=True, encoding="utf-8")
    print(t, "->", (r.stdout.strip().splitlines() or ["(aucune sortie)"])[-1])
    if r.returncode:
        bad += 1
        print(r.stderr[-1500:])
sys.exit(1 if bad else 0)
