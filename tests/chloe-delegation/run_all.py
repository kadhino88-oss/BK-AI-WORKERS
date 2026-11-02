"""Lance toutes les suites de la delegation de Chloe, UNE APRES L'AUTRE (la machine est lente et partagee), et affiche un resume.

  wsl -e python3 tests/chloe-delegation/run_all.py          (PowerShell 7 requis pour les suites qui lancent Chloe ; sinon elles se sautent)
  python tests/chloe-delegation/run_all.py --quick          (sans test_orchestration.py, la plus longue : plusieurs minutes)

Aucun reseau, aucun cout, aucun vrai secret.
"""
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SUITES = ["test_cards.py", "test_routing_accuracy.py", "test_scope_server.py", "test_planner.py", "test_router.py", "test_ui_render.js", "test_orchestration.py"]


def main():
    quick = "--quick" in sys.argv
    results = []
    for name in SUITES:
        if quick and name == "test_orchestration.py":
            continue
        if name.endswith(".js") and not shutil.which("node"):
            # WSL sans Node.js : la suite d'interface se lance a part sous Windows (node tests/chloe-delegation/test_ui_render.js)
            print(f"{name:32} SAUTEE (node absent ici : lancer node tests/chloe-delegation/{name} sous Windows)", flush=True)
            continue
        cmd = [shutil.which("node"), os.path.join(HERE, name)] if name.endswith(".js") else [sys.executable, os.path.join(HERE, name)]
        started = time.time()
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
        tail = " | ".join(line.strip() for line in (p.stdout + p.stderr).splitlines()[-12:] if line.startswith(("Ran ", "OK", "FAILED", "TOUT PASSE", "ECHEC")) or "ECHEC" in line)
        results.append((name, p.returncode, round(time.time() - started), tail))
        print(f"{name:32} rc={p.returncode} {round(time.time() - started):4d}s  {tail}", flush=True)
        if p.returncode != 0:
            print((p.stdout + p.stderr)[-3000:])
    failed = [r for r in results if r[1] != 0]
    print("\nTOUT PASSE" if not failed else f"\n{len(failed)} SUITE(S) EN ECHEC : " + ", ".join(r[0] for r in failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
