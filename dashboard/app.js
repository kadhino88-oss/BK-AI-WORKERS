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
  // Topbar etroit (style.css, "TOPBAR ETROIT") : connecte, le libelle long ne
  // tient pas a cote du hamburger — le CSS le remplace par une pastille icone
  // selon cet etat. Le libelle complet (mode client/proprietaire compris)
  // reste dans le DOM et en infobulle.
  btn.dataset.state = !accountAuthenticated ? "out" : isOperator ? "owner" : "client";
  if (accountAuthenticated) btn.title = btn.textContent;
  else btn.removeAttribute("title");
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
  // Une fiche de Worker deja ouverte propose maintenant « Installer » ou « Embaucher » selon le compte qui vient de se connecter.
  if (!profileView.hidden && currentWorkerId) loadInstallPanel(currentWorkerId);
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
      errorEl.textContent = result.error === "WORKER_NOT_INCLUDED" && result.detail
        ? result.detail
        : "Chloé n'a identifié aucun Worker pour cette demande. Essaie de reformuler ton objectif.";
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
    resultEl.innerHTML = `<div class="status-line">${statusLine}</div>${renderAnswer(result.error === "WORKER_NOT_INCLUDED" && result.detail ? result.detail : (result.FinalSynthesis || "Aucune synthèse disponible."))}`;

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
  loadAdminEngine();
  loadAdminActivity();
  clearInterval(adminActivityTimer);
  adminActivityTimer = setInterval(() => { if (!adminView.hidden) loadAdminActivity(); }, 30000);
  const data = await fetchJson("/api/admin/overview");
  if (data.error) return;
  adminClientsCache = data.clients || [];
  renderAdminHireRequests(data.hireRequests);         // demandes d'embauche de Workers (message du client : echappe a l'affichage)

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
    const hiredLine = c.workerSlots ? ` · Workers ${(c.hiredWorkers || []).length}/${c.workerSlots} : ${(c.hiredWorkers || []).map((w) => escapeHtml(workerNameById(w))).join(", ") || "aucun"}` : "";
    row.innerHTML = `
      <div class="admin-client-row-head">
        <div>
          <div class="admin-client-name">${escapeHtml(c.label)}${c.isOwner ? " · propriétaire" : ""}</div>
          <div class="admin-client-meta">${escapeHtml(c.email || "—")} · ${escapeHtml(c.clientId)} · inscrit le ${signup} · plan ${escapeHtml(c.planName)}${hiredLine}</div>
        </div>
        <div class="admin-client-stats">
          <div><strong>${c.totalMissions}</strong><span>Missions</span></div>
          <div><strong>${c.automationsActive}</strong><span>Automatisations</span></div>
          <div><strong>${creditsLabel}</strong><span>Crédits</span></div>
        </div>
      </div>
      <div class="admin-client-tools" hidden>${c.isOwner ? "" : '<button type="button" class="btn-small iw-grant-open">Attribuer des Workers (Solo / Trio)</button>'}</div>
      <div class="admin-client-detail" hidden></div>
    `;
    const head = row.querySelector(".admin-client-row-head");
    const detail = row.querySelector(".admin-client-detail");
    const tools = row.querySelector(".admin-client-tools");
    const grantBtn = row.querySelector(".iw-grant-open");
    if (grantBtn) grantBtn.addEventListener("click", () => openGrantForm(c.clientId, c.email || c.label || c.clientId, null));
    const toggle = async () => {
      const opening = detail.hidden;
      detail.hidden = !opening;
      tools.hidden = !opening;
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

// Les prix (CHF) viennent du serveur : chaque forfait de /api/billing (availablePlans) porte son priceChf, tire de PLAN_CATALOG (server.py) — il
// n'y a plus de liste de prix en dur ici. Quota MENSUEL fixe : jamais illimite, pas de recharge ; quand il est atteint, on passe au forfait
// suivant (data.upgrade.next). Enterprise est sur devis (plafond de credits fixe par contrat) : on nous ecrit.
const BK_CONTACT_EMAIL = "contact@bk-entreprise.com";

let billingInterval = "month";

function billingDate(iso) {
  const d = new Date(iso);
  return isNaN(d) ? "" : d.toLocaleDateString(BK_LOCALE(), { day: "numeric", month: "long", year: "numeric" });
}

// Bouton « Passer a la formule superieure » : le forfait suivant par POST /api/billing/plan (Stripe Checkout quand Stripe est configure,
// aucun prelevement avant le paiement sur la page Stripe) ; Enterprise / plafond contractuel : un e-mail pre-rempli.
function startUpgrade(up) {
  const nxt = up && up.next;
  if (!nxt || nxt.onQuote) {
    const subject = encodeURIComponent(nxt ? `${nxt.name} — plafond de crédits` : "Relever mon plafond de crédits");
    window.location.href = `mailto:${(up && up.contactEmail) || BK_CONTACT_EMAIL}?subject=${subject}`;
    return;
  }
  // Le client paie au meme rythme que son abonnement (mensuel ou annuel, donne par le serveur) : un abonne annuel ne se voit pas proposer un
  // forfait mensuel qui annulerait ses mois deja payes.
  switchBillingPlan(nxt.planId, (up && up.interval) || billingInterval);
}

function upgradeNextHtml(up) {
  const nxt = up && up.next;
  if (!nxt) return "Votre plafond de crédits est fixé par votre contrat : écrivez-nous pour le relever.";
  if (nxt.onQuote) return `<span>Prochaine formule :</span> <strong>${escapeHtml(nxt.name)}</strong> — <span>sur devis (plafond de crédits fixé par contrat)</span>`;
  const yearly = up.interval === "year";
  const price = nxt.priceChf ? ` <strong>${formatPrice(yearly ? nxt.priceChf.year : nxt.priceChf.month)}</strong>${yearly ? "/an" : "/mois"}` : "";
  return `<span>Prochaine formule :</span> <strong>${escapeHtml(nxt.name)}</strong> — <strong>${Number(nxt.credits).toLocaleString(BK_LOCALE())}</strong> <span>crédits par mois</span>,${price}`;
}

// Boutons affiches sous un message « quota atteint » (402 SUBSCRIPTION_REQUIRED) : le forfait suivant avec son prix, ou « nous ecrire »,
// plus le lien vers tous les forfaits. Sans information de montee en gamme (ancien serveur) : l'ancien bouton « Voir les abonnements ».
function subscribeCtaHtml(result) {
  const up = result && result.upgrade;
  if (!up) return `<button type="button" class="btn btn-gold subscribe-cta-btn" style="margin-top:10px">Voir les abonnements &rarr;</button>`;
  const nxt = up.next;
  const main = !nxt
    ? `<button type="button" class="btn btn-gold subscribe-upgrade-btn">Relever mon plafond</button>`
    : nxt.onQuote
      ? `<button type="button" class="btn btn-gold subscribe-upgrade-btn">Passer à <strong>${escapeHtml(nxt.name)}</strong> (sur devis)</button>`
      : `<button type="button" class="btn btn-gold subscribe-upgrade-btn">Passer à <strong>${escapeHtml(nxt.name)}</strong>${nxt.priceChf ? ` (${formatPrice(up.interval === "year" ? nxt.priceChf.year : nxt.priceChf.month)}${up.interval === "year" ? "/an" : "/mois"})` : ""}</button>`;
  return `<div class="subscribe-cta-row" style="margin-top:10px">${main} <button type="button" class="btn btn-ghost subscribe-cta-btn">Voir tous les forfaits</button></div>`;
}

function wireSubscribeCta(root, result, beforeNavigate) {
  const go = () => { if (beforeNavigate) beforeNavigate(); showView("billing"); };
  root.querySelectorAll(".subscribe-cta-btn").forEach((b) => b.addEventListener("click", go));
  root.querySelectorAll(".subscribe-upgrade-btn").forEach((b) => b.addEventListener("click", () => {
    const up = result && result.upgrade;
    if (up && up.next && !up.next.onQuote) go();
    startUpgrade(up);
  }));
}

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
  if (!isOperator) loadEngineCard();
  const vBanner = document.getElementById("verify-email-banner");
  if (vBanner) vBanner.hidden = isOperator || accountEmailVerified;

  // Administrateur/createur : aucun credit, aucun plan, aucune recharge —
  // il n'est pas un client (demande de Kader, 2026-09-25). Le serveur ne
  // le bloque deja jamais (subscription_blocks_mission) ; l'interface
  // ne doit donc plus lui presenter de quota.
  if (isOperator) {
    // La liste « Mes Workers installes » survit au remplacement du contenu : le proprietaire peut aussi installer et mettre en pause.
    const installedSection = document.getElementById("installed-workers-section");
    document.getElementById("billing-content").innerHTML = `
      <div class="billing-current-card">
        <div class="billing-current-label">Compte</div>
        <div class="billing-current-plan">Administrateur — accès illimité</div>
        <p class="hero-sub" style="margin:10px 0 0;text-align:left">Aucun crédit, aucun plan : tes missions ne sont jamais limitées. Le suivi des clients (inscriptions, connexions, abonnements, missions) est dans l'onglet <strong>Admin</strong>.</p>
      </div>`;
    if (installedSection) document.getElementById("billing-content").appendChild(installedSection);
    loadInstalledWorkers();
    return;
  }
  loadInstalledWorkers();

  document.getElementById("billing-plan-name").textContent = data.planName;

  const fill = document.getElementById("billing-usage-fill");
  const pct = Math.min(100, data.percentUsed || 0);
  fill.style.width = pct + "%";
  fill.classList.toggle("alert", !!data.alertThresholdReached);

  // Credits utilises / inclus ce mois-ci + date de renouvellement (quota mensuel fixe ; l'essai ne se renouvelle pas).
  const line = document.getElementById("billing-usage-line");
  const nf = (n) => Number(n).toLocaleString(BK_LOCALE());
  const renews = data.cancelAtPeriodEnd && data.paidUntilUtc ? ` — résilié : le forfait reste actif jusqu'au ${billingDate(data.paidUntilUtc)}, sans renouvellement.`
    : (data.awaitingInvoice && data.paidUntilUtc ? ` — valable jusqu'au ${billingDate(data.paidUntilUtc)} ; reconduit à la réception du règlement de la facture suivante.`
      : (data.renewsAtUtc ? ` — renouvelé le ${billingDate(data.renewsAtUtc)}.` : (data.planId === "essai" ? " — l'essai ne se renouvelle pas." : ".")));
  line.textContent = `${nf(data.creditsUsed)} / ${nf(data.creditsTotal)} crédits consommés (${nf(data.creditsRemaining)} restants)${renews}`;

  document.getElementById("billing-alert").hidden = !data.alertThresholdReached;

  // Des 80 % du quota : bouton « Passer a la formule superieure » (aucune montee en gamme automatique, aucun prelevement surprise).
  const upBox = document.getElementById("billing-upgrade");
  if (upBox) {
    upBox.hidden = !(data.upgradeSuggested && data.upgrade);
    if (!upBox.hidden) {
      document.getElementById("billing-upgrade-text").innerHTML = upgradeNextHtml(data.upgrade);
      const upBtn = document.getElementById("billing-upgrade-btn");
      upBtn.textContent = data.upgrade.next ? "Passer à la formule supérieure" : "Relever mon plafond";
      upBtn.onclick = () => startUpgrade(data.upgrade);
    }
  }

  // Forfait Solo / Trio : les Workers choisis et les emplacements restants.
  const hireBox = document.getElementById("billing-hire");
  if (hireBox) {
    const h = data.hire;
    hireBox.hidden = !(h && h.restricted);
    if (!hireBox.hidden) {
      const names = (h.hiredWorkers || []).map((id) => { const w = allWorkers.find((x) => x.id === id); return escapeHtml(w ? w.name : id); });
      hireBox.innerHTML = `<span>Workers de votre forfait :</span> <strong>${names.length ? names.join(", ") : "aucun pour le moment"}</strong>`
        + (h.slotsLeft > 0 ? ` <span>— il vous reste</span> <strong>${h.slotsLeft}</strong> <span>emplacement(s) : ouvrez la fiche d'un Worker pour l'embaucher.</span>` : "");
    }
  }

  const cancelBtn = document.getElementById("billing-cancel-btn");
  cancelBtn.hidden = data.planId === "essai" || !!data.cancelAtPeriodEnd;        // deja resilie : rien a annuler de plus
  const pendingBox = document.getElementById("billing-pending-payment");
  if (pendingBox) pendingBox.hidden = !pendingCheckoutGet();                    // paiement revenu de Stripe mais pas encore confirme

  const grid = document.getElementById("billing-plans-grid");
  grid.innerHTML = "";
  data.availablePlans.forEach((plan) => {
    const isCurrent = plan.planId === data.planId;
    const card = document.createElement("div");
    card.className = "billing-plan-card" + (isCurrent ? " active" : "");
    const creditsLabel = plan.onQuote
      ? "Plafond de crédits fixé par contrat"
      : `${nf(plan.credits)} crédits / mois`;
    const price = plan.priceChf
      ? `${formatPrice(plan.priceChf[billingInterval])}${billingInterval === "month" ? "/mois" : "/an"}`
      : (plan.onQuote ? "Sur devis" : "");
    const workers = plan.workerSlots
      ? `<div class="billing-plan-credits">${plan.workerSlots === 1 ? "1 Worker de votre choix" : `${plan.workerSlots} Workers de votre choix, Chloé comprise`}</div>`
      : "";
    const label = isCurrent ? "Plan actif" : (plan.onQuote ? "Nous contacter" : "Choisir");
    card.innerHTML = `
      <div class="billing-plan-name">${plan.name}</div>
      ${price ? `<div class="billing-plan-price">${price}</div>` : ""}
      <div class="billing-plan-credits">${creditsLabel}</div>
      ${workers}
      <button type="button" class="btn ${isCurrent ? "btn-ghost" : "btn-gold"}" ${isCurrent ? "disabled" : ""}>
        ${label}
      </button>
    `;
    if (!isCurrent) {
      card.querySelector("button").addEventListener("click", () => {
        if (plan.onQuote) startUpgrade({ next: plan, contactEmail: BK_CONTACT_EMAIL });
        else switchBillingPlan(plan.planId, billingInterval);
      });
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
  if (result.error === "PLAN_BY_INVOICE" || result.error === "PLAN_ON_QUOTE" || result.error === "PLAN_NOT_SOLD" || result.error === "PLAN_NOT_SELECTABLE") {
    alert(result.detail || result.error);       // message francais du serveur : activation sur facture, sur devis, ou forfait plus propose
    return;
  }
  if (result.error) {
    alert("Erreur : " + (result.detail || result.error));
    return;
  }
  await loadBilling();
}

// Paiement Stripe revenu mais pas encore confirme chez nous : l'identifiant de la session reste dans ce navigateur jusqu'a ce que la confirmation
// reussisse (delai du pont, reseau coupe, onglet ferme) ; il est retente a chaque chargement et par le bouton « Verifier mon paiement ».
const PENDING_CHECKOUT_KEY = "bk.pendingCheckoutSession";
// Refus definitifs : retenter ne servirait a rien, on oublie l'identifiant (le message dit pourquoi).
const CHECKOUT_FINAL_ERRORS = ["SUBSCRIPTION_NOT_ACTIVE", "PAYMENT_NOT_CONFIRMED", "INVALID_SESSION_ID", "SESSION_ID_REQUIRED"];

function pendingCheckoutGet() {
  try { return localStorage.getItem(PENDING_CHECKOUT_KEY) || ""; } catch { return ""; }
}

function pendingCheckoutSet(sessionId) {
  try {
    if (sessionId) localStorage.setItem(PENDING_CHECKOUT_KEY, sessionId);
    else localStorage.removeItem(PENDING_CHECKOUT_KEY);
  } catch { /* stockage indisponible : la confirmation reste tentee une fois */ }
}

// Confirme la session aupres du serveur. Renvoie "ok", "retry" (on garde l'identifiant) ou "final" (refus definitif, identifiant oublie).
async function confirmCheckoutSession(sessionId) {
  let result;
  try {
    result = await fetchJson("/api/billing/stripe-confirm", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sessionId }),
    });
  } catch (e) {
    return { state: "retry", detail: e && e.message ? e.message : "connexion impossible" };
  }
  if (!result || !result.error) {
    pendingCheckoutSet("");
    return { state: "ok", result };
  }
  if (CHECKOUT_FINAL_ERRORS.includes(result.error)) {
    pendingCheckoutSet("");
    return { state: "final", detail: result.detail || result.error };
  }
  return { state: "retry", detail: result.detail || result.error };
}

async function handleStripeCheckoutReturn() {
  const params = new URLSearchParams(window.location.search);
  const checkout = params.get("billing_checkout");
  const sessionId = params.get("session_id");
  if (checkout === "success" && sessionId) pendingCheckoutSet(sessionId);       // gardé jusqu'à la confirmation, avant que l'adresse soit nettoyée
  if (checkout) window.history.replaceState({}, "", window.location.pathname);

  if (checkout === "success" && sessionId) {
    showView("billing");
    const outcome = await confirmCheckoutSession(sessionId);
    if (outcome.state === "ok") {
      showToast(iwT("Paiement confirmé : votre forfait est actif."));
    } else if (outcome.state === "final") {
      alert("Le paiement n'a pas pu être confirmé : " + outcome.detail);
    } else {
      alert("Votre paiement est bien parti, mais nous n'avons pas encore pu le confirmer (" + outcome.detail + "). Rien n'est perdu : cliquez sur « Vérifier mon paiement » dans Facturation, ou rechargez la page dans un instant.");
    }
    await loadBilling();
  } else if (checkout === "cancel") {
    showView("billing");
  } else if (!checkout && pendingCheckoutGet()) {
    const outcome = await confirmCheckoutSession(pendingCheckoutGet());       // paiement non confirme lors d'une visite precedente
    if (outcome.state === "ok") showToast(iwT("Paiement confirmé : votre forfait est actif."));
    await loadBilling();
  }
}

async function retryPendingCheckout() {
  const sessionId = pendingCheckoutGet();
  if (!sessionId) return;
  const outcome = await confirmCheckoutSession(sessionId);
  if (outcome.state === "ok") showToast(iwT("Paiement confirmé : votre forfait est actif."));
  else if (outcome.state === "final") alert("Le paiement n'a pas pu être confirmé : " + outcome.detail);
  else alert("Le paiement n'a toujours pas pu être confirmé (" + outcome.detail + "). Réessayez dans un instant ; si cela dure, écrivez-nous en indiquant le montant et la date.");
  await loadBilling();
}

async function cancelBillingPlan() {
  // CGV article 6 : la resiliation prend effet a la fin de la periode en cours ; le forfait paye reste actif jusque-la.
  if (!confirm(iwT("Résilier l'abonnement ? Votre forfait reste actif jusqu'à la fin de la période déjà payée, puis votre compte repasse à l'essai. Aucun nouveau prélèvement."))) return;
  const result = await fetchJson("/api/billing/cancel", { method: "POST" });
  if (result && result.error) {
    alert(result.detail || result.error);        // ex. STRIPE_UNAVAILABLE : rien n'a change, l'abonnement est intact
    return;
  }
  if (result && result.cancelAtPeriodEnd && result.paidUntilUtc) {
    showToast(`${iwT("Résiliation enregistrée : votre forfait reste actif jusqu'au")} ${billingDate(result.paidUntilUtc)}.`);
  }
  await loadBilling();
}

// ---------- AUTOMATISATIONS (missions recurrentes, vrai pipeline) ----------

// Statuts du dernier passage ecrits par le moteur (core/automation/AUTOMATION-ENGINE.ps1) quand la mission n'a pas ete lancee.
const AUTOMATION_STATUS_LABELS = {
  installation_paused: "non lancée : Worker en pause",
  worker_not_included: "non lancée : Worker hors de votre forfait",
  quota_exceeded: "non lancée : quota de crédits atteint",
};

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
    const errorEl = document.getElementById("automation-error");
    errorEl.innerHTML = `${escapeHtml(result.detail || "Votre quota est épuisé. Souscrivez un abonnement pour continuer.")} ${subscribeCtaHtml(result)}`;
    errorEl.hidden = false;
    wireSubscribeCta(errorEl, result);
    return true;
  }
  if (result.error === "WORKER_NOT_INCLUDED") {
    // Offre « Worker a l'unite » : le texte du serveur explique, et le client est conduit vers la fiche du Worker pour l'embaucher.
    showAutomationError(result.detail || "Ce Worker ne fait pas partie de votre forfait.");
    const errorEl = document.getElementById("automation-error");
    if (result.workerId) {
      const go = document.createElement("button");
      go.type = "button";
      go.className = "iw-link";
      go.textContent = "Voir ce Worker pour l'embaucher";
      go.addEventListener("click", () => iwGoHire(result.workerId));
      errorEl.appendChild(document.createTextNode(" "));
      errorEl.appendChild(go);
    }
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
    // Dernier passage non execute parce que le Worker est en pause : la carte le dit (et ne reste pas « Active » en apparence).
    const suspended = a.enabled && a.lastRunStatus === "installation_paused";
    const statusLabel = AUTOMATION_STATUS_LABELS[a.lastRunStatus] || a.lastRunStatus;
    card.innerHTML = `
      <div class="automation-card-main">
        <div class="automation-card-objective">${escapeHtml(workerNameById(a.workerId))} — ${escapeHtml(a.objective)}</div>
        <div class="automation-card-meta">${freqLabel}${slackNote} · dernière exécution : ${lastRun}${a.lastRunStatus ? " · " + escapeHtml(statusLabel) : ""}${a.enabled && a.nextRunAtUtc ? " · prochaine : " + new Date(a.nextRunAtUtc).toLocaleString(BK_LOCALE()) : ""}</div>
      </div>
      <span class="automation-card-status ${a.enabled && !suspended ? "on" : "off"}">${suspended ? "Suspendue (Worker en pause)" : (a.enabled ? "Active" : "En pause")}</span>
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
    errorEl.innerHTML = `${escapeHtml(result.detail || "Votre quota est épuisé.")} ${subscribeCtaHtml(result)}`;
    errorEl.hidden = false;
    wireSubscribeCta(errorEl, result);
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
  // Partie de l'assistant d'installation (etape « Outils ») : on y revient, la fiche brouillon a ete enregistree avant le depart.
  iwResumeAfterOauth();
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
  // L'assistant d'installation ouvert (etape « Outils ») rafraichit alors ce qui est connecte.
  if (typeof onConnectorsReloaded === "function") onConnectorsReloaded();
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

// ---------- TARIFS (grille validee par le proprietaire le 2026-10-12, voir docs/PRICING.md) ----------
//
// MEME liste que PLAN_CATALOG (server.py) et PRICING_PLANS (seo_pages.py) : tests/pricing verifie qu'il n'existe jamais deux listes de prix
// differentes. Chaque forfait est un quota MENSUEL FIXE de credits (jamais illimite ; Enterprise a un plafond fixe par contrat). Starter et
// Business sont des forfaits HERITES (plus vendus) : ils n'apparaissent plus ici ni dans le choix de forfait. Aucun paquet de credits,
// aucun forfait illimite. Rien n'est annonce qui ne soit construit : pas de telephone ni de WhatsApp pour les clients de nos clients.

const PRICING_PLANS = [
  {
    id: "essai",
    name: "Essai",
    audience: "Pour tester sans risque",
    price: "0",
    period: "3 jours",
    credits: 15,
    creditsLabel: "crédits d'essai",
    features: [
      "Niveau Rapide uniquement",
      "Essayez plusieurs Workers",
      "Aucune carte bancaire",
    ],
  },
  {
    id: "solo",
    name: "Solo",
    audience: "Choisissez le Worker de votre activité",
    price: "29",
    annual: "290",
    period: "/mois",
    credits: 250,
    cta: "Trouver mon Worker",
    features: [
      "1 Worker de votre choix",
      "Configuré selon votre activité",
      "Chaque action vers l'extérieur validée par vous",
      "Changement de Worker possible tous les 30 jours",
    ],
  },
  {
    id: "trio",
    name: "Trio",
    audience: "Vous choisissez 3 Workers, Chloé comprise",
    price: "59",
    annual: "590",
    period: "/mois",
    credits: 500,
    features: [
      "3 Workers de votre choix",
      "Chloé, l'orchestratrice, incluse",
      "Missions avec plusieurs Workers",
      "Configuré selon votre activité",
    ],
  },
  {
    id: "equipe",
    name: "Équipe",
    audience: "PME : toute l'équipe",
    price: "99",
    annual: "990",
    period: "/mois",
    popular: true,
    credits: 900,
    features: [
      "Chloé et les 17 Workers",
      "Missions multi-agents",
      "Automatisations",
      "Chaque action vers l'extérieur validée par vous",
    ],
  },
  {
    id: "pro",
    name: "Pro",
    audience: "Entreprises, usage régulier",
    price: "139",
    annual: "1390",
    period: "/mois",
    credits: 1250,
    features: [
      "Tout Équipe, avec 39 % de crédits en plus",
      "Équipes avancées",
      "Missions complexes",
      "Analytics & contrôles avancés",
    ],
  },
  {
    id: "scale",
    name: "Scale",
    audience: "Entreprises, volume important",
    price: "449",
    annual: "4490",
    period: "/mois",
    credits: 4000,
    features: [
      "Tout Pro",
      "Capacité supérieure",
      "Équipes multiples",
      "Gouvernance avancée",
      "Accompagnement renforcé",
    ],
  },
  {
    id: "enterprise",
    name: "Enterprise",
    audience: "Grands comptes, besoins spécifiques",
    price: null,
    period: "Sur devis",
    credits: null,
    creditsLabel: "Plafond de crédits mensuel fixé par contrat",
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
    card.dataset.planId = plan.id;

    const priceHtml = plan.price === null
      ? `<div class="plan-price-row"><span class="plan-price">Sur devis</span></div>`
      : `<div class="plan-price-row"><span class="plan-price">${formatPrice(plan.price)}</span><span class="plan-price-period">${plan.period}</span></div>`;

    const strikeHtml = plan.annual
      ? `<div class="plan-price-strike">ou ${formatPrice(plan.annual)}/an — 2 mois offerts</div>`
      : "";

    // Quota de credits : un nombre fixe par mois (jamais "illimite"). Les chiffres sont dans leur propre balise : le texte autour se traduit.
    const creditsHtml = plan.credits !== null
      ? `<div class="plan-credits"><strong>${plan.credits.toLocaleString(BK_LOCALE())}</strong> ${plan.creditsLabel || "crédits par mois"}</div>`
      : `<div class="plan-credits">${plan.creditsLabel}</div>`;

    const featuresHtml = plan.features.map((f) => `<li>${f}</li>`).join("");
    const ctaLabel = plan.cta || (plan.price === null ? "Nous contacter" : "Discuter avec Chloé");

    card.innerHTML = `
      ${plan.popular ? '<div class="plan-badge">Recommandé pour une PME</div>' : ""}
      <div class="plan-name">${plan.name}</div>
      <div class="plan-audience">${plan.audience}</div>
      ${priceHtml}
      ${strikeHtml}
      ${creditsHtml}
      <ul class="plan-features">${featuresHtml}</ul>
      <button type="button" class="plan-cta">${ctaLabel}</button>
    `;

    // Solo : « Choisissez le Worker de votre activite » -> l'aide « Quel Worker pour mon activite ? » juste en dessous.
    card.querySelector(".plan-cta").addEventListener("click", plan.id === "solo" ? scrollToActivityHelper : openChloeFab);

    grid.appendChild(card);
  });

  renderPricingScale();
  renderActivityHelper();
}

// Echelle de credits (core/ai/LEVELS.json via /api/mission-levels) : « combien de missions pour mes credits ? ». Si les niveaux sont coupes
// sur le serveur (BK_LEVELS=0), la liste est vide et on affiche l'ancienne regle : une mission = un credit.
async function renderPricingScale() {
  const box = document.getElementById("pricing-scale");
  if (!box) return;
  let levels = [];
  // ?scale=public : l'echelle complete (Rapide, Equilibre, Approfondi), la meme pour tous. Sans cela un visiteur connecte a l'essai (verrouille sur
  // Rapide) ne voyait que « 250 missions Rapide » pour Solo, alors que le niveau par defaut de Solo coute 6 credits.
  try { levels = ((await fetchJson("/api/mission-levels?scale=public")).levels || []).filter((l) => Number(l.credits) > 0); } catch (e) { /* page statique : texte generique */ }
  const noRecharge = "Chaque forfait est un quota mensuel fixe, renouvelé chaque mois : il n'y a ni missions illimitées, ni recharge de crédits, ni paiement à l'usage. Quand le quota est atteint, vous passez au forfait supérieur, qui a son propre quota.";
  if (!levels.length) {
    box.innerHTML = `<h2>Combien de missions pour mes crédits ?</h2><p>Une mission réellement traitée consomme un crédit.</p><p>${noRecharge}</p>`;
    return;
  }
  const base = levels.reduce((a, b) => (b.credits < a.credits ? b : a));
  const rows = levels.map((l) => `<li><strong>${escapeHtml(l.label)}</strong> — <span class="scale-cost">${l.credits}</span> ${l.credits > 1 ? "crédits" : "crédit"} par mission</li>`).join("");
  box.innerHTML = `
    <h2>Combien de missions pour mes crédits ?</h2>
    <p>Un crédit n'est pas une mission : le coût dépend du niveau de travail que vous choisissez.</p>
    <ul class="pricing-scale-list">${rows}</ul>
    <p>Exemple avec <strong>250</strong> crédits (Solo) : ${levels.map((l) => `<strong>${Math.floor(250 / l.credits)}</strong> missions <em>${escapeHtml(l.label)}</em>`).join(", ou ")}.</p>
    <p>Les missions récurrentes (automatisations) tournent toujours au niveau le plus rapide : <strong>${base.credits}</strong> ${base.credits > 1 ? "crédits" : "crédit"} chacune.</p>
    <p>${noRecharge}</p>`;
}

// ---------- « QUEL WORKER POUR MON ACTIVITE ? » (page Tarifs) ----------
// Donnees statiques. Chaque correspondance vient du role et des competences REELS du Worker : workers/<id>/identity/identity.json et sa fiche
// d'installation workers/<id>/install-profile.json (idealFor, services) — rien d'invente, aucun temoignage, aucun chiffre. Le premier Worker
// de la liste est le plus proche de l'activite ; chaque resultat ouvre la fiche du Worker (c'est la que se trouve « Embaucher » / l'installation).
const ACTIVITY_WORKERS = [
  { id: "boutique", label: "Boutique en ligne", workers: [
    { id: "thomas", why: "Fiches produit, marge par canal frais inclus, mise en vente sur une marketplace" },
    { id: "nora", why: "Répond à vos clients et trie les demandes et réclamations" },
    { id: "maya", why: "Plan média chiffré, annonces et emails de campagne pour attirer des clients" },
  ] },
  { id: "commerce", label: "Restaurant ou commerce local", workers: [
    { id: "seoya", why: "Être trouvé sur Google : articles et pages optimisés écrits en entier" },
    { id: "emma", why: "Posts pour vos réseaux sociaux, écrits en entier, et calendrier éditorial" },
    { id: "lea", why: "Charte graphique, logo et visuels en fichiers utilisables tout de suite" },
  ] },
  { id: "cabinet", label: "Cabinet ou profession libérale", workers: [
    { id: "noah", why: "Emails prêts à envoyer, agenda, comptes-rendus de réunion" },
    { id: "clara", why: "Contrats, NDA et CGV rédigés en entier, à faire valider par un avocat" },
    { id: "dario", why: "Budget, trésorerie et documents préparés pour la fiduciaire" },
  ] },
  { id: "agence", label: "Agence ou freelance", workers: [
    { id: "alex", why: "Prospection : prospects réels, séquences de messages, relances et préparation de rendez-vous" },
    { id: "yanis", why: "Plan daté, répartition des rôles et suivi honnête de vos projets" },
    { id: "noah", why: "Emails, agenda et comptes-rendus pris en charge" },
  ] },
  { id: "pme", label: "PME de services", workers: [
    { id: "alex", why: "Un flux de rendez-vous qualifiés pour les services et le conseil" },
    { id: "dario", why: "Budget, trésorerie, prix de vente et marges" },
    { id: "sophie", why: "Annonces, tri des candidatures et entretiens structurés si vous recrutez" },
  ] },
  { id: "artisan", label: "Artisan", workers: [
    { id: "alex", why: "Si vous vendez à des entreprises : prospects réels et relances" },
    { id: "dario", why: "Prix de vente, marge et point mort" },
    { id: "seoya", why: "Être trouvé sur Google : commerces locaux et prestataires de services" },
  ] },
  { id: "association", label: "Association", workers: [
    { id: "noah", why: "Ordres du jour, comptes-rendus avec actions assignées, courriers" },
    { id: "yanis", why: "Plan daté et suivi pour un événement ou un projet" },
  ] },
];

function scrollToActivityHelper() {
  const el = document.getElementById("activity-helper");
  if (el) el.scrollIntoView({ behavior: "smooth", block: "start" });
}

function renderActivityHelper() {
  const chips = document.getElementById("activity-chips");
  const result = document.getElementById("activity-result");
  if (!chips || !result) return;
  chips.innerHTML = "";
  result.innerHTML = "";
  ACTIVITY_WORKERS.forEach((a) => {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = "activity-chip";
    chip.textContent = a.label;
    chip.setAttribute("aria-pressed", "false");
    chip.addEventListener("click", () => {
      chips.querySelectorAll(".activity-chip").forEach((c) => { const on = c === chip; c.classList.toggle("active", on); c.setAttribute("aria-pressed", String(on)); });
      showActivityWorkers(a);
    });
    chips.appendChild(chip);
  });
}

function showActivityWorkers(activity) {
  const result = document.getElementById("activity-result");
  if (!result) return;
  const items = activity.workers.map((m, i) => {
    const w = (typeof allWorkers !== "undefined" ? allWorkers : []).find((x) => x.id === m.id);
    if (!w) return "";
    return `<div class="activity-worker">
      <img src="${escapeHtml(w.portraitUrl)}" alt="" loading="lazy">
      <div class="activity-worker-body">
        <div class="activity-worker-name">${escapeHtml(w.name)}${i === 0 ? ' <span class="activity-best">Le plus proche de votre activité</span>' : ""}</div>
        <div class="activity-worker-role">${escapeHtml(w.role)}</div>
        <div class="activity-worker-why">${escapeHtml(m.why)}</div>
        <a href="#worker-${escapeHtml(w.id)}" class="activity-worker-link" data-worker="${escapeHtml(w.id)}">Voir la fiche de <strong>${escapeHtml(w.name)}</strong></a>
      </div>
    </div>`;
  }).join("");
  result.innerHTML = items || '<p class="activity-empty">Aucun Worker disponible pour le moment.</p>';
  result.querySelectorAll(".activity-worker-link").forEach((link) => link.addEventListener("click", (e) => {
    e.preventDefault();
    openWorkerProfile(link.dataset.worker);
  }));
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
  loadMissionLevels();
  loadEngineLine();
  const w = await fetchJson(`/api/workers/${workerId}`);
  fillProfileCommon(w);

  document.getElementById("activity-block").hidden = false;
  loadInstallPanel(workerId);          // « Installer ce Worker » ou « Embaucher ce Worker » selon le forfait
  await loadActivity(workerId);
}

async function openChloeProfile() {
  currentWorkerId = "chloe";
  loadMissionLevels();
  loadEngineLine();
  const w = await fetchJson("/api/chloe");
  fillProfileCommon(w);
  loadInstallPanel("chloe");           // Chloe ne s'installe ni ne s'embauche : le panneau se masque

  document.getElementById("profile-role").textContent = "Orchestratrice — comprend, répartit, vérifie";
  document.getElementById("activity-block").hidden = false;
  await loadActivity("chloe");
}

// opts.keepThread : ne reconstruit PAS le fil de discussion (seulement le panneau "Activite recente"). Utilise juste apres une
// mission en direct : le tour qu'on vient d'afficher reste dans la page, on peut donc lui accrocher les fichiers et la carte de
// validation (reconstruire le fil detachait ce tour : fichiers et carte "Confirmer / Annuler" n'apparaissaient plus).
async function loadActivity(workerId, opts = {}) {
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
      const filesBlock = renderTaskFilesBlock(a.taskId, a.files);
      if (filesBlock) item.appendChild(filesBlock);
      el.appendChild(item);
    });
  }

  // Rejoue les vraies missions deja enregistrees dans le fil de
  // discussion — sans ca, actualiser la page (ou juste rouvrir la
  // fiche) faisait perdre toute la conversation, alors qu'elle existe
  // bien cote serveur (signale par Kader, 2026-09-24). Le fil garde
  // uniquement CE que le serveur a reellement enregistre, rien de plus.
  if (opts.keepThread) return;
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
        <div class="chat-msg chat-msg-worker ${cls}"><div class="status-line">${escapeHtml(statusLine)}</div>${renderAnswer(answer)}${engineTagHtml(a.engine)}</div>
      `;
      const replayFiles = renderTaskFilesBlock(a.taskId, a.files);
      if (replayFiles) turn.appendChild(replayFiles);
      // Action preparee mais pas encore validee (le fichier PENDING-ACTION existe encore) : la carte revient apres un rechargement.
      if (a.pendingAction) turn.appendChild(renderPendingActionCard(a.pendingAction));
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
      ${engineTagHtml(result.engine)}
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
  const el = document.createElement("div");
  el.className = "task-files-block";
  el.innerHTML = '<div class="task-files-title">Fichiers produits</div>';
  files.forEach((file) => {
    const fname = file && file.filename ? String(file.filename) : "";
    if (!fname) return;
    const size = file && typeof file.sizeBytes === "number" ? ` (${formatFileSize(file.sizeBytes)})` : "";
    const base = `/api/missions/${encodeURIComponent(taskId)}/files/${encodeURIComponent(fname)}`;
    const row = document.createElement("div");
    row.className = "task-file-row";
    row.innerHTML = `<span class="task-file-name">📎 ${escapeHtml(fname)}${escapeHtml(size)}</span>
      <button type="button" class="btn btn-ghost task-file-preview-btn">Aperçu</button>
      <a class="btn btn-gold task-file-link" href="${base}" download>Télécharger</a>`;
    row.querySelector(".task-file-preview-btn").addEventListener("click", () => openFilePreview(base, fname));
    el.appendChild(row);
  });
  return el;
}

// Niveau de travail (Rapide / Equilibre / Approfondi) : memorise sur l'appareil, envoye avec chaque mission.
let missionLevels = { default: "", levels: [] };
function currentMissionLevel() {
  let stored = "";
  try { stored = localStorage.getItem("bk_mission_level") || ""; } catch (e) { /* stockage indisponible */ }
  const known = (missionLevels.levels || []).some((l) => l.id === stored);
  return known ? stored : (missionLevels.default || "");        // un niveau memorise que le forfait n'autorise plus retombe sur celui par defaut
}
async function loadMissionLevels() {
  const picker = document.getElementById("level-picker");
  if (!picker) return;
  try { missionLevels = await fetchJson("/api/mission-levels"); } catch (e) { return; }
  if (!missionLevels.levels || !missionLevels.levels.length) { picker.hidden = true; return; }
  let chosen = currentMissionLevel();
  if (!missionLevels.levels.some((l) => l.id === chosen)) chosen = missionLevels.default;   // niveau memorise absent de la liste (essai : Rapide seulement)
  picker.innerHTML = missionLevels.levels.map((l) =>
    `<button type="button" role="radio" class="level-chip${l.id === chosen ? " active" : ""}" aria-checked="${l.id === chosen}" data-level="${escapeHtml(l.id)}" title="${escapeHtml(l.description)}">${escapeHtml(l.label)} <span class="level-cost">${l.credits} crédit${l.credits > 1 ? "s" : ""}</span></button>`
  ).join("") + (missionLevels.locked ? '<span class="level-note">L\'essai est limité au niveau Rapide.</span>' : "");
  picker.hidden = false;
  picker.querySelectorAll(".level-chip").forEach((b) => b.addEventListener("click", () => {
    try { localStorage.setItem("bk_mission_level", b.dataset.level); } catch (e) { /* stockage indisponible : niveau par defaut */ }
    picker.querySelectorAll(".level-chip").forEach((x) => { const on = x === b; x.classList.toggle("active", on); x.setAttribute("aria-checked", on); });
    loadEngineLine();
  }));
}
loadMissionLevels();

// Moteur d'IA (Claude, moteur local, hote suisse, cle du client) : etiquette sous une reponse, ligne pres de la zone de mission, carte « Mon moteur »,
// reglages du proprietaire. Tout vient de GET /api/engine (jamais d'adresse ni de jeton) ; les textes sont ceux du serveur, en francais simple.
function engineTagHtml(engine) {
  if (!engine || !engine.label) return "";
  const text = engine.failedOver ? `Réponse du moteur de remplacement : ${engine.label}` : `Moteur : ${engine.label}`;
  return `<div class="engine-tag${engine.failedOver ? " is-failover" : ""}">${escapeHtml(text)}</div>`;
}
function engineLimitsHtml(view) {
  const caps = view && view.capabilities;
  if (!caps) return "";
  const lines = [];
  if (Array.isArray(caps.limitsFr) && caps.limitsFr.length) lines.push(`<li>Ne sait pas faire : ${escapeHtml(caps.limitsFr.join(", "))}.</li>`);
  if (caps.webFetchNote) lines.push(`<li>${escapeHtml(caps.webFetchNote)}</li>`);
  if (caps.languageNote) lines.push(`<li>${escapeHtml(caps.languageNote)}</li>`);
  if (view.failoverNote) lines.push(`<li>${escapeHtml(view.failoverNote)}</li>`);
  return lines.length ? `<ul>${lines.join("")}</ul>` : "";
}
async function loadEngineLine() {
  const line = document.getElementById("engine-line");
  if (!line) return;
  let view = null;
  try { view = await fetchJson("/api/engine?level=" + encodeURIComponent(currentMissionLevel())); } catch (e) { view = null; }
  if (!view || view.error || !view.summary) { line.hidden = true; return; }
  document.getElementById("engine-line-text").textContent = view.summary;
  const details = document.getElementById("engine-details");
  const more = document.getElementById("engine-more-btn");
  const html = engineLimitsHtml(view);
  details.innerHTML = html;
  details.hidden = true;
  more.hidden = !html;
  more.setAttribute("aria-expanded", "false");
  more.onclick = () => { details.hidden = !details.hidden; more.setAttribute("aria-expanded", String(!details.hidden)); };
  line.hidden = false;
}

// Carte « Mon moteur d'IA » (page Facturation) : le moteur utilise, ses limites, et la cle personnelle facultative (jamais renvoyee par le serveur).
async function loadEngineCard() {
  const section = document.getElementById("engine-section");
  if (!section) return;
  let view = null;
  try { view = await fetchJson("/api/engine"); } catch (e) { view = null; }
  if (!view || view.error) { section.hidden = true; return; }
  section.hidden = false;
  document.getElementById("engine-card-summary").textContent = view.summary || "";
  document.getElementById("engine-card-limits").innerHTML = engineLimitsHtml(view);
  const byok = view.byok || { configured: false };
  const remove = document.getElementById("engine-byok-remove");
  const msg = document.getElementById("engine-byok-msg");
  remove.hidden = !byok.configured;
  const kind = document.getElementById("engine-byok-kind");
  const sync = () => {
    const generic = kind.value === "openai_compat";
    document.getElementById("engine-byok-endpoint").hidden = !generic;
    document.getElementById("engine-byok-model").hidden = !generic;
  };
  kind.onchange = sync;
  sync();
  const state = byok.configured ? `Une clé ${byok.kind === "anthropic" ? "Anthropic" : "(" + (byok.host || "") + ")"} est enregistrée${byok.enabled ? "" : " mais désactivée"} : elle ne s'affiche jamais.` : "";
  if (state) { msg.className = "task-error ok"; msg.textContent = state; msg.hidden = false; } else { msg.hidden = true; }
  document.getElementById("engine-byok-form").onsubmit = async (ev) => {
    ev.preventDefault();
    const body = { kind: kind.value, key: document.getElementById("engine-byok-key").value.trim() };
    if (kind.value === "openai_compat") { body.endpoint = document.getElementById("engine-byok-endpoint").value.trim(); body.model = document.getElementById("engine-byok-model").value.trim(); }
    try {
      const r = await fetchJson("/api/engine/byok", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      if (r.ok) { document.getElementById("engine-byok-key").value = ""; showToast("Clé enregistrée."); loadEngineCard(); return; }
      msg.className = "task-error"; msg.textContent = r.message || r.error || "Enregistrement impossible."; msg.hidden = false;
    } catch (e) { msg.className = "task-error"; msg.textContent = e.message; msg.hidden = false; }
  };
  remove.onclick = async () => {
    if (!confirm("Supprimer votre clé ? Vos missions reviendront au moteur de la plateforme.")) return;
    // « Clé supprimée » seulement si le serveur confirme : un coffre qui n'a pas repondu laisse la cle en place (HTTP 500, message a afficher).
    try {
      const r = await fetchJson("/api/engine/byok/remove", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
      if (r.ok) { showToast("Clé supprimée."); loadEngineCard(); return; }
      msg.className = "task-error"; msg.textContent = r.message || r.error || "Suppression impossible."; msg.hidden = false;
    } catch (e) { msg.className = "task-error"; msg.textContent = e.message; msg.hidden = false; }
  };
}

// Reglages du moteur d'IA (vue proprietaire) : POST /api/admin/engine. Aucun jeton n'est saisi ici.
async function loadAdminEngine() {
  const stateEl = document.getElementById("admin-engine-state");
  if (!stateEl) return;
  let data = null;
  try { data = await fetchJson("/api/admin/engine"); } catch (e) { data = null; }
  if (!data || data.error || !data.engine) { stateEl.textContent = "Réglages indisponibles."; return; }
  const e = data.engine;
  const ceil = e.ceiling || {};
  const ENGINE_NAMES = { anthropic: "Claude", ollama: "moteur local", swiss: "hôte suisse" };
  const SOURCES = { defaut: "valeur par défaut", environnement: "variable BK_AI_PROVIDER du serveur", reglage: "réglage enregistré ici" };
  const lines = [`Moteur choisi : ${(e.defaultChain || []).map((id) => ENGINE_NAMES[id] || id).join(" → ")} (${escapeHtml(SOURCES[e.defaultChainSource] || e.defaultChainSource || "")})`];
  const oll = e.endpoints && e.endpoints.ollama;
  lines.push(oll ? `Moteur local : ${escapeHtml(oll.url)} — modèle ${escapeHtml(oll.model)}` : "Moteur local : non configuré");
  lines.push(ceil.configured
    ? `Dépense Claude : ${ceil.dayChf} CHF aujourd'hui${ceil.dailyChf ? " sur " + ceil.dailyChf : ""}, ${ceil.monthChf} CHF ce mois${ceil.monthlyChf ? " sur " + ceil.monthlyChf : ""}${ceil.reached ? " — PLAFOND ATTEINT : les missions passent sur le moteur gratuit" : ""}`
    : `Dépense Claude : ${ceil.dayChf || 0} CHF aujourd'hui, ${ceil.monthChf || 0} CHF ce mois — aucun plafond fixé`);
  const sick = Object.keys(e.health || {});
  if (sick.length) lines.push("Moteurs mis de côté : " + sick.map((k) => `${escapeHtml(ENGINE_NAMES[k] || k)} (${escapeHtml(e.health[k].reason)}, encore ${Math.ceil(e.health[k].retryInSec / 60)} min)`).join(", "));
  stateEl.innerHTML = lines.map((l) => `<div>${l}</div>`).join("");
  document.getElementById("admin-engine-chain").value = (e.defaultChain || ["anthropic"]).join(",");
  if (oll) { document.getElementById("admin-engine-url").value = oll.url; document.getElementById("admin-engine-model").value = oll.model; }
  document.getElementById("admin-engine-daily").value = ceil.dailyChf || "";
  document.getElementById("admin-engine-monthly").value = ceil.monthlyChf || "";
  document.getElementById("admin-engine-form").onsubmit = async (ev) => {
    ev.preventDefault();
    const msg = document.getElementById("admin-engine-msg");
    const num = (id) => { const v = document.getElementById(id).value.trim(); return v === "" ? null : Number(v); };
    const body = { defaultChain: document.getElementById("admin-engine-chain").value.split(","), ceiling: { dailyChf: num("admin-engine-daily"), monthlyChf: num("admin-engine-monthly") } };
    const url = document.getElementById("admin-engine-url").value.trim();
    if (url) body.endpoints = { ollama: { url, model: document.getElementById("admin-engine-model").value.trim() || "llama3:latest" } };
    try {
      const r = await fetchJson("/api/admin/engine", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      if (r.ok) { msg.className = "task-error ok"; msg.textContent = "Enregistré."; msg.hidden = false; loadAdminEngine(); return; }
      msg.className = "task-error"; msg.textContent = (r.errors || []).map((x) => x.message).join(" ") || r.error || "Refusé."; msg.hidden = false;
    } catch (err) { msg.className = "task-error"; msg.textContent = err.message; msg.hidden = false; }
  };
}

// Aperçu d'un fichier produit AVANT de le télécharger (tableur, document, presentation, PDF, image, texte).
async function openFilePreview(base, fname) {
  document.querySelectorAll(".file-preview-overlay").forEach((n) => n.remove());
  const overlay = document.createElement("div");
  overlay.className = "file-preview-overlay";
  overlay.innerHTML = `<div class="file-preview-box" role="dialog" aria-modal="true" aria-label="Aperçu du fichier">
      <div class="file-preview-head"><strong class="file-preview-title"></strong>
        <span class="file-preview-actions"><a class="btn btn-gold" download>Télécharger</a><button type="button" class="btn btn-ghost file-preview-close">Fermer</button></span></div>
      <div class="file-preview-body"><div class="file-preview-loading">Chargement de l'aperçu…</div></div></div>`;
  overlay.querySelector(".file-preview-title").textContent = fname;
  overlay.querySelector("a[download]").href = base;
  const close = () => { overlay.remove(); document.removeEventListener("keydown", onKey); };
  const onKey = (e) => { if (e.key === "Escape") close(); };
  document.addEventListener("keydown", onKey);
  overlay.addEventListener("click", (e) => { if (e.target === overlay) close(); });
  overlay.querySelector(".file-preview-close").addEventListener("click", close);
  document.body.appendChild(overlay);
  const body = overlay.querySelector(".file-preview-body");
  const table = (rows) => {
    const t = document.createElement("table");
    t.className = "file-preview-table";
    rows.forEach((r, i) => {
      const tr = document.createElement("tr");
      r.forEach((c) => { const td = document.createElement(i === 0 ? "th" : "td"); td.textContent = c; tr.appendChild(td); });
      t.appendChild(tr);
    });
    return t;
  };
  try {
    const res = await fetchJson(base + "/preview");
    body.innerHTML = "";
    if (!res.ok) { body.innerHTML = `<p class="file-preview-note">${escapeHtml(res.error || "Aperçu indisponible.")} Vous pouvez tout de même télécharger le fichier.</p>`; return; }
    const p = res.preview || {};
    if (p.kind === "table") {
      const tabs = document.createElement("div");
      tabs.className = "file-preview-tabs";
      const panel = document.createElement("div");
      const show = (i) => {
        panel.innerHTML = "";
        const s = p.sheets[i];
        panel.appendChild(table(s.rows));
        const notes = [];
        if (s.truncated) notes.push("Aperçu limité aux premières lignes et colonnes.");
        if (s.formulaCells) {
          const open = s.formulaCells - (s.computedCells || 0);
          notes.push(open > 0
            ? `${s.formulaCells} cellule(s) contiennent une formule${s.computedCells ? ` (${s.computedCells} calculée(s) ici)` : ""} : ${open === s.formulaCells ? "les résultats" : "les autres résultats"} s'affichent à l'ouverture dans Excel.`
            : `${s.formulaCells} cellule(s) contiennent une formule : valeurs calculées pour cet aperçu, le fichier garde ses formules.`);
        }
        if (notes.length) { const n = document.createElement("p"); n.className = "file-preview-note"; n.textContent = notes.join(" "); panel.appendChild(n); }
        [...tabs.children].forEach((b, j) => b.classList.toggle("active", j === i));
      };
      p.sheets.forEach((s, i) => { const b = document.createElement("button"); b.type = "button"; b.className = "file-preview-tab"; b.textContent = s.name; b.addEventListener("click", () => show(i)); tabs.appendChild(b); });
      if (p.sheets.length > 1) body.appendChild(tabs);
      body.appendChild(panel);
      show(0);
    } else if (p.kind === "document") {
      p.blocks.forEach((b) => {
        if (b.type === "table") { body.appendChild(table(b.rows)); return; }
        const n = document.createElement(b.type === "h" ? "h4" : "p");
        n.textContent = b.text;
        body.appendChild(n);
      });
      if (p.truncated) { const n = document.createElement("p"); n.className = "file-preview-note"; n.textContent = "Aperçu limité au début du document."; body.appendChild(n); }
    } else if (p.kind === "slides") {
      p.slides.forEach((s) => {
        const d = document.createElement("div"); d.className = "file-preview-slide";
        const h = document.createElement("strong"); h.textContent = "Diapositive " + s.n; d.appendChild(h);
        s.lines.forEach((l) => { const li = document.createElement("p"); li.textContent = l; d.appendChild(li); });
        body.appendChild(d);
      });
    } else if (p.kind === "text") {
      const pre = document.createElement("pre"); pre.className = "file-preview-text"; pre.textContent = p.text; body.appendChild(pre);
    } else if (p.kind === "pdf") {
      const f = document.createElement("iframe"); f.className = "file-preview-frame"; f.title = "Aperçu PDF"; f.src = base + "?inline=1"; body.appendChild(f);
    } else if (p.kind === "image") {
      const img = document.createElement("img"); img.className = "file-preview-image"; img.alt = fname; img.src = base + "?inline=1"; body.appendChild(img);
    } else {
      body.innerHTML = '<p class="file-preview-note">Pas d\'aperçu pour ce type de fichier. Vous pouvez le télécharger.</p>';
    }
  } catch (e) {
    body.innerHTML = '<p class="file-preview-note">Aperçu indisponible pour le moment. Vous pouvez télécharger le fichier.</p>';
  }
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
    // (envoi + interrogation : submitMissionAndWait, partage avec l'essai a
    // blanc de l'assistant d'installation.)
    const missionWorkerId = currentWorkerId;
    const outcome = await submitMissionAndWait(missionWorkerId, objective);

    if (outcome.accountRequired) {
      turn.remove();
      requireAccount(() => runTask(objective));
      return;
    }
    if (outcome.timedOut) {
      // Plafond de securite atteint : on cesse d'interroger plutot que
      // de boucler indefiniment. La mission continue cote serveur.
      responseEl.className = "chat-msg chat-msg-worker needs-chloe";
      responseEl.innerHTML = `<div class="status-line">Toujours en cours</div>
        <p>La mission prend plus de temps que prévu. Elle continue en arrière-plan — réessayez dans un instant.</p>`;
      turn.scrollIntoView({ behavior: "smooth", block: "end" });
      return;
    }
    const result = outcome.result;

    if (result.error === "WORKER_NOT_INCLUDED") {
      // Offre « Worker a l'unite » : ce Worker n'est pas dans le forfait (aucune mission lancee, aucun credit consomme).
      iwRenderNotIncluded(responseEl, result, missionWorkerId, null);
      turn.scrollIntoView({ behavior: "smooth", block: "end" });
      return;
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
        ${subscribeCtaHtml(result)}`;
      wireSubscribeCta(responseEl, result);
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
      responseEl.innerHTML = `<div class="status-line">${statusLine}</div>${renderAnswer(result.FinalSynthesis || "Aucune synthèse disponible.")}`
        + engineTagHtml((result.Results || []).map((r) => r && r.Result && r.Result.Engine).find(Boolean));
    } else {
      const needsChloe = result.Status === "NEEDS_CHLOE_VERIFICATION";
      const blocked = result.Authorized !== true;
      responseEl.className = "chat-msg chat-msg-worker" + (needsChloe ? " needs-chloe" : blocked ? " blocked" : "");
      const statusLine = blocked ? (result.Reason || result.Status || "Bloqué") : "Exécuté";
      const answer = result.Result && result.Result.Answer ? result.Result.Answer
        : (result.ExecutionNote || (needsChloe ? "Cette action passe par le chat avec Chloé pour vérification." : "Tâche autorisée, en attente de routage vers un Worker."));
      responseEl.innerHTML = `<div class="status-line">${escapeHtml(statusLine)}</div>${renderAnswer(answer)}${engineTagHtml(result.Result && result.Result.Engine)}`;
      await loadActivity(currentWorkerId, { keepThread: true });
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
        ${subscribeCtaHtml(result)}`;
      wireSubscribeCta(responseEl, result, closeChloeFab);
      return;
    }
    if (result.error === "WORKER_NOT_INCLUDED") {
      // Forfait Solo : Chloe n'est pas incluse ; Trio : seuls les Workers embauches travaillent (notIncludedWorkers).
      iwRenderNotIncluded(responseEl, result, "chloe", closeChloeFab);
      turn.scrollIntoView({ behavior: "smooth", block: "end" });
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

// ===== HIRE-UI BEGIN : offre « Worker a l'unite » (installation guidee, embauche, interrupteur de pause) =====
// 2026-10-12 : le client installe UN Worker selon ses competences : services -> fiche de connaissances -> autonomie -> outils -> essai a blanc
// -> activation. Contrat serveur : docs/HIRE-API.md. Regles que cette interface ne contourne jamais :
//  - "Autonome" (auto) n'est propose QUE pour les actions que le profil classe en risque faible ; envoyer, publier, payer, supprimer et
//    appeler demandent toujours la validation du client ;
//  - seuls les canaux reellement disponibles (liveChannels) sont presentes comme disponibles : telephone, WhatsApp et e-mail = « bientot » ;
//  - tout texte venant du serveur ou du client passe par escapeHtml ; aucun secret n'est jamais demande ni conserve ici ;
//  - aucun prix n'est affiche par cette interface (les prix sont sur la page Tarifs et dans Facturation) : la demande part chez BK Entreprise,
//    rien n'est debite ici ;
//  - les reglages d'autonomie sont des CONSIGNES donnees au Worker (injectees dans son prompt, voir Client-Installation.ps1), jamais presentes
//    comme une garantie de la plateforme : la validation des envois, publications, paiements, suppressions et appels est technique, a part.

// BK-PURE-BEGIN (fonctions sans acces au DOM : testees telles quelles par tests/hire-ui/test_pure_logic.js)
const IW_MODES = [
  { id: "off", label: "Ne jamais", help: "Consigne donnée au Worker : ne jamais faire cette action." },
  { id: "ask", label: "Demander d'abord", help: "Consigne donnée au Worker : vous demander avant d'agir et attendre votre réponse." },
  { id: "draft", label: "Préparer et attendre ma validation", help: "Consigne donnée au Worker : préparer le résultat (brouillon, fichier) et attendre votre accord." },
  { id: "auto", label: "Autonome", help: "Consigne donnée au Worker : le faire, puis vous le dire. Réservé aux actions sans risque (lire, analyser, rédiger)." },
];
const IW_RISK = { low: "Risque faible", medium: "Risque moyen", high: "Risque élevé" };
const IW_CHANNEL_LABELS = { web: "Dans l'application", schedule: "Mission récurrente", email: "E-mail", phone: "Téléphone", whatsapp: "WhatsApp" };
const IW_STEP_LABELS = ["Services", "Fiche", "Autonomie", "Outils", "Essai"];
const IW_STATUS_LABELS = { draft: "Brouillon", active: "Actif", paused: "En pause" };
// Texte de l'interrupteur d'arret : un brouillon reste « en marche » (il recoit la fiche et ses automatisations tournent) tant qu'on ne l'arrete pas.
const IW_RUN_LABELS = { draft: "En marche", active: "Actif", paused: "En pause" };
const IW_FIELD_MAX = 2000;

// "Autonome" n'existe que pour une action de risque faible qui n'ecrit pas dans un outil (une regle avec « operations » gouverne une ecriture :
// tache CRM, brouillon de message, carte...) : le serveur le refuse sinon (400 INSTALLATION_INVALID).
function iwModesFor(rule) {
  return IW_MODES.filter((m) => m.id !== "auto" || (rule && rule.risk === "low" && !(Array.isArray(rule.operations) && rule.operations.length)));
}

// Piege du focus de l'assistant : renvoie "first" ou "last" quand la touche Tab doit boucler (ou ramener le focus dans la fenetre), sinon null.
// `items` = elements focalisables de la fenetre, `active` = element qui a le focus, `box` = la fenetre. Un element qui n'est pas dans la liste
// (le titre qui recoit le focus a l'ouverture, ou la page derriere quand le focus s'est echappe) compte comme « avant le premier » pour Maj+Tab.
function iwTabTarget(items, active, box, shift) {
  if (!items || !items.length) return null;
  const first = items[0];
  const last = items[items.length - 1];
  if (!box || !box.contains(active)) return shift ? "last" : "first";
  if (shift) return (active === first || active === box || items.indexOf(active) < 0) ? "last" : null;
  return active === last ? "first" : null;
}

function iwDefaultMode(rule) {
  const allowed = iwModesFor(rule).map((m) => m.id);
  return rule && allowed.includes(rule.defaultMode) ? rule.defaultMode : "ask";
}

// Etat de l'assistant a partir du profil et de la fiche deja enregistree (ou rien). Les reglages d'autonomie partent des valeurs par defaut du profil.
function iwInitialState(profile, installation) {
  const services = {};
  ((profile && profile.services) || []).forEach((def) => {
    const saved = installation && installation.services && installation.services[def.id];
    const knowledge = {};
    (def.knowledgeFields || []).forEach((f) => {
      const v = saved && saved.knowledge ? saved.knowledge[f.key] : "";
      knowledge[f.key] = typeof v === "string" ? v : "";
    });
    const autonomy = {};
    (def.autonomyRules || []).forEach((r) => {
      const m = saved && saved.autonomy ? saved.autonomy[r.category] : null;
      autonomy[r.category] = iwModesFor(r).some((x) => x.id === m) ? m : iwDefaultMode(r);
    });
    services[def.id] = { enabled: !!(saved && saved.enabled), level: (saved && saved.level) || null, knowledge, autonomy };
  });
  return { services, notes: (installation && typeof installation.notes === "string") ? installation.notes : "" };
}

function iwEnabledDefs(profile, state) {
  return ((profile && profile.services) || []).filter((d) => state.services[d.id] && state.services[d.id].enabled);
}

// Canaux de ce service que le profil dit REELLEMENT disponibles ("available"), dans l'ordre du profil.
function iwLiveChannelsOf(def, profile, liveChannels) {
  const support = (profile && profile.channelSupport) || {};
  const live = Array.isArray(liveChannels) ? liveChannels : [];
  return (def.channels || []).filter((c) => support[c] === "available" && live.includes(c));
}

// Canaux affiches pour un service : disponibles d'un cote, « bientot » de l'autre ; ce que le profil exclut ("no") n'est jamais montre.
function iwChannelChips(def, profile, liveChannels) {
  const support = (profile && profile.channelSupport) || {};
  const live = Array.isArray(liveChannels) ? liveChannels : [];
  return (def.channels || [])
    .filter((c) => support[c] === "available" || support[c] === "planned")
    .map((c) => ({ id: c, label: IW_CHANNEL_LABELS[c] || c, soon: !(support[c] === "available" && live.includes(c)) }));
}

// Configuration COMPLETE envoyee a POST /api/installations (elle remplace la precedente). Un service ni coche ni renseigne n'est pas envoye.
function iwBuildPayload(workerId, profile, state, liveChannels) {
  const services = {};
  ((profile && profile.services) || []).forEach((def) => {
    const s = state.services[def.id];
    if (!s) return;
    const knowledge = {};
    Object.keys(s.knowledge || {}).forEach((k) => {
      const v = String(s.knowledge[k] == null ? "" : s.knowledge[k]).trim();
      if (v) knowledge[k] = v;
    });
    if (!s.enabled && !Object.keys(knowledge).length) return;
    const autonomy = {};
    (def.autonomyRules || []).forEach((r) => {
      const wanted = s.autonomy ? s.autonomy[r.category] : null;
      autonomy[r.category] = iwModesFor(r).some((x) => x.id === wanted) ? wanted : iwDefaultMode(r);
    });
    const entry = { enabled: !!s.enabled, knowledge, autonomy, channels: iwLiveChannelsOf(def, profile, liveChannels) };
    if (s.level) entry.level = s.level;
    services[def.id] = entry;
  });
  return { workerId, services, notes: String(state.notes || "").trim() };
}

// Ce qu'il manque pour activer (reflet du calcul serveur : au moins un service, champs obligatoires, outils obligatoires connectes).
// connectorStatus : { "hubspot.controlled": true|false|null } ; null = non verifiable (compte proprietaire) -> aucun controle d'outil.
function iwMissing(profile, state, connectorStatus) {
  const out = [];
  const defs = iwEnabledDefs(profile, state);
  if (!defs.length) out.push({ kind: "service" });
  defs.forEach((d) => {
    const s = state.services[d.id];
    (d.knowledgeFields || []).forEach((f) => {
      if (f.required && !String((s.knowledge || {})[f.key] || "").trim()) out.push({ kind: "field", svc: d.label, svcId: d.id, what: f.label });
    });
    const known = (cid) => !connectorStatus || connectorStatus[cid] !== false;
    (d.requiredConnectors || []).forEach((cid) => {
      if (!known(cid)) out.push({ kind: "tool", svc: d.label, svcId: d.id, tools: [cid], any: false });
    });
    (d.requiredAnyOf || []).forEach((group) => {
      if (Array.isArray(group) && group.length && !group.some(known)) out.push({ kind: "tool", svc: d.label, svcId: d.id, tools: group.slice(), any: true });
    });
  });
  return out;
}

// Outils d'un service : obligatoires, « au moins un parmi », facultatifs.
function iwToolsOf(def) {
  return {
    required: (def.requiredConnectors || []).slice(),
    anyOf: (def.requiredAnyOf || []).filter((g) => Array.isArray(g) && g.length).map((g) => g.slice()),
    optional: (def.optionalConnectors || []).slice(),
  };
}

// Repartition des reglages d'autonomie des services coches (pour le resume avant activation).
function iwAutonomySummary(profile, state) {
  const n = { off: 0, ask: 0, draft: 0, auto: 0 };
  iwEnabledDefs(profile, state).forEach((d) => {
    (d.autonomyRules || []).forEach((r) => {
      const m = state.services[d.id].autonomy[r.category];
      if (n[m] !== undefined) n[m] += 1;
    });
  });
  return n;
}

function iwFriendlyError(msg) {
  const m = String(msg || "");
  let x;
  if ((x = m.match(/(\d+) caracteres? maximum/))) return `${x[1]} caractères au maximum.`;
  if (/ne saisissez jamais de mot de passe/i.test(m)) return "Ne saisissez jamais de mot de passe, de clé d'API, de numéro de carte ni d'IBAN : retirez cette information.";
  if (/autonomie complete n'est pas autorisee/i.test(m)) return "L'autonomie complète n'est pas permise pour cette action : votre validation reste obligatoire.";
  return m ? m.charAt(0).toUpperCase() + m.slice(1) : "Valeur refusée.";
}

// Messages d'erreur du serveur (400 INSTALLATION_INVALID, "service.champ : message") -> par champ, avec l'etape ou les corriger.
function iwParseErrors(errors, profile) {
  const out = { fields: {}, general: [], items: [] };
  const defs = {};
  ((profile && profile.services) || []).forEach((d) => { defs[d.id] = d; });
  const push = (key, step, svcLabel, msg, field) => {
    if (key) (out.fields[key] = out.fields[key] || []).push(msg);
    out.items.push({ key, step, svc: svcLabel || "", field: field || "", msg });
  };
  (Array.isArray(errors) ? errors : [errors]).filter(Boolean).forEach((raw) => {
    const text = String(raw);
    let m = text.match(/^([a-z0-9-]+)\.([a-z0-9_-]+) : (.*)$/);
    if (m && defs[m[1]]) {
      const kf = (defs[m[1]].knowledgeFields || []).find((f) => f.key === m[2]);
      const rule = kf ? null : (defs[m[1]].autonomyRules || []).find((r) => r.category === m[2]);
      push(m[1] + "." + m[2], kf ? 1 : 2, defs[m[1]].label, iwFriendlyError(m[3]), (kf && kf.label) || (rule && rule.label) || "");
      return;
    }
    m = text.match(/^notes : (.*)$/);
    if (m) { push("notes", 1, "", iwFriendlyError(m[1]), "Consignes générales"); return; }
    m = text.match(/^([a-z0-9-]+) : (.*)$/);
    if (m && defs[m[1]]) { push(m[1], 0, defs[m[1]].label, iwFriendlyError(m[2])); return; }
    out.general.push(iwFriendlyError(text));
    out.items.push({ key: "", step: -1, svc: "", field: "", msg: iwFriendlyError(text) });
  });
  return out;
}
// BK-PURE-END

// Un seul assistant a la fois (null = ferme). iwMemory garde ce qui a ete saisi mais pas enregistre : fermer puis rouvrir ne perd rien.
let iw = null;
const iwMemory = {};
let onConnectorsReloaded = null;      // appele par loadConnectors() : l'assistant rafraichit alors l'etat des outils
const IW_RETURN_KEY = "bk_install_return";

// Texte d'une boite native (confirm) : le dictionnaire du navigateur ne les voit pas, on les traduit a la main.
const iwT = (s) => (window.bkTr ? window.bkTr(s) : s);
// Phrase avec des valeurs (nom du Worker...) : le modele est traduit, puis les {valeurs} sont inserees.
const iwTf = (template, vars) => iwT(template).replace(/\{(\w+)\}/g, (m, k) => (vars && vars[k] !== undefined ? vars[k] : m));

function iwNow() {
  return new Date().toLocaleTimeString(BK_LOCALE(), { hour: "2-digit", minute: "2-digit" });
}

function iwDate(iso) {
  return iso ? new Date(iso).toLocaleString(BK_LOCALE(), { dateStyle: "medium", timeStyle: "short" }) : "";
}

async function iwLoadCatalog() {
  try {
    const data = await fetchJson("/api/connectors");
    const map = {};
    Object.entries(data.categories || {}).forEach(([category, list]) => (list || []).forEach((c) => { map[c.connectorId] = Object.assign({ category }, c); }));
    return map;
  } catch (e) {
    return {};
  }
}

function iwToolName(cid, catalog) {
  const c = catalog && catalog[cid];
  if (c && c.provider) return brandName(c.provider);
  const t = humanizeTag(String(cid).split(".")[0]);
  return t.charAt(0).toUpperCase() + t.slice(1);
}

function iwToolNames(list, catalog) {
  return list.map((cid) => iwToolName(cid, catalog)).join(", ");
}

// ---------- ASSISTANT D'INSTALLATION ----------

let iwOpening = false;

// Ouverture : le serveur est interroge (profil + outils), ce qui prend un instant ; le bouton le montre et un double clic n'ouvre pas deux fenetres.
async function openInstallWizard(workerId, startStep) {
  if (!accountAuthenticated) { requireAccount(() => openInstallWizard(workerId, startStep)); return; }
  if (iw || iwOpening) return;
  iwOpening = true;
  const trigger = document.activeElement && document.activeElement.tagName === "BUTTON" ? document.activeElement : null;
  if (trigger) { trigger.classList.add("is-busy"); trigger.setAttribute("aria-busy", "true"); }
  try {
    await iwOpenNow(workerId, startStep);
  } finally {
    iwOpening = false;
    if (trigger) { trigger.classList.remove("is-busy"); trigger.removeAttribute("aria-busy"); }
  }
}

async function iwOpenNow(workerId, startStep) {
  const opener = document.activeElement;
  let data;
  let catalog;
  try {
    [data, catalog] = await Promise.all([fetchJson(`/api/workers/${encodeURIComponent(workerId)}/install-profile`), iwLoadCatalog()]);
  } catch (e) {
    showToast(e.message || "Impossible d'ouvrir l'installation pour le moment. Réessayez.", false);
    return;
  }
  if (data.error === "ACCOUNT_REQUIRED") { iwSessionLost(() => openInstallWizard(workerId, startStep)); return; }
  if (data.error) { showToast(data.detail || "Ce Worker n'a pas encore de fiche d'installation.", false); return; }
  if (!data.entitled) {
    showToast("Ce Worker ne fait pas partie de votre forfait : embauchez-le d'abord.", false);
    loadInstallPanel(workerId);
    return;
  }
  const mem = iwMemory[workerId];
  iw = {
    workerId, workerName: data.workerName || workerNameById(workerId), profile: data.profile, installation: data.installation,
    readiness: data.readiness || [], connectorStatus: data.connectorStatus || {}, liveChannels: data.liveChannels || [], catalog,
    step: Math.max(0, Math.min(IW_STEP_LABELS.length - 1, startStep || 0)),
    state: mem ? mem.state : iwInitialState(data.profile, data.installation),
    dirty: mem ? mem.dirty : false, errors: null, warnings: [], savedAt: null, saving: false, trialServiceId: null, trialRunning: false, opener,
  };
  const worker = allWorkers.find((x) => x.id === workerId);
  const overlay = document.createElement("div");
  overlay.className = "iw-overlay";
  overlay.id = "iw-overlay";
  overlay.innerHTML = `
    <div class="iw-box" role="dialog" aria-modal="true" aria-labelledby="iw-title">
      <header class="iw-head">
        ${worker && worker.portraitUrl ? `<img class="iw-portrait" src="${escapeHtml(worker.portraitUrl)}" alt="">` : ""}
        <div class="iw-head-text">
          <div class="iw-kicker">Installation</div>
          <h2 id="iw-title" tabindex="-1">${escapeHtml(iw.workerName)}</h2>
        </div>
        <span class="iw-status-pill" id="iw-status-pill"></span>
        <button type="button" class="iw-close" id="iw-close" aria-label="Fermer">&times;</button>
      </header>
      <ol class="iw-steps" id="iw-steps" aria-label="Étapes de l'installation"></ol>
      <div class="iw-body" id="iw-body"></div>
      <footer class="iw-foot">
        <div class="iw-foot-top">
          <div class="iw-savestate" id="iw-savestate" role="status" aria-live="polite"></div>
          <button type="button" class="btn btn-ghost iw-save-btn" id="iw-save">Enregistrer le brouillon</button>
        </div>
        <div class="iw-foot-btns">
          <button type="button" class="btn btn-ghost" id="iw-prev">Précédent</button>
          <button type="button" class="btn btn-gold" id="iw-next">Suivant</button>
        </div>
      </footer>
    </div>`;
  document.body.appendChild(overlay);
  document.body.classList.add("iw-open");
  overlay.addEventListener("keydown", iwOnKeydown);
  overlay.addEventListener("mousedown", (e) => { if (e.target === overlay) iwClose(); });
  overlay.querySelector("#iw-close").addEventListener("click", () => iwClose());
  overlay.querySelector("#iw-prev").addEventListener("click", () => iwGo(iw.step - 1));
  overlay.querySelector("#iw-next").addEventListener("click", () => {
    if (iw.step >= IW_STEP_LABELS.length - 1) iwFinish();
    else iwGo(iw.step + 1);
  });
  overlay.querySelector("#iw-save").addEventListener("click", async () => {
    const ok = await iwSave();
    if (ok) showToast("Brouillon enregistré.");
  });
  window.addEventListener("beforeunload", iwBeforeUnload);
  onConnectorsReloaded = () => { if (iw) iwRefreshServerState(); };
  iwRender();
  iwSetSaveState(iw.dirty ? "dirty" : (iw.installation ? "saved-before" : "none"));
  const title = document.getElementById("iw-title");
  if (title) title.focus();
}

// Reponse ACCOUNT_REQUIRED du serveur = la session est finie (30 jours, ou deconnexion dans un autre onglet). Le drapeau local est perime : sans le
// remettre a faux, requireAccount relancerait l'action au lieu d'ouvrir la fenetre de connexion, et le bouton ne ferait rien.
function iwSessionLost(action) {
  accountAuthenticated = false;
  requireAccount(action);
}

function iwBeforeUnload(e) {
  if (iw && iw.dirty) { e.preventDefault(); e.returnValue = ""; }
}

function iwOnKeydown(e) {
  if (e.key === "Escape") {
    if (document.querySelector(".cg-overlay")) return;      // la fenetre « Connecter un outil » gere sa propre fermeture
    e.preventDefault();
    iwClose();
    return;
  }
  if (e.key !== "Tab") return;
  const box = document.querySelector("#iw-overlay .iw-box");
  if (!box) return;
  const items = Array.from(box.querySelectorAll("button, [href], input, select, textarea, summary, [tabindex]:not([tabindex='-1'])"))
    .filter((el) => !el.disabled && el.offsetParent !== null);
  // Maj+Tab depuis le titre (tabindex -1, focus a l'ouverture) ou depuis la page derriere la fenetre ramene dans la fenetre, jamais dehors.
  const target = iwTabTarget(items, document.activeElement, box, e.shiftKey);
  if (!target) return;
  e.preventDefault();
  (target === "last" ? items[items.length - 1] : items[0]).focus();
}

// Fermer ne perd jamais la saisie : elle est enregistree en brouillon ; si le serveur refuse (champ invalide, reseau, session expiree), elle est
// gardee dans iwMemory et revient a la reouverture. opts.skipSave : ne pas tenter d'enregistrer (session expiree : on garde simplement).
async function iwClose(opts) {
  if (!iw) return;
  let kept = false;
  if (iw.dirty) {
    if (opts && opts.skipSave) kept = true;
    else if (!iw.saving) kept = !(await iwSave({ quiet: true }));
    else kept = true;
  }
  if (!iw) return;
  const { workerId, opener } = iw;
  if (kept) iwMemory[workerId] = { state: iw.state, dirty: true };
  else delete iwMemory[workerId];
  const overlay = document.getElementById("iw-overlay");
  if (overlay) overlay.remove();
  document.body.classList.remove("iw-open");
  window.removeEventListener("beforeunload", iwBeforeUnload);
  onConnectorsReloaded = null;
  iw = null;
  if (kept) showToast("Vos modifications n'ont pas pu être enregistrées, mais elles sont conservées : rouvrez l'installation pour les corriger.", false);
  if (!billingView.hidden) loadInstalledWorkers();
  await loadInstallPanel(workerId);
  // Le panneau vient d'etre redessine : le clavier retrouve le bouton qui avait ouvert l'assistant.
  const target = opener && document.contains(opener) ? opener : document.getElementById("iw-open-btn");
  if (target && target.focus) target.focus();
}

function iwSetSaveState(kind) {
  const el = document.getElementById("iw-savestate");
  if (!el) return;
  const map = {
    none: '<span>Rien d\'enregistré pour le moment</span>',
    "saved-before": '<span>Brouillon déjà enregistré</span>',
    dirty: '<span class="iw-dirty">Modifications non enregistrées</span>',
    saving: '<span>Enregistrement…</span>',
    saved: `<span>Brouillon enregistré à</span> <time>${escapeHtml(iw && iw.savedAt ? iw.savedAt : iwNow())}</time>`,
    failed: '<span class="iw-dirty">Enregistrement refusé : corrigez les points signalés</span>',
    "failed-general": '<span class="iw-dirty">Enregistrement non effectué : votre saisie est conservée</span>',
  };
  el.innerHTML = map[kind] || "";
}

function iwMarkDirty() {
  if (!iw) return;
  iw.dirty = true;
  iwSetSaveState("dirty");
}

// ---------- ENREGISTREMENT (brouillon a chaque etape ; les erreurs du serveur restent a l'ecran, la saisie n'est jamais effacee) ----------

async function iwSave(opts) {
  if (!iw || iw.saving) return false;
  const quiet = !!(opts && opts.quiet);
  const statusBefore = iw.installation ? iw.installation.status : null;
  if (!quiet && statusBefore === "active" && iwMissing(iw.profile, iw.state, iw.connectorStatus).some((m) => m.kind === "service" || m.kind === "field")) {
    // Le serveur repasse une installation active en brouillon des qu'il manque un service ou un champ obligatoire : on le dit AVANT.
    if (!confirm(iwT("Cette modification laisse un élément obligatoire vide : l'installation repassera en brouillon et ne sera plus marquée « Actif » tant que vous ne l'aurez pas complétée. Enregistrer quand même ?"))) return false;
  }
  iw.saving = true;
  iwSetSaveState("saving");
  const saveBtn = document.getElementById("iw-save");
  if (saveBtn) saveBtn.disabled = true;
  try {
    const r = await fetchJson("/api/installations", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(iwBuildPayload(iw.workerId, iw.profile, iw.state, iw.liveChannels)),
    });
    if (r.error === "ACCOUNT_REQUIRED") {
      // Session expiree : on ferme l'assistant en gardant la saisie, la connexion se fait par-dessus, puis on rouvre a la meme etape.
      // Le drapeau local est perime (la session est finie cote serveur) : sans le remettre a faux, requireAccount relancerait l'action au lieu
      // d'ouvrir la fenetre de connexion.
      const { workerId, step } = iw;
      iw.saving = false;
      accountAuthenticated = false;
      iwClose({ skipSave: true });
      requireAccount(() => openInstallWizard(workerId, step));
      return false;
    }
    if (r.error === "INSTALLATION_INVALID") {
      iw.errors = iwParseErrors(r.errors && r.errors.length ? r.errors : [r.detail], iw.profile);
      iwSetSaveState("failed");
      if (!quiet) iwShowErrors();
      return false;
    }
    if (r.error === "WORKER_NOT_INCLUDED") {
      iw.errors = { fields: {}, general: [r.detail || "Ce Worker ne fait pas partie de votre forfait."], items: [{ key: "", step: -1, svc: "", msg: r.detail || "" }] };
      iwSetSaveState("failed-general");
      if (!quiet) iwShowErrors();
      return false;
    }
    if (r.error || !r.installation) {
      iw.errors = { fields: {}, general: [r.detail || "Enregistrement impossible pour le moment. Réessayez."], items: [] };
      iwSetSaveState("failed-general");
      if (!quiet) iwShowErrors();
      return false;
    }
    iw.installation = r.installation;
    iw.readiness = r.installation.readiness || [];
    iw.warnings = r.warnings || [];
    iw.errors = null;
    iw.dirty = false;
    iw.savedAt = iwNow();
    iwSetSaveState("saved");
    iwRenderStatusPill();
    iwClearErrors();
    if (statusBefore === "active" && r.installation.status === "draft") {
      showToast("Cette installation n'est plus complète : elle repasse en brouillon. Complétez-la pour la réactiver.", false);
    }
    return true;
  } catch (e) {
    iw.errors = { fields: {}, general: ["Enregistrement impossible pour le moment (réseau ou serveur). Ce que vous avez saisi est conservé."], items: [] };
    iwSetSaveState("failed-general");
    if (!quiet) iwShowErrors();
    return false;
  } finally {
    if (iw) iw.saving = false;
    const b = document.getElementById("iw-save");
    if (b) b.disabled = false;
  }
}

function iwClearErrors() {
  document.querySelectorAll("#iw-body .iw-field-err").forEach((el) => { el.hidden = true; el.textContent = ""; });
  document.querySelectorAll("#iw-body [aria-invalid='true']").forEach((el) => el.removeAttribute("aria-invalid"));
  const sum = document.getElementById("iw-error-summary");
  if (sum) sum.hidden = true;
}

// Resume des erreurs en haut de l'etape + message sous chaque champ concerne (les champs d'autres etapes sont atteignables par un bouton).
function iwShowErrors() {
  if (!iw || !iw.errors) return;
  const sum = document.getElementById("iw-error-summary");
  if (!sum) return;
  const items = iw.errors.items.length ? iw.errors.items : iw.errors.general.map((msg) => ({ key: "", step: -1, svc: "", msg }));
  sum.innerHTML = `<div class="iw-alert-title">${items.some((it) => it.key) ? "L'enregistrement a été refusé. Corrigez ces points, votre saisie est conservée." : "L'enregistrement n'a pas abouti. Votre saisie est conservée."}</div>
    <ul>${items.map((it) => `<li>${it.svc ? `<strong>${escapeHtml(it.svc)}</strong> ` : ""}${it.field ? `<em>${escapeHtml(it.field)} :</em> ` : ""}<span>${escapeHtml(it.msg)}</span>${it.step >= 0 && it.step !== iw.step ? ` <button type="button" class="iw-link" data-goto="${it.step}">Corriger à l'étape « ${escapeHtml(IW_STEP_LABELS[it.step])} »</button>` : ""}</li>`).join("")}</ul>`;
  sum.hidden = false;
  sum.querySelectorAll("[data-goto]").forEach((b) => b.addEventListener("click", () => { iw.step = Number(b.dataset.goto); iwRender(); }));
  Object.entries(iw.errors.fields).forEach(([key, msgs]) => {
    const err = document.querySelector(`#iw-body [data-err-for="${CSS.escape(key)}"]`);
    if (err) {
      err.textContent = msgs.join(" ");
      err.hidden = false;
      const input = err.parentElement && err.parentElement.querySelector("textarea, input");
      if (input) input.setAttribute("aria-invalid", "true");
    }
  });
  sum.focus();
}

async function iwGo(step) {
  if (!iw) return;
  const target = Math.max(0, Math.min(IW_STEP_LABELS.length - 1, step));
  if (target === iw.step) return;
  if (iw.dirty) {
    const ok = await iwSave();
    if (!ok) return;           // on reste sur l'etape : les erreurs sont affichees, la saisie est intacte
  }
  iw.step = target;
  iwRender();
  const body = document.getElementById("iw-body");
  if (body) body.scrollTop = 0;
}

async function iwFinish() {
  if (iw.dirty) { const ok = await iwSave(); if (!ok) return; }
  const status = iw.installation ? iw.installation.status : "draft";
  showToast(status === "active" ? "Installation enregistrée."
    : (status === "paused" ? "Installation enregistrée. Ce Worker reste en pause."
      : "Installation enregistrée. Elle reste en brouillon tant que vous ne l'activez pas."));
  iwClose();
}

// Etat des outils / de la fiche cote serveur (apres connexion d'un outil par exemple) sans toucher a ce qui est saisi.
async function iwRefreshServerState() {
  if (!iw) return;
  const wid = iw.workerId;
  try {
    const data = await fetchJson(`/api/workers/${encodeURIComponent(wid)}/install-profile`);
    if (!iw || iw.workerId !== wid || data.error) return;
    iw.connectorStatus = data.connectorStatus || {};
    iw.installation = data.installation || iw.installation;
    iw.readiness = data.readiness || iw.readiness;
    iw.catalog = await iwLoadCatalog();
    if (iw.step === 3 || iw.step === 4) iwRender();
  } catch (e) {
    /* non bloquant : l'etat se rafraichira a la prochaine ouverture */
  }
}

// ---------- RENDU ----------

function iwRenderStatusPill() {
  const pill = document.getElementById("iw-status-pill");
  if (!pill) return;
  const status = iw && iw.installation ? iw.installation.status : null;
  pill.className = "iw-status-pill" + (status ? " is-" + status : "");
  pill.textContent = status ? IW_STATUS_LABELS[status] : "Nouveau";
}

function iwRender() {
  if (!iw) return;
  iwRenderStatusPill();
  const steps = document.getElementById("iw-steps");
  steps.innerHTML = IW_STEP_LABELS.map((label, i) => {
    const cls = i === iw.step ? "is-current" : (i < iw.step ? "is-done" : "");
    return `<li class="iw-step-item ${cls}"><button type="button" class="iw-step-btn" data-step="${i}" aria-label="${escapeHtml(iwTf("Étape {n} : {label}", { n: i + 1, label: iwT(label) }))}"${i === iw.step ? ' aria-current="step"' : ""}><span class="iw-step-num" aria-hidden="true">${i + 1}</span><span class="iw-step-label">${escapeHtml(label)}</span></button></li>`;
  }).join("");
  steps.querySelectorAll(".iw-step-btn").forEach((b) => b.addEventListener("click", () => iwGo(Number(b.dataset.step))));
  document.getElementById("iw-prev").hidden = iw.step === 0;
  document.getElementById("iw-next").textContent = iw.step >= IW_STEP_LABELS.length - 1 ? "Enregistrer et fermer" : "Suivant";
  const body = document.getElementById("iw-body");
  body.innerHTML = '<div class="iw-alert" id="iw-error-summary" role="alert" tabindex="-1" hidden></div><div id="iw-step-content"></div>';
  const content = document.getElementById("iw-step-content");
  [iwRenderServices, iwRenderKnowledge, iwRenderAutonomy, iwRenderTools, iwRenderTrial][iw.step](content);
  if (iw.errors) iwShowErrors();
}

function iwEnabledOrHint(content) {
  content.innerHTML = `<div class="iw-empty"><p>Choisissez d'abord au moins un service à l'étape « Services ».</p>
    <button type="button" class="btn btn-gold" id="iw-back-to-services">Choisir les services</button></div>`;
  content.querySelector("#iw-back-to-services").addEventListener("click", () => { iw.step = 0; iwRender(); });
}

// 1. Services (competences)
function iwRenderServices(content) {
  const p = iw.profile;
  const support = p.channelSupport || {};
  const cards = (p.services || []).map((def, si) => {
    const s = iw.state.services[def.id];
    const tools = iwToolsOf(def);
    const lines = [];
    if (tools.required.length) lines.push(`<span class="iw-meta-key">Outils obligatoires</span><span class="iw-meta-val">${escapeHtml(iwToolNames(tools.required, iw.catalog))}</span>`);
    tools.anyOf.forEach((g) => lines.push(`<span class="iw-meta-key">Au moins un de ces outils</span><span class="iw-meta-val">${escapeHtml(iwToolNames(g, iw.catalog))}</span>`));
    if (tools.optional.length) lines.push(`<span class="iw-meta-key">Outils facultatifs</span><span class="iw-meta-val">${escapeHtml(iwToolNames(tools.optional, iw.catalog))}</span>`);
    if (!lines.length) lines.push('<span class="iw-meta-key">Outils</span><span class="iw-meta-val iw-meta-none">Aucun outil à connecter</span>');
    const chips = iwChannelChips(def, p, iw.liveChannels).map((c) => `<span class="iw-chip${c.soon ? " iw-chip-soon" : ""}">${escapeHtml(c.label)}${c.soon ? ' <em>bientôt</em>' : ""}</span>`).join("");
    return `<label class="iw-service${s.enabled ? " is-on" : ""}" for="iw-svc-${si}">
      <input type="checkbox" id="iw-svc-${si}" data-svc="${escapeHtml(def.id)}" aria-labelledby="iw-st-${si}" aria-describedby="iw-sd-${si}"${s.enabled ? " checked" : ""}>
      <span class="iw-service-main">
        <span class="iw-service-title" id="iw-st-${si}">${escapeHtml(def.label)}</span>
        <span class="iw-service-desc" id="iw-sd-${si}">${escapeHtml(def.description || "")}</span>
        <span class="iw-service-meta">${lines.map((l) => `<span class="iw-meta-line">${l}</span>`).join("")}
          <span class="iw-meta-line"><span class="iw-meta-key">Canaux</span><span class="iw-meta-val iw-chips">${chips}</span></span></span>
      </span>
    </label>`;
  }).join("");
  const planned = (p.plannedCapabilities || []).length
    ? `<details class="iw-planned"><summary>Ce qui n'est pas encore disponible</summary>
        <p>Ces fonctions sont prévues mais ne sont pas construites aujourd'hui : ne comptez pas dessus.</p>
        <ul>${p.plannedCapabilities.map((t) => `<li>${escapeHtml(t)}</li>`).join("")}</ul></details>`
    : "";
  const channelNote = (support.email === "planned" || support.phone === "planned" || support.whatsapp === "planned")
    ? '<p class="iw-note">Aujourd\'hui, ce Worker travaille depuis l\'application et en missions récurrentes. Le numéro de téléphone, WhatsApp et la boîte e-mail pour vos propres clients ne sont pas encore disponibles.</p>' : "";
  content.innerHTML = `
    ${p.tagline ? `<p class="iw-lead">${escapeHtml(p.tagline)}</p>` : ""}
    ${p.idealFor ? `<p class="iw-ideal"><strong>Idéal pour</strong> ${escapeHtml(p.idealFor)}</p>` : ""}
    <h3 class="iw-h">Que voulez-vous confier à ce Worker ?</h3>
    <p class="iw-hint">Cochez les services dont vous avez besoin. Vous pourrez en ajouter ou en retirer plus tard.</p>
    ${channelNote}
    <div class="iw-services">${cards}</div>
    ${planned}`;
  content.querySelectorAll(".iw-service input").forEach((box) => box.addEventListener("change", () => {
    iw.state.services[box.dataset.svc].enabled = box.checked;
    box.closest(".iw-service").classList.toggle("is-on", box.checked);
    iwMarkDirty();
  }));
}

// 2. Fiche de connaissances
function iwRenderKnowledge(content) {
  const defs = iwEnabledDefs(iw.profile, iw.state);
  if (!defs.length) { iwEnabledOrHint(content); return; }
  const secretNote = '<p class="iw-note iw-note-warn">Ne saisissez jamais de mot de passe, de clé d\'API, de numéro de carte ni d\'IBAN : la fiche les refuse. Les outils se connectent à l\'étape « Outils ».</p>';
  const sections = defs.map((def) => {
    const si = (iw.profile.services || []).indexOf(def);
    const s = iw.state.services[def.id];
    const fields = (def.knowledgeFields || []).map((f, fi) => {
      const id = `iw-k-${si}-${fi}`;
      const value = s.knowledge[f.key] || "";
      const rows = (f.example || "").length > 90 ? 3 : 2;
      const donor = !value.trim() ? defs.find((o) => o.id !== def.id && String(iw.state.services[o.id].knowledge[f.key] || "").trim()) : null;
      return `<div class="iw-field">
        <label class="iw-label" for="${id}"><span>${escapeHtml(f.label)}</span> ${f.required ? '<span class="iw-req">obligatoire</span>' : '<span class="iw-opt">facultatif</span>'}</label>
        ${f.help ? `<div class="iw-help" id="${id}-h">${escapeHtml(f.help)}</div>` : ""}
        <textarea id="${id}" rows="${rows}" maxlength="${IW_FIELD_MAX}" data-svc="${escapeHtml(def.id)}" data-key="${escapeHtml(f.key)}"${f.required ? ' aria-required="true"' : ""} aria-describedby="${id}-h ${id}-e" placeholder="${escapeHtml(f.example ? "Ex : " + f.example : "")}">${escapeHtml(value)}</textarea>
        <div class="iw-field-err" id="${id}-e" data-err-for="${escapeHtml(def.id + "." + f.key)}" role="alert" hidden></div>
        ${donor ? `<button type="button" class="iw-link iw-copy" data-copy-from="${escapeHtml(donor.id)}" data-svc="${escapeHtml(def.id)}" data-key="${escapeHtml(f.key)}" data-target="${id}">Reprendre ce que vous avez écrit pour <em>${escapeHtml(donor.label)}</em></button>` : ""}
      </div>`;
    }).join("");
    return `<section class="iw-svc" aria-labelledby="iw-svc-t-${si}">
      <h3 class="iw-svc-title" id="iw-svc-t-${si}">${escapeHtml(def.label)}</h3>
      <div class="iw-prog" data-prog-for="${escapeHtml(def.id)}"></div>
      ${fields}
    </section>`;
  }).join("");
  content.innerHTML = `
    <h3 class="iw-h">Dites au Worker ce qu'il doit savoir de votre entreprise</h3>
    <p class="iw-hint">Plus la fiche est précise, plus le travail est juste. Seuls les champs marqués « obligatoire » sont indispensables pour activer.</p>
    ${secretNote}
    ${sections}
    <section class="iw-svc">
      <h3 class="iw-svc-title">Consignes générales</h3>
      <div class="iw-field">
        <label class="iw-label" for="iw-notes"><span>Autre chose à respecter ou à savoir</span> <span class="iw-opt">facultatif</span></label>
        <textarea id="iw-notes" rows="3" maxlength="${IW_FIELD_MAX}" aria-describedby="iw-notes-e">${escapeHtml(iw.state.notes)}</textarea>
        <div class="iw-field-err" id="iw-notes-e" data-err-for="notes" role="alert" hidden></div>
      </div>
    </section>`;
  const updateProgress = () => {
    defs.forEach((def) => {
      const el = content.querySelector(`[data-prog-for="${CSS.escape(def.id)}"]`);
      if (!el) return;
      const req = (def.knowledgeFields || []).filter((f) => f.required);
      const done = req.filter((f) => String(iw.state.services[def.id].knowledge[f.key] || "").trim()).length;
      el.innerHTML = req.length ? `<span class="iw-prog-n${done === req.length ? " is-done" : ""}">${done}/${req.length}</span> <span>champs obligatoires remplis</span>` : "<span>Aucun champ obligatoire</span>";
    });
  };
  updateProgress();
  content.querySelectorAll("textarea[data-key]").forEach((ta) => ta.addEventListener("input", () => {
    iw.state.services[ta.dataset.svc].knowledge[ta.dataset.key] = ta.value;
    ta.removeAttribute("aria-invalid");
    const err = document.getElementById(ta.id + "-e");
    if (err) { err.hidden = true; err.textContent = ""; }
    iwMarkDirty();
    updateProgress();
  }));
  content.querySelector("#iw-notes").addEventListener("input", (e) => { iw.state.notes = e.target.value; iwMarkDirty(); });
  content.querySelectorAll(".iw-copy").forEach((b) => b.addEventListener("click", () => {
    const from = iw.state.services[b.dataset.copyFrom].knowledge[b.dataset.key] || "";
    iw.state.services[b.dataset.svc].knowledge[b.dataset.key] = from;
    const ta = document.getElementById(b.dataset.target);
    if (ta) { ta.value = from; ta.focus(); }
    b.remove();
    iwMarkDirty();
    updateProgress();
  }));
}

// 3. Autonomie par categorie d'action
function iwRenderAutonomy(content) {
  const defs = iwEnabledDefs(iw.profile, iw.state);
  if (!defs.length) { iwEnabledOrHint(content); return; }
  const legend = IW_MODES.map((m) => `<li><strong>${escapeHtml(m.label)}</strong><span>${escapeHtml(m.help)}</span></li>`).join("");
  const sections = defs.map((def) => {
    const si = (iw.profile.services || []).indexOf(def);
    const rules = (def.autonomyRules || []).map((rule, ri) => {
      const allowed = iwModesFor(rule);
      const current = iw.state.services[def.id].autonomy[rule.category];
      const cur = allowed.find((m) => m.id === current) || allowed[0];
      const name = `iw-m-${si}-${ri}`;
      const examples = (rule.examples || []).slice(0, 2);
      return `<fieldset class="iw-rule" data-svc="${escapeHtml(def.id)}" data-cat="${escapeHtml(rule.category)}">
        <legend><span class="iw-rule-label">${escapeHtml(rule.label)}</span> <span class="iw-risk iw-risk-${escapeHtml(rule.risk || "high")}">${escapeHtml(IW_RISK[rule.risk] || IW_RISK.high)}</span></legend>
        ${examples.length ? `<ul class="iw-examples">${examples.map((t) => `<li>${escapeHtml(t)}</li>`).join("")}</ul>` : ""}
        <div class="iw-modes">${allowed.map((m) => `<label class="iw-mode"><input type="radio" name="${name}" value="${m.id}"${m.id === cur.id ? " checked" : ""}><span>${escapeHtml(m.label)}</span></label>`).join("")}</div>
        <div class="iw-mode-help" aria-live="polite">${escapeHtml(cur.help)}</div>
        ${rule.risk === "low" ? "" : '<div class="iw-mode-lock">Cette action demande toujours votre validation : « Autonome » n\'est pas proposé.</div>'}
        <div class="iw-field-err" data-err-for="${escapeHtml(def.id + "." + rule.category)}" role="alert" hidden></div>
      </fieldset>`;
    }).join("");
    return `<section class="iw-svc" aria-labelledby="iw-au-t-${si}"><h3 class="iw-svc-title" id="iw-au-t-${si}">${escapeHtml(def.label)}</h3>${rules || '<p class="iw-hint">Aucun réglage pour ce service.</p>'}</section>`;
  }).join("");
  content.innerHTML = `
    <h3 class="iw-h">Quelles consignes donner au Worker ?</h3>
    <div class="iw-law" role="note"><strong>Règle de la plateforme :</strong> envoyer, publier, payer, supprimer et appeler demandent toujours votre validation, quel que soit le réglage choisi. « Autonome » n'est proposé que pour des actions sans risque, comme lire, analyser ou rédiger.</div>
    <p class="iw-hint">Ces réglages sont des consignes que le Worker suit dans son travail. Elles ne remplacent pas la validation que la plateforme exige pour agir vers l'extérieur.</p>
    <ul class="iw-legend">${legend}</ul>
    ${sections}`;
  content.querySelectorAll(".iw-rule").forEach((fs) => fs.addEventListener("change", (e) => {
    if (!e.target.matches("input[type='radio']")) return;
    iw.state.services[fs.dataset.svc].autonomy[fs.dataset.cat] = e.target.value;
    const mode = IW_MODES.find((m) => m.id === e.target.value);
    fs.querySelector(".iw-mode-help").textContent = mode ? mode.help : "";
    const err = fs.querySelector(".iw-field-err");
    if (err) { err.hidden = true; err.textContent = ""; }
    iwMarkDirty();
  }));
}

// 4. Outils : connectes ou manquants, avec le flux de connexion existant (formulaire guide / « Se connecter avec ... »)
function iwToolRows() {
  const rows = new Map();
  const add = (cid, role, svcLabel) => {
    const r = rows.get(cid) || { cid, roles: [] };
    r.roles.push({ role, svc: svcLabel });
    rows.set(cid, r);
  };
  iwEnabledDefs(iw.profile, iw.state).forEach((d) => {
    const t = iwToolsOf(d);
    t.required.forEach((cid) => add(cid, "required", d.label));
    t.anyOf.forEach((g) => g.forEach((cid) => add(cid, "any", d.label)));
    t.optional.forEach((cid) => add(cid, "optional", d.label));
  });
  return Array.from(rows.values());
}

function iwRenderTools(content) {
  const defs = iwEnabledDefs(iw.profile, iw.state);
  if (!defs.length) { iwEnabledOrHint(content); return; }
  const rows = iwToolRows();
  if (!rows.length) {
    content.innerHTML = `<h3 class="iw-h">Outils</h3><div class="iw-empty"><p>Les services choisis n'ont besoin d'aucun outil à connecter : ils travaillent depuis l'application. Vous pouvez passer à l'essai.</p></div>`;
    return;
  }
  const roleText = { required: "obligatoire", any: "au choix, au moins un", optional: "facultatif" };
  const html = rows.map((row, i) => {
    const c = iw.catalog[row.cid];
    const state = iw.connectorStatus[row.cid];
    const name = iwToolName(row.cid, iw.catalog);
    const cat = c ? (CONNECTOR_CATEGORY_LABELS[c.category] || humanizeTag(c.category || "")) : "";
    const best = row.roles.some((r) => r.role === "required") ? "required" : (row.roles.some((r) => r.role === "any") ? "any" : "optional");
    const who = Array.from(new Set(row.roles.map((r) => r.svc))).join(" · ");
    let stateHtml;
    if (state === true) stateHtml = '<span class="cstate on">Connecté</span>';
    else if (state === null || state === undefined) stateHtml = '<span class="cstate">Non vérifiable pour ce compte</span>';
    else stateHtml = '<span class="cstate off">Non connecté</span>';
    let actions = "";
    if (!c || !c.realIntegration) {
      stateHtml = '<span class="cstate soon">Bientôt</span>';
    } else if (state === true) {
      if (c.connectGuide) actions = `<button type="button" class="iw-link" data-tool-guide="${i}">Modifier la connexion</button>`;
    } else if (c.oauthProvider) {
      const v = OAUTH_VENDOR_UI[c.oauthProvider] || { label: brandName(c.provider), svg: "" };
      actions = `<button type="button" class="connector-oauth-btn" data-tool-oauth="${i}">${v.svg}<span>Se connecter avec ${escapeHtml(v.label)}</span></button>`;
      if (c.connectGuide) actions += `<button type="button" class="iw-link" data-tool-guide="${i}">Connexion manuelle</button>`;
    } else if (c.connectGuide) {
      actions = `<button type="button" class="connector-primary-btn" data-tool-guide="${i}">Connecter</button>`;
    } else if (!c.clientCanConfigure) {
      stateHtml = '<span class="cstate soon">Connexion en préparation</span>';
    }
    return `<li class="iw-tool">
      <div class="iw-tool-main">
        <div class="iw-tool-name">${escapeHtml(name)}${cat ? ` <span class="iw-tool-cat">${escapeHtml(cat)}</span>` : ""}</div>
        <div class="iw-tool-role iw-role-${best}">${escapeHtml(roleText[best])}</div>
        <div class="iw-tool-who">${escapeHtml(who)}</div>
        ${stateHtml}
      </div>
      <div class="iw-tool-actions">${actions}</div>
    </li>`;
  }).join("");
  content.innerHTML = `
    <h3 class="iw-h">Les outils dont le Worker a besoin</h3>
    <p class="iw-hint">Connectez ce que vous utilisez déjà. Un outil facultatif non connecté n'empêche pas d'activer : le Worker prépare alors le travail dans la conversation et en fichiers.</p>
    <p class="iw-note">Vos accès sont chiffrés et jamais réaffichés. Vous pouvez déconnecter un outil à tout moment depuis la page Automatisations.</p>
    <ul class="iw-tools">${html}</ul>
    <p class="iw-hint"><button type="button" class="iw-link" id="iw-open-tools-page">Gérer tous mes outils connectés</button></p>`;
  const openGuide = (i, opener) => {
    const c = iw.catalog[rows[i].cid];
    if (!c || !c.connectGuide) return;
    openGuidedConnectForm(null, c);
    // A la fermeture de la fenetre « Connecter », le clavier retrouve sa place dans l'assistant (sinon le focus tombe sur la page).
    const watcher = new MutationObserver(() => {
      if (document.querySelector(".cg-overlay")) return;
      watcher.disconnect();
      const target = document.contains(opener) ? opener : document.getElementById("iw-title");
      if (iw && target && (!document.activeElement || document.activeElement === document.body)) target.focus();
    });
    watcher.observe(document.body, { childList: true });
  };
  content.querySelectorAll("[data-tool-guide]").forEach((b) => b.addEventListener("click", () => openGuide(Number(b.dataset.toolGuide), b)));
  content.querySelectorAll("[data-tool-oauth]").forEach((b) => b.addEventListener("click", async () => {
    const c = iw.catalog[rows[Number(b.dataset.toolOauth)].cid];
    if (!c) return;
    // La connexion en un clic quitte la page : on enregistre le brouillon et on retiendra ou revenir (voir handleOauthReturn).
    b.disabled = true;
    if (iw.dirty) { const ok = await iwSave(); if (!ok) { b.disabled = false; return; } }
    try { sessionStorage.setItem(IW_RETURN_KEY, JSON.stringify({ workerId: iw.workerId, step: 3 })); } catch (e) { /* retour direct sur la page Automatisations */ }
    window.location.href = "/oauth/" + encodeURIComponent(c.oauthProvider) + "/start?provider=" + encodeURIComponent(c.credentialProvider);
  }));
  const toolsPage = content.querySelector("#iw-open-tools-page");
  if (toolsPage) toolsPage.addEventListener("click", async () => { const ok = iw.dirty ? await iwSave() : true; if (ok) { await iwClose(); showView("automations"); } });
}

// 5. Essai a blanc, puis activation
function iwMissingHtml(items, serverStrings) {
  if (!items.length && serverStrings && serverStrings.length) return `<ul class="iw-missing">${serverStrings.map((t) => `<li>${escapeHtml(t)}</li>`).join("")}</ul>`;
  if (!items.length) return "";
  return `<ul class="iw-missing">${items.map((m) => {
    if (m.kind === "service") return "<li>Choisissez au moins un service.</li>";
    if (m.kind === "field") return `<li><strong>${escapeHtml(m.svc)}</strong><span>${escapeHtml(m.what)}</span><em>champ obligatoire à remplir</em></li>`;
    return `<li><strong>${escapeHtml(m.svc)}</strong><span>${escapeHtml(iwToolNames(m.tools, iw.catalog))}</span><em>${m.any ? "connectez au moins un de ces outils" : "outil à connecter"}</em></li>`;
  }).join("")}</ul>`;
}

function iwRenderTrial(content) {
  const defs = iwEnabledDefs(iw.profile, iw.state);
  if (!defs.length) { iwEnabledOrHint(content); return; }
  const status = iw.installation ? iw.installation.status : null;
  if (!iw.trialServiceId || !defs.some((d) => d.id === iw.trialServiceId)) iw.trialServiceId = defs[0].id;
  const def = defs.find((d) => d.id === iw.trialServiceId);
  const scenario = def.testScenario || {};
  const missing = iwMissing(iw.profile, iw.state, iw.connectorStatus);
  const fieldsMissingForTrial = missing.filter((m) => m.kind === "field" && m.svcId === def.id);
  const options = defs.map((d) => `<option value="${escapeHtml(d.id)}"${d.id === def.id ? " selected" : ""}>${escapeHtml(d.label)}</option>`).join("");
  const paused = status === "paused";
  // L'essai est une vraie mission au niveau choisi pour vos missions : on dit combien de credits il consomme.
  const trialLevel = (missionLevels.levels || []).find((l) => l.id === currentMissionLevel());
  const trialCost = trialLevel ? `<p class="iw-hint">${escapeHtml(iwTf("Cet essai sera lancé au niveau {level} : {n} crédit(s) de votre quota.", { level: trialLevel.label, n: trialLevel.credits }))}</p>` : "";
  content.innerHTML = `
    <h3 class="iw-h">Essai à blanc</h3>
    <p class="iw-hint">Avant d'activer, le Worker traite un exercice avec votre fiche. C'est une vraie mission : elle compte dans votre quota comme une mission normale. Le Worker prépare le travail ; toute action vers l'extérieur reste à valider par vous.</p>
    ${trialCost}
    ${paused ? '<div class="iw-alert iw-alert-info">L\'installation est en pause : sa fiche n\'est pas transmise au Worker. Pour faire l\'essai, levez la pause : l\'installation repasse en brouillon et le Worker peut de nouveau agir de lui-même.</div>' : ""}
    <div class="iw-field">
      <label class="iw-label" for="iw-trial-svc"><span>Service à essayer</span></label>
      <select id="iw-trial-svc">${options}</select>
    </div>
    ${scenario.objective ? `<div class="iw-scenario"><div class="iw-scenario-title">Demande envoyée au Worker</div><blockquote>${escapeHtml(scenario.objective)}</blockquote></div>` : '<p class="iw-hint">Ce service n\'a pas de scénario d\'essai prévu.</p>'}
    ${(scenario.expectedChecks || []).length ? `<div class="iw-checks"><div class="iw-scenario-title">Ce que vous devez vérifier dans la réponse</div><ul>${scenario.expectedChecks.map((t) => `<li>${escapeHtml(t)}</li>`).join("")}</ul></div>` : ""}
    ${fieldsMissingForTrial.length ? `<div class="iw-alert iw-alert-info">Remplissez d'abord les champs obligatoires de ce service (étape « Fiche »), sinon l'essai ne vous dira rien d'utile.</div>` : ""}
    <div class="iw-trial-actions">
      <button type="button" class="btn btn-gold" id="iw-trial-run"${scenario.objective && !fieldsMissingForTrial.length && !paused ? "" : " disabled"}>Lancer l'essai à blanc</button>
      ${paused ? '<button type="button" class="btn btn-ghost" id="iw-to-draft">Lever la pause (repasser en brouillon)</button>' : ""}
    </div>
    <div id="iw-trial-result" class="iw-trial-result" aria-live="polite"></div>

    <h3 class="iw-h iw-h-act">Activation</h3>
    <div id="iw-activation"></div>`;
  content.querySelector("#iw-trial-svc").addEventListener("change", (e) => { iw.trialServiceId = e.target.value; iwRender(); });
  const runBtn = content.querySelector("#iw-trial-run");
  if (runBtn) runBtn.addEventListener("click", iwRunTrial);
  const draftBtn = content.querySelector("#iw-to-draft");
  if (draftBtn) draftBtn.addEventListener("click", () => iwChangeStatus("draft"));
  iwRenderActivation();
}

function iwRenderActivation() {
  const el = document.getElementById("iw-activation");
  if (!el || !iw) return;
  const status = iw.installation ? iw.installation.status : null;
  const missing = iwMissing(iw.profile, iw.state, iw.connectorStatus);
  const sum = iwAutonomySummary(iw.profile, iw.state);
  const recap = `<ul class="iw-recap">
      <li><strong>${iwEnabledDefs(iw.profile, iw.state).length}</strong> <span>service(s) choisi(s)</span></li>
      <li><strong>${sum.auto}</strong> <span>action(s) sans risque que le Worker a pour consigne de faire seul</span></li>
      <li><strong>${sum.draft + sum.ask}</strong> <span>action(s) qu'il a pour consigne de préparer ou de demander avant de continuer</span></li>
      <li><strong>${sum.off}</strong> <span>action(s) qu'il a pour consigne de ne jamais faire</span></li>
    </ul>
    <p class="iw-note">Envoyer, publier, payer, supprimer et appeler restent toujours soumis à votre validation. Vous pouvez mettre ce Worker en pause à tout moment : depuis cette fenêtre, depuis sa fiche ou depuis la page Facturation.</p>`;
  if (status === "active") {
    el.innerHTML = `<div class="iw-alert iw-alert-ok"><strong>Ce Worker est actif</strong> avec cette installation.${iw.installation.installedAtUtc ? ` <span class="iw-since">Depuis le ${escapeHtml(iwDate(iw.installation.installedAtUtc))}.</span>` : ""}</div>
      ${recap}
      <div class="iw-trial-actions"><button type="button" class="btn btn-ghost" id="iw-pause">Mettre en pause</button></div>
      <div class="iw-field-err" id="iw-act-err" role="alert" hidden></div>`;
    el.querySelector("#iw-pause").addEventListener("click", () => iwChangeStatus("paused"));
    return;
  }
  const blockers = iwMissingHtml(missing, missing.length ? [] : (iw.readiness || []));
  el.innerHTML = `${recap}
    ${blockers ? `<div class="iw-alert iw-alert-info"><div class="iw-alert-title">Il manque encore, avant de pouvoir activer :</div>${blockers}</div>` : ""}
    <div class="iw-trial-actions">
      <button type="button" class="btn btn-gold" id="iw-activate"${blockers ? " disabled" : ""}>${status === "paused" ? "Réactiver ce Worker" : "Activer ce Worker"}</button>
    </div>
    <div class="iw-field-err" id="iw-act-err" role="alert" hidden></div>`;
  el.querySelector("#iw-activate").addEventListener("click", iwActivate);
}

async function iwRunTrial() {
  if (!iw || iw.trialRunning) return;
  const defs = iwEnabledDefs(iw.profile, iw.state);
  const def = defs.find((d) => d.id === iw.trialServiceId);
  const objective = def && def.testScenario && def.testScenario.objective;
  const out = document.getElementById("iw-trial-result");
  const btn = document.getElementById("iw-trial-run");
  if (!objective || !out) return;
  iw.trialRunning = true;
  btn.disabled = true;
  const workerId = iw.workerId;
  const name = iw.workerName;
  out.innerHTML = `<div class="task-loading"><span></span><span></span><span></span></div><p class="task-loading-text"><strong>${escapeHtml(name)}</strong> <span>fait l'essai à blanc…</span></p>`;
  // Le Worker doit voir la fiche telle qu'elle est a l'ecran : brouillon enregistre d'abord (jamais d'activation ici).
  const saved = await iwSave();
  if (!iw || iw.workerId !== workerId) return;
  if (!saved) { out.innerHTML = ""; iw.trialRunning = false; btn.disabled = false; return; }
  const outcome = await submitMissionAndWait(workerId, objective).catch((e) => ({ result: { error: "NETWORK", detail: e.message } }));
  if (!iw || iw.workerId !== workerId) return;
  iw.trialRunning = false;
  const box = document.getElementById("iw-trial-result");
  const runBtn = document.getElementById("iw-trial-run");
  if (runBtn) runBtn.disabled = false;
  if (!box) return;
  if (outcome.accountRequired) {
    iwClose({ skipSave: true });
    iwSessionLost(() => openInstallWizard(workerId, 4));
    return;
  }
  if (outcome.timedOut) {
    box.innerHTML = '<div class="iw-alert iw-alert-info">L\'essai prend plus de temps que prévu. Il continue en arrière-plan : son résultat apparaîtra dans l\'activité récente de la fiche du Worker.</div>';
    return;
  }
  const result = outcome.result || {};
  if (result.error === "SUBSCRIPTION_REQUIRED") {
    // Comme toutes les cartes « quota atteint » : le forfait suivant (avec le rythme de paiement du client) en plus du lien vers tous les forfaits.
    const up = result.upgrade && result.upgrade.next && !result.upgrade.next.onQuote ? result.upgrade : null;
    const upgradeBtn = up ? `<button type="button" class="btn btn-gold" id="iw-upgrade-now">${escapeHtml(iwTf("Passer à {name}", { name: up.next.name }))}</button> ` : "";
    box.innerHTML = `<div class="iw-alert iw-alert-warn"><div class="iw-alert-title">Abonnement requis</div><p>${escapeHtml(result.detail || "Votre quota est épuisé.")}</p>${upgradeBtn}<button type="button" class="btn ${up ? "btn-ghost" : "btn-gold"}" id="iw-to-billing">Voir les abonnements</button></div>`;
    box.querySelector("#iw-to-billing").addEventListener("click", async () => { await iwClose(); showView("billing"); });
    const upgradeNow = box.querySelector("#iw-upgrade-now");
    if (upgradeNow) upgradeNow.addEventListener("click", async () => { await iwClose(); showView("billing"); startUpgrade(up); });
    return;
  }
  if (result.error === "WORKER_NOT_INCLUDED") {
    box.innerHTML = `<div class="iw-alert iw-alert-warn"><p>${escapeHtml(result.detail || "Ce Worker ne fait pas partie de votre forfait.")}</p></div>`;
    return;
  }
  if (result.error) {
    box.innerHTML = `<div class="iw-alert iw-alert-warn"><div class="iw-alert-title">L'essai n'a pas abouti</div><p>${escapeHtml(result.detail || result.error)}</p></div>`;
    return;
  }
  const blocked = result.Authorized !== true;
  const answer = result.Result && result.Result.Answer ? result.Result.Answer
    : (result.ExecutionNote || "Aucune réponse enregistrée.");
  box.innerHTML = `<div class="iw-scenario-title">Réponse du Worker</div>
    <div class="chat-msg chat-msg-worker${blocked ? " blocked" : ""}"><div class="status-line">${escapeHtml(blocked ? (result.Reason || result.Status || "Bloqué") : "Exécuté")}</div>${renderAnswer(answer)}</div>
    <p class="iw-hint">Le résultat est conforme à ce que vous attendiez ? Activez le Worker. Sinon, corrigez la fiche (étape « Fiche ») et relancez l'essai.</p>`;
  if (result.Result && Array.isArray(result.Result.Files) && result.Result.Files.length) {
    const files = renderTaskFilesBlock(result.Result.TaskId, result.Result.Files);
    if (files) box.appendChild(files);
  }
  if (result.pendingAction) box.appendChild(renderPendingActionCard(result.pendingAction));
  if (currentWorkerId === workerId) loadActivity(workerId);
}

async function iwActivate() {
  if (!iw) return;
  const btn = document.getElementById("iw-activate");
  const err = document.getElementById("iw-act-err");
  if (btn) btn.disabled = true;
  if (err) { err.hidden = true; err.textContent = ""; }
  const ok = await iwSave();
  if (!ok) { if (btn) btn.disabled = false; return; }
  const left = iwMissing(iw.profile, iw.state, iw.connectorStatus);
  if (left.length || (iw.readiness || []).length) {
    iwRenderActivation();
    return;
  }
  await iwChangeStatus("active");
}

async function iwChangeStatus(status) {
  if (!iw) return;
  const before = iw.installation ? iw.installation.status : null;
  const r = await iwSetStatus(iw.workerId, status);
  if (!iw) return;
  if (r.ok) {
    iw.installation = Object.assign({}, iw.installation || {}, r.installation);
    iw.readiness = r.installation.readiness || [];
    iwRenderStatusPill();
    if (status === "active") showToast("Ce Worker est actif.");
    else if (status === "paused") showToast("Ce Worker est en pause : il n'agit plus de lui-même.");
    // Le resultat de l'essai reste affiche : on ne redessine toute l'etape que si la pause change ce qu'elle propose.
    if ((before === "paused") !== (status === "paused")) iwRender();
    else iwRenderActivation();
    loadInstallPanel(iw.workerId);
    if (!billingView.hidden) loadInstalledWorkers();
    return;
  }
  const err = document.getElementById("iw-act-err");
  const lines = (r.errors && r.errors.length ? r.errors : [r.message]).filter(Boolean);
  if (err) { err.textContent = lines.join(" "); err.hidden = false; }
  else showToast(lines.join(" "), false);
}

// Statut d'une installation (active / paused / draft) : utilise par l'assistant, la fiche du Worker et la page Facturation.
async function iwSetStatus(workerId, status) {
  try {
    const r = await fetchJson("/api/installations/status", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ workerId, status }),
    });
    if (r.error === "ACCOUNT_REQUIRED") return { ok: false, message: "Connectez-vous pour continuer." };
    if (r.ok && r.installation) return { ok: true, installation: r.installation };
    return { ok: false, code: r.error, message: r.detail || r.error || "Changement impossible pour le moment.", errors: r.errors || r.readiness || [] };
  } catch (e) {
    return { ok: false, message: e.message || "Changement impossible pour le moment." };
  }
}


// ---------- MISSION : meme chemin que la fiche du Worker (POST .../async puis interrogation toutes les 2 s) ----------

// Lance une mission en arriere-plan et attend son resultat. Renvoie { result } (resultat final ou erreur), { accountRequired: true } ou { timedOut: true }.
// Utilise par la fiche (runTask) et par l'essai a blanc de l'assistant : une seule facon de faire, un seul garde-fou serveur.
async function submitMissionAndWait(workerId, objective) {
  const endpoint = workerId === "chloe" ? "/api/chloe/task" : `/api/workers/${workerId}/task`;
  const started = await fetchJson(endpoint + "/async", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ objective, level: currentMissionLevel() }),
  });
  if (started.error === "ACCOUNT_REQUIRED") return { accountRequired: true };
  if (started.error || !started.jobId) {
    // Garde refusee en amont (compte, abonnement, Worker non embauche, objectif...) : c'est le resultat, rendu comme d'habitude.
    return { result: started };
  }
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
    if (job.error === "ACCOUNT_REQUIRED") return { accountRequired: true };
    if (job.error) return { result: job };
    if (job.status === "DONE") return { result: job.result || {} };
    if (job.status === "ERROR") {
      // Worker non embauche (verifie une seconde fois par le job) : l'interface propose alors d'embaucher, pas un message technique.
      if (job.errorCode === "WORKER_NOT_INCLUDED") return { result: { error: "WORKER_NOT_INCLUDED", detail: job.error, workerId } };
      return { result: { error: "SUBMIT_EXCEPTION", detail: job.error } };
    }
  }
  return { timedOut: true };
}

// ---------- FICHE DU WORKER : panneau « Installer » (Worker du forfait) ou « Embaucher » (Worker hors forfait) ----------

function iwStatusPill(status) {
  return `<span class="iw-status-pill is-${escapeHtml(status)}">${escapeHtml(IW_STATUS_LABELS[status] || status)}</span>`;
}

function iwServiceChips(rec) {
  const labels = Object.values((rec && rec.services) || {}).filter((s) => s.enabled).map((s) => s.label);
  if (!labels.length) return '<span class="iw-meta-none">Aucun service choisi</span>';
  return labels.map((l) => `<span class="iw-chip">${escapeHtml(l)}</span>`).join("");
}

// Interrupteur d'arret (kill switch) : coche = en marche ; decocher = pause immediate. Offert pour TOUT statut : un brouillon recoit la fiche et ses
// automatisations tournent, il doit donc pouvoir etre arrete lui aussi. La reprise remet l'installation la ou la pause l'a prise (pausedFrom : brouillon
// ou actif). Utilise sur la fiche du Worker et dans Facturation.
function iwPauseSwitchEl(rec, workerName, opts) {
  const label = document.createElement("label");
  label.className = "switch iw-pause";
  label.title = "Interrupteur d'arrêt : met ce Worker en pause tout de suite";
  let current = rec;
  const running = rec.status !== "paused";
  const blocked = !running && rec.entitled === false;
  label.innerHTML = `<input type="checkbox" role="switch" class="iw-pause-input"${running ? " checked" : ""}${blocked ? " disabled" : ""}><span class="switch-track"></span><span class="iw-sr">${escapeHtml(workerName)} : </span><span class="switch-label iw-pause-text">${IW_RUN_LABELS[rec.status] || IW_RUN_LABELS.paused}</span>`;
  const input = label.querySelector("input");
  input.addEventListener("change", async () => {
    const want = input.checked ? (current.pausedFrom === "draft" ? "draft" : "active") : "paused";
    input.disabled = true;
    const r = await iwSetStatus(rec.workerId, want);
    input.disabled = false;
    if (r.ok) {
      current = Object.assign({}, current, r.installation);
      label.querySelector(".iw-pause-text").textContent = IW_RUN_LABELS[r.installation.status] || IW_RUN_LABELS.paused;
      if (opts && opts.onChange) opts.onChange(r.installation);
      showToast(want === "paused" ? "Ce Worker est en pause : il n'agit plus de lui-même."
        : (want === "draft" ? "Ce Worker n'est plus en pause." : "Ce Worker est de nouveau actif."));
    } else {
      input.checked = !input.checked;                       // l'interrupteur reste fidele a l'etat reel du serveur
      const lines = (r.errors && r.errors.length ? r.errors : [r.message]).filter(Boolean);
      if (opts && opts.onError) opts.onError(lines);
      else showToast(lines.join(" "), false);
    }
  });
  return label;
}

async function loadInstallPanel(workerId) {
  const block = document.getElementById("install-block");
  const panel = document.getElementById("install-panel");
  const title = document.getElementById("install-title");
  if (!block || !panel) return;
  if (!workerId || workerId === "chloe") { block.hidden = true; panel.dataset.rendered = ""; panel.dataset.worker = workerId || ""; return; }       // Chloe n'est ni embauchee ni installee ; une reponse tardive du Worker precedent ne reaffiche rien
  panel.dataset.worker = workerId;
  if (!accountAuthenticated) {
    block.hidden = false;
    panel.dataset.rendered = "";
    title.textContent = "Installer ce Worker";
    panel.innerHTML = `<p class="iw-lead">Installez ce Worker chez vous : choisissez ses services, renseignez votre entreprise, réglez son autonomie et faites un essai avant de l'activer. Rien n'est envoyé ni publié sans votre validation.</p>
      <button type="button" class="btn btn-gold" id="iw-guest-btn">Créer mon compte ou me connecter</button>`;
    panel.querySelector("#iw-guest-btn").addEventListener("click", () => requireAccount(() => loadInstallPanel(workerId)));
    return;
  }
  let data;
  let hired;
  // Une autre fiche que celle deja affichee : on ne laisse jamais le panneau du Worker precedent pendant le chargement.
  if (panel.dataset.rendered !== workerId) {
    block.hidden = false;
    title.textContent = "Installer ce Worker";
    panel.innerHTML = '<p class="iw-hint">Chargement…</p>';
  }
  try {
    [data, hired] = await Promise.all([fetchJson(`/api/workers/${encodeURIComponent(workerId)}/install-profile`), fetchJson("/api/workers/hired")]);
  } catch (e) {
    if (panel.dataset.worker !== workerId) return;
    block.hidden = false;
    panel.innerHTML = `<p class="iw-note">${escapeHtml(e.message || "Chargement impossible.")}</p><button type="button" class="btn btn-ghost" id="iw-retry-btn">Réessayer</button>`;
    panel.querySelector("#iw-retry-btn").addEventListener("click", () => loadInstallPanel(workerId));
    return;
  }
  if (panel.dataset.worker !== workerId) return;       // l'utilisateur a ouvert une autre fiche entre-temps
  if (data.error) { block.hidden = true; panel.dataset.rendered = ""; return; }    // Worker sans fiche d'installation (ou session expiree) : rien a proposer
  block.hidden = false;
  panel.dataset.rendered = workerId;
  if (data.entitled) iwRenderInstallPanel(panel, title, workerId, data, hired || {});
  else iwRenderHirePanel(panel, title, workerId, data, hired || {});
}

function iwRenderInstallPanel(panel, title, workerId, data, hired) {
  title.textContent = "Installer ce Worker";
  const rec = data.installation;
  const p = data.profile || {};
  const hire = hired.hire || {};
  let html = p.tagline ? `<p class="iw-lead">${escapeHtml(p.tagline)}</p>` : "";
  if (!rec) {
    html += `<ol class="iw-howto">
        <li>Choisir les services</li><li>Remplir la fiche de votre entreprise</li><li>Régler l'autonomie de chaque action</li><li>Connecter vos outils</li><li>Faire un essai à blanc, puis activer</li></ol>
      <p class="iw-note">Rien n'est activé tant que vous ne l'avez pas décidé. Envoyer, publier, payer, supprimer et appeler demandent toujours votre validation.</p>
      <div class="iw-state-actions"><button type="button" class="btn btn-gold" id="iw-open-btn">Installer ce Worker</button></div>`;
  } else {
    const missing = rec.status !== "active" && (data.readiness || []).length
      ? `<div class="iw-state-line"><span class="iw-meta-key">Il manque encore</span><ul class="iw-missing iw-missing-inline">${data.readiness.map((t) => `<li>${escapeHtml(t)}</li>`).join("")}</ul></div>` : "";
    html += `<div class="iw-state">
        <div class="iw-state-line">${iwStatusPill(rec.status)}${rec.status === "draft" ? '<span class="iw-meta-none">Pas encore activé</span>' : ""}</div>
        <div class="iw-state-line"><span class="iw-meta-key">Services</span><span class="iw-chips">${iwServiceChips(rec)}</span></div>
        <div class="iw-state-line"><span class="iw-meta-key">Dernière modification</span><time>${escapeHtml(iwDate(rec.updatedAtUtc))}</time></div>
        ${missing}
        ${rec.status === "paused" ? '<p class="iw-note">En pause : la fiche n\'est plus transmise au Worker, ses automatisations planifiées sont suspendues (y compris celles de Chloé qui l\'appelleraient) et rien n\'est validé automatiquement. Vos missions lancées à la main fonctionnent toujours.</p>' : ""}
        <div class="iw-state-actions" id="iw-state-actions"></div>
        <div class="iw-field-err" id="iw-panel-err" role="alert" hidden></div>
      </div>`;
  }
  // Un client en essai peut demander a garder ce seul Worker apres l'essai (demande d'embauche, aucun paiement ici).
  const trial = hire.planId === "essai" && !(hired.openRequests || []).includes(workerId);
  if (trial) {
    html += `<details class="iw-keep"><summary>Garder seulement ce Worker après l'essai</summary>
      <p class="iw-note">Pendant l'essai, vous pouvez tester tous les Workers. Pour n'en garder qu'un, envoyez une demande à BK Entreprise.</p>
      <div id="iw-request-slot"></div></details>`;
  } else if (hire.planId === "essai" && (hired.openRequests || []).includes(workerId)) {
    html += '<p class="iw-note iw-note-ok">Votre demande pour garder ce Worker a bien été transmise à BK Entreprise.</p>';
  }
  panel.innerHTML = html;
  const openBtn = panel.querySelector("#iw-open-btn");
  if (openBtn) openBtn.addEventListener("click", () => openInstallWizard(workerId, 0));
  if (rec) {
    const actions = panel.querySelector("#iw-state-actions");
    const err = panel.querySelector("#iw-panel-err");
    // Interrupteur d'arret offert pour tout statut (brouillon, actif, en pause).
    {
      actions.appendChild(iwPauseSwitchEl(Object.assign({ entitled: data.entitled }, rec), data.workerName, {
        onChange: async () => {
          await loadInstallPanel(workerId);
          const sw = document.querySelector("#install-panel .iw-pause-input");      // le panneau est redessine : le clavier retrouve l'interrupteur
          if (sw) sw.focus();
        },
        onError: (lines) => { err.textContent = lines.join(" "); err.hidden = false; },
      }));
    }
    const edit = document.createElement("button");
    edit.type = "button";
    edit.className = "btn btn-ghost";
    edit.id = "iw-open-btn";
    edit.textContent = rec.status === "draft" ? "Poursuivre l'installation" : "Modifier l'installation";
    edit.addEventListener("click", () => openInstallWizard(workerId, 0));
    actions.appendChild(edit);
    const del = document.createElement("button");
    del.type = "button";
    del.className = "iw-link iw-danger";
    del.textContent = "Supprimer cette installation";
    del.addEventListener("click", async () => {
      if (!confirm(iwT("Supprimer cette installation ? La fiche que vous avez remplie pour ce Worker sera effacée. Vous pourrez en refaire une plus tard."))) return;
      del.disabled = true;
      try {
        const r = await fetchJson("/api/installations/delete", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ workerId }) });
        if (r.error) { err.textContent = r.detail || r.error; err.hidden = false; del.disabled = false; return; }
        delete iwMemory[workerId];
        showToast("Installation supprimée.");
        loadInstallPanel(workerId);
        if (!billingView.hidden) loadInstalledWorkers();
      } catch (e) { err.textContent = e.message; err.hidden = false; del.disabled = false; }
    });
    actions.appendChild(del);
  }
  const slot = panel.querySelector("#iw-request-slot");
  if (slot) iwRenderRequestForm(slot, workerId, data.workerName, hired);
}

// Demande d'embauche (POST /api/workers/<id>/hire-request) : une par client et par Worker, message facultatif.
function iwRenderRequestForm(slot, workerId, workerName, hired) {
  if ((hired.openRequests || []).includes(workerId)) {
    slot.innerHTML = '<p class="iw-note iw-note-ok">Votre demande pour ce Worker a bien été transmise à BK Entreprise.</p>';
    return;
  }
  slot.innerHTML = `<div class="iw-field">
      <label class="iw-label" for="iw-req-msg"><span>Message pour BK Entreprise</span> <span class="iw-opt">facultatif</span></label>
      <textarea id="iw-req-msg" rows="2" maxlength="500" aria-describedby="iw-req-e"></textarea>
      <div class="iw-field-err" id="iw-req-e" role="alert" hidden></div>
    </div>
    <button type="button" class="btn btn-ghost" id="iw-req-btn">Envoyer la demande</button>
    <p class="iw-note">Aucun paiement n'est demandé ici et aucun prix n'est affiché : le tarif vous est communiqué avant toute facture.</p>`;
  const btn = slot.querySelector("#iw-req-btn");
  const err = slot.querySelector("#iw-req-e");
  btn.addEventListener("click", async () => {
    btn.disabled = true;
    err.hidden = true;
    try {
      const r = await fetchJson(`/api/workers/${encodeURIComponent(workerId)}/hire-request`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: slot.querySelector("#iw-req-msg").value.trim() }),
      });
      if (r.error === "ACCOUNT_REQUIRED") { btn.disabled = false; iwSessionLost(() => loadInstallPanel(workerId)); return; }
      if (r.error) {
        err.textContent = r.error === "ALREADY_INCLUDED" ? "Ce Worker fait déjà partie de votre forfait. Rechargez la page." : (r.detail || "Demande impossible pour le moment. Réessayez plus tard.");
        err.hidden = false;
        btn.disabled = false;
        return;
      }
      slot.innerHTML = `<p class="iw-note iw-note-ok">${r.alreadyRequested ? "Vous aviez déjà demandé ce Worker : la demande est toujours en attente." : "Demande envoyée."} <span class="iw-ref">Référence</span> <code>${escapeHtml(r.requestId || "")}</code></p>
        <p class="iw-note">Votre demande est transmise à BK Entreprise. Rien n'est débité ici : un Worker n'est ajouté à votre forfait qu'après une facture réglée.</p>`;
    } catch (e) {
      err.textContent = e.message || "Demande impossible pour le moment.";
      err.hidden = false;
      btn.disabled = false;
    }
  });
}

// Worker hors forfait (Solo / Trio) : l'embaucher s'il reste un emplacement, remplacer un Worker (une fois par 30 jours) ou envoyer une demande.
function iwRenderHirePanel(panel, title, workerId, data, hired) {
  title.textContent = "Embaucher ce Worker";
  const hire = hired.hire || {};
  const name = data.workerName || workerNameById(workerId);
  const planName = hired.planName || "";
  const hiredNames = (hire.hiredWorkers || []).map((w) => workerNameById(w));
  const p = data.profile || {};
  let html = p.tagline ? `<p class="iw-lead">${escapeHtml(p.tagline)}</p>` : "";
  html += `<p><strong>${escapeHtml(name)}</strong> <span>ne fait pas partie de votre forfait</span> <strong>(${escapeHtml(planName)})</strong>.</p>`;
  if (hire.workerSlots) {
    html += `<div class="iw-state-line"><span class="iw-meta-key">Emplacements utilisés</span><strong>${(hire.hiredWorkers || []).length} / ${hire.workerSlots}</strong>
      <span class="iw-chips">${hiredNames.map((n) => `<span class="iw-chip">${escapeHtml(n)}</span>`).join("")}</span></div>`;
  }
  html += '<div id="iw-hire-actions"></div><div id="iw-request-slot"></div>';
  panel.innerHTML = html;
  const actions = panel.querySelector("#iw-hire-actions");
  const slot = panel.querySelector("#iw-request-slot");
  const msg = (cls, text) => { const m = document.createElement("div"); m.className = cls; m.setAttribute("role", "alert"); m.textContent = text; return m; };

  const hireNow = async (replaceId, box) => {
    const err = box.querySelector(".iw-field-err");
    box.querySelectorAll("button").forEach((b) => { b.disabled = true; });
    err.hidden = true;
    try {
      const r = await fetchJson("/api/workers/hire", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(replaceId ? { workerId, replaceWorkerId: replaceId } : { workerId }),
      });
      if (r.error === "ACCOUNT_REQUIRED") { iwSessionLost(() => loadInstallPanel(workerId)); return; }
      if (r.error) {
        let text = r.detail || "Embauche impossible pour le moment.";
        if (r.error === "SWAP_COOLDOWN" && r.nextSwapAtUtc) text += " Prochain remplacement possible le " + iwDate(r.nextSwapAtUtc) + ".";
        err.textContent = text;
        err.hidden = false;
        box.querySelectorAll("button").forEach((b) => { b.disabled = false; });
        if (r.error === "NO_SLOT_LEFT" || r.error === "SWAP_COOLDOWN") loadInstallPanel(workerId);
        return;
      }
      showToast(r.replaced ? iwTf("{name} remplace {old} : l'installation de {old} est mise en pause.", { name, old: workerNameById(r.replaced) })
        : iwTf("{name} fait maintenant partie de votre forfait.", { name }));
      await loadInstallPanel(workerId);
      if (!billingView.hidden) loadBilling();
    } catch (e) {
      err.textContent = e.message || "Embauche impossible pour le moment.";
      err.hidden = false;
      box.querySelectorAll("button").forEach((b) => { b.disabled = false; });
    }
  };

  if (hire.slotsLeft > 0) {
    actions.innerHTML = `<p class="iw-note">Embaucher ce Worker utilise un de vos emplacements. Vous pourrez ensuite l'installer et lui confier des missions.</p>
      <div class="iw-confirm" id="iw-hire-box"><button type="button" class="btn btn-gold" id="iw-hire-btn"><span>Embaucher</span> <strong>${escapeHtml(name)}</strong></button>
      <div class="iw-field-err" role="alert" hidden></div></div>`;
    const box = actions.querySelector("#iw-hire-box");
    box.querySelector("#iw-hire-btn").addEventListener("click", () => {
      if (confirm(iwTf("Embaucher {name} ? Il prend l'un de vos emplacements.", { name }))) hireNow(null, box);
    });
  } else if (hire.workerSlots && hire.canSwapNow) {
    actions.innerHTML = `<fieldset class="iw-swap"><legend>Remplacer l'un de vos Workers par celui-ci</legend>
      <p class="iw-note">Le Worker remplacé est mis en pause (son installation est conservée). Un remplacement est possible une fois tous les 30 jours.</p>
      <div class="iw-swap-list">${(hire.hiredWorkers || []).map((w, i) => `<label class="iw-mode"><input type="radio" name="iw-swap" value="${escapeHtml(w)}"${i === 0 ? " checked" : ""}><span>${escapeHtml(workerNameById(w))}</span></label>`).join("")}</div>
      <div class="iw-confirm" id="iw-hire-box"><button type="button" class="btn btn-gold" id="iw-swap-btn"><span>Remplacer et embaucher</span> <strong>${escapeHtml(name)}</strong></button>
      <div class="iw-field-err" role="alert" hidden></div></div></fieldset>`;
    const box = actions.querySelector("#iw-hire-box");
    box.querySelector("#iw-swap-btn").addEventListener("click", () => {
      const sel = actions.querySelector("input[name='iw-swap']:checked");
      if (sel && confirm(iwTf("Remplacer {old} par {name} ? {old} sera mis en pause et vous ne pourrez plus changer de Worker pendant 30 jours.", { name, old: workerNameById(sel.value) }))) hireNow(sel.value, box);
    });
  } else if (hire.workerSlots) {
    actions.appendChild(msg("iw-note", "Tous vos emplacements sont pris et vous avez déjà remplacé un Worker récemment."));
    if (hire.nextSwapAtUtc) {
      const when = document.createElement("p");
      when.className = "iw-note";
      when.innerHTML = `<span>Prochain remplacement possible le</span> <time>${escapeHtml(iwDate(hire.nextSwapAtUtc))}</time>`;
      actions.appendChild(when);
    }
  }
  if (hire.workerSlots && hire.slotsLeft > 0) return;     // un emplacement libre : l'embauche directe suffit
  const intro = document.createElement("h3");
  intro.className = "iw-h iw-h-small";
  intro.textContent = "Besoin d'un autre Worker ou d'un forfait plus large ?";
  slot.parentNode.insertBefore(intro, slot);
  iwRenderRequestForm(slot, workerId, name, hired);
}

// Ouvre la fiche d'un Worker et amene le client sur le panneau « Embaucher » (utilise par les refus de mission).
async function iwGoHire(workerId) {
  if (!workerId || workerId === "chloe") { showView("billing"); return; }
  if (currentWorkerId !== workerId || profileView.hidden) await openWorkerProfile(workerId);
  const block = document.getElementById("install-block");
  if (block && !block.hidden) {
    block.scrollIntoView({ behavior: "smooth", block: "start" });
    const focusable = block.querySelector("button, textarea, input");
    if (focusable) focusable.focus({ preventScroll: true });
  }
}

// Refus 403 WORKER_NOT_INCLUDED d'une mission : le texte du serveur + une action « Embaucher », jamais un message technique.
function iwRenderNotIncluded(responseEl, result, workerId, closeFab) {
  responseEl.className = "chat-msg chat-msg-worker needs-chloe";
  responseEl.innerHTML = `<div class="status-line">Non inclus dans votre forfait</div>
    <p>${escapeHtml(result.detail || "Ce Worker ne fait pas partie de votre forfait.")}</p>
    <div class="iw-notice-actions"></div>`;
  const actions = responseEl.querySelector(".iw-notice-actions");
  const targets = [];
  if (result.workerId && result.workerId !== "chloe") targets.push(result.workerId);
  else if (workerId && workerId !== "chloe") targets.push(workerId);
  (result.notIncludedWorkers || []).forEach((w) => { const id = String(w).toLowerCase(); if (id && id !== "chloe" && !targets.includes(id)) targets.push(id); });
  targets.slice(0, 3).forEach((id) => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "btn btn-gold";
    b.innerHTML = `<span>Embaucher</span> <strong>${escapeHtml(workerNameById(id))}</strong>`;
    b.addEventListener("click", () => { if (closeFab) closeFab(); iwGoHire(id); });
    actions.appendChild(b);
  });
  const plan = document.createElement("button");
  plan.type = "button";
  plan.className = "btn btn-ghost";
  plan.textContent = "Voir mon forfait";
  plan.addEventListener("click", () => { if (closeFab) closeFab(); showView("billing"); });
  actions.appendChild(plan);
}

// ---------- FACTURATION : « Mes Workers installes » avec l'interrupteur de pause ----------

async function loadInstalledWorkers() {
  const section = document.getElementById("installed-workers-section");
  if (!section) return;
  if (!accountAuthenticated) { section.hidden = true; return; }
  const list = document.getElementById("installed-workers-list");
  const summary = document.getElementById("installed-workers-summary");
  let data;
  let hired;
  try {
    [data, hired] = await Promise.all([fetchJson("/api/installations"), fetchJson("/api/workers/hired")]);
  } catch (e) {
    section.hidden = false;
    summary.innerHTML = "";
    list.innerHTML = `<p class="iw-note">${escapeHtml(e.message || "Chargement impossible.")}</p>`;
    return;
  }
  if (data.error) { section.hidden = true; return; }
  section.hidden = false;
  const hire = (hired && hired.hire) || {};
  // Forfait Solo / Trio : combien d'emplacements, quels Workers, quand le prochain remplacement est possible.
  if (hire.restricted) {
    const names = (hire.hiredWorkers || []).map((w) => `<span class="iw-chip">${escapeHtml(workerNameById(w))}</span>`).join("");
    let swap = "";
    if (hire.slotsLeft === 0) {
      swap = hire.canSwapNow
        ? '<span class="iw-meta-line">Un remplacement est possible dès maintenant : ouvrez la fiche du Worker que vous voulez.</span>'
        : (hire.nextSwapAtUtc ? `<span class="iw-meta-line"><span>Prochain remplacement possible le</span> <time>${escapeHtml(iwDate(hire.nextSwapAtUtc))}</time></span>` : "");
    }
    summary.innerHTML = `<div class="iw-state-line"><span class="iw-meta-key">Votre forfait</span><strong>${escapeHtml(hired.planName || "")}</strong></div>
      <div class="iw-state-line"><span class="iw-meta-key">Emplacements utilisés</span><strong>${(hire.hiredWorkers || []).length} / ${hire.workerSlots}</strong><span class="iw-chips">${names}</span></div>
      ${swap ? `<div class="iw-state-line">${swap}</div>` : ""}
      ${hire.chloeIncluded ? "" : '<div class="iw-state-line"><span class="iw-meta-line">Chloé, l\'orchestratrice, n\'est pas incluse dans ce forfait : confiez vos missions directement à vos Workers.</span></div>'}`;
  } else {
    summary.innerHTML = "";
  }
  const items = data.installations || [];
  if (!items.length) {
    list.innerHTML = `<div class="iw-empty"><p>Aucun Worker installé pour le moment. Ouvrez la fiche d'un Worker et choisissez « Installer ce Worker » pour commencer.</p>
      <button type="button" class="btn btn-gold" id="iw-to-catalog">Voir les Workers</button></div>`;
    list.querySelector("#iw-to-catalog").addEventListener("click", () => showView("workers"));
    return;
  }
  list.innerHTML = "";
  items.forEach((rec) => {
    const worker = allWorkers.find((x) => x.id === rec.workerId);
    const name = rec.workerName || (worker ? worker.name : rec.workerId);
    const card = document.createElement("article");
    card.className = "iw-card";
    card.innerHTML = `${worker && worker.portraitUrl ? `<img class="iw-card-portrait" src="${escapeHtml(worker.portraitUrl)}" alt="">` : ""}
      <div class="iw-card-main">
        <div class="iw-card-head"><h3 class="iw-card-name">${escapeHtml(name)}</h3>${iwStatusPill(rec.status)}${rec.entitled === false ? '<span class="iw-badge-warn">Hors forfait</span>' : ""}</div>
        <div class="iw-state-line"><span class="iw-meta-key">Services</span><span class="iw-chips">${iwServiceChips(rec)}</span></div>
        <div class="iw-state-line"><span class="iw-meta-key">Dernière modification</span><time>${escapeHtml(iwDate(rec.updatedAtUtc))}</time></div>
        ${rec.status === "draft" ? '<div class="iw-state-line"><span class="iw-meta-none">Pas encore activé</span></div>' : ""}
        <div class="iw-field-err iw-card-msg" role="alert" hidden></div>
      </div>
      <div class="iw-card-actions"></div>`;
    const actions = card.querySelector(".iw-card-actions");
    const msg = card.querySelector(".iw-card-msg");
    // Interrupteur d'arret offert pour tout statut (brouillon, actif, en pause).
    {
      actions.appendChild(iwPauseSwitchEl(rec, name, {
        onChange: (updated) => {
          // Mise a jour sur place (pas de redessin) : le focus reste sur l'interrupteur.
          const pill = card.querySelector(".iw-status-pill");
          pill.className = "iw-status-pill is-" + updated.status;
          pill.textContent = IW_STATUS_LABELS[updated.status] || updated.status;
          const when = card.querySelector("time");
          if (when) when.textContent = iwDate(updated.updatedAtUtc);
          msg.hidden = true;
        },
        onError: (lines) => { msg.innerHTML = `<span>${escapeHtml(lines.join(" "))}</span> <span>Ouvrez l'installation pour terminer.</span>`; msg.hidden = false; },
      }));
    }
    const open = document.createElement("button");
    open.type = "button";
    open.className = "btn btn-ghost";
    open.textContent = rec.status === "draft" ? "Poursuivre" : "Ouvrir";
    open.addEventListener("click", async () => {
      await openWorkerProfile(rec.workerId);
      const block = document.getElementById("install-block");
      if (block && !block.hidden) block.scrollIntoView({ behavior: "smooth", block: "start" });
    });
    actions.appendChild(open);
    list.appendChild(card);
  });
}

// ---------- RETOUR D'UNE CONNEXION « Se connecter avec ... » : on revient dans l'assistant, a l'etape Outils ----------

async function iwResumeAfterOauth() {
  let saved = null;
  try {
    saved = JSON.parse(sessionStorage.getItem(IW_RETURN_KEY) || "null");
    sessionStorage.removeItem(IW_RETURN_KEY);
  } catch (e) { saved = null; }
  if (!saved || !saved.workerId || !accountAuthenticated) return;
  await openWorkerProfile(saved.workerId);
  openInstallWizard(saved.workerId, saved.step || 3);
}

// ---------- PROPRIETAIRE : demandes d'embauche et attribution des Workers apres facture reglee ----------

let adminClientsCache = [];

function renderAdminHireRequests(requests) {
  const list = document.getElementById("admin-hire-list");
  if (!list) return;
  const rows = Array.isArray(requests) ? requests : [];
  if (!rows.length) { list.innerHTML = '<div class="activity-empty">Aucune demande d\'embauche en attente.</div>'; return; }
  list.innerHTML = rows.map((r, i) => `<div class="admin-activity-row iw-hire-row">
      <span class="admin-activity-when">${escapeHtml(r.createdAtUtc ? new Date(r.createdAtUtc).toLocaleString(BK_LOCALE()) : "")}</span>
      <span class="admin-activity-kind">${escapeHtml(r.workerName || r.workerId || "")}</span>
      <span class="admin-activity-who">${escapeHtml(r.clientLabel || r.clientId || "")}</span>
      <span class="admin-activity-text">${r.message ? escapeHtml(r.message) : '<em class="iw-meta-none">sans message</em>'} <button type="button" class="btn-small iw-grant-btn" data-i="${i}">Attribuer</button></span>
    </div>`).join("");
  list.querySelectorAll(".iw-grant-btn").forEach((b) => b.addEventListener("click", () => {
    const r = rows[Number(b.dataset.i)];
    openGrantForm(r.clientId, r.clientLabel || r.clientId, r.workerId);
  }));
}

// Formulaire d'attribution (POST /api/admin/grant-workers). Le proprietaire confirme lui-meme que la facture est reglee : rien n'est facture ici.
function openGrantForm(clientId, clientLabel, presetWorker) {
  const card = document.getElementById("admin-grant-card");
  if (!card) return;
  const client = adminClientsCache.find((c) => c.clientId === clientId) || {};
  const current = Array.isArray(client.hiredWorkers) ? client.hiredWorkers : [];
  const chosen = new Set(current);
  if (presetWorker) chosen.add(presetWorker);
  const planGuess = chosen.size > 1 || client.workerSlots === 3 ? "trio" : "solo";
  const workers = allWorkers.filter((w) => w.id !== "chloe");
  card.hidden = false;
  card.innerHTML = `<h3 class="iw-h iw-h-small">Attribuer des Workers à <span>${escapeHtml(clientLabel)}</span></h3>
    <p class="iw-note">Le client est <code>${escapeHtml(clientId)}</code>. Cette liste remplace celle du client ; les installations des Workers retirés sont mises en pause.</p>
    <div class="iw-field"><label class="iw-label" for="iw-grant-plan"><span>Forfait</span></label>
      <select id="iw-grant-plan"><option value="solo"${planGuess === "solo" ? " selected" : ""}>Solo : 1 Worker au choix</option><option value="trio"${planGuess === "trio" ? " selected" : ""}>Trio : 3 Workers au choix, Chloé incluse</option></select></div>
    <fieldset class="iw-grant-workers"><legend>Workers du forfait <span class="iw-grant-count"></span></legend>
      ${workers.map((w) => `<label class="iw-mode"><input type="checkbox" value="${escapeHtml(w.id)}"${chosen.has(w.id) ? " checked" : ""}><span>${escapeHtml(w.name)}</span></label>`).join("")}</fieldset>
    <label class="iw-check"><input type="checkbox" id="iw-grant-cycle" checked> <span>Nouveau cycle de crédits (facture réglée)</span></label>
    <div class="iw-field"><label class="iw-label" for="iw-grant-months"><span>Mois couverts par cette facture</span></label>
      <input type="number" id="iw-grant-months" min="1" max="24" step="1" value="1" aria-describedby="iw-grant-months-h">
      <div class="iw-hint" id="iw-grant-months-h">Au-delà, le forfait retombe à l'Essai (5 jours de grâce) tant que vous ne l'avez pas reconduit avec la facture suivante.</div></div>
    <label class="iw-check"><input type="checkbox" id="iw-grant-paid"> <span>Je confirme que la facture de ce client est réglée</span></label>
    <div class="iw-trial-actions"><button type="button" class="btn btn-gold" id="iw-grant-go" disabled>Attribuer</button><button type="button" class="btn btn-ghost" id="iw-grant-cancel">Annuler</button></div>
    <div class="iw-field-err" id="iw-grant-msg" role="alert" hidden></div>`;
  const plan = card.querySelector("#iw-grant-plan");
  const paid = card.querySelector("#iw-grant-paid");
  const go = card.querySelector("#iw-grant-go");
  const msg = card.querySelector("#iw-grant-msg");
  const sync = () => {
    const slots = plan.value === "trio" ? 3 : 1;
    const picked = card.querySelectorAll(".iw-grant-workers input:checked").length;
    card.querySelector(".iw-grant-count").textContent = `${picked} / ${slots}`;
    go.disabled = !(paid.checked && picked >= 1 && picked <= slots);
  };
  card.querySelectorAll("input, select").forEach((el) => el.addEventListener("change", sync));
  sync();
  card.querySelector("#iw-grant-cancel").addEventListener("click", () => { card.hidden = true; card.innerHTML = ""; });
  go.addEventListener("click", async () => {
    go.disabled = true;
    msg.hidden = true;
    const picked = Array.from(card.querySelectorAll(".iw-grant-workers input:checked")).map((b) => b.value);
    try {
      const r = await fetchJson("/api/admin/grant-workers", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ clientId, planId: plan.value, workers: picked, newCycle: card.querySelector("#iw-grant-cycle").checked,
          paidMonths: Math.max(1, Math.min(24, parseInt(card.querySelector("#iw-grant-months").value, 10) || 1)) }),
      });
      if (r.error) {
        msg.textContent = r.detail || r.error;
        msg.hidden = false;
        sync();
        return;
      }
      showToast(`Forfait ${r.planName} attribué à ${clientLabel}.`);
      card.hidden = true;
      card.innerHTML = "";
      loadAdminOverview();
    } catch (e) {
      msg.textContent = e.message || "Attribution impossible.";
      msg.hidden = false;
      sync();
    }
  });
  card.scrollIntoView({ behavior: "smooth", block: "center" });
  plan.focus({ preventScroll: true });
}
// ===== HIRE-UI END =====

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
document.getElementById("billing-pending-btn").addEventListener("click", retryPendingCheckout);
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
    const pw = prompt("Suppression DÉFINITIVE de votre compte, de vos missions et de vos connexions. Un forfait déjà résilié mais encore valable s'arrête aussitôt : le temps déjà payé n'est pas remboursé.\nEntrez votre mot de passe pour confirmer :");
    if (!pw) return;
    const r = await fetchJson("/api/account/delete", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ password: pw }) });
    if (r.ok) { location.href = "/"; return; }
    const texts = {
      INVALID_PASSWORD: "Mot de passe incorrect.",
      ACTIVE_SUBSCRIPTION: "Votre abonnement est encore renouvelé : résiliez-le d'abord avec « Annuler l'abonnement » (en haut de cette page), puis supprimez votre compte. Une fois la résiliation enregistrée, vous pouvez supprimer votre compte tout de suite.",
      STRIPE_CLEANUP_PENDING: "Un ancien abonnement est en cours d'annulation chez notre prestataire de paiement : réessayez dans quelques heures, ou écrivez-nous pour que nous le fassions tout de suite.",
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
