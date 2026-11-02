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


class UsageScripts(unittest.TestCase):
    def run_script(self, name):
        p = subprocess.run([sys.executable, os.path.join(HERE, name)], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600, cwd=HERE)
        tail = "\n".join((p.stdout or "").splitlines()[-25:]) + "\n" + (p.stderr or "")[-1500:]
        self.assertEqual(p.returncode, 0, name + " :\n" + tail)

    def test_usage_core(self):
        self.run_script("test_usage_core.py")

    def test_usage_wiring(self):
        self.run_script("test_usage_wiring.py")


if __name__ == "__main__":
    unittest.main(verbosity=2)
