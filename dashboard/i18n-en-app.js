/* Dictionnaire FR -> EN : messages dynamiques de l'application (erreurs, statuts,
   tableaux de bord). Les textes avec valeurs inserees passent par BK_EN_FRAG
   (fragments remplaces a l'interieur de la phrase). */
Object.assign(window.BK_EN, {
  "Réponse vide du serveur, réessayez.": "Empty response from the server, please try again.",
  "Réponse invalide du serveur, réessayez.": "Invalid response from the server, please try again.",
  "Mon compte (propriétaire)": "My account (owner)",
  "Missions traitées": "Missions handled", "Workers ayant travaillé": "Workers who worked", "Exécutions automatisées": "Automated runs",
  "Aucune mission traitée pour le moment.": "No mission handled yet.",
  "Appels IA réels": "Real AI calls", "Tokens consommés": "Tokens used", "Coût IA estimé": "Estimated AI cost", "Coût moyen / appel": "Average cost / call",
  "Décris d'abord ton objectif.": "Describe your goal first.",
  "Chloé analyse...": "Chloé is analysing…",
  "Chloé n'a identifié aucun Worker pour cette demande. Essaie de reformuler ton objectif.": "Chloé couldn't identify a Worker for this request. Try rephrasing your goal.",
  "Résultat indisponible": "Result unavailable", "Aucune synthèse disponible.": "No summary available.", "Erreur réseau": "Network error",
  "Inscription": "Sign-up", "Connexion": "Sign-in", "Mission": "Mission", "Abonnement": "Subscription", "Démo": "Demo",
  "Aucune activité pour le moment.": "No activity yet.", "Missions traitées, tous comptes confondus": "Missions handled, all accounts combined",
  "Illimité": "Unlimited", "Crédits": "Credits", "Bloqué": "Blocked", "Exécuté": "Executed", "Aucune réponse enregistrée.": "No answer recorded.",
  "Administrateur — accès illimité": "Administrator — unlimited access",
  "Aucun évènement pour le moment.": "No event yet.",
  "Votre quota est épuisé. Souscrivez un abonnement pour continuer.": "Your quota is used up. Subscribe to a plan to continue.",
  "Votre quota est épuisé.": "Your quota is used up.",
  "Connectez-vous pour voir et gérer vos automatisations.": "Sign in to view and manage your automations.",
  "Aucune automatisation pour le moment — créez-en une ci-dessus.": "No automation yet — create one above.",
  "Voir les résultats": "View results", "Exécuter maintenant": "Run now", "Mettre en pause": "Pause", "Réactiver": "Resume",
  "Aucune exécution pour le moment. Elle se lancera automatiquement à la prochaine échéance, ou cliquez sur « Exécuter maintenant ».": "No run yet. It will start automatically at the next due time, or click “Run now”.",
  "Pas de réponse.": "No answer.", "Aucun détail": "No detail",
  "Décrivez la mission avant de créer l'automatisation.": "Describe the mission before creating the automation.",
  "Voir les abonnements →": "See plans →",
  "🔓 Diffusion réelle possible pour les outils que vous connectez": "🔓 Real sending possible for the tools you connect",
  "🔒 Mode préparation — aucune diffusion réelle n'est jamais effectuée": "🔒 Preparation mode — no real sending is ever performed",
  "Autoriser vos Workers à utiliser cet outil": "Allow your Workers to use this tool",
  "Colle ta clé ou ton jeton ici": "Paste your key or token here",
  "Essai gratuit déjà utilisé sur ce navigateur": "Free trial already used on this browser",
  "Reformulation nécessaire": "Rephrasing needed",
  "Beaucoup de monde teste BK-AI-WORKERS en ce moment — réessayez un peu plus tard, ou inscrivez-vous pour un accès sans limite.": "Lots of people are trying BK-AI-WORKERS right now — try again a little later, or sign up for unlimited access.",
  "Réponse tronquée — inscrivez-vous pour recevoir le livrable complet, sans limite.": "Answer truncated — sign up to receive the full deliverable, with no limit.",
  "🔓 Action réelle préparée — pas encore envoyée": "🔓 Real action prepared — not sent yet",
  "✅ Envoyé avec succès, pour de vrai.": "✅ Sent successfully, for real.",
  "Chloé traite votre mission…": "Chloé is handling your mission…",
  "Partiellement traité": "Partially handled", "Aucun Worker identifié": "No Worker identified",
  "Aucun Worker ne correspond à cette recherche.": "No Worker matches this search.",
  "Orchestratrice — comprend, répartit, vérifie": "Orchestrator — understands, delegates, verifies",
  "Aucune tâche enregistrée pour le moment — confiez une mission ci-dessus pour commencer.": "No task recorded yet — give a mission above to get started.",
  "Aucune demande de démo pour le moment.": "No demo request yet.",
  "Cette action passe par le chat avec Chloé pour vérification.": "This action goes through the chat with Chloé for verification.",
  "Tâche autorisée, en attente de routage vers un Worker.": "Task authorised, waiting to be routed to a Worker.",
  "1. Cliquez ci-dessous : WhatsApp s'ouvre avec le message prêt.": "1. Click below: WhatsApp opens with the message ready.",
  "2. Appuyez sur « Envoyer ». C'est tout.": "2. Press “Send”. That's it.",
  "Délier ce numéro WhatsApp ?": "Unlink this WhatsApp number?",
  "Connectez-vous pour voir votre plan actif, votre consommation et votre historique — ou consultez la page": "Sign in to see your active plan, your usage and your history — or see the"
});

/* Fragments : remplaces a l'interieur d'une phrase contenant des valeurs. */
window.BK_EN_FRAG = [
  ["dernière exécution :", "last run:"], ["prochaine :", "next:"],
  ["pas encore — vérifiée toutes les 15 min, ou cliquez Exécuter maintenant", "not yet — checked every 15 min, or click Run now"],
  ["Toutes les heures", "Every hour"], ["Tous les jours", "Every day"], ["Toutes les semaines", "Every week"], ["Tous les mois", "Every month"],
  ["missions traitées ce cycle — quota illimité (Enterprise).", "missions handled this cycle — unlimited quota (Enterprise)."],
  ["crédits consommés", "credits used"], ["restants", "remaining"], ["crédits / cycle", "credits / cycle"],
  ["Temps estimé évité :", "Estimated time saved:"], ["Coût IA", "AI cost"],
  ["Compte ", "Account "], [" connecté", " connected"], ["vos Workers peuvent maintenant l'utiliser.", "your Workers can now use it."],
  ["La connexion a échoué", "The connection failed"], ["Réessayez.", "Please try again."],
  ["activé(s) pour votre compte", "enabled for your account"],
  ["Dernière mission :", "Latest mission:"], ["autres, un pour chaque métier", "more, one for every profession"],
  ["Erreur serveur", "Server error"], ["réessayez.", "please try again."], ["Erreur réseau :", "Network error:"], ["Erreur :", "Error:"],
  ["Traité par :", "Handled by:"], ["propriétaire", "owner"], ["Chloé propose", "Chloé proposes"], ["cette équipe", "this team"], ["ce Worker", "this Worker"],
  ["pour ta mission :", "for your mission:"], ["Aperçu d'essai gratuit", "Free trial preview"], ["(mode secours)", "(fallback mode)"],
  ["Le paiement n'a pas pu être confirmé :", "The payment couldn't be confirmed:"], ["Lié —", "Linked —"],
  ["connecteurs disponibles.", "connectors available."],
  ["🔓 Diffusion réelle possible pour les outils que vous connectez", "🔓 Real sending possible for the tools you connect"],
  ["🔒 Mode préparation — aucune diffusion réelle n'est jamais effectuée", "🔒 Preparation mode — no real sending is ever performed"]
];

Object.assign(window.BK_EN, {
  "Finance & Contrôle de gestion": "Finance & Management control",
  "Directrice Créative & Design": "Creative & Design Director",
  "Assistant Exécutif & Administratif": "Executive & Administrative Assistant",
  "Responsable IT, Infrastructure & Cybersécurité": "Head of IT, Infrastructure & Cybersecurity",
  "1 à 4 phrases courtes et naturelles par défaut, sauf demande explicite de détail. Répond toujours dans la langue du client. Vouvoiement ou tutoiement selon le client.": "1 to 4 short, natural sentences by default, unless more detail is explicitly requested. Always answers in the customer's language. Formal or informal address depending on the customer."
});

Object.assign(window.BK_EN, {
  "Ce que disent nos clients": "What our customers say", "Témoignages clients": "Customer testimonials",
  "Publiez uniquement de vrais avis, avec l'accord de la personne. La section n'apparaît sur le site qu'à partir du premier témoignage.": "Publish real reviews only, with the person's consent. The section only appears on the site once there is a first testimonial.",
  "Publier": "Publish", "Supprimer": "Delete", "Publié.": "Published.",
  "J'ai l'accord de cette personne pour publier ce témoignage": "I have this person's consent to publish this testimonial"
});

Object.assign(window.BK_EN, {
  "✉️ Confirmez votre email pour pouvoir souscrire un plan : un lien vous a été envoyé à l'inscription.": "✉️ Confirm your email to be able to subscribe to a plan: a link was sent when you signed up.",
  "Renvoyer l'email": "Resend the email",
  "Confirmez d'abord votre email (lien reçu à l'inscription) pour souscrire un plan.": "Please confirm your email first (link received at sign-up) to subscribe to a plan.",
  "Votre email est déjà confirmé.": "Your email is already confirmed.",
  "Email renvoyé — pensez à vérifier vos spams.": "Email sent again — check your spam folder too.",
  "Trop de demandes : réessayez dans un moment.": "Too many requests: try again in a moment.",
  "Email confirmé ✓ — vous pouvez maintenant souscrire un plan.": "Email confirmed ✓ — you can now subscribe to a plan.",
  "Ce lien de confirmation a expiré ou a déjà été utilisé.": "This confirmation link has expired or was already used."
});
