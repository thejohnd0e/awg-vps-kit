#!/bin/bash
# One-line installer: puts the kit in /opt/awg-vps-kit (clones it, or fast-forwards an
# existing clone) and runs install.sh there with the given options. The folder is fixed,
# so the result does not depend on where this is run from. Run as root.
#
#   curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/bootstrap.sh \
#     | bash -s -- [install.sh options]
set -euo pipefail

REPO=https://github.com/thejohnd0e/awg-vps-kit.git
DIR=/opt/awg-vps-kit
die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
command -v apt-get >/dev/null || die "only Debian/Ubuntu (apt) is supported"
export DEBIAN_FRONTEND=noninteractive

if ! command -v git >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq git ca-certificates >/dev/null
fi

if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull --ff-only -q || die "cannot fast-forward $DIR (local changes?)"
elif [ -e "$DIR" ]; then
  die "$DIR exists but is not a clone of the kit; move it away and run this again"
else
  git clone -q "$REPO" "$DIR"
fi

cd "$DIR"
exec ./install.sh "$@"
