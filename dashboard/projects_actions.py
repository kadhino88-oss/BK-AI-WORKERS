# -*- coding: utf-8 -*-
"""Actions du client sur un projet (docs/AUTONOMY-ENGINE.md, sections 2.3, 5, 6, 7.2) : création, plan, messages, réponses, validations,
pause, reprise, annulation, relance d'étape, « accepter en l'état », plafond de crédits, suppression, administration.

Mixin de ProjectService (projects.py). Chaque méthode publique prend le `client_id` de la session et refuse tout projet d'un autre client
(ProjectNotFound = 404 : on ne confirme jamais l'existence d'un projet d'autrui). Toute écriture passe par une transaction du magasin.
Les erreurs sont des ProjectError(code, detail, **extra) : projects_api.py les traduit en HTTP.
"""
import base64
import binascii
import json
import os
import re
import secrets
import sys
import time

import project_paths as pp
import projects_approvals as pa
import projects_config as cfg
import projects_plan
import projects_store as ps
import projects_usage as pu

TITLE_MAX = 80
LEVELS = ("standard", "approfondi")
MESSAGE_TYPES = ("note", "change", "question")
MAX_OPEN_QUESTIONS = 3


def make_title(goal):
    text = re.sub(r"\s+", " ", str(goal or "")).strip()
    cut = re.split(r"(?<=[.!?])\s", text, maxsplit=1)[0]
    cut = cut if 10 <= len(cut) <= 160 else text
    return (cut[:TITLE_MAX].rstrip() + ("…" if len(cut) > TITLE_MAX else "")) or "Projet"


def _int(value, default=None):
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value == int(value):
        return int(value)
    if isinstance(value, str) and re.match(r"^\d{1,9}\Z", value.strip()):
        return int(value.strip())
    return default


class ActionMixin:
    # ------------------------------------------------------------------ accès
    def owned_state(self, client_id, pid):
        """Etat du projet SI il appartient à ce client ; sinon ProjectNotFound (404, jamais 403)."""
        if not ps.PROJECT_ID_RE.match(pid or "") or not ps.CLIENT_ID_RE.match(client_id or ""):
            raise ps.ProjectNotFound(pid)
        if self.store.client_of(pid) != client_id:
            raise ps.ProjectNotFound(pid)
        return self.store.state(pid)

    def _check_open(self, st, what="cette action"):
        if st["status"] in ps.TERMINAL and st["status"] != "FAILED":
            raise ps.ProjectError("INVALID_STATE", f"Le projet est {('terminé' if st['status'] == 'DONE' else 'annulé')} : {what} n'est plus possible.",
                                  status=st["status"])

    def refresh_scope_state(self, st):
        sc = self.scope_of(st["clientId"])
        st["scope"] = {"chloe": bool(sc.get("chloe")), "allowedWorkers": list(sc.get("allowed") or []),
                       "deniedWorkers": [d.get("workerId") for d in sc.get("denied") or [] if isinstance(d, dict)]}

    def upgrade_hint(self, client_id):
        try:
            if self._upgrade_fn:
                return self._upgrade_fn(client_id)
            return (self.plan_view(client_id) or {}).get("upgrade")
        except Exception:  # noqa: BLE001
            return None

    # ------------------------------------------------------------------ création
    def _check_allowed(self, client_id):
        if self.allowlist and client_id not in self.allowlist:
            raise ps.ProjectError("PROJECT_NOT_IN_PLAN", "Les projets ne sont pas encore ouverts à votre compte.", upgrade=None)
        plan_id = self.plan_id_of(client_id)
        if int(cfg.plan_value(self.limits["activeProjects"], plan_id, 0) or 0) <= 0 or self.plan_view(client_id).get("projectsAllowed") is False:
            raise ps.ProjectError("PROJECT_NOT_IN_PLAN", "Les projets sont disponibles à partir du forfait Solo. Chloé reste utilisable pour une demande courte.",
                                  upgrade=self.upgrade_hint(client_id))
        return plan_id

    def _usage_block_error(self, client_id, view):
        binding = pu.g(view, "binding") or "month"
        if binding == "month":
            return ps.ProjectError("SUBSCRIPTION_REQUIRED", "Vos crédits du mois sont épuisés : un projet ne peut pas démarrer avant le renouvellement ou une montée en gamme.",
                                   upgrade=self.upgrade_hint(client_id), usage=pu.view_summary(view))
        resets = pu.binding_reset(view)
        return ps.ProjectError("USAGE_LIMIT_REACHED", f"Votre quota {'de session' if binding == 'session' else 'de la semaine'} est atteint"
                               + (f" : il se renouvelle à {resets}." if resets else "."), limit=binding, resetsAtUtc=resets,
                               needed=int(self.limits["budget"]["minStartCredits"]), remaining=int(pu.g(view, "allowedNow", 0) or 0),
                               usage=pu.view_summary(view), upgrade=self.upgrade_hint(client_id))

    def _created_last_day(self, client_id):
        n = 0
        cutoff = self.now() - 86400
        for pid in self.store.ids_of_client(client_id):
            try:
                created = ps.parse_iso(self.store.state(pid).get("createdUtc")) or 0
            except ps.ProjectError:
                continue
            if created >= cutoff:
                n += 1
        return n

    def _write_inputs(self, project_dir, inputs):
        lim = self.limits["input"]
        if inputs in (None, []):
            return []
        if not isinstance(inputs, list) or len(inputs) > int(lim["inputFilesMax"]):
            raise ps.ProjectError("INVALID_INPUT", f"Au plus {lim['inputFilesMax']} fichiers par projet.", field="inputs")
        ws = os.path.join(project_dir, "workspace")
        total, written = 0, []
        for i, f in enumerate(inputs):
            if not isinstance(f, dict) or not isinstance(f.get("name"), str):
                raise ps.ProjectError("INVALID_INPUT", "Chaque fichier doit avoir un nom.", field=f"inputs[{i}]")
            name = re.sub(r"[^A-Za-z0-9._-]", "_", f["name"].rsplit("/", 1)[-1].rsplit("\\", 1)[-1])[:60].lstrip("._-") or f"fichier{i + 1}"
            ext = pp.ext_of(name)
            if ext not in lim["inputFileExtensions"]:
                raise ps.ProjectError("INVALID_INPUT", f"Type de fichier non accepté : .{ext or '?'} (acceptés : {', '.join(lim['inputFileExtensions'])}).", field=f"inputs[{i}]")
            if isinstance(f.get("text"), str):
                data = f["text"].encode("utf-8")
            elif isinstance(f.get("contentBase64"), str):
                try:
                    data = base64.b64decode(f["contentBase64"], validate=True)
                except (binascii.Error, ValueError):
                    raise ps.ProjectError("INVALID_INPUT", "Contenu du fichier illisible (base64 attendu).", field=f"inputs[{i}]")
            else:
                raise ps.ProjectError("INVALID_INPUT", "Un fichier a besoin de « text » ou de « contentBase64 ».", field=f"inputs[{i}]")
            total += len(data)
            if total > int(lim["inputFilesMaxBytes"]):
                raise ps.ProjectError("TOO_LARGE", "Les fichiers fournis dépassent 10 Mo au total.")
            if ext in ("txt", "csv", "md", "json", "svg") and pa.secret_like(data.decode("utf-8", errors="replace")):
                raise ps.ProjectError("INVALID_INPUT", f"« {name} » ressemble à un secret (mot de passe, clé, numéro de carte) : retirez-le, aucun secret n'est stocké.",
                                      field=f"inputs[{i}]")
            try:
                full = pp.resolve(ws, f"inputs/{name}", kind="file")
            except pp.PathError as e:
                raise ps.ProjectError("INVALID_PATH", e.detail, field=f"inputs[{i}]")
            pp.atomic_write_bytes(full, data)
            written.append(f"inputs/{name}")
        return written

    def create_project(self, client_id, goal, worker_id="chloe", recipe_id=None, level="standard", credits_cap=None, auto_start=False, language=None,
                       inputs=None):
        """Crée un projet : l'étape de planification est mise en file. Renvoie {"projectId","status","queuePosition"}."""
        self.require_enabled()
        if not ps.CLIENT_ID_RE.match(client_id or ""):
            raise ps.ProjectError("INVALID_INPUT", "Compte invalide.")
        lim_in = self.limits["input"]
        goal = str(goal or "").strip()
        if not goal:
            raise ps.ProjectError("GOAL_REQUIRED", "Décrivez ce que vous voulez obtenir.", field="goal")
        if len(goal) > int(lim_in["goalMaxChars"]):
            raise ps.ProjectError("GOAL_TOO_LONG", f"L'objectif est trop long ({lim_in['goalMaxChars']} caractères au plus).", field="goal")
        if pa.secret_like(goal):
            raise ps.ProjectError("INVALID_INPUT", "L'objectif contient ce qui ressemble à un secret (mot de passe, clé, numéro de carte) : retirez-le.", field="goal")
        worker_id = str(worker_id or "chloe").lower()
        if not re.match(r"^[a-z]{2,20}\Z", worker_id):
            raise ps.ProjectError("INVALID_INPUT", "Worker invalide.", field="workerId")
        if level not in LEVELS:
            raise ps.ProjectError("INVALID_INPUT", "Niveau : « standard » ou « approfondi ».", field="level")
        plan_id = self._check_allowed(client_id)
        self.check_client_disk(client_id, plan_id)
        refusal = self._engine_gate_fn(client_id, level) if self._engine_gate_fn else None
        if refusal:   # moteur choisi par le proprietaire (docs/PROVIDERS.md) sans les capacites d'un projet long : on le dit, on ne lance pas sur Claude en cachette
            raise ps.ProjectError("ENGINE_NO_PROJECTS", refusal)
        scope = self.scope_of(client_id, fresh=True)
        if not self.worker_in_scope(scope, worker_id):
            hire = None
            for d in scope.get("denied") or []:
                if isinstance(d, dict) and str(d.get("workerId")).lower() == worker_id:
                    hire = d.get("reason")
            raise ps.ProjectError("WORKER_NOT_INCLUDED", "Ce Worker ne fait pas partie de votre forfait." if worker_id != "chloe"
                                  else "Chloé n'est pas incluse dans votre forfait : lancez le projet depuis la fiche d'un de vos Workers.",
                                  workerId=worker_id, hire=hire)
        cap = None
        if credits_cap is not None:
            cap = _int(credits_cap)
            if cap is None or cap < int(self.limits["budget"]["minStartCredits"]):
                raise ps.ProjectError("INVALID_INPUT", "Plafond de crédits invalide.", field="creditsCap")
        recipe = None
        if recipe_id:
            recipe = str(recipe_id)[:80]
            if not re.match(r"^[a-z0-9_-]+/[a-z0-9_-]+\Z", recipe):
                raise ps.ProjectError("INVALID_INPUT", "Recette invalide.", field="recipeId")
            try:
                import recipes
                if recipes.get(recipe) is None:
                    raise ps.ProjectError("INVALID_INPUT", "Recette inconnue.", field="recipeId")
            except ImportError:
                pass
        lang = str(language or "fr").lower()[:2]
        if lang not in ("fr", "en", "de", "it", "es", "pt"):
            lang = "fr"
        view = self.usage.remaining(client_id)
        if not pu.g(view, "exempt") and int(pu.g(view, "allowedNow", 0) or 0) < int(self.limits["budget"]["minStartCredits"]):
            raise self._usage_block_error(client_id, view)
        with self._create_lock:
            per_day = int(cfg.plan_value(self.limits["createPerDay"], plan_id, 0) or 0)
            if per_day and self._created_last_day(client_id) >= per_day:
                raise ps.ProjectError("RATE_LIMITED", f"Vous avez déjà créé {per_day} projets aujourd'hui : réessayez demain.", retryAfterSec=3600, limit=per_day)
            active_limit = int(cfg.plan_value(self.limits["activeProjects"], plan_id, 0) or 0)
            queued = len(self.queued_ids(client_id))
            go_queue = self.active_count(client_id) >= active_limit
            if go_queue and queued >= int(self.limits["queuedProjects"]):
                raise ps.ProjectError("PROJECT_LIMIT_REACHED", "Trop de projets sont déjà en cours ou en file : terminez ou annulez-en un.", queued=queued,
                                      limit=active_limit, upgrade=self.upgrade_hint(client_id))
            pid = ps.new_project_id()
            now_iso = self.now_iso()
            lead = worker_id
            state = {
                "schema": "BK-PROJECT-STATE-V1", "projectId": pid, "clientId": client_id, "title": make_title(goal), "goal": goal, "leadWorker": lead,
                "recipeId": recipe, "language": lang, "createdUtc": now_iso, "createdNs": time.time_ns(), "startedUtc": None, "finishedUtc": None, "updatedUtc": now_iso,
                "status": "QUEUED" if go_queue else "PLANNING", "waitingFor": None, "statusReason": "QUEUED" if go_queue else "CREATED", "resumeAtUtc": None,
                "statusSinceUtc": now_iso, "previousStatus": None, "activeSeconds": 0.0, "seq": 0,
                "level": level, "autoStart": bool(auto_start), "planVersion": 0, "planApproved": False, "phase": "plan", "steps": {},
                "budget": {"creditsCap": 0, "creditsCharged": 0, "chfCeiling": 0.0, "chfSpent": 0.0, "estimate": {}, "capSetByClient": False},
                "counters": {"stepsRun": 0, "replans": 0, "verifyRounds": 0, "fixRounds": 0, "noProgress": 0, "apiRetries": 0, "approvalsQueued": 0},
                "scope": {}, "questions": [], "answers": {}, "inboxProcessed": [], "notify": {}, "approvals": {"counts": {}, "pending": 0},
                "acceptedGaps": [], "owner": {"supervisorBoot": self.store.boot_utc},
            }
            self.refresh_scope_state(state)
            if cap is not None:
                state["budget"].update(creditsCap=cap, capSetByClient=True, chfCeiling=round(cap * self.credit_cost, 4))
            else:
                default_cap = int(self.limits["budget"]["defaultCap"].get(level, 150))
                abs_max = cfg.plan_value(self.limits["absoluteMaxChf"], plan_id, 8)
                if abs_max:
                    default_cap = min(default_cap, int(abs_max / self.credit_cost))
                state["budget"].update(creditsCap=default_cap, chfCeiling=round(default_cap * self.credit_cost, 4))
            plan_title = "Plan du projet"
            plan_goal = ("Transforme l'objectif du client en un plan BK-PROJECT-PLAN-V1 (critères d'acceptation vérifiables, étapes, un Worker par étape), "
                         "enregistre-le avec project_plan (action « set »), puis termine par step_complete.")
            self._new_system_step(state, "PLAN1", "plan", lead, plan_title, plan_goal)
            project_dir = self.store.create(client_id, state)
            try:
                written = self._write_inputs(project_dir, inputs)
            except ps.ProjectError:
                self.store.delete_project(client_id, pid)
                raise
            self._live[pid] = state["status"]
            with self.store.txn(pid) as t:
                t.event("project_created", f"Projet créé : {state['title']}", worker=lead, level=level, queued=go_queue, inputs=written)
                if go_queue:
                    t.event("status_changed", "Votre projet est en file d'attente : la planification commence dès qu'une place se libère.", reason="QUEUED")
        self.nudge()
        return {"projectId": pid, "status": state["status"], "queuePosition": (queued + 1) if go_queue else None}

    # ------------------------------------------------------------------ plan
    def approve_plan(self, client_id, pid, credits_cap=None, level=None, remove_steps=None, auto_start=None):
        self.require_enabled()
        st0 = self.owned_state(client_id, pid)
        if not (st0["status"] == "WAITING_INPUT" and st0.get("waitingFor") == "PLAN_VALIDATION"):
            raise ps.ProjectError("INVALID_STATE", "Ce projet n'attend pas la validation d'un plan.", status=st0["status"])
        if level is not None and level not in LEVELS:
            raise ps.ProjectError("INVALID_INPUT", "Niveau : « standard » ou « approfondi ».", field="level")
        cap = None
        if credits_cap is not None:
            cap = _int(credits_cap)
            if cap is None or cap < int(self.limits["budget"]["minStartCredits"]):
                raise ps.ProjectError("INVALID_INPUT", "Plafond de crédits invalide.", field="creditsCap")
        remove = [str(x) for x in (remove_steps or []) if isinstance(x, str)] if isinstance(remove_steps, list) else []
        if remove_steps is not None and not isinstance(remove_steps, list):
            raise ps.ProjectError("INVALID_INPUT", "removeSteps : liste d'étapes.", field="removeSteps")
        with self.store.txn(pid) as t:
            st = t.state
            if not (st["status"] == "WAITING_INPUT" and st.get("waitingFor") == "PLAN_VALIDATION"):
                raise ps.ProjectError("INVALID_STATE", "Ce projet n'attend pas la validation d'un plan.", status=st["status"])
            plan_doc = self.store.read_json(pid, "plan.json", {}) or {}
            plan = plan_doc.get("plan") or {}
            if remove:
                self._remove_steps(t, plan_doc, plan, remove)
            if level is not None:
                st["level"] = level
            if auto_start is not None:
                st["autoStart"] = bool(auto_start)
            if cap is not None:
                self._apply_cap(t, cap)
            elif level is not None and not st["budget"].get("capSetByClient"):
                self._set_default_cap(t, plan)
            plan_credits_min = (plan.get("estimate") or {}).get("creditsMin")
            view = self.usage.remaining(st["clientId"])
            if not pu.g(view, "exempt"):
                rem = pu.g(pu.g(view, "month"), "remaining")
                if isinstance(rem, int) and isinstance(plan_credits_min, (int, float)) and plan_credits_min > rem and not st.get("startAnyway"):
                    raise ps.ProjectError("PROJECT_EXCEEDS_QUOTA", "L'estimation minimale de ce plan dépasse vos crédits restants du mois.",
                                          estimate=plan.get("estimate"), remaining=rem,
                                          options=["variante Essentiel (retirer des étapes facultatives)", "passer à un forfait supérieur",
                                                   "démarrer quand même : le plafond sera votre solde, des livrables partiels sont possibles"],
                                          upgrade=self.upgrade_hint(st["clientId"]))
            st["planApproved"] = True
            st["planRejected"] = False
            st["planNotice"] = None
            st["phase"] = "execute"
            t.event("plan_approved", "Plan validé : le travail commence.")
            t.transition("RUNNING", "PLAN_APPROVED")
            self._recompute(t)
            status = t.state["status"]
        self.nudge()
        return {"ok": True, "status": status}

    def start_anyway(self, client_id, pid, credits_cap=None):
        """« Démarrer quand même » (PROJECT_EXCEEDS_QUOTA) : le plafond devient le solde du mois ; le projet atteindra BUDGET_REACHED si besoin."""
        st0 = self.owned_state(client_id, pid)
        if not (st0["status"] == "WAITING_INPUT" and st0.get("waitingFor") == "PLAN_VALIDATION"):
            raise ps.ProjectError("INVALID_STATE", "Ce projet n'attend pas la validation d'un plan.", status=st0["status"])
        with self.store.txn(pid) as t:
            t.state["startAnyway"] = True
        return self.approve_plan(client_id, pid, credits_cap=credits_cap)

    def _remove_steps(self, t, plan_doc, plan, remove):
        st = t.state
        ids = {s["id"] for s in plan.get("steps") or []}
        unknown = [r for r in remove if r not in ids]
        if unknown:
            raise ps.ProjectError("INVALID_INPUT", f"Étape inconnue : {unknown[0]}.", field="removeSteps")
        if len(set(remove)) >= len(ids):
            raise ps.ProjectError("INVALID_INPUT", "Il faut garder au moins une étape.", field="removeSteps")
        keep = [s for s in plan["steps"] if s["id"] not in remove]
        for s in keep:
            s["dependsOn"] = [d for d in s.get("dependsOn") or [] if d not in remove]
            s["requiresApprovalsFrom"] = [d for d in s.get("requiresApprovalsFrom") or [] if d not in remove]
        covered = {c for s in keep for c in s.get("criteriaIds") or []}
        dropped = [c for c in plan.get("criteria") or [] if c["id"] not in covered and not c.get("implicit")]
        plan["steps"] = keep
        plan["criteria"] = [c for c in plan.get("criteria") or [] if c["id"] in covered or c.get("implicit")]
        if not projects_plan.needs_consistency_review(plan):         # la relecture de cohérence n'a de sens qu'à partir de deux Workers qui produisent
            plan["criteria"] = [c for c in plan["criteria"] if not c.get("implicit")]
        if dropped:
            plan.setdefault("assumptions", []).append({"id": f"A{len(plan.get('assumptions') or []) + 1}", "text":
                                                       "Retiré à la demande du client : " + "; ".join(c["text"][:100] for c in dropped)})
        plan["milestones"] = [m for m in plan.get("milestones") or [] if all(a in {s['id'] for s in keep} for a in m.get("afterSteps") or [])]
        plan_doc["plan"] = plan
        self.store.write_json(t.pid, "plan.json", plan_doc)
        for sid in remove:
            if sid in st["steps"]:
                st["steps"][sid]["status"] = "SKIPPED"
        t.event("replan", f"Étape(s) retirée(s) à votre demande : {', '.join(sorted(set(remove)))}.", removed=sorted(set(remove)))

    def _apply_cap(self, t, cap):
        st = t.state
        b = st["budget"]
        plan_id = self.plan_id_of(st["clientId"])
        abs_max = cfg.plan_value(self.limits["absoluteMaxChf"], plan_id, 8)
        if abs_max and cap * self.credit_cost > float(abs_max) + 1e-9:
            raise ps.ProjectError("INVALID_INPUT", f"Plafond trop élevé pour votre forfait ({int(abs_max / self.credit_cost)} crédits au plus par projet).",
                                  field="creditsCap")
        view = self.usage.remaining(st["clientId"])
        if not pu.g(view, "exempt"):
            rem = pu.g(pu.g(view, "month"), "remaining")
            if isinstance(rem, int) and cap > int(b.get("creditsCharged") or 0) + rem:
                raise ps.ProjectError("PROJECT_EXCEEDS_QUOTA", "Ce plafond dépasse vos crédits restants du mois.", remaining=rem,
                                      estimate=b.get("estimate"), options=["choisir un plafond plus bas", "passer à un forfait supérieur"],
                                      upgrade=self.upgrade_hint(st["clientId"]))
        b["creditsCap"] = cap
        b["chfCeiling"] = round(cap * self.credit_cost, 4)
        b["capSetByClient"] = True

    def reject_plan(self, client_id, pid, feedback):
        self.require_enabled()
        st0 = self.owned_state(client_id, pid)
        if not (st0["status"] == "WAITING_INPUT" and st0.get("waitingFor") == "PLAN_VALIDATION"):
            raise ps.ProjectError("INVALID_STATE", "Ce projet n'attend pas la validation d'un plan.", status=st0["status"])
        feedback = str(feedback or "").strip()
        if not feedback:
            raise ps.ProjectError("INVALID_INPUT", "Dites ce que vous voulez changer dans le plan.", field="feedback")
        if len(feedback) > int(self.limits["input"]["messageMaxChars"]):
            raise ps.ProjectError("TOO_LARGE", "Message trop long.", field="feedback")
        with self.store.txn(pid) as t:
            st = t.state
            if int(st["counters"].get("replans") or 0) >= int(self.limits["step"]["maxReplans"]):
                raise ps.ProjectError("INVALID_STATE", "Le plan a déjà été révisé le nombre maximal de fois : validez-le ou annulez le projet.", status=st["status"])
            st["phase"] = "plan"
            t.transition("PLANNING", "PLAN_REJECTED")
            self.store.append_jsonl(pid, "inbox.jsonl", {"id": "MSG-" + secrets.token_hex(4), "ts": self.now_iso(), "from": "client", "kind": "change",
                                                         "text": feedback[:4000], "stepId": None})
            self._request_replan(t, "Le client n'a pas validé le plan et demande : " + feedback[:2000])
            t.event("plan_rejected", "Vous avez demandé des changements : le plan est révisé.")
            status = t.state["status"]
        self.nudge()
        return {"ok": True, "status": status}

    # ------------------------------------------------------------------ messages
    def post_message(self, client_id, pid, mtype, text, step_id=None):
        self.require_enabled()
        st0 = self.owned_state(client_id, pid)
        if mtype not in MESSAGE_TYPES:
            raise ps.ProjectError("INVALID_INPUT", "Type de message : note, change ou question.", field="type")
        text = str(text or "").strip()
        if not text:
            raise ps.ProjectError("INVALID_INPUT", "Le message est vide.", field="text")
        if len(text) > int(self.limits["input"]["messageMaxChars"]):
            raise ps.ProjectError("TOO_LARGE", "Message trop long (4 000 caractères au plus).", field="text")
        if pa.secret_like(text):
            raise ps.ProjectError("INVALID_INPUT", "Le message contient ce qui ressemble à un secret : retirez-le.", field="text")
        if step_id is not None and not (isinstance(step_id, str) and step_id in st0["steps"]):
            raise ps.ProjectError("INVALID_INPUT", "Étape inconnue.", field="stepId")
        if st0["status"] in ps.TERMINAL:
            raise ps.ProjectError("INVALID_STATE", "Ce projet est terminé : démarrez un nouveau projet pour une nouvelle demande.", status=st0["status"])
        mid = "MSG-" + secrets.token_hex(4)
        will_replan = False
        with self.store.txn(pid) as t:
            st = t.state
            if st["status"] in ps.TERMINAL:
                raise ps.ProjectError("INVALID_STATE", "Ce projet est terminé.", status=st["status"])
            self.store.append_jsonl(pid, "inbox.jsonl", {"id": mid, "ts": self.now_iso(), "from": "client", "kind": mtype, "text": text, "stepId": step_id})
            t.event("message_received", {"note": "Votre précision est prise en compte à la prochaine étape.",
                                         "change": "Votre demande de modification est prise en compte : le plan est révisé.",
                                         "question": "Votre question est transmise à l'équipe."}[mtype], messageId=mid, type=mtype)
            if mtype == "change":
                if st["status"] == "WAITING_INPUT" and st.get("waitingFor") == "PLAN_VALIDATION":
                    raise ps.ProjectError("INVALID_STATE", "Le plan attend votre validation : utilisez « Modifier le plan » (refus avec vos remarques).", status=st["status"])
                rid = self._request_replan(t, "Le client demande une modification : " + text[:2000])
                will_replan = bool(rid)
            elif mtype == "question":
                open_q = [s for s in st["steps"].values() if s.get("kind") == "answer" and s.get("status") in ("READY", "RUNNING")]
                if len(open_q) >= MAX_OPEN_QUESTIONS:
                    raise ps.ProjectError("RATE_LIMITED", "Plusieurs questions sont déjà en cours de traitement : patientez un instant.", retryAfterSec=30)
                if not self.steps_room(st):
                    raise ps.ProjectError("TOO_LARGE", "Ce projet a atteint son nombre maximal d'étapes : les questions ne sont plus possibles.")
                sid = self._next_id(st, "ANS")
                lead = st.get("leadWorker") or "chloe"
                self._new_system_step(st, sid, "answer", lead, "Réponse à votre question", text[:3000])
        self.nudge()
        return {"messageId": mid, "willReplan": will_replan}

    def list_messages(self, client_id, pid, since=0):
        self.owned_state(client_id, pid)
        out = []
        for i, m in enumerate(self.store.read_jsonl(pid, "inbox.jsonl"), 1):
            if m.get("kind") not in ("note", "change", "question", "assistant_answer", "answer"):
                continue
            if i <= int(since or 0):
                continue
            frm = m.get("from") or "client"
            out.append({"seq": i, "id": m.get("id"), "ts": m.get("ts"), "from": frm, "type": "answer" if m.get("kind") == "assistant_answer" else m.get("kind"),
                        "text": str(m.get("text") or "")[:4000], "stepId": m.get("stepId")})
        return {"messages": out}

    def answer_input(self, client_id, pid, question_id, answer):
        self.require_enabled()
        self.owned_state(client_id, pid)
        answer = str(answer or "").strip()
        if not answer:
            raise ps.ProjectError("INVALID_INPUT", "La réponse est vide.", field="answer")
        if len(answer) > int(self.limits["input"]["messageMaxChars"]):
            raise ps.ProjectError("TOO_LARGE", "Réponse trop longue.", field="answer")
        if pa.secret_like(answer):
            raise ps.ProjectError("INVALID_INPUT", "La réponse contient ce qui ressemble à un secret (mot de passe, clé, numéro de carte) : retirez-le.", field="answer")
        with self.store.txn(pid) as t:
            st = t.state
            q = next((x for x in st.get("questions") or [] if x.get("id") == question_id), None)
            if not q:
                raise ps.ProjectError("INVALID_INPUT", "Question inconnue.", field="questionId")
            if q.get("answeredUtc"):
                raise ps.ProjectError("INVALID_STATE", "Cette question a déjà reçu une réponse.", status=st["status"])
            if st["status"] in ps.TERMINAL and st["status"] != "FAILED":
                raise ps.ProjectError("INVALID_STATE", "Ce projet est terminé.", status=st["status"])
            q["answer"], q["answeredUtc"] = answer, self.now_iso()
            st.setdefault("answers", {})[str(q.get("question"))[:120]] = answer[:600]
            self.store.append_jsonl(pid, "inbox.jsonl", {"id": "MSG-" + secrets.token_hex(4), "ts": self.now_iso(), "from": "client", "kind": "answer",
                                                         "text": f"Réponse à « {str(q.get('question'))[:120]} » : {answer[:1500]}", "stepId": q.get("stepId")})
            t.event("message_received", "Votre réponse est transmise.", questionId=question_id, type="answer")
            if st["status"] == "WAITING_INPUT" and st.get("waitingFor") == "INPUT":
                open_blocking = [x for x in st.get("questions") or [] if x.get("blocking") and not x.get("answeredUtc")]
                if not open_blocking:
                    t.transition(self._resume_target(st), "INPUT_ANSWERED")
            self._recompute(t)
            status = t.state["status"]
        self.nudge()
        return {"ok": True, "status": status}

    # ------------------------------------------------------------------ approbations
    def _feedback_for_edit(self, t, it, edited):
        if edited:
            self._approval_feedback(t, it, "Le client a modifié ces champs avant de valider : " + ", ".join(sorted(edited)) +
                                    ". Tiens-en compte pour les prochaines actions du même type.")

    def approve_approval(self, client_id, pid, aid, params=None, confirm=None):
        self.require_enabled()
        self.owned_state(client_id, pid)
        if params is not None and not isinstance(params, dict):
            raise ps.ProjectError("INVALID_INPUT", "params : objet attendu.", field="params")
        dispatch = False
        with self.store.txn(pid) as t:
            if t.state["status"] == "CANCELLED":
                raise ps.ProjectError("INVALID_STATE", "Le projet est annulé : plus rien ne part.", status="CANCELLED")
            items = pa.load_items(self.store, pid)
            try:
                it, dispatch = pa.decide_approve(items, aid, self.now(), params, confirm)
            except pa.ApprovalError as e:
                if e.code == "APPROVAL_EXPIRED":
                    pa.save_items(self.store, pid, items)
                raise
            pa.save_items(self.store, pid, items)
            t.event("approval_decided", f"Action validée : {(it.get('display') or {}).get('title')}", approvalId=aid, status=it["status"],
                    stepId=it.get("stepId"), worker=it.get("worker"))
            self._feedback_for_edit(t, it, sorted((params or {}).keys()))
            self.refresh_approval_counts(t)
            if not dispatch:
                self._recompute(t)
            status = it["status"]
        if dispatch:
            self.executor.submit(pid, aid)
        self.nudge()
        return {"ok": True, "status": status}

    def reject_approval(self, client_id, pid, aid, reason=None):
        self.require_enabled()
        self.owned_state(client_id, pid)
        with self.store.txn(pid) as t:
            items = pa.load_items(self.store, pid)
            it = pa.decide_reject(items, aid, self.now(), reason)
            pa.save_items(self.store, pid, items)
            t.event("approval_decided", f"Action rejetée : {(it.get('display') or {}).get('title')}", approvalId=aid, status="REJECTED",
                    stepId=it.get("stepId"), worker=it.get("worker"))
            why = str(reason or "").strip()
            self._approval_feedback(t, it, "Le client a rejeté cette action" + (f" : {why[:300]}" if why else ".") +
                                    " Ne la représente pas telle quelle ; propose au besoin une version remplaçante (supersedes).")
            self.refresh_approval_counts(t)
            self._recompute(t)
        self.nudge()
        return {"ok": True, "status": "REJECTED"}

    def batch_approvals(self, client_id, pid, ids, decision, reason=None):
        self.require_enabled()
        self.owned_state(client_id, pid)
        if decision not in ("approve", "reject"):
            raise ps.ProjectError("INVALID_INPUT", "decision : « approve » ou « reject ».", field="decision")
        if not isinstance(ids, list) or not ids or not all(isinstance(i, str) for i in ids):
            raise ps.ProjectError("INVALID_INPUT", "ids : liste d'identifiants d'actions.", field="ids")
        ids = list(dict.fromkeys(ids))
        if len(ids) > int(self.limits["approvals"]["batchMax"]):
            raise ps.ProjectError("INVALID_INPUT", f"Un lot contient {self.limits['approvals']['batchMax']} actions au plus.", field="ids")
        items = {i["id"]: i for i in pa.load_items(self.store, pid)}
        batch_ids = {(items.get(i) or {}).get("batchId") for i in ids if i in items}
        if len(batch_ids) > 1:
            raise ps.ProjectError("INVALID_INPUT", "Un lot regroupe des actions de la même étape, du même connecteur et de la même opération.", field="ids")
        results = []
        for aid in ids:
            it = items.get(aid)
            if it and it.get("risk") == "high" and decision == "approve":
                results.append({"id": aid, "status": it.get("status"), "error": "BATCH_NOT_ALLOWED"})
                continue
            try:
                r = self.approve_approval(client_id, pid, aid) if decision == "approve" else self.reject_approval(client_id, pid, aid, reason)
                results.append({"id": aid, "status": r["status"]})
            except ps.ProjectError as e:
                results.append({"id": aid, "status": (it or {}).get("status"), "error": e.code})
        return {"results": results}

    # ------------------------------------------------------------------ contrôle : pause, reprise, annulation
    def pause(self, client_id, pid):
        self.require_enabled()
        st0 = self.owned_state(client_id, pid)
        self._pausable(st0)
        with self.store.txn(pid) as t:
            self._pausable(t.state)
            t.transition("PAUSED", "CLIENT_PAUSED")
            t.event("status_changed", "Projet mis en pause à votre demande. Une étape déjà lancée se termine ; rien d'autre ne démarre.", reason="CLIENT_PAUSED")
        return {"ok": True, "status": "PAUSED"}

    def _pausable(self, st):
        if st["status"] in ps.TERMINAL or st["status"] in ("PAUSED", "QUEUED", "BUDGET_REACHED"):
            raise ps.ProjectError("INVALID_STATE", "Ce projet ne peut pas être mis en pause maintenant.", status=st["status"])
        if st["status"] == "WAITING_INPUT" and st.get("waitingFor") in ("PLAN_VALIDATION", "CRITERIA_FAILED"):
            raise ps.ProjectError("INVALID_STATE", "Le projet attend déjà votre décision.", status=st["status"])

    def resume(self, client_id, pid):
        self.require_enabled()
        st0 = self.owned_state(client_id, pid)
        if st0["status"] != "PAUSED":
            raise ps.ProjectError("INVALID_STATE", "Ce projet n'est pas en pause.", status=st0["status"])
        if st0.get("statusReason") == "OWNER_PAUSED" and st0["clientId"] in (self.read_control().get("pausedClients") or []):
            raise ps.ProjectError("INVALID_STATE", "Ce projet est suspendu par l'administration.", status="PAUSED")
        with self.store.txn(pid) as t:
            st = t.state
            if st["status"] != "PAUSED":
                raise ps.ProjectError("INVALID_STATE", "Ce projet n'est pas en pause.", status=st["status"])
            if st.get("statusReason") in ("NO_PROGRESS",):
                st["counters"]["noProgress"] = 0
            for s in st["steps"].values():
                if s.get("status") == "READY":
                    s["notBeforeUtc"] = None
            t.transition(self._resume_target(st), "CLIENT_RESUMED")
            t.event("status_changed", "Le projet reprend.", reason="CLIENT_RESUMED")
            self._recompute(t)
            status = t.state["status"]
        self.nudge()
        return {"ok": True, "status": status}

    def cancel(self, client_id, pid, reason=None):
        self.require_enabled()
        st0 = self.owned_state(client_id, pid)
        if st0["status"] in ("DONE", "CANCELLED"):
            raise ps.ProjectError("INVALID_STATE", "Ce projet est déjà terminé.", status=st0["status"])
        self._cancel(pid, "CANCELLED_BY_CLIENT", "Projet annulé à votre demande. Les fichiers restent téléchargeables pendant 7 jours.", reason)
        return {"ok": True, "status": "CANCELLED"}

    def _cancel(self, pid, code, message, reason=None):
        with self.store.txn(pid) as t:
            if t.state["status"] in ("DONE", "CANCELLED"):
                return
            t.transition("CANCELLED", code)
            t.state["cancelReason"] = str(reason or "")[:300]
            items = pa.load_items(self.store, pid)
            changed = False
            for it in items:
                if it.get("status") == "PENDING":
                    it["status"], it["decision"], it["decidedUtc"] = "REJECTED", "cancelled", self.now_iso()
                    changed = True
            if changed:
                pa.save_items(self.store, pid, items)
            for s in t.state["steps"].values():
                if s.get("status") in ("READY", "PENDING", "BLOCKED"):
                    s["status"] = "SKIPPED"
            self.refresh_approval_counts(t)
            t.event("cancelled", message)
        self.abort_running_steps(pid, "CANCELLED")
        self.nudge()

    # ------------------------------------------------------------------ étapes, écarts, budget
    def retry_step(self, client_id, pid, step_id):
        self.require_enabled()
        self.owned_state(client_id, pid)
        with self.store.txn(pid) as t:
            st = t.state
            s = st["steps"].get(step_id)
            if not s:
                raise ps.ProjectError("INVALID_INPUT", "Étape inconnue.", field="stepId")
            if s.get("status") not in ("FAILED", "PARTIAL", "BLOCKED"):
                raise ps.ProjectError("INVALID_STATE", "Seule une étape en échec, partielle ou bloquée peut être relancée.", status=s.get("status"))
            if st["status"] in ("CANCELLED", "DONE"):
                raise ps.ProjectError("INVALID_STATE", "Le projet est terminé.", status=st["status"])
            s.update(status="READY", attempts=0, error=None, blockedReason=None, final=False, reportRetry=False, notBeforeUtc=None,
                     resumeNote="Relance demandée par le client : relis workspace/ et handoff/, ne refais pas ce qui existe.")
            if st["status"] == "FAILED":
                t.transition(self._resume_target(st), "STEP_RETRY")
            t.event("step_retry", f"Relance de l'étape « {s.get('title')} » à votre demande.", stepId=step_id, worker=s.get("worker"))
            self._recompute(t)
            status = t.state["status"]
        self.nudge()
        return {"ok": True, "status": status}

    def accept_gaps(self, client_id, pid, criteria_ids=None):
        self.require_enabled()
        st0 = self.owned_state(client_id, pid)
        ok_state = (st0["status"] == "WAITING_INPUT" and st0.get("waitingFor") == "CRITERIA_FAILED") or st0["status"] == "BUDGET_REACHED"
        if not ok_state:
            raise ps.ProjectError("INVALID_STATE", "On ne peut accepter l'état actuel que lorsque des critères restent en échec ou que le plafond est atteint.",
                                  status=st0["status"])
        if criteria_ids is not None and not (isinstance(criteria_ids, list) and all(isinstance(c, str) for c in criteria_ids)):
            raise ps.ProjectError("INVALID_INPUT", "criteriaIds : liste de critères.", field="criteriaIds")
        with self.store.txn(pid) as t:
            st = t.state
            plan = self.read_plan(pid)
            from_budget = st["status"] == "BUDGET_REACHED"
            ver = st.get("verification") or {}
            passed = {c["id"] for c in ver.get("criteria") or [] if c.get("verdict") == "PASS"}
            all_ids = [c["id"] for c in plan.get("criteria") or []]
            failing = [c for c in all_ids if c not in passed]
            chosen = failing if not criteria_ids else [c for c in criteria_ids if c in failing]
            if criteria_ids and len(chosen) != len(set(criteria_ids)):
                raise ps.ProjectError("INVALID_INPUT", "Un critère indiqué n'est pas en échec.", field="criteriaIds")
            if from_budget:
                chosen = failing                                 # plafond atteint : tout ce qui n'est pas encore vérifié devient un écart connu
            st["acceptedGaps"] = sorted(set(st.get("acceptedGaps") or []) | set(chosen))
            st["acceptedGapsUtc"] = self.now_iso()
            for s in st["steps"].values():
                if s.get("status") in ("PENDING", "READY", "BLOCKED", "FAILED") and s.get("kind") in ("execute", "fix"):
                    s["status"] = "SKIPPED"
                    s["skipReason"] = "GAP_ACCEPTED"
            t.event("verification_result", "Vous avez accepté l'état actuel : les écarts restants figureront dans le rapport final.", accepted=st["acceptedGaps"])
            self._finalize(t, "")
            status = t.state["status"]
        self.nudge()
        return {"ok": True, "status": status}

    def set_budget(self, client_id, pid, credits_cap):
        self.require_enabled()
        self.owned_state(client_id, pid)
        cap = _int(credits_cap)
        if cap is None or cap <= 0:
            raise ps.ProjectError("INVALID_INPUT", "Plafond de crédits invalide.", field="creditsCap")
        with self.store.txn(pid) as t:
            st = t.state
            if st["status"] in ("DONE", "CANCELLED"):
                raise ps.ProjectError("INVALID_STATE", "Le projet est terminé.", status=st["status"])
            charged = int(st["budget"].get("creditsCharged") or 0)
            if cap < charged + int(self.limits["budget"]["minStartCredits"]):
                raise ps.ProjectError("INVALID_INPUT", f"Le plafond doit dépasser les {charged} crédits déjà consommés d'au moins {self.limits['budget']['minStartCredits']}.",
                                      field="creditsCap")
            self._apply_cap(t, cap)
            t.event("status_changed", f"Plafond du projet fixé à {cap} crédits.", reason="BUDGET_SET", cap=cap)
            if st["status"] == "BUDGET_REACHED":
                t.transition(self._resume_target(st), "BUDGET_RAISED")
                t.event("status_changed", "Le plafond est relevé : le projet reprend.", reason="BUDGET_RAISED")
                self._recompute(t)
            status = t.state["status"]
            out_cap = t.state["budget"]["creditsCap"]
        self.nudge()
        return {"ok": True, "creditsCap": out_cap, "status": status}

    def delete_project(self, client_id, pid, confirm=False):
        self.require_enabled()
        st = self.owned_state(client_id, pid)
        if st["status"] not in ps.TERMINAL:
            raise ps.ProjectError("INVALID_STATE", "Annulez d'abord le projet : on ne supprime qu'un projet terminé, échoué ou annulé.", status=st["status"])
        if not confirm:
            raise ps.ProjectError("CONFIRM_REQUIRED", "Ajoutez confirm=1 pour supprimer définitivement ce projet et ses fichiers.")
        self.abort_running_steps(pid, "CANCELLED")
        # Les crédits déjà consommés restent comptés dans le mois : le journal de coût survit à la suppression (jamais un remboursement par effacement).
        ledger = self.store.read_jsonl(pid, "cost-ledger.jsonl")
        if ledger:
            keep = os.path.join(self.store.client_dir(client_id), "_deleted")
            os.makedirs(keep, exist_ok=True)
            with open(os.path.join(keep, "cost-ledger.jsonl"), "a", encoding="utf-8") as f:
                for rec in ledger:
                    f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
                f.flush()
                os.fsync(f.fileno())
        self.store.delete_project(client_id, pid)
        self._live.pop(pid, None)
        self._last_maint.pop(pid, None)
        return {"ok": True}

    # ------------------------------------------------------------------ administration (porte propriétaire)
    def admin_pause_client(self, client_id, paused):
        if not ps.CLIENT_ID_RE.match(client_id or ""):
            raise ps.ProjectError("INVALID_INPUT", "Identifiant client invalide.", field="clientId")
        ctrl = dict(self.read_control())
        clients = set(ctrl.get("pausedClients") or [])
        (clients.add if paused else clients.discard)(client_id)
        ctrl["pausedClients"] = sorted(clients)
        self.write_control(ctrl)
        return {"ok": True, "pausedClients": ctrl["pausedClients"]}

    def admin_kill_all(self, on):
        ctrl = dict(self.read_control())
        ctrl["killAll"] = bool(on)
        self.write_control(ctrl)
        if on:
            self.kill_all_running("KILL_ALL")
        return {"ok": True, "killAll": bool(on)}

    def admin_kill_project(self, pid):
        client_id = self.store.client_of(pid)
        if not client_id:
            raise ps.ProjectNotFound(pid)
        self._cancel(pid, "OWNER_KILLED", "Le projet a été arrêté par l'administration.", "owner")
        return {"ok": True, "status": "CANCELLED"}

    def admin_list(self):
        rows = []
        for pid, cid in self.store.all_ids():
            try:
                st = self.store.state(pid)
            except ps.ProjectError:
                continue
            b = st.get("budget") or {}
            rows.append({"projectId": pid, "clientId": cid, "status": st.get("status"), "createdUtc": st.get("createdUtc"), "updatedUtc": st.get("updatedUtc"),
                         "leadWorker": st.get("leadWorker"), "creditsCharged": b.get("creditsCharged"), "creditsCap": b.get("creditsCap"),
                         "chfSpent": b.get("chfSpent"), "stepsRun": (st.get("counters") or {}).get("stepsRun")})
        day = self.now() - 86400
        spend = sum(float(r["chfSpent"] or 0) for r in rows if (ps.parse_iso(r["updatedUtc"]) or 0) >= day)
        return {"projects": rows, "running": self.running_count(), "control": self.read_control(), "chfActiveToday": round(spend, 4)}

    # ------------------------------------------------------------------ suppression de compte
    def purge_client(self, client_id):
        """Suppression de compte : arrête les lanceurs du client et supprime tous ses projets (runtime/projects/<ClientId>). Jamais d'exception."""
        if not ps.CLIENT_ID_RE.match(client_id or ""):
            return 0
        n = 0
        for pid in list(self.store.ids_of_client(client_id)):
            try:
                self.abort_running_steps(pid, "CANCELLED")
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"projects purge_client abort: {type(e).__name__}\n")
            self._live.pop(pid, None)
            self._last_maint.pop(pid, None)
            n += 1
        import shutil
        try:
            shutil.rmtree(self.store.client_dir(client_id), ignore_errors=True)
        except ps.ProjectError:
            pass
        self.store.refresh_index()
        return n

