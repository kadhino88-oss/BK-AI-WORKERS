# -*- coding: utf-8 -*-
"""Lance toute la suite « confiance » : tests unitaires, garde-fou des mots de certification, puis (sauf --fast)
le test de bout en bout avec un vrai serveur sur une copie jetable et un port libre.

Usage : python tests/trust/run_all.py [--fast]
Code de sortie 0 seulement si TOUT passe. Aucun acces Internet requis, jamais les vraies donnees."""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STEPS = [
    ("tests unitaires (pages, preuves, traductions)", [sys.executable, "-m", "unittest", "-q", "test_trust_pages", "test_trust_extras", "test_status_monitor"]),
    ("mots de certification non adosses a un document", [sys.executable, os.path.join(HERE, "check_certification_claims.py")]),
]
if "--fast" not in sys.argv:
    STEPS.append(("bout en bout : vrai serveur, copie jetable, port libre", [sys.executable, os.path.join(HERE, "e2e_server.py")]))

failed = []
for name, cmd in STEPS:
    print(f"\n=== {name} ===", flush=True)
    code = subprocess.call(cmd, cwd=HERE)
    print(f"--- {'OK' if code == 0 else 'ECHEC (code ' + str(code) + ')'} : {name}", flush=True)
    if code != 0:
        failed.append(name)
print("\nRESULTAT :", "TOUT PASSE" if not failed else "ECHEC -> " + " ; ".join(failed))
sys.exit(1 if failed else 0)
