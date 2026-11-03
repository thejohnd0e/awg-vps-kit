#!/bin/bash
# Reliability scenarios for install.sh, awg-client, update.sh and uninstall.sh.
#
# DESTRUCTIVE: installs the kit into /etc/amnezia, /usr/local/bin and /opt.
# Run only in a disposable container or VM:
#
#   AWG_TEST_ALLOW_DESTRUCTIVE=1 tests/test-reliability.sh BIN_DIR [CASE]
#
# BIN_DIR holds amneziawg-go, awg, awg-quick built by `install.sh --build-only`.
# CASE: cli | peers | protocol | update | lock | bootstrap | cleanup | watchdog | all
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
  if "$ROOT/install.sh" --no-service --subnet 010.79.0 --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null 2>&1; then
    fail "subnet with leading zeros must be rejected"
  fi
  if "$ROOT/install.sh" --no-service --protocol 3.0 --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null 2>&1; then
    fail "invalid --protocol must be rejected"
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
  grep -qx 'delete table ip awg_nat' "$DIR/nat-up.nft" || fail "nat-up.nft must be idempotent"
  grep -q '^PostDown = .*|| true$' "$CONF" || fail "PostDown must ignore a missing NAT table"

  # Boundary values are accepted and used as-is.
  rm -rf "$DIR"
  "$ROOT/install.sh" --no-service --port 65535 --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null
  grep -q '^ListenPort = 65535$' "$CONF" || fail "port 65535 was not accepted"
  rm -rf "$DIR"
  "$ROOT/install.sh" --no-service --port 1 --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null
  grep -q '^ListenPort = 1$' "$CONF" || fail "port 1 was not accepted"
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
  out=$( ( cd "$tmp" && bash -s -- --check < "$ROOT/update.sh" ) 2>&1 )
  local rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "update.sh --check without a kit checkout must fail"
  case "$out" in *"no kit checkout"*) ;; *) fail "update.sh --check must say there is no kit checkout (got: $out)" ;; esac
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

  local before; before=$(sha256sum "$CONF" | cut -d' ' -f1)
  AWG_STUB_SET_FAIL=1 "$ROOT/awg-client" remove bob >/dev/null 2>&1 && fail "remove must fail when awg set fails"
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$before" ] || fail "failed remove must not change awg0.conf"
  "$ROOT/awg-client" list | grep -q bob || fail "failed remove must keep the client"

  # SIGKILL cannot be handled: the transaction stays and blocks further changes.
  cat > /usr/local/bin/awg <<'EOS'
#!/bin/sh
case "$1" in
  genkey|pubkey|genpsk) exec /usr/local/bin/awg.real "$@" ;;
  set) : > /tmp/awg-kill.ready; sleep 30 ;;
  *) exit 0 ;;
esac
EOS
  chmod 755 /usr/local/bin/awg
  rm -f /tmp/awg-kill.ready
  "$ROOT/awg-client" add killed >/dev/null 2>&1 & local kp=$!
  local i=0; while [ ! -e /tmp/awg-kill.ready ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
  kill -9 $kp 2>/dev/null || true
  wait $kp 2>/dev/null || true
  pkill -f 'sleep 30' 2>/dev/null || true
  ls -d "$DIR"/transactions/peer.* >/dev/null 2>&1 || fail "killed add left no peer transaction"
  if "$ROOT/awg-client" add afterkill >/dev/null 2>&1; then fail "add must refuse while a peer transaction is unfinished"; fi
  rm -rf "$DIR/transactions"
  stub_awg
  # Failure after the runtime change: publishing the client config fails, so the peer
  # and awg0.conf must be rolled back.
  local pbefore saved; pbefore=$(sha256sum "$CONF" | cut -d' ' -f1); saved=$PATH
  stub_mv_fail "/clients/crashv.conf"
  if "$ROOT/awg-client" add crashv >/dev/null 2>&1; then
    fail "add must fail when publishing the client config fails"
  fi
  PATH=$saved
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$pbefore" ] || fail "failed publish must restore awg0.conf"
  assert_missing "$CL/crashv.conf" "failed publish must not leave client files"
  assert_missing "$CL/crashv.key" "failed publish must not leave key files"
  ls -d "$DIR"/transactions/peer.* >/dev/null 2>&1 && fail "clean rollback must remove the peer transaction"

  # SIGTERM in the middle of awg set: the peer must be removed, not left half-created.
  export AWG_STUB_BARRIER=/tmp/awg-term-barrier
  rm -f "$AWG_STUB_BARRIER" "$AWG_STUB_BARRIER.ready"
  "$ROOT/awg-client" add termsig >/dev/null 2>&1 & local tp=$!
  local i=0; while [ ! -e "${AWG_STUB_BARRIER}.ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
  : > "$AWG_STUB_BARRIER"
  kill -TERM $tp
  local trc=0; wait $tp || trc=$?
  unset AWG_STUB_BARRIER
  assert_status 130 "$trc" "SIGTERM must exit 130"
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$pbefore" ] || fail "SIGTERM must leave awg0.conf unchanged"
  assert_missing "$CL/termsig.conf" "interrupted add must not leave client files"
  ls -d "$DIR"/transactions/peer.* >/dev/null 2>&1 && fail "clean SIGTERM rollback must remove the transaction"

  # An unfinished transaction blocks the next change until it is resolved.
  mkdir -p "$DIR/transactions/peer.test"
  if "$ROOT/awg-client" add pendingx >/dev/null 2>&1; then fail "unfinished transaction must block add"; fi
  rm -rf "$DIR/transactions/peer.test"
  ok "peers: runtime guard, rollback, publish failure, SIGTERM, SIGKILL block"
}

case_protocol() {
  echo "# protocol"
  fresh_install
  stub_awg
  stub_systemctl
  local log=/tmp/awg-systemctl.log
  : > "$log"
  "$ROOT/awg-client" add erin >/dev/null
  local before out; before=$(sha256sum "$CONF" | cut -d' ' -f1)
  # key=value file format; custom I-signatures must survive every transition
  printf 'I1=<b 0xc00000000108><b 0x42>\nI2=keep=this\n' >> "$DIR/protocol"

  SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 1.5 >/dev/null
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$before" ] || fail "1.0 -> 1.5 must not rewrite awg0.conf"
  if grep -q restart "$log"; then fail "1.0 -> 1.5 must not restart the tunnel"; fi
  out=$("$ROOT/awg-client" show erin)
  echo "$out" | grep -q '^I2 = keep=this$' || fail "custom I2 was not preserved"
  echo "$out" | grep -q '^I1 = <b 0xc00000000108><b 0x42>$' || fail "custom I1 was overwritten"

  SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 1.0 >/dev/null
  out=$("$ROOT/awg-client" show erin)
  if echo "$out" | grep -Eq '^I[1-5] = '; then fail "1.0 clients must not get I-signature fields"; fi
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$before" ] || fail "1.5 -> 1.0 must not rewrite awg0.conf"
  "$ROOT/awg-client" protocol 1.5 >/dev/null
  out=$("$ROOT/awg-client" show erin)
  echo "$out" | grep -q '^I1 = <b 0xc00000000108><b 0x42>$' || fail "returning to 1.5 lost the custom I1"

  : > "$log"
  SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 2.0 >/dev/null
  grep -q '^S3 = ' "$CONF" || fail "2.0 must add S3 to awg0.conf"
  grep -q restart "$log" || fail "2.0 must restart the tunnel"
  out=$("$ROOT/awg-client" show erin)
  echo "$out" | grep -Eq '^H1 = [0-9]+-[0-9]+$' || fail "2.0 client H1 is not a range"
  if echo "$out" | grep -Eq '^I[1-5] = '; then fail "2.0 clients must not get 1.5 I-signatures"; fi

  # A failed restart must leave the previous protocol and config in place.
  before=$(sha256sum "$CONF" | cut -d' ' -f1)
  if SYSTEMCTL_ACTIVE=1 SYSTEMCTL_RESTART_FAIL=1 SYSTEMCTL_LOG=$log \
     "$ROOT/awg-client" protocol 1.0 >/dev/null 2>&1; then
    fail "a failed restart must fail the protocol change"
  fi
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$before" ] || fail "failed protocol change must restore awg0.conf"
  [ "$("$ROOT/awg-client" protocol)" = 2.0 ] || fail "failed protocol change must keep protocol 2.0"
  ok "protocol: metadata-only switches, custom fields, failed restart rollback"
}

case_update() {
  echo "# update"
  fresh_install
  stub_awg
  stub_git_version
  stub_systemctl
  # First update on a fresh install, before any awg-client call: nothing but install.sh
  # has created /etc/amnezia/amneziawg so far.
  "$ROOT/update.sh" --force --bin-dir "$BIN" --no-restart >/dev/null || fail "update must work on a fresh install"
  stub_awg   # the update replaced the stubbed awg with the real binary

  "$ROOT/awg-client" add carol >/dev/null
  local before out mtime; before=$(sha256sum "$CONF" | cut -d' ' -f1)
  out=$("$ROOT/update.sh" --force --bin-dir "$BIN" --no-restart)
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$before" ] || fail "update must not touch awg0.conf"
  "$ROOT/awg-client" list | grep -q carol || fail "clients lost after update"
  echo "$out" | grep -q 'runtime not verified' || fail "--no-restart must say the runtime was not verified"

  # is-active alone is not health: a broken interface must stop the update before replacing files.
  mtime=$(stat -c %y /usr/local/bin/awg)
  if SYSTEMCTL_ACTIVE=1 AWG_STUB_SHOW_FAIL=1 "$ROOT/update.sh" --force --bin-dir "$BIN" >/dev/null 2>&1; then
    fail "update must refuse an active service whose interface is unusable"
  fi
  [ "$(stat -c %y /usr/local/bin/awg)" = "$mtime" ] || fail "refused update must not replace binaries"

  # Migration of installations created before the idempotent NAT and robust PostDown.
  printf 'table ip awg_nat {\n}\n' > "$DIR/nat-up.nft"
  sed -i 's|^PostDown = .*|PostDown = nft delete table ip awg_nat|' "$CONF"
  "$ROOT/update.sh" --force --bin-dir "$BIN" --no-restart >/dev/null
  grep -qx 'delete table ip awg_nat' "$DIR/nat-up.nft" || fail "update must make nat-up.nft idempotent"
  grep -q '^PostDown = .*|| true$' "$CONF" || fail "update must fix PostDown for an old installation"
  mtime=$(stat -c %y /usr/local/bin/awg)

  # A stopped service is not an implicit --no-restart.
  if SYSTEMCTL_ACTIVE=0 "$ROOT/update.sh" --force --bin-dir "$BIN" >/dev/null 2>&1; then
    fail "update must refuse a stopped service without --no-restart"
  fi
  [ "$(stat -c %y /usr/local/bin/awg)" = "$mtime" ] || fail "stopped-service refusal must not replace binaries"

  # An unfinished transaction is the only copy of the old state: no second update.
  mkdir -p "$DIR/transactions/update.test"
  if "$ROOT/update.sh" --force --bin-dir "$BIN" --no-restart >/dev/null 2>&1; then
    fail "update must refuse while an unfinished operation exists"
  fi
  rm -rf "$DIR/transactions/update.test"

  # A failed restart must restore the previous binaries and metadata.
  mtime=$(stat -c %y /usr/local/bin/awg)
  local vhash; vhash=$(sha256sum "$DIR/versions" | cut -d' ' -f1)
  if SYSTEMCTL_ACTIVE=1 SYSTEMCTL_RESTART_FAIL=1 "$ROOT/update.sh" --force --bin-dir "$BIN" >/dev/null 2>&1; then
    fail "a failed restart must fail the update"
  fi
  [ "$(stat -c %y /usr/local/bin/awg)" = "$mtime" ] || fail "failed update must restore the previous binaries"
  [ "$(sha256sum "$DIR/versions" | cut -d' ' -f1)" = "$vhash" ] || fail "failed update must restore versions"
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$before" ] || fail "failed update must not touch awg0.conf"
  ok "update: fresh install, health gate, stopped service, pending block, rollback"
}

case_lock() {
  echo "# lock"
  fresh_install
  stub_awg
  local hold=/run/lock/awg-vps-kit.lock
  mkdir -p /run/lock

  # A concurrent operation must make add wait for the lock, not race it.
  flock "$hold" -c 'sleep 2' & local hp=$!
  sleep 0.3
  local t0 t1 elapsed
  t0=$(date +%s%N)
  "$ROOT/awg-client" add waited >/dev/null || fail "add must wait for the lock and then succeed"
  t1=$(date +%s%N)
  wait $hp
  elapsed=$(( (t1 - t0) / 1000000 ))
  [ "$elapsed" -ge 1500 ] || fail "add did not wait for the kit lock (${elapsed}ms)"

  # A lock that is never released must end in a clear error, not a second writer.
  flock "$hold" -c 'sleep 12' & hp=$!
  sleep 0.3
  local out rc
  set +e
  out=$("$ROOT/awg-client" add blocked 2>&1); rc=$?
  set -e
  wait $hp || true
  [ "$rc" -ne 0 ] || fail "add must fail while another operation holds the lock"
  case "$out" in *"another kit operation is running"*) ;; *) fail "lock timeout message missing (got: $out)" ;; esac
  assert_missing "$DIR/clients/blocked.conf" "a blocked add must not write client files"

  # update and uninstall take the same lock; hold it longer than both timeouts
  flock "$hold" -c 'sleep 25' & hp=$!
  sleep 0.3
  if "$ROOT/update.sh" --force --bin-dir "$BIN" --no-restart >/dev/null 2>&1; then
    fail "update must respect the kit lock"
  fi
  if "$ROOT/uninstall.sh" --yes >/dev/null 2>&1; then
    fail "uninstall must respect the kit lock"
  fi
  wait $hp || true
  [ -d "$DIR" ] || fail "a blocked uninstall must not remove /etc/amnezia"

  "$ROOT/awg-client" add lock1 >/dev/null & local p1=$!
  "$ROOT/awg-client" add lock2 >/dev/null & local p2=$!
  wait $p1 || fail "first concurrent add failed"
  wait $p2 || fail "second concurrent add failed"
  [ "$("$ROOT/awg-client" list | awk '{print $1}' | sort -u | wc -l)" = 3 ] || fail "concurrent adds shared an address"
  ok "lock: waiting, timeout and concurrent adds"
}

case_watchdog() {
  echo "# watchdog"
  [ -x "$ROOT/awg-watchdog" ] || fail "awg-watchdog script is missing"
  mkdir -p "$DIR"; : > "$CONF"   # the watchdog ignores hosts where the kit is not installed
  local tmp; tmp=$(mktemp -d /tmp/awg-wd.XXXXXX)
  : > /tmp/awg-wd-restarts
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/systemctl" <<'EOS'
#!/bin/sh
case "$1" in
  is-active) [ "${WD_ACTIVE:-1}" = 1 ]; exit $? ;;
  restart) printf '%s\n' "$*" >> /tmp/awg-wd-restarts; exit 0 ;;
  *) exit 0 ;;
esac
EOS
  cat > "$tmp/bin/awg" <<'EOS'
#!/bin/sh
[ "${WD_SHOW_FAIL:-0}" = 1 ] && exit 1
exit 0
EOS
  cat > "$tmp/bin/ip" <<'EOS'
#!/bin/sh
[ "${WD_LINK_FAIL:-0}" = 1 ] && exit 1
exit 0
EOS
  cat > "$tmp/bin/nft" <<'EOS'
#!/bin/sh
[ "${WD_NFT_FAIL:-0}" = 1 ] && exit 1
exit 0
EOS
  chmod 755 "$tmp/bin/systemctl" "$tmp/bin/awg" "$tmp/bin/ip" "$tmp/bin/nft"

  PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog" || fail "watchdog must exit 0 on a healthy tunnel"
  [ ! -s /tmp/awg-wd-restarts ] || fail "watchdog restarted a healthy tunnel"

  WD_SHOW_FAIL=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog" || fail "watchdog must exit 0 after a restart attempt"
  grep -qx 'restart awg-quick@awg0' /tmp/awg-wd-restarts || fail "watchdog did not restart a dead tunnel"
  : > /tmp/awg-wd-restarts

  WD_LINK_FAIL=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog" || fail "watchdog must exit 0 after a restart attempt"
  grep -qx 'restart awg-quick@awg0' /tmp/awg-wd-restarts || fail "watchdog ignored a missing interface"
  : > /tmp/awg-wd-restarts

  # NAT can disappear without the interface dying (systemctl restart nftables).
  WD_NFT_FAIL=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog" || fail "watchdog must exit 0 after a restart attempt"
  grep -qx 'restart awg-quick@awg0' /tmp/awg-wd-restarts || fail "watchdog ignored a missing NAT table"
  : > /tmp/awg-wd-restarts

  WD_ACTIVE=0 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog"
  [ ! -s /tmp/awg-wd-restarts ] || fail "watchdog restarted an inactive unit"
  rm -rf "$tmp"; rm -f "$CONF"
  ok "watchdog: healthy, dead daemon, missing interface, missing NAT, inactive unit"
}

if [ "$CASE" = all ]; then
  for c in cli bootstrap cleanup lock peers protocol update watchdog; do
    "case_$c"
  done
else
  case "$CASE" in
    cli|bootstrap|cleanup|lock|peers|protocol|update|watchdog) "case_$CASE" ;;
    *) echo "unknown case: $CASE" >&2; exit 2 ;;
  esac
fi
echo "All reliability tests passed ($CASE)"
