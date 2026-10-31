# gentooinstall

A guided installer for Gentoo Linux, in the spirit of Arch's `archinstall`. It asks its questions up front, then follows the [Gentoo AMD64 Handbook](https://wiki.gentoo.org/wiki/Handbook:AMD64) step by step: disk, stage3, Portage, kernel, bootloader, users and an optional desktop: KDE Plasma, GNOME, Xfce, Budgie or Cinnamon, or one of the window managers i3, Sway, Hyprland, Niri, MangoWM, dwm and dwl. Budgie, Hyprland, Niri and MangoWM come from overlays that Gentoo doesn't review. It installs from the official binary package host wherever it can.

It's plain bash and needs nothing beyond what the Gentoo minimal install ISO ships. `SPEC.md` says what it does; `ARCHITECTURE.md` says how the code fits together.

Status: in development. Version 1 targets UEFI x86_64 machines and wipes the whole chosen disk.

## Running it

Boot the [Gentoo minimal install ISO](https://www.gentoo.org/downloads/) in UEFI mode, get online (`nmtui` or `net-setup` for Wi-Fi), then:

```sh
git clone <repository-url> gentooinstall
cd gentooinstall
./gentooinstall
```

Every command is logged to `/tmp/gentooinstall/install.log`, and `/tmp/gentooinstall/replay.sh` collects them as a script you can read top to bottom. Passwords never appear in either. At the end both are copied to `/var/log/gentooinstall/` on the new system.

If a step fails, you can retry it, read the log, open a shell to fix things, skip it (optional steps only), or stop. A stopped install continues with `./gentooinstall --resume`, even after rebooting the ISO; the install state is kept on the new system's disk, so after a reboot clone the installer again and run that.

## Options

| Option | What it does |
|---|---|
| `--config FILE` | Read answers from FILE, plain `key=value` lines (see `SPEC.md`). The file is parsed, never run. |
| `--secrets FILE` | Read passwords from FILE: `luks_passphrase`, `root_password`, `user.<name>.password`, `wifi_psk`. It must be owned by root with mode 600. |
| `--resume` | Continue an install that stopped. With `--config`, an answer can change only until the step that uses it has run. Can't be combined with `--dry-run`. |
| `--dry-run` | Ask the questions, then print every command instead of running it. |
| `--explain` | Before each step, say why it's done and link the Handbook section; show each command as it runs. |
| `--yes` | Don't ask anything; take every answer from `--config` and every password from `--secrets`. Needs `--config`. A failed step stops the run with exit status 1 (resume it with `--resume`) instead of showing the error menu. |
| `--no-tui` | Plain numbered prompts instead of `dialog` menus. Useful on serial consoles. |
| `--log FILE` | Write the log to FILE instead of `/tmp/gentooinstall/install.log`. |
| `--help`, `--version` | |

Exit status: 0 done, 1 failed, 2 bad usage or config, 130 stopped by the user.

## Tests

Tests run on a development machine, never on the ISO, and never as root. Every command that would change a system is replaced by a stub that only records its arguments, and the test mode refuses to run anything else.

```sh
tests/bootstrap.sh   # once: downloads shellcheck and bats-core into .tools/
tests/run.sh         # shellcheck and every bats test
tests/run.sh lib/core.sh tests/core.bats   # just these files
```
