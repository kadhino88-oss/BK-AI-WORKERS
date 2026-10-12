"""Demarre le VRAI serveur (dashboard/server.py) sur une COPIE jetable du depot, sur un port libre
choisi par le systeme. Rien du depot ni des vraies donnees n'est touche. Utilise par
e2e_server.py et browser_e2e.py."""
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_SKIP = {".git", ".claude", "__pycache__", "runtime", "_archive", "node_modules", "client-credentials", ".gate"}


class TestServer:
    def __init__(self, repo=REPO):
        self.repo = repo
        self.root = tempfile.mkdtemp(prefix="bkpwa-srv-")
        self.copy = os.path.join(self.root, "app")
        shutil.copytree(repo, self.copy, ignore=lambda d, names: [n for n in names if n in _SKIP])
        for sub in (("memory", "runtime"), ("core", "accounts", "data")):
            shutil.rmtree(os.path.join(self.copy, *sub), ignore_errors=True)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        self.proc = None
        self._log = None

    @property
    def base(self):
        return f"http://127.0.0.1:{self.port}"

    def start(self):
        env = dict(os.environ, BK_ROOT=self.copy, BK_PORT=str(self.port), BK_LISTEN_HOST="127.0.0.1", PYTHONIOENCODING="utf-8")
        for k in ("BK_REQUIRE_GATE", "BK_GATE_HASH"):
            env.pop(k, None)
        log_path = os.path.join(self.root, "server.log")
        self._log = open(log_path, "a", encoding="utf-8")
        self.proc = subprocess.Popen([sys.executable, os.path.join(self.copy, "dashboard", "server.py")], env=env,
                                     stdout=self._log, stderr=subprocess.STDOUT, cwd=self.copy)
        for _ in range(150):
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.5):
                    return self
            except OSError:
                if self.proc.poll() is not None:
                    self._log.flush()
                    with open(log_path, encoding="utf-8", errors="replace") as f:
                        raise RuntimeError("le serveur s'est arrete :\n" + f.read())
                time.sleep(0.2)
        raise RuntimeError("le serveur ne repond pas")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)
        self.proc = None
        if self._log:
            self._log.close()
            self._log = None

    def cleanup(self):
        self.stop()
        shutil.rmtree(self.root, ignore_errors=True)
