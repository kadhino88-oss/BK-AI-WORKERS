# ERROR HANDLING

## États standards

SUCCESS
PARTIAL_SUCCESS
BLOCKED
NEEDS_HUMAN
ERROR

## SUCCESS

La tâche est terminée et le résultat est vérifiable.

## PARTIAL_SUCCESS

Une partie de la tâche est terminée.

Le Worker doit indiquer :
- ce qui est terminé ;
- ce qui reste ;
- pourquoi.

## BLOCKED

Une dépendance empêche la progression.

Exemples :
- accès manquant ;
- donnée manquante ;
- service indisponible.

## NEEDS_HUMAN

Une décision humaine obligatoire est nécessaire.

Cas prioritaire :
- finance ;
- identité ambiguë ;
- permission critique ;
- incident de sécurité ;
- décision à fort impact.

## ERROR

Erreur technique ou logique non résolue.

Le système doit conserver :
- erreur ;
- contexte ;
- Worker concerné ;
- étape ;
- prochaine action.

## Interdiction

Ne jamais transformer une erreur en SUCCESS.
