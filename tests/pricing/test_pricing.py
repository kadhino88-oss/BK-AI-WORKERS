# -*- coding: utf-8 -*-
"""Grille de prix et modele de quota (validés par le proprietaire le 2026-10-12, docs/PRICING.md) dans le vrai dashboard/server.py :

  - catalogue : credits et prix de chaque forfait, annuel = 10 mois, forfaits HERITES (Starter, Business) inchanges et caches, aucun forfait illimite
    (Enterprise = plafond contractuel), voie de montee en gamme Solo -> Trio -> Equipe -> Pro -> Scale -> Enterprise ;
  - quota MENSUEL fixe : fenetre de 30 jours glissante ancree sur la date d'activation, renouvellement, essai non renouvelable, message francais qui
    nomme les credits inclus, la date de renouvellement et le forfait suivant (credits + prix), bouton de montee en gamme a partir de 80 % ;
  - niveaux : echelle 1 / 6 / 12, niveau par defaut Equilibre, essai verrouille sur Rapide, automatisations au niveau Rapide (1 credit), BK_LEVELS=0 ;
  - achat : montant Stripe en centimes de CHF (annuel = 10 mois), jamais de bascule gratuite vers Solo / Trio / Equipe, Enterprise sur devis,
    ancien abonnement Stripe annule quand le nouveau est confirme, activation par le proprietaire avec plafond contractuel ;
  - cout : le cout IA au pire cas reste sous 35 % du prix mensuel de chaque forfait (modele docs/pricing-cost-model.py).

Aucun reseau, aucun modele, aucun secret.   python tests/pricing/test_pricing.py
"""
import importlib.util
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import A, B, C, NOW, REPO, add_account, load_server, reset, write_billing, write_task  # noqa: E402

server, ROOT = load_server()

GRID = {   # forfait -> (credits par mois, prix mensuel CHF, prix annuel CHF) : la grille validee le 2026-10-12
    "solo": (250, 29, 290), "trio": (500, 59, 590), "equipe": (900, 99, 990), "pro": (1250, 139, 1390), "scale": (4000, 449, 4490),
}
LEGACY = {"starter": (150, 39, 390), "business": (600, 99, 990)}


class Fixture(unittest.TestCase):
    def setUp(self):
        reset(server)
        server.INSTALLS = server.inst.InstallationStore(ROOT)
        server.run_stripe_bridge = self.fake_bridge
        self.bridge_calls = []
        self.stripe_configured = True
        self.cancelled = []
        self.cancel_ok = True

    def fake_bridge(self, action, **kw):
        self.bridge_calls.append((action, kw))
        if action == "status":
            return {"Configured": self.stripe_configured}
        if action == "create-checkout":
            return {"Status": "SUCCESS", "CheckoutUrl": "https://checkout.example/test", "SessionId": "cs_test_1"}
        if action == "cancel-subscription":
            self.cancelled.append(kw.get("subscription_id"))
            return {"Status": "SUCCESS"} if self.cancel_ok else {"Status": "ERROR", "Detail": "boom"}
        return {"Status": "ERROR"}


class Catalog(Fixture):
    def test_the_grid_matches_the_owner_approved_scale(self):
        for pid, (credits, month, year) in GRID.items():
            plan = server.PLAN_CATALOG[pid]
            self.assertEqual((plan["credits"], plan["priceChf"]["month"], plan["priceChf"]["year"]), (credits, month, year), pid)
            self.assertFalse(plan.get("legacy"), pid)
        self.assertEqual(server.PLAN_CATALOG["essai"]["credits"], 15)
        self.assertEqual(server.PLAN_CATALOG["essai"]["trialDays"], 3)
        self.assertNotIn("priceChf", server.PLAN_CATALOG["essai"])
        self.assertNotIn("priceChf", server.PLAN_CATALOG["enterprise"])      # sur devis : pas de prix catalogue
        self.assertTrue(server.PLAN_CATALOG["enterprise"]["onQuote"])

    def test_annual_is_exactly_ten_months(self):
        for pid, p in server.PLAN_CATALOG.items():
            if p.get("priceChf"):
                self.assertEqual(p["priceChf"]["year"], p["priceChf"]["month"] * 10, pid)

    def test_legacy_plans_keep_their_credits_and_prices_and_are_not_sellable(self):
        for pid, (credits, month, year) in LEGACY.items():
            plan = server.PLAN_CATALOG[pid]
            self.assertEqual((plan["credits"], plan["priceChf"]["month"], plan["priceChf"]["year"]), (credits, month, year), pid)
            self.assertTrue(plan["legacy"], pid)
            self.assertNotIn(pid, server.PAID_PLANS_WITH_CHECKOUT)
        write_billing(server, A, "solo", hiredWorkers=["alex"])
        add_account(server, A)
        self.assertEqual([p["planId"] for p in server.get_billing(A)["availablePlans"]], ["solo", "trio", "equipe", "pro", "scale", "enterprise"])
        write_billing(server, B, "starter")
        b = server.get_billing(B)
        self.assertEqual(b["creditsIncluded"], 150)                       # l'abonne Starter garde ses 150 credits
        self.assertIn("starter", [p["planId"] for p in b["availablePlans"]])    # ... et voit son forfait, que les autres ne voient pas
        self.assertTrue(next(p for p in b["availablePlans"] if p["planId"] == "starter")["legacy"])
        write_billing(server, C, "business")
        self.assertEqual(server.get_billing(C)["creditsIncluded"], 600)

    def test_no_plan_is_unlimited(self):
        for pid in server.PLAN_CATALOG:
            write_billing(server, A, pid)
            b = server.get_billing(A)
            self.assertIsInstance(b["creditsTotal"], int, pid)
            self.assertGreater(b["creditsTotal"], 0, pid)
            self.assertFalse(b["unlimited"], pid)
            self.assertIsNotNone(b["creditsRemaining"], pid)
        # Enterprise : plafond par defaut documente, ou plafond contractuel du client (borne) ; une valeur absurde est ignoree
        write_billing(server, A, "enterprise")
        self.assertEqual(server.get_billing(A)["creditsIncluded"], server.ENTERPRISE_DEFAULT_CREDITS)
        write_billing(server, A, "enterprise", contractCredits=25000)
        self.assertEqual(server.get_billing(A)["creditsIncluded"], 25000)
        for bad in (0, -5, None, "illimite", 10 ** 9, True, 12.5):
            write_billing(server, A, "enterprise", contractCredits=bad)
            self.assertEqual(server.get_billing(A)["creditsIncluded"], server.ENTERPRISE_DEFAULT_CREDITS, repr(bad))
        write_billing(server, A, "solo", contractCredits=999999)             # le plafond d'un contrat ne s'applique qu'a Enterprise
        self.assertEqual(server.get_billing(A)["creditsIncluded"], 250)

    def test_a_missing_cap_blocks_instead_of_opening_everything(self):
        orig = dict(server.PLAN_CATALOG["scale"])
        try:
            server.PLAN_CATALOG["scale"]["credits"] = None                   # ancien « None = illimite » : refuse desormais
            write_billing(server, A, "scale")
            b = server.get_billing(A)
            self.assertEqual((b["creditsIncluded"], b["creditsRemaining"], b["unlimited"]), (0, 0, False))
            self.assertIn("quota est épuisé", server.subscription_blocks_mission(A))
        finally:
            server.PLAN_CATALOG["scale"].update(orig)
        # un solde illisible vaut 0 aussi
        orig_get = server.get_billing
        try:
            server.get_billing = lambda cid=None: {"unlimited": True, "creditsRemaining": None}
            self.assertIn("quota est épuisé", server.subscription_blocks_mission(A))
        finally:
            server.get_billing = orig_get

    def test_the_upgrade_ladder_goes_up_in_credits_and_price(self):
        chain, pid = [], "essai"
        while pid:
            chain.append(pid)
            pid = server.PLAN_CATALOG[pid].get("nextPlan")
        self.assertEqual(chain, ["essai", "solo", "trio", "equipe", "pro", "scale", "enterprise"])
        credits = [server.plan_monthly_credits(p) for p in chain]
        self.assertEqual(credits, sorted(credits))
        self.assertEqual(len(set(credits)), len(credits))
        prices = [server.PLAN_CATALOG[p]["priceChf"]["month"] for p in chain[1:-1]]
        self.assertEqual(prices, sorted(prices))
        self.assertIsNone(server.next_plan_info("enterprise"))
        self.assertEqual(server.next_plan_info("starter")["planId"], "equipe")      # un abonne Starter monte vers un forfait avec tous les Workers
        self.assertEqual(server.next_plan_info("business")["planId"], "pro")
        for pid, p in server.PLAN_CATALOG.items():
            nxt = p.get("nextPlan")
            self.assertTrue(nxt is None or nxt in server.PLAN_CATALOG, pid)
            if nxt and not server.PLAN_CATALOG[nxt].get("onQuote"):
                self.assertGreater(server.PLAN_CATALOG[nxt]["credits"], p["credits"], pid)

    def test_the_trial_has_no_phone_minutes_and_is_locked_to_the_cheapest_level(self):
        essai = server.PLAN_CATALOG["essai"]
        self.assertEqual(essai["phoneMinutes"], 0)
        self.assertEqual(essai["levelLock"], "rapide")
        self.assertFalse(essai.get("renews", True))
        for pid in GRID:
            self.assertNotIn("phoneMinutes", server.PLAN_CATALOG[pid])

    def test_credit_packs_and_top_ups_do_not_exist(self):
        for p in server.PLAN_CATALOG.values():
            for key in p:
                self.assertNotIn("pack", key.lower())
        write_billing(server, A, "solo")
        res = server.recharge_billing_credits(100, A)                        # un client ne peut jamais se recharger
        self.assertEqual(res["error"], "RECHARGE_NOT_AVAILABLE")
        self.assertIn("forfait supérieur", res["detail"])
        self.assertEqual(server.get_billing(A)["creditsTotal"], 250)


class Quota(Fixture):
    def test_the_window_is_monthly_and_anchored_on_the_activation_date(self):
        f = server.billing_cycle
        self.assertEqual(f("2026-09-20T08:00:00Z", now=NOW), ("2026-09-20T08:00:00Z", "2026-10-20T08:00:00Z"))
        start, renews = f("2026-09-20T08:00:00Z", now=NOW.replace(day=25))
        self.assertEqual((start[:19], renews[:19]), ("2026-10-20T08:00:00", "2026-11-20T08:00:00"))
        start, renews = f("2026-01-31T10:00:00.123456Z", now=NOW.replace(month=3, day=1))     # mois courts : meme jour, ramene a la fin du mois
        self.assertEqual((start[:10], renews[:10]), ("2026-02-28", "2026-03-31"))
        start, renews = f("2025-12-15T00:00:00Z", now=NOW.replace(year=2027, month=1, day=14))
        self.assertEqual((start[:10], renews[:10]), ("2026-12-15", "2027-01-15"))
        self.assertEqual(f("2026-09-20T08:00:00Z", renews=False, now=NOW.replace(month=12)), ("2026-09-20T08:00:00Z", None))   # l'essai ne se renouvelle pas
        self.assertEqual(f("pas une date", now=NOW), ("pas une date", None))
        self.assertEqual(f("2999-01-01T00:00:00Z", now=NOW), ("2999-01-01T00:00:00Z", None))

    def test_usage_counts_only_the_current_window_and_credits_come_back_each_month(self):
        write_billing(server, A, "solo", cycle_start="2026-09-20T08:00:00Z")
        write_task(server, A, 250, created="2026-09-25T00:00:00Z")
        self.assertEqual(server.get_billing(A)["creditsRemaining"], 0)       # 12 octobre : toujours dans la fenetre du 20 septembre
        self.assertIsNotNone(server.subscription_blocks_mission(A))
        server._utcnow = lambda: NOW.replace(day=21)                        # apres le renouvellement du 20 octobre : le quota est reparti de zero
        b = server.get_billing(A)
        self.assertEqual((b["creditsUsed"], b["creditsRemaining"]), (0, 250))
        self.assertTrue(b["renewsAtUtc"].startswith("2026-11-20"))
        self.assertIsNone(server.subscription_blocks_mission(A))
        write_task(server, A, 6, created="2026-10-21T01:00:00Z")
        self.assertEqual(server.get_billing(A)["creditsUsed"], 6)

    def test_the_trial_is_a_single_allowance_that_never_renews(self):
        write_billing(server, A, "essai", cycle_start="2026-08-01T00:00:00Z")
        write_task(server, A, 15, created="2026-08-02T00:00:00Z")
        b = server.get_billing(A)
        self.assertIsNone(b["renewsAtUtc"])
        self.assertEqual(b["creditsRemaining"], 0)
        msg = server.subscription_blocks_mission(A)
        self.assertIn("l'essai inclut 15 crédits", msg)
        self.assertNotIn("renouvel", msg)
        self.assertIn("Solo (250 crédits par mois, CHF 29 par mois)", msg)

    def test_the_message_names_credits_renewal_and_the_next_plan_for_every_step(self):
        expect = {"solo": ("250", "Trio", "500", "59"), "trio": ("500", "Équipe", "900", "99"), "equipe": ("900", "Pro", "1 250", "139"),
                  "pro": ("1 250", "Scale", "4 000", "449"), "starter": ("150", "Équipe", "900", "99"), "business": ("600", "Pro", "1 250", "139")}
        for pid, (included, nxt, nxt_credits, nxt_price) in expect.items():
            reset(server)
            cap = server.plan_monthly_credits(pid)
            write_billing(server, A, pid, cycle_start="2026-09-20T08:00:00Z")
            write_task(server, A, cap, created="2026-10-02T00:00:00Z")
            msg = server.subscription_blocks_mission(A)
            name = server.PLAN_CATALOG[pid]["name"]
            self.assertIn(f"Votre quota est épuisé : le forfait {name} inclut {included} crédits par mois", msg, pid)
            self.assertIn("renouvelés le 20 octobre 2026", msg, pid)
            self.assertIn(f"passez au forfait {nxt} ({nxt_credits} crédits par mois, CHF {nxt_price} par mois)", msg, pid)
            self.assertNotIn("illimité", msg)
            self.assertNotIn("recharge", msg)

    def test_scale_points_to_enterprise_on_quote_and_enterprise_has_a_contractual_cap(self):
        write_billing(server, A, "scale", cycle_start="2026-09-20T08:00:00Z")
        write_task(server, A, 4000, created="2026-10-02T00:00:00Z")
        msg = server.subscription_blocks_mission(A)
        self.assertIn("Enterprise, sur devis", msg)
        self.assertIn("plafond de crédits fixé par contrat", msg)
        self.assertIn(server.CONTACT_EMAIL, msg)
        up = server.get_billing(A)["upgrade"]
        self.assertEqual((up["next"]["planId"], up["next"]["onQuote"], up["next"]["selfService"], up["next"]["credits"]), ("enterprise", True, False, None))
        reset(server)
        write_billing(server, A, "enterprise", cycle_start="2026-09-20T08:00:00Z", contractCredits=12000)
        write_task(server, A, 12000, created="2026-10-02T00:00:00Z")
        msg = server.subscription_blocks_mission(A)
        self.assertIn("inclut 12 000 crédits par mois", msg)
        self.assertIn("relever le plafond de votre contrat", msg)
        self.assertIsNone(server.get_billing(A)["upgrade"]["next"])

    def test_partial_balance_message_suggests_a_faster_level_or_the_next_plan(self):
        write_billing(server, A, "solo", cycle_start="2026-09-20T08:00:00Z")
        write_task(server, A, 245, created="2026-10-02T00:00:00Z")
        msg = server.subscription_blocks_mission(A, "equilibre")             # il reste 5 credits, Equilibre en demande 6
        self.assertIn("Il vous reste 5 crédit(s), ce niveau en demande 6", msg)
        self.assertIn("niveau plus rapide", msg)
        self.assertIn("passez au forfait Trio", msg)
        self.assertIsNone(server.subscription_blocks_mission(A, "rapide"))

    def test_the_upgrade_button_shows_from_80_percent(self):
        write_billing(server, A, "solo", cycle_start="2026-09-20T08:00:00Z")
        write_task(server, A, 199)                                           # 79,6 % -> 80 % arrondi : seuil atteint ; 199/250 = 79.6 -> round = 80
        self.assertTrue(server.get_billing(A)["upgradeSuggested"])
        reset(server)
        write_billing(server, A, "solo", cycle_start="2026-09-20T08:00:00Z")
        write_task(server, A, 150)
        b = server.get_billing(A)
        self.assertFalse(b["upgradeSuggested"])
        self.assertEqual(b["upgrade"]["next"]["planId"], "trio")             # les donnees sont la, seul l'affichage attend 80 %
        self.assertEqual(b["upgrade"]["creditsIncluded"], 250)
        self.assertTrue(b["upgrade"]["renewsAtUtc"].startswith("2026-10-20"))

    def test_the_402_payload_carries_the_upgrade_card(self):
        write_billing(server, A, "pro", cycle_start="2026-09-20T08:00:00Z")
        write_task(server, A, 1250, created="2026-10-02T00:00:00Z")
        payload = server.subscription_required_payload(A, server.subscription_blocks_mission(A))
        self.assertEqual(payload["error"], "SUBSCRIPTION_REQUIRED")
        self.assertEqual(payload["upgrade"]["next"]["planId"], "scale")
        self.assertEqual(payload["upgrade"]["next"]["priceChf"], {"month": 449, "year": 4490})
        self.assertEqual(payload["upgrade"]["creditsIncluded"], 1250)
        self.assertEqual(payload["upgrade"]["contactEmail"], server.CONTACT_EMAIL)
        json.dumps(payload)

    def test_choosing_the_same_plan_never_starts_a_new_cycle_and_the_trial_cannot_be_refilled(self):
        write_billing(server, A, "solo", cycle_start="2026-09-20T08:00:00Z")
        add_account(server, A)
        write_task(server, A, 250, created="2026-10-02T00:00:00Z")
        payload, status = server.select_billing_plan(A, "solo", "month")
        self.assertEqual(status, 200)
        self.assertEqual(server._billing_load(A)["cycleStartUtc"], "2026-09-20T08:00:00Z")
        self.assertEqual(server.get_billing(A)["creditsRemaining"], 0)
        self.assertEqual(self.bridge_calls, [])                              # aucun appel Stripe pour un forfait deja actif
        payload, status = server.select_billing_plan(A, "essai", "month")
        self.assertEqual((status, payload["error"]), (403, "PLAN_NOT_SELECTABLE"))
        # annuler un abonnement : retour a l'essai SANS repartir sur 15 credits neufs ; annuler a l'essai ne fait rien
        write_billing(server, B, "equipe", cycle_start="2026-09-20T08:00:00Z")
        write_task(server, B, 40, created="2026-10-02T00:00:00Z")
        res = server.cancel_billing_plan(B)
        self.assertEqual((res["planId"], res["creditsUsed"], res["creditsRemaining"]), ("essai", 40, 0))
        self.assertEqual(server._billing_load(B)["cycleStartUtc"], "2026-09-20T08:00:00Z")
        before = server._billing_load(B)
        server.cancel_billing_plan(B)
        self.assertEqual(server._billing_load(B), before)


class Levels(Fixture):
    def test_scale_default_and_kill_switch(self):
        self.assertEqual([server.level_credits(l) for l in ("rapide", "equilibre", "approfondi")], [1, 6, 12])
        self.assertTrue(server.levels_enabled())                             # le fichier livre active les niveaux
        self.assertEqual(server.normalize_level(None, "CLI-X"), "equilibre")
        os.environ["BK_LEVELS"] = "0"                                        # interrupteur d'arret : ancien comportement
        try:
            self.assertEqual(server.normalize_level("approfondi", A), "")
            self.assertEqual(server.public_mission_levels(A), {"levels": [], "default": ""})
            self.assertEqual(server.automation_level(A), "")
            write_billing(server, A, "solo", cycle_start="2026-09-20T08:00:00Z")
            write_task(server, A, 249, created="2026-10-02T00:00:00Z")
            self.assertIsNone(server.subscription_blocks_mission(A))        # un seul credit par mission
        finally:
            os.environ.pop("BK_LEVELS", None)

    def test_the_trial_plan_is_locked_to_rapide_everywhere(self):
        write_billing(server, A, "essai")
        write_billing(server, B, "solo", hiredWorkers=["alex"])
        for asked in ("approfondi", "equilibre", None, "n'importe quoi"):
            self.assertEqual(server.normalize_level(asked, A), "rapide", asked)
        self.assertEqual(server.normalize_level("approfondi", B), "approfondi")
        self.assertEqual(server.normalize_level(None, B), "equilibre")
        self.assertEqual(server.normalize_level("approfondi", "CLI-TRIAL-PUBLIC"), "rapide")
        pub = server.public_mission_levels(A)
        self.assertEqual([l["id"] for l in pub["levels"]], ["rapide"])
        self.assertEqual((pub["default"], pub["locked"]), ("rapide", True))
        self.assertEqual(len(server.public_mission_levels(B)["levels"]), 3)
        # un compte sans fichier de facturation est a l'essai ; un fichier illisible aussi (le niveau le moins cher)
        self.assertEqual(server.normalize_level("approfondi", C), "rapide")
        os.makedirs(server.BILLING_DATA_DIR, exist_ok=True)
        with open(server._billing_path(B), "w", encoding="utf-8") as f:
            f.write("{ illisible")
        self.assertEqual(server.normalize_level("approfondi", B), "rapide")
        # le quota de l'essai se controle donc a 1 credit par mission, meme si le client demande Approfondi
        write_billing(server, A, "essai")
        write_task(server, A, 14, created="2026-10-02T00:00:00Z")
        self.assertIsNone(server.subscription_blocks_mission(A, "approfondi"))

    def test_legacy_plans_keep_a_one_credit_mission_unless_the_client_chooses_more(self):
        # Aucun changement silencieux pour un abonne Starter / Business : sans choix de sa part, sa mission reste a 1 credit comme avant l'activation
        # des niveaux ; s'il choisit lui-meme Equilibre ou Approfondi, il paie le cout de ce niveau (6 ou 12).
        write_billing(server, A, "starter")
        write_billing(server, B, "business")
        write_billing(server, C, "equipe")
        for client in (A, B):
            self.assertEqual(server.normalize_level(None, client), "rapide")
            self.assertEqual(server.normalize_level("n'importe quoi", client), "rapide")
            self.assertEqual(server.normalize_level("equilibre", client), "equilibre")
            self.assertEqual(server.normalize_level("approfondi", client), "approfondi")
            pub = server.public_mission_levels(client)
            self.assertEqual((pub["default"], pub["locked"], len(pub["levels"])), ("rapide", False, 3))
        self.assertEqual(server.normalize_level(None, C), "equilibre")                    # un forfait vendu garde le niveau par defaut du fichier
        self.assertEqual(server.public_mission_levels(C)["default"], "equilibre")
        write_task(server, A, 149, created="2026-10-02T00:00:00Z")                        # Starter : il reste 1 credit sur 150
        self.assertIsNone(server.subscription_blocks_mission(A))                           # une mission sans choix passe (1 credit)
        self.assertIn("Il vous reste 1 crédit", server.subscription_blocks_mission(A, "equilibre"))
        os.environ["BK_LEVELS"] = "0"
        try:
            self.assertEqual(server.normalize_level(None, A), "")                          # interrupteur d'arret : niveaux coupes pour tout le monde
        finally:
            os.environ.pop("BK_LEVELS", None)

    def test_automations_run_at_rapide_and_cost_one_credit(self):
        write_billing(server, A, "solo", cycle_start="2026-09-20T08:00:00Z", hiredWorkers=["alex"])
        write_task(server, A, 249, created="2026-10-02T00:00:00Z")           # il reste 1 credit
        self.assertEqual(server.automation_level(A), "rapide")
        self.assertIsNone(server.subscription_blocks_mission(A, server.automation_level(A)))     # l'automatisation passe : 1 credit
        self.assertIsNotNone(server.subscription_blocks_mission(A))                              # une mission au niveau par defaut (6) est refusee
        self.assertEqual(server.level_credits(server.automation_level(A)), 1)
        # le niveau « rapide » est impose meme si le fichier de niveaux est reordonne
        self.assertEqual(server.AUTOMATION_LEVEL, "rapide")


class Checkout(Fixture):
    def setUp(self):
        super().setUp()
        add_account(server, A)
        add_account(server, B, verified=False)
        write_billing(server, A, "essai")
        write_billing(server, B, "essai")

    def test_stripe_amounts_are_the_catalog_prices_in_chf_cents(self):
        for pid, (credits, month, year) in {**GRID, **LEGACY}.items():
            self.assertEqual(server.plan_price_cents(pid, "month"), month * 100, pid)
            self.assertEqual(server.plan_price_cents(pid, "year"), year * 100, pid)
        self.assertEqual((server.plan_price_cents("solo", "month"), server.plan_price_cents("solo", "year")), (2900, 29000))
        self.assertEqual((server.plan_price_cents("trio", "month"), server.plan_price_cents("trio", "year")), (5900, 59000))
        self.assertEqual((server.plan_price_cents("equipe", "month"), server.plan_price_cents("equipe", "year")), (9900, 99000))
        for pid in ("essai", "enterprise", "inconnu"):
            self.assertIsNone(server.plan_price_cents(pid, "month"), pid)        # jamais de montant invente
        self.assertIsNone(server.plan_price_cents("solo", "week"))
        self.assertIsNone(server.plan_price_cents("solo", None))

    def test_checkout_session_gets_the_catalog_amount_per_plan_and_interval(self):
        for pid, (credits, month, year) in GRID.items():
            for interval, amount in (("month", month), ("year", year)):
                self.bridge_calls.clear()
                payload, status = server.select_billing_plan(A, pid, interval)
                self.assertEqual((status, payload.get("checkoutUrl")), (200, "https://checkout.example/test"), pid)
                action, kw = next(c for c in self.bridge_calls if c[0] == "create-checkout")
                self.assertEqual((kw["plan_id"], kw["interval"], kw["amount_cents"], kw["client_id"]), (pid, interval, amount * 100, A), (pid, interval))
                self.assertEqual(kw["plan_name"], server.PLAN_CATALOG[pid]["name"])
                self.assertIn("{CHECKOUT_SESSION_ID}", kw["success_url"])
        self.assertEqual(server._billing_load(A)["planId"], "essai")        # rien n'est active avant le paiement confirme

    def test_without_stripe_solo_trio_equipe_never_switch_for_free(self):
        self.stripe_configured = False
        for pid in ("solo", "trio", "equipe"):
            payload, status = server.select_billing_plan(A, pid, "month")
            self.assertEqual((status, payload["error"]), (403, "PLAN_BY_INVOICE"), pid)
            self.assertEqual(server._billing_load(A)["planId"], "essai", pid)
        payload, status = server.select_billing_plan(B, "solo", "month")     # meme pour un e-mail non confirme : la reponse reste « sur facture »
        self.assertEqual((status, payload["error"]), (403, "PLAN_BY_INVOICE"))
        # Pro et Scale gardent la simulation locale d'origine (aucun changement silencieux pour le parcours existant)
        payload, status = server.select_billing_plan(A, "pro", "month")
        self.assertEqual((status, payload["planId"]), (200, "pro"))

    def test_unverified_email_cannot_start_a_payment(self):
        payload, status = server.select_billing_plan(B, "pro", "month")
        self.assertEqual((status, payload["error"]), (403, "EMAIL_NOT_VERIFIED"))
        self.assertFalse([c for c in self.bridge_calls if c[0] == "create-checkout"])

    def test_enterprise_trial_and_legacy_are_not_self_service(self):
        payload, status = server.select_billing_plan(A, "enterprise", "month")
        self.assertEqual((status, payload["error"], payload["contactEmail"]), (403, "PLAN_ON_QUOTE", server.CONTACT_EMAIL))
        for pid in ("starter", "business"):
            payload, status = server.select_billing_plan(A, pid, "month")
            self.assertEqual((status, payload["error"]), (403, "PLAN_NOT_SOLD"), pid)
        payload, status = server.select_billing_plan(A, "inconnu", "month")
        self.assertEqual((status, payload["error"]), (400, "UNKNOWN_PLAN"))
        self.assertEqual(server._billing_load(A)["planId"], "essai")
        write_billing(server, C, "starter")                                  # celui qui est deja Starter : rien ne change pour lui
        payload, status = server.select_billing_plan(C, "starter", "month")
        self.assertEqual((status, payload["planId"], payload["creditsIncluded"]), (200, "starter", 150))

    def test_paying_a_new_plan_cancels_the_old_stripe_subscription_once(self):
        write_billing(server, A, "solo", stripeSubscriptionId="sub_old", hiredWorkers=["alex"])
        confirmation = {"Paid": True, "PlanId": "trio", "ClientId": A, "SubscriptionId": "sub_new"}
        payload, status = server.activate_checkout_plan(confirmation)
        self.assertEqual((status, payload["planId"], payload["creditsIncluded"]), (200, "trio", 500))
        self.assertEqual(self.cancelled, ["sub_old"])
        state = server._billing_load(A)
        self.assertEqual(state["stripeSubscriptionId"], "sub_new")
        self.assertTrue(any("Ancien abonnement Stripe annulé" in h["event"] for h in state["history"]))
        server.activate_checkout_plan(confirmation)                          # la page de retour recharge : aucune annulation de plus
        self.assertEqual(self.cancelled, ["sub_old"])
        # echec de l'annulation : le client est prevenu dans l'historique, rien n'est cache
        write_billing(server, B, "trio", stripeSubscriptionId="sub_b_old")
        self.cancel_ok = False
        server.activate_checkout_plan({"Paid": True, "PlanId": "equipe", "ClientId": B, "SubscriptionId": "sub_b_new"})
        self.assertTrue(any("ECHEC annulation de l'ancien abonnement Stripe" in h["event"] for h in server._billing_load(B)["history"]))

    def test_an_unpaid_or_unknown_session_activates_nothing(self):
        payload, status = server.activate_checkout_plan({"Paid": False, "PlanId": "pro", "ClientId": A, "PaymentStatus": "unpaid"})
        self.assertEqual((status, payload["error"]), (400, "PAYMENT_NOT_CONFIRMED"))
        payload, status = server.activate_checkout_plan({"Paid": True, "PlanId": "gratuit-illimite", "ClientId": A})
        self.assertEqual((status, payload["error"]), (400, "PAYMENT_NOT_CONFIRMED"))
        payload, status = server.activate_checkout_plan({"Paid": True, "PlanId": "pro"})
        self.assertEqual((status, payload["error"]), (401, "ACCOUNT_REQUIRED"))
        self.assertEqual(server._billing_load(A)["planId"], "essai")

    def test_owner_activates_a_plan_and_sets_the_contractual_cap(self):
        payload, status = server.set_client_plan(A, "equipe")
        self.assertEqual((status, payload["credits"]), (200, 900))
        self.assertTrue(payload["renewsAtUtc"])
        payload, status = server.set_client_plan(A, "enterprise", contract_credits=15000)
        self.assertEqual((status, payload["credits"]), (200, 15000))
        self.assertEqual(server.get_billing(A)["creditsTotal"], 15000)
        payload, status = server.set_client_plan(A, "enterprise")           # sans plafond saisi : le defaut documente, jamais illimite
        self.assertEqual(payload["credits"], server.ENTERPRISE_DEFAULT_CREDITS)
        self.assertNotEqual(server._billing_load(A).get("contractCredits"), 15000)
        server.set_client_plan(A, "enterprise", contract_credits=15000)
        server.set_client_plan(A, "pro")                                     # changer de forfait efface le plafond du contrat
        self.assertNotIn("contractCredits", server._billing_load(A))
        for args, code, st in (((A, "enterprise", 0), "INVALID_CAP", 400), ((A, "enterprise", 10 ** 7), "INVALID_CAP", 400),
                               ((A, "enterprise", "beaucoup"), "INVALID_CAP", 400), ((A, "enterprise", True), "INVALID_CAP", 400),
                               ((A, "pro", 5000), "CAP_NOT_ALLOWED", 400), ((A, "solo"), "INVALID_PLAN", 400), ((A, "trio"), "INVALID_PLAN", 400),
                               ((A, "essai"), "INVALID_PLAN", 400), ((A, "inconnu"), "INVALID_PLAN", 400),
                               (("CLI-CUST-00000000", "pro"), "CLIENT_NOT_FOUND", 404), (("CLI-DASHBOARD", "pro"), "CLIENT_NOT_FOUND", 404)):
            payload, status = server.set_client_plan(*args) if len(args) == 3 else server.set_client_plan(args[0], args[1])
            self.assertEqual((status, payload["error"]), (st, code), args)
        write_billing(server, B, "pro", stripeSubscriptionId="sub_live")
        add_account(server, B)
        payload, status = server.set_client_plan(B, "scale")
        self.assertEqual((status, payload["error"]), (409, "ACTIVE_SUBSCRIPTION"))


class CostRatio(unittest.TestCase):
    """Cout IA au pire cas / prix du forfait, d'apres le modele de l'etude de marche (docs/pricing-cost-model.py, hypotheses de calcul et non des
    mesures). Regle du proprietaire : sous 35 % du prix MENSUEL quand le client epuise tous ses credits en missions lourdes."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("pricing_cost_model", os.path.join(REPO, "docs", "pricing-cost-model.py"))
        cls.model = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.model)
        levels = json.load(open(os.path.join(REPO, "core", "ai", "LEVELS.json"), encoding="utf-8"))["levels"]
        cls.credits = {k: v["credits"] for k, v in levels.items()}
        sc = cls.model.SCENARIOS["lourd"]
        cls.worst_per_credit = {k: cls.model.mission_cost(k, sc["calls"], sc["out"], sc["searches"], sc["search_tok"], sc["u0"]) * cls.model.USD_CHF / c
                                for k, c in cls.credits.items()}
        cls.worst = max(cls.worst_per_credit.values())

    def test_the_levels_file_carries_the_validated_scale(self):
        self.assertEqual(self.credits, {"rapide": 1, "equilibre": 6, "approfondi": 12})
        self.assertAlmostEqual(self.worst, 0.0378, places=3)                  # etude de marche, section 4.1
        for per_credit in self.worst_per_credit.values():
            self.assertLess(per_credit, 0.04)

    def test_every_sold_plan_stays_under_35_percent_at_worst_case(self):
        for pid, (credits, month, year) in GRID.items():
            ratio = credits * self.worst / month
            self.assertLess(ratio, 0.35, f"{pid}: {ratio:.1%}")
        # le modele de l'etude : Solo 32,6 %, Trio 32,0 %, Equipe 34,4 %, Pro 34,0 %, Scale 33,7 %
        self.assertAlmostEqual(250 * self.worst / 29, 0.326, places=2)
        self.assertAlmostEqual(900 * self.worst / 99, 0.344, places=2)

    def test_legacy_plans_also_stay_under_35_percent(self):
        for pid, (credits, month, year) in LEGACY.items():
            self.assertLess(credits * self.worst / month, 0.35, pid)

    def test_the_trial_costs_less_than_a_franc_at_worst_case(self):
        self.assertLess(15 * self.worst_per_credit["rapide"], 1.0)

    def test_annual_billing_is_documented_not_hidden(self):
        # a 10 mois payes pour 12 mois de credits, le pire cas depasse 35 % : c'est le prix des « 2 mois offerts » (voir docs/PRICING.md)
        ratios = {pid: credits * self.worst / (year / 12) for pid, (credits, month, year) in GRID.items()}
        self.assertTrue(all(r < 0.45 for r in ratios.values()), ratios)
        self.assertGreater(max(ratios.values()), 0.35)

    def test_enterprise_cap_needs_a_quote_above_the_documented_minimum(self):
        minimum = server.ENTERPRISE_DEFAULT_CREDITS * self.worst / 0.35
        self.assertGreater(minimum, server.PLAN_CATALOG["scale"]["priceChf"]["month"])
        self.assertLess(minimum, 1200)                                        # ~1 080 CHF par mois pour 10 000 credits (a ecrire dans docs/PRICING.md)


if __name__ == "__main__":
    ok = unittest.main(verbosity=2, exit=False).result.wasSuccessful()
    sys.exit(0 if ok else 1)
