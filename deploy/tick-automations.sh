#!/bin/sh
# BK-AI-WORKERS — declenche periodiquement (cron) les automatisations
# dues, tous clients confondus (2026-09-24). Avant ce script, rien
# n'appelait jamais Invoke-AutomationTick automatiquement : une
# automatisation creee restait "jamais executee" tant qu'un client ne
# rouvrait pas le dashboard pour cliquer "Executer maintenant" a la
# main — ce qui n'est pas une automatisation. Invoke-AutomationTick
# avec -ClientId vide traite TOUS les clients (voir Get-Automations
# dans AUTOMATION-ENGINE.ps1), c'est le comportement voulu ici.
set -eu

CONTAINER="bk-ai-workers-app-1"
OUT="/tmp/bk-automation-tick-result.json"

docker exec "$CONTAINER" pwsh -NoProfile -File /data/app/dashboard/Automation-Bridge.ps1 \
  -Action tick -OutFile "$OUT"

docker exec "$CONTAINER" cat "$OUT"
echo
