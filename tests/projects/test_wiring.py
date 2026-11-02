# -*- coding: utf-8 -*-
"""Branchement du moteur sur server.py (dashboard/projects_wiring.py) avec un FAUX module serveur : droits des Workers par forfait (Essai, Solo,
Trio, Equipe...), dormant par défaut, liste blanche, repli d'usage mensuel, courrier de notification. Aucun vrai serveur.

    python tests/projects/test_wiring.py"""
import json
import os
import shutil
import sys
import tempfile
import time
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import projects_wiring  # noqa: E402

IDS = ["alex", "amina", "clara", "dario", "emma", "ines", "lea", "lucas", "maya", "noah", "nora", "rayan", "sam", "seoya", "sophie", "thomas", "yanis"]
CUST = "CLI-CUST-AAAAAAAA"


def fake_server(root, billing):
    """billing : {clientId: état de facturation} (None = illisible)."""
    def readonly(cid):
        return billing.get(cid, {})

    def env_allowed(cid):
        st = readonly(cid)
        if st is None:
            return "-"
        hired = st.get("hired")
        return None if hired is None else (",".join(hired) or "-")

    def block(cid, wid):
        st = readonly(cid)
        if st is None:
            return {"error": "WORKER_NOT_INCLUDED"}
        if wid == "chloe":
            return None if st.get("planId") in ("equipe", "pro", "scale", "enterprise", "trio", "essai") else {"error": "WORKER_NOT_INCLUDED"}
        hired = st.get("hired")
        return None if hired is None or wid in hired else {"error": "WORKER_NOT_INCLUDED"}
    sent = []
    srv = types.SimpleNamespace(
        ROOT=root, PS_CMD=["pwsh", "-NoProfile"], DASHBOARD_CLIENT_ID="CLI-DASHBOARD", PUBLIC_BASE_URL="https://app.test.example",
        get_worker_ids=lambda: list(IDS), _is_customer_id=lambda c: str(c).startswith("CLI-CUST-"), _billing_state_readonly=readonly,
        allowed_workers_env=env_allowed, worker_block=block, installation_paused=lambda c, w: False,
        get_billing=lambda c: {"creditsTotal": 900, "creditsUsed": 100, "renewsAtUtc": "2099-01-01T00:00:00Z", "cycleStartUtc": "2026-10-01T00:00:00Z"},
        upgrade_payload=lambda b: {"planId": "pro", "planName": "Pro"},
        _load_accounts=lambda: [{"clientId": CUST, "email": "client@test.example"}], account_email_verified=lambda c: True,
        get_company_profile=lambda c: {}, run_mailer_bridge=lambda p: {"ok": True},
        mailer=types.SimpleNamespace(send_email=lambda to, subject, html, text, gmail_bridge=None: (sent.append((to, subject, html, text)) or (True, None))),
        load_json=lambda p, d=None: json.load(open(p, encoding="utf-8-sig")) if os.path.isfile(p) else d)
    srv.sent = sent
    return srv


class WiringTests(unittest.TestCase):
    def build(self, billing, env=None, **ov):
        root = tempfile.mkdtemp(prefix="bkwire-")
        self.addCleanup(shutil.rmtree, root, True)
        srv = fake_server(root, billing)
        service, api = projects_wiring.build(srv, env=env if env is not None else {"BK_PROJECTS": "1"}, **ov)
        self.addCleanup(service.stop, False)
        return srv, service, api

    def test_dormant_by_default_and_nothing_is_created(self):
        srv, svc, api = self.build({}, env={})
        self.assertFalse(svc.enabled)
        self.assertFalse(os.path.exists(os.path.join(srv.ROOT, "runtime", "projects")))
        svc.start_supervisor()
        svc.reap(boot=True)
        self.assertIsNone(svc._thread)
        self.assertFalse(os.path.exists(os.path.join(srv.ROOT, "runtime", "projects")))
        self.assertEqual(svc.export_client(CUST), {"projects": []})
        self.assertEqual(svc.purge_client(CUST), 0)
        for v in ("0", "", "false", "no", "off", None):
            _s, s2, _a = self.build({}, env={"BK_PROJECTS": v} if v is not None else {})
            self.assertFalse(s2.enabled, v)
        for v in ("1", "true", "yes", "on"):
            _s, s2, _a = self.build({}, env={"BK_PROJECTS": v})
            self.assertTrue(s2.enabled, v)

    def test_every_plan_gets_the_right_scope(self):
        billing = {"CLI-CUST-AAAAAAA1": {"planId": "equipe", "hired": None}, "CLI-CUST-AAAAAAA2": {"planId": "solo", "hired": ["lucas"]},
                   "CLI-CUST-AAAAAAA3": {"planId": "trio", "hired": ["lucas", "emma", "lea"]}, "CLI-CUST-AAAAAAA4": {"planId": "trio", "hired": None},
                   "CLI-CUST-AAAAAAA5": {"planId": "essai", "hired": None}, "CLI-CUST-AAAAAAA6": None}
        _srv, svc, _api = self.build(billing)
        sc = svc.resolve_scope("CLI-CUST-AAAAAAA1")                                          # Equipe : toute l'équipe, Chloé comprise
        self.assertEqual((sc["chloe"], sorted(sc["allowed"]), sc["denied"]), (True, sorted(IDS), []))
        sc = svc.resolve_scope("CLI-CUST-AAAAAAA2")                                          # Solo : pas de Chloé, un seul Worker
        self.assertEqual((sc["chloe"], sc["allowed"]), (False, ["lucas"]))
        self.assertEqual(len(sc["denied"]), 16)
        self.assertTrue(sc["hireOffer"])
        sc = svc.resolve_scope("CLI-CUST-AAAAAAA3")                                          # Trio : Chloé + les 3 Workers embauchés, les autres nommés avec une offre
        self.assertEqual((sc["chloe"], sorted(sc["allowed"])), (True, ["emma", "lea", "lucas"]))
        self.assertEqual({d["workerId"] for d in sc["denied"]}, set(IDS) - {"emma", "lea", "lucas"})
        self.assertTrue(all("embauchez" in d["reason"] for d in sc["denied"]))
        sc = svc.resolve_scope("CLI-CUST-AAAAAAA4")                                          # Trio sans emplacements lisibles : rien d'ouvert par défaut
        self.assertEqual((sc["chloe"], sc["allowed"]), (True, []))
        sc = svc.resolve_scope("CLI-DASHBOARD")                                              # le propriétaire : tout
        self.assertEqual((sc["chloe"], sorted(sc["allowed"])), (True, sorted(IDS)))
        sc = svc.resolve_scope("CLI-CUST-AAAAAAA6")                                          # facturation illisible : on n'ouvre jamais
        self.assertEqual(sc["allowed"], [])

    def test_plan_view_never_opens_by_default(self):
        srv, svc, _api = self.build({"CLI-CUST-AAAAAAA1": {"planId": "pro"}, "CLI-CUST-AAAAAAA6": None})
        self.assertEqual(svc.plan_id_of("CLI-CUST-AAAAAAA1"), "pro")
        self.assertEqual(svc.plan_id_of("CLI-CUST-AAAAAAA6"), "essai")                        # illisible : forfait Essai, donc pas de projet
        self.assertEqual(svc.plan_id_of("CLI-DASHBOARD"), "enterprise")
        self.assertEqual(svc.plan_id_of("CLI-CUST-NOBILLING"), "essai")

    def test_the_monthly_fallback_counts_projects_and_blocks_at_the_limit(self):
        srv, svc, _api = self.build({CUST: {"planId": "equipe"}})
        v = svc.usage.remaining(CUST)
        self.assertEqual((v.month.limit, v.month.used, v.allowedNow, v.binding), (900, 100, 800, "month"))
        base = os.path.join(srv.ROOT, "runtime", "projects", CUST, "PRJ-" + "A" * 32)
        os.makedirs(base)
        with open(os.path.join(base, "cost-ledger.jsonl"), "w", encoding="utf-8") as f:
            f.write(json.dumps({"ts": "2026-10-10T10:00:00Z", "credits": 300}) + "\n")
            f.write(json.dumps({"ts": "2026-09-10T10:00:00Z", "credits": 999}) + "\n")           # d'un cycle précédent : ne compte pas
        self.assertEqual(svc.usage.remaining(CUST).allowedNow, 500)
        r = svc.usage.reserve(CUST, 400, "project_step", "x", ttl_s=60, allow_partial=True)
        self.assertEqual(r.credits, 400)
        self.assertEqual(svc.usage.remaining(CUST).allowedNow, 100)
        blocked = svc.usage.reserve(CUST, 400, "project_step", "y", allow_partial=False)
        self.assertEqual((blocked.limit, blocked.needed, blocked.remaining), ("month", 400, 100))
        svc.usage.release(CUST, r.id)
        self.assertEqual(svc.usage.remaining(CUST).allowedNow, 500)
        self.assertEqual(svc.usage.remaining("CLI-DASHBOARD").exempt, True)

    def test_notifications_go_through_the_mailer_without_any_content(self):
        srv, svc, _api = self.build({CUST: {"planId": "equipe"}})
        pid = svc.create_project(CUST, "Creer le site vitrine de mon cabinet", "chloe")["projectId"]
        self.assertTrue(svc.send_notification(pid, "input_needed"))
        self.assertEqual(len(srv.sent), 1)
        to, subject, html, text = srv.sent[0]
        self.assertEqual(to, "client@test.example")
        self.assertIn(f"https://app.test.example/#projet/{pid}", text)
        self.assertNotIn("Creer le site vitrine", html + text)                               # jamais le contenu du projet dans un e-mail
        self.assertFalse(svc.send_notification(pid, "input_needed"))                         # une seule fois par type, projet et heure

    def test_a_declared_notification_opt_out_sends_nothing(self):
        srv, svc, _api = self.build({CUST: {"planId": "equipe"}})
        srv.get_company_profile = lambda c: {"notifyProjects": False}
        pid = svc.create_project(CUST, "Un projet de test pour les notifications", "chloe")["projectId"]
        self.assertFalse(svc.send_notification(pid, "done"))
        self.assertEqual(srv.sent, [])

    def test_allowlist_restricts_the_rollout(self):
        _srv, svc, _api = self.build({CUST: {"planId": "equipe"}}, env={"BK_PROJECTS": "1", "BK_PROJECTS_ALLOW": "CLI-CUST-BBBBBBBB, CLI-CUST-CCCCCCCC"})
        with self.assertRaises(Exception) as cm:
            svc.create_project(CUST, "Creer un site", "chloe")
        self.assertEqual(cm.exception.code, "PROJECT_NOT_IN_PLAN")
        _srv, svc2, _api = self.build({CUST: {"planId": "equipe"}}, env={"BK_PROJECTS": "1", "BK_PROJECTS_ALLOW": CUST})
        self.assertTrue(svc2.create_project(CUST, "Creer un site vitrine", "chloe")["projectId"])

    def test_the_runner_limits_come_from_the_environment(self):
        saved = {k: os.environ.get(k) for k in ("BK_PROJECT_STEPS_GLOBAL", "BK_PROJECT_STEPS_PER_CLIENT")}
        self.addCleanup(lambda: [os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v) for k, v in saved.items()])
        os.environ.update(BK_PROJECT_STEPS_GLOBAL="1", BK_PROJECT_STEPS_PER_CLIENT="2")
        _srv, svc, _api = self.build({})
        self.assertEqual((svc.limits["runners"]["global"], svc.limits["runners"]["perClient"]), (1, 2))
        os.environ["BK_PROJECT_STEPS_GLOBAL"] = "abc"
        _srv, svc2, _api = self.build({})
        self.assertEqual(svc2.limits["runners"]["global"], 2)                                # valeur invalide : le défaut sûr


if __name__ == "__main__":
    unittest.main(verbosity=2)
