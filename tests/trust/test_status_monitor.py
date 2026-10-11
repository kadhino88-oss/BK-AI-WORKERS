# -*- coding: utf-8 -*-
"""Tests unitaires de dashboard/status_monitor.py (mesure de disponibilite, journal d'incidents).
Lancer : python tests/trust/test_status_monitor.py
Aucune horloge reelle, aucun reseau (sauf la sonde TCP vers un port local ouvert par le test)."""
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import time
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import status_monitor as sm  # noqa: E402

def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


T0 = 1_790_000_000 - (1_790_000_000 % 86400) + 3600      # un jour UTC rond + 1 h (pas de passage de minuit proche)
OK = {"app": True, "data": True, "ai": True}


class RecorderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bkstatus-")
        self.rec = sm.StatusRecorder(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def feed(self, start, minutes, results=OK):
        for i in range(minutes):
            self.rec.record(results, ts=start + i * 60 + 5)

    def test_no_data_means_unknown_and_no_history(self):
        snap = self.rec.snapshot(T0)
        self.assertEqual(snap["status"], "unknown")
        self.assertEqual(snap["days"], [])
        self.assertIsNone(snap["uptimePercent"])
        self.assertIsNone(snap["sinceTs"])
        p = sm.public_payload(self.rec, sm.IncidentLog(os.path.join(self.tmp, "i.json")), now=T0)
        self.assertIsNone(p["measuredSinceUtc"])
        self.assertIsNone(p["uptime"]["percent"])
        self.assertEqual(p["days"], [])
        self.assertEqual(p["status"], "unknown")

    def test_all_up_is_100_percent_over_measured_period_only(self):
        self.feed(T0, 120)
        snap = self.rec.snapshot(T0 + 120 * 60)
        self.assertEqual(snap["status"], "operational")
        self.assertEqual(snap["uptimePercent"], 100.0)
        self.assertEqual(snap["expectedMinutes"], 120)            # et non 1440 : seule la periode mesuree compte
        self.assertEqual(len(snap["days"]), 1)
        self.assertTrue(snap["days"][0]["partial"])
        self.assertEqual(snap["sinceTs"], T0 + 5)

    def test_missing_minutes_count_as_unavailable(self):
        self.feed(T0, 60)
        self.feed(T0 + 90 * 60, 30)                                # 30 minutes de trou (serveur arrete)
        snap = self.rec.snapshot(T0 + 120 * 60)
        self.assertEqual(snap["expectedMinutes"], 120)
        self.assertEqual(snap["availableMinutes"], 90)
        self.assertEqual(snap["uptimePercent"], 75.0)
        self.assertEqual(snap["days"][0]["unmeasuredMinutes"], 30)

    def test_down_and_degraded_states(self):
        self.feed(T0, 10)
        self.feed(T0 + 10 * 60, 5, {"app": False, "data": True, "ai": True})
        self.feed(T0 + 15 * 60, 5, {"app": True, "data": False, "ai": True})
        self.feed(T0 + 20 * 60, 10, {"app": True, "data": True, "ai": False})
        snap = self.rec.snapshot(T0 + 30 * 60)
        d = snap["days"][0]
        self.assertEqual((d["expectedMinutes"], d["availableMinutes"], d["degradedMinutes"]), (30, 20, 10))
        self.assertEqual(snap["uptimePercent"], 66.66)             # tronque, jamais arrondi vers le haut
        snap_now = self.rec.snapshot(T0 + 29 * 60 + 40)
        self.assertEqual(snap_now["status"], "degraded")           # dernier echantillon : IA injoignable, le reste fonctionne

    def test_percent_never_rounds_up_to_100_when_a_minute_is_lost(self):
        self.feed(T0, 1200)
        self.rec.record({"app": False, "data": True, "ai": True}, ts=T0 + 600 * 60 + 7)     # une seule minute perdue sur 1200
        snap = self.rec.snapshot(T0 + 1200 * 60)
        self.assertEqual(snap["uptimePercent"], 99.91)
        self.assertLess(snap["uptimePercent"], 100.0)

    def test_stale_last_sample_is_unknown_not_ok(self):
        self.feed(T0, 3)
        self.assertEqual(self.rec.snapshot(T0 + 3 * 60 + 10)["status"], "operational")
        self.assertEqual(self.rec.snapshot(T0 + 3 * 60 + 400)["status"], "unknown")

    def test_worst_state_wins_inside_a_minute(self):
        self.rec.record(OK, ts=T0 + 1)
        self.rec.record({"app": False, "data": True, "ai": True}, ts=T0 + 20)
        self.rec.record(OK, ts=T0 + 40)
        snap = self.rec.snapshot(T0 + 60)
        self.assertEqual(snap["availableMinutes"], 0)
        self.assertEqual(snap["expectedMinutes"], 1)

    def test_persistence_survives_restart_and_keeps_measured_since(self):
        self.feed(T0, 10)
        again = sm.StatusRecorder(self.tmp)
        snap = again.snapshot(T0 + 10 * 60)
        self.assertEqual(snap["sinceTs"], T0 + 5)
        self.assertEqual(snap["expectedMinutes"], 10)
        self.assertEqual(snap["availableMinutes"], 10)
        self.assertTrue(os.path.isfile(os.path.join(self.tmp, "meta.json")))

    def test_whole_missing_days_inside_the_measured_period_are_outage_not_skipped(self):
        self.feed(T0, 60)
        later = T0 + 3 * 86400 + 600
        self.feed(later, 5)
        snap = self.rec.snapshot(later + 300)
        dates = [d["date"] for d in snap["days"]]
        self.assertEqual(len(dates), 4)
        self.assertEqual(snap["days"][1]["level"], "outage")       # jour sans aucun echantillon = indisponible, pas absent
        self.assertEqual(snap["days"][1]["uptimePercent"], 0.0)
        self.assertEqual(snap["days"][1]["unmeasuredMinutes"], 1440)

    def test_rotation_keeps_90_days_only(self):
        for k in range(100):
            day = T0 - k * 86400
            self.rec.record(OK, ts=day + 30)
        now = T0
        self.rec.rotate(now)
        files = sorted(os.listdir(os.path.join(self.tmp, "days")))
        self.assertEqual(len(files), sm.RETENTION_DAYS)
        self.assertEqual(files[-1], sm.day_key(T0) + ".json")
        self.assertEqual(files[0], sm.day_key(T0 - 89 * 86400) + ".json")
        snap = self.rec.snapshot(now + 3600)
        self.assertLessEqual(len(snap["days"]), sm.RETENTION_DAYS)
        self.assertTrue(all(d["date"] >= sm.day_key(T0 - 89 * 86400) for d in snap["days"]))

    def test_corrupt_day_file_is_ignored_never_reconstructed(self):
        self.feed(T0, 10)
        key = sm.day_key(T0)
        write(os.path.join(self.tmp, "days", key + ".json"), '{"minutes": "UUU')
        again = sm.StatusRecorder(self.tmp)
        snap = again.snapshot(T0 + 600)
        self.assertEqual(snap["availableMinutes"], 0)              # rien n'est reinvente a partir d'un fichier casse
        self.assertEqual(snap["expectedMinutes"], 10)

    def test_public_payload_leaks_no_internal_details(self):
        self.feed(T0, 5, {"app": True, "data": False, "ai": False})
        log = sm.IncidentLog(os.path.join(self.tmp, "incidents.json"))
        log.add("Lenteur sur les missions", text="Nous enquetons.")
        blob = json.dumps(sm.public_payload(self.rec, log, now=T0 + 400), ensure_ascii=False)
        for forbidden in (self.tmp, "127.0.0.1", "api.anthropic.com", "accounts.json", "sessions.json", "Traceback",
                          "memory/runtime", "core/security", "CLI-", "/data/app", "Exception", "secret"):
            self.assertNotIn(forbidden, blob, forbidden)
        p = json.loads(blob)
        self.assertEqual({c["id"] for c in p["components"]}, {"app", "data", "ai"})
        self.assertEqual(set(p), {"generatedAtUtc", "status", "components", "measuredSinceUtc", "uptime", "days",
                                  "incidents", "sampleIntervalSeconds"})


class ProbeTests(unittest.TestCase):
    def test_ai_probe_is_dns_plus_tcp_only(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]
        accepted = []
        def accept_and_close():
            conn, addr = srv.accept()
            accepted.append(addr)
            conn.close()
        t = threading.Thread(target=accept_and_close, daemon=True)
        t.start()
        self.assertTrue(sm.check_ai_reachable("127.0.0.1", port, timeout=2))
        t.join(2)
        srv.close()
        self.assertFalse(sm.check_ai_reachable("127.0.0.1", port, timeout=1))         # plus rien n'ecoute
        self.assertFalse(sm.check_ai_reachable("no-such-host.invalid", 443, timeout=2))

    def test_app_probe_fails_when_nothing_listens(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        self.assertFalse(sm.check_app(port, timeout=1))

    def test_data_checker_detects_a_half_written_state_file(self):
        root = tempfile.mkdtemp(prefix="bkdata-")
        try:
            sdir = os.path.join(root, "core", "security", "x", "state")
            os.makedirs(sdir)
            good = os.path.join(sdir, "bindings.json")
            write(good, '[{"a":1}]')
            os.makedirs(os.path.join(root, "core", "accounts", "data"))
            checker = sm.DataChecker(root)
            self.assertTrue(checker(time.time()))
            time.sleep(0.02)
            write(good, '[{"a":1},\n{"a":')            # exactement le cas du 2026-09-28
            self.assertFalse(checker(time.time()))
            write(good, '[{"a":1}]')
            self.assertTrue(checker(time.time()))
        finally:
            shutil.rmtree(root, ignore_errors=True)

    def test_data_checker_tolerates_a_write_in_progress_but_not_a_lasting_corruption(self):
        root = tempfile.mkdtemp(prefix="bkdata-")
        try:
            sdir = os.path.join(root, "core", "security", "x", "state")
            os.makedirs(sdir)
            f = os.path.join(sdir, "bindings.json")
            write(f, '[{"a":1}]')
            checker = sm.DataChecker(root)
            self.assertTrue(checker(time.time()))
            time.sleep(0.02)
            write(f, '[{"a":')                                     # ecriture en cours...

            def finish():
                time.sleep(0.4)                                    # ...terminee avant la 3e lecture
                write(f, '[{"a":1}]')
            t = threading.Thread(target=finish)
            t.start()
            self.assertTrue(checker(time.time()), "une ecriture concurrente brève ne doit pas etre comptee comme une panne")
            t.join()
            time.sleep(0.02)
            write(f, '[{"a":')                                     # corruption durable
            import contextlib
            import io
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                self.assertFalse(checker(time.time()))
                self.assertFalse(checker(time.time()))
            lines = [x for x in buf.getvalue().splitlines() if "[status]" in x]
            self.assertEqual(len(lines), 1, "une seule ligne de journal interne par fenetre (pas de spam)")
            self.assertIn("bindings.json", lines[0])               # le fichier est retrouvable dans le journal prive du serveur...
            rec = sm.StatusRecorder(tempfile.mkdtemp(prefix="bkstatus-"))
            rec.record({"app": True, "data": False, "ai": True}, ts=T0)
            blob = json.dumps(sm.public_payload(rec, sm.IncidentLog(os.path.join(rec.dir, "i.json")), now=T0 + 30))
            self.assertNotIn("bindings.json", blob)                # ...jamais dans la charge utile publique
            shutil.rmtree(rec.dir, ignore_errors=True)
        finally:
            shutil.rmtree(root, ignore_errors=True)

    def test_probe_exception_counts_as_failure_and_loop_survives(self):
        tmp = tempfile.mkdtemp(prefix="bkstatus-")
        try:
            rec = sm.StatusRecorder(tmp)

            def boom():
                raise RuntimeError("secret internal detail")
            s = sm.Sampler(rec, {"app": lambda: True, "data": boom, "ai": lambda: True})
            self.assertEqual(s.sample_once(ts=T0), sm.DOWN)
            self.assertEqual(s.sample_once(ts=T0 + 60), sm.DOWN)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class IncidentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bkinc-")
        self.path = os.path.join(self.tmp, "incidents.json")
        self.clock = [T0]
        self.log = sm.IncidentLog(self.path, clock=lambda: self.clock[0])

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_lifecycle(self):
        inc = self.log.add("Panne partielle", impact="major", text="Nous enquetons.")
        self.assertEqual(inc["status"], "investigating")
        self.clock[0] += 600
        self.log.update(inc["id"], status="identified", text="Cause identifiee.")
        self.clock[0] += 600
        done = self.log.resolve(inc["id"], "Retour a la normale.")
        self.assertEqual(done["status"], "resolved")
        self.assertIsNotNone(done["resolvedAtUtc"])
        self.assertEqual(len(done["updates"]), 3)
        self.assertEqual(self.log.public(self.clock[0])[0]["id"], inc["id"])
        self.log.delete(inc["id"])
        self.assertEqual(self.log.list_all(), [])
        with self.assertRaises(KeyError):
            self.log.resolve("INC-NOPE")

    def test_title_required(self):
        with self.assertRaises(ValueError):
            self.log.add("   ")

    def test_hand_edited_json_and_typo_tolerance(self):
        write(self.path, json.dumps({"incidents": [
            {"id": "INC-1", "title": "Maintenance", "status": "monitoring", "impact": "maintenance",
             "startedAtUtc": "2026-10-07T08:00:00Z", "updates": [{"atUtc": "2026-10-07T08:05:00Z", "text": "En cours."}]},
            {"id": "BAD", "title": "pas de date"},
            "n'importe quoi",
        ]}))
        rows = self.log.list_all()
        self.assertEqual([r["id"] for r in rows], ["INC-1"])
        write(self.path, '{"incidents": [ {"id": "INC-1", ')   # faute de frappe du proprietaire
        self.assertEqual([r["id"] for r in self.log.list_all()], ["INC-1"])             # derniere version valide conservee
        self.assertTrue(self.log.invalid)

    def test_old_resolved_incidents_leave_the_public_view_but_open_ones_stay(self):
        old = sm.iso(T0 - 200 * 86400)
        write(self.path, json.dumps({"incidents": [
            {"id": "INC-OLD", "title": "Ancien", "status": "resolved", "startedAtUtc": old, "resolvedAtUtc": old},
            {"id": "INC-OPEN", "title": "Toujours ouvert", "status": "investigating", "startedAtUtc": old},
        ]}))
        ids = [r["id"] for r in self.log.public(T0)]
        self.assertEqual(ids, ["INC-OPEN"])

    def test_text_is_clipped_and_control_chars_removed(self):
        inc = self.log.add("T" * 500, text="x" * 5000 + "\x00\x07")
        self.assertEqual(len(inc["title"]), 140)
        self.assertEqual(len(inc["updates"][0]["text"]), 600)
        self.assertNotIn("\x00", inc["updates"][0]["text"])


class IncidentCliTests(unittest.TestCase):
    """deploy/status-incident.py : le proprietaire tient le journal sans toucher au code."""

    def run_cli(self, tmp, *args):
        import subprocess
        env = dict(os.environ, BK_STATUS_DIR=tmp, PYTHONIOENCODING="utf-8")
        return subprocess.run([sys.executable, os.path.join(REPO, "deploy", "status-incident.py"), *args],
                              capture_output=True, text=True, encoding="utf-8", env=env)

    def test_add_update_resolve_list_delete(self):
        tmp = tempfile.mkdtemp(prefix="bkcli-")
        try:
            r = self.run_cli(tmp, "add", "--title", "Lenteur sur les missions", "--impact", "major", "--text", "Nous enquetons.")
            self.assertEqual(r.returncode, 0, r.stderr)
            inc = json.loads(r.stdout)
            self.assertEqual((inc["status"], inc["impact"]), ("investigating", "major"))
            r = self.run_cli(tmp, "update", inc["id"], "--status", "identified", "--text", "Cause identifiee.")
            self.assertEqual(json.loads(r.stdout)["status"], "identified")
            r = self.run_cli(tmp, "resolve", inc["id"], "--text", "Retour a la normale.")
            done = json.loads(r.stdout)
            self.assertEqual(done["status"], "resolved")
            self.assertEqual(len(done["updates"]), 3)
            listed = json.loads(self.run_cli(tmp, "list").stdout)
            self.assertEqual([x["id"] for x in listed], [inc["id"]])
            # le meme fichier est lu par le serveur : l'incident est public
            pub = sm.IncidentLog(os.path.join(tmp, "incidents.json")).public(time.time())
            self.assertEqual(pub[0]["title"], "Lenteur sur les missions")
            self.assertEqual(self.run_cli(tmp, "delete", inc["id"]).returncode, 0)
            self.assertEqual(json.loads(self.run_cli(tmp, "list").stdout), [])
            bad = self.run_cli(tmp, "resolve", "INC-NOPE")
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("introuvable", bad.stderr)
            self.assertNotEqual(self.run_cli(tmp, "add", "--title", "x", "--impact", "catastrophic").returncode, 0)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
