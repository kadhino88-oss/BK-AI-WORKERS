# -*- coding: utf-8 -*-
"""Essai MANUEL contre le VRAI Ollama de cette machine (gratuit, aucun appel externe) : une reponse simple et un appel d'outil, avec chaque modele installe
(ou celui donne en argument). Rend compte honnetement de ce qui marche, du temps pris et du mode d'outils utilise. N'est PAS lance avec les suites automatiques.

    python tests/providers/real_ollama_check.py                       (Windows : PowerShell 7 requis, variable BK_PWSH si pwsh n'est pas dans le PATH)
    python tests/providers/real_ollama_check.py --model qwen2.5:1.5b --url http://127.0.0.1:11434

Seul http://127.0.0.1:11434 (ou --url, adresse privee) est appele. Les fichiers de test vivent dans une racine jetable, supprimee a la fin.
"""
import argparse
import json
import os
import shutil
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import harness  # noqa: E402
from harness import Run, make_root  # noqa: E402


def installed(url):
    with urllib.request.urlopen(url.rstrip("/") + "/api/tags", timeout=10) as r:
        return [(m["name"], m.get("capabilities") or []) for m in json.load(r).get("models", [])]


def one(root, url, model, objective, label, timeout):
    env = {"BK_MISSION_LEVEL": "rapide", "BK_ENGINE_DEADLINE_EPOCH": str(time.time() + timeout)}
    t = time.time()
    r = Run("core/ai/adapters/OPENAI-COMPAT-ADAPTER.ps1", root=root, objective=objective, model=model, env=env, timeout=timeout + 60,
            splat={"EngineId": "ollama", "EndpointUrl": url, "ToolMode": "auto", "TimeoutSec": timeout})
    dt = time.time() - t
    res = r.result
    eng = res.get("engine") or {}
    files = r.task_files()
    print(f"[{model}] {label}: exit={r.exit} duree={dt:.0f}s statut={res.get('status')} mode_outils={eng.get('toolMode')} appels_outils={eng.get('toolCalls')} "
          f"iterations={eng.get('iterations')} jetons={res.get('usage', {}).get('input_tokens')}/{res.get('usage', {}).get('output_tokens')} fichiers={sorted(files)}")
    print("   reponse :", (res.get("answer") or res.get("error") or "")[:400].replace("\n", " | "))
    return res, files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:11434")
    ap.add_argument("--model", action="append", help="modele(s) a essayer (defaut : tous les modeles installes)")
    ap.add_argument("--timeout", type=int, default=900, help="delai par essai, en secondes")
    args = ap.parse_args()
    models = installed(args.url)
    print("Modeles installes :", ", ".join(f"{n} {c}" for n, c in models))
    todo = args.model or [n for n, _ in models]
    pwsh = os.environ.get("BK_PWSH") or shutil.which("pwsh")
    print("PowerShell :", pwsh)
    root = make_root()
    try:
        for model in todo:
            os.environ.setdefault("BK_PWSH", pwsh or "pwsh")
            one(root, args.url, model, "Dis bonjour et presente-toi en une phrase.", "reponse simple", args.timeout)
            one(root, args.url, model, "Enregistre le texte « Bonjour le monde » dans un fichier nomme note.txt, puis confirme-moi que c'est fait.", "appel d'outil", args.timeout)
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
