"""Fichiers statiques de l'application installable (PWA) — 2026-10-07.

Regroupe en un seul endroit les types MIME et les en-tetes de cache des fichiers qui
font de BK-AI-WORKERS une application installable, pour que server.py n'ait qu'un
crochet a porter (voir do_GET) :

  /manifest.json                  application/manifest+json
  /service-worker.js              text/javascript, JAMAIS en cache long, Service-Worker-Allowed: /
  /offline.html                   page de secours hors connexion (FR/EN)
  /pwa-install.js, /pwa-install.css, /i18n-en-pwa.js   invitation a installer + traductions
  /icons/<nom>.png                icones (any / maskable / apple-touch)
  /suppression-compte.html        page publique "supprimer mon compte" (exigee par les stores)
  /.well-known/assetlinks.json    preuve de propriete Android (Trusted Web Activity), servie
                                  seulement si dashboard/well-known/assetlinks.json existe
  /.well-known/apple-app-site-association   liens universels iOS (retour OAuth dans l'app iOS),
                                  servi seulement si dashboard/well-known/apple-app-site-association existe

Les en-tetes de cache restent "no-cache" (revalidation a chaque requete, 304 si inchange
grace a l'ETag) : meme regle que _send_file, nee de l'incident de JS perime du 2026-09-24.
"""
import hashlib
import os
import re

JS = "text/javascript; charset=utf-8"
HTML = "text/html; charset=utf-8"
CSS = "text/css; charset=utf-8"
REVALIDATE = "no-cache, max-age=0, must-revalidate"

# chemin public -> (fichier sous dashboard/, Content-Type, Cache-Control, en-tetes en plus)
ROUTES = {
    "/manifest.json": ("manifest.json", "application/manifest+json; charset=utf-8", REVALIDATE, {}),
    # Un service worker ne controle jamais une portee plus large que son chemin : servi a la racine.
    "/service-worker.js": ("service-worker.js", JS, REVALIDATE, {"Service-Worker-Allowed": "/"}),
    "/offline.html": ("offline.html", HTML, REVALIDATE, {}),
    "/pwa-install.js": ("pwa-install.js", JS, REVALIDATE, {}),
    "/pwa-install.css": ("pwa-install.css", CSS, REVALIDATE, {}),
    "/i18n-en-pwa.js": ("i18n-en-pwa.js", JS, REVALIDATE, {}),
    "/suppression-compte.html": ("suppression-compte.html", HTML, REVALIDATE, {}),
    # Android : fichier fourni par le proprietaire apres la creation de l'app (docs/MOBILE-APPS.md).
    "/.well-known/assetlinks.json": ("well-known/assetlinks.json", "application/json; charset=utf-8", "public, max-age=300", {}),
    # iOS : fichier fourni par le proprietaire apres la creation de l'app (docs/MOBILE-APPS.md). Apple exige du JSON
    # sans extension, en HTTPS, sans redirection.
    "/.well-known/apple-app-site-association": ("well-known/apple-app-site-association", "application/json; charset=utf-8", "public, max-age=300", {}),
}

ICON_RE = re.compile(r"^/icons/([a-z0-9][a-z0-9_-]{0,63}\.png)$")


def resolve(path):
    """-> (nom de fichier relatif a dashboard/, content_type, cache_control, extra) ou None."""
    route = ROUTES.get(path)
    if route:
        return route
    m = ICON_RE.match(path)
    if m:
        return ("icons/" + m.group(1), "image/png", REVALIDATE, {})
    return None


def handles(path):
    return resolve(path) is not None


def _etag(body):
    return '"' + hashlib.sha1(body).hexdigest()[:20] + '"'


def serve(handler, path, dashboard_dir):
    """Envoie le fichier PWA correspondant a `path`. Renvoie False si ce chemin n'est pas
    un fichier PWA (le serveur continue alors son routage normal)."""
    route = resolve(path)
    if not route:
        return False
    rel, content_type, cache_control, extra = route
    full = os.path.join(dashboard_dir, *rel.split("/"))
    base = os.path.realpath(dashboard_dir)
    if not os.path.realpath(full).startswith(base + os.sep) or not os.path.isfile(full):
        body = b'{"error": "NOT_FOUND"}'
        handler.send_response(404)
        handler.send_header("Content-Type", "application/json; charset=utf-8")
        handler.send_header("Content-Length", str(len(body)))
        handler.send_header("Cache-Control", "no-store")
        handler.end_headers()
        handler.wfile.write(body)
        return True
    with open(full, "rb") as f:
        body = f.read()
    etag = _etag(body)
    not_modified = (handler.headers.get("If-None-Match") or "").strip() == etag
    handler.send_response(304 if not_modified else 200)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Cache-Control", cache_control)
    handler.send_header("ETag", etag)
    handler.send_header("X-Content-Type-Options", "nosniff")
    for k, v in extra.items():
        handler.send_header(k, v)
    if not_modified:
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)
    return True
