# -*- coding: utf-8 -*-
"""Lanceur en ligne de commande des outils d'une étape de projet (docs/AUTONOMY-ENGINE.md, section 7.7).

    python dashboard/project-tool.py <outil>          entrée standard : {"projectDir","stepDir","stepId","kind","worker","input":{...}}
                                                      sortie standard : {"ok":true,"result":{...}} ou {"ok":false,"error":"CODE","detail":"..."}
Code de sortie : 0 (le résultat, succès ou refus, est dans le JSON), 2 si l'appel est mal formé (outil absent, entrée illisible).

Aucune surface HTTP : le lanceur PowerShell (Project-StepRunner.ps1) appelle ce programme, donc aucun risque d'accès externe ni de SSRF. Le chemin
sûr de l'espace de travail est codé et testé UNE fois, dans project_paths.py / project_tools.py. Les outils de l'atelier de sites (site_tools.py,
chantier B5) s'enregistrent eux-mêmes à l'import, s'ils existent.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

MAX_STDIN = 6 * 1024 * 1024


def main(argv):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stdin.reconfigure(encoding="utf-8")
    if len(argv) != 2 or not argv[1].replace("_", "").isalnum():
        sys.stdout.write(json.dumps({"ok": False, "error": "INVALID_INPUT", "detail": "usage : project-tool.py <outil>"}) + "\n")
        return 2
    import project_tools
    try:
        import site_tools  # noqa: F401  (enregistre les outils site_* ; absent tant que l'atelier de sites n'est pas fusionné)
    except ImportError:
        pass
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"project-tool: site_tools: {type(e).__name__}\n")
    raw = sys.stdin.read(MAX_STDIN + 1)
    if len(raw) > MAX_STDIN:
        sys.stdout.write(json.dumps({"ok": False, "error": "TOO_LARGE", "detail": "Entrée trop volumineuse."}) + "\n")
        return 2
    try:
        payload = json.loads(raw or "{}")
    except ValueError:
        sys.stdout.write(json.dumps({"ok": False, "error": "INVALID_INPUT", "detail": "L'entrée n'est pas du JSON."}) + "\n")
        return 2
    if argv[1] == "_definitions":                  # définitions des outils enregistrés par d'autres modules (site_*) : appelé par le lanceur
        names = payload.get("names") if isinstance(payload, dict) else None
        out = {"ok": True, "result": {"definitions": project_tools.definitions_for([n for n in names if isinstance(n, str)] if isinstance(names, list) else [])}}
    else:
        out = project_tools.run_tool(argv[1], payload)
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    return 2 if out.get("error") == "UNKNOWN_TOOL" else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
