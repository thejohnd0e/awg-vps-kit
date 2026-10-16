#!/bin/bash
# AWG VPS Kit updater: compares the installed versions with the latest ones and
# updates only when something is newer: the kit itself (git pull) and the
# amneziawg binaries (rebuilt from upstream), then restarts the service.
# Server config and clients are not touched. Run as root from the cloned repo.
#
#   ./update.sh --check       only report (exit 0: latest installed, 10: update available)
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
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

installed() { awk -F= -v k="$1" '$1==k{print $2}' "$DIR/versions" 2>/dev/null || true; }
upstream() { git ls-remote "$1" HEAD | cut -f1; }
# scripts, docs and the recorded kit version always follow the checkout
refresh_scripts() {
  install -m 755 "$HERE/awg-client" /usr/local/bin/awg-client
  install -m 644 "$HERE/README.md" "$DIR/README.md"
  printf 'version=%s\ncommit=%s\n' "$(tr -d '\r\n ' < "$HERE/VERSION" 2>/dev/null || echo unknown)" \
    "$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)" > "$DIR/kit-version"
}

changes=()
curver=$(tr -d '\r\n ' < "$HERE/VERSION" 2>/dev/null || echo unknown)

# ------------------------------------------------------------------ kit
behind=0
if [ "$SKIP_KIT" = 0 ] && [ -d "$HERE/.git" ] && command -v git >/dev/null \
   && git -C "$HERE" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
  git -C "$HERE" fetch -q
  behind=$(git -C "$HERE" rev-list --count 'HEAD..@{u}')
  if [ "$behind" -gt 0 ]; then
    newver=$(git -C "$HERE" show '@{u}:VERSION' 2>/dev/null | tr -d '\r\n ' || true)
    if [ -z "$newver" ] || [ "$newver" = "$curver" ]; then
      kitdesc="$curver (+$behind commit(s))"
    else
      kitdesc="$curver -> $newver"
    fi
    echo "kit: $kitdesc"
    changes+=("kit $kitdesc")
  else
    echo "kit: up to date ($curver)"
  fi
elif [ "$SKIP_KIT" = 0 ]; then
  echo "kit: $curver (not a git checkout with upstream, not checked)"
fi

# ------------------------------------------------------------- binaries
bin_outdated=0
latest="kit $curver"
for comp in go tools; do
  if [ "$comp" = go ]; then name=amneziawg-go; url=$UP_GO; else name=amneziawg-tools; url=$UP_TOOLS; fi
  have=$(installed "$name"); want=$(upstream "$url")
  [ -n "$want" ] || die "cannot reach $url"
  if [ "$have" = "$want" ]; then
    echo "$name: up to date (${have:0:7})"
    latest+=", $name ${have:0:7}"
  else
    shown=${have:0:7}
    echo "$name: ${shown:-unknown} -> ${want:0:7}"
    changes+=("$name ${shown:-unknown} -> ${want:0:7}")
    bin_outdated=1
  fi
done

if [ ${#changes[@]} -eq 0 ] && { [ "$CHECK" = 1 ] || [ "$FORCE" = 0 ]; }; then
  [ "$CHECK" = 1 ] || refresh_scripts
  echo "Latest version is installed ($latest)."
  exit 0
fi

summary=
for c in "${changes[@]}"; do summary+="${summary:+, }$c"; done
if [ "$CHECK" = 1 ]; then
  echo "Update available: $summary; run ./update.sh"
  exit 10
fi
if [ "$SKIP_KIT" = 0 ]; then
  if [ -n "$summary" ]; then echo "Update available: $summary; updating."; else echo "Nothing new; reinstalling (--force)."; fi
fi

# the kit first: continue with the updated script
if [ "$behind" -gt 0 ]; then
  git -C "$HERE" pull --ff-only -q || die "cannot fast-forward $HERE (local changes?)"
  exec bash "$HERE/update.sh" --skip-kit "$@"
fi

replaced=0
if [ "$bin_outdated" = 1 ] || [ "$FORCE" = 1 ]; then
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

refresh_scripts

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
