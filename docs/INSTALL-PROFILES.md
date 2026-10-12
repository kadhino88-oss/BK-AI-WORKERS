# Profils d'installation des Workers

Objectif (décision du 2026-10-12) : vendre **chaque Worker à l'unité** et l'**installer chez le client selon ses compétences**.
Chaque Worker commercial a un fichier `workers/<id>/install-profile.json` qui décrit, de façon vérifiable par machine :

- ce que le Worker fait une fois installé (4 à 8 **services** concrets, tirés de son `identity/playbook.md`) ;
- ce que le client doit lui fournir (**champs de connaissance**) et connecter (**connecteurs**) ;
- ce que le Worker a le droit de faire seul (**règles d'autonomie**) ;
- par quels **canaux** il travaille, aujourd'hui et demain ;
- comment le client **l'essaie** sans rien envoyer (**scénario d'essai**) et les **étapes d'installation**.

Rien dans l'application ne lit encore ces fichiers (pas d'API ni d'écran) : ils sont la source de données du futur assistant d'installation (voir plus bas). Les prix ne font pas partie des profils.

## Format

```jsonc
{
  "schema": "BK-INSTALL-PROFILE-V1",
  "workerId": "alex",                  // = nom du dossier workers/<id>
  "displayName": "Alex",               // = nom de identity.json (accents ignorés)
  "tagline": "…", "idealFor": "…",     // 1 ligne / 1-2 lignes, pour la fiche de vente
  "services": [ { … } ],               // 4 à 8
  "channelSupport": { "email": "planned", "phone": "planned", "whatsapp": "planned", "web": "available", "schedule": "available" },
  "plannedCapabilities": ["…"],        // ce qui n'existe PAS encore : affiché « bientôt », jamais comme disponible
  "installationSteps": ["…"]           // 5 à 9 étapes courtes que suit un client non technique
}
```

Un **service** :

| Clé | Contenu |
|---|---|
| `id`, `label`, `description` | slug (`prospection-sortante`), titre, ce que le client reçoit |
| `skills` | ids de `workers/<id>/skills/contracts/*.json` (peut être vide si aucun ne correspond) |
| `requiredConnectors`, `optionalConnectors` | ids du catalogue (`hubspot.controlled`) ; tous les requis doivent être connectés |
| `requiredAnyOf` *(option)* | groupes d'alternatives : au moins un connecteur par groupe (`[["hubspot.controlled","pipedrive.controlled"]]`) |
| `connectorOperations` | par connecteur, les opérations **réelles** utilisées (`READ_DEAL`, `CREATE_TASK`…), lues dans `core/integrations/Connector-Dispatch.ps1` |
| `channels` | sous-ensemble de `email`, `phone`, `whatsapp`, `web`, `schedule` ; toujours `web` (lancé depuis l'application) |
| `suggestedFrequencyMinutes` *(si `schedule`)* | fréquence conseillée de la mission récurrente, ≥ 60 (devient `frequencyMinutes` de l'automatisation) |
| `knowledgeFields` | `{key, label, help, required, example}` : ce que le client renseigne (au moins un `required`) ; même `key` = même champ d'un service à l'autre |
| `autonomyRules` | voir ci-dessous |
| `testScenario` | `objective` (demande prête à lancer, précise qu'aucune action réelle n'est faite) + `expectedChecks` (≥ 2 vérifications) |
| `recommendedLevel` | `rapide`, `equilibre` ou `approfondi` (niveaux de mission : modèle et effort ; `core/ai/LEVELS.json` sur la branche `ws/memory-v2` tant qu'elle n'est pas fusionnée) |

Conventions : `id` de service et `category` en kebab-case ; `key` de champ en snake_case ; textes en français.

## Règles d'autonomie (la loi de la plateforme)

Chaque règle : `category`, `label`, `examples`, `risk` (`low|medium|high`), `defaultMode`, `maxAutoPerDay`, et `operations` (`"connecteur:OPERATION"`) quand elle gouverne une écriture dans un outil.

| `defaultMode` | Sens |
|---|---|
| `auto` | le Worker le fait seul ; **réservé à lire, analyser, rédiger et prendre des notes internes**. Plafond `maxAutoPerDay` obligatoire |
| `draft` | le Worker prépare et dépose un vrai brouillon (Gmail/Outlook, WordPress, note interne Zendesk/Intercom) ; rien ne part |
| `ask` | le Worker prépare l'action exacte ; elle ne s'exécute qu'après confirmation du client (une action en attente par mission) |
| `off` | le Worker n'y touche pas, sauf si le client l'active |

Ce que le validateur impose :

- jamais `auto` pour envoyer, publier, payer, supprimer, appeler, signer, ni pour un risque `medium`/`high` ;
- toute opération d'écriture d'un connecteur est gouvernée par une règle ; elle est en `ask` ou `off` (ou `draft` pour un vrai brouillon) ;
- attention aux noms trompeurs : `CREATE_DRAFT_POST` **publie** sur LinkedIn, Facebook, Instagram, TikTok et X ; `DRAFT_MESSAGE` **envoie** sur Teams et WhatsApp ; `slack:POST_MESSAGE` envoie ; `twilio:PLACE_CALL` appelle. Ces opérations ne sont jamais en `draft` ni en `auto` ;
- les opérations qui déplacent de l'argent (remboursement, virement, paiement) sont toujours `off`, risque `high` ; les connecteurs financiers ne sont de toute façon pas connectables par un client.

## Ce qui « existe » aujourd'hui (au 2026-10-12)

**Canaux** (`channelSupport`) :

| Canal | Valeur | Pourquoi |
|---|---|---|
| `web` | `available` | missions lancées depuis l'application |
| `schedule` | `available` | automatisations = missions récurrentes (`core/automation`) |
| `email` | `planned` ou `no` | pas de traitement automatique d'une boîte de réception ; seulement lecture, recherche et brouillon via Gmail/Outlook (Gmail ne renvoie que des identifiants de messages) |
| `phone` | `planned` ou `no` | l'agent téléphonique (`dashboard/phone_agent.py`, `docs/PHONE-AGENT.md`) ne sert que le compte propriétaire |
| `whatsapp` | `planned` ou `no` | pas de numéro WhatsApp propre à un client. Le lien « Lier mon WhatsApp » (`dashboard/whatsapp_channel.py`) permet de parler à Chloé, pas de faire répondre un Worker à ses clients |

`no` = le canal n'a pas de sens pour ce Worker. Le validateur refuse `available` pour `email`, `phone` et `whatsapp` : à relâcher dans `CHANNEL_MAX_SUPPORT` le jour où un canal existe vraiment.

**Connecteurs** : seuls les connecteurs du catalogue qui ont un vrai adaptateur **et** que le client peut connecter lui-même sont utilisables dans un profil. Sont exclus et décrits dans `plannedCapabilities` : les catégories génériques (`crm`, `social_media`, `design`, `web_analytics`, `canva`), Salesforce et Google Ads (application OAuth fournisseur à enregistrer), Stripe, PayPal, QuickBooks et Xero (financiers, non connectables par un client). Autres limites assumées : pas de dépôt de fichier dans la conversation, pas de connecteur GA4.

## Comment l'assistant d'installation s'en servira (à construire)

1. **Fiche de vente** : `tagline`, `idealFor` et la liste des `services` alimentent la page du Worker ; les `plannedCapabilities` et les canaux `planned` s'affichent « bientôt ».
2. **Recrutement du Worker** : le formulaire de connaissance regroupe les `knowledgeFields` de tous les services activés (dédoublés par `key`, obligatoires d'abord) et les enregistre dans la mémoire du client.
3. **Connexion des outils** : pour chaque service, requis, groupes `requiredAnyOf` et optionnels deviennent des boutons vers la page Connecteurs (guide de connexion `core/integrations/connect-guides.json` ou OAuth). Un service est « prêt » quand tous ses requis sont connectés ; sinon l'assistant dit lesquels manquent.
4. **Autonomie** : les `autonomyRules` pré-remplissent l'écran de réglages (mode par défaut, plafond quotidien). Le bouton existant « Laisser mes Workers agir seuls » ne couvre que les vrais brouillons.
5. **Essai** : `testScenario.objective` est lancé comme mission au `recommendedLevel` ; `expectedChecks` s'affichent en liste à cocher pour que le client juge le résultat.
6. **Récurrence** : un service avec le canal `schedule` propose de créer l'automatisation (Worker + objectif + `suggestedFrequencyMinutes`).
7. **Parcours** : `installationSteps` forme la check-list de l'installation.

## Validation

```
python tests/install-profiles/validate_profiles.py          # 17 profils : code de sortie 0 si tout est valide
python tests/install-profiles/validate_profiles.py --only alex,nora
python tests/install-profiles/test_validator.py             # 36 tests : chaque règle doit refuser un profil fautif
```

Le validateur vérifie : les 17 fichiers existent et sont du JSON UTF-8 sans BOM ; clés obligatoires et inconnues ; ids en slug et uniques par Worker ; compétences présentes dans `skills/contracts` ; connecteurs présents dans le catalogue (ou les guides de connexion), réels et connectables ; opérations présentes dans `Connector-Dispatch.ps1` ; règles `risk`/`defaultMode` ci-dessus ; scénario d'essai et champ obligatoire par service ; canaux cohérents avec la réalité ; aucun mot interdit (noms propres du propriétaire et de ses autres projets).

Les profils décrivent ce que les playbooks et les connecteurs permettent le 2026-10-12. Le validateur garantit la cohérence structurelle, pas la qualité des réponses : celle-ci se mesure avec le benchmark de missions.

## Maintenance

- Un Worker gagne un connecteur ou une opération : mettre à jour son profil (`connectorOperations`, règles d'autonomie) et retirer la ligne correspondante de `plannedCapabilities`.
- Un canal devient réel : changer `CHANNEL_MAX_SUPPORT` dans le validateur, puis les `channelSupport` concernés.
- Un connecteur devient connectable par un client : le retirer de `NOT_CLIENT_CONNECTABLE` dans le validateur.
- Un playbook change : relire les services du Worker concerné (le profil ne doit pas promettre ce que le playbook interdit).
