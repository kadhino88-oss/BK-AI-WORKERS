# 7H-23 — Retry / Timeout / Idempotency Manager

## Objectif

Éviter :

- les exécutions infinies
- les timeouts non contrôlés
- les doubles créations
- les doubles mutations
- les retries sans limite

## Timeout

Plage actuelle :

- minimum : 1 seconde
- défaut : 30 secondes
- maximum : 300 secondes

## Retry

Configuration :

- maximum : 3 tentatives
- backoff exponentiel
- maximum backoff : 30 secondes

Aucun retry illimité.

## Idempotency

Chaque opération contrôlée peut recevoir une clé :

`IDEMP-<SHA256>`

La clé est dérivée de :

- tenant
- client
- projet
- opération
- task
- execution

Une clé déjà connue bloque la seconde exécution.

## Sécurité

L'Idempotency Manager ne reçoit aucun secret.

Il ne réalise aucun appel externe.

## LIVE

LIVE reste explicitement désactivé.

`liveExecutionEnabled = false`

## Version

1.0