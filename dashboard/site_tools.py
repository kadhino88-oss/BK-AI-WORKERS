# -*- coding: utf-8 -*-
"""Outils de l'atelier de sites pour les Workers (docs/AUTONOMY-ENGINE.md, section 8.3), enregistrés dans le registre de project_tools.py.

  site_scaffold          crée site.json, les parties communes, la feuille de style de la marque et un squelette par page (kit de conception)
  site_build             assemble site/dist/ (déterministe, sans réseau) et prolonge l'aperçu privé s'il existe
  site_check             contrôles automatiques (preuve CHK-xxxxxxxx que le moteur relit)
  site_package           deliverables/site-<slug>.zip + deliverables/MISE-EN-LIGNE.md, inscrits comme livrables
  site_publish_prepare   prépare la publication : un article d'approbation par page (brouillon de page WordPress) ou une action manuelle guidée
  preview_fetch          (remplace la version du moteur) lit une page construite par les MÊMES règles de chemin que l'aperçu à jeton

Chaque outil n'écrit que dans workspace/ et spool/ (règle de l'écrivain unique). Rien ne sort du serveur : aucun outil n'appelle un connecteur ;
la publication passe TOUJOURS par un article d'approbation validé par le client.
"""
import json
import os
import re
import secrets

import project_paths as pp
import project_tools as pt
import site_factory as sf

SITE_KINDS = ("execute", "fix")
_GUIDE_EXCERPT = 6000


def _err(e):
    return pt.ToolError(e.code, e.detail)


def _guide():
    g = sf.guide_text()
    return g[:_GUIDE_EXCERPT] + ("\n[… suite dans notes/site-guide.md]" if len(g) > _GUIDE_EXCERPT else "")


def _project_ids(ctx):
    pid = os.path.basename(ctx.project_dir.rstrip("/\\"))
    st = ctx.state()
    return pid, str(st.get("clientId") or "")


# ------------------------------------------------------------------ outils
def tool_site_scaffold(ctx, inp):
    try:
        out = sf.scaffold(ctx.workspace, inp)
    except sf.SiteError as e:
        raise _err(e)
    out["guide"] = _guide()
    out["next"] = ("Écris maintenant le texte de chaque page (workspace_write sur site/src/pages/<langue>/<slug>.html) en remplaçant chaque "
                   "[À RÉDIGER] / [TO WRITE] ; remplis la ligne <!--meta {\"title\",\"description\"} --> (titre 30-60 caractères, description 70-160) ; "
                   "puis site_build et site_check. Les faits que seul le client connaît restent « [À COMPLÉTER : …] » et figurent dans needsFromClient.")
    return out


def tool_site_build(ctx, inp):
    try:
        info = sf.build(ctx.workspace, capacity_bytes=ctx.workspace_cap_bytes())
    except sf.SiteError as e:
        raise _err(e)
    except pp.PathError as e:
        raise pt.ToolError(e.code, e.detail)
    preview = None
    try:
        import site_preview
        pid, _cid = _project_ids(ctx)
        preview = site_preview.SitePreview(pt.ROOT).refresh(pid)
    except Exception:  # noqa: BLE001 - l'aperçu est un confort : jamais une cause d'échec de la construction
        preview = None
    return {"pages": [{"url": p["url"], "path": "site/dist/" + p["path"], "lang": p["lang"], "title": p["title"], "bytes": p["bytes"]} for p in info["pages"]],
            "files": info["files"], "totalBytes": info["totalBytes"], "warnings": info["warnings"],
            "previewExtendedTo": preview,
            "next": "Lance site_check (profil et familles du critère) et corrige chaque constat « error » avant de terminer l'étape."}


def tool_site_check(ctx, inp):
    check = {"type": "site_check", "profile": inp.get("profile") if isinstance(inp.get("profile"), str) else "vitrine"}
    if isinstance(inp.get("must"), list):
        check["must"] = [m for m in inp["must"] if isinstance(m, str)][:12]
    res = pt.tool_check_run(ctx, {"check": check})
    errors = [f for f in res["findings"] if f.get("severity") == "error"]
    warns = [f for f in res["findings"] if f.get("severity") == "warn"]
    res["summary"] = (f"{len(errors)} erreur(s), {len(warns)} avertissement(s)." + (" Le contrôle passe : cite " + res["id"] + " comme preuve." if res["ok"]
                      else " Corrige les erreurs puis relance site_build et site_check."))
    return res


def tool_site_package(ctx, inp):
    try:
        out = sf.package(ctx.workspace)
    except sf.SiteError as e:
        raise _err(e)
    regs = []
    for path, title in ((out["zip"], "Site prêt à mettre en ligne (zip)"), (out["guide"], "Guide de mise en ligne")):
        try:
            regs.append(pt.tool_deliverable_register(ctx, {"path": path, "title": title}))
        except pt.ToolError as e:
            regs.append({"path": path, "error": e.code, "detail": e.detail})
    out["registered"] = regs
    return out


def tool_site_publish_prepare(ctx, inp):
    """Un article d'approbation par page : brouillon de page WordPress (connecteur du client, après validation) si possible, sinon action manuelle
    guidée. Ne publie rien ; ne contacte aucun service."""
    import projects_approvals as pa
    target = inp.get("target") if inp.get("target") in ("wordpress", "manual") else "wordpress"
    _pid, client_id = _project_ids(ctx)
    try:
        site = sf.load_site(ctx.workspace)
        if not os.path.isdir(sf.site_paths(ctx.workspace)["dist"]):
            raise pt.ToolError("BUILD_MISSING", "Le site n'est pas construit : lance site_build (et site_check) avant de préparer la publication.")
        langs = [l for l in (inp.get("languages") or [site["defaultLanguage"]]) if isinstance(l, str)]
        pages = sf.wordpress_pages(ctx.workspace, langs)
    except sf.SiteError as e:
        raise _err(e)
    wp_problem = pa.connector_problem(pt.ROOT, client_id, "wordpress", "CREATE_PAGE_DRAFT") if target == "wordpress" else ("MANUAL", "")
    queued, manual = [], []
    for pg in pages:
        if target == "wordpress" and wp_problem is None and pg["fits"]:
            r = pt.tool_request_approval(ctx, {
                "kind": "connector", "connectorId": "wordpress", "operation": "CREATE_PAGE_DRAFT",
                "params": {"Title": pg["title"], "Slug": pg["slug"], "Content": pg["content"]},
                "title": f"Brouillon WordPress : page « {pg['title']} » ({pg['lang']})",
                "what": f"Crée la page « {pg['title']} » en BROUILLON dans votre WordPress (adresse prévue /{pg['slug']}/). Rien n'est publié : vous relisez et publiez vous-même.",
                "why": "Mise en ligne du site préparé dans ce projet."})
            queued.append({"page": pg["key"], "lang": pg["lang"], **{k: r.get(k) for k in ("approvalId", "risk", "duplicate", "note")}})
        else:
            manual.append(pg)
    if manual:
        if target == "wordpress" and wp_problem is None:
            why = "contenu trop long pour un article d'approbation (8 Ko au plus)"
        elif target == "wordpress":
            why = "WordPress n'est pas connecté à ce compte" if wp_problem[0] == "CONNECTOR_MISSING" else "opération WordPress indisponible"
        else:
            why = "mise en ligne manuelle demandée"
        names = ", ".join(f"« {p['title']} » ({p['lang']})" for p in manual[:12])
        r = pt.tool_request_approval(ctx, {
            "kind": "manual", "risk": "medium",
            "title": "Mettre le site en ligne (étapes à faire par vous)",
            "what": (f"Pages concernées : {names}. Suivez deliverables/MISE-EN-LIGNE.md : déposer le dossier site/ du zip chez votre hébergeur "
                     "(ou recréer les pages dans votre outil), relier le domaine, activer HTTPS. Confirmez ici une fois le site en ligne."),
            "why": f"Préparé automatiquement ; publication manuelle parce que : {why}."})
        queued.append({"manual": True, "pages": len(manual), **{k: r.get(k) for k in ("approvalId", "risk", "duplicate", "note")}})
    return {"target": target, "items": queued, "connector": "wordpress" if target == "wordpress" and wp_problem is None else None,
            "note": "Chaque article attend la validation du client ; rien n'est publié tant qu'il n'a pas validé. Continue ton étape (step_complete)."}


def tool_preview_fetch(ctx, inp):
    """Lit une page construite de site/dist/ par les règles de chemin de l'aperçu à jeton (mêmes refus, même 404) ; aucun réseau, aucun jeton
    exposé. Enregistre la lecture (fetches/FET-xxxxxxxx.json) : c'est une preuve de type « fetch » pour le vérificateur."""
    import site_html as H
    import site_preview
    path = inp.get("path") if isinstance(inp.get("path"), str) else "/"
    path = "/" + path.lstrip("/")
    fake_token = "A" * 32
    req = site_preview.SitePreview(pt.ROOT).resolve_request(site_preview.PREFIX + fake_token + path)
    if not req or req[1] is None:
        return {"status": 404, "detail": "Chemin refusé par les règles de l'aperçu."}
    segs = req[1]
    rel = "site/dist/" + "/".join(segs)
    try:
        full = pp.resolve(ctx.workspace, rel, kind="file", must_exist=True)
    except pp.PathError:
        return {"status": 404, "detail": f"Introuvable : {path}"}
    size = os.path.getsize(full)
    if size > site_preview.MAX_FILE_BYTES:
        return {"status": 404, "detail": "Fichier trop gros pour l'aperçu (5 Mo au plus)."}
    with open(full, "rb") as f:
        raw = f.read(1024 * 1024)
    rec = {"id": "FET-" + secrets.token_hex(4), "path": pp.rel_of(ctx.workspace, full), "status": 200, "bytes": size,
           "contentType": site_preview.MIME.get(segs[-1].rsplit(".", 1)[-1].lower(), "")}
    if segs[-1].endswith((".html", ".htm")):
        text = raw.decode("utf-8", errors="replace")
        doc = H.parse(text)
        t = doc.first("title")
        rec["title"] = (t.inner_text().strip()[:200] if t else "")
        rec["description"] = (H.meta_content(doc, "description") or "")[:300]
        rec["lang"] = ((doc.first("html").get("lang") if doc.first("html") else "") or "")
        rec["headings"] = [f"{h.tag}: {h.inner_text().strip()[:100]}" for h in doc.by_tag("h1", "h2", "h3")][:30]
        links = []
        try:
            import site_checks
            model = site_checks.SiteModel(ctx.workspace)
            page = next((p for p in model.pages if p.rel == "/".join(segs)), None)
        except Exception:  # noqa: BLE001
            page = None
        for a in doc.by_tag("a")[:80]:
            href = a.get("href") or ""
            state = "externe" if H.is_external(href) else ("contact" if href.startswith(("mailto:", "tel:")) else
                                                          ("ok" if page is not None and model.resolve(page, href) else "introuvable"))
            links.append({"href": href[:200], "text": a.inner_text().strip()[:80], "state": state})
        rec["links"] = links
        rec["text"] = re.sub(r"\s+", " ", doc.visible_text()).strip()[:4000]
    if ctx.step_dir:
        try:
            os.makedirs(os.path.join(ctx.step_dir, "fetches"), exist_ok=True)
            with open(os.path.join(ctx.step_dir, "fetches", rec["id"] + ".json"), "w", encoding="utf-8") as f:
                json.dump({k: v for k, v in rec.items() if k != "text"}, f, ensure_ascii=False)
        except OSError:
            pass
    return rec


# ------------------------------------------------------------------ définitions pour le modèle
def _def(name, description, props, required=(), examples=()):
    d = {"name": name, "description": description, "input_schema": {"type": "object", "properties": props, "required": list(required)}}
    if examples:
        d["input_examples"] = list(examples)
    return d


_STR = {"type": "string"}
DEFINITIONS = {
    "site_scaffold": _def(
        "site_scaffold",
        "Crée le squelette d'un site statique professionnel dans site/ : site.json (marque, langues, pages, coordonnées), en-tête et pied de page, "
        "feuille de style à variables (couleurs de la marque avec contrastes garantis, typographie, espacements, mobile d'abord) et une page par langue "
        "faite de sections éprouvées (héros, prestations, déroulement, faits vérifiables, tarifs, FAQ, appel à l'action, contact sans serveur, mentions "
        "légales, confidentialité). Les textes à écrire sont marqués [À RÉDIGER] / [TO WRITE] ; les faits que seul le client connaît restent "
        "« [À COMPLÉTER : …] » et sont listés dans needsFromClient : n'invente jamais un avis, un chiffre, une certification ni une coordonnée. "
        "À utiliser UNE fois au début d'un projet de site ; refuse d'écraser un site existant sans force:true. Le résultat contient le guide de l'atelier.",
        {"profile": {"type": "string", "enum": ["vitrine", "landing", "blog"], "description": "vitrine (multi-pages), landing (une page), blog"},
         "languages": {"type": "array", "items": {"type": "string", "enum": list(sf.LANGS)}, "description": "Langues, la première est la langue par défaut"},
         "brand": {"type": "object", "description": "name, tagline, tone, colors{primary,accent,bg,text} (#rrggbb), font (system|humanist|geometric|serif|classic), radius"},
         "pages": {"type": "array", "items": {"type": "object"}, "description": "Facultatif : [{key, slug, title, sections[]}] ; sinon les pages du profil"},
         "contact": {"type": "object", "description": "email, phone, address, hours : SEULEMENT des valeurs fournies par le client"},
         "legal": {"type": "object", "description": "company, address, uid, responsible, host, retention : fournis par le client"},
         "hosting": {"type": "object", "description": "host (infomaniak|hostpoint|ovh|netlify|cloudflare-pages|github-pages|autre), domain"},
         "baseUrl": _STR, "force": {"type": "boolean"}},
        (), ({"profile": "vitrine", "languages": ["fr", "en"], "brand": {"name": "Physio Léman", "colors": {"primary": "#0e7490", "accent": "#f59e0b"}, "font": "humanist"},
              "contact": {"email": "contact@physio-leman.ch"}},)),
    "site_build": _def(
        "site_build",
        "Construit site/dist/ à partir de site/src/ et de site.json : assemble en-tête, navigation (page courante marquée), contenu et pied de page, ajoute "
        "doctype, langue, encodage, viewport, titre, description, canonical, hreflang réciproques, Open Graph, carte Twitter, icône, données structurées "
        "issues de site.json seulement, puis génère sitemap.xml, robots.txt, 404.html, l'icône et l'image de partage si elles manquent. Les liens internes "
        "« /chemin » deviennent relatifs (le site marche partout). Déterministe et sans réseau ; ne modifie jamais src/. À relancer après chaque "
        "modification, avant site_check, l'aperçu et le zip.",
        {}, (), ({},)),
    "site_check": _def(
        "site_check",
        "Contrôle automatiquement le site construit (site/dist/) : HTML valide, balises de tête, liens internes et ancres, images (alt, dimensions, poids), "
        "accessibilité (un seul h1, ordre des titres, repères, libellés, contraste des couleurs, focus visible), poids des pages, vie privée (aucun traceur "
        "ni ressource externe), parité des langues, sitemap, pages orphelines, données structurées, textes non rédigés, coordonnées factices et affirmations "
        "non vérifiées (avis, notes, nombre de clients, certifications). Renvoie les constats classés et un identifiant CHK-xxxxxxxx à citer comme preuve. "
        "Une erreur bloque la fin du projet : corrige-la (src/), relance site_build puis site_check.",
        {"profile": {"type": "string", "enum": ["vitrine", "landing", "blog", "minimal"]},
         "must": {"type": "array", "items": {"type": "string", "enum": ["html", "meta", "links", "img", "a11y", "perf", "privacy", "i18n", "seo", "content"]},
                  "description": "Familles à contrôler (toutes par défaut) ; les règles de sécurité tournent toujours"}},
        (), ({"profile": "vitrine", "must": ["html", "meta", "links", "a11y", "privacy", "i18n", "seo", "content"]},)),
    "site_package": _def(
        "site_package",
        "Produit les livrables de mise en ligne : deliverables/site-<slug>.zip (le dossier dist/ complet, reproductible) et deliverables/MISE-EN-LIGNE.md "
        "(guide pour l'hébergeur du client : dépôt des fichiers, DNS exacts seulement si le domaine est connu, HTTPS, liste « avant » et « après »), puis "
        "les inscrit comme livrables du projet. À appeler quand site_check passe. Ne publie rien.",
        {}, (), ({},)),
    "site_publish_prepare": _def(
        "site_publish_prepare",
        "Prépare la publication du site SANS rien publier : pour WordPress connecté, un article d'approbation par page (brouillon de page, risque moyen, "
        "réversible) que le client valide un par un ; sinon (pas de WordPress, page trop longue, ou target manual) une action manuelle guidée par "
        "MISE-EN-LIGNE.md. Webflow, Shopify et WooCommerce ne permettent pas de déposer un site statique : guide manuel. L'étape continue après "
        "l'appel (les articles attendent le client). Lance d'abord site_build, site_check et site_package.",
        {"target": {"type": "string", "enum": ["wordpress", "manual"]},
         "languages": {"type": "array", "items": {"type": "string"}, "description": "Langues à déposer (défaut : la langue principale)"}},
        (), ({"target": "wordpress"},)),
    "preview_fetch": _def(
        "preview_fetch",
        "Lit une page du site construit (site/dist/) comme l'aperçu privé la servirait : statut, titre, description, langue, titres h1-h3, liens avec leur "
        "état (ok, introuvable, externe, contact) et texte visible. Aucun réseau. Chaque lecture réussie est enregistrée (FET-xxxxxxxx) et peut servir de "
        "preuve de type « fetch ». Chemins comme sur le site : « / », « /services/ », « /en/about/ ».",
        {"path": {"type": "string", "description": "Chemin de la page, ex. /contact/"}}, ("path",), ({"path": "/"},)),
}

for _name, _fn, _kinds in (
        ("site_scaffold", tool_site_scaffold, SITE_KINDS),
        ("site_build", tool_site_build, SITE_KINDS),
        ("site_check", tool_site_check, SITE_KINDS + ("verify",)),
        ("site_package", tool_site_package, SITE_KINDS + ("consolidate",)),
        ("site_publish_prepare", tool_site_publish_prepare, SITE_KINDS),
        ("preview_fetch", tool_preview_fetch, ("verify", "execute", "fix"))):
    pt.register_tool(_name, _fn, kinds=_kinds, definition=DEFINITIONS[_name])
