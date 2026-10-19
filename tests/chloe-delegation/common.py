"""Outils communs des tests de la delegation de Chloe (chloe/Invoke-Chloe-Orchestration.ps1 et ses modules).

PowerShell 7 requis (pwsh ; sous Windows, lancer dans WSL : wsl -e python3 tests/chloe-delegation/test_*.py). Aucun reseau, aucun cout, aucun vrai secret :
  - l'API Anthropic est simulee par tests/adapter-review/fake_api.ps1 (cassette de reponses dans l'ordre des appels) ;
  - les Workers sont simules par tests/chloe-delegation/stub_worker.ps1 (a la place de core/runtime/worker-runtime/Invoke-Worker-AI.ps1) ;
  - tout se passe dans une COPIE jetable du depot (jamais le depot), supprimee a la fin.
"""
import json
import os
import shutil
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
FAKE_KEY = "FAKE-ANTHROPIC-KEY-FOR-TESTS-ONLY"
CLIENT = "CLI-CUST-AAAAAAAA"

COPY_FILES = (
    "chloe/Invoke-Chloe-Orchestration.ps1", "chloe/Chloe-Common.ps1", "chloe/Chloe-Router.ps1", "chloe/Chloe-Executor.ps1",
    "chloe/Chloe-Consolidate.ps1", "chloe/Chloe-Consistency.ps1", "chloe/Invoke-Chloe-WorkerCall.ps1", "chloe/prompts/consistency-review.md",
    "orchestrator/worker-routing.json", "core/ai/Get-DefaultProvider.ps1", "core/ai/BK-Secret.ps1", "core/ai/AI-PROVIDERS.json",
    "core/ai/AI-PRICING.json", "core/ai/LEVELS.json", "core/ai/adapters/Mission-Cost.ps1", "core/projects/WORKER-CARDS.json",
)

DRIVER = r'''
$ErrorActionPreference = "Stop"
if ($env:T_USE_FAKE_API -eq "1") { . (Join-Path $env:BK_ROOT "_test/fake_api.ps1") }
$a = @{ Request = $env:T_REQUEST; TenantId = "T"; ClientId = $env:T_CLIENT; ProjectId = "P"; ExecutionId = "EXEC-1"; UserId = "U"; SessionId = "S"; TokenId = "K"; Token = "tok-secret-not-in-files" }
if ($env:T_COLLAB) { $a["CollaborationMode"] = $env:T_COLLAB }
if ($env:T_PLAN -eq "1") { $a["PlanOnly"] = $true }
if ($env:T_EMIT -eq "1") { $a["EmitPlan"] = $true }
$r = & (Join-Path $env:BK_ROOT "chloe/Invoke-Chloe-Orchestration.ps1") @a
$r | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $env:OUT_FILE -Encoding utf8
'''


def as_list(value):
    """ConvertTo-Json de PowerShell rend une liste d'un seul element sous forme de valeur seule, une liste vide sous forme null."""
    return [] if value is None else (value if isinstance(value, list) else [value])


def text_block(text):
    return {"type": "text", "text": text}


def usage(i=3000, o=300):
    return {"input_tokens": i, "output_tokens": o}


def route_response(plan, name="submit_route_plan"):
    """Reponse de l'API : le modele appelle l'outil de routage avec ce plan."""
    return {"body": {"id": "msg_r", "type": "message", "role": "assistant", "model": "claude-haiku-5-5", "stop_reason": "tool_use", "usage": usage(),
                     "content": [{"type": "tool_use", "id": "toolu_1", "name": name, "input": plan}]}}


def text_response(text):
    return {"body": {"id": "msg_t", "type": "message", "role": "assistant", "model": "claude-haiku-5-5", "stop_reason": "end_turn", "usage": usage(),
                     "content": [text_block(text)]}}


def task(tid, worker, objective=None, deps=(), public=False, why=""):
    return {"id": tid, "worker": worker, "objective": objective or f"Objectif de {worker} pour la demande du client.", "why": why or "test",
            "dependsOn": list(deps), "publicFacing": public}


def plan(*tasks, mode="mission", consistency=False, **extra):
    out = {"mode": mode, "language": "fr", "why": "test", "consistencyCheck": consistency, "subtasks": list(tasks)}
    out.update(extra)
    return out


class Chloe:
    """Une mission de Chloe dans une copie jetable du depot. `cassette` = reponses de l'API simulee (None : pas d'API simulee, pas de cle)."""

    def __init__(self, request, cassette=None, stub=None, env=None, collab=None, plan_only=False, emit=False, hold=False):
        self.root = tempfile.mkdtemp(prefix="bkchloe-")
        for rel in COPY_FILES:
            dst = os.path.join(self.root, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(os.path.join(REPO, rel), dst)
        os.makedirs(os.path.join(self.root, "_test"), exist_ok=True)
        shutil.copy2(os.path.join(REPO, "tests", "adapter-review", "fake_api.ps1"), os.path.join(self.root, "_test", "fake_api.ps1"))
        stub_dst = os.path.join(self.root, "core", "runtime", "worker-runtime", "Invoke-Worker-AI.ps1")
        os.makedirs(os.path.dirname(stub_dst), exist_ok=True)
        shutil.copy2(os.path.join(HERE, "stub_worker.ps1"), stub_dst)
        self.stub_dir = os.path.join(self.root, "_test", "stub")
        os.makedirs(self.stub_dir, exist_ok=True)
        self.stub_log = os.path.join(self.stub_dir, "calls.jsonl")
        self.out_file = os.path.join(self.root, "_test", "out.json")
        self.api_log = os.path.join(self.root, "_test", "requests.jsonl")
        stub_cfg = os.path.join(self.stub_dir, "config.json")
        with open(stub_cfg, "w", encoding="utf-8") as f:
            json.dump(stub or {"default": {"answer": "Reponse de {worker}"}}, f)
        driver = os.path.join(self.root, "_test", "driver.ps1")
        with open(driver, "w", encoding="utf-8") as f:
            f.write(DRIVER)
        self.driver = driver
        base = {k: v for k, v in os.environ.items() if not k.startswith("BK_") and not k.startswith("FAKE_") and not k.startswith("STUB_")}
        self.env = dict(base, BK_ROOT=self.root, OUT_FILE=self.out_file, STUB_CONFIG=stub_cfg, STUB_LOG=self.stub_log, STUB_DIR=self.stub_dir,
                        T_REQUEST=request, T_CLIENT=CLIENT, BK_REPLY_LANG="", T_COLLAB=collab or "", T_PLAN="1" if plan_only else "0",
                        T_EMIT="1" if emit else "0", BK_CHLOE_TAIL_SEC="3")
        if cassette is not None:
            cassette_path = os.path.join(self.root, "_test", "cassette.json")
            with open(cassette_path, "w", encoding="utf-8") as f:
                json.dump({"responses": cassette}, f)
            self.env.update(T_USE_FAKE_API="1", FAKE_CASSETTE=cassette_path, FAKE_LOG=self.api_log, FAKE_KEY=FAKE_KEY, BK_SECRET_ANTHROPIC=FAKE_KEY)
        self.env.update(env or {})
        self.proc = None
        self.result = None
        if not hold:
            self.run()

    def spawn(self):
        return subprocess.Popen([PWSH, "-NoProfile", "-NonInteractive", "-File", self.driver], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, encoding="utf-8", errors="replace", env=self.env, cwd=self.root)

    def run(self):
        p = self.spawn()
        out, err = p.communicate(timeout=420)
        self.collect(out, err)

    def collect(self, out="", err=""):
        self.stdout, self.stderr = out, err
        assert os.path.isfile(self.out_file), f"the orchestration wrote nothing\nSTDOUT:\n{out}\nSTDERR:\n{err}"
        with open(self.out_file, encoding="utf-8-sig") as f:
            self.result = json.load(f)

    # ---- journaux
    def stub_events(self):
        if not os.path.isfile(self.stub_log):
            return []
        with open(self.stub_log, encoding="utf-8-sig") as f:
            return [json.loads(line) for line in f if line.strip()]

    def starts(self):
        return [e for e in self.stub_events() if e["event"] == "start"]

    def called(self):
        """Workers appeles, dans l'ordre de demarrage."""
        return [e["worker"] for e in sorted(self.starts(), key=lambda e: e["t"])]

    def start_of(self, worker, attempt=1):
        return next(e for e in self.starts() if e["worker"] == worker and e["attempt"] == attempt)

    def end_of(self, worker, attempt=1):
        return next(e for e in self.stub_events() if e["event"] == "end" and e["worker"] == worker and e["attempt"] == attempt)

    def api_requests(self):
        if not os.path.isfile(self.api_log):
            return []
        with open(self.api_log, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]

    def messages(self):
        return [r for r in self.api_requests() if r["kind"] == "messages"]

    def results_by_worker(self):
        return {r["Worker"]: r for r in as_list(self.result.get("Results"))}

    def section(self, worker):
        return next(s for s in as_list(self.result.get("Sections")) if s["worker"] == worker)

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)
