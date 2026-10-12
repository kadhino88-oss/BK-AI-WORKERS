/* Candidature au programme pilote : envoie le formulaire en JSON a POST /api/pilot/apply.
   La validation qui fait foi est celle du serveur ; ici on ne fait qu'afficher le resultat.
   Les messages d'erreur sont des elements masques de la page (data-code) : ils sont donc traduits par
   i18n.js comme le reste, et on ne fabrique jamais de HTML a partir d'une reponse du serveur.
   (Ce fichier est servi precede de window.BK_EN_HEAD, voir pilot_program.build_form_js.) */
(function () {
  "use strict";
  var form = document.getElementById("pilot-form");
  if (!form) return;
  var errBox = document.getElementById("pilot-errors");
  var doneBox = document.getElementById("pilot-done");
  var submit = document.getElementById("pilot-submit");
  var busy = false;

  // Le formulaire n'est visible qu'avec JavaScript (sinon : <noscript> + adresse email de contact).
  form.hidden = false;

  function currentLang() {
    return (window.BK_LANG && window.BK_LANG() === "en") ? "en" : "fr";
  }

  function fieldValue(name) {
    var el = form.elements[name];
    return el && typeof el.value === "string" ? el.value : "";
  }

  function collect() {
    var tools = [];
    var boxes = form.querySelectorAll('input[name="tools"]');
    for (var i = 0; i < boxes.length; i++) {
      if (boxes[i].checked) tools.push(boxes[i].value);
    }
    return {
      name: fieldValue("name"),
      email: fieldValue("email"),
      company: fieldValue("company"),
      website: fieldValue("website"),
      tools: tools,
      otherTools: fieldValue("otherTools"),
      useCase: fieldValue("useCase"),
      consent: !!(form.elements.consent && form.elements.consent.checked),
      lang: currentLang(),
      contact_me_by_fax_only: fieldValue("contact_me_by_fax_only")
    };
  }

  function clearInvalid() {
    var marked = form.querySelectorAll("[aria-invalid]");
    for (var i = 0; i < marked.length; i++) marked[i].removeAttribute("aria-invalid");
  }

  function hideErrors() {
    errBox.hidden = true;
    var items = errBox.querySelectorAll("[data-code]");
    for (var i = 0; i < items.length; i++) items[i].hidden = true;
    clearInvalid();
  }

  function showError(code, field) {
    hideErrors();
    var items = errBox.querySelectorAll("[data-code]");
    var shown = false;
    for (var i = 0; i < items.length; i++) {
      if (items[i].getAttribute("data-code") === code) { items[i].hidden = false; shown = true; }
    }
    if (!shown) {
      for (var j = 0; j < items.length; j++) {
        if (items[j].getAttribute("data-code") === "GENERIC") items[j].hidden = false;
      }
    }
    errBox.hidden = false;
    var target = field ? form.elements[field] : null;
    if (target && !target.tagName && target.length) target = target[0];   // groupe de cases : la premiere
    if (target && target.setAttribute) {
      target.setAttribute("aria-invalid", "true");
      if (target.focus) target.focus();
    } else if (errBox.scrollIntoView) {
      errBox.scrollIntoView({ block: "center" });
    }
  }

  function setBusy(on) {
    busy = on;
    submit.disabled = on;
    var lbl = submit.querySelector(".lbl");
    var wait = submit.querySelector(".busy");
    if (lbl) lbl.hidden = on;
    if (wait) wait.hidden = !on;
  }

  function showDone(id) {
    hideErrors();
    form.hidden = true;
    var ref = document.getElementById("pilot-ref");
    if (ref) ref.textContent = String(id || "");
    doneBox.hidden = false;
    doneBox.focus();
    if (doneBox.scrollIntoView) doneBox.scrollIntoView({ block: "center" });
  }

  function handle(res) {
    var body = res.body || {};
    if (res.status === 200 && body.ok === true) { showDone(body.id); return; }
    var code = typeof body.error === "string" ? body.error : "";
    if (!code && res.status === 429) code = "RATE_LIMITED";
    if (!code && res.status >= 500) code = "UNAVAILABLE";
    showError(code, typeof body.field === "string" ? body.field : "");
  }

  form.addEventListener("submit", function (ev) {
    ev.preventDefault();
    if (busy) return;
    hideErrors();
    if (typeof window.fetch !== "function") { showError("NETWORK", ""); return; }
    setBusy(true);
    window.fetch("/api/pilot/apply", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "same-origin",
      body: JSON.stringify(collect())
    }).then(function (r) {
      return r.json().then(function (j) { return { status: r.status, body: j }; },
                           function () { return { status: r.status, body: {} }; });
    }).then(handle, function () { showError("NETWORK", ""); })
      .then(function () { setBusy(false); }, function () { setBusy(false); });
  });
})();
