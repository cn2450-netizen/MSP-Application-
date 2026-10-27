#!/usr/bin/env bash
# Configure (or remove) CHAP on this VM's iSCSI login to the data LUN. Run as root.
#
#   sudo scripts/iscsi-set-chap.sh --generate [--target IQN] [--portal IP]
#       Makes two random 16-character secrets (one for the VM to prove itself to the SAN, one for the SAN to prove itself
#       to the VM = mutual CHAP), stores them in the iSCSI node record (root-only, /etc/iscsi/nodes), and PRINTS them once
#       so you can type them into TrueNAS. Nothing is written to any other file. Put them in your vault.
#   sudo scripts/iscsi-set-chap.sh --set          ask for the secrets instead (rebuilds: take them from the vault)
#   sudo scripts/iscsi-set-chap.sh --oneway       keep the VM's CHAP login but stop asking the SAN to prove itself (clears the peer settings)
#   sudo scripts/iscsi-set-chap.sh --disable      back to no authentication (rollback)
#   sudo scripts/iscsi-set-chap.sh --status       show what is configured (never prints secrets) and the live session
#
# The running session is not touched. The new settings apply the next time the VM logs in (reboot, or
# `iscsiadm -m node -T IQN --logout` then `--login` - only with the platform stopped).
# The target and portal default to the ones found in the node record.
set -euo pipefail

USER_NAME="${CHAP_USER:-msp-app}"          # what the VM calls itself
PEER_NAME="${CHAP_PEER_USER:-msp-san}"     # what the SAN calls itself (mutual CHAP)
TARGET="" PORTAL="" mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --generate|--set|--disable|--status|--oneway) mode="${1#--}"; shift;;
    --target) TARGET="${2:?}"; shift 2;;
    --portal) PORTAL="${2:?}"; shift 2;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[[ -n "$mode" ]] || { sed -n 2,16p "$0" | sed 's/^# \?//'; exit 2; }
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }

if [[ -z "$TARGET" ]]; then
  TARGET="$(iscsiadm -m node 2>/dev/null | awk '{print $2}' | head -1)"
  [[ -n "$TARGET" ]] || { echo "no iSCSI node record found; pass --target" >&2; exit 1; }
fi
if [[ -z "$PORTAL" ]]; then
  PORTAL="$(iscsiadm -m node 2>/dev/null | awk -v t="$TARGET" '$2==t{print $1}' | head -1 | sed 's/,.*//')"
fi
[[ -n "$PORTAL" ]] || { echo "cannot work out the portal; pass --portal IP:3260" >&2; exit 1; }
upd() { iscsiadm -m node -T "$TARGET" -p "$PORTAL" --op update -n "$1" -v "$2" >/dev/null; }

valid() { [[ "${#1}" -ge 12 && "${#1}" -le 16 ]]; }
rand16() { openssl rand -base64 48 | tr -dc 'A-HJ-NP-Za-km-z2-9' | head -c 16; }

case "$mode" in
  status)
    echo "target ${TARGET}  portal ${PORTAL}"
    iscsiadm -m node -T "$TARGET" -p "$PORTAL" 2>/dev/null | grep -E "node.session.auth.(authmethod|username|username_in)" | sed 's/^/  /'
    iscsiadm -m node -T "$TARGET" -p "$PORTAL" 2>/dev/null | grep -qE "node.session.auth.password += \*+" && echo "  secret: set" || echo "  secret: not set"
    iscsiadm -m session 2>/dev/null | sed 's/^/  live session: /' || true
    exit 0;;
  oneway)
    upd node.session.auth.username_in ""; upd node.session.auth.password_in ""
    echo "Peer (mutual) settings cleared; the VM still logs in with CHAP as ${USER_NAME}. Set the TrueNAS target to plain CHAP."
    exit 0;;
  disable)
    upd node.session.auth.authmethod None
    for k in username password username_in password_in; do upd "node.session.auth.$k" ""; done
    echo "CHAP removed from the VM side. Also set the target's Authorized Access back to None in TrueNAS."
    exit 0;;
  generate)
    secret="$(rand16)"; peer="$(rand16)"
    valid "$secret" && valid "$peer" && [[ "$secret" != "$peer" ]] || { echo "could not generate secrets" >&2; exit 1; }
    ;;
  set)
    read -rsp "Secret the VM uses (12-16 chars): " secret; echo
    read -rsp "Type it again to confirm: " again; echo
    [[ "$secret" == "$again" ]] || { echo "the two entries differ" >&2; exit 1; }
    read -rsp "Secret the SAN uses (peer; 12-16 chars, different; ENTER for none = one-way CHAP): " peer; echo
    valid "$secret" || { echo "secret must be 12-16 characters" >&2; exit 1; }
    [[ -z "$peer" ]] || { valid "$peer" && [[ "$secret" != "$peer" ]] || { echo "peer secret must be 12-16 characters and different" >&2; exit 1; }; }
    ;;
esac

upd node.session.auth.authmethod CHAP
upd node.session.auth.username "$USER_NAME"
upd node.session.auth.password "$secret"
if [[ -n "$peer" ]]; then upd node.session.auth.username_in "$PEER_NAME"; upd node.session.auth.password_in "$peer"; else upd node.session.auth.username_in ""; upd node.session.auth.password_in ""; fi
echo "Stored in the iSCSI node record for ${TARGET} ($([[ -n "$peer" ]] && echo mutual || echo one-way) CHAP)."

if [[ "$mode" == generate ]]; then
  cat <<EOF

==========================  WRITE THESE DOWN (shown once)  ==========================
  TrueNAS "Authorized Access" entry:
      Group ID      : 1   (any unused number)
      User          : ${USER_NAME}
      Secret        : ${secret}
      Peer User     : ${PEER_NAME}
      Peer Secret   : ${peer}
=====================================================================================
Put both secrets in your vault. A rebuilt VM needs them (iscsi-set-chap.sh --set).
EOF
fi
