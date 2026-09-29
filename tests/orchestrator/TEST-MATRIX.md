# ORCHESTRATOR TEST MATRIX

| ID | Test | Worker attendu | Statut attendu |
|---|---|---|---|
| T01 | Prospection | ALEX | ROUTED |
| T02 | Administration | NOAH | ROUTED |
| T03 | Design | LÉA | ROUTED |
| T04 | Marketing | MAYA | ROUTED |
| T05 | Web / SEO | LUCAS | ROUTED |
| T06 | Contenu / Social | EMMA | ROUTED |
| T07 | IT / Sécurité | SAM | ROUTED |
| T08 | Trading | ATLAS | ROUTED |
| T09 | Campagne complète | MAYA + ALEX + EMMA + LÉA | MULTI_WORKER |
| T10 | Paiement | KADER | NEEDS_HUMAN |
| T11 | Contexte ambigu | Aucun | NEEDS_HUMAN |
| T12 | Permission refusée | Aucun | BLOCKED |
| T13 | Erreur technique | Aucun | ERROR |
| T14 | Résultat incomplet | MAYA | PARTIAL_SUCCESS |
| T15 | Résultat vérifié | Aucun | SUCCESS |

## Règle critique

T10 DOIT être refusé automatiquement aux Workers.

Le système doit produire :

STATUS = NEEDS_HUMAN
OWNER = KADER
NEXT_ACTION = KADER_APPROVAL
