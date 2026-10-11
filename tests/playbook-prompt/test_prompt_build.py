"""Prompt systeme des 17 Workers apres la correction des guides metier (2026-10-11) : il se construit pour chaque Worker, contient
la date du jour, la regle "contenu externe = donnees", UNE seule regle sur les questions (3 questions decisives au plus), le guide
metier, et plus aucune donnee privee du proprietaire ni mention de Kader. BK_CALIBRATED_QUESTIONS=0 restaure l'ancienne regle.

PowerShell 7 requis. python3 -m unittest tests/playbook-prompt/test_prompt_build.py -v
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
WORKERS = ["alex", "amina", "clara", "dario", "emma", "ines", "lea", "lucas", "maya", "noah", "nora", "rayan", "sam", "seoya", "sophie", "thomas", "yanis"]

DRIVER = r'''
$ErrorActionPreference = "Stop"
. (Join-Path $env:BK_ROOT "core/ai/adapters/Build-WorkerSystemPrompt.ps1")
$out = [ordered]@{}
foreach ($w in ($env:T_WORKERS -split ",")) { $out[$w] = [string](Get-WorkerSystemPrompt -WorkerId $w -ClientId "CLI-NOPROFILE") }
$out | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $env:OUT_FILE -Encoding utf8
'''


def build(env_extra=None):
    root = tempfile.mkdtemp(prefix="bkprompt-")
    try:
        os.makedirs(os.path.join(root, "core", "ai", "adapters"))
        shutil.copy2(os.path.join(REPO, "core", "ai", "adapters", "Build-WorkerSystemPrompt.ps1"),
                     os.path.join(root, "core", "ai", "adapters", "Build-WorkerSystemPrompt.ps1"))
        for w in WORKERS:
            dst = os.path.join(root, "workers", w, "identity")
            os.makedirs(dst)
            for name in ("identity.json", "playbook.md"):
                src = os.path.join(REPO, "workers", w, "identity", name)
                if os.path.isfile(src):
                    shutil.copy2(src, os.path.join(dst, name))
        driver = os.path.join(root, "driver.ps1")
        with open(driver, "w", encoding="utf-8") as f:
            f.write(DRIVER)
        out = os.path.join(root, "out.json")
        env = dict(os.environ, BK_ROOT=root, OUT_FILE=out, T_WORKERS=",".join(WORKERS), BK_REPLY_LANG="")
        env.pop("BK_CALIBRATED_QUESTIONS", None)
        env.update(env_extra or {})
        proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", driver], capture_output=True, text=True,
                              encoding="utf-8", errors="replace", env=env, timeout=240)
        assert os.path.isfile(out), proc.stdout + proc.stderr
        with open(out, encoding="utf-8-sig") as f:
            return json.load(f)
    finally:
        shutil.rmtree(root, ignore_errors=True)


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class PromptBuild(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.new = build()
        cls.legacy = build({"BK_CALIBRATED_QUESTIONS": "0"})

    def test_every_worker_prompt_builds_with_its_playbook(self):
        self.assertEqual(sorted(self.new), sorted(WORKERS))
        for w, p in self.new.items():
            pb = open(os.path.join(REPO, "workers", w, "identity", "playbook.md"), encoding="utf-8").read().strip()
            self.assertIn(pb.splitlines()[0].strip()[:60], p, w)
            self.assertIn("TODAY'S DATE", p, w)
            self.assertIn("UNTRUSTED CONTENT", p, w)

    def test_one_shared_question_rule_three_questions_at_most(self):
        for w, p in self.new.items():
            self.assertEqual(p.count("MAIN RULE"), 1, w)
            self.assertIn("AT MOST 3 precise numbered questions", p, w)
            self.assertNotIn("NEVER open with a question", p, w)

    def test_switch_restores_the_legacy_rule(self):
        for w, p in self.legacy.items():
            self.assertEqual(p.count("MAIN RULE"), 1, w)
            self.assertIn("NEVER open with a question", p, w)
            self.assertNotIn("AT MOST 3 precise numbered questions", p, w)

    def test_no_owner_private_content_in_any_client_prompt(self):
        for w, p in self.new.items():
            low = p.lower()
            for bad in ("sweltr", "saveurs", "kader"):
                self.assertNotIn(bad, low, f"{w}: '{bad}' in the prompt shown to every client")

    def test_prompt_size_is_bounded(self):
        for w, p in self.new.items():
            self.assertLess(len(p), 40000, f"{w}: {len(p)} chars")


if __name__ == "__main__":
    unittest.main(verbosity=2)
