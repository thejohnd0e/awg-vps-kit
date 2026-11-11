# shellcheck shell=bash
# Shared helpers of awg-vps-kit, sourced by install.sh, update.sh and awg-client.
# Installed to /usr/local/lib/awg-vps-kit/common.sh (awg-client runs from /usr/local/bin and
# needs it there; update.sh refreshes and rolls it back with the other managed files).
#
# Not used by uninstall.sh, block-ping and awg-watchdog on purpose: uninstall.sh and block-ping are
# started through `curl | bash` without a kit checkout, and the watchdog must keep working
# when this file is damaged. Each of them keeps its own few lines.
#
# This file sets no shell options and defines functions and constants only.

KIT_LOCK_FILE=/run/lock/awg-vps-kit.lock
# QUIC-like Initial header, random connection id, then random payload (client side, protocol 1.5)
# shellcheck disable=SC2034  # used by the scripts that source this file
AWG_I1_DEFAULT='<b 0xc00000000108><r 8><b 0x00><r 64>'

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

# Serialise every operation that reads and writes installed state. The lock stays held on file
# descriptor 9 until the process exits (install.sh closes it with `exec 9>&-` before it calls
# awg-client, which takes the lock itself).
take_lock() {
  command -v flock >/dev/null || die "flock is required (util-linux)"
  mkdir -p /run/lock
  exec 9>>"$KIT_LOCK_FILE"
  flock -w 10 9 || die "another kit operation is running (lock: $KIT_LOCK_FILE)"
}

# kv <file> <key>: value from a key=value file, empty if missing.
# Everything after the first '=' belongs to the value (I-signatures may contain '=');
# spaces around the key are tolerated for hand-edited files.
kv() {
  awk -F= -v k="$2" '{ key=$1; sub(/^[ \t]+/,"",key); sub(/[ \t]+$/,"",key); if (key==k) { sub(/^[^=]*=/,""); print; exit } }' "$1" 2>/dev/null || true
}

# prune_backups <path-prefix>: keep the 5 newest "<prefix>*<YYYYmmdd-HHMMSS>" files, by the stamp
# in the name: cp -p keeps the original's mtime, so mtime says nothing about the age of a backup.
prune_backups() {
  local f
  find "$(dirname "$1")" -maxdepth 1 -type f -name "$(basename "$1")*" 2>/dev/null \
    | sed -n 's/.*\([0-9]\{8\}-[0-9]\{6\}\)$/\1 &/p' | sort -r | tail -n +6 | cut -d' ' -f2- \
    | while IFS= read -r f; do rm -f -- "$f"; done
}

# ------------------------------------------------------------------ obfuscation values
# Random 32-bit value of at least 5 (0-4 are the WireGuard message types).
awg_rnd32() { local v=0; while [ "$v" -lt 5 ]; do v=$(od -An -N4 -tu4 /dev/urandom | tr -d " "); done; echo "$v"; }

# awg_distinct_rnd32 <n>: n different random values, one per line.
awg_distinct_rnd32() {
  local -a vals=(); local x
  while [ ${#vals[@]} -lt "$1" ]; do
    x=$(awg_rnd32)
    case " ${vals[*]} " in *" $x "*) ;; *) vals+=("$x") ;; esac
  done
  printf '%s\n' "${vals[@]}"
}

# awg_h_values <protocol>: the four H1..H4 values, one per line. Protocol 3.1 has fixed values
# 1-4; protocol 2.0 uses ranges "a-b"; eight distinct values are sorted and paired, so the four
# ranges can never overlap.
awg_h_values() {
  local -a r
  if [ "$1" = 3.1 ]; then printf '%s\n' 1 2 3 4; return; fi
  if [ "$1" = 2.0 ]; then
    mapfile -t r < <(awg_distinct_rnd32 8 | sort -n)
    printf '%s-%s\n' "${r[@]}"
  else
    awg_distinct_rnd32 4
  fi
}

# awg_s34_values: the S3/S4 lines of protocol 2.0.
awg_s34_values() { printf 'S3 = %s\nS4 = %s\n' "$(shuf -i 8-64 -n 1)" "$(shuf -i 4-32 -n 1)"; }

# awg_s31_value: one random protocol-3.1 S value (15-32).
awg_s31_value() { shuf -i 15-32 -n 1; }

# awg_31_client_defaults: the key=value defaults of the protocol-3.1 client fields for $DIR/protocol.
awg_31_client_defaults() {
  echo "I1=$AWG_I1_DEFAULT"
  echo "ContentPaddingAddition=10-100"
  echo "DisableCookies=on"
  echo "RekeyAfterTime=100-120"
  echo "RekeyTimeout=3-7"
  echo "RejectAfterTime=150-180"
  echo "KeepaliveTimeout=5-15"
  echo "MaxHandshakeAttempts=15-20"
}
