"""Calcule le hash du mot de passe d'acces (PBKDF2-SHA256) a coller dans .env (BK_GATE_HASH).
Le mot de passe n'est jamais affiche ni enregistre."""
import getpass
import hashlib
import os

pw = getpass.getpass("Mot de passe d'acces au dashboard : ")
if getpass.getpass("Confirme : ") != pw or not pw:
    raise SystemExit("Mots de passe differents ou vides.")
iterations = 200000
salt = os.urandom(16)
h = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), salt, iterations, dklen=32)
print(f"BK_GATE_HASH={salt.hex()}:{h.hex()}:{iterations}")
