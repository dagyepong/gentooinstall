# shellcheck shell=bash
# System step: fstab, machine ID, hostname, hosts, systemd presets and the root account.

step_define system "System configuration" \
  "Writes the filesystem table, the hostname and the hosts file, gives the machine its ID, enables systemd's preset services and sets or locks the root password." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/System"

# dracut reads fstab, and kernel-install names boot entries after the machine ID, while the kernel installs during world.
step_system_portage() {
  local fstab problems id=''
  # genfstab runs on the live system, which sees the target's mounts and their options. The filter
  # leaves out swap the live system has on other disks: a missing one would stall every boot.
  fstab=$(dry_value "# genfstab -U -f $GI_TARGET $GI_TARGET" genfstab -U -f "$GI_TARGET" "$GI_TARGET") || return
  if ((!GI_DRY_RUN)); then
    problems=$(_system_fstab_problems "$fstab")
    [[ -z $problems ]] || die "genfstab produced an fstab that won't work:"$'\n'"$problems"
  fi
  # btrfs turns on discard=async by itself on SSDs, and the kernel never lists nodiscard among the
  # mount options, so genfstab drops it; TRIM runs on a schedule instead.
  fstab=$(awk 'BEGIN { OFS = "\t" } $1 !~ /^#/ && $3 == "btrfs" && $4 !~ /(^|,)(no)?discard(=|,|$)/ { $4 = $4 ",nodiscard" } 1' <<< "$fstab")
  printf '%s\n' "$fstab" | write_file /etc/fstab
  if cfg_home_part && [[ ${CFG[encryption]} == luks2 ]]; then _system_home_crypt; fi
  if [[ -f $GI_TARGET/etc/machine-id ]]; then id=$(< "$GI_TARGET/etc/machine-id"); fi
  # Keep a valid ID: boot entries and their directory on the ESP are named after it.
  if [[ ! $id =~ ^[0-9a-f]{32}$ ]]; then
    id=$(< /proc/sys/kernel/random/uuid)
    printf '%s\n' "${id//-/}" | write_file /etc/machine-id 0444
  fi
}

# The boot unlocks /home with the key file on the encrypted root. The initramfs unlocks only the
# root its rd.luks.uuid names. OpenRC's dmcrypt service reads conf.d, systemd crypttab.
_system_home_crypt() {
  local uuid key=/etc/cryptsetup-keys.d/home.key
  uuid=$(state_get disk.home_luks_uuid)
  if is_systemd; then
    printf 'home UUID=%s %s luks%s\n' "$uuid" "$key" "$(if [[ ${CFG[luks_discard]} == yes ]]; then echo ,discard; fi)" |
      write_file /etc/crypttab
  else
    {
      printf '# Written by gentooinstall: /home, unlocked with the key file on the encrypted root.\ntarget=home\nsource=UUID=%s\nkey=%s\n' "$uuid" "$key"
      if [[ ${CFG[luks_discard]} == yes ]]; then echo "options='--allow-discards'"; fi
    } | write_file /etc/conf.d/dmcrypt
  fi
}

# Prints one line per problem: a missing mount point or swap file, swap that isn't the install's
# own swap file, a device not given by UUID, or online discard.
_system_fstab_problems() { # FSTAB
  local dev mp fs opts mount o swapfile
  local -a want=(/ /efi) o_list=()
  local -A seen=()
  swapfile=$(state_get disk.swapfile)
  while read -r dev mp fs opts _; do
    [[ -z $dev || $dev == \#* ]] && continue
    # The swap file is listed by its path.
    if [[ $fs == swap ]]; then
      if [[ $dev == "$swapfile" ]]; then seen[$dev]=1; else echo "swap $dev is not this system's swap file"; fi
      continue
    fi
    seen[$mp]=1
    if [[ $dev != UUID=* ]]; then echo "$mp: $dev is not given by UUID"; fi
    IFS=, read -ra o_list <<< "$opts"
    for o in "${o_list[@]}"; do
      if [[ $o == discard || $o == discard=* ]]; then echo "$mp: has $o, but TRIM runs on a schedule"; fi
    done
  done <<< "$1"
  if [[ ${CFG[filesystem]} == btrfs ]]; then
    want+=(/home /var/log /var/cache /.snapshots)
    if cfg_swap_file; then want+=(/swap); fi
  fi
  if [[ -n $swapfile ]]; then want+=("$swapfile"); fi
  if cfg_home_part; then want+=(/home); fi
  for mount in "${want[@]}"; do
    [[ -n ${seen[$mount]:-} ]] || echo "no entry for $mount"
  done
}

step_system() {
  local h=${CFG[hostname]}
  printf '%s\n' "$h" | write_file /etc/hostname
  # NetworkManager on Gentoo reads the hostname from this file, which the stage3 sets to localhost.
  if is_openrc; then set_shell_var /etc/conf.d/hostname hostname "$h"; fi
  # OpenRC needs the hostname in /etc/hosts.
  printf '127.0.0.1\t%s localhost\n::1\t\t%s localhost\n' "$h" "$h" | write_file /etc/hosts
  # OpenRC's dmcrypt service unlocks /home with its key file before localmount mounts it.
  if cfg_home_part && [[ ${CFG[encryption]} == luks2 ]] && is_openrc; then service_enable dmcrypt boot; fi
  # No systemd-firstboot, systemd-machine-id-setup or dbus-uuidgen: the hook above wrote the machine ID,
  # and the locale step and this one write every file they would.
  if is_systemd; then run_chroot systemctl preset-all --preset-mode=enable-only; fi
  if [[ ${CFG[root]} == locked ]]; then
    run_chroot passwd -l root
  else
    run_chroot_stdin "root:${SECRET[root_password]}"$'\n' chpasswd
  fi
}
