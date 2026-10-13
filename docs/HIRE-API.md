# Offre « Worker à l'unité » : API d'embauche et d'installation

Décision du 2026-10-12 : vendre **un Worker seul** (comme Delos ou Limova) et l'**installer chez le client selon ses compétences**, avec validation humaine de toute action vers l'extérieur. Ce document décrit le serveur (`dashboard/server.py`, `dashboard/installations.py`) ; l'interface s'appuie dessus. Les profils d'installation sont dans `workers/<id>/install-profile.json`.

## Forfaits

| Forfait | Emplacements | Chloé | Crédits (provisoires) | Prix recommandé (CHF) |
|---|---|---|---|---|
| `solo` | 1 Worker au choix | non | 250 | 29 / mois, 290 / an |
| `trio` | 3 Workers au choix | oui, en plus des 3 | 500 | 59 / mois, 590 / an |
| `equipe` | tous les Workers | oui | 900 | 99 / mois, 990 / an |
| `essai`, `pro`, `scale`, `enterprise` (et `starter`, `business`, forfaits hérités) | tous les Workers | oui | voir `docs/PRICING.md` | voir `docs/PRICING.md` |

- Pas de missions illimitées : quand le pot de crédits est vide, `402 SUBSCRIPTION_REQUIRED` comme pour tous les forfaits, et le client passe au forfait supérieur.
- Grille de prix et modèle de quota (quota MENSUEL fixe, jamais illimité, forfait suivant quand il est atteint) : `docs/PRICING.md`. Les crédits ci-dessus sont ceux validés par le propriétaire le 2026-10-12.
- Quand Stripe est configuré, `POST /api/billing/plan` ouvre une vraie Checkout Session pour `solo`, `trio`, `equipe`, `pro` et `scale` (montant du catalogue en CHF, annuel = 10 mois) ; le forfait n'est activé qu'après le paiement vérifié côté serveur. Sans Stripe, il répond `403 PLAN_BY_INVOICE` pour **chacun de ces cinq forfaits** (aucune bascule gratuite en libre-service, Pro et Scale compris) : le propriétaire active `solo` et `trio` après facture réglée (`POST /api/admin/grant-workers`), `equipe`, `pro`, `scale` et `enterprise` par `POST /api/admin/set-plan`. Stripe configuré mais injoignable (pont en erreur, délai de 30 s dépassé) : `503 STRIPE_UNAVAILABLE`, rien ne change. Seul le compte du propriétaire peut simuler un changement de forfait sans Stripe, pour tester le parcours.
- Le propriétaire (`CLI-DASHBOARD`) et l'essai public ne sont jamais restreints.
- L'état vit dans le fichier de facturation du client (`core/billing/data/<ClientId>.json`) : `planId`, `gridVersion`, `hiredWorkers` (liste), `workerSwaps`, `lastWorkerSwapAtUtc`, et pour la période payée `paidUntilUtc`, `cancelAtPeriodEnd`, `billingInterval`, `stripeSessions` (voir plus bas).

## Période payée, renouvellement et résiliation

Les **crédits** se renouvellent chaque mois tant que le forfait est valide (fenêtre ancrée sur l'activation, `docs/PRICING.md` §3). Ce qui décide si le forfait est encore **valide** :

| Origine du forfait | Fin de validité |
|---|---|
| Abonnement Stripe en cours | aucune date : Stripe renouvelle et facture ; le forfait ne se termine que par une résiliation (ou une nouvelle souscription) |
| Stripe, résilié par le client (`POST /api/billing/cancel`) | `cancelAtPeriodEnd: true` : l'abonnement est résilié chez Stripe **en fin de période** (`cancel_at_period_end`), le forfait reste actif jusqu'à `paidUntilUtc` (date donnée par Stripe), puis retombe à l'Essai. Aucun remboursement au prorata, aucun nouveau prélèvement. Si Stripe ne répond pas, le retour à l'Essai est immédiat et l'historique le dit (« ECHEC annulation Stripe ») |
| **Activé sur facture** (`grant-workers`, `set-plan`) | `paidUntilUtc` = activation + `paidMonths` mois (1 par défaut, jusqu'à 24) ; **au-delà, plus 5 jours de grâce, le forfait retombe à l'Essai** tant que le propriétaire ne l'a pas reconduit en rappelant la route avec la facture suivante. Sans cela un client réglé une fois gardait son forfait et son quota mensuel pour toujours (il n'y a ni webhook ni renouvellement automatique pour une facture). Une résiliation d'un forfait sur facture le garde jusqu'à `paidUntilUtc`, sans grâce |
| État écrit avant cette version, sans `paidUntilUtc` | aucune date : ne se termine jamais tout seul (à reconduire à la main si nécessaire) |

Le retour à l'Essai conserve la fenêtre de crédits en cours (l'essai n'est pas renouvelable : s'abonner puis laisser expirer ne redonne pas 15 crédits neufs), vide la liste des Workers embauchés et se lit tout de suite par les contrôles d'accès (`worker_block`, `allowed_workers_env`). `GET /api/billing` expose `billingInterval` (`month`|`year`, le rythme de paiement de l'abonné : la montée en gamme propose le même, `upgrade.interval`), `paidUntilUtc`, `cancelAtPeriodEnd` et `grandfathered`. `GET /api/admin/overview` ajoute `paidUntilUtc` et `cancelAtPeriodEnd` à chaque client : c'est la liste des forfaits à reconduire.

**Confirmation d'un paiement Stripe** (`POST /api/billing/stripe-confirm`, sans connexion obligatoire : le client qui a payé vient des métadonnées de la session). Elle est **idempotente** : l'identifiant de la Checkout Session est gardé dans `stripeSessions` (50 derniers) et un même abonnement déjà actif ne change rien ; rejouer la confirmation renvoie l'état courant avec `alreadyConfirmed: true`, sans nouveau cycle de crédits, sans effacer le délai d'échange de Worker et sans ressusciter un forfait résilié. L'abonnement doit être encore `active` ou `trialing` chez Stripe (`409 SUBSCRIPTION_NOT_ACTIVE` sinon) et un compte connecté différent de celui qui a payé est refusé (`403 SESSION_CLIENT_MISMATCH`). Quand un nouveau paiement remplace un abonnement (montée en gamme), l'ancien est résilié chez Stripe avec le prorata du temps déjà payé (crédité chez Stripe).

## Où l'accès est vérifié

Un Worker non embauché ne démarre **jamais** : `HTTP 403`, `{"error": "WORKER_NOT_INCLUDED", "detail": "<message français>", "workerId": "...", "hire": {...}}`, aucune tâche créée, aucun crédit consommé.

| Point d'entrée | Contrôle |
|---|---|
| `POST /api/workers/<id>/task`, `.../task/async` | avant l'abonnement et l'objectif |
| `POST /api/chloe/task`, `.../task/async`, `/api/chloe/plan` | Chloé : forfait Trio ou forfait classique ; la demande d'un Worker non embauché est un `403 WORKER_NOT_INCLUDED` partout, plan compris |
| `POST /api/public/v1/missions` (clé API) | Worker demandé, ou Chloé par défaut |
| `POST /api/automations` (création), `.../toggle` (activation), `.../run` | Worker de l'automatisation |
| Automatisations planifiées (cron, `core/automation/AUTOMATION-ENGINE.ps1` + `dashboard/quota-check.py`) | `worker_not_included` ; `installation_paused` (voir plus bas) ; `quota_exceeded`. Pour une automatisation de Chloé, les Workers en pause sont retirés de `BK_ALLOWED_WORKERS` et `BK_MAX_WORKERS` plafonne leur nombre |
| WhatsApp lié à un compte | message clair au lieu de « réessayez » |
| `submit_task()` | **dernier verrou** pour tous les points d'entrée ci-dessus |
| `POST /api/installations` (enregistrer) et `POST /api/installations/status` avec `active` | Worker embauché obligatoire (mettre en pause et supprimer restent permis) |

Variable `BK_MAX_WORKERS` : posée par le serveur (`submit_task`) et par `quota-check.py` pour **Chloé seulement** = solde de crédits // coût du niveau de la mission (au moins 1). Chaque Worker appelé par Chloé est tracé et facturé au niveau de la mission : sans ce plafond, une mission qui rassemble 5 ou 17 Workers dépassait le quota de plusieurs dizaines de crédits. `chloe/Invoke-Chloe-Orchestration.ps1` ne garde que les premiers Workers de sa sélection et liste les autres dans `QuotaSkippedWorkers` et à la fin de la synthèse. Absente ou invalide = pas de plafond (propriétaire, essai public).

Variable `BK_ALLOWED_WORKERS` : posée par le serveur (et par le moteur d'automatisation) pour les scripts PowerShell. Liste de Workers en minuscules séparés par des virgules ; `-` = aucun ; absente = tous. Lue par `chloe/Invoke-Chloe-Orchestration.ps1` (le routeur ne délègue qu'à ces Workers ; si le meilleur Worker n'est pas embauché : `Status = "WORKER_NOT_INCLUDED"`, aucun Worker exécuté ; si une partie seulement l'est : les embauchés travaillent et `NotIncludedWorkers` liste les autres) et par `dashboard/Submit-Task.ps1` (second verrou). Le serveur traduit ce statut en `403 WORKER_NOT_INCLUDED` (route synchrone) ou en job `ERROR` avec `errorCode: "WORKER_NOT_INCLUDED"` (route asynchrone).

## Routes du client (compte connecté, toujours limitées à son propre `ClientId`)

Sans compte : `401 {"error": "ACCOUNT_REQUIRED"}`. Corps JSON ; taille maximale en `413 {"error": "TOO_LARGE"}`. Les identifiants de Worker sont en minuscules (`alex`) ; les majuscules et les espaces autour sont tolérés à l'entrée, jamais un chemin.

### `GET /api/workers/hired`
```json
{"hire": {"restricted": true, "planId": "trio", "workerSlots": 3, "hiredWorkers": ["alex"], "slotsLeft": 2, "chloeIncluded": true,
          "swaps": [], "canSwapNow": true, "lastSwapAtUtc": null, "nextSwapAtUtc": null},
 "planName": "Trio", "openRequests": ["emma"]}
```
Hors forfait restreint : `restricted: false`, `workerSlots: null`, `hiredWorkers: []`. Le même objet `hire` est dans `GET /api/billing` (avec aussi `workerSlots`, `hiredWorkers`, et `workerPlans: [{planId, name, credits, workerSlots, chloeIncluded, priceChf: {month, year}}]`). `availablePlans` est le choix de forfait de la grille de prix (Solo, Trio, Équipe, Pro, Scale, Enterprise sur devis ; jamais l'essai ; Starter et Business seulement pour le client qui y est déjà) ; `workerPlans` détaille Solo et Trio.

### `POST /api/workers/hire` (limite : 20 par heure, corps ≤ 2 Ko)
Requête `{"workerId": "nora", "replaceWorkerId": "alex"}` (`replaceWorkerId` seulement quand tous les emplacements sont pris).
Réponse 200 `{"ok": true, "hired": "nora", "replaced": null, "alreadyHired": false, "hire": {...}}`.
Erreurs : `404 UNKNOWN_WORKER`, `400 CHLOE_NOT_HIRABLE`, `409 NO_RESTRICTED_PLAN` (forfait classique ou propriétaire), `409 NO_SLOT_LEFT` (+ `hiredWorkers`, `workerSlots` : demander quel Worker remplacer), `400 REPLACE_NOT_HIRED`, `409 SWAP_COOLDOWN` (+ `nextSwapAtUtc`, `canSwapNow: false`), `429 RATE_LIMITED`. Un échange met en pause l'installation du Worker remplacé et ferme la demande d'embauche correspondante. Le premier échange est possible tout de suite ; ensuite un par période de 30 jours.

### `POST /api/workers/<id>/hire-request` (5 par jour, corps ≤ 3 Ko)
Requête `{"message": "texte libre, 500 caractères au plus"}`. Réponse `{"ok": true, "requestId": "HRQ-1A2B3C4D", "alreadyRequested": false, "notified": true}`. Une seule demande ouverte par client et par Worker. `notified` = un e-mail a été lancé au propriétaire (adresse `BK_PILOT_NOTIFY_EMAIL` ou fiche du standard, plafond de 30 par jour) ; sans adresse la demande reste visible dans l'aperçu propriétaire. Autorisée pour un client en Essai (il veut souscrire un Worker seul) ou en Solo/Trio sans ce Worker. Erreurs : `404 UNKNOWN_WORKER`, `409 ALREADY_INCLUDED`, `429 RATE_LIMITED`.

### `GET /api/workers/<id>/install-profile`
```json
{"workerId": "alex", "workerName": "Alex", "entitled": true,
 "profile": {"schema": "BK-INSTALL-PROFILE-V1", "tagline": "...", "idealFor": "...", "services": [{"id": "...", "label": "...",
             "knowledgeFields": [{"key", "label", "help", "required", "example"}], "autonomyRules": [{"category", "label", "examples", "risk", "defaultMode", "maxAutoPerDay"}],
             "requiredConnectors": [], "requiredAnyOf": [[]], "optionalConnectors": [], "channels": [], "testScenario": {}, "recommendedLevel": "equilibre"}],
             "channelSupport": {"email": "planned", "phone": "planned", "whatsapp": "planned", "web": "available", "schedule": "available"},
             "plannedCapabilities": [], "installationSteps": []},
 "installation": null,
 "readiness": null,
 "connectorStatus": {"hubspot.controlled": false, "gmail.controlled": false},
 "liveChannels": ["web", "schedule"]}
```
Lisible même sans embauche (`entitled: false`) pour décider. `installation` = la fiche enregistrée de CE client (ou `null`), `readiness` = ce qui manque pour activer (liste de textes français, `[]` = prêt, `null` = pas encore de fiche). `connectorStatus` : connecteur du profil → connecté par ce client (`null` pour le propriétaire). Erreurs : `404 UNKNOWN_WORKER` (y compris `chloe`), `404 NO_INSTALL_PROFILE`.

### `GET /api/installations`
`{"installations": [<installation>...]}`. Chaque installation :
```json
{"workerId": "alex", "workerName": "Alex", "clientId": "CLI-CUST-...", "status": "draft|active|paused", "entitled": true,
 "services": {"prospection-sortante": {"enabled": true, "level": "equilibre", "label": "...",
              "knowledge": {"site_web": "..."}, "autonomy": {"redaction": "auto", "envoi-externe": "off"}, "channels": ["web", "schedule"]}},
 "notes": "...", "readiness": [], "createdAtUtc": "...", "updatedAtUtc": "...", "installedAtUtc": "..."}
```

### `POST /api/installations` (300 par heure, corps ≤ 200 Ko)
Requête = la configuration **complète** (elle remplace la précédente) : `{"workerId": "alex", "services": {"<serviceId>": {"enabled": true, "level": "rapide|equilibre|approfondi", "knowledge": {"<key>": "texte ≤ 2000 caractères"}, "autonomy": {"<category>": "off|ask|draft|auto"}, "channels": ["web"]}}, "notes": "≤ 2000 caractères"}`.
Réponse 200 `{"ok": true, "installation": {...avec readiness}, "warnings": ["... le canal « téléphone » n'est pas encore disponible, il n'a pas été enregistré."]}`. Enregistre un brouillon (`draft`), **jamais** l'activation ; une fiche active modifiée qui devient incomplète repasse en `draft` (l'interface le dit avant et après) ; une fiche en pause reste en pause, quelle que soit la modification.
Erreurs : `400 INSTALLATION_INVALID` `{"detail": "...", "errors": ["messages français"]}` (service ou champ inconnu, `knowledge` ou `autonomy` qui n'est pas un objet, secret détecté, `auto` sur une action à risque ou qui écrit dans un outil, valeur trop longue...), `403 WORKER_NOT_INCLUDED`, `404 UNKNOWN_WORKER` / `NO_INSTALL_PROFILE`, `500 INSTALLATION_FAILED` (jamais de connexion coupée sans réponse).
Règles : `auto` n'est accepté que pour les catégories de risque `low` **sans `operations`** (lire, analyser, rédiger : une règle qui gouverne une écriture dans un outil, tâche CRM, brouillon de message, carte, reste `ask`, `draft` ou `off`) ; jamais pour envoyer, publier, payer, supprimer, appeler. Mots de passe, clés d'API (Stripe `sk_live_`/`rk_live_`/`pk_live_`, AWS `AKIA…`, jetons JWT, `Bearer …`, etc.), IBAN et numéros de carte (13 à 19 chiffres **dont la somme de Luhn est valide** ; un SIRET écrit en 3-3-3-5 chiffres n'en est pas un) sont refusés. `maxAutoPerDay`, dans les profils, est **indicatif** : la plateforme ne le fait pas respecter (ni côté serveur ni dans le prompt).
**Les réglages d'autonomie sont des consignes données au Worker**, injectées dans son prompt comme données (`Client-Installation.ps1`) : ils n'activent aucun mécanisme technique propre à une catégorie. La validation des écritures dans un outil (action en attente à confirmer, brouillons seulement en auto-approbation) dépend du réglage général du compte et de l'adaptateur, pas de ces consignes ; l'interface ne les présente jamais comme une garantie. Seuls les canaux réellement disponibles (`channelSupport == "available"` : aujourd'hui `web`, `schedule`) sont enregistrés ; téléphone, WhatsApp et e-mail sortant ne sont **pas** construits pour les clients du client.

### `POST /api/installations/status` (60 par heure, corps ≤ 2 Ko)
Requête `{"workerId": "alex", "status": "active|paused|draft"}`. Réponse 200 `{"ok": true, "installation": {...}}`. Une mise en pause garde l'origine dans `pausedFrom` (`draft` ou `active`) : l'interface reprend dans le même état. Un brouillon se met en pause lui aussi (il reçoit la fiche et ses automatisations tournent).
Erreurs : `409 NOT_READY` `{"errors": [...], "readiness": [...]}` (activer exige `readiness == []`, y compris les outils obligatoires connectés), `403 WORKER_NOT_INCLUDED` (pour `active`), `404 NO_INSTALLATION`, `400 INVALID_STATUS`, `404 UNKNOWN_WORKER`.

### `POST /api/installations/delete` (comme `status`)
Requête `{"workerId": "alex"}`. Réponse `{"ok": true, "deleted": true}`.

## Routes du propriétaire (porte historique `bk_session`, jamais une session de compte client : sinon `401 GATE_REQUIRED`)

### `POST /api/admin/grant-workers` (60 par heure, corps ≤ 5 Ko)
Requête `{"clientId": "CLI-CUST-XXXXXXXX", "planId": "solo|trio", "workers": ["alex"], "newCycle": true, "paidMonths": 1}` (`newCycle` par défaut `true` : une facture réglée = nouveau pot de crédits et nouvelle période payée ; `false` pour seulement changer la liste, la période en cours n'est pas touchée). `paidMonths` = mois couverts par la facture (1 à 24, défaut 1) : le forfait retombe à l'Essai à l'échéance (+ 5 jours de grâce) tant que cette route n'est pas rappelée avec la facture suivante. Fixe le forfait, repart sur son pot de crédits et remplace la liste des Workers (pas un échange : le délai de 30 jours n'est pas touché quand le forfait ne change pas). Les installations de **tous** les Workers non embauchés sont mises en pause (y compris celles faites pendant l'essai) ; les demandes d'embauche correspondantes passent à `granted`.
Réponse 200 `{"ok": true, "clientId", "planId", "planName", "credits", "newCycle", "paidUntilUtc", "hire": {...}}`.
Erreurs : `404 CLIENT_NOT_FOUND`, `400 INVALID_PLAN`, `400 INVALID_PERIOD`, `400 WORKERS_REQUIRED`, `400 TOO_MANY_WORKERS`, `404 UNKNOWN_WORKER`, `400 CHLOE_NOT_HIRABLE`, `409 ACTIVE_SUBSCRIPTION` (abonnement Stripe en cours : l'annuler d'abord), `429 RATE_LIMITED`.

### `POST /api/admin/set-plan` (même limite)
Requête `{"clientId", "planId": "equipe|pro|scale|enterprise", "contractCredits": 25000, "paidMonths": 1}` : active un forfait sans liste de Workers après facture réglée ou devis signé (`contractCredits` seulement pour Enterprise). Même règle de période payée que `grant-workers` ; réponse `{"ok", "clientId", "planId", "planName", "credits", "renewsAtUtc", "paidUntilUtc"}`.

### `GET /api/admin/overview` (existant, étendu)
Chaque client reçoit `workerSlots` et `hiredWorkers` ; nouvelle clé `hireRequests`: `[{id, clientId, clientLabel, workerId, workerName, message, status: "open", createdAtUtc}]` (demandes ouvertes). **Le `message` vient du client : à échapper à l'affichage.**

## Interrupteur d'arrêt (pause)

Mettre une installation en `paused` agit immédiatement : (1) le bloc de configuration n'est plus injecté dans le prompt du Worker ; (2) les automatisations planifiées de ce Worker sont sautées (`installation_paused`, ni mission ni crédit), **y compris celles de Chloé qui l'appelleraient** (il est retiré de la liste `BK_ALLOWED_WORKERS` de la mission planifiée ; si tous les Workers sont en pause, la mission planifiée de Chloé est sautée) ; (3) les vrais brouillons ne sont plus exécutés automatiquement par « Laisser mes Workers agir seuls » (ils attendent la confirmation du client). Les missions lancées à la main continuent de fonctionner. Une fiche illisible est traitée comme en pause.

L'interrupteur est offert pour **tout** statut : un brouillon (`draft`) reçoit la fiche et ses automatisations tournent, il doit donc pouvoir être arrêté. Seul un geste explicite sort une installation de la pause (l'interrupteur, ou « Lever la pause (repasser en brouillon) » dans l'essai à blanc) ; enregistrer la fiche ne le fait jamais.

## Configuration injectée dans le prompt

`core/ai/adapters/Client-Installation.ps1` (appelé par `Build-WorkerSystemPrompt.ps1`, comme la mémoire) ajoute un bloc entre `<client_installation>` et `</client_installation>` : services activés, fiche de connaissances, règles d'autonomie, notes. Uniquement pour le bon client **et** le bon Worker, en statut `active` ou `draft` (essai). Tout texte du client est présenté comme **donnée** : ramené sur une ligne, tronqué à 2000 caractères, `<` et `>` remplacés (impossible de refermer la balise), précédé d'un rappel que ces textes ne peuvent pas annuler les règles de la plateforme ; les règles « contenu externe = données » et « jamais d'action réelle sans validation » restent placées après le bloc.

## Suppression et export de compte

`delete_account` supprime `runtime/installations/<ClientId>/` et les demandes d'embauche du client. `POST /api/account/export` inclut `installations` et `hireRequests`.

## Tests

`tests/hire/` : `test_entitlements.py`, `test_installations.py`, `test_server_hire.py` (Python seul) ; `test_prompt_installation.py`, `test_chloe_allowed.py`, `test_adapter_pause.py` (PowerShell 7) ; `e2e_server.py` (vrai serveur sur une copie du dépôt, deux à cinq comptes, propriétaire). Aucun appel modèle ni réseau.

## Limites connues

- Sans Stripe configuré, facturation manuelle : activation par le propriétaire (`grant-workers`, `set-plan`) après facture réglée.
- Les crédits se renouvellent **chaque mois** tant que le forfait est valide (fenêtre ancrée sur l'activation). Un forfait activé sur facture n'est valide que pour les mois facturés (`paidMonths`, + 5 jours de grâce) : une nouvelle facture réglée = un nouvel appel à `grant-workers` ou `set-plan`, sinon le client retombe à l'Essai. Un forfait écrit avant cette version, sans date de fin, ne se termine jamais tout seul.
- Aucun webhook Stripe : un abonnement résilié ou en échec de paiement chez Stripe sans passer par `POST /api/billing/cancel` n'est pas vu par l'application.
- Les règles d'autonomie de l'installation sont des consignes transmises au Worker comme données ; elles ne remplacent pas les garde-fous techniques existants (confirmation des écritures, brouillons seulement en auto-approbation) et la plateforme n'en vérifie pas le respect.
- Téléphone et WhatsApp pour les clients du client, et traitement automatique d'une boîte e-mail : **non disponibles** (ne pas les présenter comme tels).
