# -*- coding: utf-8 -*-
"""Regressions de la revue du 2026-10-13 (branche ws/hire-final) sur la facturation, dans le vrai dashboard/server.py :

  - confirmation Stripe IDEMPOTENTE : rejouer la meme Checkout Session ne rend ni quota neuf, ni delai d'echange de Worker efface, ni forfait
    resilie ressuscite ; l'abonnement doit etre actif chez Stripe ; un autre compte connecte est refuse ;
  - resiliation en FIN DE PERIODE (CGV article 6) : le forfait paye reste actif jusqu'au terme, puis retombe a l'Essai ; rythme de paiement
    (mensuel / annuel) conserve pour proposer la meme montee en gamme ;
  - forfait active SUR FACTURE : periode payee (mois factures + grace), puis retour a l'Essai tant que le proprietaire ne le reconduit pas ;
  - anciens abonnes Pro / Scale : credits d'origine et niveau Rapide par defaut tant qu'ils ne changent pas de forfait ;
  - credits : une mission refusee ou degradee (fournisseur d'IA indisponible) ne coute rien.

Aucun reseau, aucun modele, aucun secret (le pont Stripe est remplace).   python tests/pricing/test_billing_review.py
"""
import datetime
import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import A, B, C, NOW, add_account, load_server, reset, write_billing  # noqa: E402

server, ROOT = load_server("bk_server_billing_review")
inst = server.inst


def confirmation(plan, sub, session, client=A, status="active", interval="month"):
    """Ce que Stripe-Bridge.ps1 -Action confirm renvoie (session relue chez Stripe), plus le SessionId que la route y ajoute."""
    return {"Status": "SUCCESS", "Paid": True, "PlanId": plan, "ClientId": client, "SubscriptionId": sub, "SubscriptionStatus": status,
            "SessionId": session, "Interval": interval, "PaymentStatus": "paid"}


def write_task_record(client, credits, created, **extra):
    os.makedirs(server.TASKS_DIR, exist_ok=True)
    tid = "%032X" % (len(os.listdir(server.TASKS_DIR)) + 1)
    rec = {"TaskId": f"TASK-{tid}", "ClientId": client, "CreatedAtUtc": created, "Status": "EXECUTED"}
    if credits is not None:
        rec["Credits"] = credits
    rec.update(extra)
    with open(os.path.join(server.TASKS_DIR, f"TASK-{tid}.json"), "w", encoding="utf-8") as f:
        json.dump(rec, f)


def at(days=0, months=0):
    """Date figee decalee (la facturation lit server._utcnow)."""
    dt = NOW + datetime.timedelta(days=days)
    return server._add_months(dt, months) if months else dt


class Fixture(unittest.TestCase):
    def setUp(self):
        reset(server)
        server.INSTALLS = inst.InstallationStore(ROOT)
        server.HIRE_RATE.clear()
        server.run_stripe_bridge = self.fake_bridge
        self.bridge_calls = []
        self.stripe_configured = True
        self.cancelled = []
        self.cancel_calls = []
        self.cancel_ok = True
        self.cancel_gone = False         # Stripe repond 404 : l'abonnement n'existe plus
        self.resume_calls = []
        self.period_end = "2026-11-02T08:00:00Z"
        add_account(server, A)
        add_account(server, B)

    def fake_bridge(self, action, **kw):
        self.bridge_calls.append((action, kw))
        if action == "status":
            return {"Configured": self.stripe_configured}
        if action == "create-checkout":
            return {"Status": "SUCCESS", "CheckoutUrl": "https://checkout.example/test", "SessionId": "cs_test_1"}
        if action == "cancel-subscription":
            self.cancelled.append(kw.get("subscription_id"))
            self.cancel_calls.append(kw)
            if self.cancel_gone:
                return {"Status": "ERROR", "Detail": "Response status code does not indicate success: 404 (Not Found).", "HttpStatus": 404}
            if not self.cancel_ok:
                return {"Status": "ERROR", "Detail": "boom"}
            return {"Status": "SUCCESS", "CurrentPeriodEnd": self.period_end} if kw.get("at_period_end") else {"Status": "SUCCESS"}
        if action == "resume-subscription":
            self.resume_calls.append(kw.get("subscription_id"))
            return {"Status": "SUCCESS", "SubscriptionStatus": "active", "CancelAtPeriodEnd": False}
        return {"Status": "ERROR"}

    def activate(self, plan, sub, session, client=A, **kw):
        return server.activate_checkout_plan(confirmation(plan, sub, session, client=client, **kw))


class ReplayedConfirmation(Fixture):
    def test_replaying_a_paid_session_gives_no_fresh_quota_and_keeps_the_swap_delay(self):
        payload, status = self.activate("solo", "sub_1", "cs_1")
        self.assertEqual((status, payload["planId"], payload["creditsRemaining"]), (200, "solo", 250))
        self.assertEqual(server.hire_worker(A, "alex")[1], 200)
        write_task_record(A, 250, "2026-10-12T12:00:01Z")                        # le client a consomme tout son quota
        self.assertEqual(server.get_billing(A)["creditsRemaining"], 0)
        body, st = server.hire_worker(A, "nora", "alex")                          # un echange de Worker : le delai de 30 jours demarre
        self.assertEqual(st, 200, body)
        before = server._billing_load(A)
        self.assertTrue(before["lastWorkerSwapAtUtc"])
        for _ in range(3):                                                        # rejeu de la confirmation (POST /api/billing/stripe-confirm sans connexion)
            payload, status = self.activate("solo", "sub_1", "cs_1")
            self.assertEqual((status, payload.get("alreadyConfirmed")), (200, True))
            self.assertEqual((payload["creditsUsed"], payload["creditsRemaining"]), (250, 0))
            after = server._billing_load(A)
            self.assertEqual(after["lastWorkerSwapAtUtc"], before["lastWorkerSwapAtUtc"])
            self.assertEqual((after["cycleStartUtc"], after["hiredWorkers"], after["stripeSessions"]),
                             (before["cycleStartUtc"], ["nora"], ["cs_1"]))
        body, st = server.hire_worker(A, "maya", "nora")                          # le delai de 30 jours tient toujours : pas de rotation entre les Workers
        self.assertEqual((st, body["error"]), (409, "SWAP_COOLDOWN"))
        self.assertIsNotNone(server.subscription_blocks_mission(A))

    def test_replaying_without_a_session_id_is_still_a_no_op_for_the_same_subscription(self):
        self.activate("trio", "sub_9", "cs_9")
        server.hire_worker(A, "alex")
        write_task_record(A, 500, "2026-10-12T12:00:01Z")
        legacy = confirmation("trio", "sub_9", "cs_9")
        legacy.pop("SessionId")                                                   # ancienne confirmation, sans identifiant de session
        payload, status = server.activate_checkout_plan(legacy)
        self.assertEqual((status, payload.get("alreadyConfirmed"), payload["creditsRemaining"]), (200, True, 0))

    def test_a_cancelled_subscription_is_not_resurrected_by_a_replay(self):
        self.activate("solo", "sub_1", "cs_1")
        server.cancel_billing_plan(A)
        server._utcnow = lambda: at(days=40)                                     # la periode payee est finie : retour a l'Essai
        self.assertEqual(server.get_billing(A)["planId"], "essai")
        payload, status = self.activate("solo", "sub_1", "cs_1")
        self.assertEqual((status, payload["planId"], payload.get("alreadyConfirmed")), (200, "essai", True))
        self.assertEqual(server._billing_load(A)["planId"], "essai")
        # resiliation IMMEDIATE (Stripe ne connait plus l'abonnement : 404) : le rejeu ne ressuscite rien non plus
        reset(server)
        self.cancel_gone = True
        add_account(server, A)
        self.activate("solo", "sub_2", "cs_2")
        self.assertEqual(server.cancel_billing_plan(A)["planId"], "essai")
        payload, status = self.activate("solo", "sub_2", "cs_2")
        self.assertEqual((payload["planId"], payload.get("alreadyConfirmed")), ("essai", True))

    def test_an_old_session_cannot_downgrade_or_cancel_the_live_subscription(self):
        self.activate("solo", "sub_1", "cs_1")
        self.activate("trio", "sub_2", "cs_2")                                   # montee en gamme : sub_1 est annule chez Stripe
        self.assertEqual(self.cancelled, ["sub_1"])
        payload, status = self.activate("solo", "sub_1", "cs_1")                 # rejeu de la premiere session
        self.assertEqual((status, payload["planId"], payload.get("alreadyConfirmed")), (200, "trio", True))
        self.assertEqual(self.cancelled, ["sub_1"])                              # l'abonnement vivant (sub_2) n'a PAS ete annule
        self.assertEqual(server._billing_load(A)["stripeSubscriptionId"], "sub_2")
        # meme si la liste des sessions avait ete perdue, Stripe dit que sub_1 est resilie : rien n'est active
        state = server._billing_load(A)
        state["stripeSessions"] = []
        server._billing_save(state, A)
        payload, status = self.activate("solo", "sub_1", "cs_1", status="canceled")
        self.assertEqual((status, payload["error"]), (409, "SUBSCRIPTION_NOT_ACTIVE"))
        self.assertEqual(server._billing_load(A)["planId"], "trio")

    def test_the_subscription_must_still_be_active_at_stripe(self):
        for bad in ("canceled", "incomplete", "past_due", "unpaid", "", None):
            payload, status = self.activate("pro", "sub_x", "cs_x", status=bad)
            self.assertEqual((status, payload["error"]), (409, "SUBSCRIPTION_NOT_ACTIVE"), bad)
        missing = confirmation("pro", "sub_x", "cs_x")
        missing.pop("SubscriptionStatus")                                        # un pont qui ne dit rien de l'abonnement : on ne devine pas
        self.assertEqual(server.activate_checkout_plan(missing)[1], 409)
        self.assertEqual(server._billing_load(A)["planId"], "essai")
        payload, status = self.activate("pro", "sub_x", "cs_x", status="trialing")
        self.assertEqual((status, payload["planId"]), (200, "pro"))

    def test_the_session_must_belong_to_the_connected_account(self):
        conf = confirmation("solo", "sub_1", "cs_1", client=A)
        payload, status = server.activate_checkout_plan(conf, fallback_client_id=B)      # le cookie est celui d'un autre compte
        self.assertEqual((status, payload["error"]), (403, "SESSION_CLIENT_MISMATCH"))
        self.assertEqual(server._billing_load(A)["planId"], "essai")
        self.assertEqual(server._billing_load(B)["planId"], "essai")
        payload, status = server.activate_checkout_plan(conf, fallback_client_id=A)      # son propre compte : normal
        self.assertEqual((status, payload["planId"]), (200, "solo"))
        old = confirmation("pro", "sub_o", "cs_o", client=None)                          # ancienne session sans metadata : le cookie fait foi
        payload, status = server.activate_checkout_plan(old, fallback_client_id=B)
        self.assertEqual((status, payload["planId"]), (200, "pro"))
        self.assertEqual(server._billing_load(B)["planId"], "pro")

    def test_a_genuine_new_payment_for_the_same_plan_restarts_the_cycle_but_not_the_swap_delay(self):
        self.activate("solo", "sub_1", "cs_1")
        server.hire_worker(A, "alex")
        server.hire_worker(A, "nora", "alex")
        swap = server._billing_load(A)["lastWorkerSwapAtUtc"]
        server._utcnow = lambda: at(days=3)
        payload, status = self.activate("solo", "sub_2", "cs_2", interval="year")        # nouveau paiement (autre session, autre abonnement)
        self.assertEqual((status, payload.get("alreadyConfirmed")), (200, None))
        state = server._billing_load(A)
        self.assertEqual((state["stripeSubscriptionId"], state["billingInterval"], state["stripeSessions"]), ("sub_2", "year", ["cs_1", "cs_2"]))
        self.assertEqual(state["lastWorkerSwapAtUtc"], swap)                              # meme forfait : le delai d'echange n'est pas efface
        self.assertEqual(state["hiredWorkers"], ["nora"])
        self.assertEqual(self.cancelled, ["sub_1"])

    def test_a_real_plan_change_still_resets_the_swap_delay(self):
        self.activate("solo", "sub_1", "cs_1")
        server.hire_worker(A, "alex")
        server.hire_worker(A, "nora", "alex")
        self.activate("trio", "sub_2", "cs_2")
        self.assertNotIn("lastWorkerSwapAtUtc", server._billing_load(A))

    def test_the_owner_re_granting_the_same_plan_keeps_the_swap_delay(self):
        self.assertEqual(server.grant_workers(A, "solo", ["alex"])[1], 200)
        server.hire_worker(A, "nora", "alex")
        swap = server._billing_load(A)["lastWorkerSwapAtUtc"]
        self.assertEqual(server.grant_workers(A, "solo", ["nora"])[1], 200)               # prochaine facture, meme forfait
        self.assertEqual(server._billing_load(A)["lastWorkerSwapAtUtc"], swap)
        add_account(server, C)
        server.set_client_plan(C, "equipe")
        write_billing(server, C, "equipe", lastWorkerSwapAtUtc="2026-10-01T00:00:00Z")
        server.set_client_plan(C, "equipe")
        self.assertEqual(server._billing_load(C)["lastWorkerSwapAtUtc"], "2026-10-01T00:00:00Z")


class CancelAtPeriodEnd(Fixture):
    def test_cancelling_keeps_the_paid_plan_until_the_end_of_the_period(self):
        self.activate("trio", "sub_1", "cs_1", interval="year")
        server.hire_worker(A, "alex")
        out = server.cancel_billing_plan(A)
        self.assertEqual(self.cancel_calls, [{"subscription_id": "sub_1", "at_period_end": True}])     # resiliation en FIN de periode chez Stripe
        self.assertEqual((out["planId"], out["creditsIncluded"], out["cancelAtPeriodEnd"], out["paidUntilUtc"]), ("trio", 500, True, "2026-11-02T08:00:00Z"))
        self.assertIsNone(out["renewsAtUtc"])                                    # rien ne se renouvelle apres la periode payee
        self.assertEqual(out["hiredWorkers"], ["alex"])
        self.assertTrue(any("reste actif jusqu'au 2 novembre 2026" in h["event"] for h in out["history"]))
        self.assertIsNone(server.worker_block(A, "alex"))                        # le client continue de travailler
        self.assertIsNone(server.subscription_blocks_mission(A))
        server.cancel_billing_plan(A)                                            # deuxieme clic : aucun nouvel appel, aucune nouvelle date
        self.assertEqual(len(self.cancel_calls), 1)
        server._utcnow = lambda: NOW.replace(month=11, day=2, hour=7)            # la veille du terme : toujours Trio
        self.assertEqual(server.get_billing(A)["planId"], "trio")
        server._utcnow = lambda: NOW.replace(month=11, day=2, hour=9)            # le terme est passe : retour a l'Essai
        out = server.get_billing(A)
        self.assertEqual((out["planId"], out["creditsIncluded"], out["hiredWorkers"], out["cancelAtPeriodEnd"]), ("essai", 15, [], False))
        self.assertIsNone(server._billing_load(A)["stripeSubscriptionId"])
        self.assertTrue(any("arrivé à échéance le 2 novembre 2026" in h["event"] for h in out["history"]))
        self.assertEqual(out["creditsRemaining"], 15 - out["creditsUsed"])       # la fenetre n'est pas remise a zero : pas de 15 credits neufs

    def test_an_expired_subscription_does_not_refill_the_trial(self):
        self.activate("solo", "sub_1", "cs_1")
        write_task_record(A, 250, "2026-10-12T12:00:01Z")
        server.cancel_billing_plan(A)
        server._utcnow = lambda: at(days=40)
        out = server.get_billing(A)
        self.assertEqual((out["planId"], out["creditsRemaining"]), ("essai", 0))
        self.assertIsNotNone(server.subscription_blocks_mission(A))

    def test_the_stripe_period_end_falls_back_to_the_billing_window(self):
        self.period_end = None                                                   # Stripe ne donne pas la date (version d'API sans current_period_end)
        self.activate("solo", "sub_1", "cs_1")
        self.assertEqual(server.cancel_billing_plan(A)["paidUntilUtc"][:10], "2026-11-12")      # mensuel : un mois apres l'activation
        reset(server)
        add_account(server, A)
        self.activate("solo", "sub_2", "cs_2", interval="year")
        self.assertEqual(server.cancel_billing_plan(A)["paidUntilUtc"][:10], "2027-10-12")      # annuel : douze mois payes d'avance, pas un seul

    def test_if_stripe_cannot_be_reached_nothing_changes_and_the_client_can_retry(self):
        # 2e revue : le client etait ramene a l'Essai (periode payee perdue) et l'identifiant de l'abonnement oublie, alors que l'abonnement vivait chez
        # Stripe et continuait d'etre facture, sans que personne puisse plus l'annuler.
        self.activate("solo", "sub_1", "cs_1")
        before = server._billing_load(A)
        self.cancel_ok = False
        out = server.cancel_billing_plan(A)
        self.assertEqual(out["error"], "STRIPE_UNAVAILABLE")
        after = server._billing_load(A)
        self.assertEqual((after["planId"], after["stripeSubscriptionId"], after.get("cancelAtPeriodEnd")), ("solo", "sub_1", None))
        self.assertEqual(after["history"], before["history"])                    # rien n'a ete ecrit : l'abonnement est intact
        self.cancel_ok = True                                                    # Stripe repond de nouveau : la resiliation passe, en fin de periode
        out = server.cancel_billing_plan(A)
        self.assertEqual((out["planId"], out["cancelAtPeriodEnd"], out["paidUntilUtc"]), ("solo", True, "2026-11-02T08:00:00Z"))
        self.assertEqual(self.cancelled, ["sub_1", "sub_1"])

    def test_a_subscription_that_stripe_no_longer_knows_is_ended_at_once(self):
        self.activate("solo", "sub_1", "cs_1")
        self.cancel_gone = True
        out = server.cancel_billing_plan(A)
        self.assertEqual((out["planId"], out["cancelAtPeriodEnd"]), ("essai", False))
        self.assertTrue(any("introuvable chez Stripe" in h["event"] for h in out["history"]))
        self.assertIsNone(server._billing_load(A)["stripeSubscriptionId"])

    def test_choosing_the_same_plan_again_after_cancelling_resumes_it_without_a_second_payment(self):
        # 2e revue : une nouvelle Checkout Session facturait de nouveau le plein prix et laissait le temps deja paye sur l'ancien client Stripe.
        self.activate("solo", "sub_1", "cs_1")
        server.cancel_billing_plan(A)
        before = [c for c in self.bridge_calls if c[0] == "create-checkout"]
        payload, status = server.select_billing_plan(A, "solo", "month")
        self.assertEqual((status, payload["planId"], payload["cancelAtPeriodEnd"], payload["paidUntilUtc"]), (200, "solo", False, None))
        self.assertEqual(self.resume_calls, ["sub_1"])
        self.assertEqual([c for c in self.bridge_calls if c[0] == "create-checkout"], before)       # aucune nouvelle Checkout Session : aucun second paiement
        state = server._billing_load(A)
        self.assertEqual((state["stripeSubscriptionId"], state.get("cancelAtPeriodEnd")), ("sub_1", None))
        self.assertTrue(any("Résiliation annulée" in h["event"] for h in server.get_billing(A)["history"]))

    def test_resuming_with_stripe_down_changes_nothing(self):
        self.activate("solo", "sub_1", "cs_1")
        server.cancel_billing_plan(A)
        orig = self.fake_bridge

        def down(action, **kw):
            return {"Status": "ERROR", "Detail": "STRIPE_BRIDGE_TIMEOUT"} if action == "resume-subscription" else orig(action, **kw)
        server.run_stripe_bridge = down
        payload, status = server.select_billing_plan(A, "solo", "month")
        self.assertEqual((status, payload["error"]), (503, "STRIPE_UNAVAILABLE"))
        self.assertTrue(server._billing_load(A)["cancelAtPeriodEnd"])

    def test_choosing_the_plan_again_once_it_has_ended_opens_a_new_checkout(self):
        self.activate("solo", "sub_1", "cs_1")
        server.cancel_billing_plan(A)
        server._utcnow = lambda: at(days=40)                                     # la periode payee est finie : retour a l'Essai
        payload, status = server.select_billing_plan(A, "solo", "month")
        self.assertEqual((status, payload.get("checkoutUrl")), (200, "https://checkout.example/test"))
        payload, status = self.activate("solo", "sub_new", "cs_new")
        self.assertEqual((status, payload["cancelAtPeriodEnd"], payload["planId"]), (200, False, "solo"))

    def test_the_upgrade_card_proposes_the_interval_the_client_pays(self):
        self.activate("solo", "sub_1", "cs_1", interval="year")
        out = server.get_billing(A)
        self.assertEqual((out["billingInterval"], out["upgrade"]["interval"]), ("year", "year"))
        self.assertEqual(out["upgrade"]["next"]["priceChf"], {"month": 59, "year": 590})
        write_billing(server, B, "pro", stripeSubscriptionId="sub_b")            # etat sans rythme connu : mensuel, comme avant
        self.assertEqual(server.get_billing(B)["upgrade"]["interval"], "month")

    def test_the_quota_message_of_a_cancelled_plan_says_it_ends(self):
        self.activate("solo", "sub_1", "cs_1")
        write_task_record(A, 250, "2026-10-12T12:00:01Z")
        server.cancel_billing_plan(A)
        self.assertIn("votre résiliation y met fin le 2 novembre 2026", server.subscription_blocks_mission(A))

    def test_cancelling_a_plan_without_a_paid_period_is_still_immediate(self):
        write_billing(server, A, "pro")                                          # etat ecrit avant cette version, ni abonnement Stripe ni fin de periode
        out = server.cancel_billing_plan(A)
        self.assertEqual((out["planId"], out["creditsIncluded"]), ("essai", 15))
        self.assertEqual(self.cancel_calls, [])


class InvoicePeriod(Fixture):
    def test_a_plan_activated_by_invoice_lapses_after_the_paid_month_and_its_grace(self):
        res, st = server.grant_workers(A, "solo", ["alex"])
        self.assertEqual((st, res["paidUntilUtc"]), (200, "2026-11-12T12:00:00Z"))
        self.assertEqual(server.set_client_plan(B, "equipe")[0]["paidUntilUtc"], "2026-11-12T12:00:00Z")
        write_task_record(A, 250, "2026-10-13T00:00:00Z")
        server._utcnow = lambda: at(days=61)                                     # deux mois plus tard, aucune nouvelle facture n'a ete enregistree
        out = server.get_billing(A)
        self.assertEqual((out["planId"], out["creditsIncluded"], out["hiredWorkers"]), ("essai", 15, []))
        self.assertEqual(out["creditsRemaining"], 0)                             # l'Essai ne rend pas de credits neufs
        self.assertIsNotNone(server.subscription_blocks_mission(A))
        self.assertEqual(server.get_billing(B)["planId"], "essai")
        self.assertTrue(any("arrivé à échéance le 12 novembre 2026" in h["event"] for h in out["history"]))

    def test_the_grace_period_keeps_the_plan_for_a_few_days(self):
        server.grant_workers(A, "solo", ["alex"])
        server._utcnow = lambda: NOW.replace(month=11, day=14)                   # 2 jours apres la fin de periode (grace de 5 jours)
        self.assertEqual(server.get_billing(A)["planId"], "solo")
        self.assertIsNone(server.worker_block(A, "alex"))
        server._utcnow = lambda: NOW.replace(month=11, day=18)                   # au-dela
        self.assertEqual(server.get_billing(A)["planId"], "essai")

    def test_access_checks_see_the_lapse_without_a_billing_read(self):
        server.grant_workers(A, "solo", ["alex"])
        self.assertIsNotNone(server.worker_block(A, "nora"))                     # Solo : seul Alex est embauche
        self.assertEqual(server.allowed_workers_env(A), "alex")
        server._utcnow = lambda: at(days=70)
        path = server._billing_path(A)
        raw = open(path, encoding="utf-8").read()
        self.assertIsNone(server.worker_block(A, "nora"))                        # periode finie : Essai, tous les Workers (sans credits)
        self.assertIsNone(server.allowed_workers_env(A))
        self.assertEqual(server.normalize_level("approfondi", A), "rapide")      # et le niveau verrouille de l'Essai
        self.assertEqual(open(path, encoding="utf-8").read(), raw)               # lire ne reecrit rien
        self.assertEqual(server.get_billing(A)["planId"], "essai")               # la lecture complete, elle, enregistre le retour a l'Essai
        self.assertEqual(json.load(open(path, encoding="utf-8"))["planId"], "essai")

    def test_the_owner_renewing_the_invoice_extends_the_period(self):
        server.grant_workers(A, "solo", ["alex"])
        server._utcnow = lambda: at(days=28)
        res, st = server.grant_workers(A, "solo", ["alex"], paid_months=3)       # facture suivante, trois mois d'un coup
        self.assertEqual((st, res["newCycle"], res["paidUntilUtc"][:10]), (200, True, "2027-02-09"))
        server._utcnow = lambda: at(days=70)
        self.assertEqual(server.get_billing(A)["planId"], "solo")
        res, st = server.grant_workers(A, "solo", ["alex"], new_cycle=False)     # simple changement de la liste : la periode payee ne bouge pas
        self.assertEqual((st, res["paidUntilUtc"][:10]), (200, "2027-02-09"))
        res, st = server.set_client_plan(B, "scale", paid_months=12)
        self.assertEqual((st, res["paidUntilUtc"][:10]), (200, "2027-12-21"))

    def test_the_billed_months_are_validated(self):
        for bad in (0, -1, 25, "3", 1.5, True, [1]):
            self.assertEqual(server.grant_workers(A, "solo", ["alex"], paid_months=bad)[0]["error"], "INVALID_PERIOD", bad)
            self.assertEqual(server.set_client_plan(B, "pro", paid_months=bad)[0]["error"], "INVALID_PERIOD", bad)
        self.assertEqual(server._billing_load(A)["planId"], "essai")

    def test_a_plan_without_an_end_date_never_lapses_by_itself(self):
        write_billing(server, A, "equipe", cycle_start="2026-01-01T00:00:00Z")   # forfait ecrit avant cette version (ou abonnement Stripe en cours)
        write_billing(server, B, "pro", stripeSubscriptionId="sub_b", cycle_start="2026-01-01T00:00:00Z")
        server._utcnow = lambda: at(days=300)
        self.assertEqual((server.get_billing(A)["planId"], server.get_billing(B)["planId"]), ("equipe", "pro"))

    def test_cancelling_an_invoice_plan_keeps_it_until_the_end_of_the_paid_period(self):
        server.set_client_plan(A, "equipe", paid_months=2)
        out = server.cancel_billing_plan(A)
        self.assertEqual((out["planId"], out["cancelAtPeriodEnd"], out["paidUntilUtc"][:10]), ("equipe", True, "2026-12-12"))
        self.assertEqual(self.cancel_calls, [])                                  # pas d'abonnement Stripe a resilier
        server._utcnow = lambda: at(days=63)                                     # le terme est passe : pas de grace pour une resiliation
        self.assertEqual(server.get_billing(A)["planId"], "essai")

    def test_the_owner_overview_shows_the_end_of_the_paid_period(self):
        server.set_client_plan(A, "equipe")
        rows = {r["clientId"]: r for r in server.get_admin_overview()["clients"]}
        self.assertEqual((rows[A]["paidUntilUtc"], rows[A]["cancelAtPeriodEnd"]), ("2026-11-12T12:00:00Z", False))
        self.assertIsNone(rows[server.DASHBOARD_CLIENT_ID]["paidUntilUtc"])


class ExistingSubscribers(Fixture):
    def test_a_pro_or_scale_account_written_before_the_new_grid_keeps_its_credits_and_its_one_credit_mission(self):
        write_billing(server, A, "pro", gridVersion=None, stripeSubscriptionId="sub_a")                # abonnement Stripe : preuve de paiement
        write_billing(server, B, "scale", gridVersion=None, history=[{"dateUtc": "2026-09-01T00:00:00Z", "event": "Changement de plan : Essai -> Scale (paiement Stripe confirme)."}])
        a, b = server.get_billing(A), server.get_billing(B)
        self.assertEqual((a["creditsIncluded"], a["grandfathered"]), (1500, True))
        self.assertEqual((b["creditsIncluded"], b["grandfathered"]), (4000, True))
        for client in (A, B):
            self.assertEqual(server.normalize_level(None, client), "rapide")      # une mission sans choix coute 1 credit comme avant
            self.assertEqual(server.normalize_level("equilibre", client), "equilibre")       # et il peut choisir plus (au cout de ce niveau)
            pub = server.public_mission_levels(client)
            self.assertEqual((pub["default"], len(pub["levels"])), ("rapide", 3))
        self.assertEqual(next(p for p in a["availablePlans"] if p["planId"] == "pro")["credits"], 1500)
        self.assertEqual(next(p for p in server.get_billing(C)["availablePlans"] if p["planId"] == "pro")["credits"], 1250)

    def test_a_new_pro_subscriber_gets_the_new_grid(self):
        write_billing(server, A, "pro")                                          # gridVersion 2 (ecrit avec la grille actuelle)
        a = server.get_billing(A)
        self.assertEqual((a["creditsIncluded"], a["grandfathered"], server.normalize_level(None, A)), (1250, False, "equilibre"))
        payload, status = server.activate_checkout_plan(confirmation("pro", "sub_p", "cs_p"))
        self.assertEqual((status, payload["creditsIncluded"], payload["grandfathered"]), (200, 1250, False))
        self.assertEqual(server._billing_load(A)["gridVersion"], server.GRID_VERSION)

    def test_changing_plan_ends_the_old_terms_and_new_states_are_stamped(self):
        write_billing(server, A, "pro", gridVersion=None, history=[{"dateUtc": "2026-09-01T00:00:00Z", "event": "Changement de plan : Essai -> Pro (paiement Stripe confirme)."}])
        server.set_client_plan(A, "scale")
        self.assertEqual((server.get_billing(A)["creditsIncluded"], server.get_billing(A)["grandfathered"]), (4000, False))
        self.assertEqual(server.normalize_level(None, A), "equilibre")
        server.set_client_plan(A, "pro")
        self.assertEqual(server.get_billing(A)["creditsIncluded"], 1250)
        self.assertEqual(server._billing_load(C)["gridVersion"], server.GRID_VERSION)       # compte neuf : etat par defaut deja a la nouvelle grille
        self.assertFalse(server.get_billing(C)["grandfathered"])

    def test_other_plans_are_untouched_by_the_grandfathering(self):
        for pid, credits in (("solo", 250), ("equipe", 900), ("starter", 150), ("business", 600)):
            write_billing(server, A, pid, gridVersion=None)
            self.assertEqual(server.get_billing(A)["creditsIncluded"], credits, pid)
            self.assertFalse(server.get_billing(A)["grandfathered"], pid)


class CreditsOnlyForDeliveredMissions(Fixture):
    def test_the_charge_of_one_record(self):
        f = server.task_credits
        self.assertEqual(f({"Status": "EXECUTED", "Credits": 6, "Result": {"Degraded": False}}), 6)
        self.assertEqual(f({"Status": "EXECUTED", "Credits": 12}), 12)
        self.assertEqual(f({"Status": "EXECUTED", "Credits": 6, "Result": {"Degraded": True, "FallbackReason": "ANTHROPIC_EXIT_CODE_1"}}), 0)
        for status in ("SECURITY_BLOCKED", "BLOCKED", "NEEDS_CHLOE_VERIFICATION", "WORKER_NOT_INCLUDED", "security_blocked"):
            self.assertEqual(f({"Status": status, "Credits": 12}), 0, status)
        self.assertEqual(f({"Status": "EXECUTED", "Credits": 0}), 0)                         # le script ecrit 0 pour une mission non livree
        self.assertEqual(f({"Status": "EXECUTED"}), 1)                                       # trace ecrite avant les niveaux : 1 credit, comme avant
        self.assertEqual(f({"Status": "ROUTED"}), 1)
        for junk in ("beaucoup", True, [], {}):
            self.assertEqual(f({"Status": "EXECUTED", "Credits": junk}), 1, junk)
        self.assertEqual(f({"Status": "EXECUTED", "Credits": -4}), 0)

    def test_a_provider_outage_and_a_blocked_mission_do_not_burn_credits(self):
        write_billing(server, A, "pro")
        write_task_record(A, 6, "2026-10-05T00:00:00Z", Result={"Degraded": True, "FallbackReason": "ANTHROPIC_EXIT_CODE_1", "Status": "SUCCESS"})
        write_task_record(A, 12, "2026-10-05T00:00:00Z", Status="SECURITY_BLOCKED")
        out = server.get_billing(A)
        self.assertEqual((out["creditsUsed"], out["creditsRemaining"]), (0, 1250))
        write_task_record(A, 6, "2026-10-05T00:00:00Z", Result={"Degraded": False, "Answer": "ok"})
        write_task_record(A, None, "2026-10-05T00:00:00Z")
        self.assertEqual(server.get_billing(A)["creditsUsed"], 7)                # une vraie mission (6) + une ancienne trace sans niveau (1)


class OverHttp(Fixture):
    """Le meme rejeu, mais par les vraies routes HTTP du serveur (dans ce processus, pont Stripe remplace) : POST /api/billing/stripe-confirm n'exige
    aucune connexion, c'est ce que la revue du 2026-10-13 a exploite pour rejouer une session payee."""

    def setUp(self):
        super().setUp()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.sessions = {"cs_test_X": confirmation("scale", "sub_X", "cs_test_X", client=A)}
        self.token_a = server.account_create_session({"clientId": A, "email": "a@mail-test.example"})
        self.token_b = server.account_create_session({"clientId": B, "email": "b@mail-test.example"})

    def fake_bridge(self, action, **kw):
        if action == "confirm":
            return dict(self.sessions[kw["session_id"]]) if kw.get("session_id") in self.sessions else {"Status": "ERROR", "Detail": "No such session"}
        return super().fake_bridge(action, **kw)

    def http(self, method, path, body=None, token=None):
        headers = {"Content-Type": "application/json", "X-Forwarded-For": "198.51.100.7"}
        if token:
            headers["Cookie"] = "bk_account=" + token
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=json.dumps(body).encode() if body is not None else None, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode("utf-8"))

    def test_replaying_stripe_confirm_without_any_cookie_gives_no_second_quota(self):
        st, out = self.http("POST", "/api/billing/stripe-confirm", {"sessionId": "cs_test_X"})
        self.assertEqual((st, out["planId"], out["creditsRemaining"], out.get("alreadyConfirmed")), (200, "scale", 4000, None))
        write_task_record(A, 4000, "2026-10-12T12:00:01Z")                             # le quota est consomme
        st, out = self.http("GET", "/api/billing", token=self.token_a)
        self.assertEqual((st, out["creditsRemaining"]), (200, 0))
        self.assertIsNotNone(server.subscription_blocks_mission(A))
        for _ in range(3):
            st, out = self.http("POST", "/api/billing/stripe-confirm", {"sessionId": "cs_test_X"})      # aucun cookie, aucun paiement
            self.assertEqual((st, out["planId"], out["creditsRemaining"], out["alreadyConfirmed"]), (200, "scale", 0, True))
        self.assertIsNotNone(server.subscription_blocks_mission(A))
        # abonnement resilie puis rejeu : pas de resurrection
        st, out = self.http("POST", "/api/billing/cancel", token=self.token_a)
        self.assertEqual((st, out["planId"], out["cancelAtPeriodEnd"]), (200, "scale", True))
        server._utcnow = lambda: at(days=45)
        st, out = self.http("POST", "/api/billing/stripe-confirm", {"sessionId": "cs_test_X"})
        self.assertEqual((st, out["planId"], out["alreadyConfirmed"]), (200, "essai", True))

    def test_a_logged_in_stranger_cannot_confirm_someone_elses_session(self):
        st, out = self.http("POST", "/api/billing/stripe-confirm", {"sessionId": "cs_test_X"}, token=self.token_b)
        self.assertEqual((st, out["error"]), (403, "SESSION_CLIENT_MISMATCH"))
        self.assertEqual(server._billing_load(A)["planId"], "essai")
        st, out = self.http("POST", "/api/billing/stripe-confirm", {"sessionId": "cs_test_X"}, token=self.token_a)
        self.assertEqual((st, out["planId"]), (200, "scale"))
        st, out = self.http("POST", "/api/billing/stripe-confirm", {"sessionId": "cs_inconnue"})
        self.assertEqual((st, out["error"]), (400, "STRIPE_CONFIRM_FAILED"))

    def test_the_cancelled_subscription_at_stripe_is_refused_over_http(self):
        self.sessions["cs_test_X"]["SubscriptionStatus"] = "canceled"
        st, out = self.http("POST", "/api/billing/stripe-confirm", {"sessionId": "cs_test_X"})
        self.assertEqual((st, out["error"]), (409, "SUBSCRIPTION_NOT_ACTIVE"))
        self.assertEqual(server._billing_load(A)["planId"], "essai")

    def test_the_public_scale_is_complete_for_a_trial_account_while_its_own_view_stays_locked(self):
        st, own = self.http("GET", "/api/mission-levels", token=self.token_a)
        self.assertEqual([l["id"] for l in own["levels"]], ["rapide"])                      # un compte a l'essai ne PEUT choisir que Rapide
        st, public = self.http("GET", "/api/mission-levels?scale=public", token=self.token_a)
        self.assertEqual([(l["id"], l["credits"]) for l in public["levels"]], [("rapide", 1), ("equilibre", 6), ("approfondi", 12)])
        self.assertNotIn("locked", [k for k, v in public.items() if v is True])
        st, anon = self.http("GET", "/api/mission-levels?scale=public")
        self.assertEqual(anon["levels"], public["levels"])                                  # la meme echelle pour tous, aucune donnee de compte

    def test_stripe_down_over_http_never_opens_a_plan(self):
        self.stripe_configured = True
        orig = self.fake_bridge

        def failing(action, **kw):
            return {"Status": "ERROR", "Detail": "STRIPE_BRIDGE_TIMEOUT"} if action == "status" else orig(action, **kw)
        server.run_stripe_bridge = failing
        for plan in ("equipe", "pro", "scale"):
            st, out = self.http("POST", "/api/billing/plan", {"planId": plan}, token=self.token_a)
            self.assertEqual((st, out["error"]), (503, "STRIPE_UNAVAILABLE"), plan)
        self.assertEqual(self.http("GET", "/api/billing", token=self.token_a)[1]["planId"], "essai")


if __name__ == "__main__":
    ok = unittest.main(verbosity=2, exit=False).result.wasSuccessful()
    sys.exit(0 if ok else 1)
