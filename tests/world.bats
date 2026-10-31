#!/usr/bin/env bats
# Tests for lib/steps/world.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui config state world
  cfg_defaults_apply
  # Defined out of step order on purpose; output must follow GI_STEPS.
  step_desktop_packages() { printf '%s\n' kde-plasma/plasma-meta app-admin/sudo; }
  step_kernel_packages() { printf '%s\n\n%s\n' sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware; }
  step_tools_packages() { printf '%s\n' app-admin/sudo app-shells/bash-completion; }
  # Portage's files are already up to date; the last test uses the real one.
  portage_refresh() { :; }
}

emerge_line() { sed -n "s|^arch-chroot $GI_TARGET /bin/bash -c 'source /etc/profile && \(emerge .*\); exit \$?'\$|\1|p" "$GI_RUN_DIR/replay.sh"; }

@test "world_packages lists every step's packages in step order, then the extras, without duplicates" {
  CFG[packages]='app-editors/vim app-admin/sudo >=dev-lang/rust-1.80:0'
  run world_packages
  [ "$status" -eq 0 ]
  [ "$output" = 'sys-kernel/gentoo-kernel-bin
sys-kernel/linux-firmware
app-admin/sudo
app-shells/bash-completion
kde-plasma/plasma-meta
app-editors/vim
>=dev-lang/rust-1.80:0' ]
}

@test "world_packages fails when a step's package list fails" {
  step_tools_packages() { return 3; }
  run world_packages
  [ "$status" -eq 3 ]
}

@test "step_world installs @world and every package in one emerge call with binary packages" {
  CFG[packages]=app-editors/vim
  step_world
  [ "$(emerge_line)" = 'emerge --keep-going --verbose --update --deep --newuse --getbinpkg @world sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware app-admin/sudo app-shells/bash-completion kde-plasma/plasma-meta app-editors/vim' ]
  [ "$(wc -l < "$STUB_LOG")" -eq 1 ]
}

@test "step_world leaves out --getbinpkg without binary packages, and a rerun issues the same command" {
  CFG[binpkgs]=no
  step_world
  step_world
  [ "$(emerge_line | sort -u)" = 'emerge --keep-going --verbose --update --deep --newuse @world sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware app-admin/sudo app-shells/bash-completion kde-plasma/plasma-meta' ]
}

@test "a failed build fails the step and leaves the package for the error menu" {
  cp "$GI_HOME/tests/fixtures/emerge/fail-serial.txt" "$STUB_OUT_DIR/arch-chroot"
  export STUB_RC_arch_chroot=1
  run step_world
  [ "$status" -eq 1 ]
  grep -qx 'package=app-misc/hello-2.12.3' "$GI_RUN_DIR/last_failure"
  grep -qx 'exit=1' "$GI_RUN_DIR/last_failure"
}

@test "dry-run prints the emerge command and runs nothing" {
  GI_DRY_RUN=1
  run --separate-stderr step_world
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [[ $stderr == *"emerge --keep-going --verbose --update --deep --newuse --getbinpkg @world sys-kernel/gentoo-kernel-bin"* ]]
}

@test "a retry runs only emerge, and a resume with changed answers rewrites Portage's files first" {
  gi_load stage3 portage
  printf '%s\n' '  [1]   default/linux/amd64/23.0/desktop/plasma (stable) *' '  [5]   default/linux/amd64/23.0/desktop/gnome (stable)' > "$STUB_OUT_DIR/arch-chroot"
  cmds() { sed -n "s|^arch-chroot $GI_TARGET /bin/bash -c 'source /etc/profile && \(.*\); exit \$?'\$|\1|p" "$GI_RUN_DIR/replay.sh" | cut -d' ' -f1-3; }
  portage_configure 2> /dev/null
  : > "$GI_RUN_DIR/replay.sh"
  step_world
  step_world
  [ "$(cmds)" = $'emerge --keep-going --verbose\nemerge --keep-going --verbose' ]
  CFG[desktop]=gnome
  : > "$GI_RUN_DIR/replay.sh"
  step_world 2> /dev/null
  [ "$(cmds)" = $'eselect profile set\ngetuto\nemerge --keep-going --verbose' ]
  grep -q 'eselect profile set default/linux/amd64/23.0/desktop/gnome' "$GI_RUN_DIR/replay.sh"
}
