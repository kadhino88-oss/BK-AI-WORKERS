"""Enregistre dans .env le jeton d'un moteur d'IA ou du point de recherche web SANS jamais l'afficher ni le journaliser.
Usage (sur le serveur, dans le dossier du projet) :

    python3 deploy/set-engine-secret.py swiss       # BK_SECRET_SWISS  : jeton Bearer de l'hebergeur suisse
    python3 deploy/set-engine-secret.py ollama      # BK_SECRET_OLLAMA : seulement si Ollama est derriere un https qui exige un jeton
    python3 deploy/set-engine-secret.py search      # BK_SECRET_SEARCH : jeton Bearer du point de recherche web en https
    python3 deploy/set-engine-secret.py searxng     # genere SEARXNG_SECRET sans afficher sa valeur

Le jeton est demande sans echo, ecrit dans .env (droits 600). Puis : docker compose up -d (ou les deux fichiers Compose si SearXNG est actif). Pas de jeton pour un service en http sur le reseau prive.
Ne sert PAS pour la cle d'un client (elle est saisie par le client dans l'application, chiffree, jamais relue) ni pour la cle Anthropic (deploy/set-secrets.py).
"""
import getpass
import os
import re
import secrets
import sys

ENV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
ENGINES = {"swiss": "BK_SECRET_SWISS", "ollama": "BK_SECRET_OLLAMA", "search": "BK_SECRET_SEARCH"}


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


def main(argv):
    if len(argv) != 2 or (argv[1] not in ENGINES and argv[1] != "searxng"):
        sys.exit("Usage : python3 deploy/set-engine-secret.py swiss|ollama|search|searxng")
    if not os.path.isfile(ENV):
        sys.exit(".env introuvable : lance d'abord  cp .env.example .env")
    if argv[1] == "searxng":
        text = open(ENV, encoding="utf-8").read()
        current = re.search(r"^SEARXNG_SECRET=(.*)$", text, flags=re.M)
        if current and current.group(1).strip():
            sys.exit("SEARXNG_SECRET est deja defini dans .env ; rien n'a ete modifie.")
        set_var("SEARXNG_SECRET", secrets.token_hex(32))
        print("SEARXNG_SECRET genere et enregistre dans .env (droits 600), sans afficher sa valeur.")
        return
    name = ENGINES[argv[1]]
    token = getpass.getpass(f"Jeton pour {name} (rien ne s'affiche) : ").strip()
    if len(token) < 16 or re.search(r"\s", token):
        sys.exit("Jeton trop court (16 caracteres minimum) ou avec des espaces. Rien n'a ete enregistre.")
    if getpass.getpass("Confirme : ").strip() != token:
        sys.exit("Les deux saisies different. Rien n'a ete enregistre.")
    set_var(name, token)
    print(f"{name} enregistre dans .env (droits 600). Redemarrez avec votre commande Compose habituelle ; si SearXNG est actif, incluez les deux fichiers Compose.")


if __name__ == "__main__":
    main(sys.argv)
