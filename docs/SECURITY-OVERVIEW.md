# Sécurité de BK-AI-WORKERS — vue d'ensemble technique

Dernière revue du code : **7 octobre 2026** (branche `ws/trust-2`). Ce document est la version détaillée de la page publique
[`/securite.html`](../dashboard/trust_pages.py) : mêmes faits, avec les fichiers du code qui les prouvent.
Il décrit **uniquement ce qui existe** ; ce qui manque est dit en clair (section 6).

> Règle : une phrase n'a le droit d'être publiée que si elle est vérifiable dans ce dépôt. La page publique est tenue à jour
> par `tests/trust/` (voir section 8) : chaque ligne porte un identifiant (`data-claim`) relié à un motif du code dans
> `tests/trust/claims-evidence.json`. Si le code change, le test échoue et la page doit être relue.

## 1. Architecture et périmètre

```
Internet --HTTPS--> Caddy (conteneur) --HTTP, réseau Docker privé--> app (conteneur : Python 3 stdlib + PowerShell 7)
                                                                          |
                                                    volume Docker `bkdata` monté sur /data (BK_ROOT=/data/app)
```
- Un seul VPS chez OVHcloud (France) : `docker-compose.yml` = deux services, `app` et `caddy`. Pas de redondance.
- `app` n'est publié que sur `127.0.0.1:8787` de l'hôte ; seul Caddy publie les ports 80/443.
- Serveur HTTP : `dashboard/server.py` (`ThreadingHTTPServer`, bibliothèque standard uniquement, aucune dépendance Python tierce).
- Moteur des Workers : PowerShell 7 (`core/`, `chloe/`, `workers/`), appelé par processus. Image : `mcr.microsoft.com/powershell:ubuntu-24.04`.
- Code dans l'image (`/opt/bk`), synchronisé au démarrage vers le volume (`deploy/entrypoint.sh`) sans écraser l'état.
- Déploiement : push sur `main` → GitHub Actions (`.github/workflows/deploy.yml`) → SSH (clé dédiée dans les secrets GitHub) → `git checkout` + `docker compose up -d --build`.

## 2. Où sont les données (volume `bkdata`, racine `/data/app`)

| Chemin | Contenu | Protection au repos | Conservation |
|---|---|---|---|
| `core/accounts/data/accounts.json` | e-mail, entreprise, hash de mot de passe, date | mot de passe haché (PBKDF2) ; reste en clair | jusqu'à suppression du compte |
| `core/accounts/data/sessions.json` | empreintes SHA-256 des jetons de session | fichier `0600`, jamais le jeton | expiration (30 j client, 12 h propriétaire) |
| `core/accounts/data/activity-log.json` | inscriptions, connexions réussies (+IP), e-mails, connexions d'outils, suppressions | en clair | 1 000 derniers événements |
| `core/accounts/data/password-resets.json`, `email-verifications.json` | empreintes de jetons à usage unique | hachés | 1 h / 7 j |
| `core/accounts/data/demo-requests.json` | demandes de démo (nom, e-mail, société, téléphone, message) | en clair | 500 dernières |
| `core/accounts/data/whatsapp-links.json` | numéro WhatsApp ↔ compte | en clair | jusqu'à déliaison/suppression |
| `core/connectors/client-credentials/data/<ClientId>/<outil>.json` | identifiants et jetons des outils du client | **AES-256-GCM** (clé `BK_SECRET_CRED_ENCRYPTION_KEY`) | jusqu'à déconnexion/suppression |
| `core/connectors/data/<ClientId>*.json` | outils activés, option de pré-autorisation, empreinte de clé API, URL + secret de webhook | secret de webhook **en clair** (limite) | jusqu'à suppression |
| `core/billing/data/<ClientId>.json` | plan, crédits, historique | en clair | **non supprimé** avec le compte |
| `core/profile/data/<ClientId>.json` | profil d'entreprise saisi par le client | en clair | jusqu'à suppression |
| `runtime/tasks/TASK-*.json` | missions : demande, résultat, ClientId | en clair | jusqu'à suppression du compte |
| `memory/runtime/PENDING-ACTION-*.json` | actions d'écriture en attente de validation (paramètres compris) | en clair | jusqu'à confirmation/annulation |
| `memory/runtime/phone-calls/<date>/` | transcriptions de l'agent téléphonique | en clair | **90 jours** (purge au démarrage) |
| `core/trial/data/trial-missions.jsonl` | essai public : IP, Worker, date (plafonds) | en clair | non purgé |
| `memory/runtime/status/` | mesure de disponibilité (aucune donnée personnelle) | — | 90 jours |

Sauvegarde : `deploy/backup.sh` archive tout le volume en `.tgz` (non chiffré), planifié à 3 h 30 par la procédure de `deploy/DEPLOIEMENT-VPS.md`, 14 jours de conservation, sur le même serveur.
La clé `BK_SECRET_CRED_ENCRYPTION_KEY` vit dans `.env` (hôte, `chmod 600`), fourni au conteneur par `env_file` : elle n'est **pas** dans le volume, donc pas dans les sauvegardes.

## 3. Contrôles en place (avec la preuve dans le code)

| Domaine | Ce qui est en place | Où |
|---|---|---|
| Transport | HTTPS automatique par Caddy ; appels sortants en HTTPS | `docker-compose.yml`, `deploy/Caddyfile.docker` |
| Chiffrement des identifiants d'outils | AES-256-GCM, nonce aléatoire de 12 octets, tag de 16 octets, clé de 32 octets exigée | `core/connectors/Crypto-Helper.ps1`, `Client-Credential-Store.ps1` |
| Valeur jamais relue | seul le **nom** des outils connectés est listé ; le secret n'est jamais renvoyé au navigateur ni journalisé | `server.py: get_client_configured_providers`, `connect_guides.py` |
| Mots de passe | PBKDF2-HMAC-SHA256, 200 000 itérations, sel de 16 octets, `hmac.compare_digest`, 8 caractères minimum | `server.py: _hash_password`, `_verify_password`, `create_account` |
| Sessions | `secrets.token_urlsafe(32)`, cookie `HttpOnly; SameSite=Lax` (+ `Secure` en HTTPS), empreinte SHA-256 seule sur disque (`0600`), fermeture de toutes les sessions au reset du mot de passe et à la suppression | `server.py` |
| Anti force brute | 8 échecs par compte+IP et 40 par IP sur 15 min ; inscription 10/h/IP ; mot de passe oublié 6/h/IP et 3/h/e-mail ; démo 4/h/IP ; identifiants d'outils 40/h/client ; API publique 20/min/client ; essai public 3/jour/IP et 80/jour au total ; WhatsApp 30 messages/h | `server.py`, `whatsapp_channel.py` |
| Réinitialisation | jeton à usage unique valable 1 h, réponse identique que le compte existe ou non | `server.py: request_password_reset` |
| Isolation par client | fichiers séparés par `ClientId` ; routes de données exigent une session ; action en attente vérifiée contre le `clientId` ; clé API limitée à son client ; aucun repli vers l'identifiant d'un autre client | `server.py`, `Client-Credential-Store.ps1` |
| SSRF (connexion guidée) | nom d'hôte public uniquement (pas d'IP, suffixes internes bloqués, DNS résolu et public), sous-domaines liés à un domaine fournisseur | `dashboard/connect_guides.py` |
| Webhooks entrants | Twilio : HMAC-SHA1 de l'URL et des paramètres, comparaison constante, rejet sinon ; Meta : `X-Hub-Signature-256` HMAC-SHA256 | `phone_agent.py`, `whatsapp_channel.py` |
| Webhooks sortants | signés HMAC-SHA256 (`X-BK-Signature`), secret par client | `server.py: dispatch_webhook_if_configured` |
| Paiement | Stripe Checkout hébergé ; plan activé seulement si `payment_status = paid` vérifié côté serveur | `Stripe-Adapter.ps1`, `server.py` |
| Validation humaine | lecture (`READ_*`, `SEARCH_*`) immédiate ; toute écriture → `PENDING-ACTION` + confirmation explicite ; pré-autorisation optionnelle (désactivée par défaut) ; exception déclarée : la notification Slack d'une automatisation (résumé : objectif, statut, extrait de 300 caractères) part sans carte de confirmation si le client l'a cochée (`core/automation/AUTOMATION-ENGINE.ps1`) ; opérations financières jamais connectables par un client et toujours manuelles sur le compte propriétaire | `core/ai/adapters/ANTHROPIC-ADAPTER.ps1` |
| Chaîne d'autorisation | capacité, autorité, politique, tâche, identifiants, connecteur, fournisseur, preuve, rétention ; échec = `AI_AUTHORIZATION_BLOCKED` | `core/runtime/worker-runtime/Invoke-Worker-AI.ps1` |
| Agent téléphonique | aucun Worker, connecteur ni donnée de client joignable : seulement la fiche publique | `dashboard/phone_agent.py`, `docs/PHONE-AGENT.md` |
| Écritures concurrentes | verrou + écriture atomique (incident du 2026-09-28) | `server.py`, `core/runtime/State-Lock.ps1` |
| Droits des personnes | export JSON (`/api/account/export`), suppression en libre-service (`/api/account/delete`, mot de passe requis, refus si abonnement Stripe actif) | `server.py` |
| Disponibilité | mesure toutes les 60 s, agrégats quotidiens 90 j, page `/status.html`, `/api/status` | `status_monitor.py`, `trust_pages.py` |

## 4. Services tiers réellement appelés (liste de sous-traitants)

Cette liste suit le code (un service n'y figure que si le code l'appelle). Colonnes « Garanties » à compléter : le dépôt ne contient ni DPA signé ni preuve d'adhésion à un cadre de transfert.

| Service | Rôle | Données | Lieu | Déclencheur | Preuve dans le code | Garanties à documenter |
|---|---|---|---|---|---|---|
| OVHcloud | hébergement serveur, données, sauvegardes | toutes | France (ville non précisée) | toujours | mentions légales, `DEPLOIEMENT-VPS.md` | contrat OVHcloud, attestations par produit |
| Anthropic | modèle d'IA (Claude) | contenu des missions, profil, résultats d'outils lus, transcriptions téléphoniques | États-Unis | chaque mission / appel | `ANTHROPIC-ADAPTER.ps1`, `phone_agent.py` | DPA commercial, mécanisme de transfert |
| OpenAI | modèle de secours | idem | États-Unis | seulement si aucune clé Anthropic | `Get-DefaultProvider.ps1`, `OPENAI-ADAPTER.ps1` | à documenter **ou** retirer l'adaptateur |
| Stripe | paiement | e-mail, plan, id client (carte chez Stripe) | UE/États-Unis | souscription | `Stripe-Adapter.ps1` | DPA Stripe |
| Google | OAuth, Gmail/Agenda/Drive/Search Console (outils du client) ; e-mails transactionnels via Gmail si pas de SMTP ; Google Fonts (IP des visiteurs) | selon l'outil | États-Unis/UE | demande du client / visite | `Google-OAuth-Bridge.ps1`, `Mailer-Bridge.ps1`, `seo_pages.py` | DPA Google Workspace/Cloud |
| Microsoft | Graph : Outlook, Teams, OneDrive (outils du client) | selon l'outil | UE/États-Unis | demande du client | `server.py`, `Google-OAuth-Bridge.ps1` | DPA Microsoft |
| Twilio | agent téléphonique, appels sortants | numéro, propos transcrits | États-Unis | seulement si numéro configuré | `phone_agent.py` | DPA Twilio |
| Meta | WhatsApp Cloud API | numéro, messages | États-Unis/UE | seulement si lié | `whatsapp_channel.py` | conditions WhatsApp Business |
| SMTP dédié | e-mails du service | destinataire, contenu | selon fournisseur | seulement si `BK_SMTP_HOST` | `mailer.py` | à nommer si activé |
| Outils tiers du client (Slack, HubSpot, Asana, Intercom, LinkedIn, Dropbox, …) | actions demandées | selon l'outil | selon l'outil | demande du client | `oauth-vendors.json`, `connect-guides.json` | le client reste responsable de son contrat avec l'outil |
| GitHub | code source, déploiement | aucune donnée client | — | mises à jour | `.github/workflows/deploy.yml` | — |
| Cloudflare (cdnjs) | bibliothèque d'animation | IP des visiteurs | mondial | visite de l'accueil | `index.html` | envisager l'hébergement local de la bibliothèque |
| jsDelivr (CDN) | icônes des logos d'outils dans l'application | adresse IP des utilisateurs | mondial | quand la liste des outils s'affiche | `app.js` | envisager l'hébergement local des icônes |
| frankfurter.dev | taux de change indicatifs | aucune donnée personnelle | — | requête serveur (cache 12 h) | `server.py: get_fx_rates` | — |

Non utilisés à l'exécution (outils du propriétaire pour produire des vidéos) : D-ID, ElevenLabs (`core/avatar/`).

## 5. Procédures

- **Publier un incident** (page `/status.html`) : `docker compose exec app python3 /data/app/deploy/status-incident.py add --title "..." --impact minor --text "..."` (voir l'en-tête du script ; `update`, `resolve`, `delete`, `list`). Le fichier `memory/runtime/status/incidents.json` est un JSON simple, modifiable à la main.
- **Sonde de supervision** : `deploy/healthcheck.sh` (cron toutes les 5 min, à planifier) essaie `/api/health` puis `/api/workers` ; redémarre `app` après 2 échecs consécutifs. L'ancienne URL `/api/workers` reste en secours pour que le script fonctionne avant, pendant et après un déploiement.
- **Surveillance externe (pas en place aujourd'hui)** : `/api/health`, `/api/status`, `/status.html` et `/securite.html` répondent aussi à `HEAD` (en-têtes seulement), ce qui permet à un service gratuit (ex. UptimeRobot) de les surveiller depuis l'extérieur : c'est la seule façon d'être prévenu quand tout le serveur est arrêté, la mesure intégrée tournant sur le serveur qu'elle mesure.
- **Page de statut obsolète** : si le navigateur du visiteur ne joint pas `/api/status` (hors ligne, copie en cache), le bandeau passe à « Mesure indisponible » au lieu d'afficher un ancien « Tous les systèmes fonctionnent ».
- **Divulgation de vulnérabilité** : adresse déjà publiée `contact@bk-entreprise.com` ; `/.well-known/security.txt` (RFC 9116).
- **Fuite de données** (non formalisé à ce jour) : voir `docs/SOC2-READINESS.md` §6 — notification au PFPDT « dans les meilleurs délais » (nLPD art. 24) et, pour des personnes de l'UE, 72 h à l'autorité compétente (RGPD art. 33).

## 6. Ce qui n'est pas fait (à dire tel quel)

Aucun rapport SOC 2, aucune certification ISO/IEC 27001, aucun test d'intrusion externe, aucun programme de récompense. Pas de 2FA ni de SSO. Pas de HSTS ni de CSP (ni aucun en-tête de sécurité HTTP) et pas de jeton anti-CSRF dédié. Pas de HSM, pas de rotation de la clé maîtresse. Missions, profils et comptes non chiffrés au niveau applicatif. Sauvegardes sur le même serveur, non chiffrées, sans test de restauration documenté. Un seul serveur, une seule personne, aucune relecture de code par un tiers. Pas de scan de dépendances, pas de CI de tests bloquante, conteneur exécuté en `root`.

### Points faibles relevés pendant cette revue (7 octobre 2026)

| # | Constat (preuve) | Gravité | Correctif proposé |
|---|---|---|---|
| 1 | L'URL de webhook sortant d'un client (`POST /api/integrations/webhook`) n'est contrôlée que par `startswith("http")` : le serveur peut être amené à appeler une adresse interne (SSRF). La protection de `connect_guides.py` ne la couvre pas. | **Haute** | réutiliser `connect_guides.normalize_host` + refuser IP/ports/suffixes internes ; revalider au moment de l'envoi |
| 2 | Plusieurs routes lisent `Content-Length` sans plafond (`signup`, `login`, `chloe/task`, …) : un corps énorme est lu en mémoire. | Moyenne | plafond global (ex. 200 Ko) dans un point d'entrée unique |
| 3 | Le secret d'un outil transite par un fichier temporaire en clair (`/tmp/bkaiw-cred-in-*.json`), supprimé aussitôt, créé avec les droits par défaut. | Moyenne | `os.open(..., 0o600)` ou passage par l'entrée standard |
| 4 | Aucun en-tête HTTP de sécurité (HSTS, CSP, `X-Content-Type-Options`, `Referrer-Policy`) ; pas de jeton anti-CSRF (SameSite=Lax seul). | Moyenne | directive `header` dans `deploy/Caddyfile.docker` ; jeton CSRF sur les POST à cookie |
| 5 | **Corrigé dans cette branche.** Le site affichait « personne, pas même nous, ne peut les lire » (`dashboard/index.html`, section « Connectez votre outil ») et la politique de confidentialité §6 disait « y compris par l'équipe » : techniquement faux pour une personne qui détient la clé serveur. Les phrases (page d'accueil, FAQ, politique de confidentialité, dictionnaires anglais) disent maintenant « chiffrés au repos, jamais réaffichés ni renvoyés au navigateur ; une personne ayant accès au serveur et à son environnement pourrait techniquement les lire ». `tests/trust/test_trust_extras.py` refuse le retour de l'ancienne promesse. | Moyenne (honnêteté) | fait ; à relire par le propriétaire |
| 6 | Conteneur exécuté en `root` (aucune directive `USER`). | Basse | utilisateur dédié, volume en lecture/écriture ciblée |
| 7 | Les échecs de connexion ne sont pas journalisés (seulement comptés en mémoire). | Basse | événement `login_failed` dans `activity-log.json` |
| 8 | `delete_account` ne supprime ni l'historique de facturation ni les lignes de `activity-log.json` / `demo-requests.json`. | Basse (si justifié par la loi comptable) | documenter la durée, purger ce qui n'a pas de base légale |
| 9 | Compteurs de limitation en mémoire : remis à zéro à chaque redémarrage ; l'IP vient du premier élément de `X-Forwarded-For` (sûr derrière Caddy, falsifiable si on atteint le port 8787 directement). | Basse | persister ou ajouter une limite au proxy ; ne jamais exposer 8787 |
| 10 | Le secret de webhook sortant est stocké en clair et renvoyé par `GET /api/integrations/webhook` (au client concerné). | Basse | afficher une seule fois, stocker haché/chiffré |
| 11 | `core/ai/CREDENTIAL-BOUNDARY.md` décrit un état ancien (« aucun credential, LLM désactivé ») : ne pas l'utiliser comme preuve. | Info | mettre à jour ou archiver |
| 12 | Session client de 30 jours sans délai d'inactivité ni liste des appareils. | Basse | délai d'inactivité, bouton « fermer toutes les sessions » |
| 13 | La politique de confidentialité (§5 de `dashboard/confidentialite.html` et le même texte dans `index.html`) affirme que les transferts à l'étranger « sont encadrés par des garanties contractuelles conformes à la nLPD ». Le dépôt ne contient ni DPA signé ni preuve d'adhésion d'un fournisseur à un cadre de transfert (voir la colonne « Garanties à documenter » du §4). Texte juridique : **non modifié** par ce travail. | Moyenne (honnêteté juridique) | rassembler les DPA et les certifications DPF fournisseur par fournisseur, puis garder la phrase ; sinon la reformuler avec un juriste |
| 14 | La planification nocturne de `deploy/backup.sh` et le cron de `deploy/healthcheck.sh` sont **décrits** dans le dépôt (`DEPLOIEMENT-VPS.md`, en-tête du script) mais le dépôt ne peut pas prouver qu'ils sont installés sur le serveur. La page publique le dit (« le dépôt décrit cette planification mais ne peut pas prouver qu'elle est active »). | Moyenne | sur le serveur : `crontab -l` ; si absent, installer les deux lignes ; vérifier une archive récente dans `/var/backups/bk-ai-workers` |
| 15 | L'icône de chaque outil est chargée depuis jsDelivr (`dashboard/app.js`, `simple-icons`, y compris la version `@latest` non épinglée) : l'adresse IP de l'utilisateur est vue par ce CDN et une mise à jour du paquet change ce qui s'affiche sans passer par notre code. Ajouté à la liste des sous-traitants. | Basse | héberger les quelques icônes utilisées dans le dépôt |

## 7. Rétention et suppression — décisions à prendre

Les durées ci-dessus sont celles **du code**. La politique de confidentialité promet une suppression « sur demande » et 10 ans de conservation comptable : décider ce qui relève de la comptabilité (facturation) et purger le reste (journal d'activité, demandes de démo, journal de l'essai public) selon une durée écrite.

## 8. Garder la page publique honnête

```
python tests/trust/run_all.py [--fast]        # tout d'un coup (--fast : sans le test de bout en bout)
python tests/trust/test_trust_pages.py        # preuves du code, traductions, mots de certification, security.txt, hooks
python tests/trust/test_status_monitor.py     # mesure, uptime, rotation, incidents
python tests/trust/test_trust_extras.py       # aucune promesse contredite, inventaire des hôtes externes, page Statut jamais périmée, HEAD
python tests/trust/check_certification_claims.py   # échoue si un mot de certification n'est ni une négation ni appuyé par un document
python tests/trust/e2e_server.py [--long]     # vrai serveur sur copie jetable, port libre, jamais les vraies données
python dashboard/trust_pages.py --write-i18n  # régénère dashboard/i18n-en-trust.js après toute modification du texte
```
Pour **faire apparaître** un jour une preuve positive (rapport SOC 2, test d'intrusion), déposer le document dans `docs/evidence/` (`soc2-*.pdf`, `pentest-*.pdf`, …) : les tests « non fait » échouent alors, ce qui oblige à réécrire la page — et seulement alors la phrase positive devient autorisée.
