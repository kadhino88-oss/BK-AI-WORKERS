# Standard téléphonique IA (Twilio Voice)

Une assistante virtuelle décroche les appels de BK Entreprise / BK-AI-WORKERS, renseigne l'appelant
et prend un message complet ; Kader reçoit un email à chaque message. Aucune intervention humaine.

## Comment ça marche
1. Twilio reçoit l'appel et poste sur `https://bk-ai-workers.com/webhooks/twilio/voice` (au décroché, puis après chaque phrase transcrite par Twilio).
2. `dashboard/phone_agent.py` : vérifie la signature Twilio, appelle Claude Haiku **une fois par tour, sans aucun outil**, et renvoie du TwiML (voix `Google.fr-FR-Neural2-F`). ~1,5 s par tour.
3. Si un message est capturé : email à `notifyEmail` + transcription dans `memory/runtime/phone-calls/<date>/<CallSid>.json` (supprimée après 90 jours).

## Règle de sécurité (à ne jamais relâcher)
L'appelant est un inconnu. L'agent n'a accès à **aucun** Worker, connecteur, historique de missions ou donnée du propriétaire — seulement la fiche publique `dashboard/phone-agent/<ClientId>.md`.
Protections : signature Twilio obligatoire (HMAC-SHA1, comparaison en temps constant) ; seuls les clients ayant un `dashboard/phone-agent/<ClientId>.json` sont joignables ; plafonds : 6 appels/heure/numéro, 14 tours/appel, 1500 tours/jour, 40 emails/jour, 6 appels modèle en parallèle ; l'agent se déclare « assistante virtuelle » ; l'Auth Token Twilio n'est déchiffré que par PowerShell (`Twilio-Auth-Token.ps1`) puis gardé en mémoire 1 h.

## Modifier le comportement
- Accueil, voix, email de notification : `dashboard/phone-agent/CLI-DASHBOARD.json`.
- Ce que l'agent sait (services, tarifs publics, adresse) : `dashboard/phone-agent/CLI-DASHBOARD.md`. Il n'invente rien hors de cette fiche.
- Autre entreprise : ajouter `<ClientId>.json` + `<ClientId>.md` dans le même dossier, et `core/connectors/data/phone-routing.json` : `{"+41...": "<ClientId>"}` (numéro Twilio appelé → client). Ce client doit avoir son propre compte Twilio connecté.

## Mise en service (côté Twilio / opérateur)
1. Passer le compte Twilio en payant (le mode *Trial* ajoute un message aux appelants et limite les numéros).
2. Acheter un numéro vocal ; en Suisse, Twilio demande une adresse vérifiée.
3. Console Twilio → Phone Numbers → le numéro → *Voice Configuration* → **A call comes in : Webhook, `https://bk-ai-workers.com/webhooks/twilio/voice`, HTTP POST**.
4. Dans le connecteur Twilio de BK-AI-WORKERS, mettre ce numéro comme « from » (appels sortants).
5. Renvoi d'appel depuis le mobile (le numéro public +41 79 934 99 46 reste le même) : renvoi si pas de réponse `**61*<numéro Twilio>**20#` ; occupé `**67*<numéro Twilio>#` ; injoignable `**62*<numéro Twilio>#` ; annuler tout : `##002#`.

## Tests
```
python tests/phone-agent/test_phone_agent.py          # 36 tests dont 4 avec le vrai modèle (seulement si BK_SECRET_ANTHROPIC est défini)
python3 tests/phone-agent/test_auth_token_ps.py       # Linux/WSL avec pwsh 7 : déchiffrement du jeton, bout en bout via sous-processus
python3 tests/phone-agent/e2e_server.py               # Linux/WSL : vrai serveur + requêtes HTTP signées comme Twilio
```
