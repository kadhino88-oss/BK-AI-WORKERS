# BK AI WORKERS
# CREDENTIAL BOUNDARY
# PHASE 7F-2

## OBJECTIF

Les credentials des fournisseurs IA doivent rester séparés du code,
des Workers, de la mémoire métier et des résultats d'exécution.

## SECRET STORE

Répertoire réservé :

.secrets/

Ce répertoire ne doit jamais être versionné.

## INTERDICTIONS

Un credential ne doit jamais apparaître dans :

- workers/
- orchestrator/
- core/ai/*.ps1
- memory/
- logs
- résultats JSON
- prompts
- rapports
- README
- Git

## FOURNISSEURS

ANTHROPIC
OPENAI

## ETAT ACTUEL

Aucun credential configuré.

LLM réel = désactivé.
API réelle = désactivée.
Coût = 0.

## REGLE D'ACCES

Les Workers ne lisent jamais directement un secret.

Le chemin autorisé futur est :

WORKER
→ ORCHESTRATOR
→ CONTEXT BRIDGE
→ AI GATEWAY
→ PROVIDER ENGINE
→ ADAPTER
→ SECRET BOUNDARY
→ PROVIDER

## SECURITE

client_isolation = true
project_isolation = true
worker_isolation = true
secret_exposure = false
financial_actions = false
external_actions = false

## FINANCIAL BOUNDARY

Les credentials IA ne donnent aucun droit financier.

Toute opération financière réelle reste sous autorité KADER.

## STATUS

READY
NO CREDENTIALS
NO API CALL
NO COST