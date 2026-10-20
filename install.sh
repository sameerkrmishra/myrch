#!/usr/bin/env bash
# Stage 1: install Arch from the live ISO with archinstall, then hand over to
# setup.sh.
#
# All questions are asked up front; after the final confirmation the rest
# runs unattended. The answers become an archinstall config, and archinstall
# does the disk, base system, every module's packages and services, the user
# and systemd-boot. Layout: GPT, ESP at /boot, ext4 root, zram + /swapfile.
# THE CHOSEN DISK IS WIPED.
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
WORK=/tmp/myrch

preflight() {
	[[ $EUID -eq 0 ]] || die "Run as root from the Arch live ISO"
	[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode (systemd-boot needs UEFI)"
	command -v pacstrap &>/dev/null || die "pacstrap not found; run this from the Arch ISO"
	curl -fsI --max-time 10 https://archlinux.org >/dev/null ||
		die "No network. For Wi-Fi: iwctl station wlan0 connect <SSID>"
	# The config format below is archinstall 4's; older ISOs ship older ones.
	step "Updating archinstall"
	pacman -Sy --needed --noconfirm archinstall >/dev/null
	info "archinstall $(pacman -Q archinstall | cut -d' ' -f2)"
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

	local m
	for m in $MODULES; do
		[[ -d $MYRCH_ROOT/modules/$m ]] || die "No such module: $m"
	done

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

# What archinstall can't express, run in the new system's chroot after it has
# installed packages and before it writes fstab.
post_commands() {
	local l
	echo 'set -euo pipefail'
	echo 'hwclock --systohc'
	# archinstall enables only the main locale.
	for l in "${LOCALES[@]}"; do
		printf "sed -i 's/^#\\\\s*%s/%s/' /etc/locale.gen\n" "${l//./\\.}" "$l"
	done
	cat <<-EOF
		locale-gen

		cat >/etc/hosts <<'HOSTS'
		127.0.0.1 localhost
		::1       localhost
		127.0.1.1 $HOST_NAME.localdomain $HOST_NAME
		HOSTS

		passwd -l root
	EOF
	if [[ $SWAP_SIZE != 0 ]]; then
		cat <<-EOF
			mkswap --file /swapfile --size $SWAP_SIZE >/dev/null
			echo '/swapfile none swap defaults 0 0' >>/etc/fstab
		EOF
	fi
	cat <<-'EOF'
		# Shorter menu, no kernel-command-line editing.
		sed -i -E '/^#?(timeout|console-mode|editor)\b/d' /boot/loader/loader.conf
		printf 'timeout 3\nconsole-mode max\neditor no\n' >>/boot/loader/loader.conf
	EOF
}

write_config() {
	local -a pkgs services
	local m
	mapfile -t pkgs < <(for m in $MODULES; do read_list "$MYRCH_ROOT/modules/$m/packages"; done | sort -u)
	mapfile -t services < <(for m in $MODULES; do read_list "$MYRCH_ROOT/modules/$m/services"; done)

	mkdir -p "$WORK"
	chmod 700 "$WORK"
	DISK=$DISK DISK_BYTES=$(lsblk -bdno SIZE "$DISK") SECTOR=$(lsblk -bdno LOG-SEC "$DISK") \
		ESP_SIZE_MIB=$ESP_SIZE_MIB HOST_NAME=$HOST_NAME TIMEZONE=$TIMEZONE KEYMAP=$KEYMAP \
		LANG_DEFAULT=$LANG_DEFAULT USER_NAME=$USER_NAME USER_PASSWORD=$USER_PASSWORD \
		PKGS="$(printf '%s\n' "${pkgs[@]}")" SERVICES="$(printf '%s\n' "${services[@]}")" \
		POST="$(post_commands)" WORK=$WORK \
		python3 - <<-'EOF'
			import json, os, uuid
			e = os.environ
			MiB = 1024 * 1024
			sector = {"value": int(e["SECTOR"]), "unit": "B"}

			def mib(n):
			    return {"value": n, "unit": "MiB", "sector_size": sector}

			def part(start, size, fs, mountpoint, flags=(), options=()):
			    return {
			        "obj_id": str(uuid.uuid4()), "status": "create", "type": "primary",
			        "start": mib(start), "size": mib(size), "fs_type": fs,
			        "mountpoint": mountpoint, "mount_options": list(options),
			        "flags": list(flags), "dev_path": None, "btrfs": [],
			    }

			# 1 MiB in front for alignment, 1 MiB at the end for the backup GPT.
			esp = int(e["ESP_SIZE_MIB"])
			root = int(e["DISK_BYTES"]) // MiB - 2 - esp
			lang, _, enc = e["LANG_DEFAULT"].partition(".")
			lines = lambda k: [l for l in e[k].splitlines() if l]

			config = {
			    "disk_config": {
			        "config_type": "manual_partitioning",
			        "device_modifications": [{
			            "device": e["DISK"],
			            "wipe": True,
			            "partitions": [
			                part(1, esp, "fat32", "/boot", ["boot", "esp"], ["fmask=0077", "dmask=0077"]),
			                part(1 + esp, root, "ext4", "/"),
			            ],
			        }],
			    },
			    "bootloader_config": {"bootloader": "Systemd-boot", "uki": False, "removable": False},
			    "kernels": ["linux"],
			    "hostname": e["HOST_NAME"],
			    "timezone": e["TIMEZONE"],
			    "ntp": True,
			    "locale_config": {"sys_lang": lang, "sys_enc": enc or "UTF-8", "kb_layout": e["KEYMAP"]},
			    "mirror_config": {"optional_repositories": ["multilib"]},
			    "pacman_config": {"color": True, "parallel_downloads": 10},
			    "swap": {"enabled": True, "algorithm": "zstd"},
			    "packages": lines("PKGS"),
			    "services": lines("SERVICES"),
			    "custom_commands": [e["POST"]],
			}
			creds = {
			    # sudo comes from wheel via the base module's sudoers.d/10-wheel.
			    "users": [{"username": e["USER_NAME"], "!password": e["USER_PASSWORD"],
			               "sudo": False, "groups": ["wheel"]}],
			}
			for name, data in (("config.json", config), ("creds.json", creds)):
			    path = os.path.join(e["WORK"], name)
			    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
			        json.dump(data, f, indent=2)
		EOF
}

run_archinstall() {
	step "Running archinstall"
	umount -R /mnt 2>/dev/null || true
	swapoff -a 2>/dev/null || true
	timedatectl set-ntp true
	local rc=0
	archinstall --config "$WORK/config.json" --creds "$WORK/creds.json" \
		--silent --skip-version-check || rc=$?
	rm -f "$WORK/creds.json"
	((rc == 0)) || die "archinstall failed; see /var/log/archinstall/install.log"
	findmnt /mnt >/dev/null || die "archinstall finished but /mnt is not mounted"
}

run_setup() {
	local dest=/home/$USER_NAME/$MYRCH_DIR
	step "Copying myrch to $dest"
	mkdir -p "/mnt$(dirname "$dest")"
	cp -a "$MYRCH_ROOT" "/mnt$dest"
	arch-chroot /mnt chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME"
	arch-chroot /mnt "$dest/setup.sh" --user "$USER_NAME" --modules "$MODULES" --no-packages ||
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
	write_config
	run_archinstall
	run_setup
	mkdir -p /mnt/var/log/archinstall
	cp /var/log/archinstall/install.log "$WORK/config.json" /mnt/var/log/archinstall/ 2>/dev/null || true
	cp "$LOG" /mnt/var/log/myrch-install.log

	ok "Installed in $(((SECONDS - start) / 60)) min. Remove the ISO and reboot."
	if [[ ${CONFIRM-} != yes ]] && ask_yn "Reboot now?" y; then
		umount -R /mnt
		reboot
	fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
