# -*- coding: utf-8 -*-
"""SMOKE avec un VRAI petit modèle local (Ollama, gratuit) dans le VRAI moteur de projets : même contrat que Project-StepRunner.ps1 (input.json -> result.json, cost.json),
mais la boucle d'outils est ce petit script Python qui parle à Ollama (/api/chat avec tools) et exécute les outils par project_tools.run_tool (les mêmes que le lanceur PowerShell).

    python ollama_runner.py <input.json> <result.json>

Réglages : variables d'environnement BK_OLLAMA_URL (http://127.0.0.1:11434), BK_OLLAMA_MODEL (qwen2.5:1.5b) ; fichier <BK_ROOT>/_prove/knobs.json {"scriptedPlan": true} =
l'étape « plan » est alors écrite par le banc (plan connu bon) pour observer le modèle sur l'exécution seule. Ce n'est PAS le lanceur de production (il n'a ni web, ni code, ni cache) :
il ne prouve que la manière dont un petit modèle se comporte DANS le moteur (outils, vérification, garde-fous), jamais la qualité de production d'un Worker."""
import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
sys.path.insert(0, HERE)
import project_tools as pt  # noqa: E402
from common import read_json  # noqa: E402

URL = os.environ.get("BK_OLLAMA_URL", "http://127.0.0.1:11434")
MODEL = os.environ.get("BK_OLLAMA_MODEL", "qwen2.5:1.5b")
MAX_ITER = 8

S = lambda **kw: {"type": "string", **kw}  # noqa: E731
DEFS = {
    "workspace_list": ("Liste les fichiers de l'espace de travail.", {"path": S()}, []),
    "workspace_read": ("Lit un fichier de l'espace de travail.", {"path": S()}, ["path"]),
    "workspace_write": ("Écrit un fichier (texte) dans l'espace de travail.", {"path": S(description="chemin relatif, ex. notes/accueil.md"), "content": S(), "mode": S(description="overwrite")}, ["path", "content"]),
    "deliverable_register": ("Déclare un fichier comme livrable.", {"path": S(), "title": S()}, ["path"]),
    "request_input": ("Pose UNE question au client quand une information manque vraiment.", {"question": S(), "why": S(), "blocking": {"type": "boolean"}}, ["question"]),
    "project_plan": ("Définit le plan du projet. action doit valoir « set » et plan est l'objet complet {goal, criteria[], steps[]}.", {"action": S(), "plan": {"type": "object"}}, ["action", "plan"]),
    "step_complete": ("Termine l'étape. À APPELER EN DERNIER. status: DONE, PARTIAL ou NEEDS_INPUT.",
                      {"status": S(), "summary": S(description="une ou deux phrases sur ce qui est fait"), "deliverables": {"type": "array", "items": {"type": "object"}},
                       "criteriaClaims": {"type": "array", "items": {"type": "object"}}}, ["status", "summary"]),
}
KIND_TOOLS = {"plan": ["project_plan", "step_complete"], "replan": ["project_plan", "step_complete"],
              "execute": ["workspace_list", "workspace_read", "workspace_write", "deliverable_register", "request_input", "step_complete"],
              "fix": ["workspace_list", "workspace_read", "workspace_write", "deliverable_register", "step_complete"],
              "verify": ["workspace_list", "workspace_read", "step_complete"], "consolidate": ["workspace_list", "workspace_read", "workspace_write", "deliverable_register", "step_complete"],
              "answer": ["workspace_list", "workspace_read"]}


def tool_defs(kind):
    out = []
    for n in KIND_TOOLS.get(kind, []):
        d, props, req = DEFS[n]
        out.append({"type": "function", "function": {"name": n, "description": d, "parameters": {"type": "object", "properties": props, "required": req}}})
    return out


def chat(messages, tools):
    body = {"model": MODEL, "stream": False, "messages": messages, "tools": tools, "options": {"num_ctx": 8192, "num_predict": 1200, "temperature": 0.2}}
    req = urllib.request.Request(URL + "/api/chat", data=json.dumps(body).encode("utf-8"), headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    in_path, out_path = sys.argv[1], sys.argv[2]
    inp = read_json(in_path)
    sd = inp["paths"]["stepDir"]
    kind = inp["kind"]
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    knobs = read_json(os.path.join(os.environ.get("BK_ROOT", REPO), "_prove", "knobs.json"), {}) or {}

    def tool(name, payload):
        return pt.run_tool(name, {"projectDir": inp["paths"]["projectDir"], "stepDir": sd, "stepId": inp["stepId"], "kind": kind, "worker": inp["worker"], "input": payload})

    log = open(os.path.join(sd, "ollama-trace.jsonl"), "a", encoding="utf-8")
    result = {"schema": "BK-STEP-RESULT-V1", "status": "FAILED", "exitReason": "max_iterations", "report": {}, "answerText": "", "model": MODEL, "iterations": 0, "filesImported": [], "error": None,
              "retryAfterSec": None, "startedUtc": started}
    ptok = ctok = 0
    if kind in ("plan", "replan") and knobs.get("scriptedPlan"):
        import fl_site  # noqa: F401  (plan connu bon, fabriqué par le banc)
        plan = knobs["scriptedPlan"]
        out = tool("project_plan", {"action": "set", "plan": plan})
        out2 = tool("step_complete", {"status": "DONE", "summary": "Plan prêt (écrit par le banc)."})
        result.update(status="DONE" if out.get("ok") and out2.get("ok") else "FAILED", exitReason="step_complete", report=(out2.get("result") or {}).get("report") or {})
    else:
        with open(inp["paths"]["context"], encoding="utf-8") as f:
            context = f.read()
        system = ("Tu es %s, un Worker d'une équipe. Tu travailles UNIQUEMENT en appelant des outils, un à la fois. Les fichiers que tu écris vont dans l'espace de travail. "
                  "Tu n'inventes aucun fait. Quand le travail est fait, appelle step_complete (status DONE, summary). Réponds en français.\n\nCONTEXTE DE L'ÉTAPE :\n%s" % (inp["worker"], context[:9000]))
        msgs = [{"role": "system", "content": system}, {"role": "user", "content": "Fais ton étape maintenant (type : %s, identifiant : %s)." % (kind, inp["stepId"])}]
        tools = tool_defs(kind)
        done = False
        for it in range(1, MAX_ITER + 1):
            result["iterations"] = it
            try:
                resp = chat(msgs, tools)
            except Exception as e:  # noqa: BLE001
                result.update(status="RETRY_LATER", exitReason="api_error", error="%s: %s" % (type(e).__name__, str(e)[:200]), retryAfterSec=60)
                break
            m = resp.get("message") or {}
            ptok += int(resp.get("prompt_eval_count") or 0)
            ctok += int(resp.get("eval_count") or 0)
            msgs.append({"role": "assistant", "content": m.get("content") or "", "tool_calls": m.get("tool_calls") or []})
            calls = m.get("tool_calls") or []
            log.write(json.dumps({"iter": it, "text": (m.get("content") or "")[:400], "calls": [c.get("function") for c in calls]}, ensure_ascii=False) + "\n")
            log.flush()
            if not calls:
                msgs.append({"role": "user", "content": "Tu dois appeler un outil. Si le travail est fait, appelle step_complete."})
                continue
            for c in calls:
                fn = c.get("function") or {}
                name, args = fn.get("name"), fn.get("arguments") or {}
                if isinstance(args, str):
                    try:
                        args = json.loads(args)
                    except ValueError:
                        args = {}
                if name not in KIND_TOOLS.get(kind, []):
                    res = {"ok": False, "error": "UNKNOWN_TOOL", "detail": "Outil indisponible : " + str(name)}
                else:
                    res = tool(name, args)
                log.write(json.dumps({"iter": it, "tool": name, "ok": res.get("ok"), "error": res.get("error"), "detail": str(res.get("detail") or "")[:300]}, ensure_ascii=False) + "\n")
                log.flush()
                msgs.append({"role": "tool", "content": json.dumps(res, ensure_ascii=False)[:3000]})
                if name == "step_complete" and res.get("ok"):
                    rep = res["result"]["report"]
                    result.update(status=rep.get("status", "DONE"), exitReason="step_complete", report=rep)
                    done = True
            if done:
                break
        if kind == "answer" and not done:
            result.update(status="DONE", exitReason="step_complete", answerText=(msgs[-1].get("content") or "")[:2000])
    usage = {"input_tokens": ptok, "output_tokens": ctok, "api_calls": result["iterations"], "estimated_cost_usd": 0.0, "estimated_cost_chf": 0.0, "cost_capped": False}
    with open(os.path.join(sd, "cost.json"), "w", encoding="utf-8") as f:
        json.dump({"updatedUtc": started, "usage": usage}, f)
    result.update(usage=usage, finishedUtc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False)
    os.replace(tmp, out_path)


if __name__ == "__main__":
    main()
