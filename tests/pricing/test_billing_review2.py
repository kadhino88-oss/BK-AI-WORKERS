# -*- coding: utf-8 -*-
"""Regressions de la 2e revue (branche ws/hire-final, fixes du 2026-10-19), dans le vrai dashboard/server.py :

  - la grace d'un forfait sur facture n'ouvre PAS une fenetre mensuelle neuve (un mois de credits que personne n'a paye) ;
  - un Pro / Scale sans preuve de paiement (ancienne simulation gratuite) n'est pas un ancien abonne a vie ;
  - reconduire un Enterprise garde son plafond contractuel ; un forfait arrive a echeance retient ses Workers et son plafond ;
  - les abonnements Stripe sont relus (resilie, impaye, arrete cote Stripe) : un forfait Stripe se termine quand le client ne paie plus ;
  - le client Stripe du compte est reutilise par les Checkout Sessions suivantes (credit de prorata) ;
  - POST /api/billing/stripe-confirm : identifiant verifie avant tout PowerShell, plafond par IP, corps borne ; stripe-status mis en cache ;
    le nombre d'appels PowerShell simultanes est borne ;
  - suppression de compte apres resiliation ; corps JSON mal type : une reponse 400, jamais une connexion coupee.

Aucun reseau, aucun modele, aucun secret (le pont Stripe est remplace).   python tests/pricing/test_billing_review2.py
"""
import datetime
import json
import os
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import A, B, C, NOW, add_account, reset, write_billing  # noqa: E402
from test_billing_review import Fixture, ROOT, at, confirmation, inst, server, write_task_record  # noqa: E402,F401

REAL_RUN_STRIPE_BRIDGE = server.run_stripe_bridge      # Fixture.setUp remplace server.run_stripe_bridge par un faux : on garde le vrai (plafond d'appels simultanes)


class GraceWindow(Fixture):
    def test_the_grace_days_do_not_open_a_fresh_monthly_quota(self):
        # Reproduction de la revue : Pro active sur facture le 12/10 (paye jusqu'au 12/11), quota epuise le 20/10 ; le 14/11 (grace de 5 jours) la fenetre
        # suivante s'ouvrait sur 1250 credits neufs, puis un retardataire reconduit recevait une troisieme allocation.
        self.assertEqual(server.set_client_plan(A, "pro")[1], 200)
        write_task_record(A, 1250, "2026-10-20T00:00:00Z")
        self.assertEqual(server.get_billing(A)["creditsRemaining"], 0)
        server._utcnow = lambda: NOW.replace(month=11, day=14)
        out = server.get_billing(A)
        self.assertEqual((out["planId"], out["creditsUsed"], out["creditsRemaining"]), ("pro", 1250, 0))
        self.assertIsNotNone(server.subscription_blocks_mission(A, "approfondi"))
        self.assertTrue(out["awaitingInvoice"])                                  # rien ne se renouvelle tant que la facture suivante n'est pas reglee
        server._utcnow = lambda: NOW.replace(month=11, day=18)                   # la grace est finie : Essai, l'essai n'est pas renouvelable
        out = server.get_billing(A)
        self.assertEqual((out["planId"], out["creditsRemaining"]), ("essai", 0))

    def test_missions_run_during_the_grace_days_count_on_the_last_paid_window(self):
        server.set_client_plan(A, "pro")
        server._utcnow = lambda: NOW.replace(month=11, day=14)
        write_task_record(A, 100, "2026-11-13T00:00:00Z")                        # en pleine grace
        out = server.get_billing(A)
        self.assertEqual((out["creditsUsed"], out["creditsRemaining"]), (100, 1150))

    def test_a_late_payer_regranted_during_the_grace_gets_exactly_one_new_window(self):
        server.set_client_plan(A, "pro")
        write_task_record(A, 1250, "2026-10-20T00:00:00Z")
        server._utcnow = lambda: NOW.replace(month=11, day=14)
        self.assertEqual(server.get_billing(A)["creditsRemaining"], 0)
        server.set_client_plan(A, "pro")                                         # la facture est reglee : une fenetre neuve, payee
        out = server.get_billing(A)
        self.assertEqual((out["creditsUsed"], out["creditsRemaining"]), (0, 1250))
        write_task_record(A, 1250, "2026-11-15T00:00:00Z")
        self.assertEqual(server.get_billing(A)["creditsRemaining"], 0)

    def test_a_multi_month_invoice_still_renews_the_window_each_month(self):
        server.set_client_plan(A, "pro", paid_months=3)
        write_task_record(A, 1250, "2026-10-20T00:00:00Z")
        server._utcnow = lambda: NOW.replace(month=11, day=14)                   # 2e mois paye : fenetre neuve
        out = server.get_billing(A)
        self.assertEqual((out["planId"], out["creditsRemaining"], out["renewsAtUtc"][:10], out["awaitingInvoice"]), ("pro", 1250, "2026-12-12", False))
        server._utcnow = lambda: NOW.replace(year=2027, month=1, day=14)         # 3e mois termine, grace : plus de fenetre neuve
        write_task_record(A, 1250, "2026-12-20T00:00:00Z")
        out = server.get_billing(A)
        self.assertEqual((out["planId"], out["creditsRemaining"], out["awaitingInvoice"]), ("pro", 0, True))

    def test_the_last_paid_month_says_valid_until_not_renewed(self):
        server.set_client_plan(A, "equipe")
        write_task_record(A, 900, "2026-10-13T00:00:00Z")
        msg = server.subscription_blocks_mission(A)
        self.assertIn("valable jusqu'au 12 novembre 2026", msg)
        self.assertNotIn("renouvelés le", msg)


class EarlyRenewal(Fixture):
    def test_renewing_early_adds_to_the_paid_period_instead_of_overwriting_it(self):
        # 2e revue : paidUntilUtc = maintenant + mois, donc renouveler 10 jours en avance faisait perdre ces 10 jours payes (et rouvrait une fenetre de
        # credits au milieu du mois).
        server.set_client_plan(A, "equipe")                                      # 12/10 -> 12/11
        server.grant_workers(B, "solo", ["alex"])                                # idem pour B
        write_task_record(A, 900, "2026-10-13T00:00:00Z")
        server._utcnow = lambda: at(days=10)                                     # 22/10
        res, st = server.set_client_plan(A, "equipe")
        self.assertEqual((st, res["paidUntilUtc"][:10]), (200, "2026-12-12"))     # 12/11 + 1 mois, pas 22/11
        out = server.get_billing(A)
        self.assertEqual(out["creditsRemaining"], 0)                             # pas de quota neuf en milieu de fenetre
        self.assertEqual(server._billing_load(A)["cycleStartUtc"], "2026-10-12T12:00:00Z")
        server._utcnow = lambda: NOW.replace(month=11, day=14)                   # la fenetre suivante s'ouvre a la date d'ancrage
        self.assertEqual(server.get_billing(A)["creditsRemaining"], 900)
        res, st = server.grant_workers(B, "solo", ["alex"], paid_months=2)       # B etait en grace depuis le 12/11 : la periode repart de maintenant
        self.assertEqual(res["paidUntilUtc"][:10], "2027-01-14")

    def test_a_plan_change_or_a_renewal_after_the_end_starts_from_now(self):
        server.set_client_plan(A, "equipe")
        server._utcnow = lambda: at(days=5)
        res, st = server.set_client_plan(A, "pro")                               # autre forfait : une periode neuve, payee a partir de maintenant
        self.assertEqual(res["paidUntilUtc"][:10], "2026-11-17")
        self.assertEqual(server._billing_load(A)["cycleStartUtc"], "2026-10-17T12:00:00Z")


class UnprovenLegacyPlans(Fixture):
    def old_simulation(self, client, plan):
        write_billing(server, client, plan, gridVersion=None, stripeSubscriptionId=None,
                      history=[{"dateUtc": "2026-09-01T00:00:00Z", "event": f"Changement de plan : Essai -> {plan.title()} (simulation, aucun paiement reel)."}])

    def test_a_free_simulated_pro_or_scale_is_not_grandfathered_for_ever(self):
        self.old_simulation(A, "scale")
        self.old_simulation(B, "pro")
        out = server.get_billing(A)
        self.assertEqual((out["planId"], out["creditsIncluded"], out["grandfathered"]), ("scale", 4000, False))
        self.assertEqual(server.get_billing(B)["creditsIncluded"], 1250)            # grille actuelle, pas les 1500 d'origine
        self.assertEqual(server.normalize_level(None, B), "equilibre")
        state = server._billing_load(A)
        self.assertEqual((state["gridVersion"], state["paidUntilUtc"][:10]), (server.GRID_VERSION, "2026-11-11"))      # 30 jours pour regulariser
        self.assertTrue(any("sans paiement vérifiable" in h["event"] for h in out["history"]))
        server._utcnow = lambda: at(days=29)
        self.assertEqual(server.get_billing(A)["planId"], "scale")
        server._utcnow = lambda: at(days=36)                                        # 30 jours + 5 de grace
        self.assertEqual(server.get_billing(A)["planId"], "essai")

    def test_an_owner_reactivation_after_payment_keeps_the_plan(self):
        self.old_simulation(A, "pro")
        server.get_billing(A)
        server._utcnow = lambda: at(days=20)
        self.assertEqual(server.set_client_plan(A, "pro")[1], 200)               # facture reglee : activation par BK Entreprise
        server._utcnow = lambda: at(days=40)
        self.assertEqual(server.get_billing(A)["planId"], "pro")

    def test_real_subscribers_stay_grandfathered_and_are_not_given_an_end_date(self):
        write_billing(server, A, "pro", gridVersion=None, stripeSubscriptionId="sub_old")
        write_billing(server, B, "scale", gridVersion=None,
                      history=[{"dateUtc": "2026-09-01T00:00:00Z", "event": "Changement de plan : Essai -> Scale (paiement Stripe confirme)."}])
        for client, credits in ((A, 1500), (B, 4000)):
            out = server.get_billing(client)
            self.assertEqual((out["creditsIncluded"], out["grandfathered"], out["paidUntilUtc"]), (credits, True, None))
        server._utcnow = lambda: at(days=400)
        self.assertEqual((server.get_billing(A)["planId"], server.get_billing(B)["planId"]), ("pro", "scale"))

    def test_the_owner_account_and_other_plans_are_left_alone(self):
        write_billing(server, server.DASHBOARD_CLIENT_ID, "scale", gridVersion=None)
        server.get_billing(server.DASHBOARD_CLIENT_ID)
        self.assertNotIn("paidUntilUtc", server._billing_load(server.DASHBOARD_CLIENT_ID))
        write_billing(server, A, "equipe", gridVersion=None)
        self.assertIsNone(server.get_billing(A)["paidUntilUtc"])


class EnterpriseRenewal(Fixture):
    def test_renewing_an_enterprise_contract_keeps_its_cap(self):
        server.set_client_plan(A, "enterprise", contract_credits=25000)
        self.assertEqual(server.get_billing(A)["creditsIncluded"], 25000)
        server._utcnow = lambda: at(days=28)
        res, st = server.set_client_plan(A, "enterprise", paid_months=1)         # la facture suivante, sans repeter le plafond
        self.assertEqual((st, res["credits"]), (200, 25000))
        res, st = server.set_client_plan(A, "enterprise", contract_credits=40000)  # un nouveau plafond explicite est pris
        self.assertEqual((st, res["credits"]), (200, 40000))
        server.set_client_plan(B, "enterprise")                                  # premiere activation sans plafond : le defaut
        self.assertEqual(server.get_billing(B)["creditsIncluded"], server.ENTERPRISE_DEFAULT_CREDITS)

    def test_a_late_renewal_after_the_lapse_restores_the_contract(self):
        server.grant_workers(C, "trio", ["alex", "nora"])
        server.set_client_plan(A, "enterprise", contract_credits=25000)
        server._utcnow = lambda: at(days=60)
        out = server.get_billing(A)
        self.assertEqual(out["planId"], "essai")
        self.assertTrue(any(f"Plafond contractuel : {server._fr_int(25000)} crédits" in h["event"] for h in out["history"]))
        res, st = server.set_client_plan(A, "enterprise")                        # retardataire : le contrat revient avec son plafond
        self.assertEqual((st, res["credits"]), (200, 25000))
        self.assertNotIn("lapsedFrom", server._billing_load(A))
        # un autre forfait entre-temps : le plafond d'un ancien contrat ne revient pas tout seul
        server.set_client_plan(A, "pro")
        res, st = server.set_client_plan(A, "enterprise")
        self.assertEqual(res["credits"], server.ENTERPRISE_DEFAULT_CREDITS)

    def test_the_lapse_remembers_the_hired_workers(self):
        server.grant_workers(A, "trio", ["alex", "nora"])
        server._utcnow = lambda: at(days=60)
        out = server.get_billing(A)
        self.assertEqual((out["planId"], out["hiredWorkers"]), ("essai", []))
        self.assertTrue(any("Workers embauchés : alex, nora" in h["event"] for h in out["history"]))
        self.assertEqual(server._billing_load(A)["lapsedFrom"]["hiredWorkers"], ["alex", "nora"])


class StripeCustomerReuse(Fixture):
    def test_the_stripe_customer_of_the_account_is_stored_and_reused_by_the_next_checkout(self):
        conf = confirmation("solo", "sub_1", "cs_1")
        conf["CustomerId"] = "cus_ABC123"
        self.assertEqual(server.activate_checkout_plan(conf)[1], 200)
        self.assertEqual(server._billing_load(A)["stripeCustomerId"], "cus_ABC123")
        server.select_billing_plan(A, "trio", "month")
        create = [kw for action, kw in self.bridge_calls if action == "create-checkout"]
        self.assertEqual(create[-1].get("customer_id"), "cus_ABC123")
        server.cancel_billing_plan(A)
        server._utcnow = lambda: at(days=40)                                     # lapse : le client Stripe survit au forfait
        self.assertEqual(server._billing_load(A)["stripeCustomerId"], "cus_ABC123")

    def test_a_customer_stripe_no_longer_knows_falls_back_to_a_fresh_checkout(self):
        write_billing(server, A, "solo", stripeCustomerId="cus_GONE", stripeSubscriptionId="sub_1")
        seen = []
        orig = self.fake_bridge

        def picky(action, **kw):
            if action == "create-checkout":
                seen.append(kw.get("customer_id"))
                if kw.get("customer_id"):
                    return {"Status": "ERROR", "Detail": "No such customer"}
            return orig(action, **kw)
        server.run_stripe_bridge = picky
        payload, status = server.select_billing_plan(A, "trio", "month")
        self.assertEqual((status, payload.get("checkoutUrl")), (200, "https://checkout.example/test"))
        self.assertEqual(seen, ["cus_GONE", None])

    def test_a_malformed_customer_id_is_never_stored_or_sent(self):
        conf = confirmation("solo", "sub_1", "cs_1")
        conf["CustomerId"] = "cus_x; -Command evil"
        server.activate_checkout_plan(conf)
        self.assertNotIn("stripeCustomerId", server._billing_load(A))


class StripeFollowUp(Fixture):
    def setUp(self):
        super().setUp()
        self.sub = {"Status": "SUCCESS", "SubscriptionStatus": "active", "CancelAtPeriodEnd": False, "CurrentPeriodEnd": "2026-11-12T12:00:00Z"}
        self.sub_calls = []

    def fake_bridge(self, action, **kw):
        if action == "get-subscription":
            self.sub_calls.append(kw.get("subscription_id"))
            return dict(self.sub)
        return super().fake_bridge(action, **kw)

    def pro(self):
        self.activate("pro", "sub_1", "cs_1")

    def test_an_unpaid_or_cancelled_subscription_ends_the_plan(self):
        for status in ("canceled", "unpaid", "incomplete_expired"):
            reset(server)
            add_account(server, A)
            self.pro()
            self.sub = {"Status": "SUCCESS", "SubscriptionStatus": status}
            self.assertEqual(server.sync_stripe_subscription(A, force=True), "ended", status)
            state = server._billing_load(A)
            self.assertEqual((state["planId"], state["stripeSubscriptionId"]), ("essai", None), status)
            self.assertIn("arrêté chez Stripe", state["history"][-1]["event"])

    def test_a_cancelled_subscription_does_not_refill_the_trial(self):
        self.pro()
        write_task_record(A, 1250, "2026-10-12T12:00:01Z")
        self.sub = {"Status": "SUCCESS", "SubscriptionStatus": "canceled"}
        server.sync_stripe_subscription(A, force=True)
        out = server.get_billing(A)
        self.assertEqual((out["planId"], out["creditsRemaining"]), ("essai", 0))

    def test_a_subscription_stripe_no_longer_knows_ends_the_plan(self):
        self.pro()
        self.sub = {"Status": "ERROR", "Detail": "404", "HttpStatus": 404}
        self.assertEqual(server.sync_stripe_subscription(A, force=True), "ended")
        self.assertEqual(server._billing_load(A)["planId"], "essai")

    def test_a_stripe_error_changes_nothing(self):
        self.pro()
        self.sub = {"Status": "ERROR", "Detail": "STRIPE_BRIDGE_TIMEOUT"}
        self.assertEqual(server.sync_stripe_subscription(A, force=True), "error")
        self.assertEqual(server._billing_load(A)["planId"], "pro")

    def test_a_cancellation_made_in_the_stripe_dashboard_is_picked_up(self):
        self.pro()
        self.sub = {"Status": "SUCCESS", "SubscriptionStatus": "active", "CancelAtPeriodEnd": True, "CurrentPeriodEnd": "2026-11-12T12:00:00Z"}
        self.assertEqual(server.sync_stripe_subscription(A, force=True), "cancel_scheduled")
        out = server.get_billing(A)
        self.assertEqual((out["planId"], out["cancelAtPeriodEnd"], out["paidUntilUtc"]), ("pro", True, "2026-11-12T12:00:00Z"))
        server._utcnow = lambda: NOW.replace(month=11, day=13)
        self.assertEqual(server.get_billing(A)["planId"], "essai")               # le terme est passe
        # et inversement : la resiliation est annulee chez Stripe
        reset(server)
        add_account(server, A)
        self.pro()
        server._utcnow = lambda: NOW
        server.cancel_billing_plan(A)
        self.sub = {"Status": "SUCCESS", "SubscriptionStatus": "active", "CancelAtPeriodEnd": False}
        self.assertEqual(server.sync_stripe_subscription(A, force=True), "resumed")
        self.assertFalse(server.get_billing(A)["cancelAtPeriodEnd"])

    def test_a_late_payment_keeps_the_access_and_is_recorded_once(self):
        self.pro()
        self.sub = {"Status": "SUCCESS", "SubscriptionStatus": "past_due", "CancelAtPeriodEnd": False}
        self.assertEqual(server.sync_stripe_subscription(A, force=True), "past_due")
        self.assertEqual(server.sync_stripe_subscription(A, force=True), "past_due")
        out = server.get_billing(A)
        self.assertEqual(out["planId"], "pro")
        self.assertEqual(sum("en retard chez Stripe" in h["event"] for h in out["history"]), 1)
        self.sub = {"Status": "SUCCESS", "SubscriptionStatus": "active", "CancelAtPeriodEnd": False}
        server.sync_stripe_subscription(A, force=True)
        self.assertNotIn("paymentIssue", server._billing_load(A))

    def test_each_subscription_is_read_at_most_once_per_interval(self):
        self.pro()
        self.assertEqual(server.sync_stripe_subscription(A), "ok")
        self.assertEqual(server.sync_stripe_subscription(A), "recent")
        self.assertEqual(self.sub_calls, ["sub_1"])
        server._utcnow = lambda: NOW + datetime.timedelta(hours=7)
        self.assertEqual(server.sync_stripe_subscription(A), "ok")
        self.assertEqual(len(self.sub_calls), 2)

    def test_sync_all_reads_only_clients_with_a_subscription(self):
        self.pro()
        server.set_client_plan(B, "equipe")                                      # sur facture : pas d'abonnement Stripe
        counts = server.sync_all_stripe_subscriptions(force=True)
        self.assertEqual(counts, {"ok": 1})
        self.assertEqual(self.sub_calls, ["sub_1"])
        self.assertEqual(server.sync_stripe_subscription(B), "no_subscription")


class AccountDeletionAfterCancel(Fixture):
    def test_a_cancelled_subscription_no_longer_blocks_the_deletion_of_the_account(self):
        self.activate("pro", "sub_1", "cs_1")
        self.assertEqual(server.delete_account(A, "motdepasse-test"), "ACTIVE_SUBSCRIPTION")        # encore renouvele : a resilier d'abord
        server.cancel_billing_plan(A)
        self.assertIsNone(server.delete_account(A, "motdepasse-test"))
        self.assertFalse(any(a.get("clientId") == A for a in server._load_accounts()))

    def test_the_owner_can_activate_an_invoice_plan_over_a_cancelled_subscription_but_not_over_a_live_one(self):
        self.activate("pro", "sub_1", "cs_1")
        self.assertEqual(server.set_client_plan(A, "equipe")[1], 409)
        self.assertEqual(server.grant_workers(A, "solo", ["alex"])[1], 409)
        server.cancel_billing_plan(A)
        res, st = server.set_client_plan(A, "equipe")
        self.assertEqual(st, 200, res)
        state = server._billing_load(A)
        self.assertEqual((state["planId"], state["stripeSubscriptionId"], state.get("cancelAtPeriodEnd")), ("equipe", None, None))


class HttpGuards(Fixture):
    def setUp(self):
        super().setUp()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.token_a = server.account_create_session({"clientId": A, "email": "a@mail-test.example"})
        self.gate = server.gate_create_session()
        server._STRIPE_STATUS_CACHE.update(at=0.0, ttl=0, result=None)
        self.confirm_calls = []

    def fake_bridge(self, action, **kw):
        if action == "confirm":
            self.confirm_calls.append(kw.get("session_id"))
            return {"Status": "ERROR", "Detail": "No such session"}
        if action == "status":
            self.status_calls = getattr(self, "status_calls", 0) + 1
            return {"Configured": True, "Live": False, "PublishableKey": "pk_test_x"}
        return super().fake_bridge(action, **kw)

    def http(self, method, path, body=None, token=None, gate=False, ip="198.51.100.7", raw=None):
        headers = {"Content-Type": "application/json", "X-Forwarded-For": ip}
        cookies = []
        if token:
            cookies.append("bk_account=" + token)
        if gate:
            cookies.append("bk_session=" + self.gate)
        if cookies:
            headers["Cookie"] = "; ".join(cookies)
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode("utf-8"))

    def test_stripe_confirm_checks_the_session_id_before_any_powershell(self):
        for bad in ("x7", "cs_", "cs_abc", "cs_" + "a" * 300, "cs_test_a b c d", "../cs_test_aaaaaaaa", "CS_test_aaaaaaaa"):
            st, out = self.http("POST", "/api/billing/stripe-confirm", {"sessionId": bad})
            self.assertEqual((st, out["error"]), (400, "INVALID_SESSION_ID"), bad)
        for not_a_string in (5, ["cs_test_aaaaaaaa"], None, {"a": 1}, True):
            st, out = self.http("POST", "/api/billing/stripe-confirm", {"sessionId": not_a_string})
            self.assertEqual((st, out["error"]), (400, "SESSION_ID_REQUIRED"), not_a_string)
        self.assertEqual(self.confirm_calls, [])                                 # aucun processus PowerShell lance

    def test_stripe_confirm_is_throttled_per_ip_and_bounded(self):
        limit = server.HIRE_LIMITS["stripe-confirm"][0]
        for i in range(limit):
            st, out = self.http("POST", "/api/billing/stripe-confirm", {"sessionId": "cs_test_aaaaaaaa" + str(i)}, ip="203.0.113.9")
            self.assertEqual((st, out["error"]), (400, "STRIPE_CONFIRM_FAILED"))
        st, out = self.http("POST", "/api/billing/stripe-confirm", {"sessionId": "cs_test_aaaaaaaaZ"}, ip="203.0.113.9")
        self.assertEqual((st, out["error"]), (429, "RATE_LIMITED"))
        self.assertEqual(len(self.confirm_calls), limit)                         # le (limit+1)e n'a pas lance de pont
        st, out = self.http("POST", "/api/billing/stripe-confirm", {"sessionId": "cs_test_aaaaaaaa1"}, ip="203.0.113.10")      # une autre adresse n'est pas touchee
        self.assertEqual(st, 400)
        self.assertEqual(self.http("POST", "/api/billing/stripe-confirm", raw=b'{"sessionId": "' + b"a" * 5000 + b'"}')[0], 413)

    def test_stripe_status_is_cached_for_everyone(self):
        for _ in range(6):
            st, out = self.http("GET", "/api/billing/stripe-status")
            self.assertEqual((st, out["Configured"]), (200, True))
        self.assertEqual(self.status_calls, 1)

    def test_the_bridge_runs_at_most_three_powershell_at_once(self):
        running, peak, lock = [0], [0], threading.Lock()

        def slow(action, **kw):
            with lock:
                running[0] += 1
                peak[0] = max(peak[0], running[0])
            time.sleep(0.15)
            with lock:
                running[0] -= 1
            return {"Status": "SUCCESS"}
        orig_unbounded = server._run_stripe_bridge
        server._run_stripe_bridge = slow
        try:
            threads = [threading.Thread(target=REAL_RUN_STRIPE_BRIDGE, args=("status",)) for _ in range(12)]
            [t.start() for t in threads]
            [t.join() for t in threads]
        finally:
            server._run_stripe_bridge = orig_unbounded
        self.assertLessEqual(peak[0], 3)
        self.assertGreaterEqual(peak[0], 2)

    def test_badly_typed_bodies_get_a_400_not_a_dropped_connection(self):
        for body in ([1, 2], "x", None, 5, {"planId": ["pro"]}, {"planId": 5}, {"interval": ["year"]}):
            st, out = self.http("POST", "/api/billing/plan", body, token=self.token_a)
            self.assertIn(st, (400, 403), body)
            self.assertIn("error", out)
        st, out = self.http("POST", "/api/billing/plan", raw=b"not json at all", token=self.token_a)
        self.assertEqual(st, 400)

    def test_owner_routes_answer_400_to_an_unreadable_body(self):
        for path in ("/api/admin/grant-workers", "/api/admin/set-plan", "/api/admin/stripe-sync"):
            for raw in (b"not json", b"[1,2]", b"null", b'"x"'):
                st, out = self.http("POST", path, raw=raw, gate=True)
                self.assertEqual((st, out["error"]), (400, "INVALID_JSON"), (path, raw))
        st, out = self.http("POST", "/api/admin/set-plan", {"clientId": A, "planId": "pro"})             # sans la porte : refuse
        self.assertEqual(st, 401)

    def test_the_owner_can_force_a_stripe_follow_up(self):
        self.activate("pro", "sub_1", "cs_1")
        orig = self.fake_bridge
        server.run_stripe_bridge = lambda action, **kw: ({"Status": "SUCCESS", "SubscriptionStatus": "canceled"} if action == "get-subscription" else orig(action, **kw))
        st, out = self.http("POST", "/api/admin/stripe-sync", {"clientId": A}, gate=True)
        self.assertEqual((st, out["result"]), (200, "ended"))
        self.assertEqual(self.http("POST", "/api/admin/stripe-sync", {"clientId": "../x"}, gate=True)[0], 404)
        st, out = self.http("POST", "/api/admin/stripe-sync", {}, gate=True)
        self.assertEqual((st, out["results"]), (200, {}))

    def test_cancel_over_http_answers_503_when_stripe_is_down(self):
        self.activate("pro", "sub_1", "cs_1")
        self.cancel_ok = False
        st, out = self.http("POST", "/api/billing/cancel", token=self.token_a)
        self.assertEqual((st, out["error"]), (503, "STRIPE_UNAVAILABLE"))
        self.assertEqual(self.http("GET", "/api/billing", token=self.token_a)[1]["planId"], "pro")


if __name__ == "__main__":
    ok = unittest.main(verbosity=2, exit=False).result.wasSuccessful()
    sys.exit(0 if ok else 1)
