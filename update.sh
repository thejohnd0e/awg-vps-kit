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
  --upstream-head           follow the newest amneziawg-go/-tools instead of the reviewed commits in
                            upstream.lock (unreviewed code, runs as root)

Examples:
  curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/update.sh | bash -s -- --check
  curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/update.sh | bash
EOF
}

need_value() {
  [ $# -ge 2 ] || die "$1 requires a value"
  case "$2" in --*) die "$1 requires a value" ;; esac
}

CHECK=0; FORCE=0; BIN_DIR=; NO_RESTART=0; SKIP_KIT=0; UPSTREAM_HEAD=0
ORIG_ARGS=("$@")
for arg in "$@"; do [ "$arg" != --check ] || CHECK=1; done

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --force) FORCE=1; shift ;;
    --bin-dir) need_value "$@"; BIN_DIR=$2; shift 2 ;;
    --no-restart) NO_RESTART=1; shift ;;
    --upstream-head) UPSTREAM_HEAD=1; shift ;;
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
TUNNEL_UNIT=/etc/systemd/system/awg-quick@.service

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
pin() { printf '%s\n' "$LOCK_TEXT" | awk -F= -v k="$1" '$1 == k && $2 ~ /^[0-9a-f]{40}$/ { print $2; exit }'; }
# scripts, docs and the recorded kit version always follow the checkout
refresh_scripts() {
  apply_migrations
  install -m 755 "$HERE/awg-client" /usr/local/bin/awg-client
  install -m 755 "$HERE/awg-watchdog" /usr/local/bin/awg-watchdog
  install -m 755 "$HERE/block-ping" /usr/local/bin/block-ping
  install -m 644 "$HERE/README.md" "$DIR/README.md"
  printf 'version=%s\ncommit=%s\n' "$(tr -d '\r\n ' < "$HERE/VERSION" 2>/dev/null || echo unknown)" \
    "$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)" > "$DIR/kit-version"
  chmod 644 "$DIR/kit-version"
  # Migration for servers installed before the watchdog existed: create/repair the
  # units and start the timer. Only the units this kit owns are touched.
  if command -v systemctl >/dev/null 2>&1; then
    # the tunnel unit only where install.sh created it (not on --no-service installs);
    # a changed ExecStart applies at the next restart
    [ ! -e "$TUNNEL_UNIT" ] || install -m 644 "$HERE/awg-quick@.service" "$TUNNEL_UNIT" 2>/dev/null || true
    install -m 644 "$HERE/awg-watchdog.service" "$HERE/awg-watchdog.timer" /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now awg-watchdog.timer >/dev/null 2>&1 || true
  fi
}

prune_backups() {  # prune_backups <path-prefix>: keep the 5 newest "<prefix>*<YYYYmmdd-HHMMSS>" files (as in awg-client)
  local f
  find "$(dirname "$1")" -maxdepth 1 -type f -name "$(basename "$1")*" 2>/dev/null \
    | sed -n 's/.*\([0-9]\{8\}-[0-9]\{6\}\)$/\1 &/p' | sort -r | tail -n +6 | cut -d' ' -f2- \
    | while IFS= read -r f; do rm -f -- "$f"; done
}

# Server config migrations for installations created by older kits. Idempotent and
# limited to the files this kit owns; the config is backed up before a rewrite.
apply_migrations() {
  local nat=$DIR/nat-up.nft conf=$DIR/$IF.conf ts
  if [ -f "$nat" ] && ! grep -qx 'delete table ip awg_nat' "$nat"; then
    { printf 'table ip awg_nat\n'; printf 'delete table ip awg_nat\n'; cat "$nat"; } > "$nat.new" \
      && mv -f "$nat.new" "$nat"
  fi
  # MSS clamping for the 1280 MTU of the server interface (see install.sh): put the rules in
  # front of the first accept of the forward chain, and apply them to a running tunnel too.
  if [ -f "$nat" ] && ! grep -q 'tcp option maxseg' "$nat" && grep -qx "    iifname \"$IF\" accept" "$nat"; then
    ts=$(date +%Y%m%d-%H%M%S)
    cp -p "$nat" "$nat.bak-update-$ts"
    awk -v i="$IF" '
      $0 == "    iifname \"" i "\" accept" && !done {
        print "    # MSS clamping for the 1280 MTU of " i " (1280 - 40 bytes of IPv4+TCP headers): clients use"
        print "    # a larger MTU (1420), so without this they advertise an MSS that does not fit the tunnel."
        print "    iifname \"" i "\" tcp flags syn tcp option maxseg size > 1240 tcp option maxseg size set 1240"
        print "    oifname \"" i "\" tcp flags syn tcp option maxseg size > 1240 tcp option maxseg size set 1240"
        done = 1
      }
      { print }' "$nat" > "$nat.new" && mv -f "$nat.new" "$nat" && chmod 644 "$nat"
    if command -v nft >/dev/null 2>&1 && nft list table ip awg_nat >/dev/null 2>&1; then
      if ! nft -f "$nat"; then
        echo "warning: the new NAT rules did not load; restoring the previous nat-up.nft" >&2
        cp -p "$nat.bak-update-$ts" "$nat"; nft -f "$nat" || true
      fi
    fi
    prune_backups "$nat.bak-update-"
  fi
  if [ -f "$conf" ] && grep -qx 'PostDown = nft delete table ip awg_nat' "$conf"; then
    ts=$(date +%Y%m%d-%H%M%S)
    cp -p "$conf" "$conf.bak-update-$ts"
    sed -i 's#^PostDown = nft delete table ip awg_nat$#PostDown = nft delete table ip awg_nat 2>/dev/null || true#' "$conf"
    chmod 600 "$conf"
    prune_backups "$conf.bak-update-"
  fi
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
# The commits to be installed come from upstream.lock of the kit version that will be in place:
# when the kit is about to be pulled, that is the lock of the new version (the real run restarts
# after the pull and recomputes everything from the pulled files).
LOCK_TEXT=$(cat "$HERE/upstream.lock" 2>/dev/null || true)
if [ "$behind" -gt 0 ]; then
  newlock=$(git -C "$HERE" show '@{u}:upstream.lock' 2>/dev/null || true)
  [ -z "$newlock" ] || LOCK_TEXT=$newlock
fi
for comp in go tools; do
  if [ "$comp" = go ]; then name=amneziawg-go; url=$UP_GO; else name=amneziawg-tools; url=$UP_TOOLS; fi
  have=$(installed "$name")
  if [ "$UPSTREAM_HEAD" = 1 ]; then
    want=$(upstream "$url" || true)
    [ -n "$want" ] || die "cannot reach $url (git ls-remote failed); check network access to GitHub"
  else
    want=$(pin "$name")
    [ -n "$want" ] || die "no valid $name commit in upstream.lock (restore the file from the kit, or pass --upstream-head)"
    # information only: the pin is the supported state, newer upstream code is not reviewed yet
    head=$(upstream "$url" || true)
    [ -z "$head" ] || [ "$head" = "$want" ] || echo "note: $name upstream HEAD is ${head:0:7}, the reviewed commit is ${want:0:7} (not installed until upstream.lock moves)"
  fi
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
apply_migrations

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
    /usr/local/bin/awg-client /usr/local/bin/awg-watchdog /usr/local/bin/block-ping \
    /etc/systemd/system/awg-watchdog.service /etc/systemd/system/awg-watchdog.timer "$TUNNEL_UNIT" \
    "$DIR/versions" "$DIR/kit-version" "$DIR/README.md"
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
  if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload 2>/dev/null || true; fi
  return "$failed"
}

if [ "$bin_outdated" = 1 ] || [ "$FORCE" = 1 ]; then
  if [ -z "$BIN_DIR" ]; then
    BIN_DIR=$(mktemp -d /var/tmp/awg-update.XXXXXX)
    trap 'rm -rf "$BIN_DIR"' EXIT
    log "Building new binaries (a few minutes)"
    build_args=(--build-only "$BIN_DIR")
    [ "$UPSTREAM_HEAD" = 0 ] || build_args+=(--upstream-head)
    bash "$HERE/install.sh" "${build_args[@]}" >/dev/null
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
  install -m 755 "$HERE/awg-watchdog" "$txn/new/awg-watchdog"
  install -m 755 "$HERE/block-ping" "$txn/new/block-ping"
  install -m 644 "$HERE/awg-watchdog.service" "$txn/new/awg-watchdog.service"
  install -m 644 "$HERE/awg-watchdog.timer" "$txn/new/awg-watchdog.timer"
  install -m 644 "$HERE/awg-quick@.service" "$txn/new/awg-quick@.service"
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
    install -m 755 "$txn/new/awg-watchdog" /usr/local/bin/awg-watchdog || return 1
    install -m 755 "$txn/new/block-ping" /usr/local/bin/block-ping || return 1
    install -m 644 "$txn/new/awg-watchdog.service" /etc/systemd/system/awg-watchdog.service || return 1
    install -m 644 "$txn/new/awg-watchdog.timer" /etc/systemd/system/awg-watchdog.timer || return 1
    install -m 644 "$txn/new/README.md" "$DIR/README.md" || return 1
    if [ -e "$TUNNEL_UNIT" ]; then
      install -m 644 "$txn/new/awg-quick@.service" "$TUNNEL_UNIT" || return 1
    fi
    # the restart below must run the unit that is now on disk
    if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload 2>/dev/null || true; fi
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

if [ "$replaced" = 1 ] && command -v systemctl >/dev/null 2>&1; then
  # Migration: servers installed before the watchdog existed get the timer here.
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now awg-watchdog.timer >/dev/null 2>&1 || true
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
