# Étude de marché et de prix — BK-AI-WORKERS

**Date : 12 octobre 2026** · Pour : Kader (décision sur les prix) · Branche `ws/market-study`
Données complètes : `docs/pricing-study-data.json` · Calculs reproductibles : `docs/pricing-cost-model.py`

> Règle de cette étude : **aucun chiffre inventé**. Chaque prix d'un concurrent a son adresse (URL) et la date de consultation (tout a été lu le **12.10.2026**). Quand un chiffre n'a pas pu être vérifié, il est marqué **« non vérifié »** ou **« sur devis »**. Les chiffres que je calcule moi-même sont des **hypothèses de calcul** (pas des mesures) : je montre le détail pour que vous puissiez les contester.

---

# RÉSUMÉ POUR DÉCIDER (1 page)

**Votre question :** valider l'échelle des crédits et fixer le prix d'un Worker vendu seul, après avoir passé la concurrence au peigne fin.

**Ce que j'ai trouvé**

1. **Delos** (Paris) vend **un Worker à 50 € / mois** (= CHF 46.56), avec 40 000 crédits, joignable par Slack, Teams, e-mail et téléphone, essai gratuit, sans engagement. **Pas de WhatsApp.** C'est le seul acteur qui publie clairement le « Worker à l'unité » pour les PME.
2. **Limova** vend un **paquet de 8 agents** pour 5 utilisateurs : **79,90 € / mois HT** (= CHF 74.41). Le téléphone et le chatbot WhatsApp ne sont débloqués que par le plan **Pro à 139,90 € / mois** (= CHF 130.29) **+ 0,20 € par minute d'appel** (= CHF 0.186). Limova ne vend jamais un agent seul.
3. Les petits paquets américains (**Sintra**, **Marblism**) sont **beaucoup moins chers** (CHF 13 à 43 par mois pour 7 à 12 assistants), mais sans WhatsApp, avec un téléphone limité aux numéros US/Canada/UK, et sans présence suisse/française. Ils ne sont pas vos concurrents directs, mais ils tirent le prix perçu vers le bas : **ne jamais dire « le moins cher du marché »**.
4. **Coût IA d'une mission** (estimation, détail section 2) : Rapide **CHF 0.002 à 0.035** (typique 0.0125) · Équilibré **0.034 à 0.227** (typique 0.090) · Approfondi **0.067 à 0.429** (typique 0.171).
5. **L'échelle actuelle (1 / 3 / 8 crédits ; plans 150 / 600 / 1 500 / 4 000) ne passe pas votre règle des 35 %** : au pire cas, l'IA coûterait **46 %** du prix du plan Business, **82 %** du Pro, **67 %** du Scale (seul Starter passe, 29 %). Raison : une mission Équilibré coûte environ 6 fois une mission Rapide mais ne se facture que 3 fois.

**Ma recommandation** (prix en CHF, sans TVA comme aujourd'hui, annuel = 10 mois)

| Offre | Prix / mois | Annuel | Crédits | Coût IA pire cas | Face à la concurrence directe |
|---|---|---|---|---|---|
| **Worker Solo** (1 Worker au choix) | **29** | 290 | 250 | 32.6 % | **38 % moins cher que Delos** (46.56) |
| **Trio** (3 Workers) | **59** | 590 | 500 | 32.0 % | 21 % moins cher que Limova Essentiel (74.41) |
| **Équipe** (17 Workers + Chloé) | **99** | 990 | 900 | 34.4 % | 24 % moins cher que Limova Pro (130.29) |
| Pro | 139 | 1 390 | 1 250 | 34.0 % | 7 % **plus cher** que Limova Pro (130.29) |
| Scale | 449 | 4 490 | 4 000 | 33.7 % | pas de comparable direct |
| **Pack de crédits** | CHF 12 les 100 / CHF 55 les 500 | — | — | 31.5 % / 34.4 % | à peine plus cher que le crédit d'un plan |

**Nouvelle échelle de crédits : Rapide 1 · Équilibré 6 · Approfondi 12.** Téléphone : 1,5 crédit par minute d'appel (≈ CHF 0.17/min, contre 0.186 chez Limova).

**Où nous sommes plus chers (à dire franchement) :** Équipe à 99 est **33 % plus cher** que Limova Essentiel (mais celui-ci n'a ni agent téléphone ni chatbot WhatsApp), et **129 % à 171 % plus cher** que Sintra/Marblism (7 à 12 assistants génériques). Pro à 139 est 7 % plus cher que Limova Pro.

**Trois alertes**

- **La phrase du site « au moins 5 % moins cher que les alternatives comparables » (`dashboard/index.html` ligne 464) n'est pas étayée** : elle est fausse face à Limova Essentiel, Sintra, Marblism et Dust. À retirer ou remplacer (phrase défendable en section 4.3).
- **Ne pas vendre « Worker qui répond au téléphone et sur WhatsApp pour vos clients » avant que ce soit réellement en production** : d'après les notes du projet, le compte Twilio était encore en essai, sans numéro acheté (état du 06.10.2026, à re-vérifier), et l'installation par client (numéro, WhatsApp Business) n'existe pas encore (état du 12.10.2026).
- **La recharge de crédits n'est reliée à aucun paiement** (réservée à vous). Sans cela, le pack de crédits ne peut pas se vendre.

**Décisions à prendre :** voir le tableau d'une page en section 4.5.

---

# 1. Les concurrents

Toutes les pages ci-dessous ont été consultées le **12.10.2026**. Conversion en CHF avec le cours BCE du 09.10.2026 (dernier publié) : **1 € = 0,9313 CHF** et **1 US$ = 0,83107 CHF** (source : `https://api.frankfurter.dev/v1/latest`, données BCE). « HT » = hors taxes.

## 1.1 Les deux concurrents directs que vous avez nommés

### Delos — https://delos.so (pages `/fr/pricing` et `/fr`, consultées le 12.10.2026) — statut : **vérifié** (avec incohérences à connaître)

- **Qui :** société parisienne (adresse sur la page : 41-43 rue Saint-Dominique, 75007 Paris). 15 « Workers » spécialisés (SEO, satisfaction client, design, commercial…), chacun avec « son propre e-mail, téléphone » ; ils travaillent dans **Slack, Teams, e-mail et téléphone** et se branchent à 3 000+ outils. **WhatsApp : non mentionné.**
- **Cible :** équipes de 1 à 50 personnes (plan *Team*) ; grandes entreprises (*Enterprise*, sur devis).
- **Comment ils facturent :** **par Worker et par mois, en crédits**.
  - **Team : 50 € / mois (= CHF 46.56) pour un Worker spécialisé, 40 000 crédits**, mémoire longue, validation humaine, essai gratuit **sans carte**, **sans engagement** (« annuler à tout moment »).
  - Enterprise : sur mesure (Workers illimités, SLA, déploiement chez le client).
  - Suite bureautique IA (autre produit) : Étudiant 10 € ; Explore 25 € (23 € en annuel) ; Advanced 45 € (41 €) ; Premium 80 € (73 €) ; 10 000 à 50 000 crédits. Remise annuelle d'environ 8-9 %.
- **Limites :** le nombre de missions que représentent « 40 000 crédits » n'est pas publié → **on ne peut pas comparer les volumes**. Pas de prix annuel affiché pour *Team*. Prix pour 2 ou 3 Workers : non affiché (je n'ai **pas** le droit de supposer ×2 ou ×3).
- **Incohérences relevées (pour prudence) :** la balise technique de la page anglaise parle de « $30 per Worker » ; le code du site contient aussi d'autres grilles non affichées (ex. « Business 490 US$ », « Worker Pack 2 500 € »). Seule la **page rendue** (50 €) est retenue ; **les autres valeurs ne sont pas vérifiées et ne doivent jamais être citées**. Delos a une page « Workers vs Limova » : c'est bien le concurrent qu'il se donne.

### Limova — https://www.limova.ai/offres (aussi `limova.ai/en/pricing`, consultées le 12.10.2026) — statut : **vérifié** (prix lus à l'écran car affichés par animation)

- **Qui :** Limova.ai (éditeur indiqué « KAINOTOM.IA » sur Capterra : https://www.capterra.co.uk/software/1075207/Limova-ai ; téléphone français). 8 agents nommés : **Charly** (assistant général), **John** (réseaux sociaux), **Lou** (SEO), **Elio** (prospection LinkedIn/téléphone), **Manue** (comptabilité), **Julia** (juridique), **Tom** (téléphone/SAV), un agent recrutement.
- **Cible :** entrepreneurs, freelances, TPE/PME francophones.
- **Comment ils facturent :** **un abonnement qui donne accès à tous les agents, « pour 5 utilisateurs »** (prix **HT**), plus **0,20 € par minute d'appel** pour le téléphone.

| Plan | Mensuel | Annuel | Contenu |
|---|---|---|---|
| **Essentiel** | **79,90 € HT** (= CHF 74.41) | 949,90 € HT (= CHF 884.64 ; soit 79,16 €/mois, **−0,9 %** seulement) | 8 agents, marketing, SEO, prospection LinkedIn, documents, API ; **pas de téléphone** |
| **Pro** | **139,90 € HT** (= CHF 130.29) | 1 649,90 € HT (= CHF 1 536.55 ; −1,7 %) | tout Essentiel + agent téléphone Tom **0,20 €/min** (= CHF 0.186), jusqu'à 10 000 appels simultanés, 140 langues, **chatbot WhatsApp + site web** |
| Business+ | sur demande | — | tout Pro + onboarding individualisé, support premium |

- **Essai :** « 7 jours gratuits » (Essentiel et Pro). **Engagement minimum :** non indiqué. **Plafonds d'usage (crédits, messages) : aucun publié.** Onboarding sur mesure **inclus** dans chaque pack.
- **Promotion :** bandeau « Offre LEGEND » : **−10 % en mensuel (code LEGEND10)**, **−25 % en annuel (code LEGEND25)**. Je ne peux pas savoir si le code s'applique aux prix affichés. **Si oui** : Essentiel 71,91 €/mois (CHF 66.97) ou 712,43 €/an (CHF 663.48) ; Pro 125,91 €/mois (CHF 117.26) ou 1 237,43 €/an (CHF 1 152.41) — calculs de ma part, **non vérifiés**. Je compare donc aussi contre ces prix « avec code » pour rester prudent.
- **Canaux :** e-mail (Gmail, Outlook), **WhatsApp** (chatbot du plan Pro), **téléphone** (Tom, plan Pro), Google Agenda, HubSpot, Notion, Slack, Stripe, LinkedIn.
- Limova affiche « 4,9/5 avec +1000 avis » : **déclaration non vérifiée, jamais à reprendre**.

## 1.2 Les autres acteurs (16)

| Acteur / URL (12.10.2026) | Ce qu'il vend | Prix publié (devise exacte) | ≈ CHF | Inclus / limites | Statut |
|---|---|---|---|---|---|
| **Sintra** https://sintra.ai/pricing | 12 « helpers » IA en un seul plan (Sintra X) | 1 mois **48,50 US$** (barré 97) ; 3 mois **23,60 US$/mois** (barré 59) ; 12 mois **15,60 US$/mois** (barré 52). Helper seul **39 US$/mois** affiché | 40.31 ; 19.61 ; 12.96 ; 32.41 | 250 crédits/mois ; 15+ intégrations ; garantie 14 jours ; **WhatsApp/téléphone non mentionnés**. Un article tiers (https://www.eesel.ai/blog/sintra-ai-pricing, non vérifié) dit que les helpers individuels ne sont plus vendus | vérifié ; plans individuels contestés |
| **Marblism** https://www.marblism.com/pricing | 7 « employés IA » (assistante, réseaux sociaux, leads, site, SEO, réceptionniste, juridique) | **44 US$/mois** (mensuel, déduit) ; **24 US$/mois** en annuel | 36.57 ; 19.95 | 50 h de travail IA/mois ; téléphone : numéros US/Canada/UK ; garantie 77 j **et** 7 j (contradiction) | vérifié |
| **Lindy** https://www.lindy.ai/pricing | Plateforme d'agents, crédits mutualisés | Free **0 US$** (50 US$ de crédits, 7 jours) ; Team **49,99 US$/mois** pour 5 000 crédits ; 99,99 US$ pour 15 000 ; 199,99 US$ pour 35 000 | 41.55 | Recharge **10 US$ / 1 000 crédits** ; une demande courante = 2 à 250 crédits, travail approfondi 250 à 1 000 ; canaux non précisés sur la page | vérifié |
| **Dust** https://dust.tt/pricing | Plateforme d'agents pour équipes | Pro **24 €/siège/mois** (annuel) ou 30 € ; Max 120 € ou 150 € ; Free 0 € (500 crédits à vie) | 22.35 / 27.94 ; 111.76 / 139.69 | 8 000 / 40 000 crédits par siège ; −20 % annuel ; pas de canaux téléphone/WhatsApp | vérifié |
| **Phonely** https://www.phonely.ai/pricing | **Agent téléphonique seul** | Starter **50 US$/mois** (33 US$ en annuel) ; Pro **150 US$** (100 en annuel) | 41.55 ; 124.66 | 200-250 min (Starter), 650-750 min (Pro) ; dépassement 0,25 à 0,35 US$/min ; chiffres internes contradictoires | vérifié |
| **Zapier (Zaps + Agents)** https://zapier.com/pricing | Automatisations + Agents | Pro 750 tâches **19,99 US$/mois** (annuel) ou 29,99 ; Team 2 000 tâches 69 US$ (annuel) | 16.61 ; 57.34 | Agents facturés en « activités » : 400 (Free), 1 500 (Pro) ; prix des Agents peu clair | partiel |
| **Beam AI** https://beam.ai/pricing | Agents pour processus, par tâches | Free 0 ; Pro **50 US$/mois** (200 tâches) ; Scale **3 990 US$/mois** | 41.55 ; 3 315.97 | pas de crédits ; Custom sur devis | vérifié |
| **AiSDR** https://www.aisdr.com/pricing | SDR IA (e-mail + LinkedIn) | Solo **250 US$/mois** ; Explore 900 ; Scale 2 500 (−20 % annuel) | 207.77 ; 747.96 ; 2 077.67 | 200 / 800 / 2 500 contacts par mois ; Solo sans engagement | vérifié |
| **11x** https://11x.ai/products/alice/pricing | Alice, SDR numérique (1 agent) | Growth **3 750 US$/mois**, engagement **annuel** ; Pro/Enterprise sur devis | 3 116.51 | 5 utilisateurs, 2 000 prospects/mois ; la FAQ de la même page dit « 36 000 US$ par an » (= 3 000/mois) : contradiction | vérifié ; chiffre contradictoire |
| **Salesforce Agentforce** https://www.salesforce.com/agentforce/pricing/ | Agents dans le CRM Salesforce | **2 US$ par conversation** ; Flex Credits **500 US$ / 100 000** (action = 0,10 US$, action voix 0,15) ; add-on 125 US$/utilisateur/mois | 1.66 / conv. ; 0.083 / action | réservé aux clients Salesforce | vérifié |
| **Microsoft Copilot Studio** https://www.microsoft.com/en-us/microsoft-copilot/microsoft-copilot-studio | Constructeur d'agents Microsoft | Pack 25 000 crédits **200 US$/mois** ; paiement à l'usage (tarif non publié) | 166.21 | abonnement Azure obligatoire | vérifié ; tarif à l'usage non publié |
| **Swisscom — Swiss AI Assistant** https://www.swisscom.ch/fr/business/pme/it-cloud/new-way-of-working/swiss-ai-assistant.html | Chatbot d'équipe hébergé en Suisse (pas un agent téléphone/WhatsApp) | Essential **149 CHF** (10 utilisateurs) ; Professional **399 CHF** (40) ; Premium **799 CHF** (100) HT/mois | 149 ; 399 ; 799 | 20 M / 75 M / 200 M jetons ; essai 1 mois ; préavis 30 jours | vérifié |
| **Safe Swiss Cloud — PAI Chat** https://safeswisscloud.com/en/private-ai/private-ai-pricing/ | Chatbot IA hébergé en Suisse | **35 CHF/utilisateur/mois** (30 en annuel) ; API minimum 95 CHF/mois | 35 ; 30 | 250 requêtes/jour/utilisateur | vérifié |
| **Artisan (Ava)** https://www.artisan.co/pricing | AI BDR (prospection) | **Aucun prix publié** : « Talk to sales » (~2 500 ou ~6 000 leads/mois) | — | dialer en option par licence | **sur devis** |
| **Relevance AI** https://relevanceai.com/pricing | Plateforme « AI workforce » | **Aucun prix publié** (seul « Enterprise » affiché) | — | agents d'appel et de réunion | **sur devis** |
| **Cassidy** https://www.cassidyai.com/pricing | Agents et workflows pour équipes | Starter **0** (3 sièges, 10 000 crédits IA/mois) ; Business **sur devis** | — | essai 14 jours (FAQ) | partiel |

**Pistes trouvées mais NON vérifiées** (blogs ou résumés de recherche, pas les pages officielles ; à ne pas citer) : chatbot suisse aiaibot « dès 49 CHF/mois » ; agents vocaux CloudTalk « dès 99 €/mois avec 200 min », JustCall 149 €, Rosie AI 49 €, Smith.ai 300 € (source : blog d'un éditeur concurrent, https://www.cloudtalk.io/fr/blog/combien-coute-un-service-de-secretariat-telephonique-ia/) ; fourchette « standard téléphonique IA 50 à 200 €/mois » et « intégration sur mesure 6 000 à 15 000 € HT » (blogs cloudtalk.io et kolonell.com). **Je n'ai trouvé aucun acteur suisse vendant un « employé IA » avec prix publié en CHF** : Swisscom et Safe Swiss Cloud sont des chatbots d'équipe.

## 1.3 Comment le marché vend « un agent seul » ou « un paquet »

- **Par agent seul :** **Delos** (50 €/mois par Worker, en crédits), **11x** (Alice 3 750 US$/mois, annuel), **Artisan** (sur devis, au volume de leads), **Sintra** (helper à 39 US$ affiché, statut incertain), **Phonely** (agent téléphone seul, 50 US$/mois). Pour les PME, **seul Delos publie clairement le « Worker à l'unité »**.
- **Par paquet :** **Limova** (8 agents, 79,90 €), **Sintra X** (12 helpers), **Marblism** (7 employés). Ce sont les offres les moins chères *par agent*, mais ce sont des assistants génériques ; aucun plafond de volume clair chez Limova.
- **Par crédits ou usage :** Lindy, Dust, Delos, Copilot Studio, Agentforce, Zapier, Beam. Tous parlent de « crédits » mais **les unités ne sont pas comparables** (1 crédit Lindy ≈ 0,01 US$ ; 1 crédit Copilot ≈ 0,008 US$ ; 1 crédit Delos : inconnu).
- **Au résultat :** Agentforce (2 US$ par conversation), 11x (par lead).
- **Au téléphone :** à la minute (Limova 0,20 €, Phonely 0,25-0,35 US$ en dépassement).

**Conséquence pour vous :** vendre un Worker seul est **rare et défendable**, et la référence de prix à battre est **Delos à 50 € (CHF 46.56)**. Pour l'équipe complète, la référence est **Limova** (74.41 à 130.29 CHF), pas les paquets américains.

---

# 2. Notre base de coûts

## 2.1 Prix Anthropic (re-vérifiés le 12.10.2026)

Source : https://platform.claude.com/docs/en/about-claude/pricing (USD par million de jetons).

| Modèle (niveau) | Entrée | Écriture cache (5 min) | **Lecture cache** | Sortie |
|---|---|---|---|---|
| **Haiku 5.5** (Rapide) | 0,10 | 0,125 | 0,01 | 0,50 |
| **Sonnet 5.5** (Équilibré) | 2,00 | 2,50 | **0,10** | 10,00 |
| **Opus 5.5** (Approfondi) | 4,00 | 5,00 | **0,20** | 20,00 |

- **Confirmé :** Haiku 5.5 **×5 au-delà de 100 000 jetons de prompt** (0,50 / 2,50) ; recherche web **10 US$ les 1 000** (+ les jetons des résultats) ; l'exécution de code est **gratuite** avec la recherche/lecture web.
- **Écart avec la note de cadrage :** la lecture du cache de Sonnet 5.5 et Opus 5.5 vaut **5 %** du prix d'entrée (0,10 et 0,20 US$), pas « environ 10 % ». (Haiku 5.5 : 10 %.)
- **Taux de change :** 1 US$ = **0,83107 CHF** (BCE, 09.10.2026). Un dollar plus fort ou plus faible de ±10 % déplace tous les coûts IA de ±10 %.

## 2.2 Coût d'une mission : hypothèses et calcul

**Hypothèses (les vôtres, appliquées telles quelles) :** prompt système de **9 000 jetons** (milieu de 8-10 K), mis en cache ; **2 à 6 appels** par mission ; **1 000 à 4 000 jetons** de sortie. J'ajoute deux choses **prudentes** :
- seul le prompt système est en cache ; **tout le reste du contexte** (la demande, les réponses précédentes, les résultats de recherche web) est **refacturé au tarif d'entrée à chaque appel** de la boucle ;
- une recherche web = 0,01 US$ + environ 4 000 à 5 000 jetons de résultats ajoutés au contexte.

| Scénario | Appels | Sortie totale | Recherches web | Jetons « frais » de départ |
|---|---|---|---|---|
| **Léger** | 2 | 1 000 | 0 | 1 500 |
| **Typique** | 4 | 2 500 | 1 (4 000 jetons) | 2 000 |
| **Lourd** (pire cas réaliste) | 6 | 4 000 | 3 (5 000 jetons chacune) | 3 000 |

**Exemple détaillé : mission Équilibré (Sonnet 5.5), scénario typique**

| Poste | Calcul | US$ |
|---|---|---|
| Prompt système, appel 1 (écriture cache) | 9 000 × 2,50 / 1 M | 0,0225 |
| Prompt système, appels 2 à 4 (lecture cache) | 3 × 9 000 × 0,10 / 1 M | 0,0027 |
| Entrée non cachée (2 000 + 6 625 + 7 250 + 7 875 = 23 750 jetons) | 23 750 × 2 / 1 M | 0,0475 |
| Sortie | 2 500 × 10 / 1 M | 0,0250 |
| 1 recherche web | 1 × 0,01 | 0,0100 |
| **Total** | | **0,1077 US$ = 0,0895 CHF** |

**Résultats pour les trois niveaux** (1 US$ = 0,83107 CHF)

| Niveau (modèle) | Léger | **Typique** | Lourd | Plafond théorique de la boucle* |
|---|---|---|---|---|
| **Rapide** (Haiku 5.5, effort low) | 0,0021 US$ = **0.0017 CHF** | 0,0150 US$ = **0.0125 CHF** | 0,0424 US$ = **0.0352 CHF** | 0,044 US$ = 0.036 CHF (6 appels, 3 recherches) |
| **Équilibré** (Sonnet 5.5, medium) | 0,0404 US$ = **0.0336 CHF** | 0,1077 US$ = **0.0895 CHF** | 0,2730 US$ = **0.2269 CHF** | 1,036 US$ = 0.861 CHF (12 appels, 8 recherches) |
| **Approfondi** (Opus 5.5, high) | 0,0808 US$ = **0.0672 CHF** | 0,2054 US$ = **0.1707 CHF** | 0,5160 US$ = **0.4288 CHF** | 5,229 US$ = 4.346 CHF (20 appels, 15 recherches) |

\* *Plafond théorique : la mission va jusqu'aux limites `maxIterations` et `webMaxUses` de `core/ai/LEVELS.json` (branche `ws/memory-v2`). Ce n'est pas un cas normal : c'est le risque à encadrer par un plafond de coût par mission (section 4.4).*

**Scénario « gros consommateur » (usage intensif) :** un client qui épuise tous ses crédits en missions **lourdes** de son niveau coûte, par crédit, **0.0352 CHF (Rapide), 0.0378 (Équilibré), 0.0357 (Approfondi)** avec la nouvelle échelle 1/6/12 — soit **environ 0.038 CHF le crédit au pire**. Au cas typique : 0.0125 / 0.0149 / 0.0142 CHF le crédit.

**Sensibilités :**
- **Réflexion plus longue (sortie ×2) sur le scénario lourd** (les jetons de réflexion des niveaux élevés comptent en sortie) : Rapide 0.0377 CHF · Équilibré **0.2767** · Approfondi **0.5286**. → à mesurer avec le registre de coûts réel.
- **Cache déjà chaud** (typique, prompt système déjà en cache) : 0.0116 / 0.0716 / 0.1348 CHF.
- **Levier d'économie non compté ci-dessus : mettre en cache la conversation** (pas seulement le prompt système) ramènerait le scénario lourd à **0.0307 / 0.1305 / 0.2360 CHF** (−43 % à −45 % pour Équilibré et Approfondi). C'est la première optimisation à faire côté technique.

## 2.3 Les autres coûts par client

| Poste | Chiffre | Source (consultée le 12.10.2026) | Statut |
|---|---|---|---|
| **Serveur (VPS)** | Notre serveur OVH (2 vCPU, 3,8 Go) correspond à l'offre **VPS-1 : 2 vCores, 4 Go, « à partir de 4,54 US$/mois »** (= CHF 3.77) ; VPS-2 (4 vCores, 8 Go) 8,50 US$ (= CHF 7.06). Part par client **négligeable** (< 0.10 CHF à 50 clients) ; la limite est la **capacité** (2 vCPU pour des missions de plusieurs minutes), pas le prix. | https://www.ovhcloud.com/en/vps/ | partiel : devise/TVA non précisées, contrat réel à confirmer sur votre facture OVH |
| **Numéro de téléphone suisse (Twilio)** | **1,15 US$/mois** (= CHF 0.96) | https://www.twilio.com/en-us/voice/pricing/ch (prix « août 2026 ») | vérifié ; un numéro suisse exige une adresse vérifiée |
| **Appels entrants (Twilio, Suisse local)** | **0,0100 US$/min** ; sortants 0,0419 US$/min (fixe), 0,1802 US$/min (mobile) | idem | vérifié |
| **Reconnaissance vocale (Twilio « Gather »)** | **0,02 US$ « par utilisation »** (à chaque tour de parole) | idem | partiel : unité exacte à confirmer sur une vraie facture |
| **Voix de synthèse** | voix de base gratuites ; **Neural 0,0032 US$ / 100 caractères** | idem | vérifié |
| **WhatsApp** | Notre canal actuel (`dashboard/whatsapp_channel.py`) utilise **l'API Cloud de Meta en direct** : les réponses dans la fenêtre de 24 h après un message du client sont **gratuites** côté Meta ; les messages « modèles » (hors fenêtre) sont payants **par message** depuis le 01.07.2025. Via Twilio : **+0,005 US$ par message**. | https://developers.facebook.com/docs/whatsapp/pricing/ ; https://www.twilio.com/en-us/whatsapp/pricing | vérifié pour le principe ; **tarifs Meta Suisse/France par message : non vérifié** (tableau dynamique) |
| **E-mail** | pas de frais de canal (Gmail/Outlook via connecteur) : seulement le coût IA | — | — |
| **Paiement Stripe** | Cartes suisses **2,9 % + 0,30 CHF** ; cartes étrangères **3,25 % + 0,30 CHF** ; conversion de devise **+2 %** ; Stripe Billing **0,7 %** du volume d'abonnements | https://stripe.com/ch/pricing | vérifié ; Billing 0,7 % : à confirmer sur votre compte |

**Coût réel d'une minute de téléphone (agent actuel, Twilio + IA) :** 0,01 + 5 tours × (0,02 reconnaissance + 2,5 × 0,0032 voix neurale + 0,0003 IA) = 0,1515 US$ = **0.126 CHF/min** (hypothèse : 5 tours de parole par minute, réponse de 250 caractères). Fourchette : **0.076 CHF** (4 tours, voix gratuite) à **0.161 CHF** (6,5 tours, voix neurale). C'est le poste où la marge est la plus mince.

**Frais Stripe sur un plan à 29 CHF :** carte suisse = 29 × (2,9 % + 0,7 %) + 0,30 = **1.34 CHF** (4,6 %) ; carte étrangère avec conversion = 29 × (3,25 % + 0,7 % + 2 %) + 0,30 = **2.03 CHF** (7,0 %).

**Une conversation WhatsApp de 10 messages via Twilio :** 10 × 0,005 = 0,05 US$ de frais de canal + environ 5 réponses IA (quelques centimes) — négligeable face au prix du plan.

---

# 3. Notre offre actuelle (vérifiée dans le code, `origin/main`)

Sources : `dashboard/server.py` (`PLAN_CATALOG`, ligne 2397 et suivantes), `dashboard/seo_pages.py` (`PRICING_PLANS`), `dashboard/app.js`, `core/ai/LEVELS.json` (branche `ws/memory-v2`).

| Plan | Prix / mois | Annuel | Crédits / mois | CHF par crédit |
|---|---|---|---|---|
| Essai | 0 (3 jours, sans carte) | — | 15 | — |
| Starter | 39 | 390 | 150 | 0.260 |
| Business | 99 | 990 | 600 | 0.165 |
| Pro | 139 | 1 390 | 1 500 | **0.093** |
| Scale | 449 | 4 490 | 4 000 | **0.112** |
| Enterprise | sur devis | — | illimité | — |

Niveaux proposés (désactivés par défaut, `"enabled": false`) : Rapide **1** crédit (Haiku 5.5, effort low), Équilibré **3** (Sonnet 5.5, medium, par défaut), Approfondi **8** (Opus 5.5, high).

**Constats (tous vérifiés) :**
1. Aujourd'hui **1 mission = 1 crédit** quel que soit le modèle.
2. **La recharge de crédits n'est reliée à aucun paiement** : `recharge_billing_credits` est réservée au propriétaire (`dashboard/server.py`). Aucun client ne peut acheter de crédits.
3. **Prix par crédit incohérent :** Pro (0.093 CHF) est **moins cher** que Scale (0.112 CHF) alors que Scale est le plus gros.
4. La page d'accueil (`dashboard/index.html`, ligne 464) dit : « Un chatbot seul coûte déjà l'équivalent de CHF 79 à CHF 149/mois… **au moins 5 % moins cher que les alternatives comparables** ». **Aucune source dans le dépôt ne l'étaye** ; mes relevés la contredisent (section 4.2).
5. Les prix Stripe réels sont **à recréer** (note du 15.09.2026 dans `IMPLEMENTATION-COMMERCIALISATION-SUISSE-2026-09-15.md`) : changer les prix maintenant coûte peu.

---

# 4. Recommandation

## 4.1 (a) L'échelle de crédits : à corriger

**Règle :** au pire cas, quand le client **épuise tous ses crédits** en missions lourdes, **le coût IA doit rester sous 35 % du prix du plan**.

**Coût IA pire cas par crédit** = coût d'une mission lourde ÷ crédits facturés (section 2.2) :

| Échelle | Rapide | Équilibré | Approfondi | **Pire** |
|---|---|---|---|---|
| **Actuelle 1 / 3 / 8** | 0.0352 | **0.0756** (0,2269 ÷ 3) | 0.0536 | **0.0756** |
| **Proposée 1 / 6 / 12** | 0.0352 | 0.0378 (0,2269 ÷ 6) | 0.0357 | **0.0378** |

Avec 1/3/8, **Équilibré est sous-facturé** : la mission coûte 6,4 fois une mission Rapide (0,2269 ÷ 0,0352) et ne se facture que 3 fois. Avec **1/6/12**, les trois niveaux coûtent à peu près la même chose **par crédit** (0.035 à 0.038 CHF) : peu importe le niveau choisi par le client, la marge est la même. Approfondi coûte 1,9 fois Équilibré (0,4288 ÷ 0,2269) : 12 ÷ 6 = 2, cohérent.

**Test de l'échelle actuelle** (coût IA pire cas = crédits × 0.0756) :

| Plan actuel | Prix | Crédits | Coût IA pire cas | % du prix | Typique | Verdict |
|---|---|---|---|---|---|---|
| Starter | 39 | 150 | 11.34 | **29.1 %** | 11.5 % | passe |
| Business | 99 | 600 | 45.38 | **45.8 %** | 18.1 % | **échoue** |
| Pro | 139 | 1 500 | 113.45 | **81.6 %** | 32.2 % | **échoue** |
| Scale | 449 | 4 000 | 302.53 | **67.4 %** | 26.6 % | **échoue** |

**Plan par plan avec la nouvelle échelle** (crédits max pour 35 % = 0,35 × prix ÷ 0,0378 = **9,26 × prix**) :

| Offre | Prix | Crédits proposés | Maximum admis (35 %) | Coût IA pire cas | % du prix | Coût IA typique | % |
|---|---|---|---|---|---|---|---|
| Solo | 29 | **250** | 268 | 9.45 | **32.6 %** | 3.73 | 12.9 % |
| Trio | 59 | **500** | 546 | 18.91 | **32.0 %** | 7.46 | 12.6 % |
| Équipe | 99 | **900** | 916 | 34.03 | **34.4 %** | 13.43 | 13.6 % |
| Pro | 139 | **1 250** | 1 286 | 47.27 | **34.0 %** | 18.65 | 13.4 % |
| Scale | 449 | **4 000** | 4 155 | 151.27 | **33.7 %** | 59.67 | 13.3 % |

(Marge après frais Stripe carte suisse, pire cas / typique : Solo 18.21 / 23.93 · Trio 37.67 / 49.12 · Équipe 61.10 / 81.71 · Pro 86.43 / 115.05 · Scale 281.27 / 372.87 CHF.)

**Ce que ça représente en missions** (avec 1/6/12) : Solo 250 crédits = 250 missions Rapide **ou** 41 Équilibré **ou** 20 Approfondi ; Trio 500 = 500 / 83 / 41 ; Équipe 900 = 900 / 150 / 75 ; Pro 1 250 = 1 250 / 208 / 104 ; Scale 4 000 = 4 000 / 666 / 333.

**Honnêteté sur la perte de volume :** en missions Équilibré, l'ancien Business (600 crédits à 3) = 200 missions → Équipe = 150 (−25 %) ; l'ancien Pro = 500 → 208 (−58 %) ; l'ancien Scale = 1 333 → 666 (−50 %). C'est le prix de la règle des 35 %. **Si vous préférez garder plus de volume**, vous pouvez assouplir la règle à 45 % au pire cas (le coût **typique** resterait autour de 13 %) : crédits max = 0,45 × prix ÷ 0,0378 = 11,9 × prix (Équipe 1 178, Pro 1 650, Scale 5 345). Je recommande de **lancer prudemment à 35 %**, puis de **relever les crédits après 30 jours de coûts réels** (le registre de coûts de la branche `ws/p1-e1-ledger` doit être fusionné pour ça).

**Garde-fou indispensable :** le coût d'une mission qui va au bout de la boucle peut atteindre **4.35 CHF** (Approfondi, 20 appels, 15 recherches), soit 10 fois le cas lourd. Il faut un **plafond de coût par mission** (proposé : Équilibré 0.50 CHF, Approfondi 1.00 CHF ; Rapide n'en a pas besoin, son plafond théorique est de 0.036 CHF). Même au plafond, le coût par crédit (0.083 CHF) reste **sous** le prix d'un crédit (0.11-0.12) : jamais de perte nette.

**Évolution recommandée à terme :** débiter les crédits d'après le **coût réel mesuré** (1 crédit = environ 0.04 CHF de coût IA) plutôt que d'après une valeur fixe par niveau : la règle des 35 % serait alors vraie par construction.

## 4.2 (b) Les prix, justifiés face au tableau des concurrents

### L'offre proposée

| Offre | Mensuel | Annuel (10 mois) | Crédits | Contenu |
|---|---|---|---|---|
| **Essai** | 0 | — | 15 (Rapide seulement) | 3 jours, sans carte ; **pas de minutes de téléphone** pendant l'essai |
| **Worker Solo** | **CHF 29** | **CHF 290** | **250** | 1 Worker au choix, installé selon ses compétences, e-mail + WhatsApp + téléphone (en crédits) |
| **Trio** | **CHF 59** | **CHF 590** | **500** | 3 Workers au choix + Chloé |
| **Équipe** | **CHF 99** | **CHF 990** | **900** | 17 Workers + Chloé (remplace « Business ») |
| **Pro** | CHF 139 | CHF 1 390 | **1 250** | Équipe + volume (+39 % de crédits) |
| **Scale** | CHF 449 | CHF 4 490 | **4 000** | inchangé en prix |
| **Enterprise** | sur devis | — | — | inchangé |
| **Pack de crédits** | **CHF 12 les 100**, **CHF 55 les 500** | — | — | à la demande, jamais automatique |

**Starter (39) est retiré** : remplacé par Solo (29) et Trio (59). Le même prix pour **tous** les Workers (simple ; le pot de crédits absorbe les différences de coût entre Workers). Remise annuelle = **2 mois offerts (−16,7 %)**, comme sur le site actuel ; le marché : Delos −8 à −9 %, Limova −1 à −2 % hors codes, Marblism/Phonely/Zapier −33 à −45 %.

**Option plus agressive (à votre choix) :** Solo à **CHF 19 avec 150 crédits** (pire cas 29.8 %) : 59 % moins cher que Delos, au niveau de Marblism en annuel (19.95), mais à l'opposé de « faire monter la valeur ».

### Comparaison avec les offres comparables (prix catalogue, CHF, 12.10.2026)

| Notre offre | Offre comparée | Prix comparé | Écart | Verdict |
|---|---|---|---|---|
| **Solo 29** | **Delos Team, 1 Worker (50 €)** | 46.56 | **−37,7 %** | **moins cher** |
| Solo 29 | Sintra helper seul (39 US$, statut incertain) | 32.41 | −10,5 % | moins cher |
| Solo 29 | Lindy Team (49,99 US$, 5 000 crédits) | 41.55 | −30,2 % | moins cher (produit différent : constructeur d'agents) |
| Solo 29 | Phonely Starter (50 US$, agent téléphone seul) | 41.55 | −30,2 % | moins cher (leur forfait inclut 200-250 min ; le nôtre : crédits) |
| Solo 29 | Marblism mensuel (44 US$, 7 employés) | 36.57 | −20,7 % | moins cher pour 1 Worker, mais **eux en donnent 7** |
| Solo annuel 24.17/mois | Marblism annuel (24 US$/mois) | 19.95 | **+21,2 %** | **plus cher** |
| Solo 29 | Dust Pro mensuel (30 €/siège) | 27.94 | **+3,8 %** | **plus cher** (légèrement ; Dust = chat, sans canaux) |
| **Trio 59** | **Limova Essentiel (79,90 €, 8 agents, 5 utilisateurs)** | 74.41 | **−20,7 %** | **moins cher** (mais 3 Workers contre 8 agents) |
| Trio 59 | Limova Essentiel **avec code LEGEND10** (71,91 €) | 66.97 | −11,9 % | moins cher (si le code s'applique : non vérifié) |
| Trio annuel 49.17/mois | Limova Essentiel annuel (949,90 €/12) | 73.72 | −33,3 % | moins cher |
| **Équipe 99** | **Limova Pro (139,90 €)**, seul plan avec agent téléphone + chatbot WhatsApp | 130.29 | **−24,0 %** | **moins cher** (Limova ajoute 0,20 €/min) |
| Équipe 99 | Limova Pro **avec LEGEND10** (125,91 €) | 117.26 | −15,6 % | moins cher (si code : non vérifié) |
| Équipe annuel 990 | Limova Pro annuel (1 649,90 €) | 1 536.55 | −35,6 % | moins cher |
| Équipe annuel 990 | Limova Pro annuel **avec LEGEND25** (1 237,43 €) | 1 152.41 | −14,1 % | moins cher (si code : non vérifié) |
| Équipe 99 | **Limova Essentiel** (79,90 €, sans agent téléphone ni chatbot WhatsApp) | 74.41 | **+33,0 %** | **plus cher** (mais 17 Workers contre 8 agents) |
| Équipe 99 | Sintra 12 mois, prix catalogue (52 US$) | 43.22 | **+129 %** | **plus cher** (12 helpers génériques, 250 crédits, US) |
| Équipe 99 | Marblism mensuel (44 US$) | 36.57 | **+171 %** | **plus cher** (7 employés, 50 h, téléphone US/CA/UK) |
| Équipe 99 | Swisscom Swiss AI Assistant Essential (149 CHF) | 149 | −33,6 % | moins cher (chatbot d'équipe, pas un agent) |
| **Pro 139** | **Limova Pro (139,90 €)** | 130.29 | **+6,7 %** | **plus cher** (mêmes chiffres, mais l'euro vaut 0,9313 CHF) |
| **Téléphone ≈ 0.17 CHF/min** (1,5 crédit) | Limova Tom (0,20 €/min, + plan Pro) | 0.186 | **−8,7 %** | **moins cher** |
| Téléphone ≈ 0.17 CHF/min | Phonely, dépassement Starter (0,25 US$/min) | 0.208 | −18,2 % | moins cher |

**Lecture honnête pour décider :**
- **Face à vos deux concurrents directs**, nous sommes **moins chers à chaque échelon utile** : Solo contre Delos (−38 %), Équipe contre le seul plan Limova qui a l'agent téléphone et le chatbot WhatsApp (−24 %, et encore −16 % contre le prix avec code promo).
- **Nous ne sommes pas moins chers** que Limova Essentiel pour l'équipe complète (+33 %), que les paquets américains Sintra/Marblism (+129 % à +171 %), ni que Dust (+4 %), ni **Pro contre Limova Pro (+7 %)**. Si vous voulez que Pro soit aussi « moins cher que Limova » : **CHF 129 avec 1 150 crédits** (−1 % : égalité, honnêtement). Sinon, présentez Pro comme « Équipe + 39 % de volume », sans comparaison.
- **Les volumes ne sont pas comparables** : Delos (40 000 crédits) et Limova (aucun plafond publié) ne disent pas combien de missions ils permettent. Je ne peux donc pas affirmer « plus de missions pour moins cher ».

### Pack de crédits supplémentaires (« bon marché », comme vous le voulez)

- **CHF 12 les 100 crédits** (0.12 CHF le crédit) et **CHF 55 les 500** (0.11). Le crédit d'un plan vaut 0.110 à 0.118 : le pack est **seulement 3 à 9 % plus cher** — pas une punition. Coût IA pire cas dans le pack : 31.5 % et 34.4 % ; typique 12 % à 14 %.
- Un pack à 10 CHF les 100 (0.10) serait plus « généreux » mais ferait passer le pire cas à **37.8 %** : au-dessus de votre règle.
- Un client qui a besoin de volume est mieux servi par **Équipe (0.110 le crédit)** que par Solo + packs (0.12) : l'échelle des prix se tient.
- **Prérequis technique :** relier l'achat de crédits à un vrai paiement Stripe (aujourd'hui impossible pour un client).
- Comparaison par crédit impossible (unités différentes). Ordres de grandeur : recharge Lindy 10 US$ les 1 000 crédits, mais leurs « demandes courantes » coûtent 2 à 250 crédits (0,02 à 2,50 US$) ; une action Agentforce 0,10 US$ (CHF 0.083). Notre mission Rapide = 1 crédit ≈ CHF 0.12 ; Équilibré = 6 crédits ≈ CHF 0.72 : **dans la même fourchette, pas démontrablement moins chère**.

### Les canaux : un mélange, pas seulement WhatsApp

Tous les Workers peuvent travailler par **e-mail, WhatsApp et téléphone** ; le prix du plan est le même, les canaux consomment des crédits :

| Canal | Coût réel estimé pour nous | Proposition de facturation |
|---|---|---|
| **E-mail** (réponse/tri) | CHF 0.002 à 0.0125 (Rapide) | 1 crédit par conversation traitée (Rapide) |
| **WhatsApp** (client écrit, réponse dans les 24 h) | Meta gratuit en direct ; Twilio +0.004 CHF par message ; + IA | 1 crédit par conversation traitée (Rapide) |
| **Téléphone** (entrant) | **0.076 à 0.161 CHF/min** (central 0.126) | **1,5 crédit par minute** (15 crédits = 10 minutes) ≈ 0.17 CHF/min |

Règle de révision : si le coût **mesuré** dépasse **0.13 CHF/min**, passer à **2 crédits/min** (≈ 0.22-0.23 CHF/min, environ +20 à +25 % contre Limova : décision à prendre avec les vraies factures). Les Workers naturellement concernés par le téléphone : **Nora** (support), **Alex** (ventes), **Noah** (admin/e-mail) — proposition à valider ; les autres Workers l'utilisent peu.

**Exemple chiffré (profil « réception » : 300 min d'appels + 200 conversations WhatsApp + 300 e-mails par mois = 450 + 200 + 300 = 950 crédits)** : Équipe 99 + 100 crédits (12) = **CHF 111**, ou Solo 29 + 700 crédits (7 × 12) = CHF 113. Chez Limova : Pro 139,90 € + 300 × 0,20 € = **199,90 € = CHF 186.17 HT**. Écart : **−40 %**. Notre coût estimé : 37.8 (téléphone) + 6.25 (500 conversations Rapide) + environ 5 (Stripe) + 1 (numéro) ≈ **CHF 50**, soit une marge d'environ 55 %.

### Installer un Worker chez le client « selon ses compétences »

- **Prix de l'installation guidée : inclus** (pas de frais de mise en place). Référence marché : **Limova inclut un onboarding sur mesure dans chaque pack** (page Limova) ; je n'ai trouvé **aucun prix d'installation vérifié** chez les autres.
- Une installation **accompagnée par un humain** (vous) coûte du temps : décision à prendre **après les 5 premiers clients**, avec le temps réellement passé. Je ne propose pas de chiffre faute de référence vérifiée (la seule trouvée, « 6 000 à 15 000 € HT pour un agent vocal sur mesure », vient d'un blog d'intégrateur, **non vérifiée**).

## 4.3 (c) La phrase de positionnement qu'on peut défendre

**Quand les canaux seront réellement en production :**
> « Un Worker IA qui répond à vos e-mails, à vos appels et sur WhatsApp, dès **CHF 29 par mois**, sans engagement : **38 % moins cher** que le Worker à l'unité de Delos (50 €, soit CHF 46.56 au 12.10.2026), et sans le plan Pro à 139,90 € que Limova exige pour débloquer l'agent téléphone et le chatbot WhatsApp. »

**Aujourd'hui (ce qui existe réellement) :**
> « Un Worker IA spécialisé par métier, dès **CHF 29 par mois**, sans engagement, qui prépare vos e-mails et vos documents avec validation avant toute action sensible : **38 % moins cher** que le Worker à l'unité de Delos (50 €/mois). »

À chaque fois : **date de la comparaison et lien vers la source** en bas de page, et à refaire tous les trimestres.

**À ne jamais écrire :** « au moins 5 % moins cher que les alternatives comparables » (faux face à Limova Essentiel, Sintra, Marblism, Dust) ; « le moins cher du marché » ; toute note, avis, nombre de clients ou certification repris d'un concurrent ; « téléphone/WhatsApp pour vos clients » tant que le numéro et l'installation par client ne sont pas en production.

## 4.4 (d) Les risques

| Risque | Ce qui peut arriver | Parade |
|---|---|---|
| **Un concurrent baisse ses prix** | Sintra et Marblism affichent déjà 15,60 à 24 US$/mois en promotion ; Delos pourrait publier un prix annuel ou une promo ; les codes Limova (−10 %/−25 %) réduisent déjà l'écart de 8 à 10 points | Se positionner sur ce que les paquets US n'ont pas (CH/FR, WhatsApp, téléphone, validation humaine) ; relire les prix chaque trimestre |
| **Anthropic change ses prix** | Haiku 5.5 ×5 au-delà de 100 000 jetons de prompt ; le cache Sonnet/Opus est à 5 % ; de nouveaux modèles arrivent | Les crédits suivent le coût (réévaluer l'échelle à chaque changement) ; garder la marge de 65 % ; mettre en cache la conversation |
| **Le dollar monte** | Coûts en US$, ventes en CHF : +10 % sur le dollar = +3,4 points sur le ratio de 34 % | Marge de sécurité de 1 à 2 points déjà prise ; révision trimestrielle |
| **Abus de l'essai** | Plusieurs comptes pour l'essai gratuit : coût IA **borné à environ 0.57 CHF** par essai au pire (15 × 0.0378), mais **le téléphone et le WhatsApp sortant coûtent vraiment** | Pas de téléphone ni de messages sortants pendant l'essai ; vérification d'un numéro ou d'une carte avant d'activer un canal |
| **Missions qui ne s'arrêtent pas** | Jusqu'à 4.35 CHF pour une mission Approfondi qui va au bout de la boucle | Plafond de coût par mission ; revoir `maxIterations` (20) et `webMaxUses` (15) d'Approfondi |
| **Vendre ce qui n'existe pas encore** | Numéro Twilio non acheté (compte en essai au 06.10.2026, à re-vérifier), WhatsApp par client, déclencheurs autonomes, « installation selon compétences » non construits (note du projet du 12.10.2026) | Ne vendre le « Worker qui répond au téléphone » qu'après mise en production et test réel ; commencer par l'e-mail et les missions |
| **Capacité du serveur** | 2 vCPU, une mission = un processus PowerShell de plusieurs minutes | Plafonds d'exécutions simultanées (déjà en place), passer à VPS-2 (≈ 7 CHF/mois) avant d'avoir beaucoup de clients |
| **Allégations comparatives** | En droit suisse (loi contre la concurrence déloyale) comme français, une comparaison de prix doit être exacte et vérifiable | Chaque affirmation = chiffre + source + date ; retirer la phrase actuelle de la page d'accueil |
| **TVA** | Le site indique l'absence de TVA sous 100 000 CHF de chiffre d'affaires ; des ventes B2C dans l'UE peuvent avoir leurs propres règles | Hors périmètre de cette étude : à faire valider par votre fiduciaire |

## 4.5 (e) Le tableau de décision d'une page

| # | Décision | Recommandation | Pourquoi (une ligne) | Alternative |
|---|---|---|---|---|
| 1 | Échelle des crédits | **Rapide 1 · Équilibré 6 · Approfondi 12** | 1/3/8 sous-facture Équilibré : Business 46 %, Pro 82 %, Scale 67 % au pire cas | Garder 1/3/8 : possible seulement avec des plans à ≥ 216 CHF par 1 000 crédits |
| 2 | Crédits par offre | **250 / 500 / 900 / 1 250 / 4 000** | 32-34 % au pire cas, 13 % en usage typique | Règle à 45 % : 1 178 (Équipe) / 1 650 (Pro) / 5 345 (Scale) |
| 3 | Worker seul | **CHF 29/mois, 290/an** | 38 % sous Delos (46.56) ; marge typique 23.93 CHF | CHF 19 / 150 crédits : −59 % vs Delos, au niveau de Marblism annuel |
| 4 | Trio (3 Workers) | **CHF 59/mois, 590/an** | 21 % sous Limova Essentiel (74.41) | — |
| 5 | Équipe (17 Workers + Chloé) | **CHF 99/mois, 990/an** | 24 % sous Limova Pro (130.29), le seul avec agent téléphone + chatbot WhatsApp | CHF 79 (≈ Limova Essentiel) avec 700 crédits |
| 6 | Pro et Scale | **139 et 449, prix inchangés** ; Pro = « Équipe + 39 % de volume » | Pro est 7 % **plus cher** que Limova Pro | Pro à CHF 129 / 1 150 crédits (égalité) ou supprimer Pro |
| 7 | Starter 39 | **Retirer** (remplacé par Solo/Trio) | Trois entrées de gamme (29/39/59) = confusion | Le garder avec 350 crédits |
| 8 | Pack de crédits | **CHF 12 les 100, CHF 55 les 500** | Seulement 3-9 % au-dessus du crédit du plan ; 31-34 % au pire cas | CHF 10 les 100 (37.8 % au pire cas) |
| 9 | Téléphone | **1,5 crédit par minute** (≈ 0.17 CHF/min) | 8,7 % sous Limova (0.186) ; marge d'environ 25 % (coût 0.126) | 2 crédits/min si le coût mesuré dépasse 0.13 |
| 10 | Essai | **3 jours, 15 crédits, Rapide seulement, sans téléphone** | Coût borné à 0.57 CHF ; le téléphone, lui, coûte réellement | — |
| 11 | Installation | **Guidée, incluse** ; accompagnement humain : décision après 5 clients | Limova inclut son onboarding | — |
| 12 | Message du site | **Retirer « au moins 5 % moins cher… »**, utiliser la phrase 4.3 | Non étayée et fausse face à 4 concurrents | — |
| 13 | Avant de vendre | **Brancher le paiement des crédits ; plafond de coût par mission ; mettre en cache la conversation ; vendre le téléphone/WhatsApp client seulement une fois en production** | Sans cela, la marge ou la promesse ne tiennent pas | — |

---

# 5. Annexes

## 5.1 Ce qui n'a pas pu être vérifié (à ne pas citer)

Voir aussi `docs/pricing-study-data.json` (`unverifiedLeads`).
- Nombre de missions équivalant aux « 40 000 crédits » de Delos ; prix d'un 2e ou 3e Worker chez Delos ; prix annuel de Delos *Team*.
- L'application réelle des codes LEGEND10/LEGEND25 de Limova aux prix affichés.
- Le statut actuel des plans « helper seul » de Sintra ; la durée facturée réelle des plans 3 et 12 mois.
- Les tarifs Meta par message WhatsApp pour la Suisse et la France ; l'unité exacte de facturation Twilio « Gather » ; le prix réel du contrat OVH ; l'application de Stripe Billing 0,7 % à votre compte.
- Toutes les annonces des concurrents (avis, nombre de clients, certifications, « 10 000 Workers déployés ») : jamais à reprendre.
- Prix de Relevance AI, Artisan, Cassidy (Business), 11x « Julian » : **sur devis / non publiés**.

## 5.2 Méthode et reproductibilité

- Les pages JavaScript de Delos et Limova ont été **lues dans un navigateur** (prix affichés par animation ou chargés dynamiquement) ; les autres via leur page officielle. Quand le résumé automatique d'une page était incomplet ou contradictoire, je l'ai signalé dans le tableau.
- Tous les coûts IA se recalculent avec `python docs/pricing-cost-model.py` (hypothèses en tête du fichier). **Ce sont des hypothèses, pas des mesures.** Dès que le registre de coûts réel est fusionné (branche `ws/p1-e1-ledger`), remplacer ces hypothèses par les coûts mesurés et relancer le test des 35 %.
- Source des plafonds de boucle : `core/ai/LEVELS.json` sur la branche `origin/ws/memory-v2` (niveaux désactivés tant que l'échelle n'est pas validée : `"enabled": false`).

## 5.3 Étapes suivantes proposées (après votre décision)

1. Mettre à jour `core/ai/LEVELS.json` (crédits 1/6/12), `PLAN_CATALOG`, la page Tarifs et les textes « 1 mission = 1 crédit » (page Tarifs, FAQ, CGV).
2. Créer les nouveaux prix dans Stripe (Solo, Trio, Équipe, Pro, Scale ; mensuel et annuel) et relier le pack de crédits à un paiement.
3. Implémenter le plafond de coût par mission et la mise en cache de la conversation.
4. Remplacer la phrase d'accueil (section 4.3).
5. Construire, tester puis seulement ensuite annoncer : numéro de téléphone par Worker, WhatsApp par client, déclencheurs autonomes, installation d'un Worker selon ses compétences.
