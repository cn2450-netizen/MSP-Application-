#!/usr/bin/env bash
# Attach the NAS backup share at /srv/msp-backups, safely and permanently. Idempotent; run as root.
#
#   sudo scripts/setup-backup-storage.sh --nfs 192.168.20.251:/mnt/Share/msp-backups [--init]
#
# Safety design (a network mount that is missing must never let anything write to the VM's own disk):
#   1. msp-backup-nfs.service mounts the share at boot, retries while the NAS is unreachable, and unmounts
#      cleanly at shutdown. Docker starts after it (ordering only: platform startup never depends on the NAS).
#   2. While unmounted, the mount point is made IMMUTABLE (chattr +i), so any write to it fails instead of
#      landing on the local disk.
#   3. A marker file (.msp-backup-root) on the share must exist, so the wrong or an empty share is never used.
# --init creates the marker on a brand-new, empty share (refuses if the share already has other files).
set -euo pipefail

MNT=/srv/msp-backups
NFS="" INIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nfs)  NFS="${2:?--nfs needs HOST:/export}"; shift 2;;
    --init) INIT=1; shift;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[[ -n "$NFS" ]] || { echo "usage: setup-backup-storage.sh --nfs HOST:/export [--init]" >&2; exit 2; }
[[ "$NFS" =~ ^[A-Za-z0-9.-]+:/[A-Za-z0-9._/-]+$ ]] || { echo "unexpected characters in the NFS source" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
HOST="${NFS%%:*}"

echo "== packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-common e2fsprogs netcat-openbsd >/dev/null

echo "== mount point ${MNT}"
mkdir -p "$MNT"
if mountpoint -q "$MNT"; then
  echo "   (currently mounted: immutability is applied to the empty directory only while it is unmounted)"
else
  chattr +i "$MNT"
  echo "   immutable while unmounted: $(lsattr -d "$MNT" | cut -c1-20)"
fi

echo "== attach / detach scripts"
cat > /usr/local/sbin/msp-backup-attach <<ATTACH
#!/usr/bin/env bash
# Mount the NAS backup share. Retries while the NAS is unreachable; refuses a share without the marker file.
set -euo pipefail
SRC="${NFS}"; MNT="${MNT}"; HOST="${HOST}"
for _ in \$(seq 1 60); do
  timeout 2 bash -c "echo >/dev/tcp/\${HOST}/2049" 2>/dev/null && break
  sleep 2
done
mountpoint -q "\$MNT" || mount -t nfs4 \\
  -o nfsvers=4.2,hard,timeo=600,retrans=2,noatime,nodev,nosuid,noexec,rsize=1048576,wsize=1048576 "\$SRC" "\$MNT"
if [[ ! -f "\$MNT/.msp-backup-root" ]]; then
  echo "marker file missing on \$SRC: not the backup share (or not initialised). Refusing to use it." >&2
  umount "\$MNT" 2>/dev/null || true
  exit 1
fi
ATTACH
cat > /usr/local/sbin/msp-backup-detach <<DETACH
#!/usr/bin/env bash
sync
mountpoint -q "${MNT}" && { umount "${MNT}" || umount -l "${MNT}"; }
exit 0
DETACH
chmod 0750 /usr/local/sbin/msp-backup-attach /usr/local/sbin/msp-backup-detach

echo "== systemd units"
cat > /etc/systemd/system/msp-backup-nfs.service <<UNIT
[Unit]
Description=MSP backup storage (NFS from ${HOST}) at ${MNT}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/msp-backup-attach
ExecStop=/usr/local/sbin/msp-backup-detach
Restart=on-failure
RestartSec=30
TimeoutStartSec=170

[Install]
WantedBy=multi-user.target
UNIT
install -d /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/20-msp-backup.conf <<DROPIN
[Unit]
# Order only (no Requires): a slow or absent NAS must never stop the platform from starting.
Wants=msp-backup-nfs.service
After=msp-backup-nfs.service
DROPIN
systemctl daemon-reload
systemctl enable msp-backup-nfs.service >/dev/null 2>&1

if [[ $INIT -eq 1 ]] && ! mountpoint -q "$MNT"; then
  echo "== initialise the share (marker file)"
  tmp="$(mktemp -d)"
  mount -t nfs4 -o nfsvers=4.2,hard,nodev,nosuid,noexec "$NFS" "$tmp"
  if [[ -f "$tmp/.msp-backup-root" ]]; then echo "   marker already present"
  elif [[ -z "$(ls -A "$tmp")" ]]; then
    echo "msp-backups $(cat /proc/sys/kernel/random/uuid) created $(date -u +%FT%TZ)" > "$tmp/.msp-backup-root"
    echo "   marker created"
  else
    umount "$tmp"; rmdir "$tmp"; echo "REFUSING --init: the share is not empty and has no marker" >&2; exit 1
  fi
  umount "$tmp"; rmdir "$tmp"
fi

echo "== start"
systemctl restart msp-backup-nfs.service
mountpoint -q "$MNT" && echo "   mounted: $(findmnt -no SOURCE,FSTYPE "$MNT")" || { echo "mount failed: see journalctl -u msp-backup-nfs" >&2; exit 1; }
echo "== done"
