"""Teste dashboard/Twilio-Auth-Token.ps1 (dechiffrement du jeton) sous PowerShell 7, et le
chemin reel PhoneAgent -> sous-processus pwsh -> jeton -> signature. Environnement temporaire
(BK_ROOT jetable, cle de chiffrement aleatoire) : aucune vraie donnee n'est lue ni modifiee.
Lancer sous Linux / WSL (pwsh installe) : python3 tests/phone-agent/test_auth_token_ps.py"""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import urlencode

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import phone_agent as pa  # noqa: E402

PWSH = os.environ.get("BK_PWSH") or "pwsh"
TOKEN = "ps_roundtrip_token_" + os.urandom(5).hex()


class AuthTokenScript(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp(prefix="bkauth-")
        for rel in ("core/runtime/State-Lock.ps1", "core/connectors/Client-Credential-Store.ps1",
                    "core/connectors/Crypto-Helper.ps1", "dashboard/Twilio-Auth-Token.ps1"):
            dst = os.path.join(cls.root, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy(os.path.join(REPO, rel), dst)
        shutil.copytree(os.path.join(REPO, "dashboard", "phone-agent"), os.path.join(cls.root, "dashboard", "phone-agent"))
        cls.env = dict(os.environ, BK_ROOT=cls.root, BK_SECRET_CRED_ENCRYPTION_KEY=base64.b64encode(os.urandom(32)).decode())
        os.environ["BK_ROOT"] = cls.root
        os.environ["BK_SECRET_CRED_ENCRYPTION_KEY"] = cls.env["BK_SECRET_CRED_ENCRYPTION_KEY"]
        cred = json.dumps({"user": "AC" + "0" * 32, "pass": TOKEN, "from": "+15005550006"})
        script = (f". '{cls.root}/core/connectors/Client-Credential-Store.ps1'; "
                  "Set-BKClientCredentialValue -ClientId 'CLI-DASHBOARD' -Provider 'twilio' -PlainText $env:BK_TEST_CRED")
        subprocess.run([PWSH, "-NoProfile", "-Command", script], check=True, capture_output=True, env=dict(cls.env, BK_TEST_CRED=cred))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root, ignore_errors=True)

    def run_script(self, client_id):
        return subprocess.run([PWSH, "-NoProfile", "-File", os.path.join(self.root, "dashboard", "Twilio-Auth-Token.ps1"),
                               "-ClientId", client_id], capture_output=True, env=self.env, timeout=60)

    def test_returns_the_decrypted_token_on_stdout_only(self):
        p = self.run_script("CLI-DASHBOARD")
        self.assertEqual((p.returncode, p.stdout.decode()), (0, TOKEN))
        self.assertEqual(p.stderr, b"")

    def test_unknown_client_exits_3_with_empty_stdout(self):
        p = self.run_script("CLI-NOBODY")
        self.assertEqual((p.returncode, p.stdout), (3, b""))

    def test_client_id_traversal_is_sanitised(self):
        p = self.run_script("../../CLI-DASHBOARD")        # nettoye en "CLI-DASHBOARD" : jamais un chemin hors du coffre
        self.assertIn(p.returncode, (0, 3))
        p = self.run_script(r"..\..\etc\passwd")
        self.assertEqual(p.stdout, b"")

    def test_no_token_file_left_in_temp(self):
        before = set(os.listdir(tempfile.gettempdir()))
        self.run_script("CLI-DASHBOARD")
        leaked = [f for f in set(os.listdir(tempfile.gettempdir())) - before if TOKEN in (open(os.path.join(tempfile.gettempdir(), f), errors="ignore").read() if os.path.isfile(os.path.join(tempfile.gettempdir(), f)) else "")]
        self.assertEqual(leaked, [])

    def test_phone_agent_real_subprocess_verifies_a_signature_end_to_end(self):
        agent = pa.PhoneAgent(self.root, [PWSH, "-NoProfile"], model_call=lambda s, m: None)
        p = {"CallSid": "CA" + "b" * 32, "From": "+41791112233", "To": "+41225550100"}
        raw = urlencode(p).encode()
        status, body = agent.handle(raw, pa.twilio_signature(TOKEN, pa.DEFAULT_WEBHOOK_URL, p), [pa.DEFAULT_WEBHOOK_URL])
        self.assertEqual(status, 200)
        self.assertIn("BK Entreprise", body)                # accueil de la vraie config
        status, body = agent.handle(raw, pa.twilio_signature("mauvais-jeton-mauvais", pa.DEFAULT_WEBHOOK_URL, p), [pa.DEFAULT_WEBHOOK_URL])
        self.assertEqual(status, 403)


if __name__ == "__main__":
    unittest.main(verbosity=2)
