#!/bin/bash
# Reliability scenarios for install.sh, awg-client, update.sh and uninstall.sh.
#
# DESTRUCTIVE: installs the kit into /etc/amnezia, /usr/local/bin and /opt.
# Run only in a disposable container or VM:
#
#   AWG_TEST_ALLOW_DESTRUCTIVE=1 tests/test-reliability.sh BIN_DIR [CASE]
#
# BIN_DIR holds amneziawg-go, awg, awg-quick built by `install.sh --build-only`.
# CASE: cli | peers | protocol | update | lock | bootstrap | cleanup | all
# shellcheck disable=SC2119  # fresh_install passes extra options only when a case needs them
set -euo pipefail

BIN=${1:?usage: $0 BIN_DIR [CASE]}
CASE=${2:-all}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

[ "${AWG_TEST_ALLOW_DESTRUCTIVE:-0}" = 1 ] \
  || { echo "refusing: these tests overwrite /etc/amnezia; set AWG_TEST_ALLOW_DESTRUCTIVE=1 in a container or VM" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }
[ -x "$BIN/awg" ] || { echo "missing $BIN/awg (build with install.sh --build-only)" >&2; exit 2; }
# install.sh installs iproute2/nftables/qrencode/curl with apt
apt-get update -qq

. "$ROOT/tests/helpers/reliability.sh"
BIN=$(cd "$BIN" && pwd)

case_cli() {
  echo "# cli"
  local out rc
  set +e
  out=$("$ROOT/install.sh" --port 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "install.sh --port without a value must fail"
  case "$out" in *"unbound variable"*) fail "install.sh --port: raw shell error instead of a message" ;; esac
  case "$out" in *"--port requires a value"*) ;; *) fail "install.sh --port: no '--port requires a value' (got: $out)" ;; esac

  set +e
  out=$("$ROOT/install.sh" --port --no-service 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an option used as a value must fail"
  case "$out" in *"requires a value"*) ;; *) fail "--port --no-service: unclear error (got: $out)" ;; esac

  for p in 0 65536 abc; do
    if "$ROOT/install.sh" --no-service --port "$p" --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null 2>&1; then
      fail "port $p must be rejected"
    fi
  done
  if "$ROOT/install.sh" --no-service --subnet 999.1.1 --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null 2>&1; then
    fail "subnet 999.1.1 must be rejected"
  fi

  out=$("$ROOT/install.sh" --help)
  echo "$out" | grep -q -- '--allow-outdated' || fail "install.sh --help drops --allow-outdated"
  if echo "$out" | grep -q 'set -euo'; then fail "install.sh --help prints shell code"; fi
  out=$("$ROOT/update.sh" --help)
  echo "$out" | grep -q -- '--bin-dir' || fail "update.sh --help drops --bin-dir"
  if echo "$out" | grep -q 'set -euo'; then fail "update.sh --help prints shell code"; fi

  fresh_install --endpoint 2001:db8::1
  stub_awg
  "$ROOT/awg-client" add v6test >/dev/null
  out6=$("$ROOT/awg-client" show v6test)
  echo "$out6" | grep -Fqx 'Endpoint = [2001:db8::1]:443' \
    || fail "IPv6 endpoint is not bracketed"
  for f in awg0.conf srv.key; do
    [ "$(stat -c %a "$DIR/$f")" = 600 ] || fail "$f must be mode 600 (got $(stat -c %a "$DIR/$f"))"
  done
  for f in srv.pub protocol endpoint nat-up.nft README.md; do
    [ "$(stat -c %a "$DIR/$f")" = 644 ] || fail "$f must be mode 644 (got $(stat -c %a "$DIR/$f"))"
  done
  ok "cli: values, ranges, help, IPv6 endpoint and file modes"
}

case_bootstrap() {
  echo "# bootstrap"
  rm -rf /opt/awg-vps-kit
  local tmp; tmp=$(mktemp -d /tmp/awg-bootstrap.XXXXXX)
  cp "$ROOT/install.sh" "$tmp/install.sh"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/awg-client"   # decoy in the current folder
  ( cd "$tmp" && bash ./install.sh --help >/dev/null ) || fail "install.sh --help failed"
  [ ! -e /opt/awg-vps-kit ] || fail "bootstrap cloned the kit although install.sh ran from a file"
  ( cd "$tmp" && bash -s -- --help < ./install.sh >/dev/null ) || fail "piped install.sh --help failed"
  assert_missing /opt/awg-vps-kit "piped --help must not clone the kit"
  ( cd "$tmp" && bash -s -- --port < ./install.sh >/dev/null 2>&1 ) && fail "piped --port without a value must fail"
  assert_missing /opt/awg-vps-kit "piped invalid options must not clone the kit"

  set +e
  ( cd "$tmp" && bash -s -- --check < "$ROOT/update.sh" >/dev/null 2>&1 )
  local rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "update.sh --check without a kit checkout must fail"
  assert_missing /opt/awg-vps-kit "update.sh --check must not clone the kit"
  rm -rf "$tmp"
  ok "bootstrap: stdin runs and read-only check"
}

case_cleanup() {
  echo "# cleanup"
  local tmp; tmp=$(mktemp -d /tmp/awg-cleanup.XXXXXX)
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/git" <<'EOS'
#!/bin/sh
case "$1" in clone) echo "stub: clone refused" >&2; exit 1 ;; esac
exec /usr/bin/git "$@"
EOS
  cat > "$tmp/bin/apt-get" <<'EOS'
#!/bin/sh
exit 0
EOS
  chmod 755 "$tmp/bin/git" "$tmp/bin/apt-get"
  local before after
  before=$(find /var/tmp -maxdepth 1 -name 'awg-build.*' | sort)
  set +e
  PATH="$tmp/bin:$PATH" "$ROOT/install.sh" --build-only "$tmp/out" >/dev/null 2>&1
  local rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a failed clone must fail the build"
  after=$(find /var/tmp -maxdepth 1 -name 'awg-build.*' | sort)
  [ "$before" = "$after" ] || fail "failed build left a temporary directory in /var/tmp"
  rm -rf "$tmp"
  ok "cleanup: failed build removes its temporary directory"
}

case_peers() {
  echo "# peers"
  fresh_install
  stub_awg
  AWG_STUB_SHOW_FAIL=1 "$ROOT/awg-client" add alice >/dev/null 2>&1 && fail "add with a dead tunnel must fail"
  assert_missing "$DIR/clients/alice.conf" "failed add must not leave client files"
  grep -q '# alice' "$CONF" && fail "failed add must not change awg0.conf"
  ok "peers: add refuses to run when the tunnel is down"

  AWG_STUB_SET_FAIL=1 "$ROOT/awg-client" add bob >/dev/null 2>&1 && fail "add must fail when awg set fails"
  assert_missing "$DIR/clients/bob.conf" "failed add must not leave client files"
  grep -q '# bob' "$CONF" && fail "failed add must not change awg0.conf"
  "$ROOT/awg-client" add bob >/dev/null || fail "add must work after a clean rollback"
  ok "peers: failed awg set rolls back"
}

case_protocol() {
  echo "# protocol"
  fresh_install
  stub_awg
  "$ROOT/awg-client" add erin >/dev/null
  local before; before=$(sha256sum "$CONF" | cut -d' ' -f1)
  printf 'I1 = <b 0xc00000000108><b 0x42>\nI2 = keep=this\n' >> "$DIR/protocol"
  SYSTEMCTL_LOG=/tmp/awg-systemctl.log
  : > "$SYSTEMCTL_LOG"
  SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$SYSTEMCTL_LOG PATH=/tmp/awg-test-bin:$PATH "$ROOT/awg-client" protocol 1.5 >/dev/null
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$before" ] || fail "1.0 -> 1.5 must not rewrite awg0.conf"
  if grep -q restart "$SYSTEMCTL_LOG"; then fail "1.0 -> 1.5 must not restart the tunnel"; fi
  local out; out=$("$ROOT/awg-client" show erin)
  echo "$out" | grep -q '^I2 = keep=this$' || fail "custom I2 was not preserved"
  ok "protocol: 1.0 -> 1.5 keeps the server config and custom fields"
}

case_update() {
  echo "# update"
  fresh_install
  stub_awg
  "$ROOT/awg-client" add carol >/dev/null
  local before; before=$(sha256sum "$CONF" | cut -d' ' -f1)
  "$ROOT/update.sh" --force --bin-dir "$BIN" --no-restart >/dev/null
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$before" ] || fail "update must not touch awg0.conf"
  "$ROOT/awg-client" list | grep -q carol || fail "clients lost after update"
  ok "update: binaries installed, config untouched"
}

case_lock() {
  echo "# lock"
  fresh_install
  stub_awg
  : > /tmp/awg-lock-out
  "$ROOT/awg-client" add lock1 >/dev/null & local p1=$!
  "$ROOT/awg-client" add lock2 >/dev/null & local p2=$!
  wait $p1 || fail "first concurrent add failed"
  wait $p2 || fail "second concurrent add failed"
  [ "$("$ROOT/awg-client" list | awk '{print $1}' | sort -u | wc -l)" = 2 ] || fail "concurrent adds shared an address"
  ok "lock: concurrent adds get distinct addresses"
}

if [ "$CASE" = all ]; then
  for c in cli bootstrap cleanup lock peers protocol update; do
    "case_$c"
  done
else
  case "$CASE" in
    cli|bootstrap|cleanup|lock|peers|protocol|update) "case_$CASE" ;;
    *) echo "unknown case: $CASE" >&2; exit 2 ;;
  esac
fi
echo "All reliability tests passed ($CASE)"
