#!/bin/bash
# bump-upstream: show or move the reviewed upstream commits in upstream.lock.
# Maintainer tool for a development machine; it is not installed on servers.
#
#   tools/bump-upstream.sh                       compare the lock with upstream HEAD (exit 10 if it moved)
#   tools/bump-upstream.sh --apply               pin the current upstream HEAD of both components
#   tools/bump-upstream.sh --apply --go SHA      pin SHA for amneziawg-go (and HEAD for -tools)
#   tools/bump-upstream.sh --apply --go SHA --tools SHA
#   tools/bump-upstream.sh --apply --go keep     leave a component as it is ("keep")
#
# It only edits upstream.lock. Review the changes behind the compare links first, then build
# and run the test suites before committing (steps are printed at the end).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOCK=$ROOT/upstream.lock
die() { echo "error: $*" >&2; exit 1; }

APPLY=0; GO=; TOOLS=
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --go) [ $# -ge 2 ] || die "--go needs a commit or 'keep'"; GO=$2; shift 2 ;;
    --tools) [ $# -ge 2 ] || die "--tools needs a commit or 'keep'"; TOOLS=$2; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
{ [ -z "$GO$TOOLS" ] || [ "$APPLY" = 1 ]; } || die "--go/--tools only make sense with --apply"
[ -f "$LOCK" ] || die "$LOCK not found"
command -v git >/dev/null || die "git is required"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

url_of() { echo "https://github.com/amnezia-vpn/$1"; }
locked() { awk -F= -v k="$1" '$1 == k && length($2) == 40 && $2 ~ /^[0-9a-f]+$/ { print $2; exit }' "$LOCK"; }
head_of() { git ls-remote "$(url_of "$1")" HEAD | cut -f1; }
describe() {  # describe <name> <sha>: "abc1234 2026-08-28 author: subject"; fails if the commit cannot be fetched
  local d=$TMP/$1.$2
  git init -q "$d"
  git -C "$d" fetch -q --depth 1 "$(url_of "$1")" "$2" 2>/dev/null || return 1
  git -C "$d" log -1 --format='%h %ad %an: %s' --date=short FETCH_HEAD
}

moved=0
declare -A NEW
for name in amneziawg-go amneziawg-tools; do
  cur=$(locked "$name"); [ -n "$cur" ] || die "$LOCK has no valid $name commit"
  head=$(head_of "$name"); [ -n "$head" ] || die "cannot reach $(url_of "$name")"
  want=$head
  if [ "$APPLY" = 1 ]; then
    case "$name" in amneziawg-go) req=$GO ;; *) req=$TOOLS ;; esac
    case "$req" in
      '') ;;
      keep) want=$cur ;;
      *) [[ "$req" =~ ^[0-9a-f]{40}$ ]] || die "$name: '$req' is not a full 40-character commit id"; want=$req ;;
    esac
  fi
  echo "== $name"
  echo "   locked:   $cur  $(describe "$name" "$cur" || echo '(cannot be fetched!)')"
  if [ "$head" = "$cur" ]; then echo "   upstream: same commit"; else
    echo "   upstream: $head  $(describe "$name" "$head" || echo '(cannot be fetched)')"
    echo "   review:   $(url_of "$name")/compare/${cur:0:12}...${head:0:12}"
    moved=1
  fi
  NEW[$name]=$want
  if [ "$APPLY" = 1 ] && [ "$want" != "$cur" ]; then
    info=$(describe "$name" "$want") || die "$name: commit $want does not exist upstream"
    # an annotated tag id is accepted by fetch but is not what a checkout of HEAD reports: pin the commit
    real=$(git -C "$TMP/$name.$want" rev-parse 'FETCH_HEAD^{commit}')
    [ "$real" = "$want" ] || die "$name: $want is not a commit id (a tag object?); the commit behind it is $real"
    echo "   -> pinning $want  $info"
  fi
done

if [ "$APPLY" = 0 ]; then
  [ "$moved" = 0 ] || { echo; echo "Upstream moved. Review the links, then: tools/bump-upstream.sh --apply"; exit 10; }
  exit 0
fi

awk -v go="${NEW[amneziawg-go]}" -v tools="${NEW[amneziawg-tools]}" '
  /^amneziawg-go=/    { print "amneziawg-go=" go; next }
  /^amneziawg-tools=/ { print "amneziawg-tools=" tools; next }
  { print }' "$LOCK" > "$LOCK.new" && mv -f "$LOCK.new" "$LOCK"
echo
echo "upstream.lock updated. Before committing it:"
echo "  1. bash install.sh --build-only /tmp/awg-bin        (builds the new pins)"
echo "  2. AWG_TEST_ALLOW_DESTRUCTIVE=1 bash tests/test-reliability.sh /tmp/awg-bin all   (in a container or VM)"
echo "  3. a live check on a test server (docs/testing/reliability-vm.md), then update STATUS.md and commit"
