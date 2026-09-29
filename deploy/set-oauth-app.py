"""Enregistre l'application OAuth d'un fournisseur ("Se connecter avec Slack",
HubSpot, Dropbox...) dans .env, sans jamais afficher le secret.

Usage (sur le serveur, dans le dossier du projet) :
    python3 deploy/set-oauth-app.py slack
    python3 deploy/set-oauth-app.py hubspot
    ...
Fournisseurs : voir core/integrations/oauth-vendors.json
Puis : docker compose up -d   (recree le conteneur avec le nouvel .env)

Chez le fournisseur, l'URL de redirection a declarer est affichee a la fin :
    https://bk-ai-workers.com/oauth/<fournisseur>/callback
"""
import getpass
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV = os.path.join(ROOT, ".env")
VENDORS = json.load(open(os.path.join(ROOT, "core", "integrations", "oauth-vendors.json"), encoding="utf-8"))
VENDORS = {k: v for k, v in VENDORS.items() if not k.startswith("_")}

if len(sys.argv) != 2 or sys.argv[1] not in VENDORS:
    sys.exit("Usage : python3 deploy/set-oauth-app.py <" + "|".join(VENDORS) + ">")
vendor = sys.argv[1]
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


client_id = input(f"Client ID de l'application {VENDORS[vendor]['label']} : ").strip()
secret = getpass.getpass("Client Secret (rien ne s'affiche) : ").strip()
if len(client_id) < 6 or len(secret) < 8 or " " in client_id or " " in secret:
    sys.exit("Une valeur semble invalide. Rien n'a ete enregistre.")
key = vendor.upper()
set_var(f"OAUTH_{key}_CLIENT_ID", client_id)
set_var(f"OAUTH_{key}_CLIENT_SECRET", secret)
print(f"\nEnregistre. URL de redirection a declarer chez {VENDORS[vendor]['label']} :")
print(f"  https://bk-ai-workers.com/oauth/{vendor}/callback")
print("Puis lance : docker compose up -d")
