/* Vue operateur : candidatures du programme pilote (section de la vue Admin, voir index.html).
   REGLE : les donnees viennent d'un formulaire public. Elles ne sont JAMAIS injectees comme HTML :
   uniquement textContent / setAttribute avec une valeur verifiee. Aucun innerHTML ici. */
(function () {
  "use strict";
  var LIST_ID = "admin-pilot-list";
  var EMAIL_OK = /^[A-Za-z0-9][A-Za-z0-9._+-]*@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/;
  var URL_OK = /^https?:\/\/[A-Za-z0-9.-]+(\/[A-Za-z0-9._~%/+=&?#:,;@!-]*)?$/;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = String(text);
    return e;
  }

  function when(iso) {
    var d = new Date(iso);
    return isNaN(d.getTime()) ? String(iso || "") : d.toLocaleString();
  }

  function renderRow(r, onDelete) {
    var row = el("div", "admin-activity-row kind-demo");
    row.appendChild(el("span", "admin-activity-when", when(r.atUtc)));
    row.appendChild(el("span", "admin-activity-kind", String(r.lang || "fr").toUpperCase()));
    var who = el("span", "admin-activity-who", (r.name || "") + " — ");
    if (typeof r.email === "string" && EMAIL_OK.test(r.email)) {
      var mail = el("a", "", r.email);
      mail.setAttribute("href", "mailto:" + r.email);
      who.appendChild(mail);
    } else {
      who.appendChild(document.createTextNode(String(r.email || "")));
    }
    row.appendChild(who);
    var info = el("span", "admin-activity-text", r.company || "");
    if (typeof r.website === "string" && r.website) {
      info.appendChild(document.createTextNode(" · "));
      if (URL_OK.test(r.website)) {
        var link = el("a", "", r.website);
        link.setAttribute("href", r.website);
        link.setAttribute("target", "_blank");
        link.setAttribute("rel", "noopener noreferrer nofollow");
        info.appendChild(link);
      } else {
        info.appendChild(document.createTextNode(r.website));
      }
    }
    row.appendChild(info);

    var tools = (Array.isArray(r.tools) ? r.tools : []).map(function (t) { return t && (t.name || t.id) || ""; }).filter(Boolean);
    if (r.otherTools) tools.push(String(r.otherTools));
    if (tools.length) row.appendChild(el("span", "admin-demo-msg", "Outils : " + tools.join(", ")));
    if (r.useCase) row.appendChild(el("span", "admin-demo-msg admin-pilot-usecase", r.useCase));

    var actions = el("span", "admin-pilot-actions");
    actions.appendChild(el("span", "admin-pilot-id", "Réf. " + (r.id || "")));
    var del = el("button", "connector-link-btn", "Supprimer");
    del.setAttribute("type", "button");
    del.addEventListener("click", function () { onDelete(r); });
    actions.appendChild(del);
    row.appendChild(actions);
    return row;
  }

  async function load() {
    var box = document.getElementById(LIST_ID);
    if (!box) return;
    var res;
    try {
      res = await fetch("/api/pilot/applications", { credentials: "same-origin" });
    } catch (e) {
      return;
    }
    if (!res.ok) {                       // 403 : pas operateur ; 503 : stockage illisible
      box.replaceChildren(el("div", "activity-empty",
        res.status === 403 ? "Réservé à l'accès propriétaire." : "Candidatures indisponibles pour le moment."));
      return;
    }
    var data = await res.json();
    var rows = Array.isArray(data.applications) ? data.applications : [];
    if (!rows.length) {
      box.replaceChildren(el("div", "activity-empty", "Aucune candidature pour le moment."));
      return;
    }
    box.replaceChildren.apply(box, rows.map(function (r) { return renderRow(r, remove); }));
  }

  async function remove(r) {
    if (!window.confirm("Supprimer définitivement la candidature de " + (r.name || "?") + " (" + (r.id || "") + ") ?")) return;
    try {
      await fetch("/api/pilot/applications/delete", {
        method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id: r.id })
      });
    } catch (e) { /* le rechargement ci-dessous montre l'etat reel */ }
    load();
  }

  window.loadAdminPilot = load;
})();
