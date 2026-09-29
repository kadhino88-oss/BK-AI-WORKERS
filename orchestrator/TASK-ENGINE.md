# TASK ENGINE

## Objectif

Créer et suivre les tâches confiées aux Workers.

## Cycle

CREATED
↓
ROUTED
↓
IN_PROGRESS
↓
WAITING
↓
COMPLETED / BLOCKED / NEEDS_HUMAN / ERROR

## Chaque tâche possède

- task_id
- parent_task_id
- client_id
- project_id
- source
- target_worker
- objective
- inputs
- constraints
- permissions
- priority
- deadline
- status
- result
- blocker
- next_action
- created_at
- updated_at

## Règle

Une tâche doit toujours avoir :
- un objectif ;
- un contexte ;
- un Worker responsable ;
- un état ;
- une prochaine action.

Une tâche sans responsable ne peut pas être exécutée.
