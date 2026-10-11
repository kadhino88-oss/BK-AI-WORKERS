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


class AsyncMissions(unittest.TestCase):
    def setUp(self):
        self.gate = threading.Event()
        self.started = []

        def fake_submit(objective, worker_id="", plan_only=False, client_id=""):
            self.started.append(client_id)
            self.gate.wait(10)
            return {"Status": "SUCCESS", "Result": {"Answer": "ok"}}

        self._orig = server.submit_task
        server.submit_task = fake_submit
        server.attach_pending_action = lambda r: r
        server._ASYNC_ACTIVE.clear()

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
        a = server.submit_task_async("x", "chloe", "CLI-A")
        b = server.submit_task_async("x", "chloe", "CLI-A")
        c = server.submit_task_async("x", "chloe", "CLI-A")
        self.assertIn("jobId", a)
        self.assertIn("jobId", b)
        self.assertEqual(c["error"], "TOO_MANY_RUNNING_MISSIONS")
        self.assertIn("mission", c["detail"])
        self.gate.set()
        self.wait_done(a["jobId"]); self.wait_done(b["jobId"])
        time.sleep(0.2)
        d = server.submit_task_async("x", "chloe", "CLI-A")        # la place est revenue
        self.assertIn("jobId", d)

    def test_global_cap_across_clients(self):
        ids = [server.submit_task_async("x", "chloe", f"CLI-{i}") for i in range(3)]
        self.assertTrue(all("jobId" in r for r in ids))
        over = server.submit_task_async("x", "chloe", "CLI-OTHER")
        self.assertEqual(over["error"], "TOO_MANY_RUNNING_MISSIONS")

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


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2, exit=False)
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
