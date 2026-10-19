#!/usr/bin/env bash
# Compare what's installed with what the repo says.
#
#   tools/unmanaged.sh          # vs. this machine's modules (/etc/myrch.conf)
#   tools/unmanaged.sh --all    # vs. every module in the repo
#
# "Unmanaged" packages are explicitly installed but not in any module: either
# add them to a module or `pacman -Rns` them.
set -euo pipefail

MYRCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MYRCH_ROOT/lib/common.sh"

if [[ ${1-} == --all ]]; then
	MYRCH_MODULES=$(available_modules | tr '\n' ' ')
else
	[[ -f /etc/myrch.conf ]] || die "No /etc/myrch.conf; use --all"
	source /etc/myrch.conf
fi

# Package lists may contain groups (e.g. nerd-fonts); expand them.
wanted() {
	local m p
	for m in $MYRCH_MODULES; do
		for p in $(read_list "$MYRCH_ROOT/modules/$m/packages") $(read_list "$MYRCH_ROOT/modules/$m/aur"); do
			pacman -Sgq "$p" 2>/dev/null || echo "$p"
		done
	done | sort -u
}

# The packages pacstrap installs, which no module lists.
base_pkgs="base linux linux-firmware intel-ucode amd-ucode"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
wanted >"$tmp/wanted"
pacman -Qqe | sort >"$tmp/explicit"
pacman -Qq | sort >"$tmp/installed"

echo "== Explicitly installed, not in any module ($(echo "$MYRCH_MODULES" | wc -w) modules checked):"
comm -23 "$tmp/explicit" "$tmp/wanted" | grep -vxF -f <(tr ' ' '\n' <<<"$base_pkgs") | column -c "${COLUMNS:-100}"
echo
echo "== In a module, not installed:"
comm -13 "$tmp/installed" "$tmp/wanted" | column -c "${COLUMNS:-100}"
