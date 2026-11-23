# Accord de sous-traitance de données personnelles — MODÈLE

> **Modèle de travail, non validé par un juriste.** Il sert de base de discussion avec un client qui demande un DPA (RGPD art. 28 / nLPD art. 9).
> Tout ce qui est entre crochets `[...]` est une **décision du propriétaire** à prendre avant signature : ne rien promettre qui ne soit tenu.
> Les annexes décrivent **ce qui existe réellement** (voir `docs/SECURITY-OVERVIEW.md`). Si une mesure change, l'annexe doit changer.

**Entre**
- **Le Client** : [raison sociale, adresse, représentant] — *responsable du traitement* (« le Responsable »)
- **BK-ENTREPRISE**, entreprise individuelle, Rue Joseph-Pasquier 1, 1203 Genève, Suisse, contact : contact@bk-entreprise.com — *sous-traitant* (« le Sous-traitant »), éditeur de la plateforme BK-AI-WORKERS

## 1. Objet, durée, nature et finalité
1.1 Le Sous-traitant traite des données personnelles **pour le compte du Responsable** afin de fournir la plateforme BK-AI-WORKERS (Chloé et les Workers : préparation de livrables, exécution d'actions validées dans les outils que le Responsable connecte lui-même), conformément aux Conditions générales de vente.
1.2 Durée : celle de l'abonnement, plus la période de restitution/suppression de l'article 9.
1.3 Nature : stockage, consultation, transmission à un modèle d'IA pour produire une réponse, restitution. Finalité : fournir le service demandé, rien d'autre. Le Sous-traitant n'utilise pas ces données pour son propre compte ni pour entraîner un modèle.
*[À confirmer par le propriétaire : engagement de non-réutilisation. Le code ne réutilise pas les missions d'un client pour un autre ; l'entraînement relève du fournisseur de modèle, voir l'annexe 3.]*

## 2. Données et personnes concernées
2.1 Catégories de personnes : utilisateurs du Responsable ; contacts et clients du Responsable dont les données figurent dans les contenus confiés ou dans les outils connectés.
2.2 Catégories de données : identité et coordonnées, contenu des missions et des résultats, données présentes dans les outils connectés (e-mails, agenda, documents, CRM…), profil d'entreprise, journaux techniques (adresse IP, horodatage).
2.3 Le Responsable s'interdit de confier des données sensibles (santé, données bancaires complètes, mots de passe) ; la plateforme n'est pas conçue pour elles (aucune attestation HIPAA, PCI DSS ou HDS).

## 3. Instructions du Responsable
3.1 Le Sous-traitant ne traite les données que sur instruction documentée du Responsable (le contrat, l'usage du service, les actions que le Responsable demande ou valide).
3.2 Il informe le Responsable s'il estime qu'une instruction viole la loi applicable.

## 4. Confidentialité
Le Sous-traitant impose la confidentialité aux personnes autorisées à accéder aux données. *[À remplir : à ce jour, une seule personne — le fondateur — a accès à l'exploitation.]*

## 5. Sécurité
Le Sous-traitant met en œuvre les mesures de l'**annexe 2**, qui décrit l'état réel des mesures **et leurs limites connues**. Il les réexamine au moins [une fois par an].

## 6. Sous-traitants ultérieurs
6.1 Le Responsable donne une **autorisation générale** pour les sous-traitants de l'**annexe 3**. *[Choix du propriétaire : autorisation générale avec préavis, ou autorisation spécifique.]*
6.2 Le Sous-traitant informe le Responsable de tout ajout ou remplacement avec un préavis de [30] jours ; le Responsable peut s'y opposer pour un motif raisonnable ; à défaut d'accord, il peut résilier sans pénalité.
6.3 Le Sous-traitant impose à ses sous-traitants des obligations équivalentes et reste responsable envers le Responsable de leur exécution.
6.4 Les outils tiers que **le Responsable connecte lui-même** (Slack, HubSpot, Google, Microsoft…) ne sont pas des sous-traitants du Sous-traitant : le Responsable reste lié à eux par son propre contrat.

## 7. Transferts internationaux
Des données peuvent être traitées hors de Suisse et de l'UE/EEE (notamment États-Unis, annexe 3). Le Sous-traitant s'assure qu'un mécanisme valable existe pour chaque transfert : décision d'adéquation (dont le Swiss-US et l'EU-US Data Privacy Framework pour les entreprises certifiées) ou clauses contractuelles types. *[À compléter fournisseur par fournisseur après vérification : voir la colonne « Garanties » de `SECURITY-OVERVIEW.md` §4.]*

## 8. Droits des personnes et assistance
8.1 Le Sous-traitant aide le Responsable à répondre aux demandes d'accès, de rectification, d'effacement, de portabilité, d'opposition. Outils fournis : export JSON et suppression du compte en libre-service ; autres demandes à contact@bk-entreprise.com.
8.2 Il aide le Responsable pour les analyses d'impact et les consultations d'autorité, dans la mesure de ses informations.

## 9. Violation de données
9.1 Le Sous-traitant notifie le Responsable **sans délai injustifié et au plus tard dans les [48] heures** après en avoir pris connaissance, avec : nature de la violation, données et personnes concernées (si connues), conséquences probables, mesures prises ou proposées.
*[À décider : le délai. Le RGPD impose au Responsable 72 h pour notifier l'autorité ; la nLPD exige que le sous-traitant annonce « dans les meilleurs délais ». Aucune procédure écrite n'existe encore : voir `SOC2-READINESS.md` §6.]*
9.2 Le Sous-traitant coopère aux notifications à l'autorité (PFPDT, autorité de l'UE compétente) et aux personnes.

## 10. Fin du contrat : restitution et suppression
10.1 Au choix du Responsable, à la fin du service : export de ses données (JSON) puis suppression. La suppression du compte efface le compte, les identifiants d'outils, le profil, les missions, les automatisations, la clé API et le webhook.
10.2 **Exceptions déclarées** : l'historique de facturation est conservé pour les obligations comptables ; le journal d'activité garde ses 1 000 derniers événements ; les sauvegardes déjà faites conservent les données jusqu'à leur expiration ([14] jours selon la procédure d'exploitation). *[À décider : durées écrites et purge du reste.]*

## 11. Audit
Le Sous-traitant met à disposition les informations nécessaires pour démontrer le respect du présent accord et permet des audits raisonnables, annoncés [30] jours à l'avance, aux frais du Responsable, sur la base documentaire d'abord. *[À décider.]* Le Sous-traitant n'a, à ce jour, aucun rapport SOC 2, aucune certification ISO/IEC 27001 ni test d'intrusion externe à fournir (voir la page `/securite.html`).

## 12. Responsabilité, droit applicable
La responsabilité est régie par les Conditions générales de vente (art. 11). Droit suisse ; for à Genève ; pour les personnes soumises au RGPD, les dispositions impératives de ce règlement restent applicables. *[À faire valider par un juriste.]*

---

## Annexe 1 — Détail du traitement
| Élément | Contenu |
|---|---|
| Sujet | Fourniture de la plateforme BK-AI-WORKERS |
| Durée | Durée de l'abonnement + art. 10 |
| Fréquence | Continue, à la demande du Responsable et de ses automatisations |
| Catégories de personnes / de données | Art. 2 |
| Lieu de stockage | Serveur unique chez OVHcloud (France) |
| Contact protection des données du Sous-traitant | contact@bk-entreprise.com |
| Contact protection des données du Responsable | [à remplir] |

## Annexe 2 — Mesures de sécurité (état réel, au 7 octobre 2026)
**En place** : HTTPS (Caddy) ; identifiants d'outils chiffrés au repos en AES-256-GCM, jamais renvoyés au navigateur ; mots de passe hachés PBKDF2-HMAC-SHA256 (600 000 itérations) ; en-têtes de sécurité HTTP (HSTS en HTTPS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy) ; sessions en cookie HttpOnly/SameSite=Lax, empreintes SHA-256 seules sur disque ; espace séparé par client ; limites anti-abus (connexion, inscription, réinitialisation, API) ; contrôle SSRF des formulaires de connexion d'outils ; webhooks Twilio et Meta vérifiés par signature, webhooks sortants signés HMAC-SHA256 ; écritures dans les outils proposées puis confirmées par le client (option de pré-autorisation désactivée par défaut) ; export et suppression en libre-service ; sauvegarde nocturne du volume ([14] jours) ; mesure de disponibilité publique.
**Limites connues, déclarées** : pas de 2FA ni de SSO ; pas de politique CSP ni de jeton anti-CSRF dédié ; URL de webhook sortant non soumise au contrôle SSRF ; missions et profils non chiffrés au niveau applicatif ; clé maîtresse sans HSM ni rotation automatique ; sauvegardes sur le même serveur, non chiffrées, sans test de restauration documenté ; un seul serveur et une seule personne ; conteneur exécuté en root ; aucun SOC 2, aucune ISO/IEC 27001, aucun test d'intrusion externe.
*Source de vérité : `docs/SECURITY-OVERVIEW.md` et la page publique `/securite.html`.*

## Annexe 3 — Sous-traitants ultérieurs
| Sous-traitant | Service | Données | Lieu | Garantie de transfert |
|---|---|---|---|---|
| OVHcloud | Hébergement | Toutes | France | [contrat OVHcloud : à joindre] |
| Anthropic | Modèle d'IA | Contenu des missions, profil, résultats d'outils lus | États-Unis | [DPA + mécanisme : à vérifier] |
| Infomaniak AI Services | Modèle d'IA via API, seulement si choisi par le Sous-traitant | Contenu de mission et profil d'entreprise | Suisse, selon la documentation du fournisseur | [conditions/DPA du produit AI Services : à joindre] |
| SearXNG, DuckDuckGo et Brave Search | Recherche web — seulement si activée | Termes de recherche issus de la mission | Instance SearXNG : OVHcloud (France) ; moteurs externes : lieux selon les conditions des fournisseurs | [conditions des moteurs et garanties contractuelles à vérifier avant le pilote] |
| OpenAI | Modèle de secours — **utilisé seulement si aucune clé Anthropic n'est configurée** | idem | États-Unis | [à vérifier, ou retirer] |
| Stripe | Paiement | E-mail, plan, identifiant client | [à vérifier] | [DPA Stripe] |
| Twilio | Téléphone — **seulement si un numéro est configuré** | Numéro, propos transcrits | États-Unis | [à vérifier] |
| Meta | WhatsApp — **seulement si le Responsable lie WhatsApp** | Numéro, messages | [à vérifier] | [à vérifier] |
| Google / Microsoft | E-mails du service (Gmail si pas de SMTP dédié) / outils connectés par le Responsable | Selon l'outil | [à vérifier] | [DPA] |
| GitHub | Code source et déploiement | Aucune donnée client | — | — |

*Anthropic traite le contenu à titre de sous-traitant selon ses conditions commerciales ; la politique de confidentialité du site indique qu'il n'utilise pas les données d'API pour entraîner ses modèles « selon ses conditions publiées » — à joindre en pièce, le dépôt ne le prouve pas.*
