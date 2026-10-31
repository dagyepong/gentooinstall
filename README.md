# gentooinstall

A guided installer for Gentoo Linux, like Arch's `archinstall`. You answer a few questions in a menu, and it installs Gentoo the way the [AMD64 Handbook](https://wiki.gentoo.org/wiki/Handbook:AMD64) does, using prebuilt packages wherever it can.

**It erases the whole disk you pick.**

Status: early. Tested in virtual machines, not yet on real hardware.

## What you need

- A 64-bit PC that boots in UEFI mode, with Secure Boot turned off
- A USB stick with the [Gentoo minimal install ISO](https://www.gentoo.org/downloads/)
- Internet: Ethernet, or Wi-Fi with WPA2

## Install

1. Boot the USB stick in UEFI mode.
2. Connect to the internet. Ethernet works on its own. For Wi-Fi, run `nmtui`.
3. Download and start the installer:

   ```sh
   git clone https://github.com/w0x7y/gentooinstall
   cd gentooinstall
   ./gentooinstall
   ```

4. Go through the menu, then start the install.
5. When it's done, remove the USB stick and reboot. `first-steps.txt` in your home folder says what to do next.

## What you can choose

- OpenRC or systemd
- ext4, xfs or btrfs, with optional disk encryption
- systemd-boot, GRUB or Limine
- A desktop: KDE Plasma, GNOME, Xfce, Cinnamon or Budgie
- Or a window manager: i3, Sway, Hyprland, niri, MangoWM, dwm or dwl
- Or no desktop at all

Budgie, Hyprland, niri and MangoWM come from community overlays that Gentoo doesn't review, and they build from source.

## If something goes wrong

When a step fails, you can retry it, read the log, or open a shell to fix things.

If you stop the install or reboot, run the installer again with `--resume` and it continues where it stopped. After a reboot, connect and download it again first (steps 2 and 3).

Everything it runs is logged in `/tmp/gentooinstall/`, and copied to `/var/log/gentooinstall/` on the new system. Passwords never appear in the logs.

## Options

| Option | What it does |
|---|---|
| `--resume` | Continue a stopped install |
| `--dry-run` | Ask the questions, then only print what it would do |
| `--explain` | Explain each step as it runs |
| `--no-tui` | Plain text prompts instead of menus |

`./gentooinstall --help` lists them all, including unattended installs with `--config`, `--secrets` and `--yes`.

## Development

`SPEC.md` describes what the installer does, and `ARCHITECTURE.md` how the code fits together. Tests never run as root or change your system:

```sh
tests/bootstrap.sh   # once: downloads shellcheck and bats
tests/run.sh         # runs every test
```
