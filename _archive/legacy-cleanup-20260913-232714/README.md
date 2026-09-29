# Archive — nettoyage légitime, 2026-09-13

Ces 17 fichiers ont été déplacés ici (pas supprimés) car chacun est une version historique clairement supersédée par un fichier actuel du même nom dans le projet, et aucun autre fichier ne les référence (vérifié par recherche exhaustive avant déplacement).

Pour annuler : déplacer un fichier de ce dossier vers son chemin d'origine (indiqué par la structure de dossiers ci-dessous, relative à `BK-AI-WORKERS/`).

## Fichiers archivés et leur remplaçant actuel

| Chemin archivé | Remplacé par (fichier actuel) |
|---|---|
| `core/ai/AI-PROVIDER-ENGINE.7E-2.backup.ps1` | `core/ai/AI-PROVIDER-ENGINE.ps1` |
| `core/ai/AI-PROVIDER-ENGINE.7G-2.backup.ps1` | `core/ai/AI-PROVIDER-ENGINE.ps1` |
| `core/security/rbac/RBAC.ps1.bak-binding-fix` | `core/security/rbac/RBAC.ps1` |
| `core/security/rbac/RBAC.ps1.bak-json` | `core/security/rbac/RBAC.ps1` |
| `core/security/rbac/config.json.bak-json` | `core/security/rbac/config.json` |
| `core/security/rbac/state/bindings.json.bak-binding-fix` | `core/security/rbac/state/bindings.json` |
| `core/security/rbac/state/roles.json.bak-binding-fix` | `core/security/rbac/state/roles.json` |
| `core/security/rbac/state/roles.json.bak-json` | `core/security/rbac/state/roles.json` |
| `core/security/session-token-security/runtime.ps1.bak-8A02-FINAL` | `core/security/session-token-security/runtime.ps1` |
| `core/security/session-token-security/runtime.ps1.bak-8A02-PIPELINE` | `core/security/session-token-security/runtime.ps1` |
| `core/security/session-token-security/runtime.ps1.bak-8A02-ROOT-CAUSE` | `core/security/session-token-security/runtime.ps1` |
| `orchestrator/Ask-Orchestrator.7C.broken-backup.ps1` | `orchestrator/Ask-Orchestrator.ps1` (nommé "broken" par son auteur) |
| `orchestrator/Ask-Orchestrator.PHASE6D-BACKUP.ps1` | `orchestrator/Ask-Orchestrator.ps1` |
| `workers/maya/MAYA-Campaign-Planner.7G-6-fix-backup.ps1` | `workers/maya/MAYA-Campaign-Planner.ps1` |
| `workers/maya/MAYA-Intelligence.7G-4.backup.ps1` | `workers/maya/MAYA-Intelligence.ps1` |
| `workers/maya/MAYA-Intelligence.7G-5.backup.ps1` | `workers/maya/MAYA-Intelligence.ps1` |
| `orchestrator/Invoke-EndTo-End.ps1` (avec tiret) | `orchestrator/Invoke-EndToEnd.ps1` (sans tiret — orphelin, non référencé nulle part) |

## Ce qui n'a PAS été touché (volontairement)

- **Dossiers vides** (`chloe/`, `clients/`, `dashboard/`, `docs/`, `memory/*`, `projects/`, `workflows/`, ainsi que tous les sous-dossiers `state/`/`backups/` sous `core/runtime/*`) : ce sont soit des dossiers d'état attendus par des modules qui ne les recréent pas automatiquement, soit l'ossature prévue pour les phases futures du projet (Chloé, multi-client, dashboard). Les supprimer aurait risqué de casser des modules ou d'effacer une préparation volontaire.
- **Fichiers `test.ps1` / `test-XXXX.ps1`** dans chaque dossier `core/*` : convention standard du projet (test unitaire à côté de son `runtime.ps1`), pas des fichiers égarés.
- **`workers/*/skills/contracts/BACKUP_STRATEGY.json` et `BACKUP_VERIFICATION.json`** : ce sont de vrais contrats de compétence (SAM/LUCAS savent auditer des stratégies de sauvegarde), pas des sauvegardes du projet.
- **`orchestrator/Ask-Orchestrator.ps1`** (version actuelle) : conservé tel quel — rien ne prouve qu'il soit obsolète, seulement que rien d'autre ne l'appelle (pourrait être un point d'entrée manuel).
- **`orchestrator/Worker-Execution.ps1`** (implémentation plus ancienne "PHASE 6B-1") : conservé — encore activement appelé par `Invoke-EndToEnd.ps1`, donc pas mort, juste un chemin d'exécution parallèle à celui que Claude a étendu dans `Invoke-Orchestrator.ps1`. À unifier plus tard, hors périmètre de ce ménage.
