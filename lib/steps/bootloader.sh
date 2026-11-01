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
  if [[ ${CFG[secure_boot]} == yes ]]; then printf '%s\n' sys-boot/shim sys-boot/mokutil app-crypt/sbsigntools; fi
}

# With Secure Boot, one key signs everything: Portage's secureboot flag signs the EFI programs as
# they install (systemd-boot among them), modules-sign the kernel modules built here, like
# NVIDIA's, and a kernel-install plugin each kernel copied to the ESP. gentoo-kernel-bin has no
# secureboot flag, so the plugin is what signs it. shim, which Microsoft signed, trusts the key
# once MokManager enrolled it.
GI_SB_KEY=/etc/portage/secureboot.pem

step_bootloader_portage() {
  local f=/etc/kernel/install.d/91-sbsign.install v
  if [[ ${CFG[secure_boot]} != yes ]]; then
    if [[ -e $GI_TARGET$f ]]; then run_cmd rm -f -- "$GI_TARGET$f"; fi
    return 0
  fi
  # Kept across reruns: the key MokManager enrolled must stay the one that signs.
  if [[ ! -s $GI_TARGET$GI_SB_KEY ]]; then
    run_chroot openssl req -new -nodes -utf8 -sha256 -x509 -days 36500 -subj "/CN=Secure Boot key of ${CFG[hostname]}" \
      -outform PEM -out "$GI_SB_KEY" -keyout "$GI_SB_KEY"
    run_chroot chmod 600 "$GI_SB_KEY"
  fi
  make_conf_use_add secureboot modules-sign
  for v in SECUREBOOT_SIGN_KEY SECUREBOOT_SIGN_CERT MODULES_SIGN_KEY MODULES_SIGN_CERT; do
    set_shell_var /etc/portage/make.conf "$v" "$GI_SB_KEY"
  done
  _bootloader_sbsign_plugin | write_file "$f" 0755
}

# After 90-loaderentry.install, which copies the kernel to the ESP.
_bootloader_sbsign_plugin() {
  cat << EOF
#!/bin/bash
# Written by gentooinstall. kernel-install runs this after every kernel install. It signs the
# kernel on the ESP with $GI_SB_KEY, which shim trusts once MokManager enrolled it.
key=$GI_SB_KEY
EOF
  cat << 'EOF'
[[ $1 == add && $KERNEL_INSTALL_LAYOUT == bls ]] || exit 0
k=$3/linux
[[ -f $k ]] || exit 0
# The world step may install the kernel before sbsigntools; the kernel step installs it again.
if ! command -v sbsign > /dev/null; then
  echo "91-sbsign.install: sbsign is missing, so $k isn't signed and won't start with Secure Boot on." >&2
  exit 0
fi
if sbverify --cert "$key" "$k" > /dev/null 2>&1; then exit 0; fi
# Signed beside it, flushed, then renamed, so a crash never leaves half a kernel.
sbsign --key "$key" --cert "$key" --output "$k.signed" "$k" && sync -- "$k.signed" && mv -f -- "$k.signed" "$k"
EOF
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
    # GRUB finds root by itself, but not the swap file to resume from.
    if [[ ${CFG[swap]} == hibernate ]]; then set_shell_var /etc/default/grub GRUB_CMDLINE_LINUX "$(kernel_resume_args)"; fi
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
    if [[ ${CFG[secure_boot]} == yes ]]; then
      _bootloader_shim
      _bootloader_nvram_entry '\EFI\systemd\shimx64.efi' 'Gentoo (shim)' '\EFI\systemd\systemd-bootx64.efi'
      _bootloader_nvram_check shimx64.efi
    else
      _bootloader_nvram_entry '\EFI\systemd\systemd-bootx64.efi' 'Linux Boot Manager'
      _bootloader_nvram_check systemd-bootx64.efi
    fi
  fi
}

# shim starts systemd-boot, named in the firmware entry; the fallback path, which has no entry,
# gets shim with a copy of systemd-boot under the name shim loads by default. Each place gets
# MokManager, which enrolls the key at the first start. Every kernel and systemd-boot must carry
# the key's signature, or Secure Boot refuses them.
_bootloader_shim() {
  local d code
  for d in systemd BOOT; do
    run_chroot install -D -m 0644 /usr/share/shim/mmx64.efi "/efi/EFI/$d/mmx64.efi"
  done
  run_chroot install -m 0644 /usr/share/shim/BOOTX64.EFI /efi/EFI/systemd/shimx64.efi
  run_chroot install -m 0644 /usr/share/shim/BOOTX64.EFI /efi/EFI/BOOT/BOOTX64.EFI
  run_chroot install -m 0644 /efi/EFI/systemd/systemd-bootx64.efi /efi/EFI/BOOT/grubx64.efi
  if ! _bootloader_signed; then
    kernel_reinstall
    _bootloader_signed || die "Not every kernel on the ESP is signed with $GI_SB_KEY, so Secure Boot would refuse it. See /var/log/installkernel.log in the new system."
  fi
  # Asked once: a second request would need the first one's code.
  if [[ -z $(state_get secureboot.mok_code) ]]; then
    run_chroot openssl x509 -in "$GI_SB_KEY" -outform DER -out /etc/portage/secureboot.der
    # Digits only: MokManager reads the keyboard as US English whatever the layout.
    printf -v code '%04d%04d' $((SRANDOM % 10000)) $((SRANDOM % 10000))
    run_chroot_stdin "$code"$'\n'"$code" mokutil --import /etc/portage/secureboot.der
    state_set secureboot.mok_code "$code"
  fi
}

# True when systemd-boot and every kernel on the ESP carry the Secure Boot key's signature.
_bootloader_signed() {
  local f
  ((!GI_DRY_RUN)) || return 0
  for f in "$GI_TARGET"/efi/EFI/systemd/systemd-bootx64.efi "$GI_TARGET"/efi/*/*/linux; do
    [[ -f $f ]] || continue
    run_chroot sbverify --cert "$GI_SB_KEY" "/${f#"$GI_TARGET"/}" || return 1
  done
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
_bootloader_nvram_entry() { # LOADER LABEL [LOAD_OPTION]
  local uuid out part
  local -a opt=()
  if ((!GI_DRY_RUN)); then
    uuid=$(findmnt -no PARTUUID -- "$GI_TARGET/efi")
    out=$(efibootmgr --verbose) || out=''
    # An entry left by an earlier install on this disk names a partition that's gone.
    if [[ -n $uuid ]] && grep -iF -- "$uuid" <<< "$out" | grep -iF -- "$1" > /dev/null; then return 0; fi
  fi
  # Partition 1 on a wiped disk; installs started before the disk step saved it are always that.
  part=$(state_get disk.esp_part)
  # shim takes the program it starts from the entry's load option.
  if [[ -n ${3:-} ]]; then opt=(--unicode "$3"); fi
  _bootloader_efi run_cmd efibootmgr --create --disk "${CFG[disk]}" --part "${part:-1}" --loader "$1" --label "$2" "${opt[@]}"
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
