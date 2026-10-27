# -*- coding: utf-8 -*-
"""Outils site_* côté Worker (dashboard/site_tools.py) appelés comme le fait le lanceur : `python dashboard/project-tool.py <outil>` (JSON sur
l'entrée standard) et project_tools.run_tool. Sortes d'étape autorisées, définitions pour le modèle, preuve « fetch », plafond de contenu d'un
article d'approbation, lecture des opérations de connecteur réelles.

    python tests/site-factory/test_tools.py"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import fixtures as fx  # noqa: E402
import project_tools as pt  # noqa: E402
import projects_approvals as pa  # noqa: E402
import site_tools  # noqa: E402,F401

CLIENT = "CLI-CUST-CCCCCCCC"
PID = "PRJ-" + "C" * 32


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="bk-tools-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.pdir = os.path.join(self.root, "runtime", "projects", CLIENT, PID)
        os.makedirs(os.path.join(self.pdir, "workspace"))
        os.makedirs(os.path.join(self.pdir, "steps", "S1", "1"))
        with open(os.path.join(self.pdir, "state.json"), "w", encoding="utf-8") as f:
            json.dump({"projectId": PID, "clientId": CLIENT, "status": "RUNNING"}, f)
        old = pt.ROOT
        pt.ROOT = self.root
        self.addCleanup(setattr, pt, "ROOT", old)
        shutil.copytree(os.path.join(REPO, "core", "integrations"), os.path.join(self.root, "core", "integrations"))
        shutil.copytree(os.path.join(REPO, "core", "projects"), os.path.join(self.root, "core", "projects"))

    def call(self, name, inp, kind="execute"):
        return pt.run_tool(name, {"projectDir": self.pdir, "stepDir": os.path.join(self.pdir, "steps", "S1", "1"), "stepId": "S1", "kind": kind,
                                  "worker": "lucas", "input": inp})

    def connect(self, *conns):
        p = os.path.join(self.root, "core", "connectors", "data", CLIENT + ".json")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            json.dump(list(conns), f)

    def test_full_tool_chain(self):
        out = self.call("site_scaffold", fx.SCAFFOLD)
        self.assertTrue(out["ok"], out)
        self.assertIn("Guide de l'atelier", out["result"]["guide"])
        self.assertEqual(self.call("site_scaffold", fx.SCAFFOLD)["error"], "EXISTS")
        out = self.call("site_build", {})
        self.assertTrue(out["ok"], out)
        self.assertGreaterEqual(len(out["result"]["pages"]), 12)
        out = self.call("site_check", {"profile": "vitrine"})
        self.assertTrue(out["ok"], out)
        self.assertFalse(out["result"]["ok"])                         # squelette : textes non rédigés
        self.assertRegex(out["result"]["id"], r"^CHK-[0-9a-f]{8}$")
        self.assertTrue(os.path.isfile(os.path.join(self.pdir, "steps", "S1", "1", "checks", out["result"]["id"] + ".json")))
        out = self.call("preview_fetch", {"path": "/en/"})
        self.assertTrue(out["ok"], out)
        rec = out["result"]
        self.assertEqual(rec["status"], 200)
        self.assertEqual(rec["lang"], "en")
        self.assertTrue(os.path.isfile(os.path.join(self.pdir, "steps", "S1", "1", "fetches", rec["id"] + ".json")))
        self.assertTrue(all(l["state"] in ("ok", "externe", "contact") for l in rec["links"]), rec["links"])
        self.assertEqual(self.call("preview_fetch", {"path": "/../state.json"})["result"]["status"], 404)
        out = self.call("site_package", {})
        self.assertTrue(out["ok"], out)
        self.assertEqual(len(out["result"]["registered"]), 2)
        spooled = [json.loads(l) for n in os.listdir(os.path.join(self.pdir, "spool")) if n.startswith("deliverables-")
                   for l in open(os.path.join(self.pdir, "spool", n), encoding="utf-8")]
        self.assertTrue(any(d.get("path") == "deliverables/site-atelier-lumen.zip" for d in spooled), spooled)

    def test_kinds_are_enforced(self):
        self.call("site_scaffold", fx.SCAFFOLD)
        self.assertEqual(self.call("site_build", {}, kind="verify")["error"], "NOT_ALLOWED")
        self.assertEqual(self.call("site_scaffold", {"force": True}, kind="answer")["error"], "NOT_ALLOWED")
        self.assertEqual(self.call("site_publish_prepare", {}, kind="verify")["error"], "NOT_ALLOWED")
        self.call("site_build", {})
        self.assertTrue(self.call("site_check", {}, kind="verify")["ok"])            # le vérificateur peut contrôler, pas écrire
        self.assertTrue(self.call("preview_fetch", {"path": "/"}, kind="verify")["ok"])

    def test_publish_prepare_queues_one_approval_per_page_and_manual_for_oversized(self):
        ws = os.path.join(self.pdir, "workspace")
        fx.make_good_site(ws)
        self.connect("wordpress")
        fx.edit_src(ws, "fr", "services", lambda t: t + "\n<section class=\"section\"><div class=\"container prose\">" + "<p>Explication détaillée du soin.</p>" * 300 + "</div></section>")
        self.call("site_build", {})
        out = self.call("site_publish_prepare", {"target": "wordpress"})
        self.assertTrue(out["ok"], out)
        items = [json.loads(l) for l in open(os.path.join(self.pdir, "spool", "approvals-S1.jsonl"), encoding="utf-8")]
        wp = [i for i in items if i["kind"] == "connector_action"]
        manual = [i for i in items if i["kind"] == "manual_action"]
        self.assertEqual(len(wp), 5)
        self.assertEqual(len(manual), 1)
        self.assertIn("Prestations", manual[0]["display"]["what"])
        self.assertIn("trop long", manual[0]["display"]["why"])
        for i in wp:
            self.assertEqual((i["connectorId"], i["operation"], i["status"], i["risk"]), ("wordpress", "CREATE_PAGE_DRAFT", "PENDING", "medium"))
            self.assertLessEqual(len(json.dumps(i["params"], ensure_ascii=False, sort_keys=True).encode("utf-8")), pa.PARAMS_MAX_BYTES)
            self.assertIn("BROUILLON", i["display"]["what"])
            self.assertIsNone(pa.validate_item(self.root, CLIENT, i, [], 0)[0])         # l'ingestion du moteur l'accepte telle quelle
        again = self.call("site_publish_prepare", {"target": "wordpress"})
        self.assertTrue(all(x.get("duplicate") for x in again["result"]["items"]))       # rejouer ne duplique rien

    def test_connector_operation_is_read_from_the_powershell_table(self):
        ops = pa.connector_ops(self.root)
        self.assertIn("CREATE_PAGE_DRAFT", ops["wordpress"])
        self.assertNotIn("UPDATE_PAGE_DRAFT", ops["wordpress"])          # pas de mise à jour d'une page (elle serait en ligne)
        self.assertNotIn("UPLOAD_MEDIA", ops["wordpress"])
        self.assertEqual(pa.classify_risk(self.root, "wordpress", "CREATE_PAGE_DRAFT", {}), "medium")
        self.assertTrue(pa.is_reversible(self.root, "wordpress", "CREATE_PAGE_DRAFT"))
        self.assertFalse(pa.is_safe_draft(self.root, "wordpress", "CREATE_PAGE_DRAFT"))   # jamais pré-autorisé : le client valide chaque page
        self.assertEqual(set(ops.get("webflow", ())) - {"READ_PAGE", "CREATE_DRAFT", "UPDATE_DRAFT"}, set())

    def test_project_tool_cli_registers_site_tools_and_definitions(self):
        env = dict(os.environ, BK_ROOT=self.root, PYTHONIOENCODING="utf-8")
        cli = os.path.join(REPO, "dashboard", "project-tool.py")
        payload = {"projectDir": self.pdir, "stepDir": os.path.join(self.pdir, "steps", "S1", "1"), "stepId": "S1", "kind": "execute", "worker": "lucas",
                   "input": {"names": ["site_scaffold", "site_build", "site_check", "site_package", "site_publish_prepare", "preview_fetch"]}}
        r = subprocess.run([sys.executable, cli, "_definitions"], input=json.dumps({"names": payload["input"]["names"]}), capture_output=True, text=True, encoding="utf-8", env=env, timeout=60)
        out = json.loads(r.stdout)
        defs = out["result"]["definitions"]
        self.assertEqual(set(defs), set(payload["input"]["names"]))
        for name, d in defs.items():
            self.assertEqual(d["name"], name)
            self.assertGreaterEqual(d["description"].count("."), 3, name)        # descriptions de 3-4 phrases au moins
            self.assertEqual(d["input_schema"]["type"], "object")
            self.assertTrue(d.get("input_examples"), name)
        payload["input"] = fx.SCAFFOLD
        r = subprocess.run([sys.executable, cli, "site_scaffold"], input=json.dumps(payload), capture_output=True, text=True, encoding="utf-8", env=env, timeout=60)
        self.assertTrue(json.loads(r.stdout)["ok"], r.stdout[:300] + r.stderr[-500:])
        payload["input"] = {}
        r = subprocess.run([sys.executable, cli, "site_build"], input=json.dumps(payload), capture_output=True, text=True, encoding="utf-8", env=env, timeout=60)
        self.assertTrue(json.loads(r.stdout)["ok"], r.stdout[:300])

    def test_step_tool_list_offers_site_tools_to_execute_steps_only(self):
        tools_exec = [n for n, e in pt.REGISTRY.items() if e.get("kinds") and "execute" in e["kinds"]]
        tools_verify = [n for n, e in pt.REGISTRY.items() if e.get("kinds") and "verify" in e["kinds"]]
        self.assertTrue({"site_scaffold", "site_build", "site_check", "site_package", "site_publish_prepare"} <= set(tools_exec))
        self.assertEqual({n for n in tools_verify if n.startswith("site_")}, {"site_check"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
