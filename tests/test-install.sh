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
kit_version=$(tr -d '\r\n ' < VERSION)
awg-client version | grep -q "^awg-vps-kit: $kit_version " || fail "awg-client version: wrong kit version"
awg-client version | grep -Eq '^amneziawg-go: [0-9a-f]{7}$' || fail "awg-client version: no amneziawg-go commit"
ok "awg-client version"

if ./install.sh --no-service --endpoint 203.0.113.10 --wan-if eth0 --bin-dir "$BIN" >/dev/null 2>&1; then
  fail "second install.sh run must refuse to overwrite"
fi
ok "install.sh refuses to overwrite an existing config"

# No live interface in the container: keep real key generation, stub the rest.
mv /usr/local/bin/awg /usr/local/bin/awg.real
cat > /usr/local/bin/awg <<'EOS'
#!/bin/sh
case "$1" in genkey|pubkey|genpsk) exec /usr/local/bin/awg.real "$@" ;; *) exit 0 ;; esac
EOS
chmod 755 /usr/local/bin/awg

awg-client add alice >/dev/null
awg-client add bob >/dev/null
awg-client list | grep -q "^10.79.0.2.*alice" || fail "alice should get 10.79.0.2"
awg-client list | grep -q "^10.79.0.3.*bob" || fail "bob should get 10.79.0.3"
ok "add assigns sequential addresses"

out=$(awg-client show alice)
echo "$out" | grep -q 'Address = 10.79.0.2/32' || fail "show: wrong address"
echo "$out" | grep -q 'Endpoint = 203.0.113.10:443' || fail "show: wrong endpoint"
h1=$(awk '$1=="H1"{print $3; exit}' "$DIR/awg0.conf")
echo "$out" | grep -q "^H1 = $h1\$" || fail "show: H1 differs from server"
[ "$(echo "$out" | head -1)" = "$(printf "%60s" "" | tr " " "#")" ] || fail "show: config is not framed by separator lines"
[ "$(grep -c "^####" "$DIR/clients/alice.conf")" = 0 ] || fail "separator leaked into the client file"
ok "show prints a matching client config"

if awg-client add alice >/dev/null 2>&1; then fail "duplicate add must fail"; fi
if awg-client add 'bad name' >/dev/null 2>&1; then fail "invalid name must fail"; fi
ok "duplicate and invalid names rejected"

awg-client remove alice >/dev/null
if awg-client list | grep -q alice; then fail "alice still listed after remove"; fi
awg-client list | grep -q bob || fail "bob lost after removing alice"
awg-client add carol >/dev/null
awg-client list | grep -q "^10.79.0.2.*carol" || fail "carol should reuse 10.79.0.2"
ok "remove frees the address and keeps other clients"

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

echo "All tests passed"
