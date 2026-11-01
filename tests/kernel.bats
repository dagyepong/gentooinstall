#!/usr/bin/env bats
# Tests for lib/steps/kernel.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui config state disk kernel
  state_set windows.esp none
  cfg_defaults_apply
  state_set disk.root_uuid ROOTUUID
  state_set disk.luks_uuid LUKSUUID
}

# The stub records each chroot script %q-quoted.
chroot_ran() { grep -qxF "arch-chroot $(printf '%q' "$GI_TARGET") /bin/bash -c $(printf '%q' "source /etc/profile && $1; exit \$?")" "$STUB_LOG"; }

# A systemd-boot entry as kernel-install writes it, with its files on the ESP.
bls_entry() { # [MISSING_FILE]
  local d=$GI_TARGET/efi
  mkdir -p "$d/loader/entries" "$d/abc/6.18.1"
  printf 'title Gentoo\nversion 6.18.1\noptions root=UUID=ROOTUUID rw\nlinux /abc/6.18.1/linux\ninitrd /abc/6.18.1/initrd\n' \
    > "$d/loader/entries/abc-6.18.1.conf"
  touch "$d/abc/6.18.1/linux" "$d/abc/6.18.1/initrd"
  if [[ -n ${1:-} ]]; then rm "$d/abc/6.18.1/$1"; fi
}

@test "cmdline: plain root by filesystem UUID" {
  run kernel_cmdline
  [ "$output" = "root=UUID=ROOTUUID rw" ]
}

@test "cmdline: hibernation resumes from the swap file on the root filesystem, and dracut gets resume" {
  CFG[swap]=hibernate
  state_set disk.resume_offset 34816
  run kernel_cmdline
  [ "$output" = "root=UUID=ROOTUUID resume=UUID=ROOTUUID resume_offset=34816 rw" ]
  grep -qx 'add_dracutmodules+=" resume "' <(_kernel_dracut_conf)
  state_set disk.resume_offset ''
  run kernel_cmdline
  [ "$status" -ne 0 ]
  [[ $output == *"didn't record where the swap file starts"* ]]
  CFG[swap]=file
  run kernel_cmdline
  [ "$output" = "root=UUID=ROOTUUID rw" ]
  run ! grep -q resume <(_kernel_dracut_conf)
}

@test "cmdline: LUKS on OpenRC uses dracut's allow-discards, btrfs adds the subvolume" {
  CFG[encryption]=luks2 CFG[filesystem]=btrfs CFG[init]=openrc
  run kernel_cmdline
  [ "$output" = "rd.luks.uuid=LUKSUUID rd.luks.allow-discards=LUKSUUID root=UUID=ROOTUUID rootflags=subvol=@ rw" ]
}

@test "cmdline: LUKS on systemd uses rd.luks.options, and no discard when it's off" {
  CFG[encryption]=luks2 CFG[init]=systemd
  run kernel_cmdline
  [ "$output" = "rd.luks.uuid=LUKSUUID rd.luks.options=discard root=UUID=ROOTUUID rw" ]
  CFG[luks_discard]=no
  run kernel_cmdline
  [ "$output" = "rd.luks.uuid=LUKSUUID root=UUID=ROOTUUID rw" ]
}

@test "cmdline: no nvidia_drm.modeset, which every installed NVIDIA driver turns on itself" {
  HW[gpus]="intel nvidia"
  run kernel_cmdline
  [ "$output" = "root=UUID=ROOTUUID rw" ]
}

@test "cmdline: a missing root UUID stops the install, except in dry-run" {
  state_set disk.root_uuid ''
  run kernel_cmdline
  [ "$status" -eq 1 ]
  [[ $output == *"root filesystem UUID"* ]]
  GI_DRY_RUN=1
  run kernel_cmdline
  [ "$status" -eq 0 ]
}

@test "cmdline: LUKS without a recorded LUKS UUID stops the install, except in dry-run" {
  CFG[encryption]=luks2
  state_set disk.luks_uuid ''
  run kernel_cmdline
  [ "$status" -eq 1 ]
  [[ $output == *"LUKS UUID"* ]]
  CFG[encryption]=none
  run kernel_cmdline
  [ "$output" = "root=UUID=ROOTUUID rw" ]
  CFG[encryption]=luks2 GI_DRY_RUN=1
  run kernel_cmdline
  [ "$status" -eq 0 ]
}

@test "portage hook: systemd-boot on OpenRC" {
  CFG[filesystem]=btrfs CFG[encryption]=luks2
  step_kernel_portage
  run cat "$GI_TARGET/etc/portage/package.use/installkernel"
  [ "$output" = $'sys-kernel/installkernel dracut systemd systemd-boot\nsys-apps/systemd-utils boot kernel-install' ]
  grep -qx 'USE="dist-kernel"' "$GI_TARGET/etc/portage/make.conf"
  [ "$(cat "$GI_TARGET/etc/kernel/cmdline")" = "rd.luks.uuid=LUKSUUID rd.luks.allow-discards=LUKSUUID root=UUID=ROOTUUID rootflags=subvol=@ rw" ]
  [ "$(readlink "$GI_TARGET/etc/cmdline.d/00-installkernel.conf")" = ../kernel/cmdline ]
  [ "$(cat "$GI_TARGET/etc/cmdline.d/00-installkernel.conf")" = "$(cat "$GI_TARGET/etc/kernel/cmdline")" ]
  run cat "$GI_TARGET/etc/dracut.conf.d/gentooinstall.conf"
  [ "${lines[0]}" = 'hostonly="yes"' ]
  [[ $output == *'command -v cryptsetup >/dev/null; then add_dracutmodules+=" crypt "'* ]]
  [[ $output == *'command -v btrfs >/dev/null; then add_dracutmodules+=" btrfs "'* ]]
  [[ $output == *'i18n_vars="/etc/conf.d/keymaps:keymap-KEYMAP,extended_keymaps-EXT_KEYMAPS"'* ]]
}

@test "portage hook: systemd-boot on systemd with LUKS" {
  CFG[init]=systemd CFG[encryption]=luks2
  step_kernel_portage
  run cat "$GI_TARGET/etc/portage/package.use/installkernel"
  [ "$output" = $'sys-kernel/installkernel dracut systemd systemd-boot\nsys-apps/systemd boot\nsys-apps/systemd cryptsetup' ]
  run cat "$GI_TARGET/etc/dracut.conf.d/gentooinstall.conf"
  [[ $output != *i18n_vars* ]]
  [[ $output != *btrfs* ]]
}

@test "portage hook: systemd-boot on systemd without LUKS leaves systemd's cryptsetup flag alone" {
  CFG[init]=systemd
  step_kernel_portage
  [ "$(cat "$GI_TARGET/etc/portage/package.use/installkernel")" = $'sys-kernel/installkernel dracut systemd systemd-boot\nsys-apps/systemd boot' ]
}

@test "portage hook: GRUB" {
  CFG[bootloader]=grub CFG[init]=systemd
  step_kernel_portage
  [ "$(cat "$GI_TARGET/etc/portage/package.use/installkernel")" = 'sys-kernel/installkernel dracut grub' ]
  [ "$(cat "$GI_TARGET/etc/dracut.conf.d/gentooinstall.conf")" = 'hostonly="yes"' ]
}

@test "portage hook: running it twice changes nothing" {
  step_kernel_portage
  cp -r "$GI_TARGET/etc" "$BATS_TEST_TMPDIR/first"
  step_kernel_portage
  diff -r "$BATS_TEST_TMPDIR/first" "$GI_TARGET/etc"
}

@test "portage hook: Limine on OpenRC gets kernel-install's BLS layout, the plugin and the keyword" {
  CFG[bootloader]=limine
  step_kernel_portage
  [ "$(cat "$GI_TARGET/etc/portage/package.use/installkernel")" = $'sys-kernel/installkernel dracut systemd\nsys-apps/systemd-utils kernel-install' ]
  [ "$(cat "$GI_TARGET/etc/portage/package.accept_keywords/limine")" = 'sys-boot/limine ~amd64' ]
  [ "$(cat "$GI_TARGET/etc/kernel/install.conf.d/limine.conf")" = 'layout=bls' ]
  [ "$(stat -c %a "$GI_TARGET/etc/kernel/install.d/95-limine.install")" = 755 ]
  shellcheck "$GI_TARGET/etc/kernel/install.d/95-limine.install"
  # Portage sources it in the ebuild's bash, which defines EROOT, elog and eerror.
  shellcheck -s bash -e SC2154 "$GI_TARGET/etc/portage/env/sys-boot/limine"
  [ "$(cat "$GI_TARGET/etc/kernel/cmdline")" = "root=UUID=ROOTUUID rw" ]
}

@test "portage hook: Limine on systemd leaves systemd at the binary host's flags, except cryptsetup for LUKS" {
  CFG[bootloader]=limine CFG[init]=systemd
  step_kernel_portage
  [ "$(cat "$GI_TARGET/etc/portage/package.use/installkernel")" = 'sys-kernel/installkernel dracut systemd' ]
  CFG[encryption]=luks2
  step_kernel_portage
  [ "$(cat "$GI_TARGET/etc/portage/package.use/installkernel")" = $'sys-kernel/installkernel dracut systemd\nsys-apps/systemd cryptsetup' ]
}

@test "portage hook: Limine twice changes nothing, and another bootloader removes its files" {
  CFG[bootloader]=limine
  step_kernel_portage
  cp -r "$GI_TARGET/etc" "$BATS_TEST_TMPDIR/first"
  step_kernel_portage
  diff -r "$BATS_TEST_TMPDIR/first" "$GI_TARGET/etc"
  # A layout=bls left behind would send GRUB's kernels to the ESP.
  CFG[bootloader]=grub
  step_kernel_portage
  [ ! -e "$GI_TARGET/etc/portage/package.accept_keywords/limine" ]
  [ ! -e "$GI_TARGET/etc/kernel/install.conf.d/limine.conf" ]
  [ ! -e "$GI_TARGET/etc/kernel/install.d/95-limine.install" ]
  [ ! -e "$GI_TARGET/etc/portage/env/sys-boot/limine" ]
  [ "$(cat "$GI_TARGET/etc/portage/package.use/installkernel")" = 'sys-kernel/installkernel dracut grub' ]
}

@test "portage hook: every bootloader gets the kernel cleanup hook for both kernel packages" {
  local b
  for b in systemd-boot limine grub; do
    CFG[bootloader]=$b
    step_kernel_portage
    cmp "$GI_TARGET/etc/portage/env/sys-kernel/gentoo-kernel-bin" "$GI_TARGET/etc/portage/env/sys-kernel/gentoo-kernel"
    shellcheck -s bash -e SC2154 "$GI_TARGET/etc/portage/env/sys-kernel/gentoo-kernel-bin"
  done
}

# Runs the cleanup hook as Portage does after a kernel package's removal, with /efi, /boot,
# /usr/src and /lib/modules moved into the target. kernel-install removes the entry, as
# 90-loaderentry.install does.
kernel_cleanup() { # RUNNING_VERSION [EROOT [no-kernel-install]]
  (
    elog() { echo "elog: $*"; }
    ewarn() { echo "ewarn: $*"; }
    uname() { echo "$RUNNING"; }
    kernel-install() {
      echo "kernel-install $*"
      [[ ! -e $GI_TARGET/fail ]] || return 1
      rm -f "$GI_TARGET/efi/loader/entries/abc-$2.conf"
    }
    grub-mkconfig() {
      echo "grub-mkconfig $*"
      [[ ! -e $GI_TARGET/grub-fail ]]
    }
    RUNNING=$1 EROOT=${2-}
    # shellcheck source=/dev/null
    source <(sed "s|/efi/|$GI_TARGET/efi/|g; s|/boot/|$GI_TARGET/boot/|g; s|/usr/src/|$GI_TARGET/usr/src/|g; s|/lib/modules/|$GI_TARGET/lib/modules/|g" \
      "$GI_TARGET/etc/portage/env/sys-kernel/gentoo-kernel-bin")
    # Only the tools the hook needs, so no kernel-install of the machine running the tests is found.
    if [[ -n ${3:-} ]]; then
      unset -f kernel-install
      PATH=$BATS_TEST_TMPDIR/bin
    fi
    post_pkg_postrm
  )
}

@test "kernel cleanup hook: removes kernels whose package is gone and their modules, never the running, newest or an installed one" {
  local v d=$GI_TARGET/efi/loader/entries m=$GI_TARGET/lib/modules
  step_kernel_portage
  mkdir -p "$d" "$GI_TARGET/usr/src/linux-6.18.3" "$GI_TARGET/home/me/linux"
  for v in 6.18.1 6.18.2 6.18.3 6.18.4 6.18.10; do
    printf 'title Gentoo\nversion %s\n' "$v" > "$d/abc-$v.conf"
    mkdir -p "$m/$v/kernel"
  done
  printf 'title Memtest\nefi /EFI/memtest.efi\n' > "$d/memtest.conf"
  # Not a kernel release, or more than one name under /lib/modules: never removed.
  printf 'title Bad\nversion ..\n' > "$d/abc-dots.conf"
  printf 'title Bad\nversion 6.18.4/../..\n' > "$d/abc-slash.conf"
  # Portage keeps /lib/modules, so 6.18.1's build link dangles once its package is gone.
  ln -s ../../../usr/src/linux-6.18.1 "$m/6.18.1/build"
  ln -s "$GI_TARGET/home/me/linux" "$m/6.18.4/build"
  # 6.18.2 runs, 6.18.3 has its package, 6.18.4 was built by hand, and 6.18.10 is the newest
  # (by version, not by name).
  run kernel_cleanup 6.18.2
  [ "$status" -eq 0 ]
  [ "$output" = $'kernel-install remove 6.18.1\nelog: Removed the old kernel 6.18.1 and its modules.' ]
  [ "$(ls "$m")" = $'6.18.10\n6.18.2\n6.18.3\n6.18.4' ]
  # In a live system's chroot the running kernel isn't this system's, so 6.18.2, which last ran, stays.
  run kernel_cleanup 6.12.41-gentoo-live
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(ls "$m")" = $'6.18.10\n6.18.2\n6.18.3\n6.18.4' ]
  # After a reboot into 6.18.10, the next removal takes the kept 6.18.2.
  run kernel_cleanup 6.18.10
  [ "$output" = $'kernel-install remove 6.18.2\nelog: Removed the old kernel 6.18.2 and its modules.' ]
  [ "$(ls "$d")" = $'abc-6.18.10.conf\nabc-6.18.3.conf\nabc-6.18.4.conf\nabc-dots.conf\nabc-slash.conf\nmemtest.conf' ]
  [ "$(ls "$m")" = $'6.18.10\n6.18.3\n6.18.4' ]
  # An emerge --root into another system leaves this ESP and /lib/modules alone.
  printf 'title Gentoo\nversion 6.18.1\n' > "$d/abc-6.18.1.conf"
  mkdir "$m/6.18.1"
  run kernel_cleanup 6.18.10 /mnt/other/
  [ -z "$output" ]
  [ -d "$m/6.18.1" ]
  # A failed removal keeps the files and the modules and only warns: the package is gone either way.
  touch "$GI_TARGET/fail"
  run kernel_cleanup 6.18.10
  [ "$status" -eq 0 ]
  [ "$output" = $'kernel-install remove 6.18.1\newarn: kernel-install remove 6.18.1 failed, so that kernel and its modules stay.' ]
  [ -d "$m/6.18.1" ]
  # Without kernel-install, as on OpenRC after systemd-utils loses that flag, it does nothing.
  mkdir "$BATS_TEST_TMPDIR/bin"
  ln -s "$(type -P sed)" "$(type -P sort)" "$(type -P tail)" "$BATS_TEST_TMPDIR/bin/"
  run kernel_cleanup 6.18.10 '' no-kernel-install
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -d "$m/6.18.1" ]
}

@test "kernel cleanup hook: with GRUB removes an old kernel's files from /boot and its modules, then runs grub-mkconfig once" {
  local v b=$GI_TARGET/boot m=$GI_TARGET/lib/modules
  CFG[bootloader]=grub
  step_kernel_portage
  mkdir -p "$b/grub" "$GI_TARGET/usr/src/linux-6.18.3" "$GI_TARGET/home/me/linux" "$BATS_TEST_TMPDIR/bin"
  touch "$b/grub/grub.cfg" "$b/amd-uc.img"
  # installkernel's names, with the .old copies a same-version reinstall keeps.
  for v in 6.18.1 6.18.2 6.18.3 6.18.4 6.18.10; do
    touch "$b/vmlinuz-$v" "$b/initramfs-$v.img" "$b/System.map-$v" "$b/config-$v"
    mkdir -p "$m/$v/kernel"
  done
  touch "$b"/{vmlinuz,System.map,config}-6.18.1.old "$b/initramfs-6.18.1.img.old" "$b/vmlinuz-6.18.10.old"
  # The names systemd's kernel-install gives them.
  touch "$b/kernel-6.18.5" "$b/initramfs-6.18.5.img"
  mkdir "$m/6.18.5"
  ln -s ../../../usr/src/linux-6.18.1 "$m/6.18.1/build"
  ln -s "$GI_TARGET/home/me/linux" "$m/6.18.4/build"
  # OpenRC has no kernel-install with GRUB.
  ln -s "$(type -P sed)" "$(type -P sort)" "$(type -P tail)" "$(type -P rm)" "$BATS_TEST_TMPDIR/bin/"
  run kernel_cleanup 6.18.2 '' no-kernel-install
  [ "$status" -eq 0 ]
  [ "$output" = "elog: Removed the old kernel 6.18.1 and its modules.
elog: Removed the old kernel 6.18.5 and its modules.
grub-mkconfig -o $b/grub/grub.cfg" ]
  [ "$(LC_ALL=C ls "$b" | tr '\n' ' ')" = "$(printf '%s ' System.map-6.18.{10,2,3,4} amd-uc.img config-6.18.{10,2,3,4} grub \
    initramfs-6.18.{10,2,3,4}.img vmlinuz-6.18.10 vmlinuz-6.18.10.old vmlinuz-6.18.{2,3,4})" ]
  [ "$(ls "$m")" = $'6.18.10\n6.18.2\n6.18.3\n6.18.4' ]
  # After a reboot into 6.18.10, the next removal takes the kept 6.18.2, and then nothing is old.
  run kernel_cleanup 6.18.10
  [ "$output" = "elog: Removed the old kernel 6.18.2 and its modules.
grub-mkconfig -o $b/grub/grub.cfg" ]
  [ "$(LC_ALL=C ls "$b" | tr '\n' ' ')" = "$(printf '%s ' System.map-6.18.{10,3,4} amd-uc.img config-6.18.{10,3,4} grub \
    initramfs-6.18.{10,3,4}.img vmlinuz-6.18.10 vmlinuz-6.18.10.old vmlinuz-6.18.{3,4})" ]
  [ "$(ls "$m")" = $'6.18.10\n6.18.3\n6.18.4' ]
  # Booted into 6.18.3, the newest stays too, though no kernel-* name is left for the glob to match.
  run kernel_cleanup 6.18.3
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # An emerge --root into another system leaves this /boot and /lib/modules alone.
  touch "$b/vmlinuz-6.18.1"
  mkdir "$m/6.18.1"
  run kernel_cleanup 6.18.10 /mnt/other/
  [ -z "$output" ]
  [ -f "$b/vmlinuz-6.18.1" ]
  [ -d "$m/6.18.1" ]
  # A file rm can't remove keeps the modules; a failing grub-mkconfig only warns.
  mkdir "$b/config-6.18.1"
  touch "$GI_TARGET/grub-fail"
  run kernel_cleanup 6.18.10
  [ "$status" -eq 0 ]
  [[ $output == *"ewarn: Couldn't remove the old kernel 6.18.1 from /boot, so its modules stay too."* ]]
  [ "${lines[-2]}" = "grub-mkconfig -o $b/grub/grub.cfg" ]
  [ "${lines[-1]}" = "ewarn: grub-mkconfig failed, so the GRUB menu still lists the removed kernels. Run: grub-mkconfig -o $b/grub/grub.cfg" ]
  [ -d "$m/6.18.1" ]
}

@test "kernel cleanup hook: a kernel without modules in /lib/modules stays: a copy, one built without them, another system's" {
  local b=$GI_TARGET/boot d=$GI_TARGET/efi/loader/entries
  step_kernel_portage
  mkdir -p "$b/grub" "$d" "$GI_TARGET/lib/modules/6.18.10" "$GI_TARGET/usr/src/linux-6.18.10" "$BATS_TEST_TMPDIR/bin"
  ln -s "$(type -P sed)" "$(type -P sort)" "$(type -P tail)" "$(type -P rm)" "$BATS_TEST_TMPDIR/bin/"
  # Nothing is installed but 6.18.10, which runs; the rest is older and has no modules.
  touch "$b/grub/grub.cfg" "$b/vmlinuz-6.18.10" "$b/vmlinuz-6.18.9.bak" "$b/vmlinuz-6.0.8-mono" \
    "$b/initramfs-6.0.8-mono.img" "$b/vmlinuz" "$b/vmlinuz-lts" "$b/memtest86+x64.efi"
  cp -r "$b" "$BATS_TEST_TMPDIR/boot"
  run kernel_cleanup 6.18.10 '' no-kernel-install
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  diff -r "$BATS_TEST_TMPDIR/boot" "$b"
  # The same on the ESP, with another distribution's entry beside this system's.
  rm "$b/grub/grub.cfg"
  printf 'title Gentoo\nversion 6.18.10\n' > "$d/abc-6.18.10.conf"
  printf 'title Gentoo\nversion 6.0.8-mono\n' > "$d/abc-6.0.8-mono.conf"
  printf 'title Arch Linux\nversion 6.11.1-arch1-1\n' > "$d/arch.conf"
  run kernel_cleanup 6.18.10
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(ls "$d")" = $'abc-6.0.8-mono.conf\nabc-6.18.10.conf\narch.conf' ]
}

# Runs the update hook as Portage does after sys-boot/limine installs, the target as EROOT.
limine_update() {
  (
    elog() { echo "elog: $*"; }
    eerror() { echo "eerror: $*"; }
    EROOT=$GI_TARGET/
    source "$GI_TARGET/etc/portage/env/sys-boot/limine"
    post_pkg_postinst
  )
}

@test "Limine update hook: a new loader replaces Limine's copies on the ESP, never another loader or half a file" {
  local esp=$GI_TARGET/efi/EFI
  CFG[bootloader]=limine
  step_kernel_portage
  mkdir -p "$GI_TARGET/usr/share/limine"
  echo NEW > "$GI_TARGET/usr/share/limine/BOOTX64.EFI"
  # The first install, in the world step: the bootloader step makes the copies later.
  run limine_update
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$esp" ]
  mkdir -p "$esp/limine" "$esp/BOOT"
  echo OLD | tee "$esp/limine/BOOTX64.EFI" > "$esp/BOOT/BOOTX64.EFI"
  run limine_update
  [ "$status" -eq 0 ]
  [ "$(cat "$esp/limine/BOOTX64.EFI" "$esp/BOOT/BOOTX64.EFI")" = $'NEW\nNEW' ]
  [ -z "$(find "$esp" -name '*.new')" ]
  grep -qxF "sync -- $(printf %q "$esp/limine/BOOTX64.EFI.new")" "$STUB_LOG"
  # A fallback that isn't Limine's own copy belongs to another loader.
  echo OLD > "$esp/limine/BOOTX64.EFI"
  echo OTHER > "$esp/BOOT/BOOTX64.EFI"
  run limine_update
  [ "$(cat "$esp/limine/BOOTX64.EFI" "$esp/BOOT/BOOTX64.EFI")" = $'NEW\nOTHER' ]
  # A full ESP: the old loader stays whole.
  echo OLD > "$esp/limine/BOOTX64.EFI"
  ln -s /dev/full "$esp/limine/BOOTX64.EFI.new"
  run limine_update
  [ "$status" -eq 0 ]
  [[ $output == *"eerror: Couldn't copy /usr/share/limine/BOOTX64.EFI to $esp/limine/BOOTX64.EFI"* ]]
  [ "$(cat "$esp/limine/BOOTX64.EFI")" = OLD ]
  [ ! -e "$esp/limine/BOOTX64.EFI.new" ] && [ ! -L "$esp/limine/BOOTX64.EFI.new" ]
}

# A BLS entry as systemd 261's 90-loaderentry.install writes it, microcode first.
bls_full_entry() { # VERSION
  local d=$GI_TARGET/efi
  mkdir -p "$d/loader/entries" "$d/abc/$1"
  printf '%s\n' '# Boot Loader Specification type#1 entry' 'title      Gentoo Linux' "version    $1" 'machine-id abc' \
    'sort-key   gentoo' 'options    root=UUID=ROOTUUID rw systemd.machine_id=abc' "linux      /abc/$1/linux" \
    "initrd     /abc/$1/microcode-amd" "initrd     /abc/$1/initrd" > "$d/loader/entries/abc-$1.conf"
  touch "$d/abc/$1/linux" "$d/abc/$1/microcode-amd" "$d/abc/$1/initrd"
}

# Runs the plugin as kernel-install does: COMMAND KERNEL-VERSION ENTRY-DIR, the layout in the environment.
limine_plugin() { # COMMAND [LAYOUT]
  KERNEL_INSTALL_LAYOUT=${2:-bls} KERNEL_INSTALL_BOOT_ROOT=$GI_TARGET/efi \
    "$GI_TARGET/etc/kernel/install.d/95-limine.install" "$1" 6.18.10 "$GI_TARGET/efi/abc/6.18.10"
}

limine_menu() { # VERSION...
  printf 'timeout: 3\neditor_enabled: no\n'
  for v; do
    printf '\n/Gentoo Linux %s\n    protocol: linux\n    path: boot():/abc/%s/linux\n' "$v" "$v"
    printf '    module_path: boot():/abc/%s/microcode-amd\n    module_path: boot():/abc/%s/initrd\n' "$v" "$v"
    printf '    cmdline: root=UUID=ROOTUUID rw systemd.machine_id=abc\n'
  done
}

@test "Limine plugin: limine.conf follows the entries on install and removal, newest kernel first" {
  CFG[bootloader]=limine
  step_kernel_portage
  bls_full_entry 6.18.9
  bls_full_entry 6.18.10
  limine_plugin add
  [ "$(cat "$GI_TARGET/efi/limine.conf")" = "$(limine_menu 6.18.10 6.18.9)" ]
  [ ! -e "$GI_TARGET/efi/limine.conf.new" ]
  # Flushed before the rename, so a crash after a kernel update never leaves an empty config.
  grep -qxF "sync -- $(printf %q "$GI_TARGET/efi/limine.conf.new")" "$STUB_LOG"
  # 90-loaderentry.install removed the entry first; kernel-install removes the directory afterwards.
  rm "$GI_TARGET/efi/loader/entries/abc-6.18.10.conf"
  limine_plugin remove
  [ "$(cat "$GI_TARGET/efi/limine.conf")" = "$(limine_menu 6.18.9)" ]
  # Other commands and layouts leave it alone.
  bls_full_entry 6.18.10
  limine_plugin inspect
  limine_plugin add uki
  [ "$(cat "$GI_TARGET/efi/limine.conf")" = "$(limine_menu 6.18.9)" ]
  # A write that fails, as on a full ESP, leaves the old config whole.
  ln -s /dev/full "$GI_TARGET/efi/limine.conf.new"
  run limine_plugin add
  [ "$status" -ne 0 ]
  [ "$(cat "$GI_TARGET/efi/limine.conf")" = "$(limine_menu 6.18.9)" ]
}

@test "Limine plugin: Windows comes last, chainloaded from its own ESP" {
  CFG[bootloader]=limine
  state_set windows.esp '3333-p 3333-f'
  step_kernel_portage
  shellcheck "$GI_TARGET/etc/kernel/install.d/95-limine.install"
  bls_full_entry 6.18.10
  limine_plugin add
  [ "$(cat "$GI_TARGET/efi/limine.conf")" = "$(limine_menu 6.18.10)

/Windows
    protocol: efi
    path: guid(3333-p):/EFI/Microsoft/Boot/bootmgfw.efi" ]
}

@test "Limine plugin: no initrd means no module_path, an entry without linux is left out, options lines join" {
  local d=$GI_TARGET/efi/loader/entries
  CFG[bootloader]=limine
  step_kernel_portage
  mkdir -p "$d"
  printf 'title Gentoo\nversion 6.18.2\noptions root=UUID=R\noptions rw quiet\nlinux /abc/6.18.2/linux\n' > "$d/abc-6.18.2.conf"
  printf 'title Other\nversion 7.0\nefi /EFI/other.efi\n' > "$d/other.conf"
  limine_plugin add
  [ "$(cat "$GI_TARGET/efi/limine.conf")" = "$(printf 'timeout: 3\neditor_enabled: no\n\n/Gentoo 6.18.2\n    protocol: linux\n    path: boot():/abc/6.18.2/linux\n    cmdline: root=UUID=R rw quiet')" ]
}

@test "Limine plugin: a \${ in a command line fails the kernel install instead of a config Limine stops on" {
  CFG[bootloader]=limine
  step_kernel_portage
  bls_full_entry 6.18.9
  limine_plugin add
  cp "$GI_TARGET/efi/limine.conf" "$BATS_TEST_TMPDIR/before"
  sed -i 's/^options .*/& init=${X/' "$GI_TARGET/efi/loader/entries/abc-6.18.9.conf"
  run --separate-stderr limine_plugin add
  [ "$status" -eq 1 ]
  [[ $stderr == *"contains \${, which Limine reads as a macro"* ]]
  cmp "$BATS_TEST_TMPDIR/before" "$GI_TARGET/efi/limine.conf"
}

# limine.conf as the plugin writes it from the BLS entries on the ESP.
limine_conf() {
  CFG[bootloader]=limine
  step_kernel_portage
  limine_plugin add
}

@test "step with Limine: the first limine.conf entry needs its kernel and initramfs on the ESP" {
  CFG[bootloader]=limine
  run kernel_check
  [ "$status" -eq 1 ]
  [[ $output == *"The first entry in $GI_TARGET/efi/limine.conf doesn't have its kernel and initramfs"* ]]
  bls_full_entry 6.18.9
  bls_full_entry 6.18.10
  limine_conf
  run step_kernel
  [ "$status" -eq 0 ]
  chroot_ran 'emerge --config sys-kernel/gentoo-kernel-bin'
  # The newest kernel boots by default, so an older one that works doesn't count.
  for f in initrd microcode-amd linux; do
    mv "$GI_TARGET/efi/abc/6.18.10/$f" "$BATS_TEST_TMPDIR/$f"
    run kernel_check
    [ "$status" -eq 1 ]
    mv "$BATS_TEST_TMPDIR/$f" "$GI_TARGET/efi/abc/6.18.10/$f"
  done
  rm "$GI_TARGET/efi/abc/6.18.9/initrd"
  run kernel_check
  [ "$status" -eq 0 ]
  # A path off the ESP, which Limine can't read here.
  sed -i '0,/path: boot():/s//path: guid(1234):/' "$GI_TARGET/efi/limine.conf"
  run kernel_check
  [ "$status" -eq 1 ]
}

@test "step with Limine and LUKS: lsinitrd checks the first entry's initramfs" {
  CFG[encryption]=luks2
  bls_full_entry 6.18.9
  bls_full_entry 6.18.10
  limine_conf
  printf '%s\n' '-rwxr-xr-x   1 root     root       158192 Oct 30 15:53 usr/bin/cryptsetup' > "$STUB_OUT_DIR/arch-chroot"
  run kernel_check
  [ "$status" -eq 0 ]
  grep -qxF "arch-chroot $GI_TARGET lsinitrd /efi/abc/6.18.10/initrd" "$STUB_LOG"
  : > "$STUB_OUT_DIR/arch-chroot"
  run kernel_check
  [ "$status" -eq 1 ]
  [[ $output == *"has no cryptsetup"* ]]
}

@test "dracut config adds crypt and btrfs only once their tools exist" {
  CFG[encryption]=luks2 CFG[filesystem]=btrfs
  _kernel_dracut_conf > "$BATS_TEST_TMPDIR/conf"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  run env -i PATH="$BATS_TEST_TMPDIR/bin" /bin/bash -c 'source "$1"; printf "%s" "$add_dracutmodules"' _ "$BATS_TEST_TMPDIR/conf"
  [ -z "$output" ]
  printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/bin/cryptsetup"
  printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/bin/btrfs"
  chmod +x "$BATS_TEST_TMPDIR/bin/cryptsetup" "$BATS_TEST_TMPDIR/bin/btrfs"
  run env -i PATH="$BATS_TEST_TMPDIR/bin" /bin/bash -c 'source "$1"; printf "%s" "$add_dracutmodules"' _ "$BATS_TEST_TMPDIR/conf"
  [ "$output" = " crypt  btrfs " ]
}

@test "packages: firmware, installkernel and the kernel; microcode, SOF and cryptsetup when needed" {
  HW[cpu_vendor]=amd HW[sof]=no
  run step_kernel_packages
  [ "$output" = $'sys-kernel/linux-firmware\nsys-kernel/installkernel\nsys-kernel/gentoo-kernel-bin' ]
  HW[cpu_vendor]=intel HW[sof]=yes CFG[encryption]=luks2 CFG[kernel]=gentoo-kernel
  run step_kernel_packages
  [ "$output" = $'sys-kernel/linux-firmware\nsys-kernel/installkernel\nsys-kernel/gentoo-kernel\nsys-firmware/intel-microcode\nsys-firmware/sof-firmware\nsys-fs/cryptsetup' ]
}

@test "step: rebuilds the initramfs, then finds the systemd-boot entry on the ESP" {
  bls_entry
  run step_kernel
  [ "$status" -eq 0 ]
  chroot_ran 'emerge --config sys-kernel/gentoo-kernel-bin'
}

@test "step: with two kernel slots installed, rebuilds each one's initramfs by version" {
  local p=$GI_TARGET/var/db/pkg/sys-kernel
  bls_entry
  # An LTS slot from packages, a newer slot after a sync, and the other kernel from an earlier answer.
  mkdir -p "$p"/{gentoo-kernel-bin-6.6.160,gentoo-kernel-bin-6.18.58-r1,gentoo-kernel-6.18.57,-MERGING-gentoo-kernel-bin-6.18.59,linux-firmware-20251010}
  run step_kernel
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--config' "$STUB_LOG")" -eq 3 ]
  chroot_ran 'emerge --config =sys-kernel/gentoo-kernel-6.18.57'
  chroot_ran 'emerge --config =sys-kernel/gentoo-kernel-bin-6.18.58-r1'
  chroot_ran 'emerge --config =sys-kernel/gentoo-kernel-bin-6.6.160'
  # The first failure fails the step.
  : > "$STUB_LOG"
  STUB_RC_arch_chroot=1 run kernel_reinstall
  [ "$status" -eq 1 ]
  [ "$(grep -c -- '--config' "$STUB_LOG")" -eq 1 ]
}

@test "step: a GRUB config left from an earlier answer goes, or the cleanup hook would look in /boot instead of the ESP" {
  bls_entry
  mkdir -p "$GI_TARGET/boot/grub"
  touch "$GI_TARGET/boot/grub/grub.cfg" "$GI_TARGET/boot/vmlinuz-6.18.1" "$GI_TARGET/boot/initramfs-6.18.1.img"
  CFG[bootloader]=grub
  run step_kernel
  [ "$status" -eq 0 ]
  [ -f "$GI_TARGET/boot/grub/grub.cfg" ]
  CFG[bootloader]=systemd-boot
  run step_kernel
  [ "$status" -eq 0 ]
  [ ! -e "$GI_TARGET/boot/grub/grub.cfg" ]
}

@test "step: fails when the entry is missing or its initramfs isn't on the ESP" {
  run step_kernel
  [ "$status" -ne 0 ]
  [[ $output == *"No systemd-boot entry"* ]]
  bls_entry initrd
  run step_kernel
  [ "$status" -ne 0 ]
  rm -r "$GI_TARGET/efi"
  bls_entry linux
  run step_kernel
  [ "$status" -ne 0 ]
}

@test "step with LUKS: the initramfs must hold the unlocker for the init system" {
  CFG[encryption]=luks2
  bls_entry
  # lsinitrd lines as dracut 112 prints them.
  printf '%s\n' 'crypt' '-rwxr-xr-x   1 root     root       158192 Oct 30 15:53 usr/bin/cryptsetup' > "$STUB_OUT_DIR/arch-chroot"
  run kernel_check
  [ "$status" -eq 0 ]
  grep -qxF "arch-chroot $GI_TARGET lsinitrd /efi/abc/6.18.1/initrd" "$STUB_LOG"
  # systemd's initramfs needs systemd-cryptsetup, which systemd only builds with USE=cryptsetup.
  CFG[init]=systemd
  run kernel_check
  [ "$status" -eq 1 ]
  [[ $output == *"has no systemd-cryptsetup, so it can't unlock"* ]]
  # The dracut module of that name, or its generator, doesn't count without the binary.
  printf '%s\n' 'systemd-cryptsetup' > "$STUB_OUT_DIR/arch-chroot"
  run kernel_check
  [ "$status" -eq 1 ]
  printf '%s\n' '-rwxr-xr-x   1 root     root        30000 Oct 30 20:47 usr/lib/systemd/system-generators/systemd-cryptsetup-generator' > "$STUB_OUT_DIR/arch-chroot"
  run kernel_check
  [ "$status" -eq 1 ]
  printf '%s\n' 'systemd-cryptsetup' '-rwxr-xr-x   1 root     root        79944 Oct 30 15:53 usr/lib/systemd/systemd-cryptsetup' > "$STUB_OUT_DIR/arch-chroot"
  run kernel_check
  [ "$status" -eq 0 ]
  # systemd 261 moved it to usr/bin.
  printf '%s\n' 'systemd-cryptsetup' '-rwxr-xr-x   1 root     root        85392 Oct 30 20:47 usr/bin/systemd-cryptsetup' > "$STUB_OUT_DIR/arch-chroot"
  run kernel_check
  [ "$status" -eq 0 ]
  CFG[init]=openrc
  run kernel_check
  [ "$status" -eq 1 ]
  [[ $output == *"has no cryptsetup"* ]]
}

@test "step without LUKS doesn't look inside the initramfs" {
  bls_entry
  run kernel_check
  [ "$status" -eq 0 ]
  run ! grep -q lsinitrd "$STUB_LOG"
}

@test "step: an entry without an initrd line fails" {
  bls_entry
  sed -i '/^initrd/d' "$GI_TARGET"/efi/loader/entries/*.conf
  run kernel_check
  [ "$status" -eq 1 ]
}

@test "step: GRUB needs a kernel and an initramfs in /boot, under either installkernel name" {
  CFG[bootloader]=grub
  mkdir -p "$GI_TARGET/boot"
  run kernel_check
  [ "$status" -eq 1 ]
  [[ $output == *"where GRUB looks"* ]]
  touch "$GI_TARGET/boot/vmlinuz-6.18.1-gentoo-dist"
  run kernel_check
  [ "$status" -eq 1 ]
  touch "$GI_TARGET/boot/initramfs-6.18.1-gentoo-dist.img"
  run kernel_check
  [ "$status" -eq 0 ]
  mv "$GI_TARGET/boot/vmlinuz-6.18.1-gentoo-dist" "$GI_TARGET/boot/kernel-6.18.1-gentoo-dist"
  run kernel_check
  [ "$status" -eq 0 ]
}

@test "dry-run: prints everything, runs and writes nothing" {
  GI_DRY_RUN=1
  run --separate-stderr step_kernel_portage
  [ "$status" -eq 0 ]
  [[ $stderr == *"/etc/kernel/cmdline"* ]]
  [[ $stderr == *"/etc/portage/env/sys-kernel/gentoo-kernel-bin"* ]]
  run step_kernel
  [ "$status" -eq 0 ]
  CFG[bootloader]=limine
  run --separate-stderr step_kernel_portage
  [ "$status" -eq 0 ]
  [[ $stderr == *"/etc/kernel/install.d/95-limine.install"* ]]
  [ ! -s "$STUB_LOG" ]
  [ -z "$(ls -A "$GI_TARGET")" ]
}

@test "the newest kernel is accepted from testing, with its firmware and NVIDIA driver; the long-term one needs nothing" {
  local f=$GI_TARGET/etc/portage/package.accept_keywords/kernel
  CFG[kernel_version]=latest
  step_kernel_portage
  [ "$(cat "$f")" = 'sys-kernel/gentoo-kernel-bin ~amd64
sys-kernel/gentoo-kernel ~amd64
virtual/dist-kernel ~amd64
sys-kernel/linux-firmware ~amd64
x11-drivers/nvidia-drivers ~amd64' ]
  CFG[kernel_version]=lts
  step_kernel_portage
  [ ! -e "$f" ]
}
