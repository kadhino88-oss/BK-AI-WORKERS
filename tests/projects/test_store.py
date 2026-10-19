# -*- coding: utf-8 -*-
"""Magasin des projets : machine à états, écritures atomiques sous concurrence, journal d'événements, verrou de processus.

Lancer : python tests/projects/test_store.py
"""
import itertools
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import projects_store as ps  # noqa: E402

CLIENT = "CLI-CUST-1A2B3C4D"
OTHER = "CLI-CUST-AAAAAAAA"


T0 = 1_800_000_000.0


def make_state(pid=None, client=CLIENT, status="PLANNING"):
    pid = pid or ps.new_project_id()
    return {"schema": "BK-PROJECT-STATE-V1", "projectId": pid, "clientId": client, "title": "Test", "goal": "g", "status": status,
            "createdUtc": ps.iso(T0), "statusSinceUtc": ps.iso(T0), "seq": 0, "steps": {}, "counter": 0}


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="bkproj-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.clock = [T0]
        self.store = ps.ProjectStore(self.root, now=lambda: self.clock[0])

    def new(self, status="PLANNING", client=CLIENT):
        st = make_state(status=status, client=client)
        self.store.create(client, st)
        return st["projectId"]

    # ---- machine à états
    def test_every_pair_matches_the_table(self):
        for old, new in itertools.product(ps.STATUSES, ps.STATUSES):
            pid = self.new(status=old)
            with self.subTest(old=old, new=new):
                allowed = new == old or new in ps.TRANSITIONS[old]
                try:
                    with self.store.txn(pid) as t:
                        t.transition(new, "TEST")
                    ok = True
                except ps.InvalidTransition as e:
                    ok = False
                    self.assertEqual((e.old, e.new), (old, new))
                self.assertEqual(ok, allowed)
                self.assertEqual(self.store.state(pid)["status"], new if allowed else old)

    def test_terminal_done_and_cancelled_never_leave(self):
        for terminal in ("DONE", "CANCELLED"):
            self.assertEqual(ps.TRANSITIONS[terminal], frozenset())

    def test_transition_bumps_seq_writes_event_and_dates(self):
        pid = self.new()
        self.clock[0] += 60
        with self.store.txn(pid) as t:
            t.transition("RUNNING", "GO")
        st = self.store.state(pid)
        self.assertEqual(st["status"], "RUNNING")
        self.assertEqual(st["seq"], 1)
        self.assertEqual(st["previousStatus"], "PLANNING")
        self.assertTrue(st["startedUtc"])
        self.assertAlmostEqual(st["activeSeconds"], 60, delta=1)
        evs = self.store.read_jsonl(pid, "events.jsonl")
        self.assertEqual([e["seq"] for e in evs], [1])
        self.assertEqual(evs[0]["type"], "status_changed")
        self.assertEqual(evs[0]["data"]["to"], "RUNNING")
        with self.store.txn(pid) as t:
            t.transition("DONE", "FIN")
        self.assertTrue(self.store.state(pid)["finishedUtc"])

    def test_waiting_time_does_not_count_as_active(self):
        pid = self.new(status="RUNNING")
        self.clock[0] += 100
        with self.store.txn(pid) as t:
            t.transition("WAITING_QUOTA", "SESSION", waitingFor="QUOTA", resumeAtUtc="2026-10-20T12:00:00Z")
        self.clock[0] += 10_000
        with self.store.txn(pid) as t:
            t.transition("RUNNING", "RESUME")
        st = self.store.state(pid)
        self.assertAlmostEqual(st["activeSeconds"], 100, delta=1)
        self.assertIsNone(st["resumeAtUtc"])
        self.assertIsNone(st["waitingFor"])

    def test_exception_in_block_writes_nothing(self):
        pid = self.new()
        try:
            with self.store.txn(pid) as t:
                t.state["counter"] = 99
                t.event("step_started", "x")
                raise ValueError("boom")
        except ValueError:
            pass
        self.assertEqual(self.store.state(pid)["counter"], 0)
        self.assertEqual(self.store.read_jsonl(pid, "events.jsonl"), [])

    def test_nested_transaction_is_refused(self):
        pid = self.new()
        with self.store.txn(pid):
            with self.assertRaises(RuntimeError):
                with self.store.txn(pid):
                    pass

    def test_hooks_run_after_commit_and_never_break_it(self):
        pid = self.new()
        seen = []
        self.store.hooks.append(lambda store, p, st, evs, trs: seen.append((st["status"], [e["type"] for e in evs], trs)))
        self.store.hooks.append(lambda *a: 1 / 0)
        with self.store.txn(pid) as t:
            t.transition("RUNNING", "GO")
        self.assertEqual(seen[0][0], "RUNNING")
        self.assertEqual(seen[0][1], ["status_changed"])
        self.assertEqual(seen[0][2], [("PLANNING", "RUNNING", "GO")])

    # ---- concurrence
    def test_concurrent_transactions_lose_no_update_and_file_is_always_valid(self):
        pid = self.new(status="RUNNING")
        path = os.path.join(self.store.project_dir(pid), "state.json")
        stop = threading.Event()
        bad = []

        def reader():
            while not stop.is_set():
                try:
                    with open(path, encoding="utf-8") as f:
                        json.load(f)
                except FileNotFoundError:
                    pass
                except ValueError as e:
                    bad.append(str(e))
                except PermissionError:
                    pass          # Windows : lecture pile pendant le remplacement
                time.sleep(0.003)

        def worker():
            for _ in range(40):
                with self.store.txn(pid) as t:
                    t.state["counter"] += 1
                    t.event("step_cost", "+1")

        readers = [threading.Thread(target=reader) for _ in range(3)]
        for r in readers:
            r.start()
        writers = [threading.Thread(target=worker) for _ in range(6)]
        for w in writers:
            w.start()
        for w in writers:
            w.join()
        stop.set()
        for r in readers:
            r.join()
        st = self.store.state(pid)
        self.assertEqual(st["counter"], 240)
        self.assertEqual(st["seq"], 240)
        self.assertEqual([e["seq"] for e in self.store.read_jsonl(pid, "events.jsonl")], list(range(1, 241)))
        self.assertEqual(bad, [])

    def test_jsonl_append_is_whole_lines_under_concurrency_and_bad_line_is_ignored(self):
        pid = self.new()

        def w(n):
            for i in range(30):
                self.store.append_jsonl(pid, "inbox.jsonl", {"n": n, "i": i, "pad": "é" * 50})

        ts = [threading.Thread(target=w, args=(n,)) for n in range(5)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        with open(os.path.join(self.store.project_dir(pid), "inbox.jsonl"), "a", encoding="utf-8") as f:
            f.write('{"torn": tru')          # ligne coupée par un redémarrage
        rows = self.store.read_jsonl(pid, "inbox.jsonl")
        self.assertEqual(len(rows), 150)

    # ---- événements
    def test_events_since_and_reset(self):
        pid = self.new(status="RUNNING")
        with self.store.txn(pid) as t:
            for i in range(700):
                t.event("step_cost", f"e{i}")
        evs, more, reset = self.store.events_since(pid, 0, limit=100)
        self.assertEqual(len(evs), 100)
        self.assertTrue(more)
        self.assertEqual(evs[0]["seq"], 201)          # seulement les 500 derniers sont conservés pour le suivi
        evs, more, reset = self.store.events_since(pid, 650, limit=100)
        self.assertEqual([e["seq"] for e in evs][:2], [651, 652])
        self.assertFalse(reset)
        evs, more, reset = self.store.events_since(pid, 10, limit=100)
        self.assertTrue(reset)

    def test_recover_seq_after_crash_between_events_and_state(self):
        pid = self.new(status="RUNNING")
        with self.store.txn(pid) as t:
            t.event("step_started", "a")
        d = self.store.project_dir(pid)
        with open(os.path.join(d, "events.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"seq": 7, "ts": "2026-10-20T08:00:00Z", "type": "step_cost", "text": "x"}) + "\n")
        self.store.recover_seq(pid)
        self.assertEqual(self.store.state(pid)["seq"], 7)

    # ---- identifiants, isolation
    def test_ids_are_validated_and_confined(self):
        for bad in ("../x", "PRJ-" + "a" * 32, "PRJ-" + "A" * 31, "PRJ-" + "A" * 32 + "/..", "", None, "PRJ-" + "G" * 32):
            with self.assertRaises(ps.ProjectNotFound):
                self.store.dir_for(CLIENT, bad)
        for bad in ("CLI-CUST-1", "../CLI", "CLI-CUST-1A2B3C4DX", "cli-cust-1a2b3c4d"):
            with self.assertRaises(ps.ProjectError):
                self.store.client_dir(bad)
        self.assertTrue(ps.CLIENT_ID_RE.match("CLI-DASHBOARD"))

    def test_client_of_isolation_and_index_rebuild(self):
        a = self.new(client=CLIENT)
        b = self.new(client=OTHER)
        self.assertEqual(self.store.client_of(a), CLIENT)
        self.assertEqual(self.store.client_of(b), OTHER)
        self.assertEqual(self.store.ids_of_client(CLIENT), [a])
        fresh = ps.ProjectStore(self.root)
        fresh.refresh_index()
        self.assertEqual(fresh.client_of(b), OTHER)
        self.assertIsNone(fresh.client_of("PRJ-" + "B" * 32))

    # ---- verrou de processus
    def test_lock_conflict_when_another_live_process_wrote_the_lock(self):
        pid = self.new()
        d = self.store.project_dir(pid)
        other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            with open(os.path.join(d, ".lock"), "w", encoding="utf-8") as f:
                json.dump({"pid": other.pid, "bootUtc": "2020-01-01T00:00:00Z"}, f)
            fresh = ps.ProjectStore(self.root)
            fresh.refresh_index()
            with self.assertRaises(ps.LockConflict):
                with fresh.txn(pid) as t:
                    t.state["counter"] = 5
            self.assertEqual(fresh.state(pid)["counter"], 0)
        finally:
            other.kill()
            other.wait()

    def test_stale_lock_of_a_dead_process_is_taken_over(self):
        pid = self.new()
        d = self.store.project_dir(pid)
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait()
        with open(os.path.join(d, ".lock"), "w", encoding="utf-8") as f:
            json.dump({"pid": dead.pid, "bootUtc": "2020-01-01T00:00:00Z"}, f)
        fresh = ps.ProjectStore(self.root)
        fresh.refresh_index()
        with fresh.txn(pid) as t:
            t.state["counter"] = 5
        self.assertEqual(fresh.state(pid)["counter"], 5)

    def test_pid_alive(self):
        self.assertTrue(ps.pid_alive(os.getpid()))
        p = subprocess.Popen([sys.executable, "-c", "pass"])
        p.wait()
        self.assertFalse(ps.pid_alive(p.pid))
        self.assertFalse(ps.pid_alive(0))
        self.assertFalse(ps.pid_alive("x"))

    def test_delete_project_removes_directory_and_index(self):
        pid = self.new()
        d = self.store.project_dir(pid)
        self.store.delete_project(CLIENT, pid)
        self.assertFalse(os.path.exists(d))
        self.assertIsNone(self.store.client_of(pid))


if __name__ == "__main__":
    unittest.main(verbosity=2)
