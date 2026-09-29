# BK-AI-WORKERS — Guide d'activation des connecteurs
## Écrit le 2026-09-15, suite à l'accord de Kader pour lever les verrous d'intégration

## État réel au 2026-09-15 (fin de session)

**19 connecteurs actifs et vérifiés** (appel API réel réussi, pas juste
un fichier de credential présent) :

Slack, Trello, Asana, Monday, Figma, HubSpot, Pipedrive, Intercom,
Zendesk, Dropbox, Gmail, Google Calendar, Google Drive,
Google Search Console, Microsoft Teams, Salesforce, Facebook,
Instagram, Meta Ads.

**Bloqués, avec raison précise (pas une histoire de config) :**
- **Outlook Mail / Outlook Calendar / OneDrive** — le compte Microsoft
  utilisé (kadhino88@outlook.com) est un compte personnel gratuit, sans
  licence Microsoft 365 / SharePoint Online. Erreur Graph exacte :
  `"Tenant does not have a SPO license"`. Credential DPAPI déjà en
  place (`outlook_mail`, `outlook_calendar`, `onedrive`) — si un
  abonnement Microsoft 365 est pris plus tard, relancer uniquement
  `Connect-MicrosoftGraph.ps1`, rien d'autre à refaire.
- **Shopify** — boutique fermée par Kader, laissé de côté.
- **WooCommerce / WordPress / Webflow** — pas de site sur ces
  plateformes actuellement.
- **Google Ads** — Developer Token séparé non demandé (les 4 autres
  connecteurs Google sont actifs).

**Non tentés (verrou externe ou coût, voir section 🔴 plus bas) :**
LinkedIn, TikTok, X, WhatsApp Business, Canva.

**Leçons de cette session (pour la prochaine tentative sur un
connecteur similaire) :**
- Toujours vérifier avec un vrai appel API (pas juste "le fichier
  existe") — plusieurs credentials collés au mauvais format ou avec le
  mauvais scope ont semblé "faits" avant d'échouer au test réel.
- Trello : la clé et le token doivent venir de la **même** session
  (ne pas rafraîchir la page entre les deux).
- Figma : le token doit avoir le scope **"Current user"**, pas
  seulement "File content", sinon `/v1/me` renvoie 403.
- Intercom : l'API exige un header `Accept: application/json` explicite
  (sinon 406) — corrigé dans `Generic-REST-Adapter.ps1`.
- Comptes Microsoft personnels (@outlook.com/@live.com) : Teams
  fonctionne, mais Mail/Calendar/OneDrive nécessitent une vraie licence
  Microsoft 365 (pas juste un compte gratuit).
- **Ne jamais coller un Client Secret / mot de passe en clair dans le
  chat** — même si la connexion réussit techniquement, le secret reste
  dans l'historique de conversation. Réflexe : régénérer le secret
  côté plateforme après coup si ça arrive (fait 2 fois cette session :
  Microsoft et Salesforce — les deux secrets exposés devraient être
  régénérés par précaution).
- Salesforce exige **PKCE** (code_challenge/code_verifier) en plus du
  flux OAuth standard, sinon erreur `missing required code challenge`.
- Bug trouvé dans les scripts `Connect-*.ps1` : le petit serveur local
  qui reçoit le code OAuth capturait parfois la **première requête**
  reçue sur le port (ex: favicon.ico), pas forcément le vrai retour
  OAuth, causant un faux "Aucun code reçu". Corrigé dans
  `Connect-Salesforce.ps1` (boucle jusqu'à trouver `code` ou `error`
  dans la requête) — à reporter dans les autres scripts `Connect-*.ps1`
  si l'un d'eux doit être relancé un jour.
- Si plusieurs fenêtres PowerShell lancent le même script OAuth en même
  temps, elles se disputent le port 8080 — toujours une seule fenêtre à
  la fois, et attendre le message vert final avant de la fermer.

---

### Comment ça marche

Le code est prêt pour les **38 connecteurs non-financiers** du catalogue
(`core/runtime/controlled-connectors/CONTROLLED-CONNECTOR-CATALOG.json`).
Chaque connecteur reste **inactif (NOT_CONFIGURED)** tant que tu n'as pas
toi-même :
1. Créé un compte / une app sur la plateforme concernée (Claude ne peut
   pas le faire à ta place — ça demande ton identité, ton numéro de
   téléphone, ou la vérification de ton entreprise selon les cas) ;
2. Récupéré la clé / le jeton demandé ;
3. Lancé toi-même, dans un terminal PowerShell (jamais via le chat) :
   ```powershell
   cd "C:\Users\FEUCOM\BK-AI-WORKERS\.secrets"
   .\Store-Credential.ps1 -Provider <nom>
   ```
   La valeur est chiffrée (DPAPI) et stockée localement — je ne la vois
   jamais, elle ne transite jamais par le chat.

Dès que le fichier `.secrets\<provider>.secret.dpapi` existe, le
connecteur devient réellement actif — **toujours filtré par le même
garde-fou d'autonomie que le reste** (une action d'envoi/publication
passe par la vérification de Chloé avant de partir, comme pour l'email).

### Légende

- 🟢 **Prêt aujourd'hui** — jeton généré instantanément dans les
  paramètres de ton compte, aucune app à créer, aucune attente.
- 🟡 **App à créer, faisable aujourd'hui** — tu crées une app/un
  "Connected App" toi-même (10-30 min), utilisable immédiatement sur
  ton propre compte, sans validation externe.
- 🔴 **Verrou externe (hors de notre contrôle)** — la plateforme
  elle-même (Meta, LinkedIn, TikTok, X...) impose une revue/validation
  ou un coût, qui prend du temps quoi qu'on fasse.
- 🔒 **Verrouillé exprès, ne change pas** — connecteurs financiers,
  activation impossible ici par choix (argent = toi uniquement).

---

## Parcours recommandé, étape par étape (dans cet ordre)

Fais-les dans cet ordre — du plus rapide au plus long, en groupant ce
qui partage la même app. Après chaque étape, lance
`.\Store-Credential.ps1 -Provider <nom>` avant de passer à la suivante.

### 1. Slack (déjà en cours)
1. slack.com → ton espace de travail → **Paramètres et administration**
   → **Gérer les applications** → **Créer une nouvelle app** (ou
   directement api.slack.com/apps → *Create New App* → *From scratch*).
2. Active **Incoming Webhooks**, clique **Add New Webhook to Workspace**,
   choisis le canal.
3. Copie l'URL (commence par `https://hooks.slack.com/services/...`).
4. `Store-Credential.ps1 -Provider slack` → colle l'URL.

### 2. Trello
1. trello.com/power-ups/admin (ou trello.com/app-key une fois connecté).
2. Note la **clé** affichée en haut.
3. Clique le lien **Token** sur la même page → **Autoriser**.
4. `Store-Credential.ps1 -Provider trello` → colle `{"key":"...","token":"..."}`.

### 3. Asana
1. app.asana.com → icône profil → **Paramètres** → **Apps** → onglet
   **Gestion des développeurs**.
2. **Créer un nouveau jeton d'accès personnel** → nomme-le → **Créer**.
3. `Store-Credential.ps1 -Provider asana` → colle le token.

### 4. Monday.com
1. Avatar (bas gauche) → **Administration** → **API**.
2. **Générer** en haut à droite → copie le jeton.
3. `Store-Credential.ps1 -Provider monday` → colle le token.

### 5. Figma
1. figma.com → icône profil → **Settings**.
2. Section **Personal access tokens** → **Generate new token**.
3. `Store-Credential.ps1 -Provider figma` → colle le token.

### 6. HubSpot
1. app.hubspot.com → icône ⚙️ **Paramètres** → **Intégrations** →
   **Applications privées**.
2. **Créer une application privée** → onglet **Scopes** → coche au
   minimum `crm.objects.contacts.read/write`.
3. **Créer l'application** → **Continuer** → copie le jeton affiché.
4. `Store-Credential.ps1 -Provider hubspot` → colle le token.

### 7. Pipedrive
1. pipedrive.com → avatar → **Paramètres personnels** → **API**.
2. Copie le **jeton API** affiché (ou régénère-le).
3. `Store-Credential.ps1 -Provider pipedrive` → colle le token.

### 8. Intercom
1. app.intercom.com → **Paramètres** → **Développeurs** →
   **Créer une app**.
2. Donne un nom → choisis ton espace de travail → **Créer**.
3. Onglet **Authentication** → copie le **Access Token**.
4. `Store-Credential.ps1 -Provider intercom` → colle le token.

### 9. Zendesk
1. Admin Center (icône ⚙️) → **Apps et intégrations** → **API** →
   **Jetons API**.
2. **Ajouter un jeton API** → copie-le (visible une seule fois).
3. Note aussi ton **sous-domaine** Zendesk (ex : `tonentreprise` dans
   `tonentreprise.zendesk.com`) et l'email de ton compte admin.
4. `Store-Credential.ps1 -Provider zendesk` → colle
   `{"subdomain":"tonentreprise","user":"ton-email","pass":"le-jeton"}`.

### 10. Dropbox
1. dropbox.com/developers/apps → **Create app** → Scoped access →
   Full Dropbox → nomme l'app.
2. Onglet **Permissions** → coche les scopes utiles (`files.content.read`
   etc.) → **Submit**.
3. Onglet **Settings** → **Generate access token**.
4. `Store-Credential.ps1 -Provider dropbox` → colle le token.

### 11-14. Si tu as une boutique/un site (sinon passe)
- **Shopify** : admin boutique → **Paramètres** → **Apps et canaux de
  vente** → **Développer des apps** → **Créer une app** → configure les
  scopes Admin API → **Installer** → copie le jeton `shpat_...`. Colle
  `{"shop":"nomboutique","token":"shpat_..."}`.
- **WooCommerce** : admin WordPress → **WooCommerce** → **Réglages** →
  **Avancé** → **API REST** → **Ajouter une clé** → permissions
  Lecture/Écriture. Colle `{"site":"tonsite.com","consumer_key":"ck_...","consumer_secret":"cs_..."}`.
- **WordPress** (site auto-hébergé) : profil utilisateur WP-admin →
  tout en bas, **Mots de passe d'application** → nomme-le → **Ajouter**.
  Colle `{"site":"tonsite.com","user":"tonlogin","pass":"le-mot-de-passe-app"}`.
- **Webflow** : Paramètres du site → **Apps et intégrations** → **API
  v2** → **Générer un jeton API**. Colle le token seul.

### 15. Google Workspace — une seule app pour Gmail + Calendar + Drive + Search Console + Ads
1. console.cloud.google.com → **Créer un projet** (ex : "BK-AI-WORKERS").
2. **API et services** → **Bibliothèque** → active : *Gmail API*,
   *Google Calendar API*, *Google Drive API*, *Search Console API*
   (+ *Google Ads API* si besoin).
3. **Écran de consentement OAuth** → type **Externe** → remplis nom/
   email → en mode **Test**, ajoute ton propre email comme
   "utilisateur test" (évite toute revue Google pour un usage perso).
4. **Identifiants** → **Créer des identifiants** → **ID client OAuth**
   → type **Application Web** → ajoute `http://localhost` comme URI de
   redirection → copie **Client ID** et **Client Secret**.
5. Pour obtenir le `refresh_token` : dis-moi quand tu es à cette étape,
   je te donne l'URL de consentement exacte à ouvrir dans ton
   navigateur (ça affiche un code à coller une seule fois).
6. `Store-Credential.ps1 -Provider gmail` (puis `google_calendar`,
   `google_drive`, `google_search_console`) → colle à chaque fois
   `{"client_id":"...","client_secret":"...","refresh_token":"..."}`.
7. Pour Google Ads en plus : Google Ads → **Outils et paramètres** →
   **Centre API** → demande un **Developer Token** → ajoute-le au JSON
   (`"developer_token":"..."`).

### 16. Microsoft — une seule app pour Outlook Mail + Calendar + Teams + OneDrive
1. portal.azure.com → **Microsoft Entra ID** → **Inscriptions
   d'applications** → **Nouvelle inscription**.
2. Nom → **Comptes dans cet annuaire organisationnel uniquement** (ou
   multi-tenant si tu préfères) → URI de redirection **Web** :
   `http://localhost`.
3. Note l'**ID d'application (client)** et l'**ID d'annuaire (tenant)**.
4. **Certificats et secrets** → **Nouveau secret client** → copie la
   **valeur** immédiatement (invisible ensuite).
5. **Autorisations API** → ajoute Microsoft Graph → permissions
   déléguées : `Mail.Read`, `Mail.ReadWrite`, `Calendars.ReadWrite`,
   `Files.ReadWrite`, `ChannelMessage.Send`.
6. Comme pour Google, dis-moi quand tu es là pour le `refresh_token`.
7. `Store-Credential.ps1 -Provider outlook_mail` (puis
   `outlook_calendar`, `teams`, `onedrive`) → colle
   `{"client_id":"...","client_secret":"...","refresh_token":"...","tenant":"ton-tenant-id"}`.

### 17. Salesforce (si tu en as un)
1. Salesforce → ⚙️ **Configuration** → **App Manager** → **New
   Connected App**.
2. Active OAuth → URI de rappel `http://localhost` → scopes `api`,
   `refresh_token`, `offline_access`.
3. Copie **Consumer Key** et **Consumer Secret**.
4. `Store-Credential.ps1 -Provider salesforce` → colle
   `{"client_id":"...","client_secret":"...","refresh_token":"..."}`
   (même remarque : dis-moi pour l'étape du refresh_token).

### 18+. Les 🔴 verrouillés côté plateforme (à faire seulement si tu en as vraiment besoin)
Facebook/Instagram/Meta Ads fonctionnent **dès aujourd'hui en mode
développeur sur tes propres pages** (developers.facebook.com → Créer
une app → Business → génère un jeton dans Graph API Explorer). LinkedIn,
TikTok, WhatsApp Business demandent une revue externe (jours/semaines).
X nécessite un abonnement payant (~100 USD/mois) pour écrire. Canva
n'est pas accessible en self-service. On les fait un par un si/quand tu
en as besoin — pas de raison de bloquer le reste pour ça.

---

## 🟢 Prêt aujourd'hui (jeton simple, aucune app à créer)

| Connecteur | Où obtenir le jeton | Format à coller dans Store-Credential.ps1 |
|---|---|---|
| **Slack** | Slack → Paramètres → Apps → Incoming Webhooks | L'URL du webhook telle quelle |
| **Trello** | trello.com/app-key (clé) + bouton "Token" sur la même page | `{"key":"...","token":"..."}` |
| **Asana** | Asana → Mon profil → Paramètres développeur → Personal Access Token | Le token seul |
| **Monday.com** | Avatar → Administration → API → Générer un jeton | Le token seul |
| **Figma** | Figma → Paramètres → Personal Access Tokens | Le token seul |
| **HubSpot** | Compte → Intégrations → Applications privées → Créer | Le token seul |
| **Pipedrive** | Paramètres personnels → API | Le token seul |
| **Intercom** | Paramètres → Développeurs → Créer une app → Access Token | Le token seul |
| **Zendesk** | Admin Center → Apps et intégrations → API → Jeton API | `{"subdomain":"...","user":"email","pass":"token"}` |
| **Dropbox** | dropbox.com/developers → App Console → Generate access token | Le token seul |
| **Shopify** | Boutique → Paramètres → Apps → Développer une app → Admin API | `{"shop":"nomboutique","token":"shpat_..."}` |
| **WooCommerce** | WordPress admin → WooCommerce → Réglages → Avancé → API REST | `{"site":"tonsite.com","consumer_key":"...","consumer_secret":"..."}` |
| **WordPress** (auto-hébergé) | Profil utilisateur → Mots de passe d'application | `{"site":"tonsite.com","user":"...","pass":"..."}` |
| **Webflow** | Paramètres du site → Apps et intégrations → API v2 | Le token seul |

**Temps total estimé si tu enchaînes tout : 1 à 2 heures.**

---

## 🟡 App à créer soi-même, faisable aujourd'hui (10-30 min chacune)

Ces plateformes utilisent OAuth2 — il faut créer une "app" une fois,
puis obtenir un `refresh_token` réutilisable indéfiniment.

| Connecteur | Où créer l'app | Notes |
|---|---|---|
| **Gmail / Calendar / Drive / Search Console / Google Ads** | console.cloud.google.com → nouveau projet → activer l'API → écran de consentement OAuth (mode "Test") → identifiants OAuth | Les 5 partagent le même projet Google Cloud — une seule app à créer pour tout Google. Google Ads a en plus besoin d'un "Developer Token" (Google Ads → Outils → Centre API). |
| **Outlook Mail / Outlook Calendar / Teams / OneDrive** | portal.azure.com → Inscriptions d'applications → Nouvelle inscription | Les 4 partagent la même app Azure. |
| **Salesforce** | Salesforce → Configuration → App Manager → New Connected App | Nécessite un compte Salesforce (souvent déjà payant si tu en as un). |

Format à coller pour tous : `{"client_id":"...","client_secret":"...","refresh_token":"..."}`
(+ `"tenant":"..."` pour Microsoft, `"developer_token":"..."` pour Google Ads).

Obtenir le premier `refresh_token` demande un aller-retour navigateur
(l'écran de consentement OAuth) — je peux te guider pas à pas quand tu
es prêt à le faire, mais l'échange final (coller le refresh_token) doit
rester fait par toi via Store-Credential.ps1.

---

## 🔴 Verrou externe — le délai ne dépend ni de toi ni de moi

| Connecteur | Blocage réel | Délai typique |
|---|---|---|
| **LinkedIn** | Publier au nom d'une page nécessite le programme "Marketing Developer Platform" — candidature avec justification, review LinkedIn | Plusieurs semaines, pas garanti |
| **Facebook / Instagram** | Fonctionne en mode "Développement" sur TES pages sans review, mais toute page tierce ou usage public nécessite une App Review Meta | Immédiat sur tes propres pages · semaines sinon |
| **Meta Ads** | Même logique que Facebook — gestion de comptes pub tiers nécessite review | Immédiat sur ton propre compte pub · semaines sinon |
| **TikTok** | TikTok for Developers exige une candidature d'app approuvée avant tout accès en écriture | Plusieurs jours à semaines |
| **X (Twitter)** | Écriture (publier) nécessite un plan payant (Basic, ~100 USD/mois minimum) depuis 2026 | Immédiat une fois payé — mais c'est un coût récurrent, ta décision |
| **WhatsApp Business** | Vérification d'entreprise Meta + enregistrement du numéro + approbation des modèles de message | Plusieurs jours |
| **Canva** | L'API Connect de Canva est réservée aux partenaires validés par Canva — pas d'auto-inscription | Candidature partenaire, délai indéterminé |

Pour Facebook/Instagram/Meta Ads : si tu utilises uniquement TES
propres pages/comptes pub (pas ceux de clients externes), ça marche
**dès aujourd'hui** en mode développement Meta — c'est probablement le
bon point de départ avant d'envisager une review complète.

---

## Catégories génériques (pas un fournisseur précis)

`crm.controlled`, `social_media.controlled`, `design.controlled`,
`monitoring.controlled`, `calendar_hr.controlled` (HR_PLATFORM) sont
des entrées génériques du catalogue, pas un service réel identifiable —
elles existent pour couvrir "un CRM quelconque" etc. Pas d'adaptateur
réel possible tant qu'on ne sait pas quel outil précis (Notion, Airtable,
BambooHR...) elles représentent pour un client donné. À traiter au cas
par cas si un client BK-AI-WORKERS utilise l'un de ces outils.

---

## 🔒 Ne change pas, quel que soit l'accord sur les intégrations

**Stripe, PayPal, QuickBooks, Xero** restent désactivés
(`enabled: false`). Ce n'est pas une question d'intégration technique
mais d'argent — règle distincte, confirmée à plusieurs reprises : seul
Kader valide directement un paiement ou une transaction, jamais un
Worker ni Chloé, même une fois "tous les verrous" d'intégration levés.

---

## Par où commencer, concrètement

1. **Slack** (déjà en cours — webhook à créer)
2. Les autres 🟢 "Prêt aujourd'hui" qui servent réellement à ton usage :
   probablement Trello/Asana/Monday (gestion de projet), HubSpot ou
   Pipedrive (CRM), Shopify/WooCommerce si tu as une boutique, WordPress
   si tu as un site.
3. Google Workspace (🟡) si tu utilises Gmail/Drive/Calendar
   professionnellement — une seule app à créer pour couvrir 5 connecteurs.
4. Les 🔴 seulement si tu en as vraiment besoin, en sachant que le
   délai ne dépend pas de nous.

Dis-moi lesquels tu veux activer en premier et je te guide étape par
étape pour chacun.
