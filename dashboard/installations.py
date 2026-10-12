"""Installation d'un Worker chez un client (2026-10-12) : vendre un Worker a l'unite et l'installer selon ses competences.

Un Worker vendu seul s'"installe" chez un client en 4 temps, decrits par workers/<id>/install-profile.json (services du Worker, outils a
connecter, canaux, fiche de connaissances, regles d'autonomie, scenario d'essai) :
  1. le client choisit les SERVICES (competences) qu'il veut ;
  2. il renseigne la FICHE DE CONNAISSANCES de chaque service (ton, tarifs, horaires, regles de l'entreprise...) ;
  3. il fixe les REGLES D'AUTONOMIE par categorie d'action : off / ask (demander d'abord) / draft (preparer, attendre sa validation) / auto
     (autorise seulement pour lecture, analyse, brouillon, note interne - jamais pour envoyer, publier, payer, supprimer ou appeler) ;
  4. il lance l'essai a blanc puis ACTIVE : le Worker travaille avec cette configuration (injectee dans son prompt comme DONNEE).
La fiche est stockee dans runtime/installations/<ClientId>/<WORKER>.json (volume persistant, supprimee avec le compte).

Ce module est autonome (bibliotheque standard) : validation stricte, ecritures atomiques, aucun secret accepte, aucun chemin libre.

Il porte aussi les DROITS D'ACCES par Worker (fin du fichier) : un forfait Solo (1 Worker) ou Trio (3 Workers + Chloe) n'ouvre que les Workers
EMBAUCHES par le client ; tous les autres forfaits gardent l'acces a tous les Workers. Embauche, echange (un par periode de 30 jours),
attribution par le proprietaire apres facture reglee : fonctions pures sur l'etat de facturation, branchees dans dashboard/server.py
(refus HTTP 403 WORKER_NOT_INCLUDED sur toutes les routes qui demarrent une mission) et dans les scripts PowerShell (BK_ALLOWED_WORKERS).
Documentation des routes : docs/HIRE-API.md.
"""
import datetime
import json
import os
import re
import tempfile
import threading

WORKER_ID_RE = re.compile(r"^[a-z]{2,20}\Z")      # \Z et non $ : un identifiant suivi d'un saut de ligne ne doit pas passer
CLIENT_ID_RE = re.compile(r"^CLI-[A-Z0-9-]{3,40}\Z")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,59}\Z")
MODES = ("off", "ask", "draft", "auto")
STATUSES = ("draft", "active", "paused")
CHANNELS = ("email", "phone", "whatsapp", "web", "schedule")
CHANNEL_LABELS = {"email": "e-mail", "phone": "téléphone", "whatsapp": "WhatsApp", "web": "application", "schedule": "mission récurrente"}
DEFAULT_LIVE_CHANNELS = ("web", "schedule")     # sans mention contraire dans le profil, seuls ces canaux existent vraiment
MAX_VALUE_CHARS = 2000
MAX_NOTES_CHARS = 2000
SECRET_RE = re.compile(
    r"sk-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[abp]-[0-9A-Za-z-]{10,}|ghp_[A-Za-z0-9]{20,}"
    r"|(?i:(?:password|mot de passe|mdp|api[ _-]?key|cl[eé] api|secret|token|iban))\s*[:=]\s*\S{6,}|\b(?:\d[ -]?){13,19}\b"
    r"|\b[A-Z]{2}\d{2} ?(?:[A-Z0-9]{4} ?){3,7}[A-Z0-9]{1,4}\b")
_LOCK = threading.Lock()


def _now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def _atomic_write(path, data):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def load_profile(root, worker_id):
    """workers/<id>/install-profile.json, ou None (Worker sans profil : installation generique, autonomie plafonnee)."""
    if not WORKER_ID_RE.match(worker_id or ""):
        return None
    try:
        with open(os.path.join(root, "workers", worker_id, "install-profile.json"), encoding="utf-8-sig") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def _services_by_id(profile):
    return {s.get("id"): s for s in (profile or {}).get("services", []) if isinstance(s, dict) and s.get("id")}


def profile_connector_ids(profile):
    """Tous les connecteurs cites par un profil (obligatoires, au choix, facultatifs) : le serveur dit lesquels le client a connectes."""
    ids = set()
    for d in _services_by_id(profile).values():
        for key in ("requiredConnectors", "optionalConnectors"):
            ids.update(c for c in d.get(key) or [] if isinstance(c, str))
        for group in d.get("requiredAnyOf") or []:
            if isinstance(group, list):
                ids.update(c for c in group if isinstance(c, str))
    return ids


def _connector_name(connector_id):
    return str(connector_id).split(".")[0].replace("_", " ").title()


def live_channels(profile):
    """Canaux qui existent VRAIMENT pour ce Worker (channelSupport == "available" dans son profil). Un canal annonce comme prevu n'est
    jamais enregistre comme actif : on ne presente pas comme disponible ce qui n'est pas construit."""
    support = (profile or {}).get("channelSupport")
    if not isinstance(support, dict):
        return DEFAULT_LIVE_CHANNELS
    return tuple(c for c in CHANNELS if support.get(c) == "available")


class InstallationError(Exception):
    def __init__(self, errors):
        super().__init__("; ".join(errors))
        self.errors = errors


class InstallationStore:
    def __init__(self, root):
        self.root = root
        self.base = os.path.join(root, "runtime", "installations")

    # ------------------------------------------------------------------ chemins
    def _dir(self, client_id):
        if not CLIENT_ID_RE.match(client_id or ""):
            raise InstallationError(["client invalide"])
        return os.path.join(self.base, client_id)

    def _path(self, client_id, worker_id):
        if not WORKER_ID_RE.match(worker_id or ""):
            raise InstallationError(["Worker invalide"])
        return os.path.join(self._dir(client_id), worker_id.upper() + ".json")

    # ------------------------------------------------------------------ lecture
    def get(self, client_id, worker_id):
        try:
            with open(self._path(client_id, worker_id), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError, InstallationError):
            return None

    def list(self, client_id):
        out = []
        try:
            d = self._dir(client_id)
            for name in sorted(os.listdir(d)):
                if name.endswith(".json"):
                    rec = self.get(client_id, name[:-5].lower())
                    if rec:
                        out.append(rec)
        except (OSError, InstallationError):
            pass
        return out

    # ------------------------------------------------------------------ ecriture
    def upsert(self, client_id, worker_id, payload):
        """Enregistre la configuration (jamais l'activation). Renvoie la fiche ; leve InstallationError si invalide."""
        return self.upsert_with_warnings(client_id, worker_id, payload)[0]

    def upsert_with_warnings(self, client_id, worker_id, payload):
        """Comme upsert, mais renvoie aussi les avertissements (canal pas encore disponible : non enregistre) : (fiche, [messages])."""
        profile = load_profile(self.root, worker_id)
        services_defs = _services_by_id(profile)
        errors = []
        warnings = []
        live = live_channels(profile)
        if not isinstance(payload, dict):
            raise InstallationError(["corps invalide"])
        incoming = payload.get("services") if isinstance(payload.get("services"), dict) else {}
        services = {}
        for sid, cfg in incoming.items():
            if not SLUG_RE.match(str(sid)):
                errors.append(f"service invalide : {str(sid)[:40]}")
                continue
            if profile is not None and sid not in services_defs:
                errors.append(f"service inconnu pour ce Worker : {sid}")
                continue
            if not isinstance(cfg, dict):
                errors.append(f"{sid} : configuration invalide")
                continue
            d = services_defs.get(sid, {})
            knowledge_defs = {k.get("key"): k for k in d.get("knowledgeFields", []) if isinstance(k, dict)}
            autonomy_defs = {a.get("category"): a for a in d.get("autonomyRules", []) if isinstance(a, dict)}
            knowledge = {}
            for key, value in (cfg.get("knowledge") or {}).items():
                if not SLUG_RE.match(str(key).replace("_", "-").lower()):
                    errors.append(f"{sid} : champ invalide {str(key)[:40]}")
                    continue
                if profile is not None and key not in knowledge_defs:
                    errors.append(f"{sid} : champ non prevu {key}")
                    continue
                text = "" if value is None else str(value).strip()
                if len(text) > MAX_VALUE_CHARS:
                    errors.append(f"{sid}.{key} : {MAX_VALUE_CHARS} caracteres maximum")
                elif SECRET_RE.search(text):
                    errors.append(f"{sid}.{key} : ne saisissez jamais de mot de passe, cle ou numero de carte")
                else:
                    knowledge[key] = text
            autonomy = {}
            for cat, mode in (cfg.get("autonomy") or {}).items():
                if not SLUG_RE.match(str(cat)):
                    errors.append(f"{sid} : categorie invalide {str(cat)[:40]}")
                    continue
                if mode not in MODES:
                    errors.append(f"{sid}.{cat} : mode invalide (off, ask, draft, auto)")
                    continue
                adef = autonomy_defs.get(cat)
                if profile is not None and adef is None:
                    errors.append(f"{sid} : categorie non prevue {cat}")
                    continue
                # Loi de la plateforme : "auto" seulement pour un risque faible ; tout ce qui envoie/publie/paie/supprime/appelle reste valide par le client.
                if mode == "auto" and (adef is None or adef.get("risk") != "low"):
                    errors.append(f"{sid}.{cat} : l'autonomie complete n'est pas autorisee pour cette action (validation du client obligatoire)")
                    continue
                autonomy[cat] = mode
            wanted = []
            for c in cfg.get("channels") if isinstance(cfg.get("channels"), list) else []:
                if c in CHANNELS and c not in wanted:
                    wanted.append(c)
            if profile is not None and d.get("channels"):
                wanted = [c for c in wanted if c in d["channels"]]
            channels = [c for c in wanted if c in live]
            for c in wanted:
                if c not in live:
                    warnings.append(f"{d.get('label', sid)} : le canal « {CHANNEL_LABELS.get(c, c)} » n'est pas encore disponible, il n'a pas été enregistré.")
            services[sid] = {"enabled": bool(cfg.get("enabled")), "level": cfg.get("level") if cfg.get("level") in ("rapide", "equilibre", "approfondi") else None,
                             "knowledge": knowledge, "autonomy": autonomy, "channels": channels, "label": d.get("label", str(sid))}
        notes = str(payload.get("notes") or "").strip()
        if len(notes) > MAX_NOTES_CHARS:
            errors.append(f"notes : {MAX_NOTES_CHARS} caracteres maximum")
        elif SECRET_RE.search(notes):
            errors.append("notes : ne saisissez jamais de mot de passe, cle ou numero de carte")
        if errors:
            raise InstallationError(errors)
        with _LOCK:
            rec = self.get(client_id, worker_id) or {"workerId": worker_id.lower(), "clientId": client_id, "status": "draft", "createdAtUtc": _now()}
            rec["services"] = services
            rec["notes"] = notes
            rec["updatedAtUtc"] = _now()
            if rec.get("status") == "active":      # une modification d'une installation active ne la desactive pas, mais doit rester complete
                missing = self.readiness(rec, profile)
                if missing:
                    rec["status"] = "draft"
            _atomic_write(self._path(client_id, worker_id), rec)
        return rec, warnings

    def readiness(self, rec, profile=None, connected=None):
        """Ce qu'il manque pour activer : au moins un service actif, tous ses champs obligatoires remplis et, quand `connected` est fourni
        (ensemble d'identifiants de connecteurs reellement connectes par le client), ses outils obligatoires connectes."""
        profile = profile if profile is not None else load_profile(self.root, rec.get("workerId", ""))
        defs = _services_by_id(profile)
        enabled = [(sid, s) for sid, s in (rec.get("services") or {}).items() if s.get("enabled")]
        missing = []
        if not enabled:
            missing.append("Choisissez au moins un service.")
        for sid, s in enabled:
            label = s.get("label", sid)
            d = defs.get(sid, {})
            for k in d.get("knowledgeFields", []):
                if isinstance(k, dict) and k.get("required") and not str((s.get("knowledge") or {}).get(k.get("key"), "")).strip():
                    missing.append(f"{label} : « {k.get('label', k.get('key'))} » est obligatoire.")
            if connected is not None:
                for cid in d.get("requiredConnectors") or []:
                    if cid not in connected:
                        missing.append(f"{label} : connectez {_connector_name(cid)}.")
                for group in d.get("requiredAnyOf") or []:
                    if isinstance(group, list) and group and not any(c in connected for c in group):
                        missing.append(f"{label} : connectez au moins un de ces outils : {', '.join(_connector_name(c) for c in group)}.")
        return missing

    def set_status(self, client_id, worker_id, status, connected=None):
        if status not in STATUSES:
            raise InstallationError(["statut invalide"])
        with _LOCK:
            rec = self.get(client_id, worker_id)
            if rec is None:
                raise InstallationError(["aucune installation pour ce Worker"])
            if status == "active":
                missing = self.readiness(rec, connected=connected)
                if missing:
                    raise InstallationError(missing)
                rec["installedAtUtc"] = rec.get("installedAtUtc") or _now()
            rec["status"] = status
            rec["updatedAtUtc"] = _now()
            _atomic_write(self._path(client_id, worker_id), rec)
        return rec

    def delete(self, client_id, worker_id):
        """Supprime la fiche d'un Worker pour ce client. True si une fiche existait."""
        with _LOCK:
            try:
                path = self._path(client_id, worker_id)
            except InstallationError:
                return False
            if not os.path.isfile(path):
                return False
            try:
                os.remove(path)
            except OSError:
                return False
            return True

    def delete_client(self, client_id):
        try:
            import shutil
            shutil.rmtree(self._dir(client_id), ignore_errors=True)
        except InstallationError:
            pass


# ------------------------------------------------------------------ droits d'acces par Worker (offre "Worker a l'unite")
# Les forfaits "solo" et "trio" ne donnent acces qu'aux Workers EMBAUCHES par le client (liste hiredWorkers de son etat de facturation) ;
# tous les autres forfaits (essai, starter, business, pro, scale, enterprise) gardent l'acces a tous les Workers. Un forfait restreint
# dont la liste est absente ou vide n'ouvre AUCUN Worker (on refuse, on n'ouvre jamais par defaut).
PLAN_WORKER_SLOTS = {"solo": 1, "trio": 3}          # forfait -> nombre d'emplacements de Workers
PLAN_LABELS = {"solo": "Solo", "trio": "Trio"}
PLANS_WITH_CHLOE = ("trio",)                         # Chloe (l'orchestratrice) est incluse en plus des emplacements
CHLOE_ID = "chloe"
SWAP_COOLDOWN_DAYS = 30                              # un echange de Worker par periode de 30 jours


def is_restricted(billing_state):
    return (billing_state or {}).get("planId") in PLAN_WORKER_SLOTS


def worker_slots(billing_state):
    """Nombre d'emplacements du forfait restreint, sinon None (acces a tous les Workers)."""
    return PLAN_WORKER_SLOTS.get((billing_state or {}).get("planId"))


def hired_workers(billing_state):
    """Workers embauches (identifiants en minuscules, sans doublon, ids valides), dans l'ordre d'embauche. Vide hors forfait restreint."""
    if not is_restricted(billing_state):
        return []
    out = []
    raw = (billing_state or {}).get("hiredWorkers")
    for h in raw if isinstance(raw, list) else []:
        wid = str(h or "").strip().lower()
        if WORKER_ID_RE.match(wid) and wid != CHLOE_ID and wid not in out:
            out.append(wid)
    return out[:worker_slots(billing_state)]


def allowed_workers(billing_state):
    """Liste des Workers autorises quand l'acces est restreint, sinon None (tous). Chloe n'y figure pas : elle n'est pas un Worker a embaucher."""
    return hired_workers(billing_state) if is_restricted(billing_state) else None


def worker_allowed(billing_state, worker_id):
    """Un client sur un forfait classique (ou l'essai) accede a tous les Workers. Un client en forfait solo/trio n'accede qu'aux Workers
    qu'il a embauches ; Chloe n'est ouverte qu'avec le forfait Trio. Un identifiant vide ou invalide est refuse pour un forfait restreint."""
    if not is_restricted(billing_state):
        return True
    wid = str(worker_id or "").lower()          # pas de strip : seul un identifiant exact (deja valide par la route) est reconnu
    if wid == CHLOE_ID:
        return billing_state.get("planId") in PLANS_WITH_CHLOE
    return wid in hired_workers(billing_state)


def refusal_detail(billing_state, worker_id, name_of=None):
    """Message francais, sans jargon, quand une mission est refusee faute d'embauche (HTTP 403, error WORKER_NOT_INCLUDED)."""
    name_of = name_of or (lambda w: str(w).capitalize())
    plan = PLAN_LABELS.get((billing_state or {}).get("planId"), "actuel")
    wid = str(worker_id or "").strip().lower()
    if wid == CHLOE_ID:
        return ("Chloé, l'orchestratrice, fait partie du forfait Trio. Avec le forfait " + plan
                + ", confiez vos missions directement à votre Worker.")
    hired = hired_workers(billing_state)
    if not hired:
        slots = worker_slots(billing_state) or 1
        return (f"Votre forfait {plan} inclut {slots} Worker{'s' if slots > 1 else ''} de votre choix, et vous n'en avez pas encore embauché. "
                "Embauchez-le pour lui confier des missions.")
    who = name_of(wid) if WORKER_ID_RE.match(wid) else "Ce Worker"
    return (f"{who} ne fait pas partie des Workers de votre forfait {plan} ({', '.join(name_of(h) for h in hired)}). "
            "Embauchez-le, ou remplacez l'un de vos Workers, pour lui confier des missions.")


# ------------------------------------------------------------------ embauche, echange, attribution par le proprietaire
class HireError(Exception):
    """Refus d'embauche : code stable pour l'interface, message francais, statut HTTP, informations utiles en plus."""
    def __init__(self, code, detail, status=409, extra=None):
        super().__init__(detail)
        self.code, self.detail, self.status, self.extra = code, detail, status, extra or {}


def _utc(now=None):
    return now if now is not None else datetime.datetime.now(datetime.timezone.utc)


def _iso(dt):
    return dt.astimezone(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_iso(text):
    try:
        dt = datetime.datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=datetime.timezone.utc)


def swap_status(billing_state, now=None):
    """Echange de Worker : possible une fois par periode de 30 jours (le premier est possible tout de suite)."""
    last = _parse_iso((billing_state or {}).get("lastWorkerSwapAtUtc"))
    nxt = last + datetime.timedelta(days=SWAP_COOLDOWN_DAYS) if last else None
    can = nxt is None or _utc(now) >= nxt
    return {"canSwapNow": can, "lastSwapAtUtc": _iso(last) if last else None, "nextSwapAtUtc": None if can else _iso(nxt)}


def hire(billing_state, worker_id, replace_id=None, known_ids=None, now=None, name_of=None):
    """Embauche `worker_id` dans l'etat de facturation (modifie `billing_state` en place). Tant qu'il reste un emplacement, l'embauche est
    libre ; quand tous les emplacements sont pris, il faut dire quel Worker remplacer (`replace_id`) et l'echange n'est possible qu'une
    fois tous les 30 jours. Leve HireError. Renvoie {"hired", "replaced", "alreadyHired"}."""
    name_of = name_of or (lambda w: str(w).capitalize())
    if not is_restricted(billing_state):
        raise HireError("NO_RESTRICTED_PLAN", "Votre forfait donne déjà accès à tous les Workers : il n'y a rien à embaucher.", 409)
    wid = str(worker_id or "").strip().lower()
    if wid == CHLOE_ID:
        raise HireError("CHLOE_NOT_HIRABLE", "Chloé n'est pas un Worker à embaucher : elle est incluse dans le forfait Trio.", 400)
    if not WORKER_ID_RE.match(wid) or (known_ids is not None and wid not in known_ids):
        raise HireError("UNKNOWN_WORKER", "Ce Worker n'existe pas.", 404)
    hired = hired_workers(billing_state)
    slots = worker_slots(billing_state)
    state_extra = {"hiredWorkers": hired, "workerSlots": slots}
    if wid in hired:
        return {"hired": wid, "replaced": None, "alreadyHired": True}
    now_dt = _utc(now)
    if len(hired) < slots:
        billing_state["hiredWorkers"] = hired + [wid]
        billing_state.setdefault("history", []).append({"dateUtc": _iso(now_dt), "event": f"Worker embauché : {name_of(wid)}."})
        return {"hired": wid, "replaced": None, "alreadyHired": False}
    if replace_id is None or str(replace_id).strip() == "":
        raise HireError("NO_SLOT_LEFT", f"Tous vos emplacements sont pris ({', '.join(name_of(h) for h in hired)}). "
                        "Indiquez le Worker à remplacer : un échange est possible tous les 30 jours.", 409, state_extra)
    out = str(replace_id).strip().lower()
    if out not in hired:
        raise HireError("REPLACE_NOT_HIRED", "Le Worker à remplacer ne fait pas partie de vos Workers embauchés.", 400, state_extra)
    sw = swap_status(billing_state, now_dt)
    if not sw["canSwapNow"]:
        raise HireError("SWAP_COOLDOWN", "Vous avez déjà échangé un Worker il y a moins de 30 jours. Prochain échange possible le "
                        + sw["nextSwapAtUtc"][:10] + ".", 409, dict(state_extra, **sw))
    billing_state["hiredWorkers"] = [wid if h == out else h for h in hired]
    billing_state["lastWorkerSwapAtUtc"] = _iso(now_dt)
    billing_state.setdefault("workerSwaps", []).append({"atUtc": _iso(now_dt), "out": out, "in": wid})
    billing_state["workerSwaps"] = billing_state["workerSwaps"][-20:]
    billing_state.setdefault("history", []).append({"dateUtc": _iso(now_dt), "event": f"Échange de Worker : {name_of(out)} remplacé par {name_of(wid)}."})
    return {"hired": wid, "replaced": out, "alreadyHired": False}


def grant(billing_state, workers, known_ids=None, now=None, name_of=None):
    """Attribution par le proprietaire (apres facture reglee) : remplace la liste des Workers embauches. Ce n'est pas un echange du client
    (le delai de 30 jours n'est pas touche). Leve HireError. Renvoie la liste enregistree."""
    name_of = name_of or (lambda w: str(w).capitalize())
    if not is_restricted(billing_state):
        raise HireError("NO_RESTRICTED_PLAN", "Ce forfait donne accès à tous les Workers : aucune liste à attribuer.", 409)
    if not isinstance(workers, list) or not workers:
        raise HireError("WORKERS_REQUIRED", "Indiquez au moins un Worker à attribuer.", 400)
    clean = []
    for w in workers:
        wid = str(w or "").strip().lower()
        if wid == CHLOE_ID:
            raise HireError("CHLOE_NOT_HIRABLE", "Chloé n'est pas un Worker à attribuer : elle est incluse dans le forfait Trio.", 400)
        if not WORKER_ID_RE.match(wid) or (known_ids is not None and wid not in known_ids):
            raise HireError("UNKNOWN_WORKER", f"Worker inconnu : {str(w)[:30]}.", 404)
        if wid not in clean:
            clean.append(wid)
    slots = worker_slots(billing_state)
    if len(clean) > slots:
        raise HireError("TOO_MANY_WORKERS", f"Le forfait {PLAN_LABELS.get(billing_state.get('planId'), '')} inclut {slots} Worker{'s' if slots > 1 else ''} au maximum.", 400)
    billing_state["hiredWorkers"] = clean
    billing_state.setdefault("history", []).append(
        {"dateUtc": _iso(_utc(now)), "event": "Workers attribués par BK Entreprise : " + ", ".join(name_of(w) for w in clean) + "."})
    return clean


def adapt_hired_to_plan(billing_state, now=None, plan_changed=True):
    """A appeler apres un changement de forfait : hors forfait restreint la liste est vidée ; avec moins d'emplacements elle est tronquée ;
    le délai d'échange repart de zéro quand le forfait change (pas quand le meme forfait est simplement renouvelé)."""
    if plan_changed:
        billing_state.pop("lastWorkerSwapAtUtc", None)
    if not is_restricted(billing_state):
        billing_state["hiredWorkers"] = []
        return
    kept = hired_workers(billing_state)
    if kept != [str(h).lower() for h in (billing_state.get("hiredWorkers") or [])]:
        billing_state.setdefault("history", []).append(
            {"dateUtc": _iso(_utc(now)), "event": "Liste des Workers embauchés ajustée au nombre d'emplacements du nouveau forfait."})
    billing_state["hiredWorkers"] = kept


def hire_summary(billing_state, now=None):
    """Ce que l'interface affiche pour le choix des Workers (embauches, emplacements, echange possible)."""
    restricted = is_restricted(billing_state)
    hired = hired_workers(billing_state)
    slots = worker_slots(billing_state)
    out = {"restricted": restricted, "planId": (billing_state or {}).get("planId"), "workerSlots": slots, "hiredWorkers": hired,
           "slotsLeft": None if slots is None else max(0, slots - len(hired)),
           "chloeIncluded": (not restricted) or (billing_state.get("planId") in PLANS_WITH_CHLOE),
           "swaps": list((billing_state or {}).get("workerSwaps") or [])[-5:]}
    out.update(swap_status(billing_state, now) if restricted else {"canSwapNow": False, "lastSwapAtUtc": None, "nextSwapAtUtc": None})
    return out
