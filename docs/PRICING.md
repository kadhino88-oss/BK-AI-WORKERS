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
- Starter et Business restent dans le catalogue pour les abonnés existants : mêmes crédits, même prix, `legacy: true`, masqués de la page Tarifs et du choix de forfait (sauf pour celui qui y est déjà). Pour qu'un abonné hérité ne subisse **aucun changement silencieux**, sa mission lancée sans choix de niveau reste au niveau Rapide (1 crédit) comme avant l'activation des niveaux (`defaultLevel: "rapide"`) ; s'il choisit lui-même Équilibre ou Approfondi, il paie le coût de ce niveau.

## 2. Échelle de crédits et niveaux de travail

`core/ai/LEVELS.json` : **Rapide 1 · Équilibre 6 · Approfondi 12** crédits par mission, niveaux **actifs** (`"enabled": true`). Niveau par défaut : Équilibre.

| Règle | Où |
|---|---|
| L'essai est verrouillé sur Rapide (le client ne voit que ce niveau, le serveur ignore tout autre niveau demandé) | `levelLock` du forfait Essai, `normalize_level` |
| Les **automatisations** (missions récurrentes lancées par le planificateur) tournent toujours au niveau Rapide et coûtent **1 crédit**, pour que le quota reste parlant | `automation_level`, `dashboard/quota-check.py`, `core/automation/AUTOMATION-ENGINE.ps1` (variable `BK_MISSION_LEVEL`), `dashboard/Submit-Task.ps1` |
| Chaque Worker appelé par Chloé est facturé au niveau de la mission (un Worker de Chloé ne coûte plus un crédit quel que soit le niveau) | `dashboard/Submit-Task.ps1` |
| Le quota est contrôlé **au niveau demandé** sur toutes les routes de mission (une mission Approfondi ne passe pas avec le solde d'une mission Équilibre) | `subscription_blocks_mission(client_id, level)` |

**Interrupteur d'arrêt : `BK_LEVELS=0`** dans l'environnement du serveur (puis redémarrage). Retour à l'ancien comportement : un seul niveau, modèle léger, **1 crédit par mission** (automatisations comprises, `level` vide). `BK_LEVELS=1` force l'activation quel que soit le fichier. Sans variable, c'est `enabled` de `core/ai/LEVELS.json` qui décide.

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

- `POST /api/billing/plan` `{"planId", "interval": "month"|"year"}` : forfaits payables en ligne = Solo, Trio, Équipe, Pro, Scale. Le forfait n'est activé qu'**après le paiement vérifié côté serveur** (`/api/billing/stripe-confirm`). Un client qui monte de forfait par une nouvelle Checkout Session voit son ancien abonnement Stripe annulé une fois le nouveau confirmé (pas de double facturation).
- **Montant** (`plan_price_cents`, `Get-StripeCheckoutFields` dans `core/integrations/Stripe-Adapter.ps1`) : si un Price ID existe dans le secret Stripe (`prices` / `pricesAnnual`), il est utilisé tel quel (Pro, Scale, et les forfaits hérités : rien ne change pour eux). Sinon (Solo, Trio, Équipe) le serveur envoie le montant du catalogue en centimes de CHF (`price_data`, récurrent mensuel ou annuel). Un montant absent ou hors de CHF 1 à CHF 100 000 est refusé (`INVALID_AMOUNT`) : on n'invente jamais un prix.
- Sans Stripe configuré : Solo, Trio et Équipe ne basculent **jamais** gratuitement (`403 PLAN_BY_INVOICE`) ; le propriétaire les active après facture réglée (`/api/admin/grant-workers` pour Solo et Trio, `/api/admin/set-plan` pour Équipe, Pro, Scale, Enterprise). Pro et Scale gardent la simulation locale d'origine (comportement existant, à fermer quand Stripe est en production).
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
- Les valeurs sont des **hypothèses** : les recalibrer avec le registre de coûts réels (`docs/COST-LEDGER.md`) après 30 jours d'usage. Le plafond de coût par mission recommandé par l'étude (Équilibre CHF 0,50, Approfondi CHF 1,00) n'est pas construit.

## 6. Ce qui n'est PAS construit (décisions ouvertes)

- **Fenêtres hebdomadaire et de session** (comme les limites de 5 heures et de la semaine de Claude) : non construites. Aujourd'hui un client peut consommer tout son quota mensuel en une journée. Décision du propriétaire : les ajouter ou non, et avec quelles valeurs.
- Paquets de crédits : **décidé : il n'y en a pas** (l'étude recommandait CHF 12 les 100 crédits ; le propriétaire a choisi le passage au forfait supérieur).
- Facturation du **téléphone et de WhatsApp** en crédits (1,5 crédit par minute dans l'étude) : le numéro et WhatsApp pour les clients de nos clients ne sont pas en production ; rien n'est annoncé ni facturé. L'essai n'inclut aucune minute de téléphone (`phoneMinutes: 0`).
- Aucun webhook Stripe ne rétrograde un client dont le paiement échoue ou dont l'abonnement est résilié côté Stripe : tant que le forfait est actif dans le fichier de facturation, le quota se renouvelle chaque mois. Pour les forfaits activés sur facture, c'est au propriétaire de repasser le client à l'essai (`POST /api/billing/cancel` côté client, ou changer son forfait) s'il ne paie plus.

## 7. Interface

- Page Tarifs (`PRICING_PLANS` dans `dashboard/app.js`, `renderPricing`) et page statique `/tarifs.html` (`PRICING_PLANS` dans `dashboard/seo_pages.py`) : la **même** liste que `PLAN_CATALOG` (test automatique). Solo dit « Choisissez le Worker de votre activité » ; Solo et Trio disent clairement que vous choisissez vos Workers (Trio inclut Chloé).
- Aide **« Quel Worker pour mon activité ? »** sous la grille (`ACTIVITY_WORKERS` dans `dashboard/app.js`) : boutique en ligne, restaurant ou commerce local, cabinet ou profession libérale, agence ou freelance, PME de services, artisan, association. Chaque correspondance vient du rôle et des services réels du Worker (`workers/<id>/identity/identity.json` et `workers/<id>/install-profile.json`) ; chaque résultat ouvre la fiche du Worker (où se trouve « Embaucher »). Aucun témoignage, aucun chiffre inventé.
- Page d'accueil : la phrase « au moins 5 % moins cher que les alternatives comparables » est retirée (non étayée, fausse face à plusieurs concurrents) ; elle est remplacée par un énoncé factuel (« Dès CHF 29 par mois, sans engagement »). **Aucune comparaison nommant un concurrent n'est publiée** : la publicité comparative demande l'accord du propriétaire et d'un juriste (loi contre la concurrence déloyale), avec chiffre, source et date.
- Chloé : `chloe/identity/playbook.md` (section TARIFS) et la consigne du routeur dans `chloe/Invoke-Chloe-Orchestration.ps1` citent la même grille ; `dashboard/phone-agent/CLI-DASHBOARD.md` (standard du propriétaire) aussi.

## 8. Tests

`tests/pricing/` (voir l'en-tête de chaque fichier) : `test_pricing.py` (catalogue, quota, niveaux, paiement, ratio de coût), `test_site_consistency.py` (aucun ancien prix, une seule liste, aide par activité, anglais), `test_stripe_fields.py` (montants Stripe, PowerShell), `test_automation_level.py` (automatisations au niveau Rapide, 1 crédit ; PowerShell 7), `e2e_server.py` (vrai serveur HTTP sur une copie jetable). Les attentes des suites `tests/levels` et `tests/hire` ont été mises à jour **uniquement** là où l'échelle de crédits ou le catalogue sont affirmés (commentaire « Expectation changed on 2026-10-12 »).
