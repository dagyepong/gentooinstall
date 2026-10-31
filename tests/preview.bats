#!/usr/bin/env bats
# Tests for lib/steps/preview.sh, against real emerge --pretend output in tests/fixtures/preview/.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui config state world preview
  GI_UI=plain
  cfg_defaults_apply
  CALLS=$BATS_TEST_TMPDIR/calls
  step_kernel_packages() { echo sys-kernel/gentoo-kernel-bin; }
  questions_hub() { echo hub >> "$CALLS"; CFG[packages]=app-editors/vim; }
  cfg_save() { echo save >> "$CALLS"; }
  portage_refresh() { echo refresh >> "$CALLS"; }
  stage3_mirrors() { :; }
}

fixture() { echo "$GI_HOME/tests/fixtures/preview/$1.txt"; }
use_output() { cp "$(fixture "$1")" "$STUB_OUT_DIR/arch-chroot"; }
pretend_calls() { grep -c ' emerge --pretend ' "$STUB_LOG"; }

@test "summary of a mixed binary and source install" {
  run _preview_summary "$(fixture mixed)" 5
  [ "$output" = '169 packages, 2.4 GiB to download
    166 install as binaries
      3 build from source

Built from source (! = heavy):
! www-client/firefox           your USE differs: -dbus -gnome-shell -jpegxl -pgo. Use firefox-bin instead?
  app-misc/hello               no binary
  sys-kernel/linux-firmware    no binary' ]
}

@test "USE mismatches show the user's side of the flags, heavy packages come first, the rest is cut" {
  run _preview_summary "$(fixture usechange)" 3
  [ "${lines[2]}" = '      5 build from source' ]
  [ "${lines[4]}" = '! www-client/firefox           your USE differs: -dbus -gnome-shell -jpegxl -pgo. Use firefox-bin instead?' ]
  [ "${lines[6]}" = '  app-editors/vim              your USE differs: -crypt +lua' ]
  [ "${lines[7]}" = '  ...2 more (Full list)' ]
  run _preview_summary "$(fixture usechange)" 0
  [[ $output == *'  dev-vcs/git                  your USE differs: +tk'* ]]
  run ! grep -q 'more (Full list)' <<< "$output"
}

@test "nvidia, binary alternatives, -bin packages, virtuals and changed dependencies" {
  cat > "$BATS_TEST_TMPDIR/out" << 'EOF'
[ebuild  N     ] x11-drivers/nvidia-drivers-580.95.05-r1:0/580::gentoo  USE="X" 300000 KiB
[ebuild  N     ] sys-kernel/gentoo-kernel-6.18.57:6.18.57::gentoo  USE="initramfs" 150000 KiB
[ebuild  N     ] www-client/firefox-bin-159.0:rapid::gentoo  USE="wayland" 90000 KiB
[ebuild  N     ] virtual/dist-kernel-6.18.57:0/6.18.57::gentoo  0 KiB
[ebuild     U  ] dev-libs/foo-2.0::gentoo [1.0::gentoo] 100 KiB
[binary  N g   ] dev-libs/bar-1.0-1::gentoo  20 KiB

Total: 6 packages (1 upgrade, 5 new, 1 binary), Size of downloads: 1,234 KiB

!!! The following binary packages have been ignored due to changed dependencies:

     dev-libs/foo-2.0::gentoo

NOTE: The --binpkg-changed-deps=n option will prevent emerge
EOF
  run _preview_summary "$BATS_TEST_TMPDIR/out" 0
  [ "$output" = "6 packages, 1 MiB to download
      3 install as binaries
      3 build from source

Built from source (! = heavy):
! x11-drivers/nvidia-drivers   kernel module, always built here
  sys-kernel/gentoo-kernel     no binary. Use gentoo-kernel-bin instead?
  dev-libs/foo                 the binary's dependencies are out of date" ]
}

@test "a fresh GNOME + systemd pretend: every package line counted, USE reasons found" {
  # Captured 2026-10-30 from the gnome/systemd profile with both binary repos.
  run _preview_summary "$(fixture gnome-systemd)" 0
  [ "${lines[0]}" = '335 packages, 1.8 GiB to download' ]
  grep -q '^Total: 335 packages' "$(fixture gnome-systemd)"
  [ "${lines[1]}" = '    321 install as binaries' ]
  [ "${lines[2]}" = '     14 build from source' ]
  [[ $output == *'  sys-apps/systemd             your USE differs: +boot'$'\n'* ]]
  [[ $output == *'  dev-util/sysprof             your USE differs: +systemd'$'\n'* ]]
  [[ $output == *'  gnome-base/gnome-light       no binary'* ]]
}

@test "download sizes in KiB, MiB and GiB" {
  [ "$(_preview_size 512)" = '512 KiB' ]
  [ "$(_preview_size 2048)" = '2 MiB' ]
  [ "$(_preview_size 2566416)" = '2.4 GiB' ]
}

@test "bad atoms: unknown, masked and failing REQUIRED_USE, with extra packages marked" {
  CFG[packages]='app-misc/doesnotexist app-misc/abduco'
  [ "$(_preview_bad_atoms "$(fixture unknown)")" = '  app-misc/doesnotexist (one of your extra packages)' ]
  [ "$(_preview_bad_atoms "$(fixture masked)")" = '  app-misc/abduco (one of your extra packages)' ]
  [ "$(_preview_bad_atoms "$(fixture requireduse)")" = '  app-editors/vim' ]
  [ -z "$(_preview_bad_atoms "$(fixture blocker)")" ]
}

@test "autounmask suggestions are parsed per /etc/portage directory" {
  [ "$(_preview_autounmask "$(fixture blocker)")" = 'package.use >=sys-apps/dbus-1.16.2 systemd' ]
  [ "$(_preview_autounmask "$(fixture autounmask)")" = 'package.accept_keywords =app-misc/abduco-0.6 ~amd64
package.license >=www-plugins/chrome-binary-plugins-156.0.8078.47:stable google-chrome' ]
  [ -z "$(_preview_autounmask "$(fixture requireduse)")" ]
}

@test "Install runs the pretend on exactly the world list and goes on" {
  use_output mixed
  CFG[packages]='app-editors/vim >=dev-lang/rust-1.80:0'
  run --separate-stderr step_preview <<< 1
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "arch-chroot $GI_TARGET emerge --pretend --verbose --color=n --autounmask=y --update --deep --newuse --getbinpkg @world sys-kernel/gentoo-kernel-bin app-editors/vim \>=dev-lang/rust-1.80:0" ]
  [[ $stderr == *'169 packages, 2.4 GiB to download'* ]]
  grep -q 'emerge --pretend exited with status 0' "$GI_LOG"
}

@test "without binary packages the pretend has no --getbinpkg" {
  use_output mixed
  CFG[binpkgs]=no
  step_preview <<< 1 2> /dev/null
  run ! grep -q -- --getbinpkg "$STUB_LOG"
}

@test "Full list shows every source build and Portage's output, then asks again" {
  use_output usechange
  run --separate-stderr step_preview <<< $'3\n1'
  [ "$status" -eq 0 ]
  [[ $stderr == *'dev-vcs/git                  your USE differs: +tk'* ]]
  [[ $stderr == *'Portage output:'* ]]
  [ "$(pretend_calls)" -eq 1 ]
}

@test "Change settings runs the hub, saves, rewrites Portage config and checks again" {
  use_output mixed
  step_preview <<< $'2\n1' 2> /dev/null
  [ "$(cat "$CALLS")" = $'refresh\nhub\nsave\nrefresh' ]
  [ "$(pretend_calls)" -eq 2 ]
  grep -q 'gentoo-kernel-bin app-editors/vim$' <(tail -n 1 "$STUB_LOG")
}

@test "Portage's files are brought up to the saved answers before the first pretend" {
  # A settings change that failed halfway, or a --resume with a new --config, left them behind.
  portage_refresh() { echo refresh >> "$STUB_LOG"; }
  use_output mixed
  step_preview <<< 1 2> /dev/null
  [ "$(head -n 1 "$STUB_LOG")" = refresh ]
  [ "$(sed -n 2p "$STUB_LOG" | grep -c ' emerge --pretend ')" -eq 1 ]
}

@test "after the settings the mirrors are resolved, which measures them for fastest, before the answers are saved" {
  stage3_mirrors() { echo "mirrors ${CFG[mirror]}" >> "$CALLS"; }
  questions_hub() { echo hub >> "$CALLS"; CFG[mirror]=fastest; }
  use_output mixed
  step_preview <<< $'2\n1' 2> /dev/null
  [ "$(cat "$CALLS")" = $'refresh\nhub\nmirrors fastest\nsave\nrefresh' ]
}

@test "a failed mirror measurement leaves the new answers unsaved and Portage's files alone" {
  stage3_mirrors() { echo measure >> "$CALLS"; return 1; }
  questions_hub() { echo hub >> "$CALLS"; CFG[mirror]=fastest; }
  CFG[mirror]=cdn
  use_output mixed
  run -1 eval '(set -e; step_preview <<< 2)'
  [ "$(cat "$CALLS")" = $'refresh\nhub\nmeasure' ]
}

@test "Back also goes to the settings" {
  use_output mixed
  step_preview <<< $'b\n1' 2> /dev/null
  [ "$(cat "$CALLS")" = $'refresh\nhub\nsave\nrefresh' ]
}

@test "with --yes the summary is logged and nothing is asked" {
  use_output mixed
  GI_YES=1
  run step_preview < /dev/null
  [ "$status" -eq 0 ]
  grep -q '166 install as binaries' "$GI_LOG"
}

@test "a failed pretend shows Portage's message and the bad atom, and Abort stops" {
  use_output unknown
  export STUB_RC_arch_chroot=1
  CFG[packages]=app-misc/doesnotexist
  run --separate-stderr step_preview <<< 3
  [ "$status" -eq 130 ]
  [[ $stderr == *'emerge: there are no ebuilds to satisfy "app-misc/doesnotexist".'* ]]
  [[ $stderr == *'app-misc/doesnotexist (one of your extra packages)'* ]]
  [[ $stderr != *"Apply Portage's changes"* ]]
}

@test "Abort stops the installer at once, without the runner's error menu" {
  use_output unknown
  export STUB_RC_arch_chroot=1
  unset -f cfg_save
  gi_load config # the runner saves and reloads the real config file
  GI_STEPS=(preview)
  run --separate-stderr steps_run <<< 3
  [ "$status" -eq 130 ]
  [[ $stderr == *"Compile preview failed"* ]]
  [[ $stderr != *"Step failed"* ]]
  grep -q 'aborted by the user at the compile preview' "$GI_LOG"
  [ -z "$(state_get step.preview)" ]
}

@test "Ctrl+C during the pretend ends the step with 130 instead of showing the failed menu" {
  printf '\n\nExiting on signal 2\n' > "$STUB_OUT_DIR/arch-chroot"
  export STUB_RC_arch_chroot=130
  run --separate-stderr step_preview < /dev/null
  [ "$status" -eq 130 ]
  [[ $stderr != *"Compile preview failed"* ]]
  [ "$(pretend_calls)" -eq 1 ]
}

@test "a failed pretend offers Change settings and never writes package files on its own" {
  use_output autounmask
  export STUB_RC_arch_chroot=1
  run --separate-stderr step_preview <<< $'2\n4'
  [ "$status" -eq 130 ]
  [ "$(cat "$CALLS")" = $'refresh\nhub\nsave\nrefresh' ]
  [ ! -e "$GI_TARGET/etc/portage" ]
}

@test "approved autounmask changes are written and logged, then the pretend runs again" {
  # First pretend needs keyword and license changes; the second one succeeds.
  arch-chroot() {
    echo "arch-chroot $*" >> "$STUB_LOG"
    if (($(pretend_calls) == 1)); then
      cat "$(fixture autounmask)"
      return 1
    fi
    cat "$(fixture mixed)"
  }
  run --separate-stderr step_preview <<< $'1\n1'
  [ "$status" -eq 0 ]
  [ "$(cat "$GI_TARGET/etc/portage/package.accept_keywords/zz-autounmask")" = '=app-misc/abduco-0.6 ~amd64' ]
  [ "$(cat "$GI_TARGET/etc/portage/package.license/zz-autounmask")" = '>=www-plugins/chrome-binary-plugins-156.0.8078.47:stable google-chrome' ]
  grep -q "FILE $GI_TARGET/etc/portage/package.license/zz-autounmask" "$GI_LOG"
  [[ $stderr == *'package.accept_keywords: =app-misc/abduco-0.6 ~amd64'* ]]
  [ "$(pretend_calls)" -eq 2 ]
}

@test "applying the same suggestion twice doesn't duplicate it" {
  use_output autounmask
  _preview_unmask "$(fixture autounmask)" 2> /dev/null
  _preview_unmask "$(fixture autounmask)" 2> /dev/null
  [ "$(wc -l < "$GI_TARGET/etc/portage/package.accept_keywords/zz-autounmask")" -eq 1 ]
}

@test "with --yes a failed pretend fails the step without writing anything" {
  use_output masked
  export STUB_RC_arch_chroot=1
  GI_YES=1
  CFG[packages]=app-misc/abduco
  run --separate-stderr step_preview < /dev/null
  [ "$status" -eq 1 ]
  [[ $stderr == *'app-misc/abduco (one of your extra packages)'* ]]
  [ ! -e "$GI_TARGET/etc/portage" ]
}

@test "dry-run skips the pretend and says what it would run" {
  GI_DRY_RUN=1
  run --separate-stderr step_preview < /dev/null
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [[ $stderr == *'Dry run: skipping the compile preview'*'emerge --pretend --verbose --update --deep --newuse --getbinpkg @world sys-kernel/gentoo-kernel-bin'* ]]
}

@test "a desktop from an overlay: the summary says how many packages come from it, and lists them first" {
  run _preview_summary "$(fixture niri-openrc)" 3
  [ "${lines[0]}" = '198 packages, 1.6 GiB to download' ]
  [ "${lines[2]}" = '     16 build from source' ]
  [ "${lines[3]}" = "        2 of them from the guru overlay, which Gentoo doesn't review" ]
  [ "${lines[5]}" = '  gui-apps/fuzzel              from the guru overlay' ]
  [ "${lines[6]}" = '  gui-wm/niri                  from the guru overlay' ]
  [ "${lines[8]}" = '  ...13 more (Full list)' ]
  run _preview_summary "$(fixture gnome-systemd)" 0
  run ! grep -q overlay <<< "$output"
}
