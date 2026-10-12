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

## PLAFOND DE COÛT PAR MISSION (2026-10-12, adaptateur Anthropic)

Chaque niveau de `core/ai/LEVELS.json` peut porter `maxCostChf` (Équilibré 0,50, Approfondi 1,00 ;
Rapide : `null`, pas de plafond). `Mission-Cost.ps1` cumule le coût réel de chaque appel
(jetons d'entrée, écriture et lecture du cache, sortie, recherches web) avec les tarifs de
`core/ai/AI-PRICING.json` (table unique, lue aussi par le résumé des coûts du dashboard) et le taux
fixe 1 USD = 0,83107 CHF. Avant chaque appel suivant (jamais avant le premier) :

1. coût engagé ≥ plafond : on s'arrête ;
2. sinon on estime l'appel suivant de façon prudente (prompt du dernier appel + sa sortie + les
   nouveaux résultats d'outils à 3 caractères par jeton, plein tarif sans cache ; sortie = la plus
   grosse vue, au moins 2 000 jetons ; recherches web du dernier appel) et on s'arrête si le total
   dépasse le plafond.

Un arrêt est propre : les outils du dernier tour sont traités comme d'habitude (une action en attente
de confirmation reste écrite sur disque et listée dans `connector_actions`), aucun appel de plus
n'est lancé, la réponse est la meilleure obtenue suivie d'une note en français (ce qu'il reste à
faire, fichiers peut-être incomplets) et les champs suivants sont renseignés :

- `cost_capped` (booléen, repris par le moteur puis par `Invoke-Worker-AI.ps1` en `CostCapped` dans le
  résultat de la tâche) ;
- `usage` : `input_tokens` / `output_tokens` CUMULÉS sur tous les appels, `cache_creation_input_tokens`,
  `cache_read_input_tokens`, `web_search_requests`, `api_calls`, `estimated_cost_usd`,
  `estimated_cost_chf`, `fx_chf_per_usd`, `cost_ceiling_chf`, `cost_priced`, `cost_complete`,
  `cost_capped`, `cost_cap_reason` (`ceiling-reached` ou `next-call-would-exceed`).

Limites connues : un appel unique n'est pas interrompu (`max_tokens` reste à 64 000 pour ne jamais
rendre une réponse tronquée en silence) ; le premier appel n'est jamais refusé ; un modèle sans tarif
dans `AI-PRICING.json` n'a ni coût ni plafond (`cost_priced = false`).

## VERSION

7E-4