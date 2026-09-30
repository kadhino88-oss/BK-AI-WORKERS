# 7H-29 — Execution Concurrency & Lock Manager

## Objectif

Empêcher deux exécutions concurrentes de la même opération
pour le même tenant/client/projet/connector.

## Clé de concurrence

La clé est dérivée de :

- tenantId
- clientId
- projectId
- connectorId
- operation

## Lock

Un lock contient :

- lockId
- lockKey
- tenantId
- clientId
- projectId
- connectorId
- operation
- executionId
- ownerId
- createdAt
- expiresAt

## Sécurité

Aucun secret n'est stocké dans les locks.

## Isolation

La concurrence est isolée par :

TENANT
CLIENT
PROJECT

## Stale lock

Un lock expiré est considéré comme stale
et peut être remplacé par une nouvelle exécution.

## Release

Seul le couple :

executionId + ownerId

peut libérer le lock.

## LIVE

`liveExecutionEnabled = false`

Aucun appel externe n'est effectué dans 7H-29.

## Version

1.0