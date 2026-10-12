"""Memoire durable du client (core/ai/adapters/Client-Memory.ps1) + niveaux de travail dans l'adaptateur.

PowerShell 7 requis. Aucun reseau. python3 -m unittest tests/client-memory/test_client_memory.py -v
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
. (Join-Path $env:BK_ROOT "core/ai/adapters/Client-Memory.ps1")
$steps = Get-Content -LiteralPath $env:STEPS_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
$res = [ordered]@{}
$i = 0
foreach ($s in $steps) {
    $i++
    $in = $s.input
    if ($s.op -eq "tool") { $res["s$i"] = Invoke-BKMemoryTool -Root $env:BK_ROOT -ClientId $s.client -ToolInput $in }
    elseif ($s.op -eq "block") { $res["s$i"] = Get-BKMemoryBlock -Root $env:BK_ROOT -ClientId $s.client }
    elseif ($s.op -eq "turn") { Add-BKConversationTurn -Root $env:BK_ROOT -ClientId $s.client -WorkerId $s.worker -TaskId ([string]$s.taskId) -Request ([string]$s.request) -Answer ([string]$s.answer) }
}
$res | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:OUT_FILE -Encoding utf8
'''


def run_steps(root, steps):
    d = os.path.join(root, "core", "ai", "adapters")
    os.makedirs(d, exist_ok=True)
    for n in ("Get-RecentConversation.ps1", "Client-Memory.ps1"):
        shutil.copy2(os.path.join(REPO, "core", "ai", "adapters", n), os.path.join(d, n))
    sf, out, drv = (os.path.join(root, n) for n in ("steps.json", "out.json", "driver.ps1"))
    with open(sf, "w", encoding="utf-8") as f:
        json.dump(steps, f)
    with open(drv, "w", encoding="utf-8") as f:
        f.write(DRIVER)
    p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", drv], capture_output=True, text=True, encoding="utf-8",
                       errors="replace", env=dict(os.environ, BK_ROOT=root, STEPS_FILE=sf, OUT_FILE=out), timeout=240)
    assert os.path.isfile(out), p.stdout + p.stderr
    with open(out, encoding="utf-8-sig") as f:
        return json.load(f)


def tool(client, **inp):
    return {"op": "tool", "client": client, "input": inp}


def note(client, name, content, type_="client", desc="d"):
    return tool(client, action="write", name=name, type=type_, description=desc, content=content)


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class ClientMemory(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="bkcmem-")
        self.addCleanup(shutil.rmtree, self.root, True)

    def notes_dir(self, client="CLI-A"):
        return os.path.join(self.root, "runtime", "client-memory", client)

    def test_write_search_read_delete_roundtrip_and_index(self):
        r = run_steps(self.root, [
            note("CLI-A", "Ton de marque", "Toujours vouvoyer. Pas d'emojis. Signature : L'equipe Favre.", "preference", "Ton et signature"),
            tool("CLI-A", action="search", query="vouvoyer emojis"),
            tool("CLI-A", action="read", id="ton-de-marque"),
            {"op": "block", "client": "CLI-A"},
            tool("CLI-A", action="delete", name="ton-de-marque"),
            {"op": "block", "client": "CLI-A"},
        ])
        self.assertIn("Note enregistree : ton-de-marque", r["s1"])
        self.assertIn("note ton-de-marque", r["s2"])
        self.assertIn("Toujours vouvoyer", r["s3"])
        self.assertIn("<client_memory>", r["s4"])
        self.assertIn("[ton-de-marque](ton-de-marque.md) (preference) - Ton et signature", r["s4"])
        self.assertIn("Note supprimee", r["s5"])
        self.assertIn("(no notes yet)", r["s6"])
        self.assertFalse(os.path.exists(os.path.join(self.notes_dir(), "ton-de-marque.md")))

    def test_secrets_are_refused_and_nothing_is_written(self):
        r = run_steps(self.root, [
            note("CLI-A", "acces", "Le mot de passe : Sup3rSecret!42 pour le CRM"),
            note("CLI-A", "cle", "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
            note("CLI-A", "carte", "Carte 4111 1111 1111 1111 expire 12/28"),
        ])
        for k in ("s1", "s2", "s3"):
            self.assertIn("refuse", r[k])
        self.assertFalse(os.path.isdir(self.notes_dir()) and any(f.endswith(".md") and f != "MEMORY.md" for f in os.listdir(self.notes_dir())))

    def test_caps_names_and_types(self):
        r = run_steps(self.root, [note("CLI-A", f"note {i}", f"contenu {i}") for i in range(8)])
        self.assertEqual(sum(1 for i in range(1, 9) if r[f"s{i}"].startswith("Note enregistree")), 6)   # 6 ecritures max par mission
        self.assertIn("6 notes maximum", r["s7"])
        self.assertEqual(len([f for f in os.listdir(self.notes_dir()) if f != "MEMORY.md"]), 6)

    def test_long_note_type_and_traversal_are_rejected(self):
        r = run_steps(self.root, [note("CLI-A", "x", "a" * 4001),
                                  tool("CLI-A", action="write", name="t", type="nimportequoi", description="d", content="c"),
                                  tool("CLI-A", action="write", name="../../etc/passwd", type="client", description="d", content="ok")])
        self.assertIn("trop longue", r["s1"])
        self.assertIn("type invalide", r["s2"])
        self.assertIn("Note enregistree : etc-passwd", r["s3"])                                          # nom assaini : reste dans le dossier du client
        self.assertTrue(os.path.isfile(os.path.join(self.notes_dir(), "etc-passwd.md")))

    def test_each_client_only_sees_their_own_memory(self):
        r = run_steps(self.root, [note("CLI-A", "secret-a", "Le projet Aurore est confidentiel."),
                                  tool("CLI-B", action="search", query="Aurore confidentiel"),
                                  tool("CLI-B", action="read", id="secret-a"),
                                  {"op": "block", "client": "CLI-B"}])
        self.assertIn("Aucun resultat", r["s2"])
        self.assertIn("note introuvable", r["s3"])
        self.assertNotIn("Aurore", r["s4"])

    def test_the_trial_client_has_no_memory(self):
        r = run_steps(self.root, [note("CLI-TRIAL-PUBLIC", "x", "y"), {"op": "block", "client": "CLI-TRIAL-PUBLIC"}])
        self.assertIn("pas disponible", r["s1"])
        self.assertEqual(r["s2"], "")
        self.assertFalse(os.path.exists(os.path.join(self.root, "runtime", "client-memory", "CLI-TRIAL-PUBLIC")))

    def test_search_covers_the_whole_mission_archive_and_read_opens_a_mission(self):
        steps = [{"op": "turn", "client": "CLI-A", "worker": "dario", "taskId": f"TASK-{i:032d}".replace("TASK-", "TASK-").upper().replace("0", "A")[:37],
                  "request": f"demande {i}", "answer": f"reponse {i}"} for i in range(1, 4)]
        steps[1]["request"] = "Peux-tu preparer la facture du client Müller (échéance fin novembre) ?"
        steps[1]["answer"] = "Facture preparee pour Müller, echeance 30 novembre, TVA 8.1%."
        steps[1]["taskId"] = "TASK-" + "C" * 32
        steps += [tool("CLI-A", action="search", query="facture muller echeance"), tool("CLI-A", action="read", id="TASK-" + "C" * 32)]
        r = run_steps(self.root, steps)
        self.assertIn("mission TASK-" + "C" * 32, r["s4"])
        self.assertIn("echeance 30 novembre", r["s5"])                                                   # relu en entier

    def test_a_big_thread_is_archived_not_truncated_and_stays_searchable(self):
        thread_dir = os.path.join(self.root, "runtime", "threads", "CLI-A")
        os.makedirs(thread_dir)
        old = {"ts": "2026-01-02T10:00:00Z", "taskId": "TASK-" + "D" * 32, "request": "ancienne demande unique zeppelin", "answer": "reponse " + "x" * 800, "files": [], "actions": []}
        with open(os.path.join(thread_dir, "DARIO.jsonl"), "w", encoding="utf-8") as f:
            for _ in range(2300):                                   # > 2 Mo
                f.write(json.dumps(old) + "\n")
        r = run_steps(self.root, [{"op": "turn", "client": "CLI-A", "worker": "dario", "taskId": "TASK-" + "E" * 32, "request": "nouvelle", "answer": "ok"},
                                  tool("CLI-A", action="search", query="zeppelin")])
        names = os.listdir(thread_dir)
        self.assertTrue(any(".archive-" in n for n in names), names)                                      # archive conservee
        self.assertLess(os.path.getsize(os.path.join(thread_dir, "DARIO.jsonl")), 200_000)                # fil actif de nouveau petit
        self.assertIn("zeppelin", r["s2"])                                                               # rien n'est perdu


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class AdapterMemoryAndLevels(unittest.TestCase):
    def run_case(self, cassette, **kw):
        import test_adapter_review as t
        r = t.Run(cassette, **kw)
        self.addCleanup(r.cleanup)
        return t, r

    def test_the_model_can_write_a_note_and_the_next_mission_starts_with_it(self):
        import test_adapter_review as t
        mem_call = {"type": "tool_use", "id": "toolu_m", "name": "memory",
                    "input": {"action": "write", "name": "ton de marque", "type": "preference", "description": "tutoiement", "content": "Le client veut etre tutoye."}}
        r = t.Run([t.msg([mem_call], "tool_use"), t.msg([t.text_block("C'est note, je te tutoierai.")])], activated=("gmail",), auto_approve=False)
        self.addCleanup(r.cleanup)
        self.assertEqual(r.exit, 0, r.proc.stderr)
        calls = r.of_kind("messages")
        self.assertTrue(any(c.endswith(":memory") for c in calls[0]["toolTypes"]), calls[0]["toolTypes"])
        note_path = os.path.join(r.root, "runtime", "client-memory", t.CLIENT, "ton-de-marque.md")
        self.assertTrue(os.path.isfile(note_path))
        r.rerun([t.msg([t.text_block("Salut !")])], task="TASK-" + "B" * 32)
        again = r.of_kind("messages")[0]
        self.assertTrue(again["systemHasMemory"])
        self.assertIn("ton-de-marque", again["systemText"])
        self.assertIn("DATA written earlier", again["systemText"])                                       # relu comme donnee, pas comme instruction

    def test_levels_set_model_effort_and_web_budget(self):
        import test_adapter_review as t
        for level, model, effort, web in (("rapide", "claude-haiku-5-5", "low", 3), ("equilibre", "claude-sonnet-5-5", "medium", 8), ("approfondi", "claude-opus-5-5", "high", 15)):
            r = t.Run([t.msg([t.text_block("ok")])], activated=("gmail",), auto_approve=False, env={"BK_MISSION_LEVEL": level})
            self.addCleanup(r.cleanup)
            self.assertEqual(r.exit, 0, (level, r.proc.stderr))
            c = r.of_kind("messages")[0]
            self.assertEqual((c["model"], c["effort"], c["webMaxUses"]), (model, effort, web), level)

    def test_without_a_level_the_old_behaviour_is_unchanged(self):
        import test_adapter_review as t
        r = t.Run([t.msg([t.text_block("ok")])], activated=("gmail",), auto_approve=False)
        self.addCleanup(r.cleanup)
        c = r.of_kind("messages")[0]
        self.assertEqual((c["model"], c["effort"], c["webMaxUses"]), ("claude-sonnet-5-5", "", 5))        # modele du parametre, pas d'effort, 5 recherches

    def test_pause_turn_is_continued_and_a_truncated_loop_says_so(self):
        import test_adapter_review as t
        paused = {"body": {"id": "m", "type": "message", "role": "assistant", "model": "claude-sonnet-5-5", "stop_reason": "pause_turn",
                           "content": [t.text_block("Recherche en cours...")], "usage": t.usage()}}
        r = t.Run([paused, t.msg([t.text_block("Voici le resultat final.")])], activated=("gmail",), auto_approve=False)
        self.addCleanup(r.cleanup)
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(len(r.of_kind("messages")), 2)                                                  # reprise du tour en pause
        self.assertIn("resultat final", r.result["answer"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
