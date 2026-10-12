# Offre « Worker à l'unité » : l'interface (installation, embauche, pause)

Complète `docs/HIRE-API.md` (le serveur). Tout le code de l'interface est dans `dashboard/app.js` entre `// ===== HIRE-UI BEGIN` et `// ===== HIRE-UI END`, avec `dashboard/index.html` (trois emplacements), `dashboard/style.css` (fin du fichier, préfixe `iw-`) et les textes anglais à la fin de `dashboard/i18n-en-app.js`.

## Ce que voit le client

| Où | Quoi |
|---|---|
| Fiche d'un Worker (pas Chloé), bloc « Installer ce Worker » | Worker du forfait : statut de l'installation, services choisis, interrupteur de pause, « Installer / Poursuivre / Modifier l'installation ». Worker hors forfait (Solo, Trio) : « Embaucher ce Worker » (emplacement libre : embauche directe ; sinon remplacement d'un Worker, une fois par 30 jours ; sinon demande à BK Entreprise). Client en essai : « Garder seulement ce Worker après l'essai » (demande d'embauche). Visiteur : invitation à se connecter. |
| Assistant (fenêtre plein écran sous 720 px) | 1 Services, 2 Fiche, 3 Autonomie, 4 Outils, 5 Essai à blanc + activation. Brouillon enregistré à chaque changement d'étape (`POST /api/installations`) ; erreurs du serveur sous les champs concernés ; la saisie n'est jamais perdue (gardée en mémoire si le serveur refuse ou si la session expire). |
| Facturation, « Mes Workers installés » | Une carte par installation (statut, services, dernière modification), interrupteur de pause, résumé des emplacements Solo/Trio et du prochain remplacement possible. |
| Refus d'une mission (403 `WORKER_NOT_INCLUDED`) | Fiche, bulle Chloé, automatisations, parcours « Démarrer » : le texte du serveur + « Embaucher <Worker> » / « Voir mon forfait ». Aussi pour un job asynchrone en erreur `WORKER_NOT_INCLUDED`. |
| Vue propriétaire (Admin) | « Demandes d'embauche de Workers » (message du client échappé) et formulaire « Attribuer » (`POST /api/admin/grant-workers`, le propriétaire coche lui-même que la facture est réglée). Aussi un bouton « Attribuer des Workers » dans chaque compte. |

## Règles que l'interface ne contourne pas

- « Autonome » n'est proposé que pour les actions que le profil classe en risque faible ; la règle « envoyer, publier, payer, supprimer, appeler : toujours votre validation » est affichée à l'étape 3 et dans le récapitulatif d'activation.
- Seuls les canaux réellement disponibles (`liveChannels` et `channelSupport == "available"`) sont envoyés au serveur ; téléphone, WhatsApp et e-mail apparaissent « bientôt ». Aucune promesse de numéro de téléphone, de WhatsApp ou de boîte e-mail pour les propres clients du client.
- Aucun prix pour Solo/Trio (la page Tarifs n'en montre pas) : l'interface ne lit pas `priceChf`, parle de « tarif communiqué avant toute facture » et n'effectue aucun paiement.
- L'essai à blanc est une vraie mission (`submitMissionAndWait`, le chemin de la fiche) : elle compte dans le quota, et l'interface le dit. Les actions vers l'extérieur restent validées par le client.
- Activer, mettre en pause et supprimer sont des gestes du client ; rien n'est activé au chargement. La pause agit tout de suite (voir `docs/HIRE-API.md`, « Interrupteur d'arrêt »).
- Tout texte venant du serveur ou du client passe par `escapeHtml` (vérifié par `tests/hire-ui/test_static.py`). Les descriptions de services, les champs de la fiche et les exemples viennent des profils en français et ne sont pas traduits en anglais.

## Vérifier à la main

```
python tests/hire-ui/dev_server.py --secrets-file <fichier hors du depot>      # copie jetable du dépôt, 127.0.0.1, port libre, aucun secret ni modèle
python tests/hire-ui/owner_call.py --secrets-file <fichier> grant CLI-CUST-XXXXXXXX solo alex    # forfait Solo/Trio (API propriétaire)
```

Le serveur jetable démarre sur une copie : après une modification de `dashboard/`, recopier les fichiers dans la copie (dossier `root` du fichier de secrets). Les comptes de test se créent par `POST /api/account/signup` depuis la page. Deux comptes dans le même navigateur se mélangent (les cookies ne dépendent pas du port) : utiliser des noms d'hôte différents, par exemple `client.localhost:<port>` et `owner.localhost:<port>`.

## Tests

`python tests/hire-ui/run_all.py` : `test_static.py` (routes, identifiants HTML, honnêteté, `escapeHtml`, dictionnaire anglais, petits écrans), `test_payload_contract.py` (la logique de l'assistant, exécutée par node, produit des charges utiles que le vrai validateur `installations.py` accepte pour les 17 profils, et les manques calculés des deux côtés sont identiques), `test_pure_logic.js` (fonctions pures). Aucun appel réseau ni modèle.

## Limites connues

- Aucun point d'entrée pour fermer une demande d'embauche sans attribuer : la liste du propriétaire ne se vide que par une attribution.
- Les profils d'installation sont en français ; en anglais, seul le cadre de l'interface est traduit.
- Pas de prix Stripe pour Solo/Trio : facturation manuelle, attribution par le propriétaire.
