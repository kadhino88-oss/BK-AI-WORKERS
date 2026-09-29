#!/bin/sh
# Synchronise le code vers le volume persistant sans toucher a l'etat, puis lance le serveur.
set -eu

SRC=/opt/bk/
DST="${BK_ROOT:-/data/app}"
mkdir -p "$DST"

# 1) Code : ecrase (mises a jour), en excluant tout ce qui est etat ou donnees clients.
rsync -a \
  --exclude='state/' --exclude='data/' --exclude='/runtime/' --exclude='/memory/runtime/' \
  --exclude='.gate/' --exclude='_archive/' --exclude='.secrets/*.dpapi' \
  "$SRC" "$DST/"

# 2) Etat / donnees : copie seulement si absent (premier demarrage).
rsync -a --ignore-existing --exclude='_archive/' "$SRC" "$DST/"

mkdir -p "$DST/runtime/tasks" "$DST/memory/runtime" "$DST/core/profile/data" "$DST/dashboard/.gate"
chmod 700 "$DST/dashboard/.gate"

# Le serveur ecoute en interne ; le proxy HTTPS (Caddy) est devant.
export BK_LISTEN_HOST="${BK_LISTEN_HOST:-0.0.0.0}"
export BK_REQUIRE_GATE="${BK_REQUIRE_GATE:-1}"

cd "$DST"
exec python3 dashboard/server.py
