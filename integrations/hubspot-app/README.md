# Appli HubSpot BK-AI-WORKERS (plateforme développeur HubSpot 2026.09)

Projet HubSpot qui déclare l'application OAuth « Se connecter avec HubSpot » utilisée par les clients.
Les permissions (`requiredScopes`) doivent rester identiques à `core/integrations/oauth-vendors.json` (fournisseur `hubspot`).

Déployer une modification : `hs project upload` depuis ce dossier (compte HubSpot BK Entreprise, authentifié par `hs account auth`).
L'identifiant client et le secret se lisent dans HubSpot (Développement > Projets > bk-ai-workers > Authentification),
puis se posent sur le serveur avec `python3 deploy/set-oauth-app.py hubspot` (jamais dans le dépôt).
