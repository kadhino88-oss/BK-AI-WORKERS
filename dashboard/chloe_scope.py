# -*- coding: utf-8 -*-
"""Chloe delegue a tous les Workers : ce qu'elle PEUT deleguer (droits du forfait) et combien elle peut en payer MAINTENANT (credits et fenetres d'usage).

Module PUR : aucune dependance a server.py (les fonctions du serveur lui sont injectees, comme pour le moteur de projets). Deux questions, deux
reponses, et c'est tout ce que la PowerShell de Chloe recoit : BK_ALLOWED_WORKERS (droits) et BK_MAX_WORKERS (credits) ne viennent JAMAIS d'un texte de
Worker, d'une page web ou du message du client.

  project_scope(client_id)  -> {"chloe": bool, "allowed": [ids], "denied": [{"workerId","code","reason"}], "hireOffer": bool, "paused": [ids], "plan": id}
      Contrat docs/AUTONOMY-ENGINE.md, section 6c.4 (lu par le moteur de projets : server.CHLOE_SCOPE) :
        Essai, Equipe, Pro, Scale, Enterprise : Chloe et les 17 Workers.
        Trio : Chloe et les 3 Workers EMBAUCHES ; les autres sont listes dans `denied` (Chloe dit lesquels lui manquent et propose l'embauche : sinon
               Trio vendrait toute l'equipe au prix de trois).
        Solo : pas de Chloe ; le Worker embauche seul (un projet se lance depuis sa fiche).
      Le proprietaire change la regle a deux endroits : inst.PLANS_WITH_CHLOE (dashboard/installations.py) et la table chloeDelegation de
      core/projects/PROJECT-LIMITS.json ("trio": "hired_only", defaut "all").
  mission_budget(client_id, level) -> combien de Workers les credits payent pour UNE mission de Chloe (chaque Worker appele coute le niveau).
      Source : les fenetres d'usage (session, semaine, mois : le plus bas) quand le service d'usage du chantier « limites » est la, sinon le solde du mois.
      Adaptateur volontairement mince : quand le service d'usage est branche, rien d'autre ne change.
"""
import json
import os

DEFAULT_DELEGATION = {"trio": "hired_only", "default": "all"}


def _int(value, default=0):
    return value if isinstance(value, int) and not isinstance(value, bool) else default


class ChloeScope:
    def __init__(self, *, worker_ids, allowed_workers_env, worker_block, installation_paused=None, plans_with_chloe=("trio",), plan_id_of=None,
                 delegation=None, root=None, excluded=("atlas",), worker_name=None, credits_remaining=None, level_credits=None, usage=None,
                 is_customer=None, fr_when=None):
        self._worker_ids = worker_ids                      # () -> [ids] : tous les Workers qui existent
        self._allowed_env = allowed_workers_env            # (client_id) -> None (tous) | "-" (aucun) | "a,b"
        self._worker_block = worker_block                  # (client_id, worker_id) -> None si autorise, sinon la reponse de refus
        self._paused = installation_paused or (lambda c, w: False)
        self._plans_with_chloe = tuple(plans_with_chloe)
        self._plan_id = plan_id_of or (lambda c: None)
        self._delegation = delegation
        self._root = root
        self._excluded = {str(w).lower() for w in (excluded or ())}
        self._name = worker_name or (lambda w: str(w).capitalize())
        self._credits_remaining = credits_remaining or (lambda c: None)
        self._level_credits = level_credits or (lambda lvl: 1)
        self._usage = usage                                # () -> UsageService | None (relu a chaque appel : il peut etre branche apres)
        self._is_customer = is_customer or (lambda c: True)
        self._fr_when = fr_when                            # (iso) -> "demain a 08:00" ; None : pas de phrase de renouvellement

    # ------------------------------------------------------------------ droits
    def delegation_mode(self, plan_id):
        table = self._delegation
        if table is None and self._root:
            try:
                with open(os.path.join(self._root, "core", "projects", "PROJECT-LIMITS.json"), encoding="utf-8-sig") as f:
                    table = (json.load(f) or {}).get("chloeDelegation")
            except (OSError, ValueError):
                table = None
        if not isinstance(table, dict):
            table = DEFAULT_DELEGATION
        return str(table.get(plan_id) or table.get("default") or "all")

    def _roster(self):
        return [w for w in self._worker_ids() if str(w).lower() not in self._excluded]

    def project_scope(self, client_id):
        ids = self._roster()
        if not self._is_customer(client_id):
            return {"chloe": True, "allowed": ids, "denied": [], "hireOffer": False, "paused": [], "plan": None}
        env = self._allowed_env(client_id)
        allowed = list(ids) if env is None else [w for w in str(env).split(",") if w and w != "-" and w in ids]
        chloe = self._worker_block(client_id, "chloe") is None
        plan = self._plan_id(client_id)
        if chloe and env is None and self.delegation_mode(plan) == "hired_only":
            allowed = []        # emplacements illisibles sur un forfait a Workers choisis : rien n'est ouvert par defaut
        denied = [{"workerId": w, "code": "NOT_HIRED",
                   "reason": f"{self._name(w)} ne fait pas partie de vos Workers embauchés : embauchez-le pour lui confier cette partie."}
                  for w in ids if w not in allowed]
        paused = [w for w in allowed if self._paused(client_id, w)]
        return {"chloe": chloe, "allowed": allowed, "denied": denied, "hireOffer": bool(denied), "paused": paused, "plan": plan}

    # ------------------------------------------------------------------ credits
    def _usage_view(self, client_id):
        svc = self._usage() if callable(self._usage) else self._usage
        if svc is None or not hasattr(svc, "remaining"):
            return None
        if hasattr(svc, "enforced") and not svc.enforced:
            return None        # fenetres non appliquees (BK_USAGE_WINDOWS=0 ou shadow) : le mois seul decide
        try:
            view = svc.remaining(client_id)
        except Exception:  # noqa: BLE001 - un grand livre illisible ne doit jamais bloquer Chloe : le solde du mois reste la
            return None
        return None if getattr(view, "exempt", False) else view

    def mission_budget(self, client_id, level=None):
        """{"workers": int|None, "creditsAllowed": int|None, "creditCost": int, "resetsAtUtc": str|None, "binding": str|None, "source": str|None}.
        workers = credits utilisables maintenant // cout du niveau, au moins 1 (subscription_blocks_mission a deja verifie qu'une mission de ce niveau est
        payable) ; None = pas de plafond (proprietaire, essai public, identifiant qui n'est pas un compte client)."""
        cost = max(1, _int(self._level_credits(level) if level else 1, 1))
        out = {"workers": None, "creditsAllowed": None, "creditCost": cost, "resetsAtUtc": None, "binding": None, "source": None}
        if not self._is_customer(client_id):
            return out
        view = self._usage_view(client_id)
        if view is not None:
            allowed = max(0, _int(getattr(view, "allowedNow", 0)))
            binding = getattr(view, "binding", None)
            window = getattr(view, binding, None) if binding else None
            out.update(creditsAllowed=allowed, binding=binding, resetsAtUtc=getattr(window, "resetsAtUtc", None), source="usage")
        else:
            remaining = self._credits_remaining(client_id)
            allowed = remaining if isinstance(remaining, int) and not isinstance(remaining, bool) and remaining > 0 else 0
            out.update(creditsAllowed=allowed, source="billing")
        out["workers"] = max(1, allowed // cost)
        return out

    def worker_cap(self, client_id, level=None):
        """Corps de server.chloe_worker_cap : le nombre de Workers (BK_MAX_WORKERS), ou None."""
        return self.mission_budget(client_id, level)["workers"]

    def child_env(self, client_id, level=None, worker_id=""):
        """Variables d'environnement ajoutees au processus PowerShell d'une mission de CHLOE (rien pour un Worker seul). Aucune ne vient d'un texte
        d'utilisateur : le texte de renouvellement est fabrique ici, jamais recopie."""
        if str(worker_id or "").lower() != "chloe":
            return {}
        env = {}
        budget = self.mission_budget(client_id, level)
        if budget["resetsAtUtc"] and self._fr_when:
            try:
                note = str(self._fr_when(budget["resetsAtUtc"]) or "").strip()
            except Exception:  # noqa: BLE001
                note = ""
            if note:
                env["BK_CHLOE_RESET_NOTE"] = note[:70]
        return env


def run_triage(root, ps_cmd, request, env, timeout=60):
    """Lance chloe/Chloe-Triage.ps1 (un appel au modele, aucun Worker, aucun credit) et rend son JSON : {"ok": True, "mode", "why", "workers", ...} ou
    {"ok": False, "error": CODE}. Le texte du client ne passe que comme argument de la commande, jamais interprete par un interpreteur de commandes."""
    import subprocess
    import tempfile
    import uuid
    out = os.path.join(tempfile.gettempdir(), f"bkaiw-triage-{uuid.uuid4().hex}.json")
    try:
        subprocess.run([*ps_cmd, "-File", os.path.join(root, "chloe", "Chloe-Triage.ps1"), "-Request", request, "-OutFile", out],
                       capture_output=True, timeout=timeout, env=env)
        if os.path.isfile(out):
            with open(out, encoding="utf-8-sig") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {"ok": False, "error": "TRIAGE_INVALID"}
        return {"ok": False, "error": "TRIAGE_FAILED"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "TRIAGE_TIMEOUT"}
    except Exception:  # noqa: BLE001
        return {"ok": False, "error": "TRIAGE_FAILED"}
    finally:
        try:
            os.remove(out)
        except OSError:
            pass
