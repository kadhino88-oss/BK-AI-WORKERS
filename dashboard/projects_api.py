# -*- coding: utf-8 -*-
"""Routes HTTP des projets (docs/AUTONOMY-ENGINE.md, section 7). Appelé par trois crochets d'une ou deux lignes dans server.py :
    do_GET :    if PROJECTS_API.handle_get(self, path, parsed): return
    do_POST :   if PROJECTS_API.handle_post(self, path, parsed): return
    do_DELETE : if PROJECTS_API.handle_delete(self, path, parsed): return
Chaque handle_* renvoie True quand la route lui appartient (la réponse est déjà envoyée), False sinon : une route inconnue continue son chemin
normal dans server.py. Aucune dépendance au serveur : la session, la lecture du corps JSON, la porte du propriétaire et l'horloge sont injectés.

Conventions : `{"error": CODE, "detail": FR, ...}` ; un projet d'un autre client = 404 ; routes qui modifient : en-tête Origin présent et différent de
PUBLIC_BASE_URL = 403 BAD_ORIGIN ; tout est derrière BK_PROJECTS=1 (sinon 503 PROJECTS_DISABLED) ; limites de débit par client (429 + Retry-After).

Registre pour d'autres modules (atelier de sites : B5) :  api.register_route("POST", r"^/api/projects/(PRJ-[A-F0-9]{32})/site/preview\\Z", fn, rate="control")
    fn(req) avec req.handler, req.match, req.parsed, req.client_id, req.service, req.body() (JSON borné, None si la réponse d'erreur est déjà partie),
    req.owned(pid) (état du projet, 404 sinon). fn renvoie un dict (réponse 200), (dict, statut) ou None (réponse déjà envoyée). Une ProjectError levée est
    traduite comme pour les routes natives.
"""
import json
import os
import re
import shutil
import sys
import threading
import time
from urllib.parse import parse_qs, urlparse

import projects_store as ps
from projects_actions import LEVELS

PID = r"(PRJ-[A-F0-9]{32})"
_UNSAFE_NAME = re.compile(r"[^A-Za-z0-9._-]")
BODY_LIMIT = 64 * 1024
CREATE_BODY_LIMIT = 8 * 1024 * 1024

STATUS_OF = {
    "INVALID_INPUT": 400, "GOAL_REQUIRED": 400, "GOAL_TOO_LONG": 400, "INVALID_PATH": 400, "INVALID_JSON": 400, "SECRET_REFUSED": 400, "UNSUPPORTED_OPERATION": 400,
    "CONNECTOR_MISSING": 400, "NOT_AN_ACTION": 400,
    "ACCOUNT_REQUIRED": 401,
    "SUBSCRIPTION_REQUIRED": 402, "USAGE_LIMIT_REACHED": 402, "PROJECT_EXCEEDS_QUOTA": 402,
    "WORKER_NOT_INCLUDED": 403, "PROJECT_NOT_IN_PLAN": 403, "BAD_ORIGIN": 403, "GATE_REQUIRED": 403,
    "NOT_FOUND": 404,
    "INVALID_STATE": 409, "APPROVAL_NOT_PENDING": 409, "APPROVAL_EXPIRED": 409, "BATCH_NOT_ALLOWED": 409, "CONFIRM_REQUIRED": 409, "APPROVAL_QUEUE_FULL": 409,
    "PROJECT_LOCK_CONFLICT": 409,
    "TOO_LARGE": 413, "WORKSPACE_FULL": 413,
    "RATE_LIMITED": 429, "PROJECT_LIMIT_REACHED": 429,
    "PROJECTS_DISABLED": 503,
}


class Req:
    """Contexte d'une requête transmis aux fonctions de route (natives et enregistrées)."""

    def __init__(self, api, handler, match, parsed, client_id):
        self.api = api
        self.handler = handler
        self.match = match
        self.parsed = parsed
        self.client_id = client_id
        self.service = api.service
        self._body = None
        self._read = False

    def query(self, name, default=""):
        return (parse_qs(self.parsed.query).get(name) or [default])[0]

    def body(self, limit=BODY_LIMIT):
        """Corps JSON (objet). None = la réponse d'erreur (413 / 400) est déjà envoyée : la route s'arrête."""
        if not self._read:
            self._read = True
            self._body = self.api.read_body(self.handler, limit)
        return self._body

    def owned(self, pid):
        return self.service.owned_state(self.client_id, pid)


class _Limiter:
    def __init__(self, now=time.time):
        self.now = now
        self.rows = {}
        self.lock = threading.Lock()

    def hit(self, key, limit, window, n=1):
        """True si la demande passe. Sinon (False, secondes avant la prochaine place)."""
        t = self.now()
        with self.lock:
            rows = [x for x in self.rows.get(key, []) if t - x < window]
            if len(rows) + n > limit:
                self.rows[key] = rows
                return False, max(1, int(window - (t - rows[0])) + 1) if rows else window
            rows.extend([t] * n)
            self.rows[key] = rows
            if len(self.rows) > 5000:                      # ménage : les clés silencieuses depuis longtemps
                for k in [k for k, v in self.rows.items() if not v or t - v[-1] > 7200]:
                    self.rows.pop(k, None)
            return True, 0

    def refund(self, key, n=1):
        """Rend `n` places prises par `hit` (une demande refusée pour cause de saisie invalide ne doit pas consommer le quota de création)."""
        with self.lock:
            rows = self.rows.get(key) or []
            del rows[max(0, len(rows) - n):]


def _origin(url):
    p = urlparse(url or "")
    if not p.scheme or not p.netloc:
        return None
    return f"{p.scheme}://{p.netloc}".lower()


class ProjectsAPI:
    def __init__(self, service, resolve_client_id, send_json=None, read_json_limited=None, rate_ok=None, *, is_owner=None, public_base_url="", now=time.time):
        self.service = service
        self.resolve_client_id = resolve_client_id          # fn(handler) -> ClientId | None
        self.send_json = send_json                          # fn(handler, payload, status) (facultatif : sinon réponse directe)
        self.read_json_limited = read_json_limited          # fn(handler, limit, strict) -> dict | None (réponse d'erreur déjà envoyée)
        self.rate_ok = rate_ok                              # fn(action, key, limit, window) -> bool (facultatif)
        self.is_owner = is_owner or (lambda handler: False)  # porte propriétaire (routes d'administration)
        self.public_origin = _origin(public_base_url)
        self.limiter = _Limiter(now)
        self.routes = {"GET": [], "POST": [], "DELETE": []}
        self._install_native_routes()

    # ------------------------------------------------------------------ enregistrement
    def register_route(self, method, regex, fn, rate="get", auth="client"):
        """Ajoute une route (atelier de sites...). `auth` : « client » (session) ou « owner » (porte propriétaire)."""
        self.routes[method.upper()].append((re.compile(regex), fn, rate, auth))

    def _install_native_routes(self):
        R = self.register_route
        R("GET", r"^/api/recipes\Z", self._r_recipes, rate="get")
        R("GET", r"^/api/projects\Z", self._r_list, rate="get")
        R("GET", rf"^/api/projects/{PID}\Z", self._r_detail, rate="get")
        R("GET", rf"^/api/projects/{PID}/progress\Z", self._r_progress, rate="progress")
        R("GET", rf"^/api/projects/{PID}/messages\Z", self._r_messages_get, rate="get")
        R("GET", rf"^/api/projects/{PID}/approvals\Z", self._r_approvals, rate="get")
        R("GET", rf"^/api/projects/{PID}/deliverables\Z", self._r_deliverables, rate="get")
        R("GET", rf"^/api/projects/{PID}/files/(.+)\Z", self._r_file, rate="download")
        R("GET", rf"^/api/projects/{PID}/export\.zip\Z", self._r_zip, rate="zip")
        R("GET", rf"^/api/projects/{PID}/log\Z", self._r_log, rate="get")
        R("GET", r"^/api/admin/projects\Z", self._r_admin_list, rate=None, auth="owner")
        R("POST", r"^/api/projects\Z", self._r_create, rate="createAttempts")      # le débit « create » (6/h) est appliqué dans la route, après validation
        R("POST", rf"^/api/projects/{PID}/plan/approve\Z", self._r_plan_approve, rate="control")
        R("POST", rf"^/api/projects/{PID}/plan/reject\Z", self._r_plan_reject, rate="control")
        R("POST", rf"^/api/projects/{PID}/messages\Z", self._r_message_post, rate="messages")
        R("POST", rf"^/api/projects/{PID}/input\Z", self._r_input, rate="control")
        R("POST", rf"^/api/projects/{PID}/approvals/batch\Z", self._r_batch, rate=None)           # le débit compte les éléments (dans la route)
        R("POST", rf"^/api/projects/{PID}/approvals/(APR-[0-9a-f]{{8}})/approve\Z", self._r_approve, rate="approvals")
        R("POST", rf"^/api/projects/{PID}/approvals/(APR-[0-9a-f]{{8}})/reject\Z", self._r_reject, rate="approvals")
        for name, fn in (("pause", self._r_pause), ("resume", self._r_resume), ("cancel", self._r_cancel), ("retry-step", self._r_retry),
                         ("accept-gaps", self._r_gaps), ("budget", self._r_budget)):
            R("POST", rf"^/api/projects/{PID}/{name}\Z", fn, rate="control")
        R("POST", r"^/api/admin/projects/pause-client\Z", self._r_admin_pause_client, rate=None, auth="owner")
        R("POST", r"^/api/admin/projects/kill-all\Z", self._r_admin_kill_all, rate=None, auth="owner")
        R("POST", rf"^/api/admin/projects/{PID}/kill\Z", self._r_admin_kill, rate=None, auth="owner")
        R("DELETE", rf"^/api/projects/{PID}\Z", self._r_delete, rate="control")

    # ------------------------------------------------------------------ envoi
    def _json(self, handler, payload, status=200, headers=None):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        if headers is None and self.send_json is not None:
            self.send_json(handler, payload, status)
            return
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json; charset=utf-8")
        handler.send_header("Content-Length", str(len(body)))
        handler.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            handler.send_header(k, str(v))
        handler.end_headers()
        handler.wfile.write(body)

    def error(self, handler, code, detail, http_status=None, **extra):
        """Réponse d'erreur {"error","detail",...}. `http_status` est le code HTTP ; les champs libres (extra) passent dans le corps : un champ nommé « status »
        (le statut du projet, dans INVALID_STATE) ne doit jamais être pris pour le code HTTP."""
        retry = extra.pop("retryAfterSec", None)
        payload = {"error": code, "detail": detail}
        payload.update({k: v for k, v in extra.items() if v is not None})
        headers = {"Retry-After": int(retry)} if retry else None
        self._json(handler, payload, http_status or STATUS_OF.get(code, 400), headers)

    def _project_error(self, handler, e):
        if isinstance(e, ps.ProjectNotFound):
            self.error(handler, "NOT_FOUND", "Projet introuvable.", 404)
            return
        extra = dict(getattr(e, "extra", {}) or {})
        code = e.code
        if code == "RATE_LIMITED" and "retryAfterSec" not in extra:
            extra["retryAfterSec"] = 60
        self.error(handler, code, e.detail or code, **extra)

    def read_body(self, handler, limit):
        if self.read_json_limited is not None:
            return self.read_json_limited(handler, limit, True)
        try:
            length = int(handler.headers.get("Content-Length", 0) or 0)
        except ValueError:
            length = -1
        if length < 0 or length > limit:
            handler.close_connection = True
            self.error(handler, "TOO_LARGE", "Corps de requête trop volumineux.", 413)
            return None
        raw = handler.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8"))
        except Exception:  # noqa: BLE001
            body = None
        if not isinstance(body, dict):
            self.error(handler, "INVALID_JSON", "Un objet JSON est attendu.", 400)
            return None
        return body

    # ------------------------------------------------------------------ aiguillage
    def handle_get(self, handler, path, parsed=None):
        return self._dispatch("GET", handler, path, parsed)

    def handle_post(self, handler, path, parsed=None):
        return self._dispatch("POST", handler, path, parsed)

    def handle_delete(self, handler, path, parsed=None):
        return self._dispatch("DELETE", handler, path, parsed)

    def _dispatch(self, method, handler, path, parsed):
        route, m = None, None
        for rx, fn, rate, auth in self.routes[method]:
            m = rx.match(path)
            if m:
                route = (fn, rate, auth)
                break
        if route is None:
            return False
        fn, rate, auth = route
        parsed = parsed or urlparse(handler.path)
        try:
            if not self.service.enabled:
                self.error(handler, "PROJECTS_DISABLED", "Les projets ne sont pas encore activés.", 503)
                return True
            if method != "GET" and self._bad_origin(handler):
                self.error(handler, "BAD_ORIGIN", "Origine de la requête refusée.", 403)
                return True
            if auth == "owner":
                if not self.is_owner(handler):
                    self.error(handler, "GATE_REQUIRED", "Réservé au propriétaire.", 403)
                    return True
                client_id = None
            else:
                client_id = self.resolve_client_id(handler)
                if not client_id:
                    self.error(handler, "ACCOUNT_REQUIRED", "Connectez-vous pour utiliser les projets.", 401)
                    return True
                if not self.rate_pass(handler, rate, client_id):
                    return True
            out = fn(Req(self, handler, m, parsed, client_id))
            if out is None:
                return True
            payload, status = out if isinstance(out, tuple) else (out, 200)
            self._json(handler, payload, status)
        except ps.ProjectError as e:
            self._project_error(handler, e)
        except (BrokenPipeError, ConnectionError):
            raise
        except Exception as e:  # noqa: BLE001 - jamais de trace brute vers le client
            sys.stderr.write(f"[projects-api] {method} {path.split('?')[0][:80]} : {type(e).__name__}: {str(e)[:120]}\n")
            try:
                self.error(handler, "INTERNAL", "Erreur interne du serveur.", 500)
            except Exception:  # noqa: BLE001
                pass
        return True

    def _bad_origin(self, handler):
        origin = handler.headers.get("Origin")
        if not origin:
            return False
        if self.public_origin is None:
            return False
        return _origin(origin) != self.public_origin

    def rate_pass(self, handler, rate, client_id, n=1):
        """Applique la limite de débit `rate` (clé de service.limits["rates"]) ; répond 429 et renvoie False si dépassée."""
        if not rate:
            return True
        limit, window = self.service.limits["rates"].get(rate, (120, 60))
        if self.rate_ok is not None:
            ok, retry = bool(self.rate_ok(rate, client_id, limit, window)), 60
        else:
            ok, retry = self.limiter.hit((rate, client_id), int(limit), int(window), n)
        if not ok:
            self.error(handler, "RATE_LIMITED", "Trop de demandes : réessayez dans un instant.", 429, retryAfterSec=retry)
        return ok

    # ------------------------------------------------------------------ routes : lecture
    def _r_recipes(self, r):
        worker = r.query("workerId").lower()
        try:
            import recipes
        except ImportError:
            return {"recipes": []}
        try:
            rows = recipes.list_for_worker(worker) if worker else []
            return {"recipes": [recipes.public_summary(x) for x in rows]}
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"[projects-api] recipes : {type(e).__name__}\n")
            return {"recipes": []}

    def _r_list(self, r):
        statuses = [s for s in r.query("status").upper().split(",") if s]
        try:
            limit = int(r.query("limit", "25") or 25)
        except ValueError:
            limit = 25
        return self.service.list_projects(r.client_id, statuses, limit, r.query("cursor") or None)

    def _r_detail(self, r):
        return self.service.get_detail(r.client_id, r.match.group(1))

    def _r_progress(self, r):
        pid = r.match.group(1)
        st = r.owned(pid)
        etag = self.service.progress_etag(st)
        try:
            since = int(r.query("since", "0") or 0)
        except ValueError:
            since = 0
        if r.handler.headers.get("If-None-Match") == etag and since >= int(st.get("seq") or 0):
            r.handler.send_response(304)
            r.handler.send_header("ETag", etag)
            r.handler.send_header("Cache-Control", "no-store")
            r.handler.end_headers()
            return None
        payload = self.service.progress(r.client_id, pid, since)
        self._json(r.handler, payload, 200, {"ETag": etag})
        return None

    def _r_messages_get(self, r):
        try:
            since = int(r.query("since", "0") or 0)
        except ValueError:
            since = 0
        return self.service.list_messages(r.client_id, r.match.group(1), since)

    def _r_approvals(self, r):
        try:
            limit = int(r.query("limit", "50") or 50)
        except ValueError:
            limit = 50
        return self.service.list_approvals(r.client_id, r.match.group(1), r.query("status") or None, limit)

    def _r_deliverables(self, r):
        return self.service.list_deliverables(r.client_id, r.match.group(1))

    def _r_file(self, r):
        pid, rel = r.match.group(1), r.match.group(2)
        if rel.endswith("/preview"):
            return self.service.file_preview(r.client_id, pid, rel[:-len("/preview")])
        full, name, ctype, inline = self.service.resolve_download(r.client_id, pid, rel, r.query("inline") == "1")
        h = r.handler
        size = os.path.getsize(full)
        h.send_response(200)
        h.send_header("Content-Type", ctype)
        h.send_header("Content-Length", str(size))
        safe = _UNSAFE_NAME.sub("_", name)
        h.send_header("Content-Disposition", ("inline" if inline else "attachment") + f'; filename="{safe}"')
        h.send_header("X-Content-Type-Options", "nosniff")
        h.send_header("Content-Security-Policy", "default-src 'none'; sandbox")
        h.send_header("Cache-Control", "private, no-store")
        h.end_headers()
        with open(full, "rb") as f:
            shutil.copyfileobj(f, h.wfile, 64 * 1024)
        return None

    def _r_zip(self, r):
        scope = r.query("scope", "deliverables")
        if scope not in ("deliverables", "workspace"):
            raise ps.ProjectError("INVALID_INPUT", "scope : « deliverables » ou « workspace ».", field="scope")
        data, name = self.service.export_zip(r.client_id, r.match.group(1), scope)
        h = r.handler
        h.send_response(200)
        h.send_header("Content-Type", "application/zip")
        h.send_header("Content-Length", str(len(data)))
        h.send_header("Content-Disposition", f'attachment; filename="{_UNSAFE_NAME.sub("_", name)}.zip"')
        h.send_header("X-Content-Type-Options", "nosniff")
        h.send_header("Cache-Control", "private, no-store")
        h.end_headers()
        h.wfile.write(data)
        return None

    def _r_log(self, r):
        try:
            since, limit = int(r.query("since", "0") or 0), int(r.query("limit", "200") or 200)
        except ValueError:
            since, limit = 0, 200
        return self.service.get_log(r.client_id, r.match.group(1), since, limit)

    # ------------------------------------------------------------------ routes : écriture
    def _r_create(self, r):
        body = r.body(CREATE_BODY_LIMIT)
        if body is None:
            return None
        if self.service.read_control().get("killAll"):
            raise ps.ProjectError("PROJECTS_DISABLED", "Les projets sont momentanément suspendus par l'administration.")
        if not self.rate_pass(r.handler, "create", r.client_id):
            return None
        try:
            out = self.service.create_project(
                r.client_id, body.get("goal"), body.get("workerId") or "chloe", recipe_id=body.get("recipeId"), level=body.get("level") or "standard",
                credits_cap=body.get("creditsCap"), auto_start=bool(body.get("autoStart")), language=body.get("language"), inputs=body.get("inputs"))
        except ps.ProjectError as e:
            if STATUS_OF.get(e.code, 400) == 400 and self.rate_ok is None:
                self.limiter.refund(("create", r.client_id))               # une saisie invalide n'a rien créé : elle ne consomme pas le quota
            raise
        return out, 201

    def _r_plan_approve(self, r):
        b = r.body()
        if b is None:
            return None
        if b.get("startAnyway") is True:
            return self.service.start_anyway(r.client_id, r.match.group(1), credits_cap=b.get("creditsCap"))
        return self.service.approve_plan(r.client_id, r.match.group(1), credits_cap=b.get("creditsCap"), level=b.get("level"),
                                         remove_steps=b.get("removeSteps"), auto_start=b.get("autoStart") if "autoStart" in b else None)

    def _r_plan_reject(self, r):
        b = r.body()
        if b is None:
            return None
        return self.service.reject_plan(r.client_id, r.match.group(1), b.get("feedback"))

    def _r_message_post(self, r):
        b = r.body()
        if b is None:
            return None
        return self.service.post_message(r.client_id, r.match.group(1), b.get("type") if isinstance(b.get("type"), str) else None, b.get("text"),
                                         b.get("stepId") if isinstance(b.get("stepId"), str) else None), 202

    def _r_input(self, r):
        b = r.body()
        if b is None:
            return None
        return self.service.answer_input(r.client_id, r.match.group(1), b.get("questionId") if isinstance(b.get("questionId"), str) else None, b.get("answer"))

    def _r_approve(self, r):
        b = r.body()
        if b is None:
            return None
        params = b.get("params")
        confirm = b.get("confirm") if isinstance(b.get("confirm"), str) else None
        return self.service.approve_approval(r.client_id, r.match.group(1), r.match.group(2), params, confirm)

    def _r_reject(self, r):
        b = r.body()
        if b is None:
            return None
        return self.service.reject_approval(r.client_id, r.match.group(1), r.match.group(2), b.get("reason") if isinstance(b.get("reason"), str) else None)

    def _r_batch(self, r):
        b = r.body()
        if b is None:
            return None
        ids = b.get("ids")
        n = len(ids) if isinstance(ids, list) else 1
        if not self.rate_pass(r.handler, "approvals", r.client_id, n=max(1, min(n, 50))):
            return None
        return self.service.batch_approvals(r.client_id, r.match.group(1), ids, b.get("decision"), b.get("reason") if isinstance(b.get("reason"), str) else None)

    def _r_pause(self, r):
        return self.service.pause(r.client_id, r.match.group(1))

    def _r_resume(self, r):
        return self.service.resume(r.client_id, r.match.group(1))

    def _r_cancel(self, r):
        b = r.body()
        if b is None:
            return None
        return self.service.cancel(r.client_id, r.match.group(1), b.get("reason") if isinstance(b.get("reason"), str) else None)

    def _r_retry(self, r):
        b = r.body()
        if b is None:
            return None
        return self.service.retry_step(r.client_id, r.match.group(1), b.get("stepId") if isinstance(b.get("stepId"), str) else None)

    def _r_gaps(self, r):
        b = r.body()
        if b is None:
            return None
        return self.service.accept_gaps(r.client_id, r.match.group(1), b.get("criteriaIds"))

    def _r_budget(self, r):
        b = r.body()
        if b is None:
            return None
        return self.service.set_budget(r.client_id, r.match.group(1), b.get("creditsCap"))

    def _r_delete(self, r):
        return self.service.delete_project(r.client_id, r.match.group(1), r.query("confirm") == "1")

    # ------------------------------------------------------------------ administration (porte propriétaire)
    def _r_admin_list(self, r):
        return self.service.admin_list()

    def _r_admin_pause_client(self, r):
        b = r.body()
        if b is None:
            return None
        return self.service.admin_pause_client(b.get("clientId"), bool(b.get("paused", True)))

    def _r_admin_kill_all(self, r):
        b = r.body()
        if b is None:
            return None
        return self.service.admin_kill_all(bool(b.get("on", True)))

    def _r_admin_kill(self, r):
        return self.service.admin_kill_project(r.match.group(1))
