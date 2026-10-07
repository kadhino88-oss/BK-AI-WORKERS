# -*- coding: utf-8 -*-
"""Mesure reelle de la disponibilite du service (page /status.html, API /api/status).

Principe : un fil d'arriere-plan echantillonne le service toutes les 60 secondes et
l'enregistre sur disque. Rien n'est jamais invente : la page n'affiche que ce qui a
ete mesure, depuis la date du tout premier echantillon.

Trois sondes, aucune ne fait d'appel facturable :
  - app  : requete HTTP locale sur /api/health (le serveur accepte et repond) ;
  - data : fichiers d'etat lisibles et JSON valides (comptes, sessions, etat du moteur) ;
  - ai   : DNS + connexion TCP vers l'hote du fournisseur de modele (aucune requete HTTP,
           aucun appel d'API : cout nul).

Stockage (dossier de donnees d'execution, persistant entre deux deploiements) :
  <dir>/meta.json                 date du premier echantillon
  <dir>/days/AAAA-MM-JJ.json      un agregat par jour (UTC) : 1 caractere par minute
                                  U = en service, D = degrade, X = indisponible, . = aucune mesure
  <dir>/incidents.json            journal d'incidents, modifiable par le proprietaire
Rotation : les agregats de plus de 90 jours sont supprimes.

Regle de calcul (volontairement prudente) : une minute SANS mesure est comptee comme
indisponible. Un serveur arrete ne peut pas se mesurer lui-meme ; ne compter que les
minutes mesurees afficherait 100 % apres une panne totale. Le pourcentage est calcule
uniquement sur la periode ecoulee depuis le premier echantillon.
"""
import datetime
import glob
import json
import math
import os
import re
import secrets
import socket
import threading
import time
import urllib.request

SLOT_SECONDS = 60
DAY_SLOTS = 1440
RETENTION_DAYS = 90
STALE_AFTER_SECONDS = 180          # dernier echantillon plus vieux que ca : etat "inconnu"
UP, DEGRADED, DOWN, NONE = "U", "D", "X", "."
_RANK = {NONE: 0, UP: 1, DEGRADED: 2, DOWN: 3}
_DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")

AI_HOST = "api.anthropic.com"      # meme hote que core/ai/adapters/ANTHROPIC-ADAPTER.ps1
AI_PORT = 443


# --------------------------------------------------------------------- temps
def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def day_key(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d")


def day_start_ts(key):
    y, m, d = (int(x) for x in key.split("-"))
    return datetime.datetime(y, m, d, tzinfo=datetime.timezone.utc).timestamp()


def _pct(avail, expected):
    """Pourcentage tronque (jamais arrondi vers le haut) : 99,996 % s'affiche 99,99 %, pas 100 %."""
    if expected <= 0:
        return None
    return math.floor(avail * 10000 / expected) / 100


def _write_json_atomic(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = os.path.join(os.path.dirname(path) or ".", ".tmp-" + os.path.basename(path) + "-" + secrets.token_hex(4))
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


# -------------------------------------------------------------------- sondes
def check_app(port, host="127.0.0.1", timeout=3.0):
    """Le serveur HTTP accepte une vraie requete et repond (via la boucle locale)."""
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))      # jamais via un proxy d'environnement
        with opener.open(f"http://{host}:{int(port)}/api/health", timeout=timeout) as r:
            return r.status == 200 and json.loads(r.read(2000).decode("utf-8")).get("ok") is True
    except Exception:
        return False


def check_ai_reachable(host=AI_HOST, port=AI_PORT, timeout=4.0):
    """DNS puis connexion TCP seulement : aucune requete HTTP, aucun appel d'API, aucun cout."""
    found = {}

    def resolve():
        try:
            found["infos"] = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        except OSError:
            found["infos"] = None

    t = threading.Thread(target=resolve, daemon=True)
    t.start()
    t.join(timeout)
    infos = found.get("infos")
    if not infos:
        return False
    family, socktype, proto, _, addr = infos[0]
    s = None
    try:
        s = socket.socket(family, socktype, proto)
        s.settimeout(timeout)
        s.connect(addr)
        return True
    except OSError:
        return False
    finally:
        if s is not None:
            s.close()


class DataChecker:
    """Les fichiers d'etat dont depend le service sont lisibles et contiennent du JSON valide.
    (Le 2026-09-28 un fichier d'etat du moteur a ete ecrit a moitie : toutes les missions
    echouaient alors que le site repondait. Cette sonde aurait vu ce cas.)
    Le contenu n'est reparse que si le fichier a change (taille/date)."""

    def __init__(self, root, state_glob_refresh=600):
        self.root = root
        self._seen = {}             # chemin -> (mtime_ns, size) deja valide
        self._files = []
        self._files_at = 0
        self._logged_at = -1e12
        self._refresh = state_glob_refresh

    def _state_files(self, now):
        if now - self._files_at > self._refresh:
            pattern = os.path.join(self.root, "core", "**", "state", "*.json")
            self._files = sorted(glob.glob(pattern, recursive=True))
            self._files_at = now
        base = [os.path.join(self.root, "core", "accounts", "data", n) for n in ("accounts.json", "sessions.json")]
        return [p for p in base if os.path.exists(p)] + self._files

    def _ok_file(self, path):
        try:
            st = os.stat(path)
            sig = (st.st_mtime_ns, st.st_size)
            if self._seen.get(path) == sig:
                return True
            with open(path, "rb") as f:
                raw = f.read()
            if raw.strip():                     # un fichier vide = etat neuf, pas une panne
                json.loads(raw.decode("utf-8-sig"))
            self._seen[path] = sig
            return True
        except (OSError, ValueError):
            self._seen.pop(path, None)
            return False

    RETRIES = 3                                 # relectures espacees de 0,3 s : une ecriture concurrente en cours n'est pas une panne
    LOG_EVERY_SECONDS = 600

    def _log_bad(self, path, now):
        """Journal INTERNE du serveur (jamais la page publique) : quel fichier d'etat est illisible, pour le retrouver."""
        if now - self._logged_at >= self.LOG_EVERY_SECONDS:
            self._logged_at = now
            try:
                rel = os.path.relpath(path, self.root)
            except ValueError:
                rel = os.path.basename(path)
            print(f"[status] fichier d'etat illisible ou invalide : {rel}", flush=True)

    def __call__(self, now=None):
        now = now if now is not None else time.time()
        for path in self._state_files(now):
            ok = self._ok_file(path)
            for _ in range(self.RETRIES - 1):
                if ok:
                    break
                time.sleep(0.3)
                ok = self._ok_file(path)
            if not ok:
                self._log_bad(path, now)
                return False
        for d in (os.path.join(self.root, "core", "accounts", "data"), os.path.join(self.root, "runtime", "tasks")):
            if os.path.isdir(d):
                try:
                    with os.scandir(d) as it:
                        next(it, None)
                except OSError:
                    return False
        return True


# --------------------------------------------------------------- enregistreur
def classify(results):
    """results : {"app": bool, "data": bool, "ai": bool} -> U / D / X."""
    if not results.get("app") or not results.get("data"):
        return DOWN
    if not results.get("ai", True):
        return DEGRADED
    return UP


class StatusRecorder:
    def __init__(self, data_dir, clock=time.time):
        self.dir = data_dir
        self.days_dir = os.path.join(data_dir, "days")
        self.clock = clock
        self._lock = threading.RLock()
        self._days = {}
        self._since = None          # timestamp du premier echantillon jamais enregistre
        self._last = None           # dernier echantillon {"ts", "app", "data", "ai"}
        self.persist_error = False
        self._load()

    # ---- disque
    def _day_path(self, key):
        return os.path.join(self.days_dir, key + ".json")

    def _load(self):
        try:
            with open(os.path.join(self.dir, "meta.json"), encoding="utf-8") as f:
                since = json.load(f).get("measuredSinceTs")
            if isinstance(since, (int, float)) and since > 0:
                self._since = float(since)
        except (OSError, ValueError, AttributeError):
            pass
        for path in sorted(glob.glob(os.path.join(self.days_dir, "*.json"))):
            key = os.path.basename(path)[:-5]
            if not _DAY_RE.match(key):
                continue
            try:
                with open(path, encoding="utf-8") as f:
                    raw = json.load(f)
                minutes = raw["minutes"]
                if not isinstance(minutes, str) or len(minutes) != DAY_SLOTS or set(minutes) - set(_RANK):
                    continue
                self._days[key] = {
                    "minutes": bytearray(minutes.encode("ascii")),
                    "samples": int(raw.get("samples", 0)),
                    "first": raw.get("firstTs"),
                    "last": raw.get("lastTs"),
                    "checks": {k: [int(v[0]), int(v[1])] for k, v in (raw.get("checks") or {}).items()},
                }
            except (OSError, ValueError, KeyError, TypeError, IndexError):
                continue        # agregat illisible : ignore (jamais reconstitue)
        if self._since is None and self._days:
            firsts = [d["first"] for d in self._days.values() if isinstance(d.get("first"), (int, float))]
            if firsts:
                self._since = float(min(firsts))
        self.rotate()

    def _persist_day(self, key):
        d = self._days[key]
        try:
            _write_json_atomic(self._day_path(key), {
                "version": 1, "date": key, "minutes": d["minutes"].decode("ascii"), "samples": d["samples"],
                "firstTs": d["first"], "lastTs": d["last"], "checks": d["checks"],
            })
            self.persist_error = False
        except OSError:
            self.persist_error = True

    def rotate(self, now=None):
        now = now if now is not None else self.clock()
        oldest = day_key(now - (RETENTION_DAYS - 1) * 86400)
        for key in [k for k in self._days if k < oldest]:
            self._days.pop(key, None)
        try:
            for path in glob.glob(os.path.join(self.days_dir, "*.json")):
                key = os.path.basename(path)[:-5]
                if _DAY_RE.match(key) and key < oldest:
                    os.remove(path)
            for path in glob.glob(os.path.join(self.days_dir, ".tmp-*")):
                if time.time() - os.path.getmtime(path) > 3600:
                    os.remove(path)
        except OSError:
            pass

    # ---- ecriture d'un echantillon
    def record(self, results, ts=None):
        ts = float(ts if ts is not None else self.clock())
        state = classify(results)
        with self._lock:
            key = day_key(ts)
            new_day = key not in self._days
            day = self._days.setdefault(key, {"minutes": bytearray(NONE.encode() * DAY_SLOTS), "samples": 0,
                                              "first": None, "last": None, "checks": {}})
            idx = (int(ts) % 86400) // SLOT_SECONDS
            cur = chr(day["minutes"][idx])
            if _RANK[state] >= _RANK[cur]:      # le pire etat observe dans la minute
                day["minutes"][idx] = ord(state)
            for name, ok in results.items():
                c = day["checks"].setdefault(name, [0, 0])
                c[0 if ok else 1] += 1
            day["samples"] += 1
            day["first"] = ts if day["first"] is None else min(day["first"], ts)
            day["last"] = ts if day["last"] is None else max(day["last"], ts)
            if self._since is None:
                self._since = ts
                try:
                    _write_json_atomic(os.path.join(self.dir, "meta.json"), {"measuredSinceTs": ts, "measuredSinceUtc": iso(ts)})
                except OSError:
                    self.persist_error = True
            self._last = {"ts": ts, "app": bool(results.get("app")), "data": bool(results.get("data")),
                          "ai": bool(results.get("ai", True))}
            self._persist_day(key)
            if new_day:
                self.rotate(ts)
        return state

    # ---- lecture
    def last_sample(self):
        with self._lock:
            return dict(self._last) if self._last else None

    def snapshot(self, now=None):
        """Etat courant + jours reellement mesures + disponibilite, calcules sous verrou."""
        now = float(now if now is not None else self.clock())
        with self._lock:
            since = self._since
            last = dict(self._last) if self._last else None
            days_out = []
            tot_exp = tot_av = tot_deg = 0
            if since is not None:
                first_slot = int(since // SLOT_SECONDS)
                now_slot = int(now // SLOT_SECONDS)
                first_key = max(day_key(since), day_key(now - (RETENTION_DAYS - 1) * 86400))
                key = first_key
                today = day_key(now)
                while key <= today:
                    start_slot = int(day_start_ts(key) // SLOT_SECONDS)
                    lo = max(first_slot, start_slot, now_slot - RETENTION_DAYS * DAY_SLOTS)
                    hi = min(now_slot, start_slot + DAY_SLOTS)
                    if hi > lo:
                        d = self._days.get(key)
                        seg = bytes(d["minutes"][lo - start_slot:hi - start_slot]).decode("ascii") if d else NONE * (hi - lo)
                        n_up, n_deg, n_down, n_none = seg.count(UP), seg.count(DEGRADED), seg.count(DOWN), seg.count(NONE)
                        expected = hi - lo
                        avail = n_up + n_deg
                        tot_exp += expected
                        tot_av += avail
                        tot_deg += n_deg
                        pct = _pct(avail, expected)
                        if pct >= 99.9:
                            level = "degraded" if n_deg else "ok"
                        elif pct >= 99:
                            level = "minor"
                        elif pct >= 95:
                            level = "major"
                        else:
                            level = "outage"
                        days_out.append({
                            "date": key, "uptimePercent": pct, "expectedMinutes": expected,
                            "availableMinutes": avail, "unavailableMinutes": expected - avail,
                            "degradedMinutes": n_deg, "unmeasuredMinutes": n_none, "level": level,
                            "partial": lo > start_slot or hi < start_slot + DAY_SLOTS,
                        })
                    key = day_key(day_start_ts(key) + 86400)
        fresh = last is not None and now - last["ts"] <= STALE_AFTER_SECONDS
        if not fresh:
            status, comps = "unknown", {"app": "unknown", "data": "unknown", "ai": "unknown"}
        else:
            comps = {"app": "ok" if last["app"] else "down", "data": "ok" if last["data"] else "down",
                     "ai": "ok" if last["ai"] else "down"}
            status = "outage" if (not last["app"] or not last["data"]) else ("degraded" if not last["ai"] else "operational")
        return {
            "status": status, "components": comps, "sinceTs": since, "days": days_out,
            "expectedMinutes": tot_exp, "availableMinutes": tot_av, "degradedMinutes": tot_deg,
            "uptimePercent": _pct(tot_av, tot_exp), "lastSampleTs": last["ts"] if last else None,
        }


# --------------------------------------------------------------- boucle de mesure
class Sampler(threading.Thread):
    """Lance toutes les `interval` secondes les sondes et les enregistre. Une sonde qui
    plante compte comme un echec ; la boucle, elle, ne s'arrete jamais."""

    def __init__(self, recorder, probes, interval=SLOT_SECONDS, first_delay=5.0):
        super().__init__(name="status-sampler", daemon=True)
        self.recorder, self.probes = recorder, probes
        self.interval, self.first_delay = max(1.0, float(interval)), float(first_delay)
        self._stop_evt = threading.Event()

    def stop(self):
        self._stop_evt.set()

    def sample_once(self, ts=None):
        results = {}
        for name, fn in self.probes.items():
            try:
                results[name] = bool(fn())
            except Exception:
                results[name] = False
        return self.recorder.record(results, ts=ts)

    def run(self):
        next_t = time.time() + self.first_delay
        while not self._stop_evt.is_set():
            wait = next_t - time.time()
            if wait > 0 and self._stop_evt.wait(wait):
                break
            tick = next_t
            try:
                self.sample_once(ts=tick)
            except Exception:
                pass
            next_t += self.interval
            if next_t < time.time():            # en retard (machine en veille...) : on ne rattrape pas
                next_t = time.time() + self.interval


# ------------------------------------------------------------ journal d'incidents
INCIDENT_STATUSES = ("investigating", "identified", "monitoring", "resolved")
INCIDENT_IMPACTS = ("none", "minor", "major", "critical", "maintenance")
_MAX_TITLE, _MAX_TEXT, _MAX_UPDATES, _MAX_INCIDENTS = 140, 600, 40, 200


def _clip(value, n):
    return re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", str(value or "")).strip()[:n]


def _iso_or_none(value):
    s = str(value or "").strip()
    return s if _ISO_RE.match(s) else None


def _clean_incident(raw):
    if not isinstance(raw, dict):
        return None
    iid, title = _clip(raw.get("id"), 40), _clip(raw.get("title"), _MAX_TITLE)
    started = _iso_or_none(raw.get("startedAtUtc"))
    if not iid or not title or not started:
        return None
    status = raw.get("status") if raw.get("status") in INCIDENT_STATUSES else "investigating"
    impact = raw.get("impact") if raw.get("impact") in INCIDENT_IMPACTS else "minor"
    resolved = _iso_or_none(raw.get("resolvedAtUtc"))
    if status == "resolved" and not resolved:
        resolved = started
    updates = []
    for u in (raw.get("updates") or [])[:_MAX_UPDATES]:
        if isinstance(u, dict) and _iso_or_none(u.get("atUtc")) and _clip(u.get("text"), _MAX_TEXT):
            updates.append({"atUtc": u["atUtc"], "status": u.get("status") if u.get("status") in INCIDENT_STATUSES else status,
                            "text": _clip(u.get("text"), _MAX_TEXT)})
    updates.sort(key=lambda u: u["atUtc"])
    return {"id": iid, "title": title, "status": status, "impact": impact, "startedAtUtc": started,
            "resolvedAtUtc": resolved if status == "resolved" else None, "updates": updates}


class IncidentLog:
    """Journal d'incidents du proprietaire : un fichier JSON simple, lisible et modifiable a la main.
    Une faute de frappe dans le fichier ne fait pas disparaitre les incidents : on garde la
    derniere version valide en memoire."""

    def __init__(self, path, clock=time.time):
        self.path, self.clock = path, clock
        self._lock = threading.RLock()
        self._cache, self._sig, self.invalid = [], None, False

    def _read(self):
        with self._lock:
            try:
                st = os.stat(self.path)
            except OSError:
                self._cache, self._sig, self.invalid = [], None, False
                return self._cache
            sig = (st.st_mtime_ns, st.st_size)
            if sig == self._sig:
                return self._cache
            try:
                with open(self.path, encoding="utf-8-sig") as f:
                    data = json.load(f)
                rows = data.get("incidents") if isinstance(data, dict) else data
                self._cache = [c for c in (_clean_incident(r) for r in (rows or [])[:_MAX_INCIDENTS]) if c]
                self.invalid = False
            except (OSError, ValueError):
                self.invalid = True              # on garde self._cache (derniere version valide)
            self._sig = sig
            return self._cache

    def _write(self, rows):
        _write_json_atomic(self.path, {"incidents": rows})
        self._sig = None

    def list_all(self):
        return [dict(r) for r in self._read()]

    def public(self, now=None):
        now = now if now is not None else self.clock()
        limit = iso(now - RETENTION_DAYS * 86400)
        rows = [r for r in self._read() if r["status"] != "resolved" or r["startedAtUtc"] >= limit]
        rows.sort(key=lambda r: r["startedAtUtc"], reverse=True)
        return [dict(r) for r in rows[:30]]

    def _new_id(self, rows, ts):
        base = "INC-" + day_key(ts).replace("-", "")
        n = 1 + sum(1 for r in rows if r["id"].startswith(base))
        return f"{base}-{n}"

    def add(self, title, status="investigating", impact="minor", text="", started_at=None):
        with self._lock:
            rows = self.list_all()
            now = self.clock()
            started = _iso_or_none(started_at) or iso(now)
            inc = _clean_incident({"id": self._new_id(rows, now), "title": title, "status": status, "impact": impact,
                                   "startedAtUtc": started,
                                   "updates": [{"atUtc": iso(now), "status": status, "text": text}] if text else []})
            if not inc:
                raise ValueError("TITLE_REQUIRED")
            rows.append(inc)
            self._write(rows[-_MAX_INCIDENTS:])
            return inc

    def update(self, incident_id, status=None, text=None, impact=None):
        with self._lock:
            rows = self.list_all()
            for r in rows:
                if r["id"] == incident_id:
                    if status in INCIDENT_STATUSES:
                        r["status"] = status
                        r["resolvedAtUtc"] = iso(self.clock()) if status == "resolved" else None
                    if impact in INCIDENT_IMPACTS:
                        r["impact"] = impact
                    if text and _clip(text, _MAX_TEXT):
                        r["updates"].append({"atUtc": iso(self.clock()), "status": r["status"], "text": _clip(text, _MAX_TEXT)})
                    self._write(rows)
                    return r
            raise KeyError("INCIDENT_NOT_FOUND")

    def resolve(self, incident_id, text=""):
        return self.update(incident_id, status="resolved", text=text or None)

    def delete(self, incident_id):
        with self._lock:
            rows = self.list_all()
            kept = [r for r in rows if r["id"] != incident_id]
            if len(kept) == len(rows):
                raise KeyError("INCIDENT_NOT_FOUND")
            self._write(kept)


# ------------------------------------------------------------ charge utile publique
def public_payload(recorder, incidents, interval=SLOT_SECONDS, now=None):
    """Ce que voit n'importe quel visiteur. Aucun detail interne : ni chemin, ni nom d'hote,
    ni message d'erreur, ni identifiant client — seulement des etats et des pourcentages."""
    now = float(now if now is not None else time.time())
    snap = recorder.snapshot(now)
    return {
        "generatedAtUtc": iso(now),
        "status": snap["status"],
        "components": [{"id": k, "state": snap["components"][k]} for k in ("app", "data", "ai")],
        "measuredSinceUtc": iso(snap["sinceTs"]) if snap["sinceTs"] else None,
        "uptime": {"percent": snap["uptimePercent"], "measuredMinutes": snap["expectedMinutes"],
                   "degradedMinutes": snap["degradedMinutes"], "windowDays": RETENTION_DAYS},
        "days": snap["days"],
        "incidents": incidents.public(now),
        "sampleIntervalSeconds": int(interval),
    }
