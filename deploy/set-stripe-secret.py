"""Renseigne BK_SECRET_STRIPE dans .env en une seule lecture (pas de copier-coller
de commande shell, pas de heredoc — evite le probleme de ligne coupee en deux
au milieu du JSON). Usage (sur le serveur, dans le dossier du projet) :
    python3 deploy/set-stripe-secret.py
Colle le JSON Stripe (une seule ligne, format :
{"secret_key":"sk_live_...","publishable_key":"pk_live_...","prices":{"starter":"price_...","business":"price_...","pro":"price_...","scale":"price_..."}}
) puis Entree. Rien n'est affiche a l'ecran pendant la saisie.
"""
import getpass
import json
import os
import re
import sys

ENV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
if not os.path.isfile(ENV):
    sys.exit(".env introuvable : lance d'abord  cp .env.example .env")

raw = getpass.getpass("Colle le JSON Stripe (une seule ligne, rien ne s'affiche), puis Entree : ").strip()

if not raw:
    sys.exit("Valeur vide, rien n'a ete enregistre.")

try:
    parsed = json.loads(raw)
except json.JSONDecodeError as e:
    sys.exit(
        "JSON invalide (" + str(e) + "). "
        "Le collage a probablement ete coupe en plusieurs morceaux : "
        "verifie que tu colles bien tout en une seule fois, sans appuyer sur Entree au milieu, "
        "et relance le script."
    )

required = {"secret_key", "publishable_key", "prices"}
missing = required - set(parsed.keys())
if missing:
    sys.exit(f"Champs manquants dans le JSON : {', '.join(sorted(missing))}. Rien n'a ete enregistre.")

missing_prices = {"starter", "business", "pro", "scale"} - set((parsed.get("prices") or {}).keys())
if missing_prices:
    sys.exit(f"Prix manquants : {', '.join(sorted(missing_prices))}. Rien n'a ete enregistre.")

if not str(parsed["secret_key"]).startswith("sk_"):
    sys.exit("secret_key ne ressemble pas a une cle Stripe (sk_...). Rien n'a ete enregistre.")

live = str(parsed["secret_key"]).startswith("sk_live_")

# Reecrit sur une seule ligne compacte, JSON valide, puis entoure de guillemets
# simples : docker compose (env_file) sait lire une valeur entre guillemets
# meme si elle contient des accolades/deux-points, sinon il la rejette.
compact = json.dumps(parsed, separators=(",", ":"))
line = "BK_SECRET_STRIPE='" + compact + "'"

text = open(ENV, encoding="utf-8").read()
if re.search(r"^BK_SECRET_STRIPE=.*$", text, flags=re.M):
    text = re.sub(r"^BK_SECRET_STRIPE=.*$", lambda m: line, text, flags=re.M)
else:
    text += ("" if text.endswith("\n") else "\n") + line + "\n"
with open(ENV, "w", encoding="utf-8") as f:
    f.write(text)
os.chmod(ENV, 0o600)

print(f"Cle Stripe enregistree ({'LIVE' if live else 'test'}), 4 prix presents. Relance : docker compose up -d app")
