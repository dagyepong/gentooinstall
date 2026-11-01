# shellcheck shell=bash
# Bootloader step: systemd-boot, GRUB or Limine on the ESP at /efi, with a fallback loader and an NVRAM entry.

step_define bootloader "Bootloader" \
  "Installs the bootloader to the EFI system partition and registers it with the firmware. A copy at the fallback path EFI/BOOT/BOOTX64.EFI boots laptops that forget their boot entries." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Bootloader"

# No GRUB_PLATFORMS: the amd64 profile already builds GRUB for "efi-64 pc", as the binary host does,
# and the Handbook's GRUB_PLATFORMS="efi-64" would make GRUB miss the binary host.
step_bootloader_packages() {
  if [[ ${CFG[bootloader]} == grub ]]; then
    echo sys-boot/grub
  elif [[ ${CFG[bootloader]} == limine ]]; then
    echo sys-boot/limine
  elif is_openrc; then
    echo sys-apps/systemd-utils
  else
    echo sys-apps/systemd
  fi
  echo sys-boot/efibootmgr
}

step_bootloader() {
  local win
  win=$(disk_windows_esp)
  if [[ ${CFG[bootloader]} == grub ]]; then
    _bootloader_grub_windows "${win#* }"
    # GRUB also has its BIOS platform installed, so name the target instead of letting it guess.
    _bootloader_efi run_chroot grub-install --target=x86_64-efi --efi-directory=/efi
    # The ESP is always this install's own, even beside another system, so no other loader is overwritten.
    run_chroot grub-install --target=x86_64-efi --efi-directory=/efi --removable
    run_chroot grub-mkconfig -o /boot/grub/grub.cfg
    if ((!GI_DRY_RUN)) && ! grep -q '^[[:space:]]*linux[[:space:]]' "$GI_TARGET/boot/grub/grub.cfg"; then
      die "grub-mkconfig found no kernel; $GI_TARGET/boot/grub/grub.cfg has no linux line."
    fi
    # grub-install names its directory and entry after GRUB_DISTRIBUTOR, Gentoo in /etc/default/grub.
    _bootloader_nvram_entry '\EFI\gentoo\grubx64.efi' gentoo
    _bootloader_nvram_check grubx64.efi
  elif [[ ${CFG[bootloader]} == limine ]]; then
    # sys-boot/limine installs the binary only to /usr/share/limine; the kernel step's
    # /etc/portage/env/sys-boot/limine redoes these copies on its updates. Both read /limine.conf.
    run_chroot install -D -m 0644 /usr/share/limine/BOOTX64.EFI /efi/EFI/limine/BOOTX64.EFI
    run_chroot install -D -m 0644 /usr/share/limine/BOOTX64.EFI /efi/EFI/BOOT/BOOTX64.EFI
    # limine.conf comes from the kernel step's kernel-install plugin.
    kernel_check || {
      kernel_reinstall
      kernel_check
    }
    _bootloader_nvram_entry '\EFI\limine\BOOTX64.EFI' Limine
    _bootloader_nvram_check '\EFI\limine\BOOTX64.EFI'
  else
    # Also installs the fallback EFI/BOOT/BOOTX64.EFI.
    _bootloader_efi run_chroot bootctl install --esp-path=/efi
    if [[ -n $win ]]; then _bootloader_windows_copy "${win%% *}"; fi
    # bootctl wrote loader.conf with the timeout commented out and no default, so the newest kernel boots.
    ensure_line /efi/loader/loader.conf "timeout 3"
    # The editor would let anyone at the keyboard boot with init=/bin/sh.
    ensure_line /efi/loader/loader.conf "editor no"
    run_chroot bootctl list
    kernel_check || {
      kernel_reinstall
      kernel_check
    }
    _bootloader_nvram_entry '\EFI\systemd\systemd-bootx64.efi' 'Linux Boot Manager'
    _bootloader_nvram_check systemd-bootx64.efi
  fi
}

# GRUB chainloads Windows' boot manager from its own ESP, found by its filesystem UUID. Without
# Windows an earlier answer's file goes.
_bootloader_grub_windows() { # FSUUID or nothing
  local f=/etc/grub.d/35_windows
  if [[ -z $1 ]]; then
    if [[ -e $GI_TARGET$f ]]; then run_cmd rm -f -- "$GI_TARGET$f"; fi
    return 0
  fi
  write_file "$f" 0755 << EOF
#!/bin/sh
# Written by gentooinstall: Windows, whose boot manager is on its own EFI system partition.
cat << 'END'
menuentry 'Windows' --class windows {
	insmod part_gpt
	insmod fat
	search --no-floppy --fs-uuid --set=root $1
	chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
END
EOF
}

# systemd-boot lists Windows only from its own ESP, so Windows' boot files are copied there.
# shortcut: a copy from install day; if a Windows update stops it starting from the menu, the firmware boot menu still starts it, and copying EFI/Microsoft again fixes the menu.
_bootloader_windows_copy() { # PARTUUID
  local dir=$GI_RUN_DIR/esp-probe rc=0
  run_cmd mkdir -p "$dir"
  run_cmd mount -o ro -t vfat "/dev/disk/by-partuuid/$1" "$dir"
  run_cmd rm -rf "$GI_TARGET/efi/EFI/Microsoft"
  run_cmd mkdir -p "$GI_TARGET/efi/EFI"
  run_cmd cp -rT "$dir/EFI/Microsoft" "$GI_TARGET/efi/EFI/Microsoft" || rc=$?
  run_cmd umount "$dir"
  return "$rc"
}

# Retries once after making EFI variables writable, as the Handbook's GRUB debugging notes say.
_bootloader_efi() { # RUNNER CMD [ARGS...]
  "$@" && return 0
  warn "$2 failed; making EFI variables writable and trying again."
  run_cmd mount -o remount,rw,nosuid,nodev,noexec --types efivarfs efivarfs /sys/firmware/efi/efivars
  "$@"
}

# Creates the firmware boot entry for LOADER from the live system, unless one for it on this ESP
# exists. Inside arch-chroot's PID namespace systemd sees a container, so bootctl skips EFI
# variables, and with --variables=yes it writes an entry without the ESP's partition.
_bootloader_nvram_entry() { # LOADER LABEL
  local uuid out part
  if ((!GI_DRY_RUN)); then
    uuid=$(findmnt -no PARTUUID -- "$GI_TARGET/efi")
    out=$(efibootmgr --verbose) || out=''
    # An entry left by an earlier install on this disk names a partition that's gone.
    if [[ -n $uuid ]] && grep -iF -- "$uuid" <<< "$out" | grep -iF -- "$1" > /dev/null; then return 0; fi
  fi
  # Partition 1 on a wiped disk; installs started before the disk step saved it are always that.
  part=$(state_get disk.esp_part)
  _bootloader_efi run_cmd efibootmgr --create --disk "${CFG[disk]}" --part "${part:-1}" --loader "$1" --label "$2"
}

# Warns instead of failing: the fallback loader still boots when the firmware drops the entry.
_bootloader_nvram_check() { # LOADER_FILE
  local out first
  ((GI_DRY_RUN)) && return 0
  out=$(efibootmgr --verbose) || out=''
  first=$(sed -n 's/^BootOrder: *\([0-9A-Fa-f]\{4\}\).*/\1/p' <<< "$out")
  if [[ -n $first ]] && grep -i "^Boot$first" <<< "$out" | grep -qiF "$1"; then return 0; fi
  warn "The firmware's first boot entry isn't $1. The fallback loader EFI/BOOT/BOOTX64.EFI should still boot; otherwise pick the new entry in the firmware boot menu."
}
