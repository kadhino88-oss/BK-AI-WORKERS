# -*- coding: utf-8 -*-
"""Montants envoyes a Stripe : core/integrations/Stripe-Adapter.ps1 (Get-StripeCheckoutFields, fonction PURE : aucun appel reseau, aucun secret) construit
les champs d'une Checkout Session. Sans Price ID enregistre pour le forfait, le montant du catalogue du serveur (centimes de CHF, annuel = 10 mois) part en
price_data ; avec un Price ID, rien ne change (comportement d'origine). Ce test relie les deux langages : le montant produit par server.plan_price_cents est
celui que PowerShell met dans unit_amount.

Un seul processus PowerShell traite tous les cas (le demarrage de pwsh est lent sur une machine partagee).
PowerShell 7 requis.   python tests/pricing/test_stripe_fields.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import REPO, load_server  # noqa: E402

PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
server, ROOT = load_server("bk_server_stripe")

SCRIPT = r'''
$ErrorActionPreference = "Stop"
. (Join-Path $env:BK_ROOT "core/integrations/Stripe-Adapter.ps1")
$cases = Get-Content -LiteralPath $env:T_CASES -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
$out = @()
foreach ($c in $cases) {
    $a = $c.args
    try {
        $f = Get-StripeCheckoutFields @a
        $r = @{ name = $c.name; ok = $true; fields = $f; body = (ConvertTo-StripeFormBody -Fields $f) }
    } catch {
        $r = @{ name = $c.name; ok = $false; error = $_.Exception.Message }
    }
    $out += $r
}
$resume = Get-StripeResumeFields
$out += @{ name = "resume"; ok = $true; fields = $resume; body = (ConvertTo-StripeFormBody -Fields $resume) }
$out += @{ name = "customers"; ok = $true; ids = @((Get-StripeCustomerId -Customer "cus_A1"), (Get-StripeCustomerId -Customer ([pscustomobject]@{ id = "cus_B2"; email = "x" })),
    (Get-StripeCustomerId -Customer $null), (Get-StripeCustomerId -Customer ([pscustomobject]@{ email = "x" }))) }
[System.IO.File]::WriteAllText($env:T_OUT, ($out | ConvertTo-Json -Depth 6 -AsArray), [System.Text.UTF8Encoding]::new($false))
'''

BASE = dict(PlanId="solo", SuccessUrl="https://app.example/?ok={CHECKOUT_SESSION_ID}", CancelUrl="https://app.example/?cancel", ClientId="CLI-CUST-AAAAAAAA", PlanName="Solo")


def case(name, **args):
    return {"name": name, "args": {**BASE, **args}}


def cases():
    out = [case("solo-month", Interval="month", AmountCents=2900), case("solo-year", Interval="year", AmountCents=29000)]
    for pid in ("solo", "trio", "equipe", "pro", "scale"):
        for interval in ("month", "year"):
            out.append(case(f"{pid}-{interval}", PlanId=pid, PlanName=server.PLAN_CATALOG[pid]["name"], Interval=interval,
                            AmountCents=server.plan_price_cents(pid, interval)))
    out += [case("price-id", PlanId="pro", Interval="month", PriceId="price_test_123", AmountCents=13900),
            case("price-id-no-amount", PlanId="pro", Interval="month", PriceId="price_test_123")]
    for cents in (0, 1, 99, 10000001, -2900):
        out.append(case(f"bad-{cents}", Interval="month", AmountCents=cents))
    out += [case("no-amount", Interval="month"),
            case("coupon-month", Interval="month", AmountCents=2900, LaunchCoupon="  LANCEMENT30 "),
            case("coupon-year", Interval="year", AmountCents=29000, LaunchCoupon="LANCEMENT30"),
            case("no-coupon", Interval="month", AmountCents=2900),
            case("customer", Interval="month", AmountCents=2900, CustomerId="cus_ABC123"),
            case("bad-customer", Interval="month", AmountCents=2900, CustomerId="cus_x&mode=payment"),
            case("injection", Interval="month", AmountCents=2900, PlanName="Solo&line_items[1][price]=price_x&mode=payment"),
            case("empty-name", Interval="month", AmountCents=2900, PlanName="&=[]")]
    return out


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class StripeFields(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        tmp = tempfile.mkdtemp(prefix="bkstripe-")
        cls.addClassCleanup(shutil.rmtree, tmp, True)
        cases_path, out_path = os.path.join(tmp, "cases.json"), os.path.join(tmp, "out.json")
        with open(cases_path, "w", encoding="utf-8") as f:
            json.dump(cases(), f, ensure_ascii=False)
        env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k not in ("BK_SECRETS_DIR", "BK_STRIPE_LAUNCH_COUPON")}
        env.update(BK_ROOT=REPO, T_CASES=cases_path, T_OUT=out_path)
        p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-Command", SCRIPT], capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=300)
        assert os.path.isfile(out_path), p.stderr[-800:] + p.stdout[-300:]
        with open(out_path, encoding="utf-8") as f:
            cls.r = {row["name"]: row for row in json.load(f)}

    def f(self, name):
        row = self.r[name]
        self.assertTrue(row["ok"], row.get("error"))
        return row["fields"]

    def test_a_plan_without_price_id_is_sent_with_the_catalog_amount_in_chf(self):
        f = self.f("solo-month")
        self.assertEqual(f["mode"], "subscription")
        self.assertEqual(f["line_items[0][price_data][currency]"], "chf")
        self.assertEqual(f["line_items[0][price_data][unit_amount]"], "2900")
        self.assertEqual(f["line_items[0][price_data][recurring][interval]"], "month")
        self.assertEqual(f["line_items[0][price_data][product_data][name]"], "BK-AI-WORKERS - Solo (mensuel)")
        self.assertEqual(f["line_items[0][quantity]"], "1")
        self.assertNotIn("line_items[0][price]", f)
        self.assertEqual((f["metadata[bk_plan_id]"], f["metadata[bk_interval]"], f["metadata[bk_client_id]"]), ("solo", "month", "CLI-CUST-AAAAAAAA"))
        self.assertEqual(f["success_url"], BASE["SuccessUrl"])
        self.assertEqual(f["cancel_url"], BASE["CancelUrl"])

    def test_annual_is_sent_as_a_yearly_recurrence(self):
        f = self.f("solo-year")
        self.assertEqual(f["line_items[0][price_data][unit_amount]"], "29000")
        self.assertEqual(f["line_items[0][price_data][recurring][interval]"], "year")
        self.assertIn("(annuel)", f["line_items[0][price_data][product_data][name]"])
        self.assertEqual(f["metadata[bk_interval]"], "year")

    def test_the_amount_powershell_sends_is_the_amount_python_computes_for_every_plan(self):
        for pid in ("solo", "trio", "equipe", "pro", "scale"):
            for interval in ("month", "year"):
                cents = server.plan_price_cents(pid, interval)
                f = self.f(f"{pid}-{interval}")
                self.assertEqual(f["line_items[0][price_data][unit_amount]"], str(cents), (pid, interval))
                self.assertEqual(int(f["line_items[0][price_data][unit_amount]"]), server.PLAN_CATALOG[pid]["priceChf"][interval] * 100)
                self.assertEqual(f["metadata[bk_plan_id]"], pid)
        self.assertEqual(self.f("equipe-month")["line_items[0][price_data][product_data][name]"], "BK-AI-WORKERS - Équipe (mensuel)")

    def test_an_existing_price_id_wins_and_nothing_changes_for_plans_already_on_sale(self):
        for name in ("price-id", "price-id-no-amount"):
            f = self.f(name)
            self.assertEqual(f["line_items[0][price]"], "price_test_123")
            self.assertFalse([k for k in f if "price_data" in k], name)

    def test_no_price_id_and_no_valid_amount_is_refused(self):
        for name in ("bad-0", "bad-1", "bad-99", "bad-10000001", "bad--2900", "no-amount"):
            row = self.r[name]
            self.assertFalse(row["ok"], name)
            self.assertIn("INVALID_AMOUNT", row["error"], name)

    def test_launch_coupon_only_applies_to_monthly(self):
        self.assertEqual(self.f("coupon-month")["discounts[0][coupon]"], "LANCEMENT30")
        self.assertNotIn("discounts[0][coupon]", self.f("coupon-year"))
        self.assertNotIn("discounts[0][coupon]", self.f("no-coupon"))

    def test_a_known_stripe_customer_is_reused_and_a_malformed_one_is_dropped(self):
        # 2e revue : sans client Stripe, chaque abonnement en creait un nouveau et le credit de prorata d'une montee en gamme restait sur l'ancien.
        self.assertEqual(self.f("customer")["customer"], "cus_ABC123")
        self.assertNotIn("customer", self.f("solo-month"))
        bad = self.f("bad-customer")
        self.assertNotIn("customer", bad)
        self.assertNotIn("mode=payment", self.r["bad-customer"]["body"])

    def test_resuming_a_cancelled_subscription_only_clears_cancel_at_period_end(self):
        self.assertEqual(self.f("resume"), {"cancel_at_period_end": "false"})
        self.assertEqual(self.r["resume"]["body"], "cancel_at_period_end=false")

    def test_the_customer_id_is_read_from_a_plain_or_an_expanded_customer_field(self):
        self.assertEqual(self.r["customers"]["ids"], ["cus_A1", "cus_B2", None, None])

    def test_the_bridge_exposes_the_subscription_read_and_resume_actions_and_the_customer(self):
        with open(os.path.join(REPO, "dashboard", "Stripe-Bridge.ps1"), encoding="utf-8-sig") as f:
            bridge = f.read()
        for action in ("get-subscription", "resume-subscription"):
            self.assertIn(f'"{action}"', bridge)
        self.assertIn("-CustomerId $CustomerId", bridge)

    def test_the_plan_name_cannot_inject_form_fields(self):
        f = self.f("injection")
        name = f["line_items[0][price_data][product_data][name]"]
        for bad in ("&", "=", "[", "]"):
            self.assertNotIn(bad, name)
        self.assertEqual(f["mode"], "subscription")
        body = self.r["solo-month"]["body"]
        self.assertIn("line_items%5B0%5D%5Bprice_data%5D%5Bunit_amount%5D=2900", body)       # crochets encodes : ce que Stripe attend
        body = self.r["injection"]["body"]
        self.assertEqual(body.count("mode=subscription"), 1)
        self.assertNotIn("mode=payment", body)
        self.assertNotIn("line_items%5B1%5D", body)
        self.assertEqual(self.f("empty-name")["line_items[0][price_data][product_data][name]"], "BK-AI-WORKERS - solo (mensuel)")      # nom vide : repli sur l'id


SUB_SCRIPT = r'''
$ErrorActionPreference = "Stop"
. (Join-Path $env:BK_ROOT "core/integrations/Stripe-Adapter.ps1")
$subs = Get-Content -LiteralPath $env:T_SUBS -Raw -Encoding UTF8 | ConvertFrom-Json
$out = [ordered]@{}
foreach ($prop in $subs.PSObject.Properties) {
    $out["summary-" + $prop.Name] = ConvertTo-StripeSubscriptionSummary -Subscription $prop.Value
}
$out["summary-null"] = ConvertTo-StripeSubscriptionSummary -Subscription $null
$out["cancel-end"] = Get-StripeCancelFields -AtPeriodEnd
$out["cancel-end-body"] = ConvertTo-StripeFormBody -Fields (Get-StripeCancelFields -AtPeriodEnd)
$out["cancel-prorate"] = Get-StripeCancelFields -Prorate
$out["cancel-prorate-body"] = ConvertTo-StripeFormBody -Fields (Get-StripeCancelFields -Prorate)
$out["cancel-both"] = Get-StripeCancelFields -AtPeriodEnd -Prorate
$out["cancel-plain-count"] = (Get-StripeCancelFields).Count
# Requetes REELLEMENT construites par Remove-StripeSubscription (faux appel reseau : rien ne part vers Stripe).
$global:BKCalls = @()
function Test-StripeConfigured { return $true }
function Get-StripeSecret { return [pscustomobject]@{ secret_key = "sk_test_fake" } }
function Invoke-RestMethod {
    param([string]$Uri, [string]$Method, $Headers, [int]$TimeoutSec, [string]$ContentType, $Body)
    $global:BKCalls += @{ uri = $Uri; method = $Method; contentType = $ContentType; body = $Body }
    return [pscustomobject]@{ id = "sub_fake1"; status = "canceled" }
}
$null = Remove-StripeSubscription -SubscriptionId "sub_fake1" -Prorate
$null = Remove-StripeSubscription -SubscriptionId "sub_fake1" -AtPeriodEnd
$null = Remove-StripeSubscription -SubscriptionId "sub_fake1"
$out["requests"] = $global:BKCalls
[System.IO.File]::WriteAllText($env:T_OUT, ($out | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
'''

# 2026-12-02T08:00:00Z = 1796198400 (secondes Unix) ; 2026-11-02T08:00:00Z = 1793606400
SUBSCRIPTIONS = {
    "legacy-api": {"id": "sub_legacy_1", "status": "active", "cancel_at_period_end": False, "current_period_end": 1793606400},
    "items-api": {"id": "sub_items_1", "status": "active", "cancel_at_period_end": True,
                  "items": {"data": [{"id": "si_1", "current_period_end": 1796198400}]}},
    "canceled": {"id": "sub_gone_1", "status": "canceled", "cancel_at_period_end": False},
    "id-only": "sub_text_only_1",
}


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class StripeSubscriptionHelpers(unittest.TestCase):
    """Relecture de l'abonnement et resiliation (revue du 2026-10-13) : fonctions PURES, sans reseau ni secret."""

    @classmethod
    def setUpClass(cls):
        tmp = tempfile.mkdtemp(prefix="bkstripe-sub-")
        cls.addClassCleanup(shutil.rmtree, tmp, True)
        subs_path, out_path = os.path.join(tmp, "subs.json"), os.path.join(tmp, "out.json")
        with open(subs_path, "w", encoding="utf-8") as f:
            json.dump(SUBSCRIPTIONS, f)
        env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k != "BK_SECRETS_DIR"}
        env.update(BK_ROOT=REPO, T_SUBS=subs_path, T_OUT=out_path)
        p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-Command", SUB_SCRIPT], capture_output=True, text=True, encoding="utf-8",
                           errors="replace", env=env, timeout=300)
        assert os.path.isfile(out_path), p.stderr[-800:] + p.stdout[-300:]
        with open(out_path, encoding="utf-8") as f:
            cls.r = json.load(f)

    def test_the_period_end_is_read_from_either_api_shape_as_iso_utc(self):
        self.assertEqual(self.r["summary-legacy-api"], {"Id": "sub_legacy_1", "Status": "active", "CancelAtPeriodEnd": False, "CurrentPeriodEnd": "2026-11-02T08:00:00Z"})
        self.assertEqual(self.r["summary-items-api"], {"Id": "sub_items_1", "Status": "active", "CancelAtPeriodEnd": True, "CurrentPeriodEnd": "2026-12-02T08:00:00Z"})

    def test_a_canceled_or_unexpanded_subscription_is_reported_as_such(self):
        self.assertEqual((self.r["summary-canceled"]["Status"], self.r["summary-canceled"]["CurrentPeriodEnd"]), ("canceled", None))
        self.assertEqual(self.r["summary-id-only"], {"Id": "sub_text_only_1", "Status": None, "CancelAtPeriodEnd": False, "CurrentPeriodEnd": None})
        self.assertEqual(self.r["summary-null"], {"Id": None, "Status": None, "CancelAtPeriodEnd": False, "CurrentPeriodEnd": None})

    def test_cancelling_at_period_end_never_deletes_and_a_replacement_credits_the_unused_time(self):
        self.assertEqual(self.r["cancel-end"], {"cancel_at_period_end": "true"})
        self.assertEqual(self.r["cancel-end-body"], "cancel_at_period_end=true")
        self.assertEqual(self.r["cancel-prorate"], {"prorate": "true", "invoice_now": "true"})
        self.assertEqual(self.r["cancel-prorate-body"], "prorate=true&invoice_now=true")
        self.assertEqual(self.r["cancel-both"], {"cancel_at_period_end": "true"})      # la resiliation de fin de periode l'emporte : rien n'est supprime
        self.assertEqual(self.r["cancel-plain-count"], 0)

    def test_the_prorated_delete_carries_its_parameters_in_the_url_and_never_in_a_body(self):
        """La doc de l'API Stripe ne montre aucun corps pour DELETE ; les SDK officiels mettent les parametres dans l'URL (controle du 2026-10-19)."""
        prorate, at_end, plain = self.r["requests"]
        self.assertEqual(prorate["method"], "DELETE")
        self.assertEqual(prorate["uri"], "https://api.stripe.com/v1/subscriptions/sub_fake1?prorate=true&invoice_now=true")
        self.assertIsNone(prorate["body"])
        self.assertFalse(prorate["contentType"])
        self.assertEqual(at_end["method"], "POST")                      # fin de periode : mise a jour (POST) avec corps, jamais un DELETE
        self.assertEqual(at_end["uri"], "https://api.stripe.com/v1/subscriptions/sub_fake1")
        self.assertEqual(at_end["body"], "cancel_at_period_end=true")
        self.assertEqual(at_end["contentType"], "application/x-www-form-urlencoded")
        self.assertEqual(plain["method"], "DELETE")                     # resiliation immediate simple : aucun parametre
        self.assertEqual(plain["uri"], "https://api.stripe.com/v1/subscriptions/sub_fake1")
        self.assertIsNone(plain["body"])


if __name__ == "__main__":
    ok = unittest.main(verbosity=2, exit=False).result.wasSuccessful()
    sys.exit(0 if ok else 1)
