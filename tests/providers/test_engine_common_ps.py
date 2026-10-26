# -*- coding: utf-8 -*-
"""Engine-Common.ps1 (PowerShell 7) : memes vecteurs d'adresses que Python, appel d'outil ecrit en texte (strict), fichiers texte (plafonds, noms),
disjoncteur et registre de depense, classes d'erreur.

    python3 -m unittest tests/providers/test_engine_common_ps.py -v      (pwsh requis ; sous Windows : via WSL)
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class EngineCommon(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        d = tempfile.mkdtemp(prefix="bkec-")
        cls.addClassCleanup(shutil.rmtree, d, True)
        out = os.path.join(d, "out.json")
        proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", os.path.join(HERE, "vectors-driver.ps1"), "-Repo", REPO, "-OutFile", out],
                              capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300)
        assert os.path.isfile(out), f"driver produced nothing\n{proc.stdout}\n{proc.stderr}"
        with open(out, encoding="utf-8-sig") as f:
            cls.r = json.load(f)

    def test_address_classes_match_python(self):
        self.assertEqual(self.r["ipMismatches"], [])

    def test_endpoint_policy_matches_python(self):
        self.assertEqual(self.r["endpointMismatches"], [])

    def test_text_tool_call_parser_is_strict(self):
        t = self.r["tool"]
        self.assertEqual(t["plain"], "final")
        self.assertEqual(t["json_call"], "call")
        self.assertEqual(t["fenced_call"], "call")
        self.assertEqual(t["text_around"], "final", "du texte autour du JSON n'est jamais un appel d'outil")
        self.assertEqual(t["unknown_tool"], "malformed")
        self.assertEqual(t["extra_key"], "malformed", "une cle en trop (ex. approve) ne passe pas")
        self.assertEqual(t["broken_json"], "malformed")
        self.assertEqual(t["args_not_object"], "malformed")
        self.assertEqual(t["json_without_tool"], "final", "un JSON sans cle tool est un contenu, pas un appel")
        self.assertEqual(t["case_sensitive"], "malformed")
        self.assertEqual(t["call_name"], "write_text_file")

    def test_text_files_only_and_capped(self):
        f = self.r["files"]
        self.assertTrue(f["ok_txt"].startswith("Fichier enregistre"))
        self.assertTrue(f["ok_csv"].startswith("Fichier enregistre"))
        for key in ("refuse_xlsx", "refuse_exe", "refuse_ps1", "refuse_dotfile", "refuse_nul", "refuse_empty", "refuse_badtask"):
            self.assertTrue(f[key].startswith("REFUSE"), (key, f[key]))
        self.assertIn("Excel, Word, PowerPoint et PDF ne sont pas produits", f["refuse_xlsx"])
        self.assertTrue(f["refuse_traversal"].startswith("REFUSE"), "../../etc/passwd : le nom est reduit a « passwd », sans extension texte")
        self.assertEqual(f["traversal_leaf"], 0)
        self.assertFalse(f["escaped_root"], "aucun fichier hors du dossier de la mission")
        self.assertEqual(f["count"], 10, "10 fichiers au plus")
        self.assertEqual(sorted(f["names"]), sorted(f["on_disk"]))
        self.assertTrue(any(n.endswith("notes.txt") and n != "notes.txt" for n in f["names"]), "un nom deja pris est prefixe, jamais ecrase")
        self.assertTrue(f["bulk11"].startswith("REFUSE : trop de fichiers"))

    def test_circuit_breaker_and_spend_ledger(self):
        h = self.r["health"]
        self.assertTrue(h["fresh_ok"])
        self.assertFalse(h["after_mark"])
        self.assertTrue(h["other_ok"], "un moteur n'en met pas un autre de cote")
        self.assertTrue(h["expired_ok"], "le disjoncteur se referme tout seul")
        self.assertTrue(h["cleared_ok"])
        self.assertAlmostEqual(h["spend_day_chf"], 0.35, places=4)
        self.assertAlmostEqual(h["spend_month_chf"], 0.35, places=4)
        self.assertEqual(h["spend_missions"], 2)

    def test_actions_a_small_model_claims_without_any_tool_are_flagged(self):
        c = self.r["claims"]
        for key in ("sent_fr", "sent_fr_passive", "sent_en", "file_fr", "file_fr2", "file_fr_text_subject", "file_fr_named", "web_fr"):
            self.assertTrue(c[key], key)
        for key in ("plain_text_is_fine", "file_negated_is_fine", "prepared_is_fine", "sent_but_really_executed", "file_but_really_saved", "web_but_really_read", "empty"):
            self.assertTrue(c[key], key)
        self.assertIn("n'a PAS envoyé, publié, payé ou supprimé quoi que ce soit, ni enregistré un fichier", c["note_text"])
        self.assertIn("aucun outil ne l'a fait", c["note_text"])

    def test_error_classes(self):
        c = self.r["health"]["classes"]
        self.assertEqual((c["c402"], c["credit"]), ("billing", "billing"))
        self.assertEqual((c["a401"], c["a403"], c["key"], c["nocred"]), ("auth", "auth", "auth", "auth"))
        self.assertEqual(c["r429"], "rate_limit")
        self.assertEqual((c["refused"], c["dns"]), ("connection", "connection"))
        self.assertEqual(c["to"], "timeout")
        self.assertEqual((c["s500"], c["b400"]), ("server", "bad_request"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
