# 7H-17 — Integration Adapter Contract

## Objectif

Définir le contrat standard utilisé entre :

Integration Runtime
→ Integration Adapter
→ Provider externe

## Règles principales

1. Un Adapter possède un `adapterId`, un provider, une catégorie et une version.
2. Toute exécution possède un contexte complet :
   - tenant
   - client
   - projet
   - worker
   - skill
   - task
   - tool
   - action
   - executionId
   - correlationId
3. Le capability check doit déjà être effectué.
4. La décision de policy doit déjà exister.
5. Les Workers ne reçoivent jamais les credentials.
6. `secretsProvidedToAdapter` doit rester `false`.
7. Les secrets sont résolus ultérieurement par une couche dédiée de credential management.
8. Aucun Adapter ne doit pouvoir contourner :
   - tenant isolation
   - client isolation
   - project isolation
   - capability enforcement
   - execution policy
9. SIMULATION ne doit effectuer aucun appel externe.
10. LIVE n'est possible que lorsque la policy autorise LIVE.

## Futur flux credential

Adapter
→ Credential Resolver
→ Secret Store
→ Provider API

Les credentials ne doivent jamais être ajoutés aux paramètres transmis par le Worker.

## Contrat actuel

Version : 1.0