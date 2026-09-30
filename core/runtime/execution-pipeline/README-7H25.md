# 7H-25 — External Connector Execution Pipeline

## Objectif

Assembler les protections précédentes dans un pipeline unique
et séquentiel avant toute exécution externe.

## Ordre obligatoire

1. Capability
2. Context
3. Policy
4. Adapter
5. Credential
6. Health
7. Retry / Timeout / Idempotency
8. Gateway
9. Connector
10. Result
11. Audit

## Règle

Une étape échouée arrête immédiatement le pipeline.

Aucun stage ne peut être contourné.

## Sécurité

Le pipeline interdit :

- secret forwarding
- execution directe d'un connector
- bypass des stages
- double exécution
- retry au-delà de la limite
- exécution LIVE par défaut

## Résultat

Une exécution complète autorisée produit :

`AUTHORIZED`

mais :

`externalCallPerformed = false`

dans cette phase.

## LIVE

`liveExecutionEnabled = false`

Aucun appel externe réel n'est effectué.

## Audit

Chaque pipeline complet indique :

`auditRequired = true`

La prochaine couche pourra brancher la journalisation structurée
du résultat final et des décisions de chaque étape.

## Version

1.0