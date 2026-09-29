# BK AI WORKERS
# AI PROVIDER CONTRACT
# PHASE 7E-1

## 1. OBJECTIF

Le Provider Layer fournit une interface standard entre le
BK-AI-GATEWAY et les fournisseurs de modèles IA.

Les Workers ne doivent jamais dépendre directement d'un fournisseur.

Architecture :

ORCHESTRATOR
→ CONTEXT BRIDGE
→ AI GATEWAY
→ PROVIDER LAYER
→ LLM PROVIDER
→ AI RESPONSE
→ WORKER

## 2. PRINCIPES

- Un seul AI Gateway central.
- Une abstraction commune pour tous les fournisseurs.
- Aucun Worker ne gère directement les clés API.
- Aucun Worker ne choisit ou modifie ses permissions.
- Le Provider ne peut jamais augmenter les permissions reçues.
- Le Provider reçoit uniquement le contexte validé.
- L'isolation client/projet/worker reste obligatoire.
- Les secrets ne doivent jamais être écrits dans la mémoire métier.
- Les transactions financières restent interdites.
- Les actions externes restent soumises aux règles du système.

## 3. CONTRAT D'ENTREE

Chaque appel Provider doit recevoir au minimum :

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

## 4. CONTRAT DE SORTIE

Le Provider doit retourner une structure normalisée :

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

## 5. STATUTS

SUCCESS
PARTIAL_SUCCESS
BLOCKED
NEEDS_HUMAN
ERROR

## 6. SECURITE

Le Provider ne peut pas :

- modifier client_id
- modifier project_id
- modifier worker_id
- modifier task_id
- augmenter les permissions
- autoriser une opération financière
- contourner le Context Bridge
- accéder aux secrets métier
- contourner l'AI Gateway

## 7. FOURNISSEURS

Le système doit pouvoir supporter plusieurs fournisseurs.

Exemples :

- Anthropic / Claude
- OpenAI
- autres fournisseurs compatibles

Le choix du fournisseur doit rester une décision du Gateway/configuration,
et non du Worker.

## 8. MODE DE DEVELOPPEMENT

Phase 7E commence sans appel LLM réel.

Modes :

LOCAL
LLM

Le mode LOCAL permet de tester toute l'architecture sans API.

Le mode LLM sera activé uniquement après validation complète de
l'abstraction Provider.

## 9. FINANCE

Le Provider ne peut jamais :

- effectuer un paiement
- effectuer un virement
- investir
- passer un ordre financier
- modifier une donnée bancaire
- engager une dépense

Toute opération financière doit retourner :

NEEDS_HUMAN
KADER_APPROVAL

## 10. REGLE D'OR

Les Workers utilisent l'intelligence.

Le Gateway contrôle l'accès.

Le Provider fournit le modèle.

Le système de permissions reste supérieur au modèle IA.