# -*- coding: utf-8 -*-
"""Lance, l'une apres l'autre, toutes les suites du moteur de projets (tests/projects). Code de sortie 0 si tout passe.

    python tests/projects/run_all.py            (Windows ou Linux/WSL ; python 3 ; les suites PowerShell sont sautees si pwsh est absent)
    python tests/projects/run_all.py --quick    (sans le bout en bout du serveur et sans les suites PowerShell)

Les suites PowerShell (lanceur d'etape, pipeline complet avec la fausse API) tournent sous WSL : `wsl -e python3 tests/projects/run_all.py`. L'essai de fumee
avec la VRAIE API (smoke_real_api.py) n'est jamais lance ici : il depense de l'argent, il se lance a la main."""
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PY_SUITES = ["test_store.py", "test_plan.py", "test_tools.py", "test_verify.py", "test_context.py", "test_wiring.py", "test_approvals.py", "test_consistency.py",
             "test_housekeeping.py", "test_engine_crash.py", "test_engine_flow.py", "test_engine_budget.py"]
PS_SUITES = ["test_runner.py", "test_pipeline_ps.py"]
E2E = ["e2e_server.py"]


def main():
    quick = "--quick" in sys.argv
    has_pwsh = bool(os.environ.get("BK_PWSH") or shutil.which("pwsh"))
    plan = [(n, False) for n in PY_SUITES]
    if not quick:
        plan += [(n, True) for n in PS_SUITES] + [(n, False) for n in E2E]
    results = []
    for name, needs_pwsh in plan:
        if needs_pwsh and not has_pwsh:
            results.append((name, "SKIP (pwsh absent)", 0.0))
            continue
        start = time.time()
        p = subprocess.run([sys.executable, os.path.join(HERE, name)], cwd=os.path.dirname(os.path.dirname(HERE)))
        results.append((name, "OK" if p.returncode == 0 else f"ECHEC (code {p.returncode})", time.time() - start))
    print("\n== tests/projects ==")
    for name, status, secs in results:
        print(f"  {status:<22} {name}  ({secs:.0f}s)")
    return 0 if all(s.startswith(("OK", "SKIP")) for _, s, _ in results) else 1


if __name__ == "__main__":
    sys.exit(main())
