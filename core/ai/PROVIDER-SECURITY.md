# BK AI WORKERS
# PROVIDER SECURITY
# PHASE 7F-1

## CREDENTIAL BOUNDARY

Les credentials IA sont considérés comme des secrets critiques.

Ils ne doivent jamais apparaître dans :

- WORKER.md
- scripts Worker
- AI-GATEWAY.ps1
- AI-PROVIDER-ENGINE.ps1
- fichiers JSON de mémoire
- logs
- résultats de tâches
- prompts
- Git
- rapports publics

## MODES

LOCAL
SIMULATION
LLM

La phase actuelle reste :

LLM = DISABLED

## PROVIDERS

ANTHROPIC = NOT ACTIVE
OPENAI = NOT ACTIVE

## SECURITY FLAGS

client_isolation = true
project_isolation = true
worker_isolation = true
financial_actions = false
external_actions = false
secret_exposure = false

## PRINCIPLE

Un Worker demande une capacité IA.

Il ne possède jamais le credential permettant d'appeler directement
le fournisseur.

Architecture :

WORKER
  ↓
ORCHESTRATOR
  ↓
CONTEXT BRIDGE
  ↓
AI GATEWAY
  ↓
PROVIDER ENGINE
  ↓
PROVIDER ADAPTER
  ↓
LLM PROVIDER

Les credentials restent hors du Worker.

## CURRENT STATUS

SAFE
NO API CALL
NO COST
NO FINANCIAL ACTION
