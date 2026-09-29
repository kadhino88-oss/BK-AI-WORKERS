#!/bin/bash
# Ajoute un fichier de swap (2 Go par defaut) au VPS. Idempotent : sans effet s'il existe deja.
# Usage (en root) : sudo bash deploy/setup-swap.sh [taille_en_Go]
set -eu

SIZE_GB="${1:-2}"
SWAPFILE=/swapfile

if [ "$(id -u)" -ne 0 ]; then
  echo "A lancer en root : sudo bash $0" >&2
  exit 1
fi

if swapon --show | grep -q "$SWAPFILE"; then
  echo "Swap deja actif :"
  swapon --show
  exit 0
fi

if [ ! -f "$SWAPFILE" ]; then
  fallocate -l "${SIZE_GB}G" "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SIZE_GB * 1024))
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
fi
swapon "$SWAPFILE"

# Persistant au redemarrage
grep -q "^$SWAPFILE " /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab

# Le swap sert de filet de securite, pas de memoire courante
cat > /etc/sysctl.d/99-bk-swap.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
sysctl --system >/dev/null

echo "Swap de ${SIZE_GB} Go actif :"
swapon --show
free -h
