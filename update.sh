#!/bin/bash
# AWG VPS Kit updater: pulls the kit (if this is a git checkout), rebuilds the
# amneziawg binaries from upstream when they are newer, restarts the service.
# Server config and clients are not touched. Run as root from the cloned repo.
#
#   ./update.sh --check       only report what is outdated
#   ./update.sh               update what is outdated
#   --force                   rebuild binaries even if up to date
#   --bin-dir DIR             use prebuilt amneziawg-go, awg, awg-quick from DIR (skip build)
#   --no-restart              do not restart awg-quick@awg0 (new binaries apply after restart)
set -euo pipefail

CHECK=0; FORCE=0; BIN_DIR=; NO_RESTART=0; SKIP_KIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --force) FORCE=1; shift ;;
    --bin-dir) BIN_DIR=$2; shift 2 ;;
    --no-restart) NO_RESTART=1; shift ;;
    --skip-kit) SKIP_KIT=1; shift ;;   # internal: set after the kit was pulled
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
DIR=/etc/amnezia/amneziawg
IF=awg0
UP_GO=https://github.com/amnezia-vpn/amneziawg-go
UP_TOOLS=https://github.com/amnezia-vpn/amneziawg-tools
log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$DIR/$IF.conf" ] || die "$DIR/$IF.conf not found: nothing installed here (use install.sh)"

# ------------------------------------------------------------------ kit
if [ "$SKIP_KIT" = 0 ] && [ -d "$HERE/.git" ] && command -v git >/dev/null \
   && git -C "$HERE" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
  git -C "$HERE" fetch -q
  behind=$(git -C "$HERE" rev-list --count 'HEAD..@{u}')
  if [ "$behind" -gt 0 ]; then
    echo "kit (scripts, README): $behind new commit(s) available"
    if [ "$CHECK" = 0 ]; then
      git -C "$HERE" pull --ff-only -q || die "cannot fast-forward $HERE (local changes?)"
      exec bash "$HERE/update.sh" --skip-kit "$@"   # continue with the updated script
    fi
  else
    echo "kit (scripts, README): up to date"
  fi
fi

# ------------------------------------------------------------- binaries
installed() { awk -F= -v k="$1" '$1==k{print $2}' "$DIR/versions" 2>/dev/null || true; }
upstream() { git ls-remote "$1" HEAD | cut -f1; }

outdated=0
for comp in go tools; do
  if [ "$comp" = go ]; then name=amneziawg-go; url=$UP_GO; else name=amneziawg-tools; url=$UP_TOOLS; fi
  have=$(installed "$name"); want=$(upstream "$url")
  [ -n "$want" ] || die "cannot reach $url"
  if [ "$have" = "$want" ]; then
    echo "$name: up to date (${have:0:7})"
  else
    shown=${have:0:7}
    echo "$name: ${shown:-unknown} -> ${want:0:7}"
    outdated=1
  fi
done

if [ "$CHECK" = 1 ]; then
  if [ "$outdated" = 1 ]; then echo "Update available: run ./update.sh"; else echo "Binaries are up to date."; fi
  exit 0
fi

replaced=0
if [ "$outdated" = 1 ] || [ "$FORCE" = 1 ]; then
  if [ -z "$BIN_DIR" ]; then
    BIN_DIR=$(mktemp -d /var/tmp/awg-update.XXXXXX)
    trap 'rm -rf "$BIN_DIR"' EXIT
    log "Building new binaries (a few minutes)"
    bash "$HERE/install.sh" --build-only "$BIN_DIR" >/dev/null
  fi
  for f in amneziawg-go awg awg-quick; do [ -x "$BIN_DIR/$f" ] || die "missing $BIN_DIR/$f"; done

  log "Installing binaries (previous ones saved to /opt/amneziawg/prev)"
  mkdir -p /opt/amneziawg/prev
  for f in amneziawg-go awg awg-quick; do
    [ ! -f "/usr/local/bin/$f" ] || cp -p "/usr/local/bin/$f" "/opt/amneziawg/prev/$f"
    install -m 755 "$BIN_DIR/$f" "/usr/local/bin/$f.new"
    mv -f "/usr/local/bin/$f.new" "/usr/local/bin/$f"     # safe while the old binary is running
  done
  [ ! -f "$BIN_DIR/versions" ] || install -m 644 "$BIN_DIR/versions" "$DIR/versions"
  replaced=1
fi

# scripts and docs always follow the checkout
install -m 755 "$HERE/awg-client" /usr/local/bin/awg-client
install -m 644 "$HERE/README.md" "$DIR/README.md"

if [ "$replaced" = 1 ] && [ "$NO_RESTART" = 0 ] && command -v systemctl >/dev/null \
   && systemctl is-active --quiet "awg-quick@$IF"; then
  log "Restarting awg-quick@$IF (clients reconnect in a few seconds)"
  systemctl restart "awg-quick@$IF"
  sleep 2
  systemctl is-active --quiet "awg-quick@$IF" || { journalctl -u "awg-quick@$IF" -n 30 --no-pager; die "service did not start; previous binaries are in /opt/amneziawg/prev"; }
  awg show "$IF" | head -3
elif [ "$replaced" = 1 ]; then
  echo "New binaries apply after: systemctl restart awg-quick@$IF"
fi
echo "Done."
