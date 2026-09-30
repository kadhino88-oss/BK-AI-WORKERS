# 7H-27 — Execution Event Bus & Lifecycle State Machine

## Objectif

Suivre le cycle de vie d'une exécution avec des transitions
strictement contrôlées et des événements append-only.

## États

CREATED
VALIDATING
AUTHORIZED
RUNNING
COMPLETED
FAILED
BLOCKED
CANCELLED

## Transitions principales

CREATED → VALIDATING

VALIDATING → AUTHORIZED
VALIDATING → BLOCKED

AUTHORIZED → RUNNING

RUNNING → COMPLETED
RUNNING → FAILED
RUNNING → CANCELLED

## Sécurité

Les transitions terminales ne peuvent pas revenir vers RUNNING.

Exemples interdits :

COMPLETED → RUNNING
FAILED → RUNNING
BLOCKED → RUNNING
CANCELLED → RUNNING

## Event Bus

Chaque événement possède :

- eventId
- eventVersion
- eventType
- executionId
- correlationId
- tenantId
- clientId
- projectId
- workerId
- skillId
- taskId
- fromState
- toState
- timestamp

## Audit

Le ledger est append-only.

## Secret Security

Les secrets sont filtrés avant création de l'événement.

## LIVE

`liveExecutionEnabled = false`

Aucun appel externe n'est effectué dans 7H-27.

## Version

1.0