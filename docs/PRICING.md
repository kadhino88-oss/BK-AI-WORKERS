# Grille de prix, crédits et quota mensuel

Décision du propriétaire du 2026-10-12, prise après l'étude de marché (`docs/ETUDE-MARCHE-PRIX-2026-10.md`, branche `ws/market-study`, sections 4.1, 4.2 et 4.5) : l'offre est plus attractive que celle des concurrents directs (Solo à CHF 29 est 38 % sous le Worker à l'unité de Delos ; Équipe à CHF 99 est 24 % sous Limova Pro). Ce document est la référence unique ; le code qui la porte est `PLAN_CATALOG` dans `dashboard/server.py`, et `tests/pricing/` vérifie qu'aucune page du site ne montre une autre liste.

## 1. Les forfaits

| Forfait | Mensuel (CHF) | Annuel (CHF, 10 mois) | Crédits par mois | Contenu | Activation |
|---|---|---|---|---|---|
| **Essai** | 0 | — | 15, **une seule fois**, 3 jours | niveau Rapide seulement, **aucune minute de téléphone** | automatique à la création du compte |
| **Solo** | 29 | 290 | 250 | 1 Worker au choix, installé selon son activité | Stripe, ou propriétaire après facture |
| **Trio** | 59 | 590 | 500 | 3 Workers au choix + Chloé | Stripe, ou propriétaire après facture |
| **Équipe** | 99 | 990 | 900 | les 17 Workers + Chloé (remplace Business à la vente) | Stripe, ou propriétaire après facture |
| **Pro** | 139 | 1 390 | 1 250 | Équipe + 39 % de crédits | Stripe |
| **Scale** | 449 | 4 490 | 4 000 | Pro + capacité | Stripe |
| **Enterprise** | sur devis | sur devis | plafond **fixé par contrat** (défaut 10 000) | à définir au devis | propriétaire, devis signé |
| *Starter* (hérité) | 39 | 390 | 150 | — | plus vendu |
| *Business* (hérité) | 99 | 990 | 600 | — | plus vendu |

- **Aucun paquet de crédits, aucun forfait illimité, aucun paiement à l'usage, aucune recharge automatique.** La recharge de crédits n'existe plus pour un client (`POST /api/billing/recharge` répond `RECHARGE_NOT_AVAILABLE`) ; la route reste un outil du propriétaire pour son propre compte (il n'y a plus de bouton).
- Annuel = 10 mois payés pour 12 (« 2 mois offerts »). Le quota reste **mensuel** même en annuel.
- Solo et Trio n'ouvrent que les Workers choisis (voir `docs/HIRE-API.md`) ; Trio inclut Chloé en plus des 3.
- Starter et Business restent dans le catalogue pour les abonnés existants : mêmes crédits, même prix, `legacy: true`, masqués de la page Tarifs et du choix de forfait (sauf pour celui qui y est déjà). Pour qu'un abonné hérité ne subisse **aucun changement silencieux du nombre de crédits**, sa mission lancée sans choix de niveau reste au niveau Rapide (1 crédit) comme avant l'activation des niveaux (`defaultLevel: "rapide"`) ; s'il choisit lui-même Équilibre ou Approfondi, il paie le coût de ce niveau. Deux différences restent, à connaître : leur mission par défaut tourne désormais avec les réglages du niveau Rapide (Haiku 5.5, effort bas, 6 étapes, 3 recherches web) et non plus avec les anciennes limites sans niveau (Haiku 4.5, 8 étapes, 5 recherches), soit un peu moins de capacité pour le même crédit ; et leur quota se renouvelle désormais chaque mois (avant, le compteur courait sans remise à zéro), ce qui leur est favorable.

### Abonnés Pro et Scale existants (avant la grille du 2026-10-12)

Avant la grille, Pro incluait **1 500** crédits (1 250 aujourd'hui, au même prix) et une mission coûtait toujours 1 crédit ; avec les niveaux actifs, la mission par défaut (Équilibre) coûte 6 crédits, soit environ 208 missions par mois pour un Pro au lieu de 1 500. Les CGV (art. 4 et 8) disent que les conditions sont celles de la page Tarifs au moment de la souscription et qu'un changement demande 30 jours de préavis, effectif au renouvellement suivant. **Aucun abonné existant n'est donc modifié en silence** : un état de facturation Pro ou Scale **sans `gridVersion`** (écrit avant cette version) garde ses crédits d'origine (Pro 1 500, Scale 4 000) et le niveau Rapide par défaut (`GRANDFATHERED_PLANS`, `_grandfathered`), tant qu'il ne change pas de forfait. Tout forfait activé depuis (Stripe, `grant-workers`, `set-plan`, y compris un nouveau paiement du même forfait) porte `gridVersion: 2` et reçoit la grille actuelle. `GET /api/billing` renvoie `grandfathered: true` pour ces comptes. Pour y mettre fin plus tôt, envoyer le préavis de 30 jours puis rappeler `set-plan` (qui pose `gridVersion`).

**Il faut avoir payé pour être « ancien abonné »** (2e revue) : avant le 2026-10-13, la route de choix de forfait *simulait* Pro et Scale gratuitement quand Stripe n'était pas configuré (historique « simulation, aucun paiement reel »). Ne sont donc conservés à 1 500 / 4 000 crédits que les états qui prouvent un paiement : un `stripeSubscriptionId`, ou une ligne d'historique « paiement Stripe confirme » ou « activé par BK Entreprise » (`_payment_evidence`). Un Pro ou Scale **sans `gridVersion` et sans preuve de paiement** est migré une seule fois, à sa première lecture (`_stamp_unproven_legacy_plan`) : il passe à la grille actuelle, reste actif **30 jours** (`UNPROVEN_PLAN_DAYS`, plus les 5 jours de grâce), avec une ligne d'historique qui le dit, puis retombe à l'Essai si le propriétaire ne reçoit pas le règlement et ne l'active pas par `set-plan`. **Avant le déploiement**, auditer `core/billing/data/CLI-CUST-*.json` sur le serveur : `grep -L "paiement Stripe confirme\|stripeSubscriptionId\|activé par BK Entreprise"` parmi les fichiers dont `planId` vaut `pro` ou `scale` liste les comptes qui vont recevoir ce délai. Starter et Business ne sont pas concernés (hors de ce périmètre : à auditer de la même façon si Stripe n'était pas configuré à l'époque).

## 2. Échelle de crédits et niveaux de travail

`core/ai/LEVELS.json` : **Rapide 1 · Équilibre 6 · Approfondi 12** crédits par mission, niveaux **actifs** (`"enabled": true`). Niveau par défaut : Équilibre.

| Règle | Où |
|---|---|
| L'essai est verrouillé sur Rapide (le client ne voit que ce niveau, le serveur ignore tout autre niveau demandé) | `levelLock` du forfait Essai, `normalize_level` |
| Les **automatisations** (missions récurrentes lancées par le planificateur) tournent toujours au niveau Rapide et coûtent **1 crédit**, pour que le quota reste parlant | `automation_level`, `dashboard/quota-check.py`, `core/automation/AUTOMATION-ENGINE.ps1` (variable `BK_MISSION_LEVEL`), `dashboard/Submit-Task.ps1` |
| Chaque Worker appelé par Chloé est facturé au niveau de la mission (un Worker de Chloé ne coûte plus un crédit quel que soit le niveau) | `dashboard/Submit-Task.ps1` |
| Le quota est contrôlé **au niveau demandé** sur toutes les routes de mission (une mission Approfondi ne passe pas avec le solde d'une mission Équilibre) | `subscription_blocks_mission(client_id, level)` |

**Interrupteur d'arrêt : `BK_LEVELS=0`** dans le `.env` du serveur (puis `docker compose up -d`, qui recrée le conteneur ; voir `.env.example`). Retour à l'ancien comportement : un seul niveau, modèle léger, **1 crédit par mission** (automatisations comprises, `level` vide). `BK_LEVELS=1` force l'activation quel que soit le fichier. Sans variable, c'est `enabled` de `core/ai/LEVELS.json` qui décide.

Ce que 1/6/12 donne en missions par mois :

| Forfait | Crédits | Rapide | Équilibre | Approfondi |
|---|---|---|---|---|
| Solo | 250 | 250 | 41 | 20 |
| Trio | 500 | 500 | 83 | 41 |
| Équipe | 900 | 900 | 150 | 75 |
| Pro | 1 250 | 1 250 | 208 | 104 |
| Scale | 4 000 | 4 000 | 666 | 333 |

## 3. Modèle de quota (consigne du propriétaire du 2026-10-12)

Chaque forfait est un **quota mensuel fixe de crédits**, comme les limites d'usage de Claude : jamais de missions illimitées. Quand le quota est atteint, le client passe au forfait **suivant**, qui a son propre quota plus grand. Le dernier forfait vendu (Scale) mène à **Enterprise sur devis, qui a aussi un plafond contractuel**.

- **Fenêtre mensuelle** : le compteur repart à zéro chaque mois, le jour d'activation du forfait (ramené au dernier jour des mois courts). Les crédits non utilisés ne sont pas reportés. L'essai ne se renouvelle pas. Avant le 2026-10-12 la fenêtre ne se renouvelait jamais (le compteur courait depuis l'activation).
- **Aucun chemin « illimité »** : `plan_monthly_credits` renvoie toujours un entier fini ; un plafond absent, négatif ou illisible vaut 0 et la mission est refusée (jamais « tout est permis »). `GET /api/billing` garde le champ `unlimited` pour les anciens clients de l'API, toujours à `false`.
- **Choisir le forfait qu'on a déjà ne redémarre jamais un cycle** (ce serait un quota gratuit en plus), et « annuler » ne redonne pas les 15 crédits d'essai.
- **Une mission ne coûte que si elle est livrée** : une mission refusée par la sécurité, ou traitée par le repli local parce que le fournisseur d'IA était indisponible (`Result.Degraded`), est tracée à **0 crédit** (`Get-BKMissionCredits` dans `dashboard/Submit-Task.ps1`, `task_credits` dans `dashboard/server.py` qui applique la même règle aux anciennes traces).
- **Chloé ne dépasse jamais le quota** : elle appelle autant de Workers que le solde le permet (`BK_MAX_WORKERS` = solde // coût du niveau, voir `docs/HIRE-API.md`) ; les autres sont signalés dans la synthèse.
- **Période payée** : un forfait activé sur facture dure les mois facturés (`paidMonths`, plus 5 jours de grâce) puis retombe à l'Essai ; **les jours de grâce n'ouvrent aucune fenêtre de crédits neuve** (la fenêtre reste la dernière payée, `_window_clock` : un client qui ne paie pas la facture suivante ne reçoit pas un mois de quota gratuit) ; un abonnement Stripe résilié garde son forfait jusqu'à la fin de la période déjà payée (CGV art. 6). Détail et tableau dans `docs/HIRE-API.md`, « Période payée, renouvellement et résiliation ».
- **Enterprise** : `credits` n'est plus `None` mais `ENTERPRISE_DEFAULT_CREDITS` (10 000 par mois, défaut documenté). Le propriétaire fixe le plafond du contrat du client avec `POST /api/admin/set-plan` `{"clientId", "planId": "enterprise", "contractCredits": 25000}` (entier de 1 à `ENTERPRISE_MAX_CREDITS` = 1 000 000, champ `contractCredits` du fichier de facturation du client). Un client ne peut pas se mettre lui-même en Enterprise (`403 PLAN_ON_QUOTE`). Comme le plafond de 10 000 crédits coûte au pire cas environ CHF 378 d'IA, un contrat ne doit pas descendre sous environ CHF 1 080 par mois pour 10 000 crédits (règle des 35 %, section 5).
- **Pas de surprise de facture** : aucune recharge automatique, aucun paiement à l'usage, aucun prélèvement avant le paiement sur la page Stripe.

### Voie de montée en gamme

Solo → Trio → Équipe → Pro → Scale → Enterprise (sur devis). Les forfaits hérités montent vers Équipe (Starter) et Pro (Business).

Quand une mission est refusée parce que le quota du mois est épuisé, le message français dit combien de crédits le forfait inclut, que le quota se renouvelle à la date du cycle, et nomme le forfait suivant avec ses crédits et son prix. Exemple (Solo, quota épuisé) :

> Votre quota est épuisé : le forfait Solo inclut 250 crédits par mois, renouvelés le 12 novembre 2026. Pour continuer sans attendre, passez au forfait Trio (500 crédits par mois, CHF 59 par mois).

Quand il reste des crédits mais pas assez pour le niveau demandé : « Il vous reste 5 crédit(s), ce niveau en demande 6. Choisissez un niveau plus rapide ou passez au forfait Trio (…). »

La réponse HTTP est `402 SUBSCRIPTION_REQUIRED` avec, en plus du message (`detail`), la carte de montée en gamme :

```json
{"error": "SUBSCRIPTION_REQUIRED", "detail": "Votre quota est épuisé : …",
 "upgrade": {"planId": "solo", "planName": "Solo", "creditsIncluded": 250, "renews": true, "renewsAtUtc": "2026-11-12T…Z",
             "next": {"planId": "trio", "name": "Trio", "credits": 500, "priceChf": {"month": 59, "year": 590},
                      "onQuote": false, "selfService": true, "workerSlots": 3},
             "contactEmail": "…"}}
```

Dans l'interface (`dashboard/app.js`) : toute carte « quota épuisé » (chat d'un Worker, Chloé, automatisations) affiche le bouton **« Passer à <forfait suivant> (prix/mois) »**, qui ouvre le flux de changement de forfait déjà présent (`POST /api/billing/plan` : Checkout Stripe quand Stripe est configuré), plus « Voir tous les forfaits ». La vue **Facturation** montre les crédits utilisés / inclus, la date de renouvellement, et, **à partir de 80 % du quota**, le bouton **« Passer à la formule supérieure »** (`upgradeSuggested` dans `GET /api/billing`). Pour Enterprise (ou le plafond d'un contrat) le bouton ouvre un e-mail pré-rempli : le plafond se relève par avenant.

## 4. Paiement (Stripe)

- `POST /api/billing/plan` `{"planId", "interval": "month"|"year"}` : forfaits payables en ligne = Solo, Trio, Équipe, Pro, Scale. Le forfait n'est activé qu'**après le paiement vérifié côté serveur** (`/api/billing/stripe-confirm`). Un client qui monte de forfait par une nouvelle Checkout Session voit son ancien abonnement Stripe annulé une fois le nouveau confirmé (pas de double facturation) ; la Checkout Session réutilise le **client Stripe** du compte (`stripeCustomerId`, relevé à la confirmation, puis à chaque relecture de l'abonnement pour ceux qui ont payé avant que le client soit retenu) pour que le crédit de prorata de l'ancien abonnement lui reste attaché (il s'impute sur ses prochaines factures) au lieu de rester sur un ancien client Stripe. Choisir à nouveau un forfait résilié mais encore actif **reprend l'abonnement en place** (`cancel_at_period_end=false`, aucun second paiement) ; une fois la période finie, c'est un nouveau paiement.
- **Montant** (`plan_price_cents`, `Get-StripeCheckoutFields` dans `core/integrations/Stripe-Adapter.ps1`) : si un Price ID existe dans le secret Stripe (`prices` / `pricesAnnual`), il est utilisé tel quel (Pro, Scale, et les forfaits hérités : rien ne change pour eux). Sinon (Solo, Trio, Équipe) le serveur envoie le montant du catalogue en centimes de CHF (`price_data`, récurrent mensuel ou annuel). Un montant absent ou hors de CHF 1 à CHF 100 000 est refusé (`INVALID_AMOUNT`) : on n'invente jamais un prix.
- Sans Stripe configuré : **aucun** forfait payant (Solo, Trio, Équipe, Pro, Scale) ne bascule gratuitement pour un client (`403 PLAN_BY_INVOICE`) ; le propriétaire les active après facture réglée (`/api/admin/grant-workers` pour Solo et Trio, `/api/admin/set-plan` pour Équipe, Pro, Scale, Enterprise), pour les mois facturés. Seul le compte du propriétaire peut simuler un changement, pour tester le parcours. (Avant la revue du 2026-10-13, Pro et Scale restaient une simulation gratuite ouverte à tout client à l'e-mail confirmé.)
- Stripe configuré mais le pont en erreur ou en délai dépassé : `503 STRIPE_UNAVAILABLE`, rien ne change (avant, Pro et Scale basculaient gratuitement sur une erreur du pont).
- **La confirmation du paiement est idempotente** : une Checkout Session ne peut activer un forfait qu'une fois (son identifiant est gardé), l'abonnement doit être encore actif chez Stripe, et un rejeu ne redonne ni quota, ni délai d'échange de Worker effacé, ni forfait résilié. Une résiliation (`POST /api/billing/cancel`) est une résiliation **en fin de période** chez Stripe ; un remplacement par un forfait supérieur résilie l'ancien abonnement avec le prorata du temps déjà payé. La montée en gamme proposée reprend le rythme de paiement du client (mensuel ou annuel).
- Les forfaits hérités, l'essai et Enterprise n'ont jamais de Checkout (`PLAN_NOT_SOLD`, `PLAN_NOT_SELECTABLE`, `PLAN_ON_QUOTE`).

## 5. Coût de l'IA : la règle des 35 %

Règle du propriétaire : quand un client épuise **tous** ses crédits du mois en missions lourdes, le coût IA reste sous 35 % du prix mensuel. Calcul : `docs/pricing-cost-model.py` (copié de la branche `ws/market-study`), scénario « lourd », hypothèses de calcul et non des mesures. Coût IA au pire cas par crédit : Rapide 0,0352 · **Équilibre 0,0378** · Approfondi 0,0357 CHF (avec 1/3/8, Équilibre coûtait 0,0756).

| Forfait | Prix | Crédits | Coût IA pire cas | % du prix | Coût IA typique |
|---|---|---|---|---|---|
| Solo | 29 | 250 | 9,45 | 32,6 % | 12,9 % |
| Trio | 59 | 500 | 18,91 | 32,0 % | 12,6 % |
| Équipe | 99 | 900 | 34,03 | 34,4 % | 13,6 % |
| Pro | 139 | 1 250 | 47,27 | 34,0 % | 13,4 % |
| Scale | 449 | 4 000 | 151,25 | 33,7 % | 13,3 % |
| Starter (hérité) | 39 | 150 | 5,67 | 14,5 % | 5,7 % |
| Business (hérité) | 99 | 600 | 22,69 | 22,9 % | 9,0 % |

- L'**annuel** (10 mois pour 12 mois de crédits) porte le pire cas à 38-41 % du prix mensuel équivalent : c'est le prix des « 2 mois offerts », à garder en tête (le coût typique passe de 13 % à 15-16 %).
- L'essai coûte au plus CHF 0,53 d'IA (15 crédits Rapide).
- Les valeurs sont des **hypothèses** : les recalibrer avec le registre de coûts réels (`docs/COST-LEDGER.md`) après 30 jours d'usage.
- **Deux bornes différentes.** (1) Le scénario « lourd » de l'étude, ci-dessus : sous 35 % pour les cinq forfaits vendus, mais Équipe n'a que **0,6 point** de marge (un mouvement d'environ 1,7 % du dollar contre le franc la ferait franchir). (2) Le **plafond dur par mission** déjà construit (`maxCostChf` de `core/ai/LEVELS.json`, appliqué par `core/ai/adapters/Mission-Cost.ps1` : Équilibre CHF 0,50, Approfondi CHF 1,00, soit 0,0833 CHF par crédit ; Rapide n'en a pas). Si **toutes** les missions atteignaient leur plafond, le coût IA serait de **71,8 %** du prix pour Solo, 70,6 % Trio, 75,8 % Équipe, 74,9 % Pro et 74,2 % Scale : le plafond protège d'une mission folle, il ne garantit pas la règle des 35 %. Pour qu'il la garantisse, il faudrait descendre Équilibre vers CHF 0,23 et Approfondi vers CHF 0,43 (coûts du scénario lourd, 0,2269 et 0,4288 CHF par mission) : décision du propriétaire.
- **`BK_LEVELS=0` est une mesure d'urgence de courte durée, pas un mode normal.** L'ancien comportement qu'il restaure (1 crédit par mission) tourne sur Haiku 4.5 (1/5 USD par million de jetons), dix fois plus cher par appel que Haiku 5.5 : au scénario lourd, 0,1278 CHF par mission, donc Solo 110 %, Trio 108 %, Équipe 116 %, Pro 115 % et Scale 114 % du prix (typique : environ 43-46 %). À utiliser pour rétablir un service, puis à lever.
- **Coupon de lancement** (`BK_STRIPE_LAUNCH_COUPON`, vide par défaut, 30 % sur les deux premiers mois de tout abonnement mensuel y compris Solo, Trio et Équipe) : sur ces deux mois le pire cas passe à Solo 46,6 %, Trio 45,8 %, Équipe 49,1 %, Pro 48,6 %, Scale 48,1 % du prix payé. À ne renseigner que si le propriétaire accepte cette marge pendant deux mois.

## 6. Limites d'usage : session, semaine et mois (consigne du propriétaire du 2026-10-18)

Comme les limites de Claude, en plus du prix mensuel et des crédits du mois : une limite par **session de 4 heures** (fenêtre glissante, ouverte par la première mission qui consomme des crédits, qui se renouvelle seule) et une limite par **semaine** (7 jours à partir de la première utilisation de la semaine). **Aucun forfait n'est illimité.** Toute consommation (mission, automatisation, étape de projet) doit passer les trois fenêtres (session, semaine, mois) ; la plus restrictive borne. Le code : `dashboard/usage.py` (grand livre, indépendant de `server.py`), `dashboard/usage_wiring.py` (branchement), `dashboard/usage-cli.py` (automatisations), réglages dans `core/usage/USAGE-LIMITS.json`. Le contrat détaillé (réservation atomique, réconciliation, projets) est `docs/AUTONOMY-ENGINE.md`, section 6b.

### 6.1 Les chiffres

Réglages (`core/usage/USAGE-LIMITS.json`, versionné ; les allocations ne sont **jamais stockées**, elles sont recalculées à chaque contrôle depuis le forfait **actuel** du client) :

| Constante | Valeur | Sens |
|---|---|---|
| `weeklyDivisor` | 4,35 | semaine = crédits du mois ÷ 4,35 (arrondi à l'entier le plus proche, .5 vers le haut) |
| `sessionShareOfWeek` | 0,40 | session = 40 % de la semaine |
| `minSessionCredits` | 12 | plancher : une mission Approfondi (12 crédits) tient toujours dans une session vide |
| `sessionHours` / `weekDays` | 4 / 7 | durée des fenêtres glissantes |
| `warnPercent` | 80 | seuil d'alerte de l'interface |
| `minStartCredits` | 6 | en dessous, un projet n'est pas relancé (il attend) |
| `exemptClients`, `exemptPlans` | propriétaire, essai public ; **Essai** | exemptés des fenêtres (15 crédits uniques sur 3 jours : une fenêtre n'ajouterait rien) |

Ce que cela donne (le coût IA au pire cas est celui de la section 5, 0,0378 CHF par crédit, le plus haut des trois niveaux) :

| Forfait | Mois | Semaine | Session | Missions Équilibre par session | Coût IA au pire cas, session / semaine / mois | Part du prix (mois) |
|---|---|---|---|---|---|---|
| Solo | 250 | 57 | 23 | 3 | 0,87 / 2,15 / 9,45 CHF | 32,6 % |
| Trio | 500 | 115 | 46 | 7 | 1,74 / 4,35 / 18,90 CHF | 32,0 % |
| Équipe | 900 | 207 | 83 | 13 | 3,14 / 7,82 / 34,02 CHF | 34,4 % |
| Pro | 1 250 | 287 | 115 | 19 | 4,35 / 10,85 / 47,25 CHF | 34,0 % |
| Scale | 4 000 | 920 | 368 | 61 | 13,91 / 34,78 / 151,20 CHF | 33,7 % |
| Enterprise (défaut 10 000) | 10 000 | 2 299 | 920 | 153 | 34,78 / 86,90 / 378,00 CHF | sur contrat |
| *Starter* (hérité) | 150 | 34 | 14 | 2 | 0,53 / 1,29 / 5,67 CHF | 14,5 % |
| *Business* (hérité) | 600 | 138 | 55 | 9 | 2,08 / 5,22 / 22,68 CHF | 22,9 % |
| *Pro* d'avant la grille (1 500) | 1 500 | 345 | 138 | 23 | 5,22 / 13,04 / 56,70 CHF | 40,8 % (voir ci-dessous) |

**Règle des 35 % (section 5) : les fenêtres ne la changent pas, elles ne peuvent que la servir.** Le plafond du mois reste le troisième plafond, actif en plus des deux autres : quel que soit le chevauchement des fenêtres (jusqu'à 5 semaines glissantes peuvent démarrer dans un même cycle), un cycle ne consomme jamais plus que les crédits du mois, donc le coût IA au pire cas est celui du tableau de la section 5. Les fenêtres ne servent pas à tenir la marge : elles servent à **lisser** l'usage (un client ne vide plus son mois en une journée, et l'exposition d'une journée est bornée à la session : au plus 0,87 CHF d'IA par session pour Solo, 3,14 CHF pour Équipe). Le seul chiffre au-dessus de 35 % du tableau est le Pro d'avant la grille (1 500 crédits pour CHF 139, 40,8 %) : c'est le maintien des conditions d'origine décidé en section 1, qui date d'avant les fenêtres et que les fenêtres ne modifient pas ; il se règle avec le préavis de 30 jours.

Derniers détails : une session ne dépasse jamais la semaine, ni la semaine le mois (petit contrat). Une allocation absente, négative ou illisible vaut 0 et la mission est refusée (jamais « tout est permis »). Enterprise : les fenêtres se déduisent du plafond du contrat (`contractCredits`), ou sont fixées sur mesure par `POST /api/admin/set-plan` avec `"usageOverride": {"sessionCredits": 1200, "weekCredits": 3000}` (Enterprise seulement ; `USAGE_OVERRIDE_NOT_ALLOWED` pour un autre forfait ; effacé à un changement de forfait).

### 6.2 Les règles exactes (tout en UTC)

- **La fenêtre s'ouvre à la première réservation qui passe** (`début = maintenant`, `fin = début + 4 h` pour la session, `+ 7 j` pour la semaine). Pendant la fenêtre, les crédits consommés s'accumulent. À l'instant exact de la fin (`maintenant ≥ fin`), la fenêtre est refermée ; la suivante s'ouvre à la prochaine réservation (il n'y a pas de fenêtre « vide » qui court). Une réservation libérée sans aucun crédit consommé referme la fenêtre qu'elle avait ouverte : un incident au premier appel n'ouvre pas de session.
- **Le mois** est le cycle de facturation existant (section 3), pas une fenêtre glissante.
- **Réservation atomique** : le contrôle des trois fenêtres et leur mise à jour se font dans la même section critique, par client (verrou de fichier entre le serveur et `quota-check.py`, qui est un autre processus). Deux missions et trois étapes simultanées ne peuvent pas dépasser une fenêtre. Une mission réserve ses crédits **avant** de lancer le sous-processus, et les règle sur les crédits réellement tracés à la fin (0 si elle n'a rien livré, règle de la section 3). Une réservation oubliée (processus tué) est libérée à l'échéance : mission 12 minutes, étape de projet 15, automatisation 5 ; au démarrage du serveur, les réservations de missions orphelines sont libérées tout de suite. Dans les deux cas, ce que la mission avait déjà livré est recompté d'après ses traces à la prochaine écriture du grand livre (réconciliation avancée) : une mission livrée juste avant un arrêt n'est jamais offerte.
- **Grand livre O(1)** : un fichier par client, `runtime/usage/<ClientId>.json` (schéma `BK-USAGE-LEDGER-V1`), jamais un balayage des fichiers `TASK-*.json` à chaque appel. Les traces font foi : `reconcile` (au plus toutes les 6 heures par client actif, et à la demande) recalcule le mois, la session et la semaine à partir de `runtime/tasks/TASK-*.json` (`task_credits`) et des règlements de projet, **corrige le cache, jamais les traces**, et journalise l'écart. `creditsUsed` de `GET /api/billing` vient du grand livre (le balayage ne subsiste que dans la réconciliation et dans un test qui compare les deux). Un grand livre illisible ne coupe jamais le service : on journalise et la mission passe (le quota du mois d'origine reste appliqué).
- **Horloge** : injectée dans le service (tests) ; une horloge qui recule ne referme rien et n'efface aucun compteur ; un saut en avant referme les fenêtres échues.
- **Changement de forfait en cours de fenêtre** : une montée en gamme élargit tout de suite les trois fenêtres (les crédits déjà consommés restent comptés) ; une descente les réduit sans rien rembourser ; les fenêtres de session et de semaine **ne sont pas remises à zéro** (comme Claude). Un nouveau cycle (renouvellement, nouveau forfait) repart avec un mois neuf. Les anciens abonnés (Starter, Business, Pro et Scale d'avant la grille) suivent leurs crédits d'origine (tableau ci-dessus), par le même calcul.
- **Isolation** : un grand livre par `ClientId` ; l'identifiant est validé avant tout accès au disque ; la suppression du compte efface le grand livre et l'export du compte l'inclut.
- **Qui passe par la porte** : `submit_task` (point d'entrée unique des missions : routes Worker, Chloé, asynchrones, WhatsApp, API) réserve `crédits du niveau × Workers que Chloé peut appeler` (la réservation partielle réduit le nombre de Workers que Chloé appelle plutôt que de refuser) ; les automatisations (`dashboard/quota-check.py` → `usage-cli.py charge`) débitent 1 crédit et **sautent sans erreur** quand une fenêtre est pleine (elles repassent au tick suivant) ; les étapes de projet (moteur d'autonomie, section 6.3 de `docs/AUTONOMY-ENGINE.md`) réservent avant chaque étape et, fenêtre atteinte, passent le projet en `WAITING_QUOTA` avec l'heure de reprise au lieu d'échouer. Un mode « plan seulement » ne réserve rien (aucun crédit).

### 6.3 Ce que le client voit

Refus d'une mission, `402 USAGE_LIMIT_REACHED` pour la session et la semaine (le mois garde `402 SUBSCRIPTION_REQUIRED`, déjà géré par l'interface) ; le message nomme la limite, ce qui reste, l'heure exacte de renouvellement dans le fuseau du client, la durée et le forfait du dessus avec ses chiffres :

> Vous avez utilisé votre quota de session (83 crédits). Il se renouvelle à 14:12 (dans 1 h 12). Pour continuer sans attendre, passez au forfait Pro (115 crédits par session).

> Il vous reste 5 crédit(s) dans votre quota de session, ce niveau en demande 12. Il se renouvelle à 14:12 (dans 1 h 12). Choisissez un niveau plus rapide, attendez le renouvellement ou passez au forfait Pro (115 crédits par session).

```json
{"error": "USAGE_LIMIT_REACHED", "limit": "session", "needed": 12, "remaining": 5, "resetsAtUtc": "2026-10-20T12:12:00Z",
 "detail": "Vous avez utilisé votre quota de session …",
 "usage": {"… comme GET /api/usage": ""}, "upgrade": {"planId": "pro", "planName": "Pro", "priceChf": {"month": 139, "year": 1390},
          "limits": {"session": 115, "week": 287, "month": 1250}, "onQuote": false, "selfService": true}}
```

`GET /api/usage` (compte client ; le propriétaire reçoit `exempt: true` et aucune fenêtre) : `session`, `week` (`limit`, `used`, `reserved`, `remaining`, `opened`, `startUtc`, `resetsAtUtc`), `month`, `binding` (la fenêtre qui borne), `allowedNow`, `nextRenewalUtc`, `upgrade` (forfait du dessus et ses limites), `activeReservations`. `GET /api/billing` porte le même bloc `usage`, les cartes de forfait portent leurs `limits`, et `upgrade.next.limits` donne celles du forfait suivant. `GET /api/usage-limits` (public, sans compte) donne les plafonds de session et de semaine de chaque forfait vendu pour la page Tarifs.

### 6.4 Les messages et l'interface (anglais par `i18n-en-app.js`, lisible à 375 px)

- **Vue Facturation** : bloc « Vos limites d'usage » avec deux jauges (Session 4 h, Semaine) : crédits utilisés / limite, crédits restants, heure de renouvellement avec compte à rebours (« à 14:12 (dans 1 h 12) ») ou « Démarre à votre prochaine mission » quand la fenêtre n'est pas ouverte ; **à partir de 80 %** le texte d'alerte et le bouton **« Passer à <forfait> »** avec les limites du forfait du dessus ; à 100 %, « Quota de session atteint : vous pourrez lancer de nouvelles missions à 14:12 ». Le niveau (normal, alerte, plein) est écrit en toutes lettres : la couleur n'est jamais la seule information. Chaque jauge est un `progressbar` annoncé aux lecteurs d'écran (« 72 sur 83 crédits utilisés, 11 restants »).
- **Pastille de la barre du haut** (bouton, atteignable au clavier) : la fenêtre la plus avancée (« Session 87 % »), un anneau, `aria-label` complet, ouvre Facturation.
- **Refus** dans le chat d'un Worker, de Chloé et des automatisations : le message du serveur, le prochain renouvellement avec compte à rebours, les limites du forfait du dessus et le bouton de montée en gamme.
- **Page Tarifs, FAQ et page Facturation** (`/tarifs.html`, `/faq.html`, `/facturation.html`, `dashboard/seo_pages.py`, et la vue Tarifs de l'application) : chaque carte de forfait affiche « 83 crédits par session de 4 h · 207 par semaine » sous ses crédits du mois ; un encadré dit que chaque forfait est **un prix mensuel plus des limites d'usage** et qu'**aucun forfait n'est illimité** ; une question de FAQ explique ce qui se passe à la limite. **Ces textes n'apparaissent que si les fenêtres s'appliquent réellement (`BK_USAGE_WINDOWS=1`)** : aucune page n'annonce une limite qui ne soit pas appliquée.
- Les mentions de l'essai public (« sans limite ») ont été reformulées : aucun texte du site ne laisse entendre un usage illimité.

### 6.5 Mise en service (interrupteur `BK_USAGE_WINDOWS`)

| Valeur | Effet |
|---|---|
| `0` (défaut) | service inerte : seul le mois borne, **aucune réponse existante ne change** (testé), aucune jauge, aucune page modifiée |
| `shadow` | le grand livre tourne, **rien n'est bloqué**, chaque refus qui aurait eu lieu est journalisé (`usage_would_block`, avec la fenêtre, le forfait et l'heure) ; sert à calibrer les constantes sur sept jours de vraies données avant de freiner un client. `BK_PROJECTS=1` impose au moins `shadow` (les crédits des projets ne sont pas des fichiers `TASK-*.json`) |
| `1` | actif : refus `USAGE_LIMIT_REACHED`, jauges, pages et FAQ |

Retour arrière : `BK_USAGE_WINDOWS=0` (puis `docker compose up -d`), sans perte de données. **Les fenêtres durcissent les conditions des abonnés existants** : les CGV (art. 4 et 8) demandent 30 jours de préavis effectif au renouvellement suivant ; l'activation se fait d'abord pour les nouveaux abonnements, le préavis des autres est une décision du propriétaire (section 7).

### 6.6 Valeurs à confirmer par le propriétaire

4 heures de session et 7 jours de semaine ; 40 % de la semaine par session ; diviseur 4,35 ; plancher de 12 crédits (au pire une session de Solo vaut 3 missions Équilibre : c'est le prix de la protection contre un client qui vide son mois en une journée). Ces valeurs sont des **réglages**, pas du code : on les change dans `core/usage/USAGE-LIMITS.json` (redémarrage) après la période `shadow`.

### 6.7 Ce qui reste à relier

Le moteur de projets (`docs/AUTONOMY-ENGINE.md`) appelle la même interface Python (`remaining`, `reserve`, `settle`, `release`, `charge`, `next_renewal`) ; la reprise automatique de `WAITING_QUOTA` et son interface appartiennent à ce moteur et ne sont pas livrées ici. Rien n'en est annoncé tant que ce moteur n'est pas construit et testé.

## 7. Ce qui n'est PAS construit (décisions ouvertes)

- **Moteur d'IA par mission** (2026-10-25, `docs/PROVIDERS.md`) : l'essai gratuit tourne sur un modèle local (coût 0) quand le propriétaire l'a configuré, un repli vers un autre moteur ne coûte **aucun crédit**, et le propriétaire peut fixer un plafond de dépense Claude (jour / mois). **Décision ouverte** : les crédits d'une mission en **clé personnelle** du client (BYOK). Livré : ils restent ceux du forfait ; alternatives et recommandation dans `docs/PROVIDERS.md` §8.
- **Fenêtres hebdomadaire et de session** : **construites** (section 6) et inertes par défaut (`BK_USAGE_WINDOWS=0`). Reste à décider : l'activation (ombre puis actif), les constantes (4 h, 40 %, 4,35, plancher 12), et le préavis de 30 jours pour les abonnés existants (CGV art. 4 et 8).
- Paquets de crédits : **décidé : il n'y en a pas** (l'étude recommandait CHF 12 les 100 crédits ; le propriétaire a choisi le passage au forfait supérieur).
- Facturation du **téléphone et de WhatsApp** en crédits (1,5 crédit par minute dans l'étude) : le numéro et WhatsApp pour les clients de nos clients ne sont pas en production ; rien n'est annoncé ni facturé. L'essai n'inclut aucune minute de téléphone (`phoneMinutes: 0`).
- **Suivi des abonnements Stripe (sans webhook)** : le serveur relit chaque abonnement Stripe par le pont, en lecture seule (`Stripe-Bridge.ps1 -Action get-subscription`), toutes les 6 heures (`STRIPE_SYNC_INTERVAL_S`, premier passage 10 minutes après le démarrage, un client à la fois) et à la demande du propriétaire (`POST /api/admin/stripe-sync`, `{"clientId"}` ou tous). Abonnement `canceled`, `unpaid`, `incomplete_expired` ou introuvable (404) : retour immédiat à l'Essai (l'essai n'est pas renouvelable) ; résilié dans le tableau de bord Stripe : fin de période enregistrée ; résiliation annulée : reprise ; `past_due` : l'accès reste ouvert pendant que Stripe relance le paiement, une ligne d'historique le signale, et l'abonnement s'arrête quand Stripe le passe à `unpaid` ou `canceled`. **À régler dans Stripe** (Réglages, Abonnements, Relances de paiement) : « résilier l'abonnement » ou « marquer comme impayé » après les relances, sinon un abonnement `past_due` garde son accès sans limite. Un webhook signé (`invoice.payment_failed`, `customer.subscription.deleted`) reste préférable pour réagir en minutes : il demande un secret de signature à ajouter, non construit. **Pour les forfaits activés sur facture, c'est réglé** : ils portent une fin de période payée (`paidMonths`) et retombent à l'Essai tout seuls, sauf reconduction par le propriétaire (`docs/HIRE-API.md`). **Ancien abonnement non annulé après une montée en gamme** : si Stripe ne répond pas au moment d'annuler l'ancien abonnement (avec prorata), son identifiant est retenu (`staleStripeSubscriptions`, 10 au plus) et l'annulation est retentée à chaque passage du suivi ci-dessus (ou par `POST /api/admin/stripe-sync`) jusqu'à ce qu'elle aboutisse ou que Stripe dise qu'il est déjà arrêté ; tant qu'il en reste un, la suppression du compte est refusée (`409 STRIPE_CLEANUP_PENDING`), sinon l'abonnement continuerait de facturer sans plus aucun moyen de l'annuler.
- **Textes juridiques** (décision du propriétaire, non modifiés ici) : les CGV (art. 5, 6) parlent de paiement par carte via Stripe et d'abonnements mensuels ; elles ne mentionnent ni l'activation sur facture (Solo, Trio, Équipe et Pro/Scale sans Stripe) ni les abonnements annuels. À compléter, par exemple : « Les abonnements peuvent aussi être réglés sur facture ; le plan est alors activé par BK-ENTREPRISE à réception du paiement pour la période facturée et prend fin à son terme si la facture suivante n'est pas réglée. »

## 8. Interface

- **Jauges et pastille d'usage** (`BK_USAGE_WINDOWS=1`) : voir la section 6.4 ; rien n'est affiché ni annoncé tant que les fenêtres ne s'appliquent pas.
- Page Tarifs (`PRICING_PLANS` dans `dashboard/app.js`, `renderPricing`) et page statique `/tarifs.html` (`PRICING_PLANS` dans `dashboard/seo_pages.py`) : la **même** liste que `PLAN_CATALOG` (test automatique). Solo dit « Choisissez le Worker de votre activité » ; Solo et Trio disent clairement que vous choisissez vos Workers (Trio inclut Chloé).
- Aide **« Quel Worker pour mon activité ? »** sous la grille (`ACTIVITY_WORKERS` dans `dashboard/app.js`) : boutique en ligne, restaurant ou commerce local, cabinet ou profession libérale, agence ou freelance, PME de services, artisan, association. Chaque correspondance vient du rôle et des services réels du Worker (`workers/<id>/identity/identity.json` et `workers/<id>/install-profile.json`) ; chaque résultat ouvre la fiche du Worker (où se trouve « Embaucher »). Aucun témoignage, aucun chiffre inventé.
- Page d'accueil : la phrase « au moins 5 % moins cher que les alternatives comparables » est retirée (non étayée, fausse face à plusieurs concurrents) ; elle est remplacée par un énoncé factuel (« Dès CHF 29 par mois, sans engagement »). **Aucune comparaison nommant un concurrent n'est publiée** : la publicité comparative demande l'accord du propriétaire et d'un juriste (loi contre la concurrence déloyale), avec chiffre, source et date.
- Chloé : `chloe/identity/playbook.md` (section TARIFS) et la consigne du routeur dans `chloe/Invoke-Chloe-Orchestration.ps1` citent la même grille ; `dashboard/phone-agent/CLI-DASHBOARD.md` (standard du propriétaire) aussi.

## 9. Tests

`tests/usage/` (fenêtres d'usage, section 6) : `test_usage_core.py` (le service sur une racine jetable, horloge injectée : allocations, ouverture à la première utilisation, secondes aux bornes, refus qui nomment la fenêtre, concurrence entre fils et entre processus, changement de forfait, réservations échues, amorçage et réconciliation sur 200 traces, dérive d'horloge), `test_usage_wiring.py` (le vrai `server.py` : porte des missions, 402, `get_billing`, Chloé, anciens forfaits, Enterprise sur mesure, automatisations, suppression et export du compte, grand livre illisible), `e2e_server.py` (vrai serveur HTTP sur une copie jetable, deux comptes, pages et interface ; `python tests/usage/e2e_server.py`, sans modèle, sans réseau, sans secret).

`tests/pricing/` (voir l'en-tête de chaque fichier) : `test_pricing.py` (catalogue, quota, niveaux, paiement, ratio de coût), `test_billing_review.py` (revue du 2026-10-13 : confirmation Stripe idempotente, résiliation en fin de période, période payée sur facture, anciens abonnés Pro/Scale, crédits des missions livrées), `test_billing_review2.py` (2e revue : grâce sans crédits neufs, anciens abonnés sans preuve de paiement, plafond Enterprise conservé, suivi des abonnements Stripe, client Stripe réutilisé, garde-fous de `stripe-confirm`, suppression de compte après résiliation, corps mal typés), `test_site_consistency.py` (aucun ancien prix, une seule liste, aide par activité, anglais), `test_stripe_fields.py` (montants Stripe, PowerShell), `test_automation_level.py` (automatisations au niveau Rapide, 1 crédit ; PowerShell 7), `e2e_server.py` (vrai serveur HTTP sur une copie jetable). Les attentes des suites `tests/levels` et `tests/hire` ont été mises à jour **uniquement** là où l'échelle de crédits ou le catalogue sont affirmés (commentaire « Expectation changed on 2026-10-12 »).
