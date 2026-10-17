#!/bin/bash
# AmneziaWG server installer (userspace amneziawg-go) for Debian/Ubuntu.
# Run as root on a fresh server. See README.md.
#
#   ./install.sh [options]
#     --subnet 10.79.0      tunnel /24 prefix (server gets .1)        default: 10.77.0
#     --port 443            UDP listen port                           default: 443
#     --endpoint IP|HOST    public address written into client files  default: auto-detected
#     --wan-if eth0         outgoing interface for NAT                default: from default route
#     --bin-dir DIR         use prebuilt amneziawg-go, awg, awg-quick from DIR (skip build)
#     --build-only DIR      only build the three binaries into DIR and exit
#     --first-client NAME   create a client right after install       default: none
#     --no-service          write files only: no systemd, sysctl, firewall (for testing)
#     --allow-outdated      do not stop if this git checkout is behind upstream
set -euo pipefail

# Started through `curl ... | bash` (no kit checkout next to this script): fetch the kit into
# /opt/awg-vps-kit (or fast-forward the clone there) and continue from it, so the result does
# not depend on the current folder.
if [ ! -f "$(dirname "$0")/awg-client" ]; then
  KIT=/opt/awg-vps-kit
  [ "$(id -u)" = 0 ] || { echo "error: run as root" >&2; exit 1; }
  command -v git >/dev/null || { apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null; }
  if [ -d "$KIT/.git" ]; then
    git -C "$KIT" pull --ff-only -q || { echo "error: cannot fast-forward $KIT (local changes?)" >&2; exit 1; }
  elif [ -e "$KIT" ]; then
    echo "error: $KIT exists but is not a clone of the kit; move it away and run this again" >&2; exit 1
  else
    git clone -q https://github.com/thejohnd0e/awg-vps-kit.git "$KIT"
  fi
  exec "$KIT/install.sh" "$@"
fi

SUBNET=10.77.0; PORT=443; ENDPOINT=; WAN_IF=; BIN_DIR=; BUILD_ONLY=; FIRST=; NO_SERVICE=0; ALLOW_OUTDATED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --subnet) SUBNET=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    --endpoint) ENDPOINT=$2; shift 2 ;;
    --wan-if) WAN_IF=$2; shift 2 ;;
    --bin-dir) BIN_DIR=$2; shift 2 ;;
    --build-only) BUILD_ONLY=$2; shift 2 ;;
    --first-client) FIRST=$2; shift 2 ;;
    --no-service) NO_SERVICE=1; shift ;;
    --allow-outdated) ALLOW_OUTDATED=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
DIR=/etc/amnezia/amneziawg
IF=awg0
log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[[ "$SUBNET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "--subnet must look like 10.79.0"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
command -v apt-get >/dev/null || die "only Debian/Ubuntu (apt) is supported"
export DEBIAN_FRONTEND=noninteractive

# Fail early, before the (slow) build: an existing install and a busy UDP port.
if [ -z "$BUILD_ONLY" ]; then
  if [ -f "$DIR/$IF.conf" ]; then die "$DIR/$IF.conf already exists, refusing to overwrite (remove it first if this is intended)"; fi
  if [ "$NO_SERVICE" = 0 ] && command -v ss >/dev/null; then
    busy=$(ss -H -ulnp "sport = :$PORT" 2>/dev/null || true)
    [ -z "$busy" ] || die "UDP port $PORT is already in use:
$busy
stop that service or pick another port with --port"
  fi
fi

# Warn if this checkout is behind its upstream: the installer installs what is here.
if [ -z "$BUILD_ONLY" ] && [ "$ALLOW_OUTDATED" = 0 ] && command -v git >/dev/null && [ -d "$HERE/.git" ] \
   && git -C "$HERE" rev-parse -q --verify '@{u}' >/dev/null 2>&1 \
   && timeout 15 git -C "$HERE" fetch -q 2>/dev/null; then
  behind=$(git -C "$HERE" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
  [ "$behind" = 0 ] || die "this checkout is $behind commit(s) behind upstream; run: git -C $HERE pull   (or pass --allow-outdated)"
fi

# ---------------------------------------------------------------- build
build_binaries() {  # build_binaries <outdir>
  local out=$1 src go_bin need have
  mkdir -p "$out"
  log "Installing build dependencies"
  apt-get update -qq
  apt-get install -y -qq git make gcc curl ca-certificates >/dev/null

  src=$(mktemp -d /var/tmp/awg-build.XXXXXX)
  trap 'rm -rf "$src"' RETURN
  git clone -q --depth 1 https://github.com/amnezia-vpn/amneziawg-go "$src/awg-go"
  git clone -q --depth 1 https://github.com/amnezia-vpn/amneziawg-tools "$src/awg-tools"
  echo "amneziawg-go:    $(git -C "$src/awg-go" log -1 --format='%h %ad' --date=short)"
  echo "amneziawg-tools: $(git -C "$src/awg-tools" log -1 --format='%h %ad' --date=short)"

  # Go: distro package if it is new enough, otherwise the official tarball.
  need=$(awk '$1=="go"{print $2; exit}' "$src/awg-go/go.mod")
  have=
  if ! command -v go >/dev/null; then
    log "Installing golang-go from apt (can take a minute)"
    apt-get install -y -qq golang-go >/dev/null 2>&1 || true
  fi
  if command -v go >/dev/null; then have=$(go env GOVERSION | sed 's/^go//'); fi
  if [ -z "$have" ] || [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)" != "$need" ]; then
    log "Go $need or newer is needed (have: ${have:-none}), downloading the official toolchain"
    local arch json file sha
    case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) die "unsupported CPU $(uname -m)" ;; esac
    json=$(curl -fsSL 'https://go.dev/dl/?mode=json')
    file=$(printf '%s\n' "$json" | grep -o "\"filename\": \"go[0-9.]*\.linux-$arch\.tar\.gz\"" | head -1 | cut -d'"' -f4)
    [ -n "$file" ] || die "cannot find a Go tarball for $arch"
    sha=$(printf '%s\n' "$json" | grep -A8 "\"filename\": \"$file\"" | grep '"sha256"' | head -1 | cut -d'"' -f4)
    curl -fL -# "https://go.dev/dl/$file" -o "$src/go.tgz"
    [ "$(sha256sum "$src/go.tgz" | cut -d' ' -f1)" = "$sha" ] || die "Go tarball checksum mismatch"
    tar -C "$src" -xzf "$src/go.tgz"          # extracts to $src/go
    go_bin=$src/go/bin/go
  else
    go_bin=$(command -v go)
  fi
  echo "go: $("$go_bin" version)"

  log "Building amneziawg-go (low-memory settings, can take a few minutes, no output until done)"
  ( cd "$src/awg-go" && GOFLAGS=-p=1 GOGC=50 "$go_bin" build -trimpath -ldflags="-s -w" -o "$out/amneziawg-go" . )
  log "Building awg and awg-quick"
  ( cd "$src/awg-tools/src" && make -j1 >/dev/null )
  cp "$src/awg-tools/src/wg" "$out/awg"
  cp "$src/awg-tools/src/wg-quick/linux.bash" "$out/awg-quick"
  chmod 755 "$out/amneziawg-go" "$out/awg" "$out/awg-quick"
  {
    echo "amneziawg-go=$(git -C "$src/awg-go" rev-parse HEAD)"
    echo "amneziawg-tools=$(git -C "$src/awg-tools" rev-parse HEAD)"
  } > "$out/versions"
}

if [ -n "$BUILD_ONLY" ]; then
  build_binaries "$BUILD_ONLY"
  ls -la "$BUILD_ONLY"
  exit 0
fi

# ------------------------------------------------------------- binaries
if [ -z "$BIN_DIR" ]; then
  BIN_DIR=/opt/amneziawg/bin
  build_binaries "$BIN_DIR"
fi
for f in amneziawg-go awg awg-quick; do [ -x "$BIN_DIR/$f" ] || die "missing $BIN_DIR/$f"; done
log "Installing binaries to /usr/local/bin"
apt-get install -y -qq iproute2 nftables qrencode curl >/dev/null
install -m 755 "$BIN_DIR/amneziawg-go" "$BIN_DIR/awg" "$BIN_DIR/awg-quick" /usr/local/bin/
install -m 755 "$HERE/awg-client" /usr/local/bin/awg-client

# -------------------------------------------------------- network facts
[ -n "$WAN_IF" ] || WAN_IF=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$WAN_IF" ] || die "cannot detect the outgoing interface, pass --wan-if"
if [ -z "$ENDPOINT" ]; then
  ENDPOINT=$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)
  [ -n "$ENDPOINT" ] || die "cannot detect the public IP, pass --endpoint"
fi

# ----------------------------------------------------------- parameters
rnd32() { local v=0; while [ "$v" -lt 5 ]; do v=$(od -An -N4 -tu4 /dev/urandom | tr -d " "); done; echo "$v"; }
H=()
while [ ${#H[@]} -lt 4 ]; do
  v=$(rnd32)
  case " ${H[*]} " in *" $v "*) ;; *) H+=("$v") ;; esac
done
S1=$(shuf -i 15-150 -n 1); S2=$(shuf -i 15-150 -n 1)
while [ $((S1 + 56)) -eq "$S2" ]; do S2=$(shuf -i 15-150 -n 1); done

mkdir -p "$DIR/clients"; chmod 700 "$DIR"; umask 077
awg genkey | tee "$DIR/srv.key" | awg pubkey > "$DIR/srv.pub"
[ ! -f "$BIN_DIR/versions" ] || install -m 644 "$BIN_DIR/versions" "$DIR/versions"
{
  echo "version=$(tr -d '\r\n ' < "$HERE/VERSION" 2>/dev/null || echo unknown)"
  echo "commit=$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
} > "$DIR/kit-version"
echo "$ENDPOINT" > "$DIR/endpoint"

# -------------------------------------------------------------- firewall
# NAT through nftables (own table, removed on stop).
cat > "$DIR/nat-up.nft" <<EOF
table ip awg_nat {
  chain post {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $SUBNET.0/24 oifname "$WAN_IF" masquerade
  }
  chain awg_forward {
    type filter hook forward priority filter - 1; policy accept;
    iifname "$IF" accept
    oifname "$IF" ct state established,related accept
  }
}
EOF

cat > "$DIR/$IF.conf" <<EOF
[Interface]
PrivateKey = $(cat "$DIR/srv.key")
Address = $SUBNET.1/24
ListenPort = $PORT
MTU = 1280
Jc = 5
Jmin = 40
Jmax = 900
S1 = $S1
S2 = $S2
H1 = ${H[0]}
H2 = ${H[1]}
H3 = ${H[2]}
H4 = ${H[3]}
PostUp = nft -f $DIR/nat-up.nft
PostDown = nft delete table ip awg_nat
EOF
install -m 644 "$HERE/README.md" "$DIR/README.md"

if [ "$NO_SERVICE" = 1 ]; then
  log "Files written (--no-service): $DIR"
else
  log "Enabling IP forwarding"
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-awg.conf
  sysctl -q -p /etc/sysctl.d/99-awg.conf

  # ufw (if active) also needs the UDP port and a forwarding rule; its own FORWARD
  # policy is DROP and would block the tunnel even though the nft table accepts it.
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    log "ufw is active: allowing $PORT/udp and routing $IF -> $WAN_IF"
    ufw allow "$PORT/udp" >/dev/null
    ufw route allow in on "$IF" out on "$WAN_IF" >/dev/null
  fi

  log "Creating systemd service awg-quick@$IF"
  cat > /etc/systemd/system/awg-quick@.service <<'EOF'
[Unit]
Description=AmneziaWG %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
Environment=WG_QUICK_CONFIG_DIR=/etc/amnezia/amneziawg
ExecStart=/usr/local/bin/awg-quick up %i
ExecStop=/usr/local/bin/awg-quick down %i

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "awg-quick@$IF"
  systemctl start "awg-quick@$IF" || true
  sleep 2
  systemctl is-active "awg-quick@$IF" >/dev/null || { journalctl -u "awg-quick@$IF" -n 30 --no-pager; die "service did not start (config left in $DIR: remove it before re-running)"; }
  awg show "$IF" | head -5
fi

cat <<EOF

AmneziaWG server is ready.
  Address:  $ENDPOINT:$PORT/udp   tunnel $SUBNET.0/24   NAT via $WAN_IF
  Config:   $DIR/$IF.conf
  Help:     awg-client help      (full notes: $DIR/README.md)
If the provider has an external firewall / security group, open UDP $PORT there.
EOF

if [ -n "$FIRST" ] && [ "$NO_SERVICE" = 0 ]; then
  log "Creating first client: $FIRST"
  awg-client add "$FIRST"
fi
