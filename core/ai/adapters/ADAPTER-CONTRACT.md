# ============================================================
# BK AI WORKERS
# LLM ADAPTER CONTRACT
# PHASE 7E-4
# ============================================================

## OBJECTIF

Les adaptateurs LLM permettent au Provider Engine de communiquer
avec différents fournisseurs d'intelligence artificielle sans que
les Workers dépendent directement d'un fournisseur.

Architecture :

ORCHESTRATOR
    ↓
CONTEXT BRIDGE
    ↓
AI GATEWAY
    ↓
PROVIDER ENGINE
    ↓
LLM ADAPTER
    ↓
LLM PROVIDER
    ↓
NORMALIZED RESPONSE
    ↓
WORKER

## FOURNISSEURS PRÉVUS

- Anthropic / Claude
- OpenAI / GPT

## RÈGLES

1. Aucun Worker ne contient de clé API.
2. Aucun Worker ne contacte directement un fournisseur LLM.
3. Le Provider Engine sélectionne le fournisseur.
4. Le Gateway reste la frontière de sécurité.
5. L'identité client/projet/worker/task doit être conservée.
6. L'isolation client doit être conservée.
7. L'isolation projet doit être conservée.
8. Les permissions ne peuvent jamais être augmentées par le LLM.
9. Le LLM ne peut jamais autoriser une opération financière.
10. Le LLM ne peut jamais contourner la validation humaine.
11. Les secrets ne doivent jamais apparaître dans les prompts ou réponses.
12. Les appels externes restent désactivés tant que le fournisseur
    n'est pas explicitement activé.

## ENTRÉE STANDARD

- client_id
- project_id
- worker_id
- task_id
- objective
- context
- memory
- permissions
- provider
- model

## SORTIE STANDARD

- status
- provider
- model
- worker
- task_id
- answer
- recommendations
- next_action
- security_status
- financial_actions
- external_actions
- generated_at

## MODE 7E-4

Les adaptateurs sont actuellement en mode :

SIMULATION

Aucun appel API réel.

Aucun coût.

Aucune transmission externe.

## FRONTIÈRE FINANCIÈRE

FINANCIAL_OWNER = KADER

Toute opération financière réelle doit rester :

NEEDS_HUMAN
KADER_APPROVAL

## VERSION

7E-4