#!/usr/bin/env bash
# Install the pinned restic binary on this host (used by the server-side backup maintenance jobs). Run as root.
# The download is verified against the SHA256 pinned in agent/backup/version.env; a mismatch installs nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
source agent/backup/version.env
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }

arch="$(uname -m)"
case "$arch" in
  x86_64)  file="$RESTIC_LINUX_AMD64_FILE"; want="$RESTIC_LINUX_AMD64_SHA256";;
  aarch64) file="$RESTIC_LINUX_ARM64_FILE"; want="$RESTIC_LINUX_ARM64_SHA256";;
  *) echo "unsupported architecture: $arch" >&2; exit 1;;
esac

if [[ -x /usr/local/bin/restic ]] && /usr/local/bin/restic version 2>/dev/null | grep -q " ${RESTIC_VERSION} "; then
  echo "restic ${RESTIC_VERSION} already installed"; exit 0
fi

tmp="$(mktemp -d)"; trap 'rm -rf -- "${tmp:?}"' EXIT
ok=0
for attempt in 1 2 3 4; do
  curl -fsSL --retry 3 -o "$tmp/$file" "${RESTIC_URL_BASE}/${file}" || true
  if [[ "$(sha256sum "$tmp/$file" 2>/dev/null | cut -d' ' -f1)" == "$want" ]]; then ok=1; break; fi
  echo "download attempt ${attempt}: hash mismatch or incomplete; retrying" >&2; sleep $((attempt*3))
done
[[ "$ok" == 1 ]] || { echo "could not get a restic build matching the pinned SHA256; nothing installed" >&2; exit 1; }
echo "download verified (SHA256 matches)"
bunzip2 -c "$tmp/$file" > "$tmp/restic"
install -m 0755 "$tmp/restic" /usr/local/bin/restic
/usr/local/bin/restic version
