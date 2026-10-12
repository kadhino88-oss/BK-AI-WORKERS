"""ANTHROPIC-ADAPTER.ps1 apres la revue d'integration du 2026-10-11 : prompt mis en cache, auto-approve limite aux
vrais brouillons, fichiers generes (tous les tours, plafonds, suppression chez Anthropic), repli d'outil cible.

PowerShell 7 requis (pwsh). Aucun reseau, aucun cout : l'API est simulee par tests/adapter-review/fake_api.ps1.
    python3 -m unittest tests/adapter-review/test_adapter_review.py -v
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
FAKE_KEY = "FAKE-ANTHROPIC-KEY-FOR-TESTS-ONLY"
TASK = "TASK-" + "A" * 32
CLIENT = "CLI-ADAPTER-TEST"

DRIVER = r'''
$ErrorActionPreference = "Stop"
. (Join-Path $env:BK_ROOT "_test/fake_api.ps1")
$Out = & (Join-Path $env:BK_ROOT "core/ai/adapters/ANTHROPIC-ADAPTER.ps1") `
    -ClientId $env:T_CLIENT -ProjectId "PROJ-T" -WorkerId "noah" -TaskId $env:T_TASK `
    -Objective "Prepare le brouillon et publie le post" -Model "claude-sonnet-5-5"
$Exit = $LASTEXITCODE
[ordered]@{ exit = $Exit; stdout = (($Out | Out-String).Trim()) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:OUT_FILE -Encoding utf8
'''


def text_block(text):
    return {"type": "text", "text": text}


def usage(i=1000, o=100):
    return {"input_tokens": i, "output_tokens": o}


def tool_use(i, connector, operation, params=None):
    return {"type": "tool_use", "id": f"toolu_{i}", "name": "use_connector",
            "input": {"connectorId": connector, "operation": operation, "reason": "test", "params": params or {}}}


def code_result(*file_ids):
    return {"type": "bash_code_execution_tool_result", "tool_use_id": "srvtoolu_1",
            "content": {"type": "bash_code_execution_result", "stdout": "", "stderr": "", "return_code": 0,
                        "content": [{"type": "bash_code_execution_output", "file_id": fid} for fid in file_ids]}}


def msg(content, stop="end_turn"):
    return {"body": {"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-sonnet-5-5",
                     "content": content, "stop_reason": stop, "usage": usage()}}


class Run:
    def __init__(self, cassette, files=None, env=None, activated=("gmail", "linkedin"), auto_approve=True):
        self.root = tempfile.mkdtemp(prefix="bkadrev-")
        shutil.copytree(os.path.join(REPO, "core"), os.path.join(self.root, "core"),
                        ignore=shutil.ignore_patterns("client-credentials", "accounts", "__pycache__", "*.pyc"))
        for sub in ("_test", "memory/runtime", "runtime/tasks", "core/connectors/data"):
            os.makedirs(os.path.join(self.root, sub), exist_ok=True)
        shutil.copy2(os.path.join(HERE, "fake_api.ps1"), os.path.join(self.root, "_test", "fake_api.ps1"))
        with open(os.path.join(self.root, "core/connectors/data", CLIENT + ".json"), "w", encoding="utf-8") as f:
            json.dump(list(activated), f)
        if auto_approve:
            with open(os.path.join(self.root, "core/connectors/data", CLIENT + ".autoapprove.json"), "w", encoding="utf-8") as f:
                json.dump({"autoApprove": True}, f)
        cassette_path = os.path.join(self.root, "_test", "cassette.json")
        with open(cassette_path, "w", encoding="utf-8") as f:
            json.dump({"responses": cassette}, f)
        driver = os.path.join(self.root, "_test", "driver.ps1")
        with open(driver, "w", encoding="utf-8") as f:
            f.write(DRIVER)
        self.out_file = os.path.join(self.root, "_test", "out.json")
        self.log_file = os.path.join(self.root, "_test", "requests.jsonl")
        self.cassette_path = cassette_path
        self.driver = driver
        self.env = dict(os.environ, BK_ROOT=self.root, OUT_FILE=self.out_file, FAKE_CASSETTE=cassette_path, FAKE_LOG=self.log_file,
                        FAKE_KEY=FAKE_KEY, BK_SECRET_ANTHROPIC=FAKE_KEY, T_CLIENT=CLIENT, T_TASK=TASK, BK_REPLY_LANG="")
        if files:
            self.env["FAKE_FILES"] = json.dumps(files)
        self.env.update(env or {})
        self._execute()

    def rerun(self, cassette, task=None):
        """Seconde mission dans le MEME dossier (meme client, memes fils de conversation)."""
        with open(self.cassette_path, "w", encoding="utf-8") as f:
            json.dump({"responses": cassette}, f)
        if os.path.isfile(self.log_file):
            os.remove(self.log_file)
        if task:
            self.env["T_TASK"] = task
        self._execute()

    def _execute(self):
        self.proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", self.driver], capture_output=True, text=True,
                                   encoding="utf-8", errors="replace", env=self.env, timeout=300, cwd=self.root)
        assert os.path.isfile(self.out_file), f"driver produced nothing\nSTDOUT:\n{self.proc.stdout}\nSTDERR:\n{self.proc.stderr}"
        with open(self.out_file, encoding="utf-8-sig") as f:
            out = json.load(f)
        self.exit = out["exit"]
        self.result = json.loads(out["stdout"]) if out["stdout"].startswith("{") else {"raw": out["stdout"]}
        self.log = []
        if os.path.isfile(self.log_file):
            with open(self.log_file, encoding="utf-8") as f:
                self.log = [json.loads(line) for line in f if line.strip()]

    def of_kind(self, kind):
        return [r for r in self.log if r["kind"] == kind]

    def task_files(self):
        d = os.path.join(self.root, "runtime", "task-files", TASK)
        return {n: os.path.getsize(os.path.join(d, n)) for n in os.listdir(d)} if os.path.isdir(d) else {}

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class AdapterReview(unittest.TestCase):
    def run_case(self, *a, **k):
        r = Run(*a, **k)
        self.addCleanup(r.cleanup)
        return r

    def test_system_prompt_is_a_cacheable_block_on_every_call(self):
        r = self.run_case([msg([tool_use(1, "gmail", "READ_MESSAGE", {"Id": "1"})], "tool_use"), msg([text_block("ok")])])
        self.assertEqual(r.exit, 0, r.proc.stderr)
        calls = r.of_kind("messages")
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(c["systemIsArray"] and c["systemCacheControl"] for c in calls), calls)

    def test_auto_approve_executes_only_true_drafts(self):
        r = self.run_case([
            msg([tool_use(1, "gmail", "DRAFT_MESSAGE", {"To": "a@b.ch", "Subject": "s", "Body": "b"}),
                 tool_use(2, "linkedin", "CREATE_DRAFT_POST", {"Text": "salut"})], "tool_use"),
            msg([text_block("fait")]),
        ])
        self.assertEqual(r.exit, 0, r.proc.stderr)
        by = {a["connectorId"] + "|" + a["operation"]: a for a in r.result["connector_actions"]}
        self.assertTrue(by["gmail|DRAFT_MESSAGE"]["executed"])                      # vrai brouillon : auto-execute
        self.assertTrue(by["gmail|DRAFT_MESSAGE"]["autoApproved"])
        self.assertFalse(by["linkedin|CREATE_DRAFT_POST"]["executed"])              # PUBLIE pour de vrai : carte de confirmation
        self.assertEqual(by["linkedin|CREATE_DRAFT_POST"]["status"], "PENDING_CONFIRMATION")
        self.assertTrue(os.path.isfile(os.path.join(r.root, "memory", "runtime", f"PENDING-ACTION-{TASK}.json")))

    def test_old_behaviour_comes_back_with_the_switch_off(self):
        r = self.run_case([
            msg([tool_use(1, "linkedin", "CREATE_DRAFT_POST", {"Text": "salut"})], "tool_use"),
            msg([text_block("fait")]),
        ], env={"BK_AUTOAPPROVE_DRAFTS_ONLY": "0"})
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertTrue(r.result["connector_actions"][0]["executed"])

    def test_without_auto_approve_every_write_waits_for_the_client(self):
        r = self.run_case([
            msg([tool_use(1, "gmail", "DRAFT_MESSAGE", {"To": "a@b.ch"})], "tool_use"),
            msg([text_block("ok")]),
        ], auto_approve=False)
        self.assertFalse(r.result["connector_actions"][0]["executed"])
        self.assertEqual(r.result["connector_actions"][0]["status"], "PENDING_CONFIRMATION")

    def test_files_from_every_turn_are_captured_capped_and_deleted_remotely(self):
        files = {
            "file_early": {"filename": "devis.pdf", "mime_type": "application/pdf", "size_bytes": 4000},
            "file_late": {"filename": "../../evil name.xlsx", "mime_type": "application/vnd.ms-excel", "size_bytes": 9000},
            "file_huge": {"filename": "gros.zip", "mime_type": "application/zip", "size_bytes": 30 * 1024 * 1024},
        }
        r = self.run_case([
            # tour 1 : un fichier est produit ET un connecteur (lecture) est appele -> ce fichier ne doit pas etre perdu
            msg([code_result("file_early"), tool_use(1, "gmail", "READ_MESSAGE", {"Id": "1"})], "tool_use"),
            msg([code_result("file_late", "file_huge"), text_block("Voici vos documents.")]),
        ], files=files)
        self.assertEqual(r.exit, 0, r.proc.stderr)
        got = r.task_files()
        self.assertEqual(sorted(got), ["devis.pdf", "evil_name.xlsx"], got)          # noms assainis, tour 1 inclus
        self.assertEqual({f["filename"] for f in r.result["files"]}, {"devis.pdf", "evil_name.xlsx"})
        self.assertNotIn("gros.zip", got)                                            # > 25 Mo : ignore
        self.assertIn("non joint", r.result["answer"])
        self.assertIn("gros.zip", r.result["answer"])
        deleted = {x["fileId"] for x in r.of_kind("file") if x["method"] == "Delete"}
        self.assertEqual(deleted, {"file_early", "file_late", "file_huge"})          # plus rien chez Anthropic
        downloaded = {x["fileId"] for x in r.of_kind("download")}
        self.assertNotIn("file_huge", downloaded)                                    # jamais telecharge

    def test_at_most_ten_files_per_mission(self):
        ids = [f"f{i:02d}" for i in range(13)]
        files = {i: {"filename": f"{i}.csv", "mime_type": "text/csv", "size_bytes": 100} for i in ids}
        r = self.run_case([msg([code_result(*ids), text_block("ok")])], files=files)
        self.assertEqual(len(r.task_files()), 10)
        self.assertEqual({x["fileId"] for x in r.of_kind("file") if x["method"] == "Delete"}, set(ids))

    def test_tool_version_fallback_only_on_http_400_about_tools(self):
        r = self.run_case([{"throw400": "400 invalid_request_error: tool type code_execution_20250825 is not supported"},
                           msg([text_block("repli ok")])])
        self.assertEqual(r.exit, 0, r.proc.stderr)
        calls = r.of_kind("messages")
        self.assertEqual(len(calls), 2)
        self.assertIn("code_execution_20250825:code_execution", calls[0]["toolTypes"])
        self.assertIn("code_execution_20250522:code_execution", calls[1]["toolTypes"])
        self.assertEqual(calls[1]["betaHeader"], "code-execution-2025-05-22")

    def test_timeout_or_server_error_is_not_retried_with_the_legacy_tool(self):
        r = self.run_case([{"throw": "The operation was canceled: timeout after 240 seconds"}, msg([text_block("ne doit pas arriver")])])
        self.assertEqual(r.exit, 1)
        self.assertEqual(len(r.of_kind("messages")), 1)                              # une seule requete : pas de double generation


if __name__ == "__main__":
    unittest.main(verbosity=2)
