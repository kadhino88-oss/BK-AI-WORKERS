# -*- coding: utf-8 -*-
"""Les automatisations (missions recurrentes) tournent au niveau RAPIDE et coutent 1 credit, et les credits suivent le niveau de la mission :

  - dashboard/quota-check.py : controle le quota a 1 credit pour une automatisation (un client qui n'a plus qu'un credit n'est pas bloque), et renvoie
    le niveau a appliquer (« rapide », ou vide quand BK_LEVELS=0) ;
  - core/automation/AUTOMATION-ENGINE.ps1 : transmet ce niveau au vrai dashboard/Submit-Task.ps1 (variable BK_MISSION_LEVEL) ;
  - dashboard/Submit-Task.ps1 : la trace de la tache porte Level et Credits d'apres core/ai/LEVELS.json ; chaque Worker appele par Chloe est trace au meme
    niveau (avant, ces traces n'avaient aucun credit : un Worker d'une mission Approfondi de Chloe ne coutait qu'un credit).

Racine jetable (copie du depot), Invoke-Worker-AI.ps1 et l'orchestration de Chloe remplaces par des faux : aucun modele, aucun reseau, aucun secret.
PowerShell 7 requis.   python tests/pricing/test_automation_level.py
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import A, REPO, load_server  # noqa: E402

PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")

WORKER_STUB = r'''
param([string]$WorkerId, [string]$TaskId, [string]$Objective, [string]$TenantId, [string]$ClientId, [string]$ProjectId, [string]$ExecutionId,
      [string]$UserId, [string]$SessionId, [string]$TokenId, [string]$Token, [string]$Environment, [string]$Mode, [string]$Provider, [string]$Model)
# STUB_DEGRADED=1 : le fournisseur d'IA est indisponible (repli local, Degraded) ; STUB_STATUS : un autre statut que SUCCESS (mission refusee).
$status = if ($env:STUB_STATUS) { $env:STUB_STATUS } else { "SUCCESS" }
@{ Status = $status; Answer = ("Reponse de " + $WorkerId); WorkerId = $WorkerId; LevelSeen = [string]$env:BK_MISSION_LEVEL; Degraded = ($env:STUB_DEGRADED -eq "1") } | ConvertTo-Json -Compress
'''

CHLOE_STUB = r'''
param([string]$Request, [string]$TenantId, [string]$ClientId, [string]$ProjectId, [string]$ExecutionId, [string]$UserId, [string]$SessionId,
      [string]$TokenId, [string]$Token, [string]$Mode, [string]$Environment, [string]$CollaborationMode, [switch]$PlanOnly)
$items = @()
foreach ($w in @("ALEX", "MAYA")) {
    # STUB_DEGRADED_WORKER=MAYA : ce Worker n'a eu que la reponse de repli (fournisseur d'IA indisponible) ; STUB_BLOCKED_WORKER : refuse par la securite.
    $degraded = ($env:STUB_DEGRADED_WORKER -eq $w)
    $st = if ($env:STUB_BLOCKED_WORKER -eq $w) { "BLOCKED" } else { "SUCCESS" }
    $items += [pscustomobject]@{ TaskId = ("TASK-" + $w.PadRight(32, "C")); Worker = $w; Status = $st; Result = [pscustomobject]@{ Status = $st; Answer = "ok"; Degraded = $degraded } }
}
[pscustomobject]@{ Status = "SUCCESS"; SelectedWorkers = @("alex", "maya"); Results = $items; FinalSynthesis = "ok" }
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
    if rel == "dashboard":
        skip.add(".gate")
    return skip


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f)


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class AutomationLevel(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="bkautolevel-")
        cls.addClassCleanup(shutil.rmtree, cls.tmp, True)
        cls.root = os.path.join(cls.tmp, "app")
        shutil.copytree(REPO, cls.root, ignore=ignore)
        for rel, text in (("core/runtime/worker-runtime/Invoke-Worker-AI.ps1", WORKER_STUB), ("chloe/Invoke-Chloe-Orchestration.ps1", CHLOE_STUB)):
            with open(os.path.join(cls.root, rel), "w", encoding="utf-8-sig") as f:
                f.write(text)

    def setUp(self):
        shutil.rmtree(os.path.join(self.root, "runtime"), ignore_errors=True)
        for sub in ("core/billing/data", "core/automation/data", "core/accounts/data"):
            shutil.rmtree(os.path.join(self.root, sub), ignore_errors=True)
        write_json(os.path.join(self.root, "core", "billing", "data", A + ".json"),
                   {"planId": "solo", "cycleStartUtc": "2026-10-01T00:00:00Z", "extraCredits": 0, "history": [], "hiredWorkers": ["alex"]})

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k not in ("BK_SECRETS_DIR", "BK_LEVELS", "BK_MISSION_LEVEL", "BK_ALLOWED_WORKERS", "BK_MAX_WORKERS")}
        env.update(BK_ROOT=self.root, BK_PYTHON=sys.executable, PYTHONIOENCODING="utf-8", BK_PWSH=PWSH)
        env.update(extra)
        return env

    def tasks(self):
        out = []
        for p in sorted(glob.glob(os.path.join(self.root, "runtime", "tasks", "TASK-*.json"))):
            with open(p, encoding="utf-8-sig") as f:
                out.append(json.load(f))
        return out

    def quota(self, *args, **extra):
        p = subprocess.run([sys.executable, os.path.join(self.root, "dashboard", "quota-check.py"), *args], capture_output=True, text=True, encoding="utf-8",
                           errors="replace", env=self.env(**extra), timeout=120, cwd=self.root)
        lines = [l for l in p.stdout.splitlines() if l.strip().startswith("{")]
        self.assertTrue(lines, p.stdout + p.stderr)
        return json.loads(lines[-1])

    def run_automation(self, worker="alex", **extra):
        autos = os.path.join(self.root, "core", "automation", "data", "automations.json")
        write_json(autos, [{"id": "AUTO-TEST000001", "clientId": A, "workerId": worker, "objective": "Rapport hebdomadaire", "frequencyMinutes": 60, "enabled": True,
                            "notifySlack": False, "createdAtUtc": "2026-10-01T00:00:00.0000000Z", "lastRunAtUtc": None, "lastRunStatus": None,
                            "nextRunAtUtc": "2026-10-01T00:00:00.0000000Z", "runCount": 0}])
        out_file = os.path.join(self.tmp, "bridge-out.json")
        if os.path.exists(out_file):
            os.remove(out_file)
        p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", os.path.join(self.root, "dashboard", "Automation-Bridge.ps1"), "-Action", "run",
                            "-Id", "AUTO-TEST000001", "-ClientId", A, "-OutFile", out_file],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", env=self.env(**extra), timeout=600, cwd=self.root)
        self.assertTrue(os.path.isfile(out_file), p.stdout[-500:] + p.stderr[-500:])
        with open(out_file, encoding="utf-8-sig") as f:
            return json.load(f), p

    def submit(self, worker, **extra):
        out_file = os.path.join(self.tmp, "submit-out.json")
        if os.path.exists(out_file):
            os.remove(out_file)
        p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", os.path.join(self.root, "dashboard", "Submit-Task.ps1"), "-Request", "Prepare un resume",
                            "-WorkerId", worker, "-ClientId", A, "-OutFile", out_file],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", env=self.env(**extra), timeout=600, cwd=self.root)
        self.assertTrue(os.path.isfile(out_file), p.stdout[-500:] + p.stderr[-500:])
        return p

    # ------------------------------------------------------------------------------------------------------ quota-check
    def test_quota_check_gives_automations_the_rapide_level_and_a_one_credit_quota(self):
        write_json(os.path.join(self.root, "runtime", "tasks", "TASK-" + "1" * 32 + ".json"),
                   {"TaskId": "TASK-" + "1" * 32, "ClientId": A, "Credits": 249, "CreatedAtUtc": "2999-01-01T00:00:00Z"})      # reste 1 credit sur 250
        v = self.quota(A, "alex", "scheduled")
        self.assertEqual((v["blocked"], v["level"], v["allowedWorkers"]), (False, "rapide", "alex"))
        write_json(os.path.join(self.root, "runtime", "tasks", "TASK-" + "2" * 32 + ".json"),
                   {"TaskId": "TASK-" + "2" * 32, "ClientId": A, "Credits": 1, "CreatedAtUtc": "2999-01-01T00:00:01Z"})        # plus rien
        v = self.quota(A, "alex", "scheduled")
        self.assertEqual((v["blocked"], v["code"]), (True, "QUOTA_EXCEEDED"))
        self.assertIn("passez au forfait Trio", v["detail"])
        self.assertIn("renouvelés le", v["detail"])

    def test_quota_check_without_levels_keeps_the_old_behaviour(self):
        v = self.quota(A, "alex", "scheduled", BK_LEVELS="0")
        self.assertEqual((v["blocked"], v["level"]), (False, ""))

    def test_the_owner_automations_also_run_at_rapide(self):
        v = self.quota("CLI-DASHBOARD", "alex", "scheduled")
        self.assertEqual((v["blocked"], v["level"]), (False, "rapide"))

    # ------------------------------------------------------------------------------------------------------ moteur + Submit-Task
    def test_the_engine_runs_an_automation_at_rapide_and_charges_one_credit(self):
        res, p = self.run_automation()
        tasks = self.tasks()
        self.assertEqual(len(tasks), 1, p.stdout[-400:] + p.stderr[-400:])
        self.assertEqual((tasks[0]["Level"], tasks[0]["Credits"], tasks[0]["ClientId"]), ("rapide", 1, A))
        self.assertEqual(tasks[0]["Result"]["LevelSeen"], "rapide")             # le Worker a vraiment tourne au niveau Rapide
        self.assertEqual(res["status"], "EXECUTED")

    def test_without_levels_the_automation_keeps_the_legacy_one_credit_mission(self):
        res, p = self.run_automation(BK_LEVELS="0")
        tasks = self.tasks()
        self.assertEqual(len(tasks), 1, p.stdout[-400:] + p.stderr[-400:])
        self.assertEqual((tasks[0]["Level"], tasks[0]["Credits"]), ("", 1))
        self.assertEqual(tasks[0]["Result"]["LevelSeen"], "")

    def test_an_inherited_mission_level_never_leaks_into_an_automation(self):
        res, p = self.run_automation(BK_MISSION_LEVEL="approfondi")             # meme si le processus appelant porte un autre niveau
        tasks = self.tasks()
        self.assertEqual((tasks[0]["Level"], tasks[0]["Credits"]), ("rapide", 1), p.stdout[-300:] + p.stderr[-300:])

    def test_a_mission_is_charged_at_the_credit_cost_of_its_level(self):
        for level, credits in (("equilibre", 6), ("approfondi", 12), ("rapide", 1)):
            shutil.rmtree(os.path.join(self.root, "runtime", "tasks"), ignore_errors=True)
            p = self.submit("alex", BK_MISSION_LEVEL=level, BK_ALLOWED_WORKERS="alex")
            tasks = self.tasks()
            self.assertEqual(len(tasks), 1, p.stdout[-300:] + p.stderr[-300:])
            self.assertEqual((tasks[0]["Level"], tasks[0]["Credits"]), (level, credits))

    def test_each_worker_called_by_chloe_is_charged_at_the_mission_level(self):
        p = self.submit("chloe", BK_MISSION_LEVEL="equilibre")
        tasks = self.tasks()
        self.assertEqual([(t["Worker"], t["Level"], t["Credits"]) for t in tasks], [("ALEX", "equilibre", 6), ("MAYA", "equilibre", 6)], p.stdout[-300:] + p.stderr[-300:])
        shutil.rmtree(os.path.join(self.root, "runtime", "tasks"), ignore_errors=True)
        self.submit("chloe")                                                    # sans niveau (BK_LEVELS=0) : ancien comportement, 1 credit par Worker
        self.assertEqual([(t["Level"], t["Credits"]) for t in self.tasks()], [("", 1), ("", 1)])

    def test_a_provider_outage_or_a_refused_mission_is_recorded_without_credits(self):
        # Revue du 2026-10-13 : toute trace portait le cout du niveau, meme quand le fournisseur d'IA etait indisponible (reponse de repli) ou que la
        # mission avait ete refusee : 6 ou 12 credits pour rien. Seule une mission livree coute son niveau.
        self.submit("alex", BK_MISSION_LEVEL="equilibre", BK_ALLOWED_WORKERS="alex", STUB_DEGRADED="1")
        task = self.tasks()[0]
        self.assertEqual((task["Status"], task["Level"], task["Credits"], task["Result"]["Degraded"]), ("EXECUTED", "equilibre", 0, True))
        shutil.rmtree(os.path.join(self.root, "runtime", "tasks"), ignore_errors=True)
        self.submit("alex", BK_MISSION_LEVEL="approfondi", BK_ALLOWED_WORKERS="alex", STUB_STATUS="BLOCKED")
        task = self.tasks()[0]
        self.assertEqual((task["Status"], task["Authorized"], task["Credits"]), ("SECURITY_BLOCKED", False, 0))
        shutil.rmtree(os.path.join(self.root, "runtime", "tasks"), ignore_errors=True)
        self.submit("alex", BK_MISSION_LEVEL="equilibre", BK_ALLOWED_WORKERS="alex")                      # une mission livree : le cout normal
        self.assertEqual(self.tasks()[0]["Credits"], 6)

    def test_chloe_records_zero_credits_for_a_worker_that_was_degraded_or_refused(self):
        self.submit("chloe", BK_MISSION_LEVEL="equilibre", STUB_DEGRADED_WORKER="MAYA")
        self.assertEqual([(t["Worker"], t["Credits"]) for t in self.tasks()], [("ALEX", 6), ("MAYA", 0)])
        shutil.rmtree(os.path.join(self.root, "runtime", "tasks"), ignore_errors=True)
        self.submit("chloe", BK_MISSION_LEVEL="approfondi", STUB_BLOCKED_WORKER="ALEX")
        self.assertEqual([(t["Worker"], t["Status"], t["Credits"]) for t in self.tasks()], [("ALEX", "SECURITY_BLOCKED", 0), ("MAYA", "EXECUTED", 12)])

    def test_the_server_counts_those_traces_as_zero_credits(self):
        # le meme calcul que get_billing : les traces d'une panne du fournisseur ne consomment pas le quota
        self.submit("alex", BK_MISSION_LEVEL="equilibre", BK_ALLOWED_WORKERS="alex", STUB_DEGRADED="1")
        self.submit("alex", BK_MISSION_LEVEL="equilibre", BK_ALLOWED_WORKERS="alex")
        srv, _ = load_server("bk_server_credits_probe")                       # la fonction de calcul du serveur, appliquee aux traces ecrites par Submit-Task.ps1
        self.assertEqual(sorted(srv.task_credits(t) for t in self.tasks()), [0, 6])       # l'ordre des fichiers est aleatoire (identifiants de tache)

    # ------------------------------------------------------------------------------------------------------ plafond de Workers pour Chloe, pause
    def test_quota_check_caps_the_workers_chloe_can_call_with_the_remaining_credits(self):
        write_json(os.path.join(self.root, "core", "billing", "data", A + ".json"),
                   {"planId": "trio", "gridVersion": 2, "cycleStartUtc": "2026-10-01T00:00:00Z", "extraCredits": 0, "history": [], "hiredWorkers": ["alex", "maya"]})
        write_json(os.path.join(self.root, "runtime", "tasks", "TASK-" + "3" * 32 + ".json"),
                   {"TaskId": "TASK-" + "3" * 32, "ClientId": A, "Credits": 497, "CreatedAtUtc": "2999-01-01T00:00:00Z", "Status": "EXECUTED"})      # reste 3 credits sur 500
        v = self.quota(A, "chloe", "scheduled")
        self.assertEqual((v["blocked"], v["level"], v["maxWorkers"]), (False, "rapide", 3))               # une automatisation = niveau Rapide, 1 credit par Worker
        self.assertNotIn("maxWorkers", self.quota(A, "alex", "scheduled"))                               # un Worker seul n'appelle personne d'autre
        self.assertEqual(self.quota("CLI-DASHBOARD", "chloe", "scheduled").get("maxWorkers"), None)       # le proprietaire n'a pas de quota

    def test_the_engine_hands_the_cap_to_chloe(self):
        write_json(os.path.join(self.root, "core", "billing", "data", A + ".json"),
                   {"planId": "trio", "gridVersion": 2, "cycleStartUtc": "2026-10-01T00:00:00Z", "extraCredits": 0, "history": [], "hiredWorkers": ["alex", "maya"]})
        write_json(os.path.join(self.root, "runtime", "tasks", "TASK-" + "4" * 32 + ".json"),
                   {"TaskId": "TASK-" + "4" * 32, "ClientId": A, "Credits": 499, "CreatedAtUtc": "2999-01-01T00:00:00Z", "Status": "EXECUTED"})      # reste 1 credit
        # le faux Chloe de ce test ecrit la valeur qu'il a recue dans son resultat
        with open(os.path.join(self.root, "chloe", "Invoke-Chloe-Orchestration.ps1"), "w", encoding="utf-8-sig") as f:
            f.write(CHLOE_STUB.replace('FinalSynthesis = "ok" }', 'FinalSynthesis = ("cap=" + [string]$env:BK_MAX_WORKERS) }'))
        res, p = self.run_automation(worker="chloe")
        self.assertEqual(res["status"], "SUCCESS", p.stdout[-300:] + p.stderr[-300:])
        run_files = glob.glob(os.path.join(self.root, "core", "automation", "data", "runs", "AUTO-TEST000001", "run-*.json"))
        self.assertEqual(len(run_files), 1)
        with open(run_files[0], encoding="utf-8-sig") as f:
            self.assertEqual(json.load(f)["detail"]["FinalSynthesis"], "cap=1")

    def test_pausing_a_worker_also_stops_chloe_from_calling_it_on_schedule(self):
        # Revue du 2026-10-13 : seul le Worker de l'automatisation etait verifie ; une automatisation de Chloe continuait d'appeler le Worker en pause.
        write_json(os.path.join(self.root, "core", "billing", "data", A + ".json"),
                   {"planId": "trio", "gridVersion": 2, "cycleStartUtc": "2026-10-01T00:00:00Z", "extraCredits": 0, "history": [], "hiredWorkers": ["alex", "maya", "nora"]})
        for wid, status in (("ALEX", "paused"), ("MAYA", "active")):
            write_json(os.path.join(self.root, "runtime", "installations", A, wid + ".json"),
                       {"workerId": wid.lower(), "clientId": A, "status": status, "services": {}, "notes": ""})
        v = self.quota(A, "chloe", "scheduled")
        self.assertEqual((v["blocked"], sorted(v["allowedWorkers"].split(","))), (False, ["maya", "nora"]))
        self.assertEqual(self.quota(A, "alex", "scheduled")["code"], "INSTALLATION_PAUSED")               # le Worker en pause lui-meme : toujours bloque
        manual = self.quota(A, "chloe", "manual")                                                         # « Executer maintenant » reste manuel : aucun retrait
        self.assertEqual(sorted(manual["allowedWorkers"].split(",")), ["alex", "maya", "nora"])
        for wid in ("MAYA", "NORA"):
            write_json(os.path.join(self.root, "runtime", "installations", A, wid + ".json"),
                       {"workerId": wid.lower(), "clientId": A, "status": "paused", "services": {}, "notes": ""})
        v = self.quota(A, "chloe", "scheduled")                                                           # tous les Workers sont en pause
        self.assertEqual((v["blocked"], v["code"]), (True, "INSTALLATION_PAUSED"))

    def test_pausing_a_worker_on_an_unrestricted_plan_gives_chloe_the_explicit_list_of_the_others(self):
        write_json(os.path.join(self.root, "core", "billing", "data", A + ".json"),
                   {"planId": "pro", "gridVersion": 2, "cycleStartUtc": "2026-10-01T00:00:00Z", "extraCredits": 0, "history": []})
        self.assertIsNone(self.quota(A, "chloe", "scheduled")["allowedWorkers"])                          # rien en pause : tous les Workers, comme avant
        write_json(os.path.join(self.root, "runtime", "installations", A, "ALEX.json"),
                   {"workerId": "alex", "clientId": A, "status": "paused", "services": {}, "notes": ""})
        allowed = self.quota(A, "chloe", "scheduled")["allowedWorkers"].split(",")
        self.assertNotIn("alex", allowed)
        self.assertIn("maya", allowed)


if __name__ == "__main__":
    ok = unittest.main(verbosity=2, exit=False).result.wasSuccessful()
    sys.exit(0 if ok else 1)
