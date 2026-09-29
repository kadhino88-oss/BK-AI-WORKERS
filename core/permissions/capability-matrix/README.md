# 7H-10 — CAPABILITY MATRIX

La Capability Matrix définit les capacités autorisées selon :

**Worker → Skill → Tool → Action**

Elle complète les permissions globales, le Skill Runtime, le Tool Router et l'Integration Runtime.

## Sécurité

Une exécution nécessite :

- autorisation Worker
- autorisation Skill
- autorisation Tool
- autorisation Action
- isolation tenant/client/projet

Les secrets ne sont jamais exposés aux Workers.

## Finance

Les opérations financières réelles nécessitent une validation humaine.

Les Workers peuvent préparer et analyser, mais ne peuvent pas exécuter seuls :

- paiements
- virements
- investissements
- remboursements réels
- modifications bancaires
- dépenses réelles

## Architecture

ORCHESTRATOR
→ CONTEXT BRIDGE
→ WORKER
→ SKILL RUNTIME
→ CAPABILITY MATRIX
→ TOOL ROUTER
→ INTEGRATION RUNTIME
→ PROVIDER / API

## Extensibilité

La matrice peut être étendue avec :

- nouveaux Workers
- nouvelles Skills
- nouveaux Tools
- nouvelles Actions
- nouveaux fournisseurs
- configurations spécifiques par client
- configurations spécifiques par projet