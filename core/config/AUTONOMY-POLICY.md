# BK-AI-WORKERS — POLITIQUE D'AUTONOMIE PAR WORKER (V2)
Révisée le 2026-09-14 suite au retour de Kader — remplace la V1.
Basée sur les vraies paires outil+action de
`core/permissions/capability-matrix/CAPABILITY-MATRIX.json`.

## Application réelle (2026-09-15)

Cette politique est désormais VÉRIFIÉE, pas seulement documentée :
`orchestrator/runtime/Invoke-Orchestrator.ps1` détecte l'intention
d'action (envoie/publie/supprime/exécute) dans la demande et refuse
l'exécution directe si l'action correspondante figure dans
`chloeVerificationRequired` du `contract.json` du Worker concerné —
la demande doit alors passer par
`chloe/Invoke-Chloe-Orchestration.ps1` (qui a sa propre étape REVIEW).
Testé : une demande solo "envoie un email" est bloquée
(`NEEDS_CHLOE_VERIFICATION`), la même demande via Chloé aboutit
normalement.

## Principe V2

- **Autonome, aucune vérification** : READ, SEARCH, REPORT, CREATE, UPDATE.
- **Autonome côté Worker, mais vérifié par CHLOÉ avant exécution réelle** :
  DELETE, SEND, PUBLISH, EXECUTE (y compris les actions infra/sécurité de SAM).
  Chloé contrôle avant que ça parte — Kader n'a plus à intervenir ici.
- **Validation humaine directe (Kader), seul cas restant** : tout ce qui
  touche l'argent (FINANCIAL_PREPARE / FINANCIAL_COMMIT — paiements,
  virements, engagements financiers). Rien d'autre ne remonte à Kader.
- **Envoi d'email centralisé** (2026-09-14, confirmé par Kader) : NOAH gère
  TOUT ce qui est email — lecture, rédaction, envoi. MAYA, ALEX, EMMA n'ont
  plus aucun accès à l'outil EMAIL (retiré, pas juste l'envoi) ; ils
  préparent leur contenu via DOCUMENTS et le transmettent à NOAH.

## Détail par Worker

### MAYA — Directrice Marketing & Growth

**Autonome, aucune vérification :**
- WEB_ANALYTICS.READ
- WEB_ANALYTICS.SEARCH
- WEB_ANALYTICS.REPORT
- WEB_ANALYTICS.CREATE
- CRM.READ
- CRM.SEARCH
- CRM.CREATE
- CRM.UPDATE
- SEARCH_ENGINE.READ
- SEARCH_ENGINE.SEARCH
- SEARCH_ENGINE.REPORT
- SOCIAL_MEDIA.READ
- SOCIAL_MEDIA.CREATE
- SOCIAL_MEDIA.UPDATE
- DOCUMENTS.READ
- DOCUMENTS.CREATE
- DOCUMENTS.UPDATE

**Autonome, vérifié par Chloé avant exécution réelle :**
- SOCIAL_MEDIA.PUBLISH

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### ALEX — Responsable Prospection & Sales

**Autonome, aucune vérification :**
- CRM.READ
- CRM.SEARCH
- CRM.CREATE
- CRM.UPDATE
- WEB_ANALYTICS.READ
- WEB_ANALYTICS.SEARCH
- WEB_ANALYTICS.REPORT
- SEARCH_ENGINE.READ
- SEARCH_ENGINE.SEARCH
- SEARCH_ENGINE.REPORT
- DOCUMENTS.READ
- DOCUMENTS.CREATE
- DOCUMENTS.UPDATE

**Vérification Chloé :** aucune action de ce type actuellement.

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### EMMA — Responsable Contenu & Social Media

**Autonome, aucune vérification :**
- SOCIAL_MEDIA.READ
- SOCIAL_MEDIA.CREATE
- SOCIAL_MEDIA.UPDATE
- DESIGN.READ
- DESIGN.CREATE
- DESIGN.UPDATE
- DOCUMENTS.READ
- DOCUMENTS.CREATE
- DOCUMENTS.UPDATE
- WEB_ANALYTICS.READ
- WEB_ANALYTICS.SEARCH
- WEB_ANALYTICS.REPORT

**Autonome, vérifié par Chloé avant exécution réelle :**
- SOCIAL_MEDIA.PUBLISH

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### LUCAS — Développement Web & Digital

**Autonome, aucune vérification :**
- WORDPRESS.READ
- WORDPRESS.CREATE
- WORDPRESS.UPDATE
- WEBFLOW.READ
- WEBFLOW.CREATE
- WEBFLOW.UPDATE
- WEB_ANALYTICS.READ
- WEB_ANALYTICS.SEARCH
- WEB_ANALYTICS.REPORT
- SEARCH_ENGINE.READ
- SEARCH_ENGINE.SEARCH
- SEARCH_ENGINE.REPORT
- DOCUMENTS.READ
- DOCUMENTS.CREATE
- DOCUMENTS.UPDATE

**Autonome, vérifié par Chloé avant exécution réelle :**
- WORDPRESS.PUBLISH
- WEBFLOW.PUBLISH

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### SAM — IT, Infrastructure & Cybersécurité

**Autonome, aucune vérification :**
- MONITORING.READ
- MONITORING.SEARCH
- MONITORING.CREATE
- MONITORING.UPDATE
- SECURITY_SCANNER.READ
- SECURITY_SCANNER.SEARCH
- CLOUD_INFRASTRUCTURE.READ
- CLOUD_INFRASTRUCTURE.SEARCH
- CLOUD_INFRASTRUCTURE.CREATE
- CLOUD_INFRASTRUCTURE.UPDATE
- DOCUMENTS.READ
- DOCUMENTS.CREATE
- DOCUMENTS.UPDATE

**Autonome, vérifié par Chloé avant exécution réelle :**
- SECURITY_SCANNER.EXECUTE
- CLOUD_INFRASTRUCTURE.EXECUTE

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### NOAH — Administration & Organisation

**Autonome, aucune vérification :**
- CALENDAR.READ
- CALENDAR.SEARCH
- CALENDAR.CREATE
- CALENDAR.UPDATE
- EMAIL.READ
- EMAIL.CREATE
- DOCUMENTS.READ
- DOCUMENTS.CREATE
- DOCUMENTS.UPDATE
- CRM.READ
- CRM.SEARCH
- CRM.CREATE
- CRM.UPDATE

**Autonome, vérifié par Chloé avant exécution réelle :**
- CALENDAR.DELETE
- EMAIL.SEND

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### LEA — Design & Branding

**Autonome, aucune vérification :**
- DESIGN.READ
- DESIGN.CREATE
- DESIGN.UPDATE
- DOCUMENTS.READ
- DOCUMENTS.CREATE
- DOCUMENTS.UPDATE
- SOCIAL_MEDIA.READ
- SOCIAL_MEDIA.CREATE
- SOCIAL_MEDIA.UPDATE
- WEB_ANALYTICS.READ
- WEB_ANALYTICS.SEARCH
- WEB_ANALYTICS.REPORT

**Vérification Chloé :** aucune action de ce type actuellement.

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### SEOYA — SEO & Search Intelligence

**Autonome, aucune vérification :**
- GOOGLE_SEARCH_CONSOLE.READ
- GOOGLE_SEARCH_CONSOLE.SEARCH
- GOOGLE_SEARCH_CONSOLE.REPORT
- WEB_ANALYTICS.READ
- WEB_ANALYTICS.SEARCH
- WEB_ANALYTICS.REPORT
- WORDPRESS.READ

**Vérification Chloé :** aucune action de ce type actuellement.

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### NORA — Customer Support

**Autonome, aucune vérification :**
- ZENDESK.READ
- ZENDESK.CREATE
- ZENDESK.UPDATE
- INTERCOM.READ
- INTERCOM.CREATE
- INTERCOM.UPDATE
- WHATSAPP_BUSINESS.READ
- WHATSAPP_BUSINESS.CREATE

**Vérification Chloé :** aucune action de ce type actuellement.

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### SOPHIE — RH & Recrutement

**Autonome, aucune vérification :**
- HR_PLATFORM.READ
- HR_PLATFORM.CREATE
- HR_PLATFORM.UPDATE
- LINKEDIN.READ
- LINKEDIN.CREATE
- GOOGLE_DRIVE.READ
- GOOGLE_DRIVE.CREATE

**Vérification Chloé :** aucune action de ce type actuellement.

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### DARIO — Finance & Contrôle de gestion

**Autonome, aucune vérification :**
- GOOGLE_DRIVE.READ
- GOOGLE_DRIVE.CREATE
- QUICKBOOKS.READ
- QUICKBOOKS.REPORT
- XERO.READ
- XERO.REPORT
- STRIPE.READ
- STRIPE.REPORT

**Vérification Chloé :** aucune action de ce type actuellement.

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### INES — Data & Analytics

**Autonome, aucune vérification :**
- WEB_ANALYTICS.READ
- WEB_ANALYTICS.SEARCH
- WEB_ANALYTICS.REPORT
- MONITORING.READ
- MONITORING.REPORT
- GOOGLE_DRIVE.READ
- GOOGLE_DRIVE.CREATE

**Vérification Chloé :** aucune action de ce type actuellement.

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### YANIS — Project Management / PMO

**Autonome, aucune vérification :**
- ASANA.READ
- ASANA.CREATE
- ASANA.UPDATE
- TRELLO.READ
- TRELLO.CREATE
- TRELLO.UPDATE
- MICROSOFT_TEAMS.READ
- MICROSOFT_TEAMS.CREATE
- MICROSOFT_TEAMS.REPORT

**Vérification Chloé :** aucune action de ce type actuellement.

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### CLARA — Juridique & Contrats

**Autonome, aucune vérification :**
- GOOGLE_DRIVE.READ
- GOOGLE_DRIVE.CREATE
- GOOGLE_DRIVE.UPDATE
- DROPBOX.READ
- DROPBOX.CREATE

**Vérification Chloé :** aucune action de ce type actuellement.

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### AMINA — Research & Intelligence

**Autonome, aucune vérification :**
- GOOGLE_DRIVE.READ
- GOOGLE_DRIVE.CREATE
- WEB_ANALYTICS.READ
- WEB_ANALYTICS.SEARCH
- WEB_ANALYTICS.REPORT
- MONITORING.READ
- MONITORING.REPORT

**Vérification Chloé :** aucune action de ce type actuellement.

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### THOMAS — E-commerce & Marketplace

**Autonome, aucune vérification :**
- SHOPIFY.READ
- SHOPIFY.CREATE
- SHOPIFY.UPDATE
- WOOCOMMERCE.READ
- WOOCOMMERCE.CREATE
- WOOCOMMERCE.UPDATE
- WEB_ANALYTICS.READ
- WEB_ANALYTICS.REPORT

**Vérification Chloé :** aucune action de ce type actuellement.

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.

### RAYAN — Automation & Integrations

**Autonome, aucune vérification :**
- MONITORING.READ
- MONITORING.REPORT
- SLACK.READ
- SLACK.CREATE
- GOOGLE_DRIVE.READ
- GOOGLE_DRIVE.CREATE

**Vérification Chloé :** aucune action de ce type actuellement.

**Validation Kader :** aucune — ce Worker ne touche pas l'argent.
### CHLOE — Agent maître / Orchestration

CHLOÉ ne possède aucune capability outil directe. Elle est le POINT DE
VÉRIFICATION pour toutes les actions SEND/PUBLISH/EXECUTE/DELETE des
17 Workers commerciaux — elle contrôle avant que ça parte réellement,
remplaçant l'ancienne validation Kader pour tout sauf l'argent.

**Autonome, aucune vérification :**
- SELECT_WORKER, ANALYZE_REQUEST, DECOMPOSE_TASK, DELEGATE_TO_WORKER,
  AGGREGATE_RESULTS, SYNTHESIZE_RESPONSE

**Rôle de vérification :**
- VERIFY_BEFORE_SEND, VERIFY_BEFORE_PUBLISH, VERIFY_BEFORE_EXECUTE,
  VERIFY_BEFORE_DELETE — sur les 17 Workers commerciaux.

**Validation Kader :** aucune au niveau orchestration — seul DARIO
(argent) remonte directement à Kader, jamais via Chloé.

## Intégrations externes réelles (à partir du 2026-09-15)

Jusqu'ici, aucun connecteur du catalogue (`CONTROLLED-CONNECTOR-CATALOG.json`)
ne faisait de vrai appel externe — tout restait en SIMULATION, verrouillé
en dur par `liveExecutionEnabled: false` (~70 modules, validateurs qui
échouent si ce flag passe à `true`).

Le 2026-09-15, Kader a donné son accord explicite pour lever ces
verrous côté intégrations. Décision d'implémentation :

- Plutôt que de basculer le flag global `liveExecutionEnabled` (ce qui
  casserait les ~70 validateurs conçus pour l'en empêcher, et n'activerait
  de toute façon rien de réel puisqu'aucun connecteur n'a de vrai
  adaptateur ni de vrais identifiants), les connecteurs passent en réel
  **un par un**, chacun avec son propre adaptateur testé.
- **SLACK** est le premier connecteur, adaptateur dédié
  (`core/integrations/Slack-Adapter.ps1`).
- **Le 2026-09-15 (même jour)**, Kader a demandé la couverture la plus
  large possible ("tous les connecteurs utilisables en entreprise").
  Deux moteurs génériques réutilisables ont été ajoutés :
  `core/integrations/Generic-REST-Adapter.ps1` (jeton/clé API simple —
  20 connecteurs : Trello, Asana, Monday, Zendesk, Intercom, Figma,
  HubSpot, Pipedrive, Webflow, Shopify, WooCommerce, WordPress, Dropbox,
  LinkedIn, Facebook, Instagram, TikTok, X, Meta Ads, WhatsApp Business)
  et `core/integrations/OAuth2-Adapter.ps1` (OAuth2 refresh_token — 10
  connecteurs : Gmail, Calendar, Drive, Search Console, Google Ads,
  Outlook Mail/Calendar, Teams, OneDrive, Salesforce). Soit **31
  connecteurs avec du code réel prêt** (sur 38 non-financiers).
  Détail plateforme par plateforme, dont ceux bloqués par une revue
  externe (LinkedIn, TikTok, X, WhatsApp Business, Canva — délai qui ne
  dépend pas de Claude ni de Kader) : voir
  `core/integrations/CONNECTOR-SETUP-GUIDE.md`.
- Chacun reste `NOT_CONFIGURED` (aucun appel tenté) tant que Kader n'a
  pas lui-même créé le compte/l'app nécessaire et stocké le identifiant
  via `.secrets/Store-Credential.ps1` — jamais vu par Claude.
- Les 5 connecteurs "génériques" du catalogue (CRM, SOCIAL_MEDIA,
  DESIGN, MONITORING, HR_PLATFORM) ne correspondent à aucun fournisseur
  réel précis et n'ont donc pas d'adaptateur — à traiter au cas par cas
  si un usage concret se présente.
- Chaque connecteur rendu réel reste soumis au **même gate d'autonomie**
  que tout le reste : une action SEND/PUBLISH déclenche toujours la
  vérification Chloé avant exécution, réelle ou simulée.
- **Session du 2026-09-15, même jour, suite** : Kader a effectivement
  connecté et fait vérifier (vrai appel API, pas juste un fichier
  présent) **19 connecteurs** un par un : Slack, Trello, Asana, Monday,
  Figma, HubSpot, Pipedrive, Intercom, Zendesk, Dropbox, Gmail, Google
  Calendar, Google Drive, Google Search Console, Microsoft Teams,
  Salesforce, Facebook, Instagram, Meta Ads. Scripts d'authentification
  OAuth dédiés créés au passage (`Connect-ZendeskOAuth.ps1`,
  `Connect-GoogleWorkspace.ps1`, `Connect-MicrosoftGraph.ps1`,
  `Connect-Salesforce.ps1`, `Connect-MetaGraph.ps1`,
  `Connect-MetaAds.ps1` dans `.secrets/`), tous conçus pour écrire le
  résultat directement en DPAPI en une seule exécution (aucune valeur
  retapée manuellement par Kader, aucune vue par Claude).
  Outlook Mail/Calendar/OneDrive restent bloqués (compte Microsoft
  personnel sans licence M365) ; Shopify/WooCommerce/WordPress/Webflow/
  Salesforce initialement pas de compte ou boutique fermée — Salesforce
  finalement connecté après coup. Détail complet, bugs trouvés et
  corrigés en cours de route (chemins vides, header Accept manquant,
  PKCE Salesforce, capture de la mauvaise requête OAuth) : voir la
  section "État réel" en tête de `CONNECTOR-SETUP-GUIDE.md`.
- **Exception qui ne bouge pas, quel que soit l'accord donné sur les
  intégrations :** PAYMENT (Stripe, PayPal) et ACCOUNTING (QuickBooks,
  Xero) restent désactivés (`enabled: false`). Ce n'est pas une question
  d'intégration mais d'argent — règle distincte et plus stricte,
  confirmée à plusieurs reprises : seul Kader valide directement un
  paiement ou une transaction, jamais un Worker ni Chloé.
