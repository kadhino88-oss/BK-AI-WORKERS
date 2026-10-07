# -*- coding: utf-8 -*-
"""Tests des pages de confiance (dashboard/trust_pages.py) : chaque affirmation de la page Securite doit etre
adossee au code, aucun mot de certification ne doit etre invente, la version anglaise doit etre complete.
Lancer : python tests/trust/test_trust_pages.py
Sans reseau, sans serveur. (Le test de bout en bout avec un vrai serveur est tests/trust/e2e_server.py.)"""
import ast
import datetime
import glob
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from html.parser import HTMLParser

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
sys.path.insert(0, HERE)
import trust_pages  # noqa: E402
import seo_pages  # noqa: E402
import check_certification_claims as ccc  # noqa: E402

EVIDENCE = json.load(open(os.path.join(HERE, "claims-evidence.json"), encoding="utf-8"))
EVIDENCE.pop("_comment", None)
EMPTY_PAYLOAD = {"status": "unknown", "components": [], "days": [], "incidents": [], "uptime": {}, "measuredSinceUtc": None}
HAS_NODE = shutil.which("node") is not None


def read(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8-sig", newline=None) as f:        # newline=None : CRLF -> LF
        return f.read()


SEC = trust_pages.render_security_page()
STA = trust_pages.render_status_page(EMPTY_PAYLOAD)


class TextNodes(HTMLParser):
    """Noeuds texte tels que i18n.js les voit : hors script/style et hors data-no-i18n ; restreint a <main> si demande."""

    def __init__(self, main_only=True):
        super().__init__(convert_charrefs=True)
        self.nodes, self._skip, self._noi18n, self._main, self.main_only = [], 0, [], 0, main_only
        self._depth = 0
        self._stack = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        voids = {"meta", "link", "br", "img", "input", "hr"}
        if tag in voids:
            return
        self._stack.append((tag, "data-no-i18n" in a))
        if tag in ("script", "style", "noscript") and tag != "noscript":
            self._skip += 1
        if tag == "main":
            self._main += 1

    def handle_endtag(self, tag):
        while self._stack:
            t, noi = self._stack.pop()
            if t in ("script", "style"):
                self._skip -= 1
            if t == "main":
                self._main -= 1
            if t == tag:
                break

    def handle_data(self, data):
        if self._skip or any(noi for _, noi in self._stack):
            return
        if self.main_only and not self._main:
            return
        t = re.sub(r"\s+", " ", data).strip()
        if t:
            self.nodes.append(t)


def text_nodes(page, main_only=True):
    p = TextNodes(main_only)
    p.feed(page)
    return p.nodes


def dictionary():
    d = {}
    for name in ("i18n-en.js", "i18n-en-legal.js", "i18n-en-trust.js"):
        d.update(ccc.load_translations(os.path.join(REPO, "dashboard", name)))
    return d


def claims_on_pages():
    out = set()
    for page in (SEC, STA):
        for attr in re.findall(r'data-claim="([^"]*)"', page):
            out.update(attr.split())
    return out


def _function_source(path, source, name):
    tree = ast.parse(source)
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return ast.get_source_segment(source, node)
    return None


def check_evidence(claim):
    """-> liste de problemes (vide si la preuve tient)."""
    problems = []
    for chk in EVIDENCE[claim]:
        if "absent_files" in chk:
            for pat in chk["absent_files"]:
                found = glob.glob(os.path.join(REPO, pat), recursive=True)
                if found:
                    problems.append(f"fichier present qui contredit '{claim}' : {os.path.relpath(found[0], REPO)} (relire la page)")
            continue
        rel = chk["file"]
        if not os.path.isfile(os.path.join(REPO, rel)):
            problems.append(f"{rel} introuvable")
            continue
        src = read(rel)
        scope = src
        if "function" in chk:
            scope = _function_source(rel, src, chk["function"])
            if scope is None:
                problems.append(f"{rel}: fonction {chk['function']} introuvable")
                continue
        for pat in chk.get("match", []):
            if not re.search(pat, scope, re.M):
                problems.append(f"{rel}{':' + chk['function'] if 'function' in chk else ''}: motif absent {pat!r}")
        for pat in chk.get("absent", []):
            if re.search(pat, scope, re.M):
                problems.append(f"{rel}{':' + chk['function'] if 'function' in chk else ''}: motif present alors qu'il devrait etre absent {pat!r}")
        if "assign_excludes" in chk:
            spec = chk["assign_excludes"]
            tree = ast.parse(src)
            value = None
            for node in tree.body:
                if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == spec["name"] for t in node.targets):
                    value = ast.literal_eval(node.value)
            if value is None:
                problems.append(f"{rel}: constante {spec['name']} introuvable")
            else:
                for v in spec["values"]:
                    if v in value:
                        problems.append(f"{rel}: {spec['name']} contient {v!r}")
    return problems


class ClaimsTests(unittest.TestCase):
    def test_every_claim_on_the_pages_has_evidence_that_holds(self):
        claims = claims_on_pages()
        self.assertGreater(len(claims), 40)
        missing = sorted(c for c in claims if c not in EVIDENCE)
        self.assertEqual(missing, [], "affirmations sans preuve dans claims-evidence.json")
        failures = {}
        for c in sorted(claims):
            if c in EVIDENCE:
                p = check_evidence(c)
                if p:
                    failures[c] = p
        self.assertEqual(failures, {}, json.dumps(failures, ensure_ascii=False, indent=1))

    def test_no_orphan_evidence(self):
        self.assertEqual(sorted(set(EVIDENCE) - claims_on_pages()), [], "preuves qui ne correspondent a aucune affirmation de la page")

    def test_a_changed_code_fact_is_detected(self):
        """Le test ne doit pas etre decoratif : si un fait du code change, la preuve echoue."""
        broken = json.loads(json.dumps(EVIDENCE["rate-limits"]))
        broken[0]["match"][0] = "AUTH_MAX_PER_ACCOUNT = 9999"
        saved = EVIDENCE["rate-limits"]
        EVIDENCE["rate-limits"] = broken
        try:
            self.assertTrue(check_evidence("rate-limits"))
        finally:
            EVIDENCE["rate-limits"] = saved

    def test_negative_claims_flip_when_a_report_is_deposited(self):
        root = tempfile.mkdtemp(prefix="bkev-")
        try:
            os.makedirs(os.path.join(root, "docs", "evidence"))
            self.assertFalse(ccc.has_evidence("soc2", root))
            open(os.path.join(root, "docs", "evidence", "soc2-type1-2027.pdf"), "w").close()
            self.assertTrue(ccc.has_evidence("soc2", root))
        finally:
            shutil.rmtree(root, ignore_errors=True)


class HonestyTests(unittest.TestCase):
    def test_security_page_states_plainly_what_is_not_done(self):
        text = " ".join(text_nodes(SEC))
        for needle in ("Aucun rapport SOC 2", "Aucune certification ISO/IEC 27001", "Aucun test d'intrusion", "Pas d'authentification à deux facteurs",
                       "Aucun engagement de disponibilité (SLA)", "Identifié, non commencé", "À décider"):
            self.assertIn(needle, text)
        en = dictionary()
        for fr, expected in (("Aucun rapport SOC 2, aucune certification ISO/IEC 27001.", "No SOC 2 report, no ISO/IEC 27001 certification."),):
            self.assertEqual(en[fr], expected)

    def test_certification_checker_passes_on_the_real_pages_fr_and_en(self):
        en = dictionary()
        for name, page in (("securite", SEC), ("status", STA)):
            self.assertEqual(ccc.check_html(page), [], name + " fr")
            self.assertEqual(ccc.check_html(page, en), [], name + " en")
        self.assertEqual(ccc.check_plain(trust_pages.render_security_txt("https://bk-ai-workers.com")), [])

    def test_certification_checker_catches_positive_claims(self):
        bad = [
            "<p>Nous sommes certifiés ISO 27001.</p>",
            "<p>BK-AI-WORKERS est conforme SOC 2 Type II.</p>",
            "<li>SOC 2 Type II report available on request</li>",
            "<p>Test d'intrusion réussi par un cabinet indépendant.</p>",
            "<p>Penetration test passed in 2026.</p>",
            "<p>Audited by an independent firm.</p>",
            "<p>Sécurité de niveau bancaire, 100 % sécurisé.</p>",
            "<p>GDPR compliant platform.</p>",
            "<li>HIPAA compliant</li>",
            "<table><tr><td>Audit SOC 2</td><td>Fait</td></tr></table>",
        ]
        for snippet in bad:
            self.assertTrue(ccc.check_html(snippet), snippet)

    def test_certification_checker_accepts_negations_and_not_done(self):
        good = [
            "<p>Aucun rapport SOC 2 n'existe.</p>",
            "<li>Nous ne sommes pas certifiés ISO 27001.</li>",
            "<li>No penetration test has been carried out.</li>",
            "<table><tr><td>Audit SOC 2</td><td>À décider</td><td>Dépend du budget</td></tr></table>",
            "<p>Les certificats TLS sont gérés automatiquement.</p>",
            "<li>Aucune attestation sectorielle (HIPAA, PCI DSS, HDS).</li>",
        ]
        for snippet in good:
            self.assertEqual(ccc.check_html(snippet), [], snippet)

    def test_a_deposited_evidence_document_allows_the_positive_sentence(self):
        root = tempfile.mkdtemp(prefix="bkev-")
        try:
            snippet = "<p>Rapport SOC 2 Type I disponible.</p>"
            self.assertTrue(ccc.check_html(snippet, root=root))
            os.makedirs(os.path.join(root, "docs", "evidence"))
            open(os.path.join(root, "docs", "evidence", "soc2-type1-2027.pdf"), "w").close()
            self.assertEqual(ccc.check_html(snippet, root=root), [])
        finally:
            shutil.rmtree(root, ignore_errors=True)

    def test_checker_cli_exit_codes(self):
        py = sys.executable
        r = subprocess.run([py, os.path.join(HERE, "check_certification_claims.py")], capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        tmp = tempfile.mkdtemp(prefix="bkcc-")
        try:
            bad = os.path.join(tmp, "page.html")
            with open(bad, "w", encoding="utf-8") as f:
                f.write("<p>Notre plateforme est certifiée ISO 27001 et auditée SOC 2.</p>")
            r = subprocess.run([py, os.path.join(HERE, "check_certification_claims.py"), bad], capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(r.returncode, 1, r.stdout)
            self.assertIn("ISO", r.stdout)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_no_invented_social_proof_or_promised_dates(self):
        visible = " ".join(text_nodes(SEC, main_only=False) + text_nodes(STA, main_only=False))
        for pat in (r"(?i)trusted by", r"(?i)ils nous font confiance", r"(?i)nous font confiance", r"(?i)\b\d[\d  ,.]*\s*(clients|customers|utilisateurs|users|entreprises)\b",
                    r"(?i)bientôt|prochainement|coming soon|\bsoon\b", r"\bQ[1-4]\b", r"(?i)d'ici (la fin|\d)", r"(?i)uptime de \d", r"(?i)\b99[.,]\d+\s*%\s*(uptime|de disponibilité)"):
            self.assertIsNone(re.search(pat, visible), pat)
        self.assertNotIn("Market Les Saveurs", SEC + STA)

    def test_pages_publish_no_internal_details(self):
        both = SEC + STA
        self.assertIsNone(re.search(r"\b\d{1,3}(\.\d{1,3}){3}\b", both), "adresse IP")
        for needle in ("C:\\", "/data/app", "/opt/bk", "BK_SECRET_", "sk-ant", "sk_live", "password.hash", "152.228"):
            self.assertNotIn(needle, both)

    def test_brand_rule_bk_entreprise_prices_not_mixed(self):
        self.assertNotRegex(SEC + STA, r"\b(39|99|139|449)\s*CHF")

    def test_roadmap_statuses_are_the_three_honest_labels(self):
        self.assertEqual({s for _, s, _, _ in trust_pages.ROADMAP}, {"done", "todo", "decide"})
        for fr, _, _, claim in [(r[0], r[1], r[2], r[3]) for r in trust_pages.ROADMAP]:
            self.assertTrue(claim in EVIDENCE, fr)


class I18nTests(unittest.TestCase):
    EXEMPT = re.compile(r"^(?:[\W\d_]+|/\S*|\S+@\S+|[A-Za-z0-9_.-]+\.(?:txt|html|json))$")

    def test_every_french_text_of_the_two_pages_has_an_english_translation(self):
        d = dictionary()
        missing = []
        for name, page in (("securite", SEC), ("status", STA)):
            for node in text_nodes(page):
                if self.EXEMPT.match(node) or node in d:
                    continue
                missing.append((name, node))
        self.assertEqual(missing, [], "textes sans traduction : " + json.dumps(missing[:5], ensure_ascii=False))

    def test_translations_are_not_identity_for_real_sentences(self):
        d = ccc.load_translations(os.path.join(REPO, "dashboard", "i18n-en-trust.js"))
        same = [fr for fr, en in d.items() if fr == en and len(fr) > 40]
        self.assertEqual(same, [])

    def test_generated_dictionary_file_is_up_to_date(self):
        trust_pages.render_security_page()
        trust_pages.render_status_page(EMPTY_PAYLOAD)
        with open(os.path.join(REPO, "dashboard", "i18n-en-trust.js"), encoding="utf-8", newline=None) as f:
            on_disk = f.read()
        self.assertEqual(on_disk, trust_pages.build_i18n_js(), "relancer : python dashboard/trust_pages.py --write-i18n")

    @unittest.skipUnless(HAS_NODE, "node absent")
    def test_dictionary_and_status_script_are_valid_javascript(self):
        tmp = tempfile.mkdtemp(prefix="bkjs-")
        try:
            scripts = re.findall(r"<script>(.*?)</script>", STA, re.S)
            self.assertTrue(scripts)
            for i, code in enumerate(scripts):
                p = os.path.join(tmp, f"s{i}.js")
                with open(p, "w", encoding="utf-8") as f:
                    f.write(code)
                r = subprocess.run(["node", "--check", p], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
            r = subprocess.run(["node", "--check", os.path.join(REPO, "dashboard", "i18n-en-trust.js")], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    @unittest.skipUnless(HAS_NODE, "node absent")
    def test_dictionary_loads_in_the_browser_i18n_mechanism(self):
        """i18n-en-trust.js s'ajoute a window.BK_EN sans ecraser les dictionnaires existants."""
        code = ("global.window={BK_EN:{existing:'x'}};"
                "require('fs');eval(require('fs').readFileSync(process.argv[1],'utf8'));"
                "console.log(JSON.stringify({keep:window.BK_EN.existing, n:Object.keys(window.BK_EN).length, sample:window.BK_EN['Sécurité et confiance']}));")
        r = subprocess.run(["node", "-e", code, os.path.join(REPO, "dashboard", "i18n-en-trust.js")], capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual(out["keep"], "x")
        self.assertEqual(out["sample"], "Security and trust")
        self.assertGreater(out["n"], 150)


class SecurityTxtTests(unittest.TestCase):
    def test_fields_and_contact_already_published(self):
        txt = trust_pages.render_security_txt("https://bk-ai-workers.com", now=time.time())
        fields = dict(line.split(": ", 1) for line in txt.splitlines() if line and not line.startswith("#"))
        self.assertEqual(fields["Contact"], "mailto:contact@bk-entreprise.com")
        self.assertEqual(fields["Canonical"], "https://bk-ai-workers.com/.well-known/security.txt")
        self.assertEqual(fields["Policy"], "https://bk-ai-workers.com/securite.html#signaler")
        self.assertEqual(fields["Preferred-Languages"], "fr, en")
        exp = datetime.datetime.strptime(fields["Expires"], "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=datetime.timezone.utc)
        delta = exp - datetime.datetime.now(datetime.timezone.utc)
        self.assertTrue(datetime.timedelta(days=200) < delta < datetime.timedelta(days=365), delta)     # RFC 9116 : moins d'un an
        # l'adresse n'est pas inventee : elle figure deja dans les mentions legales et la politique de confidentialite
        self.assertIn("contact@bk-entreprise.com", seo_pages.render_mentions_page())
        self.assertIn("contact@bk-entreprise.com", read("dashboard/confidentialite.html"))
        self.assertTrue(txt.endswith("\n"))
        self.assertNotIn("\r", txt)

    def test_contact_email_is_the_only_address_in_the_file(self):
        txt = trust_pages.render_security_txt("https://bk-ai-workers.com")
        self.assertEqual(set(re.findall(r"[\w.+-]+@[\w.-]+", txt)), {"contact@bk-entreprise.com"})


class HooksTests(unittest.TestCase):
    def test_footer_links_on_static_pages_and_home(self):
        for render in (seo_pages.render_faq_page, seo_pages.render_cgv_page, seo_pages.render_cookies_page):
            page = render()
            self.assertIn('<a href="/securite.html">Sécurité et confiance</a>', page)
            self.assertIn('<a href="/status.html">Statut du service</a>', page)
        for page in (SEC, STA):
            self.assertIn('href="/securite.html"', page)
            self.assertIn('href="/status.html"', page)
        home = read("dashboard/index.html")
        self.assertIn('<a href="/securite.html">Sécurité et confiance</a>', home)
        self.assertIn('<a href="/status.html">Statut du service</a>', home)
        legal = ccc.load_translations(os.path.join(REPO, "dashboard", "i18n-en-legal.js"))
        self.assertEqual(legal["Sécurité et confiance"], "Security and trust")
        self.assertEqual(legal["Statut du service"], "Service status")

    def test_pages_load_the_trust_dictionary_after_i18n_and_override_the_english_title(self):
        for page in (SEC, STA):
            self.assertLess(page.index('src="/i18n.js"'), page.index('src="/i18n-en-trust.js"'))
            self.assertIn("window.BK_EN_HEAD=", page)
            self.assertIn('<link rel="canonical" href="https://bk-ai-workers.com/', page)
        self.assertIn("<title>Sécurité et confiance | BK-AI-WORKERS</title>", SEC)

    def test_server_py_hooks(self):
        src = read("dashboard/server.py")
        self.assertIn("import trust_pages", src)
        self.assertIn("SITEMAP_PATHS.extend(p for p in trust_pages.SITEMAP_PATHS", src)
        self.assertIn("TRUST = trust_pages.TrustService(ROOT, PUBLIC_BASE_URL)", src)
        self.assertEqual(src.count("TRUST.handle_get(self, path)"), 1)
        self.assertEqual(src.count("TRUST.handle_post(self, path)"), 1)
        self.assertIn("TRUST.start(port,", src)
        self.assertLess(src.index("TRUST.start(port,"), src.index("server.serve_forever()"))
        self.assertEqual(trust_pages.SITEMAP_PATHS, ["/securite.html", "/status.html"])

    def test_server_py_diff_is_only_the_hook_lines(self):
        r = subprocess.run(["git", "diff", "--numstat", "main", "--", "dashboard/server.py"], cwd=REPO, capture_output=True, text=True)
        if r.returncode != 0 or not r.stdout.strip():
            self.skipTest("pas de branche main comparable (ou aucune difference)")
        added, deleted, _ = r.stdout.split()[:3]
        self.assertLessEqual(int(added), 25)
        self.assertEqual(int(deleted), 0)

    def test_healthcheck_script_falls_back_to_api_workers(self):
        sh = read("deploy/healthcheck.sh")
        self.assertIn("/api/health", sh)
        self.assertIn("/api/workers", sh)
        self.assertRegex(sh, r'curl -fsS -m 15 -o /dev/null "\$URL" \|\| curl -fsS -m 15 -o /dev/null "\$FALLBACK_URL"')

    def test_line_endings_of_edited_files_are_not_mixed(self):
        for rel in ("dashboard/server.py", "dashboard/seo_pages.py", "dashboard/index.html", "dashboard/i18n-en-legal.js", "deploy/healthcheck.sh"):
            with open(os.path.join(REPO, rel), "rb") as f:
                raw = f.read()
            crlf = raw.count(b"\r\n")
            lf_only = raw.count(b"\n") - crlf
            self.assertTrue(crlf == 0 or lf_only == 0, f"{rel}: fins de ligne melangees (crlf={crlf}, lf={lf_only})")


class StatusPageTests(unittest.TestCase):
    def test_payload_is_embedded_and_script_tags_cannot_be_injected(self):
        payload = dict(EMPTY_PAYLOAD, incidents=[{"id": "INC-1", "title": "</script><img src=x onerror=alert(1)>", "status": "investigating",
                                                  "impact": "minor", "startedAtUtc": "2026-10-07T08:00:00Z", "resolvedAtUtc": None, "updates": []}])
        page = trust_pages.render_status_page(payload)
        self.assertNotIn("</script><img", page)
        m = re.search(r'<script type="application/json" id="status-data">(.*?)</script>', page, re.S)
        self.assertEqual(json.loads(m.group(1))["incidents"][0]["title"], "</script><img src=x onerror=alert(1)>")

    def test_status_script_renders_only_through_text_content(self):
        js = trust_pages._STATUS_JS
        self.assertNotIn("innerHTML", js)
        self.assertNotIn("document.write", js)
        self.assertNotIn("eval(", js)
        self.assertIn("mesure depuis le ", js)
        self.assertIn("measured since ", js)

    def test_no_history_is_displayed_without_data(self):
        page = trust_pages.render_status_page(EMPTY_PAYLOAD)
        data = json.loads(re.search(r'id="status-data">(.*?)</script>', page, re.S).group(1))
        self.assertEqual(data["days"], [])
        self.assertIsNone(data["measuredSinceUtc"])


class DocsTests(unittest.TestCase):
    def test_soc2_readiness_has_gap_table_sources_and_dates(self):
        d = read("docs/SOC2-READINESS.md")
        for cc in ("CC1", "CC2", "CC3", "CC4", "CC5", "CC6.1", "CC6.6", "CC7.1", "CC7.4", "CC7.5", "CC8.1", "CC9.2"):
            self.assertIn("**" + cc, d)
        for col in ("Preuve présente", "Écart", "Effort"):
            self.assertIn(col, d)
        self.assertIn("Aucun audit SOC 2 n'est engagé", d)
        self.assertIn("consultées le 2026-10-07", d)
        urls = re.findall(r"\]\((https://[^)]+)\)", d)
        for needle in ("drata.com/blog/soc-2-audit-cost", "scrut.io/post/cost-of-soc-2-audit", "klaay.com", "vanta.com/pricing",
                       "secureframe.com/pricing", "blazeinfosec.com", "ovhcloud.com", "dataprivacyframework.gov", "fedlex.admin.ch"):
            self.assertTrue(any(needle in u for u in urls), needle)
        for needle in ("Type I", "Type II", "nLPD", "RGPD", "PFPDT", "Registre", "72 h"):
            self.assertIn(needle, d)
        self.assertIn("pas un devis", d)

    def test_security_overview_lists_files_subprocessors_and_weaknesses(self):
        d = read("docs/SECURITY-OVERVIEW.md")
        for needle in ("AES-256-GCM", "PBKDF2", "OVHcloud", "Anthropic", "OpenAI", "Twilio", "Meta", "Stripe", "Google", "Microsoft",
                       "SSRF", "Content-Length", "HSTS", "CSRF", "root", "pas même nous", "status-incident.py", "claims-evidence.json"):
            self.assertIn(needle, d)
        for rel in re.findall(r"`((?:dashboard|core|deploy|tests|docs|\.github)/[A-Za-z0-9_./-]+\.(?:py|ps1|sh|md|yml|json|js|html))", d):
            if "/data/" in rel:                        # donnees d'execution du serveur : absentes du depot par construction
                continue
            self.assertTrue(os.path.exists(os.path.join(REPO, rel.split(":")[0])), "fichier cite introuvable : " + rel)

    def test_dpa_template_is_flagged_and_does_not_overpromise(self):
        d = read("docs/DPA-TEMPLATE.md")
        self.assertIn("non validé par un juriste", d)
        self.assertIn("[48]", d)                                # delai de notification : decision du proprietaire, entre crochets
        self.assertIn("aucun rapport SOC 2", d.replace("Aucun", "aucun"))
        self.assertIn("utilisé seulement si aucune clé Anthropic", d)


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    unittest.main(verbosity=2)
