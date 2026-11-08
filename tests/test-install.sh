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
has "$DIR/awg0.conf" 'ListenPort = 443'
has "$DIR/nat-up.nft" 'ip saddr 10.79.0.0/24 oifname "eth0" masquerade'
[ "$(grep -E '^H[1-4] =' "$DIR/awg0.conf" | awk '{print $3}' | sort -u | wc -l)" = 4 ] || fail "H1-H4 not distinct"
ok "install.sh wrote server files"

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
case "$1" in genkey|pubkey|genpsk) exec /usr/local/bin/awg.real "$@" ;; *) exit 0 ;; esac
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

check=$(./update.sh --check) || [ $? = 10 ]   # 0 = latest installed, 10 = update available
echo "$check" | grep -q "^amneziawg-go: " || fail "update --check printed no status"
./update.sh --force --bin-dir "$BIN" --no-restart >/dev/null
awg-client list | grep -q carol || fail "clients lost after update"
ok "update.sh --check and --force keep the config"

./uninstall.sh --yes >/dev/null
for p in /etc/amnezia /opt/amneziawg /usr/local/bin/awg /usr/local/bin/awg-client /usr/local/bin/amneziawg-go; do
  [ ! -e "$p" ] || fail "uninstall left $p"
done
ok "uninstall.sh removed everything"

# Protocol versions: server fields, client fields, recorded choice.
for proto in 1.5 2.0; do
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
  esac
  ok "protocol $proto"
  ./uninstall.sh --yes >/dev/null
done
# Switching the protocol of an installed server: fields rewritten, keys and clients kept.
./install.sh --no-service --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null
stub_awg
awg-client add erin >/dev/null
[ "$(awg-client protocol)" = 1.0 ] || fail "protocol: fresh server must report 1.0"
key=$(cat "$DIR/clients/erin.key"); s1=$(awk '$1=="S1"{print $3}' "$DIR/awg0.conf")
for proto in 2.0 1.5 1.0; do
  awg-client protocol "$proto" >/dev/null
  [ "$(awg-client protocol)" = "$proto" ] || fail "protocol: $proto not recorded"
  [ "$(grep -c '^\[Peer\]' "$DIR/awg0.conf")" = 1 ] || fail "protocol $proto: peer lost"
  [ "$(awk '$1=="S1"{print $3}' "$DIR/awg0.conf")" = "$s1" ] || fail "protocol $proto: S1 changed"
  [ "$(awk '/^\[Peer\]/{exit} /^(S3|S4|H[1-4]) =/' "$DIR/awg0.conf" | wc -l)" = "$([ "$proto" = 2.0 ] && echo 6 || echo 4)" ] || fail "protocol $proto: wrong server fields"
  out=$(awg-client show erin)
  grep -q "^PrivateKey = $key\$" <<<"$out" || fail "protocol $proto: client key changed"
  case "$proto" in
    2.0) grep -Eq '^H1 = [0-9]+-[0-9]+$' <<<"$out" || fail "2.0: client H1 not a range"; grep -q '^S3 = ' <<<"$out" || fail "2.0: client has no S3" ;;
    1.5) grep -q '^I1 = ' <<<"$out" || fail "1.5: client has no I1" ;;
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
if awg-client protocol 3.0 >/dev/null 2>&1; then fail "protocol 3.0 must be rejected"; fi
ok "awg-client protocol switches 1.0 / 1.5 / 2.0 and keeps clients"
./uninstall.sh --yes >/dev/null

if ./install.sh --no-service --protocol 3.0 --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null 2>&1; then
  fail "unknown protocol must be rejected"
fi
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
