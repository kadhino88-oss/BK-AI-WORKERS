# 7H-12 — TOOL ROUTER ENFORCEMENT + AUDIT

## Objectif

Le Tool Router devient le point d'entrée obligatoire avant toute exécution d'outil.

Flux :

Worker
→ Skill
→ Capability Enforcer
→ Audit
→ Tool Router
→ Integration Runtime / Legacy Router

## Décisions

### AUTHORIZED

La combinaison Worker + Skill + Tool + Action est autorisée.

### DENIED

L'exécution est bloquée.

### NEEDS_HUMAN

L'exécution est bloquée jusqu'à validation humaine.

## Audit

Chaque décision est écrite dans :

`core/logging/audit/CAPABILITY-AUDIT.jsonl`

Les informations principales sont :

- Worker
- Skill
- Tool
- Action
- Client
- Projet
- mode
- décision
- statut
- validation humaine
- raison

## Compatibilité

Le Router historique est sauvegardé avant remplacement sous :

`core/tools/TOOL-ROUTER-LEGACY-YYYYMMDD-HHMMSS.ps1`

Le nouveau `TOOL-ROUTER.ps1` devient la porte de contrôle.

## Finance

Aucune opération financière réelle ne peut contourner :

`NEEDS_HUMAN` / `KADER_APPROVAL_REQUIRED`

## Important

Le Capability Enforcer décide si une action est autorisée.

L'Integration Runtime reste responsable de l'exécution technique et de la gestion des secrets.