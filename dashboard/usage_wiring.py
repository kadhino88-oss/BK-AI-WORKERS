# -*- coding: utf-8 -*-
"""Branchement de dashboard/usage.py sur server.py (facturation, missions, route /api/usage). server.py n'y ajoute que de petits crochets :

    USAGE = usage_wiring.build(globals())        # juste apres subscription_required_payload

`build` accepte le module ou son dictionnaire de globales : les fonctions de server.py sont resolues AU MOMENT DE L'APPEL (tests qui remplacent
server._utcnow, fonctions definies plus bas dans le fichier). Rien ici n'est execute a l'import.

Regles (docs/PRICING.md section 6, docs/AUTONOMY-ENGINE.md section 6b) :
  - BK_USAGE_WINDOWS=0 (defaut) : tout est inerte, aucune reponse existante ne change. shadow : le grand livre tourne, rien n'est bloque,
    chaque refus qui aurait eu lieu est journalise (usage_would_block). 1 : session et semaine bloquent, avec un 402 USAGE_LIMIT_REACHED.
  - BK_PROJECTS=1 impose au moins « shadow » : les credits des etapes de projet ne sont pas des fichiers TASK-*.json, seul le grand livre les compte.
  - Un grand livre illisible ne coupe JAMAIS le service : on journalise et on laisse passer (le quota mensuel d'origine reste applique).
"""
import calendar
import os
import uuid

import usage as usage_mod


class UsageLimitMessage(str):
    """Message francais d'un refus de SESSION ou de SEMAINE. Il se comporte comme le texte que les routes de mission renvoient deja ; en plus il
    porte l'UsageBlock, pour que subscription_required_payload en fasse un 402 USAGE_LIMIT_REACHED (le refus du mois reste un SUBSCRIPTION_REQUIRED)."""
    usage_block = None


class _NS:
    """Acces par attribut a un module ou a un dictionnaire de globales, resolu a chaque appel."""

    def __init__(self, ns):
        object.__setattr__(self, "_ns", ns)

    def __getattr__(self, name):
        ns = object.__getattribute__(self, "_ns")
        if isinstance(ns, dict):
            try:
                return ns[name]
            except KeyError:
                raise AttributeError(name)
        return getattr(ns, name)


def effective_mode():
    mode = usage_mod._mode_from_env()
    # Meme ecriture que le moteur de projets (projects_wiring._truthy, site_preview, server.py) : « 1 », « true », « yes », « on ». Un moteur de projets
    # actif sans grand livre d'usage laisserait les projets hors des compteurs session / semaine / mois.
    if mode == "off" and os.environ.get("BK_PROJECTS", "0").strip().lower() in ("1", "true", "yes", "on"):
        return "shadow"
    return mode


class MissionRun:
    """Une mission en cours vue par le grand livre : sa reservation, le nombre de Workers que Chloe peut appeler avec ce qui est reserve."""
    __slots__ = ("client_id", "reservation", "workers", "blocked", "result", "cost")

    def __init__(self, client_id):
        self.client_id = client_id
        self.reservation = None
        self.workers = None
        self.blocked = None            # corps de la reponse 402 quand la reservation est refusee
        self.result = None
        self.cost = 1

    def cap_workers(self, max_workers):
        """Plafond du nombre de Workers de Chloe : le plus petit entre le solde mensuel et ce que les fenetres ont accorde."""
        if max_workers is None or self.workers is None:
            return max_workers
        return max(1, min(max_workers, self.workers))


class WiredUsage(usage_mod.UsageService):
    def __init__(self, ns):
        self.s = _NS(ns)
        super().__init__(
            self.s.ROOT, plan_view=self._plan_view_impl, now=self._clock, mode=effective_mode, nudge=self._nudge_impl,
            write_json=lambda path, data: self.s._write_json_atomic(path, data, ensure_ascii=False),
            log=lambda event, **fields: self.s.log_activity(event, **fields), task_credits=lambda data: self.s.task_credits(data))

    # ---- horloge, forfait, reveil ----------------------------------------------------------------------------------------------------------
    def _clock(self):
        dt = self.s._utcnow()
        return calendar.timegm(dt.timetuple()) + dt.microsecond / 1e6

    def _nudge_impl(self, client_id):
        try:
            projects = self.s.PROJECTS
        except AttributeError:
            return
        nudge = getattr(projects, "nudge", None)
        if callable(nudge):
            try:
                nudge()          # ProjectService.nudge() reveille le superviseur pour tous les clients (il ne prend pas d'identifiant)
            except TypeError:
                nudge(client_id)

    def _plan_view_impl(self, client_id):
        """Forfait du client tel que le service d'usage le lit : credits du mois (forfait + credits accordes), cycle de facturation, plafonds
        d'un contrat. Les comptes qui ne sont pas des clients (proprietaire, essai public, identifiants libres) sont exemptes."""
        s = self.s
        if not s._is_customer_id(client_id):
            return {"exempt": True, "planId": None}
        state = s._billing_load(client_id)
        plan_id = state.get("planId", "essai")
        plan = s.PLAN_CATALOG.get(plan_id, s.PLAN_CATALOG["essai"])
        # Meme horloge que get_billing : une fois la periode payee terminee (jours de grace d'un forfait sur facture), la fenetre du mois ne
        # se renouvelle plus ; sans cela le grand livre ouvrirait un mois neuf que personne n'a paye.
        cycle_start, renews_at = s.billing_cycle(state.get("cycleStartUtc", ""), plan.get("renews", True), s._window_clock(state))
        paid_until = state.get("paidUntilUtc") if s._parse_utc(state.get("paidUntilUtc")) else None
        if bool(state.get("cancelAtPeriodEnd")) and paid_until and renews_at and s._parse_utc(renews_at) >= s._parse_utc(paid_until):
            renews_at = None            # meme regle que get_billing : resilie, rien ne se renouvelle au-dela de la periode payee
        try:
            extra = max(0, int(state.get("extraCredits") or 0))
        except (TypeError, ValueError):
            extra = 0
        override = state.get("usageOverride")
        return {"exempt": False, "planId": plan_id, "monthlyCredits": s.plan_monthly_credits(plan_id, state) + extra,
                "cycleStartUtc": cycle_start, "renewsAtUtc": renews_at, "override": override if isinstance(override, dict) else None}

    # ---- missions --------------------------------------------------------------------------------------------------------------------------
    def _chloe_fanout(self, client_id):
        allowed = self.s.allowed_workers_env(client_id)
        if allowed is None:
            return max(1, len(self.s.get_worker_ids()))
        if allowed == "-":
            return 1
        return max(1, len([x for x in allowed.split(",") if x.strip()]))

    def mission_begin(self, client_id, worker_id, level, plan_only):
        """Reserve les credits de la mission dans les trois fenetres (une seule section critique). Chloe appelle plusieurs Workers et chacun
        coute le niveau de la mission : on reserve niveau x Workers possibles, en acceptant moins (reservation partielle) ; le nombre de
        Workers qu'elle peut appeler est ensuite plafonne a ce qui a ete accorde. Rien n'est reserve pour un plan (plan_only)."""
        run = MissionRun(client_id)
        s = self.s
        if plan_only or not self.enabled or self.exempt_client(client_id) or not s._is_customer_id(client_id):
            return run
        try:
            lvl = s.normalize_level(level, client_id)
            run.cost = s.level_credits(lvl) if lvl else 1
            chloe = str(worker_id or "").lower() == "chloe"
            workers = 1
            if chloe:
                cap = s.chloe_worker_cap(client_id, lvl)
                workers = max(1, min(cap or 1, self._chloe_fanout(client_id)))
            rsv = self.reserve(client_id, run.cost * workers, "mission", "MSN-" + uuid.uuid4().hex[:12].upper(), allow_partial=chloe, min_partial=run.cost)
            if isinstance(rsv, usage_mod.UsageBlock):
                msg = self.block_message(client_id, rsv)
                run.blocked = self.limit_payload(client_id, msg) if isinstance(msg, UsageLimitMessage) else s.subscription_required_payload(client_id, msg)
                return run
            run.reservation = rsv
            if chloe and not rsv.exempt:
                run.workers = max(1, rsv.credits // max(1, run.cost))
        except Exception as exc:  # noqa: BLE001 - un grand livre illisible ne coupe pas la mission : le quota mensuel d'origine reste applique
            self._fail_open("mission_begin", client_id, exc)
        return run

    def mission_end(self, run):
        """Regle la reservation sur les credits REELLEMENT tracees (memes fichiers TASK-*.json et memes regles que le quota mensuel)."""
        if run is None or run.reservation is None:
            return
        try:
            self.settle(run.client_id, run.reservation, self.mission_credits(run.result))
        except Exception as exc:  # noqa: BLE001
            self._fail_open("mission_end", run.client_id, exc)

    def mission_credits(self, result):
        """Credits d'une mission : somme de task_credits des traces ecrites (TaskId de la reponse et de chaque Worker appele par Chloe)."""
        s = self.s
        ids = []
        if isinstance(result, dict):
            ids.append(result.get("TaskId"))
            for item in (result.get("Results") or []):
                if isinstance(item, dict):
                    ids.append(item.get("TaskId"))
        total = 0
        for tid in dict.fromkeys(t for t in ids if isinstance(t, str) and s.TASK_ID_PATTERN.match(t)):
            data = s.load_json(os.path.join(s.TASKS_DIR, tid + ".json"))
            if isinstance(data, dict):
                total += s.task_credits(data)
        return total

    def _fail_open(self, where, client_id, exc):
        try:
            self.s.log_activity("usage_failopen", where=where, clientId=client_id, error=type(exc).__name__)
        except Exception:  # noqa: BLE001
            pass

    # ---- facturation -----------------------------------------------------------------------------------------------------------------------
    def billing_used(self, client_id):
        """Credits du cycle d'apres le grand livre, ou None (service inerte, compte exempte, grand livre illisible) : get_billing garde alors le
        balayage d'origine."""
        try:
            return self.month_used(client_id)
        except Exception as exc:  # noqa: BLE001
            self._fail_open("billing_used", client_id, exc)
            return None

    def next_limits(self, credits):
        return usage_mod.allowances_for(credits, self.limits()) if isinstance(credits, int) and credits > 0 else None

    # ---- controle de la mission (sans rien consommer) et messages ---------------------------------------------------------------------------
    def gate(self, client_id, needed):
        """None si la mission passe dans les fenetres, sinon le message francais du refus. Appele par subscription_blocks_mission APRES le
        controle du mois d'origine. Le refus du mois (reservations comprises) garde le texte d'origine (SUBSCRIPTION_REQUIRED)."""
        if not self.enforced:
            return None
        try:
            block = self.check(client_id, needed)
        except Exception as exc:  # noqa: BLE001
            self._fail_open("gate", client_id, exc)
            return None
        return None if block is None else self.block_message(client_id, block)       # UsageBlock est faux comme booleen : toujours tester `is None`

    def block_message(self, client_id, block):
        s = self.s
        if block.limit == "month":
            billing = s.get_billing(client_id)
            sentence = s._upgrade_sentence(billing)
            if block.remaining > 0:
                return (f"Il vous reste {block.remaining} crédit(s), ce niveau en demande {block.needed}. Choisissez un niveau plus rapide"
                        + (f" ou {sentence}." if sentence else " ou souscrivez un abonnement pour continuer."))
            return s.quota_reached_message(billing)
        lim = self.limits()
        view = block.view
        window = getattr(view, block.limit)
        label = "de session" if block.limit == "session" else "de la semaine"
        limit_txt = s._fr_int(window.limit)
        now = self._clock()
        if block.remaining > 0:
            text = f"Il vous reste {block.remaining} crédit(s) dans votre quota {label}, ce niveau en demande {block.needed}."
        else:
            text = f"Vous avez utilisé votre quota {label} ({limit_txt} crédits)."
        reset = usage_mod.parse_iso(block.resetsAtUtc)
        if reset is not None:
            text += f" Il se renouvelle {usage_mod.fr_when(reset, now, lim['displayTimezone'])} (dans {usage_mod.fr_duration(reset - now)})."
        else:
            text += f" Ce niveau dépasse le quota {label} de votre forfait."
        pid = view.planId
        sentence = self.upgrade_sentence(pid, block.limit)
        if block.remaining > 0 and reset is not None:
            text += " Choisissez un niveau plus rapide, attendez le renouvellement" + (f" ou {sentence}." if sentence else ".")
        elif block.remaining > 0:
            text += " Choisissez un niveau plus rapide" + (f" ou {sentence}." if sentence else ".")
        elif sentence:
            text += f" Pour continuer sans attendre, {sentence}."
        msg = UsageLimitMessage(text)
        msg.usage_block = block
        return msg

    def upgrade_sentence(self, plan_id, window):
        """« passez au forfait Pro (115 crédits par session) » ; « écrivez-nous… » quand il n'y a pas de forfait libre-service au-dessus."""
        s = self.s
        nxt = s.next_plan_info(plan_id)
        contact = s.CONTACT_EMAIL
        if nxt is None:
            return f"écrivez-nous à {contact} pour relever ce plafond"
        if nxt["onQuote"]:
            return f"passez à Enterprise, sur devis, avec des plafonds fixés par contrat : écrivez-nous à {contact}"
        limits = self.next_limits(nxt["credits"]) or {}
        per = "par session" if window == "session" else "par semaine"
        return f"passez au forfait {nxt['name']} ({s._fr_int(limits.get(window, 0))} crédits {per})"

    def upgrade_card(self, plan_id):
        """Le forfait du dessus, avec ses limites : {planId, planName, priceChf, limits{session, week, month}, onQuote, selfService} (None si aucun)."""
        nxt = self.s.next_plan_info(plan_id)
        if nxt is None:
            return None
        return {"planId": nxt["planId"], "planName": nxt["name"], "priceChf": nxt["priceChf"], "limits": self.next_limits(nxt["credits"]),
                "onQuote": nxt["onQuote"], "selfService": nxt["selfService"], "creditsPerMonth": nxt["credits"], "contactEmail": self.s.CONTACT_EMAIL}

    def limit_payload(self, client_id, msg):
        """Corps du 402 USAGE_LIMIT_REACHED."""
        b = msg.usage_block
        payload = self.payload(client_id)
        return {"error": "USAGE_LIMIT_REACHED", "limit": b.limit, "needed": b.needed, "remaining": b.remaining, "resetsAtUtc": b.resetsAtUtc,
                "detail": str(msg), "usage": payload, "upgrade": payload.get("upgrade")}

    # ---- GET /api/usage --------------------------------------------------------------------------------------------------------------------
    def payload(self, client_id):
        s = self.s
        lim = self.limits()
        mode = self.mode()
        base = {"ok": True, "mode": mode, "enforced": mode == "on", "sessionHours": lim["sessionHours"], "weekDays": lim["weekDays"],
                "warnPercent": lim["warnPercent"]}
        if self.exempt_client(client_id) or not s._is_customer_id(client_id):
            base.update(exempt=True, windowsApply=False, planId=None, planName=None, session=None, week=None, month=None, binding=None,
                        allowedNow=None, nextRenewalUtc=None, upgrade=None, activeReservations=[])
            return base
        pv = self._plan_view_impl(client_id)
        plan = s.PLAN_CATALOG.get(pv["planId"], s.PLAN_CATALOG["essai"])
        base.update(planId=pv["planId"], planName=plan["name"], limits=usage_mod.allowances_for(pv["monthlyCredits"], lim, pv.get("override")),
                    upgrade=self.upgrade_card(pv["planId"]))
        if mode == "off":
            b = s.get_billing(client_id)
            used, total = int(b["creditsUsed"]), int(b["creditsTotal"])
            base.update(exempt=False, windowsApply=False, session=None, week=None, binding="month", allowedNow=max(0, total - used),
                        nextRenewalUtc=b["renewsAtUtc"], activeReservations=[],
                        month={"limit": total, "used": used, "reserved": 0, "remaining": max(0, total - used), "opened": True,
                               "startUtc": b["cycleStartUtc"], "resetsAtUtc": b["renewsAtUtc"], "percentUsed": b["percentUsed"]})
            return base
        view = self.remaining(client_id)
        base.update(view.to_dict(lim["sessionHours"], lim["weekDays"]))
        base["activeReservations"] = self.active_reservations(client_id)
        return base

    def public_limits(self):
        """GET /api/usage-limits (sans compte) : les plafonds par forfait, ceux de la page Tarifs. `enforced` dit si ils s'appliquent
        reellement : tant que c'est faux, aucune page ne doit les presenter comme un engagement."""
        s = self.s
        lim = self.limits()
        plans = {}
        for pid, p in s.PLAN_CATALOG.items():
            if p.get("legacy") or pid == "essai" or p.get("contractual"):
                continue
            plans[pid] = dict(usage_mod.allowances_for(p["credits"], lim), name=p["name"])
        return {"ok": True, "enforced": self.enforced, "sessionHours": lim["sessionHours"], "weekDays": lim["weekDays"], "plans": plans}


def build(ns):
    return WiredUsage(ns)
