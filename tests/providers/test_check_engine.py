# -*- coding: utf-8 -*-
"""deploy/check-engine.py (outil du proprietaire, lance sur le serveur) contre un faux serveur OpenAI-compatible : liste des modeles, modele present, delai,
refus des adresses interdites, jeton jamais affiche.

    python tests/providers/test_check_engine.py       (Windows ou Linux ; aucun PowerShell)
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fake_openai  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SCRIPT = os.path.join(REPO, "deploy", "check-engine.py")


class CheckEngine(unittest.TestCase):
    def run_script(self, *args, env=None):
        root = tempfile.mkdtemp(prefix="bkchk-")
        self.addCleanup(shutil.rmtree, root, True)                  # une racine jetable par appel : rien ne reste dans le dossier temporaire
        full = dict(os.environ, BK_ROOT=root)
        for k in ("BK_SECRET_OLLAMA", "BK_SECRET_SWISS", "BK_OLLAMA_URL", "BK_SWISS_URL", "BK_SECRETS_DIR"):
            full.pop(k, None)
        full.update(env or {})
        proc = subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True, encoding="utf-8", errors="replace", env=full, timeout=120)
        return proc.returncode, proc.stdout + proc.stderr

    def serve(self, **kw):
        srv = fake_openai.FakeOpenAI(**kw)
        self.addCleanup(srv.stop)
        return srv

    def test_reports_models_latency_and_a_real_answer(self):
        srv = self.serve(models=["llama3:latest", "qwen2.5:1.5b"], script=[{"content": "ok"}])
        code, out = self.run_script("--url", srv.url, "--model", "llama3:latest", "--chat")
        self.assertEqual(code, 0, out)
        self.assertIn("2 modele(s)", out)
        self.assertIn("llama3:latest", out)
        self.assertIn("present", out)
        self.assertIn("reponse reelle", out)
        self.assertIn("le moteur est pret", out)
        self.assertEqual(len(srv.chat_requests()), 1, "une seule petite requete reelle, et seulement avec --chat")

    def test_without_chat_no_inference_request_is_sent(self):
        srv = self.serve(models=["llama3:latest"])
        code, out = self.run_script("--url", srv.url, "--model", "llama3:latest")
        self.assertEqual(code, 0, out)
        self.assertEqual(srv.chat_requests(), [])

    def test_missing_model_is_a_failure_with_the_command_to_fix_it(self):
        srv = self.serve(models=["qwen2.5:1.5b"])
        code, out = self.run_script("--url", srv.url, "--model", "llama3:latest")
        self.assertEqual(code, 1, out)
        self.assertIn("ABSENT", out)
        self.assertIn("ollama pull llama3:latest", out)

    def test_token_is_sent_but_never_printed(self):
        token = "tok-SECRET-0123456789abcdef"
        srv = self.serve(models=["m"], token=token)
        code, out = self.run_script("--url", srv.url, "--model", "m", env={"BK_SECRET_OLLAMA": token})
        self.assertEqual(code, 0, out)
        self.assertIn("Jeton : present", out)
        self.assertNotIn(token, out)
        self.assertTrue(all(g["_auth"] for g in srv.gets))

    def test_wrong_token_is_reported_without_echoing_it(self):
        srv = self.serve(models=["m"], token="tok-GOOD-0123456789")
        code, out = self.run_script("--url", srv.url, "--model", "m", env={"BK_SECRET_OLLAMA": "tok-BAD-0123456789"})
        self.assertEqual(code, 1, out)
        self.assertIn("jeton refuse", out)
        self.assertNotIn("tok-BAD", out)

    def test_forbidden_addresses_are_refused_before_any_connection(self):
        for url in ("http://8.8.8.8:11434", "http://169.254.169.254/v1", "http://user:pw@127.0.0.1:11434", "file:///etc/passwd"):
            code, out = self.run_script("--url", url)
            self.assertEqual(code, 1, url + "\n" + out)
            self.assertIn("ECHEC", out)
            self.assertNotIn("joignable en", out)

    def test_https_without_a_token_is_refused(self):
        code, out = self.run_script("--engine", "swiss", "--url", "https://8.8.8.8/v1")
        self.assertEqual(code, 1, out)
        self.assertIn("TOKEN_REQUIRED", out)

    def test_the_local_engine_on_a_public_address_is_refused_even_with_a_token(self):
        code, out = self.run_script("--url", "https://8.8.8.8/v1", env={"BK_SECRET_OLLAMA": "tok-0123456789abcdef"})
        self.assertEqual(code, 1, out)
        self.assertIn("NOT_PRIVATE", out)
        self.assertNotIn("joignable en", out)

    def test_dead_engine_gives_an_actionable_message(self):
        srv = self.serve()
        url = srv.url
        srv.stop()
        code, out = self.run_script("--url", url, "--model", "m")
        self.assertEqual(code, 1, out)
        self.assertIn("injoignable", out)
        self.assertIn("Tailscale", out)

    def test_no_url_configured(self):
        code, out = self.run_script()
        self.assertEqual(code, 1, out)
        self.assertIn("aucune adresse configuree", out)

    def test_url_read_from_the_owner_environment(self):
        srv = self.serve(models=["llama3:latest"])
        code, out = self.run_script("--model", "llama3:latest", env={"BK_OLLAMA_URL": srv.url})
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
