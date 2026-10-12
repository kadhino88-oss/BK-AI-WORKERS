const BK_LOCALE = () => (window.BK_LANG && window.BK_LANG() === "en" ? "en-GB" : "fr-FR");
const homeView = document.getElementById("home-view");
const workersView = document.getElementById("workers-view");
const automationsView = document.getElementById("automations-view");
const analyticsView = document.getElementById("analytics-view");
const onboardingView = document.getElementById("onboarding-view");
const billingView = document.getElementById("billing-view");
const pricingView = document.getElementById("pricing-view");
const faqView = document.getElementById("faq-view");
const legalView = document.getElementById("legal-view");
const profileView = document.getElementById("profile-view");
const adminView = document.getElementById("admin-view");
const catalogGrid = document.getElementById("catalog-grid");
const agentWheel = document.getElementById("agent-wheel");
const categoryBar = document.getElementById("category-bar");
const statsRow = document.getElementById("stats-row");
const backBtn = document.getElementById("back-btn");
const searchInput = document.getElementById("worker-search");

let currentWorkerId = null;
let allWorkers = [];
let chloeData = null;
let activeCategory = "ALL";
let searchQuery = "";
let gateAuthenticated = false;
let pendingGateAction = null;
let cameFromView = "home";
// Compte client (2026-09-22) : distinct du mot de passe de Kader
// ci-dessus, qui ne protege plus que les Automatisations. Un client
// s'inscrit librement (gratuit, sans carte) pour utiliser Chloe/les
// Workers/sa facturation/ses analytics — jamais avec le mot de passe
// de Kader. "operator" = connecte via CE mot de passe historique
// (c'est Kader lui-meme, pas un client) : reste vrai sans rien faire
// de nouveau puisque son ancienne session continue de fonctionner.
let accountAuthenticated = false;
let accountEmailVerified = true;
let isOperator = false;
let pendingAccountAction = null;

// Video D-ID re-desactivee (2026-09-24, quelques minutes apres l'avoir
// reactivee) : les videos generees ne montrent PAS le bon visage
// (visage generique different du vrai portrait) et affichent un
// filigrane D-ID visible — inutilisable, confirme par Kader sur
// capture reelle ("aucune video ne correspond aux Workers"). Fichiers
// generes supprimes (voir deploy/), pipeline D-ID a reprendre entierement
// avant toute reactivation (portrait source et/ou compte D-ID a revoir).
const VIDEO_ENABLED = false;

// ---------- DEVISE AUTOMATIQUE (2026-09-25) ----------
// Les prix sont definis en CHF (devise de facturation) ; l'affichage se
// convertit automatiquement dans la devise du pays du visiteur, deduite
// de la region de sa langue (fr-CA -> CAD, en-GB -> GBP...), au taux BCE
// du jour (/api/fx). Devises limitees a celles publiees par la BCE.
const REGION_CURRENCY = {
  US: "USD", CA: "CAD", GB: "GBP", AU: "AUD", NZ: "NZD", CH: "CHF", LI: "CHF", JP: "JPY", CN: "CNY", IN: "INR",
  BR: "BRL", MX: "MXN", SE: "SEK", NO: "NOK", DK: "DKK", PL: "PLN", CZ: "CZK", HU: "HUF", RO: "RON", BG: "BGN",
  TR: "TRY", ZA: "ZAR", SG: "SGD", HK: "HKD", KR: "KRW", IL: "ILS", TH: "THB", ID: "IDR", MY: "MYR", PH: "PHP", IS: "ISK",
  FR: "EUR", DE: "EUR", IT: "EUR", ES: "EUR", PT: "EUR", NL: "EUR", BE: "EUR", AT: "EUR", IE: "EUR", FI: "EUR", GR: "EUR",
  LU: "EUR", SK: "EUR", SI: "EUR", EE: "EUR", LV: "EUR", LT: "EUR", MT: "EUR", CY: "EUR", HR: "EUR", MC: "EUR",
  // Zone franc / Maghreb : rattaches a l'euro (pas de taux BCE direct)
  SN: "EUR", CI: "EUR", CM: "EUR", MA: "EUR", TN: "EUR", DZ: "EUR", GA: "EUR", CG: "EUR", BF: "EUR", ML: "EUR", BJ: "EUR", TG: "EUR",
};
const LANG_CURRENCY = { fr: "EUR", de: "EUR", it: "EUR", es: "EUR", pt: "EUR", nl: "EUR", en: "USD" };
let displayCurrency = "CHF";
let fxRates = { CHF: 1 };

function detectCurrency() {
  const langs = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || "en-US"];
  for (const l of langs) {
    const region = (l.split("-")[1] || "").toUpperCase();
    if (region && REGION_CURRENCY[region]) return REGION_CURRENCY[region];
  }
  const base = (langs[0] || "en").split("-")[0].toLowerCase();
  return LANG_CURRENCY[base] || "USD";
}

async function loadFx() {
  try {
    const data = await Promise.race([
      fetchJson("/api/fx"),
      new Promise((_, rej) => setTimeout(() => rej(new Error("fx timeout")), 3500)),
    ]);
    const cur = detectCurrency();
    if (data && data.rates && data.rates[cur]) {
      fxRates = data.rates;
      displayCurrency = cur;
    }
  } catch { /* taux indisponibles : les prix restent affiches en CHF */ }
}

function formatPrice(chfAmount) {
  let v = chfAmount * (fxRates[displayCurrency] || 1);
  if (v >= 10000) v = Math.round(v / 100) * 100;
  else if (v >= 1000) v = Math.round(v / 10) * 10;
  else v = Math.round(v);
  try {
    return new Intl.NumberFormat(navigator.language || BK_LOCALE(), { style: "currency", currency: displayCurrency, maximumFractionDigits: 0 }).format(v);
  } catch {
    return `${displayCurrency} ${v}`;
  }
}

function applyCurrencyToStatic() {
  document.querySelectorAll("[data-chf]").forEach((el) => { el.textContent = formatPrice(Number(el.dataset.chf)); });
  const note = document.getElementById("pricing-currency-note");
  if (note) {
    note.textContent = displayCurrency === "CHF"
      ? "Prix en CHF (devise de facturation), hors taxes."
      : `Prix affichés en ${displayCurrency}, convertis depuis le CHF (devise de facturation) au taux du jour, à titre indicatif ; hors taxes.`;
  }
}

async function fetchJson(url, opts) {
  const res = await fetch(url, opts);
  const text = await res.text();
  if (!text) {
    // Corps vide (pipeline coupe/redemarre avant sa reponse, proxy
    // qui tranche une requete trop longue...) : res.json() levait ici
    // "Unexpected end of JSON input", affiche tel quel au client —
    // remplace par un message comprehensible (2026-09-24).
    throw new Error(res.ok ? "Réponse vide du serveur, réessayez." : `Erreur serveur (${res.status}), réessayez.`);
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new Error("Réponse invalide du serveur, réessayez.");
  }
}

function statusClass(status) {
  if (status === "EXECUTED") return "executed";
  if (status === "SECURITY_BLOCKED" || status === "BLOCKED" || status === "NEEDS_CHLOE_VERIFICATION") return "blocked";
  return "routed";
}

function setPersistentVideo(imgEl, videoEl, videoUrl) {
  if (videoUrl && VIDEO_ENABLED) {
    videoEl.hidden = false;
    videoEl.src = videoUrl;
    videoEl.play().catch(() => {});
  } else {
    videoEl.hidden = true;
    videoEl.pause();
    videoEl.removeAttribute("src");
  }
}

function humanizeTag(t) {
  return String(t).replaceAll("_", " ").toLowerCase();
}

// ---------- PORTE D'ACCES (protege les vues operationnelles ; la
// vitrine publique reste ouverte sans mot de passe) ----------

// "onboarding" n'a plus d'entree publique mais
// reste protegee si jamais atteinte directement, avec le mot de passe
// historique de Kader (GATED_VIEWS).
//
// 2026-09-23 : plus AUCUNE vue n'est bloquee a l'entree par un compte —
// Analytics/Facturation/Automatisations s'affichent librement, comme
// Workers/Tarifs/FAQ (meme logique que Delos : on visite tout, on ne se
// connecte que pour la donnee personnelle ou l'action elle-meme). Ce que
// chaque vue affiche a la place de la donnee reelle quand personne n'est
// connecte est gere au cas par cas dans loadAnalytics()/loadBilling()/
// loadAutomations() (voir #analytics-connect-required, #billing-connect-
// required, et le rendu inline dans #automation-list).
const GATED_VIEWS = ["admin"];
const ACCOUNT_GATED_VIEWS = [];

async function checkGateStatus() {
  try {
    const data = await fetchJson("/api/gate/status");
    gateAuthenticated = !data.enabled || !!data.authenticated;
  } catch (err) {
    gateAuthenticated = false;
  }
}

function syncAdminNavVisibility() {
  document.getElementById("nav-admin").hidden = !isOperator;
  syncAccountButtonLabel();
}

function syncAccountButtonLabel() {
  const btn = document.getElementById("topbar-account-btn");
  const logoutBtn = document.getElementById("topbar-logout-btn");
  if (!btn) return;
  if (!accountAuthenticated) {
    btn.textContent = "Se connecter";
  } else if (isOperator) {
    btn.textContent = "Mon compte (propriétaire)";
  } else {
    btn.textContent = "Mon compte (client)";
  }
  if (logoutBtn) logoutBtn.hidden = !accountAuthenticated;
}

// Deconnexion complete (2026-09-30) : avant, aucun bouton ne deconnectait
// jamais rien — une session compte client restee active masquait le mode
// propriétaire indefiniment, sans aucun moyen de s'en sortir depuis
// l'interface (signale par Kader : plusieurs outils bloques sur "Bientot"
// alors qu'il pensait etre connecte comme proprietaire). Efface les DEUX
// sessions possibles (compte client ET porte proprietaire) a chaque fois,
// pour ne plus jamais dependre de savoir laquelle est active.
async function fullLogout() {
  await Promise.allSettled([
    fetchJson("/api/account/logout", { method: "POST" }),
    fetchJson("/api/gate/logout", { method: "POST" }),
  ]);
  window.location.reload();
}

function requireGate(action) {
  if (gateAuthenticated) {
    action();
    return;
  }
  pendingGateAction = action;
  document.getElementById("gate-error").hidden = true;
  const input = document.getElementById("gate-password-input");
  input.value = "";
  document.getElementById("gate-modal").hidden = false;
  input.focus();
}

async function checkAccountStatus() {
  try {
    const data = await fetchJson("/api/account/me");
    accountAuthenticated = !!data.loggedIn;
    isOperator = !!data.operator;
    accountEmailVerified = data.emailVerified !== false;
  } catch (err) {
    accountAuthenticated = false;
    isOperator = false;
  }
}

function requireAccount(action) {
  if (accountAuthenticated) {
    action();
    return;
  }
  pendingAccountAction = action;
  showAccountTab("signup");
  document.getElementById("account-modal").hidden = false;
}

function showAccountTab(tab) {
  const isSignup = tab === "signup";
  document.getElementById("account-panel-signup").hidden = !isSignup;
  document.getElementById("account-panel-login").hidden = isSignup;
  document.getElementById("account-tab-signup").classList.toggle("active", isSignup);
  document.getElementById("account-tab-login").classList.toggle("active", !isSignup);
}

function closeAccountModal() {
  document.getElementById("account-modal").hidden = true;
  pendingAccountAction = null;
}

// Kader lui-meme n'a pas a s'inscrire comme son propre client : ce lien
// bascule de la modale d'inscription client vers son mot de passe
// historique, en conservant l'action en attente (ex. ouvrir Analytics)
// pour qu'elle se declenche des la connexion reussie.
function switchToOwnerLogin() {
  const action = pendingAccountAction;
  pendingAccountAction = null;
  document.getElementById("account-modal").hidden = true;
  requireGate(() => {
    accountAuthenticated = true;
    isOperator = true;
    if (action) action();
  });
}

async function afterAccountUnlocked() {
  accountAuthenticated = true;
  syncAccountButtonLabel();
  document.getElementById("account-modal").hidden = true;
  const action = pendingAccountAction;
  pendingAccountAction = null;
  if (action) action();
}

async function submitAccountSignup() {
  const errorEl = document.getElementById("account-signup-error");
  errorEl.hidden = true;
  const email = document.getElementById("account-signup-email").value.trim();
  const password = document.getElementById("account-signup-password").value;
  const companyName = document.getElementById("account-signup-company").value.trim();
  try {
    const result = await fetchJson("/api/account/signup", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password, companyName }),
    });
    if (result.error) {
      const messages = {
        EMAIL_INVALID: "Adresse email invalide.",
        PASSWORD_TOO_SHORT: "Le mot de passe doit faire au moins 8 caractères.",
        EMAIL_ALREADY_USED: "Un compte existe déjà avec cet email — connectez-vous plutôt.",
        RATE_LIMITED: "Trop de créations de compte depuis cette connexion. Réessayez plus tard.",
      };
      errorEl.textContent = messages[result.error] || ("Erreur : " + result.error);
      errorEl.hidden = false;
      return;
    }
    await afterAccountUnlocked();
  } catch (err) {
    errorEl.textContent = "Erreur réseau : " + err.message;
    errorEl.hidden = false;
  }
}

async function submitAccountLogin() {
  const errorEl = document.getElementById("account-login-error");
  errorEl.hidden = true;
  const email = document.getElementById("account-login-email").value.trim();
  const password = document.getElementById("account-login-password").value;
  try {
    const result = await fetchJson("/api/account/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password }),
    });
    if (result.error) {
      errorEl.textContent = result.error === "TOO_MANY_ATTEMPTS" ? "Trop de tentatives. Réessayez dans quelques minutes." : "Email ou mot de passe incorrect.";
      errorEl.hidden = false;
      return;
    }
    await afterAccountUnlocked();
  } catch (err) {
    errorEl.textContent = "Erreur réseau : " + err.message;
    errorEl.hidden = false;
  }
}

async function submitGatePassword() {
  const input = document.getElementById("gate-password-input");
  const errorEl = document.getElementById("gate-error");
  errorEl.hidden = true;
  try {
    const result = await fetchJson("/api/gate/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ password: input.value }),
    });
    if (result.error) {
      errorEl.textContent = result.error === "TOO_MANY_ATTEMPTS" ? "Trop de tentatives. Réessayez dans quelques minutes." : "Mot de passe incorrect.";
      errorEl.hidden = false;
      return;
    }
    gateAuthenticated = true;
    // Le mot de passe historique de Kader vaut aussi acces "compte" cote
    // serveur (voir _resolve_client_id -> CLI-DASHBOARD) : le refleter ici
    // pour que les vues protegees par compte (Analytics/Facturation/
    // Automatisations) se debloquent immediatement, sans rechargement.
    accountAuthenticated = true;
    isOperator = true;
    syncAdminNavVisibility();
    document.getElementById("gate-modal").hidden = true;
    const action = pendingGateAction;
    pendingGateAction = null;
    if (action) action();
  } catch (err) {
    errorEl.textContent = "Erreur réseau : " + err.message;
    errorEl.hidden = false;
  }
}

// Met en surbrillance le lien de la vue active dans la nav principale
// (2026-09-24 : avant ce correctif, aucun lien n'indiquait jamais "vous
// etes ici", contrairement a Delos/Limova — un detail de navigation
// que Kader a explicitement demande de soigner).
const NAV_LINK_VIEW_MAP = {
  "nav-home": "home",
  "nav-onboarding": "onboarding",
  "nav-catalog": "workers",
  "nav-automations": "automations",
  "nav-analytics": "analytics",
  "nav-pricing": "pricing",
  "nav-faq": "faq",
  "nav-billing": "billing",
  "nav-admin": "admin",
};

function syncActiveNavLink(name) {
  Object.entries(NAV_LINK_VIEW_MAP).forEach(([id, viewName]) => {
    const el = document.getElementById(id);
    if (el) el.classList.toggle("is-active", viewName === name);
  });
  const chloeLink = document.getElementById("nav-chloe");
  if (chloeLink) chloeLink.classList.toggle("is-active", name === "profile" && currentWorkerId === "chloe");
}

function showView(name) {
  if (GATED_VIEWS.includes(name) && !gateAuthenticated) {
    requireGate(() => showView(name));
    return;
  }
  if (ACCOUNT_GATED_VIEWS.includes(name) && !accountAuthenticated) {
    requireAccount(() => showView(name));
    return;
  }

  homeView.hidden = name !== "home";
  workersView.hidden = name !== "workers";
  automationsView.hidden = name !== "automations";
  analyticsView.hidden = name !== "analytics";
  onboardingView.hidden = name !== "onboarding";
  billingView.hidden = name !== "billing";
  pricingView.hidden = name !== "pricing";
  faqView.hidden = name !== "faq";
  legalView.hidden = name !== "legal";
  profileView.hidden = name !== "profile";
  adminView.hidden = name !== "admin";
  syncActiveNavLink(name);
  window.scrollTo(0, 0);
  // Rejoue la transition d'entree a chaque changement de vue : sans ce
  // retrait/reflow/reajout, la classe resterait presente des le premier
  // affichage et l'animation ne se rejouerait jamais (le site paraissait
  // statique — aucune vue ne "bougeait" en y naviguant).
  const enteringView = document.getElementById(name + "-view");
  if (enteringView) {
    enteringView.classList.remove("view-enter");
    void enteringView.offsetWidth;
    enteringView.classList.add("view-enter");
  }
  if (name === "automations") {
    loadAutomations();
    loadConnectors();
    loadZapierCard();
  }
  if (name === "analytics") {
    loadAnalytics();
  }
  if (name === "onboarding") {
    resetOnboarding();
  }
  if (name === "billing") {
    loadBilling();
  }
  if (name === "admin") {
    loadAdminOverview();
  }
}

// ---------- ANALYTICS (donnees reelles, temps gagne = estimation) ----------

async function loadAnalytics() {
  const data = await fetchJson("/api/analytics");

  const connectPrompt = document.getElementById("analytics-connect-required");
  const content = document.getElementById("analytics-content");
  if (data.error === "ACCOUNT_REQUIRED") {
    connectPrompt.hidden = false;
    content.hidden = true;
    return;
  }
  connectPrompt.hidden = true;
  content.hidden = false;

  const statsGrid = document.getElementById("analytics-stats-grid");
  statsGrid.innerHTML = "";
  const stats = [
    { num: data.totalMissions, label: "Missions traitées" },
    { num: data.distinctWorkersUsed, label: "Workers ayant travaillé" },
    { num: data.automationsActive, label: "Automatisations actives" },
    { num: data.automationRunsTotal, label: "Exécutions automatisées" },
  ];
  stats.forEach((s) => {
    const card = document.createElement("div");
    card.className = "analytics-stat-card";
    card.innerHTML = `<div class="analytics-stat-num">0</div><div class="analytics-stat-label">${s.label}</div>`;
    statsGrid.appendChild(card);
    animateNumber(card.querySelector(".analytics-stat-num"), s.num);
  });

  const workerBars = document.getElementById("analytics-worker-bars");
  workerBars.innerHTML = "";
  const workerEntries = Object.entries(data.byWorker || {})
    .filter(([name]) => name && name !== "INCONNU")
    .sort((a, b) => b[1] - a[1]);
  const maxWorkerCount = Math.max(1, ...workerEntries.map(([, c]) => c));
  workerEntries.forEach(([name, count]) => {
    const row = document.createElement("div");
    row.className = "analytics-bar-row";
    const pct = Math.round((count / maxWorkerCount) * 100);
    row.innerHTML = `
      <div class="analytics-bar-name">${name.toLowerCase()}</div>
      <div class="analytics-bar-track"><div class="analytics-bar-fill" style="width:${pct}%"></div></div>
      <div class="analytics-bar-count">${count}</div>
    `;
    workerBars.appendChild(row);
  });
  if (workerEntries.length === 0) {
    workerBars.innerHTML = '<div class="activity-empty">Aucune mission traitée pour le moment.</div>';
  }

  const statusBars = document.getElementById("analytics-status-bars");
  statusBars.innerHTML = "";
  const statusEntries = Object.entries(data.byStatus || {}).sort((a, b) => b[1] - a[1]);
  const maxStatusCount = Math.max(1, ...statusEntries.map(([, c]) => c));
  statusEntries.forEach(([status, count]) => {
    const row = document.createElement("div");
    row.className = "analytics-bar-row";
    const pct = Math.round((count / maxStatusCount) * 100);
    row.innerHTML = `
      <div class="analytics-bar-name">${status.toLowerCase()}</div>
      <div class="analytics-bar-track"><div class="analytics-bar-fill status-${status}" style="width:${pct}%"></div></div>
      <div class="analytics-bar-count">${count}</div>
    `;
    statusBars.appendChild(row);
  });

  const c = data.aiCost;
  if (c && c.aiCalls > 0) {
    [
      { num: c.aiCalls, label: "Appels IA réels" },
      { num: (c.inputTokens + c.outputTokens).toLocaleString(BK_LOCALE()), label: "Tokens consommés" },
      { num: "≈ " + c.estimatedCostUsd.toFixed(2) + " $", label: "Coût IA estimé" },
      { num: "≈ " + c.avgCostUsdPerCall.toFixed(3) + " $", label: "Coût moyen / appel" },
    ].forEach((s) => {
      const card = document.createElement("div");
      card.className = "analytics-stat-card";
      card.innerHTML = `<div class="analytics-stat-num">${s.num}</div><div class="analytics-stat-label">${s.label}</div>`;
      statsGrid.appendChild(card);
    });
  }

  const timeNote = document.getElementById("analytics-time-note");
  const hours = Math.round((data.estimatedMinutesSaved / 60) * 10) / 10;
  timeNote.innerHTML = `⏱️ <strong>Temps estimé évité : ~${hours} h</strong> (${data.estimatedMinutesSaved} min). ${data.estimatedMinutesSavedNote}` +
    (c && c.aiCalls > 0 ? `<br>💸 <strong>Coût IA</strong> : ${c.note}` : "");
}

// ---------- ONBOARDING (Chloé propose une equipe, l'utilisateur valide
// AVANT toute execution reelle — PlanOnly puis /api/chloe/task) ----------

let onboardingObjective = "";

function onboardingSetStep(step) {
  document.getElementById("onboarding-step-1").hidden = step !== 1;
  document.getElementById("onboarding-step-2").hidden = step !== 2;
  document.getElementById("onboarding-step-3").hidden = step !== 3;
  document.getElementById("onboarding-step-4").hidden = step !== 4;
  document.querySelectorAll(".onboarding-step-dot").forEach((dot) => {
    const n = Number(dot.dataset.step);
    dot.classList.toggle("active", n === step);
    dot.classList.toggle("done", n < step);
  });
}

async function resetOnboarding() {
  onboardingObjective = "";
  document.getElementById("onboarding-company-name").value = "";
  document.getElementById("onboarding-company-sector").value = "";
  document.getElementById("onboarding-company-description").value = "";
  // Pre-remplit avec le profil deja enregistre (evite de tout ressaisir).
  fetchJson("/api/profile").then((p) => {
    if (!p || p.error) return;
    document.getElementById("onboarding-company-name").value = p.companyName || "";
    document.getElementById("onboarding-company-sector").value = p.sector || "";
    document.getElementById("onboarding-company-description").value = p.description || "";
  }).catch(() => {});
  document.getElementById("onboarding-objective").value = "";
  document.getElementById("onboarding-analyze-error").hidden = true;
  document.getElementById("onboarding-team-grid").innerHTML = "";
  document.getElementById("onboarding-result").innerHTML = "";
  onboardingSetStep(1);
}

async function onboardingAnalyze() {
  const objective = document.getElementById("onboarding-objective").value.trim();
  const errorEl = document.getElementById("onboarding-analyze-error");
  errorEl.hidden = true;

  if (!objective) {
    errorEl.textContent = "Décris d'abord ton objectif.";
    errorEl.hidden = false;
    return;
  }

  const btn = document.getElementById("onboarding-analyze-btn");
  btn.disabled = true;
  btn.textContent = "Chloé analyse...";

  try {
    const result = await fetchJson("/api/chloe/plan", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ objective }),
    });

    if (result.error || !result.SelectedWorkers || result.SelectedWorkers.length === 0) {
      errorEl.textContent = "Chloé n'a identifié aucun Worker pour cette demande. Essaie de reformuler ton objectif.";
      errorEl.hidden = false;
      return;
    }

    onboardingObjective = objective;

    const grid = document.getElementById("onboarding-team-grid");
    grid.innerHTML = "";
    const matched = result.SelectedWorkers
      .map((id) => allWorkers.find((w) => w.id.toLowerCase() === String(id).toLowerCase()))
      .filter(Boolean);

    document.getElementById("onboarding-team-sub").textContent =
      `Chloé propose ${matched.length > 1 ? "cette équipe" : "ce Worker"} pour ta mission :`;

    matched.forEach((w) => {
      const card = document.createElement("div");
      card.className = "onboarding-team-card";
      const svgClass = w.portraitUrl.endsWith(".svg") ? "is-svg" : "";
      card.innerHTML = `
        <img class="${svgClass}" src="${w.portraitUrl}" alt="${w.name}">
        <div class="onboarding-team-card-name">${w.name}</div>
        <div class="onboarding-team-card-role">${w.category}</div>
      `;
      grid.appendChild(card);
    });

    onboardingSetStep(3);
  } catch (err) {
    errorEl.textContent = "Erreur réseau : " + err.message;
    errorEl.hidden = false;
  } finally {
    btn.disabled = false;
    btn.textContent = "Demander à Chloé →";
  }
}

async function onboardingValidate() {
  const btn = document.getElementById("onboarding-validate-btn");
  btn.disabled = true;
  btn.textContent = "Mission en cours...";

  try {
    const result = await fetchJson("/api/chloe/task", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ objective: onboardingObjective }),
    });

    const resultEl = document.getElementById("onboarding-result");
    const blocked = result.error || result.Status !== "SUCCESS";
    resultEl.className = "task-result" + (blocked ? " needs-chloe" : "");
    const workers = (result.SelectedWorkers || []).join(", ");
    const statusLine = blocked ? (chloeStatusLabel(result.Status) || "Résultat indisponible") : `Traité par : ${workers}`;
    resultEl.innerHTML = `<div class="status-line">${statusLine}</div>${renderAnswer(result.FinalSynthesis || "Aucune synthèse disponible.")}`;

    onboardingSetStep(4);
  } catch (err) {
    const resultEl = document.getElementById("onboarding-result");
    resultEl.className = "task-result needs-chloe";
    resultEl.innerHTML = `<div class="status-line">Erreur réseau</div>${err.message}`;
    onboardingSetStep(4);
  } finally {
    btn.disabled = false;
    btn.textContent = "Valider et lancer la mission →";
  }
}

// ---------- ADMIN (vue proprietaire : tous les comptes reels, jamais
// visible par un client — voir GATED_VIEWS et /api/admin/overview) ----------

const ADMIN_KIND_LABEL = { signup: "Inscription", login: "Connexion", mission: "Mission", plan: "Abonnement", demo: "Démo" };
let adminActivityTimer = null;

async function loadAdminActivity() {
  loadAdminDemos();
  loadAdminTestimonials();
  if (window.loadAdminPilot) window.loadAdminPilot();   // candidatures du programme pilote (pilot-admin.js)
  const data = await fetchJson("/api/admin/activity");
  if (data.error) return;
  const t = data.last24h || {};
  document.getElementById("admin-24h-grid").innerHTML = [
    ["Inscriptions", t.signups], ["Connexions", t.logins], ["Missions", t.missions], ["Abonnements", t.planChanges],
  ].map(([label, n]) => `<div class="trust-card"><div class="trust-num">${n || 0}</div><div class="trust-label">${label} (24 h)</div></div>`).join("");
  const list = document.getElementById("admin-activity-list");
  const events = data.events || [];
  list.innerHTML = events.length
    ? events.map((e) => `<div class="admin-activity-row kind-${e.kind}"><span class="admin-activity-when">${new Date(e.atUtc).toLocaleString(BK_LOCALE())}</span><span class="admin-activity-kind">${ADMIN_KIND_LABEL[e.kind] || e.kind}</span><span class="admin-activity-who">${escapeHtml(e.who || "")}</span><span class="admin-activity-text">${escapeHtml(e.text || "")}</span></div>`).join("")
    : '<div class="activity-empty">Aucune activité pour le moment.</div>';
}

async function loadAdminOverview() {
  loadAdminActivity();
  clearInterval(adminActivityTimer);
  adminActivityTimer = setInterval(() => { if (!adminView.hidden) loadAdminActivity(); }, 30000);
  const data = await fetchJson("/api/admin/overview");
  if (data.error) return;

  const statsGrid = document.getElementById("admin-stats-grid");
  statsGrid.innerHTML = `
    <div class="trust-card">
      <div class="trust-num">${data.totalClients}</div>
      <div class="trust-label">Comptes au total (vous inclus)</div>
    </div>
    <div class="trust-card">
      <div class="trust-num">${data.totalRealClients}</div>
      <div class="trust-label">Clients inscrits</div>
    </div>
    <div class="trust-card">
      <div class="trust-num">${data.totalMissionsAllClients}</div>
      <div class="trust-label">Missions traitées, tous comptes confondus</div>
    </div>
    <div class="trust-card">
      <div class="trust-num">${data.totalAutomationsActiveAllClients}</div>
      <div class="trust-label">Automatisations actives, tous comptes confondus</div>
    </div>
  `;

  const list = document.getElementById("admin-clients-list");
  list.innerHTML = "";
  if (data.clients.length === 0) {
    list.innerHTML = '<div class="activity-empty">Aucun compte pour le moment.</div>';
    return;
  }
  data.clients.forEach((c) => {
    const row = document.createElement("div");
    row.className = "admin-client-row";
    row.tabIndex = 0;
    const signup = c.createdAtUtc ? new Date(c.createdAtUtc).toLocaleDateString(BK_LOCALE()) : "—";
    const creditsLabel = c.isOwner ? "Illimité" : `${c.creditsUsed}${c.creditsTotal !== null ? " / " + c.creditsTotal : ""}`;
    row.innerHTML = `
      <div class="admin-client-row-head">
        <div>
          <div class="admin-client-name">${c.label}${c.isOwner ? " · propriétaire" : ""}</div>
          <div class="admin-client-meta">${c.email || "—"} · ${c.clientId} · inscrit le ${signup} · plan ${c.planName}</div>
        </div>
        <div class="admin-client-stats">
          <div><strong>${c.totalMissions}</strong><span>Missions</span></div>
          <div><strong>${c.automationsActive}</strong><span>Automatisations</span></div>
          <div><strong>${creditsLabel}</strong><span>Crédits</span></div>
        </div>
      </div>
      <div class="admin-client-detail" hidden></div>
    `;
    const head = row.querySelector(".admin-client-row-head");
    const detail = row.querySelector(".admin-client-detail");
    const toggle = async () => {
      const opening = detail.hidden;
      detail.hidden = !opening;
      row.classList.toggle("open", opening);
      if (opening && !detail.dataset.loaded) {
        detail.innerHTML = '<div class="activity-empty">Chargement…</div>';
        const activityData = await fetchJson(`/api/admin/client/${encodeURIComponent(c.clientId)}/activity`);
        const items = activityData.activity || [];
        detail.dataset.loaded = "1";
        if (items.length === 0) {
          detail.innerHTML = '<div class="activity-empty">Aucune mission pour ce compte.</div>';
          return;
        }
        detail.innerHTML = items.map((a) => {
          const cls = a.authorized === false ? "blocked" : (a.status === "NEEDS_CHLOE_VERIFICATION" ? "needs-chloe" : "");
          const statusLine = a.authorized === false ? (a.status || "Bloqué") : "Exécuté";
          const answer = a.answer || a.executionNote || "Aucune réponse enregistrée.";
          const when = a.createdAtUtc ? new Date(a.createdAtUtc).toLocaleString(BK_LOCALE()) : "—";
          return `
            <div class="chat-turn">
              <div class="admin-detail-meta">${escapeHtml(a.worker || "?")} · ${when}</div>
              <div class="chat-msg chat-msg-user">${escapeHtml(a.request || "")}</div>
              <div class="chat-msg chat-msg-worker ${cls}"><div class="status-line">${escapeHtml(statusLine)}</div>${renderAnswer(answer)}</div>
            </div>
          `;
        }).join("");
      }
    };
    head.addEventListener("click", toggle);
    head.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); } });
    list.appendChild(row);
  });
}

// ---------- BILLING (plan actif + quota reel + historique — aucun
// paiement reel n'est jamais declenche depuis cette page) ----------

// CHF, en dur car PLAN_CATALOG (cote serveur) ne porte que les credits —
// les prix eux-memes vivent dans PRICING_PLANS (page Tarifs) plus haut.
// Doit rester coherent avec les Price ID Stripe (prices / pricesAnnual)
// que Kader saisit lui-meme cote serveur.
const BILLING_PLAN_PRICES = {
  starter: { month: 39, year: 390 },
  business: { month: 99, year: 990 },
  pro: { month: 139, year: 1390 },
  scale: { month: 449, year: 4490 },
};

let billingInterval = "month";

async function loadBilling() {
  const data = await fetchJson("/api/billing");

  const connectPrompt = document.getElementById("billing-connect-required");
  const content = document.getElementById("billing-content");
  if (data.error === "ACCOUNT_REQUIRED") {
    connectPrompt.hidden = false;
    content.hidden = true;
    return;
  }
  connectPrompt.hidden = true;
  content.hidden = false;
  const dataSection = document.getElementById("account-data-section");
  if (dataSection) dataSection.hidden = isOperator;
  const vBanner = document.getElementById("verify-email-banner");
  if (vBanner) vBanner.hidden = isOperator || accountEmailVerified;

  // Administrateur/createur : aucun credit, aucun plan, aucune recharge —
  // il n'est pas un client (demande de Kader, 2026-09-25). Le serveur ne
  // le bloque deja jamais (subscription_blocks_mission) ; l'interface
  // ne doit donc plus lui presenter de quota.
  if (isOperator) {
    document.getElementById("billing-content").innerHTML = `
      <div class="billing-current-card">
        <div class="billing-current-label">Compte</div>
        <div class="billing-current-plan">Administrateur — accès illimité</div>
        <p class="hero-sub" style="margin:10px 0 0;text-align:left">Aucun crédit, aucun plan : tes missions ne sont jamais limitées. Le suivi des clients (inscriptions, connexions, abonnements, missions) est dans l'onglet <strong>Admin</strong>.</p>
      </div>`;
    return;
  }

  document.getElementById("billing-plan-name").textContent = data.planName;

  const fill = document.getElementById("billing-usage-fill");
  const pct = data.unlimited ? 0 : Math.min(100, data.percentUsed || 0);
  fill.style.width = pct + "%";
  fill.classList.toggle("alert", !!data.alertThresholdReached);

  const line = document.getElementById("billing-usage-line");
  line.textContent = data.unlimited
    ? `${data.creditsUsed} missions traitées ce cycle — quota illimité (Enterprise).`
    : `${data.creditsUsed} / ${data.creditsTotal} crédits consommés (${data.creditsRemaining} restants).`;

  document.getElementById("billing-alert").hidden = !data.alertThresholdReached;

  const cancelBtn = document.getElementById("billing-cancel-btn");
  cancelBtn.hidden = data.planId === "essai";

  const grid = document.getElementById("billing-plans-grid");
  grid.innerHTML = "";
  data.availablePlans.forEach((plan) => {
    const card = document.createElement("div");
    card.className = "billing-plan-card" + (plan.planId === data.planId ? " active" : "");
    const creditsLabel = plan.credits === null ? "Illimité" : `${plan.credits} crédits / cycle`;
    const prices = BILLING_PLAN_PRICES[plan.planId];
    const priceLabel = prices
      ? `${formatPrice(prices[billingInterval])}${billingInterval === "month" ? "/mois" : "/an"}`
      : "";
    card.innerHTML = `
      <div class="billing-plan-name">${plan.name}</div>
      ${priceLabel ? `<div class="billing-plan-price">${priceLabel}</div>` : ""}
      <div class="billing-plan-credits">${creditsLabel}</div>
      <button type="button" class="btn ${plan.planId === data.planId ? "btn-ghost" : "btn-gold"}" ${plan.planId === data.planId ? "disabled" : ""}>
        ${plan.planId === data.planId ? "Plan actif" : "Choisir"}
      </button>
    `;
    if (plan.planId !== data.planId) {
      card.querySelector("button").addEventListener("click", () => switchBillingPlan(plan.planId, billingInterval));
    }
    grid.appendChild(card);
  });

  const history = document.getElementById("billing-history");
  history.innerHTML = "";
  if (data.history.length === 0) {
    history.innerHTML = '<div class="activity-empty">Aucun évènement pour le moment.</div>';
  }
  data.history.forEach((h) => {
    const row = document.createElement("div");
    row.className = "billing-history-row";
    const when = h.dateUtc ? new Date(h.dateUtc).toLocaleString(BK_LOCALE()) : "";
    row.innerHTML = `<div class="billing-history-date">${when}</div>${h.event}`;
    history.appendChild(row);
  });
}

async function switchBillingPlan(planId, interval) {
  const result = await fetchJson("/api/billing/plan", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ planId, interval: interval || "month" }),
  });
  if (result.error === "ACCOUNT_REQUIRED") {
    requireAccount(() => switchBillingPlan(planId, interval));
    return;
  }
  if (result.checkoutUrl) {
    // Paiement reel via Stripe : on quitte le dashboard pour la page
    // hebergee par Stripe elle-meme (carte jamais saisie ici).
    window.location.href = result.checkoutUrl;
    return;
  }
  if (result.error === "EMAIL_NOT_VERIFIED") {
    showToast("Confirmez d'abord votre email (lien reçu à l'inscription) pour souscrire un plan.", false);
    await checkAccountStatus();
    await loadBilling();
    return;
  }
  if (result.error) {
    alert("Erreur : " + (result.detail || result.error));
    return;
  }
  await loadBilling();
}

async function handleStripeCheckoutReturn() {
  const params = new URLSearchParams(window.location.search);
  const checkout = params.get("billing_checkout");
  if (!checkout) return;

  const sessionId = params.get("session_id");
  window.history.replaceState({}, "", window.location.pathname);

  if (checkout === "success" && sessionId) {
    showView("billing");
    const result = await fetchJson("/api/billing/stripe-confirm", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sessionId }),
    });
    if (result.error) {
      alert("Le paiement n'a pas pu être confirmé : " + (result.detail || result.error));
    }
    await loadBilling();
  } else if (checkout === "cancel") {
    showView("billing");
  }
}

async function cancelBillingPlan() {
  await fetchJson("/api/billing/cancel", { method: "POST" });
  await loadBilling();
}

async function rechargeBillingCredits() {
  const input = document.getElementById("billing-recharge-amount");
  const amount = parseInt(input.value, 10);
  if (!amount || amount <= 0) return;
  await fetchJson("/api/billing/recharge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ amount }),
  });
  input.value = "";
  await loadBilling();
}

// ---------- AUTOMATISATIONS (missions recurrentes, vrai pipeline) ----------

const FREQUENCY_LABELS = {
  60: "Toutes les heures",
  1440: "Tous les jours",
  10080: "Toutes les semaines",
  43200: "Tous les mois",
};

function renderAutomationWorkerOptions() {
  const select = document.getElementById("automation-worker-select");
  select.innerHTML = "";
  const chloeOpt = document.createElement("option");
  chloeOpt.value = "chloe";
  chloeOpt.textContent = "Chloé";
  select.appendChild(chloeOpt);
  allWorkers.forEach((w) => {
    const opt = document.createElement("option");
    opt.value = w.id;
    opt.textContent = w.name;
    select.appendChild(opt);
  });
}

function workerNameById(id) {
  if (id === "chloe") return "Chloé";
  const w = allWorkers.find((x) => x.id === id);
  return w ? w.name : id;
}

function showAutomationError(message) {
  const errorEl = document.getElementById("automation-error");
  errorEl.textContent = message;
  errorEl.hidden = false;
}

// Gere les erreurs communes a toutes les actions d'automatisation
// (compte expire entre-temps, quota epuise) sans dupliquer cette logique
// dans chaque bouton. Retourne true si l'erreur a ete geree (l'appelant
// doit alors s'arreter), false si tout s'est bien passe.
function handleAutomationError(result, retryAction) {
  if (!result || !result.error) return false;
  if (result.error === "ACCOUNT_REQUIRED") {
    requireAccount(() => { retryAction(); loadAutomations(); });
    return true;
  }
  if (result.error === "SUBSCRIPTION_REQUIRED") {
    showAutomationError(result.detail || "Votre quota est épuisé. Souscrivez un abonnement pour continuer.");
    return true;
  }
  showAutomationError("Erreur : " + (result.detail || result.error));
  return true;
}

async function loadAutomations() {
  const listEl = document.getElementById("automation-list");
  const data = await fetchJson("/api/automations");
  if (data.error === "ACCOUNT_REQUIRED") {
    // Simple visite de la page : on invite a se connecter au lieu
    // d'ouvrir la modale automatiquement (elle, ne s'ouvre que sur une
    // vraie action — creer/activer/executer/supprimer).
    listEl.innerHTML = `<div class="connect-required">
      <p>Connectez-vous pour voir et gérer vos automatisations.</p>
      <button type="button" class="btn btn-gold" id="automation-connect-btn">Se connecter / Créer un compte</button>
    </div>`;
    document.getElementById("automation-connect-btn").addEventListener("click", () => requireAccount(() => loadAutomations()));
    return;
  }
  if (handleAutomationError(data, () => {})) return;
  const automations = data.automations || [];

  if (automations.length === 0) {
    listEl.innerHTML = '<div class="automation-empty">Aucune automatisation pour le moment — créez-en une ci-dessus.</div>';
    return;
  }

  listEl.innerHTML = "";
  automations.forEach((a) => {
    const card = document.createElement("div");
    card.className = "automation-card" + (a.enabled ? "" : " is-disabled");
    const freqLabel = FREQUENCY_LABELS[a.frequencyMinutes] || `Toutes les ${a.frequencyMinutes} min`;
    const lastRun = a.lastRunAtUtc ? new Date(a.lastRunAtUtc).toLocaleString(BK_LOCALE()) : "pas encore — vérifiée toutes les 15 min, ou cliquez Exécuter maintenant";
    const slackNote = a.notifySlack ? " · 🔔 notifie Slack" : "";
    card.innerHTML = `
      <div class="automation-card-main">
        <div class="automation-card-objective">${workerNameById(a.workerId)} — ${a.objective}</div>
        <div class="automation-card-meta">${freqLabel}${slackNote} · dernière exécution : ${lastRun}${a.lastRunStatus ? " · " + a.lastRunStatus : ""}${a.enabled && a.nextRunAtUtc ? " · prochaine : " + new Date(a.nextRunAtUtc).toLocaleString(BK_LOCALE()) : ""}</div>
      </div>
      <span class="automation-card-status ${a.enabled ? "on" : "off"}">${a.enabled ? "Active" : "En pause"}</span>
      <div class="automation-card-actions">
        <button type="button" data-action="results">Voir les résultats${a.runCount ? " (" + a.runCount + ")" : ""}</button>
        <button type="button" data-action="run">Exécuter maintenant</button>
        <button type="button" data-action="toggle">${a.enabled ? "Mettre en pause" : "Réactiver"}</button>
        <button type="button" data-action="delete" class="btn-danger">Supprimer</button>
      </div>
    `;
    // Historique reel des executions : avant, une automatisation qui
    // tournait (livrable complet produit par les Workers) n'affichait
    // JAMAIS son resultat nulle part — d'ou "rien ne marche" pour Kader
    // alors que le moteur, le cron et les Workers fonctionnaient.
    const resultsPanel = document.createElement("div");
    resultsPanel.className = "automation-results";
    resultsPanel.hidden = true;
    card.appendChild(resultsPanel);
    card.querySelector('[data-action="results"]').addEventListener("click", async (e) => {
      if (!resultsPanel.hidden) { resultsPanel.hidden = true; return; }
      resultsPanel.hidden = false;
      resultsPanel.innerHTML = '<div class="activity-empty">Chargement…</div>';
      const data = await fetchJson(`/api/automations/${a.id}/runs`);
      const runs = data.runs || [];
      if (!runs.length) {
        resultsPanel.innerHTML = '<div class="activity-empty">Aucune exécution pour le moment. Elle se lancera automatiquement à la prochaine échéance, ou cliquez sur « Exécuter maintenant ».</div>';
        return;
      }
      resultsPanel.innerHTML = runs.map((r) => {
        const d = r.detail || {};
        const when = r.ranAtUtc ? new Date(r.ranAtUtc).toLocaleString(BK_LOCALE()) : "—";
        let body = "";
        if (d.FinalSynthesis) body = renderAnswer(d.FinalSynthesis);
        else if (d.Results && d.Results.length) {
          body = d.Results.map((x) => `<div class="admin-detail-meta">${escapeHtml(x.Worker || "")}</div>${renderAnswer((x.Result && x.Result.Answer) || "Pas de réponse.")}`).join("");
        } else if (d.Result && d.Result.Answer) body = renderAnswer(d.Result.Answer);
        else body = `<p>${escapeHtml(typeof d === "string" ? d : (r.status || "Aucun détail"))}</p>`;
        const ok = r.status === "SUCCESS" || r.status === "EXECUTED";
        return `<div class="automation-run"><div class="automation-run-head"><span>${when}</span><span class="automation-card-status ${ok ? "on" : "off"}">${escapeHtml(r.status || "")}</span></div>${body}</div>`;
      }).join("");
    });
    card.querySelector('[data-action="run"]').addEventListener("click", async (e) => {
      const runBtn = e.currentTarget;
      runBtn.disabled = true;
      runBtn.textContent = "En cours...";
      // Force CETTE automatisation tout de suite, sans regarder son
      // echeance (voir /api/automations/<id>/run cote serveur) — avant
      // ce correctif, ce bouton passait par toggle+tick, qui ignore
      // silencieusement une automatisation deja executee recemment
      // (par le cron ajoute le 2026-09-24) : le clic ne faisait alors
      // rigoureusement rien, sans le moindre message (signale par
      // Kader en conditions reelles).
      const runResult = await fetchJson(`/api/automations/${a.id}/run`, { method: "POST" });
      runBtn.disabled = false;
      runBtn.textContent = "Exécuter maintenant";
      if (handleAutomationError(runResult, () => {})) return;
      if (runResult.error) {
        alert("Erreur : " + (runResult.detail || runResult.error));
        return;
      }
      await loadAutomations();
    });
    card.querySelector('[data-action="toggle"]').addEventListener("click", async () => {
      const result = await fetchJson(`/api/automations/${a.id}/toggle`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ enabled: !a.enabled }),
      });
      handleAutomationError(result, () => {});
      await loadAutomations();
    });
    card.querySelector('[data-action="delete"]').addEventListener("click", async () => {
      const result = await fetchJson(`/api/automations/${a.id}`, { method: "DELETE" });
      handleAutomationError(result, () => {});
      await loadAutomations();
    });
    listEl.appendChild(card);
  });
}

document.getElementById("automation-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const workerId = document.getElementById("automation-worker-select").value;
  const objective = document.getElementById("automation-objective-input").value.trim();
  const frequencyMinutes = parseInt(document.getElementById("automation-frequency-select").value, 10);
  const notifySlack = document.getElementById("automation-notify-slack").checked;
  const errorEl = document.getElementById("automation-error");
  errorEl.hidden = true;

  if (!objective) {
    errorEl.textContent = "Décrivez la mission avant de créer l'automatisation.";
    errorEl.hidden = false;
    return;
  }

  const result = await fetchJson("/api/automations", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ workerId, objective, frequencyMinutes, notifySlack }),
  });

  if (result.error === "ACCOUNT_REQUIRED") {
    requireAccount(() => document.getElementById("automation-form").requestSubmit());
    return;
  }
  if (result.error === "SUBSCRIPTION_REQUIRED") {
    errorEl.innerHTML = `${escapeHtml(result.detail || "Votre quota est épuisé.")} <button type="button" class="btn btn-gold" id="automation-subscribe-cta-btn" style="margin-left:8px">Voir les abonnements &rarr;</button>`;
    errorEl.hidden = false;
    document.getElementById("automation-subscribe-cta-btn").addEventListener("click", () => showView("billing"));
    return;
  }
  if (result.error) {
    errorEl.textContent = "Erreur : " + (result.detail || result.error);
    errorEl.hidden = false;
    return;
  }

  document.getElementById("automation-objective-input").value = "";
  document.getElementById("automation-notify-slack").checked = false;
  await loadAutomations();
});

// ---------- INTEGRATIONS (vrai catalogue de connecteurs — la diffusion
// reelle vers un outil externe n'a lieu que pour un outil que le client
// a lui-meme connecte a son compte, quel que soit liveExecutionEnabled ;
// ce flag autorise le principe, il ne connecte aucun outil tout seul) ----------

const GOOGLE_G_SVG = '<svg class="g-logo" viewBox="0 0 48 48" aria-hidden="true"><path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9.1 3.6l6.8-6.8C35.8 2.4 30.3 0 24 0 14.6 0 6.5 5.4 2.6 13.2l7.9 6.1C12.4 13.6 17.7 9.5 24 9.5z"/><path fill="#4285F4" d="M46.5 24.5c0-1.6-.1-3.1-.4-4.5H24v9h12.7c-.6 3-2.3 5.5-4.8 7.2l7.6 5.9c4.4-4.1 7-10.1 7-17.6z"/><path fill="#FBBC05" d="M10.5 28.7c-.5-1.4-.8-3-.8-4.7s.3-3.3.8-4.7l-7.9-6.1C.9 16.6 0 20.2 0 24s.9 7.4 2.6 10.8l7.9-6.1z"/><path fill="#34A853" d="M24 48c6.3 0 11.7-2.1 15.6-5.7l-7.6-5.9c-2.1 1.4-4.8 2.3-8 2.3-6.3 0-11.6-4.1-13.5-9.8l-7.9 6.1C6.5 42.6 14.6 48 24 48z"/></svg>';

function showToast(message, ok = true) {
  const t = document.createElement("div");
  t.className = "toast " + (ok ? "toast-ok" : "toast-err");
  t.textContent = message;
  document.body.appendChild(t);
  requestAnimationFrame(() => t.classList.add("show"));
  setTimeout(() => { t.classList.remove("show"); setTimeout(() => t.remove(), 400); }, 6000);
}

// Retour du flux "Se connecter avec Google" (/?oauth=ok|cancelled|error|login).
function handleOauthReturn() {
  const p = new URLSearchParams(location.search);
  const status = p.get("oauth");
  if (!status) return;
  history.replaceState(null, "", location.pathname);
  if (status === "login") { requireAccount(() => showView("automations")); return; }
  showView("automations");
  if (status === "ok") {
    const who = p.get("email") ? " (" + p.get("email") + ")" : "";
    const vLabel = (OAUTH_VENDOR_UI[p.get("vendor")] || { label: brandName((p.get("provider") || "").toUpperCase()) || p.get("vendor") }).label;
    showToast("Compte " + vLabel + " connecté" + who + " — vos Workers peuvent maintenant l'utiliser.", true);
  } else if (status === "cancelled") {
    showToast("Connexion annulée : aucune permission n'a été accordée.", false);
  } else {
    const reason = p.get("reason") || "";
    const msg = /_APP_NOT_CONFIGURED$/.test(reason)
      ? "Cette connexion n'est pas encore activée sur ce site."
      : "La connexion a échoué (" + reason + "). Réessayez.";
    showToast(msg, false);
  }
}

const MS_SQUARES_SVG = '<svg width="16" height="16" viewBox="0 0 21 21" aria-hidden="true"><rect x="1" y="1" width="9" height="9" fill="#f25022"/><rect x="11" y="1" width="9" height="9" fill="#7fba00"/><rect x="1" y="11" width="9" height="9" fill="#00a4ef"/><rect x="11" y="11" width="9" height="9" fill="#ffb900"/></svg>';
const OAUTH_VENDOR_UI = {
  google: { label: "Google", svg: GOOGLE_G_SVG },
  microsoft: { label: "Microsoft", svg: MS_SQUARES_SVG },
};

const CONNECTOR_CATEGORY_LABELS = {
  EMAIL: "Email", CALENDAR: "Agenda", CRM: "CRM", SOCIAL_MEDIA: "Réseaux sociaux", CMS: "Sites web (CMS)",
  ECOMMERCE: "E-commerce", PAYMENT: "Paiement", ACCOUNTING: "Comptabilité", COMMUNICATION: "Messagerie",
  STORAGE: "Stockage de fichiers", WEB_ANALYTICS: "Analyse web", ADVERTISING: "Publicité",
  PROJECT_MANAGEMENT: "Gestion de projet", SUPPORT: "Support client", DESIGN: "Design", MONITORING: "Surveillance", HR: "Ressources humaines",
  TELEPHONY: "Téléphonie",
};

async function loadConnectors() {
  const data = await fetchJson("/api/connectors");
  const summaryEl = document.getElementById("connectors-summary");
  const gridEl = document.getElementById("connectors-grid");

  const liveNote = data.liveExecutionEnabled
    ? "🔓 Diffusion réelle possible pour les outils que vous connectez"
    : "🔒 Mode préparation — aucune diffusion réelle n'est jamais effectuée";
  const activatedNote = accountAuthenticated && !isOperator
    ? ` · ${data.activatedByClientCount || 0} activé(s) pour votre compte`
    : "";
  summaryEl.textContent = `${data.realConnectorsCount}/${data.totalConnectors} connecteurs disponibles. ${liveNote}${activatedNote}.`;

  const autoApproveCard = document.getElementById("auto-approve-card");
  const autoApproveCheckbox = document.getElementById("auto-approve-checkbox");
  if (accountAuthenticated && !isOperator && data.autoApprove !== null && data.autoApprove !== undefined) {
    autoApproveCard.hidden = false;
    autoApproveCheckbox.checked = !!data.autoApprove;
    autoApproveCheckbox.onchange = async () => {
      autoApproveCheckbox.disabled = true;
      await fetchJson("/api/connectors/auto-approve/toggle", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ enabled: autoApproveCheckbox.checked }),
      });
      autoApproveCheckbox.disabled = false;
    };
  } else {
    autoApproveCard.hidden = true;
  }

  gridEl.innerHTML = "";
  Object.entries(data.categories || {}).forEach(([category, connectors]) => {
    const card = document.createElement("div");
    card.className = "connector-category-card";
    card.innerHTML = `<div class="connector-category-title">${CONNECTOR_CATEGORY_LABELS[category] || humanizeTag(category)}</div>`;
    connectors.forEach((c) => {
      const row = document.createElement("div");
      // "realIntegration" (pas "enabled") pilote l'affichage : "enabled"
      // reste un etat interne dont depend le security gate pour certains
      // Workers, voir la note cote server.py / get_connector_catalog().
      row.className = "connector-row " + (c.realIntegration ? "enabled" : "disabled");
      const needsCred = !!c.clientCanConfigure;
      const connected = needsCred ? !!c.configuredByClient : !!c.activatedByClient;
      let stateHtml;
      if (!c.realIntegration) stateHtml = '<span class="cstate soon">Bientôt</span>';
      else if (!accountAuthenticated) stateHtml = '<span class="cstate">Disponible</span>';
      else if (needsCred) stateHtml = connected ? '<span class="cstate on">Connecté</span>' : '<span class="cstate off">Non connecté</span>';
      else stateHtml = c.activatedByClient ? '<span class="cstate on">Activé</span>' : '<span class="cstate off">Désactivé</span>';

      let actionsHtml = "";
      if (c.realIntegration && !accountAuthenticated) {
        actionsHtml = '<button type="button" class="connector-primary-btn" data-need-account="1">Connecter</button>';
      } else if (c.realIntegration && needsCred && c.oauthProvider) {
        // "Se connecter avec ..." : le client saisit son login/mot de passe
        // sur la page OFFICIELLE du fournisseur — nous ne voyons jamais son
        // mot de passe, et il n'a aucune cle/jeton a copier.
        const v = OAUTH_VENDOR_UI[c.oauthProvider] || { label: brandName(c.provider), svg: "" };
        actionsHtml = `<button type="button" class="connector-oauth-btn" data-oauth="${c.oauthProvider}" data-provider="${c.credentialProvider}">${v.svg}<span>${connected ? "Reconnecter avec " : "Se connecter avec "}${v.label}</span></button>`;
        if (c.connectGuide) {
          // Repli : si la connexion en un clic n'est pas possible pour ce client
          // (application du fournisseur pas encore approuvee pour son espace de
          // travail, compte d'entreprise restreint...), il garde le formulaire
          // guide — jamais d'impasse.
          actionsHtml += '<button type="button" class="connector-link-btn connector-guide-btn">Connexion manuelle</button>';
          if (connected) actionsHtml += '<button type="button" class="connector-link-btn connector-test-btn">Tester</button>';
        }
        if (connected) {
          actionsHtml += `<button type="button" class="connector-link-btn" data-disconnect="${c.credentialProvider}">Déconnecter</button>`;
          actionsHtml += `<label class="switch" title="Autoriser vos Workers à utiliser cet outil"><input type="checkbox" class="connector-switch" ${c.activatedByClient ? "checked" : ""}><span class="switch-track"></span><span class="switch-label">Workers autorisés</span></label>`;
        }
      } else if (c.realIntegration && needsCred && c.connectGuide) {
        // Connexion guidee (2026-10-06, demande de Kader : tous les outils
        // doivent etre connectables facilement par les clients) : un
        // formulaire par outil, etapes en francais, verification immediate.
        actionsHtml = `<button type="button" class="connector-primary-btn ${connected ? "is-secondary" : ""} connector-guide-btn">${connected ? "Modifier" : "Connecter"}</button>`;
        if (connected) {
          actionsHtml += '<button type="button" class="connector-link-btn connector-test-btn">Tester</button>';
          actionsHtml += `<button type="button" class="connector-link-btn" data-disconnect="${c.credentialProvider}">Déconnecter</button>`;
          actionsHtml += `<label class="switch" title="Autoriser vos Workers à utiliser cet outil"><input type="checkbox" class="connector-switch" ${c.activatedByClient ? "checked" : ""}><span class="switch-track"></span><span class="switch-label">Workers autorisés</span></label>`;
        }
      } else if (c.realIntegration && needsCred && !isOperator) {
        // Ni "Se connecter avec" ni formulaire guide pour cet outil (il faut
        // d'abord une application chez le fournisseur) : pas d'impasse muette,
        // le client peut demander a etre prevenu.
        stateHtml = '<span class="cstate soon">Connexion en préparation</span>';
        actionsHtml = '<button type="button" class="connector-link-btn connector-interest-btn">Me prévenir</button>';
      } else if (c.realIntegration && needsCred) {
        // Reserve au proprietaire (cles techniques).
        actionsHtml = `<button type="button" class="connector-primary-btn ${connected ? "is-secondary" : ""} connector-cred-btn" data-provider="${c.credentialProvider}">${connected ? "Modifier" : "Connecter"}</button>`;
        if (connected) {
          actionsHtml += `<label class="switch" title="Autoriser vos Workers à utiliser cet outil"><input type="checkbox" class="connector-switch" ${c.activatedByClient ? "checked" : ""}><span class="switch-track"></span><span class="switch-label">Workers autorisés</span></label>`;
        }
      } else if (c.realIntegration) {
        actionsHtml = `<label class="switch"><input type="checkbox" class="connector-switch" ${c.activatedByClient ? "checked" : ""}><span class="switch-track"></span><span class="switch-label">Activer</span></label>`;
      }

      row.innerHTML = `
        <div class="connector-logo-slot"></div>
        <div class="connector-main">
          <div class="connector-name">${brandName(c.provider)}</div>
          ${stateHtml}
        </div>
        <div class="connector-actions">${actionsHtml}</div>
      `;
      row.querySelector(".connector-logo-slot").appendChild(brandLogoEl(c.provider));

      const toggleConnector = async (enable) => {
        const result = await fetchJson(`/api/connectors/${c.connectorId}/toggle`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ enabled: enable }),
        });
        if (result.error === "ACCOUNT_REQUIRED") { requireAccount(() => loadConnectors()); return; }
        await loadConnectors();
      };
      const sw = row.querySelector(".connector-switch");
      if (sw) sw.addEventListener("change", () => toggleConnector(sw.checked));
      const oBtn = row.querySelector("[data-oauth]");
      if (oBtn) oBtn.addEventListener("click", () => { window.location.href = "/oauth/" + oBtn.dataset.oauth + "/start?provider=" + encodeURIComponent(oBtn.dataset.provider); });
      const discBtn = row.querySelector("[data-disconnect]");
      if (discBtn) discBtn.addEventListener("click", async () => {
        if (!confirm("Déconnecter " + brandName(c.provider) + " ? Vos Workers n'y auront plus accès.")) return;
        await fetchJson(`/api/connectors/${c.credentialProvider}/credential`, {
          method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ value: "" }),
        });
        await toggleConnector(false);
      });
      const needBtn = row.querySelector("[data-need-account]");
      if (needBtn) needBtn.addEventListener("click", () => requireAccount(() => loadConnectors()));
      const credBtn = row.querySelector(".connector-cred-btn");
      if (credBtn) credBtn.addEventListener("click", () => openConnectorCredentialForm(row, c));
      const guideBtn = row.querySelector(".connector-guide-btn");
      if (guideBtn) guideBtn.addEventListener("click", () => openGuidedConnectForm(row, c));
      const testBtn = row.querySelector(".connector-test-btn");
      if (testBtn) testBtn.addEventListener("click", async () => {
        const label = testBtn.textContent;
        testBtn.disabled = true; testBtn.textContent = "Test…";
        try {
          const r = await fetchJson(`/api/connectors/${c.credentialProvider}/test`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
          showToast(r.message || (r.ok ? "Connexion vérifiée." : "Vérification impossible."), !!(r.ok && r.verified));
        } catch (e) { showToast(e.message || "Vérification impossible.", false); }
        testBtn.disabled = false; testBtn.textContent = label;
      });
      const interestBtn = row.querySelector(".connector-interest-btn");
      if (interestBtn) interestBtn.addEventListener("click", async () => {
        interestBtn.disabled = true;
        try {
          const r = await fetchJson(`/api/connectors/${c.credentialProvider}/interest`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
          if (r.error === "ACCOUNT_REQUIRED") { interestBtn.disabled = false; requireAccount(() => loadConnectors()); return; }
          interestBtn.textContent = "C'est noté ✓";
          showToast("Merci ! Nous vous prévenons dès que " + brandName(c.provider) + " est connectable.");
        } catch (e) { interestBtn.disabled = false; showToast(e.message || "Erreur, réessayez.", false); }
      });
      card.appendChild(row);
    });
    gridEl.appendChild(card);
  });
  renderWhatsappCard(gridEl);
}

// Integration generique Zapier/Make (2026-09-30) : une cle API pour
// declencher une mission depuis un Zap/scenario, un webhook pour etre
// notifie a la fin de chaque mission. Voir /api/public/v1/missions et
// /api/integrations/* cote server.py.
async function loadZapierCard() {
  const card = document.getElementById("zapier-card");
  const accountRequired = document.getElementById("zapier-account-required");
  if (!accountAuthenticated) {
    card.hidden = true;
    accountRequired.hidden = false;
    return;
  }
  accountRequired.hidden = true;
  card.hidden = false;

  const [keyData, webhookData] = await Promise.all([
    fetchJson("/api/integrations/apikey"),
    fetchJson("/api/integrations/webhook"),
  ]);

  const keyStateEl = document.getElementById("zapier-apikey-state");
  const revokeBtn = document.getElementById("zapier-apikey-revoke-btn");
  keyStateEl.textContent = keyData.exists ? `Clé active : ${keyData.keyPrefix}` : "Aucune clé générée";
  revokeBtn.hidden = !keyData.exists;

  const webhookInput = document.getElementById("zapier-webhook-input");
  const secretRow = document.getElementById("zapier-webhook-secret-row");
  const secretValue = document.getElementById("zapier-webhook-secret-value");
  if (webhookData.url) {
    webhookInput.value = webhookData.url;
    secretValue.textContent = webhookData.secret || "";
    secretRow.hidden = false;
  } else {
    secretRow.hidden = true;
  }
}

// Rappel du format attendu par connecteur — memes valeurs que
// CONNECTOR-SETUP-GUIDE.md / .secrets/Store-Credential.ps1, cote client.
const CONNECTOR_CRED_HINTS = {
  zendesk: '{"subdomain":"tonentreprise","user":"toi@exemple.com","pass":"API_TOKEN"}',
  shopify: '{"shop":"tonentreprise","token":"shpat_..."}',
  woocommerce: '{"site":"tonsite.com","consumer_key":"ck_...","consumer_secret":"cs_..."}',
  wordpress: '{"site":"tonsite.com","user":"toi","pass":"MOT_DE_PASSE_APPLICATION"}',
  trello: '{"key":"TA_CLE","token":"TON_TOKEN"}',
  gmail: '{"client_id":"...","client_secret":"...","refresh_token":"..."}',
  google_calendar: '{"client_id":"...","client_secret":"...","refresh_token":"..."}',
  google_drive: '{"client_id":"...","client_secret":"...","refresh_token":"..."}',
  google_search_console: '{"client_id":"...","client_secret":"...","refresh_token":"..."}',
  google_ads: '{"client_id":"...","client_secret":"...","refresh_token":"...","developer_token":"..."}',
  outlook_mail: '{"client_id":"...","client_secret":"...","refresh_token":"...","tenant":"..."}',
  outlook_calendar: '{"client_id":"...","client_secret":"...","refresh_token":"...","tenant":"..."}',
  teams: '{"client_id":"...","client_secret":"...","refresh_token":"...","tenant":"..."}',
  onedrive: '{"client_id":"...","client_secret":"...","refresh_token":"...","tenant":"..."}',
  salesforce: '{"client_id":"...","client_secret":"...","refresh_token":"..."}',
  twilio: '{"user":"AC... (Account SID)","pass":"... (Auth Token)","from":"+41... (votre numéro Twilio)"}',
  uptimerobot: '{"api_key":"votre clé API UptimeRobot (Intégrations & API dans votre compte)"}',
  bamboohr: '{"user":"votre clé API BambooHR","pass":"x","companyDomain":"tonentreprise (le sous-domaine bamboohr.com)"}',
};

function openConnectorCredentialForm(row, c) {
  if (row.querySelector(".connector-cred-form")) return; // deja ouvert
  const hint = CONNECTOR_CRED_HINTS[c.credentialProvider];
  const form = document.createElement("div");
  form.className = "connector-cred-form";
  form.innerHTML = `
    ${hint ? `<div class="connector-cred-hint">Format attendu : <code>${hint}</code></div>` : ""}
    <input type="text" class="connector-cred-input" placeholder="Colle ta clé ou ton jeton ici" autocomplete="off">
    <div class="connector-cred-actions">
      <button type="button" class="btn-small connector-cred-save">Enregistrer</button>
      ${c.configuredByClient ? '<button type="button" class="btn-small connector-cred-remove">Déconnecter</button>' : ""}
      <button type="button" class="btn-small connector-cred-cancel">Annuler</button>
    </div>
    <div class="connector-cred-error" hidden></div>
  `;
  row.appendChild(form);

  const errorEl = form.querySelector(".connector-cred-error");
  form.querySelector(".connector-cred-cancel").addEventListener("click", () => form.remove());
  form.querySelector(".connector-cred-save").addEventListener("click", async () => {
    const value = form.querySelector(".connector-cred-input").value.trim();
    if (!value) { errorEl.textContent = "Colle une valeur avant d'enregistrer."; errorEl.hidden = false; return; }
    const result = await fetchJson(`/api/connectors/${c.credentialProvider}/credential`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ value }),
    });
    if (!result.ok) { errorEl.textContent = "Erreur : " + (result.error || "inconnue"); errorEl.hidden = false; return; }
    // Un outil qu'on vient de connecter doit etre utilisable tout de
    // suite : avant, il fallait AUSSI cliquer sur un second bouton
    // "Activer pour mon compte" (deux etapes que personne ne comprenait).
    if (!c.activatedByClient) {
      await fetchJson(`/api/connectors/${c.connectorId}/toggle`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ enabled: true }),
      });
    }
    await loadConnectors();
  });
  const removeBtn = form.querySelector(".connector-cred-remove");
  if (removeBtn) {
    removeBtn.addEventListener("click", async () => {
      await fetchJson(`/api/connectors/${c.credentialProvider}/credential`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ value: "" }),
      });
      await loadConnectors();
    });
  }
}

// Formulaire de connexion guidee (2026-10-06) : etapes en francais, lien direct vers la
// page du fournisseur, un champ par valeur, verification immediate cote serveur.
// Rien de ce qui est saisi n'est conserve cote navigateur ; le serveur chiffre.
function openGuidedConnectForm(row, c) {
  document.querySelectorAll(".cg-overlay").forEach((o) => o.remove());
  const g = c.connectGuide;
  const label = g.label || brandName(c.provider);
  const form = document.createElement("div");
  form.className = "connector-guide-form";
  form.innerHTML = `
    <div class="cg-title">Connecter ${escapeHtml(label)}</div>
    <ol class="cg-steps">${(g.steps || []).map((st) => `<li>${escapeHtml(st)}</li>`).join("")}</ol>
    ${g.helpUrl ? `<a class="cg-help" href="${escapeHtml(g.helpUrl)}" target="_blank" rel="noopener noreferrer">${escapeHtml(g.helpLabel || "Ouvrir")} ↗</a>` : ""}
    <div class="cg-fields">
      ${(g.fields || []).map((f) => `
        <label class="cg-field">
          <span class="cg-label">${escapeHtml(f.label)}</span>
          <span class="cg-inputwrap">
            <input type="${f.kind === "secret" ? "password" : "text"}" name="${escapeHtml(f.key)}" placeholder="${escapeHtml(f.placeholder || "")}" autocomplete="off" autocapitalize="off" spellcheck="false">
            ${f.kind === "secret" ? '<button type="button" class="cg-eye" aria-label="Afficher ou masquer">Afficher</button>' : ""}
          </span>
          <span class="cg-error" hidden></span>
        </label>`).join("")}
    </div>
    ${g.testNote ? `<div class="cg-note">${escapeHtml(g.testNote)}</div>` : ""}
    <div class="cg-actions">
      <button type="button" class="connector-primary-btn cg-submit">Connecter ${escapeHtml(label)}</button>
      <button type="button" class="btn-small cg-cancel">Annuler</button>
    </div>
    <div class="cg-result" hidden></div>
    <div class="cg-privacy">🔒 Vos identifiants sont chiffrés, ne sont jamais affichés ni partagés, et vous pouvez déconnecter l'outil à tout moment.</div>`;
  // Fenetre centree (les cartes de la grille sont trop etroites pour un formulaire).
  const overlay = document.createElement("div");
  overlay.className = "cg-overlay";
  overlay.setAttribute("role", "dialog");
  overlay.setAttribute("aria-modal", "true");
  overlay.setAttribute("aria-label", "Connecter " + label);
  overlay.appendChild(form);
  document.body.appendChild(overlay);
  const closeForm = () => { overlay.remove(); document.removeEventListener("keydown", onEsc); };
  const onEsc = (e) => { if (e.key === "Escape") closeForm(); };
  document.addEventListener("keydown", onEsc);
  overlay.addEventListener("mousedown", (e) => { if (e.target === overlay) closeForm(); });

  const resultEl = form.querySelector(".cg-result");
  const submit = form.querySelector(".cg-submit");
  form.querySelector(".cg-cancel").addEventListener("click", closeForm);
  form.querySelectorAll(".cg-eye").forEach((b) => b.addEventListener("click", () => {
    const input = b.parentElement.querySelector("input");
    const show = input.type === "password";
    input.type = show ? "text" : "password";
    b.textContent = show ? "Masquer" : "Afficher";
  }));
  const showResult = (msg, kind) => { resultEl.textContent = msg; resultEl.className = "cg-result " + kind; resultEl.hidden = false; };
  const clearErrors = () => form.querySelectorAll(".cg-error").forEach((e) => { e.hidden = true; e.textContent = ""; });

  const send = async () => {
    clearErrors(); resultEl.hidden = true;
    const fields = {};
    let missing = false;
    form.querySelectorAll(".cg-field input").forEach((input) => {
      fields[input.name] = input.value;
      if (!input.value.trim()) {
        const err = input.closest(".cg-field").querySelector(".cg-error");
        err.textContent = "Ce champ est obligatoire."; err.hidden = false; missing = true;
      }
    });
    if (missing) return;
    submit.disabled = true;
    const idle = submit.textContent;
    submit.textContent = "Vérification en cours…";
    try {
      const r = await fetchJson(`/api/connectors/${c.credentialProvider}/credential`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ fields }),
      });
      if (r.error === "ACCOUNT_REQUIRED") { requireAccount(() => loadConnectors()); return; }
      if (r.error === "INVALID_FIELD") {
        const input = form.querySelector(`.cg-field input[name="${CSS.escape(r.field || "")}"]`);
        if (input) { const err = input.closest(".cg-field").querySelector(".cg-error"); err.textContent = r.message; err.hidden = false; input.focus(); }
        else showResult(r.message || "Valeur invalide.", "bad");
      } else if (r.error === "VERIFY_FAILED") {
        showResult(r.message, "bad");
      } else if (r.ok && r.verified) {
        showToast(r.message || (label + " est connecté."));
        closeForm();
        await loadConnectors();
        return;
      } else if (r.ok) {
        showResult(r.message, "warn");                       // enregistre mais pas encore verifie (reseau, droits...)
        setTimeout(() => { closeForm(); loadConnectors(); }, 3500);
      } else {
        showResult(r.message || "Connexion impossible pour le moment. Réessayez.", "bad");
      }
    } catch (e) {
      showResult(e.message || "Connexion impossible pour le moment. Réessayez.", "bad");
    }
    submit.disabled = false; submit.textContent = idle;
  };
  submit.addEventListener("click", send);
  form.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.target.tagName === "INPUT") { e.preventDefault(); send(); } });
  const first = form.querySelector(".cg-field input");
  if (first) first.focus();
}

// ---------- TARIFS (proposition — voir strategie Suisse, a valider
// avant mise en production reelle : facturation/TVA/paiement) ----------

const PRICING_PLANS = [
  {
    name: "Essai",
    audience: "Pour tester sans risque",
    price: "0",
    period: "3 jours",
    features: [
      "Crédits d'essai limités",
      "Missions limitées",
      "Quelques Workers",
      "Aucune carte bancaire",
    ],
  },
  {
    name: "Starter",
    audience: "Indépendants & petites structures",
    price: "39",
    annual: "390",
    period: "/mois",
    features: [
      "Chloé + Workers essentiels",
      "Missions individuelles",
      "Mémoire de base",
      "Historique des missions",
      "Support standard",
    ],
  },
  {
    name: "Business",
    audience: "PME",
    price: "99",
    annual: "990",
    period: "/mois",
    popular: true,
    features: [
      "Tout Starter",
      "Équipe de Workers",
      "Missions multi-agents",
      "Automatisations",
      "Rapports & support prioritaire",
    ],
  },
  {
    name: "Pro",
    audience: "Entreprises, usage régulier",
    price: "139",
    annual: "1390",
    period: "/mois",
    features: [
      "Tout Business",
      "Équipes avancées",
      "Missions complexes",
      "Quotas supérieurs",
      "Analytics & contrôles avancés",
    ],
  },
  {
    name: "Scale",
    audience: "Entreprises, volume important",
    price: "449",
    annual: "4490",
    period: "/mois",
    features: [
      "Tout Pro",
      "Capacité supérieure",
      "Équipes multiples",
      "Gouvernance avancée",
      "Accompagnement renforcé",
    ],
  },
  {
    name: "Enterprise",
    audience: "Grands comptes, besoins spécifiques",
    price: null,
    period: "Sur devis",
    features: [
      "Intégrations métier",
      "Gouvernance avancée",
      "Déploiement personnalisé",
      "Exigences contractuelles & conformité",
    ],
  },
];

function renderPricing() {
  const grid = document.getElementById("pricing-grid");
  grid.innerHTML = "";

  PRICING_PLANS.forEach((plan) => {
    const card = document.createElement("div");
    card.className = "plan-card" + (plan.popular ? " is-popular" : "");

    const priceHtml = plan.price === null
      ? `<div class="plan-price-row"><span class="plan-price">Sur devis</span></div>`
      : `<div class="plan-price-row"><span class="plan-price">${formatPrice(plan.price)}</span><span class="plan-price-period">${plan.period}</span></div>`;

    const strikeHtml = plan.annual
      ? `<div class="plan-price-strike">ou ${formatPrice(plan.annual)}/an — 2 mois offerts</div>`
      : "";

    const featuresHtml = plan.features.map((f) => `<li>${f}</li>`).join("");

    card.innerHTML = `
      ${plan.popular ? '<div class="plan-badge">Le plus choisi</div>' : ""}
      <div class="plan-name">${plan.name}</div>
      <div class="plan-audience">${plan.audience}</div>
      ${priceHtml}
      ${strikeHtml}
      <ul class="plan-features">${featuresHtml}</ul>
      <button type="button" class="plan-cta">${plan.price === null ? "Nous contacter" : "Discuter avec Chloé"}</button>
    `;

    card.querySelector(".plan-cta").addEventListener("click", openChloeFab);

    grid.appendChild(card);
  });
}

async function bootstrap() {
  const [workersData, categoriesData, chloe] = await Promise.all([
    fetchJson("/api/workers"),
    fetchJson("/api/categories"),
    fetchJson("/api/chloe"),
    loadFx(),
  ]);

  allWorkers = workersData.workers;
  chloeData = chloe;
  document.getElementById("chloe-fab-avatar").src = chloeData.portraitUrl;

  renderStats(allWorkers, categoriesData);
  renderFeatured();
  renderCategoryBar(categoriesData);
  renderCatalog();
  renderHeroPortraits();
  renderHomeCategoryBar(categoriesData);
  renderPromptAgentOptions();
  renderPricing();
  applyCurrencyToStatic();
  renderAutomationWorkerOptions();
  loadTrustSignals();
  initScrollReveal();
  syncActiveNavLink("home");
  handleOauthReturn();
}

// Rangee de vrais portraits dans le hero (2026-09-24, comparaison
// directe avec Delos/Limova dont le hero met en avant de vraies photos
// d'agents des l'arrivee — le notre restait un bloc de texte plat).
function renderHeroPortraits() {
  const wrap = document.getElementById("hero-portraits");
  if (!wrap) return;
  const sample = allWorkers.filter((w) => !w.portraitUrl.endsWith(".svg")).slice(0, 6);
  if (sample.length === 0) return;
  wrap.innerHTML = sample.map((w) => `<img src="${w.portraitUrl}" alt="${w.name}" loading="lazy">`).join("")
    + `<span class="hero-portraits-label">+${Math.max(allWorkers.length - sample.length, 0)} autres, un pour chaque métier</span>`;
}

// Section "par metier" de l'accueil (2026-09-24, revisee le meme jour
// apres verification des vraies donnees : /api/categories confirme 1
// Worker par metier, exactement 17 categories pour 17 Workers, jamais
// plusieurs par domaine. Une grille filtrable n'a donc aucun sens ici
// (elle n'affichait jamais qu'UNE seule carte, perdue dans une grille a
// plusieurs colonnes — "Alex en grand" signale par Kader comme
// incomprehensible). Remplace par une mise en avant explicite : un
// onglet = LE Worker de ce metier, presente avec ses vraies donnees
// (role, personnalite, competences, outils), jamais une liste a
// parcourir.
let homeActiveCategory = null;

function renderHomeCategoryBar(categoriesData) {
  const bar = document.getElementById("home-category-bar");
  if (!bar) return;
  const names = Object.keys(categoriesData.categories || {});
  homeActiveCategory = names[0] || null;
  bar.innerHTML = "";
  names.forEach((name) => {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = "category-chip" + (name === homeActiveCategory ? " active" : "");
    chip.textContent = name;
    chip.addEventListener("click", () => {
      selectHomeCategory(name);
      homeAutoPausedUntil = Date.now() + 12000; // le visiteur reprend la main
    });
    bar.appendChild(chip);
  });
  renderHomeCategorySpotlight();
  startHomeCategoryAutoplay(names);
}

// Selection d'un metier : chip active centree dans la barre (defilement de
// la barre seule, jamais de la page) + fondu du bloc de presentation.
let homeAutoPausedUntil = 0;
let homeAutoTimer = null;
function selectHomeCategory(name) {
  const bar = document.getElementById("home-category-bar");
  const spot = document.getElementById("home-category-spotlight");
  homeActiveCategory = name;
  let activeChip = null;
  [...bar.children].forEach((c) => { const on = c.textContent === name; c.classList.toggle("active", on); if (on) activeChip = c; });
  if (activeChip) {
    const left = activeChip.offsetLeft - (bar.clientWidth - activeChip.offsetWidth) / 2;
    bar.scrollTo({ left, behavior: PREFERS_REDUCED_MOTION ? "auto" : "smooth" });
  }
  if (spot && !PREFERS_REDUCED_MOTION) {
    spot.classList.add("is-swapping");
    setTimeout(() => { renderHomeCategorySpotlight(); spot.classList.remove("is-swapping"); }, 220);
  } else {
    renderHomeCategorySpotlight();
  }
}

// Defilement continu des metiers : passe au suivant toutes les 4 s tant que
// la section est visible ; pause au survol / au focus / apres un clic.
function startHomeCategoryAutoplay(names) {
  if (homeAutoTimer) clearInterval(homeAutoTimer);
  if (PREFERS_REDUCED_MOTION || names.length < 2) return;
  const section = document.getElementById("by-category-section");
  let hovering = false, inView = true;
  section.addEventListener("mouseenter", () => { hovering = true; });
  section.addEventListener("mouseleave", () => { hovering = false; });
  section.addEventListener("focusin", () => { homeAutoPausedUntil = Date.now() + 12000; });
  if ("IntersectionObserver" in window) new IntersectionObserver((es) => { inView = es[0].isIntersecting; }).observe(section);
  homeAutoTimer = setInterval(() => {
    if (hovering || !inView || document.hidden || Date.now() < homeAutoPausedUntil) return;
    const i = names.indexOf(homeActiveCategory);
    selectHomeCategory(names[(i + 1) % names.length]);
  }, 4000);
}

function renderHomeCategorySpotlight() {
  const wrap = document.getElementById("home-category-spotlight");
  if (!wrap || !homeActiveCategory) return;
  const w = allWorkers.find((x) => x.category === homeActiveCategory);
  if (!w) { wrap.innerHTML = ""; return; }

  const svgClass = w.portraitUrl.endsWith(".svg") ? "is-svg" : "";
  const skillsHtml = (w.topSkills || []).slice(0, 4).map((s) => `<span class="tag">${humanizeTag(s)}</span>`).join("");
  const toolsHtml = (w.tools || []).slice(0, 4).map((t) => `<span class="mini-tag">${humanizeTag(t)}</span>`).join("");

  wrap.innerHTML = `
    <div class="spotlight-portrait-wrap">
      <img class="spotlight-portrait ${svgClass}" src="${w.portraitUrl}" alt="${w.name}">
    </div>
    <div class="spotlight-info">
      <div class="spotlight-role">${w.category}</div>
      <h3 class="spotlight-name">${w.name} — ${w.role}</h3>
      <p class="spotlight-personality">${w.personality || ""}</p>
      <div class="tag-row">${skillsHtml}</div>
      <div class="wtools">${toolsHtml}</div>
      <div class="spotlight-actions">
        <button type="button" class="btn btn-gold" id="spotlight-recruit-btn">Confier une mission &rarr;</button>
        <button type="button" class="btn btn-ghost" id="spotlight-more-btn">Voir la fiche complète</button>
      </div>
    </div>
  `;
  const open = () => {
    cameFromView = "home";
    openWorkerProfile(w.id);
  };
  wrap.querySelector("#spotlight-recruit-btn").addEventListener("click", open);
  wrap.querySelector("#spotlight-more-btn").addEventListener("click", open);
}

// Fait apparaitre les grandes sections (.reveal) au fil du scroll —
// desactive sous prefers-reduced-motion (voir PREFERS_REDUCED_MOTION).
// Revu le 2026-09-24 (retour direct de Kader comparant a des sites
// concurrents "ou tout bouge, tout defile" contre un site "comme une
// peinture" chez nous) : quand GSAP+ScrollTrigger sont charges (CDN,
// voir index.html), chaque section anime ses propres cartes/lignes en
// cascade (stagger) plutot qu'un unique fondu en bloc, et le halo dore
// du hero suit le scroll (parallax). Repli silencieux sur l'ancien
// systeme (IntersectionObserver, fondu en bloc) si GSAP ne charge pas
// (CDN indisponible) — jamais de page cassee pour un detail visuel.
function initScrollReveal() {
  const targets = document.querySelectorAll(".reveal");
  const hasGsap = typeof gsap !== "undefined" && typeof ScrollTrigger !== "undefined";

  if (PREFERS_REDUCED_MOTION || !hasGsap) {
    if (PREFERS_REDUCED_MOTION || !("IntersectionObserver" in window)) {
      targets.forEach((el) => el.classList.add("is-visible"));
      return;
    }
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.15 });
    targets.forEach((el) => observer.observe(el));
    return;
  }

  gsap.registerPlugin(ScrollTrigger);

  // CORRECTIF (2026-09-25) : le declenchement par ScrollTrigger calculait
  // ses positions AVANT que les images/contenus asynchrones (roue,
  // spotlight, integrations) finissent de charger — les positions
  // devenaient fausses et certaines sections ("par metier",
  // integrations, CTA final) restaient a opacity:0 pour toujours,
  // laissant un grand espace VIDE sur l'accueil (signale par Kader sur
  // capture reelle). IntersectionObserver ne depend d'aucune position
  // pre-calculee : il se declenche des que la section est reellement
  // a l'ecran, quel que soit l'historique de chargement.
  const revealSection = (el) => {
    el.classList.add("is-visible");
    const items = el.querySelectorAll(".trust-card, .compare-row, .how-step, .integration-chip, .plan-card, .worker-card");
    const animTargets = items.length > 0 ? items : [el];
    gsap.fromTo(
      animTargets,
      { opacity: 0, y: 30 },
      { opacity: 1, y: 0, duration: 0.7, ease: "power2.out", stagger: 0.08, clearProps: "opacity,transform" }
    );
    // Etat final garanti INDEPENDAMMENT des animations : un navigateur
    // qui suspend rAF/transitions (onglet en arriere-plan) laissait
    // sinon une section bloquee a demi transparente.
    setTimeout(() => {
      el.style.transition = "none";
      el.style.opacity = "1";
      el.style.transform = "none";
      animTargets.forEach((t) => { t.style.opacity = ""; t.style.transform = ""; });
    }, 2200);
  };

  if (!("IntersectionObserver" in window)) {
    targets.forEach((el) => el.classList.add("is-visible"));
  } else {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          io.unobserve(entry.target);
          revealSection(entry.target);
        }
      });
    }, { threshold: 0.05, rootMargin: "0px 0px -8% 0px" });
    targets.forEach((el) => io.observe(el));

    // Filet de securite : si l'observer rate une section (rechargement
    // de contenu, saut de scroll rapide...), elle est revelee des qu'elle
    // est reellement a l'ecran — jamais de grand vide permanent.
    const sweep = () => {
      targets.forEach((el) => {
        if (el.classList.contains("is-visible")) return;
        const r = el.getBoundingClientRect();
        if (r.top < window.innerHeight * 0.95) {
          io.unobserve(el);
          revealSection(el);
        }
      });
    };
    window.addEventListener("scroll", sweep, { passive: true });
    setInterval(sweep, 700);
  }

  // Parallax subtil : le halo dore du hero se deplace a une vitesse
  // differente du contenu pendant le scroll, au lieu de rester fige.
  const glow = document.querySelector(".hero-glow");
  if (glow) {
    gsap.to(glow, {
      y: 140,
      ease: "none",
      scrollTrigger: { trigger: ".hero-band", start: "top top", end: "bottom top", scrub: 0.6 },
    });
    window.addEventListener("load", () => ScrollTrigger.refresh());
  }
}

// Vraies marques (logos Simple Icons, couleurs officielles). "old" = icone
// retiree des versions recentes de la bibliotheque, servie depuis v11.14.
// Sans slug : pastille a initiale (aucun logo libre disponible).
const BRAND_LOGOS = {
  STRIPE: { name: "Stripe", slug: "stripe", color: "#635BFF" },
  PAYPAL: { name: "PayPal", slug: "paypal", color: "#003087" },
  QUICKBOOKS: { name: "QuickBooks", slug: "quickbooks", color: "#2CA01C" },
  XERO: { name: "Xero", slug: "xero", color: "#13B5EA" },
  CRM: { name: "CRM", color: "#5B6475" },
  SOCIAL_MEDIA: { name: "Réseaux sociaux", color: "#7C2D3A" },
  WEB_ANALYTICS: { name: "Web Analytics", color: "#E37400" },
  DESIGN: { name: "Design", color: "#A5761F" },
  MONITORING: { name: "Surveillance", color: "#1A9D5C" },
  HR_PLATFORM: { name: "Plateforme RH", color: "#5B6475" },
  GMAIL: { name: "Gmail", slug: "gmail", color: "#EA4335" },
  OUTLOOK: { name: "Outlook", slug: "microsoftoutlook", color: "#0078D4", old: true },
  CALENDAR: { name: "Google Agenda", slug: "googlecalendar", color: "#4285F4" },
  OUTLOOK_CALENDAR: { name: "Outlook Calendar", slug: "microsoftoutlook", color: "#0078D4", old: true },
  SALESFORCE: { name: "Salesforce", slug: "salesforce", color: "#00A1E0", old: true },
  HUBSPOT: { name: "HubSpot", slug: "hubspot", color: "#FF7A59" },
  PIPEDRIVE: { name: "Pipedrive", color: "#1A1A1A" },
  LINKEDIN: { name: "LinkedIn", slug: "linkedin", color: "#0A66C2", old: true },
  INSTAGRAM: { name: "Instagram", slug: "instagram", color: "#E4405F" },
  FACEBOOK: { name: "Facebook", slug: "facebook", color: "#0866FF" },
  TIKTOK: { name: "TikTok", slug: "tiktok", color: "#111111" },
  X_TWITTER: { name: "X", slug: "x", color: "#111111" },
  WORDPRESS: { name: "WordPress", slug: "wordpress", color: "#21759B" },
  WEBFLOW: { name: "Webflow", slug: "webflow", color: "#146EF5" },
  SHOPIFY: { name: "Shopify", slug: "shopify", color: "#7AB55C" },
  WOOCOMMERCE: { name: "WooCommerce", slug: "woocommerce", color: "#96588A" },
  SLACK: { name: "Slack", slug: "slack", color: "#4A154B", old: true },
  MICROSOFT_TEAMS: { name: "Teams", slug: "microsoftteams", color: "#6264A7", old: true },
  WHATSAPP_BUSINESS: { name: "WhatsApp", slug: "whatsapp", color: "#25D366" },
  GOOGLE_DRIVE: { name: "Google Drive", slug: "googledrive", color: "#1FA463" },
  DROPBOX: { name: "Dropbox", slug: "dropbox", color: "#0061FF" },
  ONEDRIVE: { name: "OneDrive", slug: "microsoftonedrive", color: "#0078D4", old: true },
  GOOGLE_SEARCH_CONSOLE: { name: "Search Console", slug: "googlesearchconsole", color: "#458CF5" },
  GOOGLE_ADS: { name: "Google Ads", slug: "googleads", color: "#4285F4" },
  META_ADS: { name: "Meta Ads", slug: "meta", color: "#0467DF" },
  ASANA: { name: "Asana", slug: "asana", color: "#F06A6A" },
  TRELLO: { name: "Trello", slug: "trello", color: "#0052CC" },
  MONDAY: { name: "monday.com", color: "#FF3D57" },
  ZENDESK: { name: "Zendesk", slug: "zendesk", color: "#03363D" },
  INTERCOM: { name: "Intercom", slug: "intercom", color: "#286EFA" },
  CANVA: { name: "Canva", slug: "canva", color: "#00C4CC", old: true },
  FIGMA: { name: "Figma", slug: "figma", color: "#F24E1E" },
};

// Logo d'un outil (Simple Icons, couleur officielle) ou pastille a initiale.
function brandLogoEl(provider) {
  const brand = BRAND_LOGOS[provider] || { name: humanizeTag(provider), color: "#5B6475" };
  const logo = document.createElement("span");
  logo.className = "integration-logo";
  if (brand.slug) {
    const base = brand.old
      ? "https://cdn.jsdelivr.net/npm/simple-icons@11.14.0/icons/"
      : "https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/";
    const url = `url(${base}${brand.slug}.svg)`;
    logo.style.webkitMaskImage = url;
    logo.style.maskImage = url;
    logo.style.backgroundColor = brand.color;
  } else {
    logo.classList.add("is-initial");
    logo.textContent = brand.name[0];
    logo.style.backgroundColor = brand.color;
  }
  return logo;
}
function brandName(provider) {
  const b = BRAND_LOGOS[provider];
  if (b) return b.name;
  const t = humanizeTag(provider);
  return t.charAt(0).toUpperCase() + t.slice(1);
}

async function loadTrustSignals() {
  try {
    const data = await fetchJson("/api/connectors");
    // Nombre reel de connecteurs disponibles dans le catalogue (pas "configures
    // par un client" — ce chiffre serait 0 tant qu'aucun client n'a rien branche,
    // ce qui donnerait une fausse impression de faiblesse plutot qu'une preuve).
    // realConnectorsCount (pas enabledConnectors) : seuls ceux avec un vrai
    // adaptateur derriere comptent ici, voir get_connector_catalog() cote serveur.
    const connectorsNum = data.realConnectorsCount ?? data.totalConnectors;
    document.getElementById("trust-connectors-num").textContent = connectorsNum ?? "—";
    document.getElementById("trust-workers-num").textContent = allWorkers.length || "17";
    const chips = document.getElementById("integrations-chips");
    chips.innerHTML = "";
    Object.values(data.categories || {}).flat().forEach((c) => {
      if (!c.realIntegration) return;
      const brand = BRAND_LOGOS[c.provider];
      if (!brand) return; // connecteurs generiques (CRM, DESIGN...) : pas de marque a afficher
      const chip = document.createElement("span");
      chip.className = "integration-chip";
      const logo = document.createElement("span");
      logo.className = "integration-logo";
      if (brand.slug) {
        const base = brand.old
          ? "https://cdn.jsdelivr.net/npm/simple-icons@11.14.0/icons/"
          : "https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/";
        const url = `url(${base}${brand.slug}.svg)`;
        logo.style.webkitMaskImage = url;
        logo.style.maskImage = url;
        logo.style.backgroundColor = brand.color;
      } else {
        logo.classList.add("is-initial");
        logo.textContent = brand.name[0];
        logo.style.backgroundColor = brand.color;
      }
      const label = document.createElement("span");
      label.textContent = brand.name;
      chip.append(logo, label);
      chips.appendChild(chip);
    });
  } catch (err) {
    // Section de confiance : echec silencieux, non bloquant pour le reste de la page.
  }
}

const PREFERS_REDUCED_MOTION = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// Anime un compteur de 0 vers sa valeur reelle : purement cosmetique
// (le chiffre final est toujours le vrai chiffre, jamais invente), mais
// donne une sensation de site vivant plutot que de tableau statique.
function animateNumber(el, target, duration = 700) {
  if (!el || !Number.isFinite(target)) return;
  if (PREFERS_REDUCED_MOTION) {
    el.textContent = target;
    return;
  }
  const start = performance.now();
  function tick(now) {
    const progress = Math.min((now - start) / duration, 1);
    const eased = 1 - Math.pow(1 - progress, 3);
    el.textContent = Math.round(target * eased);
    if (progress < 1) requestAnimationFrame(tick);
    else el.textContent = target;
  }
  requestAnimationFrame(tick);
}

function renderStats(workers, categoriesData) {
  const totalSkills = workers.reduce((sum, w) => sum + (w.skillCount || 0), 0);
  const categoryCount = Object.keys(categoriesData.categories || {}).length;

  const stats = [
    { num: workers.length, label: "Workers spécialisés" },
    { num: categoryCount, label: "Domaines métier" },
    { num: totalSkills, label: "Compétences cumulées" },
  ];

  statsRow.innerHTML = "";
  stats.forEach((s) => {
    const el = document.createElement("div");
    el.className = "stat-item";
    el.innerHTML = `<span class="stat-num">0</span><span class="stat-label">${s.label}</span>`;
    statsRow.appendChild(el);
    animateNumber(el.querySelector(".stat-num"), s.num);
  });
}

// Traduit les codes de statut bruts de l'orchestration Chloe
// (Invoke-Chloe-Orchestration.ps1) en texte lisible — avant ce
// correctif, "NO_WORKER_MATCHED" s'affichait tel quel au-dessus de la
// reponse, meme apres que celle-ci soit devenue un vrai message dans
// le ton de Chloe (2026-09-24).
const CHLOE_STATUS_LABELS = {
  NO_WORKER_MATCHED: "Clarification",
  PARTIAL_SUCCESS: "Partiellement traité",
  BLOCKED: "Bloqué",
};
function chloeStatusLabel(status) {
  return CHLOE_STATUS_LABELS[status] || status;
}

// ---------- WORKER CARD (style Delos : photo + panneau sombre) ----------

// Reponse d'un modele : JAMAIS inseree telle quelle (injection HTML possible).
// On echappe tout, puis on rend un sous-ensemble sur de Markdown.
function escapeHtml(t) {
  return String(t ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function renderAnswer(text) {
  const lines = escapeHtml(text).split(/\r?\n/);
  const out = [];
  let inList = false;
  let inCode = false;
  const codeLines = [];
  const closeList = () => { if (inList) { out.push("</ul>"); inList = false; } };
  const inline = (l) => l.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>").replace(/`([^`]+?)`/g, "<code>$1</code>");
  for (const raw of lines) {
    const l = raw.trim();
    // Bloc de code balise par des triples backticks (```...```) : avant
    // ce correctif, les lignes "```" etaient rendues telles quelles en
    // texte brut — signale "tres vilain" par Kader (2026-09-24).
    if (/^```/.test(l)) {
      if (inCode) {
        out.push(`<pre><code>${codeLines.join("\n")}</code></pre>`);
        codeLines.length = 0;
        inCode = false;
      } else {
        closeList();
        inCode = true;
      }
      continue;
    }
    if (inCode) { codeLines.push(raw); continue; }
    let m;
    if (!l) { closeList(); continue; }
    if (/^-{3,}$/.test(l)) { closeList(); out.push("<hr>"); }
    else if ((m = l.match(/^(#{1,4})\s+(.*)$/))) { closeList(); out.push(`<h4>${inline(m[2])}</h4>`); }
    else if ((m = l.match(/^(?:[-*]|\d+\.)\s+(?:\[[ x]\]\s*)?(.*)$/))) {
      if (!inList) { out.push("<ul>"); inList = true; }
      out.push(`<li>${inline(m[1])}</li>`);
    }
    else if (/^\|.*\|$/.test(l)) { closeList(); if (!/^\|[\s:|-]+\|$/.test(l)) out.push(`<div class="answer-row">${inline(l.slice(1, -1).split("|").map((c) => c.trim()).join(" · "))}</div>`); }
    else { closeList(); out.push(`<p>${inline(l)}</p>`); }
  }
  closeList();
  if (inCode && codeLines.length) out.push(`<pre><code>${codeLines.join("\n")}</code></pre>`);
  return `<div class="answer-body">${out.join("")}</div>`;
}

function hashCode(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return h;
}

const activityCache = {};
function loadWorkerActivityOnce(id) {
  if (!activityCache[id]) {
    activityCache[id] = fetch(`/api/workers/${id}/activity`)
      .then((r) => r.json())
      .then((d) => d.activity || [])
      .catch(() => []);
  }
  return activityCache[id];
}

function buildWorkerCard(w, cameFrom) {
  const svgClass = w.portraitUrl.endsWith(".svg") ? "is-svg" : "";
  const card = document.createElement("div");
  card.className = "worker-card";

  const skillItems = w.topSkills.slice(0, 3).map((s) => `<li>${humanizeTag(s)}</li>`).join("");
  const toolTags = w.tools.slice(0, 4).map((t) => `<span class="mini-tag">${humanizeTag(t)}</span>`).join("");

  card.innerHTML = `
    <div class="card-portrait-wrap">
      <img class="card-portrait ${svgClass}" src="${w.portraitUrl}" alt="${w.name}">
      <div class="card-portrait-overlay"></div>
      <div class="card-name-overlay">
        <div class="wname">${w.name}</div>
        <div class="wcategory">${w.category}</div>
      </div>
    </div>
    <div class="worker-card-body">
      <ul class="wskills">${skillItems}</ul>
      <div class="wtools">${toolTags}</div>
      <div class="wactions">
        <button type="button" class="btn-info">Plus d'infos</button>
        <button type="button" class="btn-recruit">Confier une mission</button>
      </div>
    </div>
  `;

  // Video reelle (D-ID) si ce Worker en a une generee — meme aspect
  // "en action" que la fiche profil, etendu aux cartes du catalogue
  // (2026-09-24, demande explicite de Kader en comparaison avec
  // Delos/Limova dont les portraits sont en realite des videos).

  // Vie : respiration douce du portrait (decalee par Worker) + ligne
  // d'activite alimentee par la derniere VRAIE mission du Worker.
  card.style.setProperty("--breath-delay", `${(hashCode(w.id) % 40) / 10}s`);
  const tickerEl = document.createElement("div");
  tickerEl.className = "card-activity";
  tickerEl.innerHTML = '<span class="activity-dot"></span><span class="activity-text">Disponible</span>';
  card.querySelector(".card-name-overlay").appendChild(tickerEl);
  loadWorkerActivityOnce(w.id).then((acts) => {
    const last = acts && acts[0];
    if (!last) return;
    const ageMin = (Date.now() - new Date(last.createdAtUtc).getTime()) / 60000;
    tickerEl.querySelector(".activity-text").textContent = "Dernière mission : " + String(last.request).slice(0, 38);
    if (ageMin < 60 * 24) card.classList.add("is-active");
  });

  const open = () => {
    cameFromView = cameFrom;
    openWorkerProfile(w.id);
  };
  card.querySelector(".card-portrait-wrap").addEventListener("click", open);
  card.querySelector(".btn-info").addEventListener("click", open);
  card.querySelector(".btn-recruit").addEventListener("click", open);

  return card;
}

function wheelItemHtml(w, isChloe) {
  const svgClass = w.portraitUrl.endsWith(".svg") ? "is-svg" : "";
  const roleLabel = isChloe ? "Orchestratrice" : w.category;
  return `
    <img src="${w.portraitUrl}" alt="${w.name}" class="${svgClass}">
    <div class="wheel-item-name">${w.name}</div>
    <div class="wheel-item-role">${roleLabel}</div>
  `;
}

let wheelOrdered = [];
let wheelSpotlight = 0;
let wheelTimer = null;
const WHEEL_TICK_MS = 2400;

function wheelTooltipHtml(w, isChloe) {
  const roleLabel = isChloe ? "Orchestratrice" : w.category;
  const topSkill = (w.topSkills || [])[0];
  const skillHtml = topSkill ? `<span class="wheel-tooltip-skill">${humanizeTag(topSkill)}</span>` : "";
  return `
    <div class="wheel-tooltip-name">${w.name}</div>
    <div class="wheel-tooltip-role">${roleLabel}</div>
    ${skillHtml}
  `;
}

function applyWheelClasses() {
  const n = wheelOrdered.length;
  const items = agentWheel.children;
  for (let i = 0; i < n; i++) {
    const raw = Math.abs(i - wheelSpotlight);
    const dist = Math.min(raw, n - raw);
    const item = items[i];
    item.classList.remove("is-center", "is-near");
    if (dist === 0) item.classList.add("is-center");
    else if (dist === 1) item.classList.add("is-near");
  }
  const centerEl = items[wheelSpotlight];
  if (centerEl) {
    // Defilement horizontal du seul carrousel : scrollIntoView faisait
    // aussi remonter la page entiere a chaque tick.
    const cRect = centerEl.getBoundingClientRect();
    const wRect = agentWheel.getBoundingClientRect();
    const target = agentWheel.scrollLeft + (cRect.left - wRect.left) - (wRect.width - cRect.width) / 2;
    agentWheel.scrollTo({ left: target, behavior: "smooth" });
  }
}

function startWheelRotation() {
  if (wheelTimer) clearInterval(wheelTimer);
  wheelTimer = setInterval(() => {
    wheelSpotlight = (wheelSpotlight + 1) % wheelOrdered.length;
    applyWheelClasses();
  }, WHEEL_TICK_MS);
}

// Roue tournante : Chloe + les 17 Workers, chacun passe tour a tour au
// centre (agrandi) puis cede la place au suivant. Survol = pause +
// info-bulle compacte (nom, role, 1 competence-cle) ; clic = ouvre la
// fiche complete.
function renderFeatured() {
  agentWheel.innerHTML = "";

  const half = Math.ceil(allWorkers.length / 2);
  wheelOrdered = [...allWorkers.slice(0, half), { __chloe: true, ...chloeData }, ...allWorkers.slice(half)];
  wheelSpotlight = half;

  const tooltip = document.getElementById("wheel-tooltip");

  wheelOrdered.forEach((w, i) => {
    const item = document.createElement("div");
    item.className = "wheel-item";
    item.innerHTML = wheelItemHtml(w, !!w.__chloe);
    item.addEventListener("click", () => {
      cameFromView = "home";
      w.__chloe ? openChloeProfile() : openWorkerProfile(w.id);
    });
    item.addEventListener("mouseenter", () => {
      if (wheelTimer) clearInterval(wheelTimer);
      tooltip.innerHTML = wheelTooltipHtml(w, !!w.__chloe);
      tooltip.hidden = false;
      const itemRect = item.getBoundingClientRect();
      const wrapRect = agentWheel.getBoundingClientRect();
      tooltip.style.left = (itemRect.left - wrapRect.left + itemRect.width / 2) + "px";
    });
    item.addEventListener("mouseleave", () => {
      tooltip.hidden = true;
      startWheelRotation();
    });
    agentWheel.appendChild(item);
  });

  applyWheelClasses();
  startWheelRotation();
}

function renderCategoryBar(categoriesData) {
  categoryBar.innerHTML = "";

  const allChip = document.createElement("button");
  allChip.className = "category-chip active";
  allChip.textContent = `Tous (${categoriesData.total})`;
  allChip.addEventListener("click", () => setActiveCategory("ALL"));
  categoryBar.appendChild(allChip);

  Object.entries(categoriesData.categories).forEach(([name, count]) => {
    const chip = document.createElement("button");
    chip.className = "category-chip";
    chip.textContent = `${name} (${count})`;
    chip.dataset.category = name;
    chip.addEventListener("click", () => setActiveCategory(name));
    categoryBar.appendChild(chip);
  });
}

function setActiveCategory(category) {
  activeCategory = category;
  [...categoryBar.children].forEach((chip) => {
    const isActive = category === "ALL" ? !chip.dataset.category : chip.dataset.category === category;
    chip.classList.toggle("active", isActive);
  });
  renderCatalog();
}

function workerMatchesSearch(w, query) {
  if (!query) return true;
  const haystack = [w.name, w.role, w.category, ...(w.topSkills || [])]
    .join(" ")
    .toLowerCase();
  return haystack.includes(query);
}

function renderCatalog() {
  catalogGrid.innerHTML = "";
  const query = searchQuery.trim().toLowerCase();

  const filtered = allWorkers
    .filter((w) => activeCategory === "ALL" || w.category === activeCategory)
    .filter((w) => workerMatchesSearch(w, query));

  if (filtered.length === 0) {
    catalogGrid.innerHTML = '<div class="activity-empty">Aucun Worker ne correspond à cette recherche.</div>';
    return;
  }

  filtered.forEach((w) => catalogGrid.appendChild(buildWorkerCard(w, "workers")));
}

// ---------- PROFIL ----------

function fillProfileCommon(w) {
  const portraitEl = document.getElementById("profile-portrait");

  portraitEl.src = w.portraitUrl;
  portraitEl.alt = w.name;

  document.getElementById("profile-name").textContent = w.name;
  document.getElementById("profile-role").textContent = w.role;
  document.getElementById("profile-personality").textContent = w.personality;

  const chatPreviewEl = document.getElementById("chat-preview");
  const chatPreviewTextEl = document.getElementById("chat-preview-text");
  if (w.communicationStyle) {
    chatPreviewTextEl.textContent = w.communicationStyle;
    chatPreviewEl.hidden = false;
  } else {
    chatPreviewEl.hidden = true;
  }

  const skillsEl = document.getElementById("profile-skills");
  skillsEl.innerHTML = "";
  w.topSkills.forEach((s) => {
    const tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = humanizeTag(s);
    skillsEl.appendChild(tag);
  });
  if (w.skillCount > w.topSkills.length) {
    const remaining = (w.allSkills || []).slice(w.topSkills.length);
    const more = document.createElement("button");
    more.type = "button";
    more.className = "tag tag--more";
    more.textContent = `+${w.skillCount - w.topSkills.length} autres`;
    more.addEventListener("click", () => {
      more.remove();
      remaining.forEach((s) => {
        const tag = document.createElement("span");
        tag.className = "tag";
        tag.textContent = humanizeTag(s);
        skillsEl.appendChild(tag);
      });
    });
    skillsEl.appendChild(more);
  }

  const toolsEl = document.getElementById("profile-tools");
  toolsEl.innerHTML = "";
  w.tools.forEach((t) => {
    const tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = humanizeTag(t);
    toolsEl.appendChild(tag);
  });

  document.getElementById("task-input").value = "";
  document.getElementById("task-error").hidden = true;
  const threadEl = document.getElementById("task-result");
  threadEl.innerHTML = "";
  threadEl.hidden = true;

  showView("profile");
}

async function openWorkerProfile(workerId) {
  currentWorkerId = workerId;
  const w = await fetchJson(`/api/workers/${workerId}`);
  fillProfileCommon(w);

  document.getElementById("activity-block").hidden = false;
  await loadActivity(workerId);
}

async function openChloeProfile() {
  currentWorkerId = "chloe";
  const w = await fetchJson("/api/chloe");
  fillProfileCommon(w);

  document.getElementById("profile-role").textContent = "Orchestratrice — comprend, répartit, vérifie";
  document.getElementById("activity-block").hidden = false;
  await loadActivity("chloe");
}

async function loadActivity(workerId) {
  const data = await fetchJson(`/api/workers/${workerId}/activity`);
  const el = document.getElementById("profile-activity");
  el.innerHTML = "";

  if (!data.activity || data.activity.length === 0) {
    el.innerHTML = '<div class="activity-empty">Aucune tâche enregistrée pour le moment — confiez une mission ci-dessus pour commencer.</div>';
  } else {
    data.activity.forEach((a) => {
      const item = document.createElement("div");
      item.className = "activity-item";
      const cls = statusClass(a.status);
      const when = a.createdAtUtc ? new Date(a.createdAtUtc).toLocaleString(BK_LOCALE()) : "";
      // 2026-09-29 (signale par Kader) : ce panneau n'affichait que le
      // statut et la demande, jamais la reponse du Worker — on voyait
      // "Exécuté" sans jamais voir CE QUI a ete produit. La donnee etait
      // deja recue du serveur (a.answer), juste jamais rendue ici.
      const answer = a.answer || a.executionNote || "";
      item.innerHTML = `
        <span class="a-status ${cls}">${escapeHtml(a.status ?? "")}</span>${escapeHtml(when)}
        <div class="a-request">${escapeHtml(a.request ?? "")}</div>
        ${answer ? `<div class="a-answer">${renderAnswer(answer)}</div>` : ""}
      `;
      el.appendChild(item);
    });
  }

  // Rejoue les vraies missions deja enregistrees dans le fil de
  // discussion — sans ca, actualiser la page (ou juste rouvrir la
  // fiche) faisait perdre toute la conversation, alors qu'elle existe
  // bien cote serveur (signale par Kader, 2026-09-24). Le fil garde
  // uniquement CE que le serveur a reellement enregistre, rien de plus.
  const threadEl = document.getElementById("task-result");
  threadEl.innerHTML = "";
  if (data.activity && data.activity.length > 0) {
    threadEl.hidden = false;
    [...data.activity].reverse().forEach((a) => {
      const turn = document.createElement("div");
      turn.className = "chat-turn";
      const cls = a.authorized === false ? "blocked" : (a.status === "NEEDS_CHLOE_VERIFICATION" ? "needs-chloe" : "");
      const statusLine = a.authorized === false ? (a.status || "Bloqué") : "Exécuté";
      const answer = a.answer || a.executionNote || "Aucune réponse enregistrée.";
      turn.innerHTML = `
        <div class="chat-msg chat-msg-user">${escapeHtml(a.request || "")}</div>
        <div class="chat-msg chat-msg-worker ${cls}"><div class="status-line">${escapeHtml(statusLine)}</div>${renderAnswer(answer)}</div>
      `;
      threadEl.appendChild(turn);
    });
    threadEl.scrollTop = threadEl.scrollHeight;
  } else {
    threadEl.hidden = true;
  }
}

// ---------- SOUMISSION DE MISSION (reutilisee par la fiche profil ET
// la boite de prompt du hero) ----------

// Un visiteur sans mot de passe a droit a UNE vraie mission d'essai,
// tous Workers/Chloe confondus (voir /api/trial/mission cote serveur —
// plafonnee, tronquee, isolee des credits/profil reels de Kader).
// Ce marqueur est juste un confort cote navigateur (efface en 2 clics) ;
// la vraie limite est appliquee par le serveur (par IP et globale/jour).
const TRIAL_USED_KEY = "bk_trial_used";

function trialAlreadyUsed() {
  try {
    return localStorage.getItem(TRIAL_USED_KEY) === "1";
  } catch {
    return false;
  }
}

function markTrialUsed() {
  try {
    localStorage.setItem(TRIAL_USED_KEY, "1");
  } catch {
    // Stockage indisponible (navigation privee...) : tant pis, le
    // plafond cote serveur (par IP) reste la vraie protection.
  }
}

async function runTrialTask(objective) {
  const errorEl = document.getElementById("task-error");
  const resultEl = document.getElementById("task-result");
  errorEl.hidden = true;
  resultEl.hidden = true;

  if (trialAlreadyUsed()) {
    resultEl.className = "task-result needs-chloe";
    resultEl.innerHTML = `<div class="status-line">Essai gratuit déjà utilisé sur ce navigateur</div>
      <p>Inscrivez-vous pour continuer avec un vrai abonnement — essai 3 jours sans carte bancaire.</p>
      <button type="button" class="btn btn-gold" id="trial-cta-lead-btn" style="margin-top:10px">Créer mon compte &rarr;</button>`;
    resultEl.hidden = false;
    document.getElementById("trial-cta-lead-btn").addEventListener("click", () => requireAccount(() => {}));
    return;
  }

  try {
    const result = await fetchJson("/api/trial/mission", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ workerId: currentWorkerId, objective }),
    });

    if (result.error === "TRIAL_DAILY_LIMIT_REACHED" || result.error === "TRIAL_IP_LIMIT_REACHED") {
      errorEl.textContent = "Beaucoup de monde teste BK-AI-WORKERS en ce moment — réessayez un peu plus tard, ou inscrivez-vous pour un accès sans limite.";
      errorEl.hidden = false;
      return;
    }
    if (result.error) {
      errorEl.textContent = "Erreur : " + (result.detail || result.error);
      errorEl.hidden = false;
      return;
    }

    if (result.retry) {
      // Aucun Worker identifie pour cette formulation (routage par
      // mots-cles) : aucun appel reel effectue, l'essai n'est pas
      // consomme — le visiteur peut reformuler et reessayer.
      resultEl.className = "task-result needs-chloe";
      resultEl.innerHTML = `<div class="status-line">Reformulation nécessaire</div>${renderAnswer(result.answer)}`;
      resultEl.hidden = false;
      return;
    }

    markTrialUsed();
    resultEl.className = "task-result";
    resultEl.innerHTML = `<div class="status-line">Aperçu d'essai gratuit${result.degraded ? " (mode secours)" : ""}</div>
      ${renderAnswer(result.answer)}
      ${result.truncated ? '<p class="trial-note">Réponse tronquée — inscrivez-vous pour recevoir le livrable complet, sans limite.</p>' : ""}
      <button type="button" class="btn btn-gold" id="trial-cta-lead-btn" style="margin-top:10px">S'inscrire pour continuer &rarr;</button>`;
    resultEl.hidden = false;
    document.getElementById("trial-cta-lead-btn").addEventListener("click", () => requireAccount(() => {}));
  } catch (err) {
    errorEl.textContent = "Erreur réseau : " + err.message;
    errorEl.hidden = false;
  }
}

// Une mission peut avoir demande a Claude d'utiliser un connecteur en
// ECRITURE : jamais envoye automatiquement (voir ANTHROPIC-ADAPTER.ps1)
// — cette carte est le seul endroit ou le client confirme explicitement
// avant qu'un appel reel ne parte.
// Libellés français pour les clés de payload les plus courantes ; toute
// clé inconnue est affichée telle quelle (son nom brut).
const PENDING_PARAM_LABELS = {
  to: "Destinataire",
  recipient: "Destinataire",
  cc: "Copie",
  bcc: "Copie cachée",
  subject: "Objet",
  body: "Message",
  message: "Message",
  text: "Message",
  content: "Message",
  amount: "Montant",
  currency: "Devise",
  from: "Expéditeur",
  title: "Titre",
  url: "URL",
  phone: "Téléphone",
};

// Bloc « Contenu exact qui sera envoyé » : une ligne par champ du payload
// remonté depuis le fichier PENDING-ACTION. Toute valeur passe par
// escapeHtml ; un champ long est rendu dans un <pre> défilable.
function renderPendingActionPayload(params) {
  if (!params || typeof params !== "object" || Array.isArray(params)) return "";
  const keys = Object.keys(params);
  if (!keys.length) return "";
  const rows = keys.map((key) => {
    const label = PENDING_PARAM_LABELS[String(key).toLowerCase()] || key;
    let value = params[key];
    if (value !== null && typeof value === "object") {
      value = JSON.stringify(value, null, 2);
    } else {
      value = String(value ?? "");
    }
    const longField = value.length > 120 || value.includes("\n");
    const valueHtml = longField
      ? `<pre class="pending-action-payload-pre">${escapeHtml(value)}</pre>`
      : `<span class="pending-action-payload-value">${escapeHtml(value)}</span>`;
    return `<div class="pending-action-payload-row"><span class="pending-action-payload-key">${escapeHtml(label)}</span>${valueHtml}</div>`;
  }).join("");
  return `
    <div class="pending-action-payload">
      <div class="pending-action-payload-title">Contenu exact qui sera envoyé</div>
      ${rows}
    </div>
  `;
}

// Libelles HONNETES selon ce que l'action fait vraiment (revue 2026-10-11) : un brouillon Gmail n'est pas "envoye",
// et "CREATE_DRAFT_POST" PUBLIE sur LinkedIn/Facebook/X/TikTok/Instagram.
function pendingActionVerbs(connectorId, operation) {
  const c = String(connectorId || "").toLowerCase();
  const op = String(operation || "").toUpperCase();
  if (op === "DRAFT_REPLY" && (c === "zendesk" || c === "intercom")) {
    return { title: "📝 Note interne préparée — pas encore ajoutée", button: "Confirmer et ajouter la note", busy: "Ajout en cours…", done: "✅ Note interne ajoutée (rien n'est envoyé au client final)." };
  }
  if ((op === "DRAFT_MESSAGE" && (c === "gmail" || c === "outlook_mail")) || (c === "wordpress" && op.endsWith("_DRAFT"))) {
    return { title: "📝 Brouillon préparé — pas encore créé", button: "Confirmer et créer le brouillon", busy: "Création en cours…", done: "✅ Brouillon créé dans votre outil. Il n'est pas envoyé ni publié : vous le relisez puis vous l'envoyez vous-même." };
  }
  if (op === "CREATE_DRAFT_POST") {
    return { title: "📣 Publication préparée — pas encore publiée", button: "Confirmer et publier", busy: "Publication en cours…", done: "✅ Publié, pour de vrai." };
  }
  if (op === "PLACE_CALL") {
    return { title: "📞 Appel préparé — pas encore passé", button: "Confirmer et appeler", busy: "Appel en cours…", done: "✅ Appel lancé, pour de vrai." };
  }
  return { title: "🔓 Action réelle préparée — pas encore envoyée", button: "Confirmer et envoyer", busy: "Envoi en cours…", done: "✅ Envoyé avec succès, pour de vrai." };
}

function renderPendingActionCard(pendingAction) {
  const verbs = pendingActionVerbs(pendingAction.connectorId, pendingAction.operation);
  const el = document.createElement("div");
  el.className = "pending-action-card";
  el.innerHTML = `
    <div class="pending-action-title">${escapeHtml(verbs.title)}</div>
    <p class="pending-action-detail"><strong>${escapeHtml(pendingAction.connectorId)}</strong> — ${escapeHtml(pendingAction.operation)}${pendingAction.reason ? "<br>" + escapeHtml(pendingAction.reason) : ""}</p>
    ${renderPendingActionPayload(pendingAction.params)}
    <div class="pending-action-buttons">
      <button type="button" class="btn btn-gold" data-action="confirm">${escapeHtml(verbs.button)}</button>
      <button type="button" class="btn btn-ghost" data-action="cancel">Annuler</button>
    </div>
    <div class="pending-action-status" hidden></div>
  `;
  el.querySelector('[data-action="confirm"]').addEventListener("click", async (e) => {
    const confirmBtn = e.currentTarget;
    confirmBtn.disabled = true;
    confirmBtn.textContent = verbs.busy;
    const result = await fetchJson("/api/connector-action/confirm", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ taskId: pendingAction.taskId }),
    });
    const statusEl = el.querySelector(".pending-action-status");
    statusEl.hidden = false;
    if (result.Status === "SUCCESS") {
      statusEl.textContent = verbs.done;
      statusEl.className = "pending-action-status success";
      el.querySelector(".pending-action-buttons").hidden = true;
    } else {
      statusEl.textContent = "Erreur : " + (result.Detail || result.error || "échec de l'envoi.");
      statusEl.className = "pending-action-status error";
      confirmBtn.disabled = false;
      confirmBtn.textContent = verbs.button;
    }
  });
  el.querySelector('[data-action="cancel"]').addEventListener("click", async () => {
    await fetchJson("/api/connector-action/cancel", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ taskId: pendingAction.taskId }),
    });
    el.remove();
  });
  return el;
}

// Taille lisible pour l'affichage des fichiers produits.
function formatFileSize(bytes) {
  if (!bytes || bytes < 1024) return `${bytes || 0} o`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} Ko`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} Mo`;
}

// Fichiers produits par un Worker (Excel/Word/PDF/CSV/image) via code
// execution (voir ANTHROPIC-ADAPTER.ps1) — un lien de telechargement par
// fichier, servi par GET /api/missions/<taskId>/files/<filename>.
function renderTaskFilesBlock(taskId, files) {
  if (!taskId || !Array.isArray(files) || !files.length) return null;
  const links = files.map((file) => {
    const fname = file && file.filename ? String(file.filename) : "";
    if (!fname) return "";
    const size = file && typeof file.sizeBytes === "number" ? ` (${formatFileSize(file.sizeBytes)})` : "";
    const href = `/api/missions/${encodeURIComponent(taskId)}/files/${encodeURIComponent(fname)}`;
    return `<a class="task-file-link" href="${href}" download>📎 ${escapeHtml(fname)}${escapeHtml(size)}</a>`;
  }).join("");
  if (!links) return null;
  const el = document.createElement("div");
  el.className = "task-files-block";
  el.innerHTML = `<div class="task-files-title">Fichiers produits</div>${links}`;
  return el;
}

async function runTask(objective) {
  if (!accountAuthenticated) {
    requireAccount(() => runTask(objective));
    return;
  }

  const errorEl = document.getElementById("task-error");
  const threadEl = document.getElementById("task-result");

  errorEl.hidden = true;
  threadEl.hidden = false;

  // Chaque mission ajoute un nouvel echange au fil de discussion — les
  // precedents restent visibles, comme dans une vraie conversation.
  // Avant ce correctif, chaque envoi ECRASAIT le resultat precedent
  // (innerHTML remplace en entier) : la reponse au premier message
  // disparaissait des qu'on envoyait le second — signale comme "pas
  // professionnel" par Kader (2026-09-24), corrige ici.
  const turn = document.createElement("div");
  turn.className = "chat-turn";
  const workerLabel = currentWorkerId === "chloe" ? "Chloé" : workerNameById(currentWorkerId);
  turn.innerHTML = `
    <div class="chat-msg chat-msg-user">${escapeHtml(objective)}</div>
    <div class="chat-msg chat-msg-worker">
      <div class="task-loading"><span></span><span></span><span></span></div>
      <p class="task-loading-text">${escapeHtml(workerLabel)} traite votre mission…</p>
    </div>
  `;
  threadEl.appendChild(turn);
  turn.scrollIntoView({ behavior: "smooth", block: "end" });
  const responseEl = turn.querySelector(".chat-msg-worker");

  try {
    // Mission en arriere-plan : on ne bloque plus la connexion HTTP le
    // temps du pipeline (qui pouvait durer plusieurs minutes et se faire
    // trancher par le proxy). Le POST /async renvoie un jobId immediatement
    // (202), puis on interroge GET /api/missions/async/<jobId> toutes les
    // 2 s jusqu'a DONE/ERROR. Les endpoints synchrones restent disponibles
    // cote serveur (retrocompatibilite) ; seule l'UI live passe par /async.
    const endpoint = currentWorkerId === "chloe"
      ? "/api/chloe/task"
      : `/api/workers/${currentWorkerId}/task`;
    const asyncEndpoint = endpoint + "/async";

    let result;
    const started = await fetchJson(asyncEndpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ objective }),
    });

    if (started.error || !started.jobId) {
      // Garde refusee en amont (compte, abonnement, objectif...) : on
      // traite started comme le resultat et on laisse le rendu habituel
      // ci-dessous l'afficher.
      result = started;
    } else {
      const POLL_INTERVAL_MS = 2000;
      const MAX_POLL_ATTEMPTS = 330; // ~11 min
      let pollFailures = 0;
      for (let attempt = 0; attempt < MAX_POLL_ATTEMPTS; attempt++) {
        await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
        let job;
        try {
          job = await fetchJson(`/api/missions/async/${started.jobId}`, {
            method: "GET",
            headers: { "Content-Type": "application/json" },
          });
          pollFailures = 0;
        } catch (pollErr) {
          // Coupure passagere (deploiement, reseau mobile, appli en arriere-plan) : la mission continue cote serveur,
          // on reessaie au lieu d'abandonner (et de pousser le client a relancer une 2e mission payante).
          if (++pollFailures >= 8) throw pollErr;
          continue;
        }
        if (job.error === "ACCOUNT_REQUIRED") {
          turn.remove();
          requireAccount(() => runTask(objective));
          return;
        }
        if (job.error) {
          result = job;
          break;
        }
        if (job.status === "DONE") {
          result = job.result || {};
          break;
        }
        if (job.status === "ERROR") {
          result = { error: "SUBMIT_EXCEPTION", detail: job.error };
          break;
        }
      }
      if (result === undefined) {
        // Plafond de securite atteint : on cesse d'interroger plutot que
        // de boucler indefiniment. La mission continue cote serveur.
        responseEl.className = "chat-msg chat-msg-worker needs-chloe";
        responseEl.innerHTML = `<div class="status-line">Toujours en cours</div>
          <p>La mission prend plus de temps que prévu. Elle continue en arrière-plan — réessayez dans un instant.</p>`;
        turn.scrollIntoView({ behavior: "smooth", block: "end" });
        return;
      }
    }

    if (result.error === "ACCOUNT_REQUIRED") {
      // La session a expire entre-temps : redemande une connexion
      // plutot que d'afficher une erreur brute. Retire ce tour en
      // attente, il sera rejoue une fois reconnecte.
      turn.remove();
      requireAccount(() => runTask(objective));
      return;
    }
    if (result.error === "SUBSCRIPTION_REQUIRED") {
      responseEl.className = "chat-msg chat-msg-worker needs-chloe";
      responseEl.innerHTML = `<div class="status-line">Abonnement requis</div>
        <p>${escapeHtml(result.detail || "Votre quota est épuisé.")}</p>
        <button type="button" class="btn btn-gold subscribe-cta-btn" style="margin-top:10px">Voir les abonnements &rarr;</button>`;
      responseEl.querySelector(".subscribe-cta-btn").addEventListener("click", () => showView("billing"));
      return;
    }
    if (result.error) {
      responseEl.className = "chat-msg chat-msg-worker blocked";
      responseEl.innerHTML = `<div class="status-line">Erreur</div><p>${escapeHtml(result.detail || result.error)}</p>`;
      errorEl.textContent = "Erreur : " + (result.detail || result.error);
      errorEl.hidden = false;
    } else if (currentWorkerId === "chloe") {
      const blocked = result.Status !== "SUCCESS";
      responseEl.className = "chat-msg chat-msg-worker" + (blocked ? " needs-chloe" : "");
      const workers = (result.SelectedWorkers || []).join(", ");
      const statusLine = blocked ? (chloeStatusLabel(result.Status) || "Aucun Worker identifié") : `Traité par : ${workers}`;
      responseEl.innerHTML = `<div class="status-line">${statusLine}</div>${renderAnswer(result.FinalSynthesis || "Aucune synthèse disponible.")}`;
    } else {
      const needsChloe = result.Status === "NEEDS_CHLOE_VERIFICATION";
      const blocked = result.Authorized !== true;
      responseEl.className = "chat-msg chat-msg-worker" + (needsChloe ? " needs-chloe" : blocked ? " blocked" : "");
      const statusLine = blocked ? (result.Reason || result.Status || "Bloqué") : "Exécuté";
      const answer = result.Result && result.Result.Answer ? result.Result.Answer
        : (result.ExecutionNote || (needsChloe ? "Cette action passe par le chat avec Chloé pour vérification." : "Tâche autorisée, en attente de routage vers un Worker."));
      responseEl.innerHTML = `<div class="status-line">${escapeHtml(statusLine)}</div>${renderAnswer(answer)}`;
      await loadActivity(currentWorkerId);
    }
    // Fichiers produits (telechargement) — branche Chloe (un TaskId par
    // Worker dans Results[]) ou branche directe (result.Result.TaskId).
    if (currentWorkerId === "chloe" && Array.isArray(result.Results)) {
      result.Results.forEach((r) => {
        if (r && r.Result && Array.isArray(r.Result.Files)) {
          const block = renderTaskFilesBlock(r.Result.TaskId, r.Result.Files);
          if (block) turn.appendChild(block);
        }
      });
    } else if (result.Result && Array.isArray(result.Result.Files) && result.Result.Files.length) {
      const block = renderTaskFilesBlock(result.Result.TaskId, result.Result.Files);
      if (block) turn.appendChild(block);
    }
    if (result.pendingAction) {
      turn.appendChild(renderPendingActionCard(result.pendingAction));
    }
    turn.scrollIntoView({ behavior: "smooth", block: "end" });
  } catch (err) {
    responseEl.className = "chat-msg chat-msg-worker blocked";
    responseEl.innerHTML = `<div class="status-line">Erreur réseau</div><p>${escapeHtml(err.message)}</p>`;
    errorEl.textContent = "Erreur réseau : " + err.message;
    errorEl.hidden = false;
  }
}

// ---------- BULLE DE DISCUSSION FLOTTANTE (Chloe) ----------
// Widget persistant en bas a droite, visible sur toutes les vues (hors
// de <main>, donc jamais touche par showView). Reutilise les memes
// regles que le reste du produit : compte requis pour envoyer une
// mission, verification systematique de Chloe avant toute action
// sensible (cf. runTask, dont la branche "chloe" est reprise ici).

// Historique reel dans la bulle (2026-09-24, demande finale de Kader —
// un essai precedent de retirer l'historique sur fermeture a ete
// corrige en sens inverse sur sa demande explicite : la bulle doit
// garder ses vraies missions, comme #task-result sur la fiche
// complete). Charge une seule fois par session de page, uniquement une
// fois reellement connecte.
let chloeFabHistoryLoaded = false;

async function loadChloeFabHistory() {
  const data = await fetchJson("/api/workers/chloe/activity");
  const items = data.activity || [];
  if (items.length === 0) return;
  const bodyEl = document.getElementById("chloe-fab-body");
  const frag = document.createDocumentFragment();
  [...items].reverse().forEach((a) => {
    const turn = document.createElement("div");
    turn.className = "chat-turn";
    const cls = a.authorized === false ? "blocked" : (a.status === "NEEDS_CHLOE_VERIFICATION" ? "needs-chloe" : "");
    const statusLine = a.authorized === false ? (a.status || "Bloqué") : "Exécuté";
    const answer = a.answer || a.executionNote || "Aucune réponse enregistrée.";
    turn.innerHTML = `
      <div class="chat-msg chat-msg-user">${escapeHtml(a.request || "")}</div>
      <div class="chat-msg chat-msg-worker ${cls}"><div class="status-line">${escapeHtml(statusLine)}</div>${renderAnswer(answer)}</div>
    `;
    frag.appendChild(turn);
  });
  bodyEl.appendChild(frag);
  bodyEl.scrollTop = bodyEl.scrollHeight;
}

function closeChloeFab() {
  document.getElementById("chloe-fab-panel").hidden = true;
  document.getElementById("chloe-fab").classList.remove("open");
}

async function openChloeFab() {
  document.getElementById("chloe-fab-panel").hidden = false;
  document.getElementById("chloe-fab").classList.add("open");
  document.getElementById("chloe-fab-input").focus();
  if (!chloeFabHistoryLoaded && accountAuthenticated) {
    chloeFabHistoryLoaded = true;
    await loadChloeFabHistory();
  }
}

async function runChloeFabTask(objective) {
  if (!accountAuthenticated) {
    requireAccount(() => runChloeFabTask(objective));
    return;
  }

  const bodyEl = document.getElementById("chloe-fab-body");
  const turn = document.createElement("div");
  turn.className = "chat-turn";
  turn.innerHTML = `
    <div class="chat-msg chat-msg-user">${escapeHtml(objective)}</div>
    <div class="chat-msg chat-msg-worker">
      <div class="task-loading"><span></span><span></span><span></span></div>
      <p class="task-loading-text">Chloé traite votre mission…</p>
    </div>
  `;
  bodyEl.appendChild(turn);
  turn.scrollIntoView({ behavior: "smooth", block: "end" });
  const responseEl = turn.querySelector(".chat-msg-worker");

  try {
    const result = await fetchJson("/api/chloe/task", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ objective }),
    });

    if (result.error === "ACCOUNT_REQUIRED") {
      turn.remove();
      requireAccount(() => runChloeFabTask(objective));
      return;
    }
    if (result.error === "SUBSCRIPTION_REQUIRED") {
      responseEl.className = "chat-msg chat-msg-worker needs-chloe";
      responseEl.innerHTML = `<div class="status-line">Abonnement requis</div>
        <p>${escapeHtml(result.detail || "Votre quota est épuisé.")}</p>
        <button type="button" class="btn btn-gold subscribe-cta-btn" style="margin-top:10px">Voir les abonnements &rarr;</button>`;
      responseEl.querySelector(".subscribe-cta-btn").addEventListener("click", () => {
        closeChloeFab();
        showView("billing");
      });
      return;
    }
    if (result.error) {
      responseEl.className = "chat-msg chat-msg-worker blocked";
      responseEl.innerHTML = `<div class="status-line">Erreur</div><p>${escapeHtml(result.detail || result.error)}</p>`;
    } else {
      const blocked = result.Status !== "SUCCESS";
      responseEl.className = "chat-msg chat-msg-worker" + (blocked ? " needs-chloe" : "");
      const workers = (result.SelectedWorkers || []).join(", ");
      const statusLine = blocked ? (chloeStatusLabel(result.Status) || "Aucun Worker identifié") : `Traité par : ${workers}`;
      responseEl.innerHTML = `<div class="status-line">${statusLine}</div>${renderAnswer(result.FinalSynthesis || "Aucune synthèse disponible.")}`;
    }
    if (result.pendingAction) {
      turn.appendChild(renderPendingActionCard(result.pendingAction));
    }
    turn.scrollIntoView({ behavior: "smooth", block: "end" });
  } catch (err) {
    responseEl.className = "chat-msg chat-msg-worker blocked";
    responseEl.innerHTML = `<div class="status-line">Erreur réseau</div><p>${escapeHtml(err.message)}</p>`;
  }
}

document.getElementById("chloe-fab-toggle").addEventListener("click", () => {
  if (document.getElementById("chloe-fab-panel").hidden) openChloeFab();
  else closeChloeFab();
});

document.getElementById("chloe-fab-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const input = document.getElementById("chloe-fab-input");
  const objective = input.value.trim();
  if (!objective) return;
  input.value = "";
  runChloeFabTask(objective);
});

// ---------- NAVIGATION ----------

backBtn.addEventListener("click", () => {
  showView(cameFromView === "workers" ? "workers" : "home");
  currentWorkerId = null;
});

document.getElementById("workers-back-btn").addEventListener("click", () => showView("home"));
document.getElementById("pricing-back-btn").addEventListener("click", () => showView("home"));
document.getElementById("automations-back-btn").addEventListener("click", () => showView("home"));
document.getElementById("analytics-back-btn").addEventListener("click", () => showView("home"));
document.getElementById("onboarding-back-btn").addEventListener("click", () => showView("home"));
document.getElementById("billing-back-btn").addEventListener("click", () => showView("home"));
document.getElementById("faq-back-btn").addEventListener("click", () => showView("home"));
document.getElementById("legal-back-btn").addEventListener("click", () => showView("home"));

document.getElementById("nav-home").addEventListener("click", (e) => {
  e.preventDefault();
  showView("home");
});
document.getElementById("nav-catalog").addEventListener("click", (e) => {
  e.preventDefault();
  showView("workers");
});
document.getElementById("nav-automations").addEventListener("click", (e) => {
  e.preventDefault();
  showView("automations");
});
document.getElementById("nav-analytics").addEventListener("click", (e) => {
  e.preventDefault();
  showView("analytics");
});
document.getElementById("nav-onboarding").addEventListener("click", (e) => {
  e.preventDefault();
  // "Demarrer" ouvre le vrai parcours guide (profil -> objectif -> equipe
  // proposee par Chloe -> premiere mission). Avant, connecte, le clic ne
  // faisait rien (bouton "inactif", signale par Kader) ; deconnecte, il
  // ouvre la creation de compte puis enchaine sur le parcours.
  requireAccount(() => showView("onboarding"));
});
document.getElementById("onboarding-step1-next").addEventListener("click", async () => {
  // Le profil est enregistre cote serveur : il est ensuite transmis aux
  // Workers dans leurs consignes (contexte entreprise).
  try {
    await fetchJson("/api/profile", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        companyName: document.getElementById("onboarding-company-name").value,
        sector: document.getElementById("onboarding-company-sector").value,
        description: document.getElementById("onboarding-company-description").value,
      }),
    });
  } catch (err) { /* non bloquant : on continue le parcours */ }
  onboardingSetStep(2);
});
document.getElementById("onboarding-analyze-btn").addEventListener("click", onboardingAnalyze);
document.getElementById("onboarding-back-to-objective").addEventListener("click", () => {
  onboardingSetStep(2);
});
document.getElementById("onboarding-validate-btn").addEventListener("click", onboardingValidate);
document.getElementById("onboarding-finish-btn").addEventListener("click", () => showView("home"));
document.getElementById("nav-billing").addEventListener("click", (e) => {
  e.preventDefault();
  showView("billing");
});
document.getElementById("nav-admin").addEventListener("click", (e) => {
  e.preventDefault();
  showView("admin");
});
document.getElementById("admin-back-btn").addEventListener("click", () => showView("home"));
document.getElementById("billing-cancel-btn").addEventListener("click", cancelBillingPlan);
document.getElementById("billing-recharge-btn").addEventListener("click", rechargeBillingCredits);
document.querySelectorAll("#billing-interval-toggle button").forEach((btn) => {
  btn.addEventListener("click", () => {
    billingInterval = btn.dataset.interval;
    document.querySelectorAll("#billing-interval-toggle button").forEach((b) => {
      b.classList.toggle("active", b === btn);
    });
    loadBilling();
  });
});
document.getElementById("nav-pricing").addEventListener("click", (e) => {
  e.preventDefault();
  showView("pricing");
});
document.getElementById("pricing-cta-chloe-btn").addEventListener("click", openChloeFab);

function showLegalSection(anchorId) {
  showView("legal");
  if (anchorId) {
    setTimeout(() => {
      const target = document.getElementById(anchorId);
      if (target) target.scrollIntoView({ behavior: "smooth" });
    }, 0);
  }
}

document.getElementById("nav-faq").addEventListener("click", (e) => {
  e.preventDefault();
  showView("faq");
});
document.querySelectorAll(".legal-nav a").forEach((a) => {
  a.addEventListener("click", (e) => {
    e.preventDefault();
    showLegalSection(a.getAttribute("href").slice(1));
  });
});
document.getElementById("footer-nav-workers").addEventListener("click", (e) => {
  e.preventDefault();
  showView("workers");
});
document.getElementById("footer-nav-chloe").addEventListener("click", (e) => {
  e.preventDefault();
  openChloeFab();
});
document.getElementById("footer-nav-automations").addEventListener("click", (e) => {
  e.preventDefault();
  showView("automations");
});
document.getElementById("footer-nav-analytics").addEventListener("click", (e) => {
  e.preventDefault();
  showView("analytics");
});
document.getElementById("footer-nav-billing").addEventListener("click", (e) => {
  e.preventDefault();
  showView("billing");
});
document.getElementById("footer-cta-start-btn").addEventListener("click", () => {
  requireAccount(() => showView("onboarding"));
});
document.getElementById("footer-cta-chloe-btn").addEventListener("click", openChloeFab);
document.getElementById("footer-nav-pricing").addEventListener("click", (e) => {
  e.preventDefault();
  showView("pricing");
});
document.getElementById("footer-nav-faq").addEventListener("click", (e) => {
  e.preventDefault();
  showView("faq");
});
document.getElementById("footer-nav-cgv").addEventListener("click", (e) => {
  e.preventDefault();
  showLegalSection("legal-cgv");
});
document.getElementById("footer-nav-mentions").addEventListener("click", (e) => {
  e.preventDefault();
  showLegalSection("legal-mentions");
});
document.getElementById("footer-nav-confidentialite").addEventListener("click", (e) => {
  e.preventDefault();
  showLegalSection("legal-confidentialite");
});
document.getElementById("footer-nav-cookies").addEventListener("click", (e) => {
  e.preventDefault();
  showLegalSection("legal-cookies");
});
document.getElementById("nav-chloe").addEventListener("click", (e) => {
  e.preventDefault();
  cameFromView = "home";
  openChloeProfile();
});
document.getElementById("nav-chloe-btn").addEventListener("click", openChloeFab);
document.getElementById("topbar-account-btn").addEventListener("click", () => {
  if (!accountAuthenticated) {
    requireAccount(() => {});
    return;
  }
  showView(isOperator ? "admin" : "billing");
});
document.getElementById("topbar-logout-btn").addEventListener("click", fullLogout);

const navLinksEl = document.querySelector(".nav-links");
document.getElementById("mobile-menu-btn").addEventListener("click", () => {
  navLinksEl.classList.toggle("nav-open");
});
navLinksEl.querySelectorAll("a").forEach((a) => {
  a.addEventListener("click", () => navLinksEl.classList.remove("nav-open"));
});
document.getElementById("hero-chloe-btn").addEventListener("click", () => {
  cameFromView = "home";
  openChloeProfile();
});
[
  "hero-workers-btn",
  "wheel-see-all-btn",
  "final-cta-workers-btn",
].forEach((id) => document.getElementById(id).addEventListener("click", () => showView("workers")));
document.getElementById("final-cta-chloe-btn").addEventListener("click", openChloeFab);

searchInput.addEventListener("input", (e) => {
  searchQuery = e.target.value;
  renderCatalog();
});

document.getElementById("role-finder-form").addEventListener("submit", (e) => {
  e.preventDefault();
  searchQuery = document.getElementById("role-finder-input").value;
  searchInput.value = searchQuery;
  renderCatalog();
  showView("workers");
});

document.getElementById("task-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = document.getElementById("task-input");
  const errorEl = document.getElementById("task-error");
  const btn = e.target.querySelector("button");

  const objective = input.value.trim();
  if (!objective) {
    errorEl.textContent = "Écrivez une mission avant d'envoyer.";
    errorEl.hidden = false;
    return;
  }

  input.value = "";
  btn.disabled = true;
  btn.textContent = "Traitement...";
  await runTask(objective);
  btn.disabled = false;
  btn.textContent = "Envoyer";
  input.focus();
});

// ---------- BOITE DE PROMPT (hero) ----------

function renderPromptAgentOptions() {
  const select = document.getElementById("prompt-agent-select");
  const avatar = document.getElementById("prompt-agent-avatar");
  select.innerHTML = "";

  const chloeOpt = document.createElement("option");
  chloeOpt.value = "chloe";
  chloeOpt.textContent = `${chloeData.name} — Chloé choisit pour vous`;
  select.appendChild(chloeOpt);

  allWorkers.forEach((w) => {
    const opt = document.createElement("option");
    opt.value = w.id;
    opt.textContent = `${w.name} — ${w.category}`;
    select.appendChild(opt);
  });

  const updateAvatar = () => {
    const id = select.value;
    const w = id === "chloe" ? chloeData : allWorkers.find((x) => x.id === id);
    if (w) avatar.src = w.portraitUrl;
  };
  select.addEventListener("change", updateAvatar);
  updateAvatar();
}

document.getElementById("hero-prompt-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const textarea = document.getElementById("hero-prompt-input");
  const select = document.getElementById("prompt-agent-select");
  const sendBtn = document.getElementById("prompt-send-btn");

  const objective = textarea.value.trim();
  if (!objective) {
    textarea.focus();
    return;
  }

  sendBtn.disabled = true;
  cameFromView = "home";

  if (select.value === "chloe") {
    await openChloeProfile();
  } else {
    await openWorkerProfile(select.value);
  }

  document.getElementById("task-input").value = objective;
  document.getElementById("task-form").requestSubmit();

  textarea.value = "";
  sendBtn.disabled = false;
});

document.getElementById("gate-submit-btn").addEventListener("click", submitGatePassword);
document.getElementById("gate-cancel-btn").addEventListener("click", () => {
  document.getElementById("gate-modal").hidden = true;
  pendingGateAction = null;
});
document.getElementById("gate-password-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter") submitGatePassword();
});

Promise.all([checkGateStatus(), checkAccountStatus()]).then(() => {
  bootstrap();
  handleStripeCheckoutReturn();
  syncAdminNavVisibility();
});

document.getElementById("account-tab-signup").addEventListener("click", () => showAccountTab("signup"));
document.getElementById("account-tab-login").addEventListener("click", () => showAccountTab("login"));
document.getElementById("account-cancel-btn-1").addEventListener("click", closeAccountModal);
document.getElementById("account-cancel-btn-2").addEventListener("click", closeAccountModal);
document.getElementById("account-signup-btn").addEventListener("click", submitAccountSignup);
document.getElementById("account-login-btn").addEventListener("click", submitAccountLogin);
// 2026-09-30 : deplace du modal d'inscription client (Kader : "ca fait pas
// pro" d'avoir l'acces admin mele au parcours d'inscription de ses propres
// clients) vers un lien discret en pied de page, comme la plupart des sites.
document.getElementById("footer-owner-btn").addEventListener("click", switchToOwnerLogin);
document.getElementById("analytics-connect-required").querySelector("button").addEventListener("click", () => requireAccount(() => loadAnalytics()));
document.getElementById("billing-connect-required").querySelector("button").addEventListener("click", () => requireAccount(() => loadBilling()));
document.getElementById("billing-connect-pricing-link").addEventListener("click", (e) => {
  e.preventDefault();
  showView("pricing");
});
document.getElementById("account-signup-password").addEventListener("keydown", (e) => {
  if (e.key === "Enter") submitAccountSignup();
});
document.getElementById("account-login-password").addEventListener("keydown", (e) => {
  if (e.key === "Enter") submitAccountLogin();
});

// Integration generique Zapier/Make (2026-09-30) : voir loadZapierCard().
document.getElementById("zapier-apikey-generate-btn").addEventListener("click", async () => {
  const hadKey = !document.getElementById("zapier-apikey-revoke-btn").hidden;
  if (hadKey && !confirm("Générer une nouvelle clé révoque immédiatement l'ancienne. Continuer ?")) return;
  const result = await fetchJson("/api/integrations/apikey/generate", { method: "POST" });
  if (result.error === "ACCOUNT_REQUIRED") { requireAccount(() => loadZapierCard()); return; }
  document.getElementById("zapier-apikey-value").textContent = result.apiKey;
  document.getElementById("zapier-apikey-reveal").hidden = false;
  await loadZapierCard();
});
document.getElementById("zapier-apikey-revoke-btn").addEventListener("click", async () => {
  if (!confirm("Révoquer votre clé API ? Tous les Zaps/scénarios qui l'utilisent cesseront de fonctionner.")) return;
  await fetchJson("/api/integrations/apikey/revoke", { method: "POST" });
  document.getElementById("zapier-apikey-reveal").hidden = true;
  await loadZapierCard();
});
document.getElementById("zapier-apikey-copy-btn").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(document.getElementById("zapier-apikey-value").textContent);
    showToast("Clé copiée ✓", true);
  } catch (e) {
    showToast("Copie impossible — sélectionnez le texte manuellement", false);
  }
});
document.getElementById("zapier-webhook-save-btn").addEventListener("click", async () => {
  const url = document.getElementById("zapier-webhook-input").value.trim();
  const result = await fetchJson("/api/integrations/webhook", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url }),
  });
  if (result.error === "ACCOUNT_REQUIRED") { requireAccount(() => loadZapierCard()); return; }
  if (result.error) { showToast("URL invalide", false); return; }
  showToast(url ? "Webhook enregistré ✓" : "Webhook supprimé", true);
  await loadZapierCard();
});


// ---------- BOUTONS QUI "ROULENT" AU SURVOL (2026-09-25) ----------
// Enveloppe le texte des .btn/.plan-cta dans deux copies superposees ;
// le CSS les fait defiler au survol (effet Limova demande par Kader).
// MutationObserver : les boutons crees dynamiquement (cartes, modales)
// sont aussi equipes.
function enhanceButtons(root) {
  (root || document).querySelectorAll(".btn, .plan-cta").forEach((b) => {
    if (b.dataset.rolled) return;
    if (b.disabled) return;
    if (![...b.childNodes].every((n) => n.nodeType === 3)) return;
    const text = b.textContent.trim();
    if (!text) return;
    b.dataset.rolled = "1";
    b.innerHTML = `<span class="roll-in"><span>${escapeHtml(text)}</span><span aria-hidden="true">${escapeHtml(text)}</span></span>`;
  });
}
if (!PREFERS_REDUCED_MOTION) {
  enhanceButtons();
  let rollQueued = false;
  new MutationObserver(() => {
    if (rollQueued) return;
    rollQueued = true;
    requestAnimationFrame(() => { rollQueued = false; enhanceButtons(); });
  }).observe(document.body, { childList: true, subtree: true, characterData: true });
}


// Fond anime du hero : constellation doree discrete (points qui derivent,
// reliés quand ils sont proches, attires legerement par la souris).
// Coupe si mouvement reduit, ou quand l'onglet/la section est hors ecran.
function initHeroCanvas(cv) {
  if (!cv || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const ctx = cv.getContext("2d");
  const band = cv.parentElement;
  let w = 0, h = 0, dpr = Math.min(window.devicePixelRatio || 1, 2), pts = [], running = false, visible = true;
  const mouse = { x: -999, y: -999 };
  const resize = () => {
    w = band.clientWidth; h = band.clientHeight;
    cv.width = w * dpr; cv.height = h * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const n = Math.max(24, Math.min(70, Math.round((w * h) / 22000)));
    pts = Array.from({ length: n }, () => ({
      x: Math.random() * w, y: Math.random() * h,
      vx: (Math.random() - .5) * .28, vy: (Math.random() - .5) * .28, r: Math.random() * 1.4 + .6,
    }));
  };
  const frame = () => {
    if (!running) return;
    ctx.clearRect(0, 0, w, h);
    for (const p of pts) {
      p.x += p.vx; p.y += p.vy;
      if (p.x < 0 || p.x > w) p.vx *= -1;
      if (p.y < 0 || p.y > h) p.vy *= -1;
      const dx = mouse.x - p.x, dy = mouse.y - p.y, d2 = dx * dx + dy * dy;
      if (d2 < 22000) { p.x -= dx * .0009; p.y -= dy * .0009; }
      ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, 6.283);
      ctx.fillStyle = "rgba(226,178,84,.75)"; ctx.fill();
    }
    for (let i = 0; i < pts.length; i++) {
      for (let k = i + 1; k < pts.length; k++) {
        const dx = pts[i].x - pts[k].x, dy = pts[i].y - pts[k].y, d = dx * dx + dy * dy;
        if (d < 12000) {
          ctx.strokeStyle = "rgba(226,178,84," + (0.16 * (1 - d / 12000)).toFixed(3) + ")";
          ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(pts[i].x, pts[i].y); ctx.lineTo(pts[k].x, pts[k].y); ctx.stroke();
        }
      }
    }
    requestAnimationFrame(frame);
  };
  const sync = () => {
    const should = visible && !document.hidden;
    if (should && !running) { running = true; requestAnimationFrame(frame); }
    else if (!should) running = false;
  };
  band.addEventListener("mousemove", (e) => { const r = band.getBoundingClientRect(); mouse.x = e.clientX - r.left; mouse.y = e.clientY - r.top; });
  band.addEventListener("mouseleave", () => { mouse.x = mouse.y = -999; });
  new IntersectionObserver((es) => { visible = es[0].isIntersecting; sync(); }).observe(band);
  document.addEventListener("visibilitychange", sync);
  window.addEventListener("resize", resize);
  resize(); sync();
}

// Placeholder du champ de saisie : suggestions qui defilent (invite a essayer).
function initPromptSuggestions() {
  const ta = document.getElementById("hero-prompt-input");
  if (!ta) return;
  const IDEAS = {
    fr: [
      "Rédige un email de prospection pour un nouveau client…",
      "Write a product description for my online store…",
      "Crée un plan de contenu LinkedIn pour ce mois…",
      "Analyse mes ventes de la semaine et propose des actions…",
      "Redacta una respuesta amable a un cliente enfadado…",
      "Prépare le rapport mensuel de mon équipe…",
    ],
    en: [
      "Write a prospecting email for a new client…",
      "Rédige une fiche produit pour ma boutique en ligne…",
      "Create a LinkedIn content plan for this month…",
      "Analyse this week's sales and suggest actions…",
      "Redacta una respuesta amable a un cliente enfadado…",
      "Prepare my team's monthly report…",
    ],
  };
  let ideas = IDEAS[(window.BK_LANG && window.BK_LANG()) || "fr"];
  document.addEventListener("bk:lang", (e) => { ideas = IDEAS[e.detail] || IDEAS.fr; });
  if (PREFERS_REDUCED_MOTION) { ta.placeholder = ((window.BK_LANG && window.BK_LANG() === "en") ? "E.g. " : "Ex : ") + ideas[0]; return; }
  // Machine a ecrire : tape la phrase lettre par lettre, la garde un instant,
  // l'efface, puis passe a la suivante — en continu tant que le champ est vide.
  let idx = 0, pos = 0, phase = "type", wait = 0;
  setInterval(() => {
    if (document.activeElement === ta || ta.value || document.hidden) return;
    const text = ideas[idx];
    if (wait > 0) { wait--; return; }
    if (phase === "type") {
      pos++;
      if (pos >= text.length) { phase = "erase"; wait = 30; }
    } else {
      pos -= 2;
      if (pos <= 0) { pos = 0; phase = "type"; idx = (idx + 1) % ideas.length; wait = 6; }
    }
    ta.placeholder = ((window.BK_LANG && window.BK_LANG() === "en") ? "E.g. " : "Ex : ") + text.slice(0, Math.max(pos, 0)) + (pos > 0 && pos < text.length ? "▍" : "");
  }, 55);
}
// Meme fond anime dans chaque bandeau de page (Workers, Tarifs, ...).
document.querySelectorAll(".page-band, .site-footer").forEach((band) => {
  const cv = document.createElement("canvas");
  cv.className = "hero-canvas";
  cv.setAttribute("aria-hidden", "true");
  band.insertBefore(cv, band.firstChild);
});
document.querySelectorAll(".hero-canvas").forEach(initHeroCanvas);
initPromptSuggestions();

// Inclinaison 3D douce des cartes au survol (souris uniquement).
if (window.matchMedia("(hover: hover) and (pointer: fine)").matches && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
  const TILT = ".worker-card, .plan-card";
  document.addEventListener("mousemove", (e) => {
    const card = e.target.closest && e.target.closest(TILT);
    if (!card) return;
    const r = card.getBoundingClientRect();
    const px = (e.clientX - r.left) / r.width - .5, py = (e.clientY - r.top) / r.height - .5;
    card.style.transform = `perspective(900px) rotateX(${(-py * 5).toFixed(2)}deg) rotateY(${(px * 6).toFixed(2)}deg) translateY(-4px)`;
    card.style.setProperty("--mx", (px + .5) * 100 + "%");
    card.style.setProperty("--my", (py + .5) * 100 + "%");
  });
  document.addEventListener("mouseout", (e) => {
    const card = e.target.closest && e.target.closest(TILT);
    if (card && !card.contains(e.relatedTarget)) card.style.transform = "";
  });
}


// ---------- Reserver une demo ----------
(function initDemoModal() {
  const modal = document.getElementById("demo-modal");
  if (!modal) return;
  const form = document.getElementById("demo-form");
  const errEl = document.getElementById("demo-error");
  const btn = document.getElementById("demo-submit-btn");
  const open = () => {
    document.getElementById("demo-form-wrap").hidden = false;
    document.getElementById("demo-done").hidden = true;
    errEl.hidden = true;
    modal.hidden = false;
    setTimeout(() => document.getElementById("demo-name").focus(), 30);
  };
  const close = () => { modal.hidden = true; };
  document.querySelectorAll("[data-open-demo]").forEach((b) => b.addEventListener("click", open));
  document.getElementById("demo-cancel-btn").addEventListener("click", close);
  document.getElementById("demo-close-btn").addEventListener("click", close);
  modal.addEventListener("click", (e) => { if (e.target === modal) close(); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !modal.hidden) close(); });
  const MSG = {
    NAME_REQUIRED: "Indiquez votre nom.",
    EMAIL_INVALID: "Cet email ne semble pas valide.",
    RATE_LIMITED: "Trop de demandes depuis cette connexion. Réessayez plus tard.",
  };
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    errEl.hidden = true;
    btn.disabled = true;
    const payload = {
      name: document.getElementById("demo-name").value,
      email: document.getElementById("demo-email").value,
      company: document.getElementById("demo-company").value,
      phone: document.getElementById("demo-phone").value,
      slot: document.getElementById("demo-slot").value,
      message: document.getElementById("demo-message").value,
      website: document.getElementById("demo-website").value,
      timezone: (Intl.DateTimeFormat().resolvedOptions().timeZone) || "",
      lang: navigator.language || "",
    };
    const res = await fetchJson("/api/demo-request", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
    btn.disabled = false;
    if (res.ok) {
      form.reset();
      document.getElementById("demo-form-wrap").hidden = true;
      document.getElementById("demo-done").hidden = false;
    } else {
      errEl.textContent = MSG[res.error] || "Envoi impossible pour le moment. Réessayez.";
      errEl.hidden = false;
    }
  });
})();

async function loadAdminDemos() {
  const list = document.getElementById("admin-demo-list");
  if (!list) return;
  const data = await fetchJson("/api/admin/demo-requests");
  if (data.error) return;
  const rows = data.requests || [];
  list.innerHTML = rows.length
    ? rows.map((r) => `<div class="admin-activity-row kind-demo"><span class="admin-activity-when">${new Date(r.atUtc).toLocaleString(BK_LOCALE())}</span><span class="admin-activity-kind">${escapeHtml(r.slot || "Démo")}</span><span class="admin-activity-who">${escapeHtml(r.name)} — ${escapeHtml(r.email)}</span><span class="admin-activity-text">${escapeHtml([r.company, r.phone, r.timezone].filter(Boolean).join(" · "))}</span>${r.message ? `<span class="admin-demo-msg">${escapeHtml(r.message)}</span>` : ""}</div>`).join("")
    : '<div class="activity-empty">Aucune demande de démo pour le moment.</div>';
}

// ---------- Canal WhatsApp : "Lier mon WhatsApp" (code a 6 chiffres + lien wa.me) ----------
async function renderWhatsappCard(gridEl) {
  if (!accountAuthenticated) return;
  const st = await fetchJson("/api/whatsapp/status");
  if (!st || st.error) return;
  const card = document.createElement("div");
  card.className = "connector-category-card whatsapp-card";
  const row = document.createElement("div");
  row.className = "connector-row " + (st.enabled ? "enabled" : "disabled");
  let state, actions = "";
  if (!st.enabled) state = '<span class="cstate soon">Bientôt</span>';
  else if (st.linked) {
    state = `<span class="cstate on">Lié — ${escapeHtml(st.phone)}</span>`;
    actions = '<button type="button" class="connector-link-btn" data-wa-unlink>Délier</button>';
  } else {
    state = '<span class="cstate off">Non lié</span>';
    actions = '<button type="button" class="connector-primary-btn wa-btn" data-wa-link>Lier mon WhatsApp</button>';
  }
  row.innerHTML = `<div class="connector-logo-slot"><span class="wa-logo"><svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path fill="#fff" d="M12 2a10 10 0 0 0-8.5 15.2L2 22l4.9-1.5A10 10 0 1 0 12 2zm5.8 14.2c-.2.7-1.4 1.3-2 1.3-.5.1-1.2.1-3.7-.9-3.1-1.3-5.1-4.4-5.3-4.6-.1-.2-1.3-1.7-1.3-3.2s.8-2.3 1.1-2.6c.3-.3.6-.4.8-.4h.6c.2 0 .5-.1.7.5l1 2.4c.1.2.1.4 0 .6l-.4.6-.5.6c-.2.2-.3.4-.1.7.2.3.9 1.5 2 2.4 1.4 1.2 2.5 1.6 2.9 1.8.3.1.5.1.7-.1l1-1.2c.2-.3.4-.2.7-.1l2.2 1.1c.3.1.5.2.6.3.1.2.1.8-.1 1.5z"/></svg></span></div>
    <div class="connector-main"><div class="connector-name">WhatsApp</div>${state}
    <div class="wa-help">Parlez à Chloé directement depuis WhatsApp : mêmes Workers, mêmes crédits.</div></div>
    <div class="connector-actions">${actions}</div>`;
  card.innerHTML = '<div class="connector-category-title">Messagerie — parler à Chloé depuis votre téléphone</div>';
  card.appendChild(row);
  gridEl.prepend(card);
  const linkBtn = row.querySelector("[data-wa-link]");
  if (linkBtn) linkBtn.addEventListener("click", async () => {
    linkBtn.disabled = true;
    const r = await fetchJson("/api/whatsapp/link-code", { method: "POST" });
    linkBtn.disabled = false;
    if (r.error || !r.code) { showToast("WhatsApp n'est pas disponible pour le moment.", false); return; }
    const text = encodeURIComponent("LIER " + r.code);
    const url = "https://wa.me/" + r.number + "?text=" + text;
    const box = document.createElement("div");
    box.className = "wa-link-box";
    box.innerHTML = `<p>1. Cliquez ci-dessous : WhatsApp s'ouvre avec le message prêt.<br>2. Appuyez sur « Envoyer ». C'est tout.</p>
      <a class="btn btn-gold wa-open" href="${url}" target="_blank" rel="noopener">Ouvrir WhatsApp</a>
      <p class="wa-code">Ou envoyez manuellement <strong>LIER ${r.code}</strong> au +${r.number} (valable 15 min).</p>`;
    row.appendChild(box);
    linkBtn.hidden = true;
    const poll = setInterval(async () => {
      const s2 = await fetchJson("/api/whatsapp/status");
      if (s2 && s2.linked) { clearInterval(poll); showToast("WhatsApp lié ✓", true); loadConnectors(); }
    }, 3000);
    setTimeout(() => clearInterval(poll), 15 * 60 * 1000);
  });
  const unBtn = row.querySelector("[data-wa-unlink]");
  if (unBtn) unBtn.addEventListener("click", async () => {
    if (!confirm("Délier ce numéro WhatsApp ?")) return;
    await fetchJson("/api/whatsapp/unlink", { method: "POST" });
    loadConnectors();
  });
}


// ---------- Demo animee : scenario joue dans la page (aucun fichier video) ----------
// Scenario illustratif et etiquete comme tel : ne pretend pas etre un vrai client.
(function initTour() {
  const modal = document.getElementById("tour-modal");
  if (!modal) return;
  const stage = document.getElementById("tour-stage");
  const fill = document.getElementById("tour-progress-fill");
  let run = 0;

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const add = (html, cls) => {
    const el = document.createElement("div");
    el.className = cls;
    el.innerHTML = html;
    stage.appendChild(el);
    stage.scrollTop = stage.scrollHeight;
    return el;
  };
  const pickTeam = () => {
    const cats = ["Ventes & Prospection", "Contenu & Réseaux sociaux", "Marketing & Growth"];
    const team = cats.map((c) => allWorkers.find((w) => w.category === c)).filter(Boolean);
    return team.length >= 2 ? team : allWorkers.slice(0, 3);
  };

  async function play() {
    const my = ++run;
    const alive = () => my === run && !modal.hidden;
    stage.innerHTML = "";
    fill.style.width = "0";
    const bar = (p) => { if (alive()) fill.style.width = p + "%"; };
    const team = pickTeam();
    const steps = [
      [team[0], "prépare la séquence d'emails"],
      [team[1] || team[0], "rédige les textes et visuels"],
      [team[2] || team[0], "cadre le calendrier de lancement"],
    ];

    bar(4); await sleep(500); if (!alive()) return;
    const u = add("", "tour-msg user");
    const text = window.bkTr ? window.bkTr("Prépare une campagne d'emails pour le lancement de ma boutique en ligne.") : "Prépare une campagne d'emails pour le lancement de ma boutique en ligne.";
    for (let i = 1; i <= text.length; i++) { if (!alive()) return; u.textContent = text.slice(0, i); await sleep(22); }
    bar(18); await sleep(700); if (!alive()) return;

    add("Compris ! Je compose l'équipe adaptée à votre demande…", "tour-msg bot");
    bar(28); await sleep(900); if (!alive()) return;
    const teamEl = add("", "tour-team");
    for (const w of team) {
      const chip = document.createElement("div");
      chip.className = "tour-worker";
      chip.innerHTML = `<img src="${w.portraitUrl}" alt=""><span>${escapeHtml(w.name)}<small>${escapeHtml(w.category)}</small></span>`;
      teamEl.appendChild(chip);
      await sleep(450); if (!alive()) return;
    }
    bar(45); await sleep(600); if (!alive()) return;

    const stepsEl = add("", "tour-steps");
    const rows = steps.map(([w, label]) => {
      const r = document.createElement("div");
      r.className = "tour-step";
      r.innerHTML = `<span class="dot"></span><span><b>${escapeHtml(w.name)}</b> ${escapeHtml(label)}…</span>`;
      stepsEl.appendChild(r);
      return r;
    });
    for (let i = 0; i < rows.length; i++) {
      await sleep(1100); if (!alive()) return;
      rows[i].classList.add("done");
      bar(50 + (i + 1) * 12);
    }
    await sleep(600); if (!alive()) return;

    add(`<b>Séquence de lancement — 3 emails prêts</b>1. « Notre boutique ouvre : votre invitation » (J-3)<br>2. « C'est ouvert — offre de bienvenue » (J0)<br>3. « Dernière chance : 48 h » (J+2)
      <div class="tour-approve" id="tour-approve"><span>🔒 L'envoi réel attend <b>votre validation</b></span><button type="button" id="tour-approve-btn">Valider l'envoi</button></div>`, "tour-card");
    bar(90); await sleep(1800); if (!alive()) return;
    const btn = document.getElementById("tour-approve-btn");
    if (btn) { btn.classList.add("pressed"); await sleep(250); if (!alive()) return; btn.classList.remove("pressed"); btn.textContent = "Validé ✓"; document.getElementById("tour-approve").classList.add("ok"); }
    await sleep(700); if (!alive()) return;
    add("Terminé. Rien n'est envoyé sans votre accord — vous gardez le contrôle.", "tour-msg bot");
    bar(100);
  }

  const open = () => { modal.hidden = false; play(); };
  const close = () => { modal.hidden = true; run++; };
  document.querySelectorAll("[data-open-tour]").forEach((b) => b.addEventListener("click", open));
  document.getElementById("tour-close").addEventListener("click", close);
  document.getElementById("tour-replay").addEventListener("click", play);
  document.getElementById("tour-cta").addEventListener("click", () => { close(); requireAccount(() => showView("onboarding")); });
  modal.addEventListener("click", (e) => { if (e.target === modal) close(); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !modal.hidden) close(); });
})();


// ---------- Mot de passe oublie / reinitialisation ----------
(function initPasswordReset() {
  const panels = ["signup", "login", "forgot"];
  const showPanel = (name) => {
    panels.forEach((p) => { document.getElementById("account-panel-" + p).hidden = p !== name; });
    document.querySelector(".account-modal-tabs").hidden = name === "forgot";
  };
  document.getElementById("account-forgot-link").addEventListener("click", () => {
    document.getElementById("account-forgot-email").value = document.getElementById("account-login-email").value;
    document.getElementById("account-forgot-msg").hidden = true;
    showPanel("forgot");
  });
  document.getElementById("account-forgot-back").addEventListener("click", () => { showPanel("login"); });
  // toute reouverture de la modale repart sur les onglets normaux
  const origShowTab = showAccountTab;
  showAccountTab = function (tab) { document.querySelector(".account-modal-tabs").hidden = false; document.getElementById("account-panel-forgot").hidden = true; origShowTab(tab); };
  document.getElementById("account-forgot-send").addEventListener("click", async () => {
    const msg = document.getElementById("account-forgot-msg");
    const btn = document.getElementById("account-forgot-send");
    btn.disabled = true;
    await fetchJson("/api/account/forgot", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email: document.getElementById("account-forgot-email").value.trim() }) });
    btn.disabled = false;
    msg.className = "task-error ok";
    msg.textContent = "Si un compte existe pour cet email, un lien vient d'être envoyé (pensez à vérifier vos spams).";
    msg.hidden = false;
  });

  // lien recu par email : /?reset=TOKEN
  const params = new URLSearchParams(location.search);
  const token = params.get("reset");
  if (!token) return;
  history.replaceState(null, "", location.pathname);
  const modal = document.getElementById("reset-modal");
  const err = document.getElementById("reset-error");
  modal.hidden = false;
  document.getElementById("reset-cancel").addEventListener("click", () => { modal.hidden = true; });
  document.getElementById("reset-submit").addEventListener("click", async () => {
    err.hidden = true;
    const p1 = document.getElementById("reset-password").value, p2 = document.getElementById("reset-password2").value;
    if (p1.length < 8) { err.textContent = "Au moins 8 caractères."; err.hidden = false; return; }
    if (p1 !== p2) { err.textContent = "Les deux mots de passe ne correspondent pas."; err.hidden = false; return; }
    const r = await fetchJson("/api/account/reset", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ token, password: p1 }) });
    if (r.ok) {
      modal.hidden = true;
      showToast("Mot de passe modifié — connectez-vous avec le nouveau.", true);
      requireAccount(() => {});
      showAccountTab("login");
    } else {
      err.textContent = r.error === "RESET_LINK_INVALID" ? "Ce lien a expiré ou a déjà été utilisé. Refaites une demande." : "Impossible de modifier le mot de passe (" + (r.error || "erreur") + ").";
      err.hidden = false;
    }
  });
})();

// ---------- Mes donnees : export + suppression ----------
(function initAccountData() {
  const section = document.getElementById("account-data-section");
  if (!section) return;
  const msg = document.getElementById("account-data-msg");
  const say = (text, ok) => { msg.className = "task-error" + (ok ? " ok" : ""); msg.textContent = text; msg.hidden = false; };
  document.getElementById("account-export-btn").addEventListener("click", async () => {
    msg.hidden = true;
    const res = await fetch("/api/account/export", { method: "POST" });
    if (!res.ok) { say("Export impossible pour le moment.", false); return; }
    const blob = await res.blob();
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "bk-ai-workers-mes-donnees.json";
    document.body.appendChild(a); a.click(); a.remove();
    say("Export téléchargé.", true);
  });
  document.getElementById("account-delete-btn").addEventListener("click", async () => {
    msg.hidden = true;
    const pw = prompt("Suppression DÉFINITIVE de votre compte, de vos missions et de vos connexions.\nEntrez votre mot de passe pour confirmer :");
    if (!pw) return;
    const r = await fetchJson("/api/account/delete", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ password: pw }) });
    if (r.ok) { location.href = "/"; return; }
    const texts = {
      INVALID_PASSWORD: "Mot de passe incorrect.",
      ACTIVE_SUBSCRIPTION: "Résiliez d'abord votre abonnement (section Plans ci-dessus), puis supprimez votre compte.",
      TOO_MANY_ATTEMPTS: "Trop de tentatives. Réessayez plus tard.",
    };
    say(texts[r.error] || "Suppression impossible (" + (r.error || "erreur") + ").", false);
  });
})();


// ---------- Temoignages : affichage public + gestion par le proprietaire ----------
async function loadTestimonials() {
  const section = document.getElementById("testimonials-section");
  if (!section) return;
  const data = await fetchJson("/api/testimonials");
  const list = (data && data.testimonials) || [];
  if (!list.length) { section.hidden = true; return; }
  document.getElementById("testimonials-grid").innerHTML = list.map((t) => {
    const stars = t.rating ? `<div class="testimonial-stars" aria-label="${t.rating} / 5">${"★".repeat(t.rating)}${"☆".repeat(5 - t.rating)}</div>` : "";
    const who = [t.role, t.company].filter(Boolean).map(escapeHtml).join(" · ");
    return `<figure class="testimonial-card" style="margin:0">${stars}<blockquote class="testimonial-text" style="margin:0">“${escapeHtml(t.text)}”</blockquote>
      <figcaption class="testimonial-who" data-no-i18n="1"><strong>${escapeHtml(t.name)}</strong>${who}</figcaption></figure>`;
  }).join("");
  section.hidden = false;
}

async function loadAdminTestimonials() {
  const listEl = document.getElementById("admin-testimonials-list");
  if (!listEl) return;
  const data = await fetchJson("/api/testimonials");
  const rows = (data && data.testimonials) || [];
  listEl.innerHTML = rows.length
    ? rows.map((t) => `<div class="tsm-row"><span><strong>${escapeHtml(t.name)}</strong> — ${escapeHtml(t.text.slice(0, 120))}</span><button type="button" class="btn-small" data-del-tsm="${escapeHtml(t.id)}">Supprimer</button></div>`).join("")
    : "";
  listEl.querySelectorAll("[data-del-tsm]").forEach((b) => b.addEventListener("click", async () => {
    if (!confirm("Supprimer ce témoignage ?")) return;
    await fetchJson("/api/admin/testimonials/delete", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id: b.dataset.delTsm }) });
    loadAdminTestimonials(); loadTestimonials();
  }));
}

(function initTestimonialForm() {
  const form = document.getElementById("testimonial-form");
  if (!form) return;
  const msg = document.getElementById("tsm-msg");
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    msg.hidden = true;
    const r = await fetchJson("/api/admin/testimonials", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({
      name: document.getElementById("tsm-name").value, role: document.getElementById("tsm-role").value, company: document.getElementById("tsm-company").value,
      rating: document.getElementById("tsm-rating").value, text: document.getElementById("tsm-text").value, consent: document.getElementById("tsm-consent").checked,
    }) });
    if (r.ok) { form.reset(); loadAdminTestimonials(); loadTestimonials(); msg.className = "task-error ok"; msg.textContent = "Publié."; msg.hidden = false; return; }
    const T = { NAME_REQUIRED: "Indiquez le nom.", TEXT_LENGTH: "Le témoignage doit faire entre 20 et 600 caractères.", CONSENT_REQUIRED: "Cochez la case : il faut l'accord de la personne." };
    msg.className = "task-error"; msg.textContent = T[r.error] || "Impossible de publier."; msg.hidden = false;
  });
})();
loadTestimonials();


// ---------- Verification de l'email ----------
(function initEmailVerification() {
  const btn = document.getElementById("verify-resend-btn");
  if (btn) btn.addEventListener("click", async () => {
    btn.disabled = true;
    const r = await fetchJson("/api/account/resend-verification", { method: "POST" });
    btn.disabled = false;
    showToast(r && r.ok ? (r.alreadyVerified ? "Votre email est déjà confirmé." : "Email renvoyé — pensez à vérifier vos spams.") : "Trop de demandes : réessayez dans un moment.", !!(r && r.ok));
  });
  const p = new URLSearchParams(location.search);
  if (p.has("verified")) {
    const ok = p.get("verified") === "1";
    history.replaceState(null, "", location.pathname);
    setTimeout(() => showToast(ok ? "Email confirmé ✓ — vous pouvez maintenant souscrire un plan." : "Ce lien de confirmation a expiré ou a déjà été utilisé.", ok), 600);
  }
})();

// App installable (2026-09-30) : icone sur l'ecran d'accueil, ouverture en
// plein ecran sans barre de navigateur, resilience hors-ligne partielle.
// Reseau-d'abord dans le service worker (voir service-worker.js) : jamais
// de JS perime servi silencieusement, meme incident deja vecu sur ce
// projet avec le cache navigateur seul.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/service-worker.js", { scope: "/" }).catch(() => {});
  });
}
