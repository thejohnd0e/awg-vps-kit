#!/bin/bash
# AWG VPS Kit uninstaller: stops the service and removes everything install.sh created.
# Installed apt packages (nftables, qrencode, ...) are left alone. Run as root.
#
#   ./uninstall.sh            ask for confirmation, then remove everything
#   -y, --yes                 do not ask
#   --keep-config             keep /etc/amnezia (server keys, clients) for a later reinstall
set -euo pipefail

YES=0; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) YES=1; shift ;;
    --keep-config) KEEP=1; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

DIR=/etc/amnezia/amneziawg
IF=awg0
die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"

echo "This will stop awg-quick@$IF and remove:"
echo "  - systemd unit, /etc/sysctl.d/99-awg.conf, nftables table awg_nat, ufw rules (if any)"
echo "  - /usr/local/bin/{amneziawg-go,awg,awg-quick,awg-client} and /opt/amneziawg"
if [ "$KEEP" = 1 ]; then echo "  (keeping /etc/amnezia: keys and clients)"; else echo "  - /etc/amnezia (server keys and ALL client configs)"; fi
if [ "$YES" = 0 ]; then
  read -r -p "Type 'yes' to continue: " ans
  [ "$ans" = yes ] || die "aborted"
fi

port=$(awk '$1=="ListenPort"{print $3; exit}' "$DIR/$IF.conf" 2>/dev/null || true)
wan=$(grep -o 'oifname "[^"]*" masquerade' "$DIR/nat-up.nft" 2>/dev/null | cut -d'"' -f2 || true)

if command -v systemctl >/dev/null; then
  systemctl disable --now "awg-quick@$IF" 2>/dev/null || true
fi
# no systemd (or the unit was not used): bring the interface down directly
if command -v ip >/dev/null && ip link show "$IF" >/dev/null 2>&1 && [ -x /usr/local/bin/awg-quick ]; then
  WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go WG_QUICK_CONFIG_DIR=$DIR /usr/local/bin/awg-quick down "$IF" || true
fi
if command -v nft >/dev/null; then nft delete table ip awg_nat 2>/dev/null || true; fi

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  [ -z "$port" ] || ufw delete allow "$port/udp" >/dev/null 2>&1 || true
  [ -z "$wan" ] || ufw route delete allow in on "$IF" out on "$wan" >/dev/null 2>&1 || true
fi

rm -f /etc/systemd/system/awg-quick@.service /etc/sysctl.d/99-awg.conf
if command -v systemctl >/dev/null; then systemctl daemon-reload || true; fi
rm -f /usr/local/bin/amneziawg-go /usr/local/bin/awg /usr/local/bin/awg.real /usr/local/bin/awg-quick /usr/local/bin/awg-client
rm -rf /opt/amneziawg
if [ "$KEEP" = 0 ]; then rm -rf /etc/amnezia; fi

echo "Removed. Note: net.ipv4.ip_forward stays enabled until reboot; the cloned repo was not deleted."
