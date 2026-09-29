# DECISION ENGINE

## Objectif

Transformer une demande en décision d'orchestration.

## Pipeline

1. RECEIVE
2. IDENTIFY_CONTEXT
3. CLASSIFY_INTENT
4. CHECK_SCOPE
5. CHECK_PERMISSION
6. SELECT_WORKER
7. BUILD_TASK
8. EXECUTE_OR_DELEGATE
9. VALIDATE_RESULT
10. FINALIZE

## Priorités

CRITICAL
HIGH
NORMAL
LOW

## Règles

Si la demande concerne directement :
- design → LEA
- administration → NOAH
- prospection → ALEX
- marketing/growth → MAYA
- site/SEO → LUCAS
- contenu/social → EMMA
- IT/cybersécurité → SAM
- trading/analyse marché → ATLAS

## Collaboration

Si plusieurs compétences sont nécessaires,
l'Orchestrateur crée plusieurs tâches liées.

Exemple :

Refonte d'un site :

LUCAS → structure/SEO
LEA → design/UI
EMMA → contenu
MAYA → stratégie marketing
SAM → sécurité/infrastructure

## Finance

Toute action financière réelle est bloquée pour validation Kader.

L'analyse financière est autorisée.

## Ambiguïté

Si client, projet, objectif ou autorisation sont insuffisamment identifiés :
STATUS = NEEDS_HUMAN
