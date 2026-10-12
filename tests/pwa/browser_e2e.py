"""Verification dans un VRAI Chrome / Edge (headless) : installabilite selon Chrome, service worker,
invitation a installer (ordinateur / Android / iPhone), page hors connexion avec le serveur coupe puis relance.

Demarre le vrai serveur sur une copie jetable (port libre), puis pilote tests/pwa/browser_e2e.js, qui demande par
des lignes "@@WAIT stop-server" / "@@WAIT start-server" de couper et relancer ce serveur.
Necessite node >= 22 et Chrome ou Edge (BK_CHROME pour indiquer le chemin) ; sinon : SKIP, code de sortie 0.
Captures d'ecran : BK_SHOTS_DIR=<dossier> python tests/pwa/browser_e2e.py

    python tests/pwa/browser_e2e.py"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from testserver import TestServer  # noqa: E402


def main():
    node = shutil.which("node")
    if not node:
        print("SKIP : node introuvable")
        return 0
    srv = TestServer()
    code = 1
    try:
        srv.start()
        print(f"serveur de test sur {srv.base} (copie jetable)")
        env = dict(os.environ, BK_TEST_BASE_URL=srv.base)
        proc = subprocess.Popen([node, os.path.join(HERE, "browser_e2e.js")], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", bufsize=1)
        for line in proc.stdout:
            line = line.rstrip("\n")
            if line.startswith("@@WAIT "):
                what = line[7:].strip()
                print(f"      [serveur] {what}")
                if what == "stop-server":
                    srv.stop()
                elif what == "start-server":
                    srv.start()
                proc.stdin.write("go\n")
                proc.stdin.flush()
            else:
                print(line)
        code = proc.wait()
    finally:
        srv.cleanup()
    return code


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main())
