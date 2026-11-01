#!/usr/bin/env bats
# Tests for lib/steps/finish.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui state config disk finish desktop hardware
  state_set windows.esp none
  CFG[users]="larry alice"
  cfg_defaults_apply
  world_packages() { printf '%s\n' kde-plasma/plasma-meta '>=app-editors/vim-9.1:0::gentoo'; }
  echo format=1 > "$GI_RUN_DIR/config"
  echo '#!/bin/bash' > "$GI_RUN_DIR/replay.sh"
  LOGS=$GI_TARGET/var/log/gentooinstall
  T=$(printf %q "$GI_TARGET")
}

chroot_line() { printf 'arch-chroot %q /bin/bash -c %q\n' "$GI_TARGET" "source /etc/profile && $*; exit \$?"; }

# Canned `emerge --pretend --depclean` output, in Portage's format, removing PACKAGE...
depclean_output() {
  {
    printf 'Calculating dependencies... done!\n>>> Calculating removal order...\n\n'
    printf '>>> These are the packages that would be unmerged:\n\n'
    for p; do printf ' %s\n    selected: 1.0 \n   protected: none \n     omitted: none \n\n' "$p"; done
    printf 'Number to remove:     %d\n' "$#"
  } > "$STUB_OUT_DIR/arch-chroot"
}

# A target as the earlier steps leave it, plus a log and state the summary reads.
fake_install() {
  local d
  state_set stage3.file stage3-amd64-desktop-openrc-20261027T170104Z.tar.xz
  for d in '' .asc .DIGESTS .sha256; do touch "$GI_TARGET/stage3-amd64-desktop-openrc-20261027T170104Z.tar.xz$d"; done
  touch "$GI_TARGET/keep.txt"
  mkdir -p "$GI_TARGET/home/larry" "$GI_TARGET/home/alice"
  mkdir -p "$GI_TARGET/var/db/pkg/sys-apps/which-2.23" "$GI_TARGET/var/db/pkg/app-text/tree-2.2.1" \
    "$GI_TARGET/var/db/pkg/x11-drivers/nvidia-drivers-595.104.02"
  touch "$GI_TARGET/var/db/pkg/sys-apps/which-2.23/BINPKGMD5" "$GI_TARGET/var/db/pkg/app-text/tree-2.2.1/BINPKGMD5"
  mkdir -p "$GI_RUN_DIR/build-logs"
  echo 'make: *** error' > "$GI_RUN_DIR/build-logs/app-misc_foo-1.0.log"
  state_set step.tools skipped
  mkdir -p "$GI_TARGET/var/lib/gentoo/news" "$GI_TARGET/var/db/repos/gentoo/metadata/news/2018-08-07-openssh-ldap-migration"
  echo 2018-08-07-openssh-ldap-migration > "$GI_TARGET/var/lib/gentoo/news/news-gentoo.unread"
  printf 'Title: Migration required for OpenSSH with LDAP\nAuthor: someone\n' \
    > "$GI_TARGET/var/db/repos/gentoo/metadata/news/2018-08-07-openssh-ldap-migration/2018-08-07-openssh-ldap-migration.en.txt"
  log INFO "gentooinstall started"
  log WARN "disk is small"
}

@test "depclean runs when its pretend run removes nothing this install chose" {
  depclean_output app-text/tree
  _finish_depclean
  diff -u <(chroot_line emerge --pretend --depclean
    chroot_line emerge --depclean) "$STUB_LOG"
  grep -q '^ app-text/tree$' "$GI_LOG"
}

@test "depclean is skipped when it would remove a chosen package, even a versioned atom" {
  depclean_output app-text/tree app-editors/vim
  run --separate-stderr _finish_depclean
  [ "$status" -eq 0 ]
  [[ $stderr == *"it would remove app-editors/vim, which this install chose"* ]]
  diff -u <(chroot_line emerge --pretend --depclean) "$STUB_LOG"
}

@test "a failing depclean pretend run fails the step" {
  export STUB_RC_arch_chroot=1
  run _finish_depclean
  [ "$status" -eq 1 ]
  run ! grep -q 'emerge\\ --depclean' "$STUB_LOG"
}

@test "the finish step cleans up, keeps the logs and writes the notes and summary" {
  fake_install
  depclean_output
  step_finish 2> "$BATS_TEST_TMPDIR/stderr"
  diff -u <(chroot_line emerge --pretend --depclean
    chroot_line emerge --depclean
    chroot_line emaint binhost --fix
    chroot_line eclean-dist --deep
    chroot_line eclean-pkg --deep
    chroot_line chown larry: /home/larry/first-steps.txt
    chroot_line chown alice: /home/alice/first-steps.txt) "$STUB_LOG"

  [ -z "$(find "$GI_TARGET" -maxdepth 1 -name 'stage3-*')" ]
  [ -f "$GI_TARGET/keep.txt" ]

  grep -qF '# emerge -avuDN @world' "$GI_TARGET/home/alice/first-steps.txt"
  grep -qF 'type sudo in front of them' "$GI_TARGET/home/larry/first-steps.txt"
  grep -qF '/var/log/gentooinstall/' "$GI_TARGET/home/larry/first-steps.txt"

  [ "$(stat -c %a "$LOGS")" = 700 ]
  [ -f "$LOGS/install.log" ]
  [ -f "$LOGS/config" ]
  [ -f "$LOGS/replay.sh" ]
  [ -f "$LOGS/build-logs/app-misc_foo-1.0.log" ]
  [ "$(cat "$LOGS/packages.txt")" = "app-text/tree-2.2.1 binary
sys-apps/which-2.23 binary
x11-drivers/nvidia-drivers-595.104.02 source" ]

  s=$(cat "$LOGS/summary.txt")
  [[ $s == *"Packages: 2 from binary packages, 1 built from source."* ]]
  [[ $s == *"Skipped steps: tools"* ]]
  [[ $s == *$'Warnings:\n  disk is small'* ]]
  [[ $s == *"  2018-08-07  Migration required for OpenSSH with LDAP"* ]]
  [[ $s =~ The\ install\ took\ 0h\ 0[0-9]m ]]
  grep -qF 'Packages: 2 from binary packages' "$BATS_TEST_TMPDIR/stderr"
}

@test "first-steps.txt: Windows in the menu with the BitLocker and clock notes, other systems through the firmware menu" {
  CFG[users]=larry
  _finish_first_steps
  run ! grep -qE 'Windows|firmware boot menu' "$GI_TARGET/home/larry/first-steps.txt"
  state_set windows.esp '3333-p 3333-f'
  CFG[disk_mode]=free
  _finish_first_steps
  local f=$GI_TARGET/home/larry/first-steps.txt
  grep -qF 'Windows is in the boot menu too. If it uses BitLocker, start it from the' "$f"
  grep -qF 'The hardware clock' "$f"
  grep -qF 'The systems that were on the disk before are still there.' "$f"
}

@test "a summary with nothing to report says so" {
  run _finish_summary ''
  [[ $output == *"Skipped steps: none"* ]]
  [[ $output == *"Warnings: none"* ]]
  [[ $output != *news* ]]
}

@test "a stage3 name that points elsewhere is never deleted" {
  touch "$BATS_TEST_TMPDIR/important"
  state_set stage3.file ../important
  _finish_rm_stage3
  state_set stage3.file stage3-x/../../important
  _finish_rm_stage3
  [ -f "$BATS_TEST_TMPDIR/important" ]
  touch "$GI_TARGET/important"
  state_set stage3.file important
  _finish_rm_stage3
  [ -f "$GI_TARGET/important" ]
}

@test "running the finish step twice works and doesn't nest the build logs" {
  fake_install
  depclean_output
  step_finish 2> /dev/null
  step_finish 2> /dev/null
  [ -f "$LOGS/build-logs/app-misc_foo-1.0.log" ]
  [ ! -e "$LOGS/build-logs/build-logs" ]
}

@test "dry-run prints the commands and changes nothing" {
  fake_install
  GI_DRY_RUN=1
  run --separate-stderr step_finish
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$LOGS" ]
  [ -f "$GI_TARGET/stage3-amd64-desktop-openrc-20261027T170104Z.tar.xz" ]
  [ ! -e "$GI_TARGET/home/larry/first-steps.txt" ]
  [[ $stderr == *"emerge --depclean"* ]]
  [[ $stderr == *"eclean-pkg --deep"* ]]
  [[ $stderr == *"first-steps.txt"* ]]
}

@test "finish_menu does nothing in dry-run" {
  GI_DRY_RUN=1
  finish_menu
  [ ! -s "$STUB_LOG" ]
}

@test "finish_menu with --yes swaps off, unmounts, closes LUKS and syncs, without asking" {
  GI_YES=1
  CFG[encryption]=luks2
  state_set disk.swapfile /swap/swapfile
  run --separate-stderr finish_menu < /dev/null
  [ "$status" -eq 0 ]
  diff -u <(printf '%s\n' "swapoff $(printf %q "$GI_TARGET/swap/swapfile")" "umount -R $T" \
    "cryptsetup close root" sync) "$STUB_LOG"
  [[ $stderr == *"Remove the USB stick"* ]]
}

@test "finish_menu reboots by default" {
  GI_UI=plain
  run --separate-stderr finish_menu <<< ''
  [ "$status" -eq 0 ]
  diff -u <(printf '%s\n' "umount -R $T" sync reboot) "$STUB_LOG"
  [[ $stderr == *"Remove the USB stick"* ]]
}

@test "finish_menu opens a shell in the new system, then exits without rebooting" {
  GI_UI=plain
  run --separate-stderr finish_menu <<< $'2\n3'
  [ "$status" -eq 0 ]
  diff -u <(printf '%s\n' "arch-chroot $T" "umount -R $T" sync) "$STUB_LOG"
  grep -qxF "# interactive: arch-chroot $T" "$GI_RUN_DIR/replay.sh"
}

@test "a busy target: no LUKS close, a message on how to finish, and --yes still exits 0" {
  GI_YES=1
  CFG[encryption]=luks2
  state_set disk.swapfile /swap/swapfile
  export STUB_RC_umount=32
  run --separate-stderr finish_menu
  [ "$status" -eq 0 ]
  diff -u <(printf '%s\n' "swapoff $(printf %q "$GI_TARGET/swap/swapfile")" "umount -R $T" sync) "$STUB_LOG"
  [[ $stderr == *"Couldn't unmount $GI_TARGET: a program still uses it"*"fuser -vm $GI_TARGET"* ]]
  [[ $stderr == *"run: umount -R $GI_TARGET && cryptsetup close root"* ]]
  [[ $stderr != *"/dev/mapper/root"* ]]
}

@test "plain: shell, then reboot, with LUKS and a btrfs swap file" {
  GI_UI=plain
  CFG[encryption]=luks2 CFG[filesystem]=btrfs CFG[swap]=file
  state_set disk.swapfile /swap/swapfile
  run --separate-stderr finish_menu <<< $'2\nb\n1'
  [ "$status" -eq 0 ]
  diff -u <(printf '%s\n' "arch-chroot $T" "swapoff $(printf %q "$GI_TARGET/swap/swapfile")" "umount -R $T" \
    "cryptsetup close root" sync reboot) "$STUB_LOG"
  [[ $stderr == *"Type exit to come back to this menu."* ]]
  [[ $stderr == *Rebooting* ]]
}

@test "plain: a busy target still reboots, since the shutdown unmounts it" {
  GI_UI=plain
  CFG[encryption]=luks2
  export STUB_RC_umount=32
  run --separate-stderr finish_menu <<< '1'
  [ "$status" -eq 0 ]
  diff -u <(printf '%s\n' "umount -R $T" sync reboot) "$STUB_LOG"
  [[ $stderr == *"A reboot stops them and unmounts it safely."* ]]
}

@test "dialog: summary, Back, shell, then exit, with LUKS" {
  GI_UI=dialog
  CFG[encryption]=luks2
  mkdir -p "$LOGS"
  echo 'Gentoo is installed.' > "$LOGS/summary.txt"
  export DLG=$BATS_TEST_TMPDIR/dialog-replies
  # One "STATUS OUTPUT" line per dialog call: the summary, Back on the menu, Shell, Exit.
  printf '%s\n' '0 ' '1 ' '0 shell' '0 exit' > "$DLG"
  dialog() {
    local line
    if [[ ! -s $DLG ]]; then return 255; fi
    line=$(head -n 1 "$DLG")
    sed -i 1d "$DLG"
    printf '%s' "${line#* }" > "$STUB_OUT_DIR/dialog"
    STUB_RC_dialog=${line%% *} command dialog "$@"
  }
  run --separate-stderr finish_menu
  [ "$status" -eq 0 ]
  [ ! -s "$DLG" ]
  grep -m1 '^dialog ' "$STUB_LOG" | grep -qF -- "--textbox $(printf %q "$LOGS/summary.txt")"
  [ "$(grep -c -- '--title Install\\ complete' "$STUB_LOG")" -eq 3 ]
  diff -u <(printf '%s\n' "arch-chroot $T" "umount -R $T" "cryptsetup close root" sync) <(grep -v '^dialog ' "$STUB_LOG")
  [[ $stderr == *"Remove the USB stick before the next boot"* ]]
}

@test "the installer leaves a working directory inside the target before unmounting" {
  GI_YES=1
  mkdir -p "$GI_TARGET/home" "$GI_TARGET-other"
  cd "$GI_TARGET-other"
  finish_menu 2> /dev/null
  [ "$PWD" = "$GI_TARGET-other" ]
  cd "$GI_TARGET/home"
  finish_menu 2> /dev/null
  [ "$PWD" = / ]
}

@test "the duration counts from install.started, which survives a reboot of the live system" {
  log INFO "resumed after a reboot"
  state_set install.started $((EPOCHSECONDS - 7500))
  run _finish_summary ''
  [[ $output == *"The install took 2h 05m."* ]]
  state_set install.started $((EPOCHSECONDS + 600))
  run _finish_summary ''
  [[ $output == *"The install took 0h 00m."* ]]
}

@test "a damaged install.started gives 0h 00m and is never evaluated" {
  state_set install.started "x[\$(touch $BATS_TEST_TMPDIR/ran)]"
  run _finish_summary ''
  [[ $output == *"The install took 0h 00m."* ]]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "a desktop without a login screen gets told how to start it, in the summary and the notes" {
  CFG[desktop]=gnome CFG[display_manager]=none
  run _finish_summary ''
  [[ $output == *"no login screen"*"XDG_SESSION_TYPE=wayland dbus-run-session gnome-session"* ]]
  _finish_first_steps
  grep -qF 'dbus-run-session gnome-session' "$GI_TARGET/home/larry/first-steps.txt"
  CFG[desktop]=plasma
  run _finish_summary ''
  [[ $output == *"dbus-run-session startplasma-wayland"* ]]
  CFG[display_manager]=auto
  run _finish_summary ''
  [[ $output != *"login screen"* ]]
  _finish_first_steps
  run ! grep -q 'login screen' "$GI_TARGET/home/larry/first-steps.txt"
  [ "$(head -n 1 "$GI_TARGET/home/larry/first-steps.txt")" = 'First steps on your new Gentoo system' ]
}

@test "finish_menu's shell goes through the test safety net" {
  GI_UI=plain
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\ntouch "%s/ran"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/arch-chroot"
  chmod +x "$BATS_TEST_TMPDIR/bin/arch-chroot"
  PATH=$BATS_TEST_TMPDIR/bin:$PATH run --separate-stderr finish_menu <<< $'2\n3'
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
  [[ $stderr == *"safety net: refusing to run arch-chroot"* ]]
  diff -u <(printf '%s\n' "umount -R $T" sync) "$STUB_LOG"
}

@test "window managers always get their start command; on OpenRC it starts D-Bus and PipeWire first" {
  check() {
    CFG[desktop]=$1
    [ "$(_finish_desktop_hint | sed -n 3p)" = "  $2" ] || { echo "$1 ${CFG[init]}: got $(_finish_desktop_hint)"; return 1; }
  }
  CFG[init]=systemd
  check i3 'startx /usr/bin/i3'
  check dwm 'startx /usr/bin/dwm'
  check sway sway
  check dwl 'dwl -s "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=wlroots"'
  check hyprland start-hyprland
  check niri niri-session
  check mangowm mango
  CFG[init]=openrc
  # dex in i3's config starts PipeWire through its XDG autostart file, as the desktops do.
  check i3 'dbus-run-session startx /usr/bin/i3'
  check dwl "dbus-run-session sh -c 'gentoo-pipewire-launcher & exec dwl -s \"dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=wlroots\"'"
  check sway "dbus-run-session sh -c 'gentoo-pipewire-launcher & exec sway'"
  check niri "dbus-run-session sh -c 'gentoo-pipewire-launcher & exec niri --session'"
  [[ $(_finish_desktop_hint) == *"starts a D-Bus session and PipeWire for sound first"* ]]
  CFG[audio]=none
  check niri 'dbus-run-session niri --session'
  [[ $(_finish_desktop_hint) != *PipeWire* ]]
  # display_manager has no say: they never get a login screen.
  CFG[display_manager]=auto
  check mangowm 'dbus-run-session mango'
}

@test "the other desktops without a login screen start from the console too, and with one get no hint" {
  CFG[display_manager]=none
  check() {
    CFG[desktop]=$1
    [ "$(_finish_desktop_hint | sed -n 3p)" = "  $2" ] || { echo "$1 ${CFG[init]}: got $(_finish_desktop_hint)"; return 1; }
  }
  check xfce startxfce4
  # Their own XDG autostart starts PipeWire.
  check cinnamon 'dbus-run-session startx /usr/bin/cinnamon-session-cinnamon'
  check budgie 'dbus-run-session startbudgielabwc'
  check plasma 'dbus-run-session startplasma-wayland'
  CFG[init]=systemd
  check cinnamon 'startx /usr/bin/cinnamon-session-cinnamon'
  check budgie startbudgielabwc
  check gnome 'XDG_SESSION_TYPE=wayland dbus-run-session gnome-session'
  CFG[display_manager]=auto
  for d in xfce budgie cinnamon plasma gnome none; do
    CFG[desktop]=$d
    [ -z "$(_finish_desktop_hint)" ]
  done
}

@test "dwm and dwl users get told how to change config.h and rebuild; others don't" {
  fake_install
  CFG[desktop]=dwl
  _finish_first_steps
  local f=$GI_TARGET/home/alice/first-steps.txt
  grep -qxF '  # mv /etc/portage/savedconfig/gui-wm/dwl-* /etc/portage/savedconfig/gui-wm/dwl' "$f"
  grep -qF 'add the line "gui-wm/dwl savedconfig" to the file' "$f"
  grep -qxF '/etc/portage/package.use/dwl, then rebuild:' "$f"
  grep -qxF '  # emerge --oneshot gui-wm/dwl' "$f"
  grep -qF "gentoo-pipewire-launcher & exec dwl -s" "$f"
  CFG[desktop]=dwm
  _finish_first_steps
  grep -qxF '  # emerge --oneshot x11-wm/dwm' "$f"
  CFG[desktop]=sway
  _finish_first_steps
  run ! grep -q savedconfig "$f"
}

@test "Hyprland users get told where its config comes from and that Super+E's Dolphin isn't installed" {
  fake_install
  CFG[desktop]=hyprland
  _finish_first_steps
  local f=$GI_TARGET/home/larry/first-steps.txt
  grep -qxF 'Hyprland reads /etc/xdg/hypr/hyprland.lua while ~/.config/hypr/hyprland.lua' "$f"
  grep -qxF '  # emerge --ask kde-apps/dolphin' "$f"
  CFG[desktop]=sway
  _finish_first_steps
  run ! grep -q Hyprland "$f"
}

@test "with Limine the notes say where its menu comes from, and that loader updates are automatic" {
  fake_install
  CFG[bootloader]=limine
  _finish_first_steps
  local f=$GI_TARGET/home/larry/first-steps.txt
  grep -qxF '/etc/kernel/install.d/95-limine.install. An update of sys-boot/limine copies' "$f"
  run ! grep -q 'cp /usr/share/limine' "$f"
  CFG[bootloader]=systemd-boot
  _finish_first_steps
  run ! grep -q -i limine "$f"
}

@test "with every bootloader the notes say depclean removes old kernels and their modules" {
  local b f=$GI_TARGET/home/larry/first-steps.txt
  fake_install
  for b in systemd-boot grub limine; do
    CFG[bootloader]=$b
    _finish_first_steps
    # The kernel step's post_pkg_postrm hook does it, nothing to run by hand.
    grep -qxF 'The last command also takes old kernels out of the boot menu and deletes' "$f"
    grep -qxF 'until the next kernel removal.' "$f"
    run ! grep -q -e 'kernel-install remove' -e 'grub-mkconfig' "$f"
  done
}
