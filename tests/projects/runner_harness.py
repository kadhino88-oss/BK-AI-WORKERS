"""Banc d'essai du lanceur d'etape de projet (core/ai/adapters/Project-StepRunner.ps1) avec la fausse API tests/projects/fake_api.ps1.

PowerShell 7 requis (pwsh) ; sous Windows on lance ces tests dans WSL (python3 + pwsh). Aucun reseau, aucun cout, aucune vraie cle.
Une execution = une copie jetable du depot (core/, dashboard/*.py, identites des Workers) dans un dossier temporaire, un projet minimal sur disque,
un input.json, puis `pwsh -File driver.ps1` qui charge la fausse API et lance le lanceur. Les tests lisent result.json, cost.json, le spool et le
journal des requetes (requests.jsonl)."""
import atexit
import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
FAKE_KEY = "FAKE-ANTHROPIC-KEY-FOR-TESTS-ONLY"
CLIENT = "CLI-CUST-AAAAAAAA"
PROJECT = "PRJ-" + "A1" * 16

DRIVER = r'''
$ErrorActionPreference = "Stop"
. (Join-Path $env:BK_ROOT "_test/fake_api.ps1")
& (Join-Path $env:BK_ROOT "core/ai/adapters/Project-StepRunner.ps1") -InFile $env:T_IN -OutFile $env:T_OUT
$Exit = $LASTEXITCODE
[ordered]@{ exit = $Exit } | ConvertTo-Json | Set-Content -LiteralPath $env:EXIT_FILE -Encoding utf8
'''


def usage(i=1000, o=100, cache_write=None, cache_read=None, web=None):
    u = {"input_tokens": i, "output_tokens": o}
    if cache_write is not None or cache_read is not None:
        u["cache_creation_input_tokens"] = cache_write or 0
        u["cache_read_input_tokens"] = cache_read or 0
    if web is not None:
        u["server_tool_use"] = {"web_search_requests": web}
    return u


def text(t):
    return {"type": "text", "text": t}


def tu(i, name, inp):
    return {"type": "tool_use", "id": f"toolu_{i}", "name": name, "input": inp}


def msg(content, stop="end_turn", u=None, container=None):
    body = {"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-sonnet-5-5", "content": content, "stop_reason": stop,
            "usage": u or usage()}
    if container:
        body["container"] = {"id": container, "expires_at": "2099-01-01T00:00:00Z"}
    return {"body": body}


def code_result(*file_ids):
    return {"type": "bash_code_execution_tool_result", "tool_use_id": "srvtoolu_1",
            "content": {"type": "bash_code_execution_result", "stdout": "", "stderr": "", "return_code": 0,
                        "content": [{"type": "bash_code_execution_output", "file_id": fid} for fid in file_ids]}}


def complete(i=9, status="DONE", summary="Fait.", **extra):
    inp = {"status": status, "summary": summary}
    inp.update(extra)
    return tu(i, "step_complete", inp)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


_TEMPLATE = {"dir": None}


def _template():
    """Dossier modele (copie une fois par processus de test) : ce que le lanceur lit (core/ai, integrations, projects, connectors, State-Lock),
    les modules Python de dashboard/ et les identites de quelques Workers."""
    if _TEMPLATE["dir"] and os.path.isdir(_TEMPLATE["dir"]):
        return _TEMPLATE["dir"]
    d = tempfile.mkdtemp(prefix="bkproj-tpl-")
    shutil.rmtree(d)
    for part in ("ai", "integrations", "projects", "connectors"):
        shutil.copytree(os.path.join(REPO, "core", part), os.path.join(d, "core", part),
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "site", "client-credentials", "data"))
    os.makedirs(os.path.join(d, "core", "runtime"), exist_ok=True)
    shutil.copy2(os.path.join(REPO, "core", "runtime", "State-Lock.ps1"), os.path.join(d, "core", "runtime", "State-Lock.ps1"))
    os.makedirs(os.path.join(d, "dashboard"), exist_ok=True)
    for n in os.listdir(os.path.join(REPO, "dashboard")):
        if n.endswith(".py"):
            shutil.copy2(os.path.join(REPO, "dashboard", n), os.path.join(d, "dashboard", n))
    _TEMPLATE["dir"] = d
    atexit.register(lambda: shutil.rmtree(d, ignore_errors=True))
    return d


class StepRun:
    """Une execution du lanceur. Parametres utiles : kind, worker, tools, cassette, files (Files API), env, activated (connecteurs),
    auto_approve, soft_s / hard_s (echeances relatives, secondes), max_iterations, ceiling, input_files, workspace (fichiers prepares)."""

    def __init__(self, cassette, kind="execute", worker="lucas", tools=None, server_tools=None, files=None, env=None, activated=(), auto_approve=False,
                 soft_s=400, hard_s=460, max_iterations=24, ceiling=0.8, workspace=None, input_files=None, context="## 8. Etape\nObjectif : tester.\n",
                 attempt=1, step_id="S1", model="claude-sonnet-5-5", effort="medium", web_max=8, recipe="", key=True, bad_input=False, language="French",
                 plan_md=None):
        import project_tools
        self.root = tempfile.mkdtemp(prefix="bkproj-")
        shutil.rmtree(self.root)
        shutil.copytree(_template(), self.root)                  # modele copie UNE fois (la lecture de /mnt/c sous WSL est lente)
        for w in {worker, "chloe", "lucas", "emma"}:
            src = os.path.join(REPO, "chloe" if w == "chloe" else os.path.join("workers", w), "identity")
            dst = os.path.join(self.root, "chloe" if w == "chloe" else os.path.join("workers", w), "identity")
            if os.path.isdir(src) and not os.path.isdir(dst):
                shutil.copytree(src, dst)
        for sub in ("_test", "runtime/tasks", "core/connectors/data", "memory/runtime"):
            os.makedirs(os.path.join(self.root, sub), exist_ok=True)
        shutil.copy2(os.path.join(HERE, "fake_api.ps1"), os.path.join(self.root, "_test", "fake_api.ps1"))
        if plan_md is not None:
            os.makedirs(os.path.join(self.root, "chloe", "prompts"), exist_ok=True)
            with open(os.path.join(self.root, "chloe", "prompts", "plan.md"), "w", encoding="utf-8") as f:
                f.write(plan_md)
        with open(os.path.join(self.root, "core/connectors/data", CLIENT + ".json"), "w", encoding="utf-8") as f:
            json.dump(list(activated), f)
        # projet minimal sur disque
        self.project_dir = os.path.join(self.root, "runtime", "projects", CLIENT, PROJECT)
        for sub in ("workspace/inputs", "workspace/handoff", "workspace/deliverables", "spool", f"steps/{step_id}/{attempt}", "verification"):
            os.makedirs(os.path.join(self.project_dir, *sub.split("/")), exist_ok=True)
        self.step_dir = os.path.join(self.project_dir, "steps", step_id, str(attempt))
        self.workspace = os.path.join(self.project_dir, "workspace")
        self.spool = os.path.join(self.project_dir, "spool")
        state = {"projectId": PROJECT, "clientId": CLIENT, "status": "RUNNING", "goal": "Tester", "steps": {step_id: {"id": step_id, "kind": kind, "status": "RUNNING"}},
                 "scope": {"chloe": True, "allowedWorkers": ["lucas", "emma", "lea"]}, "counters": {}}
        with open(os.path.join(self.project_dir, "state.json"), "w", encoding="utf-8") as f:
            json.dump(state, f)
        with open(os.path.join(self.project_dir, "limits.json"), "w", encoding="utf-8") as f:
            json.dump({"workspaceMb": 100, "approvalTtlDays": 7, "planLimits": {}}, f)
        for rel, content in (workspace or {}).items():
            full = os.path.join(self.workspace, *rel.split("/"))
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "wb") as f:
                f.write(content if isinstance(content, bytes) else content.encode("utf-8"))
        ctx = os.path.join(self.step_dir, "context.md")
        with open(ctx, "w", encoding="utf-8") as f:
            f.write(context)
        now = datetime.datetime.now(datetime.timezone.utc)
        if tools is None:
            tools = list(project_tools.TOOLS_BY_KIND[kind])
            if kind in ("plan", "replan", "execute", "fix", "consolidate"):
                tools.append("memory")
            if activated and kind in ("execute", "fix"):
                tools.append("use_connector")
        if server_tools is None:
            server_tools = {"plan": ["web_search", "web_fetch"], "replan": ["web_search", "web_fetch"], "execute": ["web_search", "web_fetch", "code_execution"],
                            "fix": ["web_search", "web_fetch", "code_execution"], "verify": ["web_fetch"]}.get(kind, [])
        self.input = {
            "schema": "BK-STEP-INPUT-V1", "projectId": PROJECT, "clientId": CLIENT, "stepId": step_id, "attempt": attempt, "kind": kind, "worker": worker,
            "phase": "execute", "model": model, "effort": effort, "maxIterations": max_iterations, "webMaxUses": web_max, "callTimeoutSec": 300, "ceilingChf": ceiling,
            "deadlineUtc": iso(now + datetime.timedelta(seconds=soft_s)), "hardDeadlineUtc": iso(now + datetime.timedelta(seconds=hard_s)),
            "paths": {"projectDir": self.project_dir, "workspace": self.workspace, "stepDir": self.step_dir, "spool": self.spool, "context": ctx},
            "tools": tools, "serverTools": server_tools, "connectors": list(activated), "inputFiles": input_files or [], "recipeBlock": recipe, "resumeNote": None,
            "contextShrink": False, "language": language, "autoApproveSafeOps": auto_approve, "installationPaused": False, "round": 1 if kind == "verify" else None}
        if kind == "verify":
            with open(os.path.join(self.step_dir, "verify.json"), "w", encoding="utf-8") as f:
                json.dump({"round": 1}, f)
        if bad_input:
            self.input["schema"] = "NOPE"
        self.in_file = os.path.join(self.step_dir, "input.json")
        self.out_file = os.path.join(self.step_dir, "result.json")
        with open(self.in_file, "w", encoding="utf-8") as f:
            json.dump(self.input, f)
        self.cassette_path = os.path.join(self.root, "_test", "cassette.json")
        with open(self.cassette_path, "w", encoding="utf-8") as f:
            json.dump({"responses": cassette}, f)
        self.driver = os.path.join(self.root, "_test", "driver.ps1")
        with open(self.driver, "w", encoding="utf-8") as f:
            f.write(DRIVER)
        self.exit_file = os.path.join(self.root, "_test", "exit.json")
        self.log_file = os.path.join(self.root, "_test", "requests.jsonl")
        self.env = dict(os.environ, BK_ROOT=self.root, BK_PYTHON=sys.executable, T_IN=self.in_file, T_OUT=self.out_file, EXIT_FILE=self.exit_file,
                        FAKE_CASSETTE=self.cassette_path, FAKE_LOG=self.log_file, FAKE_KEY=FAKE_KEY, BK_PROJECT_BACKOFF_SCALE="0.001", BK_REPLY_LANG="")
        if key:
            self.env["BK_SECRET_ANTHROPIC"] = FAKE_KEY
        else:
            self.env.pop("BK_SECRET_ANTHROPIC", None)
            self.env["BK_SECRETS_DIR"] = os.path.join(self.root, "nokeys")
        if files:
            self.env["FAKE_FILES"] = json.dumps(files)
        self.env.update(env or {})
        self.proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", self.driver], capture_output=True, text=True, encoding="utf-8",
                                   errors="replace", env=self.env, timeout=300, cwd=self.root)
        assert os.path.isfile(self.exit_file), f"driver produced nothing\nSTDOUT:\n{self.proc.stdout}\nSTDERR:\n{self.proc.stderr}"
        with open(self.exit_file, encoding="utf-8-sig") as f:
            self.exit = json.load(f)["exit"]
        self.result = None
        if os.path.isfile(self.out_file):
            with open(self.out_file, encoding="utf-8-sig") as f:
                self.result = json.load(f)
        self.log = []
        if os.path.isfile(self.log_file):
            with open(self.log_file, encoding="utf-8") as f:
                self.log = [json.loads(line) for line in f if line.strip()]

    # ---- accesseurs
    def of_kind(self, kind):
        return [r for r in self.log if r["kind"] == kind]

    def calls(self):
        return self.of_kind("messages")

    def cost(self):
        with open(os.path.join(self.step_dir, "cost.json"), encoding="utf-8-sig") as f:
            return json.load(f)

    def spool_rows(self, name):
        rows = []
        p = os.path.join(self.spool, f"{name}-{self.input['stepId']}.jsonl")
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as f:
                rows = [json.loads(line) for line in f if line.strip()]
        return rows

    def ws(self, rel):
        return os.path.join(self.workspace, *rel.split("/"))

    def read_ws(self, rel):
        with open(self.ws(rel), encoding="utf-8") as f:
            return f.read()

    def runner_log(self):
        p = os.path.join(self.step_dir, "runner.log")
        if not os.path.isfile(p):
            return ""
        with open(p, encoding="utf-8") as f:
            return f.read()

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)
