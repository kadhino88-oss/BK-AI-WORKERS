# -*- coding: utf-8 -*-
"""Serveur JETABLE pour verifier l'interface d'installation a la main (navigateur) : le VRAI dashboard/server.py demarre sur une COPIE
du depot (port libre sur 127.0.0.1, jamais les vraies donnees, aucun secret copie, aucun transport de mail ni modele), avec une porte
proprietaire dont le mot de passe est genere ici.

    python tests/hire-ui/dev_server.py --secrets-file <chemin hors du depot>

Le fichier JSON ecrit contient {"url", "gatePassword", "root"} : le mot de passe n'est JAMAIS affiche. Le script tourne jusqu'a ce qu'on
l'arrete (Ctrl+C / kill) puis supprime la copie. Les comptes de test se creent dans le navigateur (POST /api/account/signup depuis la page)
et l'offre Solo/Trio s'attribue ensuite avec l'API proprietaire (POST /api/admin/grant-workers) : voir tests/hire-ui/owner_call.py.
"""
import argparse
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SKIP_TOP = {".git", ".claude", ".secrets", "_archive", "runtime", "node_modules", "__pycache__", "tests", "docs"}


def ignore(directory, names):
    rel = os.path.relpath(directory, REPO).replace("\\", "/")
    skip = {n for n in names if n == "__pycache__" or (rel == "." and n in SKIP_TOP)}
    if rel == "memory":
        skip.add("runtime")
    if rel == "core/accounts":
        skip.add("data")
    if rel in ("core/billing", "core/automation", "core/profile", "core/leads", "core/hire"):
        skip.add("data")
        skip.add("runs")
    if rel == "core/connectors":
        skip.add("client-credentials")
    if rel == "dashboard":
        skip.add(".gate")
    return skip


def gate_hash(password):
    salt = os.urandom(16)
    return f"{salt.hex()}:{hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 1000, dklen=32).hex()}:1000"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--secrets-file", required=True, help="fichier JSON a ecrire (hors du depot) : url + mot de passe de la porte proprietaire")
    args = ap.parse_args()
    root = tempfile.mkdtemp(prefix="bkhireui-")
    server = None
    try:
        app = os.path.join(root, "app")
        shutil.copytree(REPO, app, ignore=ignore)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        gate_password = "gate-" + os.urandom(8).hex()
        env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k not in ("BK_REQUIRE_GATE", "BK_SMTP_HOST", "BK_SECRETS_DIR")}
        env.update(BK_ROOT=app, BK_PORT=str(port), BK_LISTEN_HOST="127.0.0.1", BK_PUBLIC_URL=f"http://127.0.0.1:{port}", BK_STATUS_DISABLE="1",
                   BK_GATE_HASH=gate_hash(gate_password), BK_PILOT_NOTIFY_EMAIL="owner@mail-test.example")
        server = subprocess.Popen([sys.executable, "-u", os.path.join(app, "dashboard", "server.py")], cwd=app, env=env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        url = f"http://127.0.0.1:{port}"
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        end = time.time() + 60
        while time.time() < end:
            try:
                if opener.open(url + "/api/health", timeout=3).status == 200:
                    break
            except Exception:
                time.sleep(0.5)
        else:
            raise SystemExit("serveur non demarre")
        with open(args.secrets_file, "w", encoding="utf-8") as f:
            json.dump({"url": url, "gatePassword": gate_password, "root": app}, f)
        print("PRET " + url, flush=True)
        while server.poll() is None:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except Exception:
                server.kill()
        shutil.rmtree(root, ignore_errors=True)
        try:
            os.remove(args.secrets_file)
        except OSError:
            pass


if __name__ == "__main__":
    main()
