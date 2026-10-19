# -*- coding: utf-8 -*-
"""Magasin des projets : disque, verrous, journal d'événements et machine à états (docs/AUTONOMY-ENGINE.md, sections 2.1 à 2.6).

UN SEUL ÉCRIVAIN : seul ce module (donc Python, donc le serveur) écrit state.json, events.jsonl, inbox.jsonl, approvals.json, deliverables.json,
decisions.jsonl. Le lanceur PowerShell n'écrit que dans workspace/, spool/ et ses fichiers d'étape. Toute modification passe par une
transaction (`with store.txn(pid) as t:`) : verrou RLock par projet, état relu sur disque, événements ajoutés au journal AVANT l'état, état
réécrit en une fois (fichier temporaire + os.replace). Toute transition de statut passe par `Txn.transition`, qui vérifie la table 2.3.

Module PUR : aucune dépendance au serveur (le verrou global, l'écriture atomique et l'horloge sont injectables pour les tests).
"""
import datetime
import json
import os
import re
import secrets
import shutil
import sys
import threading
import time

import project_paths as pp

CLIENT_ID_RE = re.compile(r"^(CLI-CUST-[A-F0-9]{8}|CLI-DASHBOARD)\Z")
PROJECT_ID_RE = re.compile(r"^PRJ-[A-F0-9]{32}\Z")

STATUSES = ("PLANNING", "QUEUED", "RUNNING", "WAITING_APPROVAL", "WAITING_INPUT", "WAITING_QUOTA", "VERIFYING", "PAUSED",
            "BUDGET_REACHED", "DONE", "FAILED", "CANCELLED")
TERMINAL = frozenset(("DONE", "FAILED", "CANCELLED"))             # le client peut supprimer le projet ; FAILED peut être relancé (retry-step)
ACTIVE_LIMIT_STATUSES = frozenset(("PLANNING", "RUNNING", "VERIFYING", "WAITING_APPROVAL", "WAITING_INPUT", "WAITING_QUOTA"))
WORKING = frozenset(("PLANNING", "RUNNING", "VERIFYING"))        # le temps passé ici compte dans maxDurationHours (les WAITING_* ne comptent pas)

# Table 2.3 : transitions autorisées. Toute autre est refusée (InvalidTransition). Un projet non terminal peut toujours être suspendu,
# annulé ou échouer ; la reprise (PAUSED -> PLANNING/RUNNING/VERIFYING) revient à la phase où le projet en était.
_ANY_LIVE = ("PAUSED", "CANCELLED", "FAILED")
TRANSITIONS = {
    "QUEUED": frozenset(("PLANNING",) + _ANY_LIVE),
    "PLANNING": frozenset(("WAITING_INPUT", "RUNNING", "WAITING_QUOTA", "BUDGET_REACHED", "QUEUED") + _ANY_LIVE),
    "RUNNING": frozenset(("WAITING_APPROVAL", "WAITING_INPUT", "WAITING_QUOTA", "VERIFYING", "BUDGET_REACHED", "PLANNING", "DONE") + _ANY_LIVE),
    "WAITING_APPROVAL": frozenset(("RUNNING", "PLANNING", "VERIFYING", "WAITING_INPUT", "WAITING_QUOTA", "BUDGET_REACHED") + _ANY_LIVE),
    "WAITING_INPUT": frozenset(("RUNNING", "PLANNING", "VERIFYING", "WAITING_APPROVAL", "WAITING_QUOTA", "BUDGET_REACHED", "DONE") + _ANY_LIVE),
    "WAITING_QUOTA": frozenset(("RUNNING", "PLANNING", "VERIFYING", "WAITING_APPROVAL", "WAITING_INPUT", "BUDGET_REACHED") + _ANY_LIVE),
    "VERIFYING": frozenset(("RUNNING", "DONE", "WAITING_INPUT", "WAITING_APPROVAL", "WAITING_QUOTA", "BUDGET_REACHED") + _ANY_LIVE),
    "PAUSED": frozenset(("RUNNING", "PLANNING", "VERIFYING", "QUEUED", "WAITING_INPUT", "WAITING_APPROVAL", "WAITING_QUOTA") + ("CANCELLED", "FAILED")),
    "BUDGET_REACHED": frozenset(("RUNNING", "VERIFYING", "PLANNING", "DONE", "WAITING_INPUT", "WAITING_APPROVAL") + _ANY_LIVE),
    "FAILED": frozenset(("RUNNING", "PLANNING", "CANCELLED")),
    "DONE": frozenset(),
    "CANCELLED": frozenset(),
}

EVENT_TYPES = frozenset((
    "project_created", "plan_ready", "plan_approved", "plan_rejected", "status_changed", "step_started", "step_finished", "step_failed",
    "step_retry", "step_cost", "deliverable_added", "approval_created", "approval_decided", "approval_executed", "approval_failed",
    "input_requested", "message_received", "assistant_message", "quota_wait", "quota_resume", "budget_reached", "verification_started",
    "verification_result", "replan", "notification_sent", "done", "failed", "cancelled"))

EVENTS_KEPT_FOR_PROGRESS = 500
STATE_FILE = "state.json"


class ProjectError(Exception):
    def __init__(self, code, detail="", **extra):
        super().__init__(detail or code)
        self.code = code
        self.detail = detail
        self.extra = extra


class InvalidTransition(ProjectError):
    def __init__(self, old, new):
        super().__init__("INVALID_STATE", f"Transition interdite : {old} -> {new}.", status=old, target=new)
        self.old = old
        self.new = new


class ProjectNotFound(ProjectError):
    def __init__(self, pid=""):
        super().__init__("NOT_FOUND", "Projet introuvable.")


class LockConflict(ProjectError):
    def __init__(self, other):
        super().__init__("PROJECT_LOCK_CONFLICT", "Un autre processus serveur écrit dans ce projet.", other=other)


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(text):
    """Epoch (secondes) d'une date ISO 8601 UTC « …Z » ; None si illisible."""
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})", str(text or ""))
    if not m:
        return None
    try:
        return datetime.datetime(*(int(g) for g in m.groups()), tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        return None


def pid_alive(pid):
    """Le processus existe-t-il ? (Windows : jamais os.kill(pid, 0), qui TERMINE le processus ; on interroge l'API système.)"""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259
        k = ctypes.windll.kernel32
        h = k.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            return False
        try:
            code = ctypes.c_ulong()
            if not k.GetExitCodeProcess(h, ctypes.byref(code)):
                return False
            return code.value == STILL_ACTIVE
        finally:
            k.CloseHandle(h)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def new_project_id():
    return "PRJ-" + secrets.token_hex(16).upper()


class Txn:
    """Transaction sur UN projet (verrou tenu pendant tout le bloc). Les événements sont écrits avant l'état ; rien n'est écrit si le bloc lève."""

    def __init__(self, store, pid):
        self.store = store
        self.pid = pid
        self.state = None
        self.events = []
        self.transitions = []
        self.committed_events = []
        self._snapshot = None
        self._lock = None

    def __enter__(self):
        st = self.store
        self._lock = st.lock_for(self.pid)
        self._lock.acquire()
        try:
            depth = getattr(st._local, "depth", None)
            if depth is None:
                depth = st._local.depth = {}
            if depth.get(self.pid):
                raise RuntimeError("transaction imbriquée sur le même projet")
            self.state = st._load_state_locked(self.pid)
            self._snapshot = json.dumps(self.state, sort_keys=True, ensure_ascii=False)
            depth[self.pid] = True
        except BaseException:
            self._lock.release()
            raise
        return self

    def __exit__(self, exc_type, exc, tb):
        st = self.store
        try:
            st._local.depth.pop(self.pid, None)
            if exc_type is None:
                st._commit(self)
        finally:
            self._lock.release()
        if exc_type is None:
            st._run_hooks(self)
        return False

    @property
    def now(self):
        return self.store.now()

    def event(self, type_, text, stepId=None, worker=None, **data):
        self.events.append({"type": type_, "text": text, "stepId": stepId, "worker": worker, "data": data or None})

    def transition(self, new_status, reason=None, **fields):
        """Change le statut du projet (table 2.3). `fields` : waitingFor, resumeAtUtc, et tout champ de state.json à mettre à jour avec."""
        st = self.state
        old = st["status"]
        if new_status not in STATUSES:
            raise ProjectError("INVALID_STATE", f"Statut inconnu : {new_status}")
        now = self.now
        if new_status == old:
            for k, v in fields.items():
                st[k] = v
            st["statusReason"] = reason
            return
        if new_status not in TRANSITIONS.get(old, ()):
            raise InvalidTransition(old, new_status)
        since = parse_iso(st.get("statusSinceUtc")) or now
        if old in WORKING:
            st["activeSeconds"] = float(st.get("activeSeconds") or 0) + max(0.0, now - since)
        st["previousStatus"] = old
        st["status"] = new_status
        st["statusReason"] = reason
        st["statusSinceUtc"] = iso(now)
        st["waitingFor"] = fields.pop("waitingFor", None)
        st["resumeAtUtc"] = fields.pop("resumeAtUtc", None)
        for k, v in fields.items():
            st[k] = v
        if new_status in ("PLANNING", "RUNNING", "VERIFYING") and not st.get("startedUtc"):
            st["startedUtc"] = iso(now)
        if new_status in TERMINAL:
            st["finishedUtc"] = iso(now)
        elif old in TERMINAL:
            st["finishedUtc"] = None
        self.event("status_changed", f"Statut : {old} -> {new_status}" + (f" ({reason})" if reason else ""),
                   **{"from": old, "to": new_status, "reason": reason, "waitingFor": st.get("waitingFor")})
        self.transitions.append((old, new_status, reason))

    def append_jsonl(self, name, obj):
        self.store.append_jsonl(self.pid, name, obj)


class ProjectStore:
    def __init__(self, root, *, write_json=None, now=time.time):
        self.root = root
        self.base = os.path.join(root, "runtime", "projects")
        self.now = now
        self._write_json = write_json
        self._locks = {}
        self._locks_guard = threading.Lock()
        self._index = {}                 # pid -> client_id
        self._index_guard = threading.Lock()
        self._claimed = set()
        self._local = threading.local()
        self.hooks = []                  # fn(store, pid, state, events, transitions) appelées après chaque transaction validée
        self.boot_utc = iso(now())
        os.makedirs(self.base, exist_ok=True)
        self._real_base = os.path.realpath(self.base)
        self._dirs_ok = set()

    # ------------------------------------------------------------------ chemins
    def client_dir(self, client_id):
        if not CLIENT_ID_RE.match(client_id or ""):
            raise ProjectError("INVALID_INPUT", "Identifiant client invalide.")
        return os.path.join(self.base, client_id)

    def dir_for(self, client_id, pid):
        if not PROJECT_ID_RE.match(pid or ""):
            raise ProjectNotFound(pid)
        d = os.path.join(self.client_dir(client_id), pid)
        if d in self._dirs_ok:
            return d
        if not os.path.realpath(d).startswith(self._real_base + os.sep):      # confinement : jamais hors de runtime/projects (lien symbolique...)
            raise ProjectNotFound(pid)
        if os.path.isdir(d):
            self._dirs_ok.add(d)                                              # vérifié une fois (realpath est lent, surtout sous Windows)
        return d

    def refresh_index(self):
        idx = {}
        try:
            for cid in os.listdir(self.base):
                if not CLIENT_ID_RE.match(cid):
                    continue
                cdir = os.path.join(self.base, cid)
                for pid in os.listdir(cdir):
                    if PROJECT_ID_RE.match(pid) and os.path.isfile(os.path.join(cdir, pid, STATE_FILE)):
                        idx[pid] = cid
        except OSError:
            pass
        with self._index_guard:
            self._index = idx
        return idx

    def client_of(self, pid):
        if not PROJECT_ID_RE.match(pid or ""):
            return None
        with self._index_guard:
            cid = self._index.get(pid)
        if cid:
            return cid
        self.refresh_index()
        with self._index_guard:
            return self._index.get(pid)

    def project_dir(self, pid):
        cid = self.client_of(pid)
        if not cid:
            raise ProjectNotFound(pid)
        return self.dir_for(cid, pid)

    def all_ids(self):
        with self._index_guard:
            return sorted(self._index.items())

    def ids_of_client(self, client_id):
        with self._index_guard:
            return sorted(p for p, c in self._index.items() if c == client_id)

    def lock_for(self, pid):
        with self._locks_guard:
            lk = self._locks.get(pid)
            if lk is None:
                lk = self._locks[pid] = threading.RLock()
            return lk

    # ------------------------------------------------------------------ lecture / écriture de fichiers
    def read_json(self, pid, name, default=None):
        d = self.project_dir(pid)
        try:
            with open(os.path.join(d, name), encoding="utf-8-sig") as f:
                return json.load(f)
        except (OSError, ValueError):
            return default

    def write_json(self, pid, name, data):
        """Écriture atomique d'un fichier JSON du projet (réservée au magasin et à ses modules : un seul écrivain)."""
        d = self.project_dir(pid)
        self._claim(pid, d)
        path = os.path.join(d, name)
        if self._write_json:
            self._write_json(path, data, ensure_ascii=False, indent=2)
        else:
            pp.atomic_write_bytes(path, json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8"))

    def read_jsonl(self, pid, name, limit=None):
        """Lignes JSON lisibles d'un journal ; une ligne illisible (coupure) est ignorée. limit : les `limit` dernières."""
        d = self.project_dir(pid)
        out = []
        try:
            with open(os.path.join(d, name), encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        continue
        except OSError:
            return []
        return out[-limit:] if limit else out

    def append_jsonl(self, pid, name, obj):
        d = self.project_dir(pid)
        self._claim(pid, d)
        line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
        with self.lock_for(pid):
            with open(os.path.join(d, name), "a", encoding="utf-8") as f:
                f.write(line)
                f.flush()
                os.fsync(f.fileno())

    # ------------------------------------------------------------------ verrou de processus (.lock : deux serveurs simultanés)
    def _claim(self, pid, d):
        if pid in self._claimed:
            return
        path = os.path.join(d, ".lock")
        mine = {"pid": os.getpid(), "bootUtc": self.boot_utc}
        try:
            with open(path, encoding="utf-8") as f:
                other = json.load(f)
        except (OSError, ValueError):
            other = None
        if isinstance(other, dict) and other.get("pid") not in (None, os.getpid()) and pid_alive(other.get("pid")) \
                and other.get("bootUtc") != self.boot_utc:
            sys.stderr.write(f"PROJECT_LOCK_CONFLICT {pid} pid={other.get('pid')}\n")
            raise LockConflict(other)
        pp.atomic_write_bytes(path, json.dumps(mine).encode("utf-8"))
        self._claimed.add(pid)

    # ------------------------------------------------------------------ création / lecture de l'état
    def create(self, client_id, state):
        """Crée l'arborescence d'un projet et écrit state.json (état déjà construit par le service). Renvoie le dossier."""
        pid = state["projectId"]
        d = self.dir_for(client_id, pid)
        for sub in ("workspace/inputs", "workspace/handoff", "workspace/deliverables", "workspace/data", "workspace/notes", "spool", "steps",
                    "verification"):
            os.makedirs(os.path.join(d, *sub.split("/")), exist_ok=True)
        with self._index_guard:
            self._index[pid] = client_id
        self._claim(pid, d)
        with self.lock_for(pid):
            state.setdefault("seq", 0)
            self.write_json(pid, STATE_FILE, state)
        return d

    def _load_state_locked(self, pid):
        d = self.project_dir(pid)
        for _ in range(3):           # un lecteur peut tomber pile pendant un remplacement (Windows) : un second essai
            try:
                with open(os.path.join(d, STATE_FILE), encoding="utf-8-sig") as f:
                    st = json.load(f)
                if isinstance(st, dict):
                    return st
            except (OSError, ValueError):
                time.sleep(0.02)
        raise ProjectNotFound(pid)

    def state(self, pid):
        """Copie de lecture de l'état (sans verrou : les écritures sont atomiques)."""
        return self._load_state_locked(pid)

    def txn(self, pid):
        return Txn(self, pid)

    def _commit(self, t):
        pid = t.pid
        st = t.state
        d = self.project_dir(pid)
        now = self.now()
        out_events = []
        seq = int(st.get("seq") or 0)
        if t.events:
            self._claim(pid, d)
            lines = []
            for e in t.events:
                seq += 1
                rec = {"seq": seq, "ts": iso(now), "type": e["type"]}
                if e.get("stepId"):
                    rec["stepId"] = e["stepId"]
                if e.get("worker"):
                    rec["worker"] = e["worker"]
                rec["text"] = e["text"]
                if e.get("data"):
                    rec["data"] = e["data"]
                lines.append(json.dumps(rec, ensure_ascii=False, separators=(",", ":")))
                out_events.append(rec)
            with open(os.path.join(d, "events.jsonl"), "a", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
                f.flush()
                os.fsync(f.fileno())
            st["seq"] = seq
        if not out_events and t._snapshot is not None and json.dumps(st, sort_keys=True, ensure_ascii=False) == t._snapshot:
            t.committed_events = []
            return                      # rien n'a changé : aucune écriture (les passes périodiques du superviseur restent gratuites)
        st["updatedUtc"] = iso(now)
        self.write_json(pid, STATE_FILE, st)
        t.committed_events = out_events

    def _run_hooks(self, t):
        for hook in list(self.hooks):
            try:
                hook(self, t.pid, t.state, t.committed_events, t.transitions)
            except Exception as e:  # noqa: BLE001 - une notification ne casse jamais une transaction
                sys.stderr.write(f"projects_store hook: {type(e).__name__}: {e}\n")

    # ------------------------------------------------------------------ événements
    def events_since(self, pid, since=0, limit=200):
        """(événements avec seq > since, hasMore, reset). reset : `since` est plus ancien que les événements conservés pour le suivi."""
        evs = self.read_jsonl(pid, "events.jsonl")
        evs = evs[-EVENTS_KEPT_FOR_PROGRESS:]
        reset = bool(evs) and since > 0 and evs[0]["seq"] > since + 1 and len(evs) >= EVENTS_KEPT_FOR_PROGRESS
        picked = [e for e in evs if e["seq"] > since]
        more = len(picked) > limit
        return picked[:limit], more, reset

    def recover_seq(self, pid):
        """Après une coupure entre l'ajout d'événements et l'écriture de l'état : aligne `seq` sur la dernière ligne lisible du journal."""
        evs = self.read_jsonl(pid, "events.jsonl", limit=1)
        if not evs:
            return
        with self.txn(pid) as t:
            last = int(evs[-1].get("seq") or 0)
            if last > int(t.state.get("seq") or 0):
                t.state["seq"] = last

    # ------------------------------------------------------------------ suppression / usage disque
    def delete_project(self, client_id, pid):
        d = self.dir_for(client_id, pid)
        with self.lock_for(pid):
            shutil.rmtree(d, ignore_errors=True)
            with self._index_guard:
                self._index.pop(pid, None)
            self._claimed.discard(pid)
            self._dirs_ok.discard(d)

    def disk_usage_client(self, client_id):
        total = 0
        for pid in self.ids_of_client(client_id):
            try:
                total += pp.usage(os.path.join(self.dir_for(client_id, pid), "workspace"))[1]
            except (OSError, ProjectError):
                continue
        return total
