"""Cartes des Workers (core/projects/WORKER-CARDS.json), generees par chloe/Build-WorkerCards.ps1 et lues par le routeur et le planificateur de Chloe.

PowerShell 7 requis.   wsl -e python3 tests/chloe-delegation/test_cards.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import PWSH, REPO  # noqa: E402

ROSTER = ["alex", "amina", "clara", "dario", "emma", "ines", "lea", "lucas", "maya", "noah", "nora", "rayan", "sam", "seoya", "sophie", "thomas", "yanis"]
CARDS = os.path.join(REPO, "core", "projects", "WORKER-CARDS.json")


def load():
    with open(CARDS, encoding="utf-8-sig") as f:
        doc = json.load(f)
    return doc, {c["id"]: c for c in doc["cards"]}


class Cards(unittest.TestCase):
    @unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
    def test_the_committed_file_is_exactly_what_the_generator_produces_from_the_sources(self):
        p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", os.path.join(REPO, "chloe", "Build-WorkerCards.ps1"), "-Root", REPO, "-Check"],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=240)
        self.assertEqual(p.returncode, 0, "WORKER-CARDS.json n'est plus a jour : relancer chloe/Build-WorkerCards.ps1\n" + p.stdout + p.stderr)

    @unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
    def test_the_generator_is_deterministic(self):
        tmp = tempfile.mkdtemp(prefix="bkcards-")
        self.addCleanup(shutil.rmtree, tmp, True)
        out = os.path.join(tmp, "cards.json")
        p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", os.path.join(REPO, "chloe", "Build-WorkerCards.ps1"), "-Root", REPO, "-OutFile", out],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=240)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        with open(out, encoding="utf-8") as f, open(CARDS, encoding="utf-8-sig") as g:
            self.assertEqual(f.read().replace("\r\n", "\n"), g.read().replace("\r\n", "\n"))

    def test_there_is_one_card_per_worker_and_atlas_is_never_in_it(self):
        doc, cards = load()
        self.assertEqual(doc["schema"], "BK-WORKER-CARDS-V1")
        self.assertEqual(sorted(cards), ROSTER)
        self.assertNotIn("atlas", json.dumps(doc).lower())
        self.assertNotIn("chloe", cards)

    def test_every_card_says_what_the_worker_does_and_how_to_find_it(self):
        _, cards = load()
        for wid, c in cards.items():
            self.assertTrue(c["name"] and c["role"], wid)
            self.assertGreaterEqual(len(c["can"]), 2, f"{wid} : au moins deux capacites decrites")
            self.assertGreaterEqual(len(c["keywords"]), 3, wid)
            self.assertEqual(len(c["typicalStepCredits"]), 2, wid)
            self.assertLessEqual(c["typicalStepCredits"][0], c["typicalStepCredits"][1], wid)
            self.assertLess(len(json.dumps(c, ensure_ascii=False)), 2200, f"{wid} : une carte reste courte (la liste des 17 entre dans un seul prompt)")

    def test_the_tie_breaks_of_the_playbook_become_not_for_lists(self):
        _, cards = load()
        pairs = [("lucas", "seoya"), ("seoya", "lucas"), ("alex", "maya"), ("maya", "alex"), ("sophie", "clara"), ("clara", "sophie"),
                 ("dario", "nora"), ("nora", "dario"), ("lea", "emma"), ("emma", "lea")]
        for a, b in pairs:
            self.assertTrue(any(f"({b})" in x for x in cards[a]["notFor"]), f"{a} : ce qui releve de {b} n'est pas pour lui ({cards[a]['notFor']})")

    def test_the_whole_team_description_fits_a_planning_prompt(self):
        doc, _ = load()
        self.assertLess(len(json.dumps(doc, ensure_ascii=False)), 36000, "les 17 cartes (~9 000 jetons) restent petites devant un appel de planification")


if __name__ == "__main__":
    unittest.main(verbosity=2)
