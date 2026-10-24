#!/usr/bin/env bash
# Creates the bind-mount directories under DATA_DIR with the owner each image runs as.
# Safe to re-run. Run as root (or via sudo) before `docker compose up`.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
: "${DATA_DIR:?DATA_DIR not set in .env}"

mountpoint -q "$(dirname "$DATA_DIR")" 2>/dev/null || mountpoint -q "$DATA_DIR" 2>/dev/null || \
  echo "WARNING: $DATA_DIR is not on a separate mount — data would land on the VM disk, not the LUN." >&2

# dir:uid:gid  — ids are what each upstream image runs as (verified on first deploy)
for spec in \
  postgres:70:70 \
  authentik-media:1000:1000 \
  influx-data:1000:1000 \
  influx-config:1000:1000 \
  loki:10001:10001 \
  grafana:472:0
do
  IFS=: read -r d uid gid <<<"$spec"
  install -d -m 0750 -o "$uid" -g "$gid" "${DATA_DIR}/${d}"
done
echo "Prepared ${DATA_DIR}"
