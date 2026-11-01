#!/usr/bin/env bats
# Tests for lib/ui.sh: plain widgets fed on stdin, dialog widgets through the dialog stub.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui
  GI_UI=plain
  MENU=(Pick "Pick a filesystem" xfs ext4 ext4 "ext4 help" xfs xfs "xfs help" btrfs btrfs "btrfs help")
}

@test "ui_init picks plain without a terminal" {
  GI_UI=''
  ui_init < /dev/null > /dev/null
  [ "$GI_UI" = plain ]
}

@test "ui_init keeps plain when --no-tui preset it" {
  GI_UI=plain
  ui_init
  [ "$GI_UI" = plain ]
}

@test "plain menu returns the numbered tag" {
  run --separate-stderr ui_menu "${MENU[@]}" <<< 3
  [ "$status" -eq 0 ]
  [ "$output" = btrfs ]
  [[ $stderr == *"1) ext4"*"*  2) xfs"*"3) btrfs"* ]]
}

@test "plain menu: Enter takes the default, b goes back, ? shows help" {
  run --separate-stderr ui_menu "${MENU[@]}" <<< ''
  [ "$output" = xfs ]
  run --separate-stderr ui_menu "${MENU[@]}" <<< b
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run --separate-stderr ui_menu "${MENU[@]}" < <(printf '?\n1\n')
  [ "$output" = ext4 ]
  [[ $stderr == *"btrfs: btrfs help"* ]]
}

@test "plain menu: a default that isn't on offer isn't Enter's answer" {
  run --separate-stderr ui_menu Pick "Pick a filesystem" zfs ext4 ext4 "" xfs xfs "" < <(printf '\n2\n')
  [ "$output" = xfs ]
  [[ $stderr != *"Enter = zfs"* && $stderr == *"Not a valid choice."* ]]
}

@test "plain menu rejects bad input and asks again" {
  run --separate-stderr ui_menu "${MENU[@]}" < <(printf '9\nzz\n08\n2\n')
  [ "$output" = xfs ]
  [ "$(grep -c 'Not a valid choice' <<< "$stderr")" -eq 3 ]
}

@test "plain menu extra choice returns 3" {
  run ui_menu --extra Done Hub "Pick" a a A "a help" <<< x
  [ "$status" -eq 3 ]
}

@test "plain radio works like a menu" {
  run --separate-stderr ui_radio "${MENU[@]}" <<< 1
  [ "$output" = ext4 ]
}

@test "plain input returns typed text or the default" {
  run --separate-stderr ui_input Hostname "Name?" gentoo <<< laptop
  [ "$output" = laptop ]
  run --separate-stderr ui_input Hostname "Name?" gentoo <<< ''
  [ "$output" = gentoo ]
  run --separate-stderr ui_input Hostname "Name?" gentoo <<< b
  [ "$status" -eq 1 ]
}

@test "plain password asks twice until both match and refuses empty" {
  run --separate-stderr ui_password_twice Root "Root password" < <(printf '\n\none\ntwo\nsecret\nsecret\n')
  [ "$status" -eq 0 ]
  [ "$output" = secret ]
  [[ $stderr == *"can't be empty"*"don't match"* ]]
  [[ $stderr != *secret* ]]
}

@test "plain yesno" {
  run ui_yesno T "Go?" <<< y
  [ "$status" -eq 0 ]
  run ui_yesno T "Go?" <<< no
  [ "$status" -eq 1 ]
  run ui_yesno T "Go?" <<< ''
  [ "$status" -eq 0 ]
  run ui_yesno --defaultno T "Go?" <<< ''
  [ "$status" -eq 1 ]
}

@test "plain confirm_text needs the exact text" {
  run --separate-stderr ui_confirm_text Confirm "Type the disk name" nvme0n1 < <(printf 'sda\nnvme0n1\n')
  [ "$status" -eq 0 ]
  [[ $stderr == *"doesn't match"* ]]
  run ui_confirm_text Confirm "Type the disk name" nvme0n1 <<< b
  [ "$status" -eq 1 ]
}

@test "plain msg and textbox print to stderr" {
  echo "log line" > "$BATS_TEST_TMPDIR/f"
  run --separate-stderr ui_textbox Log "$BATS_TEST_TMPDIR/f"
  [ -z "$output" ]
  [[ $stderr == *"== Log =="*"log line"* ]]
}

@test "closed stdin stops the whole installer, even from nested retry loops" {
  run --separate-stderr timeout 20 bash -c 'source "$1/lib/core.sh"; source "$1/lib/ui.sh"; GI_UI=plain
    ( while :; do x=$(ui_menu T X a a A h) || true; done )
    echo survived' _ "$GI_HOME" < /dev/null
  [ "$status" -ne 0 ]
  [ "$status" -ne 124 ]
  [[ $stderr == *"Standard input closed"* ]]
  [[ $output != *survived* ]]
}

@test "dialog menu passes the documented options and returns the tag" {
  GI_UI=dialog HW[boot_mode]=uefi
  echo xfs > "$STUB_OUT_DIR/dialog"
  run ui_menu --extra Edit --ok Choose "${MENU[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = xfs ]
  read -ra args < "$STUB_LOG"
  [ "${args[0]}" = dialog ]
  [[ " ${args[*]} " == *" --backtitle gentooinstall\ 0.1.0\ \|\ UEFI "* ]]
  [[ " ${args[*]} " == *" --output-fd 1 "* ]]
  [[ " ${args[*]} " == *" --cancel-label Back --item-help --ok-label Choose --extra-button --extra-label Edit --default-item xfs --menu "* ]]
  [[ " ${args[*]} " == *" ext4 ext4 ext4\ help xfs xfs xfs\ help "* ]]
}

@test "dialog return codes map to OK, back and extra" {
  GI_UI=dialog
  export STUB_RC_dialog=3
  run ui_menu "${MENU[@]}"
  [ "$status" -eq 3 ]
  export STUB_RC_dialog=255
  run ui_menu "${MENU[@]}"
  [ "$status" -eq 1 ]
  export STUB_RC_dialog=1
  run ui_input T X d
  [ "$status" -eq 1 ]
  run ui_yesno T X
  [ "$status" -eq 1 ]
}

@test "dialog radiolist marks the default on" {
  GI_UI=dialog
  run ui_radio "${MENU[@]}"
  grep -q -- '--radiolist Pick\\ a\\ filesystem 0 0 0 ext4 ext4 off ext4\\ help xfs xfs on' "$STUB_LOG"
}

@test "dialog password box never puts the password in arguments" {
  GI_UI=dialog
  printf 'hunter22' > "$STUB_OUT_DIR/dialog"
  run ui_password_twice Root "Root password"
  [ "$output" = hunter22 ]
  [ "$(grep -c -- '--passwordbox' "$STUB_LOG")" -eq 2 ]
  run ! grep -q -- '--insecure\|hunter22' "$STUB_LOG"
}

@test "ui_backtitle summarizes the machine" {
  HW[boot_mode]=uefi HW[ram_mib]=15800 HW[cpu_threads]=8 HW[online]=yes
  [ "$(ui_backtitle)" = "gentooinstall 0.1.0 | UEFI | 15 GiB RAM | 8 threads | online" ]
}

@test "progress output shows steps and elapsed time; status needs a terminal" {
  progress_begin 16
  run --separate-stderr bash -c 'source "$1/lib/core.sh"; source "$1/lib/ui.sh"; GI_LOG=/dev/null
    progress_begin 16; progress_step_start 3 portage "Portage setup"; progress_status "1 of 2 x"
    progress_explain "Why." "https://wiki.gentoo.org/"; progress_step_end ok' _ "$GI_HOME"
  [[ $stderr == *"[ 3/16] Portage setup"*"done (0s)"* ]]
  [[ $stderr != *"1 of 2"* && $stderr != *Handbook* ]]
  GI_EXPLAIN=1
  run --separate-stderr progress_explain "Why we do it." "https://wiki.gentoo.org/wiki/Handbook:AMD64"
  [[ $stderr == *"Why we do it."*"Handbook: https://wiki.gentoo.org/wiki/Handbook:AMD64"* ]]
}

@test "a dialog failure asks in plain text instead of meaning back" {
  GI_UI=dialog
  # What dialog does when a box doesn't fit the screen; Esc also exits 255, but silently.
  dialog() {
    echo "Can't make sub-window at (23,3), size (1,72)." >&2
    return 255
  }
  run --separate-stderr ui_menu "${MENU[@]}" <<< 3
  [ "$status" -eq 0 ]
  [ "$output" = btrfs ]
  [[ $stderr == *"3) btrfs"* ]]
  grep -q "WARN dialog failed, asking in plain text instead: Can't make sub-window" "$GI_LOG"
  run --separate-stderr ui_input Hostname "Name?" gentoo <<< laptop
  [ "$output" = laptop ]
  run --separate-stderr ui_password_twice Root "Root password" < <(printf 'pw\npw\n')
  [ "$output" = pw ]
  run ui_yesno --defaultno T "Go?" <<< y
  [ "$status" -eq 0 ]
  run --separate-stderr ui_msg T "Hello there"
  [[ $stderr == *"Hello there"* ]]
}

@test "plain widgets take a last answer that has no newline" {
  run --separate-stderr ui_menu "${MENU[@]}" < <(printf 3)
  [ "$status" -eq 0 ]
  [ "$output" = btrfs ]
  run --separate-stderr ui_password_twice Root "Root password" < <(printf 'pw\npw')
  [ "$output" = pw ]
}

@test "plain menus show each TAG next to its ITEM, as dialog does" {
  run --separate-stderr ui_menu Hub "Pick" Disk Keyboard us "k help" Disk "nvme0n1, ext4" "d help" Continue "Review" "c help" <<< 2
  [ "$output" = Disk ]
  [[ $stderr == *"  1) Keyboard  us"* ]]
  [[ $stderr == *" *  2) Disk      nvme0n1, ext4"* ]]
  [[ $stderr == *"  3) Continue  Review"* ]]
  # Tags that only repeat their items aren't shown twice.
  run --separate-stderr ui_menu "${MENU[@]}" <<< 1
  [[ $stderr == *"1) ext4"$'\n'* ]]
}

@test "ui_password asks once, allows empty, and never echoes" {
  run --separate-stderr ui_password Unlock "Passphrase" <<< 'pass phrase'
  [ "$status" -eq 0 ]
  [ "$output" = 'pass phrase' ]
  [[ $stderr != *'pass phrase'* ]]
  run --separate-stderr ui_password Unlock "Passphrase" <<< ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run ui_password Unlock "Passphrase" <<< b
  [ "$status" -eq 1 ]
  GI_UI=dialog
  printf 'hunter22' > "$STUB_OUT_DIR/dialog"
  run ui_password Unlock "Passphrase"
  [ "$output" = hunter22 ]
  [ "$(grep -c -- '--passwordbox' "$STUB_LOG")" -eq 1 ]
  export STUB_RC_dialog=1
  run ui_password Unlock "Passphrase"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ui_yesno takes button labels" {
  run --separate-stderr ui_yesno --yes Reboot --no Exit Done "What next?" <<< n
  [ "$status" -eq 1 ]
  [[ $stderr == *"y = Reboot, n = Exit [Y/n]:"* ]]
  run ui_yesno --defaultno --no Keep T "Delete?" <<< ''
  [ "$status" -eq 1 ]
  GI_UI=dialog
  run ui_yesno --defaultno --yes Reboot --no Exit Done "What next?"
  [ "$status" -eq 0 ]
  grep -q -- '--title Done --defaultno --yes-label Reboot --no-label Exit --yesno' "$STUB_LOG"
}

@test "plain input: a single - clears the default" {
  run --separate-stderr ui_input Packages "Extra packages" "app-editors/vim" <<< -
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ $stderr == *"[Enter = app-editors/vim, - = empty]"* ]]
}
