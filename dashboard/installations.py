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
"""
import datetime
import json
import os
import re
import tempfile
import threading

WORKER_ID_RE = re.compile(r"^[a-z]{2,20}$")
CLIENT_ID_RE = re.compile(r"^CLI-[A-Z0-9-]{3,40}$")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,59}$")
MODES = ("off", "ask", "draft", "auto")
STATUSES = ("draft", "active", "paused")
CHANNELS = ("email", "phone", "whatsapp", "web", "schedule")
MAX_VALUE_CHARS = 2000
MAX_NOTES_CHARS = 2000
SECRET_RE = re.compile(
    r"sk-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[abp]-[0-9A-Za-z-]{10,}|ghp_[A-Za-z0-9]{20,}"
    r"|(?i:(?:password|mot de passe|mdp|api[ _-]?key|cl[eé] api|secret|token|iban))\s*[:=]\s*\S{6,}|\b(?:\d[ -]?){13,19}\b")
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
        profile = load_profile(self.root, worker_id)
        services_defs = _services_by_id(profile)
        errors = []
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
            channels = [c for c in (cfg.get("channels") or []) if c in CHANNELS]
            if profile is not None and d.get("channels"):
                channels = [c for c in channels if c in d["channels"]]
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
        return rec

    def readiness(self, rec, profile=None):
        """Ce qu'il manque pour activer : au moins un service actif, et tous ses champs obligatoires remplis."""
        profile = profile if profile is not None else load_profile(self.root, rec.get("workerId", ""))
        defs = _services_by_id(profile)
        enabled = [(sid, s) for sid, s in (rec.get("services") or {}).items() if s.get("enabled")]
        missing = []
        if not enabled:
            missing.append("Choisissez au moins un service.")
        for sid, s in enabled:
            for k in defs.get(sid, {}).get("knowledgeFields", []):
                if isinstance(k, dict) and k.get("required") and not str((s.get("knowledge") or {}).get(k.get("key"), "")).strip():
                    missing.append(f"{s.get('label', sid)} : « {k.get('label', k.get('key'))} » est obligatoire.")
        return missing

    def set_status(self, client_id, worker_id, status):
        if status not in STATUSES:
            raise InstallationError(["statut invalide"])
        with _LOCK:
            rec = self.get(client_id, worker_id)
            if rec is None:
                raise InstallationError(["aucune installation pour ce Worker"])
            if status == "active":
                missing = self.readiness(rec)
                if missing:
                    raise InstallationError(missing)
                rec["installedAtUtc"] = rec.get("installedAtUtc") or _now()
            rec["status"] = status
            rec["updatedAtUtc"] = _now()
            _atomic_write(self._path(client_id, worker_id), rec)
        return rec

    def delete_client(self, client_id):
        try:
            import shutil
            shutil.rmtree(self._dir(client_id), ignore_errors=True)
        except InstallationError:
            pass


# ------------------------------------------------------------------ droits d'acces par Worker (offre "Worker a l'unite")
def worker_allowed(billing_state, worker_id):
    """Un client sur un forfait classique (ou l'essai) accede a tous les Workers. Un client en offre "worker-solo" n'accede qu'aux
    Workers qu'il a embauches (accordes par le proprietaire apres facture, puis par le paiement automatique)."""
    state = billing_state or {}
    hired = state.get("hiredWorkers")
    if state.get("planId") == "worker-solo" and isinstance(hired, list):
        return str(worker_id or "").lower() in [str(h).lower() for h in hired]
    return True


def allowed_workers(billing_state):
    """Liste des Workers autorises quand l'acces est restreint, sinon None (tous)."""
    state = billing_state or {}
    hired = state.get("hiredWorkers")
    if state.get("planId") == "worker-solo" and isinstance(hired, list):
        return [str(h).lower() for h in hired]
    return None
