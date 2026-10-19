#!/usr/bin/env bash
# Stage 1: install Arch from the live ISO, then hand over to setup.sh.
#
# All questions are asked up front; after the final confirmation the rest
# runs unattended. Layout: GPT, ESP at /boot (systemd-boot), ext4 root,
# zram + /swapfile. THE CHOSEN DISK IS WIPED.
#
#   ./install.sh                     # interactive
#   ./install.sh --answers FILE      # pre-answer some or all questions
#
# An answers file is a shell snippet that can set any of:
#   DISK HOST_NAME USER_NAME USER_PASSWORD PROFILE MODULES SWAP_SIZE
#   CONFIRM=yes   (skip the final "erase disk?" prompt)
set -euo pipefail

MYRCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MYRCH_ROOT/lib/common.sh"
source "$MYRCH_ROOT/defaults.conf"

LOG=/tmp/myrch-install.log

preflight() {
	[[ $EUID -eq 0 ]] || die "Run as root from the Arch live ISO"
	[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode (systemd-boot needs UEFI)"
	command -v pacstrap &>/dev/null || die "pacstrap not found; run this from the Arch ISO"
	curl -fsI --max-time 10 https://archlinux.org >/dev/null ||
		die "No network. For Wi-Fi: iwctl station wlan0 connect <SSID>"
}

pick_disk() {
	local -a disks labels
	local name size model boot_dev
	# Don't offer the USB stick we booted from.
	boot_dev=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null | sed -E 's/p?[0-9]+$//') || true
	while read -r name size model; do
		[[ $name == "$boot_dev" ]] && continue
		disks+=("$name")
		labels+=("$name  $size  ${model:-}")
	done < <(lsblk -dpnro NAME,SIZE,MODEL,TYPE | awk '$NF == "disk" {NF--; print}' | sed 's/\\x20/ /g')
	((${#disks[@]})) || die "No disks found"
	echo "Disks:"
	local choice
	ask_choice choice "Install to" 1 "${labels[@]}"
	DISK=${choice%% *}
}

pick_modules() {
	local detected gpu m
	echo "Profiles:"
	local -a profiles
	mapfile -t profiles < <(ls "$MYRCH_ROOT/profiles")
	ask_choice PROFILE "Profile" "$(detect_profile)" "${profiles[@]}"
	MODULES="$(profile_modules "$PROFILE" | tr '\n' ' ')"

	detected=$(detect_gpu_modules)
	ask gpu "GPU modules (gpu-intel gpu-amd gpu-nvidia gpu-nouveau gpu-vm)" "${detected:-gpu-vm}"
	MODULES+=" $gpu"

	# Everything that isn't hardware (gpu-*) or part of some profile is optional.
	local profile_mods def
	local -a pkgs
	profile_mods=$(for m in "$MYRCH_ROOT"/profiles/*; do read_list "$m"; done)
	echo "Optional modules:"
	for m in $(available_modules); do
		[[ $m == gpu-* ]] || grep -qx "$m" <<<"$profile_mods" && continue
		def=n
		[[ " ${OPTIONAL_DEFAULT_YES[*]} " == *" $m "* ]] && def=y
		mapfile -t pkgs < <(read_list "$MYRCH_ROOT/modules/$m/packages"; read_list "$MYRCH_ROOT/modules/$m/aur")
		ask_yn "  $m (${pkgs[*]:0:4}...)" "$def" && MODULES+=" $m"
	done
	return 0
}

ask_questions() {
	[[ -n ${DISK-} ]] || pick_disk
	[[ -b $DISK ]] || die "$DISK is not a block device"
	[[ -n ${HOST_NAME-} ]] || ask HOST_NAME "Hostname"
	[[ -n ${USER_NAME-} ]] || ask USER_NAME "Username" "$DEFAULT_USER"
	[[ -n ${USER_PASSWORD-} ]] || ask_password USER_PASSWORD "Password for $USER_NAME (root gets locked; use sudo)"
	[[ -n ${MODULES-} ]] || pick_modules
	[[ -n ${SWAP_SIZE-} ]] || ask SWAP_SIZE "Swap file size (0 for none)" "$SWAP_SIZE_DEFAULT"

	cat <<-EOF

		  Disk:     $DISK  ($(lsblk -dno SIZE,MODEL "$DISK" | xargs))  <-- WILL BE ERASED
		  Hostname: $HOST_NAME
		  User:     $USER_NAME
		  Modules:  $MODULES
		  Swap:     zram + ${SWAP_SIZE} swap file

	EOF
	if [[ ${CONFIRM-} != yes ]]; then
		local reply
		read -rp "Type 'yes' to erase $DISK and install: " reply
		[[ $reply == yes ]] || die "Aborted"
	fi
}

partition() {
	step "Partitioning $DISK"
	umount -R /mnt 2>/dev/null || true
	swapoff -a 2>/dev/null || true
	wipefs -af "$DISK"
	sgdisk -Z "$DISK" >/dev/null
	sgdisk -n "1:0:+$ESP_SIZE" -t 1:ef00 -c 1:ESP \
		-n 2:0:0 -t 2:8304 -c 2:root "$DISK" >/dev/null
	partprobe "$DISK"
	udevadm settle

	local p=''
	[[ $DISK =~ [0-9]$ ]] && p=p # nvme0n1 -> nvme0n1p1
	ESP_PART=${DISK}${p}1
	ROOT_PART=${DISK}${p}2

	mkfs.fat -F 32 -n ESP "$ESP_PART" >/dev/null
	mkfs.ext4 -F -q -L root "$ROOT_PART"
	mount "$ROOT_PART" /mnt
	mount --mkdir -o fmask=0077,dmask=0077 "$ESP_PART" /mnt/boot
}

install_base() {
	local ucode=''
	grep -q GenuineIntel /proc/cpuinfo && ucode=intel-ucode
	grep -q AuthenticAMD /proc/cpuinfo && ucode=amd-ucode

	step "Installing base system"
	configure_pacman /etc/pacman.conf
	timedatectl set-ntp true
	pacstrap -K /mnt base linux linux-firmware $ucode

	genfstab -U /mnt >>/mnt/etc/fstab
	if [[ $SWAP_SIZE != 0 ]]; then
		mkswap --file /mnt/swapfile --size "$SWAP_SIZE" >/dev/null
		echo '/swapfile none swap defaults 0 0' >>/mnt/etc/fstab
	fi
}

configure_system() {
	step "Configuring system"
	local root_uuid
	root_uuid=$(blkid -s UUID -o value "$ROOT_PART")

	arch-chroot /mnt env \
		TIMEZONE="$TIMEZONE" LANG_DEFAULT="$LANG_DEFAULT" KEYMAP="$KEYMAP" \
		LOCALES="$(printf '%s\n' "${LOCALES[@]}")" \
		HOST_NAME="$HOST_NAME" USER_NAME="$USER_NAME" ROOT_UUID="$root_uuid" \
		bash -euo pipefail <<-'EOF'
			ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
			hwclock --systohc

			while IFS= read -r l; do
				sed -i "s/^#\s*${l//./\\.}/$l/" /etc/locale.gen
			done <<<"$LOCALES"
			locale-gen
			echo "LANG=$LANG_DEFAULT" >/etc/locale.conf
			echo "KEYMAP=$KEYMAP" >/etc/vconsole.conf

			echo "$HOST_NAME" >/etc/hostname
			cat >/etc/hosts <<-HOSTS
				127.0.0.1 localhost
				::1       localhost
				127.0.1.1 $HOST_NAME.localdomain $HOST_NAME
			HOSTS

			useradd -m -G wheel "$USER_NAME"
			passwd -l root

			bootctl install
			cat >/boot/loader/loader.conf <<-LOADER
				default arch.conf
				timeout 3
				console-mode max
				editor no
			LOADER
			opts="root=UUID=$ROOT_UUID rw zswap.enabled=0"
			cat >/boot/loader/entries/arch.conf <<-ENTRY
				title   Arch Linux
				linux   /vmlinuz-linux
				initrd  /initramfs-linux.img
				options $opts
			ENTRY
			cat >/boot/loader/entries/arch-fallback.conf <<-ENTRY
				title   Arch Linux (fallback initramfs)
				linux   /vmlinuz-linux
				initrd  /initramfs-linux-fallback.img
				options $opts
			ENTRY
		EOF
	printf '%s:%s\n' "$USER_NAME" "$USER_PASSWORD" | arch-chroot /mnt chpasswd
}

run_setup() {
	local dest=/home/$USER_NAME/$MYRCH_DIR
	step "Copying myrch to $dest"
	mkdir -p "/mnt$(dirname "$dest")"
	cp -a "$MYRCH_ROOT" "/mnt$dest"
	arch-chroot /mnt chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME"
	arch-chroot /mnt "$dest/setup.sh" --user "$USER_NAME" --modules "$MODULES" ||
		warn "setup.sh failed. Boot the new system and re-run: sudo ~/$MYRCH_DIR/setup.sh"
}

main() {
	local answers=''
	while (($#)); do
		case $1 in
		--answers) answers=$2 && shift ;;
		-h | --help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//' && exit ;;
		*) die "Unknown option: $1" ;;
		esac
		shift
	done
	[[ -n $answers ]] && source "$answers"

	preflight
	ask_questions

	# Everything below is unattended.
	exec > >(tee -a "$LOG") 2>&1
	local start=$SECONDS
	partition
	install_base
	configure_system
	run_setup
	cp "$LOG" /mnt/var/log/myrch-install.log

	ok "Installed in $(((SECONDS - start) / 60)) min. Remove the ISO and reboot."
	if [[ ${CONFIRM-} != yes ]] && ask_yn "Reboot now?" y; then
		umount -R /mnt
		reboot
	fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
