#!/usr/bin/env bash
# Test the installer end to end in a QEMU/UEFI VM.
#
#   test/vm.sh install ISO   # fresh disk, boot ISO, run install.sh unattended
#   test/vm.sh boot          # boot the installed disk (user/password: see below)
#   test/vm.sh clean
#
# Needs: qemu-desktop edk2-ovmf libarchive python
# The repo is served to the VM from your working tree, so uncommitted changes
# are tested too. The VM powers off when the install finishes.
#
# HEADLESS=1 runs without a window. The install output is mirrored to
# test/.vm/serial.log; test/.vm/qmp.sock (QMP) and test/.vm/qga.sock
# (guest agent, once the installed system is up) allow scripted checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE=$ROOT/test/.vm
PORT=8738
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd

# Answers used for the test install.
MODULES="base hyprland vm-guest gpu-vm dev"
TEST_USER="test"
TEST_PASSWORD="test"

qemu() {
	local -a display=()
	[[ ${HEADLESS-} == 1 ]] && display=(-display none)
	qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4G \
		-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
		-drive if=pflash,format=raw,file="$STATE/OVMF_VARS.fd" \
		-drive file="$STATE/disk.qcow2",if=virtio \
		-nic user,model=virtio-net-pci \
		-serial file:"$STATE/serial.log" \
		-qmp unix:"$STATE/qmp.sock",server=on,wait=off \
		-chardev socket,path="$STATE/qga.sock",server=on,wait=off,id=qga0 \
		-device virtio-serial -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
		"${display[@]}" "$@"
}

cmd_install() {
	local iso=${1:?usage: test/vm.sh install ISO} label
	mkdir -p "$STATE/www"
	rm -f "$STATE/disk.qcow2"
	qemu-img create -q -f qcow2 "$STATE/disk.qcow2" 30G
	cp "$OVMF_VARS" "$STATE/OVMF_VARS.fd"

	# Boot the ISO's kernel directly so we can add archiso's script= parameter.
	bsdtar -xf "$iso" -C "$STATE" arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img
	label=$(dd if="$iso" bs=1 skip=32808 count=32 status=none | tr -d ' ')

	tar -C "$ROOT/.." --exclude=test/.vm -czf "$STATE/www/myrch.tar.gz" "$(basename "$ROOT")"
	cat >"$STATE/www/answers.conf" <<-EOF
		DISK=/dev/vda
		HOST_NAME=myrch-test
		USER_NAME=$TEST_USER
		USER_PASSWORD=$TEST_PASSWORD
		MODULES="$MODULES"
		SWAP_SIZE=1G
		CONFIRM=yes
	EOF
	cat >"$STATE/www/run.sh" <<-EOF
		#!/bin/bash
		set -e
		exec > >(tee /dev/ttyS0) 2>&1
		cd /root
		curl -fsS http://10.0.2.2:$PORT/myrch.tar.gz | tar xz
		curl -fsS -o answers.conf http://10.0.2.2:$PORT/answers.conf
		[[ "$(basename "$ROOT")" == myrch ]] || mv "$(basename "$ROOT")" myrch
		if ./myrch/install.sh --answers answers.conf; then
			poweroff
		else
			echo "INSTALL FAILED - log: /tmp/myrch-install.log"
		fi
	EOF

	python -m http.server -d "$STATE/www" -b 127.0.0.1 "$PORT" &>/dev/null &
	trap 'kill $!' EXIT

	qemu -kernel "$STATE/arch/boot/x86_64/vmlinuz-linux" \
		-initrd "$STATE/arch/boot/x86_64/initramfs-linux.img" \
		-append "archisobasedir=arch archisolabel=$label script=http://10.0.2.2:$PORT/run.sh" \
		-drive file="$iso",if=virtio,format=raw,readonly=on
}

cmd_boot() {
	[[ -f $STATE/disk.qcow2 ]] || {
		echo "No VM disk; run: test/vm.sh install ISO" >&2
		exit 1
	}
	echo "Log in as $TEST_USER / $TEST_PASSWORD"
	if [[ ${HEADLESS-} == 1 ]]; then
		qemu -device virtio-vga
	else
		qemu -device virtio-vga-gl -display gtk,gl=on
	fi
}

case ${1-} in
install) cmd_install "${@:2}" ;;
boot) cmd_boot ;;
clean) rm -rf "$STATE" ;;
*) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//' && exit 1 ;;
esac
