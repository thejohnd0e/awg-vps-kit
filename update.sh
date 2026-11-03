#!/bin/bash
# AWG VPS Kit updater: compares the installed versions with the latest ones and
# updates only when something is newer: the kit itself (git pull) and the
# amneziawg binaries (rebuilt from upstream), then restarts the service.
# Server config and clients are not touched. Run as root.
#
# Usage: update.sh [options]   (update.sh --help prints the same list)
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

usage() {
  cat <<'EOF'
AWG VPS Kit updater: updates the kit and the amneziawg binaries when newer ones exist.
Server config and clients are not touched. Run as root.

  --check                   only report (exit 0: latest installed, 10: update available)
  --force                   rebuild binaries even if up to date
  --bin-dir DIR             use prebuilt amneziawg-go, awg, awg-quick from DIR (skip build)
  --no-restart              do not restart awg-quick@awg0 (new binaries apply after restart)

Examples:
  curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/update.sh | bash -s -- --check
  curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/update.sh | bash
EOF
}

need_value() {
  [ $# -ge 2 ] || die "$1 requires a value"
  case "$2" in --*) die "$1 requires a value" ;; esac
}

CHECK=0; FORCE=0; BIN_DIR=; NO_RESTART=0; SKIP_KIT=0
ORIG_ARGS=("$@")
for arg in "$@"; do [ "$arg" != --check ] || CHECK=1; done

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --force) FORCE=1; shift ;;
    --bin-dir) need_value "$@"; BIN_DIR=$2; shift 2 ;;
    --no-restart) NO_RESTART=1; shift ;;
    --skip-kit) SKIP_KIT=1; shift ;;   # internal: set after the kit was pulled
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# Started through `curl ... | bash` (no kit checkout next to this script): make sure the kit is in
# /opt/awg-vps-kit (clone or fast-forward) and continue from it, whatever the current folder is.
# --check is read-only: it may inspect an existing checkout but never pulls, clones or installs.
SELF=${BASH_SOURCE[0]:-}
SELF_DIR=
[ -z "$SELF" ] || SELF_DIR=$(cd "$(dirname "$SELF")" && pwd)
if [ -z "$SELF_DIR" ] || [ ! -f "$SELF_DIR/awg-client" ]; then
  KIT=/opt/awg-vps-kit
  cd /
  [ "$(id -u)" = 0 ] || die "run as root"
  if [ -d "$KIT/.git" ]; then
    if [ "$CHECK" = 0 ]; then
      git -C "$KIT" pull --ff-only -q || die "cannot fast-forward $KIT (local changes?)"
    fi
  elif [ "$CHECK" = 1 ]; then
    die "no kit checkout at $KIT: nothing to check (run update.sh from the kit, or install first)"
  elif [ -e "$KIT" ]; then
    die "$KIT exists but is not a clone of the kit; move it away and run this again"
  else
    command -v git >/dev/null || { apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null; }
    git clone -q https://github.com/thejohnd0e/awg-vps-kit.git "$KIT"
  fi
  exec "$KIT/update.sh" "${ORIG_ARGS[@]}"
fi

HERE=$SELF_DIR
DIR=/etc/amnezia/amneziawg
IF=awg0
UP_GO=https://github.com/amnezia-vpn/amneziawg-go
UP_TOOLS=https://github.com/amnezia-vpn/amneziawg-tools

[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$DIR/$IF.conf" ] || die "$DIR/$IF.conf not found: nothing installed here (use install.sh)"

LOCK_FILE=/run/lock/awg-vps-kit.lock
take_lock() {  # serialise every operation that reads and writes installed state
  command -v flock >/dev/null || die "flock is required (util-linux)"
  mkdir -p /run/lock
  exec 9>>"$LOCK_FILE"
  flock -w 10 9 || die "another kit operation is running (lock: $LOCK_FILE)"
}
# --check only reads installed state and must not be blocked by (or block) a real update.
[ "$CHECK" = 1 ] || take_lock

# An unfinished peer/protocol/update transaction is the only copy of the old state.
if [ "$CHECK" = 0 ]; then
  pending=$(find "$DIR/transactions" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)
  [ -z "$pending" ] || die "unfinished operation at $pending; resolve it before updating"
fi

installed() { awk -F= -v k="$1" '$1==k{print $2}' "$DIR/versions" 2>/dev/null || true; }
upstream() { git ls-remote "$1" HEAD 2>/dev/null | cut -f1; }
# scripts, docs and the recorded kit version always follow the checkout
refresh_scripts() {
  install -m 755 "$HERE/awg-client" /usr/local/bin/awg-client
  install -m 644 "$HERE/README.md" "$DIR/README.md"
  printf 'version=%s\ncommit=%s\n' "$(tr -d '\r\n ' < "$HERE/VERSION" 2>/dev/null || echo unknown)" \
    "$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)" > "$DIR/kit-version"
  chmod 644 "$DIR/kit-version"
}

changes=()
curver=$(tr -d '\r\n ' < "$HERE/VERSION" 2>/dev/null || echo unknown)

# ------------------------------------------------------------------ kit
behind=0
if [ "$SKIP_KIT" = 0 ] && [ -d "$HERE/.git" ] && command -v git >/dev/null \
   && git -C "$HERE" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
  git -C "$HERE" fetch -q || die "cannot fetch the kit's upstream in $HERE"
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
  have=$(installed "$name"); want=$(upstream "$url" || true)
  [ -n "$want" ] || die "cannot reach $url (git ls-remote failed); check network access to GitHub"
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
  echo "Update available: $summary; run: curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/update.sh | bash"
  exit 10
fi
if [ "$SKIP_KIT" = 0 ]; then
  if [ -n "$summary" ]; then echo "Update available: $summary; updating."; else echo "Nothing new; reinstalling (--force)."; fi
fi

# the kit first: continue with the updated script
if [ "$behind" -gt 0 ]; then
  git -C "$HERE" pull --ff-only -q || die "cannot fast-forward $HERE (local changes?)"
  exec bash "$HERE/update.sh" --skip-kit "${ORIG_ARGS[@]}"
fi

replaced=0
runtime_healthy() {  # local liveness, not proof that traffic flows
  command -v systemctl >/dev/null || return 1
  systemctl is-active --quiet "awg-quick@$IF" || return 1
  awg show "$IF" >/dev/null 2>&1
}

restart=0
if [ "$NO_RESTART" = 0 ]; then
  command -v systemctl >/dev/null || die "systemctl is not available; pass --no-restart (the runtime will not be verified)"
  systemctl is-active --quiet "awg-quick@$IF" \
    || die "awg-quick@$IF is not active; restore the service first, or pass --no-restart (the runtime will not be verified)"
  # is-active is not health: replacing binaries under a broken interface hides the failure
  # until the restart, when the rollback would have to guess which side broke it.
  runtime_healthy \
    || die "awg-quick@$IF is active but not usable (awg show $IF failed); fix it first, or pass --no-restart"
  restart=1
fi

managed_files() {
  printf '%s\n' /usr/local/bin/amneziawg-go /usr/local/bin/awg /usr/local/bin/awg-quick \
    /usr/local/bin/awg-client "$DIR/versions" "$DIR/kit-version" "$DIR/README.md"
}
snapshot_state() {  # snapshot_state <txn>: remember the current, self-consistent set
  local txn=$1 f
  mkdir -p "$txn/files"
  : > "$txn/manifest"
  while IFS= read -r f; do
    [ ! -e "$f" ] || { cp -p "$f" "$txn/files/$(basename "$f")" && printf '%s\n' "$f" >> "$txn/manifest"; }
  done < <(managed_files)
}
restore_state() {  # restore_state <txn>: files that did not exist before are removed again
  local txn=$1 f failed=0
  [ -r "$txn/manifest" ] || { echo "error: $txn/manifest is missing; refusing to guess what to restore" >&2; return 1; }
  while IFS= read -r f; do
    cp -p "$txn/files/$(basename "$f")" "$f" || failed=1
  done < "$txn/manifest"
  while IFS= read -r f; do
    grep -qxF "$f" "$txn/manifest" || rm -f "$f" || failed=1
  done < <(managed_files)
  return "$failed"
}

if [ "$bin_outdated" = 1 ] || [ "$FORCE" = 1 ]; then
  if [ -z "$BIN_DIR" ]; then
    BIN_DIR=$(mktemp -d /var/tmp/awg-update.XXXXXX)
    trap 'rm -rf "$BIN_DIR"' EXIT
    log "Building new binaries (a few minutes)"
    bash "$HERE/install.sh" --build-only "$BIN_DIR" >/dev/null
  fi
  for f in amneziawg-go awg awg-quick; do [ -x "$BIN_DIR/$f" ] || die "missing $BIN_DIR/$f"; done
  # the build took minutes: the service may have died meanwhile
  [ "$restart" = 0 ] || systemctl is-active --quiet "awg-quick@$IF" \
    || die "awg-quick@$IF stopped while the update was being prepared; nothing was replaced"

  mkdir -p "$DIR/transactions"; chmod 700 "$DIR/transactions"
  txn=$(mktemp -d "$DIR/transactions/update.XXXXXX"); chmod 700 "$txn"
  snapshot_state "$txn"
  mkdir -p "$txn/new"
  install -m 755 "$BIN_DIR/amneziawg-go" "$txn/new/amneziawg-go"
  install -m 755 "$BIN_DIR/awg" "$txn/new/awg"
  install -m 755 "$BIN_DIR/awg-quick" "$txn/new/awg-quick"
  if [ -f "$BIN_DIR/versions" ]; then
    install -m 644 "$BIN_DIR/versions" "$txn/new/versions"
  else
    # Do not keep the old commits next to new binaries as if they described them.
    printf 'amneziawg-go=unknown\namneziawg-tools=unknown\n' > "$txn/new/versions"
    echo "warning: $BIN_DIR has no versions file; recording unknown versions"
  fi
  install -m 755 "$HERE/awg-client" "$txn/new/awg-client"
  install -m 644 "$HERE/README.md" "$txn/new/README.md"
  printf 'version=%s\ncommit=%s\n' "$(tr -d '\r\n ' < "$HERE/VERSION" 2>/dev/null || echo unknown)" \
    "$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)" > "$txn/new/kit-version"

  replace_all() {
    local f
    for f in amneziawg-go awg awg-quick; do
      install -m 755 "$txn/new/$f" "/usr/local/bin/$f.new" \
        && mv -f "/usr/local/bin/$f.new" "/usr/local/bin/$f" || return 1
    done
    install -m 644 "$txn/new/versions" "$DIR/versions" || return 1
    install -m 644 "$txn/new/kit-version" "$DIR/kit-version" || return 1
    install -m 755 "$txn/new/awg-client" /usr/local/bin/awg-client.new \
      && mv -f /usr/local/bin/awg-client.new /usr/local/bin/awg-client || return 1
    install -m 644 "$txn/new/README.md" "$DIR/README.md" || return 1
  }
  rollback_update() {  # rollback_update <message>
    local msg=$1
    if ! restore_state "$txn"; then
      echo "error: $msg; RESTORE FAILED (transaction kept in $txn)" >&2
      exit 1
    fi
    if [ "$restart" = 1 ]; then
      if systemctl restart "awg-quick@$IF"; then
        sleep 2
        if runtime_healthy; then rm -rf "$txn"; die "$msg (previous version restored and running)"; fi
      fi
      echo "error: $msg; previous files restored but the service did not start" >&2
      echo "recovery: transaction kept in $txn" >&2
      exit 1
    fi
    rm -rf "$txn"
    die "$msg (previous files restored)"
  }

  log "Installing binaries (previous set is kept in $txn until the update succeeds)"
  replace_all || rollback_update "cannot replace installed files"
  replaced=1
fi

if [ "$replaced" = 0 ]; then
  refresh_scripts
fi

if [ "$replaced" = 1 ] && [ "$restart" = 1 ]; then
  log "Restarting awg-quick@$IF (clients reconnect in a few seconds)"
  systemctl restart "awg-quick@$IF" || rollback_update "the service did not restart"
  sleep 2
  runtime_healthy || { journalctl -u "awg-quick@$IF" -n 30 --no-pager; rollback_update "the tunnel is not usable after the restart"; }
  awg show "$IF" | sed -n '1,3p'
elif [ "$replaced" = 1 ]; then
  echo "New binaries are installed, runtime not verified (no restart was requested or the service is stopped)."
  echo "Apply with: systemctl restart awg-quick@$IF"
fi

if [ "$replaced" = 1 ]; then
  # keep the previous, self-consistent set (binaries and the metadata that describes them)
  mkdir -p /opt/amneziawg/prev
  if cp -p "$txn/files/"* /opt/amneziawg/prev/ 2>/dev/null; then
    rm -rf "$txn"
  else
    echo "warning: could not refresh /opt/amneziawg/prev; the previous set is kept in $txn" >&2
  fi
fi
echo "Done."
