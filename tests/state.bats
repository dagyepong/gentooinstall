#!/usr/bin/env bats
# Tests for lib/state.sh: state file, relocation, step runner and error menu.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui config state
  GI_UI=plain
  # steps_run asks for missing secrets before each step; these runs have them all.
  SECRET[root_password]=root-pw SECRET[user.larry.password]=larry-pw
  hw_disk_size_bytes() { echo $((500 * 1024 ** 3)); }
  for id in "${GI_STEPS[@]}"; do step_define "$id" "Title $id" "Why $id." "https://wiki.gentoo.org/$id"; done
  step_define hardware "Title hardware" "Why." "https://wiki.gentoo.org/hw" optional
  CALLS=$BATS_TEST_TMPDIR/calls
  for id in "${GI_STEPS[@]}"; do eval "step_$id() { echo $id >> \"\$CALLS\"; }"; done
}

@test "state_get and state_set keep single-line values" {
  [ "$(state_get missing fallback)" = fallback ]
  [ -z "$(state_get missing)" ]
  state_set disk.dev /dev/disk/by-id/x
  state_set disk.ssd yes
  state_set disk.dev /dev/disk/by-id/y
  [ "$(state_get disk.dev)" = /dev/disk/by-id/y ]
  [ "$(state_get disk.ssd)" = yes ]
  [ "$(grep -c '^disk.dev=' "$GI_RUN_DIR/state")" -eq 1 ]
  run state_set bad $'two\nlines'
  [ "$status" -ne 0 ]
  run state_set 'bad key' x
  [ "$status" -ne 0 ]
}

@test "skipped steps count as done" {
  state_step_done disk
  state_set step.hardware skipped
  state_step_is_done disk
  state_step_is_done hardware
  run state_step_is_done world
  [ "$status" -eq 1 ]
}

@test "step_define rejects unknown ids" {
  run step_define dsik "Disk" "Why" "url"
  [ "$status" -ne 0 ]
}

@test "relocation keeps a copy of state and config on the target" {
  cfg_defaults_apply
  state_set disk.dev /dev/x
  state_relocate_to_target
  dir=$GI_TARGET/var/lib/gentooinstall
  grep -qx 'disk.dev=/dev/x' "$dir/state"
  grep -qx 'hostname=gentoo' "$dir/config"
  [ "$(stat -c %a "$dir")" = 700 ]
  state_set disk.root_uuid abc
  grep -qx 'disk.root_uuid=abc' "$dir/state"
  [ "$(state_get disk.root_uuid)" = abc ]
}

@test "relocation does nothing in dry-run" {
  GI_DRY_RUN=1
  state_relocate_to_target 2> /dev/null
  [ ! -e "$GI_TARGET/var/lib/gentooinstall" ]
}

@test "steps_run runs every step in order and marks them done" {
  run steps_run
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "$(printf '%s\n' "${GI_STEPS[@]}")" ]
  for id in "${GI_STEPS[@]}"; do state_step_is_done "$id"; done
  grep -q '^# === Step 1/16: Title disk$' "$GI_RUN_DIR/replay.sh"
  grep -q '^# Handbook: https://wiki.gentoo.org/disk$' "$GI_RUN_DIR/replay.sh"
}

@test "steps_run skips steps already done" {
  for id in disk stage3 portage; do state_step_done "$id"; done
  run steps_run
  [ "$(head -1 "$CALLS")" = preview ]
  [ "$(wc -l < "$CALLS")" -eq 13 ]
}

@test "steps_run stops on an undefined step" {
  unset 'GI_STEP_TITLE[world]'
  run steps_run
  [ "$status" -ne 0 ]
  [[ $output == *"Step world isn't defined"* ]]
}

@test "a step stops at its first failing command and runs in a subshell" {
  step_stage3() {
    GI_LEAK=1
    false
    echo after >> "$CALLS"
  }
  run steps_run <<< 4
  [ "$status" -eq 130 ]
  [ "$(cat "$CALLS")" = disk ]
  [ -z "${GI_LEAK:-}" ]
  state_step_is_done disk
  run state_step_is_done stage3
  [ "$status" -eq 1 ]
}

@test "error menu: retry runs the step again" {
  step_world() {
    if [[ ! -e $BATS_TEST_TMPDIR/second ]]; then
      touch "$BATS_TEST_TMPDIR/second"
      return 1
    fi
    echo world >> "$CALLS"
  }
  run --separate-stderr steps_run <<< 1
  [ "$status" -eq 0 ]
  [[ $stderr == *"Title world, failed with exit status 1"* ]]
  [[ $stderr == *"Step failed"*"1) retry  Retry"* ]]
  [ "$(grep -c world "$CALLS")" -eq 1 ]
  state_step_is_done finish
}

@test "error menu: skip is only offered for optional steps" {
  step_hardware() { return 4; }
  run --separate-stderr steps_run <<< 4
  [ "$status" -eq 0 ]
  [ "$(state_get step.hardware)" = skipped ]
  [ "$(tail -1 "$CALLS")" = finish ]
  step_users() { return 1; }
  rm -f "$GI_RUN_DIR/state"
  run --separate-stderr steps_run <<< 4
  [ "$status" -eq 130 ]
  [[ $stderr != *Skip* ]]
}

@test "error menu: abort exits 130 and keeps the state" {
  step_portage() { return 1; }
  run steps_run <<< 4
  [ "$status" -eq 130 ]
  [ "$(state_get step.stage3)" = done ]
  [ -z "$(state_get step.portage)" ]
}

@test "error menu: log shows the failed package's build log" {
  step_world() {
    printf 'package=app-misc/hello-2.12.3\nbuild_log=%s/build.log\nexit=1\n' "$BATS_TEST_TMPDIR" > "$GI_RUN_DIR/last_failure"
    return 1
  }
  seq 1 100 | sed 's/^/build line /' > "$BATS_TEST_TMPDIR/build.log"
  run --separate-stderr steps_run < <(printf '2\n4\n')
  [ "$status" -eq 130 ]
  [[ $stderr == *"Package: app-misc/hello-2.12.3"* ]]
  [[ $stderr == *"Last 40 lines of $BATS_TEST_TMPDIR/build.log"*"build line 61"*"build line 100"* ]]
  [[ $stderr != *"build line 60"$'\n'* ]]
}

@test "error menu: log falls back to the install log" {
  step_disk() {
    log INFO "something went wrong here"
    return 1
  }
  run --separate-stderr steps_run < <(printf '2\n4\n')
  [[ $stderr == *"Last 40 lines of $GI_LOG"*"something went wrong here"* ]]
}

@test "error menu: shell is a live shell before stage3 and arch-chroot after" {
  step_disk() { return 1; }
  run --separate-stderr steps_run < <(printf '3\n4\n')
  [[ $stderr == *"Starting bash -i"*"test safety net: refusing to run bash"* ]]
  rm -f "$GI_RUN_DIR/state"
  step_disk() { :; }
  step_portage() { return 1; }
  run --separate-stderr steps_run < <(printf '3\n4\n')
  [[ $stderr == *"Starting arch-chroot $GI_TARGET"* ]]
  grep -qx "arch-chroot $GI_TARGET" "$STUB_LOG"
}

@test "answers a step saves with cfg_save reach the following steps" {
  step_preview() {
    CFG[browser]=none
    cfg_save
  }
  step_world() { echo "browser=${CFG[browser]}" >> "$CALLS"; }
  CFG[users]=larry
  run steps_run
  [ "$status" -eq 0 ]
  grep -qx 'browser=none' "$CALLS"
}

@test "steps_run locks the disk answers" {
  step_preview() {
    CFG[filesystem]=xfs
    cfg_save
  }
  CFG[users]=larry
  run steps_run
  [ "$status" -ne 0 ]
  [[ $output == *"filesystem: can't change once the disk step has started"* ]]
}

@test "error menu: shows the step's own last log lines, cut to fit an 80x24 console" {
  step_disk() {
    for n in 1 2 3 4 5 6; do log INFO "step line $n"; done
    log INFO "long $(printf 'y%.0s' {1..200})"
    return 1
  }
  run --separate-stderr steps_run <<< 4
  [ "$status" -eq 130 ]
  menu=${stderr#*Last lines of "$GI_LOG":}
  menu=${menu%%Retry*}
  [[ $menu == *"step line 3"*"step line 6"* ]]
  [[ $menu != *"step line 2"* && $menu != *"loaded config"* && $menu != *"step FAILED"* ]]
  # No timestamps: the message gets all 70 columns.
  [[ $menu == *$'\n'"INFO step line 6"$'\n'* ]]
  [[ ! $menu =~ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]
  [[ $menu == *"INFO long $(printf 'y%.0s' {1..60})"* ]]
  [[ $menu != *"$(printf 'y%.0s' {1..61})"* ]]
}

@test "install.started is set the first time steps run and kept on resume" {
  run steps_run
  [ "$status" -eq 0 ]
  start=$(state_get install.started)
  [[ $start =~ ^[0-9]+$ ]]
  ((start <= EPOCHSECONDS && start > EPOCHSECONDS - 60))
  state_set install.started 1000
  state_set step.finish ''
  run steps_run
  [ "$(state_get install.started)" = 1000 ]
}

@test "a step that exits 130 (its own Abort) stops at once, without the error menu" {
  step_preview() { exit 130; }
  run --separate-stderr steps_run < /dev/null
  [ "$status" -eq 130 ]
  [[ $stderr != *"Step failed"* ]]
  grep -q 'INFO stopped by the user in step preview' "$GI_LOG"
  [ -z "$(state_get step.preview)" ]
}

@test "secrets a step typed or changed in its subshell are asked again in the parent" {
  step_preview() {
    CFG[users]="larry anna"
    SECRET[user.anna.password]=typed-in-preview SECRET[root_password]=changed-in-preview
    cfg_save
  }
  step_system() { echo "root=${SECRET[root_password]}" >> "$CALLS"; }
  step_users() { echo "anna=${SECRET[user.anna.password]} larry=${SECRET[user.larry.password]}" >> "$CALLS"; }
  CFG[users]=larry
  run --separate-stderr steps_run < <(printf 'r00t-new\nr00t-new\ny\nanna-pw\nanna-pw\ny\n')
  [ "$status" -eq 0 ]
  [[ $stderr == *"Password for root:"*"Password for user anna:"* ]]
  grep -qx 'root=r00t-new' "$CALLS"
  grep -qx 'anna=anna-pw larry=larry-pw' "$CALLS"
  run ! grep -rqE 'in-preview|r00t|anna-pw' "$GI_RUN_DIR"
}

@test "with --yes a secret lost in a step is an error" {
  step_preview() {
    CFG[users]="larry anna"
    cfg_save
  }
  CFG[users]=larry GI_YES=1
  run --separate-stderr steps_run < /dev/null
  [ "$status" -eq 2 ]
  [[ $stderr == *"The --secrets file needs user.anna.password."* ]]
  [ "$(state_get step.preview)" = done ]
}

@test "with --yes a failed step exits 1 at once, naming the step and the package, without the error menu" {
  step_world() {
    printf 'package=app-misc/hello-2.12.3\nbuild_log=/mnt/gentoo/build.log\nexit=1\n' > "$GI_RUN_DIR/last_failure"
    return 1
  }
  GI_YES=1
  # A terminal would wait at the menu forever; here it would read the 4 and abort with 130.
  run --separate-stderr steps_run <<< 4
  [ "$status" -eq 1 ]
  [[ $stderr == *"Title world, failed with exit status 1."* ]]
  [[ $stderr == *"Package: app-misc/hello-2.12.3, build log: /mnt/gentoo/build.log"* ]]
  [[ $stderr != *"Step failed"* ]]
  grep -q 'ERROR Step 5 of 16, Title world, failed' "$GI_LOG"
  [ -z "$(state_get step.world)" ]
  # A step that failed outside emerge has no package to name.
  step_world() { return 3; }
  run --separate-stderr steps_run <<< 4
  [ "$status" -eq 1 ]
  [[ $stderr == *"failed with exit status 3."* && $stderr != *Package:* ]]
}

@test "a keymap changed inside a step drops the passwords steps_run asked for" {
  unset 'SECRET[root_password]'
  step_preview() {
    CFG[keymap]=de-latin1
    cfg_save
  }
  step_system() { echo "root=${SECRET[root_password]}" >> "$CALLS"; }
  run --separate-stderr steps_run < <(printf 'old-layout\nold-layout\ny\nnew-layout\nnew-layout\ny\n')
  [ "$status" -eq 0 ]
  grep -qx 'root=new-layout' "$CALLS"
}

@test "an asked Wi-Fi key must be a valid one, and an open network takes none" {
  CFG[wifi_ssid]=Cafe
  step_network() { echo "psk=[${SECRET[wifi_psk]}]" >> "$CALLS"; }
  run --separate-stderr steps_run < <(printf 'n\nshort\nshort\n12345678\n12345678\n')
  [ "$status" -eq 0 ]
  [[ $stderr == *"Is Cafe an open network"*"must be 8 to 63 printable ASCII"* ]]
  grep -qx 'psk=\[12345678\]' "$CALLS"
}
