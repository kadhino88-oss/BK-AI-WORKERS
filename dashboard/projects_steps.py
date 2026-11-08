# -*- coding: utf-8 -*-
"""Vie d'une étape de projet (docs/AUTONOMY-ENGINE.md, sections 2.5, 3, 4, 5, 6.3) : porte de budget avant CHAQUE étape, lancement du
sous-processus, surveillance, fin (règlement du coût, ingestion du spool, rapport), recalcul du projet, reprise.

Mixin de ProjectService (projects.py) : un seul objet, un seul superviseur. Toute écriture d'état passe par une transaction du magasin
(`with self.store.txn(pid) as t:`) ; rien ici n'est écrit hors du verrou du projet.
"""
import hashlib
import json
import math
import os
import re
import secrets
import sys
import time

import project_paths as pp
import project_tools
import projects_approvals as pa
import projects_config as cfg
import projects_context as pc
import projects_plan
import projects_store as ps
import projects_usage as pu
import projects_verify as pv

SATISFIED = ("DONE", "SKIPPED")
SERVER_TOOLS = {"plan": ("web_search", "web_fetch"), "replan": ("web_search", "web_fetch"), "execute": ("web_search", "web_fetch", "code_execution"),
                "fix": ("web_search", "web_fetch", "code_execution"), "verify": ("web_fetch",), "consolidate": (), "answer": ()}
BINARY_INPUT_EXT = ("csv", "xlsx", "docx", "pdf", "pptx", "zip", "png", "jpg", "jpeg", "webp", "gif", "json", "xml")
NO_RECOMPUTE = frozenset(("DONE", "CANCELLED", "FAILED", "QUEUED", "BUDGET_REACHED", "PAUSED", "WAITING_QUOTA"))


def _read_json(path, default=None):
    return cfg.read_json(path, default)


class StepMixin:
    # ------------------------------------------------------------------ outils d'accès
    def step_spec(self, plan, state, sid):
        """Spécification d'une étape : étape du plan, sinon spécification en ligne (étapes système : plan, vérification, correction...)."""
        for s in plan.get("steps") or []:
            if s.get("id") == sid:
                return s
        st = (state.get("steps") or {}).get(sid) or {}
        return st.get("spec") or {"id": sid, "title": st.get("title") or sid, "worker": st.get("worker") or state.get("leadWorker"),
                                  "goal": st.get("goal") or "", "dependsOn": [], "criteriaIds": [], "inputs": [], "expectedOutputs": [],
                                  "effort": "normal", "connectors": [], "requiresApprovalsFrom": []}

    def _new_system_step(self, state, sid, kind, worker, title, goal, status="READY", **spec_extra):
        spec = {"id": sid, "title": title, "worker": worker, "goal": goal, "dependsOn": [], "criteriaIds": [], "inputs": [], "expectedOutputs": [],
                "effort": "normal", "connectors": [], "requiresApprovalsFrom": [], "estimateCredits": None}
        spec.update(spec_extra)
        state["steps"][sid] = {"id": sid, "kind": kind, "title": title, "worker": worker, "status": status, "attempts": 0,
                               "createdUtc": self.now_iso(), "spec": spec, "credits": 0, "chf": 0.0}
        return state["steps"][sid]

    def _next_id(self, state, prefix):
        n = 1
        while f"{prefix}{n}" in state["steps"]:
            n += 1
        return f"{prefix}{n}"

    def _approvals_summary(self, pid):
        items = pa.load_items(self.store, pid)
        return {"counts": pa.counts(items), "pending": pa.pending_count(items)}

    def refresh_approval_counts(self, t):
        t.state["approvals"] = self._approvals_summary(t.pid)

    def client_pending_approvals(self, client_id, except_pid=None):
        total = 0
        for pid in self.store.ids_of_client(client_id):
            if pid == except_pid:
                continue
            try:
                total += (self.store.state(pid).get("approvals") or {}).get("pending", 0)
            except ps.ProjectError:
                continue
        return total

    def _autoapprove_on(self, client_id, worker):
        try:
            if self.installation_paused(client_id, worker):
                return False
        except Exception:  # noqa: BLE001
            return False
        if self.autoapprove:
            try:
                return bool(self.autoapprove(client_id))
            except Exception:  # noqa: BLE001
                return False
        data = _read_json(os.path.join(self.root, "core", "connectors", "data", client_id + ".autoapprove.json"), {}) or {}
        return bool(isinstance(data, dict) and data.get("autoApprove"))

    # ------------------------------------------------------------------ porte avant CHAQUE étape (6.3)
    def _quota_wait(self, t, view, reason_kind=None):
        resume = pu.binding_reset(view)
        if resume and (ps.parse_iso(resume) or 0) <= self.now():
            resume = ps.iso(self.now() + 60)             # fenêtre déjà échue mais pas encore renouvelée : on réessaie dans une minute
        binding = pu.g(view, "binding") or "month"
        reason = {"session": "SESSION", "week": "WEEK", "month": "MONTH"}.get(binding, "MONTH")
        st = t.state
        self._usage_cache.pop(st["clientId"], None)       # la vue d'usage mise en cache (5 s) date d'avant la dernière étape : le client doit voir la fenêtre pleine
        if st["status"] != "WAITING_QUOTA":
            t.transition("WAITING_QUOTA", reason, waitingFor="QUOTA", resumeAtUtc=resume)
            label = {"SESSION": "de session", "WEEK": "de la semaine", "MONTH": "du mois"}[reason]
            t.event("quota_wait", f"Votre quota {label} est atteint : le projet attend" + (f" et reprendra à {resume}." if resume else "."),
                    limit=binding, resumeAtUtc=resume)
        else:
            st["resumeAtUtc"] = resume

    def _gate(self, t, sid, spec):
        """Passerelle avant l'étape. Renvoie ("OK", reservation_id, credits, ceilingChf) ou (code, ...) après avoir mis à jour l'état :
        HOLD (rien ne part), BLOCKED (étape bloquée), QUOTA (WAITING_QUOTA), BUDGET (BUDGET_REACHED)."""
        st = t.state
        step = st["steps"][sid]
        kind = step["kind"]
        client_id = st["clientId"]
        worker = step.get("worker")
        lim = self.limits
        if kind not in ("verify",) and worker and worker != "qa":
            sc = self.scope_of(client_id, fresh=True)
            if not self.worker_in_scope(sc, worker):
                step.update(status="BLOCKED", blockedReason="WORKER_NOT_INCLUDED")
                t.event("step_failed", f"Le Worker {worker} ne fait plus partie de votre forfait : l'étape « {step.get('title')} » est suspendue.",
                        stepId=sid, worker=worker, blocked="WORKER_NOT_INCLUDED")
                return ("BLOCKED",)
            if kind in ("execute", "fix") and self.installation_paused(client_id, worker):
                step.update(status="BLOCKED", blockedReason="INSTALLATION_PAUSED")
                t.event("step_failed", f"L'installation de {worker} est en pause : l'étape « {step.get('title')} » attend.", stepId=sid, worker=worker,
                        blocked="INSTALLATION_PAUSED")
                return ("BLOCKED",)
        need = [c for c in (spec.get("connectors") or []) if c not in self.connectors_active(client_id)]
        if need and kind in ("execute", "fix"):
            step.update(status="BLOCKED", blockedReason="CONNECTOR", missingConnectors=need)
            t.event("input_requested", f"Connectez {', '.join(need)} pour que l'étape « {step.get('title')} » puisse continuer.", stepId=sid,
                    connectors=need)
            return ("BLOCKED",)
        b = st["budget"]
        with self._procs_lock:
            live = {sid_ for (p_, sid_) in self._procs if p_ == t.pid}
        # seules les réservations d'étapes dont le lanceur tourne vraiment réduisent le plafond (une étape perdue sera réglée par la reprise, elle ne bloque rien)
        reserved_running = sum(int(s.get("reservedCredits") or 0) for sid_, s in st["steps"].items() if s.get("status") == "RUNNING" and sid_ in live)
        cap_left = int(b.get("creditsCap") or 0) - int(b.get("creditsCharged") or 0) - (0 if kind == "answer" else reserved_running)
        min_start = int(lim["budget"]["minStartCredits"])
        if kind == "answer":
            min_start = 1                    # une question du client coûte 1 à 3 crédits : la réservation d'une étape en cours ne la prive pas de budget
        if cap_left < min_start:
            if kind != "answer" and st["status"] in ("PLANNING", "RUNNING", "VERIFYING"):
                t.transition("BUDGET_REACHED", "CAP", waitingFor="BUDGET")
                t.event("budget_reached", "Le plafond de crédits du projet est atteint : choisissez de le relever, d'accepter l'état actuel ou d'annuler.")
            return ("BUDGET",)
        view = self.usage.remaining(client_id)
        allowed = int(pu.g(view, "allowedNow", 0) or 0)
        if allowed < min_start:
            if kind != "answer":
                self._quota_wait(t, view)
            return ("QUOTA", view)
        phase = cfg.phase_for(self.cfg, kind, spec.get("effort") or "normal", st.get("level") or "standard")
        want = max(1, int(math.ceil(float(phase["maxCostChf"]) / self.credit_cost)))
        take = min(want, cap_left, allowed)
        rsv = self.usage.reserve(client_id, take, "project_step", f"{t.pid}:{sid}", ttl_s=900, allow_partial=True)
        if pu.is_block(rsv):
            if kind != "answer":
                self._quota_wait(t, pu.g(rsv, "view") or view)
            return ("QUOTA", view)
        credits = int(pu.g(rsv, "credits", take))
        ceiling = round(credits * self.credit_cost, 6)
        if ceiling < float(self.cfg["phases"].get("stepCeilingMinChf", 0.05)) and kind != "answer":
            self.usage.release(client_id, pu.reservation_id(rsv))
            self._quota_wait(t, view)
            return ("QUOTA", view)
        return ("OK", pu.reservation_id(rsv), credits, ceiling, phase)

    # ------------------------------------------------------------------ lancement
    def _candidates(self, ctrl):
        rows = []
        paused = set(ctrl.get("pausedClients") or [])
        for pid, status in list(self._live.items()):
            if status in ps.TERMINAL or status == "QUEUED":
                continue
            try:
                st = self.store.state(pid)
            except ps.ProjectError:
                continue
            client_id = st["clientId"]
            if client_id in paused:
                continue
            plan = None
            for sid, s in (st.get("steps") or {}).items():
                if s.get("status") != "READY":
                    continue
                nb = ps.parse_iso(s.get("notBeforeUtc"))
                if nb and nb > self.now():
                    continue
                if s.get("kind") != "answer" and st["status"] not in ("PLANNING", "RUNNING", "VERIFYING"):
                    continue
                if plan is None:
                    plan = self.read_plan(pid)
                crit = projects_plan.critical_path_lengths(plan.get("steps") or []) if plan else {}
                rows.append((pu_rank(s.get("kind")), -crit.get(sid, 0), s.get("createdUtc") or "", pid, sid, client_id, s.get("kind")))
        rows.sort()
        return rows

    def _spawn_ready(self, now, ctrl):
        g_cap = int(self.limits["runners"]["global"])
        mem_min = int(self.limits.get("minAvailableMemoryMb", 700))
        for _rank, _crit, _created, pid, sid, client_id, kind in self._candidates(ctrl):
            if self.running_count() >= g_cap:
                return
            per = cfg.runners_per_client(self.limits, self.plan_id_of(client_id))
            mine = self.running_count(client_id, exclude_answers=True)
            if kind == "answer":
                if self.running_count(client_id) >= per + 1:
                    continue
            elif mine >= per:
                continue
            mem = self.mem_available()
            if mem is not None and mem < mem_min:
                return
            try:
                self._start_step(pid, sid, now)
            except ps.LockConflict:
                continue
            except ps.ProjectError as e:
                sys.stderr.write(f"projects start {pid}/{sid}: {e.code}\n")
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"projects start {pid}/{sid}: {type(e).__name__}: {e}\n")

    def _step_tools(self, kind, spec, client_id, worker):
        tools = [n for n in project_tools.TOOLS_BY_KIND.get(kind, ())]
        for name, ent in project_tools.REGISTRY.items():
            if name in project_tools.RUNNER_ONLY:
                continue
            kinds = ent.get("kinds")
            if kinds is not None and kind in kinds and name not in tools:
                tools.append(name)
        if kind in ("execute", "fix") and self.connectors_active(client_id):
            tools.append("use_connector")
        if kind in ("plan", "replan", "execute", "fix", "consolidate"):
            tools.append("memory")
        return tools

    def _input_files(self, project_dir, spec, kind):
        out, total = [], 0
        if kind not in ("execute", "fix"):
            return out
        ws = os.path.join(project_dir, "workspace")
        for rel in (spec.get("inputs") or []):
            if len(out) >= 8:
                break
            ext = pp.ext_of(rel)
            if ext not in BINARY_INPUT_EXT:
                continue
            try:
                full = pp.resolve(ws, rel, kind="file", must_exist=True)
            except pp.PathError:
                continue
            size = os.path.getsize(full)
            if total + size > 20 * 1024 * 1024:
                continue
            total += size
            out.append({"path": rel, "as": "document" if ext == "pdf" else ("image" if ext in ("png", "jpg", "jpeg", "webp", "gif") else "container_upload")})
        return out

    def _recipe_block(self, state, plan, kind, spec):
        # La recette choisie par le planificateur vit dans le plan (plan.recipeId) : seule celle imposée à la création est dans l'état. Sans ce repli, les étapes
        # d'exécution et de vérification perdaient le guide de la recette dès que le client n'en avait pas désigné une (banc de preuve, 2026-11-02).
        rid = state.get("recipeId") or (plan or {}).get("recipeId")
        try:
            import recipes
        except ImportError:
            return ""
        try:
            if kind in ("plan", "replan"):
                cands = recipes.candidates(state.get("leadWorker"), state.get("goal"), state.get("language"), self.plan_id_of(state["clientId"]))
                if rid:
                    r = recipes.get(rid)
                    return recipes.render_for_planning(r) if r else ""
                return recipes.render_for_planning(cands[0][0]) if cands else ""
            if rid:
                r = recipes.get(rid)
                return recipes.render_for_step(r, spec.get("id")) if r else ""
        except Exception:  # noqa: BLE001 - une recette est un guide, jamais une cause d'échec
            return ""
        return ""

    def _worker_catalog(self, scope, lead):
        cards = _read_json(os.path.join(self.root, "core", "projects", "WORKER-CARDS.json"), {}) or {}
        by_id = {c.get("id"): c for c in (cards.get("cards") if isinstance(cards, dict) else cards) or [] if isinstance(c, dict)}
        lines = ["Workers que tu peux affecter aux étapes (un Worker par étape ; n'en choisis pas d'autre) :"]
        wanted = list(scope.get("allowed") or [])
        if scope.get("chloe") and "chloe" not in wanted:
            wanted.append("chloe")
        for wid in wanted:
            card = by_id.get(wid)
            if card:
                can = "; ".join(str(x) for x in (card.get("can") or [])[:6])
                lines.append(f"- {wid} ({card.get('name') or wid}) : {card.get('role') or ''}" + (f" — sait : {can}" if can else ""))
            else:
                w = self.worker_summary(wid) or {}
                lines.append(f"- {wid} ({w.get('name') or wid}) : {w.get('role') or ''}")
        den = scope.get("denied") or []
        if den:
            lines.append("Workers NON disponibles pour ce client (ne les affecte pas ; liste-les dans « unassignable » s'ils auraient été utiles) : " +
                         ", ".join(str(d.get("workerId")) for d in den[:20] if isinstance(d, dict)))
        return "\n".join(lines)

    def _start_step(self, pid, sid, now):
        with self.store.txn(pid) as t:
            st = t.state
            step = (st.get("steps") or {}).get(sid)
            if not step or step.get("status") != "READY":
                return False
            if st["status"] not in ("PLANNING", "RUNNING", "VERIFYING") and step["kind"] != "answer":
                return False
            plan = self.read_plan(pid)
            spec = self.step_spec(plan, st, sid)
            kind = step["kind"]
            gate = self._gate(t, sid, spec)
            if gate[0] != "OK":
                if kind == "answer" and gate[0] in ("QUOTA", "BUDGET"):
                    step.update(status="FAILED", error="QUOTA")
                    self._add_assistant_message(t, step, "Je ne peux pas répondre pour le moment : le quota de ce projet est atteint. Réessayez après le renouvellement.")
                elif gate[0] == "BLOCKED":
                    self._recompute(t)
                return False
            _ok, rsv_id, credits, ceiling, phase = gate
            attempt = int(step.get("attempts") or 0) + 1
            project_dir = self.store.project_dir(pid)
            step_dir = os.path.join(project_dir, "steps", sid, str(attempt))
            os.makedirs(step_dir, exist_ok=True)
            scope = self.scope_of(st["clientId"])
            self.refresh_scope_state(st)
            soft = int(self.limits["step"]["softDeadlineSec"])
            hard = int(self.limits["step"]["hardDeadlineSec"])
            shrink = bool(step.get("contextShrink"))
            resume_note = step.get("resumeNote")
            deliverables = (self.store.read_json(pid, "deliverables.json", {}) or {}).get("items") or []
            inbox = self.store.read_jsonl(pid, "inbox.jsonl")
            processed = set(st.get("inboxProcessed") or [])
            fresh = [m for m in inbox if m.get("id") not in processed and m.get("kind") in ("note", "change", "answer", "input_answer", "approval_feedback")
                     and (not m.get("stepId") or m.get("stepId") == sid or (m.get("kind") == "approval_feedback" and m.get("worker") == step.get("worker")))]
            budget_left = {"seconds": soft, "iterations": phase["maxIterations"], "chf": ceiling}
            extra, verif_block = [], None
            catalog = self._worker_catalog(scope, st.get("leadWorker")) if kind in ("plan", "replan") else None
            if kind == "verify":
                rnd = int((st.get("verify") or {}).get("round") or 1)
                auto = {}
                for cid, chk_id in ((st.get("verify") or {}).get("auto") or {}).items():
                    auto[cid] = pc_load_check(project_dir, rnd, chk_id) or {"id": chk_id, "ok": False, "findings": []}
                claims = {s_id: s.get("claims") for s_id, s in st["steps"].items() if s.get("claims")}
                dossier_plan = plan
                if spec.get("scope") == "consistency":                       # la relecture ne voit que son critère ; l'autre étape traite tous les autres
                    dossier_plan = dict(plan, criteria=[c for c in plan.get("criteria") or [] if c.get("id") == projects_plan.COHERENCE_ID])
                elif (st.get("verify") or {}).get("consistency"):
                    dossier_plan = dict(plan, criteria=[c for c in plan.get("criteria") or [] if c.get("id") != projects_plan.COHERENCE_ID])
                verif_block = pv.verification_dossier(dossier_plan, auto, deliverables, claims, pc.fence)
                pp.atomic_write_bytes(os.path.join(step_dir, "verify.json"), json.dumps({"round": rnd}).encode("utf-8"))
            if kind in ("plan", "replan") and st.get("planNotes"):
                extra.append("## Notes des Workers sur le plan\n" + pc.fence("plan_notes", "\n".join(str(n)[:300] for n in st["planNotes"][-10:])))
            if kind == "replan":
                extra.append("## Raison de la replanification\n" + pc.fence("replan_reason", str(step.get("spec", {}).get("goal") or "")[:2500]))
            if kind == "answer":
                extra.append("## Question du client\n" + pc.fence("client_question", str(step.get("spec", {}).get("goal") or "")[:3000]))
            context = pc.build_context(state=st, plan=plan, step=spec, step_state=step, project_dir=project_dir, kind=kind, attempt=attempt,
                                       decisions=self.store.read_jsonl(pid, "decisions.jsonl"), inbox_unprocessed=fresh, deliverables=deliverables,
                                       resume_note=resume_note, budget_left=budget_left, shrink=shrink, worker_catalog=catalog,
                                       verification_block=verif_block, extra_blocks=extra)
            ctx_path = os.path.join(step_dir, "context.md")
            pp.atomic_write_bytes(ctx_path, context.encode("utf-8"))
            in_path = os.path.join(step_dir, "input.json")
            out_path = os.path.join(step_dir, "result.json")
            now_ts = self.now()
            inp = {
                "schema": "BK-STEP-INPUT-V1", "projectId": pid, "clientId": st["clientId"], "stepId": sid, "attempt": attempt, "kind": kind,
                "worker": step.get("worker"), "phase": phase["phase"], "model": phase["model"], "effort": phase.get("effort"),
                "maxIterations": int(phase["maxIterations"]), "webMaxUses": int(phase["webMaxUses"]), "callTimeoutSec": int(phase["callTimeoutSec"]),
                "ceilingChf": ceiling, "deadlineUtc": ps.iso(now_ts + soft), "hardDeadlineUtc": ps.iso(now_ts + hard),
                "paths": {"projectDir": project_dir, "workspace": os.path.join(project_dir, "workspace"), "stepDir": step_dir,
                          "spool": os.path.join(project_dir, "spool"), "context": ctx_path},
                "tools": self._step_tools(kind, spec, st["clientId"], step.get("worker")),
                "serverTools": [x for x in SERVER_TOOLS.get(kind, ()) if not (x in ("web_search", "web_fetch") and int(phase["webMaxUses"]) <= 0)],
                "connectors": [c for c in (spec.get("connectors") or []) if c in self.connectors_active(st["clientId"])] if kind in ("execute", "fix") else [],
                "inputFiles": self._input_files(project_dir, spec, kind), "recipeBlock": self._recipe_block(st, plan, kind, spec),
                "resumeNote": resume_note, "contextShrink": shrink, "language": self.lang_name(st.get("language")),
                "autoApproveSafeOps": self._autoapprove_on(st["clientId"], step.get("worker")) if kind in ("execute", "fix") else False,
                "installationPaused": bool(self.installation_paused(st["clientId"], step.get("worker"))) if kind in ("execute", "fix") else False,
                "round": int((st.get("verify") or {}).get("round") or 0) if kind == "verify" else None,
                "scope": (spec.get("scope") or "final") if kind == "verify" else None,
                "projectStatus": st.get("status"),
            }
            pp.atomic_write_bytes(in_path, json.dumps(inp, ensure_ascii=False, indent=2).encode("utf-8"))
            limits_path = os.path.join(project_dir, "limits.json")
            if not os.path.isfile(limits_path):
                wmb = cfg.plan_value(self.limits["workspaceMb"], self.plan_id_of(st["clientId"]), 100)
                pp.atomic_write_bytes(limits_path, json.dumps({"workspaceMb": wmb, "approvalTtlDays": self.limits["approvals"]["ttlDays"],
                                                               "planLimits": {"maxPlanSteps": self.limits["step"]["maxPlanSteps"],
                                                                              "maxCriteria": self.limits["step"]["maxCriteria"]}}).encode("utf-8"))
            env = dict(os.environ)
            env.update({"BK_ROOT": self.root, "BK_PYTHON": self.python, "BK_REPLY_LANG": self.lang_name(st.get("language"))})
            argv = self._runner_argv(in_path, out_path)
            try:
                popen = self._spawn(argv, env, os.path.join(step_dir, "runner.out"))
            except OSError as e:
                self.usage.release(st["clientId"], rsv_id)
                step.update(status="FAILED", attempts=attempt, error=f"SPAWN_FAILED:{type(e).__name__}")
                t.event("step_failed", f"L'étape « {step.get('title')} » n'a pas pu démarrer.", stepId=sid, worker=step.get("worker"))
                self._recompute(t)
                return False
            pp.atomic_write_bytes(os.path.join(step_dir, "pid"), json.dumps({"pid": popen.pid, "startUtc": ps.iso(now_ts), "tag": "Project-StepRunner"}).encode("utf-8"))
            step.update(status="RUNNING", attempts=attempt, startedUtc=ps.iso(now_ts), beatUtc=ps.iso(now_ts), pid=popen.pid, reservationId=rsv_id,
                        reservedCredits=credits, ceilingChf=ceiling, resumeNote=None, contextShrink=False, wsBefore=self._ws_fingerprint(project_dir),
                        messageIds=[m.get("id") for m in fresh], blockedReason=None, error=None)
            st["counters"]["stepsRun"] = int(st["counters"].get("stepsRun") or 0) + 1
            if kind in ("execute", "fix") and not st.get("startedUtc"):
                st["startedUtc"] = ps.iso(now_ts)
            worker_name = (self.worker_summary(step.get("worker")) or {}).get("name") or step.get("worker")
            verbs = {"plan": f"{worker_name} prépare le plan", "replan": f"{worker_name} révise le plan", "verify": "Le contrôleur qualité vérifie le travail",
                     "consolidate": f"{worker_name} prépare le rapport final", "answer": f"{worker_name} répond à votre question",
                     "fix": f"{worker_name} corrige : {step.get('title')}", "execute": f"{worker_name} travaille : {step.get('title')}"}
            t.event("step_started", verbs.get(kind, step.get("title")), stepId=sid, worker=step.get("worker"), kind=kind, attempt=attempt)
            with self._procs_lock:
                self._procs[(pid, sid)] = StepProcRef(popen, pid, sid, attempt, st["clientId"], step_dir, now_ts, now_ts + hard + float(self.limits["step"].get("killGraceSec", 15)), kind)
        return True

    def _ws_fingerprint(self, project_dir):
        """Empreinte de workspace/ SANS handoff/ (le rapport de relais est écrit par le moteur : ce n'est pas un progrès du Worker)."""
        h = hashlib.sha256()
        for rel, size, mt in pp.walk_files(os.path.join(project_dir, "workspace"), limit=1000):
            if rel.startswith("handoff/"):
                continue
            h.update(f"{rel}|{size}|{int(mt)}\n".encode("utf-8"))
        return h.hexdigest()[:16]

    # ------------------------------------------------------------------ surveillance des processus
    def _poll_procs(self, now):
        with self._procs_lock:
            items = list(self._procs.items())
        hb = float(self.limits["step"]["heartbeatSec"])
        for key, sp in items:
            rc = sp.popen.poll()
            if rc is None:
                if now >= sp.hard_deadline:
                    sp.killed = "HARD_DEADLINE"
                    self.kill_popen(sp.popen)
                    self._finish_proc(key, sp)
                    continue
                if now - sp.last_beat >= hb:
                    sp.last_beat = now
                    try:
                        with self.store.txn(sp.pid) as t:
                            s = t.state["steps"].get(sp.sid)
                            if s and s.get("status") == "RUNNING":
                                s["beatUtc"] = ps.iso(now)
                    except ps.ProjectError:
                        pass
                    self._live_ingest_approvals(sp.pid)
                continue
            self._finish_proc(key, sp)

    def _live_ingest_approvals(self, pid):
        """Pendant une étape, les articles d'approbation apparaissent chez le client sans attendre la fin de l'étape."""
        try:
            with self.store.txn(pid) as t:
                self._ingest_approvals(t)
        except ps.ProjectError:
            pass

    def _finish_proc(self, key, sp):
        with self._procs_lock:
            if self._procs.pop(key, None) is None:
                return
        rc = sp.popen.poll()
        try:
            self._finish_step(sp.pid, sp.sid, sp.attempt, rc, sp.killed)
        except ps.ProjectError as e:
            sys.stderr.write(f"projects finish {sp.pid}/{sp.sid}: {e.code}\n")
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"projects finish {sp.pid}/{sp.sid}: {type(e).__name__}: {e}\n")
        finally:
            self.nudge()

    def abort_running_steps(self, pid, reason):
        """Arrête les lanceurs d'UN projet (annulation, arrêt propriétaire) et règle leur coût."""
        with self._procs_lock:
            mine = [(k, sp) for k, sp in self._procs.items() if k[0] == pid]
        for key, sp in mine:
            sp.killed = reason
            self.kill_popen(sp.popen)
            self._finish_proc(key, sp)

    # ------------------------------------------------------------------ règlement du coût
    def _read_cost(self, step_dir, result):
        cost = _read_json(os.path.join(step_dir, "cost.json"), None)
        if isinstance(cost, dict):
            return cost.get("usage") if isinstance(cost.get("usage"), dict) else cost
        if isinstance(result, dict) and isinstance(result.get("usage"), dict):
            return result["usage"]
        return {}

    def _settle_cost(self, t, step, cost):
        st = t.state
        client_id = st["clientId"]
        b = st["budget"]
        chf = cost.get("estimated_cost_chf") if isinstance(cost, dict) else None
        if not isinstance(chf, (int, float)) or isinstance(chf, bool):
            # Pas de coût lisible : si des appels ont eu lieu sans prix connu (modèle non tarifé), on règle au plafond de l'étape (le client ne
            # paie jamais moins que ce que nous avons dépensé) ; si aucune réponse n'est jamais arrivée (arrêt avant le premier appel), rien n'a été dépensé.
            chf = float(step.get("ceilingChf") or 0) if isinstance(cost, dict) and cost.get("api_calls") else 0.0
        chf = max(0.0, float(chf))
        b["chfSpent"] = round(float(b.get("chfSpent") or 0) + chf, 6)
        new_total = cfg.credits_for_chf(b["chfSpent"], self.credit_cost)
        delta = max(0, new_total - int(b.get("creditsCharged") or 0))
        rsv = step.get("reservationId")
        self.store.append_jsonl(t.pid, "cost-ledger.jsonl", {"ts": self.now_iso(), "stepId": step.get("id"), "attempt": step.get("attempts"),
                                                              "chf": round(chf, 6), "credits": delta, "cumulativeCredits": new_total})
        try:
            if rsv:
                self.usage.settle(client_id, rsv, delta)
        except Exception as e:  # noqa: BLE001 - le grand livre peut être indisponible : le plafond mensuel d'origine reste le garde-fou
            sys.stderr.write(f"projects usage.settle: {type(e).__name__}\n")
        b["creditsCharged"] = new_total
        step["credits"] = int(step.get("credits") or 0) + delta
        step["chf"] = round(float(step.get("chf") or 0) + chf, 6)
        step["reservationId"] = None
        step["reservedCredits"] = 0
        if delta:
            t.event("step_cost", f"{delta} crédit(s) pour l'étape « {step.get('title')} ».", stepId=step.get("id"), credits=delta, total=new_total)
        self._abuse_checks(t, delta)

    def _abuse_checks(self, t, delta):
        st = t.state
        b = st["budget"]
        cap = int(b.get("creditsCap") or 0)
        if cap and self.owner_alert and not st.get("capAlerted") and b.get("creditsCharged", 0) >= self.limits["abuse"]["capFractionAlert"] * cap:
            started = ps.parse_iso(st.get("startedUtc")) or self.now()
            if self.now() - started < float(self.limits["abuse"]["capFractionWindowMin"]) * 60:
                st["capAlerted"] = True
                try:
                    self.owner_alert(f"Projet {t.pid} ({st['clientId']}) : plus de 80 % du plafond en moins de 30 minutes.")
                except Exception:  # noqa: BLE001
                    pass

    # ------------------------------------------------------------------ spool : ingestion
    def _ingest_approvals(self, t, rename_step=None):
        pid = t.pid
        st = t.state
        other = self.client_pending_approvals(st["clientId"], except_pid=pid)
        new, rejected = pa.ingest_spool(self.store, pid, self.root, other, self.limits, rename=False)
        if rename_step:
            sp = os.path.join(self.store.project_dir(pid), "spool")
            done = os.path.join(sp, "done")
            f = os.path.join(sp, f"approvals-{rename_step}.jsonl")
            if os.path.isfile(f):
                os.makedirs(done, exist_ok=True)
                try:
                    os.replace(f, os.path.join(done, f"approvals-{rename_step}-{secrets.token_hex(3)}.jsonl"))
                except OSError:
                    pass
        if new:
            st["counters"]["approvalsQueued"] = int(st["counters"].get("approvalsQueued") or 0) + len(new)
            pending_new = [a for a in new if a.get("status") == "PENDING"]
            auto = [a for a in new if a.get("status") == "EXECUTED"]
            if pending_new:
                n = len(pending_new)
                t.event("approval_created", f"{n} action(s) préparée(s) attendent votre validation.", count=n,
                        stepId=pending_new[0].get("stepId"), worker=pending_new[0].get("worker"))
            for a in auto:
                t.event("approval_executed", f"Brouillon enregistré automatiquement : {(a.get('display') or {}).get('title')}.", stepId=a.get("stepId"),
                        worker=a.get("worker"), approvalId=a.get("id"), auto=True)
        for aid, code, detail in rejected:
            if code == "APPROVAL_DUPLICATE":
                continue
            self.store.append_jsonl(pid, "events-engine.jsonl", {"ts": self.now_iso(), "type": "approval_rejected_by_engine", "id": aid, "code": code})
        self.refresh_approval_counts(t)
        return new

    def _jsonl_lines(self, project_dir, name, sid, remove=True):
        sp = os.path.join(project_dir, "spool")
        path = os.path.join(sp, f"{name}-{sid}.jsonl")
        rows = []
        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(rec, dict):
                        rows.append(rec)
        except OSError:
            return rows
        if remove:
            done = os.path.join(sp, "done")
            os.makedirs(done, exist_ok=True)
            try:
                os.replace(path, os.path.join(done, f"{name}-{sid}-{secrets.token_hex(3)}.jsonl"))
            except OSError:
                pass
        return rows

    def _register_deliverable(self, t, rec, step_id, worker):
        """Inscrit un livrable au registre (deliverables.json) après avoir vérifié qu'il existe et n'est pas vide."""
        pid = t.pid
        ws = os.path.join(self.store.project_dir(pid), "workspace")
        try:
            full = pp.resolve(ws, rec.get("path"), must_exist=True, allow_trailing_slash=True)
        except pp.PathError:
            return None
        if os.path.isdir(full):
            files, size = pp.usage(full)
            if files == 0:
                return None
            sha = hashlib.sha256("|".join(f"{r}:{s}" for r, s, _m in pp.walk_files(full)).encode("utf-8")).hexdigest()
            path = pp.rel_of(ws, full) + "/"
        else:
            size = os.path.getsize(full)
            if size <= 0:
                return None
            sha = pp.sha256_file(full)
            path = pp.rel_of(ws, full)
        reg = self.store.read_json(pid, "deliverables.json", {}) or {}
        items = reg.get("items") if isinstance(reg.get("items"), list) else []
        entry = {"id": rec.get("id") or "DLV-" + secrets.token_hex(4), "path": path, "title": str(rec.get("title") or path)[:160],
                 "kind": rec.get("kind") if rec.get("kind") in ("site", "document", "table", "image", "export", "other") else "document",
                 "description": str(rec.get("description") or "")[:400], "stepId": step_id, "worker": worker, "bytes": int(size), "sha256": sha,
                 "createdUtc": self.now_iso()}
        existing = next((i for i in items if i.get("path") == path), None)
        if existing:
            existing.update({k: entry[k] for k in ("title", "kind", "description", "bytes", "sha256", "stepId", "worker")})
            existing["updatedUtc"] = entry["createdUtc"]
            added = False
        else:
            items.append(entry)
            added = True
        self.store.write_json(pid, "deliverables.json", {"schema": "BK-DELIVERABLES-V1", "items": items})
        if added:
            t.event("deliverable_added", f"Livrable ajouté : {entry['title']}", stepId=step_id, worker=worker, path=path)
        return entry

    def _ingest_spool(self, t, sid, report=None):
        """Ingestion finale du spool d'UNE étape : articles, livrables, décisions, questions, ajouts de plan, demandes de replanification."""
        pid = t.pid
        st = t.state
        step = st["steps"][sid]
        project_dir = self.store.project_dir(pid)
        out = {"questions": [], "replan": None, "added": 0}
        self._ingest_approvals(t, rename_step=sid)
        for rec in self._jsonl_lines(project_dir, "deliverables", sid):
            self._register_deliverable(t, rec, sid, step.get("worker"))
        if isinstance(report, dict):
            for d in report.get("deliverables") or []:
                self._register_deliverable(t, d, sid, step.get("worker"))
        for rec in self._jsonl_lines(project_dir, "decisions", sid):
            self.store.append_jsonl(pid, "decisions.jsonl", {"ts": rec.get("ts") or self.now_iso(), "stepId": sid, "worker": step.get("worker"),
                                                              "decision": rec.get("decision"), "why": rec.get("why")})
        if isinstance(report, dict):
            known = {r.get("decision") for r in self.store.read_jsonl(pid, "decisions.jsonl")}
            for d in report.get("decisions") or []:
                if d.get("decision") not in known:
                    self.store.append_jsonl(pid, "decisions.jsonl", {"ts": self.now_iso(), "stepId": sid, "worker": step.get("worker"),
                                                                      "decision": d.get("decision"), "why": d.get("why")})
        for rec in self._jsonl_lines(project_dir, "inputs", sid):
            qid = rec.get("id")
            if any(q.get("id") == qid for q in st.get("questions") or []):
                continue
            q = {"id": qid, "stepId": sid, "worker": step.get("worker"), "question": rec.get("question"), "why": rec.get("why"),
                 "blocking": bool(rec.get("blocking", True)), "default": rec.get("default"), "choices": rec.get("choices") or [], "askedUtc": self.now_iso(),
                 "answeredUtc": None, "answer": None}
            st.setdefault("questions", []).append(q)
            out["questions"].append(q)
            t.event("input_requested", f"{(self.worker_summary(step.get('worker')) or {}).get('name') or step.get('worker')} a une question : {q['question']}",
                    stepId=sid, worker=step.get("worker"), questionId=qid, blocking=q["blocking"])
        for rec in self._jsonl_lines(project_dir, "plan-notes", sid):
            st.setdefault("planNotes", []).append(f"[{sid}] {rec.get('text')}")
            st["planNotes"] = st["planNotes"][-30:]
        added = self._jsonl_lines(project_dir, "plan-addstep", sid)
        for spec in added:
            if self._add_plan_step(t, spec, sid):
                out["added"] += 1
        for rec in self._jsonl_lines(project_dir, "plan-replan", sid):
            out["replan"] = rec.get("reason")
        return out

    def _add_plan_step(self, t, spec, by_sid):
        """Étape ajoutée par un Worker (project_plan add_step) : validée par le moteur, au plus 8 par projet."""
        pid = t.pid
        st = t.state
        plan_doc = self.store.read_json(pid, "plan.json", {}) or {}
        plan = plan_doc.get("plan") or {}
        added_total = sum(1 for s in st["steps"].values() if s.get("addedBy"))
        if added_total >= int(self.limits["step"]["maxAddedSteps"]) or len(plan.get("steps") or []) >= int(self.limits["step"]["maxPlanSteps"])                 or not self.steps_room(st):
            return False
        scope = self.scope_of(st["clientId"])
        if not self.worker_in_scope(scope, spec.get("worker")):
            return False
        nums = [int(m.group(1)) for sid in st["steps"] for m in [re.match(r"^S(\d+)\Z", sid)] if m]
        new_id = f"S{(max(nums) if nums else 0) + 1}"
        cand = {"id": new_id, "title": spec.get("title"), "worker": spec.get("worker"), "goal": spec.get("goal"),
                "dependsOn": [d for d in spec.get("dependsOn") or [] if d in st["steps"]], "criteriaIds": [c for c in spec.get("criteriaIds") or []
                                                                                                          if c in {x["id"] for x in plan.get("criteria") or []}],
                "inputs": spec.get("inputs") or [], "expectedOutputs": spec.get("expectedOutputs") or [], "effort": spec.get("effort") or "normal",
                "connectors": spec.get("connectors") or [], "requiresApprovalsFrom": [], "estimateCredits": spec.get("estimateCredits")}
        trial = dict(plan)
        trial["criteria"] = [c for c in plan.get("criteria") or [] if not c.get("implicit")]       # le critère implicite (cohérence) n'est visé par aucune étape
        trial["steps"] = list(plan.get("steps") or []) + [cand]
        res = projects_plan.validate_plan(trial, {"chloe": scope.get("chloe"), "allowed": scope.get("allowed")}, limits=self.limits["step"])
        if not res.ok:
            return False
        plan["steps"] = res.plan["steps"]
        plan = projects_plan.with_coherence(plan)
        plan_doc["plan"] = plan
        self.store.write_json(pid, "plan.json", plan_doc)
        st["steps"][new_id] = {"id": new_id, "kind": "execute", "title": cand["title"], "worker": cand["worker"], "status": "PENDING", "attempts": 0,
                               "createdUtc": self.now_iso(), "credits": 0, "chf": 0.0, "addedBy": by_sid}
        t.event("replan", f"Étape ajoutée par {cand['worker']} : {cand['title']}", stepId=new_id, worker=cand["worker"], addedBy=by_sid)
        return True

    def _add_assistant_message(self, t, step, text, kind="assistant_answer"):
        mid = "MSG-" + secrets.token_hex(4)
        self.store.append_jsonl(t.pid, "inbox.jsonl", {"id": mid, "ts": self.now_iso(), "from": step.get("worker") or "chloe", "kind": kind,
                                                       "text": str(text)[:4000], "stepId": step.get("id"), "processed": True})
        t.event("assistant_message", str(text)[:600], stepId=step.get("id"), worker=step.get("worker"), messageId=mid)

    # ------------------------------------------------------------------ fin d'une étape
    def _classify(self, result, rc, killed, step_dir):
        if isinstance(result, dict) and result.get("status") in ("DONE", "PARTIAL", "NEEDS_INPUT", "BLOCKED", "FAILED", "RETRY_LATER"):
            return {"status": result["status"], "exitReason": result.get("exitReason"), "report": result.get("report") if isinstance(result.get("report"), dict) else {},
                    "answerText": str(result.get("answerText") or ""), "error": result.get("error"), "retryAfterSec": result.get("retryAfterSec")}
        if killed in ("HARD_DEADLINE",):
            return {"status": "PARTIAL", "exitReason": "deadline", "report": {}, "answerText": "", "error": None, "retryAfterSec": None}
        if killed:
            return {"status": "FAILED", "exitReason": killed, "report": {}, "answerText": "", "error": killed, "retryAfterSec": None, "interrupted": True}
        code = {10: "INPUT_INVALID", 11: "CREDENTIAL_NOT_CONFIGURED", 12: "API_UNAVAILABLE"}.get(rc, f"RUNNER_EXIT_{rc}")
        status = "RETRY_LATER" if rc == 12 else "FAILED"
        return {"status": status, "exitReason": code, "report": {}, "answerText": "", "error": code, "retryAfterSec": None}

    def _finish_step(self, pid, sid, attempt, rc, killed):
        project_dir = self.store.project_dir(pid)
        step_dir = os.path.join(project_dir, "steps", sid, str(attempt))
        result = _read_json(os.path.join(step_dir, "result.json"), None)
        with self.store.txn(pid) as t:
            st = t.state
            step = (st.get("steps") or {}).get(sid)
            if not step or step.get("status") != "RUNNING" or int(step.get("attempts") or 0) != attempt:
                return
            cost = self._read_cost(step_dir, result)
            self._settle_cost(t, step, cost)
            step["pid"] = None
            step["finishedUtc"] = self.now_iso()
            out = self._classify(result, rc, killed, step_dir)
            kind = step["kind"]
            if killed in ("CANCELLED", "KILL_ALL", "OWNER_KILLED"):
                # arrêt voulu : l'étape reprendra (annulation : le projet est déjà CANCELLED)
                step.update(status="READY", resumeNote="Reprise après un arrêt : relis workspace/ et handoff/ avant d'écrire.")
                step["attempts"] = max(0, attempt - 1)
                if st["status"] == "CANCELLED":
                    step["status"] = "SKIPPED"
                return
            handler = {"plan": self._on_plan_outcome, "replan": self._on_plan_outcome, "verify": self._on_verify_outcome,
                       "consolidate": self._on_consolidate_outcome, "answer": self._on_answer_outcome}.get(kind, self._on_work_outcome)
            handler(t, step, out, step_dir, attempt)
            st["counters"]["apiRetries"] = st["counters"].get("apiRetries", 0) if out["status"] == "RETRY_LATER" else 0
            self._recompute(t)

    # ---- tentatives, échecs, reprises
    def _retry_or_fail(self, t, step, error, resume_note=None, consumed=True):
        """Étape en échec : nouvelle tentative (3 au plus) avec une note, sinon FAILED."""
        st = t.state
        maxa = int(self.limits["step"]["maxAttempts"])
        if int(step.get("attempts") or 0) < maxa:
            step.update(status="READY", error=str(error)[:300], resumeNote=resume_note or f"La tentative précédente a échoué ({str(error)[:200]}). Relis workspace/ et handoff/, ne refais pas ce qui existe.")
            t.event("step_retry", f"Nouvelle tentative pour « {step.get('title')} » ({step.get('attempts')}/{maxa}).", stepId=step["id"], worker=step.get("worker"))
        else:
            step.update(status="FAILED", error=str(error)[:300])
            t.event("step_failed", f"L'étape « {step.get('title')} » a échoué après {maxa} tentatives.", stepId=step["id"], worker=step.get("worker"))

    def _on_retry_later(self, t, step, out):
        st = t.state
        step["attempts"] = max(0, int(step.get("attempts") or 0) - 1)          # une indisponibilité de l'API ne consomme pas de tentative
        delays = self.limits["step"]["retryLaterDelaysSec"]
        n = int(st["counters"].get("apiRetries") or 0)
        delay = float(out.get("retryAfterSec") or delays[min(n, len(delays) - 1)])
        step.update(status="READY", notBeforeUtc=ps.iso(self.now() + delay), error="API_UNAVAILABLE")
        st["counters"]["apiRetries"] = n + 1
        t.event("step_retry", "Le service d'IA est momentanément indisponible : nouvel essai automatique.", stepId=step["id"], worker=step.get("worker"))
        if n + 1 >= len(delays) and st["status"] in ("PLANNING", "RUNNING", "VERIFYING"):
            t.transition("PAUSED", "API_UNAVAILABLE", resumeAtUtc=ps.iso(self.now() + 900))
            if self.owner_alert:
                try:
                    self.owner_alert(f"Projet {t.pid} : API Anthropic indisponible après plusieurs essais (reprise automatique dans 15 minutes).")
                except Exception:  # noqa: BLE001
                    pass

    def _common_failure(self, t, step, out):
        """Traitement commun des sorties non réussies. Renvoie True si géré."""
        st = t.state
        s = out["status"]
        err = out.get("error") or out.get("exitReason") or "ERREUR"
        if s == "RETRY_LATER":
            self._on_retry_later(t, step, out)
            return True
        if err == "CREDENTIAL_NOT_CONFIGURED":
            step.update(status="READY", error=err, attempts=max(0, int(step.get("attempts") or 0) - 1))
            if st["status"] in ("PLANNING", "RUNNING", "VERIFYING"):
                t.transition("PAUSED", "CREDENTIAL_NOT_CONFIGURED")
            if self.owner_alert:
                try:
                    self.owner_alert("Projets : la clé d'API Anthropic n'est pas configurée (CREDENTIAL_NOT_CONFIGURED).")
                except Exception:  # noqa: BLE001
                    pass
            return True
        if s == "FAILED":
            interrupted = bool(out.get("interrupted"))
            if out.get("exitReason") == "refusal" or err == "MODEL_REFUSAL":
                step.update(status="FAILED", error="MODEL_REFUSAL")
                t.event("step_failed", f"Le modèle a refusé l'étape « {step.get('title')} ».", stepId=step["id"], worker=step.get("worker"))
                return True
            if err == "CONTEXT_TOO_LONG" and not step.get("shrunk"):
                step.update(status="READY", contextShrink=True, shrunk=True, resumeNote="Le contexte était trop long : il a été réduit de moitié.",
                            attempts=max(0, int(step.get("attempts") or 0) - 1))
                return True
            self._retry_or_fail(t, step, err)
            return True
        return False

    # ---- exécution / correction
    def _on_work_outcome(self, t, step, out, step_dir, attempt):
        st = t.state
        sid = step["id"]
        if self._common_failure(t, step, out):
            return
        report = out.get("report") or {}
        proj_dir = self.store.project_dir(t.pid)
        ing = self._ingest_spool(t, sid, report)
        s = out["status"]
        if s == "BLOCKED":
            blocked = report.get("blocked") or {}
            reason = blocked.get("reason") or "OTHER"
            step["resumeNote"] = blocked.get("resumeHint")
            if reason == "INPUT":
                step.update(status="BLOCKED", blockedReason="INPUT", questionIds=[q["id"] for q in st.get("questions") or [] if q.get("stepId") == sid and not q.get("answeredUtc")])
                if not step["questionIds"]:
                    qid = "Q-" + secrets.token_hex(4)
                    st.setdefault("questions", []).append({"id": qid, "stepId": sid, "worker": step.get("worker"), "question": str(blocked.get("detail") or "Information manquante")[:500],
                                                          "why": "", "blocking": True, "default": None, "choices": [], "askedUtc": self.now_iso(), "answeredUtc": None, "answer": None})
                    step["questionIds"] = [qid]
                    t.event("input_requested", str(blocked.get("detail") or "Une information est nécessaire.")[:400], stepId=sid, worker=step.get("worker"), questionId=qid)
            elif reason == "APPROVAL":
                step.update(status="BLOCKED", blockedReason="APPROVAL")
            elif reason == "CONNECTOR":
                step.update(status="BLOCKED", blockedReason="CONNECTOR", missingConnectors=[])
                t.event("input_requested", str(blocked.get("detail") or "Un outil doit être connecté.")[:400], stepId=sid, worker=step.get("worker"))
            else:
                self._retry_or_fail(t, step, blocked.get("detail") or "BLOQUÉ")
            return
        if s == "NEEDS_INPUT":
            qids = [q["id"] for q in st.get("questions") or [] if q.get("stepId") == sid and not q.get("answeredUtc") and q.get("blocking")]
            if qids:
                step.update(status="BLOCKED", blockedReason="INPUT", questionIds=qids)
                if report.get("summary"):
                    step["summary"] = str(report["summary"])[:1500]
                self._after_step_files(t, step, report)
                return
            s = "PARTIAL"
        # DONE ou PARTIAL : on re-vérifie le rapport (livrables présents et non vides, preuves résolues) avant de l'accepter
        problems = project_tools.revalidate_report(proj_dir, step_dir, report) if s == "DONE" else []
        if problems:
            if not step.get("reportRetry"):
                step.update(status="READY", reportRetry=True, attempts=max(0, int(step.get("attempts") or 0) - 1),
                            resumeNote="STEP_REPORT_INVALID : ton rapport a été refusé. Corrige ces points, puis rappelle step_complete : " + " | ".join(problems[:8]))
                t.event("step_retry", f"Le rapport de « {step.get('title')} » est incomplet : l'étape est relancée une fois.", stepId=sid, worker=step.get("worker"))
                return
            s = "PARTIAL"
            report = dict(report, remaining=list(report.get("remaining") or []) + [f"(rapport corrigé par le moteur : {p})" for p in problems[:4]])
        step["summary"] = str(report.get("summary") or out.get("exitReason") or "")[:1500]
        step["remaining"] = list(report.get("remaining") or [])[:10]
        step["claims"] = report.get("criteriaClaims") or []
        step["handoffNote"] = str(report.get("handoffNote") or "")[:2000]
        step["ignored"] = list(report.get("ignoredInstructions") or [])[:5]
        if step["ignored"]:
            st.setdefault("notices", []).append({"stepId": sid, "type": "ignored_instructions", "items": step["ignored"], "ts": self.now_iso()})
        self._after_step_files(t, step, report)
        if report.get("summaryUpdate") or report.get("summary"):
            old = pc.read_text(os.path.join(proj_dir, "summary.md"), 20000)
            pp.atomic_write_bytes(os.path.join(proj_dir, "summary.md"), pc.merge_summary(old, report.get("summaryUpdate") or report.get("summary"), sid).encode("utf-8"))
        self._write_handoff(t, step, report)
        for qid in report.get("inputQuestions") or []:
            pass
        processed = set(st.get("inboxProcessed") or [])
        processed.update(step.get("messageIds") or [])
        st["inboxProcessed"] = sorted(processed)[-300:]
        maxa = int(self.limits["step"]["maxAttempts"])
        if s == "DONE":
            step.update(status="DONE", error=None)
            t.event("step_finished", f"Étape terminée : {step.get('title')}", stepId=sid, worker=step.get("worker"), summary=step["summary"][:300])
        else:                                                    # PARTIAL : arrêtée au plafond de coût, à l'échéance ou aux itérations -> continuation
            if int(step.get("attempts") or 0) < maxa:
                step.update(status="READY", continuation=int(step.get("continuation") or 0) + 1,
                            resumeNote="Étape interrompue (échéance, plafond ou nombre de tours). Reste à faire : " + "; ".join(step["remaining"][:6] or ["relis workspace/ et continue"]))
                t.event("step_retry", f"« {step.get('title')} » continue dans une nouvelle étape (travail déjà fait conservé).", stepId=sid, worker=step.get("worker"))
            else:
                step.update(status="PARTIAL", final=True)
                t.event("step_finished", f"Étape terminée partiellement : {step.get('title')}", stepId=sid, worker=step.get("worker"), partial=True)
        self._progress_check(t, step)
        if ing.get("replan"):
            self._request_replan(t, f"Demande de {step.get('worker')} : {ing['replan']}")

    def _after_step_files(self, t, step, report):
        return

    def _write_handoff(self, t, step, report):
        proj_dir = self.store.project_dir(t.pid)
        L = [f"# {step.get('title')} ({step['id']}, {step.get('worker')})", "", str(report.get("summary") or "").strip(), ""]
        if report.get("deliverables"):
            L.append("## Livrables")
            for d in report["deliverables"]:
                L.append(f"- {d.get('path')} — {d.get('title') or ''}")
            L.append("")
        if report.get("remaining"):
            L.append("## Reste à faire")
            L.extend(f"- {r}" for r in report["remaining"])
            L.append("")
        if report.get("handoffNote"):
            L += ["## Note de relais", "", str(report["handoffNote"]).strip(), ""]
        qs = [q for q in t.state.get("questions") or [] if q.get("stepId") == step["id"]]
        if qs:
            L.append("## Questions posées au client")
            L.extend(f"- {q.get('question')}" + (f" (réponse : {q.get('answer')})" if q.get("answer") else "") for q in qs)
        try:
            path = os.path.join(proj_dir, "workspace", "handoff", f"{step['id']}.md")
            pp.atomic_write_bytes(path, ("\n".join(L).strip() + "\n").encode("utf-8"))
        except OSError:
            pass

    def _progress_check(self, t, step):
        """Absence de progrès : 3 étapes de suite sans écriture dans workspace/, sans nouveau livrable ni changement de plan -> PAUSED/NO_PROGRESS."""
        st = t.state
        after = self._ws_fingerprint(self.store.project_dir(t.pid))
        if step.get("kind") in ("execute", "fix") and after == step.get("wsBefore"):
            st["counters"]["noProgress"] = int(st["counters"].get("noProgress") or 0) + 1
        else:
            st["counters"]["noProgress"] = 0
        if st["counters"]["noProgress"] >= int(self.limits["step"]["noProgressLimit"]) and st["status"] in ("RUNNING", "PLANNING"):
            st["counters"]["noProgress"] = 0
            t.transition("PAUSED", "NO_PROGRESS")
            t.event("status_changed", "Le projet est en pause : trois étapes de suite n'ont rien produit. Dites-nous ce qui manque ou relancez.", reason="NO_PROGRESS")

    # ---- plan / replan
    def _accept_plan(self, t, plan_norm, replan, by_sid):
        pid = t.pid
        st = t.state
        doc = self.store.read_json(pid, "plan.json", {}) or {}
        history = list(doc.get("history") or [])
        if doc.get("plan"):
            history.append({"version": doc["plan"].get("version"), "plan": doc["plan"], "replacedUtc": self.now_iso()})
        version = int(st.get("planVersion") or 0) + 1
        plan_norm = projects_plan.with_coherence(dict(plan_norm))      # critère implicite « C-coherence » quand au moins deux Workers produisent
        plan_norm["version"] = version
        self.store.write_json(pid, "plan.json", {"schema": "BK-PROJECT-PLAN-FILE-V1", "plan": plan_norm, "history": history[-10:]})
        st["planVersion"] = version
        new_ids = {s["id"] for s in plan_norm["steps"]}
        for s in plan_norm["steps"]:
            cur = st["steps"].get(s["id"])
            if cur and cur.get("kind") == "execute":
                cur.update(title=s["title"], worker=s["worker"])
                if cur.get("status") not in ("DONE", "RUNNING", "SKIPPED"):
                    cur.update(status="PENDING", attempts=0, error=None, blockedReason=None)
            elif not cur:
                st["steps"][s["id"]] = {"id": s["id"], "kind": "execute", "title": s["title"], "worker": s["worker"], "status": "PENDING", "attempts": 0,
                                        "createdUtc": self.now_iso(), "credits": 0, "chf": 0.0}
        for sid, cur in st["steps"].items():
            if cur.get("kind") == "execute" and sid not in new_ids and cur.get("status") not in ("DONE", "RUNNING", "SKIPPED"):
                cur["status"] = "SKIPPED"
        st["budget"]["estimate"] = plan_norm.get("estimate") or {}
        self._set_default_cap(t, plan_norm)
        st["phase"] = "execute"
        t.event("plan_ready", f"Plan {'révisé' if replan else 'prêt'} : {len(plan_norm['steps'])} étape(s), {len(plan_norm['criteria'])} critère(s) d'acceptation.",
                stepId=by_sid, steps=len(plan_norm["steps"]), criteria=len(plan_norm["criteria"]), estimate=plan_norm.get("estimate"))

    def _set_default_cap(self, t, plan_norm):
        st = t.state
        b = st["budget"]
        if b.get("capSetByClient"):
            return
        est = plan_norm.get("estimate") or {}
        lim = self.limits["budget"]
        # Le plafond suit l'estimation du plan (somme des étapes de TRAVAIL) : on y ajoute la part fixe du moteur (planification, vérification, relecture de cohérence,
        # rapport final), sinon un petit projet atteint BUDGET_REACHED à la vérification alors que tout le travail est fait (banc de preuve, 2026-11-02).
        cap = (int(math.ceil(float(est.get("creditsMax") or 0) * float(lim["capMargin"]))) + int(lim.get("engineOverheadCredits") or 0)) if est.get("creditsMax") else int(lim["defaultCap"].get(st.get("level") or "standard", 150))
        cap = max(cap, int(lim["minStartCredits"]))
        abs_max = cfg.plan_value(self.limits["absoluteMaxChf"], self.plan_id_of(st["clientId"]), 8)
        if abs_max:
            cap = min(cap, int(abs_max / self.credit_cost))
        view = self.usage.remaining(st["clientId"])
        if not pu.g(view, "exempt"):
            month_rem = pu.g(pu.g(view, "month"), "remaining")
            if isinstance(month_rem, int):
                cap = min(cap, int(b.get("creditsCharged") or 0) + month_rem)
        b["creditsCap"] = max(cap, int(b.get("creditsCharged") or 0))
        b["chfCeiling"] = round(b["creditsCap"] * self.credit_cost, 4)

    def _on_plan_outcome(self, t, step, out, step_dir, attempt):
        st = t.state
        sid = step["id"]
        replan = step["kind"] == "replan"
        if self._common_failure(t, step, out):
            return
        ing = self._ingest_spool(t, sid, out.get("report"))
        if out["status"] == "NEEDS_INPUT":
            qids = [q["id"] for q in st.get("questions") or [] if q.get("stepId") == sid and not q.get("answeredUtc")]
            if qids:
                step.update(status="BLOCKED", blockedReason="INPUT", questionIds=qids)
                return
        proj_dir = self.store.project_dir(t.pid)
        plan_file = os.path.join(proj_dir, "spool", f"plan-{sid}.json")
        data = _read_json(plan_file, None)
        if not isinstance(data, dict) or not isinstance(data.get("plan"), dict):
            self._retry_or_fail(t, step, "Aucun plan enregistré",
                                "Tu n'as enregistré aucun plan : appelle project_plan avec action « set » (puis step_complete).")
            return
        scope = self.scope_of(st["clientId"], fresh=True)
        res = projects_plan.validate_plan(data["plan"], {"chloe": scope["chloe"], "allowed": scope["allowed"]}, limits=self.limits["step"])
        if not res.ok:
            self._retry_or_fail(t, step, "Plan invalide", "Ton plan a été refusé : " + " | ".join(res.messages()[:10]))
            return
        try:
            os.replace(plan_file, os.path.join(proj_dir, "spool", "done", f"plan-{sid}-{secrets.token_hex(3)}.json")) if os.path.isdir(os.path.join(proj_dir, "spool", "done")) else os.remove(plan_file)
        except OSError:
            pass
        self._accept_plan(t, res.plan, replan, sid)
        step.update(status="DONE", summary="Plan " + ("révisé" if replan else "établi"), error=None)
        initial = (not replan) or (not st.get("planApproved"))
        exceeds = self._plan_exceeds_quota(st, res.plan)
        if initial and (not st.get("autoStart") or exceeds):
            st["planApproved"] = False
            if exceeds:
                st["planNotice"] = "QUOTA"
            if st["status"] in ("PLANNING", "RUNNING"):
                t.transition("WAITING_INPUT", "PLAN_VALIDATION", waitingFor="PLAN_VALIDATION")
        else:
            st["planApproved"] = True
            st["planRejected"] = False
            t.event("plan_approved", "Le plan démarre automatiquement.", auto=True)
            if st["status"] == "PLANNING":
                t.transition("RUNNING", "PLAN_AUTO_APPROVED")

    def _plan_exceeds_quota(self, st, plan):
        """Vrai si l'estimation minimale du plan dépasse le solde mensuel restant (HTTP 402 PROJECT_EXCEEDS_QUOTA à l'approbation)."""
        try:
            view = self.usage.remaining(st["clientId"])
        except Exception:  # noqa: BLE001
            return False
        if pu.g(view, "exempt"):
            return False
        rem = pu.g(pu.g(view, "month"), "remaining")
        cmin = (plan.get("estimate") or {}).get("creditsMin")
        return isinstance(rem, int) and isinstance(cmin, (int, float)) and cmin > rem

    # ---- vérification
    def _on_verify_outcome(self, t, step, out, step_dir, attempt):
        """Fin d'une étape de vérification. Un tour peut avoir DEUX étapes (critères, puis cohérence entre Workers) : le verdict du tour est rendu quand
        toutes les étapes du tour sont finies (chaque rapport est gardé sur disque en attendant)."""
        st = t.state
        proj_dir = self.store.project_dir(t.pid)
        rnd = int((st.get("verify") or {}).get("round") or 1)
        if self._common_failure(t, step, out):
            if step.get("status") != "FAILED":
                return                                                      # nouvelle tentative prévue
            report = None                                                   # le vérificateur n'a pas pu s'exécuter : ses critères resteront UNVERIFIABLE
        else:
            report = (out.get("report") or {}).get("verification")
            step.update(status="DONE", summary=str((out.get("report") or {}).get("summary") or "")[:300])
        part = {"stepId": step["id"], "scope": (step.get("spec") or {}).get("scope") or "final", "stepDir": step_dir, "report": report}
        pv.write_part(proj_dir, rnd, step["id"], part)
        self._maybe_finish_verification(t, rnd)

    def _round_steps(self, st, rnd):
        return [s for s in st["steps"].values() if s.get("kind") == "verify" and int((s.get("spec") or {}).get("round") or 0) == int(rnd)]

    def _maybe_finish_verification(self, t, rnd):
        st = t.state
        steps = self._round_steps(st, rnd)
        if any(s.get("status") in ("READY", "RUNNING", "PENDING") for s in steps):
            return                                                          # l'autre étape du tour n'est pas finie
        proj_dir = self.store.project_dir(t.pid)
        plan = self.read_plan(t.pid)
        parts = [pv.read_part(proj_dir, rnd, s["id"]) for s in steps]
        parts = [p for p in parts if p]
        criteria, issues, summaries, step_dirs, ran = [], [], [], [], False
        for p in parts:
            rep = p.get("report")
            if p.get("stepDir"):
                step_dirs.append(p["stepDir"])
            if isinstance(rep, dict):
                ran = True
                criteria.extend(c for c in rep.get("criteria") or [] if isinstance(c, dict))
                issues.extend(i for i in rep.get("consistency") or [] if isinstance(i, dict))
                if rep.get("summary"):
                    summaries.append(str(rep["summary"]))
        merged = {"criteria": criteria, "overall": None, "summary": " ".join(summaries)[:1500]} if ran else None
        self._finish_verification(t, steps[0] if steps else {"id": "VER?"}, plan, merged, proj_dir, rnd, step_dirs, issues=issues)

    def _finish_verification(self, t, step, plan, report, proj_dir, rnd, step_dirs, issues=None):
        st = t.state
        auto = {}
        for cid, chk_id in ((st.get("verify") or {}).get("auto") or {}).items():
            c = pc_load_check(proj_dir, rnd, chk_id)
            if c:
                auto[cid] = c
        approvals = pa.load_items(self.store, t.pid)
        ver = pv.resolve_verification(plan, report, auto, proj_dir, rnd, approvals, list(step_dirs or []))
        pv.write_verification(proj_dir, rnd, ver)
        coh = next((c for c in ver["criteria"] if c["id"] == projects_plan.COHERENCE_ID), None)
        if coh is not None:
            pv.write_consistency(proj_dir, rnd, coh, issues or [])
        for s_ in self._round_steps(st, rnd):
            if s_.get("status") == "DONE":
                s_["summary"] = f"Vérification : {ver['overall']}"
        st["verification"] = {"round": rnd, "overall": ver["overall"], "lastUtc": self.now_iso(),
                              "criteria": [{"id": c["id"], "verdict": c["verdict"], "note": c["note"][:200]} for c in ver["criteria"]]}
        t.event("verification_result", f"Vérification (tour {rnd}) : {ver['overall']}.", round=rnd, overall=ver["overall"],
                failed=[c["id"] for c in ver["criteria"] if c["verdict"] == "FAIL"])
        maxfix = int(self.limits["step"]["maxFixRounds"])
        if ver["overall"] == "PASS":
            self._start_consolidation(t)
            return
        fails = [c for c in ver["criteria"] if c["verdict"] == "FAIL"]
        # critères « approval_executed » en échec alors que des actions attendent le client : on attend, on ne « corrige » pas
        pending = pa.pending_count(approvals)
        approval_only = fails and all(((plan_crit(plan, c["id"]).get("check") or {}).get("type") == "approval_executed") for c in fails)
        if fails and approval_only and pending:
            st["phase"] = "execute"
            t.transition("WAITING_APPROVAL", "APPROVALS_REQUIRED", waitingFor="APPROVAL")
            st["pendingReverify"] = True
            return
        if fails and int(st["counters"].get("fixRounds") or 0) < maxfix and self.steps_room(st, len(fails) + 2):
            st["counters"]["fixRounds"] = int(st["counters"].get("fixRounds") or 0) + 1
            scope = self.scope_of(st["clientId"])
            fixes = pv.plan_fix_steps(plan, st["steps"], ver, st["counters"]["fixRounds"], st.get("leadWorker") or "chloe", consistency=issues,
                                      worker_ok=lambda w: self.worker_in_scope(scope, w))
            for f in fixes:
                if not self.worker_in_scope(scope, f["worker"]):
                    f["worker"] = st.get("leadWorker") or f["worker"]
                self._new_system_step(st, f["id"], "fix", f["worker"], f["title"], f["goal"], criteriaIds=f["criteriaIds"], estimateCredits=6)
                st["steps"][f["id"]]["fixHint"] = f["goal"][:1500]
            st["phase"] = "fix"
            if st["status"] == "VERIFYING":
                t.transition("RUNNING", "FIX_ROUND")
            t.event("replan", f"Des critères ne sont pas satisfaits : {len(fixes)} étape(s) de correction (tour {st['counters']['fixRounds']}/{maxfix}).",
                    fixSteps=[f["id"] for f in fixes])
            return
        # tours épuisés, ou critères invérifiables : le client choisit (guider, accepter en l'état, annuler)
        st["phase"] = "execute"
        t.transition("WAITING_INPUT", "CRITERIA_FAILED", waitingFor="CRITERIA_FAILED")

    def _start_consolidation(self, t):
        st = t.state
        st["phase"] = "consolidate"
        sid = self._next_id(st, "CONS")
        lead = st.get("leadWorker") or "chloe"
        self._new_system_step(st, sid, "consolidate", lead, "Rapport final et message de livraison",
                              "Rédige le message de livraison au client (un court texte : ce qui est livré, ce qu'il doit encore faire, ce que tu n'as pas pu "
                              "vérifier). N'invente rien : appuie-toi sur le résumé du projet, les livrables et le résultat de la vérification. Termine par step_complete "
                              "(le résumé de ton rapport EST le message de livraison).")
        if st["status"] == "VERIFYING":
            t.transition("RUNNING", "CONSOLIDATION")

    def _on_consolidate_outcome(self, t, step, out, step_dir, attempt):
        if out["status"] in ("FAILED", "RETRY_LATER"):
            self._common_failure(t, step, out)
            if step.get("status") != "FAILED":
                return                                       # nouvelle tentative prévue
            self._finalize(t, "")                            # le message de livraison est facultatif : le rapport final est écrit par le moteur
            return
        report = out.get("report") or {}
        message = str(report.get("summary") or "")
        step.update(status="DONE", summary=message[:600])
        self._finalize(t, message)

    def _finalize(self, t, delivery_message):
        """Fin d'un projet : rapport final (gabarit fixe), définition de « terminé », puis DONE ou retour au client."""
        st = t.state
        pid = t.pid
        proj_dir = self.store.project_dir(pid)
        plan = self.read_plan(pid)
        rnd = pv.latest_round(proj_dir)
        ver = pv.read_verification(proj_dir, rnd) or {}
        deliverables = (self.store.read_json(pid, "deliverables.json", {}) or {}).get("items") or []
        approvals = pa.load_items(self.store, pid)
        gaps = st.get("acceptedGaps") or []
        if delivery_message and not pv.message_claims_ok(delivery_message, ver):
            delivery_message = ""
            t.event("verification_result", "Le message de livraison du Worker annonçait un critère réussi que la vérification n'a pas validé : il n'est pas repris dans le rapport.")
        problems = pv.definition_of_done(plan, ver, deliverables, approvals, os.path.join(proj_dir, "workspace"), gaps, final_report_exists=True)   # le rapport va être écrit
        report = pv.build_final_report(st, plan, ver, deliverables, approvals, delivery_message, gaps, self.now_iso(),
                                       status_label="DONE" if not problems else "EN ATTENTE (une décision est attendue)")
        pp.atomic_write_bytes(os.path.join(proj_dir, "final-report.md"), report.encode("utf-8"))
        if problems:
            st["phase"] = "execute"
            st["doneProblems"] = problems[:10]
            t.transition("WAITING_INPUT", "CRITERIA_FAILED", waitingFor="CRITERIA_FAILED")
            t.event("verification_result", "Le projet ne peut pas être déclaré terminé : " + "; ".join(problems[:3]), problems=problems[:10])
            return
        st["phase"] = "final"
        st["doneProblems"] = []
        if st["status"] in ("RUNNING", "VERIFYING", "WAITING_INPUT", "BUDGET_REACHED", "PLANNING", "WAITING_APPROVAL"):
            if st["status"] not in ("RUNNING", "VERIFYING", "WAITING_INPUT", "BUDGET_REACHED"):
                t.transition("RUNNING", "FINALIZE")
            t.transition("DONE", "COMPLETE")
        t.event("done", "Le projet est terminé et vérifié. Le rapport final est disponible.")

    # ---- question du client
    def _on_answer_outcome(self, t, step, out, step_dir, attempt):
        if out["status"] in ("FAILED", "RETRY_LATER"):
            step.update(status="FAILED", error=out.get("error"))
            self._add_assistant_message(t, step, "Je n'ai pas pu répondre à votre question pour le moment. Réessayez dans un instant.")
            return
        text = out.get("answerText") or str((out.get("report") or {}).get("summary") or "")
        step.update(status="DONE", summary=text[:300])
        self._add_assistant_message(t, step, text or "Je n'ai pas de réponse à cette question pour l'instant.")

    # ------------------------------------------------------------------ replanification
    def _request_replan(self, t, reason, needs_approval=False):
        st = t.state
        if int(st["counters"].get("replans") or 0) >= int(self.limits["step"]["maxReplans"]) or not self.steps_room(st):
            t.event("replan", "Le nombre maximal de replanifications est atteint : demande ignorée.", ignored=True)
            return None
        if any(s.get("kind") in ("replan",) and s.get("status") in ("READY", "RUNNING", "PENDING") for s in st["steps"].values()):
            return None
        st["counters"]["replans"] = int(st["counters"].get("replans") or 0) + 1
        sid = self._next_id(st, "REPLAN")
        lead = st.get("leadWorker") or "chloe"
        self._new_system_step(st, sid, "replan", lead, "Révision du plan", str(reason)[:2400], needsApproval=bool(needs_approval))
        t.event("replan", "Le plan est en cours de révision.", stepId=sid, reason=str(reason)[:200])
        return sid

    # ------------------------------------------------------------------ recalcul du projet (idempotent)
    def _deps_state(self, st, spec, approvals):
        """ready | wait | failed | approval | approval_expired pour une étape du plan."""
        steps = st["steps"]
        for d in spec.get("dependsOn") or []:
            ds = steps.get(d)
            if not ds:
                continue
            if ds["status"] in SATISFIED or (ds["status"] == "PARTIAL" and ds.get("final")):
                continue
            if ds["status"] == "FAILED":
                return "failed"
            return "wait"
        for src in spec.get("requiresApprovalsFrom") or []:
            ss = steps.get(src)
            if ss and not (ss["status"] in SATISFIED or (ss["status"] == "PARTIAL" and ss.get("final"))):
                if ss["status"] == "FAILED":
                    return "failed"
                return "wait"                                   # les actions n'existent qu'une fois l'étape source terminée : on l'attend avant de regarder les validations
            mine = [a for a in approvals if a.get("stepId") == src]
            if any(a.get("status") == "EXPIRED" for a in mine) and not any(a.get("status") in ("EXECUTED",) for a in mine):
                return "approval_expired"
            if any(a.get("status") in pa.OPEN_STATUSES for a in mine):
                return "approval"
        return "ready"

    def _recompute(self, t):
        st = t.state
        if st["status"] in NO_RECOMPUTE:
            return
        if st["status"] == "WAITING_INPUT" and st.get("waitingFor") in ("PLAN_VALIDATION", "CRITERIA_FAILED"):
            return
        if not st.get("planApproved") and st.get("phase") == "plan":
            pass
        pid = t.pid
        plan = self.read_plan(pid)
        steps = st["steps"]
        approvals = pa.load_items(self.store, pid)
        scope = self.scope_of(st["clientId"])
        # 1. déblocages
        for sid, s in steps.items():
            if s["status"] != "BLOCKED":
                continue
            reason = s.get("blockedReason")
            spec = self.step_spec(plan, st, sid)
            if reason == "WORKER_NOT_INCLUDED" and self.worker_in_scope(scope, s.get("worker")):
                s.update(status="PENDING", blockedReason=None)
            elif reason == "INSTALLATION_PAUSED" and not self.installation_paused(st["clientId"], s.get("worker")):
                s.update(status="PENDING", blockedReason=None)
            elif reason == "CONNECTOR":
                need = [c for c in (spec.get("connectors") or []) if c not in self.connectors_active(st["clientId"])]
                if not need:
                    s.update(status="PENDING", blockedReason=None)
            elif reason in ("APPROVAL", "APPROVAL_EXPIRED", "DEPENDENCY_FAILED"):
                s.update(status="PENDING", blockedReason=None)
            elif reason == "INPUT":
                qs = [q for q in st.get("questions") or [] if q["id"] in (s.get("questionIds") or [])]
                if qs and all(q.get("answeredUtc") for q in qs):
                    s.update(status="READY", blockedReason=None)
        # 2. promotion PENDING -> READY, marquage des blocages
        for sid, s in steps.items():
            if s["status"] != "PENDING" or s["kind"] not in ("execute", "fix"):
                continue
            spec = self.step_spec(plan, st, sid)
            d = self._deps_state(st, spec, approvals)
            if d == "ready":
                s["status"] = "READY"
            elif d == "failed":
                s.update(status="BLOCKED", blockedReason="DEPENDENCY_FAILED")
            elif d == "approval":
                s.update(status="BLOCKED", blockedReason="APPROVAL")
            elif d == "approval_expired":
                s.update(status="BLOCKED", blockedReason="APPROVAL_EXPIRED")
        self._milestone_checks(t, plan)
        # 3. état du projet
        active = [s for s in steps.values() if s["status"] in ("RUNNING", "READY") and s["kind"] != "answer"]
        status = st["status"]
        if st.get("phase") == "final":
            if status in ("RUNNING", "VERIFYING", "WAITING_INPUT", "WAITING_APPROVAL", "PLANNING"):
                if status not in ("RUNNING", "VERIFYING", "WAITING_INPUT"):
                    t.transition("RUNNING", "FINALIZE")
                t.transition("DONE", "COMPLETE")
                t.event("done", "Le projet est terminé et vérifié. Le rapport final est disponible.")
            return
        if active:
            target = "RUNNING"
            if any(s["kind"] == "verify" for s in active):
                target = "VERIFYING"
            elif st.get("phase") == "plan":
                target = "PLANNING"
            if status != target and status in ("PLANNING", "RUNNING", "VERIFYING", "WAITING_APPROVAL", "WAITING_INPUT"):
                t.transition(target, "STEPS_READY")
            return
        # plus rien ne tourne ni n'est prêt
        exec_steps = [s for s in steps.values() if s["kind"] in ("execute", "fix")]
        if st.get("pendingReverify"):
            if any(a.get("status") in pa.OPEN_STATUSES for a in approvals):
                if status != "WAITING_APPROVAL":
                    t.transition("WAITING_APPROVAL", "APPROVALS_REQUIRED", waitingFor="APPROVAL")
                return
            st["pendingReverify"] = False
        if st.get("phase") in ("execute", "fix") and exec_steps:
            unsatisfied = [s for s in exec_steps if not (s["status"] in SATISFIED or (s["status"] == "PARTIAL" and s.get("final")))]
            if not unsatisfied:
                self._start_verification(t, plan)
                return
        elif st.get("phase") in ("execute", "fix") and not exec_steps:
            self._start_verification(t, plan)
            return
        blocked = [s for s in steps.values() if s["status"] == "BLOCKED"]
        failed = [s for s in steps.values() if s["status"] == "FAILED" and s["kind"] in ("execute", "fix")]
        if failed:
            rid = self._request_replan(t, "Des étapes ont échoué : " + "; ".join(f"{s['id']} ({s.get('title')}) : {s.get('error')}" for s in failed[:6]) +
                                    ". Réaffecte ou simplifie (avec accord du client si le livrable change), ou laisse un trou EXPLICITE.")
            if rid:
                if st["status"] in ("WAITING_INPUT", "WAITING_APPROVAL"):
                    t.transition("RUNNING", "REPLAN")
                return
            if st["status"] in ("RUNNING", "PLANNING", "VERIFYING", "WAITING_APPROVAL", "WAITING_INPUT"):
                t.transition("FAILED", "STEP_FAILED")
                t.event("failed", "Une étape a échoué après plusieurs tentatives. Le travail déjà fait est conservé ; vous pouvez relancer l'étape.")
            return
        if blocked:
            reasons = {s.get("blockedReason") for s in blocked}
            if "APPROVAL" in reasons:
                if status != "WAITING_APPROVAL":
                    t.transition("WAITING_APPROVAL", "APPROVAL_REQUIRED", waitingFor="APPROVAL")
            elif reasons & {"INPUT", "CONNECTOR", "APPROVAL_EXPIRED", "WORKER_NOT_INCLUDED", "INSTALLATION_PAUSED"}:
                wf = "INPUT" if "INPUT" in reasons else ("CONNECTOR" if "CONNECTOR" in reasons else
                                                         ("APPROVAL_EXPIRED" if "APPROVAL_EXPIRED" in reasons else "INPUT"))
                reason = next(iter(sorted(reasons & {"INPUT", "CONNECTOR", "APPROVAL_EXPIRED", "WORKER_NOT_INCLUDED", "INSTALLATION_PAUSED"})))
                if status != "WAITING_INPUT" or st.get("waitingFor") != wf:
                    t.transition("WAITING_INPUT", reason, waitingFor=wf)
            return

    def _consistency_goal(self):
        """Mission de l'étape de cohérence : le gabarit chloe/prompts/consistency-review.md s'il existe (B3), sinon le texte de repli ci-dessous."""
        text = ""
        try:
            with open(os.path.join(self.root, "chloe", "prompts", "consistency-review.md"), encoding="utf-8-sig") as f:
                text = f.read(6000).strip()
        except OSError:
            pass
        base = ("Relis TOUS les livrables destinés au même public et compare-les. Pour chacun, extrais une fiche de faits : nom de l'entreprise, adresse, "
                "téléphone, horaires, prix, offres, dates, promesses (délais, garanties), ton, couleurs et typographie. Puis cherche les CONTRADICTIONS : un même "
                "fait différent d'un livrable à l'autre, une promesse faite ici et absente là, un ton incompatible, une marque incohérente. Ne corrige rien. "
                "Termine par step_complete avec l'objet « verification » : UN SEUL critère, « C-coherence » (PASS si aucune contradiction, FAIL sinon, avec preuves "
                "de type extrait cité des DEUX fichiers en contradiction), et la liste « consistency » : [{worker, files:[...], issue, fixHint}] avec le Worker "
                "propriétaire du fichier à corriger.")
        return (text + "\n\n" + base) if text else base

    def _milestone_checks(self, t, plan):
        """Jalons du plan (plan.milestones) : dès que les étapes d'un jalon sont terminées, le moteur exécute les contrôles typés des critères visés ; un
        échec crée tout de suite une étape de correction (2 jalons corrigés au plus par projet), sans attendre la vérification finale."""
        st = t.state
        if st["status"] not in ("PLANNING", "RUNNING") or not plan.get("milestones"):
            return
        done = st.setdefault("milestones", {})
        proj_dir = self.store.project_dir(t.pid)
        for m in plan["milestones"]:
            mid = m.get("id")
            if not mid or mid in done:
                continue
            if not all((st["steps"].get(a) or {}).get("status") in SATISFIED for a in m.get("afterSteps") or []):
                continue
            results = pv.run_milestone_checks(proj_dir, plan, m)
            failed = [cid for cid, r in results.items() if not r.get("ok")]
            done[mid] = {"checkedUtc": self.now_iso(), "failed": failed}
            t.event("verification_result", f"Jalon « {mid} » : {len(results) - len(failed)} contrôle(s) automatique(s) réussi(s), {len(failed)} en échec.",
                    scope="milestone", milestone=mid, failed=failed)
            fixes_used = int(st["counters"].get("milestoneFixes") or 0)
            if failed and fixes_used < int(self.limits["step"].get("maxMilestoneFixes", 2)) and self.steps_room(st, len(failed) + 2):
                st["counters"]["milestoneFixes"] = fixes_used + 1
                fixes = pv.plan_fix_steps(plan, st["steps"], {"criteria": pv.milestone_failures(results)}, f"M{fixes_used + 1}", st.get("leadWorker") or "chloe")
                scope = self.scope_of(st["clientId"])
                for f in fixes:
                    if not self.worker_in_scope(scope, f["worker"]):
                        f["worker"] = st.get("leadWorker") or f["worker"]
                    self._new_system_step(st, f["id"], "fix", f["worker"], f["title"], f["goal"], criteriaIds=f["criteriaIds"], estimateCredits=6)
                    st["steps"][f["id"]]["fixHint"] = f["goal"][:1500]
                t.event("replan", f"Un jalon est en échec : {len(fixes)} étape(s) de correction ajoutée(s) tout de suite.", fixSteps=[f["id"] for f in fixes], milestone=mid)

    def _start_verification(self, t, plan):
        st = t.state
        if any(s["kind"] == "verify" and s["status"] in ("READY", "RUNNING") for s in st["steps"].values()):
            return
        if any(s["kind"] == "consolidate" and s["status"] in ("READY", "RUNNING") for s in st["steps"].values()):
            return
        n = int(st["counters"].get("verifyRounds") or 0) + 1
        st["counters"]["verifyRounds"] = n
        st["phase"] = "verify"
        proj_dir = self.store.project_dir(t.pid)
        auto = pv.run_auto_checks(proj_dir, plan, n)
        st["verify"] = {"round": n, "auto": {cid: r["id"] for cid, r in auto.items()}, "startedUtc": self.now_iso()}
        has_coh = any(c.get("id") == projects_plan.COHERENCE_ID for c in plan.get("criteria") or [])
        sid = f"VER{n}"
        self._new_system_step(st, sid, "verify", "qa", "Vérification indépendante",
                              "Vérifie chaque critère d'acceptation sur les fichiers réels. Essaie de RÉFUTER. Termine par step_complete avec "
                              "l'objet « verification » (un verdict PASS, FAIL ou UNVERIFIABLE par critère, avec preuves)."
                              + (" Le critère « C-coherence » n'est PAS à ton programme : un autre contrôleur le traite." if has_coh else ""),
                              round=n, scope="final")
        if has_coh:                                                           # relecture de cohérence entre les contenus de Workers différents (6c.7)
            self._new_system_step(st, f"VERC{n}", "verify", "qa", "Relecture de cohérence entre Workers", self._consistency_goal(), round=n, scope="consistency")
        st["verify"]["consistency"] = has_coh
        if st["status"] in ("RUNNING", "WAITING_APPROVAL", "WAITING_INPUT", "PLANNING"):
            t.transition("VERIFYING", "VERIFY")
        t.event("verification_started", f"Vérification indépendante (tour {n}) : {len(plan.get('criteria') or [])} critère(s).", round=n)

    # ------------------------------------------------------------------ maintenance périodique d'un projet
    def _maintain(self, pid, now, ctrl):
        st = self.store.state(pid)
        status = st["status"]
        if status in ps.TERMINAL:
            self._live.pop(pid, None)
            return
        client_id = st["clientId"]
        last = self._last_maint.setdefault(pid, {})
        paused_by_owner = client_id in (ctrl.get("pausedClients") or [])
        if paused_by_owner and status not in ("PAUSED",):
            with self.store.txn(pid) as t:
                if t.state["status"] not in ps.TERMINAL and t.state["status"] != "PAUSED":
                    t.transition("PAUSED", "OWNER_PAUSED")
                    t.event("status_changed", "Le projet est suspendu par l'administration.", reason="OWNER_PAUSED")
            return
        if status == "PAUSED":
            reason = st.get("statusReason")
            resume_at = ps.parse_iso(st.get("resumeAtUtc"))
            if (reason == "OWNER_PAUSED" and not paused_by_owner) or (reason == "API_UNAVAILABLE" and resume_at and now >= resume_at):
                with self.store.txn(pid) as t:
                    if t.state["status"] == "PAUSED":
                        t.transition(self._resume_target(t.state), "AUTO_RESUME")
                        t.event("status_changed", "Le projet reprend.", reason=reason)
            return
        if status == "WAITING_QUOTA":
            resume_at = ps.parse_iso(st.get("resumeAtUtc"))
            go = bool(resume_at and now >= resume_at)
            if not go:
                try:
                    view = self.usage.remaining(client_id)
                    go = int(pu.g(view, "allowedNow", 0) or 0) >= int(self.limits["budget"]["minStartCredits"])
                except Exception:  # noqa: BLE001
                    go = False
            if go:
                with self.store.txn(pid) as t:
                    if t.state["status"] == "WAITING_QUOTA":
                        t.transition(self._resume_target(t.state), "QUOTA_RESUME")
                        t.event("quota_resume", "Votre quota est de nouveau disponible : le projet reprend.")
            return
        # une étape RUNNING dont le lanceur a disparu sans que le superviseur l'ait vu (processus tué de l'extérieur) : même traitement qu'au démarrage
        if status not in ("PAUSED", "WAITING_QUOTA"):
            gap = float(self.limits["step"]["noHeartbeatSec"])
            with self._procs_lock:
                live = {sid for (p, sid) in self._procs if p == pid}
            lost = [sid for sid, s in st["steps"].items() if s.get("status") == "RUNNING" and sid not in live
                    and now - (ps.parse_iso(s.get("beatUtc")) or ps.parse_iso(s.get("startedUtc")) or now) >= gap]
            if lost:
                self._reap_project(pid)
                return
        # approvals : échéances et rappels (toutes les 30 s), ingestion en direct des articles des étapes en cours (toutes les 10 s)
        ap = st.get("approvals") or {}
        if (ap.get("pending") or ap.get("counts", {}).get("PENDING")) and now - last.get("approvals", 0) >= 30:
            last["approvals"] = now
            self._approval_housekeeping(pid, now)
        if status in ("WAITING_INPUT", "WAITING_APPROVAL"):
            since = ps.parse_iso(st.get("statusSinceUtc")) or now
            idle_days = (now - since) / 86400.0
            if idle_days >= float(self.limits["lifecycle"]["idleExpiryDays"]):
                with self.store.txn(pid) as t:
                    if t.state["status"] in ("WAITING_INPUT", "WAITING_APPROVAL"):
                        t.transition("CANCELLED", "IDLE_EXPIRED")
                        t.event("cancelled", "Le projet a été annulé : aucune réponse depuis 14 jours. Le travail reste téléchargeable pendant 7 jours.")
                return
            for d in self.limits["lifecycle"]["idleReminderDays"]:
                key = f"idle{d}"
                if idle_days >= d and not (st.get("notify") or {}).get(key):
                    with self.store.txn(pid) as t:
                        t.state.setdefault("notify", {})[key] = self.now_iso()
                    self.enqueue_notification(pid, "approval_reminder" if status == "WAITING_APPROVAL" else "input_needed")
        if status in ("PLANNING", "RUNNING", "VERIFYING"):
            hours = float(st.get("activeSeconds") or 0) + max(0.0, now - (ps.parse_iso(st.get("statusSinceUtc")) or now))
            limit_h = float(cfg.plan_value(self.limits["maxDurationHours"], self.plan_id_of(client_id), 72) or 72)
            if hours / 3600.0 > limit_h:
                self.abort_running_steps(pid, "CANCELLED")
                with self.store.txn(pid) as t:
                    if t.state["status"] in ("PLANNING", "RUNNING", "VERIFYING"):
                        t.transition("FAILED", "MAX_DURATION")
                        t.event("failed", "La durée maximale d'un projet est atteinte. Le travail déjà fait est conservé.")
                return
        if status in ("PLANNING", "RUNNING", "VERIFYING", "WAITING_APPROVAL", "WAITING_INPUT"):
            with self.store.txn(pid) as t:
                self._recompute(t)

    def _resume_target(self, st):
        if st.get("phase") == "plan" and not st.get("planVersion"):
            return "PLANNING"
        if any(s.get("kind") == "verify" and s.get("status") in ("READY", "RUNNING") for s in st["steps"].values()):
            return "VERIFYING"
        return "RUNNING"

    # ------------------------------------------------------------------ approbations : maintenance et exécution
    def _approval_housekeeping(self, pid, now):
        with self.store.txn(pid) as t:
            items = pa.load_items(self.store, pid)
            expired = pa.expire_due(items, now)
            rem = pa.reminders_due(items, now, tuple(self.limits["approvals"]["reminderDays"]))
            if expired or rem:
                pa.save_items(self.store, pid, items)
            for it in expired:
                t.event("approval_decided", f"Une action a expiré sans validation : {(it.get('display') or {}).get('title')}.", approvalId=it["id"], status="EXPIRED")
                self._approval_feedback(t, it, "Cette action a expiré sans que le client la valide.")
            if expired:
                self._recompute_after_expiry(t, expired)
            self.refresh_approval_counts(t)
        if rem:
            self.enqueue_notification(pid, "approval_reminder")

    def _recompute_after_expiry(self, t, expired):
        st = t.state
        for sid, s in st["steps"].items():
            if s["status"] == "BLOCKED" and s.get("blockedReason") == "APPROVAL":
                s["status"] = "PENDING"
                s["blockedReason"] = None
        self._recompute(t)

    def _approval_feedback(self, t, item, text):
        self.store.append_jsonl(t.pid, "inbox.jsonl", {"id": "MSG-" + secrets.token_hex(4), "ts": self.now_iso(), "from": "system", "kind": "approval_feedback",
                                                       "text": text[:600], "approvalId": item.get("id"), "stepId": item.get("stepId"), "worker": item.get("worker")})

    def _approval_begin(self, pid, aid):
        try:
            with self.store.txn(pid) as t:
                items = pa.load_items(self.store, pid)
                it = next((i for i in items if i.get("id") == aid), None)
                if not it or it.get("status") != "EXECUTING":
                    return None
                ex = it.get("execution") or {}
                if ex.get("dispatchedUtc"):
                    return None                       # jamais rejoué
                if self.owner_stop_reason(t.state["clientId"]):
                    # arrêt d'urgence du propriétaire entre la validation et l'appel : rien ne part, l'article redevient en attente (le client le revalidera)
                    it["status"] = "PENDING"
                    it.pop("execution", None)
                    it.pop("decision", None)
                    it.pop("decidedUtc", None)
                    pa.save_items(self.store, pid, items)
                    t.event("approval_decided", "Action suspendue : l'administration a arrêté les envois. Revalidez-la quand ils reprennent.",
                            approvalId=aid, status="PENDING", stepId=it.get("stepId"), worker=it.get("worker"))
                    self.refresh_approval_counts(t)
                    return None
                ex["startedUtc"] = ex["dispatchedUtc"] = self.now_iso()
                it["execution"] = ex
                pa.save_items(self.store, pid, items)
                return (t.state["clientId"], it["connectorId"], it["operation"], pa.effective_params(it))
        except ps.ProjectError:
            return None

    def _run_connector_safe(self, conn, op, params, client_id):
        if not self.run_connector:
            return {"Status": "ERROR", "Detail": "Aucun exécuteur de connecteur configuré."}
        return self.run_connector(conn, op, params, client_id)

    def _approval_finish(self, pid, aid, res):
        try:
            with self.store.txn(pid) as t:
                items = pa.load_items(self.store, pid)
                it = next((i for i in items if i.get("id") == aid), None)
                if not it:
                    return
                status, cstatus, detail = pa.result_to_status(res)
                ex = it.get("execution") or {}
                ex.update(finishedUtc=self.now_iso(), connectorStatus=cstatus, detail=detail)
                it["status"] = status
                it["execution"] = ex
                pa.save_items(self.store, pid, items)
                title = (it.get("display") or {}).get("title")
                if status == "EXECUTED":
                    t.event("approval_executed", f"Action exécutée : {title}", approvalId=aid, stepId=it.get("stepId"), worker=it.get("worker"))
                else:
                    t.event("approval_failed", f"L'action a échoué : {title}", approvalId=aid, stepId=it.get("stepId"), worker=it.get("worker"))
                    self._approval_feedback(t, it, f"L'exécution a échoué ({cstatus}) : {detail}")
                self.refresh_approval_counts(t)
                self._recompute(t)
        except ps.ProjectError:
            pass
        self.nudge()

    # ------------------------------------------------------------------ reprise d'UN projet au démarrage
    def _reap_project(self, pid, boot=False):
        proj_dir = self.store.project_dir(pid)
        self.store.recover_seq(pid)
        requeue = []
        with self.store.txn(pid) as t:
            st = t.state
            for sid, s in list(st.get("steps", {}).items()):
                if s.get("status") != "RUNNING":
                    continue
                with self._procs_lock:
                    alive_here = (pid, sid) in self._procs
                if alive_here:
                    continue
                attempt = int(s.get("attempts") or 1)
                step_dir = os.path.join(proj_dir, "steps", sid, str(attempt))
                self.kill_orphan(os.path.join(step_dir, "pid"))
                cost = self._read_cost(step_dir, _read_json(os.path.join(step_dir, "result.json"), None))
                if not cost:
                    cost = {"estimated_cost_chf": 0.0}
                self._settle_cost(t, s, cost)
                s["pid"] = None
                maxa = int(self.limits["step"]["maxAttempts"])
                if attempt >= maxa:
                    s.update(status="FAILED", error="INTERRUPTED")
                    t.event("step_failed", f"L'étape « {s.get('title')} » a été interrompue trop souvent.", stepId=sid, worker=s.get("worker"))
                else:
                    s.update(status="READY", resumeNote="Reprise après une interruption (redémarrage du service) : relis workspace/ et handoff/, ne refais pas ce qui existe.")
                    t.event("step_retry", f"« {s.get('title')} » reprend après une interruption.", stepId=sid, worker=s.get("worker"))
            items = pa.load_items(self.store, pid)
            unknown, rq = pa.mark_boot_recovery(items, self.now())
            if unknown or rq:
                pa.save_items(self.store, pid, items)
                for it in unknown:
                    t.event("approval_failed", f"Action à vérifier à la main (le service a redémarré pendant l'exécution) : {(it.get('display') or {}).get('title')}.",
                            approvalId=it["id"], status="UNKNOWN_CHECK_MANUALLY")
                requeue = [i["id"] for i in rq]
            self.refresh_approval_counts(t)
            self._recompute(t)
        for aid in requeue:
            self.executor.submit(pid, aid)


class StepProcRef:
    """Référence d'un lanceur en cours (voir projects.StepProc : même forme, définie ici pour éviter un import circulaire)."""

    def __init__(self, popen, pid, sid, attempt, client_id, step_dir, started, hard_deadline, kind):
        self.popen = popen
        self.pid = pid
        self.sid = sid
        self.attempt = attempt
        self.client_id = client_id
        self.step_dir = step_dir
        self.started = started
        self.hard_deadline = hard_deadline
        self.kind = kind
        self.last_beat = started
        self.killed = None


def pu_rank(kind):
    return {"answer": 0, "plan": 1, "replan": 1, "verify": 2, "consolidate": 3, "fix": 4, "execute": 5}.get(kind, 6)


def pc_load_check(project_dir, rnd, check_id):
    import project_checks
    return project_checks.load_check(os.path.join(pv.round_dir(project_dir, rnd), "checks"), check_id)


def plan_crit(plan, cid):
    for c in plan.get("criteria") or []:
        if c.get("id") == cid:
            return c
    return {}
