#!/bin/bash
# Reliability scenarios for install.sh, awg-client, update.sh and uninstall.sh.
#
# DESTRUCTIVE: installs the kit into /etc/amnezia, /usr/local/bin and /opt.
# Run only in a disposable container or VM:
#
#   AWG_TEST_ALLOW_DESTRUCTIVE=1 tests/test-reliability.sh BIN_DIR [CASE]
#
# BIN_DIR holds amneziawg-go, awg, awg-quick built by `install.sh --build-only`.
# CASE: cli | peers | protocol | update | lock | bootstrap | cleanup | watchdog | mss | pins | all
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

# shellcheck source=tests/helpers/reliability.sh
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

  # firewalld is not supported: the installer must say so instead of leaving a blocked tunnel.
  rm -rf "$DIR"
  mkdir -p /tmp/awg-fw-bin
  printf '#!/bin/sh\necho running\n' > /tmp/awg-fw-bin/firewall-cmd
  chmod 755 /tmp/awg-fw-bin/firewall-cmd
  out=$(PATH=/tmp/awg-fw-bin:$PATH "$ROOT/install.sh" --no-service \
    --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" 2>&1)
  case "$out" in
    *"firewalld is running but not supported"*) ;;
    *) fail "install.sh must warn about an active firewalld" ;;
  esac
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
# the pinned fetch uses `git fetch` (then `git clone` as a fallback); both must fail
for a in "$@"; do case "$a" in clone|fetch) echo "stub: $a refused" >&2; exit 1 ;; esac; done
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
  [ "$rc" -ne 0 ] || fail "a failed fetch must fail the build"
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

  # rename: a failure while moving the client files restores awg0.conf and the old file names.
  "$ROOT/awg-client" add renme >/dev/null
  pbefore=$(sha256sum "$CONF" | cut -d' ' -f1); saved=$PATH
  stub_mv_fail "/clients/renamed.psk"
  if "$ROOT/awg-client" rename renme renamed >/dev/null 2>&1; then
    fail "rename must fail when moving a client file fails"
  fi
  PATH=$saved
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$pbefore" ] || fail "failed rename must restore awg0.conf"
  local e
  for e in key pub psk conf; do
    [ -e "$CL/renme.$e" ] || fail "failed rename must put $CL/renme.$e back"
    assert_missing "$CL/renamed.$e" "failed rename must not leave $CL/renamed.$e"
  done
  ls -d "$DIR"/transactions/peer.* >/dev/null 2>&1 && fail "clean rename rollback must remove the transaction"
  "$ROOT/awg-client" rename renme renamed >/dev/null || fail "rename must work again after a rolled-back attempt"
  "$ROOT/awg-client" list | grep -q 'renamed$' || fail "renamed client missing from the list"

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
  local before out s has_kv_31 hpk o cbefore rc; before=$(sha256sum "$CONF" | cut -d' ' -f1)
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

  # 2.0 -> 3.1 rewrites S1-S4 to one equal value and adds the 3.x keys and client defaults.
  SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 3.1 >/dev/null
  s=$(awk '$1=="S1"{print $3}' "$CONF")
  [ "$(grep -cE "^S[1-4] = $s\$" "$CONF")" = 4 ] || fail "3.1 switch: equal S missing"
  grep -qE '^HeaderProtectionKey = [A-Za-z0-9+/]{43}=$' "$CONF" || fail "3.1 switch: HPK missing"
  has_kv_31=$(grep -cE '^(ContentPaddingAddition|DisableCookies|RekeyAfterTime)=' "$DIR/protocol")
  [ "$has_kv_31" -ge 3 ] || fail "3.1 switch: client defaults not appended to protocol file"
  # custom values survive the transition (and are not overwritten by the defaults)
  printf 'ContentPaddingAddition=50-90\nRekeyTimeout=9\n' >> "$DIR/protocol"
  SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 2.0 >/dev/null
  SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 3.1 >/dev/null
  grep -q '^ContentPaddingAddition=50-90$' "$DIR/protocol" || fail "3.1 switch must keep custom CPA"
  # a hand-edited line with a space before '=' must keep its value, not gain a duplicate default
  printf 'protocol=3.1\nContentPaddingAddition =50-90\n' > "$DIR/protocol"
  SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 2.0 >/dev/null
  SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 3.1 >/dev/null
  [ "$(grep -cE '^ContentPaddingAddition[[:space:]]*=' "$DIR/protocol")" = 1 ] || fail "a spaced CPA line must not gain a duplicate default"
  grep -q '^ContentPaddingAddition =50-90$' "$DIR/protocol" || fail "a spaced CPA line must keep its value"
  # 3.1 -> 1.0 removes every 3.x key; the equal S1/S2 survive the downgrade
  s=$(awk '$1=="S1"{print $3}' "$CONF")   # re-captured: every switch to 3.1 regenerates S
  SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 1.0 >/dev/null
  grep -qE '^(S3|S4|HeaderProtectionKey|RandomTrailers|ContentPaddingAddition) = ' "$CONF" && fail "downgrade must remove all 3.x keys"
  [ "$(awk '$1=="S1"{print $3}' "$CONF")" = "$s" ] || fail "downgrade must keep the equal S1/S2"
  # an unreviewed engine must be refused before awg0.conf is touched
  before=$(sha256sum "$CONF" | cut -d' ' -f1)
  printf 'amneziawg-go=%040d\namneziawg-tools=%040d\n' 1 2 > "$DIR/versions"
  if SYSTEMCTL_ACTIVE=1 "$ROOT/awg-client" protocol 3.1 >/dev/null 2>&1; then fail "3.1 must be refused on an unreviewed engine"; fi
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$before" ] || fail "refused 3.1 must not touch awg0.conf"
  # an explicit client MTU is kept and 3.1 still applies; the default stays 1420 (1280 = VPN fingerprint)
  printf '1400\n' > "$DIR/client-mtu"
  printf 'amneziawg-go=%s\namneziawg-tools=%s\n' "$(grep '^amneziawg-go=' "$ROOT/upstream.lock" | cut -d= -f2)" x > "$DIR/versions"
  out=$(SYSTEMCTL_ACTIVE=1 "$ROOT/awg-client" protocol 3.1 2>&1)
  if grep -q 'MTU 1280' <<<"$out"; then fail "3.1 must not announce a 1280 client MTU"; fi
  grep -q '^HeaderProtectionKey = ' "$CONF" || fail "3.1 after warning must still apply"
  # HPK must not leak into list/version/protocol output
  hpk=$(awk '$1=="HeaderProtectionKey"{print $3}' "$CONF")
  for o in "$("$ROOT/awg-client" list)" "$("$ROOT/awg-client" list -v)" "$("$ROOT/awg-client" version)" "$out"; do
    grep -q "$hpk" <<<"$o" && fail "HPK must not appear in list/version/protocol output"
  done
  # a failed restart on 3.1 -> 2.0 must roll the 3.1 files back
  before=$(sha256sum "$CONF" | cut -d' ' -f1)
  if SYSTEMCTL_ACTIVE=1 SYSTEMCTL_RESTART_FAIL=1 SYSTEMCTL_LOG=$log \
     "$ROOT/awg-client" protocol 2.0 >/dev/null 2>&1; then
    fail "a failed restart must fail the 3.1 -> 2.0 change"
  fi
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$before" ] || fail "failed 3.1 -> 2.0 must restore awg0.conf"
  [ "$("$ROOT/awg-client" protocol)" = 3.1 ] || fail "failed 3.1 -> 2.0 must keep protocol 3.1"

  # A failing `awg genkey` must not publish an empty HeaderProtectionKey.
  fresh_install
  stub_awg
  stub_systemctl
  : > "$log"
  SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 2.0 >/dev/null
  cbefore=$(sha256sum "$CONF" | cut -d' ' -f1)
  set +e
  out=$(AWG_STUB_GENKEY_FAIL=1 SYSTEMCTL_ACTIVE=1 "$ROOT/awg-client" protocol 3.1 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "protocol 3.1 must fail when awg genkey fails"
  case "$out" in *genkey*) ;; *) fail "a genkey failure must be reported (got: $out)" ;; esac
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$cbefore" ] || fail "a failed genkey must not modify awg0.conf"
  [ "$("$ROOT/awg-client" protocol)" = 2.0 ] || fail "a failed genkey must keep protocol 2.0"
  ls -d "$DIR"/transactions/protocol.* >/dev/null 2>&1 && fail "a failed genkey must not leave a protocol transaction"

  # A missing/malformed anchor must fail the rewrite instead of silently dropping the fields.
  sed -i 's/^Jmax = 900/Jmax=900/' "$CONF"      # the 3.1 anchor is `^Jmax =`
  cbefore=$(sha256sum "$CONF" | cut -d' ' -f1)
  set +e
  out=$(SYSTEMCTL_ACTIVE=1 "$ROOT/awg-client" protocol 3.1 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a missing Jmax anchor must fail the protocol change"
  case "$out" in *Jmax*) ;; *) fail "the anchor error must name Jmax (got: $out)" ;; esac
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$cbefore" ] || fail "a missing Jmax anchor must not modify awg0.conf"
  [ "$("$ROOT/awg-client" protocol)" = 2.0 ] || fail "a missing Jmax anchor must keep protocol 2.0"

  # The old ^S2 = anchor (1.0/2.0 switches) is guarded the same way.
  sed -i 's/^Jmax=900/Jmax = 900/' "$CONF"
  sed -i 's/^S2 = /S2=/' "$CONF"
  cbefore=$(sha256sum "$CONF" | cut -d' ' -f1)
  set +e
  out=$(SYSTEMCTL_ACTIVE=1 "$ROOT/awg-client" protocol 1.0 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a missing S2 anchor must fail the protocol change"
  case "$out" in *S2*) ;; *) fail "the anchor error must name S2 (got: $out)" ;; esac
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$cbefore" ] || fail "a missing S2 anchor must not modify awg0.conf"
  [ "$("$ROOT/awg-client" protocol)" = 2.0 ] || fail "a missing S2 anchor must keep protocol 2.0"
  ok "protocol: metadata-only switches, custom fields, 3.1 switch/downgrade/guards, failed restart rollback, bad genkey and anchor guards"
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

  # HARD RULE: a server with the old MSS clamp (kit 1.3.x-1.4.0) gets the rules removed, nothing else.
  cat > "$DIR/nat-up.nft" <<'EOS'
table ip awg_nat
delete table ip awg_nat
table ip awg_nat {
  chain post {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr 10.79.0.0/24 oifname "eth0" masquerade
  }
  chain awg_forward {
    type filter hook forward priority filter - 1; policy accept;
    # MSS clamping for the 1280 MTU of awg0 (1280 - 40 bytes of IPv4+TCP headers): clients use
    # a larger MTU (1420), so without this they advertise an MSS that does not fit the tunnel.
    iifname "awg0" tcp flags syn tcp option maxseg size > 1240 tcp option maxseg size set 1240
    oifname "awg0" tcp flags syn tcp option maxseg size > 1240 tcp option maxseg size set 1240
    iifname "awg0" accept
    oifname "awg0" ct state established,related accept
  }
}
EOS
  "$ROOT/update.sh" --force --bin-dir "$BIN" --no-restart >/dev/null
  if grep -q 'maxseg' "$DIR/nat-up.nft"; then fail "update must remove the MSS clamp rules"; fi
  grep -q 'masquerade' "$DIR/nat-up.nft" || fail "the masquerade rule must stay"
  [ "$(grep -c '^    iifname "awg0" accept$' "$DIR/nat-up.nft")" = 1 ] || fail "the accept rules must stay"
  ls "$DIR"/nat-up.nft.bak-update-* >/dev/null 2>&1 || fail "update must keep a backup of the old nat-up.nft"
  cp -p "$DIR/nat-up.nft" /tmp/awg-nat-clean
  "$ROOT/update.sh" --force --bin-dir "$BIN" --no-restart >/dev/null
  cmp -s /tmp/awg-nat-clean "$DIR/nat-up.nft" || fail "a second update must not change the cleaned nat-up.nft"
  rm -f /tmp/awg-nat-clean "$DIR"/nat-up.nft.bak-update-*
  # a fresh install must not contain any clamp
  if grep -q 'maxseg' "$ROOT/install.sh"; then fail "install.sh must not write MSS clamp rules"; fi

  # The tunnel unit follows the kit, but only where install.sh created one.
  local unit=/etc/systemd/system/awg-quick@.service
  rm -f "$unit"
  "$ROOT/update.sh" --force --bin-dir "$BIN" --no-restart >/dev/null
  assert_missing "$unit" "update must not create the tunnel unit on a --no-service install"
  mkdir -p /etc/systemd/system
  printf '[Unit]\nDescription=old kit unit\n' > "$unit"
  "$ROOT/update.sh" --force --bin-dir "$BIN" --no-restart >/dev/null
  assert_same "$ROOT/awg-quick@.service" "$unit" "update must refresh an existing tunnel unit"
  printf '[Unit]\nDescription=old kit unit\n' > "$unit"
  "$ROOT/update.sh" --bin-dir "$BIN" --no-restart >/dev/null
  assert_same "$ROOT/awg-quick@.service" "$unit" "update without new binaries must refresh the tunnel unit too"

  # The shared library is part of the managed set: restored when missing, refreshed when stale.
  local libf=/usr/local/lib/awg-vps-kit/common.sh
  assert_same "$ROOT/lib/common.sh" "$libf" "install must have put the library in place"
  rm -rf /usr/local/lib/awg-vps-kit
  "$ROOT/update.sh" --bin-dir "$BIN" --no-restart >/dev/null
  assert_same "$ROOT/lib/common.sh" "$libf" "update must restore a missing library"
  printf '# stale copy\n' > "$libf"
  "$ROOT/update.sh" --force --bin-dir "$BIN" --no-restart >/dev/null
  assert_same "$ROOT/lib/common.sh" "$libf" "update must refresh a stale library"

  # upstream.lock is managed installed state: refreshed to the kit's copy like the library.
  assert_same "$ROOT/upstream.lock" "$DIR/upstream.lock" "install must have put the lock in place"
  printf 'amneziawg-go=0000000000000000000000000000000000000000\namneziawg-tools=0000000000000000000000000000000000000000\n' > "$DIR/upstream.lock"
  "$ROOT/update.sh" --force --bin-dir "$BIN" --no-restart >/dev/null
  assert_same "$ROOT/upstream.lock" "$DIR/upstream.lock" "update must refresh a stale upstream.lock"
  printf '[Unit]\nDescription=old kit unit\n' > "$unit"
  cp -p "$unit" /tmp/awg-old-unit
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
  { cat "$ROOT/lib/common.sh"; echo "# previous library"; } > "$libf"
  cp -p "$libf" /tmp/awg-old-lib
  printf 'amneziawg-go=1111111111111111111111111111111111111111\namneziawg-tools=1111111111111111111111111111111111111111\n' > "$DIR/upstream.lock"
  cp -p "$DIR/upstream.lock" /tmp/awg-old-lock
  mtime=$(stat -c %y /usr/local/bin/awg)
  local vhash; vhash=$(sha256sum "$DIR/versions" | cut -d' ' -f1)
  if SYSTEMCTL_ACTIVE=1 SYSTEMCTL_RESTART_FAIL=1 "$ROOT/update.sh" --force --bin-dir "$BIN" >/dev/null 2>&1; then
    fail "a failed restart must fail the update"
  fi
  [ "$(stat -c %y /usr/local/bin/awg)" = "$mtime" ] || fail "failed update must restore the previous binaries"
  [ "$(sha256sum "$DIR/versions" | cut -d' ' -f1)" = "$vhash" ] || fail "failed update must restore versions"
  [ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$before" ] || fail "failed update must not touch awg0.conf"
  assert_same /tmp/awg-old-unit "$unit" "failed update must restore the previous tunnel unit"
  assert_same /tmp/awg-old-lib "$libf" "failed update must restore the previous library"
  assert_same /tmp/awg-old-lock "$DIR/upstream.lock" "failed update must restore the previous upstream.lock"
  rm -f "$unit" /tmp/awg-old-unit /tmp/awg-old-lib /tmp/awg-old-lock

  # Migration 1.3.x -> 1.4.0 with the binaries already at the unchanged pins: the scripts-only
  # path (refresh_scripts) must still install $DIR/upstream.lock, or engine_is_31 can never pass
  # and `awg-client protocol 3.1` stays stuck behind "run update.sh first".
  fresh_install
  stub_awg
  stub_git_version
  stub_systemctl
  rm -f "$DIR/upstream.lock"
  "$ROOT/update.sh" --bin-dir "$BIN" --no-restart >/dev/null || fail "update without new binaries must succeed"
  assert_same "$ROOT/upstream.lock" "$DIR/upstream.lock" "update without new binaries must install upstream.lock"
  ok "update: fresh install, health gate, stopped service, pending block, rollback, tunnel unit, library, upstream.lock migration"
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
  is-failed) [ "${WD_FAILED:-0}" = 1 ]; exit $? ;;
  restart|start|reset-failed) printf '%s\n' "$*" >> /tmp/awg-wd-restarts; exit 0 ;;
  *) exit 0 ;;
esac
EOS
  cat > "$tmp/bin/ufw" <<'EOS'
#!/bin/sh
case "$1" in
  status) [ "${WD_UFW:-0}" = 1 ] && echo "Status: active" || echo "Status: inactive"; exit 0 ;;
  reload) echo "ufw reload" >> /tmp/awg-wd-restarts; exit 0 ;;
esac
exit 0
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
  chmod 755 "$tmp/bin/systemctl" "$tmp/bin/awg" "$tmp/bin/ip" "$tmp/bin/nft" "$tmp/bin/ufw"
  export AWG_WD_STAMP="$tmp/failed-at"

  PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog" || fail "watchdog must exit 0 on a healthy tunnel"
  [ ! -s /tmp/awg-wd-restarts ] || fail "watchdog restarted a healthy tunnel"

  WD_SHOW_FAIL=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog" || fail "watchdog must exit 0 after a restart attempt"
  grep -qx 'restart awg-quick@awg0' /tmp/awg-wd-restarts || fail "watchdog did not restart a dead tunnel"
  : > /tmp/awg-wd-restarts

  WD_LINK_FAIL=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog" || fail "watchdog must exit 0 after a restart attempt"
  grep -qx 'restart awg-quick@awg0' /tmp/awg-wd-restarts || fail "watchdog ignored a missing interface"
  : > /tmp/awg-wd-restarts

  # NAT can disappear without the interface dying (systemctl restart nftables),
  # but only installs that use the kit's nft table need that check.
  : > "$DIR/nat-up.nft"
  WD_NFT_FAIL=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog" || fail "watchdog must exit 0 after a restart attempt"
  grep -qx 'restart awg-quick@awg0' /tmp/awg-wd-restarts || fail "watchdog ignored a missing NAT table"
  : > /tmp/awg-wd-restarts

  # Older installs (iptables NAT, no nat-up.nft) must not be restarted every 30 s.
  rm -f "$DIR/nat-up.nft"
  WD_NFT_FAIL=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog" || fail "watchdog must exit 0 without an nft NAT table"
  [ ! -s /tmp/awg-wd-restarts ] || fail "watchdog restarted an iptables-NAT install"

  WD_ACTIVE=0 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog"
  [ ! -s /tmp/awg-wd-restarts ] || fail "watchdog restarted an inactive unit"

  # A failed unit is started again, but not every 30 s: one attempt per AWG_WD_RETRY seconds.
  printf 'table ip awg_nat\n' > "$DIR/nat-up.nft"
  WD_ACTIVE=0 WD_FAILED=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog" || fail "watchdog must exit 0 for a failed unit"
  grep -qx 'start awg-quick@awg0' /tmp/awg-wd-restarts || fail "watchdog did not start a failed unit"
  grep -qx 'reset-failed awg-quick@awg0' /tmp/awg-wd-restarts || fail "watchdog did not clear the failed state"
  : > /tmp/awg-wd-restarts
  WD_ACTIVE=0 WD_FAILED=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog"
  [ ! -s /tmp/awg-wd-restarts ] || fail "watchdog retried a failed unit before the pause was over"
  AWG_WD_RETRY=0 WD_ACTIVE=0 WD_FAILED=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog"
  grep -qx 'start awg-quick@awg0' /tmp/awg-wd-restarts || fail "watchdog did not retry after the pause"
  : > /tmp/awg-wd-restarts
  printf 'garbage\n' > "$AWG_WD_STAMP"
  WD_ACTIVE=0 WD_FAILED=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog"
  grep -qx 'start awg-quick@awg0' /tmp/awg-wd-restarts || fail "a corrupt retry stamp must not block the start"
  : > /tmp/awg-wd-restarts
  # a healthy tunnel forgets the last failure, so the next one is handled at once
  PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog"
  [ ! -e "$AWG_WD_STAMP" ] || fail "a healthy run must clear the retry stamp"
  WD_ACTIVE=0 WD_FAILED=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog"
  grep -qx 'start awg-quick@awg0' /tmp/awg-wd-restarts || fail "a new failure after recovery must be handled at once"
  : > /tmp/awg-wd-restarts

  # ufw loses its chains together with awg_nat on a flushed ruleset: reload it, but only then.
  WD_NFT_FAIL=1 WD_UFW=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog"
  grep -qx 'restart awg-quick@awg0' /tmp/awg-wd-restarts || fail "missing NAT must restart the tunnel"
  grep -qx 'ufw reload' /tmp/awg-wd-restarts || fail "missing NAT with active ufw must reload ufw"
  : > /tmp/awg-wd-restarts
  WD_NFT_FAIL=1 WD_UFW=0 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog"
  if grep -qx 'ufw reload' /tmp/awg-wd-restarts; then fail "inactive ufw must not be reloaded"; fi
  : > /tmp/awg-wd-restarts
  WD_SHOW_FAIL=1 WD_UFW=1 PATH="$tmp/bin:$PATH" "$ROOT/awg-watchdog"
  grep -qx 'restart awg-quick@awg0' /tmp/awg-wd-restarts || fail "dead daemon must restart the tunnel"
  if grep -qx 'ufw reload' /tmp/awg-wd-restarts; then fail "a dead daemon alone must not reload ufw"; fi
  : > /tmp/awg-wd-restarts
  rm -rf "$tmp"; rm -f "$CONF"
  unset AWG_WD_STAMP
  ok "watchdog: healthy, dead daemon, missing interface, NAT only for nft installs, inactive unit, failed unit, ufw reload"
}

case_mss() {
  echo "# mss"
  # Needs network namespaces and nft inside them: a plain container may not allow that
  # (run it with --privileged), then the case is skipped rather than failed.
  apt-get install -y -qq iproute2 netcat-openbsd >/dev/null 2>&1 || { echo "skip: mss (iproute2/netcat-openbsd are not installable)"; return 0; }
  if ! ip netns add awgmss-probe 2>/dev/null; then echo "skip: mss (cannot create network namespaces here)"; return 0; fi
  ip netns del awgmss-probe
  fresh_install
  mss_cleanup() { pkill -f 'nc -l 198.51.100.2' 2>/dev/null || true; for n in awgc awgr awgs; do ip netns del "$n" 2>/dev/null || true; done; }
  mss_cleanup; trap mss_cleanup RETURN
  # client (awgc, MTU 1420) -- awg0 (awgr, MTU 1280, the server) -- eth0 -- site (awgs, MTU 1500)
  ip netns add awgc; ip netns add awgr; ip netns add awgs
  # created straight inside the namespaces: the host side may already have an eth0
  ip link add cl0 netns awgc type veth peer name awg0 netns awgr
  ip link add sv0 netns awgs type veth peer name eth0 netns awgr
  ip -n awgc addr add 10.79.0.2/24 dev cl0; ip -n awgc link set cl0 mtu 1420 up; ip -n awgc link set lo up
  ip -n awgr addr add 10.79.0.1/24 dev awg0; ip -n awgr link set awg0 mtu 1280 up
  ip -n awgr addr add 198.51.100.1/24 dev eth0; ip -n awgr link set eth0 mtu 1500 up; ip -n awgr link set lo up
  ip -n awgs addr add 198.51.100.2/24 dev sv0; ip -n awgs link set sv0 mtu 1500 up; ip -n awgs link set lo up
  ip -n awgc route add default via 10.79.0.1
  ip -n awgs route add 10.79.0.0/24 via 198.51.100.1
  ns_sysctl() { ip netns exec "$1" sh -c "echo $3 > /proc/sys/${2//.//}"; }   # no procps needed (not in minimal images)
  ns_sysctl awgr net.ipv4.ip_forward 1
  # ss reports the usable MSS (advertised minus the 12 bytes of the timestamp option): switch the
  # option off on both ends so the numbers below are the MSS values carried in the SYN
  ns_sysctl awgc net.ipv4.tcp_timestamps 0
  ns_sysctl awgs net.ipv4.tcp_timestamps 0

  # the MSS of the server-side and the client-side socket of one connection
  mss_probe() {  # mss_probe <port>: prints "<server mss> <client mss>"
    ip netns exec awgs nc -l 198.51.100.2 "$1" >/dev/null 2>&1 & local nc=$!
    sleep 0.5
    ip netns exec awgc bash -c "exec 3<>/dev/tcp/198.51.100.2/$1; sleep 1.5" & local cl=$!
    sleep 0.8
    local sm cm
    sm=$(ip netns exec awgs ss -tin state established "( sport = :$1 )" | grep -o 'mss:[0-9]*' | head -1 | cut -d: -f2)
    cm=$(ip netns exec awgc ss -tin state established "( dport = :$1 )" | grep -o 'mss:[0-9]*' | head -1 | cut -d: -f2)
    wait $cl 2>/dev/null || true; kill $nc 2>/dev/null || true; wait $nc 2>/dev/null || true
    echo "${sm:-none} ${cm:-none}"
  }

  # HARD RULE: the NAT file the kit writes has no clamp, so the site sees the client's own MSS
  # (1380 for MTU 1420), never 1240 ("MTU 1280" VPN fingerprint)
  if grep -q 'maxseg' "$DIR/nat-up.nft"; then fail "nat-up.nft must have no MSS clamp rules"; fi
  ip netns exec awgr nft -f "$DIR/nat-up.nft" || fail "cannot load $DIR/nat-up.nft"
  local base; base=$(mss_probe 9101)
  [ "${base%% *}" = 1380 ] || fail "server side must see the client's MSS 1380 (got: $base)"
  ok "mss: no clamp, the site sees MSS 1380 (client MTU 1420)"
}

case_pins() {
  echo "# pins"
  fresh_install
  stub_git_version
  local lock="$ROOT/upstream.lock" lgo ltools out rc
  [ "$(grep -Ec '^amneziawg-(go|tools)=[0-9a-f]{40}$' "$lock")" = 2 ] || fail "upstream.lock must hold exactly two 40-hex commits"
  lgo=$(awk -F= '$1=="amneziawg-go"{print $2}' "$lock"); ltools=$(awk -F= '$1=="amneziawg-tools"{print $2}' "$lock")
  run_check() { out=$("$ROOT/update.sh" --check "$@" 2>&1) && rc=0 || rc=$?; }
  printf 'amneziawg-go=%s\namneziawg-tools=%s\n' "$lgo" "$ltools" > "$DIR/versions"

  # installed = pinned: up to date, even though upstream HEAD moved on (only a note)
  run_check
  [ "$rc" = 0 ] || fail "pinned versions installed: --check must exit 0 (got $rc: $out)"
  STUB_HEAD_GO=1111111111111111111111111111111111111111 run_check
  [ "$rc" = 0 ] || fail "a newer upstream HEAD alone must not request an update (got $rc: $out)"
  grep -q "note: amneziawg-go upstream HEAD is 1111111, the reviewed commit is ${lgo:0:7}" <<<"$out" || fail "no note about the unreviewed upstream HEAD: $out"
  if grep -q -- '->' <<<"$out"; then fail "an unreviewed HEAD must not be offered as an update: $out"; fi

  # installed != pinned: the pin is what gets installed, not HEAD
  printf 'amneziawg-go=%s\namneziawg-tools=%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$ltools" > "$DIR/versions"
  STUB_HEAD_GO=1111111111111111111111111111111111111111 run_check
  [ "$rc" = 10 ] || fail "installed differs from the pin: --check must exit 10 (got $rc: $out)"
  grep -q "amneziawg-go: aaaaaaa -> ${lgo:0:7}" <<<"$out" || fail "update must target the pinned commit: $out"

  # --upstream-head follows HEAD instead
  printf 'amneziawg-go=%s\namneziawg-tools=%s\n' "$lgo" "$ltools" > "$DIR/versions"
  STUB_HEAD_GO=1111111111111111111111111111111111111111 run_check --upstream-head
  [ "$rc" = 10 ] || fail "--upstream-head with a newer HEAD must exit 10 (got $rc: $out)"
  grep -q "amneziawg-go: ${lgo:0:7} -> 1111111" <<<"$out" || fail "--upstream-head must target HEAD: $out"

  # a damaged lock stops the update instead of falling back to HEAD
  cp -p "$lock" /tmp/awg-lock.bak
  printf 'amneziawg-go=nonsense\n' > "$lock"
  run_check
  cp -p /tmp/awg-lock.bak "$lock"
  { [ "$rc" != 0 ] && [ "$rc" != 10 ]; } || fail "an invalid upstream.lock must be an error (got $rc: $out)"
  grep -q 'no valid amneziawg-go commit in upstream.lock' <<<"$out" || fail "missing explanation for an invalid lock: $out"

  # A kit update that moves the pins: --check must report what the new kit version would install.
  local base=/tmp/awg-pins origin work pusher
  origin=$base/origin.git; work=$base/work; pusher=$base/pusher
  rm -rf "$base"; mkdir -p "$base"
  git init -q --bare "$origin"
  git init -q "$work"; git -C "$work" checkout -q -b master 2>/dev/null || true
  ( cd "$ROOT" && tar --exclude=.git -cf - . ) | ( cd "$work" && tar -xf - --no-same-owner --no-overwrite-dir )
  git -C "$work" add -A
  git -C "$work" -c user.name=t -c user.email=t@example.invalid commit -q -m base
  git -C "$work" remote add origin "$origin"
  git -C "$work" push -q -u origin master 2>/dev/null
  git clone -q "$origin" "$pusher" 2>/dev/null
  sed -i "s/^amneziawg-go=.*/amneziawg-go=2222222222222222222222222222222222222222/" "$pusher/upstream.lock"
  git -C "$pusher" -c user.name=t -c user.email=t@example.invalid commit -q -am "move the pin"
  git -C "$pusher" push -q origin HEAD:master 2>/dev/null
  out=$("$work/update.sh" --check 2>&1) && rc=0 || rc=$?
  [ "$rc" = 10 ] || fail "a kit update that moves the pin must exit 10 (got $rc: $out)"
  grep -q "amneziawg-go: ${lgo:0:7} -> 2222222" <<<"$out" || fail "--check must use the upstream.lock of the new kit version: $out"
  rm -rf "$base" /tmp/awg-lock.bak
  ok "pins: installed vs pinned vs HEAD, --upstream-head, invalid lock, pin moved by a kit update"
}

if [ "$CASE" = all ]; then
  for c in cli bootstrap cleanup lock peers protocol update watchdog mss pins; do
    "case_$c"
  done
else
  case "$CASE" in
    cli|bootstrap|cleanup|lock|peers|protocol|update|watchdog|mss|pins) "case_$CASE" ;;
    *) echo "unknown case: $CASE" >&2; exit 2 ;;
  esac
fi
echo "All reliability tests passed ($CASE)"
