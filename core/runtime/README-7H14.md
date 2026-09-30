# 7H-14 — RUNTIME CONTEXT HANDOFF

Le Runtime Handoff transporte le contexte complet depuis le système d'autorisation vers le Runtime.

## Identité conservée

- executionId
- correlationId
- tenantId
- clientId
- projectId
- workerId
- skillId
- taskId
- toolId
- action
- mode

## Règles

Le Handoff refuse un contexte incomplet.

L'isolation tenant/client/projet reste obligatoire.

Le contexte ne contient pas de secret.

L'autorisation doit avoir été vérifiée avant le Handoff.

Le Handoff ne donne pas automatiquement l'autorisation d'exécuter une action LIVE.

Les opérations financières autonomes restent interdites.

## Flux

Execution Context
→ Capability Enforcement
→ Runtime Handoff
→ Integration Runtime