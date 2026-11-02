# -*- coding: utf-8 -*-
"""Passerelle unittest : test_usage_core.py et test_usage_wiring.py sont des scripts (verifications `check`, code de sortie != 0 au moindre echec).
tests/run-python-suites.sh ne connait que unittest : sans cette passerelle la suite « usage » ne lancait AUCUN test et sortait en echec ("NO TESTS RAN").

    python -m unittest discover -s tests/usage -p 'test_*.py'
"""
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
# test_usage_wiring.py remplace subprocess.run a son import (decouverte unittest dans le meme processus) : on garde Popen, que personne ne remplace.
_POPEN = subprocess.Popen


class UsageScripts(unittest.TestCase):
    def run_script(self, name):
        proc = _POPEN([sys.executable, os.path.join(HERE, name)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=HERE)
        out, err = proc.communicate(timeout=600)
        out, err = out.decode("utf-8", "replace"), err.decode("utf-8", "replace")
        tail = "\n".join(out.splitlines()[-25:]) + "\n" + err[-1500:]
        self.assertEqual(proc.returncode, 0, name + " :\n" + tail)

    def test_usage_core(self):
        self.run_script("test_usage_core.py")

    def test_usage_wiring(self):
        self.run_script("test_usage_wiring.py")


if __name__ == "__main__":
    unittest.main(verbosity=2)
