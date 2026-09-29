# MULTI-WORKER WORKFLOW ENGINE

## Version

0.1 — Controlled Simulation

## Mission

Transformer une demande complexe en workflow composé
de plusieurs tâches coordonnées.

## Cycle

REQUEST
→ ANALYZE
→ DECOMPOSE
→ BUILD WORKFLOW
→ CHECK DEPENDENCIES
→ ROUTE
→ SIMULATE
→ COLLECT RESULTS
→ VALIDATE
→ FINALIZE

## Modes

SEQUENTIAL
PARALLEL
CONDITIONAL

## Règles

Une tâche peut :
- démarrer immédiatement ;
- attendre une autre tâche ;
- être exécutée en parallèle ;
- bloquer les tâches dépendantes.

## Exemple

Lancement d'un service :

MAYA
├── stratégie marketing
│
├── ALEX
│   └── prospects
│
├── EMMA
│   └── contenu
│
└── LÉA
    └── visuels

Puis :

LUCAS
└── landing page

Puis :

SAM
└── contrôle technique/sécurité

Puis :

ORCHESTRATOR
└── rapport final

## Finance

Toute opération financière réelle reste NEEDS_HUMAN.
