# Applications mobiles : installable, Android, iOS

BK-AI-WORKERS est une **application web installable (PWA)**. Elle est prête et testée.
Les **applications des stores** (Google Play, App Store) sont préparées mais **pas publiées** : elles demandent des comptes
développeur que le propriétaire créera plus tard (voir §2). Ce document dit exactement quoi faire, dans quel ordre,
ce que ça coûte, et ce qui peut faire refuser l'application.

Vérifications des faits externes : 2026-10-07, aux adresses citées (deux passes : les prix Apple et Google, le test fermé de
12 testeurs, le niveau d'API cible 36, les prérequis de Capacitor et les textes des règles Apple 3.1.1, 3.1.3(b), 3.1.3(c), 4.2, 4.8,
5.1.1(v), 5.1.2(i) ainsi que la politique Paiements de Google ont été relus à la source). Tout ce qui est marqué **[non vérifié]**
n'a pas pu être confirmé à la source pendant ce travail : le contrôler avant de s'y fier. Les règles et les prix des stores changent :
les relire le jour de la soumission.

---

## 1. Ce qui est fait et testé (l'app installable)

| Élément | Fichier | Rôle |
|---|---|---|
| Manifeste | `dashboard/manifest.json` | `id` stable `/?pwa=1` (identique à l'ancien `start_url` : les installations existantes ne sont pas dupliquées), `display: standalone`, orientation libre (tablettes), couleurs = celles du site (`#f7f6f3`, comme `--bg`), catégories, 2 raccourcis (Nouvelle mission, Automatisations), 3 icônes (192 et 512 `any`, 512 `maskable`) |
| Service worker | `dashboard/service-worker.js` | **Réseau d'abord**, jamais cache d'abord (règle née de l'incident de JS périmé du 2026-09-24, conservée). Page de secours `/offline.html` si le réseau est coupé ou si le serveur répond 502/503/504. `/api/`, `/oauth/`, `/webhooks/`, les POST, les requêtes avec `Authorization`/`Range` et les vidéos ne sont **jamais** interceptés ; seuls des fichiers statiques publics (liste blanche, réponse 200, sans `no-store`/`private`) peuvent être gardés en copie de secours (80 max). Rien d'authentifié n'est conservé |
| Page hors connexion | `dashboard/offline.html` | FR/EN (mécanisme habituel `i18n.js` + `i18n-en-pwa.js`), autonome (aucune ressource externe), se recharge toute seule dès que le site répond ; distingue « appareil hors ligne » et « serveur muet » |
| Invitation à installer | `dashboard/pwa-install.js`, `pwa-install.css`, lien « Installer l'application » dans le pied de page | Chrome/Edge/Samsung : vraie fenêtre d'installation du navigateur (`beforeinstallprompt`) ; iPhone/iPad : les 3 gestes « Partager > Sur l'écran d'accueil > Ajouter ». Bannière à partir de la 2e visite, fermable (14 jours) ; **jamais** dans l'app déjà installée, dans l'app Android (TWA) ni dans la coque iOS. Lien du pied de page toujours disponible tant que l'app n'est pas installée. Superposition fixe : aucun décalage de la page, ne recouvre pas la bulle de Chloé |
| Serveur | `dashboard/pwa_static.py` (+ 1 crochet dans `server.py`) | `application/manifest+json`, `Service-Worker-Allowed: /`, service worker `no-cache, max-age=0, must-revalidate` + ETag/304 (les ETag faibles `W/"..."` et les listes sont acceptés : le proxy HTTPS Caddy compresse en gzip et peut les modifier), icônes, `/.well-known/assetlinks.json` et `/.well-known/apple-app-site-association` (404 tant que le fichier n'existe pas : jamais de fausse empreinte), page publique `/suppression-compte.html` |
| Icône iOS | `dashboard/icons/apple-touch-icon.png` | **Corrigée** : elle avait des coins transparents (iOS les remplit en noir). Maintenant 180×180 sans transparence. Régénérable : `python tests/pwa/make_store_icons.py` |
| Page « supprimer mon compte » | `dashboard/suppression-compte.html` | Exigée par Google Play (lien web de suppression) ; FR/EN ; décrit ce que fait réellement `delete_account` (server.py) |
| Coques stores | `mobile/` | Configuration Capacitor (iOS) prête ; Android = Bubblewrap (rien à versionner) |

Raccourcis : appui long sur l'icône (Android/Chrome) → « Nouvelle mission » ouvre la fiche de Chloé avec le champ de mission sélectionné, « Automatisations » ouvre la vue correspondante (`?shortcut=` géré dans `pwa-install.js`, qui clique les vrais boutons de navigation : aucune dépendance aux fonctions internes de `app.js`).

Limites connues de la PWA (pas des bugs) :
- iPhone : Safari n'a aucune API d'installation ; l'app installée sur l'écran d'accueil a **son propre stockage** (il faut s'y reconnecter). **[non testé sur appareil iOS]**
- Les pages de `seo_pages.py` (tarifs, FAQ...) gardent leur `theme-color` sombre (`#14151a`, comme leur bandeau d'en-tête) : dans l'app installée, la barre de titre passe donc au sombre sur ces pages et revient au clair sur l'accueil. Voulu ; à uniformiser seulement si ces pages changent de bandeau.
- Aucun écran de lancement iOS (`apple-touch-startup-image`) et aucune capture `screenshots` dans le manifeste (interface d'installation enrichie de Chrome) : à ajouter avec de **vraies** captures de l'app, jamais de maquettes. **[non vérifié sur appareil]**
- `app.js` ne gère pas les erreurs réseau de `fetchJson` (exceptions « Failed to fetch » dans la console quand le serveur tombe, constaté pendant les tests). Comportement existant, sans effet visible grâce à la page de secours.

### Vérifier soi-même
1. Chrome ou Edge → https://bk-ai-workers.com → DevTools (F12) → onglet **Application** → *Manifest* (aucune erreur, icônes affichées, bouton « Installability ») et *Service workers* (activé).
2. Icône d'installation dans la barre d'adresse (Chrome/Edge) ou menu « Installer BK-AI-WORKERS ».
3. DevTools → Application → Service workers → cocher *Offline* → recharger : la page « Vous êtes hors connexion » apparaît.
4. Tests automatiques : voir §8.

---

## 2. Ce que le propriétaire doit créer et payer

| À créer | Coût | Notes (source, vérifié le 2026-10-07) |
|---|---|---|
| **Apple Developer Program** | **99 USD par an** (prix affiché en monnaie locale à l'inscription) | https://developer.apple.com/programs/enroll/ . Exemptions de frais : associations, écoles, organismes publics seulement. Particulier : nom légal, 2FA, adresse (pas de boîte postale). Organisation : entité légale (pas de nom commercial), **numéro D-U-N-S**, pouvoir de signature, site web public fonctionnel |
| **Google Play Console** | **25 USD, une seule fois** | https://support.google.com/googleplay/android-developer/answer/6112435 . Vérification d'identité : pièce d'identité officielle + carte bancaire au nom légal. Compte *personnel* ou *organisation* (organisation : **D-U-N-S** obligatoire, gratuit auprès de Dun & Bradstreet — https://support.google.com/googleplay/android-developer/answer/13634885 ) |
| Test fermé Google (comptes **personnels** créés après le 13 nov. 2023) | gratuit mais **12 testeurs pendant 14 jours consécutifs** avant la mise en production | https://support.google.com/googleplay/android-developer/answer/14151465 |
| **Un Mac avec Xcode** (iOS) | **[non vérifié]** achat d'un Mac ou service de build macOS dans le cloud | Capacitor : macOS obligatoire, Xcode ≥ 26.0, Node ≥ 22 — https://capacitorjs.com/docs/getting-started/environment-setup |
| PC Windows/Mac/Linux (Android) | gratuit | Bubblewrap : Node ≥ 18, JDK 17, outils Android en ligne de commande — https://github.com/GoogleChromeLabs/bubblewrap/tree/main/packages/cli |

Points d'attention sur l'identité juridique :
- BK-ENTREPRISE est une **entreprise individuelle** (mentions légales). Apple n'accepte pour les « organisations » qu'une entité légale avec D-U-N-S ; une entreprise individuelle s'inscrit normalement comme **particulier**, et le nom du vendeur affiché sur l'App Store est alors le nom légal de la personne. **[non vérifié : confirmer sur la page d'inscription Apple avant de payer]**
- Même question côté Google (compte personnel ou organisation) : le test fermé de 12 testeurs/14 jours est annoncé pour les comptes personnels.
- Ni commission ni frais d'achat intégré ne sont chiffrés ici **[non vérifié]** : voir §3.

---

## 3. Décision à prendre AVANT de publier : les paiements dans les apps

BK-AI-WORKERS vend des abonnements (plans Solo/Trio/Équipe/Pro/Scale ; Starter et Business sont des forfaits hérités qui ne se vendent plus) payés par carte via **Stripe**, depuis la page Facturation (`#billing-plans-grid`, routes `/api/billing/*` qui renvoient une `checkoutUrl` Stripe). La recharge de crédits n'existe plus (`#billing-recharge` a été retiré). Les deux stores ont des règles sur ce point, et c'est **le risque de refus numéro un**, devant la technique.

- **Google Play** — politique Paiements (https://support.google.com/googleplay/android-developer/answer/9858738) : Google Play Billing est exigé pour les abonnements et les « logiciels et services cloud » ; l'app ne doit pas « mener les utilisateurs vers un autre moyen de paiement » (webviews, boutons, liens, messages, appels à l'action), sauf programmes d'alternative billing dans des pays éligibles. Cela vaut aussi pour une TWA : c'est le site, donc ses boutons de paiement.
- **Apple** — Guidelines (https://developer.apple.com/app-store/review/guidelines/) : 3.1.1 (débloquer des fonctions numériques / abonnements = achat intégré obligatoire) ; 3.1.3(b) *Multiplatform Services* (accéder dans l'app à des abonnements pris ailleurs, **à condition que ces éléments soient aussi proposés en achat intégré dans l'app** : texte relu le 2026-10-07) ; 3.1.3(c) *Enterprise Services* (apps vendues directement à des organisations pour leurs employés : accès à des abonnements déjà achetés possible ; « les ventes à des consommateurs ou à un seul utilisateur doivent utiliser l'achat intégré »).

Options, de la plus simple à la plus lourde (rien de cela n'est implémenté) :
1. **App « compte existant »** : dans les coques, masquer plans, recharge et tout lien/mention de paiement ; l'abonnement se prend sur le site. Les coques s'identifient déjà : `html.is-store-app` (+ `is-ios-app` / `is-android-app`) et, pour Android TWA, `html.is-installed-app`. Il suffit d'un CSS `html.is-store-app #billing-plans-grid { display: none }` (plus le bouton « Passer à la formule supérieure » `#billing-upgrade` et les cartes « quota épuisé » qui mènent vers un forfait) et de textes sans lien. Risque **élevé côté Apple** : 3.1.3(b) exige que l'abonnement soit aussi proposé en achat intégré dans l'app. Seul le cas B2B 3.1.3(c) (apps vendues directement à des organisations pour leurs employés) permet de s'en passer, et il exclut « les ventes à des consommateurs ou à un seul utilisateur » ; or l'inscription à BK-AI-WORKERS est libre, sans justificatif d'entreprise : ce cas est fragile. **Ne pas compter dessus sans réponse écrite d'Apple** (question à l'App Review avant de construire). Côté Google Play, l'option 1 convient tant que l'app ne mène vers aucun moyen de paiement externe.
2. **Achat intégré** : Google Play Billing (API Digital Goods dans la TWA) et StoreKit (plugin Capacitor) + catalogue de produits côté stores + rapprochement avec Stripe. Chantier important, commission des stores **[non vérifiée]**.
3. **Ne pas publier sur iOS** et ne publier que la PWA (installable sans store) + Android.

Recommandation : poser la question B2B à Apple et trancher l'option 1 ou 2 **avant** de payer/soumettre quoi que ce soit.

---

## 4. Android : Trusted Web Activity (Bubblewrap)

Une TWA ouvre **le vrai Chrome en plein écran** sur le site (le stockage et les connexions de Chrome ; les connexions OAuth Google/Microsoft se font dans un vrai navigateur) **[non vérifié sur appareil]**. Aucun code applicatif à maintenir : le site mis à jour se met à jour dans l'app.

### Étapes
1. **Compte Play Console** (§2). Créer l'application dans la console (nom « BK-AI-WORKERS », langue par défaut français, application gratuite).
2. **Installer Bubblewrap** (PC) :
   ```
   npm i -g @bubblewrap/cli
   mkdir bk-android && cd bk-android
   bubblewrap init --manifest=https://bk-ai-workers.com/manifest.json
   ```
   Accepter le téléchargement automatique de JDK/SDK si proposé. Réponses : identifiant d'application `com.bkaiworkers.app` (**définitif** après publication ; même identifiant que le bundle iOS dans `mobile/capacitor/capacitor.config.json`) ; nom BK-AI-WORKERS ; start URL `/?pwa=1` ; couleurs et icônes lues dans le manifeste ; notifications : **non** (le serveur n'envoie pas de notifications push) ; **créer une nouvelle clé de signature** et noter son mot de passe.
   La clé (`*.keystore`) est un **secret** : la sauvegarder hors du dépôt (déjà ignorée par `.gitignore`) ; la perdre bloque les mises à jour.
3. **Construire** :
   ```
   bubblewrap build        # app-release-bundle.aab (pour Google Play) et app-release-signed.apk (pour tester)
   bubblewrap install      # installe l'APK sur un téléphone en débogage USB
   ```
   Google exige pour les **nouvelles** applications le niveau d'API cible **36 (Android 16)** depuis le 31 août 2026 (https://developer.android.com/google/play/requirements/target-sdk) : vérifier `targetSdkVersion` du projet généré et mettre Bubblewrap à jour (`npm i -g @bubblewrap/cli@latest`, `bubblewrap update`) si besoin. Le niveau 36 est confirmé à la page citée (nouvelles applications et mises à jour, à partir du 31 août 2026). **[non vérifié : version cible effectivement produite par Bubblewrap 1.25.0]**
4. **Prouver que le site appartient à l'app** (Digital Asset Links). Sans ce fichier, l'app s'ouvre comme un onglet Chrome **avec barre d'adresse** (https://developer.chrome.com/docs/android/trusted-web-activity/quick-start).
   Créer `dashboard/well-known/assetlinks.json` (le serveur le publie à `/.well-known/assetlinks.json`, sans redirection, en `application/json`) :
   ```json
   [{
     "relation": ["delegate_permission/common.handle_all_urls"],
     "target": {
       "namespace": "android_app",
       "package_name": "com.bkaiworkers.app",
       "sha256_cert_fingerprints": [
         "EMPREINTE_SHA256_DE_LA_CLE_DE_SIGNATURE_PLAY_APP_SIGNING",
         "EMPREINTE_SHA256_DE_LA_CLE_D_IMPORT_(UPLOAD)_POUR_LES_TESTS_LOCAUX"
       ]
     }
   }]
   ```
   (format : https://developers.google.com/digital-asset-links/v1/getting-started). Les empreintes : Play Console → *Intégrité de l'application* → certificat de signature de l'application (clé Play App Signing) ; pour la clé locale : `keytool -list -v -keystore <fichier> -alias <alias>` ou `bubblewrap fingerprint generateAssetLinks`. Les empreintes de la clé d'import et de la clé Play sont **différentes**. Déployer (push sur `main`), puis contrôler :
   ```
   curl -i https://bk-ai-workers.com/.well-known/assetlinks.json     # 200, application/json, aucune redirection
   ```
   Le fichier réel peut être commité (empreintes publiques, aucun secret) ; `tests/pwa/test_pwa.py` refuse seulement qu'on y laisse le modèle ci-dessus (empreintes qui ne sont pas de vrais SHA-256).
5. **Fiche Google Play** — exigences vérifiées :
   - **URL de politique de confidentialité** : `https://bk-ai-workers.com/confidentialite.html` (page existante).
   - **Suppression de compte** (https://support.google.com/googleplay/android-developer/answer/13327111) : chemin *dans l'app* (existe : Facturation → Mes données → Supprimer mon compte) **et** lien web : `https://bk-ai-workers.com/suppression-compte.html` (créé), à saisir dans le formulaire *Sécurité des données*.
   - Descriptions : courte ≤ 80 caractères, longue ≤ 4 000. Proposition courte (70 car.) : « Chloé et 17 Workers IA exécutent vos missions 24/7, dans votre langue. » (reprise de la meta description du site).
   - Icône 512×512 : `docs/store-assets/play-store-icon-512.png` (prête, carrée). **[non vérifié ici : gabarit exact de l'icône, du graphique de présentation (1024×500 habituellement) et nombre minimal de captures d'écran ; Play Console l'affiche au moment de la saisie]**
   - Questionnaire de classification, public cible, déclaration de publicités (aucune publicité n'est servie par le site : `ads.txt` est présent mais aucun script publicitaire n'a été trouvé dans `dashboard/`), formulaire Sécurité des données (types : nom/e-mail du compte, contenu des missions, journaux de sécurité — voir `confidentialite.html` ; sous-traitants : Anthropic, Stripe, OVHcloud).
6. **Test fermé → production** (§2 : 12 testeurs/14 jours pour un compte personnel). Mises à jour : une modification du site est immédiate sans repasser par Google ; seule une modification des réglages de l'app (icône, version, couleurs) demande `bubblewrap update` + un nouveau `.aab` avec `versionCode` incrémenté.

Alternative : **PWABuilder** (https://www.pwabuilder.com) génère aussi un paquet Android à partir de l'adresse du site. **[non vérifié : la documentation n'a pas pu être chargée ; mêmes règles de clé et d'`assetlinks.json`]**

---

## 5. iOS : coque Capacitor

Il n'existe pas de TWA sur iOS : on emballe le site dans une application native minimale (WKWebView) avec Capacitor. Fichiers prêts : `mobile/capacitor/` (config + écran hors connexion + page de démarrage). **Non compilée** (pas de Mac ici).

### Étapes (sur un Mac)
1. Prérequis : macOS, Xcode ≥ 26.0, Node ≥ 22, compte Apple Developer (§2).
2. ```
   cd mobile/capacitor
   npm install
   npx cap add ios        # génère mobile/capacitor/ios (projet Xcode, à commiter)
   npx cap sync ios
   npx cap open ios
   ```
3. Dans Xcode : *Signing & Capabilities* → votre équipe ; Bundle Identifier `com.bkaiworkers.app` (définitif) ; **Associated Domains** `applinks:bk-ai-workers.com` (retour des connexions OAuth, voir risque 6) ; *App Icons* ← `docs/store-assets/ios-app-icon-1024.png` (1024×1024, **sans transparence**, vérifié par le test) ; cible **iPhone seulement** si vous ne voulez pas fournir de captures iPad.
   `capacitor.config.json` : `server.url` charge le site, `appendUserAgent` ajoute `BKAIWorkersApp/1.0` (l'app le reconnaît : plus d'invitation à installer, classes `is-store-app`/`is-ios-app`), `errorPath` affiche `www/offline.html` quand le site est injoignable. **Capacitor précise que `server.url` « n'est pas prévu pour la production »** (https://capacitorjs.com/docs/config) : c'est une raison de plus de renforcer l'app (risque 1).
4. *Product → Archive → Distribute App → App Store Connect* ; tester d'abord avec TestFlight **[non vérifié : modalités]**.
5. App Store Connect — champs vérifiés (https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information) : description ≤ 4 000, mots-clés ≤ 100 octets, **URL d'assistance** (obligatoire ; proposition : `https://bk-ai-workers.com/faq.html`), copyright (`© 2026 BK-ENTREPRISE`), **compte de démonstration qui n'expire pas** + notes pour le relecteur ; **URL de politique de confidentialité obligatoire** (https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy) : `https://bk-ai-workers.com/confidentialite.html` ; détails de confidentialité (« étiquettes ») exacts et à jour.
   Captures d'écran (https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) : 1 à 10 par taille, PNG/JPEG **sans transparence** ; iPhone : au moins une capture ; **1179×2556** (catégorie « Dynamic Island, moyen ») est accepté, comme 1206×2622, 1290×2796 ou 1320×2868 (tableau complet sur la page citée) ; iPad 13 pouces **2064×2752** seulement si l'app gère l'iPad (relu le 2026-10-07). À prendre dans la vraie app connectée avec le compte de démonstration (pas de maquette).
   Chiffrement : l'app n'utilise que HTTPS ; clé `ITSAppUsesNonExemptEncryption` = `NO` dans `Info.plist` **[non vérifié]**.

### Risques de refus, par ordre d'importance (textes : https://developer.apple.com/app-store/review/guidelines/)
1. **4.2 Fonctionnalité minimale** : « les apps doivent apporter des fonctions, contenus et une interface qui les élèvent au-delà d'un simple site reconditionné ». Un site dans une coque sans rien d'autre est exposé. Parades possibles (rien n'est livré, aucune garantie d'acceptation) : partage natif des résultats de mission (`@capacitor/share`), retours haptiques, **notifications de fin de mission** (`@capacitor/push-notifications` — **le serveur n'envoie aucune notification aujourd'hui** : à construire : APNs, jetons, envoi à la fin d'une mission), verrouillage Face ID, import de fichiers/photos dans une mission, écran de démarrage et écran hors connexion natifs (déjà prévus). Les plugins sont déjà listés dans `mobile/capacitor/package.json`.
2. **Paiements** (§3).
3. **5.1.2(i) Données partagées avec une IA tierce** : « les données personnelles partagées avec des tiers, y compris des IA tierces, exigent l'autorisation explicite de l'utilisateur ». Les missions et le profil d'entreprise partent chez Anthropic (déclaré dans la politique de confidentialité). **À vérifier/ajouter : un écran de consentement explicite avant la première mission** — non présent à ma connaissance.
4. **4.8 Services de connexion tiers** (texte relu le 2026-10-07 : la règle vise les apps qui utilisent Google, Facebook, LinkedIn... pour l'authentification **principale** du compte ; l'usage exclusif du système de comptes de l'éditeur est une exception). Le compte BK-AI-WORKERS est un compte e-mail + mot de passe maison ; les boutons « Se connecter avec Google / Microsoft / Slack... » servent à **brancher un outil** sur un compte déjà connecté (`handleOauthReturn` de `app.js` exige un compte), pas à ouvrir le compte. 4.8 ne devrait donc pas s'appliquer **[interprétation à confirmer avec l'App Review]**. Si un jour une connexion au compte par Google/LinkedIn était ajoutée, prévoir « Se connecter avec Apple » ou une option équivalente.
5. **5.1.1(v) Suppression de compte** : doit exister dans l'app (existe). Point faible : la suppression est refusée tant qu'un abonnement est encore renouvelé (`ACTIVE_SUBSCRIPTION` ; une résiliation déjà enregistrée ne bloque plus, le temps payé restant est alors perdu) ; le dire clairement dans les notes de relecture.
6. **Connexions OAuth dans la WebView** (Google, Microsoft, Slack, Asana, Intercom, Dropbox, LinkedIn...) : Google refuse les WebViews intégrées pour l'authentification **[non vérifié dans cette session]**, et le retour (`/oauth/<fournisseur>/callback`) a besoin du cookie de session de l'app. Solution à construire et à tester sur appareil : ouvrir les adresses d'autorisation dans le navigateur système (`@capacitor/browser`) et ramener le retour dans l'app par **lien universel** (fichier `dashboard/well-known/apple-app-site-association`, route prête et servie en `application/json`, exemple ci-dessous). Les connexions guidées par jeton (24 outils) n'ont pas ce problème.
7. Compte de démonstration : l'essai gratuit dure 3 jours ; prévoir un compte de relecture avec un plan actif ou des crédits illimités (décision du propriétaire ; **ne jamais mettre ses identifiants dans le dépôt**).

Exemple `apple-app-site-association` (remplacer `ÉQUIPE` par l'identifiant d'équipe Apple) :
```json
{ "applinks": { "details": [ { "appIDs": ["ÉQUIPE.com.bkaiworkers.app"], "components": [ { "/": "/oauth/*" } ] } ] } }
```
**[non vérifié : format et comportement exacts ; à valider avec Apple et sur appareil]**

---

## 6. Ressources déjà prêtes pour les stores

| Besoin | Valeur / fichier |
|---|---|
| Icône App Store 1024×1024 sans transparence | `docs/store-assets/ios-app-icon-1024.png` |
| Icône Google Play 512×512 | `docs/store-assets/play-store-icon-512.png` |
| Icône écran d'accueil iOS 180×180 | `dashboard/icons/apple-touch-icon.png` |
| Politique de confidentialité | https://bk-ai-workers.com/confidentialite.html |
| Suppression de compte (lien web) | https://bk-ai-workers.com/suppression-compte.html |
| Conditions de vente | https://bk-ai-workers.com/cgv.html |
| Assistance (proposition) | https://bk-ai-workers.com/faq.html , contact@bk-entreprise.com |
| Éditeur | BK-ENTREPRISE, Rue Joseph-Pasquier 1, 1203 Genève (mentions légales) |
| **À produire par le propriétaire** | captures d'écran de la vraie app connectée (aucun faux avis, aucun chiffre inventé), graphique de présentation Google (1024×500 **[non vérifié]**), compte de démonstration, textes de la fiche |

Les icônes se régénèrent avec `python tests/pwa/make_store_icons.py` (Pillow ; police Segoe UI Bold, option `--font`). Écart moyen avec l'icône d'origine mesuré : 1,7 sur 255.

---

## 7. Liste de contrôle

**Propriétaire (comptes, argent, décisions)**
- [ ] Trancher les paiements dans les apps (§3), idéalement après avoir posé la question B2B à Apple
- [ ] Vérifier le type de compte (particulier/organisation) pour Apple et Google ; obtenir un D-U-N-S si organisation
- [ ] Créer le compte **Google Play Console** (25 USD) ; si compte personnel : recruter 12 testeurs pour 14 jours
- [ ] Créer le compte **Apple Developer** (99 USD/an) ; disposer d'un Mac avec Xcode (ou service de build)
- [ ] Créer un compte de démonstration pour les relecteurs (plan actif, mot de passe jamais dans le dépôt)
- [ ] Produire les captures d'écran de la vraie app et le graphique de présentation Google

**Technique (une fois les comptes créés)**
- [ ] Android : `bubblewrap init/build`, clé de signature sauvegardée hors dépôt, `dashboard/well-known/assetlinks.json` avec les vraies empreintes, déployé, `curl` 200
- [ ] Android : fiche Play (confidentialité, suppression de compte, Sécurité des données, classification), test fermé, production
- [ ] iOS : `npx cap add ios`, signature, icône 1024, Associated Domains, `apple-app-site-association`
- [ ] iOS : renforcer l'app (risque 4.2) : notifications de fin de mission, partage, Face ID ; écran de consentement IA ; décision Sign in with Apple
- [ ] iOS : OAuth dans le navigateur système + liens universels, testés sur iPhone
- [ ] Masquer les paiements dans les coques selon la décision du §3
- [ ] TestFlight puis soumission

---

## 8. Tests

```
python tests/pwa/validate_pwa.py            # 94 contrôles : manifeste, icônes (taille réelle, transparence, zone de sécurité), cohérence avec le site, service worker, pages, traductions
python tests/pwa/test_pwa.py                # 42 tests : validateur (dont fautes volontaires), routes, ETag, node --check, service worker sous Node, « test des tests » (9 service workers cassés doivent être refusés), coque Capacitor
python tests/pwa/e2e_server.py              # vrai serveur sur copie jetable (port aléatoire) : en-têtes, types MIME, icônes, assetlinks, chemins hostiles, anciennes routes, service worker réel contre ce serveur
python tests/pwa/browser_e2e.py             # vrai Chrome/Edge headless (DevTools) : installabilité selon Chrome, service worker, invitation (ordinateur/Android/iPhone), mise en page 390/320 px, raccourcis, serveur coupé puis relancé
node tests/pwa/test_service_worker.js       # (aussi lancé par les précédents)
node tests/pwa/test_pwa_install.js
```
`browser_e2e.py` accepte `BK_CHROME=<chemin>` et `BK_SHOTS_DIR=<dossier>` (captures PNG). Sans Chrome/Edge : ignoré. Sur un Chrome à profil neuf, l'activation du service worker prend une dizaine de secondes (il s'enregistre à la fin du chargement de la page) : le test l'attend jusqu'à 60 s.

Pas testé : iPhone/iPad réels, Android réel, coque Capacitor compilée, TWA générée, soumission aux stores.

---

## 9. Ce qui n'a pas pu être vérifié (récapitulatif)

- Statut d'« entreprise individuelle » face aux inscriptions Apple/Google (§2).
- Prix d'un Mac / d'un service de build macOS ; commissions des stores ; programmes d'alternative de paiement par pays.
- Acceptation du cas B2B 3.1.3(c) par Apple ; applicabilité de 4.8 aux boutons « Se connecter avec... » (interprétation).
- Gabarits Google (icône, graphique 1024×500, nombre de captures), cible d'API produite par Bubblewrap 1.25.0, documentation PWABuilder.
- Refus des WebViews intégrées par Google pour OAuth ; format AASA ; `ITSAppUsesNonExemptEncryption` ; comportement des PWA sur iOS (stockage séparé, OAuth) sur un vrai appareil.
- Que 4.2 soit satisfait avec les fonctions natives proposées.
