"""Lanceur d'etape de projet (Project-StepRunner.ps1 / Project-Loop.ps1) contre la fausse API : fin par step_complete, plafond de cout,
echeance, pause_turn, reessais, repli context_management, refus, conteneur renvoye, cache, files, ecritures de connecteur mises en file,
detecteur de boucle, rapport refuse puis corrige, verificateur en lecture seule, reponse a une question, entree invalide, cle absente.

PowerShell 7 requis (pwsh). Sous Windows : wsl -e python3 tests/projects/test_runner.py (un test a la fois)."""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runner_harness import (PWSH, StepRun, code_result, complete, msg, text, tu, usage)  # noqa: E402


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) non installe")
class RunnerTests(unittest.TestCase):
    def run_case(self, cassette, **kw):
        r = StepRun(cassette, **kw)
        self.addCleanup(r.cleanup)
        return r

    # ------------------------------------------------------------------ fin normale
    def test_execute_step_writes_files_registers_deliverable_and_completes(self):
        r = self.run_case([
            msg([tu(1, "workspace_list", {"path": ""})], "tool_use", container="container_abc"),
            msg([tu(2, "workspace_write", {"path": "site/index.html", "content": "<h1>Bonjour</h1>", "mode": "create"})], "tool_use"),
            msg([tu(3, "deliverable_register", {"path": "site/index.html", "title": "Accueil", "kind": "site"}),
                 complete(4, summary="Page ecrite.", deliverables=[{"path": "site/index.html", "title": "Accueil"}],
                          criteriaClaims=[{"criterionId": "C1", "claim": "met", "evidence": [{"type": "file", "ref": "site/index.html"}]}],
                          summaryUpdate="Accueil fait.", handoffNote="Rien.")], "tool_use"),
        ])
        self.assertEqual(r.exit, 0, r.proc.stderr + r.proc.stdout)
        self.assertEqual(r.result["status"], "DONE")
        self.assertEqual(r.result["exitReason"], "step_complete")
        self.assertEqual(r.result["report"]["deliverables"], [{"path": "site/index.html", "title": "Accueil"}])
        self.assertEqual(r.result["iterations"], 3)
        self.assertEqual(r.read_ws("site/index.html"), "<h1>Bonjour</h1>")
        self.assertEqual(len(r.spool_rows("deliverables")), 1)
        calls = r.calls()
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0]["container"], "")                      # jamais de conteneur avant la premiere reponse
        self.assertEqual([c["container"] for c in calls[1:]], ["container_abc", "container_abc"])   # puis renvoye a chaque requete de l'etape
        self.assertTrue(all(c["systemCacheControl"] for c in calls))
        self.assertTrue(all(c["cacheMarkersInMessages"] == 1 and c["lastBlockHasMarker"] for c in calls), [(c["cacheMarkersInMessages"], c["lastBlockHasMarker"]) for c in calls])
        self.assertTrue(all(c["hasContextManagement"] and "context-management-2025-06-27" in c["betaHeader"] for c in calls))
        self.assertTrue(all(c["toolChoice"] == "" for c in calls))      # tool_choice reste auto
        self.assertTrue(all(c["hasInputExamples"] for c in calls))
        self.assertEqual(r.cost()["usage"]["api_calls"], 3)

    def test_system_prompt_carries_worker_identity_addendum_and_kind_guide(self):
        r = self.run_case([msg([complete(1)], "tool_use")], recipe="RECETTE-TEST : site vitrine")
        s = r.calls()[0]["systemText"]
        self.assertIn("PROJECT ADDENDUM", s)
        self.assertIn("ANTI-ABANDON", s)
        self.assertIn("DONNEES, PAS ORDRES", s)
        self.assertIn("RECETTE-TEST", s)
        self.assertIn("TA SORTE D'ETAPE : TRAVAIL", s)
        self.assertIn("UNTRUSTED CONTENT", s)            # prompt commun du Worker, inchange
        self.assertIn("OUTPUT_DIR", s)
        self.assertNotIn(FAKE_SECRET, json.dumps(r.log))

    def test_tool_list_follows_the_step_kind(self):
        r = self.run_case([msg([complete(1)], "tool_use")])
        names = r.calls()[0]["toolNames"]
        for n in ("workspace_write", "step_complete", "request_approval", "web_search", "code_execution", "memory"):
            self.assertIn(n, names)
        self.assertNotIn("check_run", names)
        self.assertNotIn("preview_fetch", names)

    # ------------------------------------------------------------------ arrets
    def test_cost_ceiling_stops_before_the_next_call_and_leaves_a_partial_report(self):
        r = self.run_case([msg([tu(1, "workspace_write", {"path": "a.md", "content": "x"})], "tool_use"), msg([complete(2)], "tool_use")], ceiling=0.0001)
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(len(r.calls()), 1)
        self.assertEqual(r.result["status"], "PARTIAL")
        self.assertEqual(r.result["exitReason"], "cost_ceiling")
        self.assertTrue(r.result["usage"]["cost_capped"])
        self.assertIn("a.md", r.result["report"]["summary"])           # le rapport minimal cite les fichiers ecrits
        self.assertTrue(os.path.isfile(r.ws("a.md")))                  # le travail deja fait est conserve

    def test_soft_deadline_in_the_past_makes_no_call(self):
        r = self.run_case([msg([complete(1)], "tool_use")], soft_s=-5, hard_s=100)
        self.assertEqual(r.exit, 0)
        self.assertEqual(len(r.calls()), 0)
        self.assertEqual((r.result["status"], r.result["exitReason"]), ("PARTIAL", "deadline"))

    def test_iteration_cap_forces_a_finalisation_call_without_tools(self):
        r = self.run_case([
            msg([tu(1, "workspace_write", {"path": "a.md", "content": "1"})], "tool_use"),
            msg([tu(2, "workspace_write", {"path": "b.md", "content": "2"})], "tool_use"),
            msg([text("Fait : a.md et b.md. Reste : c.md.")], "end_turn"),
        ], max_iterations=2)
        self.assertEqual(r.exit, 0, r.proc.stderr)
        calls = r.calls()
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[2]["toolChoice"], "none")
        self.assertEqual((r.result["status"], r.result["exitReason"]), ("PARTIAL", "iterations"))
        self.assertIn("Reste : c.md", r.result["report"]["summary"])
        self.assertIn("RAPPEL DE BUDGET", calls[1]["lastMessage"])      # rappel a 20 %

    def test_end_turn_without_step_complete_is_reminded_then_completes(self):
        r = self.run_case([msg([text("J'ai fini")], "end_turn"), msg([complete(2, summary="Fini.")], "tool_use")])
        self.assertEqual(r.result["status"], "DONE")
        self.assertIn("step_complete", r.calls()[1]["lastMessage"])

    def test_identical_calls_warn_then_stop(self):
        same = lambda i: msg([tu(i, "workspace_list", {"path": "site/"})], "tool_use")  # noqa: E731
        r = self.run_case([same(1), same(2), same(3), same(4), msg([complete(5)], "tool_use")])
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(r.result["status"], "PARTIAL")
        self.assertEqual(len(r.calls()), 4)                              # la 4e identique arrete l'etape
        self.assertIn("tournes en rond", r.calls()[3]["lastMessage"])    # avertissement des la 3e

    def test_a_write_resets_the_identical_call_counter(self):
        lst = lambda i: tu(i, "workspace_list", {"path": ""})  # noqa: E731
        r = self.run_case([msg([lst(1)], "tool_use"), msg([lst(2)], "tool_use"), msg([tu(3, "workspace_write", {"path": "a.md", "content": "x"})], "tool_use"),
                           msg([lst(4)], "tool_use"), msg([lst(5)], "tool_use"), msg([complete(6)], "tool_use")])
        self.assertEqual(r.result["status"], "DONE")

    # ------------------------------------------------------------------ API : pause_turn, reessais, replis
    def test_pause_turn_resends_the_assistant_turn_as_is_and_costs_no_iteration(self):
        server = {"type": "server_tool_use", "id": "srvtoolu_9", "name": "web_search", "input": {"query": "x"}}
        r = self.run_case([msg([server], "pause_turn", usage(1000, 50, web=1)), msg([complete(2)], "tool_use")])
        self.assertEqual(r.result["status"], "DONE")
        self.assertEqual(r.result["iterations"], 1)
        second = r.calls()[1]
        self.assertEqual(second["messageCount"], 2)                      # user + assistant : aucun message utilisateur ajoute
        self.assertIn("server_tool_use", second["lastMessage"])
        self.assertEqual(r.calls()[1]["webMaxUses"], 7)                  # max_uses = webMaxUses moins les recherches deja faites

    def test_transient_errors_are_retried_with_backoff(self):
        r = self.run_case([{"throwStatus": 529, "message": "overloaded"}, {"throwStatus": 429, "message": "rate", "retryAfter": 1}, msg([complete(1)], "tool_use")])
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(r.result["status"], "DONE")
        self.assertEqual(len(r.calls()), 3)
        self.assertIn("nouvel essai", r.runner_log())

    def test_api_down_after_four_retries_exits_12_with_retry_later(self):
        r = self.run_case([{"throwStatus": 503, "message": "down"}] * 6)
        self.assertEqual(r.exit, 12)
        self.assertEqual(r.result["status"], "RETRY_LATER")
        self.assertEqual(r.result["exitReason"], "api_unavailable")
        self.assertEqual(len(r.calls()), 5)                              # 1 appel + 4 reessais

    def test_context_management_rejected_is_retried_once_without_it(self):
        r = self.run_case([{"throw400": "context_management: Extra inputs are not permitted"}, msg([complete(1)], "tool_use")])
        self.assertEqual(r.result["status"], "DONE")
        a, b = r.calls()
        self.assertTrue(a["hasContextManagement"])
        self.assertFalse(b["hasContextManagement"])
        self.assertNotIn("context-management", b["betaHeader"])

    def test_tool_examples_rejected_are_dropped(self):
        r = self.run_case([{"throw400": "tools.3.custom.input_examples: Extra inputs are not permitted"}, msg([complete(1)], "tool_use")])
        self.assertEqual(r.result["status"], "DONE")
        self.assertTrue(r.calls()[0]["hasInputExamples"])
        self.assertFalse(r.calls()[1]["hasInputExamples"])

    def test_code_execution_falls_back_to_the_old_tool_version(self):
        r = self.run_case([{"throw400": "tool type code_execution_20250825 is not supported"}, msg([complete(1)], "tool_use")])
        self.assertEqual(r.result["status"], "DONE")
        a, b = r.calls()
        self.assertIn("code_execution_20250825:code_execution", a["toolTypes"])
        self.assertIn("code_execution_20250522:code_execution", b["toolTypes"])
        self.assertIn("code-execution-2025-05-22", b["betaHeader"])

    def test_prompt_too_long_ends_with_context_too_long_for_a_shrunk_rerun(self):
        r = self.run_case([{"throw400": "prompt is too long: 250000 tokens > 200000 maximum"}])
        self.assertEqual((r.result["status"], r.result["error"]), ("FAILED", "CONTEXT_TOO_LONG"))

    def test_max_tokens_with_a_cut_tool_call_asks_for_shorter_content(self):
        r = self.run_case([msg([tu(1, "workspace_write", {"path": "a.md"})], "max_tokens"), msg([complete(2)], "tool_use")])
        self.assertEqual(r.result["status"], "DONE")
        self.assertIn("coupee", r.calls()[1]["lastMessage"])
        self.assertEqual(r.calls()[1]["messageCount"], 2)                # la reponse coupee n'est pas renvoyee

    def test_refusal_retries_once_on_the_other_model_then_fails(self):
        r = self.run_case([msg([], "refusal"), msg([], "refusal")])
        self.assertEqual((r.result["status"], r.result["error"], r.result["exitReason"]), ("FAILED", "MODEL_REFUSAL", "refusal"))
        self.assertEqual([c["model"] for c in r.calls()], ["claude-sonnet-5-5", "claude-opus-5-5"])

    def test_refusal_then_success_on_the_other_model(self):
        r = self.run_case([msg([], "refusal"), msg([complete(1)], "tool_use")])
        self.assertEqual(r.result["status"], "DONE")

    # ------------------------------------------------------------------ rapport : refuse puis corrige
    def test_a_report_with_a_missing_deliverable_is_refused_then_fixed(self):
        r = self.run_case([
            msg([complete(1, deliverables=[{"path": "site/absent.html", "title": "X"}])], "tool_use"),
            msg([tu(2, "workspace_write", {"path": "site/absent.html", "content": "ok"}), complete(3, deliverables=[{"path": "site/absent.html", "title": "X"}])], "tool_use"),
        ])
        self.assertEqual(r.result["status"], "DONE")
        self.assertIn("STEP_REPORT_INVALID", r.calls()[1]["lastMessage"])
        self.assertIn("absent.html", r.calls()[1]["lastMessage"])

    def test_three_refused_reports_end_the_step_partial(self):
        bad = lambda i: msg([complete(i, deliverables=[{"path": "nope.html", "title": "X"}])], "tool_use")  # noqa: E731
        r = self.run_case([bad(1), bad(2), bad(3), msg([text("Rien de livrable.")], "end_turn")])
        self.assertEqual(r.result["status"], "PARTIAL")
        self.assertEqual(len(r.calls()), 4)                              # 3 rapports refuses, puis l'appel de finalisation sans outil
        self.assertEqual(r.calls()[3]["toolChoice"], "none")
        self.assertEqual(r.result["error"], "STEP_REPORT_INVALID")

    def test_blocked_step_is_reported(self):
        r = self.run_case([msg([tu(1, "step_blocked", {"reason": "CONNECTOR", "detail": "Webflow n'est pas connecte", "resumeHint": "Reprendre apres connexion"})], "tool_use")])
        self.assertEqual((r.result["status"], r.result["exitReason"]), ("BLOCKED", "step_blocked"))
        self.assertEqual(r.result["report"]["blocked"]["reason"], "CONNECTOR")

    def test_needs_input_flow(self):
        r = self.run_case([msg([tu(1, "request_input", {"question": "Quel nom de domaine ?", "blocking": True}),
                                complete(2, status="NEEDS_INPUT", summary="En attente du domaine.")], "tool_use")])
        self.assertEqual(r.result["status"], "NEEDS_INPUT")
        self.assertEqual(len(r.spool_rows("inputs")), 1)

    # ------------------------------------------------------------------ connecteurs : ecriture = article d'approbation, la boucle continue
    def test_connector_write_becomes_an_approval_item_and_the_loop_continues(self):
        r = self.run_case([
            msg([tu(1, "use_connector", {"connectorId": "gmail", "operation": "DRAFT_MESSAGE", "reason": "prospect",
                                          "params": {"To": "marie@exemple.ch", "Subject": "Bonjour", "Body": "Texte"}})], "tool_use"),
            msg([complete(2, summary="1 brouillon prepare.")], "tool_use"),
        ], activated=("gmail",))
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(r.result["status"], "DONE")
        self.assertIn("QUEUED:APR-", r.calls()[1]["lastMessage"])
        rows = r.spool_rows("approvals")
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["connectorId"], rows[0]["operation"], rows[0]["status"], rows[0]["risk"]), ("gmail", "DRAFT_MESSAGE", "PENDING", "low"))
        self.assertFalse(os.path.exists(os.path.join(r.root, "memory", "runtime", "PENDING-ACTION-" + "x" * 5 + ".json")))

    def test_connector_not_activated_is_refused_without_an_item(self):
        r = self.run_case([msg([tu(1, "use_connector", {"connectorId": "slack", "operation": "POST_MESSAGE", "reason": "x", "params": {"Text": "t"}})], "tool_use"),
                           msg([complete(2)], "tool_use")], activated=("gmail",), tools=None)
        self.assertEqual(r.result["status"], "DONE")
        self.assertIn("pas connecte", r.calls()[1]["lastMessage"])
        self.assertEqual(r.spool_rows("approvals"), [])

    def test_duplicate_connector_write_is_not_queued_twice(self):
        call = lambda i: tu(i, "use_connector", {"connectorId": "gmail", "operation": "DRAFT_MESSAGE", "reason": "r", "params": {"To": "a@b.ch", "Subject": "s", "Body": "b"}})  # noqa: E731
        r = self.run_case([msg([call(1)], "tool_use"), msg([call(2)], "tool_use"), msg([complete(3)], "tool_use")], activated=("gmail",))
        self.assertEqual(len(r.spool_rows("approvals")), 1)

    def test_preauthorised_true_draft_is_executed_and_recorded_as_automatic(self):
        r = self.run_case([msg([tu(1, "use_connector", {"connectorId": "gmail", "operation": "DRAFT_MESSAGE", "reason": "r", "params": {"To": "a@b.ch", "Subject": "s", "Body": "b"}})], "tool_use"),
                           msg([complete(2)], "tool_use")], activated=("gmail",), auto_approve=True)
        rows = r.spool_rows("approvals")
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["status"], rows[0]["autoApproved"]), ("EXECUTED", True))

    def test_preauthorisation_never_covers_something_that_publishes(self):
        r = self.run_case([msg([tu(1, "use_connector", {"connectorId": "linkedin", "operation": "CREATE_DRAFT_POST", "reason": "r", "params": {"Text": "salut"}})], "tool_use"),
                           msg([complete(2)], "tool_use")], activated=("linkedin",), auto_approve=True)
        rows = r.spool_rows("approvals")
        self.assertEqual((rows[0]["status"], rows[0]["risk"]), ("PENDING", "medium"))

    # ------------------------------------------------------------------ fichiers
    def test_sandbox_files_are_imported_through_the_safe_path_and_deleted_at_anthropic(self):
        r = self.run_case([
            msg([{"type": "server_tool_use", "id": "srvtoolu_1", "name": "code_execution", "input": {}}, code_result("file_x1"), tu(1, "workspace_list", {})], "tool_use"),
            msg([complete(2)], "tool_use"),
        ], files={"file_x1": {"filename": "site__assets__hero.png", "mime_type": "image/png", "size_bytes": 64}})
        self.assertEqual(r.result["status"], "DONE")
        self.assertTrue(os.path.isfile(r.ws("site/assets/hero.png")))
        self.assertEqual(r.result["filesImported"], [{"path": "site/assets/hero.png", "bytes": 64}])
        self.assertEqual([f["method"] for f in r.of_kind("file") if f["fileId"] == "file_x1"], ["GET", "Delete"])

    def test_a_sandbox_file_with_a_forbidden_extension_is_refused(self):
        r = self.run_case([msg([code_result("file_x2"), tu(1, "workspace_list", {})], "tool_use"), msg([complete(2)], "tool_use")],
                          files={"file_x2": {"filename": "malware.exe", "mime_type": "application/octet-stream", "size_bytes": 10}})
        self.assertEqual(r.result["filesImported"], [])
        self.assertFalse(os.path.exists(r.ws("malware.exe")))
        self.assertTrue(any("malware.exe" in e for e in r.result.get("importErrors", [])))

    def test_input_files_go_through_the_files_api_and_are_deleted_after_the_step(self):
        r = self.run_case([msg([complete(1)], "tool_use")], workspace={"data/prospects.csv": "a;b\n1;2\n", "inputs/brief.pdf": b"%PDF-1.4 x"},
                          input_files=[{"path": "data/prospects.csv", "as": "container_upload"}, {"path": "inputs/brief.pdf", "as": "document"}])
        self.assertEqual(r.result["status"], "DONE")
        self.assertEqual(len(r.of_kind("upload")), 2)
        first = r.calls()[0]
        self.assertEqual(first["firstBlockTypes"], ["container_upload", "document", "text"])   # le contexte vient en dernier (point d'arret de cache)
        self.assertIn("files-api-2025-04-14", first["betaHeader"])
        self.assertEqual(sorted(f["fileId"] for f in r.of_kind("file") if f["method"] == "Delete"), ["file_up_1", "file_up_2"])
        with open(os.path.join(r.step_dir, "files-api.json"), encoding="utf-8-sig") as f:
            self.assertEqual(json.load(f)["uploaded"], [])

    # ------------------------------------------------------------------ outils sensibles
    def test_workspace_write_refuses_traversal_secrets_and_overwrite(self):
        r = self.run_case([
            msg([tu(1, "workspace_write", {"path": "../evil.md", "content": "x"}), tu(2, "workspace_write", {"path": "n.md", "content": "mot de passe: hunter22secret"}),
                 tu(3, "workspace_write", {"path": "ok.md", "content": "v1"}), tu(4, "workspace_write", {"path": "ok.md", "content": "v2"})], "tool_use"),
            msg([complete(5)], "tool_use"),
        ])
        last = r.calls()[1]["lastMessage"]
        self.assertIn("PATH_INVALID", last)
        self.assertIn("SECRET_REFUSED", last)
        self.assertIn("EXISTS", last)
        self.assertEqual(r.read_ws("ok.md"), "v1")
        self.assertFalse(os.path.exists(os.path.join(r.project_dir, "evil.md")))

    def test_view_image_returns_an_image_block(self):
        png = bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360000002000001e221bc330000000049454e44ae426082")
        r = self.run_case([msg([tu(1, "workspace_view_image", {"path": "img/a.png"})], "tool_use"), msg([complete(2)], "tool_use")], workspace={"img/a.png": png})
        self.assertIn('"type":"image"', r.calls()[1]["lastMessage"])
        self.assertIn("image/png", r.calls()[1]["lastMessage"])

    def test_memory_writes_are_capped_at_six_per_step(self):
        calls = [tu(i, "memory", {"action": "write", "name": f"n{i}", "type": "client", "description": "d", "content": "texte"}) for i in range(1, 9)]
        r = self.run_case([msg(calls, "tool_use"), msg([complete(9)], "tool_use")])
        self.assertEqual(r.result["status"], "DONE")
        self.assertEqual(r.calls()[1]["lastMessage"].count("Limite atteinte"), 2)
        notes = os.listdir(os.path.join(r.root, "runtime", "client-memory", "CLI-CUST-AAAAAAAA"))
        self.assertEqual(len([n for n in notes if n.startswith("n")]), 6)

    # ------------------------------------------------------------------ autres sortes d'etape
    def test_verifier_has_no_write_tool_and_a_neutral_identity(self):
        verif = {"criteria": [{"id": "C1", "verdict": "PASS", "note": "ok", "evidence": [{"type": "file", "ref": "a.md"}]}], "overall": "PASS", "summary": "RAS"}
        r = self.run_case([msg([complete(1, verification=verif)], "tool_use")], kind="verify", worker="qa", workspace={"a.md": "contenu"})
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(r.result["status"], "DONE")
        self.assertEqual(r.result["report"]["verification"]["overall"], "PASS")
        c = r.calls()[0]
        for n in ("workspace_write", "workspace_append", "workspace_delete", "use_connector", "request_approval", "memory", "code_execution", "web_search"):
            self.assertNotIn(n, c["toolNames"])
        for n in ("check_run", "preview_fetch", "web_fetch", "step_complete", "workspace_read"):
            self.assertIn(n, c["toolNames"])
        self.assertIn("CONTROLEUR QUALITE", c["systemText"])
        self.assertNotIn("ANTI-ABANDON", c["systemText"])

    def test_verifier_check_run_registers_evidence_for_the_round(self):
        r = self.run_case([
            msg([tu(1, "check_run", {"check": {"type": "file_exists", "path": "a.md", "minBytes": 3}})], "tool_use"),
            msg([complete(2, verification={"criteria": [{"id": "C1", "verdict": "PASS", "note": "ok", "evidence": [{"type": "file", "ref": "a.md"}]}], "overall": "PASS"})], "tool_use"),
        ], kind="verify", worker="qa", workspace={"a.md": "contenu"})
        self.assertEqual(r.result["status"], "DONE")
        self.assertIn('\\"ok\\":true', r.calls()[1]["lastMessage"])
        checks = os.listdir(os.path.join(r.project_dir, "verification", "1", "checks"))
        self.assertEqual(len(checks), 1)

    def test_answer_step_returns_the_text_and_cannot_write(self):
        r = self.run_case([msg([text("Le site est prevu pour jeudi.")], "end_turn")], kind="answer", max_iterations=4)
        self.assertEqual(r.result["status"], "DONE")
        self.assertEqual(r.result["answerText"], "Le site est prevu pour jeudi.")
        self.assertNotIn("workspace_write", r.calls()[0]["toolNames"])
        self.assertNotIn("step_complete", r.calls()[0]["toolNames"])

    def test_plan_step_saves_a_validated_plan_to_the_spool(self):
        plan = {"goal": "Site", "language": "fr", "criteria": [{"id": "C1", "text": "Page d'accueil", "kind": "auto", "check": {"type": "file_exists", "path": "site/index.html"}}],
                "steps": [{"id": "S1", "title": "Accueil", "worker": "lucas", "goal": "Ecrire l'accueil", "criteriaIds": ["C1"], "expectedOutputs": ["site/index.html"]}]}
        r = self.run_case([msg([tu(1, "project_plan", {"action": "set", "plan": plan}), complete(2, summary="Plan pret.")], "tool_use")], kind="plan", worker="chloe",
                          plan_md="REGLE-CHLOE-TEST")
        self.assertEqual(r.result["status"], "DONE")
        self.assertTrue(os.path.isfile(os.path.join(r.spool, "plan-S1.json")))
        self.assertIn("REGLE-CHLOE-TEST", r.calls()[0]["systemText"])
        self.assertIn("PLANIFICATION", r.calls()[0]["systemText"])

    def test_an_invalid_plan_is_refused_with_the_errors(self):
        plan = {"goal": "Site", "criteria": [{"id": "C1", "text": "x", "kind": "rubric"}], "steps": [{"id": "S1", "title": "t", "worker": "lucas", "goal": "g"}]}
        r = self.run_case([msg([tu(1, "project_plan", {"action": "set", "plan": plan})], "tool_use"), msg([complete(2)], "tool_use")], kind="plan", worker="chloe")
        self.assertIn("PLAN_INVALID", r.calls()[1]["lastMessage"])
        self.assertIn("C1", r.calls()[1]["lastMessage"])

    # ------------------------------------------------------------------ entree et cle
    def test_invalid_input_exits_10(self):
        r = self.run_case([], bad_input=True)
        self.assertEqual(r.exit, 10)
        self.assertEqual(r.result["status"], "FAILED")
        self.assertEqual(r.result["error"], "INPUT_INVALID")

    def test_missing_key_exits_11(self):
        r = self.run_case([msg([complete(1)], "tool_use")], key=False)
        self.assertEqual(r.exit, 11)
        self.assertEqual(r.result["error"], "CREDENTIAL_NOT_CONFIGURED")
        self.assertEqual(len(r.calls()), 0)

    def test_no_secret_in_any_file_written_by_the_runner(self):
        r = self.run_case([msg([tu(1, "workspace_write", {"path": "a.md", "content": "x"})], "tool_use"), msg([complete(2)], "tool_use")])
        blob = ""
        for dirpath, _d, files in os.walk(r.project_dir):
            for n in files:
                try:
                    blob += open(os.path.join(dirpath, n), encoding="utf-8", errors="ignore").read()
                except OSError:
                    pass
        self.assertNotIn(FAKE_SECRET, blob)
        self.assertNotIn(FAKE_SECRET, r.proc.stdout + r.proc.stderr)


FAKE_SECRET = "FAKE-ANTHROPIC-KEY-FOR-TESTS-ONLY"

if __name__ == "__main__":
    unittest.main(verbosity=2)
