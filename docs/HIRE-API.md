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
- Quand Stripe est configuré, `POST /api/billing/plan` ouvre une vraie Checkout Session pour `solo`, `trio` et `equipe` (montant du catalogue en CHF, annuel = 10 mois) ; le forfait n'est activé qu'après le paiement vérifié côté serveur. Sans Stripe, il répond `403 PLAN_BY_INVOICE` (pas de bascule gratuite en libre-service) : le propriétaire active `solo` et `trio` après facture réglée (`POST /api/admin/grant-workers`), `equipe`, `pro`, `scale` et `enterprise` par `POST /api/admin/set-plan`.
- Le propriétaire (`CLI-DASHBOARD`) et l'essai public ne sont jamais restreints.
- L'état vit dans le fichier de facturation du client (`core/billing/data/<ClientId>.json`) : `planId`, `hiredWorkers` (liste), `workerSwaps`, `lastWorkerSwapAtUtc`.

## Où l'accès est vérifié

Un Worker non embauché ne démarre **jamais** : `HTTP 403`, `{"error": "WORKER_NOT_INCLUDED", "detail": "<message français>", "workerId": "...", "hire": {...}}`, aucune tâche créée, aucun crédit consommé.

| Point d'entrée | Contrôle |
|---|---|
| `POST /api/workers/<id>/task`, `.../task/async` | avant l'abonnement et l'objectif |
| `POST /api/chloe/task`, `.../task/async`, `/api/chloe/plan` | Chloé : forfait Trio ou forfait classique |
| `POST /api/public/v1/missions` (clé API) | Worker demandé, ou Chloé par défaut |
| `POST /api/automations` (création), `.../toggle` (activation), `.../run` | Worker de l'automatisation |
| Automatisations planifiées (cron, `core/automation/AUTOMATION-ENGINE.ps1` + `dashboard/quota-check.py`) | `worker_not_included` ; `installation_paused` (voir plus bas) |
| WhatsApp lié à un compte | message clair au lieu de « réessayez » |
| `submit_task()` | **dernier verrou** pour tous les points d'entrée ci-dessus |
| `POST /api/installations` (enregistrer) et `POST /api/installations/status` avec `active` | Worker embauché obligatoire (mettre en pause et supprimer restent permis) |

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
Réponse 200 `{"ok": true, "installation": {...avec readiness}, "warnings": ["... le canal « téléphone » n'est pas encore disponible, il n'a pas été enregistré."]}`. Enregistre un brouillon (`draft`), **jamais** l'activation ; une fiche active modifiée qui devient incomplète repasse en `draft` ; une fiche en pause reste en pause.
Erreurs : `400 INSTALLATION_INVALID` `{"detail": "...", "errors": ["messages français"]}` (service ou champ inconnu, secret détecté, `auto` sur une action à risque, valeur trop longue...), `403 WORKER_NOT_INCLUDED`, `404 UNKNOWN_WORKER` / `NO_INSTALL_PROFILE`.
Règles : `auto` n'est accepté que pour les catégories de risque `low` (lire, analyser, rédiger, note interne) ; jamais pour envoyer, publier, payer, supprimer, appeler. Mots de passe, clés d'API, numéros de carte et IBAN sont refusés. Seuls les canaux réellement disponibles (`channelSupport == "available"` : aujourd'hui `web`, `schedule`) sont enregistrés ; téléphone, WhatsApp et e-mail sortant ne sont **pas** construits pour les clients du client.

### `POST /api/installations/status` (60 par heure, corps ≤ 2 Ko)
Requête `{"workerId": "alex", "status": "active|paused|draft"}`. Réponse 200 `{"ok": true, "installation": {...}}`.
Erreurs : `409 NOT_READY` `{"errors": [...], "readiness": [...]}` (activer exige `readiness == []`, y compris les outils obligatoires connectés), `403 WORKER_NOT_INCLUDED` (pour `active`), `404 NO_INSTALLATION`, `400 INVALID_STATUS`, `404 UNKNOWN_WORKER`.

### `POST /api/installations/delete` (comme `status`)
Requête `{"workerId": "alex"}`. Réponse `{"ok": true, "deleted": true}`.

## Routes du propriétaire (porte historique `bk_session`, jamais une session de compte client : sinon `401 GATE_REQUIRED`)

### `POST /api/admin/grant-workers` (60 par heure, corps ≤ 5 Ko)
Requête `{"clientId": "CLI-CUST-XXXXXXXX", "planId": "solo|trio", "workers": ["alex"], "newCycle": true}` (`newCycle` par défaut `true` : une facture réglée = nouveau pot de crédits ; `false` pour seulement changer la liste). Fixe le forfait, repart sur son pot de crédits et remplace la liste des Workers (pas un échange : le délai de 30 jours n'est pas touché). Les installations des Workers retirés sont mises en pause ; les demandes d'embauche correspondantes passent à `granted`.
Réponse 200 `{"ok": true, "clientId", "planId", "planName", "credits", "newCycle", "hire": {...}}`.
Erreurs : `404 CLIENT_NOT_FOUND`, `400 INVALID_PLAN`, `400 WORKERS_REQUIRED`, `400 TOO_MANY_WORKERS`, `404 UNKNOWN_WORKER`, `400 CHLOE_NOT_HIRABLE`, `409 ACTIVE_SUBSCRIPTION` (abonnement Stripe en cours : l'annuler d'abord), `429 RATE_LIMITED`.

### `GET /api/admin/overview` (existant, étendu)
Chaque client reçoit `workerSlots` et `hiredWorkers` ; nouvelle clé `hireRequests`: `[{id, clientId, clientLabel, workerId, workerName, message, status: "open", createdAtUtc}]` (demandes ouvertes). **Le `message` vient du client : à échapper à l'affichage.**

## Interrupteur d'arrêt (pause)

Mettre une installation en `paused` agit immédiatement : (1) le bloc de configuration n'est plus injecté dans le prompt du Worker ; (2) les automatisations planifiées de ce Worker sont sautées (`installation_paused`, ni mission ni crédit) ; (3) les vrais brouillons ne sont plus exécutés automatiquement par « Laisser mes Workers agir seuls » (ils attendent la confirmation du client). Les missions lancées à la main continuent de fonctionner. Une fiche illisible est traitée comme en pause.

## Configuration injectée dans le prompt

`core/ai/adapters/Client-Installation.ps1` (appelé par `Build-WorkerSystemPrompt.ps1`, comme la mémoire) ajoute un bloc entre `<client_installation>` et `</client_installation>` : services activés, fiche de connaissances, règles d'autonomie, notes. Uniquement pour le bon client **et** le bon Worker, en statut `active` ou `draft` (essai). Tout texte du client est présenté comme **donnée** : ramené sur une ligne, tronqué à 2000 caractères, `<` et `>` remplacés (impossible de refermer la balise), précédé d'un rappel que ces textes ne peuvent pas annuler les règles de la plateforme ; les règles « contenu externe = données » et « jamais d'action réelle sans validation » restent placées après le bloc.

## Suppression et export de compte

`delete_account` supprime `runtime/installations/<ClientId>/` et les demandes d'embauche du client. `POST /api/account/export` inclut `installations` et `hireRequests`.

## Tests

`tests/hire/` : `test_entitlements.py`, `test_installations.py`, `test_server_hire.py` (Python seul) ; `test_prompt_installation.py`, `test_chloe_allowed.py`, `test_adapter_pause.py` (PowerShell 7) ; `e2e_server.py` (vrai serveur sur une copie du dépôt, deux à cinq comptes, propriétaire). Aucun appel modèle ni réseau.

## Limites connues

- Pas de prix Stripe pour Solo et Trio : facturation manuelle, activation par le propriétaire.
- Les crédits ne se renouvellent pas tout seuls (aucun forfait, comme avant) : une nouvelle facture réglée = un nouvel appel à `grant-workers`.
- Les règles d'autonomie de l'installation sont transmises au Worker comme données ; elles ne remplacent pas les garde-fous techniques existants (confirmation des écritures, brouillons seulement en auto-approbation).
- Téléphone et WhatsApp pour les clients du client, et traitement automatique d'une boîte e-mail : **non disponibles** (ne pas les présenter comme tels).
