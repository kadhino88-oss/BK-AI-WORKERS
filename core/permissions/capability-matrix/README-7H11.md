# 7H-11 — CAPABILITY ENFORCEMENT

Cette phase transforme la Capability Matrix en contrôle d'autorisation effectif.

## Flux

Worker
→ Skill
→ Tool
→ Action
→ Capability Enforcement
→ Decision
→ Integration Runtime

## Decisions

### AUTHORIZED

La combinaison Worker + Skill + Tool + Action est autorisée.

### DENIED

La combinaison demandée n'est pas autorisée.

Le Router ne doit pas poursuivre l'exécution.

### NEEDS_HUMAN

L'action nécessite une validation humaine.

Cas principal :
- finance
- paiement
- virement
- investissement
- remboursement
- modification bancaire
- engagement financier réel

## Isolation

ClientId et ProjectId sont obligatoires.

Un appel sans contexte d'isolation est bloqué.

## Sécurité

Les secrets ne sont jamais transmis au Worker.

Le Capability Enforcer décide uniquement de l'autorisation fonctionnelle.

L'Integration Runtime reste responsable de l'exécution technique.

## 7H-11

Le fichier `TOOL-ROUTER-ENFORCED.ps1` constitue le point d'entrée sécurisé pour les nouveaux appels.

Le `TOOL-ROUTER.ps1` historique n'est pas écrasé dans cette phase.