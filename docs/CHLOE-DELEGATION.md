# Chloé délègue à tous les Workers (mode mission) et dirige les projets (mode projet)

Exigence C du propriétaire (2026-10-18) : Chloé, l'orchestratrice, doit pouvoir **déléguer et faire exécuter des tâches par TOUS les agents sans restriction** : pas de plafond accidentel, pas de routage par mots-clés seuls, délégation parallèle et séquentielle à plusieurs Workers avec relais de l'un à l'autre, étapes d'un projet confiées à des Workers différents, Chloé cheffe de projet. Les seules limites sont les **droits du forfait** et les **limites d'usage** du client.

Ce document décrit ce qui est construit et testé (branche `ws/chantier-chloe`). Le contrat d'ensemble reste `docs/AUTONOMY-ENGINE.md` (section 6c) ; les écarts sont listés à la fin.

## 1. Ce qui a changé, en bref

| Avant | Maintenant |
|---|---|
| Mots-clés (premier appariement), repli IA qui renvoyait seulement des identifiants | Un appel peu coûteux (Haiku 5.5) lit la demande et les **cartes des 17 Workers**, la découpe en sous-tâches (une par Worker) au **schéma dur** `BK-CHLOE-ROUTE-PLAN-V1`. Le code valide tout ; un seul nouvel essai avec la liste des erreurs ; repli sur l'ancien routeur. |
| Tous les Workers retenus recevaient **la même demande** | Chaque Worker reçoit **sa part** (consigne écrite par le routeur) et, s'il en dépend, le **résultat des Workers précédents** et leurs petits fichiers texte. |
| Parallèle imposé, aucun enchaînement | Le graphe `dependsOn` décide : indépendant = parallèle (borné), dépendant = séquence avec relais. |
| Réponses mises à la suite | Une **synthèse qui dit qui a fait quoi**, les fichiers et les actions à valider **par Worker**, ce qui a échoué et quoi faire, les écarts entre livrables. |
| `BK_MAX_WORKERS` retirait des Workers en silence ; 2 missions par client, refus au-delà | Le nombre de Workers n'est borné que par les **crédits utilisables maintenant** (mois, session, semaine) ; les Workers non traités sont **nommés** avec le moment du renouvellement ; le serveur occupé met en **file d'attente**, il ne refuse plus. |
| Un Worker qui échouait faisait échouer la mission | **Panne partielle** : les autres terminent, Chloé dit ce qui a échoué, ce qui n'a pas été lancé (et pourquoi) et propose la suite. |
| Aucun moyen de lancer un travail de plusieurs étapes | **Planificateur de projet** (`chloe/Invoke-Chloe-Plan.ps1`) : plan `BK-PROJECT-PLAN-V1` (critères mesurables, étapes avec un Worker propriétaire, coût estimé), validé par le code. Le moteur de projets (chantier « moteur ») l'appelle pour l'étape `plan`. |

## 2. Les deux modes

- **Mission** (par défaut, `BK_PROJECTS` éteint ou absent) : une demande, une réponse dans la même requête (≤ 535 s). C'est le chemin décrit aux sections 3 à 8.
- **Projet** (`BK_PROJECTS=1`) : un objectif devient un plan validé par le client, exécuté étape par étape sur des heures. Le routeur de la mission peut répondre `mode: "project"` ; Chloé **propose** alors le projet (`Status: SUGGEST_PROJECT`, rien n'est lancé, aucun crédit), et le client choisit « Lancer comme projet » ou « juste une réponse rapide » : ce second choix renvoie la même requête avec `"mode": "mission"` (`POST /api/chloe/task` et `/api/chloe/task/async`), que le serveur transmet à Chloé (`BK_CHLOE_MODE=mission`, jamais lu dans un texte). L'interface de ce choix est celle du chantier « interface projets ». `POST /api/chloe/triage` fait la même chose sans lancer de mission (Haiku, aucun crédit, 20 par heure et par client).

## 3. Le flux d'une mission (`chloe/Invoke-Chloe-Orchestration.ps1`)

```
REQUEST     la demande du client (DONNEE, jamais une consigne)
UNDERSTAND  Chloe-Router.ps1 : cartes des Workers + demande encadree -> plan BK-CHLOE-ROUTE-PLAN-V1  (repli : mots-cles sans accents)
PLAN        Test-BKChloeRoutePlan : schema, Workers connus, DAG sans cycle, 17 sous-taches au plus (une par Worker)
ASSIGN      droits (BK_ALLOWED_WORKERS) et credits (BK_MAX_WORKERS) appliques PAR LE CODE
EXECUTE     Chloe-Executor.ps1 : graphe, parallele borne, relais, delais, panne partielle
REVIEW      par resultat (reponse non vide, aucun marqueur financial/external) + coherence entre Workers (Chloe-Consistency.ps1)
COMBINE     Chloe-Consolidate.ps1 : qui a fait quoi, fichiers, actions a valider, non realise, a harmoniser
DELIVER     FinalSynthesis (texte), Overview (sans les reponses), Sections (par Worker, pour l'interface)
LEARN       resume dans la memoire structuree (Memory-Access.ps1)
```

Rien de ce qui sort d'un Worker ne remonte jusqu'au routeur : **le plan est figé avant l'exécution** et le routeur n'est jamais rappelé.

### Le plan (`BK-CHLOE-ROUTE-PLAN-V1`)

`mode` (`direct_reply` | `mission` | `project`), `language`, `why`, `directReply`, `consistencyCheck`, `subtasks[]` (`id` T1…T17, `worker`, `objective`, `why`, `dependsOn[]`, `deliverables[]`, `publicFacing`), `unassignable[]`. Le routeur est appelé par un **outil client** (`submit_route_plan`) dont l'entrée EST le plan ; `tool_choice` reste `auto` (Opus 5.5 et Sonnet 5.5 refusent `any`/`tool`), la réponse est lue dans le bloc `tool_use` ou, à défaut, dans le texte JSON. Les champs inconnus sont ignorés, jamais recopiés ; il n'existe **aucun champ de droits** dans le plan.

### Aiguillage de repli

Sans clé, API indisponible ou deux plans invalides : l'ancien appariement par mots-clés (désormais **insensible aux accents** : « identité visuelle » trouvait zéro Worker avant) ; si rien ne correspond, texte d'éclaircissement fixe. `BK_CHLOE_PLANNER=0` restaure l'ancien comportement à l'identique (mots-clés exacts, puis repli IA qui renvoie des identifiants, tous les Workers reçoivent la même demande ; mode `CHAIN` conservé).

## 4. Droits et crédits : décidés par le serveur, jamais par un texte

`dashboard/chloe_scope.py` (module pur, fonctions du serveur injectées) :

| Forfait | Chloé | Workers que Chloé peut déléguer | Si une partie relève d'un Worker absent |
|---|---|---|---|
| Essai | oui | les 17 | — |
| Solo | **non** (`PLANS_WITH_CHLOE = ("trio",)`) | le Worker embauché, depuis sa fiche | — |
| Trio | oui | les **3 embauchés** | Chloé **nomme** le Worker, dit ce qui lui revenait et **propose de l'embaucher** (`HireOffer`, boutons « Embaucher X ») ; sans cela Trio vendrait toute l'équipe au prix de trois |
| Équipe, Pro, Scale, Enterprise | oui | **les 17** | — |

Le propriétaire change la règle à deux endroits : `PLANS_WITH_CHLOE` (`dashboard/installations.py`) et la table `chloeDelegation` de `core/projects/PROJECT-LIMITS.json` (`"trio": "hired_only"`, défaut `"all"` ; lue si le fichier existe, sinon la valeur par défaut). Atlas (trading personnel du propriétaire) n'est jamais routable.

- **Droits** : `BK_ALLOWED_WORKERS` (posé par `server.py`) est la seule source. Les sous-tâches des Workers non inclus sont **retirées et nommées** (`NotIncludedWorkers`, `HireOffer`) ; si tout est hors forfait, `Status: WORKER_NOT_INCLUDED` et **aucune mission n'est lancée** (aucun crédit). Une sous-tâche dont le prérequis n'est pas inclus ne l'attend pas : sa consigne le lui dit et lui interdit de l'inventer.
- **Crédits** : `BK_MAX_WORKERS` = crédits utilisables maintenant ÷ coût du niveau (`CHLOE_SCOPE.mission_budget`). Source : les fenêtres d'usage (`USAGE.remaining(client).allowedNow`, le plus bas de session/semaine/mois) quand le service des limites d'usage est branché ET appliqué (`BK_USAGE_WINDOWS=1`) ; sinon le solde du mois. C'est l'adaptateur mince demandé : quand le service d'usage est branché, rien d'autre ne change. Les sous-tâches retenues sont les premières **dans l'ordre du graphe** (jamais une sous-tâche sans ses prérequis) ; les autres sont nommées avec l'heure du renouvellement (`BK_CHLOE_RESET_NOTE`, phrase fabriquée par le serveur, jamais recopiée). Projets activés : la synthèse propose aussi de lancer le tout comme projet (il attend les crédits et reprend seul). Un Worker qui n'a rien livré ne coûte rien (budget rendu).

## 5. Exécution : parallèle borné, relais, panne partielle (`chloe/Chloe-Executor.ps1`)

- Chaque sous-tâche tourne dans **son propre processus** (`Invoke-Chloe-WorkerCall.ps1`) par le **même chemin d'autorisation réel à 14 étapes** (`Invoke-Worker-AI.ps1`) que n'importe quel appel direct : aucun raccourci, aucun Gate contourné. Le jeton de session passe par l'environnement du processus, jamais par la ligne de commande ni un fichier.
- **Capacité (2 vCPU / 3,8 Go)** : `BK_CHLOE_PARALLEL` Workers à la fois pour une mission (2), `BK_CHLOE_SLOTS_GLOBAL` pour toutes les missions de Chloé (3, verrous de fichier libérés par le système si le processus meurt), pas de lancement sous 400 Mo de mémoire disponible. Un Worker qui ne trouve pas de place **attend** (file) ; il n'est reporté qu'après `BK_CHLOE_SLOT_WAIT_SEC` (300) sans rien en cours.
- **Délais** : la mission tient dans 535 s (le serveur coupe à 600 s). Aucun Worker n'est lancé s'il reste moins de 90 s ; chaque Worker reçoit un délai (`BK_MISSION_DEADLINE_SEC`, lu par l'adaptateur) qui lui fait rendre un résultat partiel avant la fin ; un Worker qui n'a pas rendu est coupé (arbre de processus) sans perdre les autres.
- **Relais** : une sous-tâche reçoit les résultats (texte, liste des fichiers, extraits de fichiers texte) de celles dont elle dépend, **encadrés comme des données** (`<worker_result untrusted="true">`, balises de fermeture neutralisées dans le texte). Une réponse « de secours » (fournisseur indisponible) n'alimente jamais le Worker suivant.
- **Espace de travail partagé** (même disposition que celui d'un projet, `docs/AUTONOMY-ENGINE.md` 2.1) : `runtime/chloe-runs/<ClientId>/<RunId>/{plan.json, progress.json, calls/, workspace/handoff/<Tn>.md, workspace/deliverables/<Tn>/, workspace/notes/}`. Supprimé avec le compte du client ; les missions de plus de 7 jours sont effacées.
- **Panne partielle** : un échec passager (délai, 429, 5xx) est retenté une fois s'il reste du temps ; un refus du Gate ne l'est jamais. Un Worker en échec bloque seulement ses dépendants (`BLOCKED`, `DEPENDENCY_FAILED`) ; la synthèse dit « X n'a pas abouti (raison). Les autres Workers ont terminé » et propose un message de suite prêt à envoyer (`ContinuePrompt`).
- **Cohérence** (`Chloe-Consistency.ps1`) : quand au moins deux Workers produisent des contenus pour le même public, un appel peu coûteux compare les livrables. Chaque écart doit citer **mot pour mot** un extrait de chaque livrable concerné, sinon il est écarté (aucun écart inventé). Informatif : ne change ni le statut, ni le plan, ni les droits. Gabarit partagé avec le moteur de projets : `chloe/prompts/consistency-review.md`.

## 6. Serveur : file d'attente au lieu de refus (`dashboard/server.py`)

`submit_task_async` : si le client ou le serveur est au plafond (`BK_ASYNC_MAX_PER_CLIENT` 2, `BK_ASYNC_MAX_GLOBAL` 6 — ces plafonds bornent ce qui **tourne**), la mission est mise **en file** (`status: QUEUED`, `queuePosition`), bornée (5 par client, 20 au total, 8 minutes d'attente) ; le seul refus restant est la file pleine. Une mission bloquée par le plafond de SON client ne retient pas celles des autres. `reap_async_jobs(boot=True)` interrompt aussi les missions en file. `GET /api/missions/async/<jobId>` d'une mission de Chloé en cours ajoute `progress.tasks` (Worker, statut ; aucun texte de Worker ni du client). `attach_pending_action` ajoute `workerId` : chaque carte « Confirmer / Annuler » est rangée sous son Worker.

## 7. Interface (`dashboard/app.js`, `style.css`)

`renderChloeResult` : un seul Worker sans incident = l'affichage d'avant. Plusieurs Workers, ou une partie qui n'a pas abouti : l'aperçu de Chloé (`Overview`) puis **une carte par Worker** (portrait, statut, ce qui lui était demandé, sa réponse repliable, ses fichiers, **ses** actions à valider), les boutons « Embaucher X » (`HireOffer`) et, pendant l'attente, la place dans la file et « Chloé coordonne : Lea ✓ · Emma … ». Le bloc de fichiers et la carte de confirmation du flux de mission en direct sont conservés (voir `loadActivity(…, { keepThread: true })`). Tout texte dynamique passe par `escapeHtml`.

## 8. Sécurité (règles non négociables, toutes testées)

1. Le texte du client, les réponses des Workers, les pages web et les fichiers sont des **données encadrées** (`client_request`, `worker_result`, `worker_file`, `deliverable`, `client_goal`, `client_memory`…) ; les balises de fermeture connues sont neutralisées dans le texte.
2. Le routeur ne voit **que** la demande et les cartes statiques ; il ne voit jamais une sortie de Worker.
3. Droits et crédits viennent de variables d'environnement posées par le serveur, **pas** du modèle ni d'un texte ; le plan n'a aucun champ de droits.
4. Toute action vers l'extérieur reste une carte de confirmation du client (`PENDING_CONFIRMATION`) ; Chloé ne la contourne pas.
5. Aucun secret dans un prompt, un journal, un fichier ; clé lue en mémoire seulement.
6. Isolation : tout est rangé par `ClientId` ; `runtime/chloe-runs/<ClientId>` part avec le compte.

## 9. Chloé cheffe de projet (`chloe/Chloe-Planner.ps1`, `chloe/Invoke-Chloe-Plan.ps1`)

Appelé par le moteur de projets pour les étapes `plan` et `replan` **à la place** du lanceur d'étape générique (une seule sortie structurée, pas de boucle d'outils : l'objectif, le profil et la mémoire du client sont fournis ; le plan est l'unique résultat).

```
pwsh -NoProfile -File chloe/Invoke-Chloe-Plan.ps1 -InFile <plan-input.json> -OutFile <plan-result.json>
Entrée  BK-CHLOE-PLAN-INPUT-V1  { goal, language, clientId, scope{chloe, allowed[], denied[{workerId, reason}], hireOffer},   <- dashboard/chloe_scope.py project_scope()
                                  usage{allowedNow, binding, session|week|month{remaining}, creditCostChf}, recipesBlock, inputs[], collaboration }
Sortie  BK-CHLOE-PLAN-RESULT-V1 { ok, source: "model"|"fallback", plan, errors[], warnings[], usage{input_tokens, output_tokens, api_calls, estimated_cost_usd, estimated_cost_chf}, attempts, model, fallbackReason }
Codes   0 résultat écrit (lire ok) · 10 entrée invalide · 20 erreur interne
```

- **Modèle** : phase `plan` (`core/ai/PROJECT-PHASES.json` → `levelRef` → `core/ai/LEVELS.json` ; à défaut Approfondi : Opus 5.5, effort élevé). Un appel, **un seul** nouvel essai avec la liste des erreurs de validation.
- **Prompt** : `chloe/prompts/plan.md` + les 17 cartes (les Workers hors forfait y sont marqués `[UNAVAILABLE for this client]`), la portée, la vue d'usage (« crédits utilisables maintenant : N » : un plan qui dépasse doit proposer une variante Essentiel), les recettes candidates (`recipesBlock`, fourni par le moteur).
- **Validation par le code** (`Test-BKProjectPlan`) : ≤ 40 étapes, ≤ 25 critères ; identifiants S1…/C1… ; chaque étape a un `worker` **de la portée du client** (un Worker indisponible ou inconnu = erreur renvoyée au modèle, avec l'instruction de mettre cette partie dans `unassignable`) ; `dependsOn` sans cycle ; chaque critère couvert par une étape ; un critère `auto` d'un type de contrôle inconnu devient `rubric` (avertissement) ; chemins relatifs sûrs (≤ 8 segments, pas de `..`, pas de fichier caché) ; une étape de **publication ou d'envoi vient en dernier** ; l'estimation contient toujours la somme des étapes ; au plus 3 questions bloquantes ; aucune donnée de droits ni de crédits recopiée.
- **Sortie** : `BK-PROJECT-PLAN-V1` + `delegation` + `unassignable` + `triage`. `delegation` = `{ lead:"chloe", workers[], rationale[{stepId, worker, why}], publicFacingSteps[], consistency{required, workers[]}, essentialVariant|null, hireOffer[] }`. `consistency.required` est vrai quand au moins **deux Workers différents** produisent du contenu pour le public : le moteur insère alors l'étape `verify` de portée `consistency` (gabarit `chloe/prompts/consistency-review.md`) et le critère implicite `C-coherence`. `hireOffer` et `essentialVariant` (étapes retirées + dépendantes, crédits recalculés) sont **calculés par le code**.
- **Repli** : modèle indisponible ou plan invalide deux fois → ancien routage IA puis mots-clés (sans accents) → plan minimal « une étape par Worker » (en parallèle, ou en chaîne si `collaboration: "CHAIN"`), un critère `rubric` générique, `plan.fallback = true` (affiché « plan simplifié »). Les parties qui relèvent de Workers hors forfait y sont dans `unassignable` avec l'offre d'embauche. Aucun Worker de la portée : `ok:false`, `NO_WORKER_IN_SCOPE`, aucun appel au modèle.
- **Guide de Chloé** : `chloe/identity/playbook.md` (mode mission, tel que le code fonctionne) ; `chloe/identity/playbook-projects.md` n'est lu que si `BK_PROJECTS=1` (`Get-WorkerSystemPrompt`, une seule ligne de chemin modifiée).

## 10. Réglages et interrupteurs

| Variable | Défaut | Rôle |
|---|---|---|
| `BK_CHLOE_PLANNER` | 1 | `0` = ancien routage, à l'identique |
| `BK_CHLOE_EXECUTOR` | processus | `inline` = les Workers tournent un par un dans le processus de Chloé |
| `BK_CHLOE_PARALLEL` / `BK_CHLOE_SLOTS_GLOBAL` | 2 / 3 | Workers simultanés par mission / sur tout le serveur |
| `BK_CHLOE_DEADLINE_SEC`, `_MIN_LAUNCH_SEC`, `_MIN_WORKER_SEC`, `_TAIL_SEC`, `_KILL_GRACE_SEC`, `_SLOT_WAIT_SEC` | 535, 90, 60, 40, 20, 300 | délais |
| `BK_CHLOE_PLAN_DEADLINE_SEC` | 450 | temps total du planificateur de projet (60 à 520) : aucun appel au modèle qui ne tiendrait pas dans ce qui reste, le repli prend le relais |
| `BK_CHLOE_CONSISTENCY` | auto | `0` coupe la relecture de cohérence ; `1` la force aussi au niveau Rapide |
| `BK_CHLOE_ROUTER_MODEL`, `BK_CHLOE_CONSISTENCY_MODEL`, `BK_CHLOE_PLANNER_MODEL` | Haiku 5.5 / Haiku (Sonnet à l'Approfondi) / phase `plan` | modèles (nom `claude-…` seulement) |
| `BK_CHLOE_MODE` | — | `mission` : le client a répondu « juste rapidement » |
| `BK_ASYNC_QUEUE_MAX_PER_CLIENT` / `_GLOBAL` / `_MAX_WAIT` | 5 / 20 / 480 s | file d'attente des missions en arrière-plan |

Variables posées par le serveur (jamais par un client) : `BK_ALLOWED_WORKERS`, `BK_MAX_WORKERS`, `BK_CHLOE_RESET_NOTE`, `BK_CHLOE_RUN_ID`, `BK_MISSION_LEVEL`, `BK_REPLY_LANG`.

## 11. Tests et mesures

Tout se lance dans WSL avec PowerShell 7 : `wsl -e python3 tests/chloe-delegation/run_all.py` (toutes les suites, une à la fois ; `--quick` saute la plus longue) ou `wsl -e python3 tests/chloe-delegation/test_<x>.py` (une suite ; chaque test copie le dépôt dans un dossier temporaire supprimé ensuite). Aucun réseau, aucun coût, aucun vrai secret : l'API est simulée par `tests/adapter-review/fake_api.ps1`, les Workers par `tests/chloe-delegation/stub_worker.ps1`.

| Suite | Ce qu'elle prouve |
|---|---|
| `test_router.py` | schéma dur et plans invalides refusés (un par règle) avec une raison en français ; un nouvel essai avec la liste des erreurs ; repli ; texte du client encadré (balise de fermeture neutralisée, Worker hors liste refusé) ; langue du client transmise ; aucun champ de droits |
| `test_orchestration.py` | plan en plusieurs Workers, parallèle puis relais (données encadrées, balise de fermeture glissée dans une réponse neutralisée) ; 17 Workers sans plafond ; parallélisme borné par mission et entre missions ; Trio (offre d'embauche) ; prérequis non embauché ; rien de lancé hors forfait ; **une sortie de Worker n'élargit jamais droits ni plan** ; crédits épuisés en cours de chaîne ; panne partielle ; nouvel essai ; Worker coupé au délai ; revue qui rejette une réponse vide ; actions à valider et fichiers par Worker ; secours `inline` ; `PlanOnly` / `EmitPlan` ; projet proposé seulement si activé ; cohérence (un écart inventé est écarté) ; coût des appels de Chloé comptabilisé ; interrupteur d'ancien routage |
| `test_scope_server.py` | portée par forfait (Essai, Équipe, Pro, Scale, Enterprise = 17 ; Trio = 3 + offre ; Solo = pas de Chloé) ; règle Trio changeable en un endroit ; crédits et fenêtres d'usage ; environnement donné à Chloé et à rien d'autre ; file d'attente (position, plafond d'un client sans effet sur les autres, 8 minutes, reaper au démarrage) ; suivi en direct sans texte de Worker ; suppression du compte |
| `test_planner.py` | planificateur de projet : règles de validation du plan (une par cas), appel au modèle fort avec équipe + portée + crédits, Trio (Worker absent nommé, offre d'embauche), repli, absence de Chloé, injection par l'objectif/le profil, variante Essentiel, contrat de ligne de commande, bascule du guide `playbook-projects.md` |
| `test_ui_render.js` (`node tests/chloe-delegation/test_ui_render.js`) | le VRAI code d'interface (bloc CHLOE-TEAM de `app.js`) dans un faux DOM : un Worker = l'affichage d'avant avec fichiers et carte de validation ; plusieurs = une carte par Worker avec ses fichiers et ses actions à valider ; boutons « Embaucher X » ; file d'attente et avancement ; **rien n'entre dans la page sans être échappé** |
| `test_cards.py` | les cartes sont exactement ce que le générateur produit des sources ; 17 cartes, jamais Atlas ; départages du guide = listes `notFor` |
| `test_routing_accuracy.py` | 46 demandes étiquetées à la main (17 Workers, 5 langues, paraphrases, départages, plusieurs métiers, salutations, textes qui détournent le routeur) ; banc d'essai vérifié sur cassette fabriquée ; **référence chiffrée réelle des mots-clés seuls** ; comparaison ancien / nouveau routeur sur la cassette d'enregistrement réel (voir ci-dessous) |

**Mesure réelle, hors ligne, des mots-clés seuls** (46 demandes, 2026-10-25) : exact 0,35, rappel 0,49, précision 0,82 ; insensible aux accents : exact 0,39, rappel 0,56. Les demandes à plusieurs métiers sont presque toutes mal servies (une réussite sur sept).

**Enregistrement réel du routeur à modèle : NON FAIT.** `tests/chloe-delegation/record_routing.ps1` a été lancé une fois sur Haiku 5.5 (plafond 1,50 USD) : l'API Anthropic a refusé la toute première requête (HTTP 400, « Your credit balance is too low »), le script s'est arrêté, **0 USD dépensé**. Quand le compte aura du crédit : `pwsh -NoProfile -File tests/chloe-delegation/record_routing.ps1 -Out tests/chloe-delegation/routing_cassette.json -Model claude-haiku-5-5 -CapUsd 1.5 -SecretsRoot <dépôt principal>` (environ 0,05 USD pour les 46 demandes, ancien et nouveau routeur) ; les 7 tests `RecordedAccuracy` s'activent seuls et vérifient que le nouveau routeur bat l'ancien (F1, exact), couvre ≥ 90 % des métiers demandés, ne désigne jamais Atlas ni plus de 6 Workers, répond sans Worker aux salutations, laisse des parties en parallèle. Si le prompt du routeur ou les mots-clés changent, la cassette est périmée et le test le dit.

## 12. Écarts avec le contrat et décisions laissées au propriétaire

- **Interface du planificateur** : `docs/AUTONOMY-ENGINE.md` 6c.3 dit que `Invoke-BKChloePlan` « s'exécute comme l'étape `plan` du moteur » ; la forme retenue est un script autonome (`Invoke-Chloe-Plan.ps1`, section 9) que `projects.py` lance pour `plan`/`replan` au lieu de `Project-StepRunner.ps1`. Les champs `delegation.{lead, workers, rationale[], publicFacingSteps[], consistency, essentialVariant, hireOffer}` précisent l'objet `delegation` que le contrat laissait ouvert (`CONTRACT-CHANGE`). La validation Python (`projects.validate_plan`) du moteur reste la seconde ligne de défense.
- **Tests** : dans `tests/chloe-delegation/` (consigne du chantier), et non `tests/chloe-projects/`.
- **Règle Trio / Solo / Essai** : lecture par défaut du contrat (section 4) ; le propriétaire peut la changer à deux endroits.
- **Plafonds de mission non touchés** : 535 s par mission, 2 missions qui tournent par client et 6 au total (`ASYNC_MAX_*`) : ce sont des bornes de capacité du petit serveur, pas des plafonds de Workers ; le travail plus long relève du mode projet.
- **Le routeur appelle le modèle à chaque mission** (environ 3 000 jetons d'entrée, 0,0003 à 0,0005 USD sur Haiku 5.5) : coût de Chloé, jamais facturé en crédits au client.
