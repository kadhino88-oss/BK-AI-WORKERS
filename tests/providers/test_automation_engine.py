# -*- coding: utf-8 -*-
"""Les missions RECURRENTES (automatisations) suivent le meme plan de moteurs que les missions lancees a la main :

  - dashboard/quota-check.py renvoie le plan (enginePlan) et le reste du budget (engineBudgetChf) quand le proprietaire a fait un choix, rien sinon ;
  - core/automation/AUTOMATION-ENGINE.ps1 les pose sur le processus de la mission (BK_ENGINE_PLAN, BK_ENGINE_BUDGET_CHF) et n'herite jamais d'une valeur ;
  - dashboard/Submit-Task.ps1 : un repli vers un autre moteur ne coute aucun credit, une mission voulue sur le moteur local coute le credit de son niveau.

Racine jetable (copie du depot), Invoke-Worker-AI.ps1 remplace par un faux : aucun modele, aucun reseau. PowerShell 7 requis (sous Windows : dans WSL).
    python3 -m unittest tests/providers/test_automation_engine.py -v
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
A = "CLI-CUST-AAAAAAAA"
OLLAMA = {"endpoints": {"ollama": {"url": "http://127.0.0.1:11434", "model": "llama3:latest"}}}

WORKER_STUB = r'''
param([string]$WorkerId, [string]$TaskId, [string]$Objective, [string]$TenantId, [string]$ClientId, [string]$ProjectId, [string]$ExecutionId,
      [string]$UserId, [string]$SessionId, [string]$TokenId, [string]$Token, [string]$Environment, [string]$Mode, [string]$Provider, [string]$Model)
$plan = $null
if ($env:BK_ENGINE_PLAN) { $plan = $env:BK_ENGINE_PLAN | ConvertFrom-Json }
$engine = $null
if ($env:STUB_ENGINE_JSON) { $engine = $env:STUB_ENGINE_JSON | ConvertFrom-Json }
$o = [ordered]@{ Status = "SUCCESS"; Answer = ("Reponse de " + $WorkerId); WorkerId = $WorkerId; PlanFirst = $(if ($plan) { [string]@($plan.chain)[0].id } else { "" });
                 BudgetSeen = [string]$env:BK_ENGINE_BUDGET_CHF; Degraded = $false }
if ($engine) { $o["Engine"] = $engine }
$o | ConvertTo-Json -Compress
'''


def ignore(directory, names):
    rel = os.path.relpath(directory, REPO).replace("\\", "/")
    skip = {n for n in names if n == "__pycache__"}
    if rel == ".":
        skip |= {".git", ".claude", ".secrets", "_archive", "runtime", "node_modules", "tests", "docs", "deploy", "mobile", "integrations"}
    if rel == "workers":
        skip.add("_portrait-backup-2026-09-20")
    if rel == "memory":
        skip.add("runtime")
    if rel in ("core/accounts", "core/billing", "core/automation", "core/profile", "core/leads", "core/hire"):
        skip |= {"data", "runs"}
    if rel == "core/connectors":
        skip.add("client-credentials")
    if rel == "core/ai":
        skip.add("data")
    if rel == "dashboard":
        skip.add(".gate")
    return skip


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f)


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class AutomationEngine(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="bkautoeng-")
        cls.addClassCleanup(shutil.rmtree, cls.tmp, True)
        cls.root = os.path.join(cls.tmp, "app")
        shutil.copytree(REPO, cls.root, ignore=ignore)
        with open(os.path.join(cls.root, "core/runtime/worker-runtime/Invoke-Worker-AI.ps1"), "w", encoding="utf-8-sig") as f:
            f.write(WORKER_STUB)

    def setUp(self):
        shutil.rmtree(os.path.join(self.root, "runtime"), ignore_errors=True)
        for sub in ("core/billing/data", "core/automation/data", "core/accounts/data", "core/ai/data"):
            shutil.rmtree(os.path.join(self.root, sub), ignore_errors=True)

    def plan_of(self, plan_id):
        write_json(os.path.join(self.root, "core", "billing", "data", A + ".json"),
                   {"planId": plan_id, "gridVersion": 2, "cycleStartUtc": "2026-10-01T00:00:00Z", "extraCredits": 0, "history": [], "hiredWorkers": ["alex"]})

    def settings(self, data):
        write_json(os.path.join(self.root, "core", "ai", "data", "engine-settings.json"), data)

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k not in (
            "BK_SECRETS_DIR", "BK_LEVELS", "BK_MISSION_LEVEL", "BK_ALLOWED_WORKERS", "BK_MAX_WORKERS", "BK_ENGINE_PLAN", "BK_ENGINE_BUDGET_CHF", "BK_AI_PROVIDER")}
        env.update(BK_ROOT=self.root, BK_PYTHON=sys.executable, PYTHONIOENCODING="utf-8", BK_PWSH=PWSH)
        env.update(extra)
        return env

    def quota(self, **extra):
        p = subprocess.run([sys.executable, os.path.join(self.root, "dashboard", "quota-check.py"), A, "alex", "scheduled"], capture_output=True, text=True,
                           encoding="utf-8", errors="replace", env=self.env(**extra), timeout=120, cwd=self.root)
        lines = [ln for ln in p.stdout.splitlines() if ln.strip().startswith("{")]
        self.assertTrue(lines, p.stdout + p.stderr)
        return json.loads(lines[-1])

    def tasks(self):
        out = []
        for p in sorted(glob.glob(os.path.join(self.root, "runtime", "tasks", "TASK-*.json"))):
            with open(p, encoding="utf-8-sig") as f:
                out.append(json.load(f))
        return out

    def run_automation(self, **extra):
        write_json(os.path.join(self.root, "core", "automation", "data", "automations.json"),
                   [{"id": "AUTO-TEST000001", "clientId": A, "workerId": "alex", "objective": "Rapport hebdomadaire", "frequencyMinutes": 60, "enabled": True,
                     "notifySlack": False, "createdAtUtc": "2026-10-01T00:00:00.0000000Z", "lastRunAtUtc": None, "lastRunStatus": None,
                     "nextRunAtUtc": "2026-10-01T00:00:00.0000000Z", "runCount": 0}])
        out_file = os.path.join(self.tmp, "bridge-out.json")
        if os.path.exists(out_file):
            os.remove(out_file)
        p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", os.path.join(self.root, "dashboard", "Automation-Bridge.ps1"), "-Action", "run",
                            "-Id", "AUTO-TEST000001", "-ClientId", A, "-OutFile", out_file],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", env=self.env(**extra), timeout=600, cwd=self.root)
        self.assertTrue(os.path.isfile(out_file), p.stdout[-500:] + p.stderr[-500:])
        return p

    def test_nothing_chosen_nothing_passed(self):
        self.plan_of("solo")
        v = self.quota()
        self.assertFalse(v["blocked"])
        self.assertNotIn("enginePlan", v)
        self.run_automation(BK_ENGINE_PLAN='{"chain":[{"id":"inherited"}]}', BK_ENGINE_BUDGET_CHF="9")
        res = self.tasks()[0]["Result"]
        self.assertEqual((res["PlanFirst"], res["BudgetSeen"]), ("", ""), "ni plan ni budget herites du processus appelant")

    def test_a_trial_account_automation_runs_on_the_free_engine(self):
        self.plan_of("essai")
        self.settings(OLLAMA)
        v = self.quota()
        self.assertEqual(json.loads(v["enginePlan"])["chain"][0]["id"], "ollama")
        self.run_automation()
        res = self.tasks()[0]["Result"]
        self.assertEqual(res["PlanFirst"], "ollama")

    def test_a_paying_account_automation_keeps_claude_but_gets_the_remaining_budget(self):
        self.plan_of("solo")
        self.settings({"ceiling": {"dailyChf": 2.0}})
        v = self.quota()
        plan = json.loads(v["enginePlan"])
        self.assertEqual([e["id"] for e in plan["chain"]], ["anthropic"])
        self.assertAlmostEqual(float(v["engineBudgetChf"]), 2.0, places=3)
        self.run_automation()
        res = self.tasks()[0]["Result"]
        self.assertEqual(res["PlanFirst"], "anthropic")
        self.assertAlmostEqual(float(res["BudgetSeen"]), 2.0, places=3)

    def test_a_failover_costs_no_credit_and_a_wanted_local_mission_costs_the_level(self):
        self.plan_of("solo")
        failover = {"provider": "ollama", "model": "llama3:latest", "local": True, "failedOver": True, "creditsFree": True, "label": "Moteur local (Llama 3)"}
        self.run_automation(STUB_ENGINE_JSON=json.dumps(failover))
        t = self.tasks()[0]
        self.assertEqual((t["Credits"], t["Result"]["Engine"]["failedOver"]), (0, True), "repli : 0 credit")
        shutil.rmtree(os.path.join(self.root, "runtime"), ignore_errors=True)
        wanted = dict(failover, failedOver=False, creditsFree=False)
        self.run_automation(STUB_ENGINE_JSON=json.dumps(wanted))
        t = self.tasks()[0]
        self.assertEqual(t["Credits"], 1, "mission voulue sur le moteur local : le credit du niveau (Rapide = 1)")

    def test_without_engine_info_the_credit_is_what_it_always_was(self):
        self.plan_of("solo")
        self.run_automation()
        t = self.tasks()[0]
        self.assertEqual(t["Credits"], 1)
        self.assertNotIn("Engine", t["Result"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
