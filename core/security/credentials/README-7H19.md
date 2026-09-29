# 7H-19 — Credential Resolver / Secret Store

## Objectif

Créer une séparation stricte entre :

- identité d'exécution
- référence de credential
- secret réel

## Règle fondamentale

Le système ne transmet jamais un secret brut à un Worker.

Les Workers utilisent uniquement une référence logique :

`credentialRef`

Exemple :

`cred.client001.gmail`

## Isolation

Chaque credential est lié à :

- tenantId
- clientId
- projectId
- provider
- category

Une demande provenant d'un autre tenant, client ou projet est bloquée.

## Ce que retourne le Resolver

Le Resolver retourne :

- credentialRef
- tenantId
- clientId
- projectId
- provider
- category
- secretStore
- secretExposure = false

Il ne retourne jamais :

- API key
- password
- access token
- refresh token
- private key
- client secret

## Architecture future

Credential Resolver
→ Secret Store sécurisé
→ Adapter

Le Secret Store réel pourra ultérieurement utiliser :

- Windows DPAPI
- Vault
- Azure Key Vault
- AWS Secrets Manager
- GCP Secret Manager
- autre coffre sécurisé compatible

Cette phase utilise uniquement des références simulées.

## Version

1.0