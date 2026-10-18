# Moteur d'autonomie (« Projet ») — contrat d'architecture

Statut : **squelette du 2026-10-19** (dix sections, décisions principales). Chaque section est ensuite approfondie et commitée séparément (voir l'historique git de `ws/chantier-design`). Ce document est le contrat que six constructeurs implémentent, en deux vagues.

Branche de départ : `origin/ws/hire-final`. Tout ce qui est décrit ici est **dormant** derrière `BK_PROJECTS` (défaut `0`) jusqu'à la preuve (section 10).

## Pourquoi (le problème, vérifié dans le code)

Une mission actuelle = UNE requête bornée : boucle de 6 à 20 appels (`core/ai/LEVELS.json`), échéance de 540 s (`$MissionDeadline` dans `ANTHROPIC-ADAPTER.ps1`), coupure serveur à 600 s (`submit_task`, `timeout=600`), aucun état qui survit à la requête, pas de plan, pas d'espace de travail durable (le bac à sable `code_execution` est neuf à chaque requête et sans internet), aucune vérification indépendante, un Worker à la fois, et la première action sortante arrête la mission (`PENDING_CONFIRMATION`, `$StopLoop = $true`). C'est bien pour une réponse ou un fichier ; c'est impossible pour « crée mon site », « gère mes prospects », « lance mes publicités ».

## Les 15 décisions d'architecture (résumé)

1. Un **Projet** est un objectif durable : plan à étapes + **critères d'acceptation**, espace de travail (`workspace/`), journal, registre de livrables, file d'approbations, budget. Tout vit sur disque : `runtime/projects/<ClientId>/<ProjectId>/`.
2. **Un seul écrivain** : Python (`dashboard/projects.py`) possède `state.json`, `approvals.json`, `deliverables.json`. Le moteur PowerShell n'écrit que dans `workspace/`, `spool/` et son `result.json`. Écritures atomiques (`_write_json_atomic`) sous verrou par projet.
3. Un **superviseur** (thread du processus serveur) fait avancer les projets : un sous-processus `pwsh` **par étape**, échéance douce 8 min (`Project-StepRunner.ps1`), arrêt dur 9 min. Durée totale d'un projet : des heures, sur des dizaines d'étapes.
4. L'étape réutilise **la boucle de l'adaptateur Anthropic**, extraite en bibliothèque commune (`Adapter-Common.ps1`), enrichie d'outils durables : `project_plan`, `workspace_*`, `request_approval`, `request_input`, `note_decision`, `step_complete`.
5. **Contexte frais à chaque étape** (jamais l'historique entier) : brief du projet + plan + résumé roulant + journal de décisions + rapports des étapes dont on dépend ; fichiers lus à la demande. Filet de sécurité dans l'étape : `clear_tool_uses_20250919` (vérifié dans la doc Anthropic).
6. **Modèle par phase** : planification et vérification sur le niveau fort (Opus 5.5, effort élevé), travail courant sur Sonnet 5.5, travail répétitif sur Haiku 5.5 (`core/ai/PROJECT-PHASES.json`).
7. **Aucune réussite sans preuve** : seul un VÉRIFICATEUR indépendant (contexte neuf, outils en lecture seule + contrôles automatiques typés) peut passer un critère à PASS, avec des preuves résolues par le moteur. Les critères typés (fichier présent, `site_check`, formules xlsx…) sont exécutés par le moteur lui-même, sans LLM.
8. **Validations sans fatigue** : toute action sortante devient un ARTICLE D'APPROBATION (quoi, contenu exact, pourquoi, risque) regroupé en lots ; le projet continue avec les étapes indépendantes et ne s'arrête que si une étape dépend d'une approbation. Exécution par le chemin existant `Confirm-Connector-Action.ps1`.
9. **Budget** : crédits mesurés au coût réel (`creditCostChf` = 0,0375 CHF par crédit, ce qui garantit la règle des 35 % par construction), plafond par projet, passerelle de quota **avant chaque étape**. Plafond du projet atteint = `BUDGET_REACHED` ; fenêtre d'usage atteinte = `WAITING_QUOTA`.
10. **Fenêtres d'usage comme Claude** : session glissante de 4 h + semaine de 7 jours, en plus du mensuel ; grand livre O(1) `runtime/usage/<ClientId>.json` avec `reserve/settle` atomiques ; un projet ne meurt jamais au quota : il attend (`WAITING_QUOTA`) et reprend seul au renouvellement ou dès une montée en gamme.
11. **Chloé = cheffe de projet** : décomposition par un modèle (registre des 17 Workers + compétences + coûts), une étape = un Worker, relais par `workspace/handoff/` et rapports, revue de cohérence inter-Workers ; l'ancien routeur reste en repli. Droits = ceux du forfait (Trio : 3 Workers embauchés + Chloé, elle dit lesquels lui manquent). File d'attente au lieu de refus.
12. **Atelier de sites** : outils de production + contrôles automatiques (`site_check`), **aperçu privé** servi sous `Content-Security-Policy: sandbox` sans `allow-same-origin`, URL à jeton, `noindex`, zip, publication seulement via les connecteurs du client après approbation ; **aucune page publique hébergée sur notre origine en v1**.
13. **Recettes** (`workers/<id>/recipes/*.json`) : définition de « terminé », étapes, contrôles, livrables, approbations, budget typique ; le moteur injecte la bonne recette à la planification. Évaluation chiffrée (taux de complétion, coût) contre le moteur actuel.
14. **Reprise sur redémarrage** : étapes idempotentes, battement de cœur, réapeur au démarrage, aucun état en mémoire seule.
15. **Dormant** : `BK_PROJECTS=0` par défaut, interrupteur global + pause par client, déploiement progressif.

---

## 1. Principes et définition de « terminé »

*(à approfondir)* Un objectif devient un PLAN avec CRITÈRES D'ACCEPTATION ; le Worker exécute des étapes jusqu'à ce que chaque critère soit VÉRIFIÉ ou qu'un VRAI blocage subsiste (besoin du client, approbation, identifiant, budget). Jamais « voici comment faire ». Modes de défaillance couverts : boucles infinies, coût qui s'envole, perte d'état au redémarrage, débordement de contexte, fatigue d'approbation, achèvement halluciné, outils périmés.

## 2. Machine à états et stockage

*(à approfondir)* Dossier `runtime/projects/<ClientId>/<ProjectId>/`. Statuts projet : `PLANNING, QUEUED, RUNNING, WAITING_APPROVAL, WAITING_INPUT, WAITING_QUOTA, VERIFYING, PAUSED, BUDGET_REACHED, DONE, FAILED, CANCELLED`. Plafonds de concurrence adaptés au serveur 2 vCPU / 3,8 Go.

## 3. Comment une étape s'exécute

*(à approfondir)* `Project-StepRunner.ps1 -InFile input.json -OutFile result.json`. Outils, espace de travail, passerelle bac à sable (Files API + `container_upload` + `$OUTPUT_DIR`), contexte, modèles par phase, `pause_turn`, reprises avec attente croissante.

## 4. Vérification

*(à approfondir)* Passe indépendante, contexte neuf, preuves par critère, tours de correction bornés (2), rapport final qui cite les preuves.

## 5. Validation humaine sans fatigue

*(à approfondir)* Articles d'approbation, lots, classes de risque, expiration, notifications (réutilise `mailer.send_email`).

## 6. Budget et sécurité

*(à approfondir)* Crédits, plafond CHF (`Mission-Cost.ps1`, `AI-PRICING.json`), `BK_PROJECTS=0`, pause par client, limites d'abus, `BUDGET_REACHED`, Solo/Trio, essai.

## 6b. Fenêtres d'usage (session 4 h, semaine, mois)

*(à approfondir)* `core/usage/USAGE-LIMITS.json`, `dashboard/usage.py`, `GET /api/usage`, `WAITING_QUOTA`.

## 6c. Chloé, déléguante et cheffe de projet

*(à approfondir)* Plan multi-Workers, relais, droits du forfait, file d'attente, échecs partiels.

## 7. Contrat d'API

*(à approfondir)* Routes `/api/projects/...`, JSON, codes d'erreur, limites de débit ; interface du lanceur PowerShell.

## 8. Atelier de sites (contrat)

*(à approfondir)* Outils, contrôles, aperçu isolé, zip, publication.

## 9. Recettes et évaluation (contrat)

*(à approfondir)* Format, familles, scénarios, rubriques, plafond de 25 USD.

## 10. Ordre de construction, frontières de modules, déploiement

*(à approfondir)* Six constructeurs, fichiers par constructeur, régions de `server.py` / `app.js`, tests, déploiement dormant, risques, décisions du propriétaire.
