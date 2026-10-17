#!/bin/bash
# AWG VPS Kit uninstaller: stops the service and removes everything install.sh created.
# Installed apt packages (nftables, qrencode, ...) are left alone. Run as root.
#
#   curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/uninstall.sh | bash -s -- [options]
#   -y, --yes                 do not ask for confirmation
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

# Nothing of ours on this machine: say so instead of asking to confirm a removal.
found=0
for f in "$DIR" /etc/amnezia /etc/systemd/system/awg-quick@.service /etc/sysctl.d/99-awg.conf \
         /usr/local/bin/amneziawg-go /usr/local/bin/awg /usr/local/bin/awg-quick \
         /usr/local/bin/awg-client /opt/amneziawg /opt/awg-vps-kit; do
  [ ! -e "$f" ] || { found=1; break; }
done
if [ "$found" = 0 ] && command -v ip >/dev/null && ip link show "$IF" >/dev/null 2>&1; then found=1; fi
if [ "$found" = 0 ] && command -v pgrep >/dev/null && pgrep -f "amneziawg-go $IF\$" >/dev/null; then found=1; fi
if [ "$found" = 0 ]; then echo "AWG VPS Kit is not installed here: nothing to remove."; exit 0; fi

echo "This will stop awg-quick@$IF and remove:"
echo "  - systemd unit, /etc/sysctl.d/99-awg.conf, nftables table awg_nat, ufw rules (if any)"
echo "  - /usr/local/bin/{amneziawg-go,awg,awg-quick,awg-client}, /opt/amneziawg and /opt/awg-vps-kit"
if [ "$KEEP" = 1 ]; then echo "  (keeping /etc/amnezia: keys and clients)"; else echo "  - /etc/amnezia (server keys and ALL client configs)"; fi
if [ "$YES" = 0 ]; then
  # stdin may be the script itself (curl | bash): ask on the terminal
  { true </dev/tty; } 2>/dev/null || die "no terminal to ask on: pass --yes"
  read -r -p "Type 'yes' to continue: " ans </dev/tty
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
# amneziawg-go can outlive a failed or interrupted `up` and keep holding the UDP port
if command -v pkill >/dev/null; then pkill -f "amneziawg-go $IF\$" 2>/dev/null || true; fi
if command -v ip >/dev/null; then ip link delete "$IF" 2>/dev/null || true; fi
rm -f "/var/run/amneziawg/$IF.sock"
if command -v nft >/dev/null; then nft delete table ip awg_nat 2>/dev/null || true; fi

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  [ -z "$port" ] || ufw delete allow "$port/udp" >/dev/null 2>&1 || true
  [ -z "$wan" ] || ufw route delete allow in on "$IF" out on "$wan" >/dev/null 2>&1 || true
fi

rm -f /etc/systemd/system/awg-quick@.service /etc/sysctl.d/99-awg.conf
if command -v systemctl >/dev/null; then systemctl daemon-reload || true; fi
rm -f /usr/local/bin/amneziawg-go /usr/local/bin/awg /usr/local/bin/awg.real /usr/local/bin/awg-quick /usr/local/bin/awg-client
rm -rf /opt/amneziawg /opt/awg-vps-kit
if [ "$KEEP" = 0 ]; then rm -rf /etc/amnezia; fi

if [ -n "$port" ] && command -v ss >/dev/null; then
  sleep 1
  busy=$(ss -H -ulnp "sport = :$port" 2>/dev/null || true)
  [ -z "$busy" ] || printf 'warning: UDP port %s is still in use by another process:\n%s\n' "$port" "$busy"
fi

echo "Removed. Note: net.ipv4.ip_forward stays enabled until reboot."
