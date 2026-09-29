# WORKFLOW ENGINE

## Objectif

Orchestrer des tâches simples ou complexes.

## Types

SEQUENTIAL
PARALLEL
CONDITIONAL
RETRY
ESCALATION

## Exemple séquentiel

NOAH
→ MAYA
→ ALEX
→ EMMA
→ LEA
→ LUCAS

## Exemple parallèle

LEA
└─ design

EMMA
└─ contenu

MAYA
└─ campagne

Puis :

ORCHESTRATOR
→ validation globale

## Règle

Une étape dépendante ne démarre que lorsque
les prérequis nécessaires sont disponibles.

## Retry

Une erreur temporaire peut être réessayée.

Une erreur de permission ne doit pas être contournée.

Une erreur financière doit être escaladée.
