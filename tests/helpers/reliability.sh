#!/bin/bash
# Helpers for tests/test-reliability.sh. Test-only code; never installed.
# These tests install the kit into /etc/amnezia, /usr/local/bin and /opt, so
# they must only run in a disposable container or VM.

ROOT=${ROOT:?ROOT must point at the repository root}
DIR=/etc/amnezia/amneziawg
IF=awg0
# shellcheck disable=SC2034  # CL and CONF are used by the sourcing test script
CL=$DIR/clients
# shellcheck disable=SC2034
CONF=$DIR/$IF.conf

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

assert_status() {  # assert_status <expected> <actual> <message>
  [ "$1" = "$2" ] || fail "$3 (expected status $1, got $2)"
}
assert_same() {  # assert_same <file-a> <file-b> <message>
  cmp -s "$1" "$2" || fail "$3"
}
assert_missing() {  # assert_missing <path> <message>
  [ ! -e "$1" ] || fail "$2 (still exists: $1)"
}

# Fresh --no-service install with the prebuilt binaries under test.
fresh_install() {
  rm -rf /etc/amnezia "$DIR" /opt/amneziawg
  "$ROOT/install.sh" --no-service --subnet 10.79.0 --endpoint 203.0.113.10 \
    --wan-if eth0 --bin-dir "$BIN" "$@" >/dev/null
}

# Keep real key generation, script the interface operations.
stub_awg() {
  [ -x /usr/local/bin/awg.real ] || mv /usr/local/bin/awg /usr/local/bin/awg.real
  cat > /usr/local/bin/awg <<'EOS'
#!/bin/sh
case "$1" in
  genkey|pubkey|genpsk) exec /usr/local/bin/awg.real "$@" ;;
  show)
    [ "${AWG_STUB_SHOW_FAIL:-0}" = 1 ] && { echo "stub: interface is down" >&2; exit 1; }
    exit 0 ;;
  set)
    [ "${AWG_STUB_SET_FAIL:-0}" = 1 ] && { echo "stub: set failed" >&2; exit 1; }
    if [ -n "${AWG_STUB_BARRIER:-}" ]; then
      : > "${AWG_STUB_BARRIER}.ready"
      i=0
      while [ ! -e "$AWG_STUB_BARRIER" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i+1)); done
    fi
    [ -n "${AWG_STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$AWG_STUB_LOG"
    exit 0 ;;
  *) exit 0 ;;
esac
EOS
  chmod 755 /usr/local/bin/awg
}

# systemctl stub: logs calls, is-active result and restart result are selectable.
stub_systemctl() {
  mkdir -p /tmp/awg-test-bin
  cat > /tmp/awg-test-bin/systemctl <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:-/tmp/awg-test-systemctl.log}"
case "$1" in
  is-active) [ "${SYSTEMCTL_ACTIVE:-0}" = 1 ] ;;
  restart|start) [ "${SYSTEMCTL_RESTART_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac
EOS
  chmod 755 /tmp/awg-test-bin/systemctl
  PATH=/tmp/awg-test-bin:$PATH
  export PATH
}

# git stub for `ls-remote`: reports the installed commits, so update tests stay offline.
stub_git_version() {
  mkdir -p /tmp/awg-test-git
  cat > /tmp/awg-test-git/git <<'EOS'
#!/bin/sh
case "$1" in
  ls-remote)
    case "$2" in
      *amneziawg-go) sed -n 's/^amneziawg-go=//p' /etc/amnezia/amneziawg/versions ;;
      *amneziawg-tools) sed -n 's/^amneziawg-tools=//p' /etc/amnezia/amneziawg/versions ;;
      *) echo 0000000000000000000000000000000000000000 ;;
    esac
    exit 0 ;;
esac
exec /usr/bin/git "$@"
EOS
  chmod 755 /tmp/awg-test-git/git
  PATH=/tmp/awg-test-git:$PATH
  export PATH
}

# mv stub that fails when the destination contains MV_FAIL_ON (publish failure injection).
stub_mv_fail() {
  mkdir -p /tmp/awg-test-mv
  cat > /tmp/awg-test-mv/mv <<'EOS'
#!/bin/sh
for a in "$@"; do last=$a; done
case "$last" in *"$MV_FAIL_ON"*) echo "stub: mv refused" >&2; exit 1 ;; esac
exec /usr/bin/mv "$@"
EOS
  chmod 755 /tmp/awg-test-mv/mv
  MV_FAIL_ON=$1
  export MV_FAIL_ON
  PATH=/tmp/awg-test-mv:$PATH
  export PATH
}
