"""Offre « Worker a l'unite » cote PowerShell : BK_ALLOWED_WORKERS (Workers embauches par le client).

  - chloe/Invoke-Chloe-Orchestration.ps1 : ne delegue qu'aux Workers embauches ; si le meilleur Worker n'est pas embauche -> Status
    WORKER_NOT_INCLUDED, AUCUN Worker execute ; mission partielle -> seuls les embauches travaillent et le reste est signale ;
  - dashboard/Submit-Task.ps1 : second verrou (un Worker non embauche ou un routage libre ne demarre rien, aucune trace de tache).

Aucun appel modele ni reseau : Invoke-Worker-AI.ps1 est remplace par un faux qui note les Workers appeles ; aucun secret dans l'environnement.
PowerShell 7 requis.   python tests/hire/test_chloe_allowed.py
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
REQUEST_TWO = "Je veux de la prospection de nouveaux clients et une campagne de marketing"       # ALEX (prospection) + MAYA (marketing)

def as_list(value):
    """ConvertTo-Json de PowerShell peut rendre une liste d'un seul element sous forme de valeur seule, ou une liste vide sous forme null."""
    return [] if value is None else (value if isinstance(value, list) else [value])


STUB = r'''
param([string]$WorkerId, [string]$TaskId, [string]$Objective, [string]$TenantId, [string]$ClientId, [string]$ProjectId, [string]$ExecutionId,
      [string]$UserId, [string]$SessionId, [string]$TokenId, [string]$Token, [string]$Environment, [string]$Mode, [string]$Provider, [string]$Model)
Add-Content -LiteralPath $env:STUB_LOG -Value $WorkerId
@{ Status = "SUCCESS"; Answer = ("Reponse de " + $WorkerId); WorkerId = $WorkerId } | ConvertTo-Json -Compress
'''

CHLOE_DRIVER = r'''
$ErrorActionPreference = "Stop"
if ($env:T_FAKE_ROUTER) {
    # Faux appel au routeur IA de Chloe (aucun reseau) : on garde la requete envoyee et on renvoie la reponse imposee par le test.
    function Invoke-RestMethod { param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec)
        [System.IO.File]::WriteAllText($env:ROUTER_LOG, [System.Text.Encoding]::UTF8.GetString($Body))
        return [pscustomobject]@{ content = @([pscustomobject]@{ type = "text"; text = $env:T_FAKE_ROUTER }) }
    }
}
$args2 = @{ Request = $env:T_REQUEST; TenantId = "T"; ClientId = "CLI-CUST-AAAAAAAA"; ProjectId = "P"; ExecutionId = "EXEC-1"; UserId = "U"; SessionId = "S"; TokenId = "K"; Token = "x" }
if ($env:T_PLAN -eq "1") { $args2["PlanOnly"] = $true }
$r = & (Join-Path $env:BK_ROOT "chloe/Invoke-Chloe-Orchestration.ps1") @args2
$r | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $env:OUT_FILE -Encoding utf8
'''


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class AllowedWorkers(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="bkallowed-")
        self.addCleanup(shutil.rmtree, self.root, True)
        for rel in ("chloe/Invoke-Chloe-Orchestration.ps1", "orchestrator/worker-routing.json", "core/ai/Get-DefaultProvider.ps1",
                    "core/ai/BK-Secret.ps1", "core/ai/AI-PROVIDERS.json", "dashboard/Submit-Task.ps1"):
            dst = os.path.join(self.root, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(os.path.join(REPO, rel), dst)
        stub = os.path.join(self.root, "core", "runtime", "worker-runtime", "Invoke-Worker-AI.ps1")
        os.makedirs(os.path.dirname(stub))
        with open(stub, "w", encoding="utf-8") as f:
            f.write(STUB)
        self.log = os.path.join(self.root, "stub.log")
        self.out = os.path.join(self.root, "out.json")
        self.router_log = os.path.join(self.root, "router-request.json")

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k not in ("BK_SECRETS_DIR", "BK_ALLOWED_WORKERS")}
        env.update(BK_ROOT=self.root, STUB_LOG=self.log, OUT_FILE=self.out, BK_REPLY_LANG="")
        env.update(extra)
        return env

    def chloe(self, request, allowed=None, plan=False, fake_router=None):
        for p in (self.log, self.out, self.router_log):
            if os.path.exists(p):
                os.remove(p)
        extra = {"T_REQUEST": request, "T_PLAN": "1" if plan else "0"}
        if fake_router is not None:
            extra.update(T_FAKE_ROUTER=fake_router, BK_SECRET_ANTHROPIC="cle-factice-pour-les-tests", ROUTER_LOG=self.router_log)
        if allowed is not None:
            extra["BK_ALLOWED_WORKERS"] = allowed
        drv = os.path.join(self.root, "driver.ps1")
        with open(drv, "w", encoding="utf-8") as f:
            f.write(CHLOE_DRIVER)
        p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", drv], capture_output=True, text=True, encoding="utf-8",
                           errors="replace", env=self.env(**extra), timeout=240)
        self.assertTrue(os.path.isfile(self.out), p.stdout + p.stderr)
        with open(self.out, encoding="utf-8-sig") as f:
            result = json.load(f)
        called = []
        if os.path.isfile(self.log):
            with open(self.log, encoding="utf-8-sig") as f:
                called = [l.strip() for l in f if l.strip()]
        return result, called

    def test_without_the_variable_every_matching_worker_works_as_before(self):
        r, called = self.chloe(REQUEST_TWO)
        self.assertEqual(sorted(called), ["ALEX", "MAYA"])
        self.assertEqual(r["Status"], "SUCCESS")
        self.assertEqual(as_list(r["NotIncludedWorkers"]), [])
        self.assertNotIn("Non inclus", r["FinalSynthesis"])

    def test_only_the_hired_workers_are_executed_and_the_rest_is_reported(self):
        r, called = self.chloe(REQUEST_TWO, allowed="alex")
        self.assertEqual(called, ["ALEX"])
        self.assertEqual(r["Status"], "SUCCESS")
        self.assertEqual(as_list(r["SelectedWorkers"]), ["ALEX"])
        self.assertEqual(as_list(r["NotIncludedWorkers"]), ["MAYA"])
        self.assertIn("Non inclus dans votre forfait", r["FinalSynthesis"])
        self.assertIn("Maya", r["FinalSynthesis"])
        self.assertIn("Reponse de ALEX", r["FinalSynthesis"])

    def test_when_the_best_worker_is_not_hired_nothing_runs_and_the_status_says_why(self):
        r, called = self.chloe(REQUEST_TWO, allowed="nora")
        self.assertEqual(called, [], "aucun Worker execute, donc aucun credit")
        self.assertEqual(r["Status"], "WORKER_NOT_INCLUDED")
        self.assertEqual(r["NextAction"], "HIRE_WORKER")
        self.assertIn("ne font pas partie de vos Workers embauchés", r["FinalSynthesis"])
        self.assertIn("Alex", r["FinalSynthesis"])
        self.assertIn("Maya", r["FinalSynthesis"])
        self.assertIn("aucun crédit", r["FinalSynthesis"])
        self.assertEqual(r["Results"] or [], [])
        single, called = self.chloe("Fais-moi un logo et une charte graphique", allowed="alex")        # LEA seule, non embauchee
        self.assertEqual((single["Status"], called), ("WORKER_NOT_INCLUDED", []))
        self.assertIn("relève de Lea, qui ne fait pas partie", single["FinalSynthesis"])

    def test_dash_means_no_worker_at_all(self):
        r, called = self.chloe(REQUEST_TWO, allowed="-")
        self.assertEqual((r["Status"], called), ("WORKER_NOT_INCLUDED", []))

    def test_junk_in_the_variable_never_widens_access(self):
        r, called = self.chloe(REQUEST_TWO, allowed="../etc, MAYA;rm -rf, ,al ex,*")
        self.assertEqual((r["Status"], called), ("WORKER_NOT_INCLUDED", []))
        r, called = self.chloe(REQUEST_TWO, allowed=" ALEX , ../x")        # casse et espaces tolerees, le reste est ignore
        self.assertEqual(called, ["ALEX"])

    def test_plan_only_applies_the_same_filter(self):
        r, called = self.chloe(REQUEST_TWO, allowed="alex", plan=True)
        self.assertEqual(called, [])
        self.assertEqual(r["Status"], "PLANNED")
        self.assertEqual(as_list(r["SelectedWorkers"]), ["ALEX"])
        self.assertEqual(as_list(r["NotIncludedWorkers"]), ["MAYA"])
        r, _ = self.chloe(REQUEST_TWO, allowed="nora", plan=True)
        self.assertEqual(r["Status"], "WORKER_NOT_INCLUDED")

    VAGUE = "Peux-tu m'aider avec mon projet de la semaine prochaine ?"      # aucun mot-cle : le routeur IA est appele

    def router_request(self):
        with open(self.router_log, encoding="utf-8") as f:
            return json.load(f)

    def test_the_ai_router_is_told_which_workers_are_hired_and_its_choice_is_filtered(self):
        r, called = self.chloe(self.VAGUE, allowed="alex", fake_router=json.dumps({"workers": ["alex"], "direct_reply": None}))
        self.assertEqual(called, ["ALEX"])
        system = self.router_request()["system"]
        self.assertIn("This client has hired ONLY these Workers: alex", system)
        self.assertIn("never a Worker outside this list as a fallback", system)
        r, called = self.chloe(self.VAGUE, allowed="alex", fake_router=json.dumps({"workers": ["maya"], "direct_reply": None}))
        self.assertEqual((r["Status"], called), ("WORKER_NOT_INCLUDED", []))
        self.assertIn("relève de Maya", r["FinalSynthesis"])
        r, called = self.chloe(self.VAGUE, allowed="alex", fake_router=json.dumps({"workers": ["alex", "maya"], "direct_reply": None}))
        self.assertEqual(called, ["ALEX"])
        self.assertEqual(as_list(r["NotIncludedWorkers"]), ["MAYA"])
        r, called = self.chloe(self.VAGUE, allowed="alex", fake_router=json.dumps({"workers": [], "direct_reply": "Bonjour, que puis-je faire pour vous ?"}))
        self.assertEqual((r["Status"], called), ("SUCCESS", []))
        self.assertEqual(r["FinalSynthesis"], "Bonjour, que puis-je faire pour vous ?")

    def test_without_the_variable_the_router_prompt_has_no_hired_list(self):
        r, called = self.chloe(self.VAGUE, fake_router=json.dumps({"workers": ["maya"], "direct_reply": None}))
        self.assertEqual(called, ["MAYA"])
        self.assertNotIn("has hired ONLY", self.router_request()["system"])

    def test_a_greeting_still_gets_chloes_own_answer(self):
        r, called = self.chloe("bonjour", allowed="alex")
        self.assertEqual((r["Status"], called), ("NO_WORKER_MATCHED", []))

    def submit(self, worker, allowed=None, request="Fais-moi un devis"):
        out = os.path.join(self.root, "submit-out.json")
        if os.path.exists(out):
            os.remove(out)
        extra = {} if allowed is None else {"BK_ALLOWED_WORKERS": allowed}
        script = os.path.join(self.root, "dashboard", "Submit-Task.ps1")
        args = [PWSH, "-NoProfile", "-NonInteractive", "-File", script, "-Request", request, "-OutFile", out, "-ClientId", "CLI-CUST-AAAAAAAA"]
        if worker is not None:
            args += ["-WorkerId", worker]
        p = subprocess.run(args, capture_output=True, text=True, encoding="utf-8", errors="replace", env=self.env(**extra), timeout=240)
        data = None
        if os.path.isfile(out):
            with open(out, encoding="utf-8-sig") as f:
                data = json.load(f)
        return data, p

    def test_submit_task_refuses_a_worker_that_is_not_hired_before_doing_anything(self):
        for worker in ("maya", "MAYA", "", None):
            data, p = self.submit(worker, allowed="alex")
            self.assertIsNotNone(data, (worker, p.stdout, p.stderr))
            self.assertEqual(data["Status"], "WORKER_NOT_INCLUDED", worker)
            self.assertFalse(data["Authorized"])
            self.assertIn("aucun crédit", data["FinalSynthesis"])
            self.assertEqual(p.returncode, 0)
        self.assertFalse(os.path.isdir(os.path.join(self.root, "runtime", "tasks")), "aucune trace de tache")

    def test_submit_task_lets_the_hired_worker_and_chloe_through_the_gate(self):
        # le faux depot n'a pas les modules d'identite : si le verrou laisse passer, le script echoue PLUS LOIN (aucun fichier de refus)
        for worker, allowed in (("alex", "alex"), ("ALEX", "alex,maya"), ("chloe", "alex"), ("maya", None)):
            data, p = self.submit(worker, allowed=allowed)
            self.assertIsNone(data, (worker, data))
            self.assertNotEqual(p.returncode, 0)
            self.assertNotIn("WORKER_NOT_INCLUDED", p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
