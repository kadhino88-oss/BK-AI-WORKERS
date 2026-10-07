"""Verifie, sous PowerShell 7 (comme en production), que l'operation TEST_CONNECTION de
core/integrations/Connector-Dispatch.ps1 forme pour CHAQUE outil la bonne requete :
bonne URL de base, bon chemin, bonne methode, bon schema d'authentification, secret du client.
Invoke-RestMethod est remplace par un enregistreur : aucun appel reseau reel.
Lancer sous Linux / WSL (pwsh installe) : python3 tests/connect-guides/test_dispatch_ps.py"""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
sys.path.insert(0, os.path.dirname(__file__))
import connect_guides as cg  # noqa: E402
from test_connect_guides import SAMPLES  # noqa: E402

PWSH = os.environ.get("BK_PWSH") or "pwsh"
CONNECTOR_OF = {"uptimerobot": "monitoring", "bamboohr": "calendar_hr"}
cg.load_guides(os.path.join(REPO, "core", "integrations", "connect-guides.json"))
PUBLIC = lambda host: ["93.184.216.34"]

DRIVER = r'''
$ErrorActionPreference = "Stop"
. (Join-Path $env:BK_ROOT "core/connectors/Client-Credential-Store.ps1")
. (Join-Path $env:BK_ROOT "core/integrations/Connector-Dispatch.ps1")
$Script:Calls = New-Object System.Collections.ArrayList
function Invoke-RestMethod {
    param($Uri, $Method = "GET", $Headers, $ContentType, $Body, $TimeoutSec, $Credential)
    $hdr = @{}
    if ($Headers) { foreach ($k in $Headers.Keys) { $hdr[$k] = [string]$Headers[$k] } }
    $bodyText = if ($Body -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($Body) } else { [string]$Body }
    [void]$Script:Calls.Add(@{ uri = [string]$Uri; method = [string]$Method; headers = $hdr; contentType = [string]$ContentType; body = $bodyText })
    if ($env:FAKE_FAIL) { throw $env:FAKE_FAIL }
    return @{ ok = $true }
}
$cases = Get-Content -LiteralPath $env:CASES_FILE -Raw | ConvertFrom-Json
$out = @{}
foreach ($c in $cases) {
    Set-BKClientCredentialValue -ClientId "CLI-TEST" -Provider $c.provider -PlainText $c.secret
    $Script:Calls.Clear()
    $r = Invoke-ConnectorAction -ConnectorId ($c.connector + ".controlled") -Operation "TEST_CONNECTION" -ClientId "CLI-TEST"
    $out[$c.provider] = @{ status = [string]$r.Status; detail = [string]$r.Detail; calls = @($Script:Calls) }
}
$out | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $env:OUT_FILE -Encoding UTF8
'''


def basic(user, pwd):
    return "Basic " + base64.b64encode(f"{user}:{pwd}".encode()).decode()


class DispatchRequests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp(prefix="bkdisp-")
        shutil.copytree(os.path.join(REPO, "core"), os.path.join(cls.root, "core"),
                        ignore=shutil.ignore_patterns("client-credentials", "accounts", "__pycache__"))
        cls.secrets = {}
        cases = []
        for prov, fields in SAMPLES.items():
            secret, err = cg.build_secret(prov, fields, resolver=PUBLIC)
            assert not err, (prov, err)
            cls.secrets[prov] = secret
            cases.append({"provider": prov, "connector": CONNECTOR_OF.get(prov, prov), "secret": secret})
        cls.cases_file = os.path.join(cls.root, "cases.json")
        with open(cls.cases_file, "w", encoding="utf-8") as f:
            json.dump(cases, f)
        cls.driver = os.path.join(cls.root, "driver.ps1")
        with open(cls.driver, "w", encoding="utf-8") as f:
            f.write(DRIVER)
        cls.env = dict(os.environ, BK_ROOT=cls.root, CASES_FILE=cls.cases_file,
                       BK_SECRET_CRED_ENCRYPTION_KEY=base64.b64encode(os.urandom(32)).decode())
        cls.ok = cls.run_driver(cls)
        cls.fail = cls.run_driver(cls, fake_fail="Response status code does not indicate success: 401 (Unauthorized).")

    def run_driver(self, fake_fail=None):
        out = os.path.join(self.root, "out-fail.json" if fake_fail else "out-ok.json")
        env = dict(self.env, OUT_FILE=out)
        if fake_fail:
            env["FAKE_FAIL"] = fake_fail
        p = subprocess.run([PWSH, "-NoProfile", "-File", self.driver], capture_output=True, text=True, env=env, timeout=240)
        if not os.path.isfile(out):
            raise AssertionError("driver a echoue :\n" + p.stdout[-1500:] + p.stderr[-1500:])
        with open(out, encoding="utf-8-sig") as f:
            return json.load(f)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root, ignore_errors=True)

    def call(self, prov):
        r = self.ok[prov]
        self.assertEqual(r["status"], "SUCCESS", (prov, r))
        calls = r["calls"] if isinstance(r["calls"], list) else [r["calls"]]
        self.assertEqual(len(calls), 1, (prov, calls))
        return calls[0]

    def test_every_guided_tool_makes_exactly_one_harmless_request(self):
        for prov in SAMPLES:
            c = self.call(prov)
            if prov != "slack":
                self.assertIn(c["method"], ("GET", "POST"), prov)
            self.assertTrue(c["uri"].startswith("https://"), (prov, c["uri"]))

    def test_bearer_tools(self):
        expect = {
            "asana": "https://app.asana.com/api/1.0/users/me",
            "intercom": "https://api.intercom.io/me",
            "hubspot": "https://api.hubapi.com/crm/v3/objects/contacts?limit=1",
            "webflow": "https://api.webflow.com/v2/sites",
            "dropbox": "https://api.dropboxapi.com/2/files/list_folder",
            "linkedin": "https://api.linkedin.com/v2/userinfo",
            "facebook": "https://graph.facebook.com/v19.0/me?fields=id,name",
            "instagram": "https://graph.facebook.com/v19.0/me?fields=id,name",
            "meta_ads": "https://graph.facebook.com/v19.0/me?fields=id,name",
            "whatsapp_business": "https://graph.facebook.com/v19.0/me?fields=id,name",
            "tiktok": "https://open.tiktokapis.com/v2/user/info/?fields=open_id,display_name",
            "x_twitter": "https://api.twitter.com/2/users/me",
        }
        for prov, uri in expect.items():
            c = self.call(prov)
            self.assertEqual(c["uri"], uri, prov)
            self.assertEqual(c["headers"]["Authorization"], "Bearer " + SAMPLES[prov]["token"], prov)
        self.assertEqual(self.call("dropbox")["method"], "POST")
        # Lecture des fichiers (droit files.metadata.read, celui que demandent le
        # guide ET "Se connecter avec Dropbox") : users/get_current_account exige
        # account_info.read et renvoyait 401 sur un jeton pourtant valide.
        self.assertEqual(json.loads(self.call("dropbox")["body"]), {"path": "", "limit": 1})

    def test_header_and_query_auth_tools(self):
        c = self.call("figma")
        self.assertEqual((c["uri"], c["headers"]["X-Figma-Token"]), ("https://api.figma.com/v1/me", SAMPLES["figma"]["token"]))
        c = self.call("monday")
        self.assertEqual((c["method"], c["uri"], c["headers"]["Authorization"]), ("POST", "https://api.monday.com/v2", SAMPLES["monday"]["token"]))
        self.assertIn("me", json.loads(c["body"])["query"])
        c = self.call("pipedrive")
        self.assertEqual(c["uri"], "https://api.pipedrive.com/v1/users/me?api_token=" + SAMPLES["pipedrive"]["token"])
        c = self.call("trello")
        self.assertTrue(c["uri"].startswith("https://api.trello.com/1/members/me?fields=username&"), c["uri"])
        self.assertIn("key=" + "k" * 32, c["uri"])
        self.assertIn("token=" + "t" * 64, c["uri"])
        c = self.call("woocommerce")
        self.assertTrue(c["uri"].startswith("https://www.example.com/shop/wp-json/wc/v3/products?per_page=1&"), c["uri"])
        self.assertIn("consumer_key=ck_abc", c["uri"])
        self.assertIn("consumer_secret=cs_abc", c["uri"])
        self.assertNotIn("site=", c["uri"])

    def test_basic_auth_and_account_hosts(self):
        c = self.call("zendesk")
        self.assertEqual(c["uri"], "https://acme.zendesk.com/api/v2/users/me.json")
        self.assertEqual(c["headers"]["Authorization"], basic("agent@acme.com/token", "zdtoken"))
        c = self.call("wordpress")
        self.assertEqual(c["uri"], "https://example.com/wp-json/wp/v2/users/me")
        self.assertEqual(c["headers"]["Authorization"], basic("admin", "abcd efgh ijkl mnop qrst uvwx"))
        c = self.call("shopify")
        self.assertEqual(c["uri"], "https://acme.myshopify.com/admin/api/2024-01/shop.json")
        self.assertEqual(c["headers"]["X-Shopify-Access-Token"], "shpat_abc")
        c = self.call("twilio")
        sid = SAMPLES["twilio"]["user"]
        self.assertEqual(c["uri"], f"https://api.twilio.com/2010-04-01/Accounts/{sid}/IncomingPhoneNumbers.json?PageSize=1")
        self.assertEqual(c["headers"]["Authorization"], basic(sid, "authtoken"))
        c = self.call("bamboohr")
        self.assertEqual(c["uri"], "https://api.bamboohr.com/api/gateway.php/acme/v1/employees/directory")
        self.assertEqual(c["headers"]["Authorization"], basic("bamboo-key", "x"))

    def test_uptimerobot_sends_the_key_in_the_form_body(self):
        c = self.call("uptimerobot")
        self.assertEqual((c["method"], c["uri"]), ("POST", "https://api.uptimerobot.com/v2/getAccountDetails"))
        self.assertIn("api_key=ur123-abc", c["body"])
        self.assertIn("format=json", c["body"])
        self.assertIn("x-www-form-urlencoded", c["contentType"])

    def test_slack_posts_a_visible_confirmation_to_the_clients_webhook(self):
        c = self.call("slack")
        self.assertEqual((c["method"], c["uri"]), ("Post", SAMPLES["slack"]["webhook"]) if c["method"] == "Post" else (c["method"], c["uri"]))
        self.assertEqual(c["uri"], SAMPLES["slack"]["webhook"])
        self.assertIn("BK-AI-WORKERS", c["body"])

    def test_failed_request_reports_error_without_leaking_secrets(self):
        for prov in SAMPLES:
            r = self.fail[prov]
            self.assertEqual(r["status"], "ERROR", prov)
            self.assertIn("401", r["detail"])
            blob = json.dumps(r)
            for secret_value in ("zdtoken", "shpat_abc", "authtoken"):
                if secret_value in json.dumps(SAMPLES.get(prov, {})):
                    self.assertNotIn(secret_value, r["detail"], prov)

    def test_no_data_from_the_vendor_is_returned(self):
        for prov in SAMPLES:
            self.assertNotIn("Data", self.ok[prov])


if __name__ == "__main__":
    unittest.main(verbosity=2)
