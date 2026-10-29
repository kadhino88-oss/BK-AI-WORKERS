"""Enregistre dans .env le jeton d'un moteur d'IA (hote suisse, ou Ollama derriere un https) SANS jamais l'afficher ni le journaliser.
Usage (sur le serveur, dans le dossier du projet) :

    python3 deploy/set-engine-secret.py swiss       # BK_SECRET_SWISS  : jeton Bearer de l'hebergeur suisse
    python3 deploy/set-engine-secret.py ollama      # BK_SECRET_OLLAMA : seulement si Ollama est derriere un https qui exige un jeton

Le jeton est demande sans echo, ecrit dans .env (droits 600). Puis : docker compose up -d. Pas de jeton pour un Ollama en http sur le reseau prive (Tailscale).
Ne sert PAS pour la cle d'un client (elle est saisie par le client dans l'application, chiffree, jamais relue) ni pour la cle Anthropic (deploy/set-secrets.py).
"""
import getpass
import os
import re
import sys

ENV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
ENGINES = {"swiss": "BK_SECRET_SWISS", "ollama": "BK_SECRET_OLLAMA"}


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
    if len(argv) != 2 or argv[1] not in ENGINES:
        sys.exit("Usage : python3 deploy/set-engine-secret.py swiss|ollama")
    if not os.path.isfile(ENV):
        sys.exit(".env introuvable : lance d'abord  cp .env.example .env")
    name = ENGINES[argv[1]]
    token = getpass.getpass(f"Jeton pour {name} (rien ne s'affiche) : ").strip()
    if len(token) < 16 or re.search(r"\s", token):
        sys.exit("Jeton trop court (16 caracteres minimum) ou avec des espaces. Rien n'a ete enregistre.")
    if getpass.getpass("Confirme : ").strip() != token:
        sys.exit("Les deux saisies different. Rien n'a ete enregistre.")
    set_var(name, token)
    print(f"{name} enregistre dans .env (droits 600). Relancez : docker compose up -d")


if __name__ == "__main__":
    main(sys.argv)
