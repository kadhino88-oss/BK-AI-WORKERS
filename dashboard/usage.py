# -*- coding: utf-8 -*-
"""Fenetres d'usage comme celles de Claude : SESSION (4 h glissantes, ouverte par la premiere utilisation), SEMAINE (7 jours) et MOIS (cycle de
facturation). Une consommation (mission, etape de projet, automatisation) doit passer les TROIS fenetres ; la plus restrictive borne. Contrat :
docs/AUTONOMY-ENGINE.md, section 6b ; chiffres et regles du client : docs/PRICING.md, section 6.

Ce module est INDEPENDANT de server.py (aucun import de lui) : tout ce qu'il lui faut est injecte (plan_view, horloge, ecriture atomique, journal,
source des traces). dashboard/usage_wiring.py branche le tout sur server.py.

  - Grand livre O(1) par client : runtime/usage/<ClientId>.json (quelques centaines d'octets, jamais un balayage des TASK-*.json a chaque appel).
  - Reservation atomique : le controle des trois fenetres et leur mise a jour se font dans la MEME section critique (verrou par client dans le
    processus + verrou de fichier entre processus : quota-check.py, lance par le cron des automatisations, est un autre processus que le serveur).
  - Les allocations (session, semaine) ne sont JAMAIS stockees : elles sont recalculees a chaque controle depuis le forfait ACTUEL du client
    (montee ou descente de forfait en cours de fenetre : effet immediat, les compteurs restent).
  - Les traces (runtime/tasks/TASK-*.json, runtime/projects/**/cost-ledger.jsonl) font foi ; le grand livre est un cache que reconcile() corrige,
    jamais l'inverse.
  - BK_USAGE_WINDOWS : 0 (defaut) = le service est inerte (comportement d'avant) ; shadow = le grand livre tourne, rien n'est bloque et chaque refus
    qui aurait eu lieu est journalise (usage_would_block) ; 1 = actif.
"""
import contextlib
import copy
import datetime
import json
import math
import os
import re
import secrets
import threading
import time
from dataclasses import dataclass, field

try:                                      # verrou de fichier entre processus : fcntl sous Linux, msvcrt sous Windows
    import fcntl
except ImportError:                       # pragma: no cover - Windows
    fcntl = None
try:
    import msvcrt
except ImportError:                       # pragma: no cover - Linux
    msvcrt = None

SCHEMA = "BK-USAGE-LEDGER-V1"
WINDOW_NAMES = ("session", "week", "month")
UNBOUNDED = 1_000_000_000                 # allowedNow d'un compte exempte (proprietaire, essai public) : aucune fenetre ne borne
CLIENT_ID_OK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
RECENT_KEEP = 50

DEFAULT_LIMITS = {
    "version": 1, "creditCostChf": 0.0375, "weeklyDivisor": 4.35, "sessionShareOfWeek": 0.40, "sessionHours": 4, "weekDays": 7,
    "minSessionCredits": 12, "minStartCredits": 6,
    "reservationTtlSec": {"mission": 720, "project_step": 900, "automation": 300},
    "exemptClients": ["CLI-DASHBOARD", "CLI-TRIAL-PUBLIC"], "exemptPlans": ["essai"], "overridesByClient": {},
    "warnPercent": 80, "reconcileIntervalSec": 21600, "seedLookbackDays": 35, "displayTimezone": "Europe/Zurich",
}


# ----------------------------------------------------------------------------------------------------------------------------------------------
# Constantes (core/usage/USAGE-LIMITS.json) et allocations
# ----------------------------------------------------------------------------------------------------------------------------------------------
def _num(value, default, low, high, kind=float):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    value = kind(value)
    return value if low <= value <= high else default


def load_limits(path=None, override=None):
    """Constantes d'usage : valeurs par defaut, surchargees par le fichier du proprietaire puis par `override` (tests). Une valeur illisible ou
    hors bornes est ignoree (on garde la valeur par defaut) : un fichier mal edite ne coupe jamais le service."""
    out = copy.deepcopy(DEFAULT_LIMITS)
    data = {}
    if path:
        try:
            with open(path, encoding="utf-8-sig") as f:
                data = json.load(f)
        except (OSError, ValueError):
            data = {}
    for source in (data, override or {}):
        if not isinstance(source, dict):
            continue
        out["creditCostChf"] = _num(source.get("creditCostChf"), out["creditCostChf"], 0.0001, 100.0)
        out["weeklyDivisor"] = _num(source.get("weeklyDivisor"), out["weeklyDivisor"], 1.0, 52.0)
        out["sessionShareOfWeek"] = _num(source.get("sessionShareOfWeek"), out["sessionShareOfWeek"], 0.01, 1.0)
        out["sessionHours"] = _num(source.get("sessionHours"), out["sessionHours"], 0.01, 24 * 7, float)
        out["weekDays"] = _num(source.get("weekDays"), out["weekDays"], 0.01, 31, float)
        for key in ("minSessionCredits", "minStartCredits", "warnPercent", "reconcileIntervalSec", "seedLookbackDays"):
            out[key] = _num(source.get(key), out[key], 1, 10_000_000, int)
        ttl = source.get("reservationTtlSec")
        if isinstance(ttl, dict):
            for kind, secs in ttl.items():
                if isinstance(kind, str) and not isinstance(secs, bool) and isinstance(secs, int) and 1 <= secs <= 86400:
                    out["reservationTtlSec"][kind] = secs
        for key in ("exemptClients", "exemptPlans"):
            if isinstance(source.get(key), list):
                out[key] = [str(x) for x in source[key] if isinstance(x, str)]
        if isinstance(source.get("overridesByClient"), dict):
            out["overridesByClient"] = {k: v for k, v in source["overridesByClient"].items() if isinstance(k, str) and isinstance(v, dict)}
        if isinstance(source.get("displayTimezone"), str) and source["displayTimezone"]:
            out["displayTimezone"] = source["displayTimezone"]
        out["version"] = source.get("version", out["version"])
    return out


def _half_up(x):
    return int(math.floor(x + 0.5))


def _credits_int(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def allowances_for(month_credits, limits, override=None):
    """{session, week, month} pour un quota mensuel : semaine = mensuel / 4,35 (arrondi), session = max(12, 40 % de la semaine). Une session
    ne depasse jamais la semaine, ni la semaine le mois (cas d'un petit contrat). `override` = {"sessionCredits", "weekCredits"} (contrat
    Enterprise) : prioritaire sur la formule, toujours borne par le niveau du dessus."""
    month = _credits_int(month_credits) or 0
    if month == 0:
        return {"session": 0, "week": 0, "month": 0}
    week = _half_up(month / limits["weeklyDivisor"])
    session = max(limits["minSessionCredits"], _half_up(limits["sessionShareOfWeek"] * week))
    ov = override if isinstance(override, dict) else {}
    if _credits_int(ov.get("weekCredits")):
        week = ov["weekCredits"]
    if _credits_int(ov.get("sessionCredits")):
        session = ov["sessionCredits"]
    week = max(1, min(week, month))
    session = max(1, min(session, week))
    return {"session": session, "week": week, "month": month}


# ----------------------------------------------------------------------------------------------------------------------------------------------
# Temps (tout est en UTC ; l'horloge est injectee, les dates ISO sont celles du grand livre et de l'API)
# ----------------------------------------------------------------------------------------------------------------------------------------------
def iso(epoch):
    if epoch is None:
        return None
    return datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


_ISO_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?\s*(Z|[+-]\d{2}:?\d{2})?$")


def parse_iso(text):
    """Epoch (secondes, float) d'un texte ISO 8601 (« 2026-10-12T10:11:12.123Z », avec ou sans fuseau : sans fuseau = UTC) ; None si illisible."""
    m = _ISO_RE.match(str(text or "").strip())
    if not m:
        return None
    try:
        dt = datetime.datetime(*(int(g) for g in m.groups()[:6]), tzinfo=datetime.timezone.utc)
    except ValueError:
        return None
    off = m.group(7)
    if off and off != "Z":
        sign = 1 if off[0] == "+" else -1
        digits = off[1:].replace(":", "")
        dt -= sign * datetime.timedelta(hours=int(digits[:2]), minutes=int(digits[2:4]))
    return dt.timestamp()


_JOURS = ("lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche")
_MOIS = ("janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre")


def fr_duration(seconds):
    """« 1 h 12 », « 35 min », « 6 j 21 h » : durée restante, arrondie vers le haut à la minute."""
    secs = max(0, int(math.ceil(seconds / 60.0)) * 60)
    if secs < 60:
        return "moins d'une minute"
    mins = secs // 60
    if mins < 60:
        return f"{mins} min"
    hours, rest = divmod(mins, 60)
    if hours < 48:
        return f"{hours} h" + (f" {rest:02d}" if rest else "")
    days, hours = divmod(hours, 24)
    return f"{days} j" + (f" {hours} h" if hours else "")


def _tz(name):
    try:
        import zoneinfo
        return zoneinfo.ZoneInfo(name), name
    except Exception:  # noqa: BLE001 - tzdata absent : on dit « UTC » au lieu d'inventer une heure locale
        return datetime.timezone.utc, "UTC"


def fr_when(target, now, tzname="Europe/Zurich"):
    """Heure de renouvellement lisible : « à 14:12 » (aujourd'hui), « demain à 03:12 », « le lundi 27 octobre à 10:12 ». Sans base de fuseaux,
    l'heure est donnée en UTC et le dit. L'interface réaffiche l'heure dans le fuseau du navigateur à partir de resetsAtUtc."""
    tz, label = _tz(tzname)
    t = datetime.datetime.fromtimestamp(target, tz)
    n = datetime.datetime.fromtimestamp(now, tz)
    suffix = " UTC" if label == "UTC" and tzname != "UTC" else ""
    clock = t.strftime("%H:%M") + suffix
    days = (t.date() - n.date()).days
    if days <= 0:
        return f"à {clock}"
    if days == 1:
        return f"demain à {clock}"
    year = f" {t.year}" if days > 300 else ""
    return f"le {_JOURS[t.weekday()]} {t.day} {_MOIS[t.month - 1]}{year} à {clock}"


# ----------------------------------------------------------------------------------------------------------------------------------------------
# Objets rendus par le service
# ----------------------------------------------------------------------------------------------------------------------------------------------
@dataclass
class Window:
    limit: int
    used: int = 0
    reserved: int = 0
    remaining: int = 0
    opened: bool = False
    startUtc: str = None
    resetsAtUtc: str = None

    @property
    def percent_used(self):
        if not self.limit:
            return None
        return min(100, int(round(100.0 * (self.used + self.reserved) / self.limit)))

    def to_dict(self):
        return {"limit": self.limit, "used": self.used, "reserved": self.reserved, "remaining": self.remaining, "opened": self.opened,
                "startUtc": self.startUtc, "resetsAtUtc": self.resetsAtUtc, "percentUsed": self.percent_used}


@dataclass
class UsageView:
    session: Window = None            # None : fenetre qui ne s'applique pas (essai, proprietaire)
    week: Window = None
    month: Window = None
    binding: str = None               # fenetre la plus proche de sa limite : "session" | "week" | "month" | None
    allowedNow: int = 0               # credits utilisables tout de suite (plus petit reste des fenetres) ; UNBOUNDED pour un compte exempte
    exempt: bool = False
    windowsApply: bool = True
    planId: str = None
    mode: str = "on"

    def next_renewal_utc(self):
        w = getattr(self, self.binding) if self.binding else None
        return w.resetsAtUtc if w else None

    def to_dict(self, session_hours=4, week_days=7):
        out = {"exempt": self.exempt, "windowsApply": self.windowsApply, "planId": self.planId, "mode": self.mode,
               "binding": self.binding, "allowedNow": None if self.exempt else self.allowedNow, "nextRenewalUtc": self.next_renewal_utc()}
        for name in WINDOW_NAMES:
            w = getattr(self, name)
            out[name] = w.to_dict() if w else None
        if out["session"]:
            out["session"]["windowHours"] = session_hours
        if out["week"]:
            out["week"]["windowDays"] = week_days
        return out


@dataclass
class Reservation:
    id: str
    credits: int
    kind: str = "mission"
    ref: str = ""
    windows: dict = field(default_factory=dict)
    exempt: bool = False              # rien n'a ete enregistre (compte exempte, service inerte) : settle/release sont sans effet

    def __bool__(self):
        return True


@dataclass
class UsageBlock:
    limit: str                        # fenetre qui refuse : "session" | "week" | "month"
    resetsAtUtc: str                  # quand elle se renouvelle (None : jamais, ou la fenetre est trop petite pour ce montant)
    remaining: int
    needed: int
    view: UsageView = None

    def __bool__(self):
        return False


class UsageLockTimeout(RuntimeError):
    pass


# ----------------------------------------------------------------------------------------------------------------------------------------------
# Verrou de fichier entre processus (le serveur et quota-check.py ecrivent le meme grand livre)
# ----------------------------------------------------------------------------------------------------------------------------------------------
def _flock_acquire(path, timeout):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fh = open(path, "a+b")
    try:
        fh.seek(0, 2)
        if fh.tell() == 0:
            fh.write(b"0")
            fh.flush()
        deadline = time.monotonic() + timeout
        while True:
            try:
                if fcntl is not None:
                    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                elif msvcrt is not None:
                    fh.seek(0)
                    msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                return fh
            except OSError:
                if time.monotonic() >= deadline:
                    raise UsageLockTimeout(f"verrou du grand livre d'usage indisponible : {os.path.basename(path)}")
                time.sleep(0.01)
    except BaseException:
        fh.close()
        raise


def _flock_release(fh):
    try:
        if fcntl is not None:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        elif msvcrt is not None:
            fh.seek(0)
            msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
    except OSError:
        pass
    finally:
        fh.close()


class _Gate:
    __slots__ = ("lock", "depth", "fh")

    def __init__(self):
        self.lock = threading.RLock()
        self.depth = 0
        self.fh = None


def _write_atomic(path, data):
    """Ecriture atomique (fichier temporaire du meme dossier puis os.replace) ; sous Windows un lecteur qui tient le fichier fait echouer le
    remplacement : quelques essais."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".tmp-" + os.path.basename(path) + "-" + secrets.token_hex(6))
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        for attempt in range(20):
            try:
                os.replace(tmp, path)
                return
            except PermissionError:
                if attempt == 19:
                    raise
                time.sleep(0.02)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


# ----------------------------------------------------------------------------------------------------------------------------------------------
# Le service
# ----------------------------------------------------------------------------------------------------------------------------------------------
def _empty_window():
    return {"id": None, "startUtc": None, "endUtc": None, "used": 0, "reserved": 0, "proj": 0}


def _mode_from_env():
    v = str(os.environ.get("BK_USAGE_WINDOWS") or "0").strip().lower()
    if v in ("1", "on", "true", "yes"):
        return "on"
    if v == "shadow":
        return "shadow"
    return "off"


class UsageService:
    def __init__(self, root, *, plan_view, lock=None, write_json=None, now=time.time, nudge=None, limits=None, limits_path=None, mode=None,
                 log=None, trace_source=None, task_credits=None, resolve_expired=None, lock_timeout=10.0):
        """plan_view(client_id) -> {"planId", "monthlyCredits", "cycleStartUtc", "renewsAtUtc", "exempt", "override"} (fournie par server.py).
        now() -> secondes epoch (injectable pour les tests). trace_source(client_id) -> [(epoch, credits)] ; sinon lecture des traces du disque.
        resolve_expired(client_id, reservation) -> credits reellement consommes (etape de projet : cost.json) ou None = 0."""
        self.root = root
        self.dir = os.path.join(root, "runtime", "usage")
        self._plan_view = plan_view
        self._lock = lock or threading.RLock()
        self._write_json = write_json
        self._now = now
        self._nudge = nudge
        self._log = log
        self._mode = mode
        self._trace_source = trace_source
        self._task_credits = task_credits or _default_task_credits
        self._resolve_expired = resolve_expired
        self._lock_timeout = lock_timeout
        self._gates = {}
        self._tls = threading.local()
        self._limits_override = limits
        self._limits_path = limits_path or os.path.join(root, "core", "usage", "USAGE-LIMITS.json")
        self._limits_cache = (None, None)
        self._scan_cache = (None, None, None)

    # ---- constantes, mode, exemptions ------------------------------------------------------------------------------------------------------
    def limits(self):
        """Constantes courantes ; le fichier du proprietaire est relu quand il change (aucun redemarrage necessaire)."""
        try:
            mtime = os.stat(self._limits_path).st_mtime_ns
        except OSError:
            mtime = None
        if self._limits_cache[0] != mtime or self._limits_cache[1] is None:
            self._limits_cache = (mtime, load_limits(self._limits_path, self._limits_override))
        return self._limits_cache[1]

    def mode(self):
        m = self._mode() if callable(self._mode) else (self._mode or _mode_from_env())
        return m if m in ("off", "shadow", "on") else "off"

    @property
    def enabled(self):
        return self.mode() != "off"

    @property
    def enforced(self):
        return self.mode() == "on"

    def exempt_client(self, client_id):
        return client_id in self.limits()["exemptClients"]

    def _emit(self, event, **fields):
        """Journal d'activite. Pendant qu'un verrou de grand livre est tenu, l'evenement est mis en file et ecrit APRES sa liberation : le
        journal du serveur prend le verrou global de l'etat, et get_billing prend le verrou du grand livre alors qu'il le tient deja (ordre
        inverse = interblocage possible)."""
        if not self._log:
            return
        if getattr(self._tls, "depth", 0) > 0:
            self._tls.events.append((event, fields))
            return
        self._flush_one(event, fields)

    def _flush_one(self, event, fields):
        try:
            self._log(event, **fields)
        except Exception:  # noqa: BLE001 - le journal ne casse jamais une mission
            pass

    # ---- verrous ---------------------------------------------------------------------------------------------------------------------------
    def _gate(self, client_id):
        with self._lock:
            gate = self._gates.get(client_id)
            if gate is None:
                gate = self._gates[client_id] = _Gate()
            return gate

    @contextlib.contextmanager
    def _guard(self, client_id):
        gate = self._gate(client_id)
        tls = self._tls
        if getattr(tls, "depth", 0) == 0:
            tls.events = []
        tls.depth = getattr(tls, "depth", 0) + 1
        try:
            with gate.lock:
                if gate.depth == 0:
                    gate.fh = _flock_acquire(os.path.join(self.dir, client_id + ".lock"), self._lock_timeout)
                gate.depth += 1
                try:
                    yield
                finally:
                    gate.depth -= 1
                    if gate.depth == 0:
                        _flock_release(gate.fh)
                        gate.fh = None
        finally:
            tls.depth -= 1
            if tls.depth == 0:
                pending, tls.events = tls.events, []
                for event, fields in pending:
                    self._flush_one(event, fields)

    # ---- fichier ---------------------------------------------------------------------------------------------------------------------------
    def _path(self, client_id):
        if not isinstance(client_id, str) or not CLIENT_ID_OK.match(client_id):
            raise ValueError("identifiant client invalide")
        return os.path.join(self.dir, client_id + ".json")

    def _read(self, client_id):
        path = self._path(client_id)
        for _ in range(6):
            try:
                with open(path, encoding="utf-8") as f:
                    data = json.load(f)
                return data if isinstance(data, dict) and data.get("schema") == SCHEMA else None
            except FileNotFoundError:
                return None
            except (OSError, ValueError):
                time.sleep(0.02)          # lecteur tombe pile pendant un remplacement : un nouvel essai
        return None

    def _write(self, client_id, L, now):
        L["rev"] = int(L.get("rev") or 0) + 1
        L["updatedUtc"] = iso(now)
        path = self._path(client_id)
        if self._write_json:
            self._write_json(path, L)
        else:
            _write_atomic(path, L)

    # ---- traces (sources de verite) --------------------------------------------------------------------------------------------------------
    def _traces(self, client_id, force=False):
        """[(epoch, credits)] de ce client : missions et etapes de projet reunies."""
        task, proj = self._trace_parts(client_id, force)
        return task + proj

    def _trace_parts(self, client_id, force=False):
        """([(epoch, credits)] des missions, [(epoch, credits)] des etapes de projet) : missions = runtime/tasks/TASK-*.json (un seul balayage
        partage entre les clients tant que le dossier ne change pas), projets = cost-ledger.jsonl de chaque projet."""
        if self._trace_source:
            return list(self._trace_source(client_id)), self._project_traces(client_id)
        tasks_dir = os.path.join(self.root, "runtime", "tasks")
        try:
            sig = os.stat(tasks_dir).st_mtime_ns
        except OSError:
            sig = None
        cached_sig, cached_at, by_client = self._scan_cache
        if force or by_client is None or cached_sig != sig or time.monotonic() - cached_at > 30:
            by_client = self._scan_tasks(tasks_dir)
            self._scan_cache = (sig, time.monotonic(), by_client)
        return list(by_client.get(client_id, [])), self._project_traces(client_id)

    def _scan_tasks(self, tasks_dir):
        by_client = {}
        try:
            names = os.listdir(tasks_dir)
        except OSError:
            return by_client
        for name in names:
            if not (name.startswith("TASK-") and name.endswith(".json")):
                continue
            path = os.path.join(tasks_dir, name)
            try:
                with open(path, encoding="utf-8-sig") as f:
                    data = json.load(f)
            except (OSError, ValueError):
                continue
            if not isinstance(data, dict) or not data.get("ClientId"):
                continue
            credits = self._task_credits(data)
            if not credits:
                continue
            epoch = parse_iso(data.get("CreatedAtUtc"))
            if epoch is None:
                try:
                    epoch = os.path.getmtime(path)
                except OSError:
                    continue
            by_client.setdefault(data["ClientId"], []).append((epoch, credits))
        return by_client

    def _project_traces(self, client_id):
        """Credits regles par les etapes de projet : runtime/projects/<ClientId>/<ProjectId>/cost-ledger.jsonl, une ligne JSON par reglement
        {"ts": ISO UTC, "credits": entier}. (Format pose ici faute de definition cote moteur : voir docs/AUTONOMY-ENGINE.md, 6b.6.)"""
        out = []
        base = os.path.join(self.root, "runtime", "projects", client_id)
        try:
            projects = os.listdir(base)
        except OSError:
            return out
        for prj in projects:
            try:
                with open(os.path.join(base, prj, "cost-ledger.jsonl"), encoding="utf-8") as f:
                    lines = f.read().splitlines()
            except OSError:
                continue
            for line in lines:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                credits = _credits_int(row.get("credits", row.get("delta")))
                epoch = parse_iso(row.get("ts") or row.get("tsUtc") or row.get("at"))
                if credits and epoch is not None:
                    out.append((epoch, credits))
        return out

    @staticmethod
    def _replay(traces, now, length_s):
        """Fenetre glissante reconstruite depuis les traces (ordre chronologique : la premiere ouvre, la suivante apres la fin en ouvre une
        autre). Renvoie {"start", "end", "used"} si elle est encore ouverte a `now`, sinon None."""
        cur = None
        for epoch, credits in sorted(t for t in traces if t[1] > 0 and t[0] <= now):
            if cur is None or epoch >= cur["end"]:
                cur = {"start": epoch, "end": epoch + length_s, "used": 0}
            cur["used"] += credits
        return cur if cur and cur["end"] > now else None

    # ---- grand livre : chargement, normalisation, amorcage ---------------------------------------------------------------------------------
    @staticmethod
    def _fresh(client_id):
        return {"schema": SCHEMA, "clientId": client_id, "updatedUtc": None, "rev": 0, "session": _empty_window(), "week": _empty_window(),
                "month": dict(_empty_window(), seeded=False), "reservations": {}, "recent": [], "lastReconcileUtc": None, "drift": 0}

    def _month_ident(self, pv):
        start = parse_iso(pv.get("cycleStartUtc"))
        end = parse_iso(pv.get("renewsAtUtc"))
        return ("M-%d" % int(start) if start is not None else "M-0"), start, end

    def _windows_exempt(self, pv):
        return str(pv.get("planId") or "") in self.limits()["exemptPlans"]

    def _alloc(self, client_id, pv):
        lim = self.limits()
        override = pv.get("override")
        if not override:
            override = lim["overridesByClient"].get(client_id)
        return allowances_for(pv.get("monthlyCredits"), lim, override)

    def _apply_settle(self, L, rid, r, actual, now):
        """Debite les fenetres ENCORE COURANTES (meme identifiant) puis supprime la reservation ; referme une fenetre session/semaine restee
        vide (une erreur au premier appel n'ouvre pas de session). Les compteurs `reserved` sont recalcules par l'appelant."""
        windows = r.get("windows") or {}
        for w in WINDOW_NAMES:
            wid = windows.get(w)
            if wid and L[w].get("id") == wid:
                L[w]["used"] = int(L[w].get("used") or 0) + actual
                if r.get("kind") == "project_step":
                    L[w]["proj"] = int(L[w].get("proj") or 0) + actual
        L["reservations"].pop(rid, None)
        for w in ("session", "week"):
            wid = windows.get(w)
            if wid and L[w].get("id") == wid and not L[w].get("used") and not any(x.get("windows", {}).get(w) == wid for x in L["reservations"].values()):
                L[w] = _empty_window()
        L["recent"] = (L.get("recent") or [])[-(RECENT_KEEP - 1):] + [{"ts": iso(now), "kind": r.get("kind"), "ref": r.get("ref"), "credits": actual}]

    def _recompute_reserved(self, L):
        for w in WINDOW_NAMES:
            wid = L[w].get("id")
            L[w]["reserved"] = sum(int(r.get("credits") or 0) for r in L["reservations"].values() if wid and (r.get("windows") or {}).get(w) == wid)

    def _normalize(self, client_id, L, pv, now, readonly=False):
        """Met le grand livre a jour avec le temps et le forfait : cycle de facturation, fenetres echues refermees, reservations echues
        reglees. Renvoie True si quelque chose a change."""
        changed = False
        mid, mstart, mend = self._month_ident(pv)
        m = L["month"]
        if m.get("id") != mid:
            task, proj = self._trace_parts(client_id)
            used_proj = sum(c for t, c in proj if mstart is not None and t >= mstart)
            used = used_proj + sum(c for t, c in task if mstart is not None and t >= mstart)
            L["month"] = {"id": mid, "startUtc": iso(mstart), "endUtc": iso(mend), "used": used, "reserved": 0, "proj": used_proj, "seeded": True}
            changed = True
        elif m.get("endUtc") != iso(mend):
            m["endUtc"] = iso(mend)
            changed = True
        for w in ("session", "week"):
            end = parse_iso(L[w].get("endUtc"))
            if L[w].get("id") and (end is None or end <= now):
                L[w] = _empty_window()
                changed = True
        for rid, r in list((L.get("reservations") or {}).items()):
            exp = parse_iso(r.get("expiresUtc"))
            if exp is not None and exp <= now:
                actual = 0
                if self._resolve_expired and not readonly:
                    try:
                        actual = _credits_int(self._resolve_expired(client_id, dict(r, id=rid))) or 0
                    except Exception:  # noqa: BLE001
                        actual = 0
                self._apply_settle(L, rid, r, actual, now)
                if not readonly:
                    self._emit("usage_reservation_expired", clientId=client_id, usageKind=r.get("kind"), ref=r.get("ref"), credits=actual)
                changed = True
        self._recompute_reserved(L)
        return changed

    def _seed_windows(self, client_id, L, now):
        """Amorcage d'un grand livre neuf : session et semaine reconstruites depuis les traces (un client qui vient d'epuiser sa session ne repart
        pas avec une fenetre vierge parce que le fichier n'existait pas encore)."""
        lim = self.limits()
        task, proj = self._trace_parts(client_id)
        for name, length in (("session", lim["sessionHours"] * 3600.0), ("week", lim["weekDays"] * 86400.0)):
            cur = self._replay(task + proj, now, length)
            if cur:
                L[name] = self._window_from_replay(name, cur, proj)
        L["lastReconcileUtc"] = iso(now)

    @staticmethod
    def _window_from_replay(name, cur, proj):
        return {"id": ("S-" if name == "session" else "W-") + str(int(cur["start"])), "startUtc": iso(cur["start"]), "endUtc": iso(cur["end"]),
                "used": cur["used"], "reserved": 0, "proj": sum(c for t, c in proj if cur["start"] <= t < cur["end"])}

    def _open(self, client_id, pv, now, readonly=False):
        """Charge (ou cree et amorce) le grand livre et le met a jour. En ecriture (readonly=False) : persiste si quelque chose a change.
        A appeler SOUS le verrou du client pour une ecriture ; une lecture seule travaille sur une copie et n'ecrit rien."""
        raw = self._read(client_id)
        fresh = raw is None
        L = self._fresh(client_id) if fresh else raw
        for key, default in (("session", _empty_window()), ("week", _empty_window()), ("month", dict(_empty_window(), seeded=False))):
            if not isinstance(L.get(key), dict):
                L[key] = default
        if not isinstance(L.get("reservations"), dict):
            L["reservations"] = {}
        changed = self._normalize(client_id, L, pv, now, readonly=readonly)
        if fresh:
            self._seed_windows(client_id, L, now)
            self._recompute_reserved(L)
            changed = True
        elif not readonly:
            interval = self.limits()["reconcileIntervalSec"]
            last = parse_iso(L.get("lastReconcileUtc"))
            if last is None or now - last >= interval:
                self._reconcile_in_place(client_id, L, pv, now, force=True)
                changed = True
        if changed and not readonly:
            self._write(client_id, L, now)
        return L

    # ---- vue -------------------------------------------------------------------------------------------------------------------------------
    def _rem(self, L, alloc, windows_apply):
        names = WINDOW_NAMES if windows_apply else ("month",)
        return {w: int(alloc[w]) - int(L[w].get("used") or 0) - int(L[w].get("reserved") or 0) for w in names}

    def _view(self, L, pv, alloc, now):
        windows_apply = not self._windows_exempt(pv)
        rem = self._rem(L, alloc, windows_apply)

        def win(name):
            if name not in rem:
                return None
            raw = L[name]
            opened = bool(raw.get("id"))
            return Window(limit=int(alloc[name]), used=int(raw.get("used") or 0), reserved=int(raw.get("reserved") or 0),
                          remaining=max(0, rem[name]), opened=opened if name != "month" else True,
                          startUtc=raw.get("startUtc") if opened else None, resetsAtUtc=raw.get("endUtc") if opened else None)
        view = UsageView(session=win("session"), week=win("week"), month=win("month"), exempt=False, windowsApply=windows_apply,
                         planId=pv.get("planId"), mode=self.mode())
        # fenetre la plus proche de sa limite ; a egalite, la plus courte (la session se renouvelle avant la semaine, avant le mois)
        order = [w for w in WINDOW_NAMES if w in rem]
        binding = min(order, key=lambda w: (rem[w], order.index(w)))
        view.binding = binding
        view.allowedNow = max(0, rem[binding])
        return view

    def _exempt_view(self, planId=None):
        return UsageView(session=None, week=None, month=None, binding=None, allowedNow=UNBOUNDED, exempt=True, windowsApply=False,
                         planId=planId, mode=self.mode())

    def _pv(self, client_id):
        pv = self._plan_view(client_id)
        return pv if isinstance(pv, dict) else None

    # ---- interface publique ----------------------------------------------------------------------------------------------------------------
    def remaining(self, client_id, now=None):
        """Etat des trois fenetres, SANS rien consommer (lecture : aucune ecriture, sauf la creation du grand livre la toute premiere fois)."""
        if not self.enabled or self.exempt_client(client_id):
            return self._exempt_view()
        pv = self._pv(client_id)
        if pv is None or pv.get("exempt"):
            return self._exempt_view(pv.get("planId") if pv else None)
        now = self._now() if now is None else now
        alloc = self._alloc(client_id, pv)
        if self._read(client_id) is None:
            with self._guard(client_id):
                L = self._open(client_id, pv, now)
        else:
            L = self._open(client_id, pv, now, readonly=True)
        return self._view(L, pv, alloc, now)

    def reserve(self, client_id, credits, kind="mission", ref="", ttl_s=None, allow_partial=False, min_partial=None):
        """Reserve `credits` dans les trois fenetres (controle et mise a jour dans la meme section critique). Renvoie une Reservation ou, quand
        une fenetre refuse, un UsageBlock (limit, resetsAtUtc, remaining, needed). allow_partial : accepte moins (le plus petit reste) a
        condition qu'il atteigne min_partial (defaut : minStartCredits). En mode « shadow » rien n'est refuse : le refus est journalise."""
        return self._admit(client_id, credits, kind, ref, ttl_s, allow_partial, min_partial, consume=False)

    def charge(self, client_id, credits, kind="automation", ref=""):
        """Reservation + reglement immediats (automatisations : 1 credit). None si la consommation est passee, sinon l'UsageBlock."""
        out = self._admit(client_id, credits, kind, ref, None, False, None, consume=True)
        return out if isinstance(out, UsageBlock) else None

    def _admit(self, client_id, credits, kind, ref, ttl_s, allow_partial, min_partial, consume):
        credits = int(credits)
        noop = Reservation(None, max(0, credits), kind, ref, {}, exempt=True)
        if credits <= 0 or not self.enabled or self.exempt_client(client_id):
            return noop
        pv = self._pv(client_id)                      # AVANT le verrou : plan_view lit la facturation (verrou du serveur), jamais dans l'ordre inverse
        if pv is None or pv.get("exempt"):
            return noop
        now = self._now()
        lim = self.limits()
        alloc = self._alloc(client_id, pv)
        mode = self.mode()
        with self._guard(client_id):
            L = self._open(client_id, pv, now)
            windows_apply = not self._windows_exempt(pv)
            rem = self._rem(L, alloc, windows_apply)
            smallest = min(rem.values())
            granted = credits
            if smallest < credits:
                floor = int(min_partial) if min_partial else lim["minStartCredits"]
                if allow_partial and not consume and smallest >= max(1, floor) and mode == "on":
                    granted = smallest
                else:
                    block = self._block_for(L, pv, alloc, rem, credits, now)
                    blocked = block.limit
                    if mode == "on":
                        return block
                    self._emit("usage_would_block", clientId=client_id, planId=pv.get("planId"), limit=blocked, needed=credits,
                               remaining=max(0, rem[blocked]), resetsAtUtc=block.resetsAtUtc, usageKind=kind, ref=ref, mode="shadow")
            if windows_apply:
                for name, seconds in (("session", lim["sessionHours"] * 3600.0), ("week", lim["weekDays"] * 86400.0)):
                    if not L[name].get("id"):
                        L[name] = {"id": ("S-" if name == "session" else "W-") + str(int(now)), "startUtc": iso(now),
                                   "endUtc": iso(now + seconds), "used": 0, "reserved": 0}
            applicable = WINDOW_NAMES if windows_apply else ("month",)
            windows = {w: L[w]["id"] for w in applicable}
            if consume:
                for w in applicable:
                    L[w]["used"] = int(L[w].get("used") or 0) + granted
                    if kind == "project_step":
                        L[w]["proj"] = int(L[w].get("proj") or 0) + granted
                L["recent"] = (L.get("recent") or [])[-(RECENT_KEEP - 1):] + [{"ts": iso(now), "kind": kind, "ref": ref, "credits": granted}]
                rsv = Reservation(None, granted, kind, ref, windows, exempt=True)
            else:
                ttl = int(ttl_s) if ttl_s else int(lim["reservationTtlSec"].get(kind, 720))
                rid = "RSV-" + secrets.token_hex(4)
                L["reservations"][rid] = {"credits": granted, "kind": kind, "ref": ref, "createdUtc": iso(now), "expiresUtc": iso(now + ttl),
                                          "windows": windows}
                rsv = Reservation(rid, granted, kind, ref, windows)
            self._recompute_reserved(L)
            self._write(client_id, L, now)
            return rsv

    def _block_for(self, L, pv, alloc, rem, credits, now):
        blocked = self._blocking_window(L, rem, credits)
        return UsageBlock(limit=blocked, resetsAtUtc=self._reset_of(L, blocked), remaining=max(0, rem[blocked]), needed=credits,
                          view=self._view(L, pv, alloc, now))

    def check(self, client_id, credits):
        """Sans RIEN consommer : None si `credits` passeraient maintenant dans les trois fenetres, sinon l'UsageBlock qui dirait pourquoi (fenetre
        nommee, heure de renouvellement). C'est le controle de subscription_blocks_mission ; la reservation reste faite par submit_task."""
        credits = int(credits)
        if credits <= 0 or not self.enabled or self.exempt_client(client_id):
            return None
        pv = self._pv(client_id)
        if pv is None or pv.get("exempt"):
            return None
        now = self._now()
        alloc = self._alloc(client_id, pv)
        if self._read(client_id) is None:
            with self._guard(client_id):
                L = self._open(client_id, pv, now)
        else:
            L = self._open(client_id, pv, now, readonly=True)
        rem = self._rem(L, alloc, not self._windows_exempt(pv))
        if min(rem.values()) >= credits:
            return None
        return self._block_for(L, pv, alloc, rem, credits, now)

    def _reset_of(self, L, window):
        raw = L[window]
        return raw.get("endUtc") if raw.get("id") or window == "month" else None

    def _blocking_window(self, L, rem, needed):
        """La fenetre a nommer quand plusieurs refusent : celle dont le renouvellement est le plus LOIN (c'est la que la mission peut vraiment
        passer) ; un renouvellement inconnu (l'essai ne se renouvelle pas) compte comme infini ; a egalite, la plus grande fenetre."""
        candidates = [w for w, r in rem.items() if r < needed]

        def key(w):
            end = parse_iso(self._reset_of(L, w))
            return (float("inf") if end is None else end, WINDOW_NAMES.index(w))
        return max(candidates, key=key)

    def settle(self, client_id, reservation, actual_credits):
        """Regle une reservation : debite `actual_credits` dans les fenetres encore courantes (meme identifiant) et libere le reste. Idempotent
        (reservation inconnue = rien)."""
        rid = reservation.id if isinstance(reservation, Reservation) else reservation
        if not rid or not self.enabled or self.exempt_client(client_id):
            return
        actual = _credits_int(actual_credits) or 0
        now = self._now()
        with self._guard(client_id):
            L = self._read(client_id)
            if L is None or rid not in (L.get("reservations") or {}):
                return
            r = L["reservations"][rid]
            self._apply_settle(L, rid, r, actual, now)
            self._recompute_reserved(L)
            self._write(client_id, L, now)
        if self._nudge:
            try:
                self._nudge(client_id)
            except Exception:  # noqa: BLE001
                pass

    def release(self, client_id, reservation):
        self.settle(client_id, reservation, 0)

    def next_renewal(self, client_id):
        """Heure ISO UTC du renouvellement de la fenetre qui borne ; None si rien ne borne (compte exempte, fenetre non demarree)."""
        return self.remaining(client_id).next_renewal_utc()

    def month_used(self, client_id, pv=None):
        """Credits du cycle en cours d'apres le grand livre (remplace le balayage des TASK-*.json de get_billing) ; None quand le service est
        inerte ou le compte exempte : l'appelant utilise alors le balayage d'origine."""
        if not self.enabled or self.exempt_client(client_id):
            return None
        pv = pv or self._pv(client_id)
        if pv is None:
            return None
        now = self._now()
        with self._guard(client_id):                      # la reconciliation periodique peut ecrire
            L = self._open(client_id, pv, now)
        return int(L["month"].get("used") or 0)

    def active_reservations(self, client_id):
        L = self._read(client_id) if self.enabled and not self.exempt_client(client_id) else None
        if not L:
            return []
        return [{"kind": r.get("kind"), "credits": r.get("credits"), "ref": r.get("ref")} for r in (L.get("reservations") or {}).values()]

    def on_billing_saved(self, client_id):
        """Appele a chaque ecriture de la facturation : les allocations se recalculent toutes seules a chaque controle, il ne reste qu'a
        reveiller ceux qui attendent un quota (superviseur de projets)."""
        if self._nudge:
            try:
                self._nudge(client_id)
            except Exception:  # noqa: BLE001
                pass

    # ---- reconciliation --------------------------------------------------------------------------------------------------------------------
    def _reconcile_in_place(self, client_id, L, pv, now, force=False):
        """Les missions sont recomptees depuis leurs traces ; les etapes de projet aussi, SANS jamais descendre sous ce que le grand livre a
        lui-meme regle pour des etapes de projet (un cost-ledger.jsonl absent ou illisible ne doit pas effacer de la consommation reelle)."""
        task, proj = self._trace_parts(client_id, force=force)
        lim = self.limits()
        mid, mstart, _ = self._month_ident(pv)
        drift = {}

        def expect(raw, lo, hi):
            def in_range(t):
                return t >= lo and (hi is None or t < hi)
            t_sum = sum(c for t, c in task if in_range(t))
            p_sum = max(sum(c for t, c in proj if in_range(t)), int(raw.get("proj") or 0))
            return t_sum + p_sum, p_sum
        if mstart is not None:
            expected, p_sum = expect(L["month"], mstart, None)
            drift["month"] = int(L["month"].get("used") or 0) - expected
            L["month"]["used"], L["month"]["proj"] = expected, p_sum
        if not self._windows_exempt(pv):
            for name, length in (("session", lim["sessionHours"] * 3600.0), ("week", lim["weekDays"] * 86400.0)):
                raw = L[name]
                if raw.get("id"):
                    start, end = parse_iso(raw.get("startUtc")), parse_iso(raw.get("endUtc"))
                    if start is None or end is None:
                        continue
                    expected, p_sum = expect(raw, start, end)
                    drift[name] = int(raw.get("used") or 0) - expected
                    raw["used"], raw["proj"] = expected, p_sum
                else:
                    cur = self._replay(task + proj, now, length)
                    if cur:                                # une consommation recente dont le reglement s'est perdu : la fenetre se rouvre
                        L[name] = self._window_from_replay(name, cur, proj)
                        drift[name] = -cur["used"]
        L["lastReconcileUtc"] = iso(now)
        L["drift"] = sum(abs(v) for v in drift.values())
        self._recompute_reserved(L)
        if L["drift"]:
            self._emit("usage_drift_corrected", clientId=client_id, drift=drift)
        return drift

    def reconcile(self, client_id, now=None):
        """Recalcule le grand livre depuis les traces, consigne l'ecart et corrige le CACHE (jamais les traces). Au plus toutes les 6 h par
        client actif en usage normal ; a la demande de l'administration ou d'un test ici."""
        if not self.enabled or self.exempt_client(client_id):
            return {"ok": True, "skipped": True, "drift": {}}
        pv = self._pv(client_id)
        if pv is None or pv.get("exempt"):
            return {"ok": True, "skipped": True, "drift": {}}
        now = self._now() if now is None else now
        with self._guard(client_id):
            L = self._open(client_id, pv, now)
            before = {w: int(L[w].get("used") or 0) for w in WINDOW_NAMES}
            drift = self._reconcile_in_place(client_id, L, pv, now, force=True)
            self._write(client_id, L, now)
            after = {w: int(L[w].get("used") or 0) for w in WINDOW_NAMES}
        return {"ok": True, "drift": drift, "before": before, "after": after, "corrected": any(drift.values())}

    # ---- demarrage, suppression de compte --------------------------------------------------------------------------------------------------
    def reap(self, boot=False):
        """Au demarrage : toute reservation de mission ou d'automatisation est orpheline (le processus qui la tenait est mort) -> liberee a 0 ;
        les credits eventuellement consommes sont rattrapes par reconcile() depuis les traces. Les etapes de projet suivent leur delai
        (resolve_expired relit cost.json). Renvoie le nombre de reservations liberees."""
        freed = 0
        try:
            names = [n[:-5] for n in os.listdir(self.dir) if n.endswith(".json")]
        except OSError:
            return 0
        for client_id in names:
            if not CLIENT_ID_OK.match(client_id) or not self.enabled:
                continue
            try:
                with self._guard(client_id):
                    L = self._read(client_id)
                    if not L:
                        continue
                    now = self._now()
                    for rid, r in list((L.get("reservations") or {}).items()):
                        expired = (parse_iso(r.get("expiresUtc")) or 0) <= now
                        if (boot and r.get("kind") in ("mission", "automation")) or expired:
                            actual = 0
                            if r.get("kind") == "project_step" and self._resolve_expired:
                                try:
                                    actual = _credits_int(self._resolve_expired(client_id, dict(r, id=rid))) or 0
                                except Exception:  # noqa: BLE001
                                    actual = 0
                            self._apply_settle(L, rid, r, actual, now)
                            freed += 1
                    self._recompute_reserved(L)
                    self._write(client_id, L, now)
            except Exception as exc:  # noqa: BLE001 - un grand livre abime ne bloque pas le demarrage
                self._emit("usage_reap_failed", clientId=client_id, error=type(exc).__name__)
        return freed

    def purge(self, client_id):
        """Suppression de compte : le grand livre du client disparait avec ses autres donnees."""
        if not isinstance(client_id, str) or not CLIENT_ID_OK.match(client_id):
            return
        with self._lock:
            self._gates.pop(client_id, None)
        for suffix in (".json", ".lock"):
            try:
                os.remove(os.path.join(self.dir, client_id + suffix))
            except OSError:
                pass

    def snapshot(self, client_id):
        """Grand livre brut (administration, tests)."""
        return self._read(client_id)


def _default_task_credits(data):
    """Memes regles que server.task_credits (usage_wiring injecte la vraie fonction ; celle-ci sert aux tests autonomes du module)."""
    if str(data.get("Status") or "").upper() in {"BLOCKED", "SECURITY_BLOCKED", "NEEDS_CHLOE_VERIFICATION", "WORKER_NOT_INCLUDED"}:
        return 0
    result = data.get("Result")
    if isinstance(result, dict) and result.get("Degraded") is True:
        return 0
    raw = data.get("Credits")
    if raw is None or isinstance(raw, bool):
        return 1
    try:
        return max(0, int(raw))
    except (TypeError, ValueError):
        return 1
