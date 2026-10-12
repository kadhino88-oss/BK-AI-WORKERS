# -*- coding: utf-8 -*-
"""Lance, l'une apres l'autre, toutes les suites de tests/hire (offre « Worker a l'unite »). Code de sortie 0 si tout passe.

    python tests/hire/run_all.py            (Windows ou Linux/WSL ; les suites PowerShell sont sautees si pwsh est absent)
"""
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PS_SUITES = {"test_prompt_installation.py", "test_chloe_allowed.py", "test_adapter_pause.py"}
SUITES = ["test_entitlements.py", "test_installations.py", "test_server_hire.py", "test_prompt_installation.py", "test_chloe_allowed.py",
          "test_adapter_pause.py", "e2e_server.py"]


def main():
    has_pwsh = bool(os.environ.get("BK_PWSH") or shutil.which("pwsh"))
    results = []
    for name in SUITES:
        if name in PS_SUITES and not has_pwsh:
            results.append((name, "SKIP (pwsh absent)", 0.0))
            continue
        start = time.time()
        p = subprocess.run([sys.executable, os.path.join(HERE, name)], cwd=os.path.dirname(os.path.dirname(HERE)))
        results.append((name, "OK" if p.returncode == 0 else f"ECHEC (code {p.returncode})", time.time() - start))
    print("\n== tests/hire ==")
    for name, status, secs in results:
        print(f"  {status:<22} {name}  ({secs:.0f}s)")
    return 0 if all(s.startswith(("OK", "SKIP")) for _, s, _ in results) else 1


if __name__ == "__main__":
    sys.exit(main())
