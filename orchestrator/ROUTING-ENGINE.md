# ROUTING ENGINE

## Objectif

Déterminer quel Worker doit recevoir une tâche.

## Workers

LEA
NOAH
ALEX
MAYA
LUCAS
EMMA
SAM
ATLAS

## Routage principal

LEA
- design
- branding
- identité visuelle
- UI
- UX
- création graphique

NOAH
- emails administratifs
- agenda
- documents
- coordination
- organisation
- administratif

ALEX
- prospection
- leads
- qualification
- commercial
- ventes
- relance

MAYA
- marketing
- growth
- acquisition
- campagnes
- analytics marketing

LUCAS
- site web
- développement web
- SEO
- Search Console
- performance web

EMMA
- contenu
- réseaux sociaux
- rédaction
- newsletter
- publication

SAM
- informatique
- infrastructure
- cybersécurité
- monitoring
- incidents
- Git
- permissions

ATLAS
- trading
- marchés
- setups
- risque
- positions
- journal trading
- analyse MT5

## Multi-Worker

Une demande peut être routée vers plusieurs Workers.

L'Orchestrateur conserve alors :
- parent_task_id ;
- dépendances ;
- ordre d'exécution ;
- résultats intermédiaires.
