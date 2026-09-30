# 7H-16 — INTEGRATION RUNTIME ENFORCEMENT

Le Runtime Enforcement constitue la dernière barrière avant le connecteur ou l'API.

## Décisions

- SIMULATION
- LIVE_READY
- LIVE_EXECUTION_AUTHORIZED
- NEEDS_HUMAN
- BLOCKED

## Sécurité

Une policy non autorisée ne peut pas atteindre l'intégration.

Une exécution en simulation ne déclenche jamais d'appel externe.

Un contexte incomplet est bloqué.

Une opération NEEDS_HUMAN est bloquée jusqu'à validation.

Le Runtime ne reçoit aucun secret dans ses paramètres fonctionnels.

## Architecture

Capability Enforcement
→ Execution Context
→ Runtime Handoff
→ Execution Policy
→ Integration Runtime Enforcement
→ Integration Adapter
→ API

## Important

`LIVE_EXECUTION_AUTHORIZED` signifie uniquement que le Runtime peut transmettre la demande à un adaptateur d'intégration autorisé.

Le Runtime Enforcement n'effectue pas lui-même l'appel réseau.