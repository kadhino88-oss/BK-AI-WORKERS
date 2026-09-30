# 7H-31 — Rate Limiting & Quota Manager

## Objectif

Limiter le volume d'exécution par fenêtre temporelle afin d'éviter
abus, surcharge et consommation non contrôlée.

## Scopes

- tenant
- client
- project
- worker
- connector
- provider

## Fenêtre

Fenêtre actuelle :

60 secondes

## Limites

- tenant : 100
- client : 50
- project : 25
- worker : 20
- connector : 15
- provider : 15

## Fonctionnement

Chaque scope possède une clé isolée.

Exemple :

TENANT + CLIENT + PROJECT

Une consommation augmente le compteur.

Un dépassement retourne :

`QUOTA_EXCEEDED`

Une demande dépassant la limite disponible retourne :

`RATE_LIMIT_EXCEEDED`

## Isolation

Les compteurs ne sont jamais partagés entre :

- tenants
- clients
- projets

## Sécurité

Les états ne contiennent :

- aucune API key
- aucun access token
- aucun password
- aucun client secret
- aucune private key

## LIVE

`liveExecutionEnabled = false`

Aucun appel externe n'est réalisé.

## Version

1.0