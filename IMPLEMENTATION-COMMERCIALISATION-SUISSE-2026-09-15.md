# Implémentation — Commercialisation Suisse (2026-09-15)

Rapport de la session du 2026-09-15, suite à la mission prioritaire
transmise par Kader (brief relayé depuis ChatGPT) : transformer les 19
connecteurs déjà connectés en produit commercialisable — **18 Workers →
Billing → Onboarding → Analytics → Checkout → lancement Suisse**.

Portée respectée : **aucun des 19 connecteurs déjà branchés n'a été
touché**, **aucun paiement réel n'a été exécuté ni configuré**, le mode
**LIVE reste désactivé**, et la sécurité (Identity / Session / Token /
RBAC / Authorization / Capability / Authority / Policy / Worker Task
Authority / Credential / Connector / Provider / Execution) n'a pas été
modifiée.

---

## Étape 1 — Catalogue Workers : vérifié, aucune correction nécessaire

Le brief affirmait qu'il manquerait un 18e Worker commercial. Vérification
faite sur le document source (`BK-AI-WORKERS-STRUCTURE-OFFICIELLE-
18-WORKERS.md`, 913 lignes) :

- Section 1 = **Chloé** (agent maître, pas un Worker commercial comme
  les autres)
- Sections 2 à 18 = les **17 spécialistes commerciaux** (Alex, Emma,
  Léa, Lucas, Maya, Noah, Sam, Séoya, Nora, Sophie, Dario, Inès, Yanis,
  Clara, Amina, Thomas, Rayan)
- Section 19 = **Atlas** (personnel/trading, explicitement exclu du
  catalogue commercial)

**"18" = Chloé + les 17 spécialistes.** Aucun Worker manquant. Confirmé
par :
- `core/runtime/worker-runtime/WORKER-REGISTRY.json` (17 commerciaux +
  `chloe` + `atlas`, `atlas` marqué type `trading`)
- `GET /api/workers` → 17 Workers (Chloé et Atlas correctement exclus du
  catalogue commercial, comme conçu)

Aucune modification de code nécessaire pour cette étape.

---

## Étape 2 — Billing (socle réel, aucun paiement)

**Nouveau, testé de bout en bout.**

### Backend (`dashboard/server.py`)
- `PLAN_CATALOG` : Essai (15 crédits), Starter (150), Business (600),
  Pro (1500), Scale (4000), Enterprise (illimité) — 1 crédit = 1 mission
  réellement traitée (compté depuis `runtime/tasks/`, jamais inventé).
- État persisté dans `core/billing/data/subscription.json` (plan actif,
  début de cycle, crédits bonus, historique horodaté).
- `GET /api/billing` — plan actif, consommation réelle du cycle en
  cours, seuil d'alerte à 80 % (`alertThresholdReached`), historique.
- `POST /api/billing/plan` — change de plan (upgrade/downgrade),
  réinitialise le cycle, journalise l'évènement. **Simulation** :
  aucun appel à un PSP.
- `POST /api/billing/cancel` — annule et revient au plan Essai.
- `POST /api/billing/recharge` — ajoute des crédits bonus à la demande
  (recharge volontaire) — jamais automatique, jamais de majoration
  silencieuse.

### Frontend (`dashboard/index.html`, `style.css`, `app.js`)
- Nouvelle vue `billing-view` (nav "Facturation") : plan actif, barre
  de consommation (rouge au-delà de 80 %), grille des plans
  disponibles avec bouton "Choisir", recharge, historique complet,
  bouton "Annuler l'abonnement" (masqué si déjà sur Essai).

### Vérifié en conditions réelles (navigateur)
- Changement Essai → Business : historique et quota mis à jour
  correctement (`1/600` crédits, `599` restants).
- Recharge de 50 crédits : total passé à `650`, entrée d'historique
  écrite.
- Annulation : retour à Essai, bouton "Annuler" disparaît, historique
  complet conservé.
- Connecteurs financiers (Stripe, PayPal, QuickBooks, Xero) confirmés
  `enabled: false` après toutes ces opérations.

L'architecture est prête à recevoir un vrai PSP (Stripe...) plus tard
sans reprise : il suffira de remplacer l'écriture locale par un appel
réel au moment du changement de plan / recharge.

### Mise à jour — Stripe branché en mode test (même session, après décision de Kader)

Kader a explicitement demandé le branchement ("je suis prêt, on
branche"), confirmé avoir un compte Stripe existant et choisi de
démarrer en **mode test**. Implémenté et testé avec de vrais paiements
test de bout en bout :

- `core/integrations/Stripe-Adapter.ps1` (nouveau) : crée une vraie
  Checkout Session Stripe (`New-StripeCheckoutSession`) — le client
  saisit sa carte **sur la page hébergée par Stripe**, jamais sur ce
  serveur, jamais vue par Claude. Vérifie côté serveur qu'un paiement
  est réellement passé avant d'activer un plan
  (`Get-StripeCheckoutSession`). Annule un abonnement réel
  (`Remove-StripeSubscription`) — ajouté en cours de session après
  avoir repéré que "Annuler l'abonnement" ne faisait au départ que
  réinitialiser l'affichage local sans toucher au vrai abonnement
  Stripe.
- `dashboard/Stripe-Bridge.ps1` (nouveau) : pont CLI (même convention
  que `Automation-Bridge.ps1`) — actions `status`, `create-checkout`,
  `confirm`, `cancel-subscription`.
- `dashboard/server.py` : `POST /api/billing/plan` crée une vraie
  Checkout Session quand Stripe est configuré et le plan est payant
  (Starter/Business/Pro/Scale) — le plan local n'est activé qu'après
  `POST /api/billing/stripe-confirm`, qui revérifie le paiement
  directement auprès de Stripe (jamais sur la seule foi des paramètres
  d'URL du retour client). `POST /api/billing/cancel` annule le vrai
  abonnement Stripe si un plan payant est actif. Nouvelle route
  `GET /api/billing/stripe-status`.
- Secret stocké par Kader lui-même via
  `.secrets\Store-Credential.ps1 -Provider stripe` (clé secrète,
  clé publique, Price IDs Stripe des 4 plans payants) — jamais vu
  par Claude, chiffré DPAPI comme les 19 autres connecteurs.
- `dashboard/index.html` / `style.css` / `app.js` : badge "Stripe
  branché — mode test" sur la vue Facturation, redirection vers la
  page Stripe au clic sur "Choisir" un plan payant, gestion du retour
  (`?billing_checkout=success|cancel`).

**Vérifié avec de vrais paiements test (carte `4242 4242 4242 4242`,
49 CHF/mois Starter) :**
- Checkout réel ouvert sur `checkout.stripe.com`, montant et nom de
  produit corrects.
- Paiement confirmé → historique : *"paiement Stripe confirmé"* → plan
  activé seulement à ce moment (vérifié : reste sur Essai tant que le
  paiement n'est pas passé).
- "Annuler l'abonnement" → abonnement réellement annulé côté Stripe
  (`subscription.status: canceled`, vérifié par relecture directe de
  l'API Stripe) → historique : *"abonnement Stripe réellement annulé"*.
- Compte test Stripe recontrôlé propre en fin de session (0 abonnement
  actif restant).
- Tant qu'aucun vrai PSP n'est configuré, le comportement reste
  inchangé (simulation locale, comme documenté plus haut) — testé
  aussi (bascule automatique confirmée).

---

## Étape 3 — Onboarding (flux réel, validation avant exécution)

**Nouveau, testé de bout en bout.**

Flux implémenté : `Entreprise → Objectif → Analyse Chloé (PlanOnly) →
Proposition d'équipe → Validation utilisateur → Exécution réelle →
Résultat`.

### Backend
- `chloe/Invoke-Chloe-Orchestration.ps1` : nouveau switch `-PlanOnly`
  qui retourne la sélection de Workers (`SelectedWorkers`,
  `Status: "PLANNED"`) **avant** la phase EXECUTE — aucune exécution
  tant que l'utilisateur n'a pas validé.
- `dashboard/Submit-Task.ps1` : relaie `-PlanOnly` à Chloé.
- `dashboard/server.py` : nouvelle route `POST /api/chloe/plan`
  (aperçu, sans exécution) en complément de `POST /api/chloe/task`
  (exécution réelle, appelée seulement après validation).

### Frontend
- Nouvelle vue `onboarding-view` (nav "Démarrer") en 4 étapes avec
  indicateur de progression : profil entreprise → objectif → équipe
  proposée par Chloé (portraits réels) → résultat de la mission.

### Vérifié en conditions réelles (navigateur)
- Objectif "prépare une campagne marketing et améliore le référencement
  SEO" → Chloé propose réellement **Maya + Séoya** (portraits affichés).
- Validation → exécution réelle via le pipeline existant → résultat
  affiché ("Traité par : MAYA, SEOYA").
- Objectif non reconnu → message d'erreur clair invitant à reformuler
  (`NO_WORKER_MATCHED`), pas de blocage silencieux.
- Retour au dashboard fonctionnel, état réinitialisé à chaque nouvelle
  entrée dans le flux.

---

## Étape 4 — Analytics (données réelles, gains toujours "estimés")

**Nouveau, testé de bout en bout** (construit avant Onboarding/Billing
dans cette session, toujours valide).

- `GET /api/analytics` agrège les **vraies** données de
  `runtime/tasks/` (74 missions réelles au moment du test) et
  `core/automation/data/automations.json` — aucun chiffre inventé.
- Seul le "temps gagné" est une estimation, explicitement labellisée :
  *"Estimation indicative : 12 min/mission traitée (hypothèse
  conservatrice, non mesurée individuellement)"* — conforme à la
  consigne "ne jamais présenter comme vérité un gain non mesuré".
- Vue `analytics-view` : cartes de stats, graphique par Worker
  (trié par volume), graphique par statut (couleur par état),
  note de temps estimé.

---

## Étape 5 — UX

Le style Delos-inspiré (clair/premium, portraits en pied, Chloé
centrale) a été conservé et étendu de façon cohérente aux nouvelles
vues (Onboarding, Billing) — mêmes tokens de couleur, mêmes composants
de carte, même filtre de portrait.

### Mise à jour — chantier "site complet" (même session, après comparaison directe avec Delos et Limova)

Kader a demandé une comparaison concrète avec deux concurrents directs
(delos.so, limova.ai, visités en direct) pour identifier ce qui manquait
pour que le site soit "complet". Six manques identifiés et traités :

1. **Séparation vitrine publique / produit** — le site entier était une
   SPA sans aucune authentification. Ajout d'une porte d'accès légère
   et autonome, sans toucher au système Identity/Session/RBAC existant
   (confirmé inadapté à un login humain — pure confiance service-à-
   service). Mot de passe partagé, hashé (PBKDF2-SHA256, 200 000
   itérations) via `.secrets/Set-DashboardGate.ps1` (défini par Kader,
   jamais vu par Claude), vérifié côté serveur
   (`dashboard/server.py` : `/api/gate/login`, `/api/gate/logout`,
   `/api/gate/status`, contrôle sur toutes les routes opérationnelles).
   Vitrine (accueil, catalogue, tarifs, FAQ, légal) reste ouverte à
   tous. **Bug réel trouvé et corrigé pendant les tests** : un
   `display: flex` sur `.gate-modal` écrasait l'attribut `hidden`
   (même spécificité CSS, la règle auteur l'emporte) — la modale
   restait visible en permanence tant que la porte était désactivée.
   Corrigé avec `.gate-modal[hidden] { display: none; }`.
2. **FAQ** — nouvelle vue avec 6 questions réelles (mode SIMULATION,
   validation Chloé, connexion des outils, facturation, données,
   résiliation).
3. **Pages légales** — CGV, mentions légales, confidentialité, cookies
   rédigées avec `[A COMPLÉTER]` explicites pour les vraies infos
   d'entreprise de Kader (forme juridique, IDE/UID, adresse, TVA) — à
   compléter et faire relire avant publication réelle.
4. **Témoignages** — décision explicite de ne PAS fabriquer de faux
   avis clients (aucun client payant réel n'existe encore). À la
   place : section "Ce qui est déjà vrai aujourd'hui" avec des faits
   réels et vérifiables (nombre de connecteurs réellement configurés —
   calculé en direct depuis `.secrets/*.secret.dpapi`, jamais codé en
   dur — validation humaine systématique, sécurité). Emplacement
   `.testimonials-slot` prêt à recevoir de vrais témoignages plus tard.
5. **Footer** — refondu en colonnes (Produit, Légal) avec liens
   fonctionnels vers FAQ et pages légales.
6. **Différenciation visuelle vs Delos** (déjà demandée dans le brief
   initial, traitée cette fois) — police serif distinctive (Fraunces)
   pour les titres, accent bordeaux secondaire (`--accent-2`) sur les
   sections confiance/FAQ, détail signature (bordure dorée) sur les
   cartes Workers. L'or reste la couleur d'action principale pour ne
   pas perturber le parcours Billing déjà validé.

**Vérifié en conditions réelles** : porte testée avec mot de passe de
test (401 sans auth, 200 avec cookie, mauvais mot de passe rejeté,
session persistante après rechargement) puis avec le **vrai mot de
passe de Kader**, confirmé fonctionnel par lui directement dans son
propre navigateur. FAQ/légal/footer navigables sans connexion. Compteur
de connecteurs vérifié exact (26 au moment du test). Police et couleur
d'accent confirmées via styles calculés.

### Mise à jour — passage de vérification autonome (nuit du 2026-09-15 au 09-16)

Kader parti se coucher en demandant de continuer en autonomie sur les
tâches restantes utiles. Passage de régression complet effectué :

- **Bug réel trouvé et corrigé** : en dessous de 720px de large, la nav
  principale était entièrement masquée (`display: none`) **sans aucun
  menu de remplacement** — Automatisations, Analytics, Facturation et
  Chloé devenaient inaccessibles sur mobile (seuls Accueil, Workers,
  Tarifs et les liens du footer restaient joignables). Corrigé par
  l'ajout d'un bouton menu mobile (`#mobile-menu-btn`) qui affiche les
  mêmes liens de navigation existants en tiroir déroulant — aucun ID
  dupliqué, aucun nouveau gestionnaire de clic à dupliquer, réutilise
  telles quelles les routes de navigation déjà câblées.
- Vérifié à 375px (mobile) : menu ouvre tous les liens, se ferme au
  clic, navigation FAQ confirmée fonctionnelle depuis le menu mobile.
- Vérifié à 1280px (desktop) : bouton mobile bien masqué, nav complète
  inchangée — pas de régression sur le parcours existant.
- Aucune tâche supplémentaire lancée sans validation de Kader (aucun
  paiement réel, aucun envoi externe, aucun compte créé) — en attente
  de son retour sur l'export du projet Blink avant de poursuivre
  l'inspiration visuelle.

### Mise à jour — retours Kader du 2026-09-20

- **Bug de scroll corrigé** : le carrousel de l'accueil utilisait
  `scrollIntoView`, qui faisait aussi remonter la page à chaque tick
  (~2,4 s). Remplacé par un défilement horizontal du seul carrousel.
  Vérifié : position de page stable (700 → 700) sur 3 ticks.
- **Workers "vivants"** (page Workers) : respiration douce du portrait
  (décalée par Worker, désactivée si `prefers-reduced-motion`) + ligne
  d'activité alimentée par la dernière VRAIE mission du Worker
  (`/api/workers/<id>/activity`). Point vert pulsant seulement si une
  mission date de moins de 24 h (aucune activité inventée).
- **Logos réels** sur la bande "Branchés sur vos outils" (Simple
  Icons, couleurs officielles ; pastille à initiale pour Pipedrive et
  monday.com, sans logo libre). Connecteurs génériques (CRM, Design…)
  non affichés.
- **Images des Workers** : seuls Alex, Emma, Léa, Lucas, Maya, Noah,
  Sam ont un vrai poster haute qualité (~1024 px). Les 10 autres
  (Séoya…Rayan) ne sont que des recadrages de planches de groupe
  (612 px). Aucun poster individuel pour eux sur le disque → en
  attente des fichiers de Kader (à déposer sous
  `workers/<id>/identity/portrait-3d.jpg`, pris en compte tel quel).

- **Images (2026-09-21)** : les 10 posters reçus (Séoya, Sophie, Dario,
  Inès, Yanis, Clara, Amina, Nora, Thomas, Rayan) remplacent les
  portraits basse qualité, recadrés au-dessus du bandeau de texte comme
  les 7 premiers (1024 px de large partout). Nora : version bleu clair
  (la plus récente). Anciens fichiers sauvegardés dans
  `workers/_portrait-backup-2026-09-20/`. Reste : Lucas en 525×825
  (ancien recadrage) et Chloé (portrait hors `workers/`).

### Mise à jour — moteur IA réel (2026-09-21)

Constat : l'adaptateur OpenAI réel, la configuration
(`core/ai/AI-PROVIDERS.json`) et la clé DPAPI existaient, mais les
trois points d'appel (dashboard, Chloé, Orchestrateur) forçaient
`-Provider "NONE"` → réponse de secours systématique. Test réel de la clé :
**HTTP 429** (clé reconnue, compte sans crédit) — action de Kader requise
(recharger le compte OpenAI).

Fait : `core/ai/Get-DefaultProvider.ps1` (OPENAI si LLM activé + clé
présente, sinon NONE ; ne lit jamais la clé) branché aux 3 points
d'appel ; `Invoke-Worker-AI.ps1` traite `FALLBACK` comme mission
exécutée mais marquée `Degraded` (au lieu de `SECURITY_BLOCKED`) ;
prompt de l'adaptateur reconstruit depuis l'identité du Worker
(rôle, personnalité, style, contexte suisse, "prépare sans exécuter"),
`max_tokens` 300 → 900. Vérifié : mission Maya de bout en bout →
`EXECUTED`, `Degraded=True`, raison `OPENAI_EXIT_CODE_1` (429).

**Claude (Anthropic) branché (2026-09-21)** : l'adaptateur
`ANTHROPIC-ADAPTER.ps1` n'était qu'un stub → réécrit (API Messages, clé
DPAPI `anthropic.secret.dpapi`, modèle configurable dans
`AI-PROVIDERS.json`, défaut `claude-haiku-4-5-20251001`). Prompt commun
`Build-WorkerSystemPrompt.ps1`. Bug corrigé dans le moteur : la réponse
LLM était lue sur la dernière ligne de sortie de l'adaptateur (`}`), ce
qui aurait fait échouer toute vraie réponse — lecture de la sortie
complète. `Get-DefaultProvider` : ANTHROPIC > OPENAI > NONE.
`Store-Credential.ps1` accepte `-Provider anthropic`. En attente : clé
API Anthropic (crédits API distincts de l'abonnement Claude).

**Claude en production locale (2026-09-21) — vérifié** : clé
Anthropic stockée par Kader. Mission Maya seule → `ANTHROPIC`,
`Degraded=False`, vrai plan de campagne. Mission Chloé multi-Workers
("campagne marketing + SEO boutique Genève") → Maya + Séoya + Thomas,
3 réponses réelles (~4,7 k caractères chacune), synthèse de 14 k
caractères. `max_tokens` porté à 1800 (les réponses étaient tronquées à
900). Interface : les réponses de modèle ne sont plus insérées en HTML
brut (`escapeHtml` + `renderAnswer`, Markdown de base rendu) — vérifié
qu'un `<img onerror>` / `<script>` injecté s'affiche en texte.
**Améliorations faites (2026-09-21)** : (1) *profil entreprise* —
l'onboarding enregistre nom, secteur et activité
(`POST /api/profile`, protégé par la porte, fichier par ClientId dans
`core/profile/data/`, prérempli aux visites suivantes) ; ce contexte est
injecté dans le prompt de chaque Worker (`Build-WorkerSystemPrompt.ps1`).
(2) *Livrer d'abord* — nouvelle règle : résultat complet immédiat,
hypothèses annoncées en une ligne, 2-3 questions seulement en fin de
réponse. Vérifié (mission Maya, profil de test) : la réponse cite
l'entreprise, la Suisse romande et l'éco-responsabilité, énonce ses
hypothèses et ne commence pas par des questions. Profil de test supprimé.
Texte de l'onboarding corrigé : les infos sont transmises au fournisseur IA.

**Suivi du coût IA (2026-09-21, autonome)** : les adaptateurs relèvent les
tokens réels (`usage`), transmis moteur → `Invoke-Worker-AI` → fichier de
mission ; `get_ai_cost_summary()` (server.py) les agrège avec une table de
tarifs publics (Haiku 4.5 : 1 $/5 $ par M tokens ; gpt-4o-mini : 0,15/0,60 ;
modèle inconnu = pas de coût affiché, jamais deviné) ; 4 cartes dans
Analytics (appels IA, tokens, coût estimé, coût moyen/appel).
**Trou corrigé** : les missions passant par Chloé n'écrivaient aucune trace
(donc absentes des analytics ET du quota de crédits — usage gratuit
involontaire) ; `Submit-Task.ps1` écrit désormais un enregistrement par
appel Worker (`Origin: CHLOE`). Conséquence : une mission Chloé à 3 Workers
consomme 3 crédits (1 par appel Worker). Mesure initiale (3 appels réels) :
≈ 0,0075 $ par appel — échantillon minuscule, à confirmer sur plus de
missions avant de fixer les tarifs.

### Mise à jour — inspiration Delos (2026-09-20)

Blink non exploitable (pas d'export fourni) : Kader a demandé de
s'inspirer de delos.so. Ajouts sur l'accueil, en version propre à
BK-AI-WORKERS (pas de copie) : champ "trouver le bon Worker" dans le
hero (filtre le catalogue), comparatif "Chatbot classique vs
BK-AI-WORKERS" (5 lignes, factuel), bande d'intégrations alimentée par
les vrais connecteurs de `/api/connectors` (38 activés). Vérifié dans
le navigateur.

### Mise à jour — pages légales complétées (2026-09-16)

Kader a fourni ses vraies informations : BK-ENTREPRISE (entreprise
individuelle, 100% en ligne, BK-AI-WORKERS étant un produit de
BK-ENTREPRISE), Rue Joseph-Pasquier 1, 1203 Genève, contact@bk-entreprise.com,
+41 79 934 99 46, responsable de publication M. Christ Kader Berte.
CGV, mentions légales et confidentialité mises à jour (for juridique :
Genève ; TVA : non assujetti sous le seuil légal de CHF 100'000).
**Restent en attente** (2 champs `[A COMPLÉTER]`) : numéro IDE/UID (en
cours d'obtention) et hébergement (une fois hébergé publiquement).
À faire relire par un professionnel avant tout lancement public réel.

---

## Étape 6 — Sécurité

Aucune modification de :
- Identity / Session / Token / RBAC (`core/security/...`)
- Capability / Authority / Policy / Worker Task Authority
- Master Pre-Live Security Audit
- Mode LIVE (reste désactivé — confirmé `SIMULATION` actif sur
  `GET /`)

Le garde-fou existant (actions à risque type `SEND`/`PUBLISH`/`DELETE`/
`EXECUTE` renvoyées vers Chloé pour vérification) n'a pas été contourné
par les nouveaux flux : Onboarding passe systématiquement par
`Invoke-Chloe-Orchestration.ps1`, jamais directement par un Worker.

---

## Étape 7 — Validation (exécutée cette session)

| Vérification | Résultat |
|---|---|
| Serveur dashboard répond | ✅ `200` sur `/api/workers` |
| Catalogue commercial = 17 Workers | ✅ |
| Chloé exclue du catalogue commercial, accessible via `/api/chloe` | ✅ |
| Atlas exclu du catalogue commercial | ✅ |
| `/api/analytics` — données réelles | ✅ 74 missions, 17 Workers distincts |
| `/api/billing` — plan/quota réels | ✅ testé switch/recharge/cancel |
| `/api/chloe/plan` — proposition sans exécution | ✅ |
| `/api/chloe/task` — exécution réelle après validation | ✅ |
| Mode LIVE désactivé | ✅ `SIMULATION` actif |
| Connecteurs financiers du catalogue Worker désactivés | ✅ PayPal/QuickBooks/Xero `enabled: false` (Stripe reste `DISABLED` dans ce catalogue — le branchement Billing est un chemin dédié, initié par un humain, séparé du chemin Worker) |
| Stripe (Billing) — mode test, vrai paiement bout en bout | ✅ Checkout réel, activation post-paiement vérifiée, annulation réelle confirmée |
| Stripe (Billing) — repli simulation si non configuré | ✅ |
| 19 connecteurs déjà connectés non modifiés | ✅ |
| Porte d'accès — routes opérationnelles bloquées sans auth | ✅ `401` sur `/api/automations` |
| Porte d'accès — routes publiques ouvertes sans auth | ✅ `200` sur `/api/workers` |
| Porte d'accès — vrai mot de passe de Kader fonctionnel | ✅ confirmé par Kader dans son propre navigateur |
| FAQ / pages légales / footer accessibles sans connexion | ✅ |
| Compteur de connecteurs sur la page d'accueil — donnée réelle | ✅ 26, recalculé dynamiquement |

Aucune erreur bloquante restante.

---

## Fichiers créés

- `core/billing/data/subscription.json` (créé automatiquement au
  premier appel — état de facturation persisté)
- `core/integrations/Stripe-Adapter.ps1` — checkout/confirm/cancel
- `dashboard/Stripe-Bridge.ps1` — pont CLI vers l'adaptateur Stripe
- `.secrets/stripe.secret.dpapi` — créé par Kader lui-même (jamais vu
  par Claude)
- `.secrets/Set-DashboardGate.ps1` — définit le mot de passe de la
  porte d'accès (hash PBKDF2 uniquement, jamais vu par Claude)
- `dashboard/.gate/password.hash` — créé par Kader lui-même via le
  script ci-dessus
- `IMPLEMENTATION-COMMERCIALISATION-SUISSE-2026-09-15.md` (ce rapport)

## Fichiers modifiés

- `chloe/Invoke-Chloe-Orchestration.ps1` — ajout `-PlanOnly`
- `dashboard/Submit-Task.ps1` — relai `-PlanOnly`
- `dashboard/server.py` — routes `/api/chloe/plan`, `/api/billing`,
  `/api/billing/plan`, `/api/billing/cancel`, `/api/billing/recharge`,
  `/api/billing/stripe-status`, `/api/billing/stripe-confirm`,
  `/api/gate/login`, `/api/gate/logout`, `/api/gate/status` + fonctions
  billing + pont Stripe + porte d'accès + `configuredReal` dans
  `/api/connectors`
- `dashboard/index.html` — vues `onboarding-view`, `billing-view`,
  `faq-view`, `legal-view` + modale `gate-modal` + section confiance +
  footer refondu + liens nav "Démarrer" / "Facturation" / "FAQ" +
  badge statut Stripe + police Google Fonts (Fraunces)
- `dashboard/style.css` — styles onboarding + billing + FAQ + légal +
  confiance + footer + porte d'accès + accent bordeaux (`--accent-2`)
  + police d'accroche (`--font-display`)
- `dashboard/app.js` — logique onboarding + billing + FAQ/légal + porte
  d'accès (`checkGateStatus`, `requireGate`, `submitGatePassword`) +
  retour Checkout Stripe, wiring navigation
- `.secrets/Store-Credential.ps1` — ajout du provider `stripe`
  (ValidateSet + format JSON attendu)

## Décisions prises avec Kader (fin de session)

1. **Checkout** — tranché : Billing (changement de plan simulé, sans
   friction) tient lieu de Checkout tant qu'aucun vrai PSP n'est
   branché. Pas d'écran supplémentaire à construire pour l'instant.
   La feuille de route **18 Workers → Billing → Onboarding →
   Analytics → Checkout** est donc considérée complète côté
   fonctionnel/simulation.
2. **Différenciation visuelle vs Delos** (Étape 5) — traitée dans le
   chantier "site complet" ci-dessous (police, accent, détail cartes).

## Mise à jour — Stripe branché (fin de session, sur demande explicite de Kader)

Kader a demandé le branchement Stripe en cours de session ("je suis
prêt, on branche"). Fait en **mode test**, avec son accord explicite à
chaque étape (compte Stripe déjà existant, mode test confirmé avant de
commencer). Voir la mise à jour dans l'Étape 2 ci-dessus pour le détail
technique et les tests réels effectués.

## Prochaines étapes réelles (hors scope de cette session)

- **Passage en mode live** — nécessite que Kader relance
  `Store-Credential.ps1 -Provider stripe` avec ses clés `sk_live_...` /
  `pk_live_...` et les Price IDs de production. Aucun autre changement
  de code prévu. **Décision et action réservées à Kader.**
- **Inspiration visuelle Blink** — Kader a fait construire une
  plateforme de référence via Blink (blink.new) qu'il trouve très
  réussie. But confirmé avec lui : s'en inspirer pour affiner le style
  du dashboard existant (pas le remplacer). En attente de captures
  d'écran de sa part — accès direct impossible côté Claude (aperçu
  Blink nécessite sa connexion, CDN de publication bloqué depuis cet
  environnement).
- **Vrai lancement multi-clients** (comptes clients réels, OAuth par
  client, hébergement hors machine de Kader) — explicitement mis de
  côté par Kader tant que la plateforme actuelle n'est pas complète.
  Ce chantier "site complet" (porte d'accès, FAQ, légal, confiance,
  design) répond à cette condition.
- "Optimisation commerciale" (dernier point de la feuille de route
  initiale) — à définir une fois le lancement amorcé.


## Batterie de tests IA réelle (2026-09-21)
- 17 Workers testés avec une vraie mission chacun (Claude Haiku 4.5) : 17/17 livrent (Thomas a échoué une fois sans trace, puis 2 relances OK : incident ponctuel non reproduit).
- Latence 17–34 s ; 341–383 tokens en entrée, 567–1800 en sortie ; coût réel mesuré sur 18 appels : ~0,0072 USD/appel (0,13 USD au total).
- Réserve : Séoya, Maya (et Thomas sur une mission) atteignent le plafond de 1800 tokens, réponse possiblement tronquée. À arbitrer : monter le plafond (coût +) ou demander des livrables plus courts.
- Les fichiers de test de la batterie ont été supprimés de runtime/tasks pour ne pas fausser analytics/crédits.

## Prix, légal, portage Linux (2026-09-21)
- Prix appliqués (affichage) : Starter 39, Business 99, Pro 139, Scale 449 CHF/mois ; annuel 390/990/1390/4490 (2 mois offerts) ; faux prix barrés retirés ; offres : -30 % 2 mois, parrainage 1 mois, prix bloqué 12 mois pour les 20 premiers. Les prix Stripe réels restent à recréer (live).
- CGV réécrites (16 articles, droit suisse) d'après les CGV Limova ; confidentialité nomme Anthropic et Stripe ; placeholders IDE/hébergement retirés.
- Profil d'entreprise CLI-DASHBOARD renseigné (core/profile/data).
- Portage Linux : ~40 scripts du moteur convertis (BK_ROOT, chemins `/`), `core/ai/BK-Secret.ps1` (secrets env/fichier/DPAPI), serveur Python (BK_ROOT, BK_PWSH, BK_LISTEN_HOST, BK_GATE_HASH, BK_PUBLIC_URL), Dockerfile + docker-compose + Caddy, guide `deploy/DEPLOIEMENT-VPS.md`. Validé sous Windows (missions, Chloé, Stripe, automatisations) ; NON testé sous Linux (pas de Docker sur le poste). Sauvegarde des originaux : `_archive/pre-linux-port-2026-09-21/`.

- Test Linux réel (2026-09-21, Ubuntu 26.04 + PowerShell 7.6 sous WSL) : mission Claude OK, Chloé multi-Workers OK (Maya+Dario, synthèse 9k car.), serveur + porte d'accès OK, Stripe test OK, profil OK. Corrigés : dates JSON PowerShell 7 (DateKind String), casse des chemins Workers, accès stricts aux propriétés manquantes (Invoke-Worker-AI). Image Docker non testée (pas de Docker sur le poste).
