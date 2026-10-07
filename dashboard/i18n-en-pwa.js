/* Dictionnaire FR -> EN : installation de l'application, page hors connexion, page
   "supprimer mon compte". Meme mecanisme que i18n-en*.js (voir i18n.js) : la cle est le
   texte francais exact (espaces normalises), un texte absent reste en francais.
   Ne definit PAS window.BK_EN_HEAD : chaque page (index, offline, suppression) fournit le sien. */
window.BK_EN = Object.assign(window.BK_EN || {}, {
  /* invitation a installer (pwa-install.js) */
  "Installer l'application": "Install the app",
  "Un accès direct depuis votre écran d'accueil, en plein écran.": "A direct shortcut from your home screen, in full screen.",
  "Installer": "Install",
  "Comment faire ?": "How do I do it?",
  "Compris": "Got it",
  "Fermer": "Close",
  "Touchez le bouton Partager, en bas ou en haut de l'écran.": "Tap the Share button, at the bottom or top of the screen.",
  "Faites défiler puis choisissez « Sur l'écran d'accueil ».": "Scroll down, then choose “Add to Home Screen”.",
  "Touchez « Ajouter » : l'icône BK-AI-WORKERS apparaît sur votre écran d'accueil.": "Tap “Add”: the BK-AI-WORKERS icon appears on your home screen.",
  "Application installée ✓": "App installed ✓",

  /* page hors connexion (offline.html) */
  "Vous êtes hors connexion": "You are offline",
  "Aucune connexion Internet. Vérifiez votre Wi-Fi ou vos données mobiles : cette page se rechargera d'elle-même dès que la connexion reviendra.":
    "No Internet connection. Check your Wi-Fi or mobile data: this page will reload by itself as soon as the connection is back.",
  "BK-AI-WORKERS ne répond pas pour le moment. Cette page se rechargera d'elle-même dès que le service sera de nouveau joignable.":
    "BK-AI-WORKERS is not responding right now. This page will reload by itself as soon as the service is reachable again.",
  "Réessayer maintenant": "Try again now",
  "Vérification de la connexion toutes les quelques secondes…": "Checking the connection every few seconds…",
  "Vérification…": "Checking…",
  "Connexion rétablie : rechargement…": "Connection restored: reloading…",
  "Par sécurité, le mode hors connexion ne conserve aucune donnée de votre compte sur cet appareil.":
    "For your security, offline mode keeps no account data on this device.",

  /* page publique "supprimer mon compte" (suppression-compte.html) */
  "Supprimer mon compte et mes données": "Delete my account and data",
  "Vous restez maître de vos données.": "You stay in control of your data.",
  "← Retour à l'accueil": "← Back to home",
  "Comment faire": "How to do it",
  "Connectez-vous à votre compte sur bk-ai-workers.com ou dans l'application installée.": "Sign in to your account on bk-ai-workers.com or in the installed app.",
  "Ouvrez la page « Facturation » depuis le menu.": "Open the “Billing” page from the menu.",
  "Dans la section « Mes données », touchez « Exporter mes données » si vous voulez d'abord garder une copie.":
    "In the “My data” section, tap “Export my data” if you want to keep a copy first.",
  "Touchez « Supprimer mon compte », puis saisissez votre mot de passe pour confirmer.": "Tap “Delete my account”, then enter your password to confirm.",
  "La suppression est définitive : elle ne peut pas être annulée.": "Deletion is permanent: it cannot be undone.",
  "Ce qui est supprimé": "What is deleted",
  "Votre compte et vos connexions ouvertes.": "Your account and your open sessions.",
  "Le profil de votre entreprise.": "Your company profile.",
  "Vos missions et leurs résultats.": "Your missions and their results.",
  "Vos automatisations.": "Your automations.",
  "Les connexions à vos outils (identifiants chiffrés).": "The connections to your tools (encrypted credentials).",
  "Votre clé API et votre webhook, s'ils existent.": "Your API key and webhook, if any.",
  "Le lien avec votre WhatsApp, s'il existe.": "The link with your WhatsApp, if any.",
  "Si vous avez un abonnement": "If you have a subscription",
  "Résiliez d'abord votre abonnement depuis la page « Facturation » : la suppression du compte est refusée tant qu'un abonnement est actif.":
    "Cancel your subscription first from the “Billing” page: account deletion is refused while a subscription is active.",
  "Ce qui peut être conservé": "What may be kept",
  "Certaines pièces de facturation peuvent devoir être conservées pour répondre à des obligations légales (comptabilité : 10 ans). Les paiements sont traités par Stripe ; voir la politique de confidentialité.":
    "Some billing records may have to be kept to meet legal obligations (accounting: 10 years). Payments are processed by Stripe; see the privacy policy.",
  "Les sauvegardes techniques (les nôtres et celles de l'hébergeur) peuvent contenir vos données pendant une durée limitée, jusqu'à leur remplacement automatique.":
    "Technical backups (ours and the host's) may contain your data for a limited time, until they are replaced automatically.",
  "Vous ne pouvez plus vous connecter ?": "Can't sign in any more?",
  "Écrivez-nous depuis l'adresse email de votre compte, nous répondons sous 30 jours :":
    "Write to us from your account's email address; we reply within 30 days:",
  "Politique de confidentialité": "Privacy policy"
});
