"""Missions en arriere-plan : plafonds de simultaneite, liberation des places, nettoyage des jobs perimes.

Unitaire (Windows/Linux) : python tests/async-missions/test_async_missions.py
Utilise le vrai module dashboard/server.py avec submit_task remplace par un faux (aucun appel modele, aucun PowerShell).
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
TMP = tempfile.mkdtemp(prefix="bkasync-")
os.environ["BK_ROOT"] = TMP
os.environ["BK_ASYNC_MAX_PER_CLIENT"] = "2"
os.environ["BK_ASYNC_MAX_GLOBAL"] = "3"
spec = importlib.util.spec_from_file_location("bk_server", os.path.join(REPO, "dashboard", "server.py"))
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
server.ASYNC_JOBS_DIR = os.path.join(TMP, "runtime", "async-jobs")
server.TASK_FILES_DIR = os.path.join(TMP, "runtime", "task-files")
server.PENDING_ACTIONS_DIR = os.path.join(TMP, "memory", "runtime")


class AsyncMissions(unittest.TestCase):
    def setUp(self):
        self.gate = threading.Event()
        self.started = []

        def fake_submit(objective, worker_id="", plan_only=False, client_id="", level=None):
            self.started.append(client_id)
            self.gate.wait(10)
            return {"Status": "SUCCESS", "Result": {"Answer": "ok"}}

        self._orig = server.submit_task
        server.submit_task = fake_submit
        server.attach_pending_action = lambda r: r
        server._ASYNC_ACTIVE.clear()
        server._ASYNC_QUEUE.clear()

    def tearDown(self):
        self.gate.set()
        server.submit_task = self._orig
        time.sleep(0.3)

    def wait_done(self, job_id, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            job = server.read_async_job(job_id)
            if job and job["status"] != "RUNNING":
                return job
            time.sleep(0.05)
        self.fail("job not finished")

    def test_per_client_cap_then_release(self):
        # 2026-10-19 : un serveur occupe fait ATTENDRE la mission (file d'attente), il ne la refuse plus ; la file est bornee (voir tests/chloe-delegation)
        a = server.submit_task_async("x", "chloe", "CLI-A")
        b = server.submit_task_async("x", "chloe", "CLI-A")
        c = server.submit_task_async("x", "chloe", "CLI-A")
        self.assertIn("jobId", a)
        self.assertIn("jobId", b)
        self.assertEqual((a["status"], b["status"], c["status"]), ("RUNNING", "RUNNING", "QUEUED"))
        self.assertEqual(c["queuePosition"], 1)
        self.gate.set()
        self.wait_done(a["jobId"]); self.wait_done(b["jobId"]); self.wait_done(c["jobId"])
        time.sleep(0.2)
        d = server.submit_task_async("x", "chloe", "CLI-A")        # la place est revenue
        self.assertEqual(d["status"], "RUNNING")

    def test_global_cap_across_clients(self):
        ids = [server.submit_task_async("x", "chloe", f"CLI-{i}") for i in range(3)]
        self.assertTrue(all("jobId" in r for r in ids))
        over = server.submit_task_async("x", "chloe", "CLI-OTHER")
        self.assertEqual(over["status"], "QUEUED", "le serveur est plein : elle attend son tour")
        self.gate.set()
        self.wait_done(over["jobId"])

    def test_slot_released_when_mission_crashes(self):
        def boom(*a, **k):
            raise RuntimeError("provider down")
        server.submit_task = boom
        r = server.submit_task_async("x", "chloe", "CLI-B")
        job = self.wait_done(r["jobId"])
        self.assertEqual(job["status"], "ERROR")
        time.sleep(0.2)
        self.assertEqual(server._ASYNC_ACTIVE.get("CLI-B", 0), 0)

    def test_reaper_marks_stale_running_and_purges_old(self):
        os.makedirs(server.ASYNC_JOBS_DIR, exist_ok=True)
        stale = {"jobId": "JOB-" + "A" * 32, "status": "RUNNING", "clientId": "CLI-C"}
        old = {"jobId": "JOB-" + "B" * 32, "status": "DONE", "clientId": "CLI-C"}
        fresh = {"jobId": "JOB-" + "C" * 32, "status": "RUNNING", "clientId": "CLI-C"}
        for j in (stale, old, fresh):
            with open(server._async_job_path(j["jobId"]), "w", encoding="utf-8") as f:
                json.dump(j, f)
        now = time.time()
        os.utime(server._async_job_path(stale["jobId"]), (now - 3600, now - 3600))          # 1 h : perime
        os.utime(server._async_job_path(old["jobId"]), (now - 9 * 86400, now - 9 * 86400))  # 9 jours : a purger
        server.reap_async_jobs(now)
        self.assertEqual(server.read_async_job(stale["jobId"])["status"], "ERROR")
        self.assertIsNone(server.read_async_job(old["jobId"]))
        self.assertEqual(server.read_async_job(fresh["jobId"])["status"], "RUNNING")


    def test_boot_reaper_kills_even_fresh_running_jobs(self):
        os.makedirs(server.ASYNC_JOBS_DIR, exist_ok=True)
        job = {"jobId": "JOB-" + "D" * 32, "status": "RUNNING", "clientId": "CLI-D"}
        with open(server._async_job_path(job["jobId"]), "w", encoding="utf-8") as f:
            json.dump(job, f)
        server.reap_async_jobs(time.time(), boot=True)       # redemarrage : aucun thread de mission n'a survecu
        got = server.read_async_job(job["jobId"])
        self.assertEqual(got["status"], "ERROR")
        self.assertIn("interrompue", got["error"])

    def test_polling_never_shows_a_dead_job_as_running(self):
        os.makedirs(server.ASYNC_JOBS_DIR, exist_ok=True)
        job = {"jobId": "JOB-" + "E" * 32, "status": "RUNNING", "clientId": "CLI-E"}
        p = server._async_job_path(job["jobId"])
        with open(p, "w", encoding="utf-8") as f:
            json.dump(job, f)
        old = time.time() - (server.ASYNC_JOB_MAX_RUNNING_SECONDS + 60)
        os.utime(p, (old, old))
        self.assertEqual(server.read_async_job(job["jobId"])["status"], "ERROR")

    def test_synchronous_entry_points_share_the_same_caps(self):
        # 2 missions synchrones en cours pour CLI-F : la 3e (synchrone OU asynchrone) est refusee
        results = []
        threads = [threading.Thread(target=lambda: results.append(server.submit_task_limited("x", worker_id="chloe", client_id="CLI-F")))
                   for _ in range(2)]
        for th in threads:
            th.start()
        time.sleep(0.3)
        third = server.submit_task_limited("x", worker_id="chloe", client_id="CLI-F")
        self.assertEqual(third["error"], "TOO_MANY_RUNNING_MISSIONS")
        queued = server.submit_task_async("x", "chloe", "CLI-F")
        self.assertEqual(queued["status"], "QUEUED")      # la file d'attente n'existe que pour l'arriere-plan
        self.gate.set()
        for th in threads:
            th.join(5)
        self.assertEqual(len(results), 2)
        self.wait_done(queued["jobId"])                    # la mission en file part quand les missions synchrones rendent leur place
        time.sleep(0.2)
        self.assertEqual(server._ASYNC_ACTIVE.get("CLI-F", 0), 0)

    def test_account_deletion_removes_files_jobs_and_pending_actions(self):
        tid = "TASK-" + "A" * 32
        os.makedirs(os.path.join(server.TASK_FILES_DIR, tid), exist_ok=True)
        with open(os.path.join(server.TASK_FILES_DIR, tid, "bilan.xlsx"), "wb") as f:
            f.write(b"x")
        os.makedirs(server.PENDING_ACTIONS_DIR, exist_ok=True)
        with open(server._pending_action_path(tid), "w", encoding="utf-8") as f:
            f.write("{}")
        os.makedirs(server.ASYNC_JOBS_DIR, exist_ok=True)
        mine = {"jobId": "JOB-" + "F" * 32, "status": "DONE", "clientId": "CLI-G"}
        other = {"jobId": "JOB-" + "9" * 32, "status": "DONE", "clientId": "CLI-OTHER"}
        for j in (mine, other):
            with open(server._async_job_path(j["jobId"]), "w", encoding="utf-8") as f:
                json.dump(j, f)
        server._purge_client_mission_artifacts("CLI-G", [tid])
        self.assertFalse(os.path.exists(os.path.join(server.TASK_FILES_DIR, tid)))
        self.assertFalse(os.path.exists(server._pending_action_path(tid)))
        self.assertIsNone(server.read_async_job(mine["jobId"]))
        self.assertIsNotNone(server.read_async_job(other["jobId"]))     # les jobs d'un autre client ne sont pas touches

    def test_generated_files_are_kept_30_days_then_purged(self):
        old_dir = os.path.join(server.TASK_FILES_DIR, "TASK-" + "B" * 32)
        new_dir = os.path.join(server.TASK_FILES_DIR, "TASK-" + "C" * 32)
        for d in (old_dir, new_dir):
            os.makedirs(d, exist_ok=True)
        now = time.time()
        os.utime(old_dir, (now - 31 * 86400, now - 31 * 86400))
        self.assertEqual(server.purge_old_task_files(now), 1)
        self.assertFalse(os.path.exists(old_dir))
        self.assertTrue(os.path.exists(new_dir))


if __name__ == "__main__":
    ok = False
    try:
        ok = unittest.main(verbosity=2, exit=False).result.wasSuccessful()
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
    sys.exit(0 if ok else 1)
