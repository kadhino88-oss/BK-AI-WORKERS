# 7H-24 — External Connector Execution Gateway

## Objectif

Créer un point d'entrée unique avant toute exécution d'un connector externe.

## Contrôles obligatoires

Le Gateway exige :

1. Execution Context
2. Capability Authorization
3. Policy Authorization
4. Connector resolution
5. Adapter resolution
6. Credential reference
7. Health approval
8. Timeout validity
9. Idempotency
10. Retry limit

## Interdictions

Le Gateway interdit :

- exécution directe d'un Connector
- transmission de secret brut
- bypass du Capability Engine
- bypass de la Policy
- bypass du Health Manager
- double exécution
- retry infini
- LIVE par défaut

## LIVE

`liveExecutionEnabled = false`

Aucun appel externe n'est réalisé dans 7H-24.

## Sorties

`AUTHORIZED`
- toutes les barrières sont passées
- l'exécution peut être remise au Connector
- aucun appel externe n'est réalisé par le Gateway

`BLOCKED`
- une condition de sécurité ou d'exécution n'est pas respectée

`NEEDS_HUMAN`
- une approbation humaine est requise

## Sécurité

Le résultat ne contient aucun secret brut.

Seule la référence :

`credentialRef`

est propagée.

## Version

1.0