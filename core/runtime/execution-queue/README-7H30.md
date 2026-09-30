# 7H-30 — Execution Queue & Scheduling Manager

## Objectif

Mettre les exécutions en file avant leur prise en charge par
l'Execution Orchestrator Controller.

## États

QUEUED
RUNNING
COMPLETED
FAILED
CANCELLED

## Scheduling

Le scheduler sélectionne :

1. priorité la plus élevée
2. FIFO pour les éléments de même priorité

## Concurrence

Nombre maximal actuel :

`10`

Une nouvelle exécution n'est pas sélectionnée lorsque la limite
de concurrence est atteinte.

## Doublons

Sont bloqués :

- executionId déjà actif ou terminé
- idempotencyKey déjà active ou terminée

## Isolation

Chaque élément contient :

- tenantId
- clientId
- projectId

La queue ne mélange pas les identités.

## Annulation

Une exécution QUEUED peut être annulée.

Une exécution RUNNING doit suivre son propre cycle d'arrêt.

## Secrets

Aucun secret n'est stocké dans les éléments de queue.

## LIVE

`liveExecutionEnabled = false`

Aucune exécution externe réelle n'est réalisée dans 7H-30.

## Version

1.0