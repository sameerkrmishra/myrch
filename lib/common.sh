# Shared helpers. Sourced by install.sh and setup.sh.

MYRCH_ROOT="${MYRCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ -t 1 ]]; then
	_c_blue=$'\e[1;34m' _c_yellow=$'\e[1;33m' _c_red=$'\e[1;31m' _c_green=$'\e[1;32m' _c_reset=$'\e[0m'
else
	_c_blue='' _c_yellow='' _c_red='' _c_green='' _c_reset=''
fi

step() { printf '\n%s==> %s%s\n' "$_c_blue" "$*" "$_c_reset"; }
info() { printf '  -> %s\n' "$*"; }
ok() { printf '%s==> %s%s\n' "$_c_green" "$*" "$_c_reset"; }
warn() { printf '%s==> WARNING: %s%s\n' "$_c_yellow" "$*" "$_c_reset" >&2; }
die() {
	printf '%s==> ERROR: %s%s\n' "$_c_red" "$*" "$_c_reset" >&2
	exit 1
}

# Print the entries of a list file, skipping blank lines and # comments.
read_list() {
	[[ -f $1 ]] || return 0
	sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

# All modules that exist in the repo.
available_modules() {
	local d
	for d in "$MYRCH_ROOT"/modules/*/; do
		basename "$d"
	done
}

# Modules listed in a profile file.
profile_modules() {
	read_list "$MYRCH_ROOT/profiles/$1"
}

# has_module NAME — true if NAME is in $MYRCH_MODULES.
has_module() {
	[[ " $MYRCH_MODULES " == *" $1 "* ]]
}

in_chroot() {
	systemd-detect-virt --chroot &>/dev/null
}

# ask VAR "Prompt" [default]
ask() {
	local __var=$1 __prompt=$2 __default=${3-} __reply
	if [[ -n $__default ]]; then
		read -rp "$__prompt [$__default]: " __reply
		__reply=${__reply:-$__default}
	else
		while [[ -z ${__reply-} ]]; do
			read -rp "$__prompt: " __reply
		done
	fi
	printf -v "$__var" '%s' "$__reply"
}

# ask_yn "Prompt" y|n — returns 0 for yes.
ask_yn() {
	local reply hint
	[[ $2 == y ]] && hint="Y/n" || hint="y/N"
	read -rp "$1 [$hint]: " reply
	reply=${reply:-$2}
	[[ ${reply,,} == y* ]]
}

# ask_choice VAR "Prompt" default option...
ask_choice() {
	local __var=$1 __prompt=$2 __default=$3 __reply i
	shift 3
	local -a opts=("$@")
	for i in "${!opts[@]}"; do
		printf '  %d) %s\n' "$((i + 1))" "${opts[i]}"
	done
	while :; do
		read -rp "$__prompt [$__default]: " __reply
		__reply=${__reply:-$__default}
		if [[ $__reply =~ ^[0-9]+$ ]] && ((__reply >= 1 && __reply <= ${#opts[@]})); then
			printf -v "$__var" '%s' "${opts[__reply - 1]}"
			return
		fi
		for i in "${opts[@]}"; do
			[[ $i == "$__reply" ]] && {
				printf -v "$__var" '%s' "$i"
				return
			}
		done
		echo "  Pick a number from the list."
	done
}

# ask_password VAR "Prompt" — asks twice, must match.
ask_password() {
	local __var=$1 __prompt=$2 __a __b
	while :; do
		read -rsp "$__prompt: " __a
		echo
		read -rsp "Confirm: " __b
		echo
		[[ -n $__a && $__a == "$__b" ]] && break
		echo "  Passwords were empty or did not match. Try again."
	done
	printf -v "$__var" '%s' "$__a"
}

# Turn on Color, parallel downloads and multilib in a pacman.conf.
configure_pacman() {
	local conf=${1:-/etc/pacman.conf}
	sed -i \
		-e 's/^#Color$/Color/' \
		-e 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' \
		-e '/^#\[multilib\]$/,/^#Include/ s/^#//' \
		"$conf"
}

# Suggest modules for the GPUs present (lspci). Hybrid laptops get both.
# NVIDIA: Turing and newer (TU/GA/AD/GB chips) get the nvidia-open driver,
# anything older gets nouveau.
detect_gpu_modules() {
	local class vendor device mods=()
	# lspci -mm fields: slot "class" "vendor" "device" ...
	while IFS='"' read -r _ class _ vendor _ device _; do
		[[ $class =~ VGA|3D|Display ]] || continue
		case $vendor in
		Intel*) mods+=(gpu-intel) ;;
		*AMD* | *ATI*) mods+=(gpu-amd) ;;
		NVIDIA*)
			if [[ $device =~ ^(TU|GA|AD|GB|GH)[0-9] ]]; then
				mods+=(gpu-nvidia)
			else
				mods+=(gpu-nouveau)
			fi
			;;
		*) mods+=(gpu-vm) ;; # QXL, virtio, VMware, Bochs...
		esac
	done < <(lspci -mm 2>/dev/null)
	echo "${mods[*]}"
}

detect_profile() {
	if systemd-detect-virt --vm &>/dev/null; then
		echo vm
	elif compgen -G '/sys/class/power_supply/BAT*' >/dev/null; then
		echo laptop
	else
		echo desktop
	fi
}
