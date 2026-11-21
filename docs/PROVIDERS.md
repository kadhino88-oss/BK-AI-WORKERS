# Le moteur d'IA est un choix : Claude, moteur local, hébergeur suisse, clé du client

Décision du propriétaire du 2026-10-25. Le crédit Anthropic est épuisé depuis le 2026-10-20, les missions retombent sur une réponse de secours, et le propriétaire ne veut pas dépendre d'un seul fournisseur payant. Ce document décrit ce qui est **construit et testé**, ce que chaque moteur sait **vraiment** faire, et les gestes que **seul le propriétaire** peut faire (installer Tailscale, régler le pare-feu, écrire le `.env`, choisir un modèle, fixer un plafond).

> **En une phrase** : tant que vous ne changez rien, rien ne change (Claude, comme avant). Dès que vous renseignez l'adresse de votre Ollama, l'essai gratuit et les démonstrations passent sur votre modèle local (coût zéro) ; dès que vous fixez un plafond, le crédit Claude ne peut plus s'épuiser en silence ; et à tout moment la réponse dit quel moteur l'a écrite.

## 1. Les quatre modes

| # | Mode | Qui | Moteur | Qui paie l'IA |
|---|---|---|---|---|
| 1 | Essai gratuit et démonstrations | forfait **Essai** et visiteur de l'essai public | moteur **local** (votre Ollama), jamais Claude | vous : coût 0 (votre PC) |
| 2 | Clients payants | tous les forfaits payants | **Claude** (ou un hébergeur suisse, quand vous l'aurez choisi) | vous, dans le prix du forfait (IA ≤ 35 %, `docs/PRICING.md`) |
| 3 | Clé personnelle (BYOK) | une entreprise qui a son propre compte | sa clé Anthropic ou OpenAI-compatible, **pour ses missions seulement** | le client, directement chez son fournisseur |
| 4 | Plafond de dépense | tout le monde sur Claude | au-delà d'un plafond jour / mois, bascule sur le moteur gratuit, avec mention | – |

Rien n'est lié à un fournisseur dans le code des Workers : le routeur (`dashboard/provider_router.py`) décide, l'exécuteur (`core/ai/Invoke-EngineChain.ps1`) suit le plan, deux adaptateurs parlent aux moteurs (`ANTHROPIC-ADAPTER.ps1`, `OPENAI-COMPAT-ADAPTER.ps1`).

## 2. Ce que chaque moteur sait faire (sans promesse)

Exposé par `GET /api/engine` pour le compte connecté, avec le moteur qu'il utilisera réellement ; affiché à côté de la zone de mission (« Moteur : Claude » ou « Moteur local (Llama 3) : réponses plus simples, pas de recherche web ni de fichiers Office »), avec un lien « Ce que ce moteur sait faire », et sous chaque réponse (« Moteur : … », « Réponse du moteur de remplacement : … »).

| Capacité | Claude | Moteur local / hébergeur suisse | Clé OpenAI-compatible |
|---|---|---|---|
| Recherche web | oui (outil serveur d'Anthropic) | **non**, sauf si vous configurez un point de recherche compatible SearXNG (`BK_SEARCH_URL`, §4.2) : extraits de résultats seulement | idem (le même point de recherche, si vous en avez un) |
| Lecture d'une page web | oui | oui, **client-side, https seulement**, texte seulement (`dashboard/safe_fetch.py`), et **seulement une adresse écrite telle quelle par le client ou trouvée dans un résultat de recherche, de page ou d'outil connecté** de la mission (ou la page d'accueil d'un site que le client a nommé) : une adresse fabriquée par le modèle, qui pourrait emporter des données du client vers un tiers, est refusée | oui, idem |
| Exécution de code | oui | **non** | non |
| Fichiers Excel / Word / PowerPoint / PDF | oui | **non** | non |
| Fichiers texte (txt, md, csv, json, html) | oui | oui (mêmes plafonds : 10 fichiers, 25 Mo, 60 Mo) | oui |
| Outils connectés (brouillons, lectures) | fiable | local : **fragile** (voir §6) ; suisse : correct | correct |
| Projets de plusieurs heures | oui | **non** | non |
| Français | très bon | local : correct mais plus simple, se trompe plus sur les faits et les chiffres ; suisse : bon | selon le modèle |

Le mode projet (`docs/AUTONOMY-ENGINE.md`, branche `ws/chantier-design`) doit lire cette matrice avant de promettre un chantier : fonction Python `server.engine_capabilities(client_id, level)` (capacités du moteur que ce compte utilisera), ou `provider_router.engine_supports(<moteur>, "officeFiles")`, `provider_router.capabilities_for(<moteur>)`, `provider_router.capability_matrix()`.

**Une demande qui exige ce que le moteur n'a pas le dit** : le prompt envoyé au modèle lui interdit de prétendre avoir cherché sur le web ou ouvert un fichier, et la réponse se termine par « Remarque sur le moteur utilisé (…) : votre demande semble avoir besoin de … que ce moteur ne sait pas faire. Cette partie n'a PAS été réalisée ».

## 3. Comment le serveur choisit (par mission)

1. **Clé personnelle** du compte (enregistrée et activée) → c'est **sa** chaîne, sans repli vers nos moteurs (un repli serait une dépense cachée pour vous, ou pour lui). Le plafond de dépense ne s'applique pas à sa clé.
2. **Essai** (forfait Essai, visiteur de l'essai public) → **chaîne gratuite** seulement (Ollama). Jamais Claude ni Infomaniak, même si aucun moteur gratuit n'est configuré ou si Ollama est tombé : l'essai répond alors « aucun moteur disponible » et ne crée aucune dépense IA.
3. Sinon, la **chaîne du niveau** (réglage du propriétaire `levelChains`, ou champ facultatif `providers` d'un niveau dans `core/ai/LEVELS.json`, par exemple `"rapide": {"providers": ["ollama", "anthropic"]}`), sinon la **chaîne par défaut** (réglage `defaultChain`, sinon `BK_AI_PROVIDER`, sinon `anthropic`).
4. On retire de la chaîne tout moteur **mis de côté** (disjoncteur) et Claude si son **plafond** est atteint. Si Claude est coupé par le plafond et qu'il ne reste rien, la **chaîne gratuite** prend le relais, avec mention.

**Disjoncteur** (`runtime/engine/health.json`) : un moteur qui répond « crédit épuisé », « accès refusé » ou « injoignable » est mis de côté **5 minutes** (`BK_ENGINE_BREAKER_SECONDS`) : les missions suivantes ne l'attendent pas. Une erreur ponctuelle (délai dépassé, 429, 5xx) fait seulement passer **cette** mission au moteur suivant.

**Repli, jamais en silence** : chaque résultat porte `Engine = {provider, model, local, failedOver, label, …}`. Si ce n'est pas le moteur prévu qui a répondu, la réponse commence par « Note : cette réponse vient du moteur « Moteur local (Llama 3) » et non de Claude (le crédit de ce fournisseur est épuisé). Elle peut être plus simple. Cette mission ne consomme aucun crédit. » Une réponse locale n'est **jamais** étiquetée Claude. Le repli ne se fait **que** le long de la chaîne autorisée (une chaîne « local seul » ne se rabat jamais sur Claude).

**Crédits** (`Get-BKMissionCredits`, `dashboard/Submit-Task.ps1`) :

| Cas | Crédits |
|---|---|
| Mission voulue sur le moteur local (essai) ou sur Claude | le coût du niveau (Rapide 1, Équilibre 6, Approfondi 12) |
| **Repli** : le moteur prévu était indisponible ou plafonné | **0** |
| Aucun moteur disponible (réponse de secours, « Degraded ») | **0** |
| Clé personnelle (BYOK) | le coût du niveau — **proposition à valider, voir §8** |

## 4. Réglages du propriétaire

### 4.1 Dans l'application (vue Admin, carte « Moteur d'IA »)

Choix du moteur (Claude seul, local puis Claude, Claude puis local, local seul, hébergeur suisse), adresse et modèle du moteur local, plafonds jour / mois en CHF. Même chose par l'API (`POST /api/admin/engine`, **propriétaire seulement** : un compte client reçoit 401) :

```json
{
  "defaultChain": ["anthropic", "ollama"],
  "endpoints": {"ollama": {"url": "http://100.x.y.z:11434", "model": "llama3.1:8b"}},
  "ceiling": {"dailyChf": 5, "monthlyChf": 80, "alert": true},
  "levelChains": {"rapide": ["ollama", "anthropic"]},
  "search": {"url": "http://100.x.y.z:8080"}
}
```

Tout est validé avant d'être écrit (rien n'est enregistré s'il y a une erreur) : `core/ai/data/engine-settings.json` (dans le volume persistant). **Les jetons ne se saisissent jamais ici** (§4.2). `GET /api/admin/engine` montre les réglages effectifs, la dépense du jour et du mois, le reste du plafond, et les moteurs mis de côté.

### 4.2 Dans le `.env` du serveur (noms seulement, aucun secret dans ce document)

```
BK_AI_PROVIDER=swiss       # choix de lancement Alex : Infomaniak seul, sans secours Anthropic
BK_OLLAMA_URL=             # http://100.x.y.z:11434  (adresse Tailscale de votre PC)
BK_OLLAMA_MODEL=           # llama3.1:8b
BK_OLLAMA_TIMEOUT_SEC=     # 300 par défaut
BK_SECRET_OLLAMA=          # seulement si Ollama est derrière un https qui exige un jeton Bearer
BK_SEARCH_URL=http://searxng:8080  # pour Alex, avec docker-compose.search.yml
SEARXNG_SECRET=            # obligatoire pour le service SearXNG ; générer avec openssl rand -hex 32
BK_SECRET_SEARCH=          # jeton Bearer, obligatoire si l'adresse est en https
BK_SWISS_URL=              # hébergeur suisse (Infomaniak AI Tools, Mistral, vLLM...) : adresse https
BK_SWISS_MODEL=mistralai/Mistral-Small-4-119B-2603
BK_SECRET_SWISS=           # jeton Bearer, obligatoire en https (voir deploy/set-engine-secret.py)
BK_CLAUDE_DAILY_CHF=       # plafond de dépense Claude, par jour UTC
BK_CLAUDE_MONTHLY_CHF=     # et par mois
BK_PILOT_NOTIFY_EMAIL=     # adresse qui reçoit l'alerte à 80 % (déjà utilisée pour les demandes d'embauche)
```

Facultatifs : `BK_ENGINE_BREAKER_SECONDS` (300), `BK_ENGINE_MAX_PROMPT_CHARS`, `BK_ENGINE_PLAYBOOK_CHARS`, `BK_ENGINE_COMPACT_PROMPT=0|1`, `BK_ENGINE_MAX_TOKENS`, `BK_ENGINE_WEBFETCH=0` (coupe la lecture de pages web). Les réglages enregistrés dans l'application l'emportent sur le `.env`. Après une modification du `.env` : `docker compose up -d`.

Pour enregistrer un jeton sans qu'il s'affiche : `python3 deploy/set-engine-secret.py` (demande le jeton sans l'écho et l'écrit dans `.env`, droits 600).

## 5. Relier le serveur à VOTRE PC sans l'exposer sur Internet

**À faire par vous.** Le VPS doit joindre Ollama sur votre PC, mais votre PC ne doit **jamais** devenir joignable depuis Internet. La solution recommandée est un **réseau privé maillé** (Tailscale, offre gratuite : vérifiez les conditions actuelles). Le VPS appelle alors `http://100.x.y.z:11434` (l'adresse Tailscale de votre PC, plage 100.64.0.0/10) : le trafic est chiffré de bout en bout et seuls vos deux appareils sont dans ce réseau. Il traverse quand même Internet (le VPS est en France, le PC chez vous), sous forme chiffrée ; quand une liaison directe est impossible (pare-feu, NAT), il passe par un **serveur relais de Tailscale** (DERP), qui ne voit que des paquets chiffrés. La page Sécurité le dit tel quel.

### 5.1 Pas à pas

1. **Sur votre PC (Windows)** : installez Tailscale (tailscale.com/download), connectez-vous. Notez l'adresse du PC (`tailscale ip -4`, du type `100.101.102.103`).
2. **Sur le VPS** : installez Tailscale **sur la machine elle-même** (pas dans le conteneur) : `curl -fsSL https://tailscale.com/install.sh | sh` puis `sudo tailscale up` avec le **même compte**. Dans la console Tailscale, désactivez l'expiration de clé du VPS (sinon il sort du réseau après quelques mois).
3. **Ollama n'écoute que sur le réseau privé** : sur le PC, variable d'environnement système `OLLAMA_HOST=100.101.102.103:11434` (l'adresse Tailscale du PC, **jamais `0.0.0.0`** sur un réseau public), puis redémarrer Ollama. Pour que le modèle reste en mémoire entre deux missions (sinon il se décharge après 5 minutes et le rechargement prend plusieurs minutes), ajoutez aussi `OLLAMA_KEEP_ALIVE=-1`. Si Ollama démarre avant Tailscale, il ne trouve pas son adresse : lancez-le après Tailscale (démarrage différé), ou utilisez l'alternative de 5.3.
4. **Pare-feu Windows limité au réseau privé** (PowerShell en administrateur) :
   ```powershell
   New-NetFirewallRule -DisplayName "Ollama via Tailscale" -Direction Inbound -Protocol TCP -LocalPort 11434 -RemoteAddress 100.64.0.0/10 -Action Allow -Profile Any
   Get-NetFirewallRule -DisplayName "*Ollama*" | Get-NetFirewallPortFilter     # il ne doit exister AUCUNE autre règle Ollama « Tout le monde »
   ```
   Supprimez toute règle créée par l'installateur d'Ollama qui autoriserait le port 11434 depuis « n'importe quelle adresse ».
5. **Limiter Tailscale lui-même** (console Tailscale, Access controls) : seul le VPS peut appeler le port 11434 de votre PC.
   ```json
   {"tagOwners": {"tag:bk-serveur": ["autogroup:admin"], "tag:pc-proprietaire": ["autogroup:admin"]},
    "acls": [{"action": "accept", "src": ["tag:bk-serveur"], "dst": ["tag:pc-proprietaire:11434"]}]}
   ```
   (puis étiquetez le VPS et le PC dans la console).
6. **Dans `.env` sur le VPS** : `BK_OLLAMA_URL=http://100.101.102.103:11434` et `BK_OLLAMA_MODEL=` (§4.2), puis `docker compose up -d`.
7. **Vérifier depuis le serveur** : `docker compose exec app python3 /data/app/deploy/check-engine.py --chat` affiche l'adresse (jamais un jeton), les modèles installés, le modèle choisi, si l'appel d'outils natif est disponible, et le temps d'une vraie réponse courte. Code de sortie 0 = prêt.

L'adaptateur **refuse** de lui-même tout `http://` qui n'est pas loopback (127.x), réseau privé (10.x, 172.16-31.x, 192.168.x, fd00::/8) ou CGNAT (100.64.0.0/10, Tailscale), toute adresse de lien local (169.254.x.x : métadonnées des clouds), toute adresse avec identifiants, et exige un jeton Bearer pour tout `https://`. Pour le **moteur local** (`ollama`), il refuse en plus **toute adresse publique**, même en `https://` avec un jeton (code `NOT_PRIVATE`) : un tunnel public (ngrok, port ouvert) n'est jamais accepté, ce qui garantit ce que dit la page Sécurité (moteur relié par un réseau privé). Un modèle hébergé sur Internet passe par l'hébergeur suisse (`swiss`). Mêmes règles dans `POST /api/admin/engine` (adresse refusée avant d'être enregistrée) et dans `check-engine.py`.

### 5.2 Pourquoi pas ngrok + `Bridge.cs` (l'essai du 2026-10-21/22)

À ne **pas** utiliser en production (`integrations/local-sovereign/README.md`) : le pont n'a **aucune authentification** (quiconque connaît l'URL publique déclenche un Worker, et peut donc épuiser votre PC ou y injecter du texte) ; il **ignore la demande** et lance toujours le même Worker ; l'URL est **publique** (et change à chaque redémarrage de ngrok gratuit) ; votre PC doit rester allumé et exposé. Avec le réseau privé, rien de tout cela n'existe : pas d'URL publique, pas de port ouvert sur Internet, authentification par l'appartenance au réseau.

### 5.3 Variante sans changer l'écoute d'Ollama (non testée ici)

Garder `OLLAMA_HOST` par défaut (127.0.0.1) et laisser Tailscale relayer le port : `tailscale serve --tcp 11434 tcp://127.0.0.1:11434` sur le PC. Ollama n'est alors jamais lié à une adresse du réseau. Je n'ai pas pu tester cette commande ici (pas de Tailscale sur cette machine) : essayez-la avec `check-engine.py`.

### 5.4 Si le PC est éteint

Le serveur sonde le port avant chaque mission (3 secondes). Moteur injoignable → il est mis de côté 5 minutes et la mission passe au moteur suivant de la chaîne, ou, pour un essai, répond « Aucun moteur d'IA n'a pu répondre pour le moment… ne consomme aucun crédit ». Le choix « PC toujours allumé » ou « hébergeur suisse » est le vôtre (§7).

## 6. Quel modèle ? Ce que j'ai mesuré sur votre PC (2026-10-25/26)

Modèles installés : `llama3:latest` (8 B, contexte 8 192), `qwen2.5:1.5b`.

| | `llama3:latest` | `qwen2.5:1.5b` |
|---|---|---|
| Appel d'outils natif (`/v1/chat/completions` avec `tools`) | **non** : « does not support tools » (HTTP 400) | oui, mais ne l'a pas utilisé dans mon essai (trop petit) |
| Lecture du prompt (mesuré, CPU) | environ **6 jetons / seconde** | environ 50 jetons / seconde |
| Chargement à froid | **plus de 3 minutes** (le modèle s'est déchargé après 5 min d'inactivité) | environ 13 s |

Conséquences, dites sans détour :

- Avec Llama 3 8 B sur ce PC, un prompt de Worker **complet** (environ 3 000 jetons) mettrait **plus de 8 minutes** à être lu : inutilisable. J'ai donc ajouté pour les moteurs locaux un **prompt compact** (environ un tiers du texte, mêmes règles de sécurité), un budget de prompt de 12 000 caractères (l'historique de conversation est retiré en premier, jamais les règles ni la demande), un guide métier raccourci à 1 500 caractères et une réponse plafonnée à 1 200 jetons. Voir `tests/providers/test_openai_adapter.py`.
- Tant que le modèle n'est pas chargé en mémoire, la première mission est très lente : mettez `OLLAMA_KEEP_ALIVE=-1` (§5.1).
- **Appel d'outils** : sans appel natif, l'adaptateur demande au modèle d'écrire l'appel en JSON dans sa réponse, avec une validation **stricte** (le message entier doit être un seul objet `{"tool": …, "arguments": …}` ; un nom d'outil inconnu, une clé en trop ou du texte autour sont refusés et le modèle reçoit un rappel de format). Un petit modèle le respecte mal : ne comptez pas sur les connecteurs avec un modèle local.
- **Recommandation** : si vous voulez un modèle local utilisable, **téléchargez `llama3.1:8b` ou `qwen2.5:7b`** (appel d'outils natif, contexte long) ; ce choix et ce téléchargement (environ 5 Go) sont les vôtres, je n'ai rien téléchargé : `ollama pull qwen2.5:7b`. Sans carte graphique, comptez toujours des réponses lentes : pour un vrai usage, un **hébergeur suisse** (même classe de modèles ouverts, hébergé, toujours allumé, en Suisse) est le bon remplaçant — c'est un changement de configuration (§7), pas de code.
- Le résultat de l'essai réel contre votre Ollama figure en fin de document (§11).

## 7. Infomaniak AI + recherche web séparée

Infomaniak AI Tools fournit un endpoint compatible OpenAI et facture les modèles à l'usage. Le modèle n'est pas connecté à Internet : la recherche d'Alex passe par un endpoint SearXNG distinct. Dans le dépôt, l'adaptateur fournit à Alex l'outil `web_search` (extraits et liens), puis `web_fetch` pour ouvrir une page publique. Ces outils ne prétendent jamais qu'une recherche a réussi si elle n'a pas eu lieu.

### 7.1 Configuration Infomaniak

1. Dans Infomaniak Manager, créer/ouvrir AI Services et relever l'identifiant du produit. **Modèle choisi pour le lancement : `mistralai/Mistral-Small-4-119B-2603`.** Infomaniak le décrit comme multilingue, compatible avec les appels de fonction et conçu pour les workflows autonomes. Le tarif affiché est de 0,20 CHF / million de tokens en entrée et 0,75 CHF / million en sortie. Ce choix privilégie la fiabilité d'Alex pour enchaîner recherche, comparaison et rédaction ; le nombre de recherches reste borné par le niveau de mission. La qualité, le fonctionnement des outils et le coût par tâche restent à valider sur trois cas avant le pilote. Voir le [catalogue des modèles](https://www.infomaniak.com/en/hosting/ai-services/open-source-models) et les [tarifs actuels](https://www.infomaniak.com/en/hosting/ai-services/prices).
2. Utiliser l'URL de base de l'API Chat Completions : `https://api.infomaniak.com/2/ai/<ID_PRODUIT>/openai/v1`. L'adaptateur ajoute `/chat/completions`.
3. Sur le serveur, enregistrer le jeton sans l'afficher : `python3 deploy/set-engine-secret.py swiss`. Ne jamais le mettre dans `engine-settings.json`, le dépôt ou une capture d'écran.
4. Dans la vue Admin, carte « Moteur d'IA », saisir l'URL, le modèle et le point de recherche. Le jeton n'est pas saisi dans la page.
5. Pour éviter toute dépense Anthropic imprévue, choisir « Hôte suisse seul (Infomaniak) ». Si Infomaniak est indisponible, la mission échoue sans basculer vers Claude. Le choix « Hôte suisse, puis Claude » autorise au contraire cette dépense de secours.
6. Régler une limite de dépense dans la console Infomaniak. Les champs de plafond de la vue Admin couvrent uniquement Claude et ne limitent pas Infomaniak.
7. Les comptes Essai ne basculent jamais sur Infomaniak : sans Ollama gratuit configuré, leurs tâches sont suspendues. Configurez Ollama pour proposer un essai gratuit ; ne financez pas un essai public avec le budget du pilote.

### 7.2 Recherche web avec SearXNG

Une instance SearXNG doit répondre à `GET /search?q=...&format=json`; le format JSON doit être activé dans `search.formats`. La configuration proposée est facultative et privée : `docker-compose.search.yml` ajoute SearXNG sur un réseau Docker partagé uniquement avec l'application, sans publier son port sur Internet. Le fichier `deploy/searxng/settings.yml` active le JSON et le mode sans proxy d'images.

Sur le serveur :

1. Ajouter `SEARXNG_SECRET` dans `.env` avec une valeur aléatoire (par exemple `openssl rand -hex 32`). Ne pas réutiliser un mot de passe ou une clé API.
2. Ajouter `BK_SEARCH_URL=http://searxng:8080` dans `.env`.
3. Démarrer l'application avec le service de recherche : `docker compose -f docker-compose.yml -f docker-compose.search.yml up -d --build`.
4. Garder ces deux fichiers dans chaque commande Compose de mise à jour. Sans le fichier `docker-compose.search.yml`, Compose ne démarre pas SearXNG.

Si une autre instance est utilisée, saisir son URL de base dans la vue Admin. En HTTPS, enregistrer son jeton Bearer avec `python3 deploy/set-engine-secret.py search`; en HTTP, seules les adresses de réseau privé contrôlées par l'éditeur sont permises.

**Données et coût.** SearXNG transmet la requête aux moteurs de recherche qu'il utilise. Ne pas y envoyer d'email client, de nom de particulier ou de donnée confidentielle. Choisir ses moteurs et documenter les destinataires réellement utilisés dans les informations de confidentialité avant de vendre le pilote. Infomaniak AI se facture à l'usage ; limiter le montant au niveau de son produit avant les essais avec de vraies demandes.

### 7.3 Vérification avant le pilote payant

Après configuration, vérifier d'abord SearXNG sans appel d'IA : `docker compose -f docker-compose.yml -f docker-compose.search.yml exec app python3 /data/app/deploy/check-search.py`. Puis envoyer une courte requête réelle à Infomaniak : `docker compose -f docker-compose.yml -f docker-compose.search.yml exec app python3 /data/app/deploy/check-engine.py --engine swiss --chat`. Enfin, effectuer trois cas fictifs dans Alex : demande compatible, demande ambiguë et demande hors cible. Vérifier les liens, l'ouverture des pages, les inconnues, le brouillon non envoyé et le coût indiqué dans Infomaniak. Ne proposer de règlement qu'après ce contrôle.

Le moteur suisse n'est **pas automatiquement meilleur que Claude** : le choix du modèle et des appels d'outils doit être validé sur les cas métier. L'essai gratuit reste verrouillé sur Ollama ; s'il n'est pas opérationnel, la tâche d'essai est suspendue, jamais facturée à Infomaniak.

## 8. Clé personnelle (BYOK)

Carte « Mon moteur d'IA » dans la page Facturation (comptes clients) ou par l'API : `POST /api/engine/byok` `{kind: "anthropic"|"openai_compat", key, endpoint?, model?}`, `GET /api/engine/byok` (description sans la clé), `POST /api/engine/byok` `{enabled: false}` (désactiver), `POST /api/engine/byok/remove` ou `DELETE /api/engine/byok`.

- **Validation par la forme seulement** (aucun appel réel, aucun coût) : une clé Anthropic commence par `sk-ant-` ; une clé OpenAI-compatible fait 16 à 400 caractères sans espace, avec un modèle obligatoire.
- **Aucune adresse libre** : un client ne peut pas faire appeler au serveur une adresse de son choix. Hôtes acceptés (https, adresse publique, nom dans la liste blanche) : `api.openai.com`, `api.mistral.ai`, `api.groq.com`, `api.together.xyz`, `openrouter.ai`, `api.infomaniak.com`, `api.anthropic.com`, plus ceux que vous ajoutez (`byokAllowedHosts`). La résolution DNS est revérifiée à chaque appel.
- **Chiffrée** dans le coffre existant (AES-256-GCM, `core/connectors/client-credentials/data/<ClientId>/ai_engine.json`), **jamais renvoyée** par aucune route, jamais journalisée, jamais dans un prompt ; la description non secrète (type, hôte, modèle) est dans `core/ai/data/byok/<ClientId>.json`. Isolée par `ClientId`. **La suppression du compte les efface** (testé).
- Une clé Anthropic de client passe par le même adaptateur que Claude (recherche web, fichiers, code), avec **sa** clé ; la dépense n'entre jamais dans le plafond de la plateforme. Si sa clé échoue, la mission échoue **sans** se rabattre sur nos moteurs.
- Le routage de Chloé (repli de compréhension de la demande, qui appelle Claude avec la clé de la plateforme) est **sauté** pour une mission en clé personnelle, en essai local ou au-dessus du plafond : Chloé retombe sur son routage par mots-clés (`chloe/Invoke-Chloe-Orchestration.ps1`).

**Crédits avec une clé personnelle — proposition à valider.** Aujourd'hui (et donc ce qui est livré) : les crédits restent ceux du forfait (Rapide 1, Équilibre 6, Approfondi 12), parce que le prix du forfait couvre aussi la plateforme (orchestration, mémoire, connecteurs, support), pas seulement l'IA. Votre coût d'IA est alors nul sur ces missions, donc votre marge monte. Alternatives : (B) un crédit fixe par mission en clé personnelle (frais de plateforme seuls) — plus attractif pour un gros utilisateur, mais ouvre un arbitrage (forfait bas + clé) ; (C) un forfait « plateforme seule » moins cher. **Ma recommandation : A pour commencer**, présenté honnêtement (« votre clé garde vos données chez le fournisseur de votre choix et évite nos coûts d'IA ; les crédits du forfait s'appliquent toujours »), puis B si des clients le demandent. Passer à B se fait à un seul endroit (`Get-BKMissionCredits`, qui lit déjà `Result.Engine.byok`).

## 9. Plafond de dépense Claude

`ceiling.dailyChf` / `monthlyChf` (jour UTC, mois UTC), vérifiés **avant chaque appel à Claude** avec la comptabilité existante (`Mission-Cost.ps1` : jetons, cache, recherches web, tarifs de `core/ai/AI-PRICING.json`) :

- chaque mission Claude de la plateforme ajoute son coût réel à `runtime/engine/spend.json` ; le **reste disponible** devient le plafond de la mission en cours (la boucle s'arrête avant l'appel qui le dépasserait, avec la note « Mission arrêtée au plafond de coût ») ;
- à **80 %** puis à **100 %** (au plus deux e-mails par plafond et par période, à `BK_PILOT_NOTIFY_EMAIL`), alerte ;
- plafond atteint : Claude est sauté, la chaîne gratuite répond, avec la mention « le plafond de dépense Claude fixé par le propriétaire est atteint » et 0 crédit ; s'il n'y a pas de moteur gratuit configuré, la mission répond « Aucun moteur d'IA n'a pu répondre » plutôt que de dépenser.

Limites à connaître : le **premier appel** d'une mission n'est pas bloqué par le reste (une mission peut dépasser de son coût) ; deux missions simultanées peuvent dépasser ensemble de leur coût ; l'**agent téléphonique** (`dashboard/phone_agent.py`) appelle Claude directement et n'est ni compté ni plafonné ; le coût est une **estimation au tarif public** (pas une facture Anthropic) ; seules les missions **terminées** sont ajoutées. Un plafond bas protège le portefeuille, il ne remplace pas la limite que vous pouvez fixer dans la console Anthropic (recommandé en plus).

## 10. Textes à faire valider par vous (je n'ai modifié aucun texte juridique)

Ce qui est vrai maintenant : Anthropic ne reçoit le contenu des missions **que** lorsque le moteur Claude est utilisé (par défaut aujourd'hui, ou en repli) ; le moteur local (votre PC, réseau privé) ou un hébergeur suisse reçoivent le contenu des missions qui leur sont confiées ; un client en clé personnelle envoie le contenu de **ses** missions au fournisseur qu'il a choisi. La page publique `/securite.html` (tableau des sous-traitants) a été corrigée en ce sens, avec trois lignes ajoutées (moteur local, hébergeur suisse, fournisseur de la clé du client) reliées aux preuves de `tests/trust/claims-evidence.json`. **Restent à votre main** (textes juridiques) :

1. **Politique de confidentialité** (`dashboard/confidentialite.html` §5 et le texte équivalent de `dashboard/index.html`) — remplacer « transmis à notre fournisseur d'IA (Anthropic, États-Unis) » par : « …transmis au moteur d'IA qui traite la mission : Claude (Anthropic, États-Unis) par défaut ; un modèle ouvert exécuté sur l'infrastructure de l'éditeur ou chez un hébergeur situé en Suisse, lorsque l'éditeur l'utilise (essai gratuit, démonstrations, remplacement de Claude) ; ou le fournisseur dont vous avez vous-même enregistré la clé. La page Sécurité et confiance liste les sous-traitants réellement utilisés. »
2. **CGV** — nouvel article « Moteur d'IA » : « Le moteur d'IA utilisé pour une mission dépend du plan et de la disponibilité des fournisseurs. En cas d'indisponibilité du moteur prévu, BK-ENTREPRISE peut traiter la mission avec un moteur de remplacement ; la réponse l'indique et la mission ne consomme alors aucun crédit. Les réponses d'un moteur de remplacement ou de l'essai gratuit peuvent être plus simples ; les capacités propres à certains moteurs (recherche web, fichiers Office) ne sont pas garanties. Un client peut utiliser sa propre clé d'un fournisseur d'IA ; il traite alors directement avec ce fournisseur et en supporte le coût. » Et à l'art. 3 (Essai gratuit) : « L'essai peut être traité par un modèle ouvert exécuté sur l'infrastructure de l'éditeur ; n'y saisissez pas de données confidentielles. »
3. **NDA** (art. 4, Sous-traitance et transfert étranger) — remplacer « (ex: Anthropic, USA) » par « (selon le moteur utilisé pour la mission : Anthropic, États-Unis ; un modèle ouvert exécuté sur l'infrastructure du Prestataire ou chez un hébergeur suisse ; ou le fournisseur choisi par le Client avec sa propre clé) », et ajouter que le moteur local tourne sur un ordinateur du Prestataire relié au serveur par un réseau privé chiffré (Tailscale).
4. **DPA** (`docs/DPA-TEMPLATE.md` annexe sous-traitants) et **`docs/SECURITY-OVERVIEW.md`** §4 : mêmes lignes que la page Sécurité (moteur local, hébergeur suisse avec son contrat à joindre, fournisseur de la clé du client) ; Anthropic « seulement quand le moteur Claude est utilisé ».
5. **Hébergeur suisse** : au moment de le choisir, obtenir son contrat de traitement (DPA) et l'ajouter à la ligne de la page Sécurité (nom de l'hébergeur, pays).

## 11. Tests, et ce que j'ai mesuré en réel

Tous sans réseau externe ni coût (faux serveur OpenAI-compatible de la bibliothèque standard, API d'Anthropic simulée), sauf l'essai manuel contre votre Ollama. PowerShell 7 : sous Windows, lancer les tests PowerShell dans WSL.

| Fichier | Contenu |
|---|---|
| `tests/providers/test_net_policy_fetch.py` | adresses permises / interdites, SSRF de la lecture web (redirections, DNS, taille, schémas) |
| `tests/providers/test_engine_common_ps.py` | mêmes vecteurs d'adresses côté PowerShell, appel d'outil écrit en texte (strict), fichiers texte, disjoncteur, registre de dépense |
| `tests/providers/test_router.py` | routeur : rien ne change sans choix, chaînes, essai verrouillé, clé personnelle, plafond, alertes, disjoncteur, matrice de capacités, réglages |
| `tests/providers/test_openai_adapter.py` | adaptateur : contrat, boucle d'outils natifs et en texte, **porte d'approbation (une écriture devient PENDING-ACTION, rien n'est exécuté)**, mémoire, fichiers, erreurs 402/401/429/délai, adresses interdites, **contenu externe = donnée**, prompt compact |
| `tests/providers/test_engine_chain.py` | exécuteur : repli ouvert, disjoncteur, plafond, essai gratuit, clé personnelle sans repli, étiquette du moteur, réponse de secours |
| `tests/providers/test_engine_ui.js` | interface (Node, sans page) : étiquette « Moteur : … » / « Réponse du moteur de remplacement : … », ligne près de la zone de mission, détail des limites, libellés hostiles échappés, ligne cachée si le serveur est en erreur |
| `tests/providers/test_chloe_routing.py` | le routage de Chloé n'appelle Claude que si le plan le permet |
| `tests/providers/test_check_engine.py` | `deploy/check-engine.py` |
| `tests/providers/e2e_server.py` | bout en bout : vrai serveur, vrais comptes, vraies missions (pipeline PowerShell complet) répondues par un faux moteur local |
| `tests/providers/real_ollama_check.py` | **manuel**, contre votre Ollama réel |

### Essai réel contre votre Ollama (gratuit)

Commande : `python tests/providers/real_ollama_check.py` (adaptateur réel, prompt Worker réel de Noah en version compacte, Ollama réel sur `127.0.0.1:11434`, racine jetable, niveau Rapide). Mesuré le 2026-10-26, PC du propriétaire, sans carte graphique, machine par ailleurs occupée.

| Modèle | Réponse simple | Appel d'outil (« enregistre « Bonjour le monde » dans note.txt ») |
|---|---|---|
| `qwen2.5:1.5b` | **marche** : « Bonjour, je suis Noah, assistant exécutif et administratif. » en 73 s (chargement à froid compris) | **ne marche pas** : les outils natifs sont proposés, le modèle n'en appelle aucun et **affirme** « TextEdit.txt a été enregistré avec succès » alors qu'aucun fichier n'existe. Le garde-fou ajoute alors à la réponse : « Attention : dans cette mission, le moteur n'a PAS enregistré un fichier (aucun outil ne l'a fait)… » |
| `llama3:latest` (8 B) | **marche** : « Bonjour, je suis Noah, Assistant Exécutif & Administratif, prêt à vous aider. » en **641 s** (chargement à froid de plus de 3 minutes, puis lecture d'environ 2 000 jetons à 6 jetons par seconde) | **marche** en mode « JSON dans le texte » (llama3 n'a pas d'appel natif) : un appel `write_text_file` valide, `note.txt` créé, en **660 s** (2 tours, 4 316 jetons lus) |

Ce que cela veut dire, sans détour :

- **La chaîne technique fonctionne de bout en bout avec votre vrai Ollama** (réponse, appel d'outil écrit en texte, fichier produit, garde-fou contre les actions affirmées sans effet).
- **Mais Llama 3 8 B sur ce PC est trop lent pour une mission interactive** : plus de 10 minutes par mission, alors que le serveur coupe une mission à 600 s (la plateforme s'arrête à 540 s). Je n'ai donc dû relever la limite que pour cette mesure. Tel quel, une mission d'essai envoyée à ce modèle sur ce PC se terminerait par « Aucun moteur d'IA n'a pu répondre » (gratuit, honnête). Pour des démonstrations qui répondent, il faut : une carte graphique, ou un PC plus puissant, ou un modèle plus petit (`qwen2.5:3b`, que je n'ai pas téléchargé), ou plus simplement **un hébergeur suisse** (§7).
- `qwen2.5:1.5b` est assez rapide (environ 50 jetons / seconde en lecture) pour une démonstration, mais **trop petit pour mériter la confiance** : il invente des actions. À réserver, si vous le gardez, à des démonstrations très courtes, sans connecteur.
- **Re-mesure avec la version finale du code** (2026-10-26, `qwen2.5:1.5b`, modèle déjà chargé) : réponse simple en 8 s ; l'appel d'outil n'est toujours pas fait par ce petit modèle, qui écrit cette fois « le texte … a été enregistré dans un fichier nommé « note.txt » ». Le garde-fou de la première version **ne reconnaissait pas cette tournure** (le texte comme sujet, « fichier » après le verbe) : je l'ai corrigé et ajouté cette phrase exacte aux tests ; la note « le moteur n'a PAS enregistré un fichier » apparaît maintenant sous la réponse. La mesure de `llama3:latest` ci-dessus date d'avant l'ajout de la recherche web facultative, qui ne change rien à son chemin tant que `BK_SEARCH_URL` est vide ; je ne l'ai pas refaite (plus de 10 minutes par essai).
- **Dernière re-mesure** (2026-10-26, version finale, `qwen2.5:1.5b`, trois essais d'appel d'outil) : le petit modèle n'a **jamais** appelé l'outil, et ses réponses varient d'un essai à l'autre : « le texte a été enregistré dans un fichier… » (repéré), « Ok, le texte a été enregistré avec succès » (**non repéré par la version précédente** : ni le mot « fichier » ni un nom de fichier ; le garde-fou le repère maintenant, phrase ajoutée aux tests), puis un refus (« je ne suis pas autorisé à produire de texte »). Conclusion inchangée : ne pas confier d'action à ce modèle.
- Le garde-fou « action affirmée sans effet » (`Get-BKUnbackedClaimNote`) est une heuristique de sécurité, pas une garantie : un modèle peut dire une fausseté d'une autre manière. La règle de fond reste : **rien d'extérieur ne part sans votre confirmation** (porte d'approbation), quel que soit le moteur.

## 12. Limites honnêtes

- Un modèle local n'a **pas** de recherche web (sauf point de recherche SearXNG que vous aurez installé et configuré : jamais simulée), d'exécution de code ni de fichiers Office, et ne tient pas un projet de plusieurs heures ; ses réponses sont plus simples et peuvent se tromper. L'interface et les réponses le disent.
- Le PC doit être allumé et relié au réseau privé : sinon l'essai répond « aucun moteur disponible » (gratuit, honnête).
- L'agent téléphonique n'est pas concerné par ce choix de moteur (il appelle Claude directement).
- `GET /api/engine` affiche le moteur **prévu** ; un repli de dernière minute n'apparaît que dans la réponse de la mission.
- La clé personnelle n'est pas testée à l'enregistrement : une clé fausse se voit à la première mission (elle échoue sans se rabattre sur la plateforme).
- L'enregistrement d'une clé passe par le coffre chiffré existant (un script PowerShell lancé par le serveur avec un délai de 20 secondes, comme pour les identifiants des outils). Sur une machine très lente ou à froid, ce délai peut être dépassé : le client voit « Enregistrement impossible pour le moment. Réessayez. » et le journal du serveur note « delai du coffre depasse » (jamais la valeur). Je n'ai pas mesuré ce délai sur le serveur de production ; sur le PC de développement sous WSL (machine lente et chargée), un démarrage à froid du coffre a mesuré de 11 à 146 secondes selon les essais (c'est pourquoi le test de bout en bout réchauffe le coffre avant la section « clé personnelle »).
- Le plafond de dépense est une estimation au tarif public, avec les limites du §9.
