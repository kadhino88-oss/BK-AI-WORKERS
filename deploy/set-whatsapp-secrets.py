"""Renseigne les variables WhatsApp dans .env sans jamais afficher les secrets.
Usage (sur le serveur, dans le dossier du projet) : python3 deploy/set-whatsapp-secrets.py
Puis : docker compose up -d   (recree le conteneur avec le nouvel .env)

Demande :
  - jeton d'acces permanent (Meta > WhatsApp > API Setup / utilisateur systeme)   [saisie masquee]
  - secret de l'application Meta (App settings > Basic > App secret)              [saisie masquee]
  - Phone number ID (visible dans WhatsApp > API Setup, pas un secret)
  - numero WhatsApp affiche, chiffres seuls avec indicatif pays (ex. 41791234567)
Genere aussi le "verify token" a recopier dans la configuration du webhook chez Meta.
"""
import getpass
import os
import re
import secrets
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


token = getpass.getpass("Jeton d'acces WhatsApp (rien ne s'affiche) : ").strip()
secret = getpass.getpass("Secret de l'application Meta (rien ne s'affiche) : ").strip()
phone_id = input("Phone number ID (chiffres) : ").strip()
number = re.sub(r"\D", "", input("Numero WhatsApp (indicatif pays inclus, ex. 41791234567) : "))

if len(token) < 20 or len(secret) < 16 or not phone_id.isdigit() or len(number) < 8:
    sys.exit("Une valeur semble invalide. Rien n'a ete enregistre.")

verify = secrets.token_urlsafe(24)
set_var("WHATSAPP_ACCESS_TOKEN", token)
set_var("WHATSAPP_APP_SECRET", secret)
set_var("WHATSAPP_PHONE_NUMBER_ID", phone_id)
set_var("WHATSAPP_DISPLAY_NUMBER", number)
set_var("WHATSAPP_VERIFY_TOKEN", verify)
print("\nEnregistre dans .env.")
print("A recopier chez Meta (Configuration du webhook) :")
print("  URL de rappel : https://bk-ai-workers.com/webhooks/whatsapp")
print("  Verify token  :", verify)
print("Puis lance : docker compose up -d")
