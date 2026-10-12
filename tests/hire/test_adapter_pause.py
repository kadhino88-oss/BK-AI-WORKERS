"""Interrupteur d'arret : quand le client met l'installation d'un Worker en PAUSE, ce Worker n'agit plus seul — meme un vrai brouillon,
qu'« Laisser mes Workers agir seuls » executait sans attendre, attend alors la confirmation du client. Les missions lancees a la main
fonctionnent toujours (lectures executees, propositions mises en attente). Utilise le banc d'essai de tests/adapter-review (API simulee).

PowerShell 7 requis.   python tests/hire/test_adapter_pause.py
"""
import json
import os
import shutil
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tests", "adapter-review"))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import installations as inst  # noqa: E402
import test_adapter_review as ar  # noqa: E402

DRAFT = [ar.msg([ar.tool_use(1, "gmail", "DRAFT_MESSAGE", {"To": "a@b.ch", "Subject": "s", "Body": "b"}),
                 ar.tool_use(2, "gmail", "READ_MESSAGE", {"Id": "1"})], "tool_use"), ar.msg([ar.text_block("fait")])]


@unittest.skipUnless(ar.PWSH, "pwsh (PowerShell 7) not installed")
class PauseStopsAutonomy(unittest.TestCase):
    def setUp(self):
        self.run_ = ar.Run([ar.msg([ar.text_block("rien")])])
        self.addCleanup(self.run_.cleanup)
        os.makedirs(os.path.join(self.run_.root, "workers", "noah"), exist_ok=True)
        shutil.copy2(os.path.join(REPO, "workers", "noah", "install-profile.json"), os.path.join(self.run_.root, "workers", "noah", "install-profile.json"))
        self.store = inst.InstallationStore(self.run_.root)
        self.n = 0

    def mission(self):
        self.n += 1
        self.run_.rerun(DRAFT, task="TASK-" + format(self.n, "X").rjust(32, "B"))
        self.assertEqual(self.run_.exit, 0, self.run_.proc.stderr)
        return {a["connectorId"] + "|" + a["operation"]: a for a in self.run_.result["connector_actions"]}

    def test_pause_stops_the_automatic_drafts_and_resume_brings_them_back(self):
        by = self.mission()                                           # aucune installation : comportement habituel
        self.assertTrue(by["gmail|DRAFT_MESSAGE"]["executed"] and by["gmail|DRAFT_MESSAGE"]["autoApproved"])
        self.store.upsert(ar.CLIENT, "noah", {"services": {}})
        by = self.mission()                                           # installation en essai : rien ne change
        self.assertTrue(by["gmail|DRAFT_MESSAGE"]["autoApproved"])
        self.store.set_status(ar.CLIENT, "noah", "paused")
        by = self.mission()
        self.assertFalse(by["gmail|DRAFT_MESSAGE"]["executed"], "en pause, le brouillon attend la confirmation du client")
        self.assertEqual(by["gmail|DRAFT_MESSAGE"]["status"], "PENDING_CONFIRMATION")
        self.assertFalse(by["gmail|DRAFT_MESSAGE"].get("autoApproved"))
        self.assertTrue(by["gmail|READ_MESSAGE"]["executed"], "la mission manuelle fonctionne : les lectures restent executees")
        self.store.set_status(ar.CLIENT, "noah", "draft")
        self.assertTrue(self.mission()["gmail|DRAFT_MESSAGE"]["autoApproved"])

    def test_the_pause_of_another_worker_or_client_changes_nothing(self):
        self.store.upsert(ar.CLIENT, "nora", {"services": {}})
        self.store.set_status(ar.CLIENT, "nora", "paused")
        self.store.upsert("CLI-AUTRE-CLIENT", "noah", {"services": {}})
        self.store.set_status("CLI-AUTRE-CLIENT", "noah", "paused")
        self.assertTrue(self.mission()["gmail|DRAFT_MESSAGE"]["autoApproved"])

    def test_an_unreadable_record_means_no_autonomy(self):
        self.store.upsert(ar.CLIENT, "noah", {"services": {}})
        path = os.path.join(self.run_.root, "runtime", "installations", ar.CLIENT, "NOAH.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write("{ pas du json")
        self.assertFalse(self.mission()["gmail|DRAFT_MESSAGE"].get("autoApproved"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
