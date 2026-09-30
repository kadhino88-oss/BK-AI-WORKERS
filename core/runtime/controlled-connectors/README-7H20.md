# 7H-20 — Controlled External Connectors

## Objectif

Préparer l'exécution de connecteurs externes avec une barrière de sécurité
avant toute activation de véritables appels API.

## Connecteurs préparés

- GMAIL
- WORDPRESS
- CRM
- STRIPE (désactivé)

## Modes

### SIMULATION

Aucun appel externe.

### CONTROLLED

Prépare l'exécution mais n'autorise toujours aucun appel Internet réel.

### LIVE

Bloqué dans 7H-20.

L'ouverture du LIVE réel sera effectuée ultérieurement après validation
des connecteurs, des credentials et de la politique d'exécution.

## Sécurité

Un Connector doit :

- être enregistré
- être enabled
- être associé à un Adapter
- utiliser une opération autorisée
- recevoir un contexte complet
- utiliser une credentialRef
- ne jamais recevoir directement une API key ou un password

## Secret handling

Les secrets bruts ne doivent jamais apparaître dans :

- Worker
- Skill
- paramètres de tâche
- Connector Registry
- Adapter Contract
- logs

Seule une référence comme :

`cred.client001.gmail`

est autorisée dans cette couche.

## LIVE

`liveExecutionEnabled = false`

Cette valeur doit rester false jusqu'à l'ouverture contrôlée
d'une phase dédiée aux connecteurs externes réels.

## Version

1.0