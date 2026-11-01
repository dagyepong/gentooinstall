# Architecture

How the installer is put together. `SPEC.md` says what it does. This file defines the interfaces every part codes against. If code and this file disagree, fix one of them in the same change.

## Layout and ownership

Each file has one owner part. A part edits only its own files. If it needs something from another part's file, it says so in its report instead of editing.

| File | Part | Spec sections |
|---|---|---|
| `gentooinstall` (entry point) | A core | 1 (options), flow |
| `lib/core.sh` | A core | logging, run helpers, file writers, Portage and service helpers |
| `lib/ui.sh` | A core | dialog and plain-text widgets, install progress output |
| `lib/config.sh` | A core | config schema, load and save, secrets, validators, combination rules |
| `lib/state.sh` | A core | step registry, runner, error menu, state file, resume |
| `tests/run.sh`, `tests/helpers.bash`, `tests/stubs/*`, `tests/bootstrap.sh`, `tests/fixtures/emerge/*` | A core | test tooling |
| `lib/hw.sh`, `lib/preflight.sh` | B preflight | 1, 2 |
| `lib/questions.sh` | C questions | 3, 4 |
| `lib/steps/disk.sh`, `lib/steps/stage3.sh` | D disk | 5, 6, resume mounting |
| `lib/steps/portage.sh`, `lib/steps/preview.sh`, `lib/steps/world.sh` | E portage | 8, 9, 10 |
| `lib/steps/locale.sh`, `lib/steps/kernel.sh`, `lib/steps/system.sh`, `lib/steps/bootloader.sh` | F boot | 11, 12, 13, 16 |
| `lib/steps/network.sh`, `lib/steps/tools.sh`, `lib/steps/users.sh` | G system | 14, 15, 17 |
| `lib/steps/desktop.sh`, `lib/steps/graphics.sh`, `lib/steps/hardware.sh`, `lib/steps/finish.sh` | H desktop | 18, 19, 20, 21, 22 |

Tests for a file live in `tests/<name>.bats` (for example `tests/disk.bats`, and `tests/entry.bats` for the entry point) and belong to the same part. Extra stubs a part needs are new symlinks in `tests/stubs/`, owned by that part.

## Conventions

- Bash 5. The entry point sets `set -Eeuo pipefail` and `shopt -s inherit_errexit`, and turns xtrace off, since a trace would print every secret. Library files only define functions and globals; they run nothing at source time.
- Files are sourced from inside a function (the entry point's and bats' loaders), so declare global arrays with `declare -g` / `declare -gA`. Plain `NAME=value` assignments are global anyway.
- Don't rely on `pipefail` or `nounset` being on: bats runs tests without them. Code that needs `pipefail` sets it locally with `local -; set -o pipefail`.
- Each file starts with `# shellcheck shell=bash` and a one-line comment saying what it holds.
- Public functions are `<module>_<name>`. Private helpers start with `_`. Globals are `GI_*` plus the three arrays `CFG`, `SECRET` and `HW`.
- Use `local` for every function variable. Quote every expansion. Use `[[ ]]` and `printf`. No `eval`. Never `source` anything the user supplied.
- Functions that return data print it on stdout. Everything meant for a human goes to stderr or the UI functions.
- shellcheck clean with `-x`. A `# shellcheck disable=` needs a comment saying why.
- Comments explain why, never what. US English.
- Read-only queries (`lsblk`, `blkid`, reading `/sys`) are called directly. Anything that changes a system goes through `run_cmd`, `run_chroot`, `run_stdin`, `run_interactive` or the file writers, so dry-run, explain mode, logging and the replay script all work.

## Globals

| Name | Meaning |
|---|---|
| `GI_VERSION` | `0.1.0` |
| `GI_HOME` | Directory holding `gentooinstall` and `lib/` |
| `GI_TARGET` | Mount point of the new system. Default `/mnt/gentoo`. Tests point it at a temp dir. |
| `GI_RUN_DIR` | Working dir on the live system. Default `/tmp/gentooinstall`. Holds the log, replay script and early state. |
| `GI_LOG` | `$GI_RUN_DIR/install.log` |
| `GI_DRY_RUN` | `1` with `--dry-run`. `run_cmd`, `run_chroot`, `run_stdin` and the writers print instead of acting. |
| `GI_EXPLAIN` | `1` with `--explain` or `explain=yes` |
| `GI_YES` | `1` with `--yes` (unattended; requires `--config`) |
| `GI_UI` | `dialog` or `plain`. `--no-tui` sets `plain` before `ui_init`, which keeps it. |
| `GI_RESUME` | `1` with `--resume` |
| `GI_INTERRUPTED` | `1` once the user pressed Ctrl+C during a step and chose to go on; `steps_run` resets it before each step |
| `GI_TEST` | `1` inside bats. Lets non-root runs proceed and turns on the test safety net in `run_cmd` and friends. Secrets files may then be owned by the current user. |
| `GI_HOST_ROOT` | Empty. Tests set it to a fake tree; every file read from the live system (`/sys`, `/proc`, `/dev`, `/run`, `/etc`, `/lib64`, `/usr/share`) is read below it. |
| `GI_STEPS` | Step ids in run order (`lib/state.sh`) |
| `GI_STEP_TITLE` | Associative array of step titles, from `step_define` |
| `GI_CFG_KEYS` | Config keys in table order (`lib/config.sh`) |
| `GI_ASKED_SECRETS` | Associative array of the secret keys the runner asked for itself, so a keymap change can drop them |
| `CFG` | Associative array of config answers, keyed exactly like the config file |
| `SECRET` | Associative array of secrets. Never logged, saved or passed as an argument. |
| `HW` | Associative array of detected hardware facts (see [hardware facts](#hardware-facts)) |

`lib/core.sh` declares `CFG`, `SECRET` and `HW` and sets the defaults above.

## Core API (`lib/core.sh`)

Logging. Every line in the log passes through `redact`, which replaces each non-empty `SECRET` value with `***`.

- `log LEVEL MESSAGE...` writes a timestamped line to `$GI_LOG` only.
- `info`, `warn`, `error MESSAGE...` print to stderr and log.
- `die MESSAGE [CODE]` prints, logs and exits (default code 1).
- `redact STRING` prints the string with secrets masked.

Commands. All of these log the command (quoted with `printf %q`, redacted), print it in explain mode, append it to `$GI_RUN_DIR/replay.sh`, and in dry-run print it and return 0 without running. Output goes to the log (redacted), never to the screen. Stdin is `/dev/null` unless DATA is given.

- `run_cmd CMD [ARGS...]` runs a command on the live system and returns its status. (Not `run`: bats already defines `run`, and loading core would replace it in every test.)
- `run_chroot CMD [ARGS...]` runs `arch-chroot "$GI_TARGET" /bin/bash -c 'source /etc/profile && <quoted command>; exit $?'`. The ISO's `arch-chroot` runs its command as PID 1 of a new PID namespace (`unshare --fork --pid`), and bash execs the last command of a script, which would make the command PID 1; `locale-gen` fails as PID 1. The trailing `exit` keeps bash as PID 1. `chroot_script COMMAND_LINE` prints that script, for a caller that runs `arch-chroot` itself (`emerge_run`, read-only queries through `dry_value`). The namespace also makes systemd tools in the chroot see a container (`bootctl` skips EFI variables), so the bootloader step creates the firmware boot entry from the live system.
- `run_stdin DATA CMD [ARGS...]` and `run_chroot_stdin DATA CMD [ARGS...]` feed DATA on stdin exactly as given (add a trailing newline if the command needs one). The log and replay script record `# (stdin: not recorded)` after the command, never the data or its length. Use these for every secret (`chpasswd`, `cryptsetup`).
- `run_interactive CMD [ARGS...]` runs a command the user types in, like a shell (`arch-chroot "$GI_TARGET"`), with the terminal attached: stdin, stdout and stderr are the installer's, and nothing goes to the log. It logs the command, adds it to the replay script as a `# interactive: ...` comment (what the user types isn't recorded), checks the safety net, and returns the command's status. In dry-run it prints that comment and returns 0 without running anything. Use it for every interactive shell, like the error menu's Shell and `finish_menu`'s.

Files in the target. Paths are absolute paths inside the new system (`/etc/hostname`), written to `$GI_TARGET$path` from the live system. Parent dirs are created. Writes are atomic (temp file, then `mv`). In dry-run they print the path and content; `ensure_line`, `set_shell_var` and `make_conf_use_add` print a one-line `# ...` note of the change instead, since a dry run never wrote the file they edit. A symlink at PATH is replaced, never followed, and a path whose directory resolves outside `$GI_TARGET` (through an absolute symlink in the target) is refused: such links point at the live system. To write through a link like `/etc/kernel/cmdline`, write its real target.

- `write_file PATH [MODE]` writes stdin to PATH. Default mode 0644. Logs path and content.
- `write_secret_file PATH [MODE]` same, default mode 0600, logs the path only.
- `ensure_line PATH LINE` appends LINE if no identical line exists. Keeps the file's mode.
- `set_shell_var PATH NAME VALUE` sets `NAME="VALUE"` in a shell-style file (`make.conf`, `/etc/conf.d/*`), replacing the first `NAME=` line (dropping later ones) or appending one. VALUE may contain `$` (for `${FEATURES} ...`) but not `"`, `\`, backticks or newlines.

Every step must be safe to run twice, because resume reruns the step that failed. Prefer `write_file` for whole files over appending.

Portage and services.

- `portage_file KIND NAME` writes stdin to `/etc/portage/KIND/NAME`, where KIND is `package.use`, `package.license`, `package.accept_keywords` or `package.env`.
- `make_conf_use_add FLAG...` adds flags to `USE` in `/etc/portage/make.conf`, keeping existing ones and never duplicating.
- `emerge_run ARGS...` runs `emerge ARGS...` in the chroot. It streams output to the log, shows `N of M  category/package-version (binary|source)` through `progress_status`, and on failure writes `$GI_RUN_DIR/last_failure` for the error menu: `package=` (like `app-misc/hello-2.12.3`) and `build_log=` (the live path, `$GI_TARGET/var/tmp/portage/.../build.log`) when a package failed to build, then `exit=`. It also copies that build log to `$GI_RUN_DIR/build-logs/<category>_<package-version>.log`, since Portage deletes it on the next attempt. Returns emerge's status. The parser is tested against real serial and `--jobs` output in `tests/fixtures/emerge/`.
- `service_enable NAME [RUNLEVEL]` runs `rc-update add NAME RUNLEVEL` (default `default`) on OpenRC or `systemctl enable NAME` on systemd, inside the chroot. Idempotent.
- `user_service_enable_global UNIT...` runs `systemctl --global enable` on systemd. Does nothing on OpenRC; callers handle OpenRC separately.
- `is_openrc`, `is_systemd` test `CFG[init]`.
- `dry_value PLACEHOLDER COMMAND...` prints PLACEHOLDER in dry-run, otherwise runs the read-only command (or a shell function of the step) and prints its output. Use it for values a dry run can't know, like UUIDs.

Safety net. When `GI_TEST=1`, `run_cmd` and friends (including `run_interactive`), and `dry_value` for anything but a shell function, refuse (status 126) to execute any command that doesn't resolve to `$GI_HOME/tests/stubs/<name>` and isn't one of `cat chmod cp install ln mkdir mv rm rmdir touch true false` called by bare name. Tests can never touch the real machine. `chown` is a stub, since tests don't run as root.

## UI (`lib/ui.sh`)

`ui_init` picks `dialog` when it's installed, stdin, stdout and stderr are terminals and `--no-tui` wasn't given, else `plain`. For `dialog` it exports `DIALOGRC=lib/dialogrc`, white text on black. Every widget works inside `$(...)`. In `dialog` mode results go through `--output-fd 1` and dialog draws on the terminal. In `plain` mode prompts go to stderr, answers come from stdin, menus are numbered and show TAG and ITEM in two columns like dialog (only ITEM when every tag just repeats its item), Enter takes the default, `-` clears an input's default, `b` means back, `x` is the extra button and `?` shows help.

Return codes for all widgets: 0 OK, 1 back (Back button, Esc or `b`), 3 extra button. On the extra button nothing is printed. When dialog itself fails (most often a box too tall for the screen, which dialog refuses to draw), the widget logs dialog's message and asks the same question in plain text, so a caller that repeats on back can't spin. If stdin closes in plain mode, the widget prints an error and stops the whole installer (SIGTERM to the main process and every subshell in between), so a caller that retries on failure can't spin forever. In a test, running out of piped answers fails that test.

- `ui_menu [--extra LABEL] [--ok LABEL] [--back LABEL] TITLE TEXT DEFAULT_TAG TAG ITEM HELP [TAG ITEM HELP...]` prints the chosen tag. HELP shows on the bottom line (`--item-help`).
- `ui_radio [same options] TITLE TEXT DEFAULT_TAG TAG ITEM HELP [...]` single choice, prints the tag.
- `ui_input TITLE TEXT DEFAULT` prints the typed value.
- `ui_password TITLE TEXT` asks once and prints the value, which may be empty (dialog `--passwordbox`, plain `read -rs`). Never uses `--insecure`.
- `ui_password_twice TITLE TEXT` asks twice until both match and refuses an empty value, prints the value.
- `ui_yesno [--defaultno] [--yes LABEL] [--no LABEL] TITLE TEXT` returns 0 for yes, 1 for no. The labels rename the buttons.
- `ui_msg TITLE TEXT`, `ui_textbox TITLE FILE`. The textbox's only button reads OK.
- `ui_info TITLE TEXT` shows TEXT and returns at once, for something that takes a while.
- `ui_confirm_text TITLE TEXT EXPECTED` returns 0 only after the user types EXPECTED exactly, 1 on back.
- `ui_backtitle` prints the top line: `gentooinstall 0.1.0 | UEFI | 16 GiB RAM | 8 threads | online`.

Install phase output is plain text in both modes (see `SPEC.md` and the TUI mockups):

- `progress_begin TOTAL`
- `progress_step_start INDEX ID TITLE`
- `progress_explain WHY HANDBOOK` (prints only in explain mode)
- `progress_status TEXT` rewrites the current line in place when stderr is a terminal, else prints nothing
- `progress_step_end ok|skip|fail`, which prints the elapsed time

`steps_run` calls the `progress_*` functions; steps only call `progress_status` (through `emerge_run`, or directly for downloads).

## Config (`lib/config.sh`)

File format and rules are in `SPEC.md` under "Config file". Keys, values and defaults:

| Key | Values | Default |
|---|---|---|
| `format` | `1` | `1` |
| `keymap` | console keymap name | `us` |
| `disk` | `/dev/disk/by-id/...`, or `/dev/disk/by-path/...` for a disk with no by-id link (a QEMU virtio disk without a serial) | required |
| `disk_mode` | `wipe` `free` | `wipe`. `free` installs into the largest free space of the disk's GPT; `hw_disk_free` reports it |
| `filesystem` | `ext4` `xfs` `btrfs` | `ext4` |
| `encryption` | `none` `luks2` | `none` |
| `luks_discard` | `yes` `no` | `yes` |
| `swap` | `zram` `file` `none` | `zram` |
| `init` | `openrc` `systemd` | `openrc` |
| `desktop` | `plasma` `gnome` `xfce` `budgie` `cinnamon` `i3` `sway` `hyprland` `niri` `mangowm` `dwm` `dwl` `none` | `plasma` |
| `gnome_variant` | `light` `full` | `light` |
| `display_manager` | `auto` `none` `tuigreet` `gtkgreet` `sddm` `gdm` `lightdm` | `auto` (SDDM for Plasma, GDM for GNOME, LightDM for Xfce, Budgie and Cinnamon, none for the window managers). `cfg_login_screens DESKTOP` lists the ones a desktop offers, `cfg_login_screen` resolves `auto` |
| `bootloader` | `systemd-boot` `grub` `limine` | `systemd-boot` |
| `kernel` | `gentoo-kernel-bin` `gentoo-kernel` | `gentoo-kernel-bin` |
| `nvidia_driver` | `proprietary` `nouveau` | `proprietary` |
| `network` | `networkmanager` `dhcpcd` `networkd` | `networkmanager` |
| `keep_wifi` | `yes` `no` | `yes` |
| `wifi_ssid` | SSID | from `HW[wifi_ssid]` |
| `audio` | `pipewire` `none` | `pipewire` |
| `bluetooth` | `yes` `no` | `yes` when `HW[bluetooth]=yes` |
| `power` | `ppd` `tlp` `none` | `ppd` when `HW[laptop]=yes` |
| `thermald` | `yes` `no` | `no` |
| `fwupd` | `yes` `no` | `yes` when `HW[laptop]=yes` |
| `sshd` | `yes` `no` | `no` |
| `hostname` | RFC 1123 label | `gentoo` |
| `timezone` | `Region/City` or `UTC`, picked from `lib/timezones.tsv` | `UTC` |
| `locales` | space-separated, like `en_US.UTF-8` | `en_US.UTF-8` |
| `lang` | one of `locales` | first of `locales` |
| `root` | `password` `locked` | `password` |
| `users` | space-separated usernames | required, at least one |
| `user.<name>.admin` | `yes` `no` | `yes` |
| `user.<name>.shell` | `bash` `zsh` `fish` | `bash` |
| `privilege` | `sudo` `doas` | `sudo` |
| `mirror` | `cdn` `fastest` or an `https://` URL | `cdn` |
| `binpkgs` | `yes` `no` | `yes` |
| `cflags` | compiler flags, no quotes, `$`, backticks or newlines | `-march=native -O2 -pipe` |
| `makeopts` | `auto` or flags | `auto` |
| `emerge_jobs` | `auto` or a positive integer | `auto` |
| `tune` | `yes` `no` | `no` |
| `browser` | `firefox-bin` `chromium` `none` | `firefox-bin` |
| `fonts_cjk` | `yes` `no` | `no` |
| `media_keys` | `yes` `no` | `no` |
| `packages` | space-separated package atoms, picked in fzf | empty |
| `explain` | `yes` `no` | `no` |

Secrets, kept in `SECRET`: `luks_passphrase` (with `luks2`), `root_password` (with `root=password`), `user.<name>.password` (each user), `wifi_psk` (with `network=networkmanager`, `keep_wifi=yes` and a `wifi_ssid`, since only NetworkManager gets the saved network; an empty value means an open network). A secret counts as given once its key exists in `SECRET`.

Usernames match `^[a-z_][a-z0-9_-]{0,31}$` and must not be a system account or group name (`root`, `portage`, `nobody`, `wheel`, `sddm`, `systemd-*` and others listed in `lib/config.sh`). Package atoms must look like Portage atoms (`app-editors/vim`, `>=dev-lang/rust-1.80:0`, `dev-vcs/git::gentoo`) with no shell characters. An empty `disk` or `users` is valid and means "not chosen yet"; `cfg_check_rules` requires them.

Functions:

- `cfg_defaults_apply` fills every key that isn't set yet with its default, using `HW` for the hardware-dependent ones, `lang` from the first of `locales`, and `user.<name>.admin`/`shell` for each user. It never overwrites a value, so it runs after pre-flight and after the config file was loaded. `cfg_defaults_apply ask`, for a fresh interactive run, fills only the keys the questions don't ask (`format`, `disk`, `wifi_ssid`, `users`, `packages`, `mirror`, `cflags`, `makeopts`, `emerge_jobs`, the per-user keys); the questions mark the rest `[!] not set`. `steps_run` calls it again, so steps can rely on every key being set.
- `cfg_set KEY VALUE` (validates, returns 1 with a message on stderr on bad input or a locked key).
- `cfg_validate KEY VALUE` prints `KEY: problem` on stdout and returns 1 when invalid, so callers can capture it with `$(...)`. It never echoes the value.
- `cfg_load FILE` and `cfg_load_secrets FILE` parse files (never source them). They collect every error and report them together on stderr as `FILE: line N: ...`, then return 1. Duplicate and unknown keys are errors, and so are `user.<name>.*` keys for a name not in `users`. A CR before the newline is dropped, so files with Windows line endings work; every value is a single line. Secrets files must be root-owned with mode 600 (owned by the current user when `GI_TEST=1`); their error messages never contain values.
- `cfg_save [FILE]` writes every set non-secret key, in table order, followed by the per-user keys for each user in `users`. FILE defaults to `$GI_RUN_DIR/config`. Returns 1, leaving no temp file, when it can't write the file. A step that changes answers (the preview step) changes `CFG` and calls `cfg_save` with no FILE; the runner reloads that file after every step.
- `cfg_check_rules` prints `error: ...` and `warn: ...` lines on stdout and returns 1 when there's an error. It re-validates every key, requires `disk` and at least one user, checks that `lang` is one of `locales`, and applies the v1 combination rules in `SPEC.md`: LUKS needs systemd-boot or Limine, a desktop needs a 40 GiB disk (through `hw_disk_size_bytes`), systemd-networkd needs systemd, locking root needs an admin user, a desktop without NetworkManager warns, Secure Boot on is an error, less than 4 GiB of RAM (rounded to the nearest GiB, as `MemTotal` is a little under the installed RAM) warns with a desktop or `gentoo-kernel`, and a login screen other than `auto` must be one `cfg_login_screens` offers for the desktop (only `none` without one).
- `cfg_secrets_missing [STEP_IDS...]` prints the secret keys still needed by the given pending steps.
- `cfg_secret_validate KEY VALUE` prints `KEY: problem` on stdout and returns 1 when VALUE can't be that secret, never echoing it: `wifi_psk` is empty (open network), 8 to 63 printable ASCII characters or 64 hex digits; the passwords and the LUKS passphrase must not be empty. `cfg_load_secrets` and the runner use it.
- `cfg_lock KEY...`, `cfg_is_locked KEY`. Locked keys can't change after the disk step starts: `disk`, `filesystem`, `encryption`, `swap`, `init`.

## Steps (`lib/state.sh`)

Step ids, in run order:

| Id | Title | File |
|---|---|---|
| `disk` | Disk preparation | `lib/steps/disk.sh` |
| `stage3` | Stage3 | `lib/steps/stage3.sh` |
| `portage` | Portage setup | `lib/steps/portage.sh` |
| `preview` | Compile preview | `lib/steps/preview.sh` |
| `world` | Install packages | `lib/steps/world.sh` |
| `locale` | Time, locale and keyboard | `lib/steps/locale.sh` |
| `kernel` | Firmware and kernel | `lib/steps/kernel.sh` |
| `system` | System configuration | `lib/steps/system.sh` |
| `network` | Networking | `lib/steps/network.sh` |
| `tools` | System tools | `lib/steps/tools.sh` |
| `bootloader` | Bootloader | `lib/steps/bootloader.sh` |
| `users` | Users and privileges | `lib/steps/users.sh` |
| `desktop` | Desktop | `lib/steps/desktop.sh` |
| `graphics` | Graphics drivers | `lib/steps/graphics.sh` |
| `hardware` | Audio, Bluetooth and laptop | `lib/steps/hardware.sh` |
| `finish` | Finish | `lib/steps/finish.sh` |

Each step file calls `step_define ID TITLE WHY HANDBOOK [optional]` at the top level (the one exception to "run nothing at source time"; an unknown ID stops the installer) and defines up to three functions. A step without a `step_<id>` function does nothing at run time.

- `step_<id>_portage` writes Portage config the step's packages need before they're installed: `package.use`, `package.license`, `package.accept_keywords`, `make_conf_use_add`. It also writes every file that a package reads while it installs. The kernel is installed during `world`, so `/etc/kernel/cmdline`, dracut and installkernel config, the console keymap and `/etc/machine-id` must all exist before then. The portage step calls every hook in step order, after the profile and base `make.conf` are in place. The compile preview and the world step first call `portage_refresh`, which reruns `portage_configure` (profile, `make.conf`, every hook) only when the answers differ from those its last finished run used (private state key `portage.answers`, cleared when a run starts). So a settings change that failed halfway or a resume with a new `--config` gets files that match the saved answers, and a retry of a failed package install runs only `emerge`. The preview also calls it after each settings change. Hooks must be idempotent.
- `step_<id>_packages` prints the package atoms the step needs, one per line, based on `CFG` and `HW`.
- `step_<id>` does the work after `world` has installed everything: config files, services, checks.

Speed comes from the `world` step. It installs `@world` plus the union of every `step_<id>_packages` list in one `emerge` call, so Portage resolves dependencies once, runs `--jobs` across everything and installs from binaries wherever it can. The compile preview runs `emerge --pretend` on exactly that list. That call uses `--oneshot`; after it worked, `emerge --noreplace` with the same list adds them to the world file. So a failed run records nothing a resume with changed answers would keep, and without `--update` Portage records no older installed slot of a named package, like the old kernel after a sync and a retry.

Runner functions:

- `steps_run` applies defaults, locks the disk keys, saves the config, then runs every step not yet done, in order. Each step runs in a subshell with `errexit` on, so the first failing command ends it and a failure can't leave half-changed globals. Steps share facts only through the state file and the saved config. Each step also gets a header comment in the replay script. The first run sets the state key `install.started`.
- Before each step the runner asks for the secrets that step and the later ones still need (`cfg_secrets_missing`; with `--yes` a missing one exits 2; for `wifi_psk` it first asks whether the network is open). A typed password or passphrase under 16 characters, the Handbook's suggestion, is kept only after a yes/no question; No asks again. A secret a step adds, changes or removes in its subshell (the compile preview's `questions_hub`) is lost with the subshell, so the runner drops it in the parent and asks for it again. When a step changed `keymap`, the passwords the runner itself asked for are dropped and asked again too.
- On failure with `--yes` the runner logs the step, its exit status and the failed package with its build log (from `last_failure`), and exits 1, which leaves the install resumable; the entry point's exit handler prints the log path and the `--resume` hint. There's nobody to answer the error menu, which would wait on a terminal forever. The one exception is a step that failed because the user pressed Ctrl+C and chose to go on: they're at the keyboard, so the menu shows.
- On failure without `--yes` the runner shows the error menu with the step, its exit status and the last five log lines, without their timestamps and cut to 70 columns so the menu fits an 80x24 console (plus the package and build log path from `last_failure`): Retry, Log (the last 40 lines of the failed package's build log, or of the install log), Shell (`bash -i` on the live system before `stage3` is done, `arch-chroot "$GI_TARGET"` after), Skip (optional steps only) and Abort. Abort exits with code 130 and leaves the state resumable. Ctrl+C asks first, then aborts the same way; if the user goes on, the interrupted step fails and the menu offers Retry. A step that exits 130 itself (its own Abort, like the compile preview's) stops the installer at once with 130, without the menu. The runner tells it from Ctrl+C, which also ends the step with 130, through `GI_INTERRUPTED`, set by the entry point's Ctrl+C handler when the user goes on; so a step aborts with a plain `exit 130`.
- `state_get KEY [DEFAULT]`, `state_set KEY VALUE`. Values are single lines and saved immediately.
- `state_step_done ID`, `state_step_is_done ID`. A step's state is `step.<id>=done` or `step.<id>=skipped`; both count as done.
- `state_relocate_to_target` creates `$GI_TARGET/var/lib/gentooinstall/` (mode 700), copies the state there and saves the config next to it. The disk step calls it once root is mounted. From then on every `state_set` writes both the working copy in `$GI_RUN_DIR/state` and the copy on the target (marked by `state.relocated=yes`), and the runner saves the config to both places after each step. Keeping the working copy in `$GI_RUN_DIR` means a rerun of the disk step that reformats root can't lose it. Dry-run never relocates.

State keys each part must set for the others:

| Key | Set by | Meaning |
|---|---|---|
| `disk.root_uuid` | disk | Filesystem UUID of the device mounted at `/` (the LUKS mapping or the root partition) |
| `disk.luks_uuid` | disk | LUKS UUID of the root partition, empty without LUKS |
| `disk.ssd` | disk | `yes` or `no` |
| `disk.swapfile` | disk | Swap file path inside the target, empty without one |
| `stage3.file` | stage3 | Stage3 tarball name in the target's root, set once it is verified, right before it's unpacked. A retry or resume unpacks that same one again, even after a `desktop` change picks another variant, so two stage3s never mix |
| `install.started` | core | Epoch seconds when steps first ran. Set once by `steps_run`; a resume keeps it. |
| `mirror.fastest` | stage3 | Space-separated https mirror base URLs that `mirrorselect -S` measured, set the first time `stage3_mirrors` runs with `mirror=fastest` and reused after that |

### Cross-part handoffs

Functions one part provides for another:

| Function | Provided by | Used by | Contract |
|---|---|---|---|
| `questions_hub` | C questions | E preview | Shows the hub without the review and typed confirmation. Locked keys show as read-only. The last item reads "Continue". Returns 0 when the user continues, 1 on back; both pass the same checks as Install first, since the caller keeps the answers either way. It asks for no secret, which the step's subshell would lose: one the user adds or changes, or a typed one a keymap change clears, is dropped, and the runner asks for it when the step ends. The caller calls `cfg_save`. |
| `world_packages` | E world | E preview, E world | Prints the full atom list for the one `emerge` call: every `step_<id>_packages` output plus `CFG[packages]`, deduplicated, in step order. |
| `finish_menu` | H finish | entry point | Runs after `steps_run` succeeds, outside any step (the state file on the target must stay writable until the runner marks `finish` done). Offers reboot, a shell in the new system, or exit; then swaps off, unmounts `$GI_TARGET` recursively, closes LUKS and syncs before rebooting or exiting. It first leaves a working directory inside `$GI_TARGET`. When something still uses the target, it skips the LUKS close, warns with the commands to finish by hand, and goes on (a reboot unmounts it during shutdown). With `--yes` it unmounts and exits without asking. Skipped in dry-run. |
| `graphics_nvidia_branch` | H graphics | C questions | Prints the NVIDIA driver branch the oldest NVIDIA display device in `/sys` needs: `current` (Turing and newer, device ID 0x1e00 and up), `580` (Maxwell to Volta, 0x1340 to 0x1dff) or `none` (Kepler and older, which get nouveau). Prints `current` when there's no NVIDIA GPU. |
| `hardware_pipewire` | H hardware | C questions | Returns 0 when PipeWire and WirePlumber get installed: `audio=pipewire` and either a desktop or systemd. Returns 1 with `audio=none`, and on OpenRC without a desktop (ALSA only). Reads only `CFG[audio]`, `CFG[desktop]` and `CFG[init]`. |
| `locale_xkb` | F locale | F locale, H desktop | Prints the X keyboard layout for `CFG[keymap]` as four lines in this order: `layout=`, `model=`, `variant=`, `options=`, each value empty when unset (`layout` never is). The values are what `localectl` would set: systemd's `kbd-model-map` row from the stage3, a built-in row for the menu's keymaps whose layout isn't the keymap name up to its first dash, or else that name. They contain no spaces or quotes. The locale step writes `00-keyboard.conf` from it; the desktop step gives it to the Wayland sessions that don't read that file. |
| `disk_resume_mount` | D disk | entry point | See Resume below. |
| `stage3_mirrors` | D stage3 | D stage3, E portage, E preview | Prints the mirror base URLs for `CFG[mirror]`, space-separated: `https://distfiles.gentoo.org` for `cdn`, the URL itself, or for `fastest` the list in `mirror.fastest`, which the first call measures with `mirrorselect -S` on the live system (about a minute, with an `info` line first). Called as `$(...)`: use it as an assignment of its own (or with `|| return`) so a failed measurement, which dies, fails the step. The portage step calls it each time it runs, so a mirror changed in the compile preview or on `--resume` takes effect. |
| `stage3_check_answers` | D stage3 | D stage3, F locale | Checks `timezone` and `locales` against the unpacked stage3's zoneinfo and `SUPPORTED`, asks again for a wrong one (dies with `--yes`), moves `lang` to the first locale when it's no longer among them, and calls `cfg_save`. The locale step calls it again for answers changed after the stage3 step. |

Who writes which Portage file, so no two hooks fight over one file or variable. Each file has one owner. The portage step rewrites `make.conf` from scratch each time it runs, then calls the hooks, so hooks always add to a fresh file. A hook whose condition no longer holds deletes its file, since the preview reruns the hooks after the answers change.

| File under `/etc/portage/` | Written by | When |
|---|---|---|
| `make.conf` (`COMMON_FLAGS`, `MAKEOPTS`, `EMERGE_DEFAULT_OPTS`, `FEATURES`, `ACCEPT_LICENSE`, `GENTOO_MIRRORS`, `L10N`), `binrepos.conf/gentoo.conf`, the profile | E portage step | always (`binrepos.conf` with binary packages) |
| `make.conf` `USE` | the hook of the step that needs a global flag, through `make_conf_use_add`: F kernel (`dist-kernel`), G network (`networkmanager`, with NetworkManager unless the Plasma or GNOME profile sets it) | |
| `package.use/00cpu-flags` (`CPU_FLAGS_X86`) | E portage step | `tune=yes` or no binary packages |
| `package.use/installkernel` (`installkernel`, `systemd`/`systemd-utils` `boot` for systemd-boot, `systemd-utils` `kernel-install` on OpenRC unless GRUB, `systemd` `cryptsetup` with LUKS) | F `step_kernel_portage` | always |
| `package.accept_keywords/limine` (`sys-boot/limine ~amd64`) | F `step_kernel_portage` | Limine; removed otherwise |
| `env/sys-boot/limine` (`post_pkg_postinst` copies a new `/usr/share/limine/BOOTX64.EFI` over `/efi/EFI/limine/BOOTX64.EFI`, and over the fallback while it matches that copy) | F `step_kernel_portage` | Limine; removed otherwise |
| `env/sys-kernel/gentoo-kernel-bin`, `env/sys-kernel/gentoo-kernel` (`post_pkg_postrm`: each boot menu kernel whose `/usr/src/linux-<version>` and `/lib/modules/<version>/build` are gone and whose `/lib/modules/<version>` is still there, except the running and the newest kernel, leaves the menu, then its `/lib/modules/<version>` is deleted; through `kernel-install remove` for the ESP's entries, or with `/boot/grub/grub.cfg` by removing its files in `/boot` and one `grub-mkconfig`; nothing when the running kernel has no `/lib/modules/<version>` (a live system's chroot); `step_kernel` deletes a `grub.cfg` left from an earlier bootloader answer) | F `step_kernel_portage` | always |
| `package.use/network` (`wpa_supplicant dbus`) | G `step_network_portage` | NetworkManager without a desktop |
| `package.use/zram-generator` (`-man`) | G `step_tools_portage` | zram on systemd without binary packages |
| `package.use/plasma-meta` (`-display-manager`) | H `step_desktop_portage` | Plasma without a display manager |
| `package.use/ngtcp2` (`gnutls`) | H `step_desktop_portage` | GNOME on systemd without binary packages |
| `package.accept_keywords/desktop` | H `step_desktop_portage` | Budgie (`*/*::SarahMiaOverlay`, `gui-wm/labwc`, `dev-cpp/toml11`), Hyprland (`*/*::hyproverlay`, `dev-cpp/sdbus-c++`), Niri and MangoWM (their GURU atoms), dwl, and `app-misc/brightnessctl::guru` with `media_keys=yes` for Sway, Hyprland and Niri |
| `package.use/desktop` | H `step_desktop_portage` | Budgie (`vala` and the like on its dependencies), Niri (`screencast`), Sway (`wallpapers`, for its default config's wallpaper, and `swaybg gdk-pixbuf`), Hyprland (`libheif gdk-pixbuf`, as the binary host's), Cinnamon on OpenRC (`gvfs gnome-online-accounts keyring`, `pipewire gstreamer`, `webkit-gtk keyring` and `xdg-desktop-portal gstreamer`, the binary host's only OpenRC builds), `brightnessctl udev` with its keyword |
| `repos.conf/<overlay>.conf` (`guru`, `hyproverlay`, `SarahMiaOverlay`; plain git sync), and the overlay in `/var/db/repos/<overlay>` | E portage step | Budgie, Hyprland, Niri, MangoWM, and `guru` for brightnessctl with `media_keys=yes` and Sway or Hyprland; the first copy comes from the live system's `git`, and the portage step's packages add `dev-vcs/git` for later syncs; an answer that no longer needs it removes both |
| `package.use/00video_cards` (`VIDEO_CARDS`, NVIDIA and Mesa video USE) | H `step_graphics_portage` | `tune=yes`, no binary packages, or the NVIDIA driver |
| `package.license/nvidia-drivers` | H `step_graphics_portage` | the NVIDIA driver |
| `package.mask/nvidia-drivers` (the 580 branch for pre-Turing GPUs) | H `step_graphics_portage` | Maxwell to Volta |
| `package.use/pipewire` (`sound-server`) | H `step_hardware_portage` | PipeWire with a desktop or on systemd |
| `package.use/tlp` (`-rdw`) | H `step_hardware_portage` | TLP without NetworkManager |
| `package.use/power-profiles-daemon` (`systemd policykit`) | H `step_hardware_portage` | power-profiles-daemon on systemd |
| `package.use/zz-autounmask`, `package.accept_keywords/zz-autounmask`, `package.license/zz-autounmask`, `package.unmask/zz-autounmask` | E preview | only lines the user approved; kept after later settings changes |
| `GRUB_PLATFORMS`: nobody. The amd64 profile's `efi-64 pc` for GRUB matches the binary host; `efi-64` alone forces a source build | none | |

`sys-apps/systemd` gets flags from two files (F `installkernel`, H `power-profiles-daemon`), and so does `media-video/pipewire` for Cinnamon on OpenRC (H `pipewire`, H `desktop`); flags in `package.use` add up, so they can't conflict. Files outside `/etc/portage/` that hooks write before `world`: `/etc/kernel/cmdline` (no `nvidia_drm.modeset=1`: nvidia-drivers 580 sets it in modprobe.d, and 595 and later default to it), `/etc/cmdline.d/00-installkernel.conf` and `/etc/dracut.conf.d/gentooinstall.conf` (F kernel), with Limine `/etc/kernel/install.conf.d/limine.conf` (`layout=bls`) and the kernel-install plugin `/etc/kernel/install.d/95-limine.install`, which rewrites `/efi/limine.conf` from the boot entries on every kernel install and removal (F kernel, removed with another bootloader), `/etc/fstab` and `/etc/machine-id` (F system), `/etc/conf.d/keymaps` or `/etc/vconsole.conf` (F locale).

Resume. `--resume` calls `disk_resume_mount` (part D), which finds the target by its GPT partition label, opens LUKS (asking for the passphrase) and mounts everything. Core then copies the state from the target to `$GI_RUN_DIR/state`, loads the saved config, locks the disk keys and applies a `--config` given on the command line on top. A locked key can't change. Any other answer may change only while the first step that acts on it is still pending: `locale` for `keymap`, `timezone` and `lang`, `system` for `hostname` and `root`, `network` for `keep_wifi` and `wifi_ssid`, `users` for `user.<name>.admin`, `world` for every other key (it installs every package and is the last step to rewrite Portage's files), and `explain` any time. Otherwise it exits 2, naming the key and the finished step. When a `world` key changed after the compile preview had run, the preview's step is marked pending again, so it shows the plan for the new answers. When the resulting `keymap` isn't the layout the user picked at start (which unlocked the disk), it loads it with `loadkeys`, so the passwords still to type use the new system's layout, and with LUKS it warns that the disk passphrase was set with the old one. Then it runs `cfg_check_rules` and calls `steps_run`, which asks for any secrets the pending steps still need (see the runner above). Before that it warns about each `--secrets` password the pending steps use that is under 16 characters, and it drops the Wi-Fi key pre-flight kept from the live network when that network isn't the saved `wifi_ssid` and `--secrets` didn't give one, so the runner asks for the saved network's key. The disk step must handle being resumed after it relocated the state: it must not repeat destructive work. On `--resume` it stops unless the state's `disk.stage` is `mounted`, the only value a relocated state can hold.

## Hardware facts

`hw_detect` (part B) fills `HW`. Every key is always set, using `unknown` or empty when detection fails.

| Key | Values |
|---|---|
| `boot_mode` | `uefi` `bios` |
| `efi_bits` | `64` `32` or empty |
| `secure_boot` | `on` `off` `unknown` |
| `iso` | `gentoo-minimal` `other` |
| `online` | `yes` `no` |
| `wifi_ssid` | SSID of the live session's Wi-Fi, or empty |
| `ram_mib`, `cpu_threads` | integers |
| `cpu_vendor` | `intel` `amd` `other` |
| `x86_64_v3` | `yes` `no` |
| `cpu_flags` | `cpuid2cpuflags` output without the `CPU_FLAGS_X86: ` prefix |
| `gpus` | space-separated, from `intel amd nvidia virtual` |
| `gpu_desc` | readable GPU summary for the UI |
| `sof`, `wifi`, `bluetooth`, `laptop`, `on_battery`, `vm` | `yes` `no` |
| `live_disk` | kernel name of the disk holding the live medium, like `sdb` (also under a Ventoy mapping) |

Other part B functions: `hw_disks` prints one tab-separated line per installable disk: by-id path (by-path when the disk has no by-id link, or only LVM's `lvm-pv-uuid-` one, which wiping removes), kernel name, size in bytes, kind (`NVMe`, `USB`, `SATA SSD`, `HDD`, ...), model, and a short summary of what's on it. `hw_disk_size_bytes BYID` prints one disk's size. Part B also fills `SECRET[wifi_psk]` when it knows the live Wi-Fi key, and sets it to empty when that network is open. That key is always for the config's `wifi_ssid` when one is set, else for `HW[wifi_ssid]`, and never replaces a key `--secrets` gave. Its Wi-Fi offer connects through NetworkManager (`nmcli`), which the minimal ISO starts; without NetworkManager it only points the user to `nmtui` or `net-setup`.

## Entry flow (`gentooinstall`)

Options: `--config FILE`, `--secrets FILE`, `--resume`, `--dry-run`, `--explain`, `--yes`, `--no-tui`, `--log FILE`, `--help`, `--version`. `--yes` needs `--config`. `--resume` and `--dry-run` can't be combined.

1. Parse options. Require root unless `GI_TEST=1`. Set up `GI_RUN_DIR` (mode 700, must be owned by the caller), the log (mode 600) and traps (`ERR` logs the failing command and its location, `INT` asks before aborting, `TERM` exits 1, `EXIT` prints the log path and, once the state is on the target, the resume command). A fresh run (not `--resume`) clears the old state, config, build logs and replay script in `GI_RUN_DIR`.
2. `ui_init`.
3. `cfg_load` and `cfg_load_secrets` if given; any error exits 2 before a single question. `--explain` sets `explain=yes`.
4. `questions_keymap` (part C) asks for and loads the console keymap. At this point `CFG` holds only keys from the config file, so `${CFG[keymap]:-}` is set exactly when the config has one; then it uses that instead of asking. With `--yes` and no keymap in the config it asks nothing, and `cfg_defaults_apply` sets `us`. With `--resume` (without `--yes`) it asks for the layout the install was started with, even when the config has a keymap: the disk passphrase is typed with that layout, and the config's or the saved `keymap` is the new system's, which `gi_resume` loads afterwards.
5. `preflight_run` (part B) checks the machine and fills `HW`.
6. `cfg_defaults_apply` fills every key the config didn't set.
7. With `--resume`, go to the resume flow above.
8. `questions_run` (part C) runs the hub, the review and the typed confirmation. With `--yes` and a complete config it only validates (`cfg_check_rules`, plus a `disk` that isn't in `hw_disks` and every missing secret), and fails listing every problem. A `--secrets` password under 16 characters gets a `warn:` line there, and in the interactive hub a warning before the review.
9. With `--dry-run`, `steps_run` prints every command and changes nothing.
10. `steps_run`, then `finish_menu` (part H) for the reboot, shell or exit choice. Not in dry-run, and only when `finish_menu` is defined.

Exit codes: 0 success, 1 failure, 2 bad usage or config, 130 aborted by the user.

## Tests

- `tests/run.sh [FILE...]` runs shellcheck and bats. With no arguments it checks everything. With files it checks only those (`.sh` and the entry point go to shellcheck, `.bats` to bats). It prefers tools in `.tools/bin`. `tests/bootstrap.sh` downloads them there.
- `tests/helpers.bash` provides `gi_setup`, which makes a temp `GI_TARGET` and `GI_RUN_DIR`, sets `GI_TEST=1`, puts `tests/stubs` first in `PATH`, and sets `STUB_LOG` and `STUB_OUT_DIR`. `gi_load MODULE...` sources `lib/<module>.sh` or `lib/steps/<module>.sh`. Load only what a test needs, so one part's broken file can't fail another part's tests. Most modules need `core`; anything that prints progress or asks questions also needs `ui`. Set `GI_UI=plain` and pipe answers on stdin, or set `GI_UI=dialog` and use the `dialog` stub.
- `tests/stubs/_stub` is one recorder script. Every stub is a symlink to it named after the real command (`arch-chroot`, `emerge`, `sfdisk`, `mount`, `cryptsetup`, `dialog` and so on). It appends its name and `%q`-quoted arguments to `$STUB_LOG`, prints `$STUB_OUT_DIR/<name>` if that file exists, and exits with `$STUB_RC_<name>` (default 0, with `-` and `.` in the name replaced by `_`). When `STUB_STDIN_DIR` is set it also appends its stdin to `$STUB_STDIN_DIR/<name>`; set it only in tests whose stubs are all called through the `run_*` helpers, or a stub may wait on the test's stdin. Commands run inside the chroot are recorded as one `arch-chroot` line.
- bats only fails a test on a failing simple command. `[ a ] && [ b ]` and `! cmd` in the middle of a test never fail it: put each check on its own line and use `run ! cmd`.
- Never run tests as root, never run the installer itself on a development machine, and never point anything at a real disk.

A Docker volume `gi-portage` (the Gentoo ebuild tree) and the image `gentoo/stage3:latest` are available for checking real Portage behavior:

```sh
docker run --rm --volumes-from gi-portage gentoo/stage3:latest emerge --pretend --verbose kde-plasma/plasma-meta
```

Use it to check package names, USE flags and profile names, and to capture real `emerge` output as test fixtures. Don't run the installer in it.
