# gentooinstall spec

Everything the installer must do, in the order it runs. Tick items off as they get built. Items tagged **(later)** are outside v1; see [v1 scope](#v1-scope).

Sources, checked 2026-10-30: the [Gentoo AMD64 Handbook](https://wiki.gentoo.org/wiki/Handbook:AMD64), the [Binary Host Quickstart](https://wiki.gentoo.org/wiki/Gentoo_Binary_Host_Quickstart), the live file listings on distfiles.gentoo.org, `profiles/profiles.desc` in gentoo.git, and the [oddlama/gentoo-install](https://github.com/oddlama/gentoo-install) README.

## Goals

- Take a laptop from a live USB to a graphical login with Wi-Fi, sound and a desktop. After the questions, nothing is manual.
- Install from the official binary package host wherever possible, so a full desktop downloads instead of compiling for hours.
- Survive failures. You fix a failed step and resume. You never start over from partitioning.
- Show its work. Every command is logged next to the Handbook section it comes from, and the whole run is saved as a readable shell script.

## Non-goals

- Inventing a new way to install Gentoo. Every step follows the Handbook.
- Every disk layout. ZFS, mdraid and LVM are covered by oddlama/gentoo-install.
- Hardened, SELinux, musl, llvm, x32, no-multilib and split-usr installs. The binhost only carries the stage3 package set for most of these.
- Architectures other than amd64.
- Hand-configured kernels. Users can switch to `gentoo-sources` after install.
- Managing the system after install: updates, new software, upgrades.

---

## 1. Startup

- [ ] Require root. Exit with a clear message otherwise.
- [ ] Require `x86_64` from `uname -m`.
- [ ] Detect the boot mode. UEFI if `/sys/firmware/efi` exists, BIOS otherwise.
  - [ ] v1: on BIOS, explain how to boot the USB in UEFI mode, then exit.
  - [ ] (later) BIOS installs.
- [ ] Read `/sys/firmware/efi/fw_platform_size`. Some cheap laptops have 32-bit UEFI on a 64-bit CPU. v1 refuses with a message. (later) support it.
- [ ] Detect the Secure Boot state. If it's on, warn that v1 does not sign the bootloader and the machine won't boot the new system until Secure Boot is turned off in firmware.
- [ ] Check that we're on the Gentoo minimal install ISO, the only supported live system. On anything else, warn that it's unsupported and ask before continuing.
- [ ] Check every external tool the run will need before asking any question, and print the full list of missing ones. All of these ship on the minimal ISO: `dialog`, `lsblk`, `blkid`, `sfdisk`, `wipefs`, `udevadm`, `mkfs.vfat`, `mkfs.ext4`, `mkfs.xfs`, `mkfs.btrfs`, `cryptsetup`, `gpg`, `curl`, `tar`, `xz`, `arch-chroot`, `genfstab`, `cpuid2cpuflags`, `lspci`, `efibootmgr`, `chronyd`.
- [ ] Parse options: `--config FILE`, `--secrets FILE`, `--resume`, `--dry-run`, `--explain`, `--yes`, `--no-tui`, `--log FILE`, `--help`, `--version`.
- [ ] Start the log file before anything else. Record the installer version, arguments, date, live ISO and detected hardware.
- [ ] Ask for the console keymap first and apply it with `loadkeys`. Every password and passphrase typed later depends on it.

## 2. Pre-flight checks

- [ ] Network: DNS resolves and `https://distfiles.gentoo.org` answers.
  - [ ] If offline, help connect to Wi-Fi through NetworkManager (`nmcli`), which the minimal ISO starts and which handles DHCP and DNS: list networks, ask for the password, connect, retry the check. Keep the SSID and key in memory for section 14. Without NetworkManager, point the user to `nmtui` or `net-setup` instead.
- [ ] Respect `http_proxy` and `https_proxy`, and pass them on to the chroot and Portage.
- [ ] Clock: sync with `chronyd -q`. TLS and GPG checks fail when the clock is wrong. If no time server answers, show the current time and let the user set it. When the network check fails only because the server's certificate didn't verify, sync the clock first (NTP needs no TLS), then check again.
- [ ] RAM: read the total. Refuse below 2 GiB. Warn below 4 GiB when a desktop or the compiled `gentoo-kernel` is chosen. The value also feeds MAKEOPTS and swap size. Both limits are provisional until the VM tests measure real use.
- [ ] Power: on a laptop, warn when running on battery. Read `/sys/class/power_supply/*/online` for the Mains supply.
- [ ] Disks: at least one disk that isn't the live USB and has 20 GiB or more. A desktop needs 40 GiB, checked at review time once the desktop is known. Both limits are provisional until the VM tests measure real use.
- [ ] Hardware detection, saved for later steps. Read `/sys` directly when `lspci` is missing.
  - [ ] CPU vendor (Intel or AMD), for microcode.
  - [ ] x86-64-v3 support. `/lib64/ld-linux-x86-64.so.2 --help` prints `x86-64-v3 (supported, searched)`.
  - [ ] CPU flags from `cpuid2cpuflags`, run on the ISO since it's the same CPU.
  - [ ] GPUs from PCI classes VGA, 3D and Display: Intel, AMD, NVIDIA, several at once (hybrid), or virtual (virtio, qxl, vmware).
  - [ ] Audio DSP that needs SOF firmware (Intel 10th gen and newer, Apollo Lake, some AMD APUs).
  - [ ] Wi-Fi and Bluetooth adapters.
  - [ ] Laptop or desktop, from `/sys/class/dmi/id/chassis_type` and battery presence.
  - [ ] Running in a VM.
  - [ ] Disk transport and type: NVMe, SATA SSD, HDD, virtio, eMMC. SSDs get TRIM.

## 3. Questions

Every question has a help line, can be answered from a config file, and validates input on entry. The user can go back at any point. In an interactive run nothing is filled in for the user: each question the config file leaves out is marked `[!] not set` until it's answered, lists select nothing until the user picks, and the recommended choice is labeled instead. Compiler flags, MAKEOPTS, emerge jobs and the mirror keep their defaults, which suit almost everyone. Questions that never show for the answers given (TRIM without LUKS, the GNOME variant for other desktops) get their defaults. Unattended runs and `--resume` take the defaults below for anything the config leaves out.

- [ ] **Keyboard layout.** Console keymap; the desktop layout follows from it (section 11). Validate against the keymaps installed on the live system.
- [ ] **Disk.** Pick from a list showing path, model, size, transport, current partitions, and any OS found on it.
- [ ] **Disk mode.** The whole disk, erased (`disk_mode=wipe`, the unattended default), or its free space (`free`): the largest unpartitioned space of the disk's GPT gets the install's own 1 GiB ESP and root, and every other partition stays as it was, so another system keeps booting. The installer never resizes a partition; the user shrinks one from its own system first, like Windows' Disk Management. The disk menu shows each disk's largest free space. Before Install, free space needs a GPT, no partitions from an earlier gentooinstall run, and at least 21 GiB in one piece (41 GiB with a desktop): 20 or 40 for the system, 1 for the ESP. Windows gets a boot menu entry (section 16) and the hardware clock in local time (section 11); other systems start from the firmware boot menu, which first-steps.txt says. The question says that Windows with BitLocker asks for its recovery key once Secure Boot is off, which the installer needs.
- [ ] **Windows.** After the disk step, every EFI system partition other than the install's own is mounted read-only once to look for `EFI/Microsoft/Boot/bootmgfw.efi`, in either disk mode, so a Windows on another disk counts too. The answer (its PARTUUID and filesystem UUID, or none) stays in the state. A dry run looks at nothing.
  - [ ] (later) Install into free space next to an existing OS.
  - [ ] (later) Use partitions the user already made.
- [ ] **Root filesystem.** ext4 (default), xfs or btrfs with subvolumes. (later) f2fs.
- [ ] **Encryption.** None (default) or LUKS2 on root. Passphrase typed twice and never echoed, logged or saved.
  - [ ] TRIM through LUKS: on by default. It reveals which blocks are free, which is fine for a laptop. Explain this in the help line.
- [ ] **Swap.** zram (default), swap file, or none.
  - [ ] (later) Swap partition.
  - [ ] (later) Hibernation, through a swap file at least as large as RAM. A swap file inside the root filesystem also works with LUKS.
- [ ] (later) **Separate /home partition.**
- [ ] **Init system.** OpenRC (default) or systemd, with a one-line explanation of each.
- [ ] **Desktop.** KDE Plasma, GNOME, Xfce, Budgie, Cinnamon, the window managers i3, Sway, Hyprland, Niri, MangoWM, dwm and dwl, or none (console only). This choice decides the profile and the stage3. Budgie, Hyprland, Niri and MangoWM come from overlays (section 18); their help text says the overlay is third-party, Gentoo doesn't review it, and the desktop builds from source.
- [ ] **Login screen.** A full desktop offers its own graphical one (SDDM for Plasma, GDM for GNOME, LightDM with lightdm-gtk-greeter for Xfce, Budgie and Cinnamon), the text one, tuigreet, or none. A window manager offers gtkgreet (graphical), tuigreet or none. tuigreet and gtkgreet run on greetd (section 18). None starts from a TTY. Changing the desktop drops a login screen the new one doesn't offer. Hidden without a desktop. `display_manager=auto`, the unattended default, is the desktop's own graphical one, and none for the window managers.
- [ ] **Bootloader.** systemd-boot (default on UEFI), GRUB or Limine.
  - [ ] (later) EFI stub, UKI.
- [ ] **Kernel.** `gentoo-kernel-bin` (default, prebuilt) or `gentoo-kernel` (compiled locally, about an hour or more).
- [ ] **GPU driver.** Chosen automatically from detection. For NVIDIA, ask: proprietary `nvidia-drivers` (default) or `nouveau`.
- [ ] **Networking.** NetworkManager (default), dhcpcd for wired-only machines, or systemd-networkd on systemd.
- [ ] **Keep the current Wi-Fi.** If the live session is on Wi-Fi and NetworkManager is chosen, offer to save that network so the new system connects on first boot. Default yes.
- [ ] **Audio.** PipeWire (default) or none. On OpenRC without a desktop the system gets ALSA only (section 20).
- [ ] **Bluetooth.** On by default when an adapter is detected.
- [ ] **Laptop power management.** power-profiles-daemon (default on laptops), TLP, or none. Never both.
- [ ] (later) **Printing.** CUPS.
- [ ] **Hostname.** Validate as an RFC 1123 label: `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`.
- [ ] **Timezone.** Picked from a menu: the region, then the city. The minimal ISO strips `/usr/share/zoneinfo`, so the list ships with the installer in `lib/timezones.tsv`, made from tzdata's `zone.tab` and `iso3166.tab` (one zone per country or region, with the country's name). UTC is one choice, and Other... types any name, checked for its format only. Section 6 checks the zone exists. Unattended default `UTC`.
- [ ] **Locales.** One or more, plus the system `LANG`. Default `en_US.UTF-8`. The ISO strips `/usr/share/i18n` too, so section 6 checks them against the stage3.
- [ ] **Root account.** Set a password, or lock root. Locking is allowed only when at least one admin user exists.
- [ ] **Users.** One or more. Each has a username, a password (typed twice), an admin yes/no, and a shell (bash, zsh or fish). The shell question says that fish, as a login shell, doesn't read `/etc/profile.env`, so it misses the variables set through `/etc/env.d` (Gentoo bug 545830); the installer adds only the keyboard layout ones (section 18).
- [ ] **Privilege tool.** sudo (default) or doas.
- [ ] **Mirrors.** The Gentoo CDN `https://distfiles.gentoo.org` (default), the fastest https mirrors found by the ISO's `mirrorselect -S`, or a custom `https://` URL. Mirrors that netselect names by an IP address are dropped, since HTTPS to an IP fails; if none is left, the CDN is used.
- [ ] **Binary packages.** On (default) or off. The x86-64-v3 repo is added automatically when the CPU supports it.
- [ ] **Compiler settings.** `COMMON_FLAGS` default `-march=native -O2 -pipe`. MAKEOPTS and parallel emerge jobs are calculated, with an override.
- [ ] **Tune for this machine.** Off by default when binary packages are on. On writes this CPU's `CPU_FLAGS_X86` and narrows `VIDEO_CARDS` to the detected GPUs, which makes some packages build from source. The compile preview shows how many.
- [ ] **Browser.** `firefox-bin` (default), Chromium, or none.
- [ ] **Media keys.** Off by default, and asked only for Sway, Hyprland and Niri, whose default configs call programs nothing else installs for the brightness, player and Print keys (section 18). The help names them and how many packages they build from source, and for Sway and Hyprland says brightnessctl comes from GURU, which Gentoo doesn't review. It says the volume keys work either way, or with `audio=none` that they do nothing either way.
- [ ] **Extra packages.** Picked in fzf from Gentoo's package list: Space marks a package, Enter confirms, and the current ones come first, marked. The search matches package names, exact substrings first by the shortest name. The ISO has neither fzf nor a package tree, so the first use downloads, into the run directory, fzf's static binary from its GitHub release, checked against a SHA-256 pinned in the installer, and `metadata/pkg_desc_index` from Gentoo's `gentoo-mirror/gentoo` repository. Ctrl+T switches to typing atoms, for versions, slots or overlay packages, starting from the ones picked; a failed download and `--no-tui` type them too. Checked in the compile preview (section 9), after the tree is synced.
- [ ] **Extra services.** sshd (default off), fwupd (default on for laptops), zram (follows the swap answer).
- [ ] (later) **Overlays.** GURU and others through `eselect repository`.
- [ ] (later) **Flatpak** with Flathub.
- [ ] **Explain mode.** On or off.

## 4. Review and confirm

- [ ] One screen with every answer, grouped by topic. The disk shows path, model, size and what's on it now.
- [ ] Jump back to any question from the review screen.
- [ ] Run the combination checks (see [validation rules](#combination-rules)) and block the install until they pass.
- [ ] Save the config, without secrets, before anything destructive happens.
- [ ] Final confirmation: the user types the disk name, for example `nvme0n1`. In free space mode it says what stays on the disk and what's added, instead of what gets deleted. `--yes` skips this only when a config file was given.
- [ ] `--dry-run` stops here and prints every command the install would run.

## 5. Disk preparation

- [ ] Resolve the chosen disk to its `/dev/disk/by-id/` path, or its `/dev/disk/by-path/` path when it has no by-id link (a QEMU virtio disk without a serial), and use that from here on, so a replugged USB stick can't shift `/dev/sdX` names onto the wrong disk.
- [ ] Refuse the disk that holds the live medium.
- [ ] If the disk has anything mounted or active from an earlier attempt, show it and offer to release it: `swapoff`, `umount`, `cryptsetup close`.
- [ ] Wipe old signatures with `wipefs --all` on every partition and then the disk. Leftover LUKS, RAID or filesystem headers confuse `blkid` later. Free space mode wipes only its two new partitions.
- [ ] Free space mode: `sfdisk --append` adds the ESP and root to the largest free space that `sfdisk -F` lists, with explicit start sectors, 1 MiB aligned in the disk's own sector size, and `--backup` saves the table sectors it changes to the run directory first. It checks the GPT, the names and the room again and stops before writing if one fails.
- [ ] Partition with an `sfdisk` script, never interactive `fdisk`:
  - [ ] GPT label, 1 MiB alignment.
  - [ ] ESP: 1 GiB, type "EFI System", FAT32, label `ESP`, mounted at `/efi`.
  - [ ] Root: rest of the disk, type "Linux root (x86-64)" per the Discoverable Partitions spec, label `root`.
  - [ ] (later) Swap partition: type "Linux swap", label `swap`, size from the Handbook swap table (Disks chapter).
  - [ ] (later) BIOS: GPT with a 1 MiB BIOS boot partition for GRUB, or MBR with a 1 GiB `/boot`.
  - [ ] (later) Separate `/home`.
- [ ] Wait for device nodes (`udevadm settle`), then look up partition paths with `lsblk`. Never build them by string. `sda1`, `nvme0n1p1` and `mmcblk0p1` all differ.
- [ ] LUKS2 when chosen:
  - [ ] `cryptsetup luksFormat --type luks2` on the root partition, passphrase on stdin.
  - [ ] `cryptsetup open` as `/dev/mapper/root`.
  - [ ] (later) Encrypted swap partition, TPM2 unlock, keyfiles.
- [ ] Make filesystems:
  - [ ] ESP: `mkfs.vfat -F 32 -n ESP`.
  - [ ] ext4: `mkfs.ext4 -L root`.
  - [ ] xfs: `mkfs.xfs -L root`, adding `-c options=/usr/share/xfsprogs/mkfs/lts_6.18.conf` when that file exists, as the Handbook does. Not a newer LTS config: GRUB may not read the features it turns on. Bump it when the Handbook does.
  - [ ] btrfs: `mkfs.btrfs -L root`, then subvolumes `@` (/), `@home`, `@var_log`, `@var_cache` and `@snapshots` (`/.snapshots`). Add `@swap` (`/swap`) when a swap file is chosen, because btrfs can't snapshot a subvolume holding an active swap file.
- [ ] Mount with the options the installed system will use, since `genfstab` copies them into fstab later:
  - [ ] Root at `/mnt/gentoo` with `noatime`. btrfs subvolumes add `compress=zstd` and `nodiscard`, so genfstab can't copy the `discard=async` the kernel turns on for SSDs.
  - [ ] ESP at `/mnt/gentoo/efi` with `umask=0077`.
- [ ] Swap file when chosen, sized like RAM up to 8 GiB:
  - [ ] btrfs: `btrfs filesystem mkswapfile` in `/swap/swapfile`.
  - [ ] ext4 and xfs: allocate `/swapfile`, `chmod 600`, `mkswap`.
  - [ ] `swapon` it.
- [ ] Record the root UUID, and the LUKS UUID if any, for the kernel command line.

## 6. Stage3

- [ ] Pick the variant from init system and desktop: `stage3-amd64-desktop-openrc`, `stage3-amd64-desktop-systemd`, `stage3-amd64-openrc` or `stage3-amd64-systemd`. Desktop stages already include LLVM and `rust-bin`.
- [ ] Read the current file name from the signed pointer `releases/amd64/autobuilds/latest-stage3-amd64-<variant>.txt` on the chosen mirror, and verify that pointer's signature. Never hardcode dated file names.
- [ ] Download the tarball with its `.asc`, `.DIGESTS` and `.sha256` files into `/mnt/gentoo`. Resume partial downloads, retry on failure, show progress.
- [ ] Import the Gentoo release keys from the ISO's `/usr/share/openpgp-keys/gentoo-release.asc` into a temporary `GNUPGHOME`, so the live root keyring stays untouched.
- [ ] Verify the signature with `gpg --verify`, then the SHA512 and BLAKE2B checksums from `.DIGESTS`. On mismatch, delete and download once more. A second mismatch stops the install.
- [ ] Extract: `tar xpf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo`.
- [ ] Copy the live `/etc/resolv.conf` into the target after unpacking, as the Handbook does. No stage3 has one, and `arch-chroot` binds the live file only over an existing one.
- [ ] Keep the tarball until the install finishes. A retry or resume unpacks the same verified tarball again, even after a `desktop` change would pick another variant, so two stage3s never mix.
- [ ] Check the timezone and locales from section 3 against the stage3's `/usr/share/zoneinfo` and `/usr/share/i18n/SUPPORTED`. If one is wrong, ask again, or stop in unattended mode. Nothing has been configured yet, so this costs nothing. Section 11 checks again, for answers changed later in the compile preview or on resume.

## 7. Chroot

- [ ] Run every later step with the ISO's `arch-chroot /mnt/gentoo /bin/bash -c 'source /etc/profile; ...'`, which the Handbook allows on Gentoo media. It mounts `proc`, `sys`, `dev`, `run` and `efivarfs`, binds the live `resolv.conf`, and unmounts them all when the command exits, so the installer needs no mount or unmount code of its own.
- [ ] End each chroot script with `exit $?`. `arch-chroot` runs the script as PID 1 of a new PID namespace, and without the `exit` bash would exec the last command, making it PID 1; `locale-gen` fails as PID 1.
- [ ] Send every command's output to the log.
- [ ] The error menu's "shell" option opens an interactive `arch-chroot /mnt/gentoo`.

## 8. Portage setup

- [ ] Write `GENTOO_MIRRORS` from the mirror answer.
- [ ] Sync with `emerge-webrsync`, which downloads a GPG-verified snapshot.
- [ ] List the news with `eselect news list` into the log, leaving it unread for the user. Show unread titles in the final summary. `eselect news list` exits 1 whenever it listed an item, and a fresh tree always has some, so its status is ignored.
- [ ] Set the profile by name, not by number, since the numbers shift between releases. Check the name exists in `eselect profile list` first. Names in use today:
  - `default/linux/amd64/23.0` and `.../23.0/systemd`
  - `default/linux/amd64/23.0/desktop` and `.../desktop/systemd`
  - `default/linux/amd64/23.0/desktop/plasma` and `.../desktop/plasma/systemd`
  - `default/linux/amd64/23.0/desktop/gnome` and `.../desktop/gnome/systemd`
- [ ] Assert the profile's init system matches the stage3's.
- [ ] Write `/etc/portage/make.conf` in full, with a comment above each line saying why it's there:
  - [ ] `COMMON_FLAGS`, and `CFLAGS`, `CXXFLAGS`, `FCFLAGS`, `FFLAGS` from it.
  - [ ] `RUSTFLAGS="${RUSTFLAGS} -C target-cpu=native"` when `-march=native` is used.
  - [ ] `MAKEOPTS="-jN -lN"` with N = min(CPU threads, RAM in GiB / 2), at least 1. RAM is rounded to the nearest GiB.
  - [ ] `EMERGE_DEFAULT_OPTS="--jobs=J --load-average=L"`. Parallel emerges speed up binary installs a lot.
    - [ ] Binary packages on: J = N, and L = min(2N, RAM in GiB / 2), never below N. Most jobs only unpack, so they go on beside one compile, but a second compile doesn't start where RAM has no room for it.
    - [ ] Binary packages off: every job may compile, so J = max(1, (RAM in GiB / 2) / N) keeps J × N within RAM / 2 GiB, as the Handbook recommends, and L = N.
  - [ ] `FEATURES="${FEATURES} getbinpkg binpkg-request-signature"` when binary packages are on.
  - [ ] `ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"`. Any other license a chosen package needs, such as `nvidia-drivers`, goes per package in `/etc/portage/package.license/`, and the user sees the list.
  - [ ] `USE` with only the flags the answers require, for example `dist-kernel`. Each extra global flag can push packages off the binhost, so prefer per-package flags in `package.use`.
  - [ ] No `GRUB_PLATFORMS`. The amd64 profile's `efi-64 pc` matches the binary GRUB; `efi-64` alone would build GRUB from source.
  - [ ] `L10N` from the chosen locales, in both forms (`zh zh-CN`). Few packages use it. Only with binary packages off: the binary packages are built without it, so with them on it could only cause rebuilds.
- [ ] `VIDEO_CARDS`: the amd64 profile default is already `amdgpu fbdev intel nouveau radeon radeonsi vesa`, and the binhost builds with it. So:
  - [ ] Binary packages on: keep the default. For proprietary NVIDIA, add `nvidia` to it.
  - [ ] Binary packages off, or "tune for this machine" on: write `*/* VIDEO_CARDS: -* <drivers>` to `/etc/portage/package.use/00video_cards` from detection.
- [ ] `CPU_FLAGS_X86`: the amd64 profile default is `mmx mmxext sse sse2`, and changing it makes every package with CPU flags miss the binhost. Write the `cpuid2cpuflags` result to `/etc/portage/package.use/00cpu-flags` only when binary packages are off or "tune for this machine" is on.
- [ ] Binary host in `/etc/portage/binrepos.conf/`. Check what the stage3 already ships there and edit it instead of adding a duplicate repo.
  - [ ] `[gentoo]` → `https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/`, `verify-signature = true`, `location = /var/cache/binhost/gentoo`.
  - [ ] `[gentoo-x86-64-v3]` → `.../23.0/x86-64-v3/` with a higher priority, only when the CPU supports v3. Keep both repos, as the Handbook does.
  - [ ] Swap the host for the chosen mirror.
- [ ] Run `getuto` to set up the binary package keyring.
- [ ] Write `package.use` files for the answers: installkernel flags, systemd-boot flags, `net-wireless/wpa_supplicant dbus` for NetworkManager on non-desktop profiles, PipeWire flags.
- [ ] Use `package.accept_keywords` only when a chosen option needs a testing package, and show which ones. Prefer stable.

## 9. Compile preview

- [ ] Build the complete package list for the chosen setup: the `@world` update, firmware, kernel, tools, desktop, drivers, browser and extras.
- [ ] Run `emerge --pretend --verbose --update --deep --newuse --getbinpkg <list>` (no `--getbinpkg` with binary packages off) and parse every line. `[binary` means a download, `[ebuild` means a local build.
- [ ] Show: N packages from binaries, M built from source, and the source list. Flag the known heavy ones: `www-client/chromium`, `www-client/firefox`, `dev-qt/qtwebengine`, `net-libs/webkit-gtk`, `llvm-core/llvm`, `llvm-core/clang`, `dev-lang/rust`, `app-office/libreoffice`, `sys-devel/gcc`.
- [ ] For each source build, say why when Portage reports it (USE mismatch or no binary available), and name the binary alternative if one exists: `firefox-bin`, `libreoffice-bin`, `rust-bin`, `thunderbird-bin`, `gentoo-kernel-bin`.
- [ ] Let the user go back and change answers, or continue.
- [ ] Report Portage blockers, `REQUIRED_USE` errors and masked packages with Portage's own message. Show any autounmask suggestions and apply them only after the user approves, logging every file written. Never run `--autounmask-write` silently.
- [ ] Report invalid atoms from the extra packages list and let the user fix them here.
- [ ] (later) Time estimate from a table of measured build times, scaled by core count.

## 10. Base system build

- [ ] `emerge --update --deep --newuse --getbinpkg @world`.
- [ ] Install with `--oneshot`, and once that worked, add the packages to the world file with `emerge --noreplace`. A failed run then records nothing, so a resume whose answers drop a package leaves it to depclean. Without `--update` Portage doesn't also record each older installed slot of a named package, which depclean would never remove: after a sync and a retry, the old kernel would stay in the boot menu.
- [ ] Show progress as package N of M, taken from Portage's output.
- [ ] On a build failure, show the failing package, the last 40 lines of its build log, and the log path (`/var/tmp/portage/<category>/<package>/temp/build.log`). Copy the build log into the installer's log directory. Offer retry, shell in the chroot, skip (optional packages only) or abort.

## 11. Time, locale and keyboard

- [ ] Timezone: `ln -sf ../usr/share/zoneinfo/<Region>/<City> /etc/localtime`, and remove the stage3's `/etc/timezone`, which some programs read first.
- [ ] Locales: write `/etc/locale.gen`, run `locale-gen`.
- [ ] System language: `eselect locale set <name>`, plus `/etc/locale.conf` on systemd. Then `env-update`.
- [ ] Console keymap: `keymap=` in `/etc/conf.d/keymaps` on OpenRC, `KEYMAP=` in `/etc/vconsole.conf` on systemd.
- [ ] Desktop keyboard layout in `/etc/X11/xorg.conf.d/00-keyboard.conf`, mapped from the console keymap the way systemd's `kbd-model-map` does, since `localectl` can't run in a chroot.
- [ ] Hardware clock in UTC: `clock="UTC"` in `/etc/conf.d/hwclock` on OpenRC.
  - [ ] With Windows found, the hardware clock keeps local time, as Windows does: `clock="local"` in `/etc/conf.d/hwclock` on OpenRC, `LOCAL` in `/etc/adjtime` on systemd. Otherwise UTC.
- [ ] With LUKS, make sure the initramfs passphrase prompt uses the chosen keymap. Test this in a VM with a non-US layout.

## 12. Firmware and kernel

- [ ] `sys-kernel/linux-firmware` always. It also carries AMD microcode.
- [ ] `sys-firmware/intel-microcode` on Intel CPUs.
- [ ] `sys-firmware/sof-firmware` when an SOF audio DSP was detected.
- [ ] `sys-kernel/installkernel` flags by bootloader:
  - [ ] systemd-boot: `systemd systemd-boot dracut`, plus `sys-apps/systemd boot` (and `cryptsetup` with LUKS) or, on OpenRC, `sys-apps/systemd-utils boot kernel-install`.
  - [ ] GRUB: `grub dracut`.
  - [ ] Limine: `systemd dracut`, plus `sys-apps/systemd-utils kernel-install` on OpenRC; systemd keeps the binary host's flags, which include `kernel-install`. installkernel has no Limine flag, so `/etc/kernel/install.conf.d/limine.conf` sets `layout=bls`: kernels go to the ESP as for systemd-boot, since Limine reads only FAT and ISO 9660. The kernel-install plugin `/etc/kernel/install.d/95-limine.install` rewrites `/efi/limine.conf` from `/efi/loader/entries` on every kernel install and removal, newest kernel first, with `timeout: 3` and `editor_enabled: no`. It writes `limine.conf.new`, flushes it and renames it over `limine.conf`, so a full ESP or a crash never leaves half a config. Limine reads `${` as the start of a macro and stops at boot on a malformed one, so with a `${` in an entry the plugin fails the kernel install and leaves `limine.conf` as it was. `/etc/portage/env/sys-boot/limine` copies Limine's binary to the ESP after its updates (section 16). With another bootloader these files are removed. `sys-boot/limine ~amd64` in `package.accept_keywords`.
  - [ ] (later) UKI: `dracut uki`.
  - [ ] (later) EFI stub: `efistub`, which the Handbook says needs testing keywords.
- [ ] Global `USE="dist-kernel"`, so kernel upgrades rebuild external modules like NVIDIA and regenerate the initramfs.
- [ ] Old kernels: Portage leaves an unmerged kernel in the boot menu, on the 1 GiB ESP (about 40 MB each) or in `/boot`, and keeps its `/lib/modules/<version>` (about 630 MB) on purpose (`UNINSTALL_IGNORE`). `/etc/portage/env/sys-kernel/gentoo-kernel-bin` and `gentoo-kernel` hold a `post_pkg_postrm` that takes each kernel whose `/usr/src/linux-<version>` and `/lib/modules/<version>/build` are gone out of the boot menu, except the running kernel and the newest, and only once that worked deletes its `/lib/modules/<version>`. A kernel without a `/lib/modules/<version>` stays too: Portage keeps a removed kernel's modules, so it is a copy, another system's entry or a kernel built without modules. A kernel kept because it was running goes at the next kernel removal. Nothing happens under `emerge --root`, or when the running kernel has no `/lib/modules/<version>`, as in a live system's chroot: the kernel that last ran here, the known-good fallback, would go.
  - [ ] systemd-boot and Limine: `kernel-install remove <version>` for each entry in `/efi/loader/entries`.
  - [ ] GRUB (`/boot/grub/grub.cfg` exists; the kernel step deletes one left from an earlier bootloader answer, since installkernel's `grub` flag writes it with each kernel): the kernels are installkernel's `/boot/vmlinuz-<version>` on OpenRC, or `/boot/kernel-<version>` through systemd's kernel-install on systemd. It removes `/boot/{vmlinuz,kernel,System.map,config}-<version>` and `initramfs-<version>.img`, with the `.old` copies a same-version reinstall leaves (GRUB lists them too), then runs `grub-mkconfig -o /boot/grub/grub.cfg` once if it removed anything, and only warns if that fails.
- [ ] Kernel command line in `/etc/kernel/cmdline`. Create `/etc/cmdline.d/` and link `/etc/kernel/cmdline` to `/etc/cmdline.d/00-installkernel.conf`, as the Handbook does for systemd-boot.
  - [ ] `root=UUID=<filesystem uuid>`, plus `rd.luks.uuid=<luks uuid>` with LUKS. dracut names the mapping `luks-<uuid>`, so `/dev/mapper/root` wouldn't exist at boot.
  - [ ] `rootflags=subvol=@` on btrfs.
  - [ ] TRIM through LUKS when it's on: `rd.luks.allow-discards=<luks uuid>` on OpenRC, whose dracut unlocker ignores `rd.luks.options`, and `rd.luks.options=discard` on systemd.
  - [ ] (later) `resume=` and `resume_offset=` for hibernation to the swap file.
  - [ ] No `nvidia_drm.modeset=1`: every NVIDIA driver the installer picks turns it on already, 580 through `/etc/modprobe.d/nvidia.conf` and 595 and newer by default.
  - [ ] `rw`.
  - [ ] (later) `quiet` as an option.
- [ ] dracut config in `/etc/dracut.conf.d/gentooinstall.conf`: host-only, plus the `crypt` and `btrfs` modules when needed, and the console keymap.
- [ ] Install `gentoo-kernel-bin` or `gentoo-kernel`.
- [ ] After `world`, which may have installed the kernel before `cryptsetup`, `btrfs-progs` or the firmware, rebuild the initramfs with `emerge --config =<package>-<version>` for each installed `gentoo-kernel` and `gentoo-kernel-bin`: every one is in the boot menu, and with two slots installed (an LTS kernel in `packages`, or a newer one after a sync and a retry) `emerge --config` refuses a name without a version.
- [ ] Check that the kernel and initramfs landed where the bootloader looks: the ESP for systemd-boot, `/boot` for GRUB, and for Limine the files the first entry of `/efi/limine.conf` names. With LUKS, check with `lsinitrd` that the initramfs can unlock the disk (`cryptsetup` on OpenRC, `systemd-cryptsetup` on systemd). Stop loudly if not.
- [ ] (later) `gentoo-sources` with manual config or `modprobed-db`.
- [ ] (later) Module signing and Secure Boot keys for `gentoo-kernel`. `gentoo-kernel-bin` already comes signed.

## 13. System configuration

- [ ] Write `/etc/fstab` with the ISO's `genfstab -U -f /mnt/gentoo /mnt/gentoo`, replacing the stage3's template. `-f` keeps out the live system's own swap on other disks. Run it from the live system, outside `arch-chroot`. It copies the mount options from section 5, including btrfs `subvol=` and the swap file.
- [ ] Check the result: root, ESP, every btrfs subvolume and the swap file are present, entries use `UUID=`, the only swap line is the install's own swap file, and no line has `discard`. TRIM runs on a schedule (section 15). btrfs lines get `nodiscard`, which btrfs never reports in its mount options.
- [ ] Hostname in `/etc/hostname`. On OpenRC also in `/etc/conf.d/hostname`, where the stage3 has `localhost`: NetworkManager on Gentoo sets the hostname from that file at boot.
- [ ] `/etc/hosts` with `127.0.0.1` and `::1` lines naming the host. OpenRC requires the hostname there.
- [ ] `/etc/machine-id` before the package install, since kernel-install names the boot entries after it. That covers what `systemd-machine-id-setup` and `dbus-uuidgen --ensure` would do.
- [ ] systemd:
  - [ ] No `systemd-firstboot`: the hostname, keymap, timezone and locale it would set are written by this section and section 11.
  - [ ] `systemctl preset-all --preset-mode=enable-only`.
- [ ] Root password through `chpasswd` on stdin, or `passwd -l root` when the user chose to lock it.

## 14. Networking

- [ ] NetworkManager (default):
  - [ ] Global `USE="networkmanager"`.
  - [ ] `net-wireless/wpa_supplicant dbus` in `package.use` on non-desktop profiles.
  - [ ] Install `net-misc/networkmanager`.
  - [ ] Enable it: `rc-update add NetworkManager default` or `systemctl enable NetworkManager`.
- [ ] Saved Wi-Fi: write `/etc/NetworkManager/system-connections/<name>.nmconnection` with mode 600, holding the SSID and key. They come from section 2, or from the live NetworkManager or `wpa_supplicant` config if the user connected before starting the installer. The key never goes to the log.
- [ ] dhcpcd option: install `net-misc/dhcpcd`, enable the service.
- [ ] systemd-networkd option: a `.network` file matching `en*` with DHCP, `systemctl enable systemd-networkd`, and systemd-resolved with `/etc/resolv.conf` linked to its stub.
- [ ] Enable exactly one network manager. Disable any other that a profile or package enabled.
- [ ] Install `net-wireless/iw` and `net-wireless/wpa_supplicant` for Wi-Fi debugging.
- [ ] (later) iwd as the NetworkManager backend.
- [ ] (later) Static IP.

## 15. System tools

- [ ] Logger: `app-admin/sysklogd` with `rc-update add sysklogd default` on OpenRC. systemd uses journald.
- [ ] Cron: `sys-process/cronie` with `rc-update add cronie default` on OpenRC. systemd uses timers.
- [ ] Time sync: `net-misc/chrony` with `rc-update add chronyd default` on OpenRC, `systemctl enable systemd-timesyncd` on systemd.
- [ ] Filesystem tools: `sys-fs/dosfstools` always, plus `sys-fs/e2fsprogs`, `sys-fs/xfsprogs` or `sys-fs/btrfs-progs`, and `sys-fs/cryptsetup` with LUKS.
- [ ] `sys-block/io-scheduler-udev-rules`.
- [ ] `app-shells/bash-completion`.
- [ ] `app-portage/gentoolkit` for `equery` and `eclean`.
- [ ] `sys-apps/pciutils` and `sys-apps/usbutils` for troubleshooting.
- [ ] `app-admin/sudo` or `app-admin/doas`.
- [ ] TRIM on SSDs: `systemctl enable fstrim.timer` on systemd, a weekly `fstrim --all` cron job on OpenRC.
- [ ] zram when chosen: `sys-block/zram-init` on OpenRC, `sys-apps/zram-generator` on systemd. Size half of RAM, zstd compression.
- [ ] A swap file on btrfs with OpenRC: `rc_before="!localmount"` and `rc_need="localmount"` in `/etc/conf.d/swap`, since the file is on the `@swap` subvolume that `localmount` mounts, and the swap service otherwise runs first.
- [ ] sshd when chosen: enable the service, keep root login off.
- [ ] (later) Optional extras: `app-portage/eix`, `sys-apps/plocate`, vim or neovim, git.

## 16. Bootloader

- [ ] systemd-boot:
  - [ ] `bootctl install` with the ESP at `/efi`.
  - [ ] `loader.conf`: a short timeout and `editor no`, so nobody can edit the kernel command line at boot to get a root shell. No `default` line: the newest entry boots.
  - [ ] Check `bootctl list` shows an entry for the installed kernel. If not, rerun section 12's `emerge --config` and check again.
- [ ] GRUB:
  - [ ] `grub-install --target=x86_64-efi --efi-directory=/efi`. The target is needed because the profile installs the `pc` platform too.
  - [ ] `grub-mkconfig -o /boot/grub/grub.cfg`.
  - [ ] The `grub` flag on installkernel regenerates the config on kernel updates, and section 12's cleanup hook after it removes an old kernel.
  - [ ] With Windows found, `/etc/grub.d/35_windows` adds an entry that chainloads `/EFI/Microsoft/Boot/bootmgfw.efi` from Windows' ESP, found by its filesystem UUID. No os-prober.
- [ ] Windows in the other menus: Limine's plugin (section 12) adds an `efi` entry with `path: guid(<Windows ESP PARTUUID>):/EFI/Microsoft/Boot/bootmgfw.efi`. systemd-boot lists Windows only from its own ESP, so `EFI/Microsoft` is copied there from Windows' ESP once; if a Windows update stops that copy from starting, the firmware boot menu still starts Windows. Through any of these menus a BitLocker Windows asks for its recovery key, since the boot path it measured changed, so first-steps.txt says to start it from the firmware boot menu then.
  - [ ] (later) BIOS: `grub-install --target=i386-pc /dev/<disk>`.
- [ ] Limine:
  - [ ] Copy `/usr/share/limine/BOOTX64.EFI` to `\EFI\limine\BOOTX64.EFI` and the fallback path. Both read `/limine.conf` at the root of the ESP, which section 12's plugin writes, and `boot():` in it names the ESP.
  - [ ] Check the first entry of `limine.conf` names a kernel and initramfs on the ESP. If not, rerun section 12's `emerge --config` and check again.
  - [ ] The ebuild never touches the ESP, so the kernel step's `/etc/portage/env/sys-boot/limine` does: after each install of `sys-boot/limine` its `post_pkg_postinst` copies the new binary beside each ESP copy, flushes it and renames it over the copy. It replaces the fallback only while that matches `\EFI\limine\BOOTX64.EFI`, so another loader there is kept, and it does nothing before the first copy exists. A failed copy keeps the old loader whole and names the copy to redo by hand.
- [ ] If the bootloader install reports read-only EFI variables, remount with `mount -o remount,rw,nosuid,nodev,noexec --types efivarfs efivarfs /sys/firmware/efi/efivars` and retry, as the Handbook's debugging notes say.
- [ ] Create the firmware boot entry with `efibootmgr --create --disk <disk> --part <ESP's number> --loader <loader> --label <label>` from the live system (1 on a wiped disk; the disk step saves it), unless an entry names the ESP's PARTUUID and the loader already. In `arch-chroot`'s PID namespace systemd sees a container, so `bootctl install` skips EFI variables, and `--variables=yes` writes an entry without the ESP's partition (`HD(0,GPT,00000000-...)`). `grub-install` registers its own entry, so for GRUB this only fills in when it didn't. Read-only EFI variables get the same remount and retry as the bootloader install.
- [ ] Check `efibootmgr` lists the new entry first in `BootOrder`.
- [ ] Make sure a fallback `\EFI\BOOT\BOOTX64.EFI` exists, because some laptops forget NVRAM boot entries. `bootctl install` writes it. GRUB needs a second `grub-install --removable`. Limine gets a second copy of its binary. The ESP is always the install's own, also in free space mode, so this never replaces another system's fallback.
- [ ] (later) UKI and EFI stub booting.
- [ ] (later) Secure Boot through shim and MOK, or through the user's own keys.

## 17. Users and privileges

- [ ] Validate usernames against `^[a-z_][a-z0-9_-]{0,31}$`, and reject names of existing system accounts.
- [ ] Create each user with `useradd -m -G <groups> -s <shell> <name>`. Groups: `users`, `audio`, `video`, `usb`, plus `wheel` for admins and `lp` with printing. Add only groups that exist.
- [ ] Set passwords through `chpasswd` on stdin. Warn on short passwords (the Handbook suggests 16+ characters) without blocking, when they're typed or loaded from the secrets file.
- [ ] sudo: `/etc/sudoers.d/wheel` containing `%wheel ALL=(ALL:ALL) ALL`, mode 0440, checked with `visudo -cf` before it's put in place.
- [ ] doas: `/etc/doas.conf` with `permit :wheel` (add `persist` only if doas was built with it), owned by root, mode 0600.
- [ ] Install zsh or fish when a user picked one.
- [ ] Refuse to lock root unless at least one admin user exists.
- [ ] (later) Autologin.

## 18. Desktop

- [ ] KDE Plasma: `kde-plasma/plasma-meta`, `kde-apps/konsole`, `kde-apps/dolphin`, SDDM.
- [ ] GNOME: `gnome-base/gnome-light` (minimal, default) or `gnome-base/gnome` (full), GDM.
- [ ] Every other desktop uses the `desktop` profile (section 8). Xfce, Budgie and Cinnamon get LightDM (`x11-misc/lightdm`, `x11-misc/lightdm-gtk-greeter`):
  - [ ] Xfce: `xfce-base/xfce4-meta`, plus `gnome-extra/nm-applet` with NetworkManager.
  - [ ] Cinnamon: `gnome-extra/cinnamon` and `x11-terms/gnome-terminal`, the terminal it opens. On OpenRC `net-libs/webkit-gtk keyring`, `gnome-base/gvfs gnome-online-accounts keyring`, and `gstreamer` on `media-video/pipewire` and `sys-apps/xdg-desktop-portal`: the flags of the binary host's only OpenRC builds, which saves 3 source builds and adds no package. Without keyring webkit-gtk compiles for hours.
  - [ ] Budgie 10.10 (Wayland, on labwc): `budgie-base/budgie-meta` and `x11-terms/gnome-terminal` from SarahMiaOverlay, with `*/*::SarahMiaOverlay`, `gui-wm/labwc` and `dev-cpp/toml11` at `~amd64` and the `vala` flags its dependencies need. 10.9.3, the stable one, doesn't build against current libpeas. Its labwc bridge takes the keyboard layout from systemd-localed, which OpenRC lacks, and then from `/etc/default/keyboard` (`XKBLAYOUT` and the like), which the desktop step writes from the locale step's X layout.
- [ ] Window managers start from the console or a greetd login screen, with the programs their shipped default config launches, so they work on first login:
  - [ ] i3: `x11-wm/i3`, `x11-terms/xterm` (for `i3-sensible-terminal`), `x11-misc/dmenu`, `x11-misc/i3status`, `x11-misc/i3lock`, `x11-misc/xss-lock`, `x11-misc/dex` (it runs the XDG autostart files), plus `gnome-extra/nm-applet` with NetworkManager.
  - [ ] dwm: `x11-wm/dwm`, `x11-terms/st`, `x11-misc/dmenu`. dwl: `gui-wm/dwl` (`~amd64`), `gui-apps/foot`, `gui-apps/wmenu`. Both build their default savedconfig; first-steps.txt says how to change it and rebuild.
  - [ ] Sway: `gui-wm/sway`, `gui-apps/foot`, `gui-apps/wmenu`; its bar is built in. `gui-wm/sway wallpapers` and `gui-apps/swaybg gdk-pixbuf`: the default config sets a wallpaper only that flag installs, and without it every start shows "There are errors in your config file". Two small source builds.
  - [ ] Hyprland: `gui-wm/hyprland`, `x11-terms/kitty`, `gui-apps/hyprlauncher` from hyproverlay, with `*/*::hyproverlay` and `dev-cpp/sdbus-c++` at `~amd64`, and `media-libs/libheif gdk-pixbuf`, the binary host's flags. Its default config's file manager, Dolphin, is left out: 77 more packages (Qt 6 and KDE Frameworks, about 120 MB of binary packages, hours of compiling without them) for one key. first-steps.txt says so, and how to install it or pick another.
  - [ ] Niri: `gui-wm/niri` (with `screencast`), `x11-terms/alacritty`, `gui-apps/fuzzel`, `gui-apps/waybar`, `gui-apps/swaylock`; niri and fuzzel from GURU at `~amd64`.
  - [ ] MangoWM: `gui-wm/mangowm`, `gui-apps/foot`, `x11-misc/rofi`; mangowm and `gui-libs/scenefx` from GURU at `~amd64`.
  - [ ] Media keys, only with `media_keys=yes`: the programs the brightness, player and Print keys of the default config call. Sway gets `app-misc/brightnessctl`, `media-sound/playerctl` and `gui-apps/grim` (3 source builds); Hyprland and Niri get brightnessctl and playerctl (2). The volume keys need nothing more with `audio=pipewire`: they call `pactl` (libpulse) or `wpctl` (WirePlumber). brightnessctl is GURU's, at `~amd64`, with `udev`: on OpenRC its udev rule lets the `video` group set the brightness, and on systemd the profile's `systemd` flag makes it use logind; with neither it would be setuid root. i3's config calls only `pactl`, and MangoWM, dwm and dwl bind no media keys, so they don't get the question.
  - [ ] X window managers get `x11-base/xorg-server` and `x11-apps/xinit` (so do Xfce and Cinnamon). Wayland compositors get the portal backends their portals.conf names: `xdg-desktop-portal-wlr` (Sway, dwl, MangoWM), `xdg-desktop-portal-hyprland` (Hyprland) or `xdg-desktop-portal-gnome` (Niri), each with `xdg-desktop-portal-gtk` for the file chooser. elogind (OpenRC) or logind gives them the seat.
  - [ ] Started from the console, they get from the installer what a login screen's session would give them:
    - [ ] The keyboard layout. They ignore `xorg.conf.d`, so each gets the locale step's X layout (section 13's mapping, read through `locale_xkb`) its own way: Sway, dwl and Niri through libxkbcommon's `XKB_DEFAULT_LAYOUT`, `_MODEL`, `_VARIANT` and `_OPTIONS` in `/etc/env.d/90xkb`, and the same in `/etc/fish/conf.d/90xkb.fish` for a fish login shell, which doesn't read `/etc/profile.env` (Niri asks systemd-localed first, which has the same on systemd); MangoWM through the `xkb_rules_*` lines of `/etc/mango/config.conf`; Hyprland through `/etc/xdg/hypr/hyprland.lua`, which it reads while the user has no config of their own: it runs `/usr/share/hypr/hyprland.lua`, Hyprland's example, then sets the layout, and keeps the example's first-run warning and welcome. Both shipped configs set `us`.
    - [ ] What xdg-desktop-portal needs to serve them. Hyprland, Niri (`--session`) and MangoWM export their session to it themselves. Sway gets `/etc/sway/config.d/50-gentooinstall.conf`, and dwl's start command runs it through `dwl -s`: `dbus-update-activation-environment --systemd` with `WAYLAND_DISPLAY` and `XDG_CURRENT_DESKTOP` (`sway`, or `wlroots` for dwl's `wlroots-portals.conf`). Niri's file chooser is GTK's through `/etc/xdg-desktop-portal/niri-portals.conf`, since GNOME's needs Nautilus.
  - [ ] first-steps.txt and the final summary give the exact start command. On systemd the login starts the D-Bus session bus and PipeWire; on OpenRC the command wraps the window manager in `dbus-run-session` and starts `gentoo-pipewire-launcher` first, since only desktops read PipeWire's XDG autostart file. i3 is the exception: its config's `dex` reads it.
- [ ] Login screens on greetd: `gui-libs/greetd`, built from source (the desktop stage3 has Rust), with tuigreet (`gui-apps/tuigreet`) on the console, or gtkgreet (`gui-apps/gtkgreet`, `~amd64`) shown in Sway (`gui-wm/sway`). `/etc/greetd/config.toml` runs the greeter on VT 7, display-manager-init's, as the `greetd` user. After a login greetd runs `/usr/local/bin/start-desktop`, which holds the command first-steps.txt gives for a start from the console, so the session gets the same D-Bus and PipeWire setup. gtkgreet's Sway gets the locale step's X layout in `/etc/greetd/sway-config`, since the password is typed there.
- [ ] Overlays, only for the desktop that needs one, plus GURU for brightnessctl when Sway or Hyprland has media keys on: a plain `/etc/portage/repos.conf/<name>.conf` with git sync (`guru` from `https://github.com/gentoo-mirror/guru.git`, `hyproverlay`, `SarahMiaOverlay`, the URLs `eselect repository` uses). The stage3 has no git, so the live system's `git clone --depth 1` makes the first copy; `dev-vcs/git` gets installed for later syncs. Changing the answer removes the overlay again. The compile preview says how many packages come from an overlay, which Gentoo doesn't review, and lists them right after the heavy builds.
- [ ] OpenRC plumbing:
  - [ ] `rc-update add dbus default`.
  - [ ] `rc-update add elogind boot`.
  - [ ] `gui-libs/display-manager-init`, `DISPLAYMANAGER="sddm"`, `"gdm"`, `"lightdm"` or `"greetd"` in `/etc/conf.d/display-manager`, then `rc-update add display-manager default`.
- [ ] systemd: `systemctl enable sddm`, `gdm`, `lightdm` or `greetd`.
- [ ] Fonts: `media-fonts/noto`, `media-fonts/noto-emoji`, `media-fonts/dejavu`. `media-fonts/noto-cjk` as an option.
- [ ] Check in the VM tests that XDG portals work: file pickers and screen sharing. Add the portal backend explicitly if the desktop meta package doesn't pull it in.
- [ ] Browser: `www-client/firefox-bin`, `www-client/chromium`, or none.
- [ ] Hardware video decoding: `media-libs/libva-intel-media-driver` on Intel. Check that Mesa's VA-API is enabled on AMD.

## 19. Graphics drivers

- [ ] `VIDEO_CARDS` from detection, using the Handbook's values:
  - [ ] Intel: `intel`.
  - [ ] AMD (Sea Islands and newer): `amdgpu radeonsi`.
  - [ ] NVIDIA: `nvidia`, or `nouveau` if chosen. Turing and newer get the current driver. Maxwell to Volta get the 580 series, through `>=x11-drivers/nvidia-drivers-581` in `package.mask`, since newer drivers build only the open modules, which need Turing. Kepler and older have no driver that builds against the current kernel, so they fall back to `nouveau` with a warning.
  - [ ] QEMU/KVM: `virgl`.
  - [ ] VMware, and VirtualBox's VMSVGA (PCI vendor `0x15ad`): `vmware`.
  - [ ] Hybrid laptops: both values.
- [ ] Proprietary NVIDIA:
  - [ ] `x11-drivers/nvidia-drivers` with its license accepted per package.
  - [ ] The NVIDIA wiki page's `*/* nvidia vdpau nvenc` USE line (the Handbook lists none), only when tuning or with binary packages off: with binary packages it would rebuild ffmpeg from source.
  - [ ] The kernel module builds locally against the installed kernel. The compile preview shows this.
- [ ] Check Vulkan works on real hardware with `vulkaninfo`.
- [ ] (later) PRIME render offload setup on hybrid laptops.
- [ ] (later) Pre-GCN AMD (`radeon`) and legacy NVIDIA drivers.

## 20. Audio, Bluetooth and laptop hardware

- [ ] PipeWire: `media-video/pipewire` with the `sound-server` flag, plus `media-video/wireplumber`.
  - [ ] OpenRC with a desktop: PipeWire's own XDG autostart file starts it with each desktop session. OpenRC has had user services since 0.60, but the installer doesn't use them for PipeWire.
  - [ ] OpenRC without a desktop: ALSA only, with no PipeWire, since nothing would start it. Volume through `alsamixer`. `rc-update add alsasound boot` saves the mixer levels at shutdown and restores them at boot.
  - [ ] systemd: `systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service`.
- [ ] `media-sound/alsa-utils` for `alsamixer`.
- [ ] Bluetooth: `net-wireless/bluez`, enable the `bluetooth` service.
- [ ] Power management:
  - [ ] power-profiles-daemon: install, enable the service.
  - [ ] TLP: install `sys-power/tlp`, enable it and `tlp-pd`, which serves the power profiles desktops show, and make sure power-profiles-daemon is not installed. Without NetworkManager, build it with `-rdw`, which would pull NetworkManager in. On systemd, mask `systemd-rfkill.service` and `systemd-rfkill.socket`, as TLP's docs say, since they fight TLP's radio switching.
- [ ] `sys-power/thermald` on Intel laptops, as an option.
- [ ] Suspend works through logind or elogind. Test it on the real laptop; VMs can't test it well.
- [ ] (later) Hibernation: a swap file at least the size of RAM, `resume=` and `resume_offset=` on the command line, and the dracut `resume` module. Not with zram alone.
- [ ] Firmware updates: `sys-apps/fwupd` with its service.
- [ ] (later) Fingerprint readers (fprintd), battery charge thresholds, vendor-specific tweaks (ThinkPad, ASUS, Framework).
- [ ] (later) Printing: `net-print/cups`, its service, `lp` group.

## 21. Extra packages and services

- [ ] Install the user's extra atoms after the desktop, with the same failure handling as section 10.
- [ ] Enable the user's extra services, after checking the init script or unit file exists.
- [ ] (later) A user-supplied post-install script, run inside the chroot.

## 22. Finish

- [ ] `emerge --pretend --depclean` first and log the result. Run the real depclean only if it removes nothing the user chose.
- [ ] `eclean-dist` and `eclean-pkg` to free space. Default on.
- [ ] Delete the stage3 tarball and its `.asc`, `.DIGESTS` and `.sha256` files.
- [ ] Copy into `/var/log/gentooinstall/` on the new system:
  - [ ] The full log, secrets removed.
  - [ ] The config file, no secrets.
  - [ ] The replay script.
  - [ ] Build logs of any failed packages.
  - [ ] A list of installed packages, marked binary or source.
- [ ] Put a short first-steps file in each user's home: how to update (`emerge -avuDN @world`, and that `emerge --depclean` also removes old kernels and their modules), read news, find the install log, change USE flags.
- [ ] Final summary: duration, binary vs source package counts, warnings, skipped steps, unread news titles.
- [ ] Offer: reboot, chroot into the new system, or exit to the live shell.
- [ ] Clean unmount: `swapoff` the swap file, `umount -R /mnt/gentoo`, `cryptsetup close root`, `sync`. When something still uses the target, skip the LUKS close, warn with how to find what holds it (`fuser -vm`) and the commands to finish by hand, and still reboot or exit; a reboot unmounts it safely.
- [ ] Remind the user to remove the USB stick before the next boot.
- [ ] (later) A one-shot first-boot check that reports whether the display manager, network and audio came up, then removes itself.

---

## Cross-cutting requirements

### Resume

- [ ] Split the install into named steps, one per section above. Each step either completes or is safe to run again.
- [ ] Save state after each step. Before the root filesystem exists, keep it in `/tmp`. After, keep it in `/mnt/gentoo/var/lib/gentooinstall/state`, so it survives a reboot of the live USB.
- [ ] `--resume`: find a disk with a state file, ask for the LUKS passphrase if needed, remount the target filesystems, `swapon` the swap file, and continue at the first unfinished step.
- [ ] Disk, partition and filesystem answers are locked once section 5 starts. Other answers can change on resume until the first step that acts on them has run, for example dropping a package that keeps failing before the package install finishes. A change to an answer a finished step used stops with a message naming both. When the compile preview already ran, it runs again for the new answers.
- [ ] Never repeat a destructive step on resume.
- [ ] Partial downloads resume instead of starting over.

### Errors and safety

- [ ] Treat every failed command, failed pipe and unset variable as an error.
- [ ] On error, show the step, the command, its exit code and the last lines of the log. Offer retry, shell (live system or chroot), skip (optional steps only) or abort.
- [ ] Ctrl+C asks for confirmation, then leaves the install in a resumable state.
- [ ] Destructive commands (`wipefs`, `sfdisk`, `mkfs.*`, `cryptsetup luksFormat`) run only after the typed confirmation, only once, and only against the chosen disk's by-id path (by-path when it has none).
- [ ] `--dry-run` runs nothing destructive and nothing in a chroot. It prints every command.
- [ ] Secrets (LUKS passphrase, passwords, Wi-Fi key) never reach the log, the config file, the replay script or command-line arguments, where `ps` would show them. Pass them on stdin. The log doesn't record their length either.
- [ ] Distinct exit codes: success, aborted by user, failed.

### Logging and explain mode

- [ ] Log every command with a timestamp and its full output.
- [ ] Explain mode prints a short paragraph and the Handbook link before each step, and each command as it runs.
- [ ] Write a replay script: every command in order, with comments, secrets replaced by placeholders. A person can read it top to bottom and follow the install by hand.

### Config file

Format: plain `key=value` lines, the same shape as `/etc/os-release`. Bash reads it with `IFS== read -r`, so it needs nothing beyond the ISO.

```ini
# gentooinstall config
format=1
keymap=us
disk=/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456
filesystem=btrfs
encryption=luks2
swap=zram
init=openrc
desktop=plasma
bootloader=systemd-boot
kernel=gentoo-kernel-bin
hostname=laptop
timezone=Europe/Brussels
locales=en_US.UTF-8 de_DE.UTF-8
lang=en_US.UTF-8
users=larry
user.larry.admin=yes
user.larry.shell=bash
packages=app-editors/neovim dev-vcs/git
```

- [ ] Keys are a fixed list. An unknown key is an error, which catches typos.
- [ ] List values are space-separated. Per-user settings use `user.<name>.<field>`.
- [ ] Blank lines and `#` comments are allowed. No quoting, no variable expansion, no line continuation.
- [ ] Never `source` or `eval` the file, since a shared config would then run code as root.
- [ ] Save every answer except secrets.
- [ ] `--config FILE` fills in answers. With `--yes`, a complete config runs unattended. A step that fails then logs the failure, prints where the log is and exits 1, resumable, instead of waiting at the error menu.
- [ ] Secrets come from prompts, or from a separate credentials file in the same format (`luks_passphrase`, `root_password`, `user.<name>.password`, `wifi_psk`). Refuse it unless it's owned by root with mode 600.
- [ ] Validate with the same rules as interactive input and report every error at once, not one per run.
- [ ] `format` is the format version, so later releases can read old files.

### Interface

- [ ] Menus with `dialog`, which the minimal ISO ships as a dependency of its own `net-setup`, in white text on black from `lib/dialogrc`. The first screen lists the keys: the arrows move, Space selects in a list, Enter confirms, Tab switches buttons and Esc goes back. Enter on a list with nothing selected says to press Space first. Plain numbered prompts when `--no-tui` is given, or when stdin, stdout or stderr isn't a terminal.
- [ ] Every screen has help text and a back option and shows the default.
- [ ] Works on an 80x24 text console, a serial console and over SSH, so you can drive a laptop install from another machine.
- [ ] Never carry meaning by color alone, and work with color turned off.
- [ ] Progress for long steps: download percentage, package N of M.

### Combination rules

Checked on the review screen. The install can't start until they pass.

- [ ] LUKS requires systemd-boot or Limine in v1, so the kernel and initramfs sit on the unencrypted ESP.
- [ ] A desktop requires a disk of at least 40 GiB.
- [ ] systemd-networkd requires systemd.
- [ ] Locking root requires at least one admin user.
- [ ] A display manager requires a desktop.
- [ ] A desktop without a network manager gets a warning.
- [ ] Secure Boot on blocks the install in v1, with instructions.
- [ ] (later) BIOS requires GRUB.
- [ ] (later) Dual boot requires GRUB with os-prober.

### Testing

- [ ] Unit tests with bats-core for the pure logic: MAKEOPTS calculation, swap size, partition path lookup, validators (hostname, username, timezone format, locale format, keymap), the `emerge --pretend` parser against saved outputs, the config parser, the kernel command line builder. bats runs on the development machine only, never on the ISO.
- [ ] shellcheck on every file, with no warnings left unexplained.
- [ ] VM matrix in QEMU with OVMF, booting the current Gentoo minimal ISO: OpenRC and systemd × ext4, btrfs and btrfs+LUKS × Plasma, GNOME and console only. OpenRC runs get tested first, since it's the default.
- [ ] Measure peak RAM and final disk use per profile, and replace the provisional limits in section 2.
- [ ] Check that the release spec's tools are still on each new minimal ISO. The package list lives in `releases/specs/amd64/installcd-stage1.spec` in the releng repo.
- [ ] Disk naming in VMs: virtio (`vda`), NVMe (`nvme0n1`) and SATA (`sda`).
- [ ] Interrupt tests: kill the installer at each step boundary and in the middle of steps, then `--resume`.
- [ ] Failure tests: a fake failing emerge, a network drop during the stage3 download, a bad checksum.
- [ ] Boot test: each VM reaches the login screen with networking up.
- [ ] Real laptop test only after the VM matrix passes, with a backup taken first.
- [ ] Record the last tested date and stage3 date in the README.

### Maintenance

- [ ] No hardcoded dated file names, profile numbers or package versions.
- [ ] The profile version (`23.0`) lives in one place. Warn when the expected profile is missing, which means Gentoo moved to a new one.
- [ ] Re-run the VM matrix before each release. Stage3 tarballs and the package tree change weekly.

---

## Distribution

- [ ] Bash only. The installer runs with what the minimal ISO ships and installs nothing on the live system.
- [ ] Entry point `gentooinstall`, with the rest split into files under `lib/` that it sources.
- [ ] Get it onto the ISO with `git clone`, since git ships on the minimal ISO, or by downloading a release tarball with `curl`.
- [ ] `set -Eeuo pipefail` everywhere, with an `ERR` trap feeding the error menu.

## v1 scope

- Runs from the Gentoo minimal ISO only.
- UEFI x86_64 laptop, GPT, whole-disk wipe.
- ext4, xfs or btrfs, with optional LUKS2 on root.
- zram or a swap file.
- OpenRC by default, systemd as an option.
- `gentoo-kernel-bin` or `gentoo-kernel`, dracut initramfs.
- systemd-boot, GRUB or Limine.
- Binary host with x86-64-v3, plus the compile preview (counts and package list).
- NetworkManager, with the live Wi-Fi network carried over.
- KDE Plasma, GNOME, Xfce, Budgie, Cinnamon, i3, Sway, Hyprland, Niri, MangoWM, dwm, dwl or console only.
- PipeWire, Bluetooth, power-profiles-daemon or TLP, firmware and microcode, NVIDIA/AMD/Intel drivers.
- Users with sudo or doas.
- Resume, logging, config save and load, explain mode, dry run.

Everything tagged (later) waits until v1 installs cleanly across the VM matrix and on a real laptop.

## Decisions

Settled 2026-10-30.

1. **Language: bash.** Matches the Handbook commands one for one, makes the replay script trivial, and needs nothing beyond the ISO.
2. **Live ISO: Gentoo minimal only.** Its package list (releng `installcd-stage1.spec`) includes `dialog`, `git`, `curl`, `arch-chroot`, `genfstab`, `cpuid2cpuflags`, `mirrorselect`, `cryptsetup`, `btrfs-progs`, `xfsprogs`, `dosfstools`, `efibootmgr`, `pciutils`, `chrony`, `wpa_supplicant` and `dhcpcd`. It strips `/usr/share/zoneinfo` and `/usr/share/i18n`, so timezone and locale checks wait for the stage3.
3. **Init: OpenRC by default**, systemd as an option.
4. **Binhost first.** With binary packages on, leave `CPU_FLAGS_X86` and `VIDEO_CARDS` at the profile defaults the binhost was built with. Machine-specific values are opt-in through "tune for this machine". `L10N` follows the chosen locales unless the VM preview shows it causing source builds.
5. **Swap: zram by default**, swap file as the alternative. Swap partitions come later. So does hibernation, which will use the swap file so it also works with LUKS.
6. **Config file: `key=value` lines**, parsed and never sourced. See [config file](#config-file).
7. **Minimums: 2 GiB RAM, 20 GiB disk, 40 GiB disk with a desktop.** Provisional. The VM tests measure real use and replace them.
