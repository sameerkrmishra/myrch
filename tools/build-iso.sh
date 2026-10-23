#!/usr/bin/env bash
# Build a myrch live ISO that carries a snapshot of every package the chosen
# modules need, so install.sh can install without downloading them. The
# installed system starts at the snapshot's versions; run pacman -Syu after
# the first boot to catch up.
#
#   tools/build-iso.sh                    # all modules
#   tools/build-iso.sh --modules "base hyprland laptop bluetooth dev"
#   tools/build-iso.sh --no-aur           # don't pre-build AUR packages
#   tools/build-iso.sh --out DIR          # where the ISO goes (default: ./out)
#
# Packages are taken from this machine's pacman cache when it has the exact
# file, otherwise downloaded. Runs natively as root on Arch (or a derivative)
# with archiso installed; anywhere else it runs itself in a privileged
# archlinux container (docker or podman). Downloads are kept in
# ~/.cache/myrch-iso for next time.
set -euo pipefail

MYRCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MYRCH_ROOT/lib/common.sh"
source "$MYRCH_ROOT/defaults.conf"

# Base system archinstall installs, plus what the gaming hook adds.
EXTRA_PKGS=(base sudo linux-firmware mkinitcpio linux efibootmgr zram-generator intel-ucode amd-ucode)
GAMING_HOOK_PKGS=(lib32-vulkan-intel lib32-vulkan-radeon lib32-nvidia-utils lib32-vulkan-nouveau)
HOST_CACHE=/var/cache/pacman/pkg

usage() {
	sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
	exit "${1:-0}"
}

parse_args() {
	MODULES='' NO_AUR=0 INSIDE=0
	OUT=$PWD/out
	while (($#)); do
		case $1 in
		--modules) MODULES=${2//,/ } && shift ;;
		--no-aur) NO_AUR=1 ;;
		--out) OUT=$(realpath -m "$2") && shift ;;
		--inside) INSIDE=1 ;; # internal: we are the container
		-h | --help) usage ;;
		*) warn "Unknown option: $1" && usage 1 ;;
		esac
		shift
	done
	[[ -n $MODULES ]] || MODULES=$(available_modules | tr '\n' ' ')
	local m
	for m in $MODULES; do
		[[ -d $MYRCH_ROOT/modules/$m ]] || die "No such module: $m"
	done
}

# --- Host side: run natively or hand over to a container --------------------

run_in_container() {
	local engine cache=${XDG_CACHE_HOME:-$HOME/.cache}/myrch-iso
	engine=$(command -v podman || command -v docker) ||
		die "Need root on Arch with archiso, or docker/podman, to build the ISO"
	mkdir -p "$OUT" "$cache"
	local -a args=(--rm --privileged
		-v "$MYRCH_ROOT:/myrch:ro" -v "$OUT:/out" -v "$cache:/cache"
		-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)")
	# On Arch, reuse what this machine has already downloaded.
	[[ -d $HOST_CACHE ]] && args+=(-v "$HOST_CACHE:/hostcache:ro")
	local -a pass=(--out /out)
	[[ -n $MODULES ]] && pass+=(--modules "$MODULES")
	((NO_AUR)) && pass+=(--no-aur)
	step "Building in a container ($(basename "$engine"))"
	"$engine" run "${args[@]}" docker.io/library/archlinux:latest \
		/myrch/tools/build-iso.sh --inside "${pass[@]}"
}

# --- Build (as root, on Arch) ------------------------------------------------

prepare_container() {
	step "Preparing the container"
	pacman-key --init >/dev/null
	pacman-key --populate archlinux >/dev/null
	sed -i '/^#\[multilib\]$/,/^#Include/ s/^#//' /etc/pacman.conf
	pacman -Syu --needed --noconfirm archiso git >/dev/null
	CACHE=/cache
	[[ -d /hostcache ]] && HOST_CACHE=/hostcache || HOST_CACHE=''
}

# A pacman.conf whose repos come from $1 (a mirrorlist file).
write_pacman_conf() {
	local r
	printf '[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\nLocalFileSigLevel = Optional\nParallelDownloads = 10\n'
	for r in core extra multilib; do
		printf '\n[%s]\nInclude = %s\n' "$r" "$1"
	done
}

# take DIR FILE DEST: copy a package (and its signature, if DIR has it).
take() {
	cp --reflink=auto "$1/$2" "$3/"
	[[ -f $1/$2.sig ]] && cp "$1/$2.sig" "$3/"
	return 0
}

snapshot_repos() {
	local -a pkgs m
	mapfile -t pkgs < <(
		printf '%s\n' "${EXTRA_PKGS[@]}"
		for m in $MODULES; do read_list "$MYRCH_ROOT/modules/$m/packages"; done
		has_module gaming && printf '%s\n' "${GAMING_HOOK_PKGS[@]}"
	)
	SNAP=$WORK/snapshot
	mkdir -p "$WORK/db" "$WORK/none" "$CACHE"
	write_pacman_conf /etc/pacman.d/mirrorlist >"$WORK/pacman.conf"
	PAC=(pacman --config "$WORK/pacman.conf" --dbpath "$WORK/db" --noconfirm)

	step "Syncing package databases"
	"${PAC[@]}" -Sy >/dev/null
	SNAPSHOT_DATE=$(date -u +%Y/%m/%d)
	local r
	for r in core extra multilib; do
		mkdir -p "$SNAP/$r/os/x86_64"
		cp "$WORK/db/sync/$r.db" "$SNAP/$r/os/x86_64/$r.db"
	done

	# Everything the modules need, dependencies included (the db is empty).
	local -a entries
	mapfile -t entries < <("${PAC[@]}" -Sp --cachedir "$WORK/none" --print-format '%r %n %f %l' "${pkgs[@]}")
	step "Collecting ${#entries[@]} packages"
	collect "${entries[@]}"
}

# The AUR packages' dependencies from the official repos, which the modules'
# packages may not have pulled in already.
snapshot_aur_deps() {
	local db=$SNAP/myrch-aur/os/x86_64/myrch-aur.db
	[[ -f $db ]] || return 0
	cp -L "$db" "$WORK/db/sync/myrch-aur.db"
	cp "$WORK/pacman.conf" "$WORK/pacman-aur.conf"
	printf '\n[myrch-aur]\nSigLevel = Optional TrustAll\nServer = file://%s\n' "${db%/*}" >>"$WORK/pacman-aur.conf"
	local -a names entries
	mapfile -t names < <(tar -tzf "$db" | sed -n 's|^\([^/]*\)-[^-]*-[^-]*/$|\1|p')
	mapfile -t entries < <(pacman --config "$WORK/pacman-aur.conf" --dbpath "$WORK/db" --noconfirm \
		-Sp --cachedir "$WORK/none" --print-format '%r %n %f %l' "${names[@]}" | awk '$1 != "myrch-aur"')
	local e r n f u
	local -a new=()
	for e in "${entries[@]}"; do
		read -r r n f u <<<"$e"
		[[ -f $SNAP/$r/os/x86_64/$f ]] || new+=("$e")
	done
	((${#new[@]})) || return 0
	step "Collecting ${#new[@]} more packages for the AUR packages"
	collect "${new[@]}"
}

# collect ENTRY...: put these packages ("repo name file url") and their
# signatures into the snapshot, from local caches when possible.
collect() {
	local e r n f u d have=0
	local -a missing=()
	for e; do
		read -r r n f u <<<"$e"
		SNAP_FILES+=("$f")
		if [[ -n $HOST_CACHE && -f $HOST_CACHE/$f ]]; then
			take "$HOST_CACHE" "$f" "$SNAP/$r/os/x86_64"
			((++have))
		elif [[ -f $CACHE/$f ]]; then
			take "$CACHE" "$f" "$SNAP/$r/os/x86_64"
			((++have))
		else
			missing+=("$e")
		fi
	done
	info "$have from local caches, ${#missing[@]} to download"

	if ((${#missing[@]})); then
		# -dd: just these files; pacman -Sw would also re-fetch every dependency
		# that isn't in its first cache dir.
		local try
		for try in 1 2 3; do
			"${PAC[@]}" -Swdd --cachedir "$CACHE" \
				$(printf '%s\n' "${missing[@]}" | awk '{print $1 "/" $2}') >/dev/null && break
			((try < 3)) || die "Downloads failed"
			warn "Some downloads failed; retrying"
			sleep 5
		done
		for e in "${missing[@]}"; do
			read -r r n f u <<<"$e"
			take "$CACHE" "$f" "$SNAP/$r/os/x86_64"
		done
	fi

	# pacman fetches each package's detached signature from the same server,
	# so the snapshot needs them too. Caches don't always have them.
	: >"$WORK/sigs"
	for e; do
		read -r r n f u <<<"$e"
		d=$SNAP/$r/os/x86_64
		[[ -f $d/$f.sig ]] || printf 'url = "%s.sig"\noutput = "%s/%s.sig"\n' "$u" "$d" "$f" >>"$WORK/sigs"
	done
	if [[ -s $WORK/sigs ]]; then
		info "Fetching $(($(wc -l <"$WORK/sigs") / 2)) signatures"
		curl -fsS --parallel --parallel-max 10 --retry 3 -K "$WORK/sigs" || die "Could not fetch signatures"
	fi

	# Check every file against its database checksum (pacman checks the
	# signatures again at install time).
	step "Verifying packages"
	for r in core extra multilib; do
		awk 'NR == FNR {have[$0]; next}
			/^%FILENAME%$/ {getline; f = $0}
			/^%SHA256SUM%$/ {getline; if (f in have) print $0 "  " f}' \
			<(ls "$SNAP/$r/os/x86_64") <(tar -xOf "$WORK/db/sync/$r.db" --wildcards '*/desc') |
			(cd "$SNAP/$r/os/x86_64" && sha256sum --quiet -c -) || die "Checksum mismatch in $r"
	done
}

# Drop downloads no longer in the snapshot so the cache doesn't grow forever.
prune_cache() {
	local -A keep=()
	local f
	for f in "${SNAP_FILES[@]}"; do keep[$f]=1 keep[$f.sig]=1; done
	for f in "$CACHE"/*.pkg.tar.*; do
		[[ -e $f && -z ${keep[$(basename "$f")]-} ]] && rm -f "$f"
	done
	return 0
}

build_aur() {
	local -a aur m
	mapfile -t aur < <(for m in $MODULES; do read_list "$MYRCH_ROOT/modules/$m/aur"; done | sort -u)
	local root=$WORK/aurroot dest=$SNAP/myrch-aur/os/x86_64
	step "Building ${#aur[@]} AUR packages against the snapshot"

	# A throwaway build root whose repos are the snapshot, falling back to the
	# live mirrors for build-only dependencies.
	printf 'Server = file://%s/$repo/os/$arch\nInclude = /etc/pacman.d/mirrorlist\n' "$SNAP" >"$WORK/aur-mirrors"
	write_pacman_conf "$WORK/aur-mirrors" >"$WORK/aur-pacman.conf"
	mkdir -p "$root"
	pacstrap -C "$WORK/aur-pacman.conf" -K "$root" base base-devel git sudo >/dev/null
	mkdir -p "$root/snapshot"
	mount --bind -o ro "$SNAP" "$root/snapshot"
	AUR_MNT=$root/snapshot
	printf 'Server = file:///snapshot/$repo/os/$arch\nInclude = /etc/pacman.d/mirrorlist\n' >"$root/etc/pacman.d/myrch"
	write_pacman_conf /etc/pacman.d/myrch >"$root/etc/pacman.conf"
	cp /etc/pacman.d/mirrorlist "$root/etc/pacman.d/mirrorlist"
	sed -i 's/^\(OPTIONS=.*[ (]\)debug/\1!debug/' "$root/etc/makepkg.conf"
	# Built packages go to their own folder: some PKGBUILDs (e.g.
	# ungoogled-chromium-widevine-bin) download other packages as sources.
	echo 'PKGDEST=/home/builder/pkgs' >>"$root/etc/makepkg.conf"

	arch-chroot "$root" bash -euo pipefail -s -- "${aur[@]}" <<-'EOF'
		useradd -m builder
		install -d -o builder -g builder /home/builder/pkgs
		echo 'builder ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/builder
		su builder -c 'cd && mkdir build && git clone -q --depth 1 https://aur.archlinux.org/yay-bin.git &&
			cd yay-bin && makepkg -si --noconfirm >/dev/null'
		for p; do
			su builder -c "yay -S --noconfirm --answerdiff None --answerclean None \
				--builddir ~/build $p >/dev/null" || echo "==> WARNING: AUR package $p failed to build"
		done
	EOF

	mkdir -p "$dest"
	find "$root/home/builder/pkgs" -name '*.pkg.tar.zst' ! -name '*-debug-*' -exec cp {} "$dest/" \;
	local -a built=("$dest"/*.pkg.tar.zst)
	if [[ -e ${built[0]} ]]; then
		repo-add -q "$dest/myrch-aur.db.tar.gz" "${built[@]}"
		info "Built: $(printf '%s\n' "${built[@]##*/}" | sed 's/-[^-]*-[^-]*-[^-]*$//' | tr '\n' ' ')"
	else
		warn "No AUR packages were built"
		rm -rf "$SNAP/myrch-aur"
	fi
	umount "$AUR_MNT"
	AUR_MNT=''
	rm -rf "$root"
}

# A default boot entry that starts install.sh on tty1; the plain live system
# stays as the next one. UEFI (systemd-boot) only, like install.sh.
add_install_entry() {
	local entries=$1/efiboot/loader/entries
	sed -e 's/^title .*/title    Install myrch (%ARCH%, UEFI)/' -e 's/^sort-key .*/sort-key 00/' \
		-e 's/^options .*/& myrch=install/' "$entries/01-archiso-linux.conf" >"$entries/00-myrch-install.conf"
	sed -i 's/^title .*/title    myrch live system (%ARCH%, UEFI)/' "$entries/01-archiso-linux.conf"
	sed -i 's/^default .*/default 00-myrch-install.conf/' "$1/efiboot/loader/loader.conf"
	# .zlogin is zsh, root's login shell on the ISO.
	cat >>"$1/airootfs/root/.zlogin" <<-'EOF'

		# myrch: the "Install myrch" boot entry runs the installer, once.
		if [[ $(tty) == /dev/tty1 && " $(</proc/cmdline) " == *" myrch=install "* && ! -e /tmp/myrch-started ]]; then
		    touch /tmp/myrch-started
		    /root/myrch/install.sh || print "\nThe installer stopped. Run /root/myrch/install.sh to start it again."
		fi
	EOF
}

build_iso() {
	local profile=$WORK/profile version
	version=$(date -u +%Y.%m.%d)
	step "Building the live ISO"
	cp -r /usr/share/archiso/configs/releng "$profile"
	sed -i -e 's/^iso_name=.*/iso_name="myrch"/' \
		-e 's/^iso_label=.*/iso_label="MYRCH_$(date +%Y%m)"/' \
		-e 's/^iso_application=.*/iso_application="myrch installer"/' \
		-e "s/^airootfs_image_tool_options=.*/airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15' '-b' '1M')/" \
		"$profile/profiledef.sh"
	# zstd instead of releng's xz: a slightly bigger image, but it compresses
	# many times faster (xz took two hours on an old laptop) and boots faster.
	add_install_entry "$profile"

	# The repo (and dotfiles) in /root, so the ISO needs no network to start.
	mkdir -p "$profile/airootfs/root/myrch"
	tar -C "$MYRCH_ROOT" --exclude=./test/.vm --exclude=./out -c . | tar -C "$profile/airootfs/root/myrch" -x
	# mkarchiso copies airootfs without file modes; put the executable bits back.
	(cd "$MYRCH_ROOT" && find . \( -path ./.git -o -path ./out -o -path ./test/.vm \) -prune -o \
		-type f -perm -u+x -printf 'file_permissions+=(["/root/myrch/%P"]="0:0:755")\n') \
		>>"$profile/profiledef.sh"
	git clone -q "$DOTFILES_REPO" "$profile/airootfs/root/dotfiles" ||
		warn "Could not clone $DOTFILES_REPO; the installer will clone it instead"
	printf 'SNAPSHOT_DATE=%s\nSNAPSHOT_MODULES="%s"\n' "$SNAPSHOT_DATE" "$MODULES" >"$SNAP/info"

	mkarchiso -r -w "$WORK/archiso" -o "$WORK/iso" "$profile" >/dev/null
	local base
	base=$(ls "$WORK"/iso/*.iso)

	# Add the snapshot next to the live system rather than inside its squashfs:
	# no time spent recompressing packages, and copytoram stays small.
	ISO=$OUT/myrch-$version-x86_64.iso
	step "Adding the package snapshot to the ISO"
	rm -f "$ISO"
	xorriso -indev "$base" -outdev "$ISO" -map "$SNAP" /myrch/repo -boot_image any replay \
		2>"$WORK/xorriso.log" || { cat "$WORK/xorriso.log"; die "xorriso failed"; }
	rm -f "$base"
}

# Undo mounts and, in a container, give files back to the calling user.
cleanup() {
	[[ -n ${AUR_MNT-} ]] && umount "$AUR_MNT" 2>/dev/null
	[[ -n ${HOST_UID-} ]] && chown -R "$HOST_UID:$HOST_GID" "$OUT" "$CACHE" 2>/dev/null
	return 0
}

main() {
	parse_args "$@"
	# Natively on Arch or a derivative (EndeavourOS, ...) with archiso and root.
	if ((!INSIDE)) && ! { [[ $EUID -eq 0 ]] && command -v pacman mkarchiso &>/dev/null; }; then
		run_in_container
		return
	fi
	[[ $EUID -eq 0 ]] || die "Run as root"
	MYRCH_MODULES=$MODULES # for has_module
	CACHE=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)/.cache/myrch-iso
	trap cleanup EXIT
	((INSIDE)) && prepare_container
	mkdir -p "$OUT"
	WORK=$OUT/.work
	rm -rf "$WORK"
	mkdir -p "$WORK"
	local start=$SECONDS

	SNAP_FILES=()
	snapshot_repos
	if ((!NO_AUR)); then
		build_aur
		snapshot_aur_deps
	fi
	prune_cache
	build_iso
	rm -rf "$WORK"
	ok "Built $ISO ($(du -h "$ISO" | cut -f1)) in $(((SECONDS - start) / 60)) min"
	info "Write it to a USB drive: sudo dd if=$ISO of=/dev/sdX bs=4M oflag=direct status=progress"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
