"""Garde-fou statique du flux de mission en direct (dashboard/app.js) : voir le correctif 2026-10-12.

Bug corrige : a la fin d'une mission Worker, loadActivity() reconstruisait TOUT le fil (task-result.innerHTML = ""), puis runTask
accrochait les fichiers et la carte de validation au tour qu'il venait de creer, desormais detache de la page => la carte
"Confirmer / Annuler" d'une action preparee par le Worker n'apparaissait jamais (et le fichier non plus avant l'ajout de `files`
a l'historique). Le comportement reel est verifie dans le navigateur ; ce test empeche seulement de reintroduire le motif.
Lancer : python tests/file-preview/test_live_flow_static.py
"""
import os
import re
import sys
import unittest

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "dashboard", "app.js")
SRC = open(APP, encoding="utf-8").read()


def body_of(name):
    m = re.search(r"(?:async )?function %s\b" % name, SRC)
    assert m, name
    depth, i = 0, re.compile(r"\)\s*\{").search(SRC, m.end()).end() - 1      # accolade du corps (pas celle d'un parametre par defaut)
    start = i
    while True:
        c = SRC[i]
        depth += c == "{"
        depth -= c == "}"
        i += 1
        if depth == 0:
            return SRC[start:i]


class LiveFlow(unittest.TestCase):
    def test_run_task_keeps_the_live_turn_attached(self):
        run_task = body_of("runTask")
        for m in re.finditer(r"loadActivity\(([^)]*)\)", run_task):
            self.assertIn("keepThread", m.group(1), "runTask ne doit pas reconstruire le fil : le tour en direct serait detache")

    def test_files_and_card_are_attached_after_the_activity_refresh(self):
        run_task = body_of("runTask")
        self.assertLess(run_task.index("loadActivity("), run_task.index("renderTaskFilesBlock("))
        self.assertLess(run_task.index("loadActivity("), run_task.index("renderPendingActionCard("))

    def test_keep_thread_skips_the_thread_rebuild(self):
        load = body_of("loadActivity")
        self.assertIn("opts.keepThread", load)
        self.assertLess(load.index("opts.keepThread"), load.index('threadEl.innerHTML = ""'))

    def test_replay_restores_the_pending_action_card(self):
        self.assertIn("if (a.pendingAction) turn.appendChild(renderPendingActionCard(a.pendingAction))", body_of("loadActivity"))


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=1).result
    sys.exit(0 if result.wasSuccessful() else 1)
