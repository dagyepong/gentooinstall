#!/usr/bin/env bats
# Tests for lib/steps/disk.sh: partitioning, formatting, mounting, retries, refusals and resume mounting.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  # An unexpected question then fails the test instead of waiting for input.
  exec < /dev/null
  gi_load core ui config state disk
  GI_UI=plain
  T=$GI_TARGET
  DISK=/dev/gitestdisk
  GI_HOST_ROOT=$BATS_TEST_TMPDIR/host
  XFS_CONF_DIR=$GI_HOST_ROOT/usr/share/xfsprogs/mkfs
  mkdir -p "$BATS_TEST_TMPDIR/by-id" "$GI_HOST_ROOT/sys/block/gitestdisk/queue"
  ln -s "$DISK" "$BATS_TEST_TMPDIR/by-id/nvme-Test"
  echo 0 > "$GI_HOST_ROOT/sys/block/gitestdisk/queue/rotational"
  mkdir -p "$GI_HOST_ROOT/sys/class/block/gitestdisk1" "$GI_HOST_ROOT/sys/class/block/gitestdisk5"
  echo 1 > "$GI_HOST_ROOT/sys/class/block/gitestdisk1/partition"
  echo 5 > "$GI_HOST_ROOT/sys/class/block/gitestdisk5/partition"
  BYID=$BATS_TEST_TMPDIR/by-id/nvme-Test
  CFG[disk]=$BYID
  CFG[users]=larry
  cfg_defaults_apply
  CFG[swap]=none
  HW[live_disk]=sdz HW[ram_mib]=16000
  echo uuid-root > "$STUB_OUT_DIR/blkid"
  echo uuid-luks > "$STUB_OUT_DIR/cryptsetup"
  TREE="$DISK disk "$'\n'"${DISK}1 part "$'\n'"${DISK}2 part "
  LABELS="$DISK "$'\n'"${DISK}1 gentooinstall-esp"$'\n'"${DISK}2 gentooinstall-root"
}

# Read-only queries the code calls directly; each answers from test variables.
lsblk() { fake_lsblk "$@"; }
fake_lsblk() {
  case $* in
    *NAME,TYPE,MOUNTPOINT*) printf '%s\n' "$TREE" ;;
    *NAME,PKNAME,PARTLABEL*) printf '%s\n' "$ALL" ;;
    *NAME,PARTLABEL*) printf '%s\n' "$LABELS" ;;
    # A partition and what sits on it; the root mapping sits on $ROOT_ON, ${DISK}2 by default.
    *" NAME "*)
      printf '%s\n' "${!#}"
      if [[ ${ROOT_ON:-${DISK}2} == "${!#}" ]]; then echo /dev/mapper/root; fi
      ;;
    *) return 1 ;;
  esac
}
# The root mapping is open with $ROOT_OPEN set, or once the stub opened it and until it closes it.
cryptsetup() {
  if [[ $1 == status ]]; then
    [[ -n ${ROOT_OPEN:-} || -f $BATS_TEST_TMPDIR/root-open ]]
    return
  fi
  command cryptsetup "$@" || return
  case $1 in
    open) touch "$BATS_TEST_TMPDIR/root-open" ;;
    close) rm -f "$BATS_TEST_TMPDIR/root-open" ;;
  esac
}
fallocate() { command fallocate "$@" && : > "${!#}"; }

# Mounts and swaps the stubs make are remembered, so mountpoint and swapon --show see them.
mount() { command mount "$@" && echo "${!#}" >> "$BATS_TEST_TMPDIR/mounted"; }
umount() {
  command umount "$@" || return
  local f=$BATS_TEST_TMPDIR/mounted
  [[ -f $f ]] || return 0
  awk -v d="${!#}" '$0 != d && index($0, d "/") != 1' "$f" > "$f.new"
  mv "$f.new" "$f"
}
mountpoint() { grep -qxF -- "${!#}" "$BATS_TEST_TMPDIR/mounted" 2> /dev/null; }
swapon() {
  command swapon "$@" || return
  if [[ $1 != --show* ]]; then echo "${!#}" >> "$STUB_OUT_DIR/swapon"; fi
}

# Runs a step the way steps_run does: in a subshell with errexit on.
in_step() { (set -e && "$@"); }

calls() { grep -E "^($1)( |\$)" "$STUB_LOG" || true; }

destructive='wipefs|sfdisk|mkfs\.[a-z0-9]+|cryptsetup luksFormat|btrfs subvolume create'

@test "ext4 without LUKS: exact commands and every state key" {
  run in_step step_disk
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "wipefs --all ${DISK}1 ${DISK}2
wipefs --all $BYID
sfdisk $BYID
udevadm settle
wipefs --all ${DISK}1 ${DISK}2
mkfs.vfat -F 32 -n ESP ${DISK}1
mkfs.ext4 -L root ${DISK}2
mount -o noatime ${DISK}2 $T
mount -o umask=0077 ${DISK}1 $T/efi
blkid -p -s UUID -o value ${DISK}2" ]
  [ "$(state_get disk.root_uuid)" = uuid-root ]
  [ -z "$(state_get disk.luks_uuid)" ]
  [ "$(state_get disk.ssd)" = yes ]
  [ -z "$(state_get disk.swapfile)" ]
  [ "$(state_get disk.stage)" = mounted ]
  [ "$(state_get disk.esp_part)" = 1 ]
  grep -qx 'disk.root_uuid=uuid-root' "$T/var/lib/gentooinstall/state"
  grep -qx 'filesystem=ext4' "$T/var/lib/gentooinstall/config"
}

@test "on a disk holding an earlier install, partition names are read only after the new table" {
  # TREE and LABELS already show an earlier install's gentooinstall-* partitions.
  lsblk() {
    if [[ $* == *PARTLABEL* ]]; then echo "lookup after: $(tail -n 1 "$STUB_LOG")" >> "$BATS_TEST_TMPDIR/lookups"; fi
    fake_lsblk "$@"
  }
  run in_step step_disk
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/lookups")" = "lookup after: udevadm settle
lookup after: udevadm settle" ]
}

@test "the sfdisk script makes a GPT with the named ESP and root partitions" {
  export STUB_STDIN_DIR=$BATS_TEST_TMPDIR/stdin
  mkdir -p "$STUB_STDIN_DIR"
  run in_step step_disk < /dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_STDIN_DIR/sfdisk")" = "label: gpt
size=1GiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=gentooinstall-esp
type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name=gentooinstall-root" ]
}

@test "free space: ESP and root fill the largest free space, aligned, and no other partition is touched" {
  CFG[disk_mode]=free
  export STUB_STDIN_DIR=$BATS_TEST_TMPDIR/stdin
  mkdir -p "$STUB_STDIN_DIR"
  # Windows' partitions 1 to 4 stay; the new ones come out as 5 and 6.
  hw_disk_free() { echo "gpt 42182600 62674944 512"; }
  TREE="$DISK disk "$'\n'"${DISK}3 part "$'\n'"${DISK}5 part "$'\n'"${DISK}6 part "
  LABELS="${DISK}3 Basic data partition"$'\n'"${DISK}5 gentooinstall-esp"$'\n'"${DISK}6 gentooinstall-root"
  run in_step step_disk
  [ "$status" -eq 0 ]
  [ "$(calls "$destructive")" = "sfdisk --append --backup --backup-file $GI_RUN_DIR/gpt-backup $BYID
wipefs --all ${DISK}5 ${DISK}6
mkfs.vfat -F 32 -n ESP ${DISK}5
mkfs.ext4 -L root ${DISK}6" ]
  [ "$(cat "$STUB_STDIN_DIR/sfdisk")" = "start=42182656, size=2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=gentooinstall-esp
start=44279808, size=60575744, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name=gentooinstall-root" ]
  [ "$(state_get disk.esp_part)" = 5 ]
}

@test "free space: no GPT, an earlier install's partitions or too little room stop before anything is written" {
  CFG[disk_mode]=free
  hw_disk_free() { echo "dos 2048 100000000 512"; }
  run in_step step_disk
  [ "$status" -ne 0 ]
  [[ $output == *"has no GPT partition table"* ]]
  hw_disk_free() { echo "gpt 2048 100000000 512"; }
  lsblk() { if [[ $* == "-nro PARTLABEL $DISK" ]]; then echo gentooinstall-root; else fake_lsblk "$@"; fi; }
  run in_step step_disk
  [ "$status" -ne 0 ]
  [[ $output == *"already has partitions from an earlier gentooinstall run"* ]]
  lsblk() { fake_lsblk "$@"; }
  hw_disk_free() { echo "gpt 2048 40000000 512"; }
  run in_step step_disk
  [ "$status" -ne 0 ]
  [[ $output == *"Gentoo needs at least 21 GiB in one piece"* ]]
  [ -z "$(calls "$destructive")" ]
}

@test "Windows' ESP is found by mounting each other ESP read-only, once" {
  local dir=$GI_RUN_DIR/esp-probe
  # Ours, a Linux root, then Windows' ESP. -r escapes the spaces in a label.
  lsblk() {
    [[ $* == "-nrpo NAME,PARTTYPE,PARTUUID,UUID,PARTLABEL" ]] || return 1
    printf '%s\n' "${DISK}1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b 1111-p 1111-f gentooinstall-esp" \
      "${DISK}2 4f68bce3-e8cd-4db1-96e7-fbcaf984b709 2222-p 2222-f gentooinstall-root" \
      "${DISK}3 C12A7328-F81F-11D2-BA4B-00A0C93EC93B 3333-p 3333-f EFI\x20system\x20partition"
  }
  mkdir -p "$dir/EFI/Microsoft/Boot"
  touch "$dir/EFI/Microsoft/Boot/bootmgfw.efi"
  run disk_windows_esp
  [ "$output" = "3333-p 3333-f" ]
  [ "$(calls 'mount|umount')" = "mount -o ro -t vfat ${DISK}3 $dir
umount $dir" ]
  [ "$(state_get windows.esp)" = "3333-p 3333-f" ]
  # The answer is kept, so later steps mount nothing.
  : > "$STUB_LOG"
  run disk_windows_esp
  [ "$output" = "3333-p 3333-f" ]
  [ ! -s "$STUB_LOG" ]
  # Without bootmgfw.efi there's no Windows, and that's kept too.
  rm "$dir/EFI/Microsoft/Boot/bootmgfw.efi"
  state_set windows.esp ''
  run disk_windows_esp
  [ -z "$output" ]
  [ "$(state_get windows.esp)" = none ]
}

@test "LUKS2 and btrfs with a swap file: passphrase on stdin only, subvolumes, mounts and swap" {
  CFG[encryption]=luks2 CFG[filesystem]=btrfs CFG[swap]=file
  SECRET[luks_passphrase]='pass phrase'
  export STUB_STDIN_DIR=$BATS_TEST_TMPDIR/stdin
  mkdir -p "$STUB_STDIN_DIR"
  run in_step step_disk < /dev/null
  [ "$status" -eq 0 ]
  [ "$(calls 'cryptsetup|mkfs\.[a-z0-9]+|btrfs|mount|umount|swapon')" = "cryptsetup luksFormat --type luks2 --batch-mode --key-file=- ${DISK}2
cryptsetup open --key-file=- ${DISK}2 root
mkfs.vfat -F 32 -n ESP ${DISK}1
mkfs.btrfs -L root /dev/mapper/root
mount /dev/mapper/root $T
btrfs subvolume create $T/@
btrfs subvolume create $T/@home
btrfs subvolume create $T/@var_log
btrfs subvolume create $T/@var_cache
btrfs subvolume create $T/@snapshots
btrfs subvolume create $T/@swap
umount $T
mount -o noatime\,compress=zstd\,nodiscard\,subvol=@ /dev/mapper/root $T
mount -o umask=0077 ${DISK}1 $T/efi
mount -o noatime\,compress=zstd\,nodiscard\,subvol=@home /dev/mapper/root $T/home
mount -o noatime\,compress=zstd\,nodiscard\,subvol=@var_log /dev/mapper/root $T/var/log
mount -o noatime\,compress=zstd\,nodiscard\,subvol=@var_cache /dev/mapper/root $T/var/cache
mount -o noatime\,compress=zstd\,nodiscard\,subvol=@snapshots /dev/mapper/root $T/.snapshots
mount -o noatime\,compress=zstd\,nodiscard\,subvol=@swap /dev/mapper/root $T/swap
swapon --show=NAME --noheadings --raw
btrfs filesystem mkswapfile --size 8192m $T/swap/swapfile
swapon $T/swap/swapfile
cryptsetup luksUUID ${DISK}2" ]
  # Exactly the passphrase twice, with no newline, which would become part of the key.
  [ "$(cat "$STUB_STDIN_DIR/cryptsetup")" = 'pass phrasepass phrase' ]
  run ! grep -q 'pass phrase' "$GI_LOG" "$GI_RUN_DIR/replay.sh" "$STUB_LOG"
  [ "$(state_get disk.luks_uuid)" = uuid-luks ]
  [ "$(state_get disk.swapfile)" = /swap/swapfile ]
}

@test "btrfs without a swap file has no @swap subvolume" {
  CFG[filesystem]=btrfs CFG[swap]=zram
  run in_step step_disk
  [ "$status" -eq 0 ]
  run ! grep -q '@swap' "$STUB_LOG"
  run ! grep -q mkswapfile "$STUB_LOG"
}

@test "LUKS without a passphrase stops before anything is wiped" {
  CFG[encryption]=luks2
  for stage in '' partitioned; do
    state_set disk.stage "$stage"
    run in_step step_disk
    [ "$status" -ne 0 ]
    [[ $output == *"LUKS passphrase is missing"* ]]
    [ ! -s "$STUB_LOG" ]
  done
}

@test "xfs uses the Handbook's LTS mkfs config, not a newer one GRUB may not read" {
  CFG[filesystem]=xfs
  mkdir -p "$XFS_CONF_DIR"
  touch "$XFS_CONF_DIR"/lts_{5.10,6.6,6.18,7.4}.conf
  run in_step step_disk
  [ "$status" -eq 0 ]
  [ "$(calls mkfs.xfs)" = "mkfs.xfs -c options=$XFS_CONF_DIR/lts_6.18.conf -L root ${DISK}2" ]
}

@test "xfs without the Handbook's LTS config runs plain mkfs.xfs" {
  CFG[filesystem]=xfs
  mkdir -p "$XFS_CONF_DIR"
  touch "$XFS_CONF_DIR"/lts_6.6.conf
  run in_step step_disk
  [ "$status" -eq 0 ]
  [ "$(calls mkfs.xfs)" = "mkfs.xfs -L root ${DISK}2" ]
}

@test "ext4 swap file: allocated like RAM, mode 600, mkswap and swapon" {
  CFG[swap]=file HW[ram_mib]=4096
  run in_step step_disk
  [ "$status" -eq 0 ]
  [ "$(calls 'fallocate|mkswap|swapon')" = "swapon --show=NAME --noheadings --raw
fallocate -l 4096MiB $T/swapfile
mkswap $T/swapfile
swapon $T/swapfile" ]
  [ "$(stat -c %a "$T/swapfile")" = 600 ]
  [ "$(state_get disk.swapfile)" = /swapfile ]
}

@test "the swap file is capped at 8 GiB" {
  CFG[swap]=file HW[ram_mib]=65536
  run in_step step_disk
  [ "$status" -eq 0 ]
  [ "$(calls fallocate)" = "fallocate -l 8192MiB $T/swapfile" ]
}

@test "an active swap file is left alone" {
  CFG[swap]=file
  echo "$T/swapfile" > "$STUB_OUT_DIR/swapon"
  run in_step step_disk
  [ "$status" -eq 0 ]
  [ "$(calls 'fallocate|mkswap|swapon')" = "swapon --show=NAME --noheadings --raw" ]
  [ "$(state_get disk.swapfile)" = /swapfile ]
}

@test "a swap file needs a known RAM size" {
  CFG[swap]=file HW[ram_mib]=unknown
  run in_step step_disk
  [ "$status" -ne 0 ]
  [[ $output == *"RAM size is unknown"* ]]
}

@test "a rotating disk is not an SSD" {
  echo 1 > "$GI_HOST_ROOT/sys/block/gitestdisk/queue/rotational"
  run in_step step_disk
  [ "$status" -eq 0 ]
  [ "$(state_get disk.ssd)" = no ]
}

@test "running the step twice never repeats destructive commands" {
  CFG[encryption]=luks2 CFG[filesystem]=btrfs CFG[swap]=file SECRET[luks_passphrase]=pw
  run in_step step_disk
  [ "$status" -eq 0 ]
  : > "$STUB_LOG"
  run in_step step_disk
  [ "$status" -eq 0 ]
  # Everything is still mounted, root open and the swap file active, so nothing at all is redone.
  run ! grep -qE "^($destructive|cryptsetup open|mount|btrfs|swapon $T)( |\$)" "$STUB_LOG"
  [ "$(state_get disk.stage)" = mounted ]
  [ "$(state_get disk.swapfile)" = /swap/swapfile ]
}

@test "a retry mounts whatever isn't mounted yet" {
  CFG[filesystem]=btrfs
  run in_step step_disk
  [ "$status" -eq 0 ]
  grep -vxF "$T/home" "$BATS_TEST_TMPDIR/mounted" > "$BATS_TEST_TMPDIR/m" || true
  mv "$BATS_TEST_TMPDIR/m" "$BATS_TEST_TMPDIR/mounted"
  : > "$STUB_LOG"
  run in_step step_disk
  [ "$status" -eq 0 ]
  [ "$(calls mount)" = "mount -o noatime\,compress=zstd\,nodiscard\,subvol=@home ${DISK}2 $T/home" ]
}

@test "resuming after partitioning formats but doesn't touch the partition table" {
  state_set disk.stage partitioned
  run in_step step_disk
  [ "$status" -eq 0 ]
  [ "$(calls 'wipefs|sfdisk|mkfs\.[a-z0-9]+')" = "wipefs --all ${DISK}1 ${DISK}2
mkfs.vfat -F 32 -n ESP ${DISK}1
mkfs.ext4 -L root ${DISK}2" ]
}

@test "resuming after formatting or mounting only mounts" {
  for stage in formatted mounted; do
    : > "$STUB_LOG"
    rm -f "$BATS_TEST_TMPDIR/mounted"
    state_set disk.stage "$stage"
    run in_step step_disk
    [ "$status" -eq 0 ]
    run ! grep -qE "^($destructive)( |\$)" "$STUB_LOG"
    grep -qx "mount -o noatime ${DISK}2 $T" "$STUB_LOG"
  done
}

@test "a retry or resume looks up the partitions the chosen disk has now" {
  SECRET[luks_passphrase]=pw
  for c in 'partitioned none' 'mounted none' 'mounted luks2'; do
    read -r stage CFG[encryption] <<< "$c"
    : > "$STUB_LOG"
    rm -f "$BATS_TEST_TMPDIR/mounted"
    state_set disk.stage "$stage"
    run in_step step_disk
    [ "$status" -eq 0 ]
    grep -qx "mount -o umask=0077 ${DISK}1 $T/efi" "$STUB_LOG"
  done
  grep -qx "blkid -p -s UUID -o value /dev/mapper/root" "$STUB_LOG"
  grep -qx "cryptsetup luksUUID ${DISK}2" "$STUB_LOG"
}

@test "a retry after the Shell closed the root mapping opens it again before mounting" {
  CFG[encryption]=luks2 SECRET[luks_passphrase]=pw
  run in_step step_disk
  [ "$status" -eq 0 ]
  # In the error menu's Shell: umount -R, cryptsetup close root.
  rm -f "$BATS_TEST_TMPDIR/mounted" "$BATS_TEST_TMPDIR/root-open"
  for stage in formatted mounted; do
    state_set disk.stage "$stage"
    : > "$STUB_LOG"
    run in_step step_disk
    [ "$status" -eq 0 ]
    [ "$(calls 'cryptsetup open|mount' | head -2)" = "cryptsetup open --key-file=- ${DISK}2 root
mount -o noatime /dev/mapper/root $T" ]
    run ! grep -qE "^($destructive)( |\$)" "$STUB_LOG"
    rm -f "$BATS_TEST_TMPDIR/mounted" "$BATS_TEST_TMPDIR/root-open"
  done
  # One opened from another disk in that Shell is refused, not mounted.
  ROOT_OPEN=1 ROOT_ON=/dev/sdy2
  : > "$STUB_LOG"
  run in_step step_disk
  [ "$status" -ne 0 ]
  [[ $output == *"/dev/mapper/root is open, but not from ${DISK}2"* ]]
  run ! grep -qE '^(mount|cryptsetup|swapon|fallocate)( |$)' "$STUB_LOG"
}

@test "on --resume, a state without the mounted stage never leads to a wipe" {
  GI_RESUME=1 GI_YES=1 ROOT_OPEN=1
  mountpoint() { [[ ${!#} == "$T" ]]; }
  for stage in '' partitioned formatted; do
    state_set disk.stage "$stage"
    run in_step step_disk
    [ "$status" -ne 0 ]
    [[ $output == *"going on would erase it"* ]]
    [ ! -s "$STUB_LOG" ]
  done
  state_set disk.stage mounted
  run in_step step_disk
  [ "$status" -eq 0 ]
  run ! grep -qE "^($destructive|umount|swapoff|cryptsetup close)( |\$)" "$STUB_LOG"
}

@test "a disk without the installer's partitions stops the step before anything runs" {
  state_set disk.stage mounted
  LABELS="$DISK "$'\n'"${DISK}1 "
  run in_step step_disk
  [ "$status" -ne 0 ]
  [[ $output == *"no partition named gentooinstall-esp"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "no mount turns on online discard, which genfstab would copy into fstab" {
  for fs in ext4 xfs btrfs; do
    rm -rf "$GI_RUN_DIR/state" "$T/var" "$BATS_TEST_TMPDIR/mounted"
    : > "$STUB_LOG"
    CFG[filesystem]=$fs
    run in_step step_disk
    [ "$status" -eq 0 ]
    run ! grep -E '^mount .*[ ,]discard' "$STUB_LOG"
  done
  # On an SSD btrfs picks discard=async by itself, so every one of its mounts turns that off.
  [ "$(grep -c '^mount .*subvol=' "$STUB_LOG")" -eq 5 ]
  [ "$(grep -c '^mount .*nodiscard.*subvol=' "$STUB_LOG")" -eq 5 ]
}

@test "after relocation nothing destructive runs, even with leftovers mounted" {
  state_set disk.stage mounted
  TREE="$DISK disk "$'\n'"${DISK}1 part $T/efi"$'\n'"${DISK}2 part $T"
  mountpoint() { [[ ${!#} == "$T" || ${!#} == "$T/efi" ]]; }
  run in_step step_disk
  [ "$status" -eq 0 ]
  run ! grep -qE "^($destructive|umount|mount)( |\$)" "$STUB_LOG"
}

@test "refuses the live disk" {
  HW[live_disk]=gitestdisk
  run in_step step_disk
  [ "$status" -ne 0 ]
  [[ $output == *"holds the live system"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "refuses a partition or a device that isn't a whole disk" {
  TREE="$DISK part "
  run in_step step_disk
  [ "$status" -ne 0 ]
  [[ $output == *"is a part, not a whole disk"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "refuses a disk mounted or held by something else" {
  for tree in "${DISK}1 part /boot" "${DISK}2 part [SWAP]" "${DISK}2 part "$'\n'"/dev/mapper/vg-root lvm /" \
    "${DISK}2 part "$'\n'"/dev/mapper/other crypt "; do
    TREE="$DISK disk "$'\n'"$tree"
    run in_step step_disk
    [ "$status" -ne 0 ]
    [[ $output == *"is in use"* ]]
    [ ! -s "$STUB_LOG" ]
  done
}

@test "releases leftovers of an earlier attempt when the user agrees" {
  TREE="$DISK disk "$'\n'"${DISK}1 part $T/efi"$'\n'"${DISK}2 part "$'\n'"/dev/mapper/root crypt $T"
  ROOT_OPEN=1
  printf '%s\n' "$T/swap/swapfile" /dev/zram0 > "$STUB_OUT_DIR/swapon"
  mountpoint() { [[ ${!#} == "$T" ]]; }
  run in_step step_disk <<< y
  [ "$status" -eq 0 ]
  [ "$(head -4 "$STUB_LOG")" = "swapon --show=NAME --noheadings --raw
swapoff $T/swap/swapfile
umount -R $T
cryptsetup close root" ]
  grep -qx "sfdisk $BYID" "$STUB_LOG"
}

@test "with --yes, leftovers are released without asking" {
  GI_YES=1 ROOT_OPEN=1
  run in_step step_disk < /dev/null
  [ "$status" -eq 0 ]
  grep -qx 'cryptsetup close root' "$STUB_LOG"
}

@test "declining the release stops before anything destructive" {
  mountpoint() { [[ ${!#} == "$T" ]]; }
  run in_step step_disk <<< n
  [ "$status" -ne 0 ]
  run ! grep -qE "^($destructive|umount|swapoff)( |\$)" "$STUB_LOG"
}

@test "dry-run prints the commands, runs none and records placeholders" {
  GI_DRY_RUN=1 CFG[encryption]=luks2 CFG[filesystem]=btrfs CFG[swap]=file SECRET[luks_passphrase]=pw
  run --separate-stderr in_step step_disk
  [ "$status" -eq 0 ]
  # Only read-only queries ran.
  [ "$(cat "$STUB_LOG")" = "swapon --show=NAME --noheadings --raw" ]
  [[ $stderr == *"wipefs --all $BYID"* ]]
  [[ $stderr == *"sfdisk $BYID  # (stdin: "* ]]
  [[ $stderr == *"cryptsetup luksFormat --type luks2 --batch-mode --key-file=- \<root\ partition\>"* ]]
  [[ $stderr == *"btrfs filesystem mkswapfile --size 8192m $T/swap/swapfile"* ]]
  [ "$(state_get disk.root_uuid)" = '<root filesystem UUID>' ]
  [ "$(state_get disk.luks_uuid)" = '<LUKS UUID>' ]
  [ ! -e "$T/var/lib/gentooinstall" ]
}

# --- disk_resume_mount ----------------------------------------------------------

resume_setup() {
  ALL="$DISK "$'\n'"${DISK}1 $DISK gentooinstall-esp"$'\n'"${DISK}2 $DISK gentooinstall-root"$'\n'"/dev/sdz "$'\n'"/dev/sdz1 /dev/sdz "
  mkdir -p "$T/var/lib/gentooinstall"
  printf 'disk.stage=mounted\ndisk.swapfile=%s\n' "${1:-}" > "$T/var/lib/gentooinstall/state"
}

@test "resume mounts an ext4 install like the step does" {
  resume_setup
  echo ext4 > "$STUB_OUT_DIR/blkid"
  run in_step disk_resume_mount
  [ "$status" -eq 0 ]
  [ "$(calls 'mount|cryptsetup|swapon')" = "mount -o noatime ${DISK}2 $T
mount -o umask=0077 ${DISK}1 $T/efi" ]
}

@test "resume unlocks LUKS with the --secrets passphrase and mounts btrfs with the swap subvolume" {
  resume_setup /swap/swapfile
  GI_YES=1 SECRET[luks_passphrase]=secret
  blkid() { case ${!#} in "${DISK}2") echo crypto_LUKS ;; /dev/mapper/root) echo btrfs ;; esac; }
  run in_step disk_resume_mount
  [ "$status" -eq 0 ]
  [ "$(calls 'mount|cryptsetup|swapon')" = "cryptsetup open --key-file=- ${DISK}2 root
mount -o noatime\,compress=zstd\,nodiscard\,subvol=@ /dev/mapper/root $T
mount -o umask=0077 ${DISK}1 $T/efi
mount -o noatime\,compress=zstd\,nodiscard\,subvol=@home /dev/mapper/root $T/home
mount -o noatime\,compress=zstd\,nodiscard\,subvol=@var_log /dev/mapper/root $T/var/log
mount -o noatime\,compress=zstd\,nodiscard\,subvol=@var_cache /dev/mapper/root $T/var/cache
mount -o noatime\,compress=zstd\,nodiscard\,subvol=@snapshots /dev/mapper/root $T/.snapshots
mount -o noatime\,compress=zstd\,nodiscard\,subvol=@swap /dev/mapper/root $T/swap
swapon --show=NAME --noheadings --raw
swapon $T/swap/swapfile" ]
  run ! grep -q secret "$GI_LOG" "$STUB_LOG"
}

@test "resume asks for the LUKS passphrase once, and again after an empty answer" {
  resume_setup
  blkid() { case ${!#} in "${DISK}2") echo crypto_LUKS ;; *) echo ext4 ;; esac; }
  export STUB_STDIN_DIR=$BATS_TEST_TMPDIR/stdin
  mkdir -p "$STUB_STDIN_DIR"
  run in_step disk_resume_mount <<< $'\nsecret'
  [ "$status" -eq 0 ]
  grep -qx "cryptsetup open --key-file=- ${DISK}2 root" "$STUB_LOG"
  [ "$(cat "$STUB_STDIN_DIR/cryptsetup")" = secret ]
  grep -qx "mount -o noatime /dev/mapper/root $T" "$STUB_LOG"
}

@test "resume skips unlocking when root is already open" {
  resume_setup
  ROOT_OPEN=1
  blkid() { case ${!#} in "${DISK}2") echo crypto_LUKS ;; *) echo xfs ;; esac; }
  run in_step disk_resume_mount < /dev/null
  [ "$status" -eq 0 ]
  run ! grep -q '^cryptsetup open' "$STUB_LOG"
}

@test "resume refuses a root mapping opened from another partition" {
  resume_setup
  ROOT_OPEN=1 ROOT_ON=/dev/sdy2
  blkid() { echo crypto_LUKS; }
  run in_step disk_resume_mount < /dev/null
  [ "$status" -ne 0 ]
  [[ $output == *"/dev/mapper/root is open, but not from ${DISK}2"* ]]
  run ! grep -qE '^(mount|cryptsetup)' "$STUB_LOG"
}

@test "resume with --yes fails on a wrong passphrase" {
  resume_setup
  GI_YES=1 SECRET[luks_passphrase]=wrong
  export STUB_RC_cryptsetup=2
  blkid() { echo crypto_LUKS; }
  run in_step disk_resume_mount
  [ "$status" -ne 0 ]
  [[ $output == *"doesn't open ${DISK}2"* ]]
}

@test "resume with --yes needs the passphrase in the secrets file" {
  resume_setup
  GI_YES=1
  blkid() { echo crypto_LUKS; }
  run in_step disk_resume_mount
  [ "$status" -eq 2 ]
  [[ $output == *"needs luks_passphrase"* ]]
}

@test "resume lets the user pick among several installs" {
  resume_setup
  ALL+=$'\n'"/dev/sdy1 /dev/sdy gentooinstall-esp"$'\n'"/dev/sdy2 /dev/sdy gentooinstall-root"
  echo ext4 > "$STUB_OUT_DIR/blkid"
  run in_step disk_resume_mount <<< 2
  [ "$status" -eq 0 ]
  grep -qx "mount -o noatime /dev/sdy2 $T" "$STUB_LOG"
  grep -qx "mount -o umask=0077 /dev/sdy1 $T/efi" "$STUB_LOG"
}

@test "resume refuses to guess among several installs with --yes" {
  resume_setup
  GI_YES=1
  ALL+=$'\n'"/dev/sdy2 /dev/sdy gentooinstall-root"
  run in_step disk_resume_mount
  [ "$status" -ne 0 ]
  [[ $output == *"Several disks hold an install"* ]]
}

@test "resume fails without an install" {
  ALL="$DISK "$'\n'"${DISK}1 $DISK "
  run in_step disk_resume_mount
  [ "$status" -ne 0 ]
  [[ $output == *"no install to resume"* ]]
  [ ! -s "$STUB_LOG" ]
}
