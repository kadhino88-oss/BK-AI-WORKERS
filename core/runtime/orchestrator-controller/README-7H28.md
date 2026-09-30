# 7H-28 — Execution Orchestrator Controller

## Objectif

Créer un point d'entrée unique pour les exécutions.

## Responsabilité

Le Controller orchestre dans un ordre strict :

1. Capability
2. Context
3. Policy
4. Adapter
5. Credential
6. Health
7. Execution Controls
8. Gateway
9. Connector
10. Result
11. Event
12. Audit

## Stop-on-first-failure

La première erreur arrête immédiatement l'orchestration.

## Sécurité

Le Controller interdit :

- bypass
- exécution directe de connector
- propagation de secret
- contour de la capability
- contour de la policy
- exécution LIVE par défaut

## Single Entry Point

Les futures couches d'exécution doivent passer par :

`New-OrchestratorExecutionRequest`

et non contacter directement les Connectors.

## LIVE

`liveExecutionEnabled = false`

Aucun appel externe réel n'est effectué.

## Version

1.0