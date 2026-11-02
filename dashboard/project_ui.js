/* PROJETS (moteur d'autonomie, docs/AUTONOMY-ENGINE.md section 7) : l'interface client.
   Un objectif -> un plan que le client valide (criteres d'acceptation, etapes, Workers, estimation) -> des Workers qui vont jusqu'au bout,
   un controle qualite independant, des livrables a ouvrir et telecharger. Rien ne part vers l'exterieur sans validation : la boite
   « Validations » montre le CONTENU EXACT de chaque action (destinataires, texte, montant) et se valide une par une ou par lot.

   Ce fichier est charge apres app.js et n'ajoute que des crochets d'une ligne dans app.js (window.BKProjects?.xxx). Il lit les globales
   de app.js quand elles existent (escapeHtml, openFilePreview, requireAccount, showView, startUpgrade, usageResetPhrase, workerNameById,
   accountAuthenticated, usageState...) et a un repli sinon. Dormant : tant que GET /api/projects repond 503 (BK_PROJECTS=0), rien ne s'affiche.

   Securite : tout texte venant du serveur, d'un Worker ou du client passe par esc() avant innerHTML ; le contenu des actions a valider,
   les objectifs, resumes et livrables sont marques data-no-i18n (jamais « traduits » donc jamais modifies a l'affichage). */
(function () {
  "use strict";

  // BK-PROJ-PURE-BEGIN (logique pure, testee par tests/projects-ui/test_pure_logic.js : aucun DOM, aucun reseau)
  const PJ_TERMINAL = ["DONE", "FAILED", "CANCELLED"];
  const PJ_ACTIVE = ["PLANNING", "RUNNING", "VERIFYING"];
  const PJ_STATUS = {
    PLANNING: { label: "Plan en préparation", tone: "run" },
    QUEUED: { label: "En file d'attente", tone: "wait" },
    RUNNING: { label: "En cours", tone: "run" },
    WAITING_APPROVAL: { label: "Validation requise", tone: "act" },
    WAITING_INPUT: { label: "Votre réponse est attendue", tone: "act" },
    WAITING_QUOTA: { label: "En pause : quota atteint", tone: "wait" },
    VERIFYING: { label: "Contrôle qualité", tone: "run" },
    PAUSED: { label: "En pause", tone: "wait" },
    BUDGET_REACHED: { label: "Plafond de crédits atteint", tone: "act" },
    DONE: { label: "Terminé", tone: "ok" },
    FAILED: { label: "Échec", tone: "bad" },
    CANCELLED: { label: "Annulé", tone: "off" },
  };
  const PJ_STEP_STATUS = {
    PENDING: { label: "À venir", icon: "○" }, READY: { label: "Prête", icon: "◔" }, RUNNING: { label: "En cours", icon: "◐" },
    DONE: { label: "Terminée", icon: "✓" }, PARTIAL: { label: "Partielle", icon: "◑" }, FAILED: { label: "Échec", icon: "✗" },
    SKIPPED: { label: "Retirée", icon: "–" }, BLOCKED: { label: "Bloquée", icon: "⏸" },
  };
  const PJ_BLOCKED_REASON = {
    APPROVAL: "attend votre validation", INPUT: "attend votre réponse", QUOTA: "attend le renouvellement du quota",
    CONNECTOR: "attend la connexion d'un outil", INSTALLATION_PAUSED: "Worker en pause dans vos réglages",
    WORKER_NOT_INCLUDED: "Worker hors de votre forfait", DEPENDENCY_FAILED: "une étape dont elle dépend a échoué",
    APPROVAL_EXPIRED: "une validation a expiré",
  };
  const PJ_VERDICT = {
    PASS: { label: "Atteint", icon: "✓", tone: "ok" }, FAIL: { label: "Non atteint", icon: "✗", tone: "bad" },
    UNVERIFIABLE: { label: "Non vérifiable", icon: "?", tone: "wait" },
  };
  const PJ_APPROVAL_STATUS = {
    PENDING: "En attente de votre décision", APPROVED: "Validée", EXECUTING: "En cours d'exécution", EXECUTED: "Exécutée",
    FAILED: "Échec de l'exécution", UNKNOWN_CHECK_MANUALLY: "Résultat inconnu : vérifiez dans l'outil", REJECTED: "Rejetée",
    EXPIRED: "Expirée", SUPERSEDED: "Remplacée par une version plus récente",
  };
  const PJ_RISK = { low: "Risque faible", medium: "Risque moyen", high: "Risque élevé" };
  const PJ_CONFIRM_TEXT = "J'autorise";
  const PJ_GOAL_MAX = 4000;
  const PJ_INPUT_EXT = ["txt", "csv", "md", "json", "pdf", "docx", "xlsx", "png", "jpg", "jpeg", "webp", "svg"];
  const PJ_INPUT_MAX_FILES = 10;
  const PJ_INPUT_MAX_BYTES = 6 * 1024 * 1024;          // corps de creation borne a 8 Mo cote serveur : 6 Mo de fichiers bruts une fois en base64
  const PJ_EVENT_ICON = {
    project_created: "✦", plan_ready: "☰", plan_approved: "✓", plan_rejected: "↺", status_changed: "→", step_started: "▶", step_finished: "✓",
    step_failed: "✗", step_retry: "↻", step_cost: "¤", deliverable_added: "📄", approval_created: "✋", approval_decided: "☑", approval_executed: "✓",
    approval_failed: "⚠", input_requested: "?", message_received: "✉", assistant_message: "💬", quota_wait: "⏳", quota_resume: "▶", budget_reached: "¤",
    verification_started: "🔍", verification_result: "🔍", replan: "↺", notification_sent: "✉", done: "★", failed: "✗", cancelled: "■",
  };

  // Ce que le client voit d'un projet : libelle, ton (couleur ET texte, jamais la couleur seule) et ce qu'il doit faire maintenant.
  function pjStatusInfo(p) {
    const s = (p && p.status) || "PLANNING";
    const base = PJ_STATUS[s] || { label: s, tone: "wait" };
    const wf = p && p.waitingFor;
    const out = { status: s, label: base.label, tone: base.tone, action: null, actionKind: null };
    if (s === "WAITING_INPUT") {
      if (wf === "PLAN_VALIDATION") { out.label = "Plan à valider"; out.actionKind = "plan"; out.action = "Relisez le plan (critères, étapes, estimation) puis validez-le ou demandez des changements. Aucun crédit n'est dépensé avant votre validation, hormis la préparation du plan."; }
      else if (wf === "CRITERIA_FAILED") { out.label = "Critères non atteints"; out.actionKind = "criteria"; out.action = "Le contrôle qualité a trouvé des critères non atteints après deux corrections. Guidez l'équipe, acceptez le résultat en l'état ou annulez."; }
      else if (wf === "CONNECTOR") { out.label = "Outil à connecter"; out.actionKind = "connector"; out.action = "Une étape a besoin d'un outil qui n'est pas connecté. Connectez-le dans Automatisations & Intégrations, puis relancez l'étape."; }
      else if (wf === "APPROVAL_EXPIRED") { out.label = "Validation expirée"; out.actionKind = "expired"; out.action = "Une action n'a pas été validée à temps (7 jours). Relancez l'étape pour qu'elle soit reproposée, ou annulez le projet."; }
      else { out.label = "Questions en attente"; out.actionKind = "input"; out.action = "L'équipe a besoin de vos réponses pour continuer. Les autres étapes avancent en attendant."; }
    } else if (s === "WAITING_APPROVAL") {
      out.actionKind = "approval";
      out.action = "Des actions sont prêtes à partir (envoi, publication, création dans un outil). Rien ne part sans vous : vérifiez le contenu exact, puis validez ou rejetez.";
    } else if (s === "WAITING_QUOTA") {
      out.actionKind = "quota";
      out.action = "Votre quota d'usage est atteint : le projet est en pause, tout son état est conservé. Il reprend tout seul au renouvellement, ou tout de suite si vous passez au forfait supérieur.";
    } else if (s === "BUDGET_REACHED") {
      out.actionKind = "budget";
      out.action = "Le plafond de crédits que vous avez fixé pour ce projet est atteint. Relevez le plafond pour terminer, acceptez le résultat en l'état ou annulez.";
    } else if (s === "PAUSED") {
      const r = p && p.statusReason;
      if (r === "OWNER_PAUSED") { out.label = "Suspendu par l'administration"; out.action = "Votre compte est momentanément suspendu par l'administration de la plateforme : rien n'est perdu, contactez-nous."; }
      else if (r === "NO_PROGRESS") { out.label = "En pause : pas de progrès"; out.actionKind = "resume"; out.action = "Trois étapes de suite n'ont rien fait avancer : l'équipe s'est arrêtée pour ne pas dépenser vos crédits. Précisez votre demande dans Messages, puis reprenez."; }
      else if (r === "MAX_DURATION") { out.label = "En pause : durée maximale"; out.actionKind = "resume"; out.action = "Le projet a atteint la durée maximale de votre forfait. Reprenez-le pour continuer, ou annulez."; }
      else { out.actionKind = "resume"; out.action = "Le projet est en pause : aucune nouvelle étape ne démarre. Reprenez quand vous voulez."; }
    } else if (s === "QUEUED") {
      out.action = p && p.queuePosition ? `Position ${Number(p.queuePosition) || 0} dans la file : la planification commence dès qu'une place se libère.` : "La planification commence dès qu'une place se libère.";
    } else if (s === "FAILED") {
      out.actionKind = "failed";
      out.action = "Le projet s'est arrêté sur une erreur. Les livrables déjà produits restent disponibles ; vous pouvez relancer une étape en échec.";
    }
    return out;
  }

  // Nombre de choses qui attendent le client sur ce projet (pastille de la navigation).
  function pjAttention(p) {
    if (!p || PJ_TERMINAL.includes(p.status)) return 0;
    let n = (Number(p.approvalsPending) || 0) + (Number(p.inputsPending) || 0);
    if (p.status === "WAITING_INPUT" && ["PLAN_VALIDATION", "CRITERIA_FAILED", "CONNECTOR", "APPROVAL_EXPIRED"].includes(p.waitingFor)) n += 1;
    if (p.status === "BUDGET_REACHED") n += 1;
    return n;
  }

  function pjBadgeCount(list) {
    return (Array.isArray(list) ? list : []).reduce((a, p) => a + pjAttention(p), 0);
  }

  // Frequence d'interrogation de /progress (contrat 7.4) : 3 s actif, 10 s en attente, 30 s onglet masque, rien si termine.
  function pjPollDelay(status, hidden) {
    if (PJ_TERMINAL.includes(status)) return 0;
    if (hidden) return 30000;
    return PJ_ACTIVE.includes(status) ? 3000 : 10000;
  }

  // Adresse d'un fichier de l'espace de travail : chaque segment encode (jamais de « .. » ni de chemin absolu : le serveur refuse de toute facon).
  function pjFileUrl(pid, path) {
    const segs = String(path || "").split("/").filter((s) => s && s !== "." && s !== "..");
    return `/api/projects/${encodeURIComponent(pid)}/files/` + segs.map(encodeURIComponent).join("/");
  }

  // Les actions a valider regroupees par lot (meme etape, meme outil, meme operation : seule regle d'un lot cote serveur).
  function pjGroupApprovals(items) {
    const groups = [];
    const byId = {};
    (Array.isArray(items) ? items : []).forEach((it) => {
      const key = it.batchId || it.id;
      if (!byId[key]) { byId[key] = { batchId: key, items: [] }; groups.push(byId[key]); }
      byId[key].items.push(it);
    });
    return groups;
  }

  // Identifiants qu'un lot peut reellement valider : en attente, et jamais un risque eleve (confirmation tapee une par une, BATCH_NOT_ALLOWED).
  function pjBatchIds(group, decision, selected) {
    const sel = selected ? new Set(selected) : null;
    return (group && group.items ? group.items : []).filter((it) => it.status === "PENDING" && (!sel || sel.has(it.id))
      && !(decision === "approve" && it.risk === "high")).map((it) => it.id).slice(0, 50);
  }

  // Trois exemples complets tires au hasard dans un lot de plus de 10 actions de risque moyen (contrat 5) ; `rand` injectable pour les tests.
  function pjSampleIds(group, n, rand) {
    const ids = (group && group.items ? group.items : []).map((it) => it.id);
    if (ids.length <= 10) return ids;
    const r = rand || Math.random;
    const pool = ids.slice();
    const out = [];
    while (out.length < (n || 3) && pool.length) out.push(pool.splice(Math.floor(r() * pool.length), 1)[0]);
    return out;
  }

  // Valeur saisie dans un champ modifiable -> valeur du meme type que l'original (texte, nombre, booleen, objet JSON).
  function pjCoerceParam(original, text) {
    if (typeof original === "string" || original === null || original === undefined) return { ok: true, value: String(text) };
    if (typeof original === "number") {
      const n = Number(String(text).trim().replace(",", "."));
      return Number.isFinite(n) ? { ok: true, value: n } : { ok: false, error: "Nombre attendu." };
    }
    if (typeof original === "boolean") {
      const t = String(text).trim().toLowerCase();
      if (["true", "oui", "1", "yes"].includes(t)) return { ok: true, value: true };
      if (["false", "non", "0", "no"].includes(t)) return { ok: true, value: false };
      return { ok: false, error: "Oui ou non attendu." };
    }
    try { return { ok: true, value: JSON.parse(text) }; } catch (e) { return { ok: false, error: "Format JSON invalide." }; }
  }

  function pjParamText(v) {
    if (v === null || v === undefined) return "";
    if (typeof v === "string") return v;
    if (typeof v === "number" || typeof v === "boolean") return String(v);
    try { return JSON.stringify(v, null, 2); } catch (e) { return String(v); }
  }

  // Fusionne de nouveaux evenements (par seq, sans doublon), les plus recents en premier, 300 au plus en memoire.
  function pjMergeEvents(old, incoming) {
    const seen = new Map();
    (old || []).concat(incoming || []).forEach((e) => { if (e && e.seq !== undefined) seen.set(e.seq, e); });
    return [...seen.values()].sort((a, b) => b.seq - a.seq).slice(0, 300);
  }

  // Evenements qui changent ce que montre le detail (plan, etapes, livrables, validations) : on recharge le detail.
  const PJ_RELOAD_EVENTS = ["plan_ready", "plan_approved", "plan_rejected", "status_changed", "step_started", "step_finished", "step_failed", "step_retry",
    "deliverable_added", "approval_created", "approval_decided", "approval_executed", "approval_failed", "input_requested", "quota_wait", "quota_resume",
    "budget_reached", "verification_result", "replan", "done", "failed", "cancelled", "assistant_message"];
  function pjNeedsReload(progress, prev) {
    if (!progress) return false;
    if (progress.reset) return true;
    if (prev && (prev.status !== progress.status || prev.waitingFor !== progress.waitingFor || prev.approvalsPending !== progress.approvalsPending
      || prev.inputsPending !== progress.inputsPending)) return true;
    return (progress.events || []).some((e) => PJ_RELOAD_EVENTS.includes(e.type));
  }

  // Budget du projet : utilise / plafond, niveau d'alerte, credits estimes pour finir.
  function pjBudget(d) {
    const b = (d && d.budget) || {};
    const cap = Number(b.creditsCap != null ? b.creditsCap : d && d.creditsCap) || 0;
    const used = Number(b.creditsCharged != null ? b.creditsCharged : d && d.creditsCharged) || 0;
    const pct = cap > 0 ? Math.min(100, Math.round((100 * used) / cap)) : 0;
    return { cap, used, left: Math.max(0, cap - used), pct, level: pct >= 100 ? "full" : pct >= 80 ? "warn" : "ok",
      toFinish: b.costToFinishCredits != null ? Number(b.costToFinishCredits) : null, estimate: b.estimate || (d && d.plan && d.plan.estimate) || {} };
  }

  // Plafond minimal propose pour finir : ce qui est deja depense + l'estimation pour finir (au moins 6 credits de plus, minStartCredits).
  function pjSuggestedCap(d) {
    const bu = pjBudget(d);
    const extra = Math.max(6, bu.toFinish || 0);
    return Math.max(bu.cap + 6, bu.used + extra);
  }

  // « #projet/PRJ-... » (lien des e-mails de notification, contrat F) -> identifiant, sinon null.
  function pjParseHash(hash) {
    const m = /^#projets?(?:\/(PRJ-[A-F0-9]{32}))?$/.exec(String(hash || ""));
    if (!m) return null;
    return { id: m[1] || null };
  }

  // Objectif d'un nouveau projet : message d'erreur (francais) ou null.
  function pjGoalError(text) {
    const t = String(text || "").trim();
    if (!t) return "Décrivez ce que vous voulez obtenir.";
    if (t.length < 12) return "Décrivez votre objectif en une phrase au moins : ce qu'il faut produire, pour qui, et ce qui compte pour vous.";
    if (t.length > PJ_GOAL_MAX) return `L'objectif est trop long (${PJ_GOAL_MAX} caractères au plus).`;
    return null;
  }

  // Fichiers joints : [{name,size}] -> message d'erreur ou null (memes regles que le serveur, plus la limite du corps de requete).
  function pjInputsError(files) {
    const list = Array.isArray(files) ? files : [];
    if (list.length > PJ_INPUT_MAX_FILES) return `Au plus ${PJ_INPUT_MAX_FILES} fichiers par projet.`;
    let total = 0;
    for (const f of list) {
      const ext = String(f.name || "").split(".").pop().toLowerCase();
      if (!PJ_INPUT_EXT.includes(ext)) return `Type de fichier non accepté : ${f.name} (acceptés : ${PJ_INPUT_EXT.join(", ")}).`;
      total += Number(f.size) || 0;
    }
    if (total > PJ_INPUT_MAX_BYTES) return "Les fichiers joints dépassent 6 Mo au total : retirez-en ou joignez-les plus tard dans un message.";
    return null;
  }

  // Etapes du plan dans l'ordre d'affichage : celles du plan d'abord (ordre du plan), puis les etapes systeme (verification, corrections...).
  function pjStepRows(plan) {
    const steps = (plan && Array.isArray(plan.steps)) ? plan.steps : [];
    return steps.filter((s) => !s.system).concat(steps.filter((s) => s.system && s.kind !== "answer"));
  }

  function pjPercent(p) {
    const v = Number(p && p.percent);
    return Number.isFinite(v) ? Math.max(0, Math.min(100, Math.round(v))) : 0;
  }

  // Liste filtree : « todo » = attend le client, « active » = en cours ou en attente, « done » = termine.
  function pjFilter(list, f) {
    const rows = Array.isArray(list) ? list : [];
    if (f === "todo") return rows.filter((p) => pjAttention(p) > 0);
    if (f === "active") return rows.filter((p) => !PJ_TERMINAL.includes(p.status));
    if (f === "done") return rows.filter((p) => PJ_TERMINAL.includes(p.status));
    return rows;
  }
  // BK-PROJ-PURE-END

  // ------------------------------------------------------------------ outils (globales de app.js avec repli)
  const G = window;
  const T = (s) => (typeof G.bkTr === "function" ? G.bkTr(s) : s);
  const TF = (tpl, vars) => T(tpl).replace(/\{(\w+)\}/g, (m, k) => (vars && vars[k] !== undefined ? vars[k] : m));
  function esc(t) {
    if (typeof escapeHtml === "function") return escapeHtml(t == null ? "" : String(t));   // eslint-disable-line no-undef
    return String(t == null ? "" : t).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
  // Fonctions de app.js (declarations globales : proprietes de window). Les variables « let » de app.js ne sont pas sur window, mais restent
  // visibles par leur nom depuis un autre script classique : lues directement, avec un garde typeof (fichier charge seul dans un test).
  const g = (name) => (typeof G[name] === "function" ? G[name] : undefined);
  /* global accountAuthenticated, usageState, currentWorkerId */
  const isAuth = () => (typeof accountAuthenticated !== "undefined" ? !!accountAuthenticated : false);
  const appUsageState = () => (typeof usageState !== "undefined" ? usageState : null);
  const appCurrentWorker = () => (typeof currentWorkerId !== "undefined" ? currentWorkerId : null);
  const locale = () => (typeof G.BK_LANG === "function" && G.BK_LANG() === "en" ? "en-GB" : "fr-FR");
  const num = (n) => Number(n || 0).toLocaleString(locale());
  const workerName = (id) => {
    if (!id) return "";
    if (id === "qa") return T("Contrôle qualité");
    const fn = g("workerNameById");
    try { return typeof fn === "function" ? fn(id) : id; } catch (e) { return id; }
  };
  // « 1 crédit » / « 12 crédits » (singulier au besoin, dans les deux langues).
  function credLabel(n) { return TF(Number(n) === 1 ? "{n} crédit" : "{n} crédits", { n: num(n) }); }
  function when(iso) {
    const d = new Date(iso);
    if (!iso || isNaN(d)) return "";
    return d.toLocaleString(locale(), { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
  }
  function resetPhrase(iso) {
    const fn = g("usageResetPhrase");
    if (typeof fn === "function") { try { return fn(iso); } catch (e) { /* repli */ } }
    return when(iso);
  }
  function countdownHtml(iso) {
    // data-usage-reset : le compte a rebours de app.js (usageTick) met la duree a jour toutes les 30 s.
    return `<time datetime="${esc(iso)}" data-usage-reset="${esc(iso)}" data-no-i18n="1">${esc(resetPhrase(iso))}</time>`;
  }
  function announce(text) {
    const el = document.getElementById("pj-live");
    if (el) { el.textContent = ""; setTimeout(() => { el.textContent = T(text); }, 30); }
  }

  async function api(method, url, body) {
    const opts = { method, headers: {}, credentials: "same-origin", cache: "no-store" };
    if (body !== undefined) { opts.headers["Content-Type"] = "application/json"; opts.body = JSON.stringify(body); }
    let res;
    try { res = await fetch(url, opts); } catch (e) { return { status: 0, data: { error: "NETWORK", detail: T("Connexion impossible : vérifiez votre réseau et réessayez.") } }; }
    const text = await res.text();
    let data = {};
    if (text) { try { data = JSON.parse(text); } catch (e) { data = { error: "INVALID_RESPONSE", detail: T("Réponse invalide du serveur, réessayez.") }; } }
    return { status: res.status, data, headers: res.headers };
  }

  // Message d'erreur lisible pour une reponse {error, detail} ; les refus de quota et de forfait recoivent les boutons de app.js.
  function errorHtml(r) {
    const d = (r && r.data) || {};
    const code = d.error || "";
    let html = `<p>${esc(d.detail || T("Une erreur est survenue, réessayez."))}</p>`;
    if (code === "USAGE_LIMIT_REACHED" || code === "SUBSCRIPTION_REQUIRED") {
      const extra = g("usageRefusalExtraHtml");
      const cta = g("subscribeCtaHtml");
      if (typeof extra === "function") html += extra(d);
      if (typeof cta === "function") html += cta(d);
    } else if (code === "PROJECT_NOT_IN_PLAN" || code === "PROJECT_LIMIT_REACHED") {
      html += `<div class="pj-row"><button type="button" class="btn btn-gold" data-pj="go-billing">${esc(T("Voir les forfaits"))}</button></div>`;
    } else if (code === "WORKER_NOT_INCLUDED") {
      html += `<div class="pj-row"><button type="button" class="btn btn-gold" data-pj="go-workers">${esc(T("Voir les Workers et embaucher"))}</button></div>`;
    } else if (code === "RATE_LIMITED") {
      html += `<p class="pj-muted">${esc(T("Patientez un instant avant de réessayer."))}</p>`;
    }
    return html;
  }
  function wireError(el, r) {
    const d = (r && r.data) || {};
    const wire = g("wireSubscribeCta");
    if (typeof wire === "function" && (d.error === "USAGE_LIMIT_REACHED" || d.error === "SUBSCRIPTION_REQUIRED")) wire(el, d, closeDialog);
    el.querySelectorAll('[data-pj="go-billing"]').forEach((b) => b.addEventListener("click", () => { closeDialog(); goView("billing"); }));
    el.querySelectorAll('[data-pj="go-workers"]').forEach((b) => b.addEventListener("click", () => { closeDialog(); goView("workers"); }));
  }
  function showError(el, r) {
    if (!el) return;
    el.innerHTML = errorHtml(r);
    el.hidden = false;
    wireError(el, r);
  }
  function goView(name) {
    const fn = g("showView");
    if (typeof fn === "function") fn(name);
  }

  // ------------------------------------------------------------------ etat
  const S = {
    enabled: false, probing: null, list: [], filter: "all", currentId: null, detail: null, events: [], seq: 0, etag: null,
    lastProgress: null, pollTimer: null, listTimer: null, reloadTimer: null, tab: "plan", approvals: null, messages: null,
    selected: {}, editing: {}, dialogReturn: null, pendingHash: null,
  };

  // ------------------------------------------------------------------ disponibilite (dormant tant que BK_PROJECTS=0)
  async function probe() {
    if (!isAuth()) { setEnabled(false); return false; }
    if (S.probing) return S.probing;
    S.probing = (async () => {
      const r = await api("GET", "/api/projects?limit=50");
      S.probing = null;
      if (r.status === 200 && Array.isArray(r.data.projects)) {
        S.list = r.data.projects;
        setEnabled(true);
        renderBadge();
        if (isViewShown() && !S.currentId) renderList();
        return true;
      }
      setEnabled(false);
      return false;
    })();
    return S.probing;
  }

  function setEnabled(on) {
    S.enabled = !!on;
    const nav = document.getElementById("nav-projets");
    if (nav) nav.hidden = !on;
    const block = document.getElementById("pj-launch-block");
    if (block && !on) block.hidden = true;
    clearTimeout(S.listTimer);
    if (on) S.listTimer = setTimeout(refreshList, listDelay());
    if (on && S.pendingHash) { const id = S.pendingHash; S.pendingHash = null; openProject(id); }
  }

  function listDelay() {
    if (document.hidden) return 120000;
    return S.list.some((p) => !PJ_TERMINAL.includes(p.status)) ? 30000 : 120000;
  }

  async function refreshList() {
    clearTimeout(S.listTimer);
    if (!S.enabled || !isAuth()) return;
    const r = await api("GET", "/api/projects?limit=50");
    if (r.status === 200 && Array.isArray(r.data.projects)) {
      S.list = r.data.projects;
      renderBadge();
      if (isViewShown() && !S.currentId) renderList();
    } else if (r.status === 503 || r.status === 401) {
      setEnabled(false);
      return;
    }
    S.listTimer = setTimeout(refreshList, listDelay());
  }

  function renderBadge() {
    const nav = document.getElementById("nav-projets");
    if (!nav) return;
    const n = pjBadgeCount(S.list);
    let badge = nav.querySelector(".pj-nav-badge");
    if (n > 0) {
      if (!badge) { badge = document.createElement("span"); badge.className = "pj-nav-badge"; badge.setAttribute("data-no-i18n", "1"); nav.appendChild(badge); }
      badge.textContent = n > 99 ? "99+" : String(n);
      nav.setAttribute("aria-label", TF("Projets : {n} élément(s) attendent votre action", { n }));
    } else {
      if (badge) badge.remove();
      nav.removeAttribute("aria-label");
    }
  }

  // ------------------------------------------------------------------ vue « Projets »
  function view() { return document.getElementById("projets-view"); }
  function root() { return document.getElementById("pj-root"); }
  function isViewShown() { const v = view(); return !!v && !v.hidden; }

  function onShowView(name) {
    const v = view();
    if (!v) return;
    v.hidden = name !== "projets";
    if (name !== "projets") {
      stopPolling();
      if (/^#projets?/.test(location.hash)) history.replaceState(null, "", location.pathname + location.search);
      return;
    }
    if (!isAuth()) {
      root().innerHTML = `<div class="pj-empty"><p>${esc(T("Connectez-vous pour voir et lancer vos projets."))}</p>
        <button type="button" class="btn btn-gold" data-pj="login">${esc(T("Se connecter"))}</button></div>`;
      root().querySelector('[data-pj="login"]').addEventListener("click", () => { const ra = g("requireAccount"); if (ra) ra(() => goView("projets")); });
      return;
    }
    if (S.currentId) { renderDetail(); loadDetail(); startPolling(); }
    else { renderList(); refreshList(); }
  }

  function showList() {
    S.currentId = null; S.detail = null; S.events = []; S.seq = 0; S.etag = null; S.approvals = null; S.messages = null;
    stopPolling();
    history.replaceState(null, "", location.pathname + location.search + "#projets");
    goView("projets");
  }

  function openProject(id) {
    if (!S.enabled) { S.pendingHash = id; return; }
    if (S.currentId !== id) {
      S.currentId = id; S.detail = null; S.events = []; S.seq = 0; S.etag = null; S.approvals = null; S.messages = null; S.tab = "plan";
      S.selected = {}; S.editing = {};
    }
    history.replaceState(null, "", location.pathname + location.search + "#projet/" + id);
    goView("projets");
  }

  const FILTERS = [["all", "Tous"], ["todo", "À traiter"], ["active", "En cours"], ["done", "Terminés"]];

  function renderList() {
    const el = root();
    if (!el) return;
    const rows = pjFilter(S.list, S.filter);
    const todo = pjBadgeCount(S.list);
    const chips = FILTERS.map(([id, label]) => `<button type="button" class="pj-chip${S.filter === id ? " active" : ""}" aria-pressed="${S.filter === id}" data-filter="${id}">${esc(T(label))}${id === "todo" && todo ? ` <span class="pj-count" data-no-i18n="1">${todo}</span>` : ""}</button>`).join("");
    const cards = rows.map(cardHtml).join("");
    el.innerHTML = `<div class="pj-toolbar">
        <div class="pj-chips" role="group" aria-label="${esc(T("Filtrer les projets"))}">${chips}</div>
        <button type="button" class="btn btn-gold" data-pj="new">${esc(T("Nouveau projet"))}</button>
      </div>
      ${rows.length ? `<ul class="pj-cards">${cards}</ul>` : `<div class="pj-empty">
        <h2>${esc(T(S.list.length ? "Aucun projet dans ce filtre." : "Aucun projet pour le moment."))}</h2>
        <p>${esc(T("Un projet, c'est un objectif complet (un site vitrine, une liste de prospects qualifiés, une campagne publicitaire prête à importer, un audit SEO...). Chloé ou le Worker prépare un plan avec des critères d'acceptation et une estimation ; vous le validez, l'équipe va jusqu'au bout, un contrôle qualité vérifie chaque critère, et rien ne part vers l'extérieur sans votre validation."))}</p>
      </div>`}`;
    el.querySelectorAll(".pj-chip").forEach((b) => b.addEventListener("click", () => { S.filter = b.dataset.filter; renderList(); }));
    el.querySelector('[data-pj="new"]').addEventListener("click", (e) => openNewProject({ workerId: "chloe", returnTo: e.currentTarget }));
    el.querySelectorAll("[data-open]").forEach((b) => b.addEventListener("click", () => openProject(b.dataset.open)));
  }

  function statusPill(p) {
    const info = pjStatusInfo(p);
    return `<span class="pj-pill" data-tone="${info.tone}">${esc(T(info.label))}</span>`;
  }

  function cardHtml(p) {
    const att = pjAttention(p);
    const pct = pjPercent(p);
    const workers = (p.workers || []).slice(0, 6).map((w) => `<img class="pj-avatar" src="/portraits/${encodeURIComponent(w)}.jpg" alt="${esc(workerName(w))}" title="${esc(workerName(w))}" loading="lazy">`).join("");
    const step = p.currentStep ? `<div class="pj-card-step"><span>${esc(T("Étape en cours :"))}</span> <span data-no-i18n="1">${esc(p.currentStep.title || "")}</span> · ${esc(workerName(p.currentStep.worker))}</div>` : "";
    return `<li class="pj-card${att ? " pj-card-att" : ""}">
      <button type="button" class="pj-card-btn" data-open="${esc(p.projectId)}">
        <div class="pj-card-head"><strong class="pj-card-title" data-no-i18n="1">${esc(p.title || p.goal || p.projectId)}</strong>${statusPill(p)}</div>
        <div class="pj-card-goal" data-no-i18n="1">${esc(p.goal || "")}</div>
        <div class="pj-progress" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${pct}" aria-label="${esc(T("Avancement"))}"><div style="width:${pct}%"></div></div>
        ${step}
        <div class="pj-card-foot"><span class="pj-avatars">${workers}</span>
          <span class="pj-card-meta">${pct} % · ${num(p.creditsCharged)} / ${num(p.creditsCap)} ${esc(T("crédits"))}</span>
          ${att ? `<span class="pj-att">${esc(TF("{n} à traiter", { n: att }))}</span>` : ""}</div>
      </button></li>`;
  }

  // ------------------------------------------------------------------ detail
  async function loadDetail() {
    const id = S.currentId;
    if (!id) return;
    const r = await api("GET", `/api/projects/${id}`);
    if (id !== S.currentId) return;
    if (r.status !== 200) {
      if (r.status === 404) { root().innerHTML = `<div class="pj-empty"><p>${esc(T("Projet introuvable."))}</p><button type="button" class="btn btn-ghost" data-pj="back">${esc(T("← Tous les projets"))}</button></div>`; root().querySelector('[data-pj="back"]').addEventListener("click", showList); stopPolling(); return; }
      if (r.status === 503 || r.status === 401) { setEnabled(false); goView("home"); return; }
      return;    // erreur passagere : l'interrogation suivante reessaiera
    }
    const prevStatus = S.detail && S.detail.status;
    S.detail = r.data;
    S.events = pjMergeEvents(S.events, r.data.events || []);
    S.seq = Math.max(S.seq, ...(r.data.events || []).map((e) => e.seq || 0), 0);
    if (prevStatus && prevStatus !== r.data.status) announce(TF("Statut du projet : {s}", { s: T(pjStatusInfo(r.data).label) }));
    const idx = S.list.findIndex((p) => p.projectId === id);
    if (idx >= 0) { S.list[idx] = Object.assign({}, S.list[idx], pickSummary(r.data)); renderBadge(); }
    if (S.tab === "approvals" || (r.data.approvalsPending || 0) > 0) loadApprovals();
    if (S.tab === "messages") loadMessages();
    renderDetail();
  }

  function pickSummary(d) {
    const keys = ["projectId", "title", "goal", "status", "waitingFor", "statusReason", "leadWorker", "workers", "percent", "currentStep", "createdUtc", "updatedUtc",
      "creditsCharged", "creditsCap", "approvalsPending", "inputsPending", "resumeAtUtc", "queuePosition"];
    const o = {};
    keys.forEach((k) => { if (d[k] !== undefined) o[k] = d[k]; });
    if (Array.isArray(d.workers) && d.workers.length && typeof d.workers[0] === "object") o.workers = d.workers.map((w) => w.id);
    return o;
  }

  function scheduleReload(ms) {
    clearTimeout(S.reloadTimer);
    S.reloadTimer = setTimeout(loadDetail, ms || 600);
  }

  function startPolling() {
    stopPolling();
    const tick = async () => {
      if (!S.currentId || !isViewShown()) return;
      const id = S.currentId;
      const headers = {};
      if (S.etag) headers["If-None-Match"] = S.etag;
      let res;
      try { res = await fetch(`/api/projects/${id}/progress?since=${S.seq}`, { headers, credentials: "same-origin", cache: "no-store" }); } catch (e) { res = null; }
      if (id !== S.currentId) return;
      if (res && res.status === 200) {
        S.etag = res.headers.get("ETag");
        let p = null;
        try { p = await res.json(); } catch (e) { p = null; }
        if (p) {
          const prev = S.lastProgress;
          S.lastProgress = p;
          if (p.events && p.events.length) { S.events = pjMergeEvents(S.events, p.events); S.seq = Math.max(S.seq, ...p.events.map((e) => e.seq || 0)); }
          if (p.reset) { S.seq = p.seq || 0; S.events = []; }
          if (S.detail) Object.assign(S.detail, { status: p.status, waitingFor: p.waitingFor, statusReason: p.statusReason, percent: p.percent, currentStep: p.currentStep,
            queuePosition: p.queuePosition, resumeAtUtc: p.resumeAtUtc, approvalsPending: p.approvalsPending, inputsPending: p.inputsPending,
            creditsCharged: p.creditsCharged, creditsCap: p.creditsCap, etaMinutes: p.etaMinutes });
          if (S.detail && S.detail.budget) { S.detail.budget.creditsCharged = p.creditsCharged; S.detail.budget.creditsCap = p.creditsCap; }
          if (pjNeedsReload(p, prev || S.detail)) scheduleReload(500); else renderHeaderOnly();
        }
      } else if (res && (res.status === 404 || res.status === 503 || res.status === 401)) {
        loadDetail();
        return;
      }
      const delay = pjPollDelay((S.detail && S.detail.status) || "RUNNING", document.hidden);
      if (delay) S.pollTimer = setTimeout(tick, delay);
    };
    S.pollTimer = setTimeout(tick, 1500);
  }
  function stopPolling() { clearTimeout(S.pollTimer); clearTimeout(S.reloadTimer); S.pollTimer = null; }

  // Une zone n'est pas redessinee pendant que le client y ecrit (brouillon de message, modification d'une action, reponse a une question).
  function busy(el) {
    if (!el) return false;
    if (el.querySelector("[data-dirty='1']")) return true;
    const a = document.activeElement;
    return !!(a && el.contains(a) && /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName));
  }
  function setHtml(el, html) {
    if (!el || busy(el)) return false;
    el.innerHTML = html;
    return true;
  }
  function markDirty(el) {
    el.addEventListener("input", (e) => { if (e.target && /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName)) e.target.dataset.dirty = "1"; });
  }

  const TABS = [["plan", "Plan et critères"], ["timeline", "Chronologie"], ["deliverables", "Livrables"], ["approvals", "Validations"], ["messages", "Messages"], ["team", "Équipe"]];

  function renderDetail() {
    const el = root();
    if (!el) return;
    const d = S.detail;
    if (!d) {
      el.innerHTML = `<div class="pj-loading">${esc(T("Chargement du projet…"))}</div>`;
      return;
    }
    if (!el.querySelector(".pj-detail") || el.querySelector(".pj-detail").dataset.pid !== d.projectId) {
      el.innerHTML = `<div class="pj-detail" data-pid="${esc(d.projectId)}">
        <button type="button" class="back-btn pj-back" data-pj="back">${esc(T("← Tous les projets"))}</button>
        <div class="pj-head" id="pj-head"></div>
        <div class="pj-next" id="pj-next"></div>
        <div class="pj-layout">
          <div class="pj-main">
            <div class="pj-tabs" role="tablist" aria-label="${esc(T("Sections du projet"))}"></div>
            <div class="pj-panel" id="pj-panel" role="tabpanel" tabindex="0"></div>
          </div>
          <aside class="pj-side" id="pj-side" aria-label="${esc(T("Budget et quota"))}"></aside>
        </div></div>`;
      el.querySelector('[data-pj="back"]').addEventListener("click", showList);
      markDirty(el);
    }
    renderHeaderOnly();
    renderNext();
    renderTabs();
    renderPanel();
    renderSide();
  }

  function renderHeaderOnly() {
    const d = S.detail;
    const head = document.getElementById("pj-head");
    if (!d || !head) return;
    const info = pjStatusInfo(d);
    const pct = pjPercent(d);
    const caps = d.capabilities || {};
    const lead = d.leadWorker;
    const step = d.currentStep ? `<p class="pj-current"><span class="pj-spin" aria-hidden="true"></span> <span>${esc(T("Étape en cours :"))}</span> <strong data-no-i18n="1">${esc(d.currentStep.title || "")}</strong> · ${esc(workerName(d.currentStep.worker))}</p>` : "";
    const eta = d.etaMinutes && !PJ_TERMINAL.includes(d.status) ? `<span>${esc(TF("Fin estimée dans {n} min environ", { n: num(d.etaMinutes) }))}</span>` : "";
    const btns = [];
    if (caps.canPause) btns.push(`<button type="button" class="btn btn-ghost" data-act="pause">${esc(T("Mettre en pause"))}</button>`);
    if (caps.canResume) btns.push(`<button type="button" class="btn btn-gold" data-act="resume">${esc(T("Reprendre"))}</button>`);
    if (caps.canCancel) btns.push(`<button type="button" class="btn btn-ghost pj-danger" data-act="cancel">${esc(T("Annuler le projet"))}</button>`);
    if (caps.canDelete) btns.push(`<button type="button" class="btn btn-ghost pj-danger" data-act="delete">${esc(T("Supprimer"))}</button>`);
    head.innerHTML = `<div class="pj-head-top">
        ${lead ? `<img class="pj-lead" src="/portraits/${encodeURIComponent(lead)}.jpg" alt="" aria-hidden="true">` : ""}
        <div class="pj-head-text">
          <h2 class="pj-title" data-no-i18n="1">${esc(d.title || d.projectId)}</h2>
          <p class="pj-goal" data-no-i18n="1">${esc(d.goal || "")}</p>
          <p class="pj-meta">${statusPill(d)} <span>${esc(T("Chef de projet :"))} ${esc(workerName(lead))}</span> ${eta}</p>
        </div></div>
      <div class="pj-progress pj-progress-lg" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${pct}" aria-valuetext="${esc(TF("{p} % terminé", { p: pct }))}" aria-label="${esc(T("Avancement"))}"><div style="width:${pct}%"></div></div>
      <div class="pj-head-row"><span class="pj-pct">${esc(TF("{p} % terminé", { p: pct }))}</span>${step}</div>
      ${btns.length ? `<div class="pj-controls">${btns.join("")}</div>` : ""}`;
    head.querySelectorAll("[data-act]").forEach((b) => b.addEventListener("click", () => control(b.dataset.act, b)));
    if (info.status !== (S._lastStatusDrawn || "")) { S._lastStatusDrawn = info.status; renderNext(); renderSide(); renderTabs(); }
  }

  async function control(act, btn) {
    const id = S.currentId;
    if (act === "cancel" && !confirm(T("Annuler ce projet ? Les étapes en cours s'arrêtent et les actions non validées sont rejetées. Les livrables déjà produits restent disponibles."))) return;
    if (act === "delete" && !confirm(T("Supprimer définitivement ce projet et tous ses fichiers ? Cette action est irréversible."))) return;
    btn.disabled = true;
    const r = act === "delete" ? await api("DELETE", `/api/projects/${id}?confirm=1`) : await api("POST", `/api/projects/${id}/${act}`, {});
    btn.disabled = false;
    if (r.status >= 200 && r.status < 300) {
      announce({ pause: "Projet mis en pause.", resume: "Projet repris.", cancel: "Projet annulé.", delete: "Projet supprimé." }[act]);
      if (act === "delete") { S.list = S.list.filter((p) => p.projectId !== id); showList(); return; }
      loadDetail(); startPolling();
    } else {
      toast(r);
    }
  }

  function toast(r) {
    const next = document.getElementById("pj-next") || root();
    const box = document.createElement("div");
    box.className = "pj-alert";
    box.setAttribute("role", "alert");
    box.innerHTML = errorHtml(r) + `<button type="button" class="pj-x" aria-label="${esc(T("Fermer"))}">×</button>`;
    wireError(box, r);
    box.querySelector(".pj-x").addEventListener("click", () => box.remove());
    next.prepend(box);
  }

  // Le bandeau « Ce que vous devez faire » : un texte clair et les gestes possibles, selon l'etat.
  function renderNext() {
    const el = document.getElementById("pj-next");
    const d = S.detail;
    if (!el || !d) return;
    const info = pjStatusInfo(d);
    const caps = d.capabilities || {};
    let body = "";
    if (info.actionKind === "plan") body = planValidationHtml(d);
    else if (info.actionKind === "input") body = questionsHtml(d);
    else if (info.actionKind === "approval") body = `<button type="button" class="btn btn-gold" data-go-tab="approvals">${esc(TF("Voir les {n} action(s) à valider", { n: d.approvalsPending || 0 }))}</button>`;
    else if (info.actionKind === "quota") body = quotaHtml(d);
    else if (info.actionKind === "budget") body = budgetReachedHtml(d);
    else if (info.actionKind === "criteria") body = criteriaFailedHtml(d);
    else if (info.actionKind === "connector") body = `<button type="button" class="btn btn-gold" data-pj="go-automations">${esc(T("Connecter un outil"))}</button> ${retryButtonsHtml(d)}`;
    else if (info.actionKind === "expired") body = retryButtonsHtml(d, "BLOCKED");
    else if (info.actionKind === "resume" && caps.canResume) body = `<button type="button" class="btn btn-gold" data-act-next="resume">${esc(T("Reprendre le projet"))}</button>`;
    else if (info.actionKind === "failed") body = retryButtonsHtml(d, "FAILED");
    // Questions ouvertes non bloquantes alors que le projet avance : on les montre aussi.
    if (info.actionKind !== "input" && (d.questions || []).length) body += questionsHtml(d);
    if (d.status === "DONE") body = doneHtml(d);
    const notices = (d.notices || []).concat(d.planNotice ? [d.planNotice] : []).filter(Boolean).slice(-3)
      .map((n) => `<li data-no-i18n="1">${esc(typeof n === "string" ? n : (n.text || n.detail || ""))}</li>`).join("");
    const html = (info.action || body || notices) ? `<section class="pj-next-box" data-tone="${info.tone}" aria-labelledby="pj-next-title">
        <h3 id="pj-next-title">${esc(T(info.actionKind ? "Ce que vous devez faire" : (d.status === "DONE" ? "Projet terminé" : "Où en est le projet")))}</h3>
        ${info.action ? `<p>${esc(T(info.action))}</p>` : ""}
        ${notices ? `<ul class="pj-notices">${notices}</ul>` : ""}
        ${body}
        <div class="pj-form-error" hidden role="alert"></div>
      </section>` : "";
    if (!setHtml(el, html)) return;
    wireNext(el);
  }

  function retryButtonsHtml(d, status) {
    const steps = pjStepRows(d.plan).filter((s) => (status ? s.status === status : (s.status === "FAILED" || s.status === "BLOCKED")));
    if (!steps.length) return "";
    return `<div class="pj-row">${steps.slice(0, 5).map((s) => `<button type="button" class="btn btn-ghost" data-retry="${esc(s.id)}">${esc(TF("Relancer l'étape « {t} »", { t: s.title || s.id }))}</button>`).join("")}</div>`;
  }

  function planValidationHtml(d) {
    const p = d.plan || {};
    const est = p.estimate || {};
    const bu = pjBudget(d);
    const range = (est.creditsMin != null && est.creditsMax != null) ? TF("{a} à {b} crédits", { a: num(est.creditsMin), b: num(est.creditsMax) }) : "";
    const hours = (est.hoursMin != null && est.hoursMax != null) ? TF("{a} à {b} h de travail des Workers", { a: est.hoursMin, b: est.hoursMax }) : "";
    const needs = (p.needsFromClient || []).map((n) => `<li data-no-i18n="1">${esc(typeof n === "string" ? n : (n.text || n.what || JSON.stringify(n)))}</li>`).join("");
    const unassign = (p.unassignable || []).map((u) => `<li><span data-no-i18n="1">${esc(u.capability || "")}</span>${u.bestWorker ? ` — ${esc(TF("le Worker le plus indiqué, {w}, n'est pas dans votre forfait", { w: workerName(u.bestWorker) }))}` : ""}${u.reason ? ` <span class="pj-muted" data-no-i18n="1">(${esc(u.reason)})</span>` : ""}</li>`).join("");
    const steps = pjStepRows(p).filter((s) => !s.system);
    const removable = steps.length > 1 ? `<details class="pj-remove"><summary>${esc(T("Retirer des étapes avant de valider (facultatif)"))}</summary>
        ${steps.map((s) => `<label class="pj-check"><input type="checkbox" name="pj-remove" value="${esc(s.id)}"> <span data-no-i18n="1">${esc(s.title || s.id)}</span> · ${esc(workerName(s.worker))}</label>`).join("")}
        <p class="pj-muted">${esc(T("Les critères qui ne dépendent que d'une étape retirée sont retirés aussi, avec une note dans le rapport final."))}</p></details>` : "";
    return `<div class="pj-plan-summary">
        ${range ? `<p><strong>${esc(T("Estimation :"))}</strong> ${esc(range)}${hours ? ` · ${esc(hours)}` : ""}</p>` : ""}
        ${p.fallback ? `<p class="pj-warn">${esc(T("Plan simplifié : la planification détaillée n'a pas abouti, chaque Worker reçoit une étape. Vous pouvez demander des changements."))}</p>` : ""}
        ${needs ? `<div><strong>${esc(T("Ce dont l'équipe a besoin de votre part :"))}</strong><ul>${needs}</ul></div>` : ""}
        ${unassign ? `<div class="pj-warn"><strong>${esc(T("Ce que l'équipe ne pourra pas faire dans votre forfait :"))}</strong><ul>${unassign}</ul></div>` : ""}
        <p class="pj-muted">${esc(T("Le détail des critères d'acceptation et des étapes est dans l'onglet « Plan et critères » ci-dessous."))}</p>
      </div>
      ${removable}
      <div class="pj-fields">
        <label>${esc(T("Plafond de crédits pour ce projet"))} <input type="number" min="6" step="1" name="pj-cap" value="${esc(bu.cap || "")}" inputmode="numeric"></label>
        <label>${esc(T("Niveau"))} <select name="pj-level"><option value="standard"${d.level !== "approfondi" ? " selected" : ""}>${esc(T("Standard"))}</option><option value="approfondi"${d.level === "approfondi" ? " selected" : ""}>${esc(T("Approfondi"))}</option></select></label>
      </div>
      <div class="pj-row">
        <button type="button" class="btn btn-gold" data-plan="approve">${esc(T("Valider le plan et lancer"))}</button>
        <button type="button" class="btn btn-ghost" data-plan="toggle-reject">${esc(T("Demander des changements"))}</button>
      </div>
      <div class="pj-reject" hidden>
        <label for="pj-reject-text">${esc(T("Ce qu'il faut changer dans le plan"))}</label>
        <textarea id="pj-reject-text" rows="3" maxlength="4000"></textarea>
        <button type="button" class="btn btn-gold" data-plan="reject">${esc(T("Envoyer mes remarques"))}</button>
      </div>
      <div class="pj-exceeds" hidden></div>`;
  }

  function questionsHtml(d) {
    const qs = d.questions || [];
    if (!qs.length) return "";
    return `<div class="pj-questions">${qs.map((q) => {
      const choices = (q.choices || []).map((c) => `<button type="button" class="pj-chip" data-choice="${esc(c)}"><span data-no-i18n="1">${esc(c)}</span></button>`).join("");
      return `<form class="pj-question" data-qid="${esc(q.id)}">
        <p class="pj-q-text"><strong>${esc(workerName(q.worker))}${q.blocking ? ` <span class="pj-pill" data-tone="act">${esc(T("bloquant"))}</span>` : ""}</strong><br><span data-no-i18n="1">${esc(q.question || "")}</span></p>
        ${q.why ? `<p class="pj-muted" data-no-i18n="1">${esc(q.why)}</p>` : ""}
        ${choices ? `<div class="pj-chips">${choices}</div>` : ""}
        <label class="sr-only" for="pj-a-${esc(q.id)}">${esc(T("Votre réponse"))}</label>
        <textarea id="pj-a-${esc(q.id)}" rows="2" maxlength="4000" placeholder="${esc(T("Votre réponse"))}">${esc(q.default || "")}</textarea>
        <button type="submit" class="btn btn-gold">${esc(T("Répondre"))}</button>
      </form>`;
    }).join("")}</div>`;
  }

  function upgradeArg() {
    const u = appUsageState();
    const fn = g("usageUpgradeArg");
    if (u && u.upgrade && typeof fn === "function") return fn(u.upgrade);
    return null;
  }

  function quotaHtml(d) {
    const u = d.usage || {};
    const at = d.resumeAtUtc || u.nextRenewalUtc;
    const msg = u.binding === "week" ? "Quota de la semaine atteint." : u.binding === "session" ? "Quota de session atteint." : "Quota atteint.";
    return `<p class="pj-quota">${esc(T(msg))} ${at ? `<span>${esc(T("Reprise automatique :"))}</span> ${countdownHtml(at)}` : ""}</p>
      <div class="pj-row"><button type="button" class="btn btn-gold" data-pj="upgrade">${esc(T("Passer au forfait supérieur"))}</button>
      <button type="button" class="btn btn-ghost" data-pj="go-billing">${esc(T("Voir mes limites d'usage"))}</button></div>`;
  }

  function budgetReachedHtml(d) {
    const bu = pjBudget(d);
    const sug = pjSuggestedCap(d);
    return `<p>${esc(TF("{u} crédits utilisés sur un plafond de {c}.", { u: num(bu.used), c: num(bu.cap) }))}${bu.toFinish != null ? " " + esc(TF("Il faut environ {n} crédits de plus pour terminer.", { n: num(bu.toFinish) })) : ""}</p>
      <div class="pj-fields"><label>${esc(T("Nouveau plafond"))} <input type="number" min="${bu.cap + 1}" step="1" name="pj-newcap" value="${sug}" inputmode="numeric"></label></div>
      <div class="pj-row"><button type="button" class="btn btn-gold" data-budget="raise">${esc(T("Relever le plafond et continuer"))}</button>
      <button type="button" class="btn btn-ghost" data-gaps="all">${esc(T("Accepter en l'état"))}</button>
      <button type="button" class="btn btn-ghost pj-danger" data-act-next="cancel">${esc(T("Annuler le projet"))}</button></div>`;
  }

  function criteriaFailedHtml(d) {
    const failed = ((d.plan && d.plan.criteria) || []).filter((c) => c.verdict && c.verdict !== "PASS" && !c.accepted);
    return `${failed.length ? `<ul class="pj-crit-failed">${failed.map((c) => `<li><span class="pj-verdict" data-tone="${(PJ_VERDICT[c.verdict] || {}).tone || "wait"}">${esc(T((PJ_VERDICT[c.verdict] || {}).label || c.verdict))}</span> <span data-no-i18n="1">${esc(c.text || c.id)}</span>${c.note ? `<br><span class="pj-muted" data-no-i18n="1">${esc(c.note)}</span>` : ""}</li>`).join("")}</ul>` : ""}
      <div class="pj-row"><button type="button" class="btn btn-gold" data-go-tab="messages" data-msg-type="change">${esc(T("Guider l'équipe"))}</button>
      <button type="button" class="btn btn-ghost" data-gaps="failed">${esc(T("Accepter les écarts"))}</button>
      <button type="button" class="btn btn-ghost pj-danger" data-act-next="cancel">${esc(T("Annuler le projet"))}</button></div>`;
  }

  function doneHtml(d) {
    const gaps = (d.acceptedGaps || []).length;
    const probs = (d.doneProblems || []).map((p) => `<li data-no-i18n="1">${esc(typeof p === "string" ? p : (p.text || p.detail || ""))}</li>`).join("");
    return `<p>${esc(TF("Tous les critères ont été contrôlés. {n} livrable(s) prêts.", { n: (d.deliverables || []).length }))}${gaps ? " " + esc(TF("{n} écart(s) accepté(s) par vous.", { n: gaps })) : ""}</p>
      ${probs ? `<ul class="pj-notices">${probs}</ul>` : ""}
      <div class="pj-row">${d.hasFinalReport ? `<button type="button" class="btn btn-gold" data-pj="report">${esc(T("Lire le rapport final"))}</button>` : ""}
      <a class="btn btn-ghost" href="/api/projects/${esc(d.projectId)}/export.zip?scope=deliverables" download>${esc(T("Télécharger tous les livrables (.zip)"))}</a>
      <button type="button" class="btn btn-ghost" data-go-tab="deliverables">${esc(T("Voir les livrables"))}</button></div>`;
  }

  function wireNext(el) {
    const id = S.currentId;
    const errBox = el.querySelector(".pj-form-error");
    const fail = (r) => showError(errBox, r);
    el.querySelectorAll("[data-go-tab]").forEach((b) => b.addEventListener("click", () => {
      if (b.dataset.msgType) S.msgType = b.dataset.msgType;
      selectTab(b.dataset.goTab, true);
    }));
    el.querySelectorAll("[data-act-next]").forEach((b) => b.addEventListener("click", () => control(b.dataset.actNext, b)));
    el.querySelectorAll("[data-retry]").forEach((b) => b.addEventListener("click", () => retryStep(b.dataset.retry, b, fail)));
    el.querySelectorAll('[data-pj="go-automations"]').forEach((b) => b.addEventListener("click", () => goView("automations")));
    el.querySelectorAll('[data-pj="go-billing"]').forEach((b) => b.addEventListener("click", () => goView("billing")));
    el.querySelectorAll('[data-pj="upgrade"]').forEach((b) => b.addEventListener("click", () => {
      const arg = upgradeArg();
      const su = g("startUpgrade");
      if (arg && typeof su === "function") su(arg); else goView("billing");
    }));
    el.querySelectorAll('[data-pj="report"]').forEach((b) => b.addEventListener("click", () => openReport(b)));
    // plan
    const rej = el.querySelector(".pj-reject");
    el.querySelectorAll('[data-plan="toggle-reject"]').forEach((b) => b.addEventListener("click", () => { rej.hidden = !rej.hidden; if (!rej.hidden) rej.querySelector("textarea").focus(); }));
    el.querySelectorAll('[data-plan="approve"]').forEach((b) => b.addEventListener("click", async () => {
      const body = {};
      const cap = parseInt((el.querySelector('[name="pj-cap"]') || {}).value, 10);
      if (Number.isFinite(cap) && cap !== pjBudget(S.detail).cap) body.creditsCap = cap;
      const lvl = (el.querySelector('[name="pj-level"]') || {}).value;
      if (lvl && lvl !== S.detail.level) body.level = lvl;
      const rm = [...el.querySelectorAll('[name="pj-remove"]:checked')].map((x) => x.value);
      if (rm.length) body.removeSteps = rm;
      b.disabled = true;
      const r = await api("POST", `/api/projects/${id}/plan/approve`, body);
      b.disabled = false;
      if (r.status === 200) { clearDirty(el); announce("Plan validé : le travail commence."); loadDetail(); startPolling(); return; }
      if (r.data && r.data.error === "PROJECT_EXCEEDS_QUOTA") { exceedsHtml(el, r, body); return; }
      fail(r);
    }));
    el.querySelectorAll('[data-plan="reject"]').forEach((b) => b.addEventListener("click", async () => {
      const text = el.querySelector("#pj-reject-text").value.trim();
      if (!text) { fail({ data: { detail: T("Dites en quelques mots ce qu'il faut changer.") } }); return; }
      b.disabled = true;
      const r = await api("POST", `/api/projects/${id}/plan/reject`, { feedback: text });
      b.disabled = false;
      if (r.status === 200) { clearDirty(el); announce("Vos remarques sont envoyées : le plan est revu."); loadDetail(); startPolling(); } else fail(r);
    }));
    // questions
    el.querySelectorAll(".pj-question").forEach((f) => {
      f.querySelectorAll("[data-choice]").forEach((c) => c.addEventListener("click", () => { const ta = f.querySelector("textarea"); ta.value = c.dataset.choice; ta.dataset.dirty = "1"; ta.focus(); }));
      f.addEventListener("submit", async (e) => {
        e.preventDefault();
        const ta = f.querySelector("textarea");
        const answer = ta.value.trim();
        if (!answer) { ta.focus(); return; }
        const btn = f.querySelector("button[type=submit]");
        btn.disabled = true;
        const r = await api("POST", `/api/projects/${id}/input`, { questionId: f.dataset.qid, answer });
        btn.disabled = false;
        if (r.status === 200) { clearDirty(f); announce("Réponse envoyée."); loadDetail(); } else fail(r);
      });
    });
    // budget
    el.querySelectorAll('[data-budget="raise"]').forEach((b) => b.addEventListener("click", async () => {
      const cap = parseInt(el.querySelector('[name="pj-newcap"]').value, 10);
      await setBudget(cap, b, fail, el);
    }));
    el.querySelectorAll("[data-gaps]").forEach((b) => b.addEventListener("click", async () => {
      if (!confirm(T("Accepter le projet en l'état ? Les critères non atteints seront notés comme écarts acceptés dans le rapport final."))) return;
      const ids = b.dataset.gaps === "failed" ? ((S.detail.plan && S.detail.plan.criteria) || []).filter((c) => c.verdict && c.verdict !== "PASS").map((c) => c.id) : undefined;
      b.disabled = true;
      const r = await api("POST", `/api/projects/${id}/accept-gaps`, ids ? { criteriaIds: ids } : {});
      b.disabled = false;
      if (r.status === 200) { announce("Écarts acceptés."); loadDetail(); } else fail(r);
    }));
  }

  function clearDirty(el) { el.querySelectorAll("[data-dirty]").forEach((x) => delete x.dataset.dirty); if (document.activeElement && el.contains(document.activeElement)) document.activeElement.blur(); }

  function exceedsHtml(el, r, body) {
    const box = el.querySelector(".pj-exceeds");
    const d = r.data || {};
    const est = d.estimate || {};
    box.hidden = false;
    box.innerHTML = `<p><strong>${esc(d.detail || "")}</strong></p>
      <p>${esc(TF("Estimation minimale : {a} crédits ; il vous reste {b} crédits ce mois-ci.", { a: num(est.creditsMin), b: num(d.remaining) }))}</p>
      <ul>${(d.options || []).map((o) => `<li>${esc(o)}</li>`).join("")}</ul>
      <div class="pj-row"><button type="button" class="btn btn-gold" data-pj="anyway">${esc(T("Démarrer quand même"))}</button>
      <button type="button" class="btn btn-ghost" data-pj="go-billing">${esc(T("Voir les forfaits"))}</button></div>`;
    box.querySelector('[data-pj="go-billing"]').addEventListener("click", () => goView("billing"));
    box.querySelector('[data-pj="anyway"]').addEventListener("click", async (e) => {
      e.currentTarget.disabled = true;
      const rr = await api("POST", `/api/projects/${S.currentId}/plan/approve`, Object.assign({ startAnyway: true }, body.creditsCap ? { creditsCap: body.creditsCap } : {}));
      if (rr.status === 200) { clearDirty(el); announce("Plan validé : le travail commence."); loadDetail(); startPolling(); } else showError(el.querySelector(".pj-form-error"), rr);
    });
  }

  async function setBudget(cap, btn, fail, el) {
    if (!Number.isFinite(cap) || cap < 6) { fail({ data: { detail: T("Indiquez un plafond en crédits (6 au moins).") } }); return; }
    btn.disabled = true;
    const r = await api("POST", `/api/projects/${S.currentId}/budget`, { creditsCap: cap });
    btn.disabled = false;
    if (r.status === 200) { if (el) clearDirty(el); announce("Plafond mis à jour."); loadDetail(); startPolling(); } else fail(r);
  }

  async function retryStep(stepId, btn, fail) {
    btn.disabled = true;
    const r = await api("POST", `/api/projects/${S.currentId}/retry-step`, { stepId });
    btn.disabled = false;
    if (r.status === 200) { announce("Étape relancée."); loadDetail(); startPolling(); } else fail(r);
  }

  async function openReport(btn) {
    const r = await fetch(`/api/projects/${S.currentId}/files/final-report.md`, { credentials: "same-origin", cache: "no-store" }).catch(() => null);
    const text = r && r.ok ? await r.text() : T("Rapport indisponible pour le moment.");
    openDialog(T("Rapport final"), `<pre class="pj-report" data-no-i18n="1"></pre>
      <div class="pj-row"><a class="btn btn-gold" href="/api/projects/${esc(S.currentId)}/files/final-report.md" download>${esc(T("Télécharger"))}</a></div>`, btn, (box) => {
      box.querySelector(".pj-report").textContent = text;
    });
  }

  // ------------------------------------------------------------------ onglets
  function renderTabs() {
    const el = document.querySelector("#projets-view .pj-tabs");
    const d = S.detail;
    if (!el || !d) return;
    const counts = { approvals: d.approvalsPending || 0, deliverables: (d.deliverables || []).length, messages: 0 };
    el.innerHTML = TABS.map(([id, label]) => {
      const n = counts[id];
      const on = S.tab === id;
      return `<button type="button" role="tab" id="pj-tab-${id}" aria-controls="pj-panel" aria-selected="${on}" tabindex="${on ? 0 : -1}" data-tab="${id}" class="pj-tab${on ? " active" : ""}">${esc(T(label))}${n ? ` <span class="pj-count${id === "approvals" ? " pj-count-att" : ""}" data-no-i18n="1">${n}</span>` : ""}</button>`;
    }).join("");
    el.querySelectorAll("[data-tab]").forEach((b) => {
      b.addEventListener("click", () => selectTab(b.dataset.tab, false));
      b.addEventListener("keydown", (e) => {
        const ids = TABS.map((t) => t[0]);
        let i = ids.indexOf(b.dataset.tab);
        if (e.key === "ArrowRight") i = (i + 1) % ids.length;
        else if (e.key === "ArrowLeft") i = (i - 1 + ids.length) % ids.length;
        else if (e.key === "Home") i = 0;
        else if (e.key === "End") i = ids.length - 1;
        else return;
        e.preventDefault();
        selectTab(ids[i], false, true);
      });
    });
    const panel = document.getElementById("pj-panel");
    if (panel) panel.setAttribute("aria-labelledby", "pj-tab-" + S.tab);
  }

  function selectTab(id, scroll, focusTab) {
    S.tab = id;
    renderTabs();
    const panel = document.getElementById("pj-panel");
    if (panel) delete panel.dataset.sig;
    renderPanel(true);
    if (id === "approvals") loadApprovals();
    if (id === "messages") loadMessages();
    if (focusTab) { const t = document.getElementById("pj-tab-" + id); if (t) t.focus(); }
    if (scroll && panel) panel.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function renderPanel(force) {
    const el = document.getElementById("pj-panel");
    const d = S.detail;
    if (!el || !d) return;
    let html = "";
    if (S.tab === "plan") html = planHtml(d);
    else if (S.tab === "timeline") html = timelineHtml();
    else if (S.tab === "deliverables") html = deliverablesHtml(d);
    else if (S.tab === "approvals") html = approvalsHtml();
    else if (S.tab === "messages") html = messagesHtml(d);
    else if (S.tab === "team") html = teamHtml(d);
    if (!force && el.dataset.sig === html) return;
    if (!force && busy(el)) return;
    el.innerHTML = html;
    el.dataset.sig = html;
    wirePanel(el);
  }

  function planHtml(d) {
    const p = d.plan || {};
    const crit = (p.criteria || []).map((c) => {
      const v = c.accepted ? { label: "Écart accepté", icon: "≈", tone: "off" } : (PJ_VERDICT[c.verdict] || { label: "À vérifier", icon: "○", tone: "wait" });
      return `<li class="pj-crit"><span class="pj-verdict" data-tone="${v.tone}"><span aria-hidden="true">${v.icon}</span> ${esc(T(v.label))}</span>
        <span class="pj-crit-text" data-no-i18n="1">${esc(c.text || c.id)}</span>
        <span class="pj-crit-kind">${esc(T(c.kind === "auto" ? "contrôle automatique" : "relecture du contrôle qualité"))}</span>
        ${c.note ? `<span class="pj-muted pj-crit-note" data-no-i18n="1">${esc(c.note)}</span>` : ""}</li>`;
    }).join("");
    const steps = pjStepRows(p).map((s) => {
      const st = PJ_STEP_STATUS[s.status] || { label: s.status, icon: "•" };
      const why = s.status === "BLOCKED" && s.blockedReason ? ` — ${esc(T(PJ_BLOCKED_REASON[s.blockedReason] || s.blockedReason))}` : "";
      const deps = (s.dependsOn || []).length ? `<span class="pj-muted">${esc(TF("après {d}", { d: s.dependsOn.join(", ") }))}</span>` : "";
      const dl = (s.deliverables || []).length ? `<span class="pj-muted">${esc(TF("{n} livrable(s)", { n: s.deliverables.length }))}</span>` : "";
      const credits = s.credits ? `<span class="pj-muted">${esc(credLabel(s.credits))}</span>` : (s.estimateCredits ? `<span class="pj-muted">${esc(TF("~{n} crédits estimés", { n: num(s.estimateCredits) }))}</span>` : "");
      const attempts = s.attempts > 1 ? `<span class="pj-muted">${esc(TF("{n} essais", { n: s.attempts }))}</span>` : "";
      const retry = (s.status === "FAILED" || (s.status === "BLOCKED" && ["APPROVAL_EXPIRED", "CONNECTOR", "DEPENDENCY_FAILED"].includes(s.blockedReason))) && (d.capabilities || {}).canCancel
        ? `<button type="button" class="btn btn-ghost pj-small" data-retry="${esc(s.id)}">${esc(T("Relancer"))}</button>` : "";
      return `<li class="pj-step" data-status="${esc(s.status)}">
        <span class="pj-step-icon" aria-hidden="true">${st.icon}</span>
        <div class="pj-step-body">
          <div class="pj-step-title"><strong data-no-i18n="1">${esc(s.title || s.id)}</strong> <span class="pj-step-who">${esc(workerName(s.worker))}${s.system ? ` · ${esc(T(systemKindLabel(s.kind)))}` : ""}</span></div>
          <div class="pj-step-status"><span class="sr-only">${esc(T("Statut :"))}</span>${esc(T(st.label))}${why} ${deps} ${dl} ${credits} ${attempts}</div>
          ${s.summary ? `<p class="pj-step-summary" data-no-i18n="1">${esc(s.summary)}</p>` : (s.goal && s.status === "PENDING" ? `<p class="pj-step-summary pj-muted" data-no-i18n="1">${esc(s.goal)}</p>` : "")}
          ${s.handoffNote ? `<details class="pj-handoff"><summary>${esc(T("Note de passation"))}</summary><p data-no-i18n="1">${esc(s.handoffNote)}</p></details>` : ""}
        </div>${retry}</li>`;
    }).join("");
    const assumptions = (p.assumptions || []).map((a) => `<li data-no-i18n="1">${esc(typeof a === "string" ? a : (a.text || ""))}</li>`).join("");
    const risks = (p.risks || []).map((a) => `<li data-no-i18n="1">${esc(typeof a === "string" ? a : (a.text || a.risk || ""))}</li>`).join("");
    if (!crit && !steps) return `<p class="pj-muted">${esc(T(d.status === "PLANNING" || d.status === "QUEUED" ? "Le plan est en préparation : il apparaîtra ici avec ses critères d'acceptation et ses étapes." : "Aucun plan pour le moment."))}</p>`;
    return `<h3>${esc(T("Critères d'acceptation"))}</h3>
      <p class="pj-muted">${esc(T("Le projet n'est terminé que lorsque chaque critère est vérifié avec une preuve par le contrôle qualité indépendant."))}</p>
      <ul class="pj-crits">${crit}</ul>
      <h3>${esc(T("Étapes"))}</h3>
      <ol class="pj-steps">${steps}</ol>
      ${assumptions ? `<details class="pj-more"><summary>${esc(T("Hypothèses du plan"))}</summary><ul>${assumptions}</ul></details>` : ""}
      ${risks ? `<details class="pj-more"><summary>${esc(T("Risques identifiés"))}</summary><ul>${risks}</ul></details>` : ""}`;
  }

  function systemKindLabel(k) {
    return { plan: "planification", verify: "contrôle qualité", fix: "correction", replan: "révision du plan", consolidate: "rapport final", answer: "réponse" }[k] || "étape";
  }

  // « Statut : PAUSED -> RUNNING (CLIENT_RESUMED) » (evenement technique du moteur) devient « Statut : En pause → En cours » : jamais de code brut chez le client.
  function eventText(e) {
    const t = String(e.text || e.type || "");
    const m = /^Statut : ([A-Z_]+) -> ([A-Z_]+)/.exec(t);
    if (!m) return t;
    const lab = (c) => T((PJ_STATUS[c] || { label: c }).label);
    return TF("Statut : {a} → {b}", { a: lab(m[1]), b: lab(m[2]) });
  }

  function timelineHtml() {
    if (!S.events.length) return `<p class="pj-muted">${esc(T("Aucun évènement pour le moment."))}</p>`;
    return `<ol class="pj-timeline">${S.events.filter((e) => e.type !== "step_cost").map((e) => `<li class="pj-ev" data-type="${esc(e.type)}">
        <span class="pj-ev-icon" aria-hidden="true">${PJ_EVENT_ICON[e.type] || "•"}</span>
        <time datetime="${esc(e.ts)}">${esc(when(e.ts))}</time>
        <span class="pj-ev-text">${e.worker ? `<strong>${esc(workerName(e.worker))}</strong> · ` : ""}${esc(eventText(e))}</span></li>`).join("")}</ol>`;
  }

  function deliverablesHtml(d) {
    const pid = d.projectId;
    const rows = (d.deliverables || []).map((x) => {
      const url = pjFileUrl(pid, x.path);
      const name = String(x.path || "").split("/").pop();
      const size = x.bytes ? `${num(Math.max(1, Math.round(x.bytes / 1024)))} Ko` : "";
      return `<li class="pj-file">
        <div class="pj-file-main"><strong data-no-i18n="1">${esc(x.title || name)}</strong>
          <span class="pj-muted"><span data-no-i18n="1">${esc(x.path || "")}</span>${size ? ` · ${esc(size)}` : ""}${x.worker ? ` · ${esc(workerName(x.worker))}` : ""}</span>
          ${x.description ? `<span class="pj-muted" data-no-i18n="1">${esc(x.description)}</span>` : ""}</div>
        <div class="pj-file-actions">${x.previewable ? `<button type="button" class="btn btn-ghost pj-small" data-preview="${esc(url)}" data-name="${esc(name)}">${esc(T("Aperçu"))}</button>` : ""}
          <a class="btn btn-gold pj-small" href="${esc(url)}" download>${esc(T("Télécharger"))}</a></div></li>`;
    }).join("");
    const report = d.hasFinalReport ? `<li class="pj-file"><div class="pj-file-main"><strong>${esc(T("Rapport final"))}</strong><span class="pj-muted">final-report.md</span></div>
        <div class="pj-file-actions"><button type="button" class="btn btn-ghost pj-small" data-pj="report">${esc(T("Lire"))}</button>
        <a class="btn btn-gold pj-small" href="/api/projects/${esc(pid)}/files/final-report.md" download>${esc(T("Télécharger"))}</a></div></li>` : "";
    if (!rows && !report) return `<p class="pj-muted">${esc(T("Les livrables apparaissent ici dès qu'un Worker en produit un."))}</p>${d.workspacePurged ? `<p class="pj-warn">${esc(T("Les fichiers de ce projet ont été supprimés à la fin de la durée de conservation (90 jours)."))}</p>` : ""}`;
    return `<ul class="pj-files">${report}${rows}</ul>
      <div class="pj-row"><a class="btn btn-ghost" href="/api/projects/${esc(pid)}/export.zip?scope=deliverables" download>${esc(T("Tout télécharger (.zip)"))}</a>
      <a class="btn btn-ghost" href="/api/projects/${esc(pid)}/export.zip?scope=workspace" download>${esc(T("Tout l'espace de travail (.zip)"))}</a></div>`;
  }

  function teamHtml(d) {
    const ws = Array.isArray(d.workers) ? d.workers.filter((w) => typeof w === "object") : [];
    if (!ws.length) return `<p class="pj-muted">${esc(T("L'équipe apparaît ici une fois le plan prêt."))}</p>`;
    const label = { RUNNING: "au travail", BLOCKED: "bloqué", DONE: "a terminé", FAILED: "en échec", WAITING: "en attente" };
    return `<ul class="pj-team">${ws.map((w) => `<li class="pj-member" data-status="${esc(w.status)}">
        <img src="${esc(w.portraitUrl || `/portraits/${encodeURIComponent(w.id)}.jpg`)}" alt="" aria-hidden="true" loading="lazy">
        <div><strong>${esc(w.name || workerName(w.id))}</strong> <span class="pj-muted">${esc(w.role || "")}</span>
          <div class="pj-member-meta">${esc(T(label[w.status] || w.status || ""))} · ${esc(TF("{a} étape(s) sur {b}", { a: w.stepsDone || 0, b: w.stepsTotal || 0 }))} · ${esc(credLabel(w.creditsUsed))}${w.approvalsPending ? ` · ${esc(TF("{n} action(s) à valider", { n: w.approvalsPending }))}` : ""}</div>
          ${w.lastSummary ? `<p class="pj-muted" data-no-i18n="1">${esc(w.lastSummary)}</p>` : ""}</div></li>`).join("")}</ul>
      ${(d.scope && d.scope.denied && d.scope.denied.length && d.scope.chloe) ? `<p class="pj-muted">${esc(TF("Chloé peut déléguer à {n} Worker(s) de votre forfait ; les autres peuvent être embauchés depuis leur fiche.", { n: (d.scope.allowed || []).length }))}</p>` : ""}`;
  }

  // ------------------------------------------------------------------ validations (contenu exact, une par une ou par lot)
  async function loadApprovals() {
    const id = S.currentId;
    if (!id) return;
    const [pend, all] = await Promise.all([api("GET", `/api/projects/${id}/approvals?status=PENDING&limit=200`), api("GET", `/api/projects/${id}/approvals?limit=50`)]);
    if (id !== S.currentId) return;
    if (pend.status === 200) {
      const pendingIds = new Set((pend.data.approvals || []).map((a) => a.id));
      S.approvals = { pending: pend.data.approvals || [], history: ((all.data && all.data.approvals) || []).filter((a) => !pendingIds.has(a.id)), counts: pend.data.counts || {} };
      if (S.tab === "approvals") renderPanel();
    }
  }

  function approvalsHtml() {
    const A = S.approvals;
    if (!A) return `<p class="pj-muted">${esc(T("Chargement des validations…"))}</p>`;
    const groups = pjGroupApprovals(A.pending);
    const intro = `<p class="pj-muted">${esc(T("Chaque action ci-dessous est prête mais n'est PAS partie. Vous voyez exactement ce qui sera envoyé, publié ou créé, et vers qui. Vous pouvez modifier un champ avant de valider."))}</p>`;
    const pending = groups.length ? groups.map(groupHtml).join("") : `<p class="pj-empty-line">${esc(T("Aucune action en attente de votre décision."))}</p>`;
    const hist = A.history.length ? `<details class="pj-more"><summary>${esc(TF("Historique ({n})", { n: A.history.length }))}</summary>
      <ul class="pj-approvals-hist">${A.history.map((a) => `<li><strong data-no-i18n="1">${esc((a.display || {}).title || a.operation || a.id)}</strong> — ${esc(T(PJ_APPROVAL_STATUS[a.status] || a.status))}${a.decidedUtc ? ` · ${esc(when(a.decidedUtc))}` : ""}${a.autoApproved ? ` · ${esc(T("brouillon validé automatiquement selon vos réglages"))}` : ""}${a.execution && a.execution.detail && a.status !== "EXECUTED" ? `<br><span class="pj-muted" data-no-i18n="1">${esc(a.execution.detail)}</span>` : ""}</li>`).join("")}</ul></details>` : "";
    return intro + pending + hist + `<div class="pj-form-error" hidden role="alert"></div>`;
  }

  function groupHtml(gr) {
    const items = gr.items;
    const multi = items.length > 1;
    const open = new Set(items.length > 10 ? pjSampleIds(gr, 3) : items.map((i) => i.id));
    const sel = S.selected[gr.batchId] || new Set(items.filter((i) => i.risk !== "high").map((i) => i.id));
    S.selected[gr.batchId] = sel;
    const head = multi ? `<div class="pj-batch-head"><strong>${esc(TF("Lot de {n} actions", { n: items.length }))}</strong> · <span data-no-i18n="1">${esc((items[0].display || {}).title || items[0].operation || "")}</span>
        ${items.length > 10 ? `<p class="pj-muted">${esc(T("Trois exemples sont ouverts au hasard ; ouvrez les autres pour les lire."))}</p>` : ""}
        <div class="pj-row"><label class="pj-check"><input type="checkbox" data-select-all="${esc(gr.batchId)}"${items.filter((i) => i.risk !== "high").every((i) => sel.has(i.id)) && sel.size ? " checked" : ""}> ${esc(T("Tout sélectionner"))}</label>
        <button type="button" class="btn btn-gold pj-small" data-batch="approve" data-group="${esc(gr.batchId)}">${esc(TF("Valider la sélection ({n})", { n: pjBatchIds(gr, "approve", [...sel]).length }))}</button>
        <button type="button" class="btn btn-ghost pj-small" data-batch="reject" data-group="${esc(gr.batchId)}">${esc(T("Rejeter la sélection"))}</button></div>
        ${items.some((i) => i.risk === "high") ? `<p class="pj-warn">${esc(T("Les actions à risque élevé se valident une par une, avec une confirmation écrite."))}</p>` : ""}</div>` : "";
    return `<section class="pj-group" data-group="${esc(gr.batchId)}">${head}${items.map((it) => approvalHtml(it, multi, sel.has(it.id), open.has(it.id))).join("")}</section>`;
  }

  function approvalHtml(it, multi, selected, open) {
    const d = it.display || {};
    const params = it.params || {};
    const editing = !!S.editing[it.id];
    const editable = new Set(it.editableFields || []);
    const rows = Object.keys(params).map((k) => {
      const v = params[k];
      const val = editing && editable.has(k)
        ? `<textarea rows="${Math.min(10, Math.max(2, pjParamText(v).split("\n").length + 1))}" data-param="${esc(k)}" aria-label="${esc(k)}">${esc(pjParamText(v))}</textarea>`
        : `<pre class="pj-param-val">${esc(pjParamText(v))}</pre>`;
      return `<tr><th scope="row">${esc(k)}${(it.editedFields || []).includes(k) ? ` <span class="pj-pill" data-tone="act">${esc(T("modifié"))}</span>` : ""}</th><td>${val}</td></tr>`;
    }).join("");
    // L'API donne un NOMBRE de destinataires (display.recipients, entier) ; une liste de noms reste acceptee si un jour elle existe.
    const recips = Array.isArray(it.recipients) ? it.recipients : (typeof it.recipients === "string" && it.recipients ? [it.recipients] : []);
    const recipCount = typeof it.recipients === "number" && it.recipients > 0 ? it.recipients : 0;
    const high = it.risk === "high";
    const manual = it.kind === "manual_action" || !it.connectorId;    // action que le client fait lui-meme (ex. enregistrement DNS chez son hebergeur)
    const spend = it.spendChf != null && it.spendChf !== "" ? `<p><strong>${esc(T("Montant engagé :"))}</strong> <span data-no-i18n="1">${esc(it.spendChf)} CHF</span></p>` : "";
    const body = `<div class="pj-approval-body" data-no-i18n-scope="1">
        ${d.what ? `<p><strong>${esc(T("Ce qui va se passer :"))}</strong> <span data-no-i18n="1">${esc(d.what)}</span></p>` : ""}
        ${d.why ? `<p><strong>${esc(T("Pourquoi :"))}</strong> <span data-no-i18n="1">${esc(d.why)}</span></p>` : ""}
        ${recips.length ? `<p><strong>${esc(TF("Destinataires ({n}) :", { n: recips.length }))}</strong> <span data-no-i18n="1">${esc(recips.join(", "))}</span></p>` : (recipCount ? `<p><strong>${esc(TF("Nombre de destinataires : {n}", { n: num(recipCount) }))}</strong> ${esc(T("(vérifiez le contenu exact ci-dessous)"))}</p>` : "")}
        ${spend}
        <p class="pj-muted">${manual ? esc(T("Action à faire vous-même : rien n'est envoyé par la plateforme.")) : `${esc(T("Outil :"))} <span data-no-i18n="1">${esc(it.connectorId || "")} · ${esc(it.operation || "")}</span> · ${esc(T(it.reversible ? "réversible" : "irréversible"))}`} · ${esc(T("expire"))} ${esc(when(it.expiresUtc))}</p>
        ${rows ? `<div class="pj-params-wrap"><table class="pj-params" data-no-i18n="1"><caption>${esc(T("Contenu exact"))}</caption><tbody>${rows}</tbody></table></div>` : ""}
        ${high ? `<label class="pj-confirm">${esc(TF("Action à risque élevé : tapez « {c} » pour confirmer", { c: PJ_CONFIRM_TEXT }))} <input type="text" data-confirm="${esc(it.id)}" autocomplete="off" spellcheck="false"></label>` : ""}
        <div class="pj-row">
          ${editing ? `<button type="button" class="btn btn-gold pj-small" data-approve="${esc(it.id)}" data-with-edits="1">${esc(T("Valider avec mes modifications"))}</button>
             <button type="button" class="btn btn-ghost pj-small" data-edit="${esc(it.id)}">${esc(T("Annuler les modifications"))}</button>`
          : `<button type="button" class="btn btn-gold pj-small" data-approve="${esc(it.id)}">${esc(T(manual ? "C'est fait" : "Valider"))}</button>
             ${editable.size ? `<button type="button" class="btn btn-ghost pj-small" data-edit="${esc(it.id)}">${esc(T("Modifier"))}</button>` : ""}`}
          <button type="button" class="btn btn-ghost pj-small pj-danger" data-reject="${esc(it.id)}">${esc(T("Rejeter"))}</button>
        </div>
        <div class="pj-reject-box" data-reject-box="${esc(it.id)}" hidden>
          <label>${esc(T("Pourquoi ? (facultatif, transmis au Worker)"))} <textarea rows="2" maxlength="1000" data-reason="${esc(it.id)}"></textarea></label>
          <button type="button" class="btn btn-ghost pj-small pj-danger" data-reject-go="${esc(it.id)}">${esc(T("Confirmer le rejet"))}</button>
        </div></div>`;
    return `<details class="pj-approval" data-risk="${esc(it.risk || "medium")}"${open || editing ? " open" : ""}>
      <summary>${multi ? `<input type="checkbox" class="pj-sel" data-sel="${esc(it.id)}"${selected ? " checked" : ""}${high ? " disabled" : ""} aria-label="${esc(T("Sélectionner pour le lot"))}">` : ""}
        <span class="pj-approval-title" data-no-i18n="1">${esc(d.title || it.operation || it.id)}</span>
        <span class="pj-risk" data-risk="${esc(it.risk || "medium")}">${esc(T(PJ_RISK[it.risk] || PJ_RISK.medium))}</span>
        <span class="pj-muted">${esc(workerName(it.worker))}</span></summary>${body}</details>`;
  }

  // ------------------------------------------------------------------ messages
  async function loadMessages() {
    const id = S.currentId;
    const r = await api("GET", `/api/projects/${id}/messages`);
    if (id !== S.currentId || r.status !== 200) return;
    S.messages = r.data.messages || [];
    if (S.tab === "messages") renderPanel();
  }

  function messagesHtml(d) {
    const caps = d.capabilities || {};
    const list = (S.messages || []).slice(-50).map((m) => `<li class="pj-msg pj-msg-${m.from === "client" ? "me" : "team"}">
        <span class="pj-msg-meta">${esc(T(m.from === "client" ? "Vous" : "L'équipe"))} · ${esc(T({ note: "précision", change: "modification", question: "question", answer: "réponse" }[m.type] || m.type || ""))} · ${esc(when(m.ts))}</span>
        <p data-no-i18n="1">${esc(m.text || "")}</p></li>`).join("");
    const type = S.msgType || "note";
    const types = [["note", "Précision", "Une information pour les prochaines étapes, sans changer le plan."], ["change", "Modification", "Changer ce qui doit être produit : le plan est révisé."], ["question", "Question", "Une réponse rapide de l'équipe, même si le projet est en pause."]];
    const form = caps.canMessage ? `<form class="pj-msg-form">
        <fieldset class="pj-types"><legend>${esc(T("Type de message"))}</legend>${types.map(([v, l, h]) => `<label class="pj-type"><input type="radio" name="pj-mtype" value="${v}"${v === type ? " checked" : ""}> <strong>${esc(T(l))}</strong> <span class="pj-muted">${esc(T(h))}</span></label>`).join("")}</fieldset>
        <label class="sr-only" for="pj-msg-text">${esc(T("Votre message"))}</label>
        <textarea id="pj-msg-text" rows="3" maxlength="4000" placeholder="${esc(T("Écrivez à l'équipe…"))}"></textarea>
        <div class="pj-row"><button type="submit" class="btn btn-gold">${esc(T("Envoyer"))}</button><span class="pj-muted" aria-live="polite" data-msg-status></span></div>
        <div class="pj-form-error" hidden role="alert"></div></form>` : `<p class="pj-muted">${esc(T("Ce projet est terminé : démarrez un nouveau projet pour une nouvelle demande."))}</p>`;
    return `${S.messages === null ? `<p class="pj-muted">${esc(T("Chargement des messages…"))}</p>` : (list ? `<ul class="pj-msgs">${list}</ul>` : `<p class="pj-muted">${esc(T("Aucun message pour le moment. Vous pouvez écrire à l'équipe à tout moment."))}</p>`)}${form}`;
  }

  // ------------------------------------------------------------------ colonne : budget et quota
  function renderSide() {
    const el = document.getElementById("pj-side");
    const d = S.detail;
    if (!el || !d) return;
    const bu = pjBudget(d);
    const est = bu.estimate || {};
    const u = d.usage || {};
    const caps = d.capabilities || {};
    // Regle de la plateforme : aucune limite annoncee qui ne soit pas appliquee. Session et semaine ne s'affichent que si elles s'appliquent
    // reellement (meme test que les jauges de app.js : usageActive) ; sinon seul le mois, toujours applique, est montre.
    const winOn = typeof G.usageActive === "function" && G.usageActive(appUsageState());
    const usageLine = u.exempt ? `<p class="pj-muted">${esc(T("Compte sans limite d'usage."))}</p>`
      : winOn ? `<p>${esc(TF("Crédits utilisables maintenant : {n}", { n: num(u.allowedNow) }))}</p>
         ${u.binding && u.nextRenewalUtc ? `<p class="pj-muted">${esc(T(u.binding === "session" ? "Limite la plus proche : la session." : u.binding === "week" ? "Limite la plus proche : la semaine." : "Limite la plus proche : le mois."))} <span>${esc(T("Renouvellement"))}</span> ${countdownHtml(u.nextRenewalUtc)}</p>` : ""}`
      : (u.month && u.month.remaining != null ? `<p>${esc(TF("Crédits restants ce mois-ci : {n}", { n: num(u.month.remaining) }))}</p>
         ${u.month.resetsAtUtc ? `<p class="pj-muted"><span>${esc(T("Renouvellement"))}</span> ${countdownHtml(u.month.resetsAtUtc)}</p>` : ""}` : "");
    const html = `<section class="pj-card-side"><h3>${esc(T("Budget du projet"))}</h3>
        <div class="usage-meter" data-level="${bu.level}"><div class="usage-meter-head"><span class="usage-meter-name">${esc(T("Crédits utilisés"))}</span>
          <span class="usage-meter-figures"><strong>${num(bu.used)}</strong> / <strong>${num(bu.cap)}</strong></span></div>
          <div class="usage-meter-track" role="progressbar" aria-valuemin="0" aria-valuemax="${bu.cap}" aria-valuenow="${Math.min(bu.used, bu.cap)}" aria-label="${esc(T("Crédits utilisés sur le plafond du projet"))}"><div class="usage-meter-fill" style="width:${bu.pct}%"></div></div></div>
        ${est.creditsMin != null ? `<p class="pj-muted">${esc(TF("Estimation du plan : {a} à {b} crédits", { a: num(est.creditsMin), b: num(est.creditsMax) }))}</p>` : ""}
        ${bu.toFinish != null && !PJ_TERMINAL.includes(d.status) ? `<p class="pj-muted">${esc(TF("Pour finir : environ {n} crédits", { n: num(bu.toFinish) }))}</p>` : ""}
        ${caps.canRaiseBudget && d.status !== "BUDGET_REACHED" ? `<details class="pj-more"><summary>${esc(T("Modifier le plafond"))}</summary>
          <div class="pj-fields"><label>${esc(T("Plafond (crédits)"))} <input type="number" min="6" step="1" name="pj-sidecap" value="${bu.cap}" inputmode="numeric"></label></div>
          <button type="button" class="btn btn-ghost pj-small" data-side="cap">${esc(T("Enregistrer"))}</button><div class="pj-form-error" hidden role="alert"></div></details>` : ""}
      </section>
      <section class="pj-card-side"><h3>${esc(T("Votre quota d'usage"))}</h3>${usageLine}
        <button type="button" class="btn btn-ghost pj-small" data-pj="go-billing">${esc(T("Voir mes limites et mon forfait"))}</button></section>`;
    if (!setHtml(el, html)) return;
    el.querySelectorAll('[data-pj="go-billing"]').forEach((b) => b.addEventListener("click", () => goView("billing")));
    const sb = el.querySelector('[data-side="cap"]');
    if (sb) sb.addEventListener("click", () => setBudget(parseInt(el.querySelector('[name="pj-sidecap"]').value, 10), sb, (r) => showError(el.querySelector(".pj-form-error"), r), el));
  }

  // ------------------------------------------------------------------ gestes dans le panneau
  function wirePanel(el) {
    const id = S.currentId;
    const errBox = el.querySelector(".pj-form-error");
    const fail = (r) => showError(errBox || el.querySelector(".pj-form-error"), r);
    el.querySelectorAll("[data-retry]").forEach((b) => b.addEventListener("click", () => retryStep(b.dataset.retry, b, (r) => toast(r))));
    el.querySelectorAll("[data-preview]").forEach((b) => b.addEventListener("click", () => {
      const fn = g("openFilePreview");
      if (typeof fn === "function") fn(b.dataset.preview, b.dataset.name); else window.open(b.dataset.preview, "_blank", "noopener");
    }));
    el.querySelectorAll('[data-pj="report"]').forEach((b) => b.addEventListener("click", () => openReport(b)));
    // validations
    el.querySelectorAll("[data-sel]").forEach((c) => c.addEventListener("change", () => {
      const grp = c.closest(".pj-group").dataset.group;
      const set = S.selected[grp] || new Set();
      if (c.checked) set.add(c.dataset.sel); else set.delete(c.dataset.sel);
      S.selected[grp] = set;
      delete c.dataset.dirty;
      refreshBatchLabels(el, grp);
    }));
    el.querySelectorAll("[data-sel]").forEach((c) => c.addEventListener("click", (e) => e.stopPropagation()));
    el.querySelectorAll("[data-select-all]").forEach((c) => c.addEventListener("change", () => {
      const grp = c.dataset.selectAll;
      const gr = pjGroupApprovals(S.approvals.pending).find((x) => x.batchId === grp);
      S.selected[grp] = new Set(c.checked ? gr.items.filter((i) => i.risk !== "high").map((i) => i.id) : []);
      el.querySelectorAll(`.pj-group[data-group="${CSS.escape(grp)}"] [data-sel]`).forEach((x) => { if (!x.disabled) x.checked = c.checked; });
      delete c.dataset.dirty;
      refreshBatchLabels(el, grp);
    }));
    el.querySelectorAll("[data-batch]").forEach((b) => b.addEventListener("click", async () => {
      const grp = b.dataset.group;
      const gr = pjGroupApprovals(S.approvals.pending).find((x) => x.batchId === grp);
      const ids = pjBatchIds(gr, b.dataset.batch, [...(S.selected[grp] || [])]);
      if (!ids.length) { fail({ data: { detail: T("Sélectionnez au moins une action (les actions à risque élevé se valident une par une).") } }); return; }
      if (!confirm(TF(b.dataset.batch === "approve" ? "Valider {n} action(s) ? Elles partiront telles qu'affichées." : "Rejeter {n} action(s) ?", { n: ids.length }))) return;
      b.disabled = true;
      const r = await api("POST", `/api/projects/${id}/approvals/batch`, { ids, decision: b.dataset.batch });
      b.disabled = false;
      if (r.status === 200) {
        const errs = (r.data.results || []).filter((x) => x.error);
        announce(TF("{n} action(s) traitée(s).", { n: ids.length - errs.length }));
        if (errs.length) fail({ data: { detail: TF("{n} action(s) n'ont pas pu être traitées (déjà décidées, expirées ou à risque élevé).", { n: errs.length }) } });
        clearDirty(el); afterDecision();
      } else fail(r);
    }));
    el.querySelectorAll("[data-edit]").forEach((b) => b.addEventListener("click", () => {
      const aid = b.dataset.edit;
      S.editing[aid] = !S.editing[aid];
      clearDirty(el);
      renderPanel(true);
      const ta = document.querySelector(`[data-approve="${CSS.escape(aid)}"]`);
      const box = ta && ta.closest(".pj-approval");
      const first = box && box.querySelector("textarea[data-param]");
      if (first) first.focus();
    }));
    el.querySelectorAll("[data-approve]").forEach((b) => b.addEventListener("click", async () => {
      const aid = b.dataset.approve;
      const it = (S.approvals.pending || []).find((x) => x.id === aid);
      if (!it) return;
      const box = b.closest(".pj-approval");
      const body = {};
      if (b.dataset.withEdits) {
        const edited = {};
        for (const ta of box.querySelectorAll("textarea[data-param]")) {
          const k = ta.dataset.param;
          const orig = (it.params || {})[k];
          if (ta.value === pjParamText(orig)) continue;
          const c = pjCoerceParam(orig, ta.value);
          if (!c.ok) { fail({ data: { detail: `${k} : ${T(c.error)}` } }); ta.focus(); return; }
          edited[k] = c.value;
        }
        if (Object.keys(edited).length) body.params = edited;
      }
      if (it.risk === "high") {
        const inp = box.querySelector(`[data-confirm="${CSS.escape(aid)}"]`);
        if (!inp || inp.value.trim() !== PJ_CONFIRM_TEXT) { fail({ data: { detail: TF("Tapez « {c} » pour confirmer cette action à risque élevé.", { c: PJ_CONFIRM_TEXT }) } }); if (inp) inp.focus(); return; }
        body.confirm = PJ_CONFIRM_TEXT;
      }
      b.disabled = true;
      const r = await api("POST", `/api/projects/${id}/approvals/${aid}/approve`, body);
      b.disabled = false;
      if (r.status === 200) { delete S.editing[aid]; announce("Action validée."); clearDirty(el); afterDecision(); } else fail(r);
    }));
    el.querySelectorAll("[data-reject]").forEach((b) => b.addEventListener("click", () => {
      const box = el.querySelector(`[data-reject-box="${CSS.escape(b.dataset.reject)}"]`);
      box.hidden = !box.hidden;
      if (!box.hidden) box.querySelector("textarea").focus();
    }));
    el.querySelectorAll("[data-reject-go]").forEach((b) => b.addEventListener("click", async () => {
      const aid = b.dataset.rejectGo;
      const reason = (el.querySelector(`[data-reason="${CSS.escape(aid)}"]`) || {}).value || "";
      b.disabled = true;
      const r = await api("POST", `/api/projects/${id}/approvals/${aid}/reject`, reason.trim() ? { reason: reason.trim() } : {});
      b.disabled = false;
      if (r.status === 200) { delete S.editing[aid]; announce("Action rejetée."); clearDirty(el); afterDecision(); } else fail(r);
    }));
    // messages
    const mf = el.querySelector(".pj-msg-form");
    if (mf) {
      mf.querySelectorAll('[name="pj-mtype"]').forEach((r) => r.addEventListener("change", () => { S.msgType = r.value; delete r.dataset.dirty; }));
      mf.addEventListener("submit", async (e) => {
        e.preventDefault();
        const ta = mf.querySelector("textarea");
        const text = ta.value.trim();
        if (!text) { ta.focus(); return; }
        const type = (mf.querySelector('[name="pj-mtype"]:checked') || {}).value || "note";
        const btn = mf.querySelector("button[type=submit]");
        btn.disabled = true;
        const r = await api("POST", `/api/projects/${id}/messages`, { type, text });
        btn.disabled = false;
        if (r.status === 202 || r.status === 200) {
          ta.value = ""; clearDirty(mf); S.msgType = "note";
          announce(r.data.willReplan ? "Message envoyé : le plan va être révisé." : "Message envoyé.");
          await loadMessages(); loadDetail();
        } else fail(r);
      });
    }
  }

  function refreshBatchLabels(el, grp) {
    const gr = pjGroupApprovals(S.approvals.pending).find((x) => x.batchId === grp);
    const b = el.querySelector(`[data-batch="approve"][data-group="${CSS.escape(grp)}"]`);
    if (b && gr) b.textContent = TF("Valider la sélection ({n})", { n: pjBatchIds(gr, "approve", [...(S.selected[grp] || [])]).length });
  }

  function afterDecision() { loadApprovals(); scheduleReload(300); refreshList(); }

  // ------------------------------------------------------------------ fenetre « Nouveau projet »
  let dialogEl = null;
  function closeDialog() {
    if (!dialogEl) return;
    dialogEl.remove();
    dialogEl = null;
    document.removeEventListener("keydown", dialogKey, true);
    const back = S.dialogReturn;
    S.dialogReturn = null;
    if (back && document.contains(back)) back.focus();
  }
  function dialogKey(e) {
    if (!dialogEl) return;
    if (e.key === "Escape") { e.preventDefault(); closeDialog(); return; }
    if (e.key === "Tab") {        // la tabulation reste dans la fenetre
      const f = [...dialogEl.querySelectorAll("button, [href], input, select, textarea, summary, [tabindex]:not([tabindex='-1'])")].filter((x) => !x.disabled && x.offsetParent !== null);
      if (!f.length) return;
      const first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  }
  function openDialog(title, inner, returnTo, wire) {
    closeDialog();
    S.dialogReturn = returnTo || document.activeElement;
    dialogEl = document.createElement("div");
    dialogEl.className = "pj-overlay";
    dialogEl.innerHTML = `<div class="pj-dialog" role="dialog" aria-modal="true" aria-labelledby="pj-dialog-title">
      <div class="pj-dialog-head"><h2 id="pj-dialog-title">${esc(title)}</h2><button type="button" class="pj-x" aria-label="${esc(T("Fermer"))}">×</button></div>
      <div class="pj-dialog-body">${inner}</div></div>`;
    dialogEl.addEventListener("click", (e) => { if (e.target === dialogEl) closeDialog(); });
    dialogEl.querySelector(".pj-x").addEventListener("click", closeDialog);
    document.body.appendChild(dialogEl);
    document.addEventListener("keydown", dialogKey, true);
    if (wire) wire(dialogEl);
    const f = dialogEl.querySelector("textarea, input, select, button:not(.pj-x)");
    (f || dialogEl.querySelector(".pj-x")).focus();
    return dialogEl;
  }

  async function openNewProject(opts) {
    opts = opts || {};
    if (!isAuth()) { const ra = g("requireAccount"); if (ra) ra(() => openNewProject(opts)); return; }
    if (!S.enabled && !(await probe())) return;
    const wid = opts.workerId || "chloe";
    const who = wid === "chloe" ? T("Chloé et l'équipe") : workerName(wid);
    const inner = `<form class="pj-new" novalidate>
      <p class="pj-muted">${esc(wid === "chloe"
        ? T("Chloé lit votre objectif, prépare un plan avec des critères d'acceptation, le répartit entre les Workers de votre forfait et pilote le projet jusqu'au bout. Vous validez le plan avant que le travail commence.")
        : TF("{w} prépare un plan avec des critères d'acceptation et va jusqu'au bout. Vous validez le plan avant que le travail commence.", { w: who }))}</p>
      <label for="pj-goal"><strong>${esc(T("Votre objectif"))}</strong></label>
      <textarea id="pj-goal" rows="5" maxlength="${PJ_GOAL_MAX}" required placeholder="${esc(T("Ex. : un site vitrine de 5 pages pour mon cabinet de physiothérapie à Lausanne, en français et en anglais, avec une page de prise de rendez-vous."))}" aria-describedby="pj-goal-count">${esc(opts.goal || "")}</textarea>
      <div class="pj-muted pj-counter" id="pj-goal-count" aria-live="polite"></div>
      <div class="pj-recipes" hidden></div>
      <div class="pj-fields">
        <label>${esc(T("Niveau"))} <select name="level"><option value="standard">${esc(T("Standard"))}</option><option value="approfondi">${esc(T("Approfondi (plus de vérifications, plus de crédits)"))}</option></select></label>
        <label>${esc(T("Plafond de crédits (facultatif)"))} <input type="number" name="cap" min="6" step="1" inputmode="numeric" placeholder="${esc(T("par défaut"))}"></label>
      </div>
      <label class="pj-check"><input type="checkbox" name="autostart"> ${esc(T("Démarrer sans attendre ma validation du plan"))}</label>
      <label class="pj-file-input">${esc(T("Joindre des fichiers (facultatif) : textes, tableaux, PDF, images"))}
        <input type="file" name="inputs" multiple accept="${PJ_INPUT_EXT.map((x) => "." + x).join(",")}"></label>
      ${wid === "chloe" ? `<div class="pj-triage-box"><button type="button" class="btn btn-ghost pj-small" data-pj="triage">${esc(T("Demander à Chloé : projet ou simple mission ?"))}</button><div class="pj-triage" aria-live="polite"></div></div>` : ""}
      <div class="pj-form-error" hidden role="alert"></div>
      <div class="pj-row pj-dialog-actions"><button type="submit" class="btn btn-gold">${esc(T("Préparer le plan"))}</button>
        <button type="button" class="btn btn-ghost" data-pj="close">${esc(T("Fermer"))}</button></div>
      <p class="pj-muted">${esc(T("Seule la préparation du plan consomme quelques crédits. Rien n'est envoyé, publié ni payé sans votre validation."))}</p>
    </form>`;
    openDialog(TF("Nouveau projet avec {w}", { w: who }), inner, opts.returnTo, (box) => wireNew(box, wid, opts));
  }

  function wireNew(box, wid, opts) {
    const form = box.querySelector(".pj-new");
    const goal = form.querySelector("#pj-goal");
    const counter = form.querySelector("#pj-goal-count");
    const err = form.querySelector(".pj-form-error");
    const upd = () => { counter.textContent = TF("{n} / {m} caractères", { n: num(goal.value.length), m: num(PJ_GOAL_MAX) }); };
    goal.addEventListener("input", upd);
    upd();
    let recipeId = opts.recipeId || null;
    form.querySelector('[data-pj="close"]').addEventListener("click", closeDialog);
    // Recettes (savoir-faire du Worker) : affichees seulement si le serveur en connait.
    api("GET", `/api/recipes?workerId=${encodeURIComponent(wid)}`).then((r) => {
      const list = (r.status === 200 && Array.isArray(r.data.recipes)) ? r.data.recipes : [];
      if (!list.length || !dialogEl) return;
      const rb = form.querySelector(".pj-recipes");
      rb.hidden = false;
      rb.innerHTML = `<fieldset><legend>${esc(T("Partir d'un savoir-faire (facultatif)"))}</legend>
        <label class="pj-type"><input type="radio" name="recipe" value=""${recipeId ? "" : " checked"}> ${esc(T("Aucun : plan sur mesure"))}</label>
        ${list.map((x) => {
          const cr = x.typicalCredits || (x.budget && x.budget.typicalCredits);
          return `<label class="pj-type"><input type="radio" name="recipe" value="${esc(x.id)}"${recipeId === x.id ? " checked" : ""}> <strong data-no-i18n="1">${esc(x.title || x.id)}</strong>${Array.isArray(cr) ? ` <span class="pj-muted">${esc(TF("{a} à {b} crédits", { a: cr[0], b: cr[1] }))}</span>` : ""}${x.summary ? `<br><span class="pj-muted" data-no-i18n="1">${esc(x.summary)}</span>` : ""}</label>`;
        }).join("")}</fieldset>`;
      rb.querySelectorAll('[name="recipe"]').forEach((x) => x.addEventListener("change", () => { recipeId = x.value || null; }));
    });
    const tri = form.querySelector('[data-pj="triage"]');
    if (tri) tri.addEventListener("click", async () => {
      const out = form.querySelector(".pj-triage");
      const e1 = pjGoalError(goal.value);
      if (e1) { showError(err, { data: { detail: T(e1) } }); goal.focus(); return; }
      err.hidden = true;
      tri.disabled = true;
      out.innerHTML = `<p class="pj-muted">${esc(T("Chloé lit votre demande…"))}</p>`;
      const r = await api("POST", "/api/chloe/triage", { objective: goal.value.trim() });
      tri.disabled = false;
      if (r.status !== 200 || !r.data.ok) { out.innerHTML = errorHtml(r.status === 200 ? { data: { detail: T("Chloé n'a pas pu analyser la demande : vous pouvez lancer le projet quand même.") } } : r); wireError(out, r); return; }
      const t = r.data;
      const ws = (t.workers || []).map((w) => `<li><strong>${esc(w.name || workerName(w.id))}</strong>${w.included === false ? ` <span class="pj-pill" data-tone="off">${esc(T("hors forfait"))}</span>` : ""} — <span data-no-i18n="1">${esc(w.objective || "")}</span></li>`).join("");
      const pc = t.estimate && t.estimate.projectCredits;
      const modeTxt = t.mode === "project" ? T("Conseil de Chloé : un projet (plusieurs étapes et plusieurs Workers).")
        : t.mode === "direct_reply" ? T("Conseil de Chloé : une simple réponse suffit, pas besoin de projet.") : T("Conseil de Chloé : une mission suffit (une réponse rapide).");
      out.innerHTML = `<div class="pj-triage-result"><p><strong>${esc(modeTxt)}</strong></p>${t.why ? `<p data-no-i18n="1">${esc(t.why)}</p>` : ""}
        ${ws ? `<ul>${ws}</ul>` : ""}
        ${Array.isArray(pc) && pc[1] ? `<p class="pj-muted">${esc(TF("Projet estimé entre {a} et {b} crédits.", { a: num(pc[0]), b: num(pc[1]) }))}</p>` : ""}
        ${(t.notIncluded || []).length ? `<p class="pj-muted">${esc(T("Les Workers hors forfait peuvent être embauchés depuis leur fiche ; sans eux, Chloé adapte le plan et vous dit ce qui manque."))}</p>` : ""}
        ${t.mode !== "project" ? `<button type="button" class="btn btn-ghost pj-small" data-pj="as-mission">${esc(T("Plutôt une mission rapide avec Chloé"))}</button>` : ""}</div>`;
      const am = out.querySelector('[data-pj="as-mission"]');
      if (am) am.addEventListener("click", () => { const text = goal.value.trim(); closeDialog(); quickMission(text); });
    });
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const e1 = pjGoalError(goal.value);
      if (e1) { showError(err, { data: { detail: T(e1) } }); goal.focus(); return; }
      const fileInput = form.querySelector('[name="inputs"]');
      const files = fileInput && fileInput.files ? [...fileInput.files] : [];
      const e2 = pjInputsError(files.map((f) => ({ name: f.name, size: f.size })));
      if (e2) { showError(err, { data: { detail: T(e2) } }); return; }
      const body = { goal: goal.value.trim(), workerId: wid, level: form.querySelector('[name="level"]').value, autoStart: form.querySelector('[name="autostart"]').checked,
        language: (typeof G.BK_LANG === "function" && G.BK_LANG() === "en") ? "en" : "fr" };
      const cap = parseInt(form.querySelector('[name="cap"]').value, 10);
      if (Number.isFinite(cap)) body.creditsCap = cap;
      if (recipeId) body.recipeId = recipeId;
      const btn = form.querySelector("button[type=submit]");
      btn.disabled = true;
      try {
        if (files.length) body.inputs = await Promise.all(files.map(readAsInput));
      } catch (x) { btn.disabled = false; showError(err, { data: { detail: T("Lecture d'un fichier impossible : réessayez.") } }); return; }
      const r = await api("POST", "/api/projects", body);
      btn.disabled = false;
      if (r.status === 201 && r.data.projectId) {
        closeDialog();
        S.list.unshift({ projectId: r.data.projectId, title: body.goal.slice(0, 60), goal: body.goal, status: r.data.status, queuePosition: r.data.queuePosition, workers: [wid], percent: 0, creditsCharged: 0, creditsCap: 0 });
        announce("Projet créé : le plan est en préparation.");
        openProject(r.data.projectId);
        refreshList();
        return;
      }
      showError(err, r);
    });
  }

  function readAsInput(file) {
    return new Promise((resolve, reject) => {
      const fr = new FileReader();
      fr.onerror = () => reject(fr.error);
      fr.onload = () => { const s = String(fr.result || ""); resolve({ name: file.name, contentBase64: s.slice(s.indexOf(",") + 1) }); };
      fr.readAsDataURL(file);
    });
  }

  function quickMission(text) {
    // Mission rapide avec Chloe, sans proposition de projet (mode « mission » cote serveur).
    const open = g("openChloeProfile");
    const run = g("runTask");
    if (typeof open !== "function" || typeof run !== "function") return;
    Promise.resolve(open()).then(() => run(text, { mode: "mission" }));
  }

  // ------------------------------------------------------------------ fiche d'un Worker / de Chloe : « Lancer un projet »
  async function onWorkerProfile(workerId) {
    const block = document.getElementById("pj-launch-block");
    if (!block) return;
    block.hidden = true;
    if (!isAuth()) return;
    if (!S.enabled && !(await probe())) return;
    if (appCurrentWorker() !== workerId) return;      // la fiche a change entre-temps
    const name = workerId === "chloe" ? T("Chloé") : workerName(workerId);
    const mine = S.list.filter((p) => p.leadWorker === workerId || (p.workers || []).includes(workerId)).slice(0, 3);
    block.innerHTML = `<div class="block-title">${esc(T("Lancer un projet"))}</div>
      <p class="pj-launch-text">${esc(workerId === "chloe"
        ? T("Pour un travail complet en plusieurs étapes et avec plusieurs Workers : Chloé prépare le plan, répartit le travail, vérifie la cohérence et vous livre le résultat terminé.")
        : TF("Pour un travail complet en plusieurs étapes : {w} prépare un plan avec des critères d'acceptation, va jusqu'au bout et fait vérifier chaque critère.", { w: name }))}</p>
      <div class="pj-row"><button type="button" class="btn btn-gold" data-pj="launch">${esc(T("Lancer un projet"))}</button>
      ${S.list.length ? `<button type="button" class="btn btn-ghost" data-pj="all">${esc(T("Mes projets"))}</button>` : ""}</div>
      ${mine.length ? `<ul class="pj-mini">${mine.map((p) => `<li><button type="button" class="pj-linkbtn" data-open="${esc(p.projectId)}"><span data-no-i18n="1">${esc(p.title || p.goal || p.projectId)}</span></button> ${statusPill(p)}</li>`).join("")}</ul>` : ""}`;
    block.hidden = false;
    block.querySelector('[data-pj="launch"]').addEventListener("click", (e) => openNewProject({ workerId, returnTo: e.currentTarget, goal: (document.getElementById("task-input") || {}).value || "" }));
    const all = block.querySelector('[data-pj="all"]');
    if (all) all.addEventListener("click", showList);
    block.querySelectorAll("[data-open]").forEach((b) => b.addEventListener("click", () => openProject(b.dataset.open)));
  }

  // Reponse de Chloe « je vous propose un projet » (Status SUGGEST_PROJECT) : deux boutons sous sa reponse.
  function suggestCard(result) {
    const box = document.createElement("div");
    box.className = "pj-suggest";
    const ws = ((result.SuggestProject && result.SuggestProject.workers) || []).map(workerName).join(", ");
    box.innerHTML = `${ws ? `<p class="pj-muted">${esc(TF("Workers prévus : {w}", { w: ws }))}</p>` : ""}
      <div class="pj-row"><button type="button" class="btn btn-gold" data-pj="as-project">${esc(T("Lancer comme projet"))}</button>
      <button type="button" class="btn btn-ghost" data-pj="as-mission">${esc(T("Juste une réponse rapide"))}</button></div>`;
    box.querySelector('[data-pj="as-project"]').addEventListener("click", (e) => openNewProject({ workerId: "chloe", goal: result.Request || "", returnTo: e.currentTarget }));
    box.querySelector('[data-pj="as-mission"]').addEventListener("click", () => {
      const run = g("runTask");
      if (typeof run === "function") run(result.Request || "", { mode: "mission" });
    });
    return box;
  }

  // Apres connexion (ou au demarrage) : la navigation « Projets » apparait si le moteur est actif ; un lien #projet/<id> s'ouvre.
  function onAccount() {
    const h = pjParseHash(location.hash);
    if (h) S.pendingHash = h.id || null;
    probe().then((on) => {
      if (on && h) { if (h.id) openProject(h.id); else goView("projets"); }
    });
  }

  function init() {
    const nav = document.getElementById("nav-projets");
    if (nav) nav.addEventListener("click", (e) => { e.preventDefault(); if (S.currentId) showList(); else goView("projets"); });
    const back = document.getElementById("projets-back-btn");
    if (back) back.addEventListener("click", () => goView("home"));
    window.addEventListener("hashchange", () => {
      const h = pjParseHash(location.hash);
      if (!h || !S.enabled) return;
      if (h.id && h.id !== S.currentId) openProject(h.id);
    });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden || !S.enabled) return;
      refreshList();
      if (S.currentId && isViewShown()) { loadDetail(); startPolling(); }
    });
    document.addEventListener("bk:lang", () => {
      renderBadge();
      if (!isViewShown()) return;
      if (S.currentId) { const p = document.getElementById("pj-panel"); if (p) delete p.dataset.sig; renderDetail(); } else renderList();
    });
  }
  init();

  window.BKProjects = { onShowView, onWorkerProfile, onAccount, suggestCard, open: openProject, openNew: openNewProject, refresh: refreshList,
    _state: S };
})();
