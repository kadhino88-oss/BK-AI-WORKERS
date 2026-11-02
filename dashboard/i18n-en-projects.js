/* Dictionnaire FR -> EN : interface des projets (project_ui.js). Chaque cle est le texte francais exact
   passe a T() / TF() ; les valeurs inserees ({n}, {w}...) restent entre accolades. Les textes qui viennent du serveur, d'un Worker ou du
   client (objectifs, resumes, contenu des actions) ne sont jamais traduits (data-no-i18n). Verifie par tests/projects-ui/test_i18n.js. */
Object.assign(window.BK_EN, {
  /* Page et navigation */
  "Projets": "Projects", "Mes projets": "My projects", "Nouveau projet": "New project", "Lancer un projet": "Start a project",
  "Un objectif complet, un plan que vous validez, des Workers qui vont jusqu'au bout et un contrôle qualité qui vérifie chaque critère. Rien n'est envoyé, publié ni payé sans votre validation.":
    "A complete goal, a plan you approve, Workers who see it through to the end and a quality check that verifies every criterion. Nothing is sent, published or paid without your approval.",
  "Connectez-vous pour voir et lancer vos projets.": "Sign in to see and start your projects.", "Se connecter": "Sign in",
  "Projets : {n} élément(s) attendent votre action": "Projects: {n} item(s) are waiting for your action",
  "Tous": "All", "À traiter": "To do", "En cours": "In progress", "Terminés": "Finished", "Filtrer les projets": "Filter projects",
  "Aucun projet dans ce filtre.": "No project in this filter.", "Aucun projet pour le moment.": "No project yet.",
  "Un projet, c'est un objectif complet (un site vitrine, une liste de prospects qualifiés, une campagne publicitaire prête à importer, un audit SEO...). Chloé ou le Worker prépare un plan avec des critères d'acceptation et une estimation ; vous le validez, l'équipe va jusqu'au bout, un contrôle qualité vérifie chaque critère, et rien ne part vers l'extérieur sans votre validation.":
    "A project is a complete goal (a showcase website, a list of qualified prospects, an ad campaign ready to import, an SEO audit...). Chloé or the Worker prepares a plan with acceptance criteria and an estimate; you approve it, the team sees it through, a quality check verifies every criterion, and nothing goes outside without your approval.",
  "Étape en cours :": "Current step:", "Avancement": "Progress", "crédits": "credits", "{n} à traiter": "{n} to handle",
  "Chargement du projet…": "Loading the project…", "Projet introuvable.": "Project not found.", "← Tous les projets": "← All projects",
  "Sections du projet": "Project sections", "Budget et quota": "Budget and quota", "Fermer": "Close",
  "Une erreur est survenue, réessayez.": "An error occurred, please try again.", "Connexion impossible : vérifiez votre réseau et réessayez.": "Connection failed: check your network and try again.",
  "Réponse invalide du serveur, réessayez.": "Invalid response from the server, please try again.",
  "Voir les forfaits": "See plans", "Voir les Workers et embaucher": "See the Workers and hire", "Patientez un instant avant de réessayer.": "Wait a moment before trying again.",

  /* Statuts du projet */
  "Plan en préparation": "Plan being prepared", "En file d'attente": "Queued", "Validation requise": "Approval required",
  "Votre réponse est attendue": "Your answer is needed", "En pause : quota atteint": "Paused: quota reached", "Contrôle qualité": "Quality check",
  "En pause": "Paused", "Plafond de crédits atteint": "Credit cap reached", "Terminé": "Finished", "Échec": "Failed", "Annulé": "Cancelled",
  "Plan à valider": "Plan to approve", "Critères non atteints": "Criteria not met", "Outil à connecter": "Tool to connect", "Validation expirée": "Approval expired",
  "Questions en attente": "Questions waiting", "Suspendu par l'administration": "Suspended by the administration",
  "En pause : pas de progrès": "Paused: no progress", "En pause : durée maximale": "Paused: maximum duration reached",
  "Relisez le plan (critères, étapes, estimation) puis validez-le ou demandez des changements. Aucun crédit n'est dépensé avant votre validation, hormis la préparation du plan.":
    "Read the plan (criteria, steps, estimate), then approve it or ask for changes. No credit is spent before you approve, apart from preparing the plan.",
  "Le contrôle qualité a trouvé des critères non atteints après deux corrections. Guidez l'équipe, acceptez le résultat en l'état ou annulez.":
    "The quality check found criteria that are still not met after two fix rounds. Guide the team, accept the result as it is, or cancel.",
  "Une étape a besoin d'un outil qui n'est pas connecté. Connectez-le dans Automatisations & Intégrations, puis relancez l'étape.":
    "A step needs a tool that is not connected. Connect it in Automations & Integrations, then retry the step.",
  "Une action n'a pas été validée à temps (7 jours). Relancez l'étape pour qu'elle soit reproposée, ou annulez le projet.":
    "An action was not approved in time (7 days). Retry the step so it is proposed again, or cancel the project.",
  "L'équipe a besoin de vos réponses pour continuer. Les autres étapes avancent en attendant.": "The team needs your answers to continue. The other steps keep moving in the meantime.",
  "Des actions sont prêtes à partir (envoi, publication, création dans un outil). Rien ne part sans vous : vérifiez le contenu exact, puis validez ou rejetez.":
    "Actions are ready to go (sending, publishing, creating in a tool). Nothing leaves without you: check the exact content, then approve or reject.",
  "Votre quota d'usage est atteint : le projet est en pause, tout son état est conservé. Il reprend tout seul au renouvellement, ou tout de suite si vous passez au forfait supérieur.":
    "Your usage quota is reached: the project is paused and its whole state is kept. It resumes by itself when the quota renews, or right away if you move up to the next plan.",
  "Le plafond de crédits que vous avez fixé pour ce projet est atteint. Relevez le plafond pour terminer, acceptez le résultat en l'état ou annulez.":
    "The credit cap you set for this project is reached. Raise the cap to finish, accept the result as it is, or cancel.",
  "Votre compte est momentanément suspendu par l'administration de la plateforme : rien n'est perdu, contactez-nous.":
    "Your account is temporarily suspended by the platform administration: nothing is lost, please contact us.",
  "Trois étapes de suite n'ont rien fait avancer : l'équipe s'est arrêtée pour ne pas dépenser vos crédits. Précisez votre demande dans Messages, puis reprenez.":
    "Three steps in a row made no progress: the team stopped so as not to spend your credits. Clarify your request in Messages, then resume.",
  "Le projet a atteint la durée maximale de votre forfait. Reprenez-le pour continuer, ou annulez.": "The project reached the maximum duration of your plan. Resume it to continue, or cancel.",
  "Le projet est en pause : aucune nouvelle étape ne démarre. Reprenez quand vous voulez.": "The project is paused: no new step starts. Resume whenever you like.",
  "La planification commence dès qu'une place se libère.": "Planning starts as soon as a slot is free.",
  "Le projet s'est arrêté sur une erreur. Les livrables déjà produits restent disponibles ; vous pouvez relancer une étape en échec.":
    "The project stopped on an error. Deliverables already produced remain available; you can retry a failed step.",

  /* Etapes, criteres, verdicts */
  "À venir": "Upcoming", "Prête": "Ready", "Terminée": "Done", "Partielle": "Partial", "Retirée": "Removed", "Bloquée": "Blocked",
  "attend votre validation": "waiting for your approval", "attend votre réponse": "waiting for your answer",
  "attend le renouvellement du quota": "waiting for the quota to renew", "attend la connexion d'un outil": "waiting for a tool to be connected",
  "Worker en pause dans vos réglages": "Worker paused in your settings", "Worker hors de votre forfait": "Worker not included in your plan",
  "une étape dont elle dépend a échoué": "a step it depends on failed", "une validation a expiré": "an approval expired",
  "Atteint": "Met", "Non atteint": "Not met", "Non vérifiable": "Cannot be verified", "À vérifier": "To verify", "Écart accepté": "Gap accepted",
  "contrôle automatique": "automatic check", "relecture du contrôle qualité": "quality-check review",
  "planification": "planning", "contrôle qualité": "quality check", "correction": "fix", "révision du plan": "plan revision", "rapport final": "final report", "réponse": "answer", "étape": "step",
  "Statut :": "Status:", "après {d}": "after {d}", "{n} livrable(s)": "{n} deliverable(s)", "{n} crédits": "{n} credits", "~{n} crédits estimés": "~{n} credits estimated",
  "{n} essais": "{n} attempts", "Relancer": "Retry", "Note de passation": "Hand-off note", "Hypothèses du plan": "Plan assumptions", "Risques identifiés": "Identified risks",
  "Le plan est en préparation : il apparaîtra ici avec ses critères d'acceptation et ses étapes.": "The plan is being prepared: it will appear here with its acceptance criteria and steps.",
  "Aucun plan pour le moment.": "No plan yet.", "Critères d'acceptation": "Acceptance criteria", "Étapes": "Steps",
  "Le projet n'est terminé que lorsque chaque critère est vérifié avec une preuve par le contrôle qualité indépendant.":
    "The project is only finished once every criterion has been verified, with evidence, by the independent quality check.",
  "Plan et critères": "Plan and criteria", "Chronologie": "Timeline", "Livrables": "Deliverables", "Validations": "Approvals", "Messages": "Messages", "Équipe": "Team",

  /* En-tete et boutons de controle */
  "Chef de projet :": "Project lead:", "Fin estimée dans {n} min environ": "Estimated to finish in about {n} min", "{p} % terminé": "{p} % complete",
  "Mettre en pause": "Pause", "Reprendre": "Resume", "Annuler le projet": "Cancel the project", "Supprimer": "Delete", "Reprendre le projet": "Resume the project",
  "Annuler ce projet ? Les étapes en cours s'arrêtent et les actions non validées sont rejetées. Les livrables déjà produits restent disponibles.":
    "Cancel this project? Running steps stop and unapproved actions are rejected. Deliverables already produced remain available.",
  "Supprimer définitivement ce projet et tous ses fichiers ? Cette action est irréversible.": "Permanently delete this project and all its files? This cannot be undone.",
  "Projet mis en pause.": "Project paused.", "Projet repris.": "Project resumed.", "Projet annulé.": "Project cancelled.", "Projet supprimé.": "Project deleted.",
  "Statut du projet : {s}": "Project status: {s}",

  /* Bandeau « Ce que vous devez faire » */
  "Ce que vous devez faire": "What you need to do", "Projet terminé": "Project finished", "Où en est le projet": "Where the project stands",
  "Voir les {n} action(s) à valider": "See the {n} action(s) to approve", "Connecter un outil": "Connect a tool",
  "Relancer l'étape « {t} »": "Retry the step “{t}”",
  "Estimation :": "Estimate:", "{a} à {b} crédits": "{a} to {b} credits", "{a} à {b} h de travail des Workers": "{a} to {b} h of Workers' work",
  "Plan simplifié : la planification détaillée n'a pas abouti, chaque Worker reçoit une étape. Vous pouvez demander des changements.":
    "Simplified plan: detailed planning did not work out, each Worker gets one step. You can ask for changes.",
  "Ce dont l'équipe a besoin de votre part :": "What the team needs from you:", "Ce que l'équipe ne pourra pas faire dans votre forfait :": "What the team will not be able to do within your plan:",
  "le Worker le plus indiqué, {w}, n'est pas dans votre forfait": "the best-suited Worker, {w}, is not in your plan",
  "Retirer des étapes avant de valider (facultatif)": "Remove steps before approving (optional)",
  "Les critères qui ne dépendent que d'une étape retirée sont retirés aussi, avec une note dans le rapport final.": "Criteria that depend only on a removed step are removed too, with a note in the final report.",
  "Le détail des critères d'acceptation et des étapes est dans l'onglet « Plan et critères » ci-dessous.": "The acceptance criteria and steps are detailed in the “Plan and criteria” tab below.",
  "Plafond de crédits pour ce projet": "Credit cap for this project", "Niveau": "Level", "Standard": "Standard", "Approfondi": "In-depth",
  "Valider le plan et lancer": "Approve the plan and start", "Demander des changements": "Ask for changes", "Ce qu'il faut changer dans le plan": "What to change in the plan",
  "Envoyer mes remarques": "Send my remarks", "Dites en quelques mots ce qu'il faut changer.": "Say in a few words what needs to change.",
  "Plan validé : le travail commence.": "Plan approved: the work begins.", "Vos remarques sont envoyées : le plan est revu.": "Your remarks are sent: the plan is being revised.",
  "bloquant": "blocking", "Votre réponse": "Your answer", "Répondre": "Reply", "Réponse envoyée.": "Answer sent.",
  "Quota {w} atteint.": "{w} quota reached.", "Quota atteint.": "Quota reached.", "de la semaine": "weekly", "de session": "session", "Reprise automatique :": "Automatic resume:",
  "Passer au forfait supérieur": "Move up to the next plan", "Voir mes limites d'usage": "See my usage limits",
  "{u} crédits utilisés sur un plafond de {c}.": "{u} credits used out of a cap of {c}.", "Il faut environ {n} crédits de plus pour terminer.": "About {n} more credits are needed to finish.",
  "Nouveau plafond": "New cap", "Relever le plafond et continuer": "Raise the cap and continue", "Accepter en l'état": "Accept as it is",
  "Plafond mis à jour.": "Cap updated.", "Indiquez un plafond en crédits (6 au moins).": "Enter a credit cap (at least 6).",
  "Guider l'équipe": "Guide the team", "Accepter les écarts": "Accept the gaps",
  "Accepter le projet en l'état ? Les critères non atteints seront notés comme écarts acceptés dans le rapport final.": "Accept the project as it is? Criteria not met will be recorded as accepted gaps in the final report.",
  "Écarts acceptés.": "Gaps accepted.",
  "Tous les critères ont été contrôlés. {n} livrable(s) prêts.": "All criteria have been checked. {n} deliverable(s) ready.", "{n} écart(s) accepté(s) par vous.": "{n} gap(s) accepted by you.",
  "Lire le rapport final": "Read the final report", "Télécharger tous les livrables (.zip)": "Download all deliverables (.zip)", "Voir les livrables": "See the deliverables",
  "Estimation minimale : {a} crédits ; il vous reste {b} crédits ce mois-ci.": "Minimum estimate: {a} credits; you have {b} credits left this month.",
  "Démarrer quand même": "Start anyway", "Étape relancée.": "Step restarted.", "Rapport final": "Final report", "Rapport indisponible pour le moment.": "Report unavailable for now.",
  "Télécharger": "Download", "Lire": "Read", "Aperçu": "Preview",

  /* Chronologie, livrables, equipe */
  "Aucun évènement pour le moment.": "No event yet.", "Les livrables apparaissent ici dès qu'un Worker en produit un.": "Deliverables appear here as soon as a Worker produces one.",
  "Les fichiers de ce projet ont été supprimés à la fin de la durée de conservation (90 jours).": "This project's files were deleted at the end of the retention period (90 days).",
  "Tout télécharger (.zip)": "Download everything (.zip)", "Tout l'espace de travail (.zip)": "Whole workspace (.zip)",
  "L'équipe apparaît ici une fois le plan prêt.": "The team appears here once the plan is ready.",
  "au travail": "working", "bloqué": "blocked", "a terminé": "finished", "en échec": "failed", "en attente": "waiting",
  "{a} étape(s) sur {b}": "{a} step(s) out of {b}", "{n} action(s) à valider": "{n} action(s) to approve",
  "Chloé peut déléguer à {n} Worker(s) de votre forfait ; les autres peuvent être embauchés depuis leur fiche.": "Chloé can delegate to {n} Worker(s) in your plan; the others can be hired from their profile.",

  /* Validations */
  "Chargement des validations…": "Loading approvals…", "Historique ({n})": "History ({n})", "Aucune action en attente de votre décision.": "No action waiting for your decision.",
  "Chaque action ci-dessous est prête mais n'est PAS partie. Vous voyez exactement ce qui sera envoyé, publié ou créé, et vers qui. Vous pouvez modifier un champ avant de valider.":
    "Every action below is ready but has NOT gone out. You see exactly what will be sent, published or created, and to whom. You can edit a field before approving.",
  "En attente de votre décision": "Waiting for your decision", "Validée": "Approved", "En cours d'exécution": "Running", "Exécutée": "Executed", "Échec de l'exécution": "Execution failed",
  "Résultat inconnu : vérifiez dans l'outil": "Result unknown: check in the tool", "Rejetée": "Rejected", "Expirée": "Expired", "Remplacée par une version plus récente": "Replaced by a newer version",
  "Risque faible": "Low risk", "Risque moyen": "Medium risk", "Risque élevé": "High risk", "réversible": "reversible", "irréversible": "irreversible", "modifié": "edited",
  "brouillon validé automatiquement selon vos réglages": "draft approved automatically according to your settings",
  "Contenu exact": "Exact content", "Pourquoi :": "Why:", "Ce qui va se passer :": "What will happen:", "Outil :": "Tool:", "Montant engagé :": "Amount committed:",
  "Destinataires ({n}) :": "Recipients ({n}):", "Lot de {n} actions": "Batch of {n} actions", "Tout sélectionner": "Select all",
  "Trois exemples sont ouverts au hasard ; ouvrez les autres pour les lire.": "Three examples are opened at random; open the others to read them.",
  "Les actions à risque élevé se valident une par une, avec une confirmation écrite.": "High-risk actions are approved one by one, with a written confirmation.",
  "J'autorise": "I authorize", "Action à risque élevé : tapez « {c} » pour confirmer": "High-risk action: type “{c}” to confirm",
  "Tapez « {c} » pour confirmer cette action à risque élevé.": "Type “{c}” to confirm this high-risk action.",
  "Valider avec mes modifications": "Approve with my edits", "Annuler les modifications": "Undo my edits", "Valider la sélection ({n})": "Approve the selection ({n})", "Rejeter la sélection": "Reject the selection",
  "Valider {n} action(s) ? Elles partiront telles qu'affichées.": "Approve {n} action(s)? They will go out exactly as shown.", "Rejeter {n} action(s) ?": "Reject {n} action(s)?",
  "Confirmer le rejet": "Confirm the rejection", "Pourquoi ? (facultatif, transmis au Worker)": "Why? (optional, passed on to the Worker)",
  "Sélectionnez au moins une action (les actions à risque élevé se valident une par une).": "Select at least one action (high-risk actions are approved one by one).",
  "Action validée.": "Action approved.", "Action rejetée.": "Action rejected.", "{n} action(s) traitée(s).": "{n} action(s) handled.",
  "{n} action(s) n'ont pas pu être traitées (déjà décidées, expirées ou à risque élevé).": "{n} action(s) could not be handled (already decided, expired or high-risk).",
  "Nombre attendu.": "A number is expected.", "Oui ou non attendu.": "Yes or no expected.", "Format JSON invalide.": "Invalid JSON format.",

  "Valider": "Approve", "Rejeter": "Reject", "Enregistrer": "Save", "Vous": "You", "Modification": "Change", "modification": "change", "Question": "Question", "question": "question",
  "Renouvellement": "Renewal", "Estimation du plan : {a} à {b} crédits": "Plan estimate: {a} to {b} credits",

  "Sélectionner pour le lot": "Select for the batch", "expire": "expires", "par défaut": "default",
  "Écrivez à l'équipe…": "Write to the team…",
  "Ex. : un site vitrine de 5 pages pour mon cabinet de physiothérapie à Lausanne, en français et en anglais, avec une page de prise de rendez-vous.":
    "E.g. a 5-page showcase website for my physiotherapy practice in Lausanne, in French and English, with an appointment-booking page.",

  /* Messages */
  "Chargement des messages…": "Loading messages…", "Votre message": "Your message", "Type de message": "Message type", "Précision": "Clarification", "précision": "clarification",
  "Une information pour les prochaines étapes, sans changer le plan.": "Information for the next steps, without changing the plan.",
  "Changer ce qui doit être produit : le plan est révisé.": "Change what has to be produced: the plan is revised.",
  "Une réponse rapide de l'équipe, même si le projet est en pause.": "A quick answer from the team, even if the project is paused.",
  "Aucun message pour le moment. Vous pouvez écrire à l'équipe à tout moment.": "No message yet. You can write to the team at any time.",
  "Message envoyé : le plan va être révisé.": "Message sent: the plan will be revised.", "Message envoyé.": "Message sent.",
  "Ce projet est terminé : démarrez un nouveau projet pour une nouvelle demande.": "This project is finished: start a new project for a new request.",
  "{n} / {m} caractères": "{n} / {m} characters", "Chloé": "Chloé", "L'équipe": "The team", "Chloé et l'équipe": "Chloé and the team",

  /* Budget et quota (colonne de droite) */
  "Budget du projet": "Project budget", "Crédits utilisés": "Credits used", "Plafond (crédits)": "Cap (credits)", "Modifier le plafond": "Change the cap",
  "Pour finir : environ {n} crédits": "To finish: about {n} credits", "Votre quota d'usage": "Your usage quota", "Crédits utilisables maintenant : {n}": "Credits usable now: {n}",
  "Limite la plus proche : la semaine.": "Closest limit: the week.", "Limite la plus proche : la session.": "Closest limit: the session.", "Limite la plus proche : le mois.": "Closest limit: the month.",
  "Compte sans limite d'usage.": "Account with no usage limit.", "Voir mes limites et mon forfait": "See my limits and my plan",

  /* Nouveau projet */
  "Nouveau projet avec {w}": "New project with {w}", "Votre objectif": "Your goal", "Partir d'un savoir-faire (facultatif)": "Start from a ready-made know-how (optional)", "Aucun : plan sur mesure": "None: tailor-made plan",
  "Plafond de crédits (facultatif)": "Credit cap (optional)", "Approfondi (plus de vérifications, plus de crédits)": "In-depth (more checks, more credits)",
  "Démarrer sans attendre ma validation du plan": "Start without waiting for my approval of the plan",
  "Joindre des fichiers (facultatif) : textes, tableaux, PDF, images": "Attach files (optional): texts, spreadsheets, PDFs, images",
  "Préparer le plan": "Prepare the plan", "Lancer comme projet": "Start as a project", "Juste une réponse rapide": "Just a quick answer", "Plutôt une mission rapide avec Chloé": "A quick mission with Chloé instead",
  "Demander à Chloé : projet ou simple mission ?": "Ask Chloé: project or simple mission?", "Chloé lit votre demande…": "Chloé is reading your request…",
  "Chloé n'a pas pu analyser la demande : vous pouvez lancer le projet quand même.": "Chloé could not analyse the request: you can still start the project.",
  "Conseil de Chloé : un projet (plusieurs étapes et plusieurs Workers).": "Chloé's advice: a project (several steps and several Workers).",
  "Conseil de Chloé : une mission suffit (une réponse rapide).": "Chloé's advice: a mission is enough (a quick answer).",
  "Conseil de Chloé : une simple réponse suffit, pas besoin de projet.": "Chloé's advice: a simple answer is enough, no project needed.",
  "Projet estimé entre {a} et {b} crédits.": "Project estimated at between {a} and {b} credits.", "hors forfait": "not in your plan", "Workers prévus : {w}": "Planned Workers: {w}",
  "Les Workers hors forfait peuvent être embauchés depuis leur fiche ; sans eux, Chloé adapte le plan et vous dit ce qui manque.": "Workers outside your plan can be hired from their profile; without them, Chloé adapts the plan and tells you what is missing.",
  "Pour un travail complet en plusieurs étapes : {w} prépare un plan avec des critères d'acceptation, va jusqu'au bout et fait vérifier chaque critère.":
    "For a complete job in several steps: {w} prepares a plan with acceptance criteria, sees it through and has every criterion verified.",
  "Pour un travail complet en plusieurs étapes et avec plusieurs Workers : Chloé prépare le plan, répartit le travail, vérifie la cohérence et vous livre le résultat terminé.":
    "For a complete job in several steps and with several Workers: Chloé prepares the plan, shares the work, checks consistency and delivers the finished result.",
  "Chloé lit votre objectif, prépare un plan avec des critères d'acceptation, le répartit entre les Workers de votre forfait et pilote le projet jusqu'au bout. Vous validez le plan avant que le travail commence.":
    "Chloé reads your goal, prepares a plan with acceptance criteria, shares it between the Workers of your plan and leads the project to the end. You approve the plan before the work begins.",
  "{w} prépare un plan avec des critères d'acceptation et va jusqu'au bout. Vous validez le plan avant que le travail commence.": "{w} prepares a plan with acceptance criteria and sees it through. You approve the plan before the work begins.",
  "Seule la préparation du plan consomme quelques crédits. Rien n'est envoyé, publié ni payé sans votre validation.": "Only preparing the plan uses a few credits. Nothing is sent, published or paid without your approval.",
  "Décrivez ce que vous voulez obtenir.": "Describe what you want to get.",
  "Décrivez votre objectif en une phrase au moins : ce qu'il faut produire, pour qui, et ce qui compte pour vous.": "Describe your goal in at least one sentence: what to produce, for whom, and what matters to you.",
  "Projet créé : le plan est en préparation.": "Project created: the plan is being prepared.", "Lecture d'un fichier impossible : réessayez.": "Could not read a file: please try again.",
  "Les fichiers joints dépassent 6 Mo au total : retirez-en ou joignez-les plus tard dans un message.": "The attached files exceed 6 MB in total: remove some or attach them later in a message."
});

/* Fragments : phrases avec valeurs inserees par les controles du formulaire (project_ui.js, pjGoalError / pjInputsError). */
window.BK_EN_FRAG = (window.BK_EN_FRAG || []).concat([
  ["L'objectif est trop long (", "The goal is too long ("], [" caractères au plus).", " characters at most)."],
  ["Au plus ", "At most "], ["Position ", "Position "], [" dans la file : la planification commence dès qu'une place se libère.", " in the queue: planning starts as soon as a slot is free."], [" fichiers par projet.", " files per project."],
  ["Type de fichier non accepté : ", "File type not accepted: "], ["(acceptés : ", "(accepted: "]
]);
