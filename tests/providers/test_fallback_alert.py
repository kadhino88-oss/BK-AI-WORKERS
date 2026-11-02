# -*- coding: utf-8 -*-
"""Raison d'une reponse de secours (provider_router.parse_fallback_reason) et limite d'une alerte par heure et par raison.

    python tests/providers/test_fallback_alert.py
"""
import os
import sys
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import provider_router as pr  # noqa: E402


class FallbackReason(unittest.TestCase):
    def test_reads_the_reason_code(self):
        out = "MODEL : x\n\nPROVIDER UNAVAILABLE\nREASON : ANTHROPIC_EXIT_CODE_1\nFALLBACK : LOCAL\n"
        self.assertEqual(pr.parse_fallback_reason(out), "ANTHROPIC_EXIT_CODE_1")

    def test_windows_line_endings(self):
        out = "PROVIDER UNAVAILABLE\r\nREASON : LLM_GLOBAL_DISABLED\r\nFALLBACK : LOCAL\r\n"
        self.assertEqual(pr.parse_fallback_reason(out), "LLM_GLOBAL_DISABLED")

    def test_empty_when_the_mission_did_not_fall_back(self):
        self.assertEqual(pr.parse_fallback_reason("ANTHROPIC : READY FOR LIVE PATH\nok"), "")
        self.assertEqual(pr.parse_fallback_reason(None), "")
        self.assertEqual(pr.parse_fallback_reason(""), "")

    def test_empty_reason_line_gives_nothing(self):
        self.assertEqual(pr.parse_fallback_reason("PROVIDER UNAVAILABLE\nREASON : \nFALLBACK : LOCAL"), "")


class FallbackAlertRate(unittest.TestCase):
    def test_one_alert_per_hour_per_reason(self):
        marks = {}
        self.assertTrue(pr.fallback_alert_due("A", now=1000, marks=marks))
        self.assertFalse(pr.fallback_alert_due("A", now=1000 + 60, marks=marks))
        self.assertTrue(pr.fallback_alert_due("B", now=1000 + 60, marks=marks))
        self.assertFalse(pr.fallback_alert_due("A", now=1000 + pr.FALLBACK_ALERT_SECONDS - 1, marks=marks))
        self.assertTrue(pr.fallback_alert_due("A", now=1000 + pr.FALLBACK_ALERT_SECONDS, marks=marks))


if __name__ == "__main__":
    unittest.main()
