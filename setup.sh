#!/usr/bin/env bash
# Stage 2: provision a system from the modules in this repo.
#
# Runs as root, either inside the chroot (called by install.sh) or on an
# already-installed machine to bring it in line with the repo. Safe to re-run.
#
#   sudo ./setup.sh                              # use /etc/myrch.conf
#   sudo ./setup.sh --user sameer --profile laptop --add dev,apps
#   sudo ./setup.sh --modules base,hyprland,gpu-intel
#   sudo ./setup.sh --add gaming                 # add a module to this machine
#   sudo ./setup.sh --only-dotfiles
#   sudo ./setup.sh --no-packages ...           # skip pacman packages and services
#                                               # (install.sh: archinstall did them)
set -euo pipefail

MYRCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MYRCH_ROOT/lib/common.sh"
source "$MYRCH_ROOT/defaults.conf"

MYRCH_CONF=/etc/myrch.conf

usage() {
	sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
	echo "Modules: $(available_modules | tr '\n' ' ')"
	exit "${1:-0}"
}

parse_args() {
	local profile='' add=''
	SKIP_AUR=0 ONLY_DOTFILES=0 NO_PACKAGES=0
	while (($#)); do
		case $1 in
		--user) MYRCH_USER=$2 && shift ;;
		--modules) MYRCH_MODULES=${2//,/ } && shift ;;
		--profile) profile=$2 && shift ;;
		--add) add+=" ${2//,/ }" && shift ;;
		--no-aur) SKIP_AUR=1 ;;
		--no-packages) NO_PACKAGES=1 ;;
		--only-dotfiles) ONLY_DOTFILES=1 ;;
		-h | --help) usage ;;
		*) warn "Unknown option: $1" && usage 1 ;;
		esac
		shift
	done
	if [[ -n $profile ]]; then
		[[ -f $MYRCH_ROOT/profiles/$profile ]] || die "No such profile: $profile"
		MYRCH_MODULES="$(profile_modules "$profile" | tr '\n' ' ') $(detect_gpu_modules)"
	fi
	MYRCH_MODULES="${MYRCH_MODULES-} $add"
}

# Dedupe, keep order, and check every module exists.
normalize_modules() {
	local m out=()
	for m in $MYRCH_MODULES; do
		[[ -d $MYRCH_ROOT/modules/$m ]] || die "No such module: $m"
		[[ " ${out[*]} " == *" $m "* ]] || out+=("$m")
	done
	MYRCH_MODULES="${out[*]}"
}

save_config() {
	cat >"$MYRCH_CONF" <<-EOF
		# Written by myrch setup.sh. Edit, or use setup.sh --add / --modules.
		MYRCH_USER="$MYRCH_USER"
		MYRCH_MODULES="$MYRCH_MODULES"
	EOF
}

module_list() { # module_list FILE — concatenated list from every module
	local m
	for m in $MYRCH_MODULES; do
		read_list "$MYRCH_ROOT/modules/$m/$1"
	done
}

install_packages() {
	local -a pkgs
	mapfile -t pkgs < <(module_list packages | sort -u)
	step "Installing ${#pkgs[@]} packages"
	pacman -Syu --needed --noconfirm "${pkgs[@]}"
}

# Copy modules/*/files/ into /. sudoers files must stay 0440.
install_files() {
	local m f src
	step "Installing system config files"
	for m in $MYRCH_MODULES; do
		src=$MYRCH_ROOT/modules/$m/files
		[[ -d $src ]] || continue
		while IFS= read -r f; do
			if [[ $f == etc/sudoers.d/* ]]; then
				install -Dm0440 "$src/$f" "/$f"
			else
				install -Dm0644 "$src/$f" "/$f"
			fi
			info "/$f"
		done < <(cd "$src" && find . -type f -printf '%P\n')
	done
}

run_hooks() {
	local m hook
	for m in $MYRCH_MODULES; do
		hook=$MYRCH_ROOT/modules/$m/setup.sh
		[[ -f $hook ]] || continue
		step "Running $m hook"
		(source "$hook")
	done
}

as_user() {
	sudo -u "$MYRCH_USER" -H -- "$@"
}

install_aur() {
	local -a pkgs
	# Only what's missing: installed ones (e.g. pre-built on a myrch ISO) are
	# left for `yay -Syu`, so a newer AUR version can't start a source build.
	mapfile -t pkgs < <(module_list aur | sort -u | while read -r p; do
		pacman -Q "$p" &>/dev/null || echo "$p"
	done)
	((${#pkgs[@]})) || return 0
	if ((SKIP_AUR)); then
		warn "Skipping AUR packages: ${pkgs[*]}"
		return
	fi

	# makepkg/yay call sudo pacman; allow that without a password while we run.
	local sudoers=/etc/sudoers.d/99-myrch-temp
	echo "$MYRCH_USER ALL=(ALL) NOPASSWD: ALL" >"$sudoers"
	chmod 0440 "$sudoers"
	trap 'rm -f '"$sudoers" EXIT

	if ! command -v yay &>/dev/null; then
		step "Bootstrapping yay"
		local tmp
		tmp=$(as_user mktemp -d)
		as_user git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
		(cd "$tmp/yay-bin" && as_user makepkg -si --noconfirm)
		rm -rf "$tmp"
	fi

	step "Installing ${#pkgs[@]} AUR packages"
	as_user yay -S --needed --noconfirm --answerdiff None --answerclean None \
		--removemake "${pkgs[@]}" ||
		warn "Some AUR packages failed; re-run setup.sh once you've looked at the errors"

	rm -f "$sudoers"
	trap - EXIT
}

enable_services() {
	local -a units user_units
	mapfile -t units < <(module_list services)
	mapfile -t user_units < <(module_list user-services)
	step "Enabling services"
	((${#units[@]})) && systemctl enable "${units[@]}"
	((${#user_units[@]})) && systemctl --global enable "${user_units[@]}"
	return 0
}

# Link each entry of $1 into $2, backing up anything real that's in the way.
link_tree() {
	local src_dir=$1 dest_dir=$2 src dest
	[[ -d $src_dir ]] || return 0
	as_user mkdir -p "$dest_dir"
	for src in "$src_dir"/* "$src_dir"/.[!.]*; do
		[[ -e $src ]] || continue
		dest=$dest_dir/$(basename "$src")
		if [[ -L $dest && $(readlink "$dest") == "$src" ]]; then
			continue
		elif [[ -L $dest ]]; then
			rm "$dest"
		elif [[ -e $dest ]]; then
			as_user mv "$dest" "$dest.myrch-bak-$(date +%Y%m%d%H%M%S)"
			info "Backed up existing $dest"
		fi
		as_user ln -s "$src" "$dest"
		info "$dest -> $src"
	done
}

setup_dotfiles() {
	local dir=$MYRCH_HOME/$DOTFILES_DIR
	step "Dotfiles"
	if [[ -d $dir/.git ]]; then
		as_user git -C "$dir" pull --ff-only ||
			warn "Could not fast-forward $dir; leaving it as is"
	else
		as_user mkdir -p "$(dirname "$dir")"
		as_user git clone "$DOTFILES_REPO" "$dir"
	fi
	# config/* -> ~/.config/*, home/* -> ~/*
	link_tree "$dir/config" "$MYRCH_HOME/.config"
	link_tree "$dir/home" "$MYRCH_HOME"
	as_user xdg-user-dirs-update 2>/dev/null || true
}

main() {
	if [[ -f $MYRCH_CONF ]]; then source "$MYRCH_CONF"; fi
	parse_args "$@"
	[[ $EUID -eq 0 ]] || die "Run as root (sudo $0)"
	MYRCH_USER=${MYRCH_USER:-${SUDO_USER:-}}
	[[ -n $MYRCH_USER && $MYRCH_USER != root ]] || die "No user set; pass --user NAME"
	id "$MYRCH_USER" &>/dev/null || die "User $MYRCH_USER does not exist"
	MYRCH_HOME=$(getent passwd "$MYRCH_USER" | cut -d: -f6)
	export MYRCH_USER MYRCH_HOME

	if ((ONLY_DOTFILES)); then
		setup_dotfiles
		return
	fi

	normalize_modules
	[[ -n $MYRCH_MODULES ]] || die "No modules selected; pass --profile or --modules"
	export MYRCH_MODULES
	ok "User: $MYRCH_USER"
	ok "Modules: $MYRCH_MODULES"
	save_config

	if ((!NO_PACKAGES)); then
		configure_pacman
		install_packages
	fi
	install_files
	run_hooks
	install_aur
	((NO_PACKAGES)) || enable_services
	setup_dotfiles
	ok "Done. Reboot (or log out and back in) to pick up everything."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
