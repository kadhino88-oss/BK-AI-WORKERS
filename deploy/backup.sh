#!/bin/bash
# Sauvegarde du volume de donnees (missions, profil, securite, facturation) et rotation.
# Usage : bash deploy/backup.sh            (a planifier en cron, voir DEPLOIEMENT-VPS.md)
# Variables : BK_BACKUP_DIR (defaut /var/backups/bk-ai-workers), BK_BACKUP_KEEP (jours, defaut 14)
set -eu

DIR="${BK_BACKUP_DIR:-/var/backups/bk-ai-workers}"
KEEP="${BK_BACKUP_KEEP:-14}"
VOLUME="${BK_VOLUME:-bk-ai-workers_bkdata}"
STAMP="$(date +%F_%H%M)"

mkdir -p "$DIR"
chmod 700 "$DIR"

docker run --rm -v "$VOLUME":/data:ro -v "$DIR":/backup alpine \
  tar czf "/backup/bk-backup-$STAMP.tgz" -C /data .

# Rotation : supprime les sauvegardes de plus de $KEEP jours
find "$DIR" -name 'bk-backup-*.tgz' -mtime +"$KEEP" -delete

echo "Sauvegarde : $DIR/bk-backup-$STAMP.tgz"
ls -lh "$DIR" | tail -n 5
