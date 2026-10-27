#!/usr/bin/env bash
# Host firewall for the platform VM. Run as root.
#   sudo scripts/install-host-firewall.sh            apply now and keep across reboots (msp-firewall.service)
#   sudo scripts/install-host-firewall.sh --remove   take the rules out and disable the service
#
# Why: Docker publishes the service ports (authentik, Grafana, portal, gateway, backup server, MeshCentral) on the VM's
# management address. Without this, ANY machine on that network can reach them directly over plain HTTP and skip NPM,
# its TLS and its security headers. Docker's own rules bypass ufw/INPUT, so the control belongs in the DOCKER-USER chain.
#
# Rules (own chain MSP-FW, so nothing else is touched):
#   - connections from the management NIC to a published port are dropped unless the source is NPM_IP (.env) or one of
#     FW_ALLOW_FROM (.env, space separated: your admin workstation for troubleshooting)
#   - traffic the VM sends to itself, container-to-container traffic and the storage NIC are not affected
#   - rpcbind (port 111) is closed to everything but this machine (an NFS client does not need it open)
# SSH stays open. After applying, the script fetches the portal THROUGH NPM; if that fails it removes its own rules again.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(pwd)"
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
set -a; source .env; set +a

CHAIN=MSP-FW
UNIT=/etc/systemd/system/msp-firewall.service

remove_rules() {
  while iptables -C DOCKER-USER -j "$CHAIN" 2>/dev/null; do iptables -D DOCKER-USER -j "$CHAIN"; done
  iptables -F "$CHAIN" 2>/dev/null || true; iptables -X "$CHAIN" 2>/dev/null || true
  for p in tcp udp; do while iptables -C INPUT -p "$p" --dport 111 ! -i lo -m comment --comment msp-fw -j DROP 2>/dev/null; do iptables -D INPUT -p "$p" --dport 111 ! -i lo -m comment --comment msp-fw -j DROP; done; done
}

if [[ "${1:-}" == "--remove" ]]; then
  systemctl disable --now msp-firewall.service 2>/dev/null || true
  remove_rules; rm -f "$UNIT"; systemctl daemon-reload
  echo "Host firewall removed."; exit 0
fi
if [[ "${1:-}" == "--remove-rules" ]]; then remove_rules; exit 0; fi   # used by the service on stop
mode="${1:-}"
[[ -z "$mode" || "$mode" == "--reapply" ]] || { echo "usage: install-host-firewall.sh [--remove]" >&2; exit 2; }
for _ in $(seq 1 30); do iptables -S DOCKER-USER >/dev/null 2>&1 && break; sleep 2; done   # Docker creates the chain when it starts
NIC="${FW_NIC:-$(ip -4 -o addr show | awk -v b="${BIND_ADDR}" '$4 ~ "^"b"/" {print $2}' | head -1)}"
[[ -n "$NIC" ]] || { echo "cannot find the network interface that holds ${BIND_ADDR}; set FW_NIC in .env" >&2; exit 1; }
[[ "${BIND_ADDR}" != "127.0.0.1" ]] || { echo "BIND_ADDR is loopback: the ports are already local only, nothing to do"; exit 0; }
PORTS="${AUTHENTIK_PORT:-9000} ${GRAFANA_PORT:-3000} ${GATEWAY_PORT:-8080} ${MESH_PORT:-4430} ${RESTIC_PORT:-8000} ${PORTAL_PORT:-3100}"
ALLOW="${NPM_IP} ${FW_ALLOW_FROM:-}"
[[ "$NPM_IP" =~ ^[0-9.]+$ ]] || { echo "NPM_IP in .env is not an address" >&2; exit 1; }

apply_rules() {
  remove_rules
  iptables -N "$CHAIN"
  for port in $PORTS; do
    for src in $ALLOW; do
      iptables -A "$CHAIN" -i "$NIC" -s "$src" -p tcp -m conntrack --ctorigdstport "$port" -j RETURN
    done
    iptables -A "$CHAIN" -i "$NIC" -p tcp -m conntrack --ctorigdstport "$port" -m comment --comment msp-fw -j DROP
  done
  iptables -A "$CHAIN" -j RETURN
  iptables -I DOCKER-USER 1 -j "$CHAIN"
  for p in tcp udp; do iptables -I INPUT 1 -p "$p" --dport 111 ! -i lo -m comment --comment msp-fw -j DROP; done
}

apply_rules
if [[ "$mode" == "--reapply" ]]; then echo "msp-firewall re-applied"; exit 0; fi   # boot: the self-test below ran when it was installed
# prove NPM still gets through: fetch the portal via its public name (goes VM -> NPM -> VM:PORTAL_PORT)
code="000"
for _ in 1 2 3; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${PORTAL_HOST}/" || true)"
  [[ "$code" =~ ^[234] ]] && break; sleep 3
done
if [[ ! "$code" =~ ^[234] ]]; then
  echo "SELF-TEST FAILED: https://${PORTAL_HOST}/ answered '${code}' with the firewall on. Rules removed again." >&2
  remove_rules; exit 1
fi
echo "self-test ok: https://${PORTAL_HOST}/ -> ${code} through NPM (${NPM_IP})"

cat > "$UNIT" <<UNIT
[Unit]
Description=MSP host firewall (only NPM may reach the published service ports)
After=docker.service network-online.target
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${APP}/scripts/install-host-firewall.sh --reapply
ExecStop=${APP}/scripts/install-host-firewall.sh --remove-rules

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable msp-firewall.service >/dev/null
echo "Installed msp-firewall.service (re-applied after every boot). Rules in effect:"
iptables -S "$CHAIN" | sed 's/^/  /'
