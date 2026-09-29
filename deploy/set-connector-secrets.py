"""Renseigne .env avec les cles des connecteurs, sans jamais les afficher ni les journaliser.
A LANCER SUR LE VPS (SSH), jamais colle dans le chat.

Usage (sur le serveur, dans le dossier du projet) :
  python3 deploy/set-connector-secrets.py                  -> parcourt tous les connecteurs
  python3 deploy/set-connector-secrets.py --provider slack -> un seul

Les valeurs a coller sont les memes que celles deja stockees localement sur Windows
(.secrets/<provider>.secret.dpapi) : relis-les d'abord avec
  .secrets\\Show-Credential.ps1 -Provider slack
dans un terminal PowerShell sur ta machine (jamais via Claude), puis colle-les ici.
"""
import argparse
import getpass
import os
import re
import sys

ENV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
if not os.path.isfile(ENV):
    sys.exit(".env introuvable : lance d'abord  cp .env.example .env")

# Meme liste que .secrets/Store-Credential.ps1 (hors did/elevenlabs/openai/stripe/anthropic,
# deja geres par Connect-*.ps1 / set-secrets.py).
PROVIDERS = [
    "slack",
    "trello", "asana", "monday", "zendesk", "intercom", "figma",
    "hubspot", "pipedrive", "webflow", "shopify", "woocommerce",
    "wordpress", "dropbox",
    "linkedin", "facebook", "instagram", "tiktok", "x_twitter",
    "meta_ads", "whatsapp_business",
    "gmail", "google_calendar", "google_drive", "google_search_console",
    "google_ads", "outlook_mail", "outlook_calendar", "teams",
    "onedrive", "salesforce",
]

JSON_FORMAT_HINTS = {
    "zendesk": '{"subdomain":"tonentreprise","user":"toi@exemple.com","pass":"API_TOKEN"}',
    "shopify": '{"shop":"tonentreprise","token":"shpat_..."}',
    "woocommerce": '{"site":"tonsite.com","consumer_key":"ck_...","consumer_secret":"cs_..."}',
    "wordpress": '{"site":"tonsite.com","user":"toi","pass":"APPLICATION_PASSWORD"}',
    "trello": '{"key":"TA_CLE","token":"TON_TOKEN"}',
    "gmail": '{"client_id":"...","client_secret":"...","refresh_token":"..."}',
    "google_calendar": '{"client_id":"...","client_secret":"...","refresh_token":"..."}',
    "google_drive": '{"client_id":"...","client_secret":"...","refresh_token":"..."}',
    "google_search_console": '{"client_id":"...","client_secret":"...","refresh_token":"..."}',
    "google_ads": '{"client_id":"...","client_secret":"...","refresh_token":"...","developer_token":"..."}',
    "outlook_mail": '{"client_id":"...","client_secret":"...","refresh_token":"...","tenant":"..."}',
    "outlook_calendar": '{"client_id":"...","client_secret":"...","refresh_token":"...","tenant":"..."}',
    "teams": '{"client_id":"...","client_secret":"...","refresh_token":"...","tenant":"..."}',
    "onedrive": '{"client_id":"...","client_secret":"...","refresh_token":"...","tenant":"..."}',
    "salesforce": '{"client_id":"...","client_secret":"...","refresh_token":"..."}',
}


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


def set_one(provider):
    env_name = "BK_SECRET_" + provider.upper()
    hint = JSON_FORMAT_HINTS.get(provider)
    if hint:
        print(f"\nFormat attendu pour {provider} :\n  {hint}")
    value = getpass.getpass(f"Valeur pour {provider} (Entree pour passer, rien ne s'affiche) : ").strip()
    if not value:
        print(f"{provider} : ignore.")
        return False
    set_var(env_name, value)
    print(f"{provider} : enregistre ({env_name}).")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", help="Un seul connecteur (ex: slack). Sinon, parcourt toute la liste.")
    args = parser.parse_args()

    if args.provider:
        if args.provider not in PROVIDERS:
            sys.exit(f"Connecteur inconnu : {args.provider}. Voir la liste dans ce script.")
        set_one(args.provider)
        print("\nRedemarre le conteneur pour appliquer :  docker compose up -d")
        return

    print(f"{len(PROVIDERS)} connecteurs a parcourir. Entree pour passer un connecteur sans cle.\n")
    done = 0
    for provider in PROVIDERS:
        if set_one(provider):
            done += 1
    print(f"\n{done} connecteur(s) enregistre(s) dans .env.")
    if done:
        print("Redemarre le conteneur pour appliquer :  docker compose up -d")


if __name__ == "__main__":
    main()
