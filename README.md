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

1. **install.sh (stage 1):** GPT with a 1G ESP at `/boot` and an ext4 root, `pacstrap`,
   locale/timezone/hostname, user (in `wheel`; root is locked), and
   systemd-boot.
2. **setup.sh (stage 2, in the chroot):** packages from the chosen modules,
   system config files, module hooks, AUR packages via yay, services, and
   dotfiles cloned to `~/git/dotfiles` with `config/*` linked into `~/.config`.

The repo itself is copied to `~/git/myrch` on the new machine. The log ends up in `/var/log/myrch-install.log`.

## Keep a machine in sync

```sh
sudo ./setup.sh                    # re-apply this machine's modules (from /etc/myrch.conf)
sudo ./setup.sh --add gaming       # add a module
sudo ./setup.sh --only-dotfiles    # just pull + relink dotfiles
tools/unmanaged.sh                 # installed packages that aren't in any module
```

To adopt an existing machine: `sudo ./setup.sh --user sameer --profile laptop --add dev,apps`.

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
test/vm.sh boot                                  # log in as test/test
```
