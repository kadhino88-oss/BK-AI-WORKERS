# -*- coding: utf-8 -*-
"""Moteur de projets (« Projet ») : projets durables, étapes, vérification, approbations, budget, reprise.

Contrat : docs/AUTONOMY-ENGINE.md. Tout est DORMANT derrière BK_PROJECTS (défaut 0, voir projects_wiring.py).

Ce module est le point d'entrée public (ProjectService) ; la logique est répartie en modules cohérents (un propriétaire, aucun import du serveur) :
  project_paths.py       chemins sûrs de l'espace de travail
  projects_plan.py       validation du plan (validate_plan, utilisé aussi par Chloé)
  projects_config.py     réglages (PROJECT-LIMITS.json, PROJECT-PHASES.json, LEVELS.json)
  projects_store.py      disque, verrous, journal d'événements, machine à états (Txn.transition)
  projects_approvals.py  file d'approbations (articles, risque, lots, exécution, expiration)
  projects_context.py    contexte d'étape (context.md), résumé roulant, index de l'espace
  projects_verify.py     preuves résolues par le moteur, tours de vérification, rapport final
  projects_usage.py      interface d'usage (UsageService de B2 ou repli « mois seul »)
  projects_steps.py      vie d'une étape : porte de budget, lancement, fin, ingestion du spool, recalcul du projet
  projects_actions.py    actions du client (création, plan, messages, approbations, pause, annulation...)
  projects_view.py       résumés, détail, suivi (progress)

ProjectService est composé de ces modules (mixins) : un seul objet, un seul superviseur.
"""
import datetime
import json
import os
import signal
import subprocess
import sys
import threading
import time

import project_paths as pp
import projects_approvals as pa
import projects_config as cfg
import projects_store as ps
import projects_usage as pu
from projects_actions import ActionMixin
from projects_housekeeping import HousekeepingMixin
from projects_plan import (PlanResult, validate_plan, register_check_type, known_check_types,    # noqa: F401  (interface publique)
                           topological_order, critical_path_lengths, needs_consistency_review, percent_done)
from projects_steps import StepMixin
from projects_store import ProjectError, InvalidTransition, ProjectNotFound, ProjectStore    # noqa: F401
from projects_view import ViewMixin

LANG_NAMES = {"fr": "French", "en": "English", "de": "German", "it": "Italian", "es": "Spanish", "pt": "Portuguese"}
KIND_RANK = {"answer": 0, "plan": 1, "replan": 1, "verify": 2, "consolidate": 3, "fix": 4, "execute": 5}
RUNNER_SCRIPT = os.path.join("core", "ai", "adapters", "Project-StepRunner.ps1")


def _default_mem_available_mb():
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) // 1024
    except (OSError, ValueError):
        pass
    return None


class ProjectService(StepMixin, ActionMixin, ViewMixin, HousekeepingMixin):
    def __init__(self, root, ps_cmd, *, resolve_scope, usage, notify=None, run_connector=None, log_activity=None, write_json=None, lock=None,
                 plan_view=None, account_email=None, worker_summary=None, now=time.time, enabled=True, runner_cmd=None, installation_paused=None,
                 autoapprove=None, public_url="", owner_alert=None, mem_available=None, python=None, allowlist=None, tick_sec=5.0,
                 connectors_active=None, sleep=time.sleep, upgrade=None, files_cleanup_cmd=None):
        self.root = root
        self.ps_cmd = list(ps_cmd or [])
        self.resolve_scope = resolve_scope
        self.usage = usage
        self._notify_fn = notify
        self.run_connector = run_connector
        self.log_activity = log_activity or (lambda *a, **k: None)
        self.lock = lock
        self.plan_view_fn = plan_view
        self._upgrade_fn = upgrade            # fn(client_id) -> carte de montée en gamme (ou None) : appelée seulement dans les réponses de refus
        self.account_email = account_email or (lambda client_id: None)
        self.worker_summary = worker_summary or (lambda wid: {"id": wid, "name": str(wid).capitalize(), "role": "", "portraitUrl": f"/portraits/{wid}.jpg"})
        self.now = now
        self.enabled = bool(enabled)
        self.runner_cmd = runner_cmd
        self.installation_paused = installation_paused or (lambda client_id, worker_id: False)
        self.autoapprove = autoapprove
        self.public_url = (public_url or "").rstrip("/")
        self.owner_alert = owner_alert
        self.mem_available = mem_available or _default_mem_available_mb
        self.python = python or os.environ.get("BK_PYTHON") or ("python" if os.name == "nt" else "python3")
        self.allowlist = {c.strip() for c in (allowlist or "").split(",") if c.strip()} if isinstance(allowlist, str) else set(allowlist or ())
        self.tick_sec = float(tick_sec)
        self.sleep = sleep
        self.connectors_active = connectors_active or (lambda client_id: pa.active_connectors(self.root, client_id))
        self.store = ProjectStore(root, write_json=write_json, now=now, create=self.enabled)
        self.limits = cfg.load_limits(root)
        self.cfg = {"phases": cfg.load_phases(root), "levels": cfg.load_levels(root)}
        self.credit_cost = float(self.limits["budget"]["creditCostChf"])
        self._procs = {}                      # (pid, sid) -> StepProc
        self._procs_lock = threading.RLock()
        self._wake = threading.Event()
        self._thread = None
        self._stop = False
        self._control_cache = (0, {"killAll": False, "pausedClients": []})
        self._scope_cache = {}
        self._plan_cache = {}
        self._live = {}                       # pid -> dernier statut connu (projets non terminaux)
        self._last_maint = {}                 # pid -> {nom: epoch} dernières passes périodiques
        self._notify_q = []
        self._notify_lock = threading.Lock()
        self._notify_thread = None
        self._create_lock = threading.Lock()  # création d'un projet : plafonds (actifs, file, par jour) vérifiés sans course
        self._usage_cache = {}                # client -> (epoch, vue d'usage) : la progression est interrogée toutes les 3 s
        self._booted = False
        self.files_cleanup_cmd = files_cleanup_cmd      # fn(ids_path) -> argv ; défaut : Project-FilesCleanup.ps1 (la clé reste côté PowerShell)
        self._disk_cache = {}                 # client -> (epoch, octets)
        self._last_housekeeping = 0.0
        self._last_files_reap = 0.0
        self._spike_alerted = {}
        self.executor = pa.ApprovalExecutor(self._approval_begin, self._run_connector_safe, self._approval_finish, self.limits, now=now, sleep=sleep)
        self.store.hooks.append(self._on_commit)
        self.store.refresh_index()
        for pid_, cid in self.store.all_ids():
            try:
                st = self.store.state(pid_)
                if st.get("status") not in ps.TERMINAL:
                    self._live[pid_] = st.get("status")
            except ps.ProjectError:
                continue

    # ------------------------------------------------------------------ petits utilitaires
    def now_iso(self):
        return ps.iso(self.now())

    def require_enabled(self):
        if not self.enabled:
            raise ProjectError("PROJECTS_DISABLED", "Les projets ne sont pas encore activés.")

    def lang_name(self, code):
        return LANG_NAMES.get(str(code or "fr").lower()[:2], "French")

    def plan_id_of(self, client_id):
        return self.plan_view(client_id)["planId"]

    def plan_view(self, client_id):
        hit = self._plan_cache.get(client_id)
        if hit and self.now() - hit[0] < 5:
            return hit[1]
        try:
            pv = self.plan_view_fn(client_id) if self.plan_view_fn else {}
        except Exception:  # noqa: BLE001
            pv = {}
        pv = dict(pv or {})
        pid = str(pv.get("planId") or "essai")
        pv["planId"] = pid
        pv.setdefault("projectsAllowed", cfg.plan_value(self.limits["activeProjects"], pid, 0) > 0)
        self._plan_cache[client_id] = (self.now(), pv)
        return pv

    def scope_of(self, client_id, fresh=False):
        """Portée des Workers du client (recalculée à chaque tick) : {"chloe","allowed","denied","hireOffer"}."""
        t = self.now()
        hit = self._scope_cache.get(client_id)
        if hit and not fresh and t - hit[0] < 2:
            return hit[1]
        try:
            sc = self.resolve_scope(client_id) or {}
        except Exception as e:  # noqa: BLE001 - jamais « tout autorisé » par défaut
            sys.stderr.write(f"projects resolve_scope: {type(e).__name__}\n")
            sc = {"chloe": False, "allowed": [], "denied": [], "hireOffer": False}
        sc = {"chloe": bool(sc.get("chloe")), "allowed": list(sc.get("allowed") or []), "denied": list(sc.get("denied") or []),
              "hireOffer": bool(sc.get("hireOffer"))}
        self._scope_cache[client_id] = (t, sc)
        return sc

    def worker_in_scope(self, scope, worker):
        w = str(worker or "").lower()
        if w == "chloe":
            return bool(scope.get("chloe"))
        return w in {str(x).lower() for x in scope.get("allowed") or []}

    def project_path(self, pid, *parts):
        return os.path.join(self.store.project_dir(pid), *parts)

    def read_plan(self, pid):
        data = self.store.read_json(pid, "plan.json", {}) or {}
        return data.get("plan") or {}

    def nudge(self):
        self._wake.set()

    # ------------------------------------------------------------------ interrupteurs du propriétaire
    def read_control(self):
        path = os.path.join(self.store.base, "_control.json")
        try:
            mt = os.path.getmtime(path)
        except OSError:
            self._control_cache = (0, {"killAll": False, "pausedClients": []})
            return self._control_cache[1]
        if mt == self._control_cache[0]:
            return self._control_cache[1]
        data = cfg.read_json(path, {}) or {}
        ctrl = {"killAll": bool(data.get("killAll")), "pausedClients": [str(c) for c in data.get("pausedClients") or [] if isinstance(c, str)]}
        self._control_cache = (mt, ctrl)
        return ctrl

    def write_control(self, ctrl):
        path = os.path.join(self.store.base, "_control.json")
        pp.atomic_write_bytes(path, json.dumps({"killAll": bool(ctrl.get("killAll")), "pausedClients": sorted(set(ctrl.get("pausedClients") or []))},
                                               ensure_ascii=False, indent=2).encode("utf-8"))
        self._control_cache = (0, {"killAll": False, "pausedClients": []})
        self.nudge()

    # ------------------------------------------------------------------ processus
    def _runner_argv(self, input_path, output_path):
        if self.runner_cmd:
            return list(self.runner_cmd(input_path, output_path))
        return [*self.ps_cmd, "-File", os.path.join(self.root, RUNNER_SCRIPT), "-InFile", input_path, "-OutFile", output_path]

    def _spawn(self, argv, env, log_path):
        kw = {}
        if os.name == "nt":
            kw["creationflags"] = 0x00000200 | 0x08000000       # CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW
        else:
            kw["start_new_session"] = True
        logf = open(log_path, "ab")
        try:
            return subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=logf, stderr=subprocess.STDOUT, env=env, cwd=self.root, **kw)
        finally:
            logf.close()

    def kill_popen(self, popen):
        """Arrête le groupe de processus d'une étape (pwsh et ses enfants)."""
        if popen is None or popen.poll() is not None:
            return
        pid = popen.pid
        try:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True, timeout=15)
            else:
                try:
                    os.killpg(os.getpgid(pid), signal.SIGTERM)
                except ProcessLookupError:
                    return
                for _ in range(30):
                    if popen.poll() is not None:
                        return
                    time.sleep(0.1)
                try:
                    os.killpg(os.getpgid(pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
        except (OSError, subprocess.SubprocessError):
            try:
                popen.kill()
            except OSError:
                pass
        try:
            popen.wait(timeout=5)
        except (subprocess.TimeoutExpired, OSError):
            pass

    def kill_orphan(self, pid_file):
        """Processus d'une étape d'un serveur précédent (fichier pid). Sous Linux on vérifie la ligne de commande avant d'arrêter (PID réutilisé)."""
        try:
            with open(pid_file, encoding="utf-8") as f:
                rec = json.load(f)
            pid = int(rec.get("pid"))
        except (OSError, ValueError, TypeError):
            return False
        if not ps.pid_alive(pid):
            return False
        if os.name != "nt":
            try:
                with open(f"/proc/{pid}/cmdline", "rb") as f:
                    cmd = f.read()
            except OSError:
                return False
            tag = str(rec.get("tag") or "Project-StepRunner").encode()
            if b"Project-StepRunner" not in cmd and tag not in cmd:
                return False                     # ce PID a été réutilisé par un autre programme : on n'y touche pas
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                return False
            return True
        try:
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True, timeout=15)
            return True
        except (OSError, subprocess.SubprocessError):
            return False

    # ------------------------------------------------------------------ superviseur
    def start_supervisor(self):
        if not self.enabled:
            return
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop = False
        self._thread = threading.Thread(target=self._loop, name="projects-supervisor", daemon=True)
        self._thread.start()

    def stop(self, kill=True):
        self._stop = True
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout=10)
        self.executor.stop()
        if kill:
            with self._procs_lock:
                procs = list(self._procs.values())
            for sp in procs:
                self.kill_popen(sp.popen)

    def _loop(self):
        while not self._stop:
            try:
                self.tick()
            except Exception as e:  # noqa: BLE001 - le superviseur ne meurt jamais
                sys.stderr.write(f"projects supervisor tick: {type(e).__name__}: {e}\n")
            self._wake.wait(self.tick_sec)
            self._wake.clear()

    def tick(self):
        """Une passe du superviseur (publique : les tests la pilotent à la main)."""
        if not self.enabled:
            return
        now = self.now()
        ctrl = self.read_control()
        if ctrl["killAll"]:
            self.kill_all_running("KILL_ALL")
            return
        self._poll_procs(now)
        for pid in list(self._live):
            try:
                self._maintain(pid, now, ctrl)
            except ps.ProjectNotFound:
                self._live.pop(pid, None)
            except ps.LockConflict:
                continue
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"projects maintain {pid}: {type(e).__name__}: {e}\n")
        self._promote_queued(now)
        self._spawn_ready(now, ctrl)
        self.housekeeping_tick(now)

    def _on_commit(self, store, pid, state, events, transitions):
        status = state.get("status")
        if status in ps.TERMINAL:
            self._live.pop(pid, None)
        else:
            self._live[pid] = status
        self._notify_from_commit(pid, state, events, transitions)

    # ------------------------------------------------------------------ files d'attente et plafonds
    def running_count(self, client_id=None, exclude_answers=False):
        with self._procs_lock:
            n = 0
            for sp in self._procs.values():
                if client_id is not None and sp.client_id != client_id:
                    continue
                if exclude_answers and sp.kind == "answer":
                    continue
                n += 1
            return n

    def active_count(self, client_id):
        n = 0
        for pid in self.store.ids_of_client(client_id):
            if self._live.get(pid) in ps.ACTIVE_LIMIT_STATUSES:
                n += 1
        return n

    def queued_ids(self, client_id):
        ids = [p for p in self.store.ids_of_client(client_id) if self._live.get(p) == "QUEUED"]
        rows = []
        for p in ids:
            try:
                rows.append((self.store.state(p).get("createdUtc") or "", p))
            except ps.ProjectError:
                continue
        return [p for _c, p in sorted(rows)]

    def _promote_queued(self, now):
        by_client = {}
        for pid, status in list(self._live.items()):
            if status == "QUEUED":
                by_client.setdefault(self.store.client_of(pid), []).append(pid)
        for cid, _ids in by_client.items():
            if not cid:
                continue
            limit = int(cfg.plan_value(self.limits["activeProjects"], self.plan_id_of(cid), 0))
            for pid in self.queued_ids(cid):
                if self.active_count(cid) >= limit:
                    break
                try:
                    with self.store.txn(pid) as t:
                        if t.state["status"] != "QUEUED":
                            continue
                        t.transition("PLANNING", "SLOT_FREE")
                        t.event("status_changed", "Votre projet quitte la file d'attente : la planification commence.")
                except ps.ProjectError:
                    continue

    # ------------------------------------------------------------------ reprise au démarrage
    def reap(self, boot=False):
        """Au démarrage (appelé juste après reap_async_jobs(boot=True)) : étapes RUNNING sans processus -> INTERROMPUES (coût réglé d'après
        cost.json, tentative comptée, reprise avec une note) ; processus orphelins arrêtés ; articles EXECUTING -> UNKNOWN_CHECK_MANUALLY."""
        if not self.enabled:
            return
        self.store.refresh_index()
        self._live = {}
        for pid, cid in self.store.all_ids():
            try:
                st = self.store.state(pid)
            except ps.ProjectError:
                continue
            if st.get("status") in ps.TERMINAL:
                continue
            self._live[pid] = st.get("status")
            try:
                self._reap_project(pid, boot=boot)
            except ps.LockConflict:
                self._live.pop(pid, None)
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"projects reap {pid}: {type(e).__name__}: {e}\n")
        self._booted = True
        self._last_files_reap = 0.0              # le premier nettoyage des fichiers distants suit tout de suite le démarrage
        self.nudge()

    # ------------------------------------------------------------------ superviseur : arrêt global
    def kill_all_running(self, reason):
        with self._procs_lock:
            procs = list(self._procs.items())
        for key, sp in procs:
            sp.killed = reason
            self.kill_popen(sp.popen)
            self._finish_proc(key, sp)

    # ------------------------------------------------------------------ notifications (une file, un thread : l'envoi d'e-mail est lent)
    def _notify_from_commit(self, pid, state, events, transitions):
        kinds = []
        for old, new, reason in transitions:
            wf = state.get("waitingFor")
            if new == "WAITING_QUOTA":
                kinds.append("quota_waiting")
            elif new == "BUDGET_REACHED":
                kinds.append("budget_reached")
            elif new == "DONE":
                kinds.append("done")
            elif new == "FAILED":
                kinds.append("failed")
            elif new == "WAITING_INPUT" and wf in ("INPUT", "PLAN_VALIDATION", "CRITERIA_FAILED", "CONNECTOR", "APPROVAL_EXPIRED"):
                kinds.append("input_needed")
        for e in events:
            if e.get("type") == "approval_created":
                kinds.append("approval_needed")
        for k in dict.fromkeys(kinds):
            self.enqueue_notification(pid, k)

    def enqueue_notification(self, pid, kind):
        if not self._notify_fn:
            return
        with self._notify_lock:
            self._notify_q.append((pid, kind))
            if self._notify_thread is None or not self._notify_thread.is_alive():
                self._notify_thread = threading.Thread(target=self._notify_loop, name="projects-notify", daemon=True)
                self._notify_thread.start()

    def _notify_loop(self):
        while True:
            with self._notify_lock:
                if not self._notify_q:
                    self._notify_thread = None
                    return
                pid, kind = self._notify_q.pop(0)
            try:
                self.send_notification(pid, kind)
            except Exception as e:  # noqa: BLE001 - un échec d'envoi n'interrompt jamais le projet
                sys.stderr.write(f"projects notify {kind}: {type(e).__name__}\n")

    def drain_notifications(self, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            with self._notify_lock:
                if not self._notify_q and self._notify_thread is None:
                    return True
            time.sleep(0.02)
        return False

    def send_notification(self, pid, kind, extra=None):
        """E-mail générique (jamais de contenu : ni brouillon, ni adresse tierce). Limites : 1 par type, projet et heure ; 10 par client et par jour."""
        try:
            st = self.store.state(pid)
        except ps.ProjectError:
            return False
        client_id = st["clientId"]
        to = self.account_email(client_id)
        if not to:
            return False
        nl = self.limits["notifications"]
        now = self.now()
        sent = (st.get("notify") or {}).get("sent") or {}
        last = ps.parse_iso(sent.get(kind)) or 0
        gap = float(nl["perTypePerProjectPerHourMax"]) and 3600.0
        if kind == "approval_needed":
            gap = float(nl["approvalNeededMinGapMin"]) * 60          # au plus un e-mail de validation par projet toutes les 30 minutes
        if now - last < gap and kind not in ("done", "failed"):
            return False
        ledger_path = os.path.join(self.store.client_dir(client_id), "notify.json")
        ledger = cfg.read_json(ledger_path, {}) or {}
        day = [x for x in ledger.get("sent") or [] if now - x < 86400]
        if len(day) >= int(nl["perClientPerDayMax"]):
            return False
        title = str(st.get("title") or "votre projet")[:80]
        link = f"{self.public_url}/#projet/{pid}" if self.public_url else f"#projet/{pid}"
        subjects = {
            "approval_needed": (f"Votre validation est attendue — {title}", "Des actions sont prêtes et attendent votre validation. Rien ne part sans vous."),
            "input_needed": (f"Une réponse de votre part est attendue — {title}", "Votre projet attend une information ou une décision de votre part."),
            "quota_waiting": (f"Projet en pause jusqu'au renouvellement de votre quota — {title}",
                              "Votre projet a atteint une limite d'usage. Il reprendra tout seul au renouvellement" +
                              (f" ({st.get('resumeAtUtc')})" if st.get("resumeAtUtc") else "") +
                              " ; vous pouvez aussi passer à un forfait supérieur pour continuer tout de suite."),
            "budget_reached": (f"Plafond de crédits du projet atteint — {title}", "Le plafond de crédits de ce projet est atteint. Vous pouvez le relever, accepter l'état actuel ou annuler."),
            "done": (f"Votre projet est terminé — {title}", "Le projet est terminé et vérifié. Retrouvez les livrables et le rapport final."),
            "failed": (f"Votre projet a rencontré un problème — {title}", "Le projet s'est arrêté sur une erreur. Le travail déjà fait est conservé."),
            "approval_reminder": (f"Rappel : des actions attendent votre validation — {title}", "Des actions préparées par vos Workers n'ont pas encore été validées."),
        }
        if kind not in subjects:
            return False
        subject, text = subjects[kind]
        text_full = f"{text}\n\nOuvrir le projet : {link}\n\n— BK AI WORKERS"
        html = f"<p>{text}</p><p><a href=\"{link}\">Ouvrir le projet</a></p><p>— BK AI WORKERS</p>"
        try:
            ok = bool(self._notify_fn(client_id, kind, subject, html, text_full))
        except Exception:  # noqa: BLE001
            ok = False
        if ok is not False:
            ledger["sent"] = day + [now]
            try:
                pp.atomic_write_bytes(ledger_path, json.dumps(ledger).encode("utf-8"))
            except OSError:
                pass
            try:
                with self.store.txn(pid) as t:
                    t.state.setdefault("notify", {}).setdefault("sent", {})[kind] = ps.iso(now)
                    t.event("notification_sent", "Un e-mail de notification a été envoyé.", kind=kind)
            except ps.ProjectError:
                pass
            self.log_activity("project_notification", clientId=client_id, projectId=pid, kind=kind)
        return ok
