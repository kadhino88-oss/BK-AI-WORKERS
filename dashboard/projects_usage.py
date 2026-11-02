# -*- coding: utf-8 -*-
"""Interface d'usage du moteur de projets (docs/AUTONOMY-ENGINE.md, section 6b.8) : accès tolérant à UsageService (B2) et repli « mois seul ».

Le moteur parle à un objet `usage` qui respecte l'interface de la section 6b.8 :
    remaining(client_id)  -> UsageView {session, week, month: Window(limit, used, reserved, remaining, startUtc, resetsAtUtc), binding, allowedNow, exempt}
    reserve(client_id, credits, kind, ref, ttl_s=None, allow_partial=False) -> Reservation(id, credits) | UsageBlock(limit, resetsAtUtc, remaining, needed, view)
    settle(client_id, reservation_id, actual_credits) ; release(client_id, reservation_id) ; next_renewal(client_id)
Les accesseurs ci-dessous lisent indifféremment un objet (dataclass) ou un dict. Tant que le chantier « limites d'usage » n'est pas fusionné
(ou si BK_USAGE_WINDOWS=0), le serveur donne `MonthOnlyUsage` : seul le mois borne, comme aujourd'hui, mais les crédits des projets (qui ne sont
pas des fichiers TASK-*.json) sont bien comptés dans le mois grâce aux journaux de coût des projets.
"""
import json
import os
import secrets
import threading
import time
import types

import projects_store as ps


def g(obj, name, default=None):
    if obj is None:
        return default
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


def is_block(res):
    """UsageBlock (refus) ou Reservation (accord) ?"""
    return res is not None and (g(res, "needed") is not None or (g(res, "limit") is not None and g(res, "credits") is None))


def reservation_id(res):
    return g(res, "id") or g(res, "reservation_id") or g(res, "reservationId")


def window_dict(w):
    if w is None:
        return None
    return {"limit": g(w, "limit"), "used": g(w, "used"), "reserved": g(w, "reserved"), "remaining": g(w, "remaining"),
            "opened": g(w, "opened"), "startUtc": g(w, "startUtc"), "resetsAtUtc": g(w, "resetsAtUtc")}


def view_summary(view):
    """Extrait stable d'une UsageView pour les réponses de l'API et les décisions du superviseur."""
    return {"binding": g(view, "binding"), "allowedNow": int(g(view, "allowedNow", 0) or 0), "exempt": bool(g(view, "exempt", False)),
            "session": window_dict(g(view, "session")), "week": window_dict(g(view, "week")), "month": window_dict(g(view, "month"))}


def binding_reset(view):
    """Heure ISO de fin de la fenêtre qui borne (celle de `binding`), sinon la première date de renouvellement connue."""
    b = g(view, "binding")
    if b:
        r = g(g(view, b), "resetsAtUtc")
        if r:
            return r
    for name in ("session", "week", "month"):
        r = g(g(view, name), "resetsAtUtc")
        if r:
            return r
    return None


class MonthOnlyUsage:
    """Repli : borne MENSUELLE seule (comportement actuel), crédits des projets inclus.

    month_view(client_id) -> {"limit": int, "used": int, "resetsAtUtc": str|None, "cycleStartUtc": str|None, "exempt": bool}
    où `used` compte les missions (fichiers TASK-*.json) ; les crédits des projets sont ajoutés d'après runtime/projects/<ClientId>/*/cost-ledger.jsonl."""

    def __init__(self, root, month_view, now=time.time, nudge=None):
        self.root = root
        self.month_view = month_view
        self.now = now
        self.nudge = nudge
        self._rsv = {}
        self._lock = threading.Lock()

    def project_credits(self, client_id, since_utc):
        base = os.path.join(self.root, "runtime", "projects", client_id)
        since = ps.parse_iso(since_utc) or 0
        total = 0
        try:
            names = os.listdir(base)
        except OSError:
            return 0
        for n in names:
            p = os.path.join(base, n, "cost-ledger.jsonl")
            try:
                with open(p, encoding="utf-8") as f:
                    for line in f:
                        try:
                            rec = json.loads(line)
                        except ValueError:
                            continue
                        if (ps.parse_iso(rec.get("ts")) or 0) >= since:
                            total += int(rec.get("credits") or 0)
            except OSError:
                continue
        return total

    def _purge(self):
        t = self.now()
        for rid in [k for k, v in self._rsv.items() if v["expires"] < t]:
            self._rsv.pop(rid, None)

    def remaining(self, client_id, now=None):
        mv = self.month_view(client_id) or {}
        if mv.get("exempt"):
            return types.SimpleNamespace(session=None, week=None, month=None, binding=None, allowedNow=10 ** 9, exempt=True)
        limit = int(mv.get("limit") or 0)
        used = int(mv.get("used") or 0) + self.project_credits(client_id, mv.get("cycleStartUtc"))
        with self._lock:
            self._purge()
            reserved = sum(v["credits"] for v in self._rsv.values() if v["client"] == client_id)
        rem = max(0, limit - used - reserved)
        month = types.SimpleNamespace(limit=limit, used=used, reserved=reserved, remaining=rem, opened=True, startUtc=mv.get("cycleStartUtc"),
                                      resetsAtUtc=mv.get("resetsAtUtc"))
        return types.SimpleNamespace(session=None, week=None, month=month, binding="month", allowedNow=rem, exempt=False)

    def reserve(self, client_id, credits, kind, ref, ttl_s=None, allow_partial=False):
        view = self.remaining(client_id)
        credits = int(credits)
        if g(view, "exempt"):
            rid = "RSV-" + secrets.token_hex(6)
            return types.SimpleNamespace(id=rid, credits=credits, kind=kind, ref=ref)
        allowed = int(g(view, "allowedNow", 0))
        if allowed < credits and not (allow_partial and allowed > 0):
            return types.SimpleNamespace(limit="month", resetsAtUtc=g(g(view, "month"), "resetsAtUtc"), remaining=allowed, needed=credits, view=view)
        take = min(credits, allowed) if allow_partial else credits
        rid = "RSV-" + secrets.token_hex(6)
        with self._lock:
            self._rsv[rid] = {"client": client_id, "credits": take, "expires": self.now() + float(ttl_s or 900)}
        return types.SimpleNamespace(id=rid, credits=take, kind=kind, ref=ref)

    def settle(self, client_id, rsv_id, actual_credits):
        with self._lock:
            self._rsv.pop(rsv_id, None)

    def release(self, client_id, rsv_id):
        with self._lock:
            self._rsv.pop(rsv_id, None)

    def next_renewal(self, client_id):
        mv = self.month_view(client_id) or {}
        return mv.get("resetsAtUtc")

    def charge(self, client_id, credits, kind, ref):
        return None

    def reconcile(self, client_id):
        return {}

    def on_billing_saved(self, client_id):
        if self.nudge:
            self.nudge()
