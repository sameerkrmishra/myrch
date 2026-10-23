# myrch

Zero to a fully set up Arch + Hyprland machine: answer a few questions, then
walk away.

## Install a new machine

Boot the Arch ISO (UEFI), get online (`iwctl station wlan0 connect <SSID>` for
Wi-Fi), then:

```sh
curl -L https://raw.githubusercontent.com/sameerkrmishra/myrch/main/bootstrap.sh | bash
```

You're asked for: disk, hostname, user, password, profile, GPU, optional
modules and swap size. After you type `yes`, it runs unattended:

1. **install.sh (stage 1):** turns your answers into an
   [archinstall](https://github.com/archlinux/archinstall) config and runs
   `archinstall --silent` (updating archinstall from the repos first). That
   covers GPT with a 1G ESP at `/boot` and an ext4 root, the base system,
   every package and service from the chosen modules (multilib enabled),
   locale/timezone/hostname, the user (in `wheel`), systemd-boot, and zram.
   Its `custom_commands` then add what archinstall has no option for: the
   extra locales, `/swapfile`, a locked root account, loader tweaks and a
   fallback boot entry.
2. **setup.sh --no-packages (stage 2, in the chroot):** system config files,
   module hooks, AUR packages via yay, and dotfiles cloned to `~/git/dotfiles`
   with `config/*` linked into `~/.config`.

The repo itself is copied to `~/git/myrch` on the new machine. Logs end up in
`/var/log/myrch-install.log` and `/var/log/archinstall/` (with the generated
`config.json`; the credentials file is deleted).

## Faster installs from a myrch ISO

`tools/build-iso.sh` builds a live ISO that also carries every package the
modules need (a snapshot of the official repos plus pre-built AUR packages)
and the dotfiles. Installing from it downloads next to nothing; the new
system starts at the snapshot's versions, so run `sudo pacman -Syu` after
the first boot.

```sh
tools/build-iso.sh                                  # all modules -> out/myrch-<date>-x86_64.iso
tools/build-iso.sh --modules "base hyprland laptop bluetooth dev"
sudo dd if=out/myrch-*.iso of=/dev/sdX bs=4M oflag=direct status=progress
```

Boot it (UEFI): the default **Install myrch** entry starts the installer
(same questions as above). **myrch live system** boots to a shell instead;
run `/root/myrch/install.sh` from there.

Packages come from this machine's pacman cache when it has the exact file,
otherwise from a mirror; downloads are kept in `~/.cache/myrch-iso` for the
next build. It runs natively as root on Arch (or a derivative such as
EndeavourOS) with `archiso` installed, and in a privileged `archlinux`
container (docker or podman) anywhere else. Anything missing from the
snapshot at install time is fetched from the [Arch Linux
Archive](https://archive.archlinux.org) for the snapshot's date, so versions
always match.

## Keep a machine in sync

```sh
sudo ./setup.sh                    # re-apply this machine's modules (from /etc/myrch.conf)
sudo ./setup.sh --add gaming       # add a module
sudo ./setup.sh --only-dotfiles    # just pull + relink dotfiles
tools/unmanaged.sh                 # installed packages that aren't in any module
```

To adopt an existing machine: `sudo ./setup.sh --user sameer --profile laptop --add dev,apps`.

On an existing machine `setup.sh` does everything itself, packages and
services included.

## Layout

```
defaults.conf          shared settings (timezone, locales, dotfiles repo, ...)
profiles/<name>        machine kinds -> list of modules
modules/<name>/
  packages             pacman packages / groups, one per line, # comments
  aur                  AUR packages
  services             system units to enable
  user-services        user units to enable globally
  files/               copied into / (e.g. files/etc/...)
  setup.sh             hook, sourced as root after packages are installed
```

Hooks get `MYRCH_USER`, `MYRCH_HOME`, `MYRCH_MODULES` and the helpers in
`lib/common.sh` (`has_module`, `die`, ...).

GPU modules are picked from `lspci`: `gpu-intel`, `gpu-amd`, `gpu-nvidia`
(nvidia-open, Turing and newer), `gpu-nouveau` (older NVIDIA), `gpu-vm`.

Swap: zram (half of RAM, max 8G, priority 100) plus `/swapfile` as overflow.

## Dotfiles convention

`config/<x>` is linked to `~/.config/<x>` and `home/<x>` to `~/<x>`, for files
like `.zshrc` and `.gitconfig`. Anything already there that isn't the right
link is moved to `<name>.myrch-bak-<timestamp>`.

## Testing in a VM

```sh
sudo pacman -S --needed qemu-desktop edk2-ovmf
test/vm.sh install ~/Downloads/archlinux-*.iso   # unattended install of your working tree
test/vm.sh install out/myrch-*.iso               # same, from a myrch ISO's snapshot
test/vm.sh boot                                  # log in as test/test
```
