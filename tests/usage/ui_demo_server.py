# -*- coding: utf-8 -*-
"""Serveur JETABLE pour regarder l'interface des limites d'usage dans un navigateur (a la main, pas une suite de tests).

Meme mise en place que tests/usage/e2e_server.py : COPIE du depot, port libre, BK_USAGE_WINDOWS=1, faux Submit-Task.ps1 (aucun modele, aucun reseau, aucun
secret). Il cree deux comptes locaux, amene la session du premier a ~87 % (alerte des 80 %) et attend. Ecrit l'adresse et les comptes de TEST dans le
fichier donne (JSON), puis tourne jusqu'a la fin du delai (defaut 40 minutes) ou jusqu'a Ctrl+C.

    python tests/usage/ui_demo_server.py <fichier-info.json> [minutes]

Identifiants : valeurs de test generees pour CE serveur local, jamais celles d'un vrai service.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_server as e2e  # noqa: E402


def main():
    info_path = sys.argv[1]
    minutes = float(sys.argv[2]) if len(sys.argv) > 2 else 40
    root = tempfile.mkdtemp(prefix="bkusage-demo-")
    server = None
    try:
        app = os.path.join(root, "app")
        shutil.copytree(e2e.REPO, app, ignore=e2e.ignore)
        with open(os.path.join(app, "dashboard", "Submit-Task.ps1"), "w", encoding="utf-8-sig") as f:
            f.write(e2e.STUB)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k not in ("BK_REQUIRE_GATE", "BK_SMTP_HOST", "BK_SECRETS_DIR", "BK_LEVELS")}
        env.update(BK_ROOT=app, BK_PORT=str(port), BK_LISTEN_HOST="127.0.0.1", BK_PUBLIC_URL=f"http://127.0.0.1:{port}", BK_STATUS_DISABLE="1",
                   BK_GATE_HASH=e2e.gate_hash(e2e.GATE_PASSWORD), BK_USAGE_WINDOWS=os.environ.get("BK_USAGE_WINDOWS", "1"))
        if e2e.PWSH:
            env["BK_PWSH"] = e2e.PWSH
        server = subprocess.Popen([sys.executable, "-u", os.path.join(app, "dashboard", "server.py")], cwd=app, env=env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        anon = e2e.Client(port, "198.51.100.90")
        end = time.time() + 60
        while time.time() < end:
            try:
                if anon.call("GET", "/api/health")[0] == 200:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        else:
            raise SystemExit("serveur non demarre")
        alice, a_id = e2e.signup(port, "alice@mail-test.example", "198.51.100.11")
        bob, b_id = e2e.signup(port, "bob@mail-test.example", "198.51.100.12")
        owner = e2e.Client(port, "198.51.100.99")
        assert owner.post("/api/gate/login", {"password": e2e.GATE_PASSWORD})[0] == 200
        assert owner.post("/api/admin/set-plan", {"clientId": a_id, "planId": "equipe"})[0] == 200
        assert owner.post("/api/admin/set-plan", {"clientId": b_id, "planId": "pro"})[0] == 200
        # alice (Equipe : 83 par session) : 6 x 12 = 72 -> 87 % (alerte des 80 %)
        for level in ("approfondi",) * 6:
            st, out = alice.post("/api/workers/alex/task", {"objective": "Prepare un plan", "level": level})
            assert st == 200, (st, out)
        with open(info_path, "w", encoding="utf-8") as f:
            json.dump({"url": f"http://127.0.0.1:{port}", "alice": {"email": "alice@mail-test.example", "password": e2e.PASSWORD, "plan": "equipe"},
                       "bob": {"email": "bob@mail-test.example", "password": e2e.PASSWORD, "plan": "pro"}, "root": root, "pid": server.pid}, f)
        print("pret", port, flush=True)
        deadline = time.time() + minutes * 60
        while time.time() < deadline and server.poll() is None and not os.path.exists(info_path + ".stop"):
            time.sleep(2)
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except Exception:
                server.kill()
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
