"""Droits d'acces par Worker (forfaits Solo / Trio) : helpers de dashboard/installations.py, sans serveur ni PowerShell.

python tests/hire/test_entitlements.py   (Windows ou Linux)
"""
import datetime
import os
import sys
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import installations as inst  # noqa: E402

UTC = datetime.timezone.utc
T0 = datetime.datetime(2026, 10, 12, 9, 0, tzinfo=UTC)
KNOWN = {"alex", "nora", "maya", "dario", "emma", "sam"}


def state(plan, hired=None, **extra):
    s = {"planId": plan}
    if hired is not None:
        s["hiredWorkers"] = hired
    s.update(extra)
    return s


class Entitlements(unittest.TestCase):
    def test_classic_plans_keep_access_to_every_worker(self):
        for plan in ("essai", "starter", "business", "pro", "scale", "enterprise", "inconnu", None):
            s = state(plan, ["alex"])            # une liste residuelle n'a aucun effet hors forfait restreint
            self.assertFalse(inst.is_restricted(s), plan)
            self.assertIsNone(inst.allowed_workers(s), plan)
            for w in ("alex", "nora", "chloe"):
                self.assertTrue(inst.worker_allowed(s, w), (plan, w))
        self.assertIsNone(inst.allowed_workers(None))
        self.assertTrue(inst.worker_allowed(None, "alex"))

    def test_solo_only_opens_the_hired_worker(self):
        s = state("solo", ["alex"])
        self.assertTrue(inst.worker_allowed(s, "alex"))
        self.assertTrue(inst.worker_allowed(s, "ALEX"))
        self.assertFalse(inst.worker_allowed(s, "nora"))
        self.assertEqual(inst.allowed_workers(s), ["alex"])
        self.assertEqual(inst.worker_slots(s), 1)

    def test_chloe_is_included_with_trio_only(self):
        self.assertFalse(inst.worker_allowed(state("solo", ["alex"]), "chloe"))
        self.assertTrue(inst.worker_allowed(state("trio", ["alex", "nora", "maya"]), "chloe"))
        self.assertEqual(inst.allowed_workers(state("trio", ["alex", "nora", "maya"])), ["alex", "nora", "maya"])
        self.assertNotIn("chloe", inst.allowed_workers(state("trio", ["alex", "chloe"])))      # Chloe n'est pas un Worker a embaucher

    def test_a_restricted_plan_without_a_list_opens_nothing(self):
        for s in (state("solo"), state("solo", []), state("trio", None), state("solo", "alex"), state("solo", {"alex": 1})):
            self.assertEqual(inst.allowed_workers(s), [], s)
            self.assertFalse(inst.worker_allowed(s, "alex"), s)

    def test_junk_in_the_list_is_ignored_and_slots_are_a_ceiling(self):
        s = state("solo", ["Alex", "alex", "../etc", "", None, "nora"])
        self.assertEqual(inst.hired_workers(s), ["alex"])        # un seul emplacement
        s = state("trio", ["alex", "nora", "maya", "dario"])
        self.assertEqual(inst.hired_workers(s), ["alex", "nora", "maya"])
        self.assertFalse(inst.worker_allowed(s, "dario"))

    def test_invalid_worker_ids_are_refused_on_a_restricted_plan(self):
        s = state("solo", ["alex"])
        for bad in ("", None, "alex\n", "../alex", "alex/..", "al ex", "ALEX;"):
            self.assertFalse(inst.worker_allowed(s, bad), repr(bad))

    def test_refusal_messages_are_clear_french(self):
        names = {"alex": "Alex", "nora": "Nora"}.get
        m = inst.refusal_detail(state("solo", ["alex"]), "nora", lambda w: names(w, w))
        self.assertIn("Nora", m)
        self.assertIn("Alex", m)
        self.assertIn("Solo", m)
        m = inst.refusal_detail(state("solo", []), "nora")
        self.assertIn("pas encore", m)
        m = inst.refusal_detail(state("solo", ["alex"]), "chloe")
        self.assertIn("Trio", m)


class Hiring(unittest.TestCase):
    def test_free_hire_while_slots_remain(self):
        s = state("trio", [])
        r = inst.hire(s, "alex", known_ids=KNOWN, now=T0)
        self.assertEqual((r["hired"], r["replaced"], r["alreadyHired"]), ("alex", None, False))
        inst.hire(s, "Nora", known_ids=KNOWN, now=T0)
        self.assertEqual(s["hiredWorkers"], ["alex", "nora"])
        self.assertNotIn("lastWorkerSwapAtUtc", s)               # embaucher n'est pas echanger
        self.assertEqual(inst.hire_summary(s, T0)["slotsLeft"], 1)
        self.assertEqual(len(s["history"]), 2)

    def test_hiring_the_same_worker_twice_is_idempotent(self):
        s = state("solo", ["alex"])
        r = inst.hire(s, "alex", known_ids=KNOWN, now=T0)
        self.assertTrue(r["alreadyHired"])
        self.assertEqual(s["hiredWorkers"], ["alex"])

    def test_full_plan_asks_which_worker_to_replace(self):
        s = state("solo", ["alex"])
        with self.assertRaises(inst.HireError) as cm:
            inst.hire(s, "nora", known_ids=KNOWN, now=T0)
        self.assertEqual(cm.exception.code, "NO_SLOT_LEFT")
        self.assertEqual(cm.exception.status, 409)
        self.assertEqual(cm.exception.extra["hiredWorkers"], ["alex"])
        self.assertEqual(s["hiredWorkers"], ["alex"])

    def test_one_swap_per_30_days(self):
        s = state("solo", ["alex"])
        r = inst.hire(s, "nora", replace_id="alex", known_ids=KNOWN, now=T0)
        self.assertEqual((r["hired"], r["replaced"]), ("nora", "alex"))
        self.assertEqual(s["hiredWorkers"], ["nora"])
        self.assertEqual(s["lastWorkerSwapAtUtc"], "2026-10-12T09:00:00Z")
        self.assertEqual(s["workerSwaps"][-1], {"atUtc": "2026-10-12T09:00:00Z", "out": "alex", "in": "nora"})
        with self.assertRaises(inst.HireError) as cm:               # un second echange le lendemain : refuse
            inst.hire(s, "maya", replace_id="nora", known_ids=KNOWN, now=T0 + datetime.timedelta(days=1))
        self.assertEqual(cm.exception.code, "SWAP_COOLDOWN")
        self.assertEqual(cm.exception.extra["nextSwapAtUtc"], "2026-11-11T09:00:00Z")
        self.assertFalse(cm.exception.extra["canSwapNow"])
        self.assertEqual(s["hiredWorkers"], ["nora"])
        with self.assertRaises(inst.HireError):                     # 29 jours : toujours refuse
            inst.hire(s, "maya", replace_id="nora", known_ids=KNOWN, now=T0 + datetime.timedelta(days=29, hours=23))
        inst.hire(s, "maya", replace_id="nora", known_ids=KNOWN, now=T0 + datetime.timedelta(days=30))   # 30 jours : accepte
        self.assertEqual(s["hiredWorkers"], ["maya"])
        self.assertEqual(len(s["workerSwaps"]), 2)

    def test_replacing_a_worker_that_is_not_hired_is_refused(self):
        s = state("trio", ["alex", "nora", "maya"])
        with self.assertRaises(inst.HireError) as cm:
            inst.hire(s, "dario", replace_id="emma", known_ids=KNOWN, now=T0)
        self.assertEqual(cm.exception.code, "REPLACE_NOT_HIRED")
        self.assertNotIn("lastWorkerSwapAtUtc", s)

    def test_swap_inside_a_trio_keeps_the_others(self):
        s = state("trio", ["alex", "nora", "maya"])
        inst.hire(s, "dario", replace_id="nora", known_ids=KNOWN, now=T0)
        self.assertEqual(s["hiredWorkers"], ["alex", "dario", "maya"])

    def test_unknown_chloe_and_classic_plan_are_refused(self):
        s = state("solo", [])
        for wid, code in (("hacker", "UNKNOWN_WORKER"), ("../x", "UNKNOWN_WORKER"), ("", "UNKNOWN_WORKER"), ("chloe", "CHLOE_NOT_HIRABLE")):
            with self.assertRaises(inst.HireError) as cm:
                inst.hire(s, wid, known_ids=KNOWN, now=T0)
            self.assertEqual(cm.exception.code, code, wid)
        self.assertEqual(s["hiredWorkers"] if "hiredWorkers" in s else [], [])
        with self.assertRaises(inst.HireError) as cm:
            inst.hire(state("starter"), "alex", known_ids=KNOWN, now=T0)
        self.assertEqual(cm.exception.code, "NO_RESTRICTED_PLAN")

    def test_malformed_swap_date_does_not_lock_the_client_out(self):
        s = state("solo", ["alex"], lastWorkerSwapAtUtc="pas une date")
        self.assertTrue(inst.swap_status(s, T0)["canSwapNow"])


class Granting(unittest.TestCase):
    def test_grant_sets_the_list_without_touching_the_swap_delay(self):
        s = state("trio", ["alex"], lastWorkerSwapAtUtc="2026-10-01T00:00:00Z")
        self.assertEqual(inst.grant(s, ["Nora", "maya", "nora"], known_ids=KNOWN, now=T0), ["nora", "maya"])
        self.assertEqual(s["hiredWorkers"], ["nora", "maya"])
        self.assertEqual(s["lastWorkerSwapAtUtc"], "2026-10-01T00:00:00Z")

    def test_grant_validates(self):
        s = state("solo", [])
        for workers, code in ((["alex", "nora"], "TOO_MANY_WORKERS"), ([], "WORKERS_REQUIRED"), ("alex", "WORKERS_REQUIRED"),
                              (["hacker"], "UNKNOWN_WORKER"), (["chloe"], "CHLOE_NOT_HIRABLE"), ([None], "UNKNOWN_WORKER")):
            with self.assertRaises(inst.HireError) as cm:
                inst.grant(s, workers, known_ids=KNOWN, now=T0)
            self.assertEqual(cm.exception.code, code, workers)
        self.assertEqual(s.get("hiredWorkers"), [])
        with self.assertRaises(inst.HireError):
            inst.grant(state("business"), ["alex"], known_ids=KNOWN)

    def test_adapting_to_a_new_plan(self):
        s = state("solo", ["alex", "nora", "maya"], lastWorkerSwapAtUtc="2026-10-01T00:00:00Z")
        inst.adapt_hired_to_plan(s, T0)
        self.assertEqual(s["hiredWorkers"], ["alex"])
        self.assertNotIn("lastWorkerSwapAtUtc", s)
        s = state("starter", ["alex"])
        inst.adapt_hired_to_plan(s, T0)
        self.assertEqual(s["hiredWorkers"], [])
        self.assertIsNone(inst.allowed_workers(s))


if __name__ == "__main__":
    unittest.main(verbosity=2)
