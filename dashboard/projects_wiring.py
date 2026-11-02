# -*- coding: utf-8 -*-
"""Branchement du moteur de projets sur server.py (docs/AUTONOMY-ENGINE.md, sections 7.8 et 10) : UN bloc dans server.py,

    PROJECTS, PROJECTS_API = projects_wiring.build(projects_wiring.ModuleView(globals()))

placé juste au-dessus de `class Handler(BaseHTTPRequestHandler):`. Ce module lit les fonctions du serveur (facturation, droits des Workers, courrier,
pont des connecteurs...) PAR NOM, au moment de l'appel, et les injecte dans ProjectService : le moteur n'importe jamais server.py (pas d'import
circulaire, testable avec un faux serveur).

Dormant : BK_PROJECTS (défaut 0) = les routes répondent 503 PROJECTS_DISABLED, le superviseur ne démarre pas, rien n'est lu ni écrit.
BK_PROJECTS_ALLOW = liste blanche de ClientId (vide = tous quand BK_PROJECTS=1).

Services d'autres chantiers, utilisés s'ils existent (sinon un repli sûr) :
  server.USAGE                 UsageService des fenêtres d'usage (B2) ; repli : borne mensuelle seule (projects_usage.MonthOnlyUsage)
  server.CHLOE_SCOPE           portée des Workers (B3, chloe_scope.py) : objet avec project_scope(client_id) ou fonction ; repli : règles du forfait ici
  recipes (module)             recettes (B6) : lu par ProjectService.
"""
import json
import os
import re
import sys

import projects_approvals as pa
import projects_config as cfg
import projects_store as ps
import projects_usage as pu


class ModuleView:
    """Vue en lecture d'un espace de noms (le `globals()` de server.py) : `getattr(vue, nom, défaut)` lit le nom AU MOMENT de l'appel, sans copie. Plus sûr que
    `sys.modules[__name__]` : les suites de tests qui chargent server.py par importlib sans l'inscrire dans sys.modules continuent de fonctionner."""

    def __init__(self, namespace):
        self._ns = namespace

    def __getattr__(self, name):
        try:
            return self._ns[name]
        except KeyError:
            raise AttributeError(name) from None


def _truthy(value):
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def build(srv, env=None, **overrides):
    """(ProjectService, ProjectsAPI) pour le module serveur `srv` (ou un faux module en test). `overrides` remplace n'importe quelle dépendance
    (usage, resolve_scope, notify, run_connector, runner_cmd, enabled, allowlist...) : les tests ne passent que par là."""
    import projects
    import projects_api
    env = os.environ if env is None else env
    root = overrides.pop("root", None) or getattr(srv, "ROOT")
    ps_cmd = overrides.pop("ps_cmd", None) or list(getattr(srv, "PS_CMD", ["pwsh", "-NoProfile"]))
    dashboard_id = getattr(srv, "DASHBOARD_CLIENT_ID", "CLI-DASHBOARD")

    def get(name, default=None):
        return getattr(srv, name, default)

    # ---- forfait du client (lecture seule du fichier de facturation : jamais get_billing, qui balaie les missions)
    def plan_view(client_id):
        if client_id == dashboard_id:
            return {"planId": "enterprise", "projectsAllowed": True}
        reader = get("_billing_state_readonly")
        state = reader(client_id) if reader else None
        if state is None:
            return {"planId": "essai", "projectsAllowed": False}          # facturation illisible : on n'ouvre jamais par défaut
        return {"planId": str(state.get("planId") or "essai")}

    def upgrade(client_id):
        try:
            payload = get("upgrade_payload")
            billing = get("get_billing")
            return payload(billing(client_id)) if payload and billing else None
        except Exception:  # noqa: BLE001
            return None

    # ---- portée des Workers
    def default_scope(client_id):
        ids = list((get("get_worker_ids") or (lambda: []))())
        if client_id == dashboard_id or not (get("_is_customer_id") or (lambda c: False))(client_id):
            return {"chloe": True, "allowed": ids, "denied": [], "hireOffer": False}
        env_allowed = (get("allowed_workers_env") or (lambda c: None))(client_id)
        allowed = ids if env_allowed is None else [w for w in env_allowed.split(",") if w and w != "-" and w in ids]
        block = (get("worker_block") or (lambda c, w: None))(client_id, "chloe")
        chloe = block is None
        denied = [{"workerId": w, "reason": "Ce Worker ne fait pas partie de votre forfait : embauchez-le pour lui confier une partie du projet."}
                  for w in ids if w not in allowed]
        if chloe:
            lim = cfg.load_limits(root)
            mode = cfg.plan_value(lim["chloeDelegation"], plan_view(client_id)["planId"], "all")
            if mode == "hired_only" and env_allowed is None:
                allowed = []                                   # forfait « Trio » dont les emplacements ne sont pas lisibles : rien d'ouvert par défaut
        return {"chloe": chloe, "allowed": allowed, "denied": denied, "hireOffer": bool(denied)}

    scope_svc = overrides.pop("resolve_scope", None) or get("CHLOE_SCOPE")
    if scope_svc is None:
        resolve_scope = default_scope
    elif hasattr(scope_svc, "project_scope"):
        resolve_scope = scope_svc.project_scope
    else:
        resolve_scope = scope_svc

    # ---- usage : fenêtres (B2) ou repli mensuel
    usage = overrides.pop("usage", None) or get("USAGE")
    if usage is None or not hasattr(usage, "reserve"):
        def month_view(client_id):
            if client_id == dashboard_id or not (get("_is_customer_id") or (lambda c: False))(client_id):
                return {"exempt": True}
            b = get("get_billing")(client_id)
            return {"limit": int(b.get("creditsTotal") or 0), "used": int(b.get("creditsUsed") or 0), "resetsAtUtc": b.get("renewsAtUtc"),
                    "cycleStartUtc": b.get("cycleStartUtc"), "exempt": False}
        usage = pu.MonthOnlyUsage(root, month_view)

    # ---- courrier
    def account_email(client_id):
        try:
            loader = get("_load_accounts")
            verified = get("account_email_verified")
            for acc in (loader() if loader else []):
                if acc.get("clientId") == client_id:
                    if verified and not verified(client_id):
                        return None
                    prof = (get("get_company_profile") or (lambda c: {}))(client_id) or {}
                    if prof.get("notifyProjects") in (False, "0", "false", 0):
                        return None
                    return acc.get("email")
        except Exception:  # noqa: BLE001
            return None
        return None

    def notify(client_id, kind, subject, html, text):
        mailer = get("mailer")
        bridge = get("run_mailer_bridge")
        to = account_email(client_id)
        if not (mailer and to):
            return False
        ok, _err = mailer.send_email(to, subject, html, text, gmail_bridge=bridge)
        return bool(ok)

    def owner_alert(message):
        try:
            import pilot_program
            to = pilot_program.owner_notify_address(root)
            fn = get("_notify_owner_email")
            if to and fn:
                fn(to, "BK AI Workers : alerte projets", f"<p>{message}</p>", message)
        except Exception:  # noqa: BLE001
            pass

    def worker_summary(wid):
        loader = get("load_json")
        base = (get("worker_base_dir") or (lambda w: os.path.join(root, "workers", w)))(wid)
        ident = (loader(os.path.join(base, "identity", "identity.json"), {}) if loader else {}) or {}
        portrait = get("portrait_url")
        return {"id": wid, "name": str(ident.get("name") or str(wid).capitalize()), "role": str(ident.get("role") or ""),
                "portraitUrl": portrait(wid) if portrait else f"/portraits/{wid}.jpg"}

    def engine_gate(client_id, level):
        """Un projet tourne sur le lanceur Claude (outils serveur, fichiers, longue boucle). Si le proprietaire a choisi un autre moteur pour ce compte (dashboard/provider_router.py,
        capacite longProjects absente) ou si le plafond de depense Claude est atteint, on refuse honnetement au lieu de depenser la cle de la plateforme. Sans choix : aucun effet."""
        probe = get("engine_capabilities")
        if not probe:
            return None
        try:
            caps = probe(client_id, None)
        except Exception:  # noqa: BLE001 - un souci de reglages ne bloque jamais un projet : chemin habituel
            return None
        if isinstance(caps, dict) and not caps.get("longProjects", True):
            return ("Le moteur d'IA actuellement prevu pour votre compte ne sait pas mener un projet de plusieurs heures. "
                    "Une mission ponctuelle reste possible ; le projet sera disponible des que le moteur Claude sera de nouveau actif.")
        return None

    enabled = overrides.pop("enabled", None)
    if enabled is None:
        enabled = _truthy(env.get("BK_PROJECTS"))
    allowlist = overrides.pop("allowlist", None)
    if allowlist is None:
        allowlist = env.get("BK_PROJECTS_ALLOW") or ""
    deps = dict(
        resolve_scope=resolve_scope, usage=usage, notify=notify, run_connector=get("run_connector_dispatch_bridge"), log_activity=get("log_activity"),
        write_json=get("_write_json_atomic"), lock=get("_STATE_LOCK"), plan_view=plan_view, account_email=account_email, worker_summary=worker_summary,
        enabled=enabled, installation_paused=get("installation_paused"), public_url=get("PUBLIC_BASE_URL", ""), owner_alert=owner_alert,
        allowlist=allowlist, upgrade=upgrade, engine_gate=engine_gate)
    deps.update(overrides)
    service = projects.ProjectService(root, ps_cmd, **deps)
    nudge = getattr(service, "nudge", None)
    if hasattr(usage, "nudge") and getattr(usage, "nudge", None) is None and nudge:
        usage.nudge = nudge

    def resolve_client_id(handler):
        return handler._resolve_client_id()

    def read_json_limited(handler, limit, strict=True):
        return handler._read_json_limited(limit, strict=strict)

    def is_owner(handler):
        return bool(handler._gate_authenticated())

    api = projects_api.ProjectsAPI(service, resolve_client_id, None, read_json_limited, None, is_owner=is_owner, public_base_url=get("PUBLIC_BASE_URL", ""))
    # atelier de sites (B5) : ses outils et ses routes s'enregistrent eux-mêmes s'il existe
    try:
        import site_routes
        site_routes.register(service, api)
    except ImportError:
        pass
    except Exception as e:  # noqa: BLE001 - un module optionnel ne casse jamais le serveur
        sys.stderr.write(f"projects wiring: site_routes: {type(e).__name__}: {e}\n")
    return service, api
