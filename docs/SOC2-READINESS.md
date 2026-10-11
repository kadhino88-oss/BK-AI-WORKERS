# SOC 2 — analyse d'écart et chemin recommandé (fondateur seul)

Rédigé le **7 octobre 2026**. Statut : **analyse d'écart uniquement. Aucun audit SOC 2 n'est engagé, aucun rapport n'existe.**
Ce document sert à décider (faut-il le faire, quand, à quel prix), pas à communiquer : la page publique
[`/securite.html`](../dashboard/trust_pages.py) dit « aucun rapport SOC 2 » et un test refuse toute phrase contraire tant
qu'aucun rapport n'est déposé dans `docs/evidence/` (voir `tests/trust/check_certification_claims.py`).
Complète [`SECURITY-OVERVIEW.md`](SECURITY-OVERVIEW.md) (faits et fichiers) et [`DPA-TEMPLATE.md`](DPA-TEMPLATE.md) (sous-traitance).

## 1. Ce que c'est, en deux minutes

- SOC 2 est un **rapport d'attestation** émis par un cabinet d'audit (CPA) selon les *Trust Services Criteria* de l'AICPA. Ce n'est pas une certification délivrée par un organisme : c'est un rapport d'auditeur sur *vos* contrôles.
- Cinq catégories de critères : Security, Availability, Processing Integrity, Confidentiality, Privacy. **Security (les « Common Criteria », CC1 à CC9) est la base** de tout rapport ; les autres s'ajoutent au choix. Recommandation : Security seul pour un premier rapport, éventuellement + Availability et Confidentiality ensuite.
- **Type I** : photographie à une date (les contrôles sont conçus et en place). **Type II** : les contrôles ont **fonctionné** pendant une période d'observation (3 à 12 mois ; 6 mois est courant — voir les sources, §4). Les clients exigeants demandent le Type II.
- Un rapport ne se « prépare » pas en une semaine : il faut des politiques écrites, des preuves collectées en continu, et un auditeur.

## 2. Analyse d'écart — Security (Common Criteria)

Légende effort pour **une personne seule à temps partiel** : **S** ≤ 2 jours · **M** 3 à 10 jours · **L** > 10 jours (ou dépend d'un tiers). « Preuve présente » = ce que le dépôt prouve aujourd'hui.

| Critère | Preuve présente dans le dépôt | Écart | Effort |
|---|---|---|---|
| **CC1** Environnement de contrôle (intégrité/éthique, supervision, structure, compétence, responsabilité) | Entité juridique et responsable identifiés (mentions légales, CGV). Manifeste du produit (`README.md`). | Aucune politique écrite (code de conduite, politique de sécurité, rôles), pas de supervision indépendante (fondateur seul), pas de formation sécurité tracée. Compenser : conseiller externe/fractional CISO qui signe une revue trimestrielle. | M |
| **CC2** Information et communication | Page sécurité, `security.txt`, page de statut, confidentialité, CGV, mentions légales. | Pas de « description du système » (document exigé par l'auditeur), pas de procédure de communication d'incident aux clients. | S–M |
| **CC3** Évaluation des risques | Cette analyse ; liste de faiblesses `SECURITY-OVERVIEW.md` §6. | Pas de registre de risques annuel, pas d'évaluation du risque de fraude, pas d'analyse d'impact des changements. | S–M |
| **CC4** Suivi des contrôles | Mesure de disponibilité (`status_monitor.py`) ; sonde `deploy/healthcheck.sh`. | Aucun suivi continu des *contrôles* (MFA activé ? sauvegardes faites ? correctifs ?), aucune évaluation interne périodique. Un outil d'automatisation de conformité couvre l'essentiel. | M |
| **CC5** Activités de contrôle | Barrières dans le code : chaîne d'autorisation des Workers, validation humaine des écritures, limites d'usage. | Pas de politiques/procédures reliant ces barrières aux critères ; séparation des tâches impossible seul → contrôles compensatoires à documenter. | M |
| **CC6.1–6.3** Accès logique, enregistrement, rôles | Mots de passe PBKDF2, sessions hachées, isolation par client, identifiants d'outils AES-256-GCM, modules RBAC PowerShell, porte propriétaire séparée. | Pas de 2FA (clients **et** compte propriétaire/SSH/GitHub/OVH — à vérifier hors dépôt), pas de revue périodique des accès, pas de procédure d'arrivée/départ, compte propriétaire unique et partagé (`CLI-DASHBOARD`), clé maître sans rotation ni KMS. | L |
| **CC6.4** Accès physique | Hébergé chez OVHcloud (mentions légales). | Contrôle **hérité** : obtenir les attestations OVHcloud *pour le produit VPS utilisé* (la page OVHcloud liste ISO 27001/27017/27018/27701 et SOC 1/2/3 pour ses services IaaS mais ne précise pas le périmètre par produit — consultée le 2026-10-07) et les citer comme « sous-organisation ». Ne jamais les présenter comme les nôtres. | S |
| **CC6.5** Mise au rebut des données | Suppression de compte en libre-service ; purge des transcriptions à 90 jours. | Facturation et journaux non purgés, sauvegardes 14 j non purgeables à la demande, durées de conservation non écrites. | S–M |
| **CC6.6** Menaces aux frontières | Caddy en frontal, port applicatif lié à `127.0.0.1`, limites d'usage, signatures de webhooks, garde SSRF des formulaires. | **SSRF sur l'URL de webhook sortant**, pas de plafond de taille de corps, pas de WAF, pare-feu de l'hôte non documenté dans le dépôt. | M |
| **CC6.7** Transmission des données | HTTPS partout, appels sortants en HTTPS. | Pas de HSTS ni de CSP, trafic Caddy→app en HTTP (réseau Docker privé). | S |
| **CC6.8** Logiciels malveillants | — | Aucun contrôle (pas d'antimalware/EDR serveur, pas de scan d'image, conteneur en `root`). | M |
| **CC7.1** Détection des vulnérabilités | — | Pas de scan de dépendances/images, pas de calendrier de correctifs (image de base non épinglée). | M |
| **CC7.2–7.3** Surveillance des anomalies et évaluation | Journal d'activité (1 000 événements), mesure de disponibilité. | Pas d'alerte automatique (la page se met à jour mais **personne n'est prévenu**), pas de surveillance externe indépendante (la mesure tourne sur le serveur qu'elle mesure ; `/api/health` répond à `HEAD`, un moniteur gratuit se branche en quelques minutes : voir `deploy/DEPLOIEMENT-VPS.md`), échecs de connexion non journalisés, pas de SIEM, pas de revue de journaux. | M |
| **CC7.4** Réponse aux incidents | Procédure de publication d'incident (`deploy/status-incident.py`). | Aucun plan de réponse écrit (rôles, gravité, communication, notification PFPDT/RGPD), aucun exercice. | M |
| **CC7.5** Reprise | Sauvegarde nocturne du volume (procédure `DEPLOIEMENT-VPS.md`). | Même serveur, non chiffrée, **aucun test de restauration**, aucun plan de reprise, un seul VPS. | M–L |
| **CC8.1** Gestion des changements | Historique Git ; déploiement automatisé (`deploy.yml`) ; tests dans `tests/`. | Pas de revue par un tiers (fondateur seul) → compenser par branche protégée + CI de tests obligatoire + traçabilité des changements ; pas d'environnement de préproduction ; pas de procédure de retour arrière écrite. | M |
| **CC9.1** Continuité / atténuation des risques | Sauvegardes, reprise automatique du conteneur (`healthcheck.sh`). | Pas d'analyse d'impact sur l'activité, pas d'assurance cyber (à vérifier). | S–M |
| **CC9.2** Fournisseurs et partenaires | Liste des sous-traitants réellement appelés (`SECURITY-OVERVIEW.md` §4, page publique). | Pas de registre fournisseurs avec évaluation du risque, DPA non rassemblés, rapports SOC/ISO des fournisseurs critiques (OVHcloud, Anthropic, Stripe, Twilio) non collectés. | M |
| *Optionnel* A1 Disponibilité | Page de statut mesurée, sauvegardes. | Pas de SLA, un seul serveur, pas de capacité surveillée. | M–L |
| *Optionnel* C1 Confidentialité | Chiffrement des identifiants, suppression de compte. | Données clients non chiffrées au niveau applicatif, rétention non écrite. | M |
| *Optionnel* P Vie privée | Politique de confidentialité, export/suppression, nLPD/RGPD cités. | Registre des traitements, AIPD, DPA : voir §5. À ne **pas** inclure dans un premier rapport. | L |

**Lecture honnête** : environ **40 à 70 jours de travail** pour une personne, dont une partie technique (§6 de `SECURITY-OVERVIEW.md`) et une grande partie documentaire. C'est une estimation de l'auteur de ce document à partir du tableau ci-dessus, pas un devis.

## 3. Chemin recommandé pour un fondateur seul

0. **Décider si c'est utile maintenant.** Le dépôt ne contient aucune demande client exigeant un SOC 2. Pour des PME suisses et européennes, les demandes les plus fréquentes sont d'abord un **accord de sous-traitance (DPA)**, la **liste des sous-traitants**, la localisation des données et un questionnaire de sécurité ; ISO/IEC 27001 est souvent plus recevable qu'un SOC 2 en Europe, SOC 2 l'est davantage aux États-Unis. Ne lancer l'audit que lorsqu'un contrat précis le demande ou le justifie. *(Jugement de l'auteur, à confronter à vos prospects réels.)*
1. **Semaines 0–6 — corriger les écarts techniques à fort effet** : SSRF du webhook, plafond de corps, en-têtes HTTP, 2FA (propriétaire d'abord), conteneur non-root, journal des échecs de connexion, sauvegarde chiffrée hors serveur + **test de restauration documenté**, alerte quand la mesure signale une panne. Active le 2FA sur GitHub, OVHcloud, Stripe, Google, Twilio, Anthropic (comptes du propriétaire — hors dépôt, à vérifier).
2. **Semaines 4–10 — politiques et preuves** avec un **outil d'automatisation de conformité** (modèles de politiques, collecte de preuves, rappels) : registre de risques, politique de sécurité, gestion des accès, changements, incidents, continuité, fournisseurs. Prendre aussi un conseiller externe qui signe la revue de direction (compense l'absence de supervision interne).
3. **Semaines 10–16 — rapport Type I** avec un petit cabinet CPA : photographie des contrôles. C'est un jalon commercial utile, pas la fin.
4. **Mois 4 à 10+ — période d'observation, puis Type II** : 3 à 12 mois (6 mois courant). Délai jusqu'au premier Type II : **9 à 15 mois** depuis le démarrage (estimation de l'auteur à partir des délais publiés).
5. **Test d'intrusion externe** : pas exigé par les critères, mais attendu par les auditeurs et les acheteurs ; à faire **avant** le Type I (les résultats alimentent CC7.1).

## 4. Coûts et sources (consultées le 2026-10-07)

Les prix des plateformes sont presque toujours **sur devis** ; les chiffres ci-dessous sont des fourchettes publiées par des tiers, en **USD**, à confirmer par devis. Aucune conversion en CHF n'est faite ici (taux non vérifié).

| Poste | Fourchette publiée | Source (date de la page) |
|---|---|---|
| Honoraires d'audit **Type I** | PME : 7 500 – 15 000 $ ; grandes organisations : 20 000 – 60 000 $ | Drata, [soc-2-audit-cost](https://drata.com/blog/soc-2-audit-cost) (publié le 25 mars 2026) |
| Honoraires d'audit **Type II** | PME : 12 000 – 20 000 $ ; grandes organisations : 30 000 – 100 000 $+ | Drata, même page |
| Type I « tout compris » / Type II (cabinets boutique) | 15 000 – 40 000 $ / 30 000 – 80 000 $ | Scrut, [cost-of-soc-2-audit](https://www.scrut.io/post/cost-of-soc-2-audit) (mise à jour le 5 août 2026) |
| Plateforme d'automatisation (annuel) | 10 000 – 30 000 $ (Scrut) ; points d'entrée estimés par un tiers : Vanta ≈ 10 000 $, Drata ≈ 7 500 $, Secureframe ≈ 7 000 $, Sprinto ≈ 7 000 $, Scytale ≈ 6 000 $, Klaay 149 $/mois | Scrut (même page) ; Klaay, [best-soc-2-tools-for-startups-2026](https://www.klaay.com/blog/best-soc-2-tools-for-startups-2026) (5 mai 2026 — l'auteur précise que ce sont des estimations « possibly outdated ») |
| Prix publics des éditeurs | **Aucun prix affiché** (sur devis) | [vanta.com/pricing](https://www.vanta.com/pricing), [secureframe.com/pricing](https://secureframe.com/pricing) (pages lues le 2026-10-07) |
| Analyse d'écart / mise en œuvre / outils | 5 000 – 25 000 $ ; jusqu'à 30 000 $+ ; 5 000 – 50 000 $+ | Drata (même page) |
| Premier exercice, société SaaS de 50–100 personnes | 50 000 – 110 000 $ avec automatisation ; 78 000 – 170 000 $+ sans | Scrut (même page) — **pas représentatif d'un fondateur seul** |
| Test d'intrusion SaaS | simple 4 999 – 8 999 $ (3–7 jours) ; moyen 8 999 – 20 000 $ | Blaze Infosec, [how-much-does-penetration-testing-cost](https://www.blazeinfosec.com/post/how-much-does-penetration-testing-cost/) (11 mai 2026) |
| Délais | Type I : 1–3 mois ; Type II : 6–12 mois, observation 3–12 mois | Drata (même page) ; Scrut : « 3 à 12 mois, 6 mois recommandé » |

**Ordre de grandeur pour ce dossier** (arithmétique de l'auteur à partir des fourchettes ci-dessus, hors temps du fondateur, **pas un devis**) :

| Scénario | Éléments | Total indicatif (USD) |
|---|---|---|
| Type I seul, la voie la moins chère | plateforme 6 000–10 000 + audit Type I 7 500–15 000 + test d'intrusion 5 000–9 000 | **≈ 18 500 – 34 000** |
| Type I puis Type II (12–15 mois) | ci-dessus + renouvellement plateforme 6 000–10 000 + audit Type II 12 000–20 000 | **≈ 36 500 – 64 000** |
| Avec les fourchettes de Scrut (cabinets boutique) | audit Type I 15 000–40 000 + Type II 30 000–80 000 + plateforme 10 000–30 000 (1 an) | **≈ 55 000 – 150 000** |

Prochain pas utile et gratuit : demander 3 devis (un petit cabinet CPA, un cabinet européen, un via une plateforme) en joignant `SECURITY-OVERVIEW.md` ; les écarts du §2 réduisent d'autant le temps facturé.

## 5. Suisse et UE (à faire valider par un juriste — ce n'est pas un avis juridique)

### 5.1 nLPD (loi fédérale sur la protection des données, en vigueur depuis le 1er septembre 2023)
Texte officiel : [fedlex.admin.ch/eli/cc/2022/491/fr](https://www.fedlex.admin.ch/eli/cc/2022/491/fr) (page chargée par JavaScript, non relue ici). Éléments pertinents pour BK-ENTREPRISE (responsable du traitement) :

| Sujet (article) | Situation constatée dans le dépôt | À faire |
|---|---|---|
| Devoir d'informer (art. 19) | Politique de confidentialité (`confidentialite.html`) : responsable, finalités, sous-traitants, droits | Y ajouter la liste exacte des sous-traitants et des pays (voir §5.3) |
| Registre des activités de traitement (art. 12) | Aucun registre dans le dépôt | Tenir un registre simple (l'exemption pour les petites structures dépend de l'ordonnance et du risque : à vérifier) |
| Sous-traitance (art. 9) | Aucun contrat de sous-traitance signé dans le dépôt | Utiliser les DPA des fournisseurs ; proposer [`DPA-TEMPLATE.md`](DPA-TEMPLATE.md) aux clients qui traitent des données de tiers |
| Communication à l'étranger (art. 16–17) | Anthropic, Stripe, Twilio, Google, Microsoft, Meta : États-Unis possibles | Pour les États-Unis, le Conseil fédéral a reconnu le **Swiss-US Data Privacy Framework** (décision du 14 août 2024, effet au 15 septembre 2024, **limitée aux entreprises certifiées**) : vérifier la certification de chaque fournisseur sur [dataprivacyframework.gov](https://www.dataprivacyframework.gov/list), sinon clauses contractuelles types |
| Analyse d'impact (art. 22) | Aucune | À évaluer : traitement par IA de contenus clients = risque potentiellement élevé |
| Annonce des violations (art. 24) | Aucune procédure | Notifier le PFPDT « dans les meilleurs délais » si risque élevé ; informer les personnes concernées si nécessaire ; **sous-traitant → responsable : sans délai** (source : [prighter.com, art. 24](https://prighter.com/resources/laws/swiss-fadp/fadp/articles/article-24), consulté le 2026-10-07) |
| Droits d'accès, de portabilité (art. 25, 28) | Export JSON et suppression en libre-service ; promesse de réponse sous 30 jours | Documenter la procédure pour les demandes par e-mail |
| Conseiller à la protection des données | Aucun | Facultatif ; à envisager si des clients le demandent |

### 5.2 RGPD (si des clients ou utilisateurs sont dans l'UE — le site est « disponible dans le monde entier »)
- Rôle : BK-ENTREPRISE est **responsable de traitement** pour les comptes et **sous-traitant** pour le contenu que les clients confient aux Workers → DPA de l'article 28 à proposer (modèle en [`DPA-TEMPLATE.md`](DPA-TEMPLATE.md)).
- Représentant dans l'UE (art. 27) si le service cible des personnes de l'UE sans établissement dans l'UE : **à faire valider**.
- Notification de violation à l'autorité sous **72 h** (art. 33) ; registre des traitements (art. 30) ; transferts hors UE/EEE (chap. V) : la Suisse bénéficie d'une décision d'adéquation de la Commission européenne (à re-vérifier avant usage) ; pour les États-Unis, DPF (UE-US) ou clauses types.

### 5.3 Liste de sous-traitants
Voir le tableau de [`SECURITY-OVERVIEW.md`](SECURITY-OVERVIEW.md) §4 (source de vérité alignée sur le code) et la section « Sous-traitants » de la page publique. **Trois actions** : (1) retirer l'adaptateur OpenAI s'il ne doit jamais servir, sinon le déclarer ; (2) rassembler les DPA et les preuves de transfert fournisseur par fournisseur ; (3) nommer le fournisseur SMTP si `BK_SMTP_HOST` est utilisé en production.

## 6. Fuite de données — procédure minimale à écrire (aujourd'hui inexistante)
1. Contenir (révoquer clés/jetons concernés : `OAUTH_*`, `BK_SECRET_*`, clé maître → impose une procédure de rotation qui n'existe pas encore) ; 2. noter l'heure de découverte ; 3. évaluer le risque pour les personnes ; 4. notifier le PFPDT sans délai si risque élevé, et l'autorité de l'UE dans les 72 h si des résidents de l'UE sont concernés ; 5. informer les clients (sous-traitant → responsable : sans délai) ; 6. publier l'incident sur `/status.html` (`deploy/status-incident.py`) ; 7. rédiger l'analyse après coup.

## 7. Sources consultées le 2026-10-07
Drata (soc-2-audit-cost), Scrut (cost-of-soc-2-audit), Klaay (best-soc-2-tools-for-startups-2026), pages tarifs Vanta et Secureframe (sans prix), Blaze Infosec (coût d'un test d'intrusion), OVHcloud ([us.ovhcloud.com/enterprise/certification-conformity](https://us.ovhcloud.com/enterprise/certification-conformity/)), PFPDT/Fedlex/PRIGHTER (nLPD), AICPA ([page SOC](https://www.aicpa-cima.com/resources/landing/system-and-organization-controls-soc-suite-of-services) : liste des cinq catégories de critères ; la page ne détaille ni Type I/II ni le caractère obligatoire de « Security » — ces deux points viennent des guides cités ci-dessus et de la pratique courante, **à confirmer avec l'auditeur**).
Les chiffres sont ceux publiés par ces tiers à ces dates ; ils peuvent avoir changé.
