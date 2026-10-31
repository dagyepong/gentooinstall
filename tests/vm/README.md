# VM tests

End-to-end test: install Gentoo with `gentooinstall` in a QEMU VM booted from the official minimal ISO, reboot into the installed disk, log in and check the result. Everything runs in a Docker container as your own user, so the host needs Docker, `/dev/kvm` and git, but no root.

```sh
tests/vm/run.sh tests/vm/configs/smoke.conf
```

The secrets file defaults to the config's name with `.secrets` (`configs/smoke.secrets`); pass another as the second argument. The last line is `PASS` or `FAIL`, and the exit status is 0 only on PASS. The console-only smoke config takes about 8 minutes end to end (6 of them installing) on a fast connection. Desktops download several GB more.

## What a run does

1. `run.sh` snapshots the repo (tracked and untracked files, minus ignored ones like `.tools/`, the way a clone would have them), copies the config, secrets and `guest.sh` next to it, builds the `gi-vm` image from `Dockerfile` and starts `drive.py` in it.
2. `drive.py` reads `latest-install-amd64-minimal.txt`, downloads that ISO once and checks its signature against the Gentoo release key (fingerprint `13EBBDBEDE7A12775DFDB1BABB572E0E2D182910`, fetched from keys.gentoo.org). A verified ISO is kept and reused.
3. It boots the ISO under OVMF with KVM: 8 vCPUs, 8 GiB RAM, a fresh sparse 60 GB virtio disk in PCI slot 5 with serial `gi-target` (so the config uses `disk=/dev/disk/by-id/virtio-gi-target`), user-mode networking. A config with `disk=/dev/disk/by-path/pci-0000:00:05.0` gets the disk without a serial, so it has no by-id link. It boots the ISO's own kernel and initramfs with `-kernel`/`-initrd` and the command line from the ISO's `grub.cfg`, plus `console=tty0 console=ttyS0,115200`, so the live system autologins root on the serial console. The ISO stays attached as the live medium.
4. A small ext4 image (serial `gi-xfer`) carries the repo, config, secrets and `guest.sh`. No network is needed to get them in. The driver types one command on the serial console to mount it and run `guest.sh`, which checks efivars, runs `gentooinstall --yes --no-tui --config ... --secrets ... --log ...` with stdin from `/dev/null` (so a prompt `--yes` didn't expect stops the run instead of hanging it) and writes the log, replay script and `/tmp/gentooinstall` to the transfer disk.
5. Instrumentation: after a successful install, `guest.sh` appends `console=tty0 console=ttyS0,115200` to the installed boot entries (systemd-boot `options` lines, the `linux` lines of GRUB's `grub.cfg`, or the `cmdline:` lines of Limine's `limine.conf`). This is the only change the harness makes to the installed system. It shows the boot on serial and lets the driver type a LUKS passphrase.
6. The driver boots the installed disk with the same OVMF vars file (no ISO, no `-kernel`), waits until it can ssh in as the first user from the config, takes a screenshot of the VGA console and runs the checks below as that user.

With `# gi-vm: interrupt-world` in the config, the driver cuts the power once the package install is halfway (the `N of M` progress line with 2N >= M), boots the ISO again with the same disks and runs `guest.sh resume`, which runs `gentooinstall --resume` with the same options. Its console goes to `serial-resume.log`; the install log continues in `out/install.log`.

Checks, derived from the config: the init system, no crashed or failed services, the root filesystem type, no `discard` in fstab, swap matches `swap=`, a default route plus DNS plus an https fetch, the hostname, that the firmware booted the installer's own boot entry (not its fallback for the disk), `emerge --info`, the network service running, the user in `wheel` and `sudo` or `doas` working (admin users; doas gets the password through `script`, since it reads the terminal), root locked with `root=locked`, root on `/dev/mapper` (LUKS), the bootloader that booted (systemd-boot's `LoaderInfo` variable, Limine's, which starts with `Limine `, or GRUB's `BOOT_IMAGE=`), and a login prompt (`agetty` on tty1 without a desktop or with a window manager; with a login screen, the display manager enabled and started: `systemctl is-enabled`/`is-active` and `graphical.target` on systemd, `display-manager` in the default runlevel and started on OpenRC, and its process running, plus `lightdm-gtk-greeter` for LightDM). For a window manager it also checks that its start command and the programs its shipped default config runs are on `PATH`, that `first-steps.txt` gives the start command, and, where the WM can load its config without a seat (`i3 -C`, `Hyprland --verify-config`), that the config loads. For the Wayland sessions, which ignore `xorg.conf.d` (Sway, dwl, Niri, MangoWM, Hyprland, Budgie), it checks that the X layout reached the file that session reads. Two info lines record the kernel command line and disk and memory use.

## Configs

`configs/` holds the smoke test and the matrix: `systemd-btrfs-luks`, `openrc-btrfs-plasma`, `systemd-ext4-gnome-bypath`, `openrc-xfs-grub-doas`, `systemd-xfs-grub-plasma`, `openrc-xfs-luks-limine`, `systemd-btrfs-luks-limine` and `resume`, plus one per desktop added after Plasma and GNOME: `openrc-ext4-xfce`, `openrc-btrfs-budgie`, `systemd-xfs-cinnamon`, `systemd-ext4-i3`, `openrc-xfs-dwm`, `systemd-btrfs-sway`, `openrc-ext4-dwl`, `openrc-ext4-hyprland`, `systemd-ext4-niri` and `systemd-xfs-mangowm`. Run two or three at once at most; each VM takes 8 vCPUs and 8 GiB.

## Writing a config

Configs are ordinary gentooinstall config files. The harness needs two things in them:

- `disk=/dev/disk/by-id/virtio-gi-target`
- `sshd=yes`, since the checks log in over ssh (the installed system has no getty on the serial line)

The secrets file holds `root_password`, `user.<name>.password` for each user and `luks_passphrase` with `encryption=luks2`. These are throwaway passwords for test VMs.

## Output

Each run gets `~/.cache/gi-vm/runs/<config>-<date>-<time>/` (set `GI_VM_CACHE` to move the cache):

| File | What's in it |
|---|---|
| `result.txt` | PASS or FAIL, the error, timings, one line per check |
| `serial-install.log` | Live ISO serial console: boot, the installer's screen output, guest markers (`GI-VM: ...`) |
| `out/install.log` | gentooinstall's full log |
| `out/replay.sh` | gentooinstall's replay script |
| `out/rundir/` | `/tmp/gentooinstall` from the live system: state, saved config, build logs, `last_failure` |
| `serial-boot.log` | Serial console of the installed system's first boot |
| `checks.txt` | Each check's command and output |
| `screen.png` | VGA console of the installed system after login |
| `*.cmd` | The exact QEMU command lines |
| `target.img`, `OVMF_VARS.fd` | The installed disk and its firmware variables, to boot it again by hand |

Runs aren't cleaned up. The disk image is sparse but takes about 11 GB after a console install; delete old run directories yourself.

## Timeouts

Every wait has a bound, set at the top of `drive.py`: ISO download 1 h, live boot 10 min, install 6 h, installed boot to ssh 15 min, each check 10 min. On a timeout the VM is killed and whatever reached the transfer disk is still copied out. To stop a run early, `docker kill gi-vm-<run name>`.

## Limits

- Wi-Fi, Bluetooth, sound, laptop power and suspend can't be tested here.
- Only the first user logs in.
