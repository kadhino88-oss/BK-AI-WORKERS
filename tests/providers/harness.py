# -*- coding: utf-8 -*-
"""Outils communs des tests PowerShell du dossier providers : racine jetable (copie de core/ et des fichiers Python utiles), pilote qui lance un
script (adaptateur OpenAI-compatible, executeur de chaine...) avec des variables d'environnement, lecture du JSON rendu sur la derniere ligne.

PowerShell 7 requis (pwsh). Sous Windows : lancer ces tests dans WSL (voir tests/providers/README.md).
"""
import json
import os
import shutil
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
TASK = "TASK-" + "A" * 32
CLIENT = "CLI-CUST-0000AAAA"

DRIVER = r'''
$ErrorActionPreference = "Stop"
$Splat = @{ ClientId = $env:T_CLIENT; ProjectId = "PROJ-T"; WorkerId = "noah"; TaskId = $env:T_TASK; Objective = $env:T_OBJECTIVE; Model = $env:T_MODEL }
if ($env:T_SPLAT) { foreach ($P in ($env:T_SPLAT | ConvertFrom-Json).PSObject.Properties) { $Splat[$P.Name] = $P.Value } }
$Out = & (Join-Path $env:BK_ROOT $env:T_SCRIPT) @Splat
$Exit = $LASTEXITCODE
[ordered]@{ exit = $Exit; stdout = (($Out | Out-String).Trim()) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:OUT_FILE -Encoding utf8
'''


def make_root(activated=(), auto_approve=False, extra=None):
    """Racine jetable : core/ (sans identifiants ni comptes), les deux modules Python du web_fetch, l'identite d'un Worker, le dossier de test."""
    root = tempfile.mkdtemp(prefix="bkprov-")
    shutil.copytree(os.path.join(REPO, "core"), os.path.join(root, "core"),
                    ignore=shutil.ignore_patterns("client-credentials", "accounts", "__pycache__", "*.pyc"))
    os.makedirs(os.path.join(root, "dashboard"), exist_ok=True)
    for name in ("net_policy.py", "safe_fetch.py"):
        shutil.copy2(os.path.join(REPO, "dashboard", name), os.path.join(root, "dashboard", name))
    src = os.path.join(REPO, "workers", "noah", "identity")
    dst = os.path.join(root, "workers", "noah", "identity")
    os.makedirs(dst, exist_ok=True)
    for fname in ("identity.json", "playbook.md"):
        if os.path.isfile(os.path.join(src, fname)):
            shutil.copy2(os.path.join(src, fname), os.path.join(dst, fname))
    for sub in ("_test", "memory/runtime", "runtime/tasks", "core/connectors/data", "core/ai/data", "runtime/engine"):
        os.makedirs(os.path.join(root, sub), exist_ok=True)
    if activated:
        with open(os.path.join(root, "core/connectors/data", CLIENT + ".json"), "w", encoding="utf-8") as f:
            json.dump(list(activated), f)
    if auto_approve:
        with open(os.path.join(root, "core/connectors/data", CLIENT + ".autoapprove.json"), "w", encoding="utf-8") as f:
            json.dump({"autoApprove": True}, f)
    if extra:
        extra(root)
    with open(os.path.join(root, "_test", "driver.ps1"), "w", encoding="utf-8") as f:
        f.write(DRIVER)
    return root


class Run:
    """Une execution d'un script du depot dans une racine jetable. `script` : chemin relatif depuis la racine."""

    def __init__(self, script, env=None, splat=None, objective="Bonjour, presente-toi en une phrase.", root=None, model="fake-model:latest",
                 client=CLIENT, task=TASK, timeout=300, **root_kw):
        self.root = root or make_root(**root_kw)
        self.own_root = root is None
        self.out_file = os.path.join(self.root, "_test", "out.json")
        if os.path.isfile(self.out_file):
            os.remove(self.out_file)
        self.env = dict(os.environ, BK_ROOT=self.root, OUT_FILE=self.out_file, T_CLIENT=client, T_TASK=task, T_OBJECTIVE=objective, T_MODEL=model,
                        T_SCRIPT=script, BK_REPLY_LANG="", BK_MISSION_LEVEL="")
        for k in ("BK_ENGINE_PLAN", "BK_ENGINE_BUDGET_CHF", "BK_SECRET_ANTHROPIC", "BK_SECRET_OLLAMA", "BK_SECRET_SWISS", "BK_ENGINE_DEADLINE_EPOCH"):
            self.env.pop(k, None)
        if splat is not None:
            self.env["T_SPLAT"] = json.dumps(splat)
        self.env.update(env or {})
        proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", os.path.join(self.root, "_test", "driver.ps1")], capture_output=True,
                              text=True, encoding="utf-8", errors="replace", env=self.env, timeout=timeout, cwd=self.root)
        self.proc = proc
        assert os.path.isfile(self.out_file), f"driver produced nothing\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        with open(self.out_file, encoding="utf-8-sig") as f:
            out = json.load(f)
        self.exit = out["exit"]
        text = out["stdout"]
        last = [ln for ln in text.splitlines() if ln.strip().startswith("{")]
        self.result = json.loads(last[-1]) if last else {"raw": text}
        self.stdout = text

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def read_json(self, *parts):
        p = self.path(*parts)
        if not os.path.isfile(p):
            return None
        with open(p, encoding="utf-8-sig") as f:
            return json.load(f)

    def task_files(self, task=TASK):
        d = self.path("runtime", "task-files", task)
        return {n: os.path.getsize(os.path.join(d, n)) for n in os.listdir(d)} if os.path.isdir(d) else {}

    def cleanup(self):
        if self.own_root:
            shutil.rmtree(self.root, ignore_errors=True)


def adapter_splat(srv_url, mode="auto", engine="ollama", **extra):
    d = {"EngineId": engine, "EndpointUrl": srv_url, "ToolMode": mode}
    d.update(extra)
    return d
