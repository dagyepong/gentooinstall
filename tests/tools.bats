#!/usr/bin/env bats
# Tests for lib/steps/tools.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core state tools
  CFG[init]=openrc CFG[filesystem]=ext4 CFG[encryption]=none CFG[swap]=zram CFG[sshd]=no CFG[privilege]=sudo CFG[binpkgs]=yes
  HW[ram_mib]=16000
}

step() { (
  set -e
  "$@"
); }

chroot_cmds() {
  sed -n "s|^arch-chroot [^ ]* /bin/bash -c 'source /etc/profile \&\& \(.*\); exit \$?'\(  # (stdin: not recorded)\)\{0,1\}\$|\1|p" "$GI_RUN_DIR/replay.sh"
}

@test "portage hook: zram-generator built from source skips its Ruby-built man pages" {
  CFG[init]=systemd CFG[binpkgs]=no
  step step_tools_portage
  step step_tools_portage
  [ "$(cat "$GI_TARGET/etc/portage/package.use/zram-generator")" = 'sys-apps/zram-generator -man' ]
}

@test "portage hook: nothing with binary packages, OpenRC or no zram, and a stale file is removed" {
  CFG[init]=systemd CFG[binpkgs]=no
  step step_tools_portage
  CFG[binpkgs]=yes
  step step_tools_portage
  [ ! -e "$GI_TARGET/etc/portage/package.use/zram-generator" ]
  CFG[binpkgs]=no CFG[swap]=file
  step step_tools_portage
  CFG[init]=openrc CFG[swap]=zram
  step step_tools_portage
  [ ! -e "$GI_TARGET/etc/portage/package.use/zram-generator" ]
}

@test "packages: OpenRC, ext4, sudo, zram" {
  run step_tools_packages
  [ "$output" = "sys-fs/dosfstools
sys-block/io-scheduler-udev-rules
app-shells/bash-completion
app-portage/gentoolkit
sys-apps/pciutils
sys-apps/usbutils
app-admin/sudo
app-admin/sysklogd
sys-process/cronie
net-misc/chrony
sys-fs/e2fsprogs
sys-block/zram-init" ]
}

@test "packages: systemd, btrfs on LUKS, doas, zram, sshd" {
  CFG[init]=systemd CFG[filesystem]=btrfs CFG[encryption]=luks2 CFG[privilege]=doas CFG[sshd]=yes
  run step_tools_packages
  [ "$output" = "sys-fs/dosfstools
sys-block/io-scheduler-udev-rules
app-shells/bash-completion
app-portage/gentoolkit
sys-apps/pciutils
sys-apps/usbutils
app-admin/doas
sys-fs/btrfs-progs
sys-fs/cryptsetup
sys-apps/zram-generator
net-misc/openssh" ]
}

@test "packages: xfs and a swap file bring xfsprogs and no zram tool" {
  CFG[filesystem]=xfs CFG[swap]=file
  run step_tools_packages
  [[ $output == *sys-fs/xfsprogs* ]]
  [[ $output != *zram* ]]
}

@test "OpenRC: logger, cron, chronyd and zram-init with half of RAM in zstd" {
  step step_tools
  run chroot_cmds
  [ "$output" = $'rc-update add sysklogd default\nrc-update add cronie default\nrc-update add chronyd default\nrc-update add zram-init boot' ]
  [ "$(cat "$GI_TARGET/etc/conf.d/zram-init")" = "load_on_start=yes
unload_on_stop=yes
num_devices=1
type0=swap
size0=8000
algo0=zstd
labl0=zram_swap" ]
  [ ! -e "$GI_TARGET/etc/cron.weekly/fstrim" ]
}

@test "systemd: timesyncd and a zram-generator config" {
  CFG[init]=systemd
  step step_tools
  run chroot_cmds
  [ "$output" = 'systemctl enable systemd-timesyncd' ]
  [ "$(cat "$GI_TARGET/etc/systemd/zram-generator.conf")" = $'[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd' ]
  [ ! -e "$GI_TARGET/etc/conf.d/zram-init" ]
}

@test "no zram config without swap=zram" {
  CFG[swap]=none
  step step_tools
  [ ! -e "$GI_TARGET/etc/conf.d/zram-init" ]
  run ! grep -q zram "$GI_RUN_DIR/replay.sh"
}

@test "OpenRC, btrfs swap file: swap starts after localmount mounts /swap, and a rerun keeps one line each" {
  CFG[swap]=file CFG[filesystem]=btrfs
  mkdir -p "$GI_TARGET/etc/conf.d"
  # The stage3's own file: the wiki's lines, commented out.
  printf '#rc_before="!localmount"\n#\n#rc_need="localmount"\n' > "$GI_TARGET/etc/conf.d/swap"
  step step_tools
  step step_tools
  [ "$(cat "$GI_TARGET/etc/conf.d/swap")" = '#rc_before="!localmount"
#
#rc_need="localmount"
rc_before="!localmount"
rc_need="localmount"' ]
}

@test "a swap file on ext4 or xfs root, or on systemd, leaves conf.d/swap alone" {
  CFG[swap]=file
  for fs in ext4 xfs; do
    CFG[filesystem]=$fs
    step step_tools
  done
  CFG[init]=systemd CFG[filesystem]=btrfs
  step step_tools
  [ ! -e "$GI_TARGET/etc/conf.d/swap" ]
}

@test "SSD on OpenRC: a weekly cron script runs fstrim" {
  state_set disk.ssd yes
  step step_tools
  f=$GI_TARGET/etc/cron.weekly/fstrim
  [ "$(cat "$f")" = $'#!/bin/sh\nfstrim --all' ]
  [ "$(stat -c %a "$f")" = 755 ]
}

@test "SSD on systemd: fstrim.timer" {
  CFG[init]=systemd
  state_set disk.ssd yes
  step step_tools
  run chroot_cmds
  [ "${lines[1]}" = 'systemctl enable fstrim.timer' ]
  [ ! -e "$GI_TARGET/etc/cron.weekly/fstrim" ]
}

@test "no TRIM schedule when the disk isn't an SSD" {
  CFG[init]=systemd
  state_set disk.ssd no
  step step_tools
  run ! grep -q fstrim "$GI_RUN_DIR/replay.sh"
}

@test "sshd: enabled, root login off through a drop-in when sshd_config includes sshd_config.d" {
  CFG[sshd]=yes
  mkdir -p "$GI_TARGET/etc/ssh"
  printf '#PermitRootLogin prohibit-password\nInclude "/etc/ssh/sshd_config.d/*.conf"\n' > "$GI_TARGET/etc/ssh/sshd_config"
  step step_tools
  run chroot_cmds
  [ "${lines[-1]}" = 'rc-update add sshd default' ]
  [ "$(cat "$GI_TARGET/etc/ssh/sshd_config.d/00-no-root-login.conf")" = 'PermitRootLogin no' ]
  [ "$(head -n1 "$GI_TARGET/etc/ssh/sshd_config")" = '#PermitRootLogin prohibit-password' ]
}

@test "sshd: without the Include, the setting goes first in sshd_config, once" {
  CFG[sshd]=yes CFG[init]=systemd
  mkdir -p "$GI_TARGET/etc/ssh"
  printf 'Port 22\n' > "$GI_TARGET/etc/ssh/sshd_config"
  step step_tools
  step step_tools
  [ "$(cat "$GI_TARGET/etc/ssh/sshd_config")" = $'PermitRootLogin no\nPort 22' ]
  [ "$(stat -c %a "$GI_TARGET/etc/ssh/sshd_config")" = 600 ]
  [ ! -e "$GI_TARGET/etc/ssh/sshd_config.d" ]
  grep -qxF "arch-chroot $GI_TARGET /bin/bash -c 'source /etc/profile && systemctl enable sshd; exit \$?'" "$GI_RUN_DIR/replay.sh"
}

@test "running the step twice gives the same files" {
  state_set disk.ssd yes
  step step_tools
  cp "$GI_TARGET/etc/conf.d/zram-init" "$BATS_TEST_TMPDIR/first"
  step step_tools
  cmp "$GI_TARGET/etc/conf.d/zram-init" "$BATS_TEST_TMPDIR/first"
  [ "$(cat "$GI_TARGET/etc/cron.weekly/fstrim")" = $'#!/bin/sh\nfstrim --all' ]
}

@test "dry-run prints the commands and changes nothing" {
  GI_DRY_RUN=1 CFG[sshd]=yes
  state_set disk.ssd yes
  run --separate-stderr step step_tools
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$GI_TARGET/etc" ]
  [[ $stderr == *"rc-update add zram-init boot"* ]]
  [[ $stderr == *"cron.weekly/fstrim (mode 0755)"* ]]
  [[ $stderr == *"sshd_config.d/00-no-root-login.conf"* ]]
}
