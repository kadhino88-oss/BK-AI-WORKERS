# -*- coding: utf-8 -*-
"""Outils d'une étape de projet (dashboard/project_tools.py) : chemin sûr, plafonds de taille, secrets, droits par sorte d'étape, rapport
d'étape, outils d'état (spool), vérificateur, import du bac à sable, ligne de commande. Aucun modèle, aucun réseau.

    python tests/projects/test_tools.py"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import project_paths as pp  # noqa: E402
import project_tools as T  # noqa: E402

PID = "PRJ-" + "AB" * 16
CLIENT = "CLI-CUST-AAAAAAAA"


class ToolBase(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="bktool-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.pdir = os.path.join(self.root, "runtime", "projects", CLIENT, PID)
        os.makedirs(os.path.join(self.pdir, "workspace"))
        os.makedirs(os.path.join(self.pdir, "steps", "S1", "1"))
        self.write_json("state.json", {"projectId": PID, "clientId": CLIENT, "status": "RUNNING", "steps": {}, "scope": {"chloe": True, "allowedWorkers": ["lucas", "emma"]}})
        self.write_json("limits.json", {"workspaceMb": 1, "approvalTtlDays": 7, "planLimits": {}})
        self.old_root = T.ROOT
        T.ROOT = self.root
        self.addCleanup(setattr, T, "ROOT", self.old_root)

    def write_json(self, name, data):
        with open(os.path.join(self.pdir, name), "w", encoding="utf-8") as f:
            json.dump(data, f)

    def call(self, tool, inp=None, kind="execute", step="S1", worker="lucas"):
        return T.run_tool(tool, {"projectDir": self.pdir, "stepDir": os.path.join(self.pdir, "steps", step, "1"), "stepId": step, "kind": kind,
                                 "worker": worker, "input": inp or {}})

    def ok(self, tool, inp=None, **kw):
        out = self.call(tool, inp, **kw)
        self.assertTrue(out.get("ok"), out)
        return out["result"]

    def err(self, tool, inp=None, code=None, **kw):
        out = self.call(tool, inp, **kw)
        self.assertFalse(out.get("ok"), out)
        if code:
            self.assertEqual(out["error"], code, out)
        return out

    def ws(self, rel):
        return os.path.join(self.pdir, "workspace", *rel.split("/"))

    def put(self, rel, content=b"x"):
        full = self.ws(rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(content if isinstance(content, bytes) else content.encode("utf-8"))

    def spool(self, name, step="S1"):
        p = os.path.join(self.pdir, "spool", f"{name}-{step}.jsonl")
        if not os.path.isfile(p):
            return []
        with open(p, encoding="utf-8") as f:
            return [json.loads(x) for x in f if x.strip()]


class WorkspaceTools(ToolBase):
    def test_write_read_list_roundtrip(self):
        r = self.ok("workspace_write", {"path": "site/index.html", "content": "<h1>Bonjour</h1>"})
        self.assertTrue(r["created"])
        self.assertEqual(self.ok("workspace_read", {"path": "site/index.html"})["text"], "<h1>Bonjour</h1>")
        entries = self.ok("workspace_list", {})["entries"]
        self.assertIn("site/index.html", [e["path"] for e in entries])
        self.assertIn("site/", [e["path"] for e in entries])

    def test_create_refuses_an_existing_file_and_overwrite_replaces_it(self):
        self.ok("workspace_write", {"path": "notes/a.md", "content": "un"})
        self.err("workspace_write", {"path": "notes/a.md", "content": "deux"}, "EXISTS")
        self.assertFalse(self.ok("workspace_write", {"path": "notes/a.md", "content": "deux", "mode": "overwrite"})["created"])
        self.assertEqual(self.ok("workspace_read", {"path": "notes/a.md"})["text"], "deux")

    def test_traversal_and_hostile_paths_are_refused_by_every_tool(self):
        hostile = ["../x.md", "a/../../x.md", "/etc/passwd.md", "C:/x.md", "a\\b.md", ".hidden.md", "a/.git/x.md", "a b.md", "a//b.md", "%2e%2e/x.md",
                   "..%2fx.md", "a/\x00b.md", "x" * 200 + ".md", "/".join(["d"] * 9) + "/f.md", "con.md", "nul.txt", "a/./b.md", "é.md", "a/b.md/../../../c.md"]
        for p in hostile:
            for tool, inp in (("workspace_write", {"path": p, "content": "x"}), ("workspace_append", {"path": p, "content": "x"}),
                              ("workspace_read", {"path": p}), ("workspace_delete", {"path": p}), ("deliverable_register", {"path": p})):
                out = self.call(tool, inp)
                self.assertFalse(out["ok"], (tool, p, out))
                self.assertIn(out["error"], ("PATH_INVALID", "EXT_NOT_ALLOWED", "NOT_FOUND"), (tool, p, out))
        self.assertFalse(os.path.exists(os.path.join(self.pdir, "x.md")))
        self.assertFalse(os.path.exists(os.path.join(self.root, "x.md")))

    def test_extension_allowlist_on_write(self):
        for p in ("a.exe", "a.php", "a.sh", "a.ps1", "a.bat", "a.py", "a.png", "a.docx", "a.html.exe", "noext"):
            self.err("workspace_write", {"path": p, "content": "x"})
        for p in ("a.html", "a.css", "a.js", "a.json", "a.md", "a.csv", "a.svg", "a.xml", "a.yml", "a.ics", "a.txt", "a.tsv", "a.mjs", "a.htm", "a.yaml"):
            self.ok("workspace_write", {"path": "ok/" + p, "content": "x"})

    def test_size_caps_single_file_and_workspace(self):
        self.err("workspace_write", {"path": "big.txt", "content": "x" * (T.WRITE_BYTES_MAX + 1)}, "TOO_LARGE")
        # espace de 1 Mo (limits.json) : le remplissage est refuse sans corrompre ce qui existe
        self.ok("workspace_write", {"path": "p1.txt", "content": "a" * 600_000})
        out = self.err("workspace_write", {"path": "p2.txt", "content": "b" * 600_000}, "WORKSPACE_FULL")
        self.assertIn("plein", out["detail"])
        self.assertEqual(len(self.ok("workspace_read", {"path": "p1.txt", "limit": 20000})["text"]), 20000)
        self.assertFalse(os.path.exists(self.ws("p2.txt")))

    def test_file_count_cap(self):
        self.write_json("limits.json", {"workspaceMb": 100})
        old = pp.MAX_FILES
        pp.MAX_FILES = 5
        self.addCleanup(setattr, pp, "MAX_FILES", old)
        for i in range(5):
            self.ok("workspace_write", {"path": f"f{i}.txt", "content": "x"})
        self.err("workspace_write", {"path": "f5.txt", "content": "x"}, "WORKSPACE_FULL")
        self.ok("workspace_write", {"path": "f0.txt", "content": "y", "mode": "overwrite"})        # remplacer un fichier existant reste permis

    def test_append_grows_a_file_and_caps_it(self):
        self.ok("workspace_append", {"path": "log/a.md", "content": "un\n"})
        r = self.ok("workspace_append", {"path": "log/a.md", "content": "deux\n"})
        self.assertEqual(r["totalBytes"], len("un\ndeux\n"))
        self.put("log/full.md", b"x" * (T.APPEND_FILE_MAX - 3))
        self.write_json("limits.json", {"workspaceMb": 100})
        self.err("workspace_append", {"path": "log/full.md", "content": "yyyyyyyy"}, "TOO_LARGE")

    def test_secret_like_content_is_refused_everywhere(self):
        secrets_ = ["mot de passe : hunter2xyz123", "sk-ant-api03-" + "A" * 40, "IBAN CH93 0076 2011 6238 5295 7", "carte 4111 1111 1111 1111",
                    "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789"]
        for s in secrets_:
            self.err("workspace_write", {"path": "n/x.md", "content": s}, "SECRET_REFUSED")
            self.err("workspace_append", {"path": "n/x.md", "content": s}, "SECRET_REFUSED")
            self.err("note_decision", {"decision": s}, "SECRET_REFUSED")
        self.assertFalse(os.path.exists(self.ws("n/x.md")))
        self.ok("workspace_write", {"path": "n/ok.md", "content": "Telephone du cabinet : [À COMPLÉTER : numéro]"})

    def test_read_paging_and_binary_files(self):
        self.put("n/long.md", "abcdefghij" * 5000)
        a = self.ok("workspace_read", {"path": "n/long.md"})
        self.assertFalse(a["eof"])
        self.assertEqual(len(a["text"]), T.READ_CHARS_MAX)
        text, page = a["text"], a
        while not page["eof"]:
            page = self.ok("workspace_read", {"path": "n/long.md", "offset": page["nextOffset"]})
            text += page["text"]
        self.assertEqual(text, "abcdefghij" * 5000)
        self.put("img/p.png", b"\x89PNG\r\n\x1a\n" + b"\0" * 20)
        self.err("workspace_read", {"path": "img/p.png"}, "BINARY_FILE")
        self.put("n/z.zip", b"PK\x03\x04")
        self.err("workspace_read", {"path": "n/z.zip"}, "BINARY_FILE")

    def test_view_image_caps_and_media_type(self):
        self.put("img/ok.png", b"\x89PNG\r\n\x1a\n" + b"\0" * 100)
        r = self.ok("workspace_view_image", {"path": "img/ok.png"})
        self.assertEqual(r["mediaType"], "image/png")
        self.put("img/big.jpg", b"\xff\xd8" + b"\0" * (T.IMAGE_BYTES_MAX + 10))
        self.err("workspace_view_image", {"path": "img/big.jpg"}, "TOO_LARGE")
        self.err("workspace_view_image", {"path": "notes.md"})

    def test_delete_protects_workspace_root_and_client_inputs(self):
        self.put("inputs/logo.png", b"png")
        self.put("site/a.html", "<p>a</p>")
        self.err("workspace_delete", {"path": "inputs/logo.png"}, "CONFIRM_REQUIRED")
        self.assertTrue(os.path.isfile(self.ws("inputs/logo.png")))
        self.ok("workspace_delete", {"path": "inputs/logo.png", "confirm": True})
        self.assertEqual(self.ok("workspace_delete", {"path": "site/"})["type"], "dir")
        self.assertFalse(os.path.exists(self.ws("site")))
        self.err("workspace_delete", {"path": ""})
        self.err("workspace_delete", {"path": "."})
        self.assertTrue(os.path.isdir(os.path.join(self.pdir, "workspace")))

    def test_symlink_components_are_never_followed(self):
        outside = tempfile.mkdtemp(prefix="bkout-")
        self.addCleanup(shutil.rmtree, outside, True)
        with open(os.path.join(outside, "secret.md"), "w", encoding="utf-8") as f:
            f.write("hors de l'espace")
        link = self.ws("lien")
        try:
            os.symlink(outside, link, target_is_directory=True)
        except (OSError, NotImplementedError, AttributeError):
            self.skipTest("liens symboliques non disponibles ici")
        self.err("workspace_read", {"path": "lien/secret.md"})
        self.err("workspace_write", {"path": "lien/new.md", "content": "x"})
        self.assertFalse(os.path.exists(os.path.join(outside, "new.md")))
        names = [e["path"] for e in self.ok("workspace_list", {})["entries"]]
        self.assertFalse(any(n.startswith("lien") for n in names))
        self.assertEqual(self.ok("workspace_search", {"query": "hors"})["matches"], [])

    def test_search_finds_text_skips_binary_and_refuses_nested_quantifiers(self):
        self.put("a/one.md", "Le cabinet est ouvert\nFermé le dimanche\n")
        self.put("a/two.html", "<p>Cabinet de physiotherapie</p>")
        self.put("a/img.png", b"cabinet")
        m = self.ok("workspace_search", {"query": "cabinet"})["matches"]
        self.assertEqual(sorted(x["path"] for x in m), ["a/one.md", "a/two.html"])
        self.assertEqual(len(self.ok("workspace_search", {"query": "cabinet", "glob": "*.md"})["matches"]), 1)
        self.err("workspace_search", {"query": "(a+)+$", "regex": True}, "INVALID_INPUT")
        self.err("workspace_search", {"query": "", "regex": False}, "INVALID_INPUT")
        self.err("workspace_search", {"query": "([", "regex": True}, "INVALID_INPUT")

    def test_deliverable_register_needs_a_real_non_empty_file(self):
        self.put("d/empty.md", b"")
        self.err("deliverable_register", {"path": "d/empty.md"}, "EMPTY")
        self.err("deliverable_register", {"path": "d/absent.md"})
        self.put("d/ok.md", "contenu")
        r = self.ok("deliverable_register", {"path": "d/ok.md", "title": "Mon livrable"})
        self.assertEqual(r["registered"], "d/ok.md")
        rows = self.spool("deliverables")
        self.assertEqual(rows[0]["path"], "d/ok.md")
        self.assertEqual(rows[0]["stepId"], "S1")
        os.makedirs(self.ws("site/dist"))
        self.err("deliverable_register", {"path": "site/dist/"}, "EMPTY")


class KindRights(ToolBase):
    def test_a_verifier_cannot_write_or_touch_connectors_even_if_it_invents_the_call(self):
        for tool in ("workspace_write", "workspace_append", "workspace_delete", "deliverable_register", "request_approval", "step_blocked", "project_plan",
                     "request_input", "note_decision", "import_file_x"):
            out = self.call(tool, {"path": "a.md", "content": "x"}, kind="verify", worker="qa")
            self.assertFalse(out["ok"], tool)
            self.assertIn(out["error"], ("NOT_ALLOWED", "UNKNOWN_TOOL"), (tool, out))
        self.assertFalse(os.path.exists(self.ws("a.md")))

    def test_an_answer_step_is_read_only(self):
        self.put("a.md", "x")
        self.ok("workspace_read", {"path": "a.md"}, kind="answer")
        for tool in ("workspace_write", "workspace_delete", "step_complete", "request_approval"):
            self.err(tool, {"path": "b.md", "content": "x", "summary": "x"}, "NOT_ALLOWED", kind="answer")

    def test_plan_steps_cannot_write_files_but_can_set_the_plan(self):
        self.err("workspace_write", {"path": "a.md", "content": "x"}, "NOT_ALLOWED", kind="plan", worker="chloe")
        self.err("project_plan", {"action": "add_step", "step": {}}, "NOT_ALLOWED", kind="plan", worker="chloe")

    def test_runner_only_tools_exist_for_the_runner_but_are_not_offered_to_the_model(self):
        for k, names in T.TOOLS_BY_KIND.items():
            for n in T.RUNNER_ONLY:
                self.assertNotIn(n, names, k)

    def test_bad_payloads_never_raise(self):
        self.assertEqual(T.run_tool("nope", {})["error"], "UNKNOWN_TOOL")
        self.assertEqual(T.run_tool("workspace_read", None)["error"], "INVALID_INPUT")
        self.assertEqual(T.run_tool("workspace_read", {"projectDir": "/etc", "stepId": "S1", "kind": "execute"})["error"], "INVALID_INPUT")
        self.assertEqual(T.run_tool("workspace_read", {"projectDir": self.pdir, "stepId": "../S1", "kind": "execute"})["error"], "INVALID_INPUT")
        self.assertEqual(T.run_tool("workspace_read", {"projectDir": self.pdir, "stepId": "S1", "kind": "hack"})["error"], "INVALID_INPUT")
        self.assertEqual(self.err("workspace_read", {"path": 12})["error"], "PATH_INVALID")
        self.assertEqual(self.err("workspace_write", {"path": "a.md", "content": 12})["error"], "INVALID_INPUT")


class StateTools(ToolBase):
    def good_plan(self, **over):
        plan = {"goal": "Site vitrine", "criteria": [{"id": "C1", "text": "La page existe", "kind": "auto", "check": {"type": "file_exists", "path": "site/index.html"}}],
                "steps": [{"id": "S1", "title": "Accueil", "worker": "lucas", "goal": "Ecrire l'accueil", "criteriaIds": ["C1"], "expectedOutputs": ["site/index.html"]}]}
        plan.update(over)
        return plan

    def test_plan_set_validates_against_the_scope_and_writes_only_to_the_spool(self):
        r = self.ok("project_plan", {"action": "set", "plan": self.good_plan()}, kind="plan", worker="chloe")
        self.assertTrue(r["saved"])
        self.assertTrue(os.path.isfile(os.path.join(self.pdir, "spool", "plan-S1.json")))
        self.assertFalse(os.path.exists(os.path.join(self.pdir, "plan.json")))                        # plan.json appartient au moteur
        bad = self.good_plan(steps=[{"id": "S1", "title": "x", "worker": "clara", "goal": "g", "criteriaIds": ["C1"]}])
        out = self.err("project_plan", {"action": "set", "plan": bad}, "PLAN_INVALID", kind="plan", worker="chloe")
        self.assertTrue(out["problems"])
        cyc = self.good_plan(steps=[{"id": "S1", "title": "x", "worker": "lucas", "goal": "g", "criteriaIds": ["C1"], "dependsOn": ["S2"]},
                                    {"id": "S2", "title": "y", "worker": "lucas", "goal": "g", "criteriaIds": ["C1"], "dependsOn": ["S1"]}])
        self.err("project_plan", {"action": "set", "plan": cyc}, "PLAN_INVALID", kind="plan", worker="chloe")

    def test_add_step_is_capped_at_eight_per_project(self):
        self.err("project_plan", {"action": "add_step", "step": {"title": "t", "goal": "g", "worker": "../x"}}, "INVALID_INPUT")
        step = {"title": "Plus", "goal": "Faire plus", "worker": "emma"}
        for _ in range(T.MAX_ADDED_STEPS):
            self.ok("project_plan", {"action": "add_step", "step": step})
        self.err("project_plan", {"action": "add_step", "step": step}, "TOO_MANY_STEPS")
        self.err("project_plan", {"action": "add_step", "step": step}, "TOO_MANY_STEPS", step="S2")           # le plafond est celui du projet, pas de l'etape

    def test_request_input_is_capped_at_three_questions_per_step(self):
        for i in range(3):
            self.ok("request_input", {"question": f"Question {i} ?", "choices": ["a", "b"]})
        self.err("request_input", {"question": "Encore ?"}, "TOO_MANY_QUESTIONS")
        self.assertEqual(len(self.spool("inputs")), 3)
        self.ok("request_input", {"question": "Une autre etape"}, step="S2")

    def test_step_complete_refuses_missing_empty_deliverables_and_unresolved_evidence(self):
        self.put("site/ok.html", "<p>ok</p>")
        self.put("site/empty.html", b"")
        out = self.err("step_complete", {"status": "DONE", "summary": "Fait", "deliverables": [{"path": "site/absent.html"}, {"path": "site/empty.html"}],
                                         "criteriaClaims": [{"criterionId": "C1", "claim": "ok", "evidence": [{"type": "file", "ref": "site/nope.html"},
                                                                                                           {"type": "check", "ref": "CHK-00000000"}, {"type": "excerpt", "ref": "x"}]}]},
                       "STEP_REPORT_INVALID")
        self.assertGreaterEqual(len(out["problems"]), 4)
        r = self.ok("step_complete", {"status": "DONE", "summary": "Fait", "deliverables": [{"path": "site/ok.html", "title": "Accueil"}],
                                      "criteriaClaims": [{"criterionId": "C1", "claim": "ok", "evidence": [{"type": "file", "ref": "site/ok.html"}]}]})
        self.assertTrue(r["accepted"])
        self.assertEqual(r["report"]["deliverables"][0]["path"], "site/ok.html")
        self.err("step_complete", {"status": "DONE", "summary": "  "}, "STEP_REPORT_INVALID")
        self.err("step_complete", {"status": "WOW", "summary": "x"}, "STEP_REPORT_INVALID")

    def test_revalidate_report_is_the_engine_side_check(self):
        self.put("site/ok.html", "<p>ok</p>")
        step_dir = os.path.join(self.pdir, "steps", "S1", "1")
        self.assertEqual(T.revalidate_report(self.pdir, step_dir, {"status": "DONE", "summary": "x", "deliverables": [{"path": "site/ok.html"}]}), [])
        self.assertTrue(T.revalidate_report(self.pdir, step_dir, {"status": "DONE", "summary": "x", "deliverables": [{"path": "site/gone.html"}]}))
        os.remove(self.ws("site/ok.html"))                                                              # supprime apres le rapport : refuse
        self.assertTrue(T.revalidate_report(self.pdir, step_dir, {"status": "DONE", "summary": "x", "deliverables": [{"path": "site/ok.html"}]}))

    def test_verify_report_needs_a_verification_object_with_valid_verdicts(self):
        self.err("step_complete", {"status": "DONE", "summary": "ok"}, "STEP_REPORT_INVALID", kind="verify", worker="qa")
        self.err("step_complete", {"status": "DONE", "summary": "ok", "verification": {"criteria": [{"id": "C1", "verdict": "MAYBE"}], "overall": "PASS"}},
                 "STEP_REPORT_INVALID", kind="verify", worker="qa")
        r = self.ok("step_complete", {"status": "DONE", "summary": "ok", "verification": {"criteria": [{"id": "C1", "verdict": "FAIL", "note": "manque",
                                                                                                      "evidence": [{"type": "file", "ref": "site/x.html"}]}], "overall": "FAIL"}},
                    kind="verify", worker="qa")
        self.assertEqual(r["report"]["verification"]["criteria"][0]["verdict"], "FAIL")

    def test_step_blocked_validates_the_reason(self):
        self.err("step_blocked", {"reason": "BORED", "detail": "x"}, "INVALID_INPUT")
        self.err("step_blocked", {"reason": "INPUT", "detail": ""}, "INVALID_INPUT")
        self.assertEqual(self.ok("step_blocked", {"reason": "INPUT", "detail": "Il me faut vos horaires"})["blocked"]["reason"], "INPUT")


class ApprovalTool(ToolBase):
    def setUp(self):
        super().setUp()
        for rel in ("core/projects/APPROVAL-RISK.json", "core/projects/PROJECT-LIMITS.json", "core/integrations/Connector-Dispatch.ps1"):
            os.makedirs(os.path.dirname(os.path.join(self.root, *rel.split("/"))), exist_ok=True)
            shutil.copy2(os.path.join(REPO, *rel.split("/")), os.path.join(self.root, *rel.split("/")))
        os.makedirs(os.path.join(self.root, "core", "connectors", "data"), exist_ok=True)
        with open(os.path.join(self.root, "core", "connectors", "data", CLIENT + ".json"), "w", encoding="utf-8") as f:
            json.dump(["slack", "wordpress", "hubspot"], f)

    def test_an_outward_action_becomes_an_item_with_a_recomputed_risk(self):
        r = self.ok("request_approval", {"connectorId": "slack", "operation": "POST_MESSAGE", "title": "Annonce", "what": "Poste dans #general",
                                         "params": {"channel": "#general", "text": "Bonjour"}})
        self.assertTrue(r["note"].startswith("QUEUED:APR-"))
        self.assertEqual(r["risk"], "medium")
        item = self.spool("approvals")[0]
        self.assertEqual((item["status"], item["kind"], item["connectorId"], item["operation"]), ("PENDING", "connector_action", "slack", "POST_MESSAGE"))
        self.assertIn("expiresUtc", item)
        self.assertFalse(item["autoApproved"])

    def test_refusals_not_connected_unknown_operation_read_only_secrets_oversized(self):
        self.err("request_approval", {"connectorId": "shopify", "operation": "CREATE_REFUND", "title": "t", "what": "w"}, "CONNECTOR_MISSING")
        self.err("request_approval", {"connectorId": "slack", "operation": "NUKE_WORKSPACE", "title": "t", "what": "w"}, "UNSUPPORTED_OPERATION")
        self.err("request_approval", {"connectorId": "slack", "operation": "SEARCH_MESSAGES", "title": "t", "what": "w"}, "NOT_AN_ACTION")
        self.err("request_approval", {"connectorId": "slack", "operation": "POST_MESSAGE", "title": "t", "what": "w", "params": {"text": "mot de passe : hunter2xyz123"}}, "SECRET_REFUSED")
        self.err("request_approval", {"connectorId": "slack", "operation": "POST_MESSAGE", "title": "t", "what": "w", "params": {"text": "x" * 9000}}, "TOO_LARGE")
        self.err("request_approval", {"kind": "teleport", "title": "t"}, "INVALID_INPUT")
        self.assertEqual(self.spool("approvals"), [])

    def test_the_same_action_is_not_queued_twice_and_the_model_cannot_self_approve(self):
        a = {"connectorId": "slack", "operation": "POST_MESSAGE", "title": "Annonce", "what": "Poste", "params": {"channel": "#a", "text": "x"}, "autoApproved": True,
             "status": "EXECUTED"}
        first = self.ok("request_approval", a)
        second = self.ok("request_approval", a)
        self.assertTrue(second["duplicate"])
        self.assertEqual(first["approvalId"], second["approvalId"])
        rows = self.spool("approvals")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "PENDING")
        self.assertFalse(rows[0]["autoApproved"])

    def test_more_than_twenty_recipients_is_high_risk(self):
        to = ", ".join(f"p{i}@example.com" for i in range(25))
        r = self.ok("request_approval", {"connectorId": "slack", "operation": "POST_MESSAGE", "title": "Envoi", "what": "w", "params": {"to": to, "text": "x"}})
        self.assertEqual(r["risk"], "high")

    def test_manual_action_needs_what_and_the_queue_is_capped(self):
        self.err("request_approval", {"kind": "manual", "title": "Faire quelque chose"}, "INVALID_INPUT")
        r = self.ok("request_approval", {"kind": "manual", "title": "Ajouter le DNS", "details": "Chez votre hébergeur, ajoutez l'enregistrement A", "risk": "high"})
        self.assertEqual(r["risk"], "high")
        import projects_approvals as pa
        for i in range(pa.PENDING_PER_PROJECT - 1):
            self.ok("request_approval", {"kind": "manual", "title": f"Action {i}", "details": f"Détail {i}"})
        self.err("request_approval", {"kind": "manual", "title": "De trop", "details": "x"}, "APPROVAL_QUEUE_FULL")

    def test_record_executed_action_is_runner_only_and_only_for_true_drafts(self):
        out = self.call("record_executed_action", {"connectorId": "slack", "operation": "POST_MESSAGE", "execution": {"connectorStatus": "SUCCESS"}})
        self.assertFalse(out["ok"])
        self.assertEqual(out["error"], "NOT_ALLOWED")                                                    # ce n'est pas un brouillon pre-autorise
        self.assertNotIn("record_executed_action", T.TOOLS_BY_KIND["execute"])


class VerifierTools(ToolBase):
    def test_check_run_writes_a_result_the_engine_can_resolve_later(self):
        self.put("site/index.html", "<h1>Bienvenue au cabinet</h1>")
        os.makedirs(os.path.join(self.pdir, "steps", "VER1", "1"))
        with open(os.path.join(self.pdir, "steps", "VER1", "1", "verify.json"), "w", encoding="utf-8") as f:
            json.dump({"round": 1}, f)
        r = self.ok("check_run", {"check": {"type": "file_contains", "path": "site/index.html", "mustContain": ["Bienvenue"]}}, kind="verify", step="VER1", worker="qa")
        self.assertTrue(r["ok"])
        self.assertTrue(os.path.isfile(os.path.join(self.pdir, "verification", "1", "checks", r["id"] + ".json")))
        bad = self.ok("check_run", {"check": {"type": "file_exists", "path": "site/absent.html"}}, kind="verify", step="VER1", worker="qa")
        self.assertFalse(bad["ok"])
        self.assertTrue(bad["findings"])
        self.err("check_run", {"check": "nope"}, "INVALID_INPUT", kind="verify", step="VER1", worker="qa")

    def test_preview_fetch_reads_only_the_built_site_locally(self):
        self.put("site/dist/index.html", "<html><head><title>Cabinet</title></head><body><a href=\"/contact.html\">Contact</a><p>Texte</p></body></html>")
        r = self.ok("preview_fetch", {"path": "index.html"}, kind="verify", worker="qa")
        self.assertEqual((r["status"], r["title"]), (200, "Cabinet"))
        self.assertIn("/contact.html", r["links"])
        self.assertEqual(self.ok("preview_fetch", {"path": "../../../state.json"}, kind="verify", worker="qa")["status"], 404)
        self.assertEqual(self.ok("preview_fetch", {"path": "absent.html"}, kind="verify", worker="qa")["status"], 404)


class SandboxImport(ToolBase):
    def dl(self, name, data=b"abc"):
        d = os.path.join(self.pdir, "steps", "S1", "1", "downloads")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, name)
        with open(p, "wb") as f:
            f.write(data)
        return p

    def test_double_underscore_names_become_folders_and_extensions_are_checked(self):
        src = self.dl("img__hero.png", b"\x89PNG" + b"\0" * 10)
        r = self.call("import_file", {"srcPath": src, "destName": "img__hero.png"})
        self.assertTrue(r["ok"], r)
        self.assertTrue(os.path.isfile(self.ws("img/hero.png")))
        bad = self.dl("run.exe")
        self.assertFalse(self.call("import_file", {"srcPath": bad, "destName": "run.exe"})["ok"])
        bad2 = self.dl("a__..__b.png")
        self.assertFalse(self.call("import_file", {"srcPath": bad2, "destName": "a__..__b.png"})["ok"])

    def test_the_source_must_live_inside_the_step_downloads_folder(self):
        outside = os.path.join(self.root, "elsewhere.png")
        with open(outside, "wb") as f:
            f.write(b"x")
        for src in (outside, os.path.join(self.pdir, "state.json"), os.path.join(self.pdir, "steps", "S1", "1", "downloads", "..", "..", "..", "..", "state.json")):
            out = self.call("import_file", {"srcPath": src, "destName": "a.png"})
            self.assertFalse(out["ok"], src)
            self.assertEqual(out["error"], "PATH_INVALID")


class CommandLine(ToolBase):
    def test_project_tool_cli_roundtrip_and_error_codes(self):
        cli = os.path.join(REPO, "dashboard", "project-tool.py")
        payload = {"projectDir": self.pdir, "stepDir": os.path.join(self.pdir, "steps", "S1", "1"), "stepId": "S1", "kind": "execute", "worker": "lucas",
                   "input": {"path": "site/é-accent.html", "content": "x"}}
        env = dict(os.environ, BK_ROOT=self.root)
        p = subprocess.run([sys.executable, cli, "workspace_write"], input=json.dumps(payload), capture_output=True, text=True, encoding="utf-8", env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse(json.loads(p.stdout)["ok"])                                                      # nom accentue : refuse (chemin sur)
        payload["input"]["path"] = "site/accent.html"
        payload["input"]["content"] = "<p>Café ouvert à Lausanne</p>"
        p = subprocess.run([sys.executable, cli, "workspace_write"], input=json.dumps(payload), capture_output=True, text=True, encoding="utf-8", env=env)
        self.assertTrue(json.loads(p.stdout)["ok"], p.stdout)
        with open(self.ws("site/accent.html"), encoding="utf-8") as f:
            self.assertIn("Café", f.read())
        p = subprocess.run([sys.executable, cli, "no_such_tool"], input="{}", capture_output=True, text=True, encoding="utf-8", env=env)
        self.assertEqual(p.returncode, 2)
        p = subprocess.run([sys.executable, cli, "workspace_read"], input="not json", capture_output=True, text=True, encoding="utf-8", env=env)
        self.assertEqual(p.returncode, 2)
        p = subprocess.run([sys.executable, cli, "../evil"], input="{}", capture_output=True, text=True, encoding="utf-8", env=env)
        self.assertEqual(p.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
