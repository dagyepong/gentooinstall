#!/usr/bin/env bats
# Tests for lib/steps/bootloader.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui config state disk kernel bootloader
  state_set windows.esp none
  cfg_defaults_apply
  mkdir -p "$GI_TARGET/efi/loader/entries" "$GI_TARGET/efi/abc/6.18.1" "$GI_TARGET/boot/grub"
  # What bootctl install leaves behind.
  printf '#timeout 3\n#console-mode keep\n' > "$GI_TARGET/efi/loader/loader.conf"
  printf 'linux /abc/6.18.1/linux\ninitrd /abc/6.18.1/initrd\n' > "$GI_TARGET/efi/loader/entries/abc-6.18.1.conf"
  touch "$GI_TARGET/efi/abc/6.18.1/linux" "$GI_TARGET/efi/abc/6.18.1/initrd"
  nvram 0003 '\EFI\systemd\systemd-bootx64.efi'
  CFG[disk]=/dev/disk/by-id/nvme-Disk_1
  # The ESP's PARTUUID, which the entries in nvram name.
  echo 0b2d > "$STUB_OUT_DIR/findmnt"
}

# The stub records each chroot script %q-quoted.
chroot_ran() { grep -qxF "arch-chroot $(printf '%q' "$GI_TARGET") /bin/bash -c $(printf '%q' "source /etc/profile && $1; exit \$?")" "$STUB_LOG"; }

# The runner runs every step with errexit on.
errexit() {
  set -e
  "$@"
}

nvram() { # FIRST_ID LOADER_PATH
  printf 'BootCurrent: 0001\nTimeout: 1 seconds\nBootOrder: %s,0001\nBoot0001* UEFI Shell\tFvVol(7cb8bdc9)/FvFile(7c04a583)\nBoot0003* Linux Boot Manager\tHD(1,GPT,0b2d,0x800,0x200000)/File(%s)\nBoot0004* gentoo\tHD(1,GPT,0b2d,0x800,0x200000)/File(%s)\n' \
    "$1" "$2" '\EFI\gentoo\grubx64.efi' > "$STUB_OUT_DIR/efibootmgr"
}

@test "no portage hook: GRUB_PLATFORMS stays at the profile's efi-64 pc, which the binary host builds" {
  CFG[bootloader]=grub
  run ! declare -F step_bootloader_portage
}

@test "packages per bootloader and init" {
  run errexit step_bootloader_packages
  [ "$output" = $'sys-apps/systemd-utils\nsys-boot/efibootmgr' ]
  CFG[init]=systemd
  run errexit step_bootloader_packages
  [ "$output" = $'sys-apps/systemd\nsys-boot/efibootmgr' ]
  CFG[bootloader]=grub
  run errexit step_bootloader_packages
  [ "$output" = $'sys-boot/grub\nsys-boot/efibootmgr' ]
  CFG[bootloader]=limine
  run errexit step_bootloader_packages
  [ "$output" = $'sys-boot/limine\nsys-boot/efibootmgr' ]
}

@test "systemd-boot: install to /efi, harden loader.conf, list entries, check NVRAM" {
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  chroot_ran 'bootctl install --esp-path=/efi'
  chroot_ran 'bootctl list'
  [ "$(cat "$GI_TARGET/efi/loader/loader.conf")" = $'#timeout 3\n#console-mode keep\ntimeout 3\neditor no' ]
  grep -qx 'efibootmgr --verbose' "$STUB_LOG"
  run ! grep -q 'emerge --config' "$STUB_LOG"
}

# The entry efibootmgr --create makes from the live system, %q-quoted as the stub records it.
created() { printf 'efibootmgr --create --disk /dev/disk/by-id/nvme-Disk_1 --part 1 --loader %q --label %q' "$1" "$2"; }

@test "systemd-boot: the firmware entry is created from the live system when none names this ESP" {
  # bootctl in arch-chroot's PID namespace writes no entry; this one is from an earlier install.
  echo feba97b8-dac0 > "$STUB_OUT_DIR/findmnt"
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  grep -qx 'findmnt -no PARTUUID -- '"$GI_TARGET"'/efi' "$STUB_LOG"
  grep -qxF "$(created '\EFI\systemd\systemd-bootx64.efi' 'Linux Boot Manager')" "$STUB_LOG"
  [ "$(grep -c -- --create "$STUB_LOG")" -eq 1 ]
}

@test "the firmware entry names the ESP's partition number, which free space makes other than 1" {
  echo feba97b8-dac0 > "$STUB_OUT_DIR/findmnt"
  state_set disk.esp_part 5
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  grep -qxF "$(created '\EFI\systemd\systemd-bootx64.efi' 'Linux Boot Manager' | sed 's/--part 1/--part 5/')" "$STUB_LOG"
}

@test "an entry that names this ESP and loader isn't created again, so a rerun adds none" {
  step_bootloader
  CFG[bootloader]=grub
  printf 'menuentry Gentoo {\n\tlinux /vmlinuz-6.18.1 root=UUID=x ro\n}\n' > "$GI_TARGET/boot/grub/grub.cfg"
  step_bootloader
  run ! grep -q -- --create "$STUB_LOG"
}

@test "GRUB: the firmware entry is created from the live system when grub-install made none" {
  CFG[bootloader]=grub
  printf 'menuentry Gentoo {\n\tlinux /vmlinuz-6.18.1 root=UUID=x ro\n}\n' > "$GI_TARGET/boot/grub/grub.cfg"
  printf 'BootCurrent: 0001\nBootOrder: 0001\nBoot0001* UEFI Shell\tFvVol(7cb8bdc9)/FvFile(7c04a583)\n' > "$STUB_OUT_DIR/efibootmgr"
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  grep -qxF "$(created '\EFI\gentoo\grubx64.efi' gentoo)" "$STUB_LOG"
}

@test "read-only EFI variables on the live system: remount them writable and create the entry once more" {
  echo other > "$STUB_OUT_DIR/findmnt"
  export STUB_RC_efibootmgr=1
  run errexit step_bootloader
  [ "$status" -ne 0 ]
  [ "$(grep -c -- --create "$STUB_LOG")" -eq 2 ]
  grep -qx 'mount -o remount\\,rw\\,nosuid\\,nodev\\,noexec --types efivarfs efivarfs /sys/firmware/efi/efivars' "$STUB_LOG"
}

@test "systemd-boot: running it twice keeps loader.conf the same" {
  step_bootloader
  cp "$GI_TARGET/efi/loader/loader.conf" "$BATS_TEST_TMPDIR/first"
  step_bootloader
  diff "$BATS_TEST_TMPDIR/first" "$GI_TARGET/efi/loader/loader.conf"
}

@test "systemd-boot: a missing entry is regenerated once, then the step fails loudly" {
  rm "$GI_TARGET"/efi/loader/entries/*.conf
  run errexit step_bootloader
  [ "$status" -ne 0 ]
  chroot_ran 'emerge --config sys-kernel/gentoo-kernel-bin'
  [[ $output == *"No systemd-boot entry"* ]]
}

@test "GRUB: install, removable fallback, config, NVRAM check" {
  CFG[bootloader]=grub
  nvram 0004 '\EFI\systemd\systemd-bootx64.efi'
  printf 'menuentry Gentoo {\n\tlinux /vmlinuz-6.18.1 root=UUID=x ro\n}\n' > "$GI_TARGET/boot/grub/grub.cfg"
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  chroot_ran 'grub-install --target=x86_64-efi --efi-directory=/efi'
  chroot_ran 'grub-install --target=x86_64-efi --efi-directory=/efi --removable'
  chroot_ran 'grub-mkconfig -o /boot/grub/grub.cfg'
  run ! grep -q bootctl "$STUB_LOG"
}

@test "beside Windows: GRUB gets a chainload entry before its config is made, systemd-boot a copy of its files" {
  local dir=$GI_RUN_DIR/esp-probe f=$GI_TARGET/etc/grub.d/35_windows
  state_set windows.esp '3333-p 3333-f'
  CFG[bootloader]=grub
  printf 'menuentry Gentoo {\n\tlinux /vmlinuz-6.18.1 root=UUID=x ro\n}\n' > "$GI_TARGET/boot/grub/grub.cfg"
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$f")" = 755 ]
  [ "$(sh "$f")" = "menuentry 'Windows' --class windows {
	insmod part_gpt
	insmod fat
	search --no-floppy --fs-uuid --set=root 3333-f
	chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}" ]
  run ! grep -q 'esp-probe' "$STUB_LOG"
  # systemd-boot finds Windows only on its own ESP. The mount stub mounts nothing, so this is what
  # Windows' ESP would show.
  mkdir -p "$dir/EFI/Microsoft/Boot"
  touch "$dir/EFI/Microsoft/Boot/bootmgfw.efi"
  : > "$STUB_LOG"
  CFG[bootloader]=systemd-boot
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  [ "$(grep -E '^(mount|umount|cp) ' "$STUB_LOG")" = "mount -o ro -t vfat /dev/disk/by-partuuid/3333-p $dir
umount $dir" ]
  [ -f "$GI_TARGET/efi/EFI/Microsoft/Boot/bootmgfw.efi" ]
  # Without Windows an earlier answer's GRUB file goes.
  state_set windows.esp none
  CFG[bootloader]=grub
  run --separate-stderr errexit step_bootloader
  [ ! -e "$f" ]
}

@test "GRUB: a config without a kernel fails" {
  CFG[bootloader]=grub
  printf '# nothing found\n' > "$GI_TARGET/boot/grub/grub.cfg"
  run errexit step_bootloader
  [ "$status" -eq 1 ]
  [[ $output == *"found no kernel"* ]]
}

@test "systemd-boot with LUKS: an initramfs that can't unlock is rebuilt once, then the step fails" {
  CFG[encryption]=luks2
  run errexit step_bootloader
  [ "$status" -ne 0 ]
  chroot_ran 'emerge --config sys-kernel/gentoo-kernel-bin'
  [[ $output == *"can't unlock the encrypted root"* ]]
}

@test "read-only EFI variables: remount them writable and try once more" {
  export STUB_RC_arch_chroot=1
  run errexit step_bootloader
  [ "$status" -ne 0 ]
  [ "$(grep -c 'bootctl\\ install' "$STUB_LOG")" -eq 2 ]
  grep -qx 'mount -o remount\\,rw\\,nosuid\\,nodev\\,noexec --types efivarfs efivarfs /sys/firmware/efi/efivars' "$STUB_LOG"
}

@test "NVRAM check warns when another loader boots first" {
  nvram 0001 '\EFI\systemd\systemd-bootx64.efi'
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  [[ $stderr == *"first boot entry isn't systemd-bootx64.efi"* ]]
}

# The kernel step's plugin, run over the entry in setup as kernel-install would.
limine_conf() {
  CFG[bootloader]=limine
  _kernel_limine_files
  KERNEL_INSTALL_LAYOUT=bls KERNEL_INSTALL_BOOT_ROOT=$GI_TARGET/efi "$GI_TARGET/etc/kernel/install.d/95-limine.install" add 6.18.1
}

@test "Limine: binary and fallback on the ESP, limine.conf checked, firmware entry created once" {
  limine_conf
  nvram 0003 '\EFI\limine\BOOTX64.EFI'
  echo feba97b8-dac0 > "$STUB_OUT_DIR/findmnt"
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  chroot_ran 'install -D -m 0644 /usr/share/limine/BOOTX64.EFI /efi/EFI/limine/BOOTX64.EFI'
  chroot_ran 'install -D -m 0644 /usr/share/limine/BOOTX64.EFI /efi/EFI/BOOT/BOOTX64.EFI'
  grep -qxF "$(created '\EFI\limine\BOOTX64.EFI' Limine)" "$STUB_LOG"
  run ! grep -q 'bootctl\|emerge --config' "$STUB_LOG"
  # A rerun finds the entry on this ESP.
  echo 0b2d > "$STUB_OUT_DIR/findmnt"
  : > "$STUB_LOG"
  errexit step_bootloader
  run ! grep -q -- --create "$STUB_LOG"
}

@test "Limine: a limine.conf without a bootable entry is regenerated once, then the step fails" {
  CFG[bootloader]=limine
  run errexit step_bootloader
  [ "$status" -ne 0 ]
  chroot_ran 'emerge --config sys-kernel/gentoo-kernel-bin'
  [[ $output == *"limine.conf doesn't have its kernel and initramfs on the ESP"* ]]
}

@test "Limine: NVRAM check warns when another loader boots first" {
  limine_conf
  nvram 0001 '\EFI\limine\BOOTX64.EFI'
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  [[ $stderr == *"first boot entry isn't \EFI\limine\BOOTX64.EFI"* ]]
}

@test "dry-run: prints everything, runs nothing" {
  GI_DRY_RUN=1
  cp "$GI_TARGET/efi/loader/loader.conf" "$BATS_TEST_TMPDIR/before"
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  [[ $stderr == *"bootctl install --esp-path=/efi"* ]]
  [[ $stderr == *"efibootmgr --create --disk /dev/disk/by-id/nvme-Disk_1 --part 1"* ]]
  [ ! -s "$STUB_LOG" ]
  diff "$BATS_TEST_TMPDIR/before" "$GI_TARGET/efi/loader/loader.conf"
  CFG[bootloader]=grub
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  CFG[bootloader]=limine
  run --separate-stderr errexit step_bootloader
  [ "$status" -eq 0 ]
  [[ $stderr == *"install -D -m 0644 /usr/share/limine/BOOTX64.EFI /efi/EFI/BOOT/BOOTX64.EFI"* ]]
  [[ $stderr == *"--loader \\\\EFI\\\\limine\\\\BOOTX64.EFI --label Limine"* ]]
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$GI_TARGET/efi/EFI" ]
}
