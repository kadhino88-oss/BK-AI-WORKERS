"""Ajoute les 4 Price ID Stripe annuels (starter/business/pro/scale) au JSON
BK_SECRET_STRIPE deja enregistre, SANS toucher a la cle secrete existante.
Cree d'abord les 4 prix annuels dans Stripe (meme Produit que le mensuel,
recurrence "annuelle", montants 390/990/1390/4490 CHF), puis lance :
    python3 deploy/set-stripe-annual-prices.py
Les Price ID ne sont pas des secrets (juste des identifiants d'offre) :
ils s'affichent normalement pendant la saisie, contrairement au mot de
passe ou a la cle API.
"""
import json
import os
import re
import sys

ENV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
if not os.path.isfile(ENV):
    sys.exit(".env introuvable : lance d'abord  cp .env.example .env")

text = open(ENV, encoding="utf-8").read()
m = re.search(r"^BK_SECRET_STRIPE=(.*)$", text, flags=re.M)
if not m or not m.group(1).strip():
    sys.exit("BK_SECRET_STRIPE n'est pas encore renseigne : lance d'abord deploy/set-stripe-secret.py")

raw = m.group(1).strip()
if raw[:1] in ("'", '"') and raw[-1:] == raw[:1]:
    raw = raw[1:-1]

try:
    parsed = json.loads(raw)
except json.JSONDecodeError as e:
    sys.exit("BK_SECRET_STRIPE actuel n'est pas un JSON valide (" + str(e) + "). Corrige-le avant de continuer.")

print("Colle chaque Price ID annuel Stripe (visible a l'ecran, ce n'est pas un secret).")
annual = {}
for plan, chf in (("starter", 390), ("business", 990), ("pro", 1390), ("scale", 4490)):
    val = input(f"  {plan} ({chf} CHF/an) - price_... : ").strip()
    if not val:
        sys.exit(f"Valeur vide pour '{plan}', rien n'a ete enregistre.")
    if not val.startswith("price_"):
        sys.exit(f"'{val}' ne ressemble pas a un Price ID Stripe (price_...). Rien n'a ete enregistre.")
    annual[plan] = val

parsed["pricesAnnual"] = annual
compact = json.dumps(parsed, separators=(",", ":"))
line = "BK_SECRET_STRIPE='" + compact + "'"
text = re.sub(r"^BK_SECRET_STRIPE=.*$", lambda m: line, text, flags=re.M)
with open(ENV, "w", encoding="utf-8") as f:
    f.write(text)
os.chmod(ENV, 0o600)

print("4 prix annuels enregistres. Relance : docker compose up -d app")
