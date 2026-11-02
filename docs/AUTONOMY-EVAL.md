# Évaluation de l'autonomie des Workers : banc, recettes, ce qui est prouvé et ce qui reste dû

État au 2026-11-02, branche `ws/chantier-recipes`. Contrat : `docs/AUTONOMY-ENGINE.md` section 9.

## 1. Recettes (`workers/<id>/recipes/*.json`, `chloe/recipes/*.json`)

- **58 recettes** de format `BK-RECIPE-V1` : 7 profondes (contrat 9.3 : site vitrine, gestion de prospects, publicités Meta/Google, audit SEO, calendrier social, rapport xlsx/docx/pdf, lancement d'offre piloté par Chloé) et 51 de couverture. **Chacun des 17 Workers a au moins 3 recettes.**
- Elles sont écrites par `core/projects/recipes_src/build.py` (sources Python lisibles, fichiers JSON générés ; `--check` échoue si les JSON dérivent de la source). Index : `core/projects/RECIPE-INDEX.json`. Catalogue des tâches de chaque Worker (services de `install-profile.json`) et recette qui les mène au bout : `core/projects/RECIPE-CATALOG.json` : **98 tâches sur 104 couvertes ; les 6 autres ont chacune une raison écrite** (donnée réelle indispensable, connecteur non construit, tâche récurrente et non projet).
- Module `dashboard/recipes.py` (`list_for_worker`, `get`, `candidates`, `render_for_planning` <= 9 000 caractères, `render_for_step` <= 2 400, `public_summary`, `validate`). Le moteur l'appelle déjà en `try/except ImportError` (`projects_steps._recipe_block`, `projects_actions.create_project`, `GET /api/recipes`). Point d'injection : le bloc `recipeBlock` du `input.json` de chaque étape ; aucune modification des playbooks (la limite de taille de `tests/playbook-prompt` n'est pas touchée).
- Chaque recette : définition de « terminé » (critères `auto` typés exécutés par le moteur, `rubric` pour le jugement), étapes avec Worker, dépendances et crédits, livrables, approbations (toutes `low` ou `medium`, jamais `high` par défaut), connecteurs, besoins du client, budget typique, `forbidden`, `sources`. Le critère `CH` oblige une section « Sources et limites » dans le rapport. Les contrôles de texte sont insensibles aux accents.
- **Sources vérifiables** : `core/projects/RECIPE-SOURCES.json` (URL, date de lecture 2026-11-02, `verified`). Lues et citées : guide SEO et règles anti-spam de Google, titres de page, WCAG 2.2, annonces responsives Google Ads, règles éditoriales Google Ads, spécifications Meta du fil, RGPD art. 21. **Non relues par le moteur (pages illisibles ou sources secondaires), marquées `verified: false` et « à confirmer par un juriste »** : LCD/UWG art. 3 al. 1 lit. o, directive ePrivacy art. 13 et lignes directrices CEPD, nLPD, Code des obligations, normes publicitaires Meta. Aucune règle de droit n'est affirmée à partir d'une source non relue. Les recettes de prospection, de relance, d'e-mails et de rédaction juridique portent un `legalNotice` ; la prospection prépare des BROUILLONS, le client décide et envoie, seules des coordonnées professionnelles publiques sont collectées (avec source), la note de conformité est un livrable.
- **Capacités du moteur** : les recettes ne supposent pas la recherche web, l'exécution de code ni les fichiers Office. Leurs `guidance` disent quoi faire sinon (bloquer l'étape, ne rien inventer, livrer le CSV et le dire). Les contrôles et exports déterministes n'exigent aucun modèle.

## 2. Banc d'évaluation (`tests/autonomy-eval/`)

- **15 scénarios, 14 Workers pilotes** (lucas x2, alex, maya, seoya, emma, ines, chloe, clara, dario, nora, noah, yanis, amina, thomas) ; chacun : brief client réaliste, faux profil client et installation, fichiers fournis, grille pondérée (critères `auto` sans modèle + questions `judge`), pièges, livrables attendus, budgets.
- **Contrôles automatiques réimplémentés dans `eval_lib.py`**, indépendants de `dashboard/project_checks.py` (le moteur ne se note pas lui-même) : structure HTML, CSV (colonnes, lignes, unicité, motifs, longueurs, dates), sommes, motifs interdits (avec « sauf s'ils figurent dans les fichiers fournis »), marques `[À COMPLÉTER]`, cohérence de valeurs entre fichiers, xlsx (formules vivantes, erreurs), docx, appels de connecteurs autorisés.
- **Notation** : score pondéré ; « terminé » = critères obligatoires passés + zéro fabrication + livrables présents + partie automatique >= 0,8 + juge >= 50 %. Un livrable absent n'est pas une fabrication ; un fait inventé l'est.
- **Juge à l'aveugle** (`judge.py`, `BK-EVAL-JUDGE-V1`) : prompt fixe, échelle ancrée 1-5, 5 dimensions, JSON strict, deux passes moyennées, instructions des livrables traitées comme des données.
- **Trois bras** (`engines.py`) : `baseline` (la mission actuelle : l'adaptateur PowerShell réel dans une copie de `core/`, contre la fausse API par cassette), `project` (le VRAI `ProjectService` : superviseur, plan, vérification, approbations ; le lanceur est le faux lanceur du banc), `reference` (un appel simple « Claude brut » : `fake`, Ollama local, ou Anthropic refusé par défaut).
- **Sorties** : `results.json` (taux de complétion, critères atteints, coût USD et CHF, durée, étapes), `rapport.md` (tableau), un dossier `workspace/` par exécution.
- **Sécurité des dépenses** : aucun appel Anthropic sans `--allow-anthropic` + `--max-usd > 0` + `ANTHROPIC_API_KEY` ; `SpendGuard` s'arrête au plafond. Le crédit du propriétaire étant épuisé, rien de tel n'a été lancé.

Commandes : voir `tests/autonomy-eval/README.md`.

## 3. Ce qui est prouvé (et seulement cela)

| Preuve | Résultat |
|---|---|
| `python tests/projects/test_recipes.py` | 21 tests : 58 recettes valides (DAG, couverture, types de contrôle, Workers, opérations de connecteur présentes dans `$Script:OperationTable`, budget +-30 %, aucun secret) ; chaque recette est un plan accepté par `validate_plan` sans critère rétrogradé ; **chaque critère automatique de fichier échoue à vide et passe sur des fichiers conformes** (plus de 150 contrôles exécutés) ; garde-fous contre la fabrication testés sur défauts plantés |
| `python tests/autonomy-eval/test_eval_harness.py` | 25 tests : scénarios valides, 80 défauts semés sur 80 détectés par les contrôles (jeu conforme accepté), moteur de projet réel traversé en dry-run (dont S08 à 9 étapes multi-Workers), adaptateur réel traversé contre la fausse API, juge fixe et aveugle, plafond de dépense, refus Anthropic |
| Essai réel Ollama (`qwen2.5:1.5b`, gratuit) | le bras `reference` a tourné sur S13 et S15 : le banc exécute, analyse les blocs de fichiers, note et rapporte ; le petit modèle échoue (critères 1/4 et 0/5), ce qui est attendu et sans valeur de comparaison |

## 4. Ce qui reste DÛ (preuve réelle non faite)

1. **Aucune comparaison réelle A/B/C n'a été faite** : le dry-run prouve la plomberie, pas la qualité (les chiffres d'un dry-run sont étiquetés « simulés » dans le rapport). Les critères de décision de la section 10.6 (au moins 6 scénarios sur 8 et au moins 2 fois le bras A, zéro fabrication, coût <= estimation maximale de la recette, test de redémarrage) restent à mesurer.
2. **Le bras `project` réel** exige le lanceur PowerShell et l'API Anthropic (`Project-StepRunner.ps1`) ; **le bras `baseline` réel** exige l'API Anthropic. À lancer dès que le propriétaire a du crédit Claude ou une clé d'hébergeur suisse : `run --arms baseline,project,reference --provider anthropic --allow-anthropic --max-usd <plafond> --judge anthropic` (le câblage du bras `project` réel est à finir à ce moment-là). Le plafond du contrat (25 USD) reste à approuver par le propriétaire.
3. **Le juge n'a tourné qu'en mode simulé** : un vrai juge (Sonnet 5.5) est dû. `llama3` ou `qwen2.5:1.5b` ne sont pas des juges fiables.
4. Les 6 tâches de catalogue sans recette (alex/prevision-pipeline, dario/paie-cout-employeur, ines/analyse-trafic-tracking, lucas/surveillance-maintenance-site, maya/landing-page-conversion, seoya/suivi-requetes-search-console) : raisons dans `RECIPE-CATALOG.json`.
5. Les textes juridiques officiels (LCD/UWG, nLPD, CO, ePrivacy) n'ont pas été relus : un juriste doit confirmer avant toute annonce de conformité.
6. Les budgets des recettes de couverture sont des estimations d'étapes, à recaler sur les coûts réels des premières exécutions.
