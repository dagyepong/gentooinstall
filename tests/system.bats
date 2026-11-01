#!/usr/bin/env bats
# Tests for lib/steps/system.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui config state system
  CFG[hostname]=laptop CFG[keymap]=de-latin1 CFG[timezone]=Europe/Berlin CFG[lang]=de_DE.UTF-8 CFG[locales]=de_DE.UTF-8
  cfg_defaults_apply
  SECRET[root_password]='s3cr:et pw'
  mkdir -p "$GI_TARGET/etc"
}

# The stub records each chroot script %q-quoted.
chroot_ran() { grep -qxF "arch-chroot $(printf '%q' "$GI_TARGET") /bin/bash -c $(printf '%q' "source /etc/profile && $1; exit \$?")" "$STUB_LOG"; }

btrfs_fstab() {
  cat > "$STUB_OUT_DIR/genfstab" << 'EOF'
# /dev/mapper/root
UUID=aaaa	/         	btrfs     	rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=/@	0 0

# /dev/mapper/root
UUID=aaaa	/home     	btrfs     	rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=/@home	0 0
UUID=aaaa	/var/log  	btrfs     	rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=/@var_log	0 0
UUID=aaaa	/var/cache	btrfs     	rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=/@var_cache	0 0
UUID=aaaa	/.snapshots	btrfs     	rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=/@snapshots	0 0
UUID=aaaa	/swap     	btrfs     	rw,noatime,compress=zstd:3,ssd,space_cache=v2,nodiscard,subvol=/@swap	0 0

# /dev/nvme0n1p1 LABEL=ESP
UUID=1234-ABCD	/efi      	vfat      	rw,relatime,fmask=0077,dmask=0077,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro	0 2

/swap/swapfile	none      	swap      	defaults  	0 0
EOF
}

@test "portage hook: fstab from genfstab -U on the target, filtered to the target" {
  CFG[filesystem]=btrfs CFG[swap]=file
  state_set disk.swapfile /swap/swapfile
  btrfs_fstab
  step_system_portage
  # Without -f genfstab copies every swap the live system has on, also on other disks.
  grep -qx "genfstab -U -f $GI_TARGET $GI_TARGET" "$STUB_LOG"
  # Every btrfs line gets nodiscard once; everything else is genfstab's output as is.
  diff <(grep -v btrfs "$STUB_OUT_DIR/genfstab") <(grep -v btrfs "$GI_TARGET/etc/fstab")
  grep -qxF $'UUID=aaaa\t/\tbtrfs\trw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=/@,nodiscard\t0\t0' "$GI_TARGET/etc/fstab"
  [ "$(grep -c btrfs "$GI_TARGET/etc/fstab")" -eq 6 ]
  [ "$(grep -c 'nodiscard' "$GI_TARGET/etc/fstab")" -eq 6 ]
  run ! grep -q 'nodiscard.*nodiscard' "$GI_TARGET/etc/fstab"
}

@test "portage hook: ext4 and xfs entries keep genfstab's options" {
  printf 'UUID=a\t/\txfs\trw,noatime\t0 1\nUUID=B\t/efi\tvfat\trw\t0 2\n' > "$STUB_OUT_DIR/genfstab"
  step_system_portage
  diff "$STUB_OUT_DIR/genfstab" "$GI_TARGET/etc/fstab"
}

@test "fstab check: every problem is listed and nothing is written" {
  CFG[filesystem]=btrfs CFG[swap]=file
  state_set disk.swapfile /swap/swapfile
  btrfs_fstab
  sed -i -e '/\/home/d' -e 's/,ssd,/,ssd,discard=async,/' -e 's/^UUID=1234-ABCD/\/dev\/nvme0n1p1/' "$STUB_OUT_DIR/genfstab"
  run step_system_portage
  [ "$status" -eq 1 ]
  [[ $output == *"no entry for /home"* ]]
  [[ $output != *"no entry for /var/log"* ]]
  [[ $output == *"/: has discard=async"* ]]
  [[ $output == *"/efi: /dev/nvme0n1p1 is not given by UUID"* ]]
  [[ $output != *"/swap/swapfile is not given by UUID"* ]]
  [ ! -e "$GI_TARGET/etc/fstab" ]
}

@test "fstab check: btrfs needs every subvolume" {
  local mp
  CFG[filesystem]=btrfs CFG[swap]=file
  state_set disk.swapfile /swap/swapfile
  btrfs_fstab
  for mp in /var/log /var/cache /.snapshots /swap; do
    run _system_fstab_problems "$(grep -v "[[:space:]]$mp[[:space:]]" "$STUB_OUT_DIR/genfstab")"
    [ "$output" = "no entry for $mp" ]
  done
}

@test "fstab check: ext4 needs only root and the ESP; nodiscard is fine" {
  printf 'UUID=a\t/\text4\trw,noatime,nodiscard\t0 1\nUUID=B\t/efi\tvfat\trw\t0 2\n' > "$STUB_OUT_DIR/genfstab"
  run _system_fstab_problems "$(cat "$STUB_OUT_DIR/genfstab")"
  [ -z "$output" ]
  printf 'UUID=a\t/\text4\trw\t0 1\n' > "$STUB_OUT_DIR/genfstab"
  run _system_fstab_problems "$(cat "$STUB_OUT_DIR/genfstab")"
  [ "$output" = "no entry for /efi" ]
  printf 'UUID=a\t/\text4\trw,discard\t0 1\nUUID=B\t/efi\tvfat\trw\t0 2\n' > "$STUB_OUT_DIR/genfstab"
  run _system_fstab_problems "$(cat "$STUB_OUT_DIR/genfstab")"
  [ "$output" = "/: has discard, but TRIM runs on a schedule" ]
}

@test "fstab check: swap is only the install's own swap file" {
  local fs=$'UUID=a\t/\text4\trw\t0 1\nUUID=B\t/efi\tvfat\trw\t0 2\n'
  # Another disk's swap partition, on in the live session: boot would wait for it once that disk is gone.
  run _system_fstab_problems "$fs"$'# /dev/sdb2\nUUID=c\tnone\tswap\tdefaults\t0 0\n'
  [ "$output" = "swap UUID=c is not this system's swap file" ]
  state_set disk.swapfile /swapfile
  run _system_fstab_problems "$fs"$'/swapfile\tnone\tswap\tdefaults\t0 0\n'
  [ -z "$output" ]
  run _system_fstab_problems "$fs"
  [ "$output" = "no entry for /swapfile" ]
}

@test "portage hook: a machine ID is made once and then kept" {
  printf 'UUID=a\t/\text4\trw\t0 1\nUUID=B\t/efi\tvfat\trw\t0 2\n' > "$STUB_OUT_DIR/genfstab"
  step_system_portage
  id=$(cat "$GI_TARGET/etc/machine-id")
  [[ $id =~ ^[0-9a-f]{32}$ ]]
  [ "$(stat -c %a "$GI_TARGET/etc/machine-id")" = 444 ]
  step_system_portage
  [ "$(cat "$GI_TARGET/etc/machine-id")" = "$id" ]
}

@test "portage hook: an uninitialized machine ID is replaced" {
  printf 'UUID=a\t/\text4\trw\t0 1\nUUID=B\t/efi\tvfat\trw\t0 2\n' > "$STUB_OUT_DIR/genfstab"
  echo uninitialized > "$GI_TARGET/etc/machine-id"
  step_system_portage
  [[ $(cat "$GI_TARGET/etc/machine-id") =~ ^[0-9a-f]{32}$ ]]
}

@test "step on OpenRC: hostname, hosts, root password on stdin" {
  export STUB_STDIN_DIR=$BATS_TEST_TMPDIR/stdin
  mkdir -p "$STUB_STDIN_DIR" "$GI_TARGET/etc/conf.d"
  # The stage3's file; NetworkManager on Gentoo sets the hostname from it.
  printf '# Hostname fallback if /etc/hostname does not exist\nhostname="localhost"\n' > "$GI_TARGET/etc/conf.d/hostname"
  step_system
  [ "$(cat "$GI_TARGET/etc/hostname")" = laptop ]
  [ "$(cat "$GI_TARGET/etc/conf.d/hostname")" = $'# Hostname fallback if /etc/hostname does not exist\nhostname="laptop"' ]
  grep -qx $'127.0.0.1\tlaptop localhost' "$GI_TARGET/etc/hosts"
  grep -qx $'::1\t\tlaptop localhost' "$GI_TARGET/etc/hosts"
  chroot_ran chpasswd
  [ "$(cat "$STUB_STDIN_DIR/arch-chroot")" = 'root:s3cr:et pw' ]
  run ! grep -rqF 's3cr:et' "$GI_LOG" "$GI_RUN_DIR/replay.sh" "$STUB_LOG"
  run ! grep -q systemd "$STUB_LOG"
}

@test "step on systemd: presets, and nothing that would redo the machine ID or the locale step's files" {
  CFG[init]=systemd
  step_system
  chroot_ran 'systemctl preset-all --preset-mode=enable-only'
  run ! grep -qE 'firstboot|machine-id|dbus-uuidgen' "$STUB_LOG"
  [ ! -e "$GI_TARGET/etc/conf.d/hostname" ]
}

@test "step: a locked root gets passwd -l and no chpasswd" {
  CFG[root]=locked
  unset 'SECRET[root_password]'
  step_system
  chroot_ran 'passwd -l root'
  run ! grep -q chpasswd "$STUB_LOG"
}

@test "step: running it twice gives the same files" {
  step_system
  cp -a "$GI_TARGET/etc" "$BATS_TEST_TMPDIR/first"
  step_system
  diff -r "$BATS_TEST_TMPDIR/first" "$GI_TARGET/etc"
}

@test "dry-run: prints everything, runs and writes nothing" {
  GI_DRY_RUN=1
  run --separate-stderr step_system_portage
  [ "$status" -eq 0 ]
  [[ $stderr == *"/etc/fstab"* ]]
  run --separate-stderr step_system
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [ -z "$(ls -A "$GI_TARGET/etc")" ]
}

@test "an encrypted /home partition is unlocked at boot with the key file: crypttab on systemd, dmcrypt on OpenRC" {
  CFG[filesystem]=ext4 CFG[home]=partition CFG[encryption]=luks2 CFG[swap]=zram CFG[init]=systemd CFG[luks_discard]=no
  state_set disk.home_luks_uuid hhhh
  printf '%s\n' 'UUID=aaaa	/	ext4	rw,noatime	0 1' 'UUID=bbbb	/home	ext4	rw,noatime	0 2' \
    'UUID=1234-ABCD	/efi	vfat	rw,relatime,fmask=0077,dmask=0077	0 2' > "$STUB_OUT_DIR/genfstab"
  step_system_portage
  [ "$(cat "$GI_TARGET/etc/crypttab")" = 'home UUID=hhhh /etc/cryptsetup-keys.d/home.key luks' ]
  CFG[luks_discard]=yes
  step_system_portage
  [ "$(cat "$GI_TARGET/etc/crypttab")" = 'home UUID=hhhh /etc/cryptsetup-keys.d/home.key luks,discard' ]
  CFG[init]=openrc
  step_system_portage
  [ "$(cat "$GI_TARGET/etc/conf.d/dmcrypt")" = "# Written by gentooinstall: /home, unlocked with the key file on the encrypted root.
target=home
source=UUID=hhhh
key=/etc/cryptsetup-keys.d/home.key
options='--allow-discards'" ]
  step_system
  chroot_ran 'rc-update add dmcrypt boot'
  # Without /home in fstab the boot would leave it on root.
  sed -i '/\/home/d' "$STUB_OUT_DIR/genfstab"
  run step_system_portage
  [ "$status" -ne 0 ]
  [[ $output == *"no entry for /home"* ]]
}

