#!/usr/bin/env bats
# Tests for the gentooinstall entry point. The flow tests run a copy of it next to
# core's libraries and fake versions of the other parts' functions and steps.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  export GI_TARGET GI_RUN_DIR CALLS=$BATS_TEST_TMPDIR/calls
  TREE=$(cd -- "$BATS_TEST_TMPDIR" && pwd -P)/tree
  mkdir -p "$TREE/lib/steps" "$TREE/tests"
  cp "$GI_HOME/gentooinstall" "$TREE/"
  cp "$GI_HOME"/lib/{core,ui,config,state}.sh "$TREE/lib/"
  ln -s "$GI_HOME/tests/stubs" "$TREE/tests/stubs"
  export PATH="$TREE/tests/stubs:$PATH"
  cat > "$TREE/lib/fakeparts.sh" << 'EOF'
# shellcheck shell=bash
questions_keymap() { echo "keymap:${CFG[keymap]:-ask}" >> "$CALLS"; if ((GI_RESUME)); then CFG[keymap]=${START_KEYMAP:-de-latin1}; fi; }
preflight_run() { HW[boot_mode]=uefi; echo preflight >> "$CALLS"; }
# Asked, every question the config leaves out is unset until the user takes its default.
questions_run() {
  echo questions >> "$CALLS"
  if ((!GI_YES)); then
    echo "filesystem=${CFG[filesystem]-unset} hostname=${CFG[hostname]-unset}" >> "$CALLS"
    cfg_defaults_apply
  fi
  cfg_check_rules >&2 || exit 2
}
disk_resume_mount() { echo resume_mount >> "$CALLS"; }
hw_disk_size_bytes() { echo $((500 * 1024 ** 3)); }
EOF
  cat > "$TREE/lib/steps/fake.sh" << 'EOF'
# shellcheck shell=bash
for id in "${GI_STEPS[@]}"; do step_define "$id" "Title $id" "Why $id." "https://wiki.gentoo.org/$id"; done
step_disk() { run_cmd wipefs --all "${CFG[disk]}"; state_relocate_to_target; }
step_world() { emerge_run --update @world; [[ -z ${FAIL_WORLD:-} ]]; }
step_users() { run_chroot_stdin "larry:${SECRET[user.larry.password]}" chpasswd; }
EOF
  cat > "$BATS_TEST_TMPDIR/config" << 'EOF'
keymap=de-latin1
disk=/dev/disk/by-id/nvme-Fake_SSD_123
desktop=none
display_manager=none
hostname=laptop
users=larry
EOF
  printf 'root_password=R00t-pass!\nuser.larry.password=L4rry-pass!\n' > "$BATS_TEST_TMPDIR/secrets"
  chmod 600 "$BATS_TEST_TMPDIR/secrets"
}

gi() { "$TREE/gentooinstall" "$@"; }

@test "--help and --version" {
  run gi --help
  [ "$status" -eq 0 ]
  [[ $output == *"Usage: gentooinstall [options]"*"--secrets FILE"*"--no-tui"* ]]
  run gi --version
  [ "$output" = "gentooinstall 0.1.0" ]
}

@test "bad usage exits 2" {
  run gi --bogus
  [ "$status" -eq 2 ]
  [[ $output == *"unknown option: --bogus"* ]]
  run gi --config
  [ "$status" -eq 2 ]
  run gi --yes
  [ "$status" -eq 2 ]
  [[ $output == *"--yes needs --config"* ]]
  run gi --resume --dry-run
  [ "$status" -eq 2 ]
}

@test "refuses to run without root outside tests" {
  run env -u GI_TEST "$TREE/gentooinstall" --no-tui
  [ "$status" -eq 1 ]
  [[ $output == *"must run as root"* ]]
}

@test "a bad config exits 2 with every error, before any question" {
  printf 'hostname=Bad_Host\nfilesystem=zfs\nshoe=9\n' > "$BATS_TEST_TMPDIR/bad"
  run --separate-stderr gi --no-tui --config "$BATS_TEST_TMPDIR/bad"
  [ "$status" -eq 2 ]
  [[ $stderr == *"line 1: hostname"*"line 2: filesystem"*"line 3: shoe: unknown key"* ]]
  [ ! -e "$CALLS" ]
}

@test "dry run goes through the flow and changes nothing" {
  run --separate-stderr gi --dry-run --no-tui --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = $'keymap:de-latin1\npreflight\nquestions\nfilesystem=unset hostname=laptop' ]
  [[ $stderr == *"wipefs --all /dev/disk/by-id/nvme-Fake_SSD_123"* ]]
  [[ $stderr == *"emerge --update @world"* ]]
  [[ $stderr == *"[16/16] Title finish"* ]]
  [ ! -s "$STUB_LOG" ]
  [ -z "$(ls -A "$GI_TARGET")" ]
}

@test "--rescue asks the layout, mounts the install, opens a shell in it and unmounts it after" {
  echo '_finish_unmount() { echo "unmount encryption=${CFG[encryption]}" >> "$CALLS"; }' >> "$TREE/lib/fakeparts.sh"
  mkdir -p "$GI_TARGET/var/lib/gentooinstall"
  echo 'disk.swapfile=/swapfile' > "$GI_TARGET/var/lib/gentooinstall/state"
  run --separate-stderr gi --rescue --no-tui < /dev/null
  [ "$status" -eq 0 ]
  # No preflight: the rescue needs no network. The cryptsetup stub reports the root mapping open.
  [ "$(cat "$CALLS")" = $'keymap:ask\nresume_mount\nunmount encryption=luks2' ]
  grep -qx "arch-chroot $GI_TARGET" "$STUB_LOG"
  grep -qx 'disk.swapfile=/swapfile' "$GI_RUN_DIR/state"
  [[ $stderr == *"this shell runs inside it"* ]]
  # --yes alone stops earlier, since it needs --config.
  for a in --resume --dry-run --explain "--config $BATS_TEST_TMPDIR/config" "--yes --config $BATS_TEST_TMPDIR/config"; do
    # shellcheck disable=SC2086 # --config takes its file as a second word
    run gi --rescue $a
    [ "$status" -eq 2 ]
    [[ $output == *"--rescue takes only --no-tui and --log"* ]]
  done
}

@test "an unattended run executes every step and keeps secrets out of the record" {
  # Left by an earlier attempt in the same live session.
  mkdir -p "$GI_RUN_DIR/build-logs"
  echo old > "$GI_RUN_DIR/build-logs/app-misc_hello-1.log"
  run --separate-stderr gi --yes --no-tui --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 0 ]
  grep -qx 'wipefs --all /dev/disk/by-id/nvme-Fake_SSD_123' "$STUB_LOG"
  grep -q 'emerge\\ --update\\ @world' "$STUB_LOG"
  grep -q 'chpasswd' "$STUB_LOG"
  [ "$(grep -c '^step\..*=done$' "$GI_TARGET/var/lib/gentooinstall/state")" -eq 16 ]
  grep -qx 'hostname=laptop' "$GI_TARGET/var/lib/gentooinstall/config"
  head -1 "$GI_RUN_DIR/replay.sh" | grep -qx '#!/bin/bash'
  run ! grep -rE 'R00t-pass|L4rry-pass' "$GI_RUN_DIR" "$STUB_LOG" "$GI_TARGET"
  [ ! -e "$GI_RUN_DIR/build-logs" ]
}

@test "with --yes a failed step exits 1 without the error menu and can be resumed later" {
  export FAIL_WORLD=1
  run --separate-stderr gi --yes --no-tui --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets" <<< 4
  [ "$status" -eq 1 ]
  [[ $stderr == *"Title world, failed"*"gentooinstall failed (exit status 1). Log: $GI_RUN_DIR/install.log"*"To continue: $TREE/gentooinstall --resume"* ]]
  [[ $stderr != *"Step failed"* ]]
  grep -q 'command failed with exit status 1' "$GI_RUN_DIR/install.log"
  grep -qx 'step.preview=done' "$GI_TARGET/var/lib/gentooinstall/state"
  run grep -q '^step.world=' "$GI_TARGET/var/lib/gentooinstall/state"
  [ "$status" -eq 1 ]

  unset FAIL_WORLD
  rm -rf "$GI_RUN_DIR"
  : > "$CALLS"
  START_KEYMAP=us run --separate-stderr gi --resume --no-tui --secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = $'keymap:ask\npreflight\nresume_mount' ]
  # Passwords from --secrets that the pending steps use are checked like typed ones.
  [[ $stderr == *"warning: root_password is shorter than the 16 characters the Handbook suggests."* ]]
  [[ $stderr == *"warning: user.larry.password is shorter than the 16 characters"* ]]
  # The layout typed at start unlocked the disk; the passwords still to come use the saved one.
  grep -qx 'loadkeys de-latin1' "$STUB_LOG"
  [ "$(grep -c '^wipefs' "$STUB_LOG")" -eq 1 ]
  [ "$(grep -c '^step\..*=done$' "$GI_TARGET/var/lib/gentooinstall/state")" -eq 16 ]
}

@test "resume locks the disk answers and asks for missing secrets" {
  run gi --yes --no-tui --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 0 ]
  sed -i '/^step.users=/d;/^step.desktop=/d' "$GI_TARGET/var/lib/gentooinstall/state"
  printf 'filesystem=xfs\n' > "$BATS_TEST_TMPDIR/change"
  run --separate-stderr gi --resume --no-tui --config "$BATS_TEST_TMPDIR/change"
  [ "$status" -eq 2 ]
  [[ $stderr == *"filesystem: can't change once the disk step has started"* ]]
  run --separate-stderr gi --resume --yes --no-tui --config "$BATS_TEST_TMPDIR/config"
  [ "$status" -eq 2 ]
  [[ $stderr == *"needs user.larry.password"* ]]
  # A short one gets the Handbook's 16-character warning; No types another.
  run --separate-stderr gi --resume --no-tui < <(printf 'L4rry-pass!\nL4rry-pass!\nn\nlarry-long-pass-phrase\nlarry-long-pass-phrase\n')
  [ "$status" -eq 0 ]
  [[ $stderr == *"Password for user larry:"*"shorter than the 16 characters"*"Password for user larry:"* ]]
  [ "$(grep -c 'shorter than the 16' <<< "$stderr")" -eq 1 ]
}

@test "resume lets an answer change only while the step that acts on it is pending" {
  run gi --yes --no-tui --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 0 ]
  STATE=$GI_TARGET/var/lib/gentooinstall/state
  # Stopped in the package install, after the compile preview had shown its plan.
  sed -i -E '/^step\.(world|locale|kernel|system|network|tools|bootloader|users|desktop|graphics|hardware|finish)=/d' "$STATE"
  printf 'packages=app-misc/hello\ntimezone=Europe/Berlin\n' > "$BATS_TEST_TMPDIR/change"
  run --separate-stderr gi --resume --yes --no-tui --config "$BATS_TEST_TMPDIR/change" --secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 0 ]
  [[ $stderr == *"so it runs again"*"[ 4/16] Title preview"*"[ 5/16] Title world"* ]]
  grep -qx 'packages=app-misc/hello' "$GI_TARGET/var/lib/gentooinstall/config"

  # Now every step is done: the package list and the timezone were used.
  printf 'packages=app-misc/hello app-editors/vim\ntimezone=UTC\nhostname=laptop\nmedia_keys=yes\n' > "$BATS_TEST_TMPDIR/change"
  run --separate-stderr gi --resume --yes --no-tui --config "$BATS_TEST_TMPDIR/change" --secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 2 ]
  [[ $stderr == *'packages can'"'"'t change on --resume: the step "Title world" already used it.'* ]]
  [[ $stderr == *'media_keys can'"'"'t change on --resume: the step "Title world" already used it.'* ]]
  [[ $stderr == *'timezone can'"'"'t change on --resume: the step "Title locale" already used it.'* ]]
  # hostname is unchanged, and explain may always change.
  [[ $stderr != *hostname* ]]
  grep -qx 'packages=app-misc/hello' "$GI_TARGET/var/lib/gentooinstall/config"

  # Only the steps after networking are left: the hostname is used, the extra services aren't.
  sed -i -E '/^step\.(tools|bootloader|users|desktop|graphics|hardware|finish)=/d' "$STATE"
  printf 'hostname=other\nexplain=yes\n' > "$BATS_TEST_TMPDIR/change"
  run --separate-stderr gi --resume --yes --no-tui --config "$BATS_TEST_TMPDIR/change" --secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 2 ]
  [[ $stderr == *'hostname can'"'"'t change on --resume: the step "Title system"'* ]]
  [[ $stderr != *explain* ]]
}

@test "a keymap changed on resume is loaded, with a warning about the disk passphrase" {
  echo encryption=luks2 >> "$BATS_TEST_TMPDIR/config"
  echo luks_passphrase=Disk-pass-phrase-long >> "$BATS_TEST_TMPDIR/secrets"
  run gi --yes --no-tui --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 0 ]
  sed -i -E '/^step\.(locale|kernel|system|network|tools|bootloader|users|desktop|graphics|hardware|finish)=/d' \
    "$GI_TARGET/var/lib/gentooinstall/state"
  echo keymap=fr-latin1 > "$BATS_TEST_TMPDIR/change"
  run --separate-stderr gi --resume --yes --no-tui --config "$BATS_TEST_TMPDIR/change" --secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 0 ]
  [[ $stderr == *"passphrase was set with the de-latin1 layout"*"won't unlock the disk at boot with fr-latin1"* ]]
  grep -qx 'loadkeys fr-latin1' "$STUB_LOG"
  grep -qx 'keymap=fr-latin1' "$GI_TARGET/var/lib/gentooinstall/config"
}

@test "Ctrl+C asks first, then stops with 130" {
  # shellcheck source=/dev/null
  source "$GI_HOME/gentooinstall"
  gi_load core ui config state
  GI_UI=plain
  run gi_on_int <<< y
  [ "$status" -eq 130 ]
  run gi_on_int <<< n
  [ "$status" -eq 0 ]
}

@test "finish_menu runs after every step is done, but not in a dry run" {
  cat > "$TREE/lib/steps/zfinish.sh" << 'EOT'
# shellcheck shell=bash
finish_menu() { echo "finish_menu after $(grep -c '=done$' "$GI_RUN_DIR/state") steps" >> "$CALLS"; }
EOT
  run gi --yes --no-tui --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$CALLS")" = "finish_menu after 16 steps" ]
  : > "$CALLS"
  run gi --dry-run --no-tui --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets" < /dev/null
  [ "$status" -eq 0 ]
  run ! grep -q finish_menu "$CALLS"
}

@test "the run dir is checked before chmod, so a planted symlink keeps its target's mode" {
  mkdir -m 0755 "$BATS_TEST_TMPDIR/elsewhere"
  rm -rf "$GI_RUN_DIR"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$GI_RUN_DIR"
  run --separate-stderr gi --dry-run --no-tui --config "$BATS_TEST_TMPDIR/config"
  [ "$status" -eq 1 ]
  [[ $stderr == *"must be a directory owned by the user"* ]]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/elsewhere")" = 755 ]
}

@test "xtrace never shows a secret" {
  run --separate-stderr bash -x "$TREE/gentooinstall" --yes --no-tui --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 0 ]
  [[ $stderr == *"+ set +x"* ]]
  [[ $stderr != *R00t-pass* && $stderr != *L4rry-pass* ]]
}

@test "resume can go on with an open Wi-Fi network" {
  echo 'wifi_ssid=Cafe' >> "$BATS_TEST_TMPDIR/config"
  echo 'step_network() { echo "psk=[${SECRET[wifi_psk]-unset}]" >> "$CALLS"; }' >> "$TREE/lib/steps/fake.sh"
  { cat "$BATS_TEST_TMPDIR/secrets"; echo wifi_psk=12345678; } > "$BATS_TEST_TMPDIR/secrets-wifi"
  chmod 600 "$BATS_TEST_TMPDIR/secrets-wifi"
  run gi --yes --no-tui --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets-wifi"
  [ "$status" -eq 0 ]
  sed -i '/^step.network=/d' "$GI_TARGET/var/lib/gentooinstall/state"
  run --separate-stderr gi --resume --no-tui --secrets "$BATS_TEST_TMPDIR/secrets" <<< y
  [ "$status" -eq 0 ]
  [[ $stderr == *"Is Cafe an open network"* ]]
  [ "$(tail -1 "$CALLS")" = "psk=[]" ]
}

@test "resume on another Wi-Fi network asks for the saved network's key instead of using the live one" {
  echo 'wifi_ssid=Cafe' >> "$BATS_TEST_TMPDIR/config"
  # Like hw_detect: the live network's key, unless --secrets gave one.
  cat >> "$TREE/lib/fakeparts.sh" << 'EOF'
preflight_run() {
  HW[boot_mode]=uefi HW[wifi_ssid]=${LIVE_SSID:-}
  if [[ -n ${LIVE_SSID:-} && -z ${SECRET[wifi_psk]+x} ]]; then SECRET[wifi_psk]=live-key; fi
}
EOF
  echo 'step_network() { echo "psk=[${SECRET[wifi_psk]-unset}]" >> "$CALLS"; }' >> "$TREE/lib/steps/fake.sh"
  { cat "$BATS_TEST_TMPDIR/secrets"; echo wifi_psk=12345678; } > "$BATS_TEST_TMPDIR/secrets-wifi"
  chmod 600 "$BATS_TEST_TMPDIR/secrets-wifi"
  run gi --yes --no-tui --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets-wifi"
  [ "$status" -eq 0 ]
  redo_network() { sed -i '/^step.network=/d' "$GI_TARGET/var/lib/gentooinstall/state"; }

  redo_network
  LIVE_SSID=Hotspot run --separate-stderr gi --resume --no-tui --secrets "$BATS_TEST_TMPDIR/secrets" < <(printf 'n\nCafeKey123\nCafeKey123\n')
  [ "$status" -eq 0 ]
  [[ $stderr == *"Key for the Wi-Fi network Cafe:"* ]]
  [ "$(tail -1 "$CALLS")" = "psk=[CafeKey123]" ]

  # Still on the saved network, or a key from --secrets: nothing to ask.
  redo_network
  LIVE_SSID=Cafe run --separate-stderr gi --resume --no-tui --secrets "$BATS_TEST_TMPDIR/secrets" < /dev/null
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$CALLS")" = "psk=[live-key]" ]
  redo_network
  LIVE_SSID=Hotspot run --separate-stderr gi --resume --no-tui --secrets "$BATS_TEST_TMPDIR/secrets-wifi" < /dev/null
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$CALLS")" = "psk=[12345678]" ]
}

@test "the ERR trap logs only the first line of a multi-line command" {
  # shellcheck source=/dev/null
  source "$GI_HOME/gentooinstall"
  gi_load core
  gi_on_err 1 $'( set -e\n  step_disk )' state.sh:97
  grep -q 'ERROR command failed with exit status 1 at state.sh:97: ( set -e$' "$GI_LOG"
  run ! grep -q step_disk "$GI_LOG"
}

@test "Ctrl+C in a step, then going on, offers the error menu instead of stopping" {
  # What Ctrl+C does: SIGINT to the installer and to the step's subshell.
  echo 'step_world() { if [[ ! -e $GI_RUN_DIR/once ]]; then touch "$GI_RUN_DIR/once"; kill -INT $$; kill -INT $BASHPID; fi; }' >> "$TREE/lib/steps/fake.sh"
  run --separate-stderr gi --no-tui --yes --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets" < <(printf 'n\n1\n')
  [ "$status" -eq 0 ]
  [[ $stderr == *"Stop the installer?"*"Title world, failed with exit status 130"* ]]
  grep -qx 'step.world=done' "$GI_TARGET/var/lib/gentooinstall/state"
}

@test "--log /dev/null works and leaves the device alone" {
  run --separate-stderr gi --dry-run --no-tui --config "$BATS_TEST_TMPDIR/config" --secrets "$BATS_TEST_TMPDIR/secrets" --log /dev/null
  [ "$status" -eq 0 ]
  [ "$(stat -c %a /dev/null)" = 666 ]
}
