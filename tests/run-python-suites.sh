#!/usr/bin/env bash
# Lance toutes les suites Python du depot (un dossier tests/<nom>/ = une suite).
# Usage : bash tests/run-python-suites.sh        (depuis la racine du depot)
# Certaines suites (connect-guides, phone-agent) appellent PowerShell 7 (`pwsh`) :
# sans lui elles echouent, ce qui est signale ci-dessous plutot que cache.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BK_ROOT="$ROOT"
failed=()
for dir in $(cd "$ROOT" && git ls-files 'tests/*/test_*.py' | sed -E 's#/[^/]*$##' | sort -u | grep -v '^tests/hire-ui$'); do
  name="$(basename "$dir")"
  if (cd "$ROOT/$dir" && timeout 300 python3 -m unittest discover -s . -p 'test_*.py' >"/tmp/bk-suite-$name.log" 2>&1); then
    echo "OK    $name"
  else
    echo "ECHEC $name  (voir /tmp/bk-suite-$name.log)"
    tail -n 15 "/tmp/bk-suite-$name.log" | sed 's/^/      /'
    failed+=("$name")
  fi
done
# hire-ui : scripts de verification (test_static.py sort en erreur sous unittest), lances par leur propre runner.
if (cd "$ROOT/tests/hire-ui" && timeout 300 python3 run_all.py >/tmp/bk-suite-hire-ui-runner.log 2>&1); then
  echo "OK    hire-ui (run_all.py)"
else
  echo "ECHEC hire-ui (run_all.py)  (voir /tmp/bk-suite-hire-ui-runner.log)"
  failed+=("hire-ui")
fi
if [ "${#failed[@]}" -gt 0 ]; then
  echo "Suites en echec : ${failed[*]}"
  exit 1
fi
echo "Toutes les suites Python passent."
