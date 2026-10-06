"""Tests de la connexion guidee des outils (dashboard/connect_guides.py + connect-guides.json).
Hors ligne : aucune requete reseau (la resolution DNS est remplacee par un faux).
Lancer : python tests/connect-guides/test_connect_guides.py"""
import json
import os
import re
import sys
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import connect_guides as cg  # noqa: E402

GUIDES_PATH = os.path.join(REPO, "core", "integrations", "connect-guides.json")
cg.load_guides(GUIDES_PATH)

PUBLIC = lambda host: ["93.184.216.34"]
SAMPLES = {
    "slack": {"webhook": "https://hooks.slack.com/services/T000/B000/XXXXXXXX"},
    "trello": {"key": "k" * 32, "token": "t" * 64},
    "asana": {"token": "1/12345:abcdef"},
    "monday": {"token": "eyJhbGciOi"},
    "zendesk": {"subdomain": "acme.zendesk.com", "email": "agent@acme.com", "token": "zdtoken"},
    "intercom": {"token": "dG9rOjEyMw=="},
    "figma": {"token": "figd_abc"},
    "hubspot": {"token": "pat-eu1-abc"},
    "pipedrive": {"token": "pdtoken"},
    "webflow": {"token": "wf_abc"},
    "shopify": {"shop": "https://acme.myshopify.com/admin", "token": "shpat_abc"},
    "woocommerce": {"site": "https://www.Example.com/shop/?x=1", "consumer_key": "ck_abc", "consumer_secret": "cs_abc"},
    "wordpress": {"site": "example.com", "user": "admin", "pass": "abcd efgh ijkl mnop qrst uvwx"},
    "dropbox": {"token": "sl.abc"},
    "linkedin": {"token": "AQV123"},
    "facebook": {"token": "EAAB123"},
    "instagram": {"token": "EAAB123"},
    "tiktok": {"token": "act.abc"},
    "x_twitter": {"token": "abc"},
    "meta_ads": {"token": "EAAB123"},
    "whatsapp_business": {"token": "EAAB123"},
    "twilio": {"user": "AC" + "0123456789abcdef" * 2, "pass": "authtoken", "from": "+41 79 123 45 67"},
    "uptimerobot": {"api_key": "ur123-abc"},
    "bamboohr": {"companyDomain": "acme.bamboohr.com", "apiKey": "bamboo-key"},
}


class GuideIntegrity(unittest.TestCase):
    def test_every_guide_has_a_sample_and_valid_structure(self):
        guides = {k: v for k, v in json.load(open(GUIDES_PATH, encoding="utf-8")).items() if not k.startswith("_")}
        self.assertEqual(set(guides), set(SAMPLES))
        for prov, g in guides.items():
            self.assertTrue(g["steps"], prov)
            self.assertTrue(g["fields"], prov)
            self.assertIn(g["compose"], ("raw", "json", "zendesk", "bamboohr"), prov)
            if g["compose"] == "raw":
                self.assertIn(g["rawField"], [f["key"] for f in g["fields"]], prov)
            self.assertTrue(g.get("helpUrl", "").startswith("https://"), prov)
            self.assertTrue(g.get("test"), prov)
            for f in g["fields"]:
                self.assertIn(f.get("kind"), ("text", "secret", "host", "subdomain", "email", "phone"), prov)

    def test_guided_providers_are_client_configurable_in_server(self):
        src = open(os.path.join(REPO, "dashboard", "server.py"), encoding="utf-8").read()
        block = re.search(r"CLIENT_CONNECTOR_PROVIDERS = \{(.*?)\}", src, re.S).group(1)
        providers = set(re.findall(r'"([a-z_]+)"', block))
        self.assertTrue(set(SAMPLES) <= providers, set(SAMPLES) - providers)

    def test_public_guide_never_exposes_test_or_compose_logic(self):
        for prov in SAMPLES:
            pg = cg.public_guide(prov)
            self.assertNotIn("test", pg)
            self.assertNotIn("compose", pg)
            self.assertTrue(all(set(f) <= {"key", "label", "kind", "placeholder"} for f in pg["fields"]))
        self.assertIn("message de test", cg.public_guide("slack")["testNote"])
        self.assertIsNone(cg.public_guide("asana")["testNote"])
        self.assertIsNone(cg.public_guide("nope"))


class SecretBuilding(unittest.TestCase):
    def build(self, prov, fields=None):
        return cg.build_secret(prov, fields if fields is not None else SAMPLES[prov], resolver=PUBLIC)

    def test_every_sample_builds_a_secret(self):
        for prov in SAMPLES:
            secret, err = self.build(prov)
            self.assertIsNone(err, (prov, err))
            self.assertTrue(secret, prov)

    def test_raw_providers_store_the_bare_token(self):
        for prov in ("asana", "monday", "intercom", "figma", "hubspot", "pipedrive", "webflow", "dropbox", "linkedin", "facebook", "tiktok", "x_twitter"):
            secret, _ = self.build(prov)
            self.assertEqual(secret, SAMPLES[prov]["token"])
        self.assertEqual(self.build("slack")[0], SAMPLES["slack"]["webhook"])

    def test_json_shapes_match_what_the_adapter_reads(self):
        z = json.loads(self.build("zendesk")[0])
        self.assertEqual(z, {"subdomain": "acme", "user": "agent@acme.com/token", "pass": "zdtoken"})
        s = json.loads(self.build("shopify")[0])
        self.assertEqual(s, {"shop": "acme", "token": "shpat_abc"})
        w = json.loads(self.build("woocommerce")[0])
        self.assertEqual(w, {"site": "www.example.com/shop", "consumer_key": "ck_abc", "consumer_secret": "cs_abc"})
        p = json.loads(self.build("wordpress")[0])
        self.assertEqual((p["site"], p["user"], p["pass"]), ("example.com", "admin", "abcd efgh ijkl mnop qrst uvwx"))
        t = json.loads(self.build("twilio")[0])
        self.assertEqual((t["user"][:2], t["from"]), ("AC", "+41791234567"))
        b = json.loads(self.build("bamboohr")[0])
        self.assertEqual(b, {"user": "bamboo-key", "pass": "x", "companyDomain": "acme"})
        self.assertEqual(json.loads(self.build("uptimerobot")[0]), {"api_key": "ur123-abc"})
        self.assertEqual(json.loads(self.build("trello")[0]), {"key": "k" * 32, "token": "t" * 64})

    def test_missing_or_blank_field_is_reported_with_its_name(self):
        secret, err = self.build("trello", {"key": "abc", "token": "   "})
        self.assertIsNone(secret)
        self.assertEqual(err["field"], "token")
        secret, err = self.build("asana", {})
        self.assertEqual(err["field"], "token")

    def test_control_characters_and_oversize_rejected(self):
        self.assertEqual(self.build("asana", {"token": "abc\ndef"})[1]["field"], "token")
        self.assertEqual(self.build("asana", {"token": "a" * 2001})[1]["field"], "token")
        self.assertEqual(self.build("asana", {"token": "a\x00b"})[1]["field"], "token")

    def test_quotes_around_a_pasted_token_are_stripped(self):
        self.assertEqual(self.build("asana", {"token": ' "abc123" '})[0], "abc123")

    def test_format_checks(self):
        self.assertEqual(self.build("slack", {"webhook": "https://evil.test/hook"})[1]["field"], "webhook")
        self.assertEqual(self.build("twilio", {"user": "XX123", "pass": "p", "from": "+41791234567"})[1]["field"], "user")
        self.assertEqual(self.build("twilio", {**SAMPLES["twilio"], "from": "0791234567"})[1]["field"], "from")
        self.assertEqual(self.build("zendesk", {**SAMPLES["zendesk"], "email": "pas-un-email"})[1]["field"], "email")

    def test_phone_normalisation(self):
        self.assertEqual(cg.normalize_phone("00 41 79 123 45 67", "from"), "+41791234567")
        self.assertEqual(cg.normalize_phone("+41 (79) 123-45-67", "from"), "+41791234567")
        with self.assertRaises(cg.FieldError):
            cg.normalize_phone("+0123", "from")


class SsrfAndAddresses(unittest.TestCase):
    def host(self, raw, resolver=PUBLIC, allow_path=True):
        return cg.normalize_host(raw, "site", allow_path=allow_path, resolver=resolver)

    def test_url_is_reduced_to_a_host(self):
        self.assertEqual(self.host("https://User.Example.com/"), "user.example.com")
        self.assertEqual(self.host("example.com/blog/"), "example.com/blog")
        self.assertEqual(self.host("example.com/blog", allow_path=False), "example.com")
        self.assertEqual(self.host("http://example.com/wp-admin/index.php?x=1#y"), "example.com")
        self.assertEqual(self.host("https://example.com/blog/wp-login.php"), "example.com/blog")
        self.assertEqual(self.host("example.com/a/b/c/d/e"), "example.com")          # chemin trop profond : ignore

    def test_internal_and_dangerous_targets_are_rejected(self):
        bad = ["localhost", "127.0.0.1", "http://169.254.169.254/latest/meta-data", "10.0.0.5", "[::1]", "app", "app:8787",
               "example.com:8080", "user:pw@example.com", "intranet.local", "host.internal", "x.localhost", "0x7f000001",
               "2130706433", "example", "-bad.example.com", "exa mple.com", "example..com"]
        for b in bad:
            with self.assertRaises(cg.FieldError, msg=b):
                self.host(b)

    def test_names_resolving_to_private_addresses_are_rejected(self):
        for ip in ("127.0.0.1", "10.1.2.3", "172.16.0.9", "192.168.1.1", "169.254.169.254", "::1", "fd00::1", "100.64.0.1", "0.0.0.0"):
            with self.assertRaises(cg.FieldError, msg=ip):
                self.host("rebind.example.com", resolver=lambda h, ip=ip: [ip])
        with self.assertRaises(cg.FieldError):                       # une seule adresse privee parmi plusieurs suffit
            self.host("mixed.example.com", resolver=lambda h: ["93.184.216.34", "10.0.0.1"])
        with self.assertRaises(cg.FieldError):                       # nom introuvable
            self.host("nx.example.com", resolver=lambda h: (_ for _ in ()).throw(OSError("nxdomain")))

    def test_subdomain_is_tied_to_the_vendor_domain(self):
        f = {"key": "shop", "kind": "subdomain", "suffix": "myshopify.com"}
        self.assertEqual(cg.normalize_value(f, "acme"), "acme")
        self.assertEqual(cg.normalize_value(f, "ACME.myshopify.com"), "acme")
        self.assertEqual(cg.normalize_value(f, "https://acme.myshopify.com/admin"), "acme")
        for bad in ("evil.com", "acme.evil.com", "acme.myshopify.com.evil.com", "ac me", "-acme", "acme-", "", "x" * 70):
            with self.assertRaises(cg.FieldError, msg=bad):
                cg.normalize_value(f, bad)


class TestErrorClassification(unittest.TestCase):
    def test_kinds(self):
        c = lambda d: cg.classify_test_error("Asana", d)[0]
        self.assertEqual(c("Response status code does not indicate success: 401 (Unauthorized)."), "auth")
        self.assertEqual(c("The remote server returned an error: (403) Forbidden."), "permission")
        self.assertEqual(c("Response status code does not indicate success: 404 (Not Found)."), "notfound")
        self.assertEqual(c("No such host is known."), "notfound")
        self.assertEqual(c("The request was canceled due to the configured HttpClient.Timeout"), "transient")
        self.assertEqual(c("Something unexpected"), "other")
        self.assertEqual(c("The operation has timed out."), "transient")
        self.assertEqual(c("429 Too Many Requests"), "transient")
        self.assertEqual(c(""), "other")

    def test_messages_are_french_and_never_echo_the_raw_error(self):
        kind, msg = cg.classify_test_error("Trello", "401 Unauthorized key=SECRETKEY token=SECRETTOKEN")
        self.assertIn("Trello", msg)
        self.assertNotIn("SECRET", msg)


if __name__ == "__main__":
    unittest.main(verbosity=2)
