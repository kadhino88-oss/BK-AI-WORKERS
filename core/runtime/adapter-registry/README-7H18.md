# 7H-18 — Adapter Registry & Provider Binding

## Objectif

Centraliser la résolution :

Provider + Category
→ AdapterId + Version

avec possibilité d'override :

Client + Project + Provider + Category
→ AdapterId + Version

## Règles

- Un adapter doit être enregistré.
- Un provider doit être explicitement bound.
- Un adapter disabled est bloqué.
- Une version différente est bloquée par défaut.
- Un Project doit toujours être associé à un Client.
- Un override Client/Project est prioritaire sur le binding global.
- Les secrets ne sont jamais stockés dans le Registry.
- Le Registry ne fait aucun appel API.
- Le Registry ne charge aucun credential.

## Priorité de résolution

1. Client + Project override
2. Provider + Category binding
3. Blocage si aucun binding valide

## Séparation sécurité

Le Registry sait :

- quel adapter utiliser
- quelle version
- quel statut

Le Registry ne sait pas :

- API key
- password
- access token
- client secret
- private key

La résolution des credentials sera traitée dans une couche séparée.

## Version

1.0