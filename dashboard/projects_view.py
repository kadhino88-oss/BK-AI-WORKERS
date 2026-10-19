# -*- coding: utf-8 -*-
"""Vues d'un projet pour l'API (docs/AUTONOMY-ENGINE.md, sections 7.2 à 7.4) : résumé, détail, progression, validations, livrables, fichiers, journal.

Mixin de ProjectService (projects.py). Lecture seule : rien n'est écrit ici (un seul écrivain, projects_store). Toutes les méthodes prennent le
`client_id` de la session et lèvent ProjectNotFound (404) pour le projet d'un autre client. Les identifiants de fichiers et de conteneurs du
fournisseur d'IA n'apparaissent jamais dans ces réponses (aucun n'est conservé hors de steps/<étape>/<tentative>/files-api.json).
"""
import datetime
import io
import json
import os
import zipfile

import project_paths as pp
import projects_approvals as pa
import projects_plan
import projects_store as ps
import projects_usage as pu

TEXT_PREVIEW_EXT = ("xlsx", "xlsm", "docx", "pptx", "csv", "tsv", "txt", "md", "json")
INLINE_EXT = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "pdf": "application/pdf"}
MIME = {"html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript", "json": "application/json",
        "md": "text/markdown", "txt": "text/plain", "csv": "text/csv", "tsv": "text/tab-separated-values", "svg": "image/svg+xml", "xml": "application/xml",
        "yml": "text/yaml", "yaml": "text/yaml", "ics": "text/calendar", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp",
        "gif": "image/gif", "ico": "image/x-icon", "woff2": "font/woff2", "pdf": "application/pdf",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation", "zip": "application/zip"}
ZIP_MAX_BYTES = 200 * 1024 * 1024
STEP_STATUS_ORDER = {"RUNNING": 0, "READY": 1, "BLOCKED": 2, "PENDING": 3, "PARTIAL": 4, "FAILED": 5, "DONE": 6, "SKIPPED": 7}


def _clip(text, n):
    text = str(text or "")
    return text if len(text) <= n else text[:n - 1] + "…"


class ViewMixin:
    # ------------------------------------------------------------------ petits calculs
    def usage_cached(self, client_id):
        """Vue d'usage mise en cache 5 s par client (la progression est interrogée toutes les 3 s)."""
        hit = self._usage_cache.get(client_id)
        t = self.now()
        if hit and t - hit[0] < 5:
            return hit[1]
        try:
            raw = self.usage.remaining(client_id)
            v = pu.view_summary(raw)
            v["nextRenewalUtc"] = pu.binding_reset(raw) if v.get("binding") else None
        except Exception:  # noqa: BLE001
            v = {"binding": None, "allowedNow": 0, "exempt": False, "nextRenewalUtc": None}
        self._usage_cache[client_id] = (t, v)
        return v

    def queue_position(self, st):
        if st.get("status") != "QUEUED":
            return None
        ids = self.queued_ids(st["clientId"])
        return (ids.index(st["projectId"]) + 1) if st["projectId"] in ids else None

    def _plan_steps(self, pid):
        return (self.read_plan(pid).get("steps") or [])

    def _percent(self, st, plan_steps):
        if st.get("status") == "DONE":
            return 100
        if not plan_steps:
            return 5 if st.get("status") in ("PLANNING", "RUNNING") and any(s.get("status") == "RUNNING" for s in st["steps"].values()) else 0
        cap = 95
        return projects_plan.percent_done(plan_steps, lambda sid: (st["steps"].get(sid) or {}).get("status"), cap=cap)

    def _current_step(self, st):
        rows = [s for s in st["steps"].values() if s.get("status") == "RUNNING" and s.get("kind") != "answer"]
        if not rows:
            rows = [s for s in st["steps"].values() if s.get("status") == "READY" and s.get("kind") != "answer"]
        if not rows:
            return None
        s = sorted(rows, key=lambda x: (STEP_STATUS_ORDER.get(x.get("status"), 9), x.get("createdUtc") or ""))[0]
        return {"id": s["id"], "title": s.get("title"), "worker": s.get("worker"), "startedUtc": s.get("startedUtc"), "kind": s.get("kind")}

    def _eta_minutes(self, st, plan_steps):
        """Estimation grossière du temps restant : durée moyenne mesurée des étapes terminées, sinon la fourchette d'heures du plan."""
        if st.get("status") in ps.TERMINAL:
            return None
        done = [s for s in st["steps"].values() if s.get("status") == "DONE" and s.get("startedUtc") and s.get("finishedUtc")]
        left = [s for s in plan_steps if (st["steps"].get(s["id"]) or {}).get("status") not in ("DONE", "SKIPPED")]
        if not left:
            return 5 if st.get("phase") in ("verify", "consolidate") else 0
        if done:
            durs = [(ps.parse_iso(s["finishedUtc"]) or 0) - (ps.parse_iso(s["startedUtc"]) or 0) for s in done]
            durs = [d for d in durs if d > 0]
            if durs:
                return int(round(len(left) * (sum(durs) / len(durs)) / 60.0)) + 5
        est = (st.get("budget") or {}).get("estimate") or {}
        hmax = est.get("hoursMax")
        return int(round(float(hmax) * 60)) if isinstance(hmax, (int, float)) and hmax else None

    def _open_questions(self, st):
        return [q for q in st.get("questions") or [] if not q.get("answeredUtc")]

    def capabilities(self, st):
        status = st["status"]
        wf = st.get("waitingFor")
        pausable = status not in ps.TERMINAL and status not in ("PAUSED", "QUEUED", "BUDGET_REACHED") and not (status == "WAITING_INPUT" and wf in ("PLAN_VALIDATION", "CRITERIA_FAILED"))
        owner_paused = status == "PAUSED" and st.get("statusReason") == "OWNER_PAUSED" and st["clientId"] in (self.read_control().get("pausedClients") or [])
        return {"canPause": pausable, "canResume": status == "PAUSED" and not owner_paused,
                "canCancel": status not in ("DONE", "CANCELLED"), "canApprove": status != "CANCELLED",
                "canApprovePlan": status == "WAITING_INPUT" and wf == "PLAN_VALIDATION",
                "canAcceptGaps": (status == "WAITING_INPUT" and wf == "CRITERIA_FAILED") or status == "BUDGET_REACHED",
                "canRaiseBudget": status not in ("DONE", "CANCELLED"), "canDelete": status in ps.TERMINAL,
                "canMessage": status not in ps.TERMINAL}

    # ------------------------------------------------------------------ résumé et liste
    def project_summary(self, st):
        pid = st["projectId"]
        plan_steps = self._plan_steps(pid)
        workers = []
        for s in plan_steps:
            if s.get("worker") and s["worker"] not in workers:
                workers.append(s["worker"])
        if st.get("leadWorker") and st["leadWorker"] not in workers:
            workers.insert(0, st["leadWorker"])
        b = st.get("budget") or {}
        return {"projectId": pid, "title": st.get("title"), "goal": _clip(st.get("goal"), 200), "status": st["status"], "waitingFor": st.get("waitingFor"),
                "statusReason": st.get("statusReason"), "leadWorker": st.get("leadWorker"), "workers": workers, "percent": self._percent(st, plan_steps),
                "currentStep": self._current_step(st), "createdUtc": st.get("createdUtc"), "updatedUtc": st.get("updatedUtc"),
                "creditsCharged": int(b.get("creditsCharged") or 0), "creditsCap": int(b.get("creditsCap") or 0),
                "approvalsPending": int((st.get("approvals") or {}).get("pending") or 0), "inputsPending": len(self._open_questions(st)),
                "resumeAtUtc": st.get("resumeAtUtc"), "queuePosition": self.queue_position(st)}

    def list_projects(self, client_id, statuses=None, limit=25, cursor=None):
        if not ps.CLIENT_ID_RE.match(client_id or ""):
            return {"projects": [], "nextCursor": None}
        wanted = {s for s in (statuses or []) if s in ps.STATUSES}
        rows = []
        for pid in self.store.ids_of_client(client_id):
            try:
                st = self.store.state(pid)
            except ps.ProjectError:
                continue
            if wanted and st.get("status") not in wanted:
                continue
            rows.append((st.get("createdUtc") or "", pid, st))
        rows.sort(reverse=True)
        start = 0
        if cursor:
            for i, (_c, pid, _s) in enumerate(rows):
                if pid == cursor:
                    start = i + 1
                    break
        limit = max(1, min(int(limit or 25), 100))
        page = rows[start:start + limit]
        nxt = page[-1][1] if len(rows) > start + limit and page else None
        return {"projects": [self.project_summary(st) for _c, _p, st in page], "nextCursor": nxt}

    # ------------------------------------------------------------------ détail
    def _worker_card(self, wid):
        w = dict(self.worker_summary(wid) or {})
        w.setdefault("id", wid)
        w.setdefault("name", str(wid).capitalize())
        w.setdefault("portraitUrl", f"/portraits/{wid}.jpg")
        return w

    def _plan_view(self, st, plan, deliverables):
        verdicts = {c["id"]: c for c in (st.get("verification") or {}).get("criteria") or []}
        by_step = {}
        for d in deliverables:
            by_step.setdefault(d.get("stepId"), []).append({"path": d.get("path"), "title": d.get("title"), "kind": d.get("kind")})
        steps = []
        seen = set()
        for s in plan.get("steps") or []:
            ss = st["steps"].get(s["id"]) or {}
            seen.add(s["id"])
            steps.append({"id": s["id"], "title": s.get("title"), "worker": s.get("worker"), "goal": _clip(s.get("goal"), 600), "dependsOn": s.get("dependsOn") or [],
                          "criteriaIds": s.get("criteriaIds") or [], "effort": s.get("effort"), "status": ss.get("status", "PENDING"), "attempts": ss.get("attempts", 0),
                          "blockedReason": ss.get("blockedReason"), "summary": ss.get("summary"), "handoffNote": ss.get("handoffNote"), "credits": ss.get("credits", 0),
                          "estimateCredits": s.get("estimateCredits"), "deliverables": by_step.get(s["id"], []), "kind": "execute", "system": False,
                          "startedUtc": ss.get("startedUtc"), "finishedUtc": ss.get("finishedUtc")})
        for sid, ss in st["steps"].items():
            if sid in seen:
                continue
            steps.append({"id": sid, "title": ss.get("title"), "worker": ss.get("worker"), "goal": None, "dependsOn": [], "criteriaIds": (ss.get("spec") or {}).get("criteriaIds") or [],
                          "effort": "normal", "status": ss.get("status"), "attempts": ss.get("attempts", 0), "blockedReason": ss.get("blockedReason"), "summary": ss.get("summary"),
                          "handoffNote": ss.get("handoffNote"), "credits": ss.get("credits", 0), "estimateCredits": None, "deliverables": by_step.get(sid, []),
                          "kind": ss.get("kind"), "system": True, "startedUtc": ss.get("startedUtc"), "finishedUtc": ss.get("finishedUtc")})
        crit = []
        for c in plan.get("criteria") or []:
            v = verdicts.get(c["id"]) or {}
            crit.append({"id": c["id"], "text": c.get("text"), "kind": c.get("kind"), "verdict": v.get("verdict"), "note": v.get("note"),
                         "accepted": c["id"] in (st.get("acceptedGaps") or [])})
        return {"goal": plan.get("goal") or st.get("goal"), "language": plan.get("language") or st.get("language"), "version": st.get("planVersion"),
                "assumptions": plan.get("assumptions") or [], "criteria": crit, "steps": steps, "estimate": plan.get("estimate") or (st.get("budget") or {}).get("estimate") or {},
                "needsFromClient": plan.get("needsFromClient") or [], "risks": plan.get("risks") or [], "unassignable": plan.get("unassignable") or [],
                "delegation": plan.get("delegation"), "fallback": bool(plan.get("fallback")), "milestones": plan.get("milestones") or [],
                "approved": bool(st.get("planApproved"))}

    def _workers_view(self, st, plan, deliverables, approvals):
        order = []
        for s in plan.get("steps") or []:
            if s.get("worker") and s["worker"] not in order:
                order.append(s["worker"])
        for s in st["steps"].values():
            w = s.get("worker")
            if w and w not in order and w != "qa" and s.get("kind") not in ("verify",):
                order.append(w)
        out = []
        for wid in order:
            mine = [s for sid, s in st["steps"].items() if s.get("worker") == wid and s.get("kind") not in ("verify", "answer")]
            total = [s for s in (plan.get("steps") or []) if s.get("worker") == wid] or mine
            done = [s for s in mine if s.get("status") in ("DONE", "SKIPPED")]
            if any(s.get("status") == "RUNNING" for s in mine):
                status = "RUNNING"
            elif any(s.get("status") == "BLOCKED" for s in mine):
                status = "BLOCKED"
            elif mine and len(done) == len(mine):
                status = "DONE"
            elif any(s.get("status") in ("FAILED",) for s in mine):
                status = "FAILED"
            else:
                status = "WAITING"
            last = next((s.get("summary") for s in sorted(mine, key=lambda x: x.get("finishedUtc") or "", reverse=True) if s.get("summary")), None)
            card = self._worker_card(wid)
            out.append({"id": wid, "name": card.get("name"), "portraitUrl": card.get("portraitUrl"), "role": card.get("role"), "stepsDone": len(done),
                        "stepsTotal": max(len(total), len(mine)), "status": status, "creditsUsed": sum(int(s.get("credits") or 0) for s in mine),
                        "lastSummary": _clip(last, 300) if last else None,
                        "deliverables": [{"path": d.get("path"), "title": d.get("title"), "kind": d.get("kind")} for d in deliverables if d.get("worker") == wid],
                        "approvalsPending": sum(1 for a in approvals if a.get("worker") == wid and a.get("status") == "PENDING")})
        return out

    def get_detail(self, client_id, pid):
        st = self.owned_state(client_id, pid)
        plan = self.read_plan(pid)
        deliverables = (self.store.read_json(pid, "deliverables.json", {}) or {}).get("items") or []
        approvals = pa.load_items(self.store, pid)
        out = self.project_summary(st)
        b = st.get("budget") or {}
        events, _more, _reset = self.store.events_since(pid, 0, 2000)
        out.update({
            "plan": self._plan_view(st, plan, deliverables), "workers": self._workers_view(st, plan, deliverables, approvals),
            "budget": {"creditsCap": int(b.get("creditsCap") or 0), "creditsCharged": int(b.get("creditsCharged") or 0), "chfCeiling": b.get("chfCeiling"),
                       "estimate": b.get("estimate") or {}, "capSetByClient": bool(b.get("capSetByClient")), "level": st.get("level"),
                       "costToFinishCredits": self._cost_to_finish(st, plan)},
            "usage": self.usage_cached(client_id),
            "deliverables": [self._deliverable_view(d) for d in deliverables],
            "approvals": {"counts": pa.counts(approvals)},
            "questions": [{"id": q.get("id"), "question": q.get("question"), "why": q.get("why"), "blocking": bool(q.get("blocking")), "choices": q.get("choices") or [],
                           "default": q.get("default"), "stepId": q.get("stepId"), "worker": q.get("worker")} for q in self._open_questions(st)],
            "verification": st.get("verification"), "events": events[-30:], "site": self._site_info(st), "capabilities": self.capabilities(st),
            "notices": (st.get("notices") or [])[-5:], "acceptedGaps": st.get("acceptedGaps") or [], "doneProblems": st.get("doneProblems") or [],
            "scope": st.get("scope"), "level": st.get("level"), "autoStart": bool(st.get("autoStart")), "recipeId": st.get("recipeId"), "language": st.get("language"),
            "hasFinalReport": os.path.isfile(os.path.join(self.store.project_dir(pid), "final-report.md")),
            "planNotice": st.get("planNotice"),
        })
        return out

    def _cost_to_finish(self, st, plan):
        left = [s for s in plan.get("steps") or [] if (st["steps"].get(s["id"]) or {}).get("status") not in ("DONE", "SKIPPED")]
        est = sum(float(s.get("estimateCredits") or 5) for s in left)
        done = [s for s in plan.get("steps") or [] if (st["steps"].get(s["id"]) or {}).get("status") == "DONE" and s.get("estimateCredits")]
        coef = 1.0
        if done:
            planned = sum(float(s["estimateCredits"]) for s in done)
            actual = sum(int((st["steps"].get(s["id"]) or {}).get("credits") or 0) for s in done)
            if planned > 0 and actual > 0:
                coef = max(0.5, min(3.0, actual / planned))
        return int(round(est * coef))

    def _site_info(self, st):
        fn = getattr(self, "site_info", None)
        if callable(fn):
            try:
                return fn(st)
            except Exception:  # noqa: BLE001
                return None
        return None

    def _deliverable_view(self, d):
        ext = pp.ext_of(d.get("path") or "")
        return {"path": d.get("path"), "title": d.get("title"), "kind": d.get("kind"), "bytes": d.get("bytes"), "stepId": d.get("stepId"), "worker": d.get("worker"),
                "createdUtc": d.get("createdUtc"), "previewable": ext in TEXT_PREVIEW_EXT or ext in INLINE_EXT, "description": d.get("description")}

    # ------------------------------------------------------------------ progression (interrogation)
    def progress_etag(self, st):
        return f'"p{st["projectId"]}-{int(st.get("seq") or 0)}"'

    def progress(self, client_id, pid, since=0):
        st = self.owned_state(client_id, pid)
        plan_steps = self._plan_steps(pid)
        events, more, reset = self.store.events_since(pid, max(0, int(since or 0)), 200)
        b = st.get("budget") or {}
        running = [s for s in st["steps"].values() if s.get("status") == "RUNNING"]
        usage = self.usage_cached(st["clientId"])
        out = {"seq": int(st.get("seq") or 0), "status": st["status"], "waitingFor": st.get("waitingFor"), "statusReason": st.get("statusReason"),
               "percent": self._percent(st, plan_steps), "currentStep": self._current_step(st), "stepsRunning": len(running),
               "queuePosition": self.queue_position(st), "resumeAtUtc": st.get("resumeAtUtc"), "approvalsPending": int((st.get("approvals") or {}).get("pending") or 0),
               "inputsPending": len(self._open_questions(st)), "creditsCharged": int(b.get("creditsCharged") or 0), "creditsCap": int(b.get("creditsCap") or 0),
               "usage": {"binding": usage.get("binding"), "allowedNow": usage.get("allowedNow"), "nextRenewalUtc": usage.get("nextRenewalUtc")},
               "etaMinutes": self._eta_minutes(st, plan_steps), "events": [self._event_view(e) for e in events], "hasMore": bool(more), "reset": bool(reset)}
        return out

    def _event_view(self, e):
        out = {"seq": e.get("seq"), "ts": e.get("ts"), "type": e.get("type"), "text": e.get("text")}
        if e.get("stepId"):
            out["stepId"] = e["stepId"]
        if e.get("worker"):
            out["worker"] = e["worker"]
        if e.get("data"):
            out["data"] = e["data"]
        return out

    def get_log(self, client_id, pid, since=0, limit=200):
        self.owned_state(client_id, pid)
        evs = [e for e in self.store.read_jsonl(pid, "events.jsonl") if int(e.get("seq") or 0) > int(since or 0)]
        limit = max(1, min(int(limit or 200), 500))
        return {"events": [self._event_view(e) for e in evs[:limit]], "hasMore": len(evs) > limit}

    # ------------------------------------------------------------------ validations
    def list_approvals(self, client_id, pid, status=None, limit=50):
        self.owned_state(client_id, pid)
        items = pa.load_items(self.store, pid)
        wanted = {s.strip().upper() for s in str(status or "").split(",") if s.strip()}
        shown = [i for i in items if not wanted or i.get("status") in wanted]
        limit = max(1, min(int(limit or 50), 200))
        return {"approvals": [pa.public_view(i) for i in shown[:limit]], "counts": pa.counts(items)}

    # ------------------------------------------------------------------ livrables et fichiers
    def list_deliverables(self, client_id, pid):
        self.owned_state(client_id, pid)
        items = (self.store.read_json(pid, "deliverables.json", {}) or {}).get("items") or []
        return {"deliverables": [self._deliverable_view(d) for d in items]}

    def resolve_download(self, client_id, pid, rel, inline=False):
        """(chemin absolu, nom, type MIME, en ligne ?) d'un fichier de l'espace de travail ; confiné et sans lien symbolique (3.4).
        « final-report.md » à la racine du projet est servi aussi."""
        self.owned_state(client_id, pid)
        proj_dir = self.store.project_dir(pid)
        if rel == "final-report.md":
            full = os.path.join(proj_dir, "final-report.md")
            if not os.path.isfile(full):
                raise ps.ProjectNotFound(pid)
        else:
            try:
                full = pp.resolve(os.path.join(proj_dir, "workspace"), rel, kind="file", must_exist=True, allowed_ext=set(pp.IMPORT_EXT))
            except pp.PathError as e:
                if e.code == "NOT_FOUND":
                    raise ps.ProjectNotFound(pid)
                raise ps.ProjectError("INVALID_PATH", e.detail)
        ext = pp.ext_of(full)
        name = os.path.basename(full)
        inline_ok = bool(inline) and ext in INLINE_EXT
        return full, name, (INLINE_EXT.get(ext) if inline_ok else MIME.get(ext, "application/octet-stream")), inline_ok

    def file_preview(self, client_id, pid, rel):
        self.owned_state(client_id, pid)
        proj_dir = self.store.project_dir(pid)
        try:
            full = pp.resolve(os.path.join(proj_dir, "workspace"), rel, kind="file", must_exist=True, allowed_ext=set(pp.IMPORT_EXT))
        except pp.PathError as e:
            if e.code == "NOT_FOUND":
                raise ps.ProjectNotFound(pid)
            raise ps.ProjectError("INVALID_PATH", e.detail)
        import file_preview
        name = os.path.basename(full)
        try:
            return {"ok": True, "filename": name, "preview": file_preview.build_preview(full, name)}
        except file_preview.PreviewError as e:
            return {"ok": False, "filename": name, "error": str(e)}

    def export_zip(self, client_id, pid, scope="deliverables"):
        """Archive zip (en mémoire, bornée à 200 Mo) des livrables, ou de tout l'espace de travail. Noms triés, dates fixes (reproductible)."""
        st = self.owned_state(client_id, pid)
        proj_dir = self.store.project_dir(pid)
        ws = os.path.join(proj_dir, "workspace")
        names = []
        if scope == "workspace":
            names = [r for r, _s, _m in pp.walk_files(ws, limit=2000)]
        else:
            for d in (self.store.read_json(pid, "deliverables.json", {}) or {}).get("items") or []:
                p = d.get("path") or ""
                if p.endswith("/"):
                    base = p.rstrip("/")
                    try:
                        sub = pp.resolve(ws, base, kind="dir", must_exist=True)
                    except pp.PathError:
                        continue
                    names += [f"{base}/{rel}" for rel, _s, _m in pp.walk_files(sub, limit=2000)]
                else:
                    names.append(p)
        buf = io.BytesIO()
        total = 0
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
            for rel in sorted(set(names)):
                try:
                    full = pp.resolve(ws, rel, kind="file", must_exist=True)
                except pp.PathError:
                    continue
                size = os.path.getsize(full)
                total += size
                if total > ZIP_MAX_BYTES:
                    raise ps.ProjectError("TOO_LARGE", "L'archive dépasserait 200 Mo : téléchargez les fichiers un par un.")
                info = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                with open(full, "rb") as f:
                    z.writestr(info, f.read())
            report = os.path.join(proj_dir, "final-report.md")
            if os.path.isfile(report):
                info = zipfile.ZipInfo("final-report.md", date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(report, "rb") as f:
                    z.writestr(info, f.read())
        return buf.getvalue(), f"{(st.get('title') or 'projet')[:40]}".replace(" ", "-").replace("/", "-")

    # ------------------------------------------------------------------ export des données du compte (RGPD)
    def export_client(self, client_id):
        """Objectifs, plans, livrables (liste), validations et journaux d'un client, sans le contenu des fichiers (téléchargeables en zip)."""
        out = []
        for pid in self.store.ids_of_client(client_id):
            try:
                st = self.store.state(pid)
            except ps.ProjectError:
                continue
            out.append({"summary": self.project_summary(st), "goal": st.get("goal"), "plan": self.read_plan(pid),
                        "deliverables": (self.store.read_json(pid, "deliverables.json", {}) or {}).get("items") or [],
                        "approvals": [pa.public_view(i) for i in pa.load_items(self.store, pid)],
                        "decisions": self.store.read_jsonl(pid, "decisions.jsonl"), "events": self.store.read_jsonl(pid, "events.jsonl")[-1000:],
                        "budget": st.get("budget")})
        return {"projects": out}

