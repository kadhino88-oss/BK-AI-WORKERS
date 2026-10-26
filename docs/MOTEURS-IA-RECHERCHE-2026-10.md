# Moteurs IA : ce qui existe vraiment, ce que ça coûte, ce que je recommande (2026-10-26)

Question du propriétaire : « je ne veux pas dépendre de quelque chose de payant ; trouve de vraies solutions ». Ce document sépare ce que j'ai **mesuré**, ce qui est **relevé sur une page officielle**, ce qui vient d'un **agrégateur tiers** (à revérifier) et ce que je n'ai **pas pu vérifier**. Aucune de ces valeurs n'est inventée ; les calculs sont refaits à la main en bas de page.

## 1. Verdict en cinq lignes

1. **Le PC du propriétaire ne peut pas porter les Workers.** Mesuré (docs/PROVIDERS.md §6, branche `ws/providers-v1`) : Llama 3 8B = 6 jetons/s en lecture, **641 à 660 s par mission** (limite plateforme : 540 s) ; Qwen 2.5 1,5B répond vite mais **invente des actions** (il affirme avoir enregistré un fichier sans l'avoir fait). Matériel : i5-6300U, 7,9 Go de RAM, aucune carte graphique. Acheter du matériel n'est pas la solution : un serveur à GPU capable de modèles de 70 B+ coûte bien plus par mois que les mêmes jetons chez un hébergeur.
2. **Passer à un modèle ouvert hébergé n'est pas « gratuit » ni forcément moins cher que Claude.** Les petits modèles (gpt-oss, Qwen 35B-A3B) coûtent comme Claude Haiku 5.5 ; les gros modèles ouverts (GLM, Mistral Medium, Qwen 397B) coûtent comme Claude Sonnet 5.5 ou moins, mais pas 10 fois moins (tableau §3).
3. **Le crédit Anthropic ne s'est pas vidé parce que Claude est cher** : il s'est vidé sur des missions de test du propriétaire, sans plafond. À prix de Haiku 5.5, 20 USD couvrent environ **1 000 missions « Rapide »** (calcul §3). La vraie protection est un **plafond** (construit dans `ws/providers-v1`), pas un changement de modèle.
4. **L'indépendance réelle = ne pas dépendre d'un seul fournisseur** : un routeur qui bascule, ouvertement, de Claude vers un hébergeur européen/suisse compatible OpenAI (c'est le travail de `ws/providers-v1`, déjà écrit : changer d'hébergeur = changer une adresse et une clé).
5. **Les plus gros leviers de coût et de qualité ne sont pas le choix du modèle** mais : moins de jetons par mission (modèles de pages, explorateurs et registres qui font le travail déterministe, cache de prompt, traitement par lots à -50 % pour les projets non interactifs), et un banc d'essai qui mesure, tâche par tâche, quel modèle suffit (§5).

## 2. Hébergeurs européens / suisses compatibles OpenAI

| Hébergeur | Ce qui est établi | Modèles avec appel d'outils et prix (par million de jetons) | Réserves |
|---|---|---|---|
| **Scaleway** (Paris) | Page de prix officielle lue le 2026-10-26 : 1 000 000 de jetons gratuits (une fois), traitement par lots à -50 %, API compatible OpenAI ([prix](https://www.scaleway.com/en/pricing/model-as-a-service/), [présentation](https://www.scaleway.com/generative-apis/)) | gpt-oss-120b 0,15 / 0,60 € ; Qwen 3.6 35B-A3B 0,25 / 1,50 € ; Gemma 4 26B 0,25 / 0,50 € ; DeepSeek V4 Flash 0,40 / 0,80 € ; Qwen 3.5 397B 0,60 / 3,60 € ; Mistral Medium 3.5 1,50 / 7,50 € ; GLM 5.2 1,80 / 5,50 € | Appel d'outils : annoncé par un annuaire tiers, pas lu sur la page officielle. Politique de données (conservation, entraînement) : **non lue** (page trop longue pour mon outil) |
| **OVHcloud AI Endpoints** (France) | Catalogue officiel lu le 2026-10-26, colonne « tool calling : oui » ([catalogue](https://www.ovhcloud.com/en/public-cloud/ai-endpoints/catalog/)) | gpt-oss-20b 0,04 / 0,15 € ; gpt-oss-120b 0,08 / 0,40 € ; Qwen 3.5 9B 0,10 / 0,15 € ; Qwen 3.5 397B 0,60 / 3,60 € ; Llama 3.3 70B 0,67 / 0,67 € | Mistral Small 3.2 et Mistral Nemo **retirés le 2026-11-04** (ne pas les choisir). Lieu des données et non-entraînement : **non lus** |
| **Infomaniak AI Tools** (Genève) | Présenté comme API compatible OpenAI, aucune requête conservée, traitement de bout en bout en Suisse, 1 000 000 de crédits gratuits pour un mois d'essai, carte bancaire requise ([guide](https://www.infomaniak.com/fr/support/faq/2845/guide-de-demarrage-ai-tools-services-ia-souverains), [prix](https://www.infomaniak.com/en/hosting/ai-tools/prices)) | Agrégateur tiers (à revérifier dans la console) : Apertus 70B 0,87 / 3,10 $ ; Mistral Small 4 0,25 / 0,93 $ ; Ministral 3 14B 0,37 / 0,50 $, tous avec outils ([modelcompare](https://modelcompare.dev/providers/infomaniak)) | La page de prix officielle n'a pas pu être lue (contenu tronqué) ; l'ancienne grille affiche des modèles anciens, et les chiffres de l'agrégateur ne concordent pas avec elle. **Pas d'engagement écrit « jamais d'entraînement » trouvé** (la non-conservation n'équivaut pas à cela) |
| **Mistral La Plateforme** (offre gratuite « Experiment ») | L'aide officielle prévient que les requêtes de l'offre gratuite **peuvent servir à entraîner ses modèles** ([aide](https://help.mistral.ai/en/articles/450104-how-can-i-try-the-api-for-free-with-the-experiment-plan)) | — | **Interdit pour des données de clients.** À la rigueur pour des essais sans donnée réelle |

Argument commercial réel pour la Suisse : Infomaniak est le seul des trois qui traite en Suisse (nLPD), ce qui compte pour les clients genevois du propriétaire. Argument technique : Scaleway et OVH ont des prix vérifiés et un catalogue plus large. Les deux se branchent de la même façon.

## 3. Coût d'une mission type (calcul, pas mesure)

Hypothèse unique, volontairement pessimiste et sans cache : **150 000 jetons lus et 8 000 écrits** (boucle de 12 étapes, contexte qui grossit). Prix Claude lus dans `core/ai/AI-PRICING.json` (Haiku 5.5 0,10/0,50 $, Sonnet 5.5 2/10 $, Opus 5.5 4/20 $ le million) ; change 1 USD = 0,83107 CHF.

| Moteur | Coût d'une mission type |
|---|---|
| gpt-oss-20b (OVH) | 0,007 € |
| gpt-oss-120b (OVH) | 0,015 € |
| **Claude Haiku 5.5** | **0,019 $ (0,016 CHF)** |
| gpt-oss-120b (Scaleway) | 0,027 € |
| Qwen 3.6 35B-A3B (Scaleway) | 0,050 € |
| DeepSeek V4 Flash (Scaleway) | 0,066 € |
| Qwen 3.5 397B | 0,119 € |
| Mistral Medium 3.5 (Scaleway) | 0,285 € |
| GLM 5.2 (Scaleway) | 0,314 € |
| **Claude Sonnet 5.5** (sans cache) | **0,38 $ (0,32 CHF)** |
| Claude Opus 5.5 (sans cache) | 0,76 $ (0,63 CHF) |

Lecture :
- Un modèle ouvert hébergé de **même classe que Sonnet** (GLM 5.2, Mistral Medium) coûte **autant** que Sonnet. Il n'y a pas de repas gratuit.
- Les **petits** modèles ouverts coûtent **autant que Haiku** : ils n'apportent pas d'économie, seulement un second fournisseur.
- Les lectures de cache de Claude (Sonnet 5.5 : 0,10 $ le million, soit 5 % de l'entrée) abaissent beaucoup le coût réel d'une boucle d'outils ; non mesuré ici.
- 20 USD ÷ 0,019 $ = environ 1 050 missions Rapide sur Haiku 5.5.

## 4. Qualité : ce que l'on sait et ne sait pas

- Les comparatifs publics sont des **agrégateurs** (aucune source primaire lue). Directionnel seulement : Claude Sonnet 4.6 à 87,5 contre Qwen3-Max à 76,8 sur τ-bench ; un autre agrégateur donne 89 contre 68 pour gpt-oss-120b. Les classements de modèles ouverts « de code agentique » (Qwen3-Coder, GLM 5, DeepSeek V3.2/V4, Kimi K2/K3, MiniMax M2.5) citent des chiffres SWE-bench de 65 à 76 %, souvent fournis par les éditeurs avec leur propre échafaudage : à ne pas prendre pour acquis.
- Conclusion honnête : **rien ne permet d'écrire « meilleur que Claude »** pour un moteur ouvert. Claude reste le moteur des clients payants (niveaux Équilibré et Approfondi) ; un modèle ouvert hébergé sert d'**essai, de repli et de clé personnelle**, étiqueté comme tel.

## 5. Ce qui réduit vraiment la dépendance (travail à faire)

1. **Plafond de dépense + chaîne de moteurs** (`ws/providers-v1`, en cours de relecture) : comptes du propriétaire et de test sur Haiku avec plafond, ou sur un moteur ouvert hébergé ; essai gratuit verrouillé sur la chaîne gratuite ; repli ouvert, jamais silencieux.
2. **Banc d'essai par Worker** (déjà prévu dans `docs/AUTONOMY-ENGINE.md`, partie recettes) : 10 tâches réelles par Worker, jouées sur Haiku / gpt-oss-120b / Qwen 35B / Sonnet, résultat noté par le vérificateur indépendant, coût mesuré. C'est lui qui dira quel Worker peut tourner sur un moteur moins cher, au lieu de le deviner.
3. **Faire faire le déterministe au code, pas au modèle** : modèles de pages pour le site (le modèle écrit le texte, pas 30 000 jetons de HTML), explorateur pour l'audit SEO (le code mesure, le modèle interprète), registres publics pour les prospects, connecteurs déjà construits pour publier. À chiffrer par recette.
4. **Recherche web sans service Anthropic** : l'outil `web_search` d'Anthropic coûte 10 $ les 1 000 recherches ([AI-PRICING.json](../core/ai/AI-PRICING.json)). Alternatives relevées : Brave Search API n'a plus d'offre gratuite stable pour les nouveaux comptes (environ 5 $ les 1 000, sources secondaires de juin-août 2026, à confirmer) ; l'API Google Custom Search est fermée aux nouveaux clients et arrêtée au 2027-01-01 ([sources](https://agentdeals.dev/vendor/brave-search-api)) ; un SearXNG auto-hébergé reste une option du propriétaire (point de recherche facultatif déjà prévu dans `ws/providers-v1`), **sans que j'aie pu vérifier** s'il est bloqué par les moteurs depuis un VPS : à tester avant de promettre.
5. **Registre du commerce suisse (Zefix)** : une API publique existe et un connecteur communautaire l'utilise avec identifiant et mot de passe ([validitylabs/zefix](https://github.com/validitylabs/zefix)) ; **je n'ai pas pu vérifier** les conditions d'accès ni la gratuité : à confirmer avant de bâtir la recette « prospects ».
6. **Aides financières à demander** (sources secondaires, montants non confirmés) : programme startup d'OVHcloud (jusqu'à 100 000 € selon un comparatif), Scaleway (jusqu'à 36 000 €, entreprises européennes), Anthropic for Startups (montant non publié, par candidature) ([comparatif](https://betterstack.com/community/comparisons/scaleway-vs-ovhcloud-startups/), [Anthropic](https://guptadeepak.com/anthropic-claude-for-startups-the-complete-guide-to-credits-tiers-and-eligibility-2026/)). Conditions d'éligibilité (société constituée, etc.) à vérifier sur les sites officiels.

## 6. Ce que seul le propriétaire peut faire (par ordre d'utilité)

1. Fixer sur la console Anthropic une limite mensuelle (par exemple 20 USD) avec rechargement automatique désactivé ; ce plafond protège avant tout le reste.
2. Choisir **un hébergeur** (recommandation : Infomaniak si son contrat écrit exclut l'entraînement et si ses prix actuels te conviennent, sinon Scaleway pour ses prix vérifiés), ouvrir un compte d'essai (jetons gratuits), créer une clé d'API. La clé se saisit dans le formulaire d'administration : je ne la manipule jamais.
3. Lire la politique de données de l'hébergeur retenu avant d'y envoyer des données de clients.
4. Demander les programmes startup (point 6 du §5), sans engagement.

## 7. Limites de ce document

- Pages Infomaniak, politiques de données de Scaleway et d'OVH : non lues faute de contenu exploitable par mon outil ; j'ai écrit « non lu » plutôt que de supposer.
- Qualité des modèles : seulement des agrégateurs tiers.
- Tous les prix sont ceux du 2026-10-26 et changent ; relire la console avant de s'engager.
- Les coûts du §3 sont un calcul à hypothèse fixe, pas une mesure de production (le suivi réel est dans `docs/COST-LEDGER.md` quand il existe).
