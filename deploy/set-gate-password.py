"""Definit (ou redefinit) le mot de passe "Acces administrateur" du site, sans jamais l'afficher.

Usage (sur le serveur, dans le dossier du projet) :
    python3 deploy/set-gate-password.py
Puis : docker compose up -d   (recree le conteneur avec le nouvel .env)

Ecrit BK_GATE_HASH dans .env au format lu par dashboard/server.py
(sel hex : empreinte PBKDF2-SHA256 hex : iterations). Le mot de passe lui-meme
n'est ni affiche, ni enregistre, ni transmis.
"""
import getpass
import hashlib
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV = os.path.join(ROOT, ".env")
ITERATIONS = 200000
MIN_LENGTH = 10


def make_hash(password, iterations=ITERATIONS, salt=None):
    salt = salt if salt is not None else os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations, dklen=32)
    return f"{salt.hex()}:{digest.hex()}:{iterations}"


def set_env_var(env_path, name, value):
    text = open(env_path, encoding="utf-8").read() if os.path.isfile(env_path) else ""
    line = f"{name}={value}"
    if re.search(rf"^{name}=.*$", text, flags=re.M):
        text = re.sub(rf"^{name}=.*$", lambda m: line, text, flags=re.M)
    else:
        text += ("" if text.endswith("\n") or not text else "\n") + line + "\n"
    tmp = env_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, env_path)


def looks_like_inside_container(root):
    """Heuristique legere : sommes-nous probablement DANS le conteneur ?"""
    return bool(os.environ.get("BK_ROOT")) or root.startswith("/data/app") or root.startswith("/opt/bk")


def apply_new_password(root):
    """Recree le conteneur pour que le nouveau .env soit relu. Le mot de passe n'est jamais passe a docker."""
    has_compose = any(os.path.isfile(os.path.join(root, n)) for n in ("docker-compose.yml", "compose.yaml"))
    docker = shutil.which("docker")
    if not (has_compose and docker):
        print("Sur l'HOTE, dans le dossier du projet, lance pour appliquer le nouveau mot de passe :")
        print("    docker compose up -d --force-recreate")
        return
    print("Application du nouveau mot de passe (redémarrage du conteneur)…")
    try:
        done = subprocess.run([docker, "compose", "up", "-d", "--force-recreate"], cwd=root)
        if done.returncode != 0:
            raise RuntimeError(f"docker compose a quitte avec le code {done.returncode}")
    except Exception:
        print("Le redémarrage automatique a échoué. Dans le dossier du projet, lance manuellement :")
        print("    docker compose up -d --force-recreate")
        return
    print("✅ Mot de passe appliqué. Tu peux te connecter au dashboard avec ton nouveau mot de passe.")


def main():
    if not os.path.isfile(ENV):
        sys.exit(".env introuvable : lance d'abord  cp .env.example .env")
    pw = getpass.getpass("Nouveau mot de passe administrateur (rien ne s'affiche) : ")
    if getpass.getpass("Confirme-le : ") != pw:
        sys.exit("Les deux saisies sont differentes. Rien n'a ete modifie.")
    if len(pw) < MIN_LENGTH:
        sys.exit(f"Trop court : au moins {MIN_LENGTH} caracteres. Rien n'a ete modifie.")
    if pw != pw.strip():
        sys.exit("Le mot de passe commence ou finit par un espace. Rien n'a ete modifie.")
    set_env_var(ENV, "BK_GATE_HASH", make_hash(pw))
    print("\nEnregistre.")
    if looks_like_inside_container(ROOT):
        print("Attention : ce .env n'est peut-être pas celui que Docker lit sur l'hôte.")
        print("Relance plutôt ce script sur l'HOTE, dans le dossier du projet.")
    apply_new_password(ROOT)
    print("Puis sur le site : bas de page > \"Acces administrateur\" > ton nouveau mot de passe.")


if __name__ == "__main__":
    main()
