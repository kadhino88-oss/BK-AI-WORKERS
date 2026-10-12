"""Memoire de conversation v2 (core/ai/adapters/Get-RecentConversation.ps1) : un Worker se souvient de la conversation.

PowerShell 7 requis. Aucun reseau. python3 -m unittest tests/conversation-memory/test_memory.py -v
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
sys.path.insert(0, os.path.join(REPO, "tests", "adapter-review"))

DRIVER = r'''
$ErrorActionPreference = "Stop"
. (Join-Path $env:BK_ROOT "core/ai/adapters/Get-RecentConversation.ps1")
$steps = Get-Content -LiteralPath $env:STEPS_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
$res = [ordered]@{}
$i = 0
foreach ($s in $steps) {
    $i++
    if ($s.op -eq "add") {
        Add-BKConversationTurn -Root $env:BK_ROOT -ClientId $s.client -WorkerId $s.worker -TaskId ([string]$s.taskId) -Request ([string]$s.request) -Answer ([string]$s.answer) -Files @($s.files | ForEach-Object { @{ filename = $_ } }) -Actions @($s.actions | ForEach-Object { @{ connectorId = $_.connectorId; operation = $_.operation; status = $_.status } })
    }
    elseif ($s.op -eq "recall") {
        $turns = @(Get-BKRecentConversationTurns -Root $env:BK_ROOT -ClientId $s.client -WorkerId $s.worker)
        $res["r$i"] = @($turns | ForEach-Object { [ordered]@{ role = [string]$_.role; content = [string]$_.content } })
    }
}
$res | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $env:OUT_FILE -Encoding utf8
'''


def run_steps(root, steps):
    os.makedirs(os.path.join(root, "core", "ai", "adapters"), exist_ok=True)
    shutil.copy2(os.path.join(REPO, "core", "ai", "adapters", "Get-RecentConversation.ps1"),
                 os.path.join(root, "core", "ai", "adapters", "Get-RecentConversation.ps1"))
    sf, out, drv = (os.path.join(root, n) for n in ("steps.json", "out.json", "driver.ps1"))
    json.dump(steps, open(sf, "w", encoding="utf-8"))
    open(drv, "w", encoding="utf-8").write(DRIVER)
    p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", drv], capture_output=True, text=True, encoding="utf-8",
                       errors="replace", env=dict(os.environ, BK_ROOT=root, STEPS_FILE=sf, OUT_FILE=out), timeout=240)
    assert os.path.isfile(out), p.stdout + p.stderr
    return json.load(open(out, encoding="utf-8-sig"))


def add(client, worker, n, request=None, answer=None, **kw):
    return dict(op="add", client=client, worker=worker, taskId=f"TASK-{n:032d}", request=request or f"demande numero {n}",
                answer=answer or f"reponse numero {n}", files=kw.get("files", []), actions=kw.get("actions", []))


def recall(client, worker):
    return dict(op="recall", client=client, worker=worker)


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class ConversationMemory(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="bkmem-")
        self.addCleanup(shutil.rmtree, self.root, True)

    def test_a_worker_remembers_the_whole_recent_conversation_in_order(self):
        steps = [add("CLI-A", "dario", i) for i in range(1, 6)] + [recall("CLI-A", "dario")]
        turns = run_steps(self.root, steps)["r6"]
        self.assertEqual([t["role"] for t in turns], ["user", "assistant"] * 5)
        self.assertEqual(turns[0]["content"], "demande numero 1")
        self.assertEqual(turns[-1]["content"], "reponse numero 5")

    def test_the_end_of_a_long_answer_is_kept_where_the_questions_are(self):
        long_answer = "DEBUT " + ("x" * 9000) + " QUESTION_FINALE : quel est le montant exact ?"
        turns = run_steps(self.root, [add("CLI-A", "clara", 1, answer=long_answer), add("CLI-A", "clara", 2), recall("CLI-A", "clara")])["r3"]
        first_answer = turns[1]["content"]
        self.assertIn("DEBUT", first_answer)
        self.assertIn("QUESTION_FINALE : quel est le montant exact ?", first_answer)   # la v1 coupait a 900 caracteres : fin perdue
        self.assertLessEqual(len(first_answer), 6100)

    def test_old_turns_are_condensed_and_very_old_ones_become_a_digest(self):
        steps = [add("CLI-A", "maya", i, answer="y" * 5000 + f" fin{i}") for i in range(1, 41)] + [recall("CLI-A", "maya")]
        turns = run_steps(self.root, steps)["r41"]
        self.assertEqual(turns[0]["role"], "user")
        self.assertIn("Memoire de la conversation", turns[0]["content"])              # resume des demandes anciennes
        self.assertIn("demande numero 10", turns[0]["content"])
        roles = [t["role"] for t in turns]
        self.assertTrue(all(roles[i] != roles[i + 1] for i in range(len(roles) - 1)), "roles must alternate")
        self.assertIn("fin40", turns[-1]["content"])                                  # le tout dernier tour garde sa fin
        total = sum(len(t["content"]) for t in turns)
        self.assertLess(total, 45000, total)                                          # budget borne : cout/latence maitrises
        mids = [t for t in turns[2:-4] if t["role"] == "assistant"]
        self.assertTrue(all(len(t["content"]) <= 1600 for t in mids))

    def test_files_and_prepared_actions_are_remembered(self):
        steps = [add("CLI-A", "noah", 1, files=["bilan.xlsx"], actions=[{"connectorId": "gmail", "operation": "DRAFT_MESSAGE", "status": "PENDING_CONFIRMATION"}]),
                 recall("CLI-A", "noah")]
        text = run_steps(self.root, steps)["r2"][1]["content"]
        self.assertIn("Fichiers produits : bilan.xlsx", text)
        self.assertIn("gmail DRAFT_MESSAGE (PENDING_CONFIRMATION)", text)

    def test_threads_are_per_client_and_per_worker(self):
        steps = [add("CLI-A", "noah", 1, answer="secret de A"), add("CLI-B", "noah", 2), add("CLI-A", "alex", 3),
                 recall("CLI-B", "noah"), recall("CLI-A", "alex")]
        res = run_steps(self.root, steps)
        self.assertNotIn("secret de A", json.dumps(res["r4"]))
        self.assertEqual(len(res["r4"]), 2)
        self.assertNotIn("secret de A", json.dumps(res["r5"]))

    def test_trial_clients_and_unsafe_ids_never_touch_the_disk(self):
        steps = [add("CLI-TRIAL-PUBLIC", "noah", 1), add("../evil", "noah", 2), add("CLI-A", "../../x", 3),
                 recall("CLI-TRIAL-PUBLIC", "noah"), recall("../evil", "noah")]
        res = run_steps(self.root, steps)
        self.assertEqual(res["r4"] if isinstance(res["r4"], list) else [], [])
        self.assertFalse(os.path.exists(os.path.join(self.root, "runtime", "threads", "CLI-TRIAL-PUBLIC")))
        self.assertFalse(os.path.exists(os.path.join(self.root, "runtime", "evil")))
        self.assertFalse(os.path.exists(os.path.join(self.root, "x.jsonl")))

    def test_a_damaged_line_is_ignored_not_fatal(self):
        run_steps(self.root, [add("CLI-A", "sam", 1)])
        path = os.path.join(self.root, "runtime", "threads", "CLI-A", "SAM.jsonl")
        with open(path, "a", encoding="utf-8") as f:
            f.write("{pas du json\n")
        turns = run_steps(self.root, [add("CLI-A", "sam", 2), recall("CLI-A", "sam")])["r2"]
        self.assertEqual(len(turns), 4)

    def test_first_use_migrates_the_old_task_files_once(self):
        tasks = os.path.join(self.root, "runtime", "tasks")
        os.makedirs(tasks)
        def task(n, client, worker, status="EXECUTED", authorized=True):
            json.dump({"TaskId": f"TASK-{n:032d}", "ClientId": client, "Worker": worker, "Status": status, "Authorized": authorized,
                       "CreatedAtUtc": f"2026-10-0{n}T10:00:00Z", "Request": f"ancienne demande {n}", "Result": {"Answer": f"ancienne reponse {n}"}},
                      open(os.path.join(tasks, f"TASK-{n:032d}.json"), "w", encoding="utf-8"))
        task(1, "CLI-A", "LEA"); task(2, "CLI-A", "LEA"); task(3, "CLI-OTHER", "LEA"); task(4, "CLI-A", "LEA", status="ERROR"); task(5, "CLI-A", "ALEX")
        turns = run_steps(self.root, [recall("CLI-A", "lea")])["r1"]
        self.assertEqual([t["content"] for t in turns if t["role"] == "user"], ["ancienne demande 1", "ancienne demande 2"])
        thread = os.path.join(self.root, "runtime", "threads", "CLI-A", "LEA.jsonl")
        self.assertTrue(os.path.isfile(thread), "the thread must be backfilled so the tasks directory is not scanned again")
        for n in range(1, 6):                                                          # plus aucune lecture des TASK apres la migration
            os.remove(os.path.join(tasks, f"TASK-{n:032d}.json"))
        again = run_steps(self.root, [recall("CLI-A", "lea")])["r1"]
        self.assertEqual(len(again), 4)


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class AdapterRemembersAcrossMissions(unittest.TestCase):
    def test_second_mission_receives_the_first_one_in_its_messages(self):
        import test_adapter_review as t
        r = t.Run([t.msg([t.text_block("Voici le devis. Voulez-vous la version PDF ?")])], activated=("gmail",), auto_approve=False)
        self.addCleanup(r.cleanup)
        self.assertEqual(r.exit, 0, r.proc.stderr)
        first = r.of_kind("messages")[0]["messageCount"]
        thread = os.path.join(r.root, "runtime", "threads", t.CLIENT, "NOAH.jsonl")
        self.assertTrue(os.path.isfile(thread))
        entry = json.loads(open(thread, encoding="utf-8").read().splitlines()[0])
        self.assertIn("Voulez-vous la version PDF", entry["answer"])
        r.rerun([t.msg([t.text_block("D'accord, version PDF.")])], task="TASK-" + "B" * 32)
        self.assertEqual(r.exit, 0, r.proc.stderr)
        second = r.of_kind("messages")[0]["messageCount"]
        self.assertEqual(second, first + 2)                      # + 1 demande + 1 reponse de la mission precedente


if __name__ == "__main__":
    unittest.main(verbosity=2)
