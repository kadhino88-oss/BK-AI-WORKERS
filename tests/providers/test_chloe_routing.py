# -*- coding: utf-8 -*-
"""Le repli de routage de Chloe (Invoke-BKChloeAIRouting, chloe/Chloe-LegacyRouting.ps1) est un appel DIRECT a Claude avec la cle de la plateforme. Avec un plan de moteurs il ne doit partir que
si Claude est le moteur prevu, non ecarte et sous le plafond de depense ; sa depense compte dans le registre. Sans plan : comme avant.

L'API d'Anthropic est simulee (tests/providers/shim_anthropic.ps1). PowerShell 7 requis (sous Windows : dans WSL).
    python3 -m unittest tests/providers/test_chloe_routing.py -v
"""
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "dashboard"))
import harness  # noqa: E402
import provider_router as pr  # noqa: E402
from harness import CLIENT, PWSH, REPO, Run  # noqa: E402
import shutil  # noqa: E402

KEY = "sk-ant-PLATFORM-KEY-FOR-TESTS-ONLY-0002"
DRIVER = r'''
param($ClientId, $ProjectId, $WorkerId, $TaskId, $Objective, $Model)
$Root = $env:BK_ROOT
. (Join-Path $Root "core/ai/BK-Secret.ps1")
$Src = Get-Content -LiteralPath (Join-Path $Root "chloe/Chloe-LegacyRouting.ps1") -Raw -Encoding UTF8
$Start = $Src.IndexOf("function Invoke-BKChloeAIRouting")
Invoke-Expression $Src.Substring($Start)
$Routing = Get-Content -LiteralPath (Join-Path $Root "orchestrator/worker-routing.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$R = Invoke-BKChloeAIRouting -UserRequest "Aide-moi avec une chose vague" -RoutingConfig $Routing -Excluded @($Routing.excluded_from_routing) -PreferredIds $null
[ordered]@{ routed = ($null -ne $R); workers = @($R.Workers) } | ConvertTo-Json -Compress | Write-Output
exit 0
'''


def prepare(root):
    shutil.copy2(os.path.join(HERE, "shim_anthropic.ps1"), os.path.join(root, "_test", "shim_anthropic.ps1"))
    with open(os.path.join(root, "_test", "chloe_driver.ps1"), "w", encoding="utf-8") as f:
        f.write(DRIVER)
    os.makedirs(os.path.join(root, "chloe"), exist_ok=True)
    os.makedirs(os.path.join(root, "orchestrator"), exist_ok=True)
    shutil.copy2(os.path.join(REPO, "chloe", "Chloe-LegacyRouting.ps1"), os.path.join(root, "chloe", "Chloe-LegacyRouting.ps1"))
    shutil.copy2(os.path.join(REPO, "orchestrator", "worker-routing.json"), os.path.join(root, "orchestrator", "worker-routing.json"))


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class ChloeRouting(unittest.TestCase):
    def setUp(self):
        self.root = harness.make_root(extra=prepare)
        self.addCleanup(shutil.rmtree, self.root, True)
        with open(os.path.join(REPO, "core", "ai", "LEVELS.json"), encoding="utf-8-sig") as f:
            self.levels = json.load(f)["levels"]

    def run_router(self, plan_env=None):
        env = {"T_PRE": '. (Join-Path $env:BK_ROOT "_test/shim_anthropic.ps1")', "BK_SECRET_ANTHROPIC": KEY, "FAKE_ANTHROPIC_KEY": KEY,
               "FAKE_ANTHROPIC": json.dumps([{"text": '{"workers": ["noah"], "direct_reply": null}', "usage": [4000, 300]}]),
               "FAKE_ANTHROPIC_LOG": os.path.join(self.root, "_test", "anthropic.jsonl")}
        env.update(plan_env or {})
        r = Run("_test/chloe_driver.ps1", root=self.root, env=env, model="NONE")
        calls = []
        p = os.path.join(self.root, "_test", "anthropic.jsonl")
        if os.path.isfile(p):
            calls = [json.loads(line) for line in open(p, encoding="utf-8") if line.strip()]
        return r, calls

    def spend(self):
        p = os.path.join(self.root, "runtime", "engine", "spend.json")
        return json.load(open(p, encoding="utf-8-sig")) if os.path.isfile(p) else {}

    def plan(self, **kw):
        return pr.resolve_plan(self.root, CLIENT, "rapide", "", levels=self.levels, env={}, **kw)

    def test_without_a_plan_the_routing_call_is_unchanged_and_writes_no_state(self):
        r, calls = self.run_router()
        self.assertEqual(r.result["routed"], True, r.proc.stderr + r.stdout)
        self.assertTrue(r.result["workers"], "le Worker choisi par le modele est renvoye")
        self.assertEqual(len(calls), 1)
        self.assertEqual(self.spend(), {})

    def test_with_claude_as_the_planned_engine_the_call_is_made_and_counted(self):
        pr.apply_settings(self.root, {"ceiling": {"dailyChf": 50}}, levels=self.levels, env={})
        r, calls = self.run_router(pr.plan_env(self.plan()))
        self.assertTrue(r.result["routed"], r.proc.stderr + r.stdout)
        self.assertEqual(len(calls), 1)
        day = next(iter(self.spend()["days"].values()))
        self.assertGreater(day["chf"], 0, "la depense du routage entre dans le registre du plafond")

    def test_a_trial_on_the_local_engine_never_calls_claude_for_routing(self):
        pr.apply_settings(self.root, {"endpoints": {"ollama": {"url": "http://127.0.0.1:11434", "model": "llama3:latest"}}}, levels=self.levels, env={})
        r, calls = self.run_router(pr.plan_env(self.plan(trial=True)))
        self.assertFalse(r.result["routed"])
        self.assertEqual(calls, [])

    def test_a_client_key_mission_never_uses_the_platform_key_for_routing(self):
        meta = {"kind": "anthropic", "host": "api.anthropic.com", "endpoint": "https://api.anthropic.com", "model": "", "enabled": True}
        r, calls = self.run_router(pr.plan_env(self.plan(byok=meta)))
        self.assertFalse(r.result["routed"])
        self.assertEqual(calls, [])

    def test_a_reached_ceiling_or_a_benched_engine_stops_the_routing_call(self):
        pr.apply_settings(self.root, {"ceiling": {"dailyChf": 1.0}, "endpoints": {"ollama": {"url": "http://127.0.0.1:11434", "model": "llama3:latest"}}}, levels=self.levels, env={})
        plan_env = pr.plan_env(self.plan())
        from datetime import datetime, timezone
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        os.makedirs(os.path.join(self.root, "runtime", "engine"), exist_ok=True)
        with open(os.path.join(self.root, "runtime", "engine", "spend.json"), "w", encoding="utf-8") as f:
            json.dump({"days": {day: {"chf": 2.0, "usd": 2.0, "missions": 1}}, "months": {day[:7]: {"chf": 2.0, "usd": 2.0, "missions": 1}}}, f)
        r, calls = self.run_router(plan_env)
        self.assertFalse(r.result["routed"], "plafond atteint entre le calcul du plan et l'appel")
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
