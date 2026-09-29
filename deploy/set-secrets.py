"""Renseigne .env sans jamais afficher ni journaliser les secrets.
Usage (sur le serveur, dans le dossier du projet) : python3 deploy/set-secrets.py
Demande : mot de passe d'acces au dashboard (hache PBKDF2), cle Anthropic (optionnelle : Entree pour ignorer).
"""
import getpass
import hashlib
import os
import re
import sys

ENV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
if not os.path.isfile(ENV):
    sys.exit(".env introuvable : lance d'abord  cp .env.example .env")


def set_var(name, value):
    text = open(ENV, encoding="utf-8").read()
    line = f"{name}={value}"
    if re.search(rf"^{name}=.*$", text, flags=re.M):
        text = re.sub(rf"^{name}=.*$", lambda m: line, text, flags=re.M)
    else:
        text += ("" if text.endswith("\n") else "\n") + line + "\n"
    with open(ENV, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(ENV, 0o600)


pw = getpass.getpass("Mot de passe d'acces au dashboard (rien ne s'affiche) : ")
if len(pw) < 10 or getpass.getpass("Confirme : ") != pw:
    sys.exit("Mot de passe trop court (10 caracteres minimum) ou differents. Rien n'a ete enregistre.")
salt = os.urandom(16)
h = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), salt, 200000, dklen=32)
set_var("BK_GATE_HASH", f"{salt.hex()}:{h.hex()}:200000")
print("Mot de passe d'acces enregistre (hash uniquement).")

key = getpass.getpass("Cle API Anthropic sk-ant-... (Entree pour ignorer) : ").strip()
if key:
    if not key.startswith("sk-ant-"):
        sys.exit("Cette valeur ne ressemble pas a une cle Anthropic (sk-ant-...). Cle non enregistree.")
    set_var("BK_SECRET_ANTHROPIC", key)
    print("Cle Anthropic enregistree.")
else:
    print("Cle Anthropic ignoree : les Workers repondront en mode secours local.")
