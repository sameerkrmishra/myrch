#!/usr/bin/env bash
# Run from the Arch live ISO:
#   curl -L https://raw.githubusercontent.com/sameerkrmishra/myrch/main/bootstrap.sh | bash
set -euo pipefail

REPO=${MYRCH_REPO:-https://github.com/sameerkrmishra/myrch}
DEST=/root/myrch

command -v git &>/dev/null || pacman -Sy --noconfirm git
rm -rf "$DEST"
git clone "$REPO" "$DEST"
# stdin is this script when piped from curl; give install.sh the terminal.
exec "$DEST/install.sh" "$@" </dev/tty
