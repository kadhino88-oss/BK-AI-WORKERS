# WORKFLOW STATE MACHINE

## États du workflow

CREATED
READY
RUNNING
WAITING
PARTIAL_SUCCESS
SUCCESS
BLOCKED
NEEDS_HUMAN
ERROR

## États d'une tâche

PENDING
READY
RUNNING
SUCCESS
BLOCKED
NEEDS_HUMAN
ERROR

## Transitions

CREATED → READY
READY → RUNNING
RUNNING → SUCCESS
RUNNING → PARTIAL_SUCCESS
RUNNING → BLOCKED
RUNNING → NEEDS_HUMAN
RUNNING → ERROR

## Dépendances

Une tâche avec :

depends_on = ["TASK-A"]

ne peut passer à READY que lorsque TASK-A = SUCCESS.

## Parallelisation

Les tâches sans dépendance mutuelle peuvent fonctionner
en parallèle.

## Finalisation

Le workflow devient SUCCESS lorsque toutes les tâches
obligatoires sont SUCCESS.

PARTIAL_SUCCESS si certaines tâches non critiques
sont incomplètes.

NEEDS_HUMAN si une validation humaine est obligatoire.

BLOCKED si une dépendance empêche la progression.

ERROR si une erreur critique non résolue survient.
