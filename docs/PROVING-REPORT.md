# Rapport de preuve du moteur de projets (2026-11-02)

Branche `ws/chantier-final`. Banc : `tests/proving/` (voir « Reproduire »). Dépense réelle : **0 USD** (aucun appel Anthropic ; seul Ollama local a servi).

## 0. Ce qui est prouvé et ce qui ne l'est pas

| | Statut |
|---|---|
| La MÉCANIQUE du moteur (plan, étapes de plusieurs Workers, espace de travail, vérification qui échoue puis force une correction, articles d'approbation jamais exécutés seuls, atelier de sites, aperçu, zip, question bloquante, pause de quota et reprise, redémarrage brutal, Chloé sur 3 Workers, Trio) | **PROUVÉE** par le vrai serveur HTTP, dernière exécution de chaque scénario : 0 échec ; lancements : prospects/ads/SEO/site (exécution complète), puis site, Chloé, Trio, question, quota, redémarrage : 53 contrôles ; site + SEO rejoués pour la recette navigateur : 33 contrôles (section 2) |
| La QUALITÉ du travail d'un vrai modèle sur les 4 briefs | **NON PROUVÉE** : due (section 5) |
| Le comportement d'un petit modèle réel dans le moteur | Observé une fois (section 4) : il ne mène rien au bout, et le moteur ne l'a pas laissé prétendre le contraire |

**Avertissement essentiel.** Le « bon modèle » du banc est un script (`tests/proving/fl_*.py`) : il écrit des actions d'outils que j'ai rédigées. Les textes (site du Cabinet Léman Santé, audit d'Atelier Papier, 15 fiduciaires genevoises, campagne Thés des Alpes) sont FICTIFS (domaines `.example`) et leur qualité ne dit RIEN sur ce que produirait Claude. Ce qui est éprouvé : le moteur autour (outils réels, contrôles automatiques rejoués par le moteur, vérificateur, approbations, usage, reprise).

## 1. Méthode

Le vrai `dashboard/server.py` démarre sur une copie jetable du dépôt (port libre, `BK_PROJECTS=1`, `BK_USAGE_WINDOWS=1`), avec le vrai superviseur, la vraie passerelle d'usage, un faux exécuteur de connecteurs qui NOTE ses appels, et un lanceur d'étape scripté (`proving_runner.py`, mêmes outils `project_tools`/`site_*` que le lanceur de production). Comptes de test générés à chaque lancement. Plans = critères MOT POUR MOT des vraies recettes (`workers/*/recipes`), les critères automatiques sont rejoués par le moteur. Le vérificateur scripté applique de vrais contrôles (recompte des caractères, preuve retrouvée dans l'extrait lu, source rouverte).

## 2. Résultats par projet (via l'API HTTP, serveur réel)

| Projet | Workers | Fin seule ? | Étapes | Durée (machine lente) | Crédits / plafond | Ce que la vérification a attrapé | Approbations préparées |
|---|---|---|---|---|---|---|---|
| 1. Site vitrine FR/EN (Cabinet Léman Santé) | lucas, lea, emma, seoya | DONE | 7 + vérifs + rapport | 19 s | 71 / 189 | (1ère passe : le contrôle `site_check` du moteur a refusé des pages légales sans méta ; corrigé dans le banc) | 7 brouillons WordPress, 0 exécuté |
| 2. Audit SEO (Atelier Papier, fictif) | seoya, lucas, emma | DONE | 5 + FIX1-1 | 12 s | 69 / 152 | briefs avec « 1 900 recherches/mois » inventé : C5 FAIL puis correction | 2 (brouillon WP, correction robots.txt manuelle) |
| 3. Prospects (15 fiduciaires, fictives) | alex, amina, emma | DONE | 5 + FIX1-1 | 16 s | 69 / 150 | adresse gmail privée dans la liste : critère C4 rejoué par le MOTEUR | 15 brouillons Gmail + 15 tâches CRM, 0 exécuté |
| 4. Campagne Meta (Thés des Alpes, fictif) | maya, emma, lea | DONE | 5 + FIX1-1 | 16 s | 69 / 138 | titre de 52 car. (> 40) : C3 FAIL, recompté, corrigé | 2 manuels (lancement 600 CHF « risque élevé », pixel) |

Faits vérifiés : critères tous PASS ; aucun appel de connecteur sans validation ; valider UN article WordPress = exactement UN appel avec le contenu exact ; rapport final ; zip du site téléchargeable ; aperçu privé servi sous `Content-Security-Policy: sandbox` ; aucun avis, note ni chiffre inventé dans le site construit (le brief demandait « trois avis », le rapport explique le refus) ; faits manquants (adresse, téléphone, tarif, équipe) laissés en « [À COMPLÉTER] » avec question non bloquante au client.

Autres scénarios (même serveur) :
- **Chloé, 3 Workers** (site + SEO + pub) : plan lucas → seoya → maya avec dépendances ; le Worker 3 reprend mot pour mot la ligne de remise des Workers 1 et 2 (vérifié) ; étape de consolidation par Chloé ; DONE, 39 / 72 crédits.
- **Trio (lucas embauché)** : Chloé ne délègue qu'à lucas, le détail liste les 16 Workers refusés (`scope.deniedWorkers`), le plan écrit lesquels manquent ; DONE.
- **Question bloquante** : `WAITING_INPUT` avec UNE question précise et sa raison, les étapes indépendantes continuent, la réponse relance seule, DONE.
- **WAITING_QUOTA** (fenêtre de session raccourcie à 36 s, contingent 16 crédits) : pause avec `resumeAtUtc` exact, état conservé, `/api/usage` montre session pleine + forfait du dessus ; reprise SEULE au renouvellement, plusieurs pauses successives, DONE. Seconde partie, fenêtre de 1 h : la montée en gamme Équipe → Pro relance le projet en 0,7 s.
- **Redémarrage brutal** (kill du serveur pendant l'étape S3) : après redémarrage le projet reprend et finit, sans doublon d'approbation.
- **Navigateur** (Chrome réel, serveur de test local) : aperçu du site correctement stylé à 1544 px (en-tête, héros, boutons) ; liste des projets et détail du projet SEO (critères avec preuve, étapes par Worker, jauge « Session 19 % », livrables, rapport final). À 375 px : la fenêtre n'a pas pu être redimensionnée et l'iframe a gelé le rendu ; vérifié seulement statiquement (viewport, grilles `auto-fit`, `max-width:100%`). Le navigateur intégré à l'application ne charge pas la feuille de style de l'aperçu (`ERR_BLOCKED_BY_CLIENT`, restriction de ce volet, absente dans Chrome).

Comparaison avec l'ancienne boucle unique (scénario S01, banc `autonomy-eval --dry-run`) : baseline = une réponse « voici comment faire » (cassette) : 0 fichier, note 0,0 ; projet = 1,0. **Ce n'est pas une mesure de modèle** (réponse de la cassette choisie par le banc) : elle illustre seulement ce qu'une requête unique ne PEUT pas livrer.

## 3. Défauts trouvés et corrigés (avec test de régression, `tests/proving/test_regressions.py`)

1. **Recette perdue après la planification** (`projects_steps._recipe_block`) : la recette choisie par le planificateur est dans `plan.recipeId`, mais les étapes ne lisaient que `state.recipeId` (recette imposée à la création) : exécution et vérification ne recevaient aucun guide de recette. Repli sur `plan.recipeId`.
2. **Écriture d'état sans réessai sous Windows** (`server._write_json_atomic`) : un lecteur concurrent (interrogation de la progression) faisait échouer `os.replace` (WinError 5) ; la fin d'étape était perdue, l'étape restait RUNNING et le projet bloqué (observé : 2 min). Réessais comme `project_paths.atomic_write_bytes`. Un HTTP 500 à la création d'un projet, vu une fois avant ce correctif, n'a pas été reproduit depuis (cause probable identique, non démontrée).
3. **Plafond de crédits sans part fixe** : le plafond = estimation du plan (étapes de travail) × 1,25 ; planification, vérification, relecture de cohérence et rapport (≈ 14 à 20 crédits) n'y figuraient pas, donc un petit projet passait `BUDGET_REACHED` APRÈS avoir fini son travail. Ajout de `budget.engineOverheadCredits` (14) dans `PROJECT-LIMITS.json` ; `test_engine_budget` mis à jour (20 → 34).
4. **Vue d'usage périmée à la pause** : la progression met l'usage en cache 5 s ; au passage en WAITING_QUOTA le client pouvait voir une session non pleine et un renouvellement mensuel. Cache invalidé à la mise en pause.

## 4. Smoke avec un vrai petit modèle local (qwen2.5:1.5b, Ollama, coût 0)

Lanceur `ollama_runner.py` (boucle d'outils Python parlant à Ollama, outils du moteur), projet minuscule « page d'accueil de 3 phrases pour une boulangerie » :
- **Porte** : serveur en `BK_AI_PROVIDER=ollama` : création refusée, `ENGINE_NO_PROJECTS` (400) avec message honnête. C'est la porte qui fonctionne.
- **Modèle seul (7 min)** : planification jamais aboutie. Tentative 1 : texte sans appel d'outil, puis `step_complete` au rapport invalide (`STEP_REPORT_INVALID`) ; tentative 2 : deux `project_plan` rejetés (`INVALID_INPUT`) ; tentative 3 en cours. Aucun plan.
- **Plan écrit par le banc, modèle sur l'exécution** : 3 tentatives, 29 tours, AUCUN appel d'outil (le modèle répond en texte) ; étape en échec, replanification automatique, nouvelle tentative ; aucun fichier écrit, aucun faux DONE, aucune réussite déclarée acceptée.
- Lecture honnête : un modèle de 1,5 milliard de paramètres ne sait pas utiliser ce contrat d'outils ; le moteur le détecte (réessais, échec, replanification) et ne ment pas. Cela ne dit rien de la qualité de Claude ou d'un modèle suisse plus gros.

## 5. Preuve de qualité RÉELLE encore DUE

À rejouer dès que le propriétaire a un moteur (crédit Claude ou clé d'un hébergeur suisse) :
1. Les 4 briefs ci-dessus avec Sonnet 5.5 (Opus 5.5 au plus 2 fois pour plan/vérification) : `tests/autonomy-eval/run_eval.py run --arms project,baseline --scenarios S01,S03,S04,S05 --provider anthropic --allow-anthropic --max-usd 20 --judge anthropic --out <dossier>` (clé via `ANTHROPIC_API_KEY`, jamais affichée), plus un vrai site public réel pour le SEO (le banc a audité un site fictif).
2. Un vrai site-vitrine : plan, `site_*`, `site_check`, aperçu à 375 px et 1280 px ouverts, brouillon WordPress préparé.
3. Une requête Chloé sur 3 Workers, précision de routage sur `tests/chloe-delegation/routing_cases.json`.
4. Une limite de session atteinte en plein projet avec le vrai lanceur (le banc l'a prouvée avec le lanceur scripté).
Lancer le banc mécanique : `python tests/proving/run_proving.py` (≈ 10 min, `--only site,seo,...`, `--keep --creds <fichier>` pour la recette navigateur) ; smoke local : `python tests/proving/run_ollama_smoke.py`.

## 6. Lacunes constatées (non corrigées)

- **Le connecteur Meta Ads n'a que des opérations de LECTURE** (`READ_CAMPAIGN`, `READ_REPORT`) : le lancement d'une campagne est un article d'approbation MANUEL guidé, pas une action de connecteur. Idem Google Ads. « CRM » : seul `hubspot:CREATE_TASK` existe (pas de création de contact).
- Un projet de site sur forfait **Équipe** (session ≈ 83 crédits) épuise sa session en cours de route avec des étapes à 8 crédits : il se met en pause puis reprend (voulu), mais l'expérience est lente ; à calibrer avec de vrais coûts.
- La vue de la liste d'approbations de l'API ne porte pas les paramètres complets (contenu clipsé) : l'exécution utilise bien le contenu exact stocké.
- Sous Windows, un lanceur orphelin d'un serveur tué n'est pas supprimé (nettoyage `/proc` Linux seulement) : sans effet en production (Linux).
- `state.recipeId` reste vide quand la recette vient du planificateur (champ `recipeId` du détail) : seul `plan.recipeId` la porte ; la guidance des étapes est corrigée (défaut 1), l'affichage reste à aligner.
