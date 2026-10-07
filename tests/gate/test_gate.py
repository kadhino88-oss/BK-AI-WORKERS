"""Porte "Acces administrateur" : script de (re)definition du mot de passe + limite d'essais.

Unitaire (Windows ou Linux) : python tests/gate/test_gate.py
Bout en bout sur le VRAI serveur (Linux / WSL, rsync + pwsh) : BK_GATE_E2E=1 python3 tests/gate/test_gate.py
"""
import base64
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
spec = importlib.util.spec_from_file_location("set_gate_password", os.path.join(REPO, "deploy", "set-gate-password.py"))
sgp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sgp)


class ScriptTests(unittest.TestCase):
    def test_hash_format_is_what_server_reads(self):
        line = sgp.make_hash("Un-Mot-De-Passe-42", iterations=1000, salt=bytes(range(16)))
        salt_hex, hash_hex, iterations = line.split(":")
        self.assertEqual((len(salt_hex), len(hash_hex), iterations), (32, 64, "1000"))

    def test_env_line_replaced_others_kept(self):
        d = tempfile.mkdtemp()
        try:
            env = os.path.join(d, ".env")
            with open(env, "w", encoding="utf-8") as f:
                f.write("A=1\nBK_GATE_HASH=old:old:1\nOAUTH_X_CLIENT_SECRET=s$cr$t\n")
            sgp.set_env_var(env, "BK_GATE_HASH", "aa:bb:3")
            text = open(env, encoding="utf-8").read()
            self.assertEqual(text, "A=1\nBK_GATE_HASH=aa:bb:3\nOAUTH_X_CLIENT_SECRET=s$cr$t\n")
            os.remove(env)
            with open(env, "w", encoding="utf-8") as f:
                f.write("A=1")
            sgp.set_env_var(env, "BK_GATE_HASH", "cc:dd:3")
            self.assertEqual(open(env, encoding="utf-8").read(), "A=1\nBK_GATE_HASH=cc:dd:3\n")
        finally:
            shutil.rmtree(d, ignore_errors=True)


def _post(port, path, body):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read().decode() or "{}"), r.headers.get("Set-Cookie") or ""
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}"), ""


@unittest.skipUnless(os.environ.get("BK_GATE_E2E") == "1", "bout en bout : BK_GATE_E2E=1 sous Linux/WSL")
class RealServerGate(unittest.TestCase):
    PASSWORD = "Bon-Mot-De-Passe-" + os.urandom(3).hex()

    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp(prefix="bkgate-")
        subprocess.run(["rsync", "-a", "--exclude=/.git", "--exclude=/runtime", "--exclude=/_archive", "--exclude=/memory/runtime",
                        "--exclude=/core/accounts/data", "--exclude=/core/connectors/client-credentials", "--exclude=/.claude",
                        REPO + "/", cls.root + "/"], check=True)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            cls.port = s.getsockname()[1]
        env = dict(os.environ, BK_ROOT=cls.root, BK_LISTEN_HOST="127.0.0.1", BK_PORT=str(cls.port),
                   BK_GATE_HASH=sgp.make_hash(cls.PASSWORD),
                   BK_SECRET_CRED_ENCRYPTION_KEY=base64.b64encode(os.urandom(32)).decode())
        env.pop("BK_REQUIRE_GATE", None)
        cls.server = subprocess.Popen([sys.executable, "-u", "dashboard/server.py"], cwd=cls.root, env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(80):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{cls.port}/api/gate/status", timeout=1)
                break
            except OSError:
                time.sleep(0.5)

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        try:
            cls.server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            cls.server.kill()
        shutil.rmtree(cls.root, ignore_errors=True)

    def test_sequence(self):
        # 1. Le hash produit par le script est accepte par le vrai serveur.
        st, body, cookie = _post(self.port, "/api/gate/login", {"password": self.PASSWORD})
        self.assertEqual((st, body.get("ok")), (200, True))
        self.assertIn("bk_session=", cookie)
        # 2. 8 mauvais essais : refuses un par un.
        for i in range(8):
            st, body, _ = _post(self.port, "/api/gate/login", {"password": f"faux-{i}"})
            self.assertEqual((st, body.get("error")), (401, "INVALID_PASSWORD"), i)
        # 3. Le 9e est bloque, et meme le bon mot de passe attend la fin de la fenetre.
        st, body, _ = _post(self.port, "/api/gate/login", {"password": "faux-9"})
        self.assertEqual((st, body.get("error")), (429, "TOO_MANY_ATTEMPTS"))
        st, body, _ = _post(self.port, "/api/gate/login", {"password": self.PASSWORD})
        self.assertEqual((st, body.get("error")), (429, "TOO_MANY_ATTEMPTS"))
        # 4. La connexion client d'un autre compte n'est pas bloquee par la porte admin.
        st, body, _ = _post(self.port, "/api/account/login", {"email": "x@example.com", "password": "y"})
        self.assertEqual((st, body.get("error")), (401, "INVALID_CREDENTIALS"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
