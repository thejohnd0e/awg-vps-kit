#!/bin/bash
# Container test for install.sh (--no-service) and awg-client.
# Usage (as root, from the repo root): tests/test-install.sh <dir with amneziawg-go, awg, awg-quick>
# Real `awg` is used for key generation; commands that need a live interface are stubbed.
set -euo pipefail

BIN=${1:?usage: $0 BIN_DIR}
DIR=/etc/amnezia/amneziawg
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
has() { grep -q -- "$2" "$1" || fail "$1 lacks: $2"; }

./install.sh --no-service --subnet 10.79.0 --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN"
for f in awg0.conf srv.key srv.pub endpoint nat-up.nft README.md; do [ -s "$DIR/$f" ] || fail "missing $DIR/$f"; done
has "$DIR/awg0.conf" 'Address = 10.79.0.1/24'
[ -s "$DIR/versions" ] || fail "versions file not recorded"
[ -s "$DIR/upstream.lock" ] || fail "upstream.lock not recorded"
has "$DIR/upstream.lock" '^amneziawg-go='
diff -q upstream.lock "$DIR/upstream.lock" >/dev/null || fail "installed upstream.lock differs from the repo's upstream.lock"
has "$DIR/awg0.conf" 'ListenPort = 443'
has "$DIR/nat-up.nft" 'ip saddr 10.79.0.0/24 oifname "eth0" masquerade'
[ "$(grep -E '^H[1-4] =' "$DIR/awg0.conf" | awk '{print $3}' | sort -u | wc -l)" = 4 ] || fail "H1-H4 not distinct"
ok "install.sh wrote server files"

# The shared library: installed next to the kit, required by the installed awg-client.
LIBF=/usr/local/lib/awg-vps-kit/common.sh
[ "$(stat -c %a "$LIBF")" = 644 ] || fail "$LIBF must be mode 644"
cmp -s lib/common.sh "$LIBF" || fail "installed library differs from lib/common.sh"
mv /usr/local/lib/awg-vps-kit /usr/local/lib/awg-vps-kit.away
if out=$(/usr/local/bin/awg-client list 2>&1); then fail "awg-client must not run without its library"; fi
mv /usr/local/lib/awg-vps-kit.away /usr/local/lib/awg-vps-kit
grep -q 'common.sh is missing' <<<"$out" || fail "missing library: unhelpful message: $out"
lib_check() (
  . ./lib/common.sh
  local -a h; local n prev=-1 lo hi f d
  mapfile -t h < <(awg_h_values 1.0)
  { [ "${#h[@]}" = 4 ] && [ "$(printf '%s\n' "${h[@]}" | sort -u | wc -l)" = 4 ]; } || fail "lib: 1.0 needs four distinct H values"
  for n in "${h[@]}"; do { [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 5 ]; } || fail "lib: bad H value $n"; done
  mapfile -t h < <(awg_h_values 2.0)
  [ "${#h[@]}" = 4 ] || fail "lib: 2.0 needs four H ranges"
  for n in "${h[@]}"; do
    [[ "$n" =~ ^([0-9]+)-([0-9]+)$ ]] || fail "lib: 2.0 H is not a range: $n"
    lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[2]}
    { [ "$lo" -lt "$hi" ] && [ "$lo" -gt "$prev" ]; } || fail "lib: H ranges overlap or are unordered at $n"
    prev=$hi
  done
  awg_s34_values | grep -Eq '^S3 = ([89]|[1-5][0-9]|6[0-4])$' || fail "lib: S3 out of range"
  awg_s34_values | grep -Eq '^S4 = ([4-9]|[12][0-9]|3[0-2])$' || fail "lib: S4 out of range"
  v=$(awg_s31_value); [[ "$v" =~ ^(1[5-9]|2[0-9]|3[0-2])$ ]] || fail "lib: 3.1 S value out of range: $v"
  mapfile -t h31 < <(awg_h_values 3.1)
  [ "${h31[*]}" = "1 2 3 4" ] || fail "lib: 3.1 H must be 1 2 3 4"
  awg_31_client_defaults | grep -q '^ContentPaddingAddition=10-100$' || fail "lib: 3.1 default CPA missing"
  [ "$(awg_31_client_defaults | grep -cE '^(I1|ContentPaddingAddition|DisableCookies|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts)=')" = 8 ] \
    || fail "lib: 3.1 client defaults must have exactly 8 keys"
  d=$(mktemp -d); f=$d/kvfile
  printf 'a=1\nI1=<b 0x01>=x\n b =2\n' > "$f"
  [ "$(kv "$f" I1)" = '<b 0x01>=x' ] || fail "lib: kv must keep '=' inside a value"
  [ "$(kv "$f" b)" = 2 ] || fail "lib: kv must tolerate spaces around the key"
  [ -z "$(kv "$f" missing)" ] || fail "lib: kv of a missing key must be empty"
  [ -z "$(kv "$d/nofile" a)" ] || fail "lib: kv of a missing file must be empty"
  for n in 1 2 3 4 5 6 7; do : > "$d/bak-2020010$n-000000"; done
  : > "$d/bak-20261108-120000"; : > "$d/other"
  prune_backups "$d/bak-"
  [ "$(find "$d" -name 'bak-*' | wc -l)" = 5 ] || fail "lib: prune_backups must keep 5"
  { [ -e "$d/bak-20261108-120000" ] && [ -e "$d/other" ]; } || fail "lib: prune_backups removed the wrong file"
  [ ! -e "$d/bak-20200101-000000" ] || fail "lib: prune_backups kept an old backup"
  rm -rf "$d"
)
lib_check
ok "shared library: installed, required by awg-client, generators, kv, prune_backups"

[ -x /usr/local/bin/block-ping ] || fail "block-ping not installed"
block-ping help | grep -q "block-ping on" || fail "block-ping help"
if block-ping bogus >/dev/null 2>&1; then fail "block-ping must reject unknown commands"; fi
ok "block-ping installed and answers help"
kit_version=$(tr -d '\r\n ' < VERSION)
ver=$(awg-client version)
echo "$ver" | grep -q "^awg-vps-kit: $kit_version " || fail "awg-client version: wrong kit version"
echo "$ver" | grep -Eq '^amneziawg-go: [0-9a-f]{7}$' || fail "awg-client version: no amneziawg-go commit"
ok "awg-client version"

if ./install.sh --no-service --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null 2>&1; then
  fail "second install.sh run must refuse to overwrite"
fi
ok "install.sh refuses to overwrite an existing config"

# No live interface in the container: keep real key generation, stub the rest.
stub_awg() {
  mv /usr/local/bin/awg /usr/local/bin/awg.real
  cat > /usr/local/bin/awg <<'EOS'
#!/bin/sh
case "$1" in
  genkey|pubkey|genpsk) exec /usr/local/bin/awg.real "$@" ;;
  show) if [ -n "${AWG_STUB_DUMP:-}" ] && [ "$3" = dump ]; then cat "$AWG_STUB_DUMP"; fi; exit 0 ;;
  *) exit 0 ;;
esac
EOS
  chmod 755 /usr/local/bin/awg
}
stub_awg

awg-client add alice >/dev/null
awg-client add bob >/dev/null
awg-client list | grep -q "^10.79.0.2.*alice" || fail "alice should get 10.79.0.2"
awg-client list | grep -q "^10.79.0.3.*bob" || fail "bob should get 10.79.0.3"
ok "add assigns sequential addresses"

out=$(awg-client show alice)
grep -q 'Address = 10.79.0.2/32' <<<"$out" || fail "show: wrong address"
grep -q 'Endpoint = 203.0.113.10:443' <<<"$out" || fail "show: wrong endpoint"
h1=$(awk '$1=="H1"{print $3; exit}' "$DIR/awg0.conf")
grep -q "^H1 = $h1\$" <<<"$out" || fail "show: H1 differs from server"
[ "$(echo "$out" | head -1)" = "$(printf "%60s" "" | tr " " "#")" ] || fail "show: config is not framed by separator lines"
[ "$(grep -c "^####" "$DIR/clients/alice.conf")" = 0 ] || fail "separator leaked into the client file"
ok "show prints a matching client config"

grep -q '^MTU = 1420$' <<<"$out" || fail "show: default client MTU must be 1420"
grep -q '^MTU = 1280$' "$DIR/awg0.conf" || fail "server MTU must stay 1280"
if grep -q "maxseg\|TCPMSS" "$DIR/nat-up.nft" "$DIR/awg0.conf"; then fail "no MSS clamp allowed (VPN fingerprint)"; fi
[ "$(awg-client mtu)" = 1420 ] || fail "mtu without argument must print 1420"
if awg-client mtu 1200 >/dev/null 2>&1; then fail "mtu below 1280 must fail"; fi
if awg-client mtu abc >/dev/null 2>&1; then fail "non-numeric mtu must fail"; fi
awg-client mtu 1360 >/dev/null
out=$(awg-client show alice)
grep -q '^MTU = 1360$' <<<"$out" || fail "show must use the configured client MTU"
awg-client mtu 1420 >/dev/null
ok "client MTU defaults to 1420, is configurable, server MTU unchanged"

if awg-client add alice >/dev/null 2>&1; then fail "duplicate add must fail"; fi
if awg-client add 'bad name' >/dev/null 2>&1; then fail "invalid name must fail"; fi
ok "duplicate and invalid names rejected"

awg-client remove alice >/dev/null
if awg-client list | grep -q alice; then fail "alice still listed after remove"; fi
awg-client list | grep -q bob || fail "bob lost after removing alice"
awg-client add carol >/dev/null
awg-client list | grep -q "^10.79.0.2.*carol" || fail "carol should reuse 10.79.0.2"
ok "remove frees the address and keeps other clients"

# Hand-edited config: no blank lines between blocks. Removing one peer must keep the rest.
awg-client add frank >/dev/null
sed -i '/^$/d' "$DIR/awg0.conf"
[ "$(grep -c '^\[Peer\]' "$DIR/awg0.conf")" = 3 ] || fail "setup: expected bob, carol, frank"
awg-client remove carol >/dev/null
names=$(awg-client list | cut -f2 | sort | tr '\n' ' ')
[ "$names" = "bob frank " ] || fail "remove on a compact config removed the wrong peers: $names"
[ "$(grep -c '^\[Peer\]' "$DIR/awg0.conf")" = 2 ] || fail "remove on a compact config left $(grep -c '^\[Peer\]' "$DIR/awg0.conf") peers"
grep -q '^PrivateKey = ' "$DIR/awg0.conf" || fail "remove lost the [Interface] section"
awg-client remove frank >/dev/null
awg-client list | grep -q bob || fail "bob lost after removing the last peer"
[ -z "$(tail -c 1 "$DIR/awg0.conf" | tr -d '\n')" ] || fail "config must end with a newline"
awg-client add carol >/dev/null
awg-client list | grep -q "^10.79.0.2.*carol" || fail "carol should get 10.79.0.2 again"
ok "remove deletes exactly one peer in a config without blank lines"

# --- client DNS: default, validation, per-config effect, reset
[ "$(awg-client dns)" = 1.1.1.1 ] || fail "dns without argument must print 1.1.1.1"
out=$(awg-client show bob); grep -q '^DNS = 1.1.1.1$' <<<"$out" || fail "default client DNS must be 1.1.1.1"
for bad in abc 1.1.1 256.1.1.1 ::1 01.1.1.1 "1.1.1.1," 1.1.1.1,,2.2.2.2 1.1.1.1,2.2.2.2,3.3.3.3,4.4.4.4; do
  if awg-client dns "$bad" >/dev/null 2>&1; then fail "dns '$bad' must be rejected"; fi
done
[ "$(awg-client dns)" = 1.1.1.1 ] || fail "a rejected dns value must not change the setting"
awg-client dns 9.9.9.9,149.112.112.112 >/dev/null
[ "$(awg-client dns)" = "9.9.9.9, 149.112.112.112" ] || fail "dns must be stored normalised"
out=$(awg-client show bob); grep -q '^DNS = 9.9.9.9, 149.112.112.112$' <<<"$out" || fail "show must use the configured DNS"
awg-client dns default >/dev/null
{ [ "$(awg-client dns)" = 1.1.1.1 ] && [ ! -e "$DIR/client-dns" ]; } || fail "dns default must restore 1.1.1.1"
ok "client DNS: default, validation, applied to show, reset"

# --- rename: only the name changes
awg-client add bobby >/dev/null
bobkey=$(cat "$DIR/clients/bob.key"); bobip=$(awg-client list | awk '$2=="bob"{print $1}')
bobip=${bobip%/32}   # list prints the AllowedIPs value
awg-client rename bob bobx >/dev/null
names=$(awg-client list | cut -f2 | sort | tr '\n' ' ')
[ "$names" = "bobby bobx carol " ] || fail "rename touched the wrong peers: $names"
for e in key pub psk conf; do
  { [ ! -e "$DIR/clients/bob.$e" ] && [ -e "$DIR/clients/bobx.$e" ]; } || fail "rename must move clients/bob.$e"
done
out=$(awg-client show bobx)
grep -q "^PrivateKey = $bobkey\$" <<<"$out" || fail "rename must keep the client key"
grep -q "^Address = $bobip/32\$" <<<"$out" || fail "rename must keep the client address"
if awg-client show bob >/dev/null 2>&1; then fail "the old name must be gone after rename"; fi
for args in "bobx carol" "bobx bobx" "nosuch other" "bobx" "bobx bad!name" "bobx $(printf 'n%.0s' $(seq 1 33))"; do
  # shellcheck disable=SC2086  # word splitting of the argument pairs is the point
  if awg-client rename $args >/dev/null 2>&1; then fail "rename $args must fail"; fi
done
[ "$(awg-client list | cut -f2 | sort | tr '\n' ' ')" = "bobby bobx carol " ] || fail "a rejected rename changed the list"
sed -i '/^$/d' "$DIR/awg0.conf"     # a compact config must be handled too
awg-client rename carol carol2 >/dev/null
[ "$(awg-client list | cut -f2 | sort | tr '\n' ' ')" = "bobby bobx carol2 " ] || fail "rename in a compact config failed"
[ "$(grep -c '^\[Peer\]' "$DIR/awg0.conf")" = 3 ] || fail "rename must keep every peer"
ok "rename: only the name changes, keys and address stay, bad input rejected"

# --- list -v: handshake, traffic and endpoint from the running interface
[ "$(awg-client list | head -1 | cut -f2)" = carol2 ] || fail "plain list changed its format"
bpub=$(cat "$DIR/clients/bobx.pub"); now=$(date +%s)
dump=$(mktemp)
printf 'priv\tpub\t443\toff\t5\t40\t900\t1\t2\t3\t4\n%s\t(none)\t198.51.100.7:51820\t10.79.0.3/32\t%s\t1048576\t2097152\t25\n' "$bpub" "$((now - 125))" > "$dump"
out=$(AWG_STUB_DUMP=$dump awg-client list -v)
head -1 <<<"$out" | grep -q '^NAME .*ADDRESS .*HANDSHAKE .*RX .*TX .*ENDPOINT$' || fail "list -v: bad header: $out"
row=$(grep '^bobx ' <<<"$out")
for want in '2m ago' '1.0 MiB' '2.0 MiB' '198.51.100.7:51820'; do grep -q -- "$want" <<<"$row" || fail "list -v: bobx row lacks '$want': $row"; done
row=$(grep '^bobby ' <<<"$out"); grep -q 'HANDSHAKE\|ago\|never' <<<"$row" && fail "list -v: a peer missing from the dump must show dashes: $row"
out=$(awg-client list -v 2>&1); grep -q 'not running' <<<"$out" || fail "list -v without a live interface must say so: $out"
grep -q '^bobx ' <<<"$out" || fail "list -v without a live interface must still list clients"
if awg-client list --bogus >/dev/null 2>&1; then fail "list must reject unknown options"; fi
rm -f "$dump"
ok "list -v: handshake age, traffic, endpoint, no live data"

# --- export: every client in one archive, current format, private
awg-client dns 9.9.9.9 >/dev/null
exp=$(mktemp -u /tmp/awg-export.XXXXXX).tar.gz
awg-client export "$exp" >/dev/null || fail "export failed"
[ "$(stat -c %a "$exp")" = 600 ] || fail "the export archive must be mode 600"
[ "$(tar -tzf "$exp" | sed 's#^\./##' | sort | tr '\n' ' ')" = "bobby.conf bobx.conf carol2.conf " ] || fail "export must hold one config per client: $(tar -tzf "$exp" | tr '\n' ' ')"
out=$(tar -xzOf "$exp" ./bobx.conf)
grep -q '^DNS = 9.9.9.9$' <<<"$out" || fail "export must use the current DNS setting"
grep -q "^PrivateKey = $bobkey\$" <<<"$out" || fail "exported config lacks the client key"
if awg-client export "$exp" >/dev/null 2>&1; then fail "export must not overwrite an existing file"; fi
exdir=$(mktemp -d); ( cd "$exdir" && awg-client export >/dev/null ) || fail "export without a name failed"
[ "$(find "$exdir" -name 'awg-clients-*.tar.gz' | wc -l)" = 1 ] || fail "export without a name must write awg-clients-*.tar.gz to the current folder"
rm -rf "$exp" "$exdir"; awg-client dns default >/dev/null
ok "export: one config per client, current settings, mode 600, no overwrite"

check=$(./update.sh --check) || [ $? = 10 ]   # 0 = latest installed, 10 = update available
echo "$check" | grep -q "^amneziawg-go: " || fail "update --check printed no status"
./update.sh --force --bin-dir "$BIN" --no-restart >/dev/null
awg-client list | grep -q carol || fail "clients lost after update"
ok "update.sh --check and --force keep the config"

./uninstall.sh --yes >/dev/null
for p in /etc/amnezia /opt/amneziawg /usr/local/lib/awg-vps-kit /usr/local/bin/awg /usr/local/bin/awg-client /usr/local/bin/amneziawg-go; do
  [ ! -e "$p" ] || fail "uninstall left $p"
done
ok "uninstall.sh removed everything"

# Protocol versions: server fields, client fields, recorded choice.
for proto in 1.5 2.0 3.1; do
  ./install.sh --no-service --protocol "$proto" --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null
  stub_awg
  has "$DIR/protocol" "^protocol=$proto\$"
  awg-client add dave >/dev/null
  cfg=$DIR/clients/dave.conf
  [ "$(awg-client version | grep "^protocol:")" = "protocol: $proto" ] || fail "version: protocol $proto not shown"
  case "$proto" in
    1.5)
      has "$cfg" '^I1 = <b 0x'
      grep -q '^I1' "$DIR/awg0.conf" && fail "I1 must stay client side"
      grep -Eq '^(S3|S4) ' "$cfg" && fail "1.5 must not have S3/S4" ;;
    2.0)
      has "$DIR/awg0.conf" '^S3 = '; has "$DIR/awg0.conf" '^S4 = '
      has "$cfg" '^S3 = '; has "$cfg" '^S4 = '
      grep -Eq '^H[1-4] = [0-9]+-[0-9]+$' "$cfg" || fail "2.0 H1-H4 must be ranges"
      [ "$(grep -cE '^H[1-4] = [0-9]+-[0-9]+$' "$cfg")" = 4 ] || fail "2.0 needs four H ranges"
      grep -E '^H[1-4] =' "$cfg" | awk '{split($3,r,"-"); print r[1]; print r[2]}' | sort -n -c || fail "H ranges overlap or are unordered" ;;
    3.1)
      s=$(awk '$1=="S1"{print $3}' "$DIR/awg0.conf")
      [ "$(grep -cE "^S[1-4] = $s\$" "$DIR/awg0.conf")" = 4 ] || fail "3.1: S1-S4 must be one equal value"
      [[ "$s" =~ ^(1[5-9]|2[0-9]|3[0-2])$ ]] || fail "3.1: S out of 15-32"
      [ "$(awk '$1 ~ /^H[1-4]$/{print $3}' "$DIR/awg0.conf" | paste -sd,)" = "1,2,3,4" ] || fail "3.1: H must be 1/2/3/4"
      grep -Eq '^HeaderProtectionKey = [A-Za-z0-9+/]{43}=$' "$DIR/awg0.conf" || fail "3.1: HPK missing"
      has "$DIR/awg0.conf" '^RandomTrailers = on$'
      has "$DIR/awg0.conf" '^ContentPaddingAddition = 10-100$'
      has "$DIR/protocol" '^ContentPaddingAddition=10-100$'
      has "$cfg" '^MTU = 1420$'   # HARD RULE: never 1280 on a client (VPN fingerprint)
      srvhpk=$(awk '$1=="HeaderProtectionKey"{print $3}' "$DIR/awg0.conf")
      grep -q "^HeaderProtectionKey = $srvhpk\$" "$cfg" || fail "3.1: client HPK must equal the server one"
      has "$cfg" '^RandomTrailers = on$'
      has "$cfg" '^DisableCookies = on$'
      has "$cfg" '^ContentPaddingAddition = 10-100$'
      [ "$(grep -cE '^(RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts) = ' "$cfg")" = 5 ] || fail "3.1: client timers missing"
      has "$cfg" '^I1 = <b 0x' ;;
  esac
  ok "protocol $proto"
  ./uninstall.sh --yes >/dev/null
done
# Client MTU is 1420 on every protocol (1280 is a VPN fingerprint, see DECISIONS.md); an explicit `awg-client mtu` overrides.
./install.sh --no-service --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null
stub_awg
awg-client add gina >/dev/null
grep -q '^MTU = 1420$' "$DIR/clients/gina.conf" || fail "1.0 client MTU must default to 1420"
[ "$(awg-client mtu)" = 1420 ] || fail "mtu on 1.0 must print 1420"
./uninstall.sh --yes >/dev/null
./install.sh --no-service --protocol 3.1 --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null
stub_awg
awg-client add hank >/dev/null
grep -q '^MTU = 1420$' "$DIR/clients/hank.conf" || fail "3.1 client MTU must default to 1420"
[ "$(awg-client mtu)" = 1420 ] || fail "mtu on 3.1 must print 1420"
awg-client mtu 1400 >/dev/null
[ "$(awg-client mtu)" = 1400 ] || fail "an explicit mtu must override the default"
./uninstall.sh --yes >/dev/null
ok "client MTU defaults to 1420 on 1.0 and 3.1 and is overridable"
# Switching the protocol of an installed server: fields rewritten, keys and clients kept.
./install.sh --no-service --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null
stub_awg
awg-client add erin >/dev/null
[ "$(awg-client protocol)" = 1.0 ] || fail "protocol: fresh server must report 1.0"
key=$(cat "$DIR/clients/erin.key"); s1=$(awk '$1=="S1"{print $3}' "$DIR/awg0.conf")
for proto in 1.5 2.0 3.1 1.0; do
  awg-client protocol "$proto" >/dev/null
  [ "$(awg-client protocol)" = "$proto" ] || fail "protocol: $proto not recorded"
  [ "$(grep -c '^\[Peer\]' "$DIR/awg0.conf")" = 1 ] || fail "protocol $proto: peer lost"
  if [ "$proto" = 3.1 ]; then
    [ "$(grep -cE '^(S[1-4]|H[1-4]|HeaderProtectionKey|RandomTrailers|ContentPaddingAddition) = ' "$DIR/awg0.conf")" = 11 ] || fail "protocol 3.1: wrong server fields"
    s1=$(awk '$1=="S1"{print $3}' "$DIR/awg0.conf")   # 3.1 makes S1-S4 equal; a later downgrade must keep them
  else
    [ "$(awk '$1=="S1"{print $3}' "$DIR/awg0.conf")" = "$s1" ] || fail "protocol $proto: S1 changed"
    [ "$(awk '/^\[Peer\]/{exit} /^(S3|S4|H[1-4]) =/' "$DIR/awg0.conf" | wc -l)" = "$([ "$proto" = 2.0 ] && echo 6 || echo 4)" ] || fail "protocol $proto: wrong server fields"
  fi
  out=$(awg-client show erin)
  grep -q "^PrivateKey = $key\$" <<<"$out" || fail "protocol $proto: client key changed"
  case "$proto" in
    2.0) grep -Eq '^H1 = [0-9]+-[0-9]+$' <<<"$out" || fail "2.0: client H1 not a range"; grep -q '^S3 = ' <<<"$out" || fail "2.0: client has no S3" ;;
    1.5) grep -q '^I1 = ' <<<"$out" || fail "1.5: client has no I1" ;;
    3.1) grep -q '^HeaderProtectionKey = ' <<<"$out" || fail "3.1: client has no HPK" ;;
    1.0) grep -Eq '^(S3|S4|I1) ' <<<"$out" && fail "1.0 client has newer fields" ;;
  esac
done
for i in 1 2 3 4 5 6 7; do : > "$DIR/awg0.conf.bak-protocol-1.0.2020010$i-000000"; done
awg-client protocol 2.0 >/dev/null
awg-client protocol 1.0 >/dev/null
[ "$(find "$DIR" -maxdepth 1 -name 'awg0.conf.bak-protocol-*' | wc -l)" -le 5 ] || fail "protocol backups are not pruned to 5"
[ ! -e "$DIR/awg0.conf.bak-protocol-1.0.20200101-000000" ] || fail "the oldest protocol backup must be pruned"
find "$DIR" -maxdepth 1 -name 'awg0.conf.bak-protocol-*' ! -name '*.2020*' | grep -q . || fail "the newest protocol backup was pruned"
[ "$(find "$DIR" -maxdepth 1 -name 'protocol.bak-*' | wc -l)" -le 5 ] || fail "protocol file backups are not pruned to 5"
if out=$(awg-client protocol 3.0 2>&1); then fail "protocol 3.0 must be rejected"; fi
grep -q '3.1' <<<"$out" || fail "protocol 3.0 rejection must mention 3.1"
ok "awg-client protocol switches 1.0 / 1.5 / 2.0 / 3.1 and keeps clients"
./uninstall.sh --yes >/dev/null

if out=$(./install.sh --no-service --protocol 3.0 --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" 2>&1); then
  fail "unknown protocol must be rejected"
fi
grep -q '1.0, 1.5, 2.0 or 3.1' <<<"$out" || fail "unknown protocol: unexpected message: $out"
ok "unknown protocol rejected"

# A tunnel /24 on top of a network the server is connected to must be refused.
local_pfx=$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); split(a[1],o,"."); print o[1]"."o[2]"."o[3]; exit}')
if [ -n "$local_pfx" ]; then
  if out=$(./install.sh --no-service --subnet "$local_pfx" --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" 2>&1); then
    fail "install must refuse subnet $local_pfx.0/24 that overlaps a local network"
  fi
  grep -q 'overlaps a network' <<<"$out" || fail "subnet overlap: unexpected message: $out"
  [ ! -e "$DIR/awg0.conf" ] || fail "a refused subnet must not write awg0.conf"
  ok "install refuses a subnet that overlaps a local network ($local_pfx.0/24)"
else
  echo "skip: no global IPv4 address for the subnet overlap check"
fi

# A run that fails after it started writing must not block the next one.
bad=$(mktemp -d)
cp -p "$BIN/amneziawg-go" "$BIN/awg-quick" "$bad/"
printf '#!/bin/sh\necho "awg: simulated failure" >&2\nexit 1\n' > "$bad/awg"; chmod 755 "$bad/awg"
if ./install.sh --no-service --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$bad" >/dev/null 2>&1; then
  fail "install with a failing awg must fail"
fi
[ ! -e "$DIR" ] || fail "a failed install must not leave $DIR behind"
failed=$(find /etc/amnezia -maxdepth 1 -name 'amneziawg.failed-*' -print -quit)
[ -n "$failed" ] || fail "a failed install must keep its files aside for diagnosis"
rm -rf "$failed"
./install.sh --no-service --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null || fail "install after a failed attempt must work"
[ -s "$DIR/awg0.conf" ] || fail "install after a failed attempt wrote no awg0.conf"
./uninstall.sh --yes >/dev/null
rm -rf "$bad"
ok "a failed install is undone and the next install works"

echo "All tests passed"
