# BK AI WORKERS
# PROVIDER CREDENTIAL CONTRACT
# PHASE 7F-1

## OBJECTIF

Définir une frontière stricte entre la configuration des fournisseurs IA
et les credentials secrets.

## REGLES

1. Aucun secret dans les Workers.
2. Aucun secret dans AI-GATEWAY.ps1.
3. Aucun secret dans AI-PROVIDER-ENGINE.ps1.
4. Aucun secret dans la mémoire métier.
5. Aucun secret dans les fichiers de logs.
6. Aucun secret dans les résultats Worker.
7. Aucun secret dans Git.
8. Les credentials doivent être fournis uniquement par un mécanisme sécurisé.
9. Les Workers ne connaissent jamais les credentials.
10. Le Provider Engine ne peut pas augmenter les permissions.
11. Les opérations financières restent exclusivement sous autorité KADER.

## FOURNISSEURS

- ANTHROPIC
- OPENAI

## ETAT PHASE 7F-1

Configuration préparée.
Credentials non activés.
Appels API externes désactivés.

## FINANCIAL BOUNDARY

financial_actions = false
external_actions = false

Toute opération financière réelle doit produire :

STATUS = NEEDS_HUMAN
AUTHORIZATION = KADER_APPROVAL

## SECURITY

secret_exposure = false
client_isolation = true
project_isolation = true
worker_isolation = true
