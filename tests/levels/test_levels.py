"""Niveaux de travail cote serveur : validation du niveau, cout en credits, quota par niveau, memoire du client (liste/suppression).

python tests/levels/test_levels.py   (Windows ou Linux, sans PowerShell ni reseau)
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
TMP = tempfile.mkdtemp(prefix="bklevels-")
os.makedirs(os.path.join(TMP, "core", "ai"))
shutil.copy2(os.path.join(REPO, "core", "ai", "LEVELS.json"), os.path.join(TMP, "core", "ai", "LEVELS.json"))
os.environ["BK_ROOT"] = TMP
spec = importlib.util.spec_from_file_location("bk_server_levels", os.path.join(REPO, "dashboard", "server.py"))
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
server.MISSION_LEVELS_PATH = os.path.join(TMP, "core", "ai", "LEVELS.json")
server.TASKS_DIR = os.path.join(TMP, "runtime", "tasks")
server.CLIENT_MEMORY_DIR = os.path.join(TMP, "runtime", "client-memory")


class Levels(unittest.TestCase):
    def tearDown(self):
        os.environ.pop("BK_LEVELS", None)

    def test_unknown_or_missing_level_falls_back_to_the_default(self):
        for v in (None, "", "nimportequoi", "EQUILIBRE ", "../../etc"):
            self.assertEqual(server.normalize_level(v, "CLI-X"), "equilibre", v)
        self.assertEqual(server.normalize_level("approfondi", "CLI-X"), "approfondi")
        self.assertEqual(server.normalize_level("RAPIDE", "CLI-X"), "rapide")

    def test_the_anonymous_trial_is_always_on_the_cheapest_level(self):
        self.assertEqual(server.normalize_level("approfondi", "CLI-TRIAL-PUBLIC"), "rapide")

    def test_levels_can_be_switched_off_on_the_server(self):
        os.environ["BK_LEVELS"] = "0"
        self.assertEqual(server.normalize_level("approfondi", "CLI-X"), "")
        self.assertEqual(server.public_mission_levels(), {"levels": [], "default": ""})

    def test_credits_follow_the_level_and_the_public_list_matches(self):
        self.assertEqual([server.level_credits(l) for l in ("rapide", "equilibre", "approfondi")], [1, 3, 8])
        pub = server.public_mission_levels()
        self.assertEqual([l["id"] for l in pub["levels"]], ["rapide", "equilibre", "approfondi"])
        self.assertEqual(pub["default"], "equilibre")
        self.assertTrue(all(l["label"] and l["description"] for l in pub["levels"]))

    def test_billing_counts_the_credits_of_each_mission(self):
        os.makedirs(server.TASKS_DIR, exist_ok=True)
        rows = [("A" * 32, "CLI-B", 3), ("B" * 32, "CLI-B", 8), ("C" * 32, "CLI-B", None), ("D" * 32, "CLI-CUST-0000000B", 8)]
        for tid, client, credits in rows:
            rec = {"TaskId": f"TASK-{tid}", "ClientId": client, "CreatedAtUtc": "2999-01-01T00:00:00Z"}
            if credits is not None:
                rec["Credits"] = credits
            with open(os.path.join(server.TASKS_DIR, f"TASK-{tid}.json"), "w", encoding="utf-8") as f:
                json.dump(rec, f)
        orig = server._billing_load
        server._billing_load = lambda cid=None: {"planId": "starter", "cycleStartUtc": "2000-01-01T00:00:00Z", "extraCredits": 0}
        try:
            b = server.get_billing("CLI-B")
        finally:
            server._billing_load = orig
        self.assertEqual(b["creditsUsed"], 3 + 8 + 1)             # un ancien enregistrement sans niveau = 1 credit
        self.assertEqual(b["creditsRemaining"], 150 - 12)
        self.assertIn("missionLevels", b)

    def test_the_quota_says_which_level_still_fits(self):
        def fake_billing(remaining):
            return lambda cid=None: {"unlimited": False, "creditsRemaining": remaining}
        orig = server.get_billing
        try:
            server.get_billing = fake_billing(2)
            self.assertIsNone(server.subscription_blocks_mission("CLI-C", "rapide"))               # 1 credit : ok
            msg = server.subscription_blocks_mission("CLI-C", "approfondi")                        # 8 credits : refuse
            self.assertIn("Il vous reste 2 crédit", msg)
            self.assertIn("niveau plus rapide", msg)
            server.get_billing = fake_billing(0)
            self.assertIn("quota est épuisé", server.subscription_blocks_mission("CLI-C", "rapide"))
            server.get_billing = fake_billing(10)
            self.assertIsNone(server.subscription_blocks_mission("CLI-C", "approfondi"))
            self.assertIsNone(server.subscription_blocks_mission("CLI-C"))                         # sans niveau : niveau par defaut (3)
        finally:
            server.get_billing = orig


class ClientMemoryApi(unittest.TestCase):
    def setUp(self):
        d = os.path.join(server.CLIENT_MEMORY_DIR, "CLI-CUST-0000000A")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "ton-de-marque.md"), "w", encoding="utf-8") as f:
            f.write("---\nname: ton-de-marque\ntype: preference\ndescription: Ton et signature\nsource: client\nupdated: 2026-10-12T10:00:00Z\n---\nToujours vouvoyer.\n")
        with open(os.path.join(d, "MEMORY.md"), "w", encoding="utf-8") as f:
            f.write("- [ton-de-marque](ton-de-marque.md) (preference) - Ton et signature\n- [autre](autre.md) (client) - Autre\n")

    def test_the_client_can_list_and_delete_their_notes_only(self):
        notes = server.list_client_memory("CLI-CUST-0000000A")
        self.assertEqual([n["name"] for n in notes], ["ton-de-marque"])
        self.assertEqual((notes[0]["type"], notes[0]["description"], notes[0]["content"]), ("preference", "Ton et signature", "Toujours vouvoyer."))
        self.assertEqual(server.list_client_memory("CLI-CUST-0000000B"), [])
        self.assertFalse(server.delete_client_memory_note("CLI-CUST-0000000B", "ton-de-marque"))            # un autre client ne supprime rien
        for bad in ("../ton-de-marque", "ton-de-marque.md", "TON", "", "a/b"):
            self.assertFalse(server.delete_client_memory_note("CLI-CUST-0000000A", bad), bad)
        self.assertTrue(server.delete_client_memory_note("CLI-CUST-0000000A", "ton-de-marque"))
        self.assertEqual(server.list_client_memory("CLI-CUST-0000000A"), [])
        idx = open(os.path.join(server.CLIENT_MEMORY_DIR, "CLI-CUST-0000000A", "MEMORY.md"), encoding="utf-8").read()
        self.assertNotIn("ton-de-marque", idx)                                                      # l'index ne montre plus la note supprimee
        self.assertIn("[autre]", idx)


if __name__ == "__main__":
    ok = False
    try:
        ok = unittest.main(verbosity=2, exit=False).result.wasSuccessful()
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
    sys.exit(0 if ok else 1)
