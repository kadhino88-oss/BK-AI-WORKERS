# -*- coding: utf-8 -*-
"""Lance, l'une apres l'autre, les suites de tests/hire-ui (interface « Worker a l'unite »). Code de sortie 0 si tout passe.

    python tests/hire-ui/run_all.py        (python 3 + node ; sans node, les suites qui en ont besoin sont sautees)

Pas de navigateur ici : la verification a la main se fait avec tests/hire-ui/dev_server.py (voir docs/HIRE-UI.md).
"""
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
NODE = shutil.which("node")
SUITES = [("test_static.py", False), ("test_payload_contract.py", True), ("test_pure_logic.js", True)]


def main():
    results = []
    for name, needs_node in SUITES:
        if needs_node and not NODE:
            results.append((name, "SKIP (node absent)", 0.0))
            continue
        cmd = [NODE, os.path.join(HERE, name)] if name.endswith(".js") else [sys.executable, "-X", "utf8", os.path.join(HERE, name)]
        start = time.time()
        p = subprocess.run(cmd, cwd=os.path.dirname(os.path.dirname(HERE)))
        results.append((name, "OK" if p.returncode == 0 else f"ECHEC (code {p.returncode})", time.time() - start))
    print("\n== tests/hire-ui ==")
    for name, status, secs in results:
        print(f"  {status:<22} {name}  ({secs:.0f}s)")
    return 0 if all(s.startswith(("OK", "SKIP")) for _, s, _ in results) else 1


if __name__ == "__main__":
    sys.exit(main())
