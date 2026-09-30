# 7H-21 — Connector Adapter Factory & Lifecycle

## Objectif

Industrialiser la création et le cycle de vie des adapters.

## Responsabilités

La Factory :

- vérifie qu'un adapter existe
- vérifie le provider
- vérifie la catégorie
- vérifie l'état de l'adapter
- vérifie la santé
- crée une instance logique
- produit un identifiant d'instance
- expose le statut et la version

## La Factory ne fait PAS

- aucun appel API externe
- aucun appel HTTP
- aucun accès direct aux credentials
- aucune création de secret
- aucune exposition de clé API
- aucune activation LIVE

## Lifecycle

REGISTERED
→ READY
→ ENABLED

Et possibilité de :

ENABLED
→ DISABLED

ou :

ENABLED
→ DEPRECATED

## Health

Un adapter doit être HEALTHY pour pouvoir être instancié.

## LIVE

Dans 7H-21 :

`liveCreationEnabled = false`

et :

`supportsLive = false`

Le LIVE réel sera activé uniquement après validation spécifique.

## Version

1.0