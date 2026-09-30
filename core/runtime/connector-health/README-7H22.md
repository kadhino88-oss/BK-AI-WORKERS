# 7H-22 — Connector Health & Availability Manager

## Objectif

Déterminer si un connector peut continuer une exécution
en fonction de son état de santé et du circuit breaker.

## Etats

HEALTHY
- disponible
- exécution autorisée

DEGRADED
- disponible avec prudence
- retry recommandé

UNAVAILABLE
- indisponible
- exécution bloquée

DISABLED
- désactivé
- exécution bloquée

UNKNOWN
- état inconnu
- exécution bloquée

## Retry

Retry activé avec :

- maxAttempts = 3
- backoff exponentiel
- maxBackoffSeconds = 30

Aucun retry illimité.

## Circuit Breaker

Seuil :

`3 échecs`

Après le seuil :

`CLOSED → OPEN`

Le circuit OPEN bloque les nouvelles exécutions.

## LIVE

7H-22 ne réalise aucun appel API externe.

`liveHealthChecksEnabled = false`

Le Runtime LIVE reste bloqué.

## Secret Security

Le Health Manager ne reçoit :

- aucune API key
- aucun access token
- aucun password
- aucun client secret

## Version

1.0