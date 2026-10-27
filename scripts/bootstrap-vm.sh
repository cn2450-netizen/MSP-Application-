#!/usr/bin/env bash
# Turns a fresh Debian (12/13) VM into a working MSP node. The VM is disposable ("cattle"):
# everything stateful — databases, secrets, generated config, this very repo — lives on the
# iSCSI LUN, so rebuilding is: new VM -> run this script -> same data comes back.
#
#   sudo scripts/bootstrap-vm.sh \
#     --portal 192.168.20.251 --target iqn.2005-10.org.freenas.ctl:msp-apps \
#     --initiator iqn.2026-10.lan.msp:msp-app --luks-key /path/to/msp-luks.key \
#     [--repo https://github.com/OWNER/REPO.git]   # only needed on the very first build
#     [--init-new-lun]                              # FORMATS a blank LUN. Never needed on rebuilds.
#     [--backup-nfs 192.168.20.251:/mnt/Share/msp-backups]   # attach the NAS backup share (see setup-backup-storage.sh)
#     [--chap]                                      # the target requires mutual CHAP: asks for the two secrets (from your vault)
#
# Prereq: the storage NIC is up with a static IP that can reach the portal (no gateway).
# Safe to re-run. It refuses to format anything that already has data.
set -euo pipefail

PORTAL="" TARGET="" INITIATOR="" KEYSRC="" REPO="" INIT_NEW=0 BACKUP_NFS="" CHAP=0 MNT=/srv/msp
while [[ $# -gt 0 ]]; do
  case "$1" in
    --portal)       PORTAL="$2"; shift 2;;
    --target)       TARGET="$2"; shift 2;;
    --initiator)    INITIATOR="$2"; shift 2;;
    --luks-key)     KEYSRC="$2"; shift 2;;
    --repo)         REPO="$2"; shift 2;;
    --init-new-lun) INIT_NEW=1; shift;;
    --backup-nfs)   BACKUP_NFS="$2"; shift 2;;
    --chap)         CHAP=1; shift;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
for v in PORTAL TARGET INITIATOR KEYSRC; do [[ -n "${!v}" ]] || { echo "missing --${v,,}" >&2; exit 2; }; done
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
[[ -r "$KEYSRC" ]] || { echo "cannot read LUKS key file: $KEYSRC" >&2; exit 1; }

say() { printf '\n== %s\n' "$*"; }

say "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg open-iscsi cryptsetup xfsprogs git jq openssl apache2-utils bzip2 >/dev/null
# Debian 13 ships the crypttab boot-time generator separately; without it /etc/crypttab is silently ignored.
apt-get install -y -qq systemd-cryptsetup >/dev/null 2>&1 || true

if ! command -v docker >/dev/null; then
  say "Docker Engine (official repo)"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi

say "iSCSI login"
echo "InitiatorName=${INITIATOR}" > /etc/iscsi/initiatorname.iscsi
systemctl restart iscsid
iscsiadm -m discovery -t sendtargets -p "${PORTAL}:3260" >/dev/null
iscsiadm -m node -T "$TARGET" -p "${PORTAL}:3260" --op update -n node.startup -v automatic
if [[ "$CHAP" == 1 ]]; then
  read -rsp "CHAP secret the VM uses (msp-app): " CS; echo
  read -rsp "CHAP secret the SAN uses (msp-san, peer): " CP; echo
  for kv in "authmethod CHAP" "username msp-app" "password $CS" "username_in msp-san" "password_in $CP"; do
    iscsiadm -m node -T "$TARGET" -p "${PORTAL}:3260" --op update -n "node.session.auth.${kv%% *}" -v "${kv#* }"
  done
  unset CS CP
fi
iscsiadm -m session 2>/dev/null | grep -q "$TARGET" || iscsiadm -m node -T "$TARGET" -p "${PORTAL}:3260" --login >/dev/null
DEVLINK="/dev/disk/by-path/ip-${PORTAL}:3260-iscsi-${TARGET}-lun-"
for _ in $(seq 1 20); do compgen -G "${DEVLINK}*" >/dev/null && break; sleep 1; done
LUNDEV="$(ls ${DEVLINK}* 2>/dev/null | grep -v -- '-part' | head -1)"
[[ -n "$LUNDEV" ]] || { echo "LUN did not appear under ${DEVLINK}*" >&2; exit 1; }
DEV="$(readlink -f "$LUNDEV")"
echo "LUN: $LUNDEV -> $DEV"

say "LUKS volume"
install -d -m 0700 /etc/msp
install -m 0400 -o root -g root "$KEYSRC" /etc/msp/luks.key
if cryptsetup isLuks "$DEV"; then
  echo "existing LUKS volume found — will unlock it (no formatting)"
elif [[ $INIT_NEW -eq 1 ]]; then
  [[ -z "$(blkid -p "$DEV" 2>/dev/null)" ]] || { echo "REFUSING to format: $DEV has a signature" >&2; exit 1; }
  echo "blank LUN — creating LUKS2 + XFS"
  cryptsetup luksFormat --type luks2 --sector-size 4096 --batch-mode --key-file /etc/msp/luks.key "$DEV"
  cryptsetup open --key-file /etc/msp/luks.key "$DEV" msp-data
  mkfs.xfs -q -L msp-data /dev/mapper/msp-data
  cryptsetup close msp-data
else
  echo "LUN is not LUKS-formatted. If it is brand new, re-run with --init-new-lun." >&2; exit 1
fi
LUKS_UUID="$(cryptsetup luksUUID "$DEV")"

say "Attach service (unlock + mount at every boot; Docker depends on it)"
# Older revisions used crypttab/fstab, which systemd does not reliably trigger for network disks.
sed -i '/^msp-data /d' /etc/crypttab 2>/dev/null || true
sed -i '\# /srv/msp #d' /etc/fstab

mkdir -p "$MNT"
cat > /usr/local/sbin/msp-data-attach <<ATTACH
#!/usr/bin/env bash
# Unlock the LUKS volume on the iSCSI LUN and mount it. Idempotent.
set -euo pipefail
LINK="/dev/disk/by-uuid/${LUKS_UUID}"
for _ in \$(seq 1 90); do [[ -e "\$LINK" ]] && break; sleep 1; done
[[ -e "\$LINK" ]] || { echo "LUN (LUKS ${LUKS_UUID}) did not appear" >&2; exit 1; }
[[ -e /dev/mapper/msp-data ]] || cryptsetup open --key-file /etc/msp/luks.key "UUID=${LUKS_UUID}" msp-data
mountpoint -q "${MNT}" || mount -o noatime,nodev,nosuid /dev/mapper/msp-data "${MNT}"
ATTACH
cat > /usr/local/sbin/msp-data-detach <<DETACH
#!/usr/bin/env bash
# Clean shutdown: flush, unmount, close. Docker is already stopped (it orders after this unit).
sync
mountpoint -q "${MNT}" && umount "${MNT}"
[[ -e /dev/mapper/msp-data ]] && cryptsetup close msp-data
exit 0
DETACH
chmod 0750 /usr/local/sbin/msp-data-attach /usr/local/sbin/msp-data-detach

cat > /etc/systemd/system/msp-data.service <<UNIT
[Unit]
Description=MSP data volume (iSCSI LUN + LUKS) mounted at ${MNT}
Wants=network-online.target
After=network-online.target iscsid.service open-iscsi.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/msp-data-attach
ExecStop=/usr/local/sbin/msp-data-detach
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
UNIT

# Docker must never start containers before the LUN is mounted, or they would
# silently create fresh empty data directories on the VM's own disk.
install -d /etc/systemd/system/docker.service.d
rm -f /etc/systemd/system/docker.service.d/10-msp-data.conf
cat > /etc/systemd/system/docker.service.d/10-msp-data.conf <<DROPIN
[Unit]
Requires=msp-data.service
After=msp-data.service
DROPIN

systemctl daemon-reload
systemctl enable msp-data.service docker.service >/dev/null 2>&1
systemctl start msp-data.service
mountpoint -q "$MNT" || { echo "mount of $MNT failed" >&2; exit 1; }
systemctl start docker

say "Application"
if [[ ! -d "$MNT/app/.git" && ! -f "$MNT/app/docker-compose.yml" ]]; then
  [[ -n "$REPO" ]] || { echo "No app on the LUN yet and no --repo given." >&2; exit 1; }
  git clone "$REPO" "$MNT/app"
fi
cd "$MNT/app"
chmod +x scripts/*.sh
[[ -f .env && -d secrets ]] || scripts/init-secrets.sh
scripts/prepare-data.sh
# The backup share is optional and must never stop the platform from coming up: a failure only warns.
if [[ -n "$BACKUP_NFS" ]]; then
  scripts/setup-backup-storage.sh --nfs "$BACKUP_NFS" || echo "WARNING: backup storage was not attached (see journalctl -u msp-backup-nfs); backups will wait" >&2
fi
docker compose up -d
docker compose ps --format 'table {{.Service}}\t{{.Status}}'
say "Done"
