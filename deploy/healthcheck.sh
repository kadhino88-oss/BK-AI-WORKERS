#!/bin/bash
# Surveillance + auto-reparation (a lancer en cron toutes les 5 minutes).
# Verifie que le site repond ; apres 2 echecs consecutifs, redemarre le
# conteneur applicatif et l'ecrit dans le journal. Un simple redemarrage
# suffit dans la grande majorite des pannes (processus bloque, memoire).
# Pour etre PREVENU par email en plus : ajouter le site a un service gratuit
# de surveillance externe (ex. UptimeRobot) — il voit aussi les pannes du serveur entier.
set -u
URL="${BK_HEALTH_URL:-https://bk-ai-workers.com/api/workers}"
STATE="${BK_HEALTH_STATE:-$HOME/.bk-health-fails}"
LOG="${BK_HEALTH_LOG:-$HOME/bk-health.log}"
DIR="${BK_PROJECT_DIR:-$HOME/BK-AI-WORKERS}"

if curl -fsS -m 15 -o /dev/null "$URL"; then
  [ -f "$STATE" ] && { echo "$(date -u +%FT%TZ) OK again after $(cat "$STATE") failure(s)" >> "$LOG"; rm -f "$STATE"; }
  exit 0
fi

n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STATE"
echo "$(date -u +%FT%TZ) FAIL #$n for $URL" >> "$LOG"
if [ "$n" -ge 2 ]; then
  echo "$(date -u +%FT%TZ) restarting app container" >> "$LOG"
  ( cd "$DIR" && docker compose restart app >> "$LOG" 2>&1 )
  echo 0 > "$STATE"
fi
