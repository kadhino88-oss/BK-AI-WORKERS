# -*- coding: utf-8 -*-
"""Routes HTTP de l'atelier de sites (docs/AUTONOMY-ENGINE.md, sections 7.2 et 8.5-8.6), enregistrées dans projects_api par projects_wiring :

    POST   /api/projects/{id}/site/preview      {hours?}             crée (ou remplace) le lien d'aperçu privé du projet -> {url, expiresUtc, sandbox}
    DELETE /api/projects/{id}/site/preview                           révoque le lien (même 404 ensuite que pour un jeton inconnu)
    GET    /api/projects/{id}/site/export.zip   ?scope=dist|source   zip reproductible (dist/ + MISE-EN-LIGNE.md [+ src/ et site.json])
    POST   /api/projects/{id}/site/publish      {target, languages?} prépare la publication : articles d'approbation (rien n'est publié)

Toutes derrière BK_PROJECTS=1, la session du client, le contrôle d'Origine et les limites de débit de projects_api ; un projet d'un autre client = 404.
Le service reçoit aussi `site_info(state)` (bloc « site » du détail d'un projet) ; l'aperçu (site_preview.SitePreview) est partagé avec server.py
par la variable PREVIEW de ce module.
"""
import os
import re
import sys

import projects_store as ps
import site_factory as sf
import site_preview
import site_tools  # noqa: F401  (enregistre les outils site_* dans le registre du moteur, aussi dans le processus du serveur)

PID = r"(PRJ-[A-F0-9]{32})"
PREVIEW = None


def _dirs(service, pid):
    pdir = service.store.project_dir(pid)
    ws = os.path.join(pdir, "workspace")
    return pdir, ws, os.path.join(ws, "site", "dist")


def site_info(service, preview, st):
    """Bloc « site » du détail : construit ou non, pages, poids, lien d'aperçu vivant. None quand le projet n'a pas de site."""
    pid = st.get("projectId")
    try:
        _pdir, ws, dist = _dirs(service, pid)
    except Exception:  # noqa: BLE001
        return None
    sj = os.path.join(ws, "site", "site.json")
    if not os.path.isfile(sj):
        return None
    info = {"exists": True, "built": os.path.isdir(dist), "pages": 0, "totalBytes": 0, "warnings": 0, "stale": False}
    bj = os.path.join(ws, "site", "build.json")
    try:
        import json
        with open(bj, encoding="utf-8") as f:
            b = json.load(f)
        info.update(pages=len(b.get("pages") or []), totalBytes=int(b.get("totalBytes") or 0), warnings=len(b.get("warnings") or []),
                    stale=bool(b.get("srcSha256")) and b.get("srcSha256") != sf.src_fingerprint(ws))
    except (OSError, ValueError):
        pass
    info["preview"] = preview.info(st.get("clientId"), pid) if preview else {"active": False}
    info["canPublishWordpress"] = False
    try:
        import projects_approvals as pa
        info["canPublishWordpress"] = pa.connector_problem(service.root, st.get("clientId"), "wordpress", "CREATE_PAGE_DRAFT") is None
    except Exception:  # noqa: BLE001
        pass
    return info


def register(service, api):
    """Branche l'atelier sur le service et l'API des projets. Appelé une fois par projects_wiring.build()."""
    global PREVIEW
    preview = site_preview.SitePreview(service.root, enabled=lambda: bool(service.enabled))
    PREVIEW = preview
    service.site_info = lambda st: site_info(service, preview, st)
    orig_purge = getattr(service, "purge_client", None)
    if callable(orig_purge):
        def purge_client(client_id, *a, **kw):
            try:
                preview.purge_client(client_id)
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"site_routes purge: {type(e).__name__}\n")
            return orig_purge(client_id, *a, **kw)
        service.purge_client = purge_client

    def r_preview_create(r):
        pid = r.match.group(1)
        st = r.owned(pid)
        body = r.body()
        if body is None:
            return None
        if st["status"] == "CANCELLED":
            raise ps.ProjectError("INVALID_STATE", "Le projet est annulé.", status=st["status"])
        _pdir, _ws, dist = _dirs(service, pid)
        if not os.path.isfile(os.path.join(dist, "index.html")):
            raise ps.ProjectError("INVALID_STATE", "Le site n'est pas encore construit : l'aperçu sera disponible après la première construction.", status=st["status"])
        hours = body.get("hours")
        out = preview.create(st["clientId"], pid, hours if isinstance(hours, (int, float)) and not isinstance(hours, bool) else None)
        out.pop("token", None)
        return out

    def r_preview_delete(r):
        pid = r.match.group(1)
        st = r.owned(pid)
        return {"ok": True, "revoked": preview.revoke(st["clientId"], pid)}

    def r_export(r):
        pid = r.match.group(1)
        st = r.owned(pid)
        scope = "source" if r.query("scope") == "source" else "dist"
        _pdir, ws, _dist = _dirs(service, pid)
        try:
            data = sf.export_zip(ws, scope)
            slug = sf.load_site(ws)["slug"]
        except sf.SiteError as e:
            code = {"TOO_LARGE": "TOO_LARGE"}.get(e.code, "INVALID_STATE")
            raise ps.ProjectError(code, e.detail, status=st["status"] if code == "INVALID_STATE" else None)
        name = re.sub(r"[^a-z0-9-]", "", slug)[:40] or "site"
        name = f"site-{name}{'-source' if scope == 'source' else ''}.zip"
        h = r.handler
        h.send_response(200)
        h.send_header("Content-Type", "application/zip")
        h.send_header("Content-Length", str(len(data)))
        h.send_header("Content-Disposition", f'attachment; filename="{name}"')
        h.send_header("X-Content-Type-Options", "nosniff")
        h.send_header("Content-Security-Policy", "default-src 'none'; sandbox")
        h.send_header("Cache-Control", "private, no-store")
        h.end_headers()
        h.wfile.write(data)
        return None

    def r_publish(r):
        import project_tools
        pid = r.match.group(1)
        st = r.owned(pid)
        body = r.body()
        if body is None:
            return None
        if st["status"] == "CANCELLED":
            raise ps.ProjectError("INVALID_STATE", "Le projet est annulé : plus rien ne part.", status=st["status"])
        target = body.get("target") if body.get("target") in ("wordpress", "manual") else None
        if target is None:
            raise ps.ProjectError("INVALID_INPUT", "target : « wordpress » ou « manual ».", field="target")
        langs = body.get("languages") if isinstance(body.get("languages"), list) else None
        pdir, _ws, _dist = _dirs(service, pid)
        payload = {"projectDir": pdir, "stepDir": "", "stepId": "PUBLISH", "kind": "execute",
                   "worker": str(st.get("leadWorker") or "lucas"), "input": {"target": target, **({"languages": [str(l)[:5] for l in langs[:4]]} if langs else {})}}
        out = project_tools.run_tool("site_publish_prepare", payload)
        if not out.get("ok"):
            code = out.get("error") or "INTERNAL"
            raise ps.ProjectError(code if code in ("APPROVAL_QUEUE_FULL", "TOO_LARGE") else "INVALID_STATE", out.get("detail") or "Préparation impossible.",
                                  status=st["status"])
        with service.store.txn(pid) as t:
            service._ingest_approvals(t, rename_step="PUBLISH")
            service.refresh_approval_counts(t)
        service.nudge()
        res = out["result"]
        return {"ok": True, "target": res.get("target"), "connector": res.get("connector"), "queued": len(res.get("items") or []),
                "approvalIds": [i.get("approvalId") for i in res.get("items") or [] if i.get("approvalId")]}

    api.register_route("POST", rf"^/api/projects/{PID}/site/preview\Z", r_preview_create, rate="sitePreview")
    api.register_route("DELETE", rf"^/api/projects/{PID}/site/preview\Z", r_preview_delete, rate="control")
    api.register_route("GET", rf"^/api/projects/{PID}/site/export\.zip\Z", r_export, rate="zip")
    api.register_route("POST", rf"^/api/projects/{PID}/site/publish\Z", r_publish, rate="control")
    return preview
