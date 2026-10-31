# shellcheck shell=bash
# Disk step: wipe, partition, encrypt, format and mount the chosen disk; mounting for --resume.

# Partitions get GPT names, so disk_resume_mount finds the install without any saved state:
#   gentooinstall-esp   partition 1, EFI System, 1 GiB, FAT32 labeled ESP, mounted at /efi
#   gentooinstall-root  partition 2, Linux root (x86-64), the rest, filesystem labeled root
# The state key disk.stage (partitioned, formatted, mounted) records progress. A retry skips the
# stages already finished, and once root is mounted nothing destructive runs again.

step_define disk "Disk preparation" \
  "Wipe the chosen disk, create a GPT with an EFI system partition and a root partition, encrypt root with LUKS2 if chosen, make the filesystems and mount them where the new system is built." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Disks"

step_disk() {
  local dev uuid luks='' ssd=no esp part root_dev
  [[ -n ${CFG[disk]:-} ]] || die "No disk chosen."
  dev=$(readlink -f -- "${CFG[disk]}")
  # A resume's state comes from the target, which gets it only after root is mounted. Anything
  # less there means a damaged state file, and going on would wipe the install being resumed.
  if ((GI_RESUME)) && [[ $(state_get disk.stage) != mounted ]]; then
    die "The saved install state doesn't say the disk was mounted, so going on would erase it. Start over without --resume."
  fi
  case $(state_get disk.stage) in
    '' | partitioned)
      # Before anything is wiped, so a missing passphrase can't stop the step halfway.
      if [[ ${CFG[encryption]} == luks2 && -z ${SECRET[luks_passphrase]:-} ]]; then die "The LUKS passphrase is missing."; fi
      _disk_check_free "$dev"
      if [[ -z $(state_get disk.stage) ]]; then _disk_partition "$dev"; fi
      ;;
  esac
  # Looked up on every run: kernel names saved before a retry or a reboot may now be another disk's.
  esp=$(dry_value '<ESP partition>' _disk_part "$dev" gentooinstall-esp)
  part=$(dry_value '<root partition>' _disk_part "$dev" gentooinstall-root)
  root_dev=$part
  if [[ ${CFG[encryption]} == luks2 ]]; then root_dev=/dev/mapper/root; fi
  if [[ $(state_get disk.stage) == partitioned ]]; then
    _disk_format "$esp" "$part" "$root_dev"
  elif [[ ${CFG[encryption]} == luks2 ]]; then
    # The Shell in the error menu may have closed it since.
    _disk_open_root "$part"
  fi
  _disk_mount_all "$root_dev" "$esp" "${CFG[filesystem]}" "${CFG[swap]}"
  state_set disk.stage mounted
  state_relocate_to_target

  if [[ ${CFG[swap]} == file ]]; then
    _disk_swapfile "${CFG[filesystem]}"
  else
    state_set disk.swapfile ''
  fi
  uuid=$(dry_value '<root filesystem UUID>' blkid -p -s UUID -o value "$root_dev")
  state_set disk.root_uuid "$uuid"
  if [[ ${CFG[encryption]} == luks2 ]]; then luks=$(dry_value '<LUKS UUID>' cryptsetup luksUUID "$part"); fi
  state_set disk.luks_uuid "$luks"
  if [[ $(cat -- "${GI_HOST_ROOT:-}/sys/block/${dev##*/}/queue/rotational" 2> /dev/null) == 0 ]]; then ssd=yes; fi
  state_set disk.ssd "$ssd"
}

# Refuses the live disk and disks in use; offers to release what an earlier attempt left behind.
_disk_check_free() { # DEV
  local dev=$1 tree name type mnt busy='' left=''
  [[ ${dev##*/} != "${HW[live_disk]:-}" ]] || die "$dev holds the live system. Choose another disk."
  tree=$(lsblk -nrpo NAME,TYPE,MOUNTPOINT "$dev") || die "Can't read $dev."
  read -r name type _ <<< "$tree"
  [[ $type == disk ]] || die "$dev is a $type, not a whole disk."
  while read -r name type mnt; do
    if [[ -n $mnt && $mnt != "$GI_TARGET" && $mnt != "$GI_TARGET"/* ]] ||
      [[ $type != disk && $type != part && $name != /dev/mapper/root ]]; then
      busy+=$'\n'"  $name ($type)${mnt:+ mounted at $mnt}"
    fi
  done <<< "$tree"
  [[ -z $busy ]] || die "$dev is in use:$busy"$'\n'"Stop using it (umount, swapoff, cryptsetup close, vgchange -an), then retry."
  if mountpoint -q -- "$GI_TARGET"; then left+=$'\n'"  $GI_TARGET is mounted"; fi
  if cryptsetup status root > /dev/null 2>&1; then left+=$'\n'"  /dev/mapper/root is open"; fi
  [[ -n $left ]] || return 0
  if ((!GI_YES)) && ! ui_yesno "Disk in use" "An earlier attempt left these behind:$left"$'\n\n'"Release them (swapoff, umount -R $GI_TARGET, cryptsetup close root) and go on?"; then
    die "Release them first, or choose another disk."
  fi
  _disk_release
}

# Only touches what this installer creates: swap files and mounts under the target, and the root mapping.
_disk_release() {
  local f
  while read -r f; do
    if [[ $f == "$GI_TARGET"/* ]]; then run_cmd swapoff "$f"; fi
  done < <(swapon --show=NAME --noheadings --raw)
  if mountpoint -q -- "$GI_TARGET"; then run_cmd umount -R "$GI_TARGET"; fi
  if cryptsetup status root > /dev/null 2>&1; then run_cmd cryptsetup close root; fi
}

_disk_partition() { # DEV
  local dev=$1 name type
  local -a old=()
  while read -r name type _; do
    if [[ $type == part ]]; then old+=("$name"); fi
  done < <(lsblk -nrpo NAME,TYPE,MOUNTPOINT "$dev")
  if ((${#old[@]})); then run_cmd wipefs --all "${old[@]}"; fi
  # The confirmed by-id path, so the replay script names this disk on any boot.
  run_cmd wipefs --all "${CFG[disk]}"
  run_stdin $'label: gpt\nsize=1GiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=gentooinstall-esp\ntype=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name=gentooinstall-root\n' \
    sfdisk "${CFG[disk]}"
  run_cmd udevadm settle
  state_set disk.stage partitioned
}

# Prints the partition of DEV with the GPT name NAME.
_disk_part() { # DEV NAME
  local name label
  while read -r name label; do
    if [[ $label == "$2" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(lsblk -nrpo NAME,PARTLABEL "$1")
  error "Found no partition named $2 on $1."
  return 1
}

_disk_format() { # ESP PART ROOT_DEV
  local esp=$1 part=$2 root_dev=$3 conf sv
  local -a opt=()
  # Clears what a failed earlier try of this stage made, so the mkfs tools never stop to ask.
  run_cmd wipefs --all "$esp" "$part"
  if [[ ${CFG[encryption]} == luks2 ]]; then
    run_stdin "${SECRET[luks_passphrase]}" cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$part"
    run_stdin "${SECRET[luks_passphrase]}" cryptsetup open --key-file=- "$part" root
  fi
  run_cmd mkfs.vfat -F 32 -n ESP "$esp"
  case ${CFG[filesystem]} in
    ext4) run_cmd mkfs.ext4 -L root "$root_dev" ;;
    xfs)
      # The Handbook's choice, bumped there only after GRUB was tested with it; a newer LTS
      # config on the ISO may enable features GRUB or the installed kernel can't read.
      # shortcut: pinned to one version, update it when the Handbook's Disks chapter does.
      conf=${GI_HOST_ROOT:-}/usr/share/xfsprogs/mkfs/lts_6.18.conf
      if [[ -f $conf ]]; then opt=(-c "options=$conf"); fi
      run_cmd mkfs.xfs "${opt[@]}" -L root "$root_dev"
      ;;
    btrfs)
      run_cmd mkfs.btrfs -L root "$root_dev"
      run_cmd mkdir -p "$GI_TARGET"
      run_cmd mount "$root_dev" "$GI_TARGET"
      run_cmd btrfs subvolume create "$GI_TARGET/@"
      while read -r sv _; do
        run_cmd btrfs subvolume create "$GI_TARGET/$sv"
      done < <(_disk_subvols "${CFG[swap]}")
      run_cmd umount "$GI_TARGET"
      ;;
    *) die "Unknown filesystem: ${CFG[filesystem]}" ;;
  esac
  state_set disk.stage formatted
}

# Prints the btrfs subvolumes other than @, each with its mount point.
_disk_subvols() { # SWAP
  printf '%s\n' '@home /home' '@var_log /var/log' '@var_cache /var/cache' '@snapshots /.snapshots'
  # btrfs can't snapshot a subvolume holding an active swap file, so it gets its own.
  if [[ $1 == file ]]; then printf '%s\n' '@swap /swap'; fi
}

# Mounts with the options the new system keeps (genfstab copies them), skipping what's already
# mounted, so retries and resume share it.
_disk_mount_all() { # ROOT_DEV ESP FS SWAP
  local sv dir
  # Since Linux 6.2 btrfs turns on discard=async by itself on SSDs, and genfstab would copy it;
  # TRIM runs on a schedule instead. ext4 and xfs never discard unless told to.
  local bt=noatime,compress=zstd,nodiscard
  if [[ $3 == btrfs ]]; then
    _disk_mount "$bt,subvol=@" "$1" "$GI_TARGET"
  else
    _disk_mount noatime "$1" "$GI_TARGET"
  fi
  _disk_mount umask=0077 "$2" "$GI_TARGET/efi"
  if [[ $3 == btrfs ]]; then
    while read -r sv dir; do
      _disk_mount "$bt,subvol=$sv" "$1" "$GI_TARGET$dir"
    done < <(_disk_subvols "$4")
  fi
}

_disk_mount() { # OPTIONS DEV DIR
  if mountpoint -q -- "$3"; then return 0; fi
  run_cmd mkdir -p "$3"
  run_cmd mount -o "$1" "$2" "$3"
}

# Creates and turns on the swap file, sized like RAM up to 8 GiB.
_disk_swapfile() { # FS
  local f=/swapfile mib=${HW[ram_mib]:-}
  if [[ $1 == btrfs ]]; then f=/swap/swapfile; fi
  if ! _disk_swap_active "$GI_TARGET$f"; then
    [[ $mib =~ ^[1-9][0-9]*$ ]] || die "The RAM size is unknown, so the swap file can't be sized."
    if ((mib > 8192)); then mib=8192; fi
    # A file left by a failed attempt may be incomplete.
    run_cmd rm -f "$GI_TARGET$f"
    if [[ $1 == btrfs ]]; then
      run_cmd btrfs filesystem mkswapfile --size "${mib}m" "$GI_TARGET$f"
    else
      run_cmd fallocate -l "${mib}MiB" "$GI_TARGET$f"
      run_cmd chmod 600 "$GI_TARGET$f"
      run_cmd mkswap "$GI_TARGET$f"
    fi
    run_cmd swapon "$GI_TARGET$f"
  fi
  state_set disk.swapfile "$f"
}

_disk_swap_active() { # PATH
  # Not grep -q: under pipefail, swapon killed by SIGPIPE would make an active file look inactive.
  swapon --show=NAME --noheadings --raw | grep -xF -- "$1" > /dev/null
}

# For --resume: finds the install by its GPT names, unlocks and mounts it like step_disk does,
# and turns its swap file back on.
disk_resume_mount() {
  local name pk label part esp fs root_dev swapfile
  local -a roots=() items=()
  local -A disk_of=() esp_on=()
  while read -r name pk label; do
    case $label in
      gentooinstall-root)
        roots+=("$name")
        disk_of[$name]=$pk
        items+=("$name" "on $pk" "Continue the install on $pk")
        ;;
      gentooinstall-esp) esp_on[$pk]=$name ;;
    esac
  done < <(lsblk -nrpo NAME,PKNAME,PARTLABEL)
  case ${#roots[@]} in
    0) die "Found no partition named gentooinstall-root, so there's no install to resume. Start over without --resume." ;;
    1) part=${roots[0]} ;;
    *)
      ((!GI_YES)) || die "Several disks hold an install (${roots[*]}). Resume without --yes to choose one."
      part=$(ui_menu "Resume" "Several disks hold an install. Which one should continue?" "${roots[0]}" "${items[@]}") || exit 130
      ;;
  esac
  esp=${esp_on[${disk_of[$part]}]:-}
  [[ -n $esp ]] || die "Found no partition named gentooinstall-esp next to $part, so the install can't be resumed. Start over without --resume."
  root_dev=$part
  fs=$(blkid -p -s TYPE -o value "$part") || die "$part holds no filesystem or LUKS volume, so the install can't be resumed. Start over without --resume."
  if [[ $fs == crypto_LUKS ]]; then
    root_dev=/dev/mapper/root
    _disk_open_root "$part"
    fs=$(blkid -p -s TYPE -o value "$root_dev") || die "$root_dev holds no filesystem, so the install can't be resumed. Start over without --resume."
  fi
  _disk_mount_all "$root_dev" "$esp" "$fs" none
  # The state is only on the target until core copies it back after this returns.
  swapfile=$(GI_RUN_DIR=$GI_TARGET/var/lib/gentooinstall state_get disk.swapfile)
  if [[ -n $swapfile ]]; then
    _disk_mount_all "$root_dev" "$esp" "$fs" file
    if ! _disk_swap_active "$GI_TARGET$swapfile"; then run_cmd swapon "$GI_TARGET$swapfile"; fi
  fi
}

# Opens PART as /dev/mapper/root unless that is open already.
_disk_open_root() { # PART
  if cryptsetup status root > /dev/null 2>&1; then
    # One opened from another disk would put the wrong filesystem under the target.
    lsblk -nrpo NAME "$1" | grep -xF /dev/mapper/root > /dev/null ||
      die "/dev/mapper/root is open, but not from $1. Close it (cryptsetup close root) and try again."
  else
    _disk_unlock "$1"
  fi
}

_disk_unlock() { # PART
  local rc
  while :; do
    while [[ -z ${SECRET[luks_passphrase]:-} ]]; do
      ((!GI_YES)) || die "The --secrets file needs luks_passphrase to resume." 2
      SECRET[luks_passphrase]=$(ui_password "Unlock the disk" "LUKS passphrase for $1:") || exit 130
    done
    rc=0
    run_stdin "${SECRET[luks_passphrase]}" cryptsetup open --key-file=- "$1" root || rc=$?
    ((rc)) || return 0
    # cryptsetup exits 2 for a wrong passphrase; anything else won't get better by asking again.
    ((rc == 2)) || die "cryptsetup open $1 failed with exit status $rc. The log has its message."
    ((!GI_YES)) || die "The LUKS passphrase from the --secrets file doesn't open $1."
    ui_msg "Unlock the disk" "That passphrase doesn't open $1. Try again."
    unset 'SECRET[luks_passphrase]'
  done
}
