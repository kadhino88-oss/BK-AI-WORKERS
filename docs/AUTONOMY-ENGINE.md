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
14. **Reprise sur redémarrage** : étapes idempotentes, battement de cœur, reaper au démarrage, aucun état en mémoire seule.
15. **Dormant** : `BK_PROJECTS=0` par défaut, interrupteur global + pause par client, déploiement progressif.

---

## 1. Principes et définition de « terminé »

### 1.1 Ce que « terminé » veut dire

Un objectif devient un **PLAN** avec des **CRITÈRES D'ACCEPTATION**. Le Worker exécute des étapes jusqu'à ce que **chaque critère soit VÉRIFIÉ** ou qu'un **VRAI blocage** subsiste. Le résultat n'est jamais « voici comment faire » : c'est le livrable, vérifié, ou une demande précise et unique de ce qui manque.

Un projet est `DONE` si et seulement si, simultanément :

1. chaque critère du plan est `PASS`, avec au moins une **preuve résolue par le moteur** (fichier présent et non vide, résultat d'un contrôle automatique enregistré, page de l'aperçu récupérée par `preview_fetch`, ligne de journal de connecteur) ;
2. chaque livrable déclaré existe dans `workspace/` (taille > 0) et figure au registre `deliverables.json` ;
3. aucun article d'approbation `PENDING` n'est nécessaire à un livrable requis : les actions sortantes approuvées sont `EXECUTED`, les autres `REJECTED` ou `EXPIRED` avec l'accord explicite du client (« accepter en l'état ») ;
4. le rapport final (`final-report.md`) existe et cite les preuves.

**Vrais blocages** (liste fermée, ils produisent un statut d'attente nommé, jamais un abandon) :

| Code `waitingFor` | Statut projet | Exemple |
|---|---|---|
| `INPUT` | `WAITING_INPUT` | donnée que seul le client possède (identifiant, choix de marque, texte juridique, nom de domaine) |
| `PLAN_VALIDATION` | `WAITING_INPUT` | le plan et son coût estimé attendent le « go » du client |
| `APPROVAL` | `WAITING_APPROVAL` | une étape dépend d'une action sortante non encore validée |
| `CONNECTOR` | `WAITING_INPUT` | connecteur requis non connecté ou expiré (`CONNECTOR_MISSING`) |
| `CRITERIA_FAILED` | `WAITING_INPUT` | critères encore en échec après 2 tours de correction : le client choisit (guider, accepter en l'état, annuler) |
| `QUOTA` | `WAITING_QUOTA` | fenêtre de session/semaine/mois atteinte : reprise automatique |
| `BUDGET` | `BUDGET_REACHED` | plafond de crédits du projet atteint : le client le relève ou accepte l'état partiel |

**Ne sont PAS des blocages** (le prompt d'étape l'interdit explicitement, section 3.5) : « je ne sais pas comment », « c'est long », « il faudrait vérifier » (on vérifie), « voici les étapes à suivre » (on les fait), une recherche à refaire, un fichier à produire, un choix à faible enjeu (on prend l'option la plus courante et on l'étiquette comme hypothèse, règle déjà en vigueur dans `Build-WorkerSystemPrompt.ps1`).

### 1.2 Le plan (schéma `BK-PROJECT-PLAN-V1`)

```json
{
  "schema": "BK-PROJECT-PLAN-V1",
  "version": 1,
  "goal": "Créer le site vitrine de mon cabinet de physiothérapie à Lausanne, FR + EN",
  "language": "fr",
  "recipeId": "lucas/site-vitrine-pro",
  "assumptions": [{"id": "A1", "text": "5 pages : accueil, soins, équipe, tarifs, contact (hypothèse la plus courante pour un cabinet)"}],
  "criteria": [
    {"id": "C1", "text": "Le site contient les 5 pages en FR et EN, sans lien cassé", "kind": "auto",
     "check": {"type": "site_check", "profile": "vitrine", "must": ["links", "lang_parity", "meta"]}},
    {"id": "C2", "text": "Chaque page a un titre (30-60 car.) et une description (70-160 car.)", "kind": "auto",
     "check": {"type": "site_check", "must": ["meta"]}},
    {"id": "C3", "text": "Le ton est professionnel et rassurant, sans promesse médicale non étayée", "kind": "rubric",
     "rubric": "Aucune promesse de guérison ; aucun chiffre ou témoignage inventé ; vouvoiement ; cohérent avec la fiche du client."}
  ],
  "steps": [
    {"id": "S1", "title": "Cadrage et arborescence", "worker": "lucas", "goal": "…", "dependsOn": [],
     "criteriaIds": ["C1"], "inputs": [], "expectedOutputs": ["site/ARBORESCENCE.md"], "effort": "normal",
     "connectors": [], "estimateCredits": 6},
    {"id": "S2", "title": "Charte graphique et styles", "worker": "lea", "goal": "…", "dependsOn": ["S1"],
     "expectedOutputs": ["site/assets/style.css", "site/assets/logo.svg"], "effort": "normal", "estimateCredits": 10},
    {"id": "S3", "title": "Textes FR des 5 pages", "worker": "emma", "dependsOn": ["S1"], "estimateCredits": 12},
    {"id": "S4", "title": "Pages HTML FR", "worker": "lucas", "dependsOn": ["S2", "S3"], "estimateCredits": 18},
    {"id": "S5", "title": "Traduction EN et parité", "worker": "emma", "dependsOn": ["S4"], "effort": "bulk", "estimateCredits": 8},
    {"id": "S6", "title": "SEO de base (titres, méta, balisage)", "worker": "seoya", "dependsOn": ["S5"], "estimateCredits": 8}
  ],
  "estimate": {"creditsMin": 70, "creditsMax": 140, "hoursMin": 1.5, "hoursMax": 4},
  "needsFromClient": [
    {"id": "Q1", "question": "Adresse, horaires, numéro de téléphone exacts ?", "blocking": false,
     "default": "Champs « [À COMPLÉTER : adresse] » à remplir avant mise en ligne"}
  ],
  "risks": ["Les mentions légales exigent des données de l'entreprise que seul le client possède."]
}
```

Règles du plan, appliquées par le moteur (pas par la bonne volonté du modèle) : au plus **40 étapes** et **25 critères** ; chaque étape a un `worker` valide dans la portée du client (section 6c) ; `dependsOn` forme un graphe sans cycle (vérifié à la sauvegarde) ; chaque critère est couvert par au moins une étape (`criteriaIds`) ; chaque critère `kind:"auto"` a un `check` d'un type connu du moteur (`file_exists`, `file_contains`, `site_check`, `xlsx_check`, `docx_check`, `csv_check`, `json_schema`, `approval_executed`), sinon il devient `rubric`. Un critère `rubric` porte une grille écrite (« rubric ») que le vérificateur applique.

### 1.3 Modes de défaillance et défense

| Mode | Défense | Section |
|---|---|---|
| Boucle infinie (dans une étape ou au niveau du projet) | détecteur d'appels d'outils identiques (3 fois = avertissement, puis arrêt de l'étape) ; au plus 3 tentatives par étape ; 120 étapes et 3 replanifications par projet ; détecteur « sans progrès » (3 étapes de suite sans changement de `workspace/` ni de plan = `PAUSED`, raison `NO_PROGRESS`) ; durée maximale par projet | 2.8, 3.8 |
| Coût qui s'envole | plafond CHF par étape (`Mission-Cost.ps1` déjà existant), plafond de crédits par projet, passerelle de quota avant CHAQUE étape, réservation puis règlement | 6, 6b |
| Perte d'état au redémarrage | état sur disque seul ; étapes idempotentes ; reaper au démarrage ; aucune donnée métier en mémoire | 2.7 |
| Débordement de contexte | contexte frais par étape (≤ 60 000 jetons visés), fichiers lus par morceaux, résumé roulant, `clear_tool_uses` dans l'étape | 3.6 |
| Fatigue d'approbation | articles groupés en lots, étapes indépendantes poursuivies, résumés par e-mail espacés, classes de risque | 5 |
| Achèvement halluciné | `step_complete` exige des preuves ; seul le vérificateur passe un critère à `PASS` ; preuves résolues par le moteur | 4 |
| Outils périmés | liste des connecteurs reconstruite à CHAQUE étape ; contrôle préalable `CONNECTOR_MISSING` ; une page ou un fichier de l'espace de travail relu reste une DONNÉE | 3.4, 3.9 |
| Injection par contenu web / fichiers | règle `UNTRUSTED CONTENT` déjà dans le prompt commun ; outils d'écriture sans effet externe ; toute action sortante passe par une approbation humaine | 5, 6 |
| Dérive de périmètre | les étapes ne peuvent ajouter que 8 étapes (`project_plan add_step`) ; tout changement d'objectif passe par une replanification visible du client | 3.3 |

## 2. Machine à états et stockage

### 2.1 Arborescence (par projet)

```
runtime/projects/<ClientId>/<ProjectId>/          ProjectId = PRJ-<32 hex MAJUSCULES>, ClientId validé (CLI-CUST-XXXXXXXX ou CLI-DASHBOARD)
  state.json            statut, plan courant (copie), budget, compteurs, seq, battement de cœur   [écrit par Python SEUL]
  plan.json             plan courant + plans précédents (plan.history[])                           [Python]
  events.jsonl         journal append-only : {"seq","ts","type","stepId?","data"} ; alimente /progress [Python]
  inbox.jsonl          messages du client au Worker en cours de projet                            [Python]
  approvals.json       file d'approbation (section 5)                                             [Python]
  deliverables.json    registre des livrables {path, title, kind, stepId, bytes, sha256, createdUtc} [Python]
  decisions.jsonl      journal de décisions {ts, stepId, decision, why}                           [Python, alimenté par spool]
  summary.md           résumé roulant (≤ 6 000 caractères), réécrit à la fin de chaque étape      [Python, depuis step_report]
  final-report.md      rapport final cité les preuves (étape `consolidate`)
  steps/<StepId>/<attempt>/
      input.json        entrée du lanceur (section 7.7)                                           [Python]
      context.md        contexte assemblé (≤ ~60 000 jetons)                                      [Python]
      result.json       sortie du lanceur                                                         [lanceur]
      cost.json         cumul des coûts mis à jour APRÈS CHAQUE appel API                          [lanceur]
      files-api.json    identifiants des fichiers Files API créés (pour nettoyage)                [lanceur]
      runner.log        journal sans secret (pas de contenu client brut au-delà de 200 caractères) [lanceur]
  verification/<round>/ verification.json, checks/*.json                                           [Python + vérificateur]
  spool/                articles d'approbation, notes de décision, mises à jour de résumé          [lanceur → ingéré par Python]
  workspace/            fichiers du projet (inputs/, handoff/, site/, deliverables/, data/, …)    [outils workspace_*]
```

`workspace/` est la seule zone partagée avec le lanceur et les outils. Conventions de dossiers : `inputs/` (fichiers fournis par le client), `handoff/<StepId>.md` (rapport de chaque étape, lu par les étapes suivantes), `deliverables/` (ce qui est livré au client), `data/` (tableurs, CSV intermédiaires), `site/` (atelier de sites, section 8), `notes/`.

### 2.2 `state.json` (écrit uniquement par `projects.py`)

```json
{
  "schema": "BK-PROJECT-STATE-V1",
  "projectId": "PRJ-9F1C…", "clientId": "CLI-CUST-1A2B3C4D", "title": "Site vitrine du cabinet",
  "goal": "…", "leadWorker": "chloe", "recipeId": "lucas/site-vitrine-pro", "language": "fr",
  "createdUtc": "2026-10-20T08:00:00Z", "startedUtc": null, "finishedUtc": null, "updatedUtc": "…",
  "status": "RUNNING", "waitingFor": null, "statusReason": null, "resumeAtUtc": null,
  "seq": 187,
  "level": "equilibre",
  "autoStart": false,
  "planVersion": 2,
  "steps": {
    "S1": {"status": "DONE",    "attempts": 1, "worker": "lucas", "startedUtc": "…", "finishedUtc": "…", "credits": 5, "summary": "Arborescence validée…"},
    "S4": {"status": "RUNNING", "attempts": 1, "worker": "lucas", "pid": 4412, "startedUtc": "…", "beatUtc": "…", "reservationId": "RSV-…"}
  },
  "budget": {"creditsCap": 180, "creditsCharged": 41, "chfCeiling": 6.75, "chfSpent": 1.52,
             "estimate": {"creditsMin": 70, "creditsMax": 140}},
  "counters": {"stepsRun": 6, "replans": 0, "verifyRounds": 0, "noProgress": 0, "apiRetries": 1, "approvalsQueued": 0},
  "scope": {"allowedWorkers": ["lucas", "lea", "emma", "seoya"], "deniedWorkers": []},
  "owner": {"supervisorBoot": "2026-10-20T07:55:00Z"}
}
```

`state.json` ne contient ni secret, ni contenu de page web brut, ni paramètres complets d'action (ceux-ci sont dans `approvals.json`, masqués à l'affichage comme `_safe_action_params`).

### 2.3 Statuts du projet

| Statut | Sens | Qui y entre | Sorties possibles |
|---|---|---|---|
| `PLANNING` | l'étape `plan` (modèle fort) rédige le plan et les critères | création | `WAITING_INPUT` (`PLAN_VALIDATION`, si pas d'`autoStart`), `RUNNING`, `FAILED` |
| `QUEUED` | prêt à démarrer, en attente d'une place (plafonds de la section 2.5) ; **on met en file, on ne refuse pas** | création/reprise si plafond atteint | `PLANNING`, `RUNNING` |
| `RUNNING` | au moins une étape prête ou en cours | « go », reprise | `WAITING_*`, `VERIFYING`, `PAUSED`, `BUDGET_REACHED`, `FAILED`, `CANCELLED` |
| `WAITING_APPROVAL` | plus aucune étape indépendante possible, au moins une dépend d'une approbation `PENDING` | superviseur | `RUNNING` (décision du client), `CANCELLED` |
| `WAITING_INPUT` | question bloquante, plan à valider, connecteur manquant, critères en échec | outil `request_input`, superviseur | `RUNNING` (réponse du client), `CANCELLED` |
| `WAITING_QUOTA` | fenêtre d'usage atteinte ; `resumeAtUtc` = fin de la fenêtre qui borne | passerelle de quota | `RUNNING` (reprise automatique ou montée en gamme), `CANCELLED` |
| `VERIFYING` | passe de vérification indépendante en cours | superviseur (jalon ou fin) | `RUNNING` (étapes de correction), `DONE`, `WAITING_INPUT` |
| `PAUSED` | pause demandée par le client, par le propriétaire (par client), ou raison technique (`NO_PROGRESS`, `API_UNAVAILABLE`, `INSTALLATION_PAUSED`) | client/superviseur | `RUNNING`, `CANCELLED` |
| `BUDGET_REACHED` | plafond de CRÉDITS DU PROJET atteint (différent d'une fenêtre d'usage) ; livrables partiels conservés | passerelle de budget | `RUNNING` (plafond relevé), `DONE` (« accepter en l'état »), `CANCELLED` |
| `DONE` | définition du 1.1 satisfaite (ou acceptée en l'état avec `acceptedGaps[]`) | superviseur | terminal |
| `FAILED` | erreur non récupérable (3 tentatives d'une étape critique, plan impossible) ; état partiel conservé | superviseur | `RUNNING` (via « réessayer »), `CANCELLED` |
| `CANCELLED` | annulé ; l'espace de travail reste téléchargeable 7 jours | client | terminal |

Toute transition passe par **une seule fonction** `ProjectStore.transition(project_id, new_status, reason, **fields)` qui vérifie la table ci-dessus (transition interdite = `InvalidTransition`), incrémente `seq`, ajoute un événement à `events.jsonl` et déclenche les notifications (section 5.6).

### 2.4 Statuts d'une étape

`PENDING` (dépendances non satisfaites) → `READY` → `RUNNING` → `DONE` | `PARTIAL` (arrêtée au plafond de coût ou à l'échéance : relancée en continuation) | `FAILED` (3 tentatives) | `SKIPPED` (devenue inutile après replanification) | `BLOCKED` (`reason`: `APPROVAL`, `INPUT`, `QUOTA`, `CONNECTOR`, `INSTALLATION_PAUSED`, `WORKER_NOT_INCLUDED`). `READY` est dérivé : toutes les dépendances sont `DONE` (ou `PARTIAL` marquée « suffisante »), toutes les approbations exigées (`requiresApprovalsFrom`) sont `EXECUTED`.

### 2.5 Superviseur, concurrence, file d'attente

Le superviseur (`ProjectSupervisor`, un thread démon démarré dans le bloc `__main__` de `server.py`) tourne toutes les **5 s** (et immédiatement sur un « coup de coude » : réponse du client, décision d'approbation, changement de forfait). À chaque tick, pour chaque projet `PLANNING|RUNNING|VERIFYING|QUEUED|WAITING_QUOTA` :

1. si `BK_PROJECTS=0` ou projet/client en pause → ne rien lancer ;
2. si `WAITING_QUOTA` et `now ≥ resumeAtUtc` (ou `usage.remaining` dit que ça passe maintenant) → `RUNNING` ;
3. nettoyage (reap) des étapes `RUNNING` sans battement (2.7) ;
4. calculer les étapes `READY`, les trier (priorité : plan/vérification, puis chemin critique, puis ancienneté) ;
5. pour chaque étape prête, tant que les plafonds laissent une place : **passerelle** (section 6b.5, `usage.reserve`), préparation de `input.json`/`context.md`, lancement du sous-processus, état `RUNNING` ;
6. si aucune étape n'est prête ni en cours : choisir l'état d'attente (`WAITING_APPROVAL` > `WAITING_INPUT`), ou `VERIFYING`, ou `DONE`.

**Plafonds** (fichier `core/projects/PROJECT-LIMITS.json`, réglables ; le serveur est un 2 vCPU / 3,8 Go partagé) :

| Plafond | Défaut | Variable |
|---|---|---|
| Lanceurs d'étape simultanés, global | **2** | `BK_PROJECT_STEPS_GLOBAL` |
| Lanceurs simultanés par client | **1** (Scale/Enterprise : 2) | `BK_PROJECT_STEPS_PER_CLIENT` |
| Projets actifs (`PLANNING/RUNNING/VERIFYING/WAITING_*`) par client | Essai 0 · Solo 1 · Trio 1 · Équipe 2 · Pro 3 · Scale 6 · Enterprise 10 | table `activeProjects` |
| Projets en file (`QUEUED`) par client | 3 | `queuedProjects` |
| Création de projets par client et par jour | Solo 3 · Trio 5 · Équipe 8 · Pro 12 · Scale 30 | `createPerDay` |

Ces lanceurs sont **en plus** des 6 missions asynchrones (`ASYNC_MAX_GLOBAL`) : pire cas 8 processus `pwsh` (environ 250 Mo chacun) ; si la mémoire disponible (`/proc/meminfo`, `MemAvailable`) passe sous 700 Mo, le superviseur ne lance plus d'étape (elle reste `READY`, la file s'allonge). Quand une place manque : le projet ou l'étape passe en `QUEUED` avec `queuePosition` visible dans `/progress` — **jamais un refus**, sauf dépassement du nombre de projets en file (`PROJECT_LIMIT_REACHED`, HTTP 429, avec le nombre de places libres et la montée en gamme).

### 2.6 Écritures, verrous, événements

- **Un seul écrivain par fichier** (tableau 2.1). Le lanceur PowerShell n'écrit jamais `state.json` ; il lit `input.json`, écrit `result.json`, `cost.json`, `spool/*.jsonl` et `workspace/`. C'est ce qui évite la corruption observée le 2026-09-28 (`docs/` incident de concurrence, mémoire du propriétaire).
- Verrou par projet : `threading.RLock` du `ProjectStore` (dictionnaire `project_id → RLock`, créé sous un verrou global court), **plus** un fichier `.lock` contenant `{pid, bootUtc}` pour détecter deux processus serveur simultanés (déploiement qui se chevauche) : le second refuse d'écrire et journalise `PROJECT_LOCK_CONFLICT`.
- Écriture : `_write_json_atomic` (fichier temporaire du même dossier + `os.replace` + `fsync`). Les fichiers `.jsonl` sont en ajout seul avec `fsync` ; une ligne illisible (coupure) est ignorée à la lecture.
- `seq` est un entier croissant par projet ; `GET /progress?since=<seq>` renvoie les événements `seq > since` (7.3). Un événement = un changement visible pour le client (statut, étape terminée, article d'approbation créé, livrable ajouté, message).

### 2.7 Reprise après redémarrage, battement de cœur, reaper

- Le lanceur met à jour `cost.json` après chaque appel API ; le superviseur écrit `steps.<id>.beatUtc` toutes les 20 s tant que le sous-processus répond (`proc.poll() is None`).
- **Au démarrage** (`ProjectSupervisor.reap(boot=True)`, appelé à côté de `reap_async_jobs(boot=True)`) : pour chaque projet non terminal, chaque étape `RUNNING` dont le processus n'existe plus est marquée `INTERRUPTED` : le coût déjà cumulé dans `cost.json` est **réglé** (`usage.settle`), la tentative compte (`attempts += 1`), l'étape redevient `READY` avec la note « reprise après interruption » (le lanceur voit `input.json.resumeNote` et le contenu déjà présent dans `workspace/`). Les processus orphelins (fichier `steps/<id>/<n>/pid`) sont arrêtés (`taskkill /T` ou `kill -TERM` du groupe).
- **À l'exécution** (chaque tick) : étape `RUNNING` sans battement depuis 120 s et sans processus = même traitement ; processus vivant mais au-delà de l'arrêt dur (540 s) = arrêt du groupe de processus, étape `PARTIAL` (résultat partiel lu depuis `workspace/` + `cost.json`), non comptée comme échec.
- Les étapes sont **idempotentes par construction** : un livrable est identifié par son chemin ; une nouvelle tentative lit d'abord `workspace/` et `handoff/`, ne refait pas ce qui existe (consigne du prompt d'étape, section 3.5) ; l'écriture d'un article d'approbation est dédupliquée par `(stepId, connectorId, operation, sha256(params))`.
- Les articles d'approbation `EXECUTED` ne sont jamais ré-exécutés : l'exécution écrit `status=EXECUTING` (avec identifiant d'exécution) **avant** l'appel au connecteur et `EXECUTED`/`FAILED` après ; un `EXECUTING` trouvé au démarrage devient `UNKNOWN_CHECK_MANUALLY` (affiché au client, jamais rejoué : un double envoi est pire qu'une attente).

### 2.8 Durée, inactivité, rétention

- **Étape** : échéance douce **480 s** (le lanceur cesse de lancer de nouveaux appels et finalise), arrêt dur **540 s**. Appel API individuel : `callTimeoutSec` de la phase.
- **Projet** : mesuré en heures. `maxDurationHours` par plan (Solo/Trio 72 h de projet actif, Équipe/Pro 168 h, Scale/Enterprise 336 h ; les temps `WAITING_*` ne comptent pas). Un projet `WAITING_INPUT/APPROVAL` sans réponse depuis **14 jours** passe `CANCELLED` (raison `IDLE_EXPIRED`) après deux rappels (J+3, J+10) ; `WAITING_QUOTA` n'expire pas (la reprise est automatique).
- **Rétention** : projets terminés (`DONE/CANCELLED/FAILED`) : `workspace/` conservé **90 jours**, puis purgé (le journal et le rapport final restent 12 mois, sans fichiers). Le client peut supprimer immédiatement (`DELETE /api/projects/<id>`). Suppression de compte : `shutil.rmtree(runtime/projects/<ClientId>)` ajouté à `_purge_client_mission_artifacts`.
- **Disque** : par projet 100 Mo (Scale/Enterprise 300 Mo), par client 1 Go (Scale 5 Go) ; au-delà, `workspace_write` renvoie `WORKSPACE_FULL` au modèle (qui supprime ou compresse) et l'API renvoie `413`.

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
