#!/usr/bin/env bats
# Tests for lib/questions.sh. Each flow runs in a bash with the entry point's strict
# options, fed plain-mode answers on stdin; CFG and SECRET are dumped when it exits.

bats_require_minimum_version 1.5.0

BIG=/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456
SMALL=/dev/disk/by-id/ata-Small_Disk_123

setup() {
  load helpers
  gi_setup
  STATE=$BATS_TEST_TMPDIR/state
  PRELUDE=$BATS_TEST_TMPDIR/prelude.sh
  {
    printf 'GI_HOME=%q GI_TARGET=%q GI_RUN_DIR=%q GI_LOG=%q GI_UI=plain BIG=%q SMALL=%q\n' \
      "$GI_HOME" "$GI_TARGET" "$GI_RUN_DIR" "$GI_LOG" "$BIG" "$SMALL"
    cat << 'EOF'
for m in core ui config state questions; do source "$GI_HOME/lib/$m.sh"; done
PW=correct-horse-battery # long enough to skip the short-password warning
HW=([boot_mode]=uefi [ram_mib]=16000 [cpu_threads]=8 [online]=yes [live_disk]=sdb [laptop]=yes
  [bluetooth]=yes [cpu_vendor]=intel [gpus]=intel [secure_boot]=off [wifi_ssid]='')
# Part B's functions, faked. The small disk has no model and no summary.
hw_disks() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$BIG" nvme0n1 1000204886016 nvme "Samsung SSD 980" "Windows (NTFS), 4 partitions" \
    "$SMALL" sda 32017047552 sata "" ""
}
hw_disk_size_bytes() {
  case $1 in
    "$BIG") echo 1000204886016 ;;
    "$SMALL") echo 32017047552 ;;
    *) return 1 ;;
  esac
}
EOF
  } > "$PRELUDE"
}

# The menu number of TAG in the Desktop question, in the order lib/questions.sh offers them
# (Plasma, the recommended one, is first there too), so a longer list doesn't move the answers.
desktop_choice() {
  sed -n '/^      _q_radio desktop /,/;;/p' "$GI_HOME/lib/questions.sh" | grep -oE '^        [a-z0-9]+ ' |
    grep -nx "        $1 " | cut -d: -f1
}

# q_run CODE [ANSWER...]: runs CODE like the entry point would, one answer per stdin line.
q_run() {
  local code=$1
  shift
  local script="set -Eeuo pipefail; shopt -s inherit_errexit; source \"$PRELUDE\"
trap 'declare -p CFG SECRET > \"$STATE\"' EXIT
$code"
  if (($#)); then
    run --separate-stderr bash -c "$script" < <(printf '%s\n' "$@")
  else
    run --separate-stderr bash -c "$script" < /dev/null
  fi
}

@test "questions_keymap loads the config's keymap without asking" {
  q_run 'CFG[keymap]=de-latin1; questions_keymap'
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "loadkeys de-latin1" ]
}

@test "questions_keymap exits 2 when the config's keymap doesn't load" {
  export STUB_RC_loadkeys=1
  q_run 'CFG[keymap]=xx; questions_keymap'
  [ "$status" -eq 2 ]
  [[ $stderr == *"Couldn't load the keymap xx"* ]]
}

@test "questions_keymap asks from the list, loads the choice and sets keymap" {
  q_run 'questions_keymap' 3
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "loadkeys de-latin1" ]
  source "$STATE"
  [ "${CFG[keymap]}" = de-latin1 ]
}

@test "questions_keymap on --resume asks for the layout the install started with" {
  q_run 'questions_keymap' 1
  [[ $stderr == *"and the new system uses it too."* ]]
  q_run 'GI_RESUME=1; questions_keymap' 1
  [ "$status" -eq 0 ]
  # The saved config's keymap, not this answer, is the new system's.
  [[ $stderr == *"Pick the keyboard layout you chose when this install started."* ]]
  [[ $stderr != *"the new system uses it too"* ]]
  [ "$(tail -n 1 "$STUB_LOG")" = "loadkeys us" ]
  # A --config keymap is the new system's too: the disk passphrase still needs the old layout.
  q_run 'GI_RESUME=1; CFG[keymap]=fr-latin1; questions_keymap' 3
  [ "$status" -eq 0 ]
  [[ $stderr == *"Pick the keyboard layout you chose when this install started."* ]]
  [ "$(tail -n 1 "$STUB_LOG")" = "loadkeys de-latin1" ]
}

@test "questions_keymap: Other... checks the name against the keymap files" {
  export GI_HOST_ROOT=$BATS_TEST_TMPDIR/host
  KM=$GI_HOST_ROOT/usr/share/keymaps
  mkdir -p "$KM/i386/qwertz" "$KM/i386/include"
  touch "$KM/i386/qwertz/de-latin1-nodeadkeys.map.gz" "$KM/i386/include/euro.map.gz"
  q_run 'questions_keymap' 21 nope 21 euro 21 'x*' 21 de-latin1-nodeadkeys
  [ "$status" -eq 0 ]
  [ "$(grep -c "There's no keymap named" <<< "$stderr")" -eq 3 ]
  [ "$(cat "$STUB_LOG")" = "loadkeys de-latin1-nodeadkeys" ]
  source "$STATE"
  [ "${CFG[keymap]}" = de-latin1-nodeadkeys ]
}

@test "questions_keymap: a keymap loadkeys rejects is asked again" {
  export STUB_RC_loadkeys=1
  q_run 'questions_keymap' 2 b y
  [ "$status" -eq 130 ]
  [[ $stderr == *"loadkeys couldn't load uk"* ]]
  source "$STATE"
  [ -z "${CFG[keymap]:-}" ]
}

@test "happy path: wizard through the [!] sections, review, save and typed confirmation" {
  q_run 'cfg_defaults_apply; questions_run; echo done' \
    '' '' 1 '' \
    '' '' larry 'l4rry pass phrase' 'l4rry pass phrase' '' '' 'r00t pass phrase' 'r00t pass phrase' '' \
    '' '' nvme0n1
  [ "$status" -eq 0 ]
  [ "$output" = done ]
  [[ $stderr == *"[!] not set"*"[!] none yet"*"2 sections need an answer"* ]]
  [[ $stderr == *"The live USB, sdb, isn't listed."* ]]
  # What's on the disk comes before the model, which an 80-column dialog may cut.
  [[ $stderr == *"nvme0n1  1.0 TB  nvme  Windows (NTFS), 4 partitions  Samsung SSD 980"* ]]
  [[ $stderr == *"== Review =="*"Disk"*"Samsung SSD 980"*"Windows (NTFS), 4 partitions"*"Users"*"larry"*"admin, bash"* ]]
  [[ $stderr == *"== Erase nvme0n1 and install? =="* ]]
  [[ $stderr == *"Disk     nvme0n1, 1.0 TB, Samsung SSD 980"*"Now on   Windows (NTFS), 4 partitions. All of it will be deleted."* ]]
  [[ $stderr == *"Layout   1 GiB ESP + ext4 root, zram swap"*"Type nvme0n1 to confirm:"* ]]
  [[ $stderr != *"l4rry pass"* && $stderr != *"r00t pass"* && $stderr != *"shorter than"* ]]
  source "$STATE"
  [ "${CFG[disk]}" = "$BIG" ]
  [ "${CFG[users]}" = larry ]
  [ "${CFG[user.larry.admin]}" = yes ]
  [ "${CFG[user.larry.shell]}" = bash ]
  [ "${SECRET[user.larry.password]}" = "l4rry pass phrase" ]
  [ "${SECRET[root_password]}" = "r00t pass phrase" ]
  grep -qx "disk=$BIG" "$GI_RUN_DIR/config"
  grep -qx "user.larry.admin=yes" "$GI_RUN_DIR/config"
  run ! grep -qE 'l4rry pass|r00t pass' "$GI_RUN_DIR/config"
  run ! grep -rqE 'l4rry pass|r00t pass' "$GI_LOG" "$STUB_LOG"
}

@test "a wrong disk name in the confirmation is asked again; back returns to the hub" {
  q_run 'cfg_defaults_apply; cfg_set disk "$BIG"; cfg_set users larry; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[root_password]=$PW; questions_run' \
    '' '' sda b '' '' nvme0n1
  [ "$status" -eq 0 ]
  [[ $stderr == *"doesn't match"* ]]
  [ "$(grep -c 'Install with these answers?' <<< "$stderr")" -eq 2 ]
}

@test "back navigation leaves answers alone, and Quit asks before exiting 130" {
  q_run 'cfg_defaults_apply; questions_run' \
    3 1 b b \
    2 2 3 b \
    b '' \
    b y
  [ "$status" -eq 130 ]
  [ "$(grep -c '== Quit ==' <<< "$stderr")" -eq 2 ]
  source "$STATE"
  [ "${CFG[init]}" = openrc ]
  [ "${CFG[filesystem]}" = btrfs ]
  [ ! -e "$GI_RUN_DIR/config" ]
}

@test "a bad value shows cfg_set's error and is asked again" {
  q_run 'cfg_defaults_apply; questions_run' \
    5 2 Bad_Host laptop b \
    6 1 Berlin Europe/Berlin 2 'en_US.UTF-8 de_DE.UTF-8' 3 2 b \
    7 '' 'Bad Name' root larry pw pw '' b \
    b y
  [ "$status" -eq 130 ]
  [[ $stderr == *"hostname: must be 1 to 63 lowercase letters"* ]]
  [[ $stderr == *"timezone: must be UTC or Region/City"* ]]
  [[ $stderr == *"user names must be lowercase"*"root is a system account name"* ]]
  source "$STATE"
  [ "${CFG[hostname]}" = laptop ]
  [ "${CFG[timezone]}" = Europe/Berlin ]
  [ "${CFG[locales]}" = "en_US.UTF-8 de_DE.UTF-8" ]
  [ "${CFG[lang]}" = de_DE.UTF-8 ]
  [ "${CFG[users]}" = larry ]
  [ "${SECRET[user.larry.password]}" = pw ]
}

@test "changing locales keeps lang one of them" {
  q_run 'cfg_defaults_apply; questions_run' 6 2 'de_DE.UTF-8 fr_FR.UTF-8' b b y
  source "$STATE"
  [ "${CFG[lang]}" = de_DE.UTF-8 ]
}

@test "choosing LUKS2 asks for the passphrase right away; skipping it leaves a [!]" {
  q_run 'cfg_defaults_apply; questions_run' \
    2 3 2 b \
    3 '' 'pass phrase' 'pass phrase' '' \
    b b y
  [ "$status" -eq 130 ]
  [[ $stderr == *"[!] LUKS passphrase not set"* ]]
  [[ $stderr =~ 6\)\ (Done\ +)?Go\ back ]] # the TRIM through LUKS row appeared
  source "$STATE"
  [ "${CFG[encryption]}" = luks2 ]
  [ "${SECRET[luks_passphrase]}" = "pass phrase" ]
}

@test "users: edit shell and admin, remove a user, lock root; the rules then block the install" {
  q_run 'cfg_defaults_apply; cfg_set disk "$BIG"; cfg_set users "larry anna"; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[user.anna.password]=$PW SECRET[root_password]=$PW; questions_run' \
    7 1 3 3 2 2 5 \
    2 4 y \
    3 2 '' \
    '' \
    b y
  [ "$status" -eq 130 ]
  [[ $stderr == *"== Fix these first =="*"Locking root needs at least one admin user."* ]]
  # A fish login shell misses /etc/profile.env, and the question says so.
  [[ $stderr == *"== Shell =="$'\n'"The login shell for larry. Fish, as a login shell, doesn't read /etc/profile.env, so it misses system variables set through /etc/env.d (Gentoo bug 545830); the installer adds only the keyboard layout ones."$'\n'* ]]
  source "$STATE"
  [ "${CFG[users]}" = larry ]
  [ "${CFG[user.larry.shell]}" = fish ]
  [ "${CFG[user.larry.admin]}" = no ]
  [ "${CFG[root]}" = locked ]
  [ -z "${CFG[user.anna.admin]+x}" ]
  [ -z "${SECRET[user.anna.password]+x}" ]
}

@test "rule errors block Install, warnings ask, and a disk without model or summary still confirms" {
  q_run 'cfg_defaults_apply; cfg_set disk "$SMALL"; cfg_set users larry; cfg_set network dhcpcd; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[root_password]=$PW; questions_run' \
    '' \
    4 1 "$(desktop_choice none)" '' \
    '' '' sda
  [ "$status" -eq 0 ]
  [[ $stderr == *"== Fix these first =="*"error: A desktop needs a disk of at least 40 GiB."*"warn: A desktop without NetworkManager"* ]]
  [[ $stderr != *"== Warnings =="* ]]
  [[ $stderr == *"Disk     sda, 32 GB, unknown model"*"Now on   no partitions found."* ]]
  source "$STATE"
  [ "${CFG[desktop]}" = none ]
}

@test "warnings can be accepted" {
  q_run 'cfg_defaults_apply; cfg_set disk "$BIG"; cfg_set users larry; cfg_set network dhcpcd; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[root_password]=$PW; questions_run' \
    '' '' '' y '' nvme0n1
  [ "$status" -eq 0 ]
  [ "$(grep -c '== Warnings ==' <<< "$stderr")" -eq 2 ]
}

@test "Install lists the sections that still need an answer" {
  q_run 'cfg_defaults_apply; questions_run' 10 b y
  [[ $stderr == *"These sections still need an answer: Disk, Users."* ]]
}

@test "a disk from the config that isn't installable must be picked again" {
  q_run 'cfg_defaults_apply; cfg_set disk /dev/disk/by-id/usb-Live_Stick; questions_run' b y
  [[ $stderr == *"[!] not found, pick again"* ]]
}

@test "Keep Wi-Fi shows with a live SSID and asks for a missing key, checked like the secrets file" {
  # In a UTF-8 locale [[:print:]] counts characters; a WPA key is 8 to 63 ASCII bytes.
  q_run 'LC_ALL=C.UTF-8; HW[wifi_ssid]=home-5g; cfg_defaults_apply; questions_run' \
    5 2 '' '' short short 'ключ-ключ1' 'ключ-ключ1' good-key-1 good-key-1 b b y
  [[ $stderr == *'keep Wi-Fi "home-5g"'* ]]
  [ "$(grep -c 'It must be 8 to 63 printable ASCII characters' <<< "$stderr")" -eq 2 ]
  [[ $stderr != *"shorter than"* ]]
  source "$STATE"
  [ "${SECRET[wifi_psk]}" = good-key-1 ]
}

@test "changing the keymap clears passwords typed so far, not the ones from a secrets file" {
  q_run 'cfg_defaults_apply; SECRET[root_password]=from-file; questions_run' \
    7 '' larry pw pw '' b \
    1 3 \
    b y
  [ "$status" -eq 130 ]
  [[ $stderr == *"Passwords typed so far used the old layout"*"[!] larry has no password"* ]]
  grep -qx 'loadkeys de-latin1' "$STUB_LOG"
  source "$STATE"
  [ "${CFG[keymap]}" = de-latin1 ]
  [ -z "${SECRET[user.larry.password]+x}" ]
  [ "${SECRET[root_password]}" = from-file ]
}

@test "Save config writes the answers to the typed path, and an empty one saves nothing" {
  q_run 'cfg_defaults_apply; cfg_set hostname laptop; questions_run' \
    x - x "$BATS_TEST_TMPDIR/saved.conf" b y
  [ "$(grep -c 'Saved to' <<< "$stderr")" -eq 1 ]
  [[ $stderr == *"Saved to $BATS_TEST_TMPDIR/saved.conf."* ]]
  grep -qx hostname=laptop "$BATS_TEST_TMPDIR/saved.conf"
  [ ! -e "$GI_RUN_DIR/config" ]
}

@test "questions_hub shows locked keys read-only and ends with Continue" {
  local setup='cfg_defaults_apply; cfg_set disk "$BIG"; cfg_set encryption luks2; cfg_set users larry; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[root_password]=$PW
    cfg_lock disk filesystem encryption swap init
    rc=0; questions_hub || rc=$?; echo "hub=$rc"'
  q_run "$setup" 2 2 b ''
  [ "$status" -eq 0 ]
  [ "$output" = hub=0 ]
  [[ $stderr == *"Continue"* ]]
  [[ $stderr == *"ext4 (locked)"*"filesystem can't change once the disk step has started."* ]]
  [[ $stderr != *"== Review =="* && $stderr != *"[!]"* ]]
  source "$STATE"
  [ "${CFG[filesystem]}" = ext4 ]
  q_run "$setup" b
  [ "$output" = hub=1 ]
}

@test "unattended: every problem is listed and exits 2" {
  q_run 'GI_YES=1; CFG[encryption]=luks2; CFG[desktop]=plasma; CFG[network]=dhcpcd; cfg_defaults_apply; questions_run'
  [ "$status" -eq 2 ]
  [[ $stderr == *"error: disk: is required"* ]]
  [[ $stderr == *"error: users: needs at least one user"* ]]
  [[ $stderr == *"warn: A desktop without NetworkManager"* ]]
  [[ $stderr == *"The --secrets file needs luks_passphrase."*"The --secrets file needs root_password."* ]]
}

@test "unattended: a complete config asks nothing and passes, warnings shown" {
  q_run 'GI_YES=1; cfg_set disk "$BIG"; cfg_set users larry; cfg_set network dhcpcd; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[root_password]=$PW; questions_run; echo ok'
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [[ $stderr == *"warn: A desktop without NetworkManager"* ]]
}

@test "questions_keymap with --yes and no keymap in the config asks nothing" {
  q_run 'GI_YES=1; questions_keymap; echo ok'
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ ! -s "$STUB_LOG" ]
}

@test "unattended: a disk that isn't installable is an error" {
  q_run 'GI_YES=1; cfg_set disk /dev/disk/by-id/usb-Live_Stick; cfg_set users larry; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[root_password]=$PW; questions_run'
  [ "$status" -eq 2 ]
  [[ $stderr == *"error: disk: /dev/disk/by-id/usb-Live_Stick isn't an installable disk"* ]]
}

@test "unattended: short passwords from the secrets file get a warning, not an error" {
  q_run 'GI_YES=1; cfg_set disk "$BIG"; cfg_set users larry; cfg_defaults_apply
    SECRET[user.larry.password]=short-pw SECRET[root_password]=$PW; questions_run; echo ok'
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [[ $stderr == *"warn: user.larry.password is shorter than the 16 characters the Handbook suggests."* ]]
  [[ $stderr != *"root_password is shorter"* && $stderr != *short-pw* ]]
}

@test "a short password asks whether to keep it; No types another, and a kept one isn't warned again" {
  q_run 'cfg_defaults_apply; cfg_set disk "$BIG"; cfg_set users larry; cfg_defaults_apply
    SECRET[root_password]=$PW; questions_run' \
    '' '' '' short short n 'also short' 'also short' '' '' '' \
    '' '' nvme0n1
  [ "$status" -eq 0 ]
  [ "$(grep -c "It's shorter than the 16 characters the Handbook suggests." <<< "$stderr")" -eq 2 ]
  [[ $stderr != *"== Warnings =="* ]]
  source "$STATE"
  [ "${SECRET[user.larry.password]}" = "also short" ]
}

@test "Keep Wi-Fi: an open network takes an empty key, and a typed key can be changed" {
  q_run 'HW[wifi_ssid]=cafe; cfg_defaults_apply; questions_run' \
    5 '' '' y \
    2 '' n good-key-1 good-key-1 \
    2 '' n other-key-2 other-key-2 \
    b b y
  [ "$status" -eq 130 ]
  [ "$(grep -c 'Is cafe an open network, with no key?' <<< "$stderr")" -eq 3 ]
  [[ $stderr == *'yes, "cafe"'* ]]
  source "$STATE"
  [ "${SECRET[wifi_psk]}" = other-key-2 ]
}

@test "Keep Wi-Fi: a key from the live session isn't asked again, and the row needs NetworkManager" {
  q_run 'HW[wifi_ssid]=cafe; SECRET[wifi_psk]=live-key-123; cfg_defaults_apply; questions_run' 5 2 '' b b y
  [ "$status" -eq 130 ]
  [[ $stderr != *"open network"* && $stderr != *"Type the key"* ]]
  source "$STATE"
  [ "${SECRET[wifi_psk]}" = live-key-123 ]
  q_run 'HW[wifi_ssid]=cafe; cfg_defaults_apply; cfg_set network dhcpcd; questions_run' 5 b b y
  [ "$status" -eq 130 ]
  [[ $stderr != *"Wi-Fi key not set"* && $stderr != *"Keep Wi-Fi"* && $stderr != *'keep Wi-Fi'* ]]
}

@test "leaving systemd moves networkd to NetworkManager" {
  q_run 'cfg_defaults_apply; questions_run' \
    3 1 2 b \
    5 1 3 b \
    3 1 1 b \
    b y
  [ "$status" -eq 130 ]
  [[ $stderr == *"systemd-networkd needs systemd, so the network manager is now NetworkManager."* ]]
  source "$STATE"
  [ "${CFG[init]}" = openrc ]
  [ "${CFG[network]}" = networkmanager ]
}

@test "a value the menu doesn't offer defaults to the recommended one" {
  q_run 'cfg_defaults_apply; CFG[network]=networkd; questions_run' 5 1 '' b b y
  [ "$status" -eq 130 ]
  source "$STATE"
  [ "${CFG[network]}" = networkmanager ]
}

@test "locales split on tabs and a leading space, like the rules do" {
  q_run 'cfg_defaults_apply; questions_run' \
    6 2 $' de_DE.UTF-8\tfr_FR.UTF-8' 3 2 2 $'fr_FR.UTF-8\tit_IT.UTF-8' b b y
  [ "$status" -eq 130 ]
  [[ $stderr != *"lang: "* ]]
  source "$STATE"
  [ "${CFG[locales]}" = $'fr_FR.UTF-8\tit_IT.UTF-8' ]
  [ "${CFG[lang]}" = fr_FR.UTF-8 ]
}

@test "after the disk step, changing the keymap with LUKS warns about the passphrase first" {
  q_run 'cfg_defaults_apply; cfg_set disk "$BIG"; cfg_set encryption luks2; cfg_set users larry; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[root_password]=$PW SECRET[luks_passphrase]=$PW
    GI_Q_TYPED[luks_passphrase]=1 GI_Q_TYPED[root_password]=1
    cfg_lock disk filesystem encryption swap init
    rc=0; questions_hub || rc=$?; echo "hub=$rc"' \
    1 '' 1 y 3 ''
  [ "$status" -eq 0 ]
  [ "$output" = hub=0 ]
  [ "$(grep -c 'The disk passphrase was typed with the us layout.' <<< "$stderr")" -eq 2 ]
  [ "$(cat "$STUB_LOG")" = "loadkeys de-latin1" ]
  source "$STATE"
  [ "${CFG[keymap]}" = de-latin1 ]
  # The disk is already encrypted with it, so only the other typed passwords are cleared.
  [ "${SECRET[luks_passphrase]}" = correct-horse-battery ]
  [ -z "${SECRET[root_password]+x}" ]
}

@test "compile preview: Keep Wi-Fi leaves the open-network question and a changed key to the runner" {
  q_run 'HW[wifi_ssid]=cafe; cfg_defaults_apply; cfg_set disk "$BIG"; cfg_set users larry; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[root_password]=$PW SECRET[wifi_psk]=typed-key-1 GI_Q_TYPED[wifi_psk]=1
    cfg_lock disk filesystem encryption swap init
    rc=0; questions_hub || rc=$?; echo "hub=$rc"' \
    5 2 '' y b ''
  [ "$status" -eq 0 ]
  [ "$output" = hub=0 ]
  [[ $stderr == *"Change it? You'll type it when you choose Install in the compile preview."* ]]
  [[ $stderr != *"open network"* && $stderr != *"Password (b = back)"* ]]
  source "$STATE"
  [ "${CFG[keep_wifi]}" = yes ]
  [ -z "${SECRET[wifi_psk]+x}" ]
}

@test "dialog mode: keymap, Save config, disk menu, password and typed confirmation through the stub" {
  local typed=dialog-typed-secret-1 saved=$BATS_TEST_TMPDIR/saved.conf
  export DLG=$BATS_TEST_TMPDIR/dialog-replies
  # One "STATUS OUTPUT" line per dialog call, in order.
  printf '%s\n' '0 de-latin1' '3 ' "0 $saved" '0 ' '0 Disk' '0 Disk' '0 nvme0n1' '0 Done' \
    '0 Users' '0 larry' '0 Password' "0 $typed" "0 $typed" '0 Done' '0 Done' \
    '0 Install' '0 ' '0 ' '0 nvme0n1' > "$DLG"
  q_run 'GI_UI=dialog
    # Pops the next scripted reply into the stub canned output and status.
    dialog() {
      local line
      if [[ ! -s $DLG ]]; then echo "dialog: no scripted reply left" >&2; return 255; fi
      line=$(head -n 1 "$DLG")
      sed -i 1d "$DLG"
      printf "%s" "${line#* }" > "$STUB_OUT_DIR/dialog"
      STUB_RC_dialog=${line%% *} command dialog "$@"
    }
    questions_keymap; cfg_defaults_apply; cfg_set users larry; cfg_defaults_apply; SECRET[root_password]=$PW
    questions_run; echo done'
  [ "$status" -eq 0 ]
  [ "$output" = done ]
  [ ! -s "$DLG" ]
  [ "$(grep -c '^dialog ' "$STUB_LOG")" -eq 19 ]
  grep -qx 'loadkeys de-latin1' "$STUB_LOG"
  grep -F -- '--title Keyboard\ layout --cancel-label Quit' "$STUB_LOG" | grep -qF -- '--default-item us --menu'
  grep -F -- '--title Disk\ to\ erase' "$STUB_LOG" | grep -qF -- ' --menu '
  grep -qF -- '--extra-button --extra-label Save\ config' "$STUB_LOG"
  grep -qx keymap=de-latin1 "$saved"
  grep -qx "disk=$BIG" "$GI_RUN_DIR/config"
  run ! grep -rqF -- "$typed" "$STUB_LOG" "$GI_LOG" "$GI_RUN_DIR/config"
  source "$STATE"
  [ "${SECRET[user.larry.password]}" = "$typed" ]
}

@test "compile preview: the hub asks for no secret; a changed one is dropped for the runner to ask" {
  q_run 'cfg_defaults_apply; cfg_set disk "$BIG"; cfg_set users larry; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[root_password]=$PW
    cfg_lock disk filesystem encryption swap init
    rc=0; questions_hub || rc=$?; echo "hub=$rc"' \
    7 2 anna 4 '' y 1 1 '' 5 2 5 6 \
    b
  [ "$status" -eq 0 ]
  [ "$output" = hub=1 ]
  [ "$(grep -c "You'll type it when you choose Install in the compile preview." <<< "$stderr")" -eq 3 ]
  [[ $stderr == *"Password  asked when the compile preview ends"* ]]
  [[ $stderr != *"Password (b = back)"* && $stderr != *"[!]"* ]]
  source "$STATE"
  [ "${CFG[users]}" = "larry anna" ]
  [ -z "${SECRET[user.anna.password]+x}" ]
  [ -z "${SECRET[root_password]+x}" ]
  [ "${SECRET[user.larry.password]}" = correct-horse-battery ]
}

@test "compile preview: a keymap change says the runner asks the cleared passwords again" {
  q_run 'cfg_defaults_apply; cfg_set disk "$BIG"; cfg_set users larry; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[root_password]=$PW GI_Q_TYPED[user.larry.password]=1
    cfg_lock disk filesystem encryption swap init
    rc=0; questions_hub || rc=$?; echo "hub=$rc"' \
    1 3 ''
  [ "$output" = hub=0 ]
  [[ $stderr == *"so they were cleared. You'll type them again when you choose Install in the compile preview."* ]]
  source "$STATE"
  [ -z "${SECRET[user.larry.password]+x}" ]
  [ "${SECRET[root_password]}" = correct-horse-battery ]
  # On --resume the runner asked for root's password; it drops that one itself after the step.
  q_run 'cfg_defaults_apply; cfg_set disk "$BIG"; cfg_set users larry; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[root_password]=$PW GI_ASKED_SECRETS[root_password]=1
    cfg_lock disk filesystem encryption swap init
    rc=0; questions_hub || rc=$?; echo "hub=$rc"' \
    1 3 ''
  [ "$output" = hub=0 ]
  [[ $stderr == *"so they were cleared. You'll type them again when you choose Install in the compile preview."* ]]
}

@test "compile preview: Back checks the answers like Continue, since the step keeps them" {
  q_run 'cfg_defaults_apply; cfg_set disk "$BIG"; cfg_set users larry; cfg_defaults_apply
    SECRET[user.larry.password]=$PW SECRET[root_password]=$PW
    cfg_lock disk filesystem encryption swap init
    rc=0; questions_hub || rc=$?; echo "hub=$rc"' \
    7 1 4 y 4 b \
    7 1 bob 5 b
  [ "$status" -eq 0 ]
  [ "$output" = hub=1 ]
  [[ $stderr == *"These sections still need an answer: Users."* ]]
  source "$STATE"
  [ "${CFG[users]}" = bob ]
}

@test "the NVIDIA row says what part H's detection will install" {
  export GI_HOST_ROOT=$BATS_TEST_TMPDIR/host
  local d=$GI_HOST_ROOT/sys/bus/pci/devices/0000:01:00.0
  mkdir -p "$d"
  echo 0x10de > "$d/vendor"
  echo 0x030000 > "$d/class"
  local code='source "$GI_HOME/lib/steps/graphics.sh"; HW[gpus]="intel nvidia"; cfg_defaults_apply; questions_run'
  echo 0x1180 > "$d/device" # GTX 680, Kepler
  q_run "$code" 3 4 5 b y
  [ "$status" -eq 130 ]
  [[ $stderr == *"NVIDIA driver  nouveau (card too old for NVIDIA's driver)"* ]]
  [[ $stderr == *"This NVIDIA card is a Kepler model or older."* ]]
  source "$STATE"
  [ "${CFG[nvidia_driver]}" = proprietary ]
  echo 0x1b80 > "$d/device" # GTX 1080, Pascal
  q_run "$code" 3 4 '?' '' 5 b y
  [[ $stderr == *"NVIDIA driver  proprietary (580 series)"* ]]
  [[ $stderr == *"The 580 series, the last one for this card"* ]]
  echo 0x2684 > "$d/device" # RTX 4090, Ada
  q_run "$code" 3 5 b y
  [[ $stderr == *"NVIDIA driver  proprietary"* ]]
  [[ $stderr != *"580"* && $stderr != *"too old"* ]]
}

@test "Audio says ALSA only where part H leaves PipeWire out: OpenRC without a desktop" {
  local code='source "$GI_HOME/lib/steps/hardware.sh"; cfg_defaults_apply; cfg_set desktop none; questions_run'
  q_run "$code" 4 '' b y
  [ "$status" -eq 130 ]
  [[ $stderr == *"Desktop   console only, ALSA only, Bluetooth"* ]]
  [[ $stderr =~ Audio\ +ALSA\ only:\ PipeWire\ needs\ a\ desktop\ on\ OpenRC ]]
  q_run "${code/desktop none/init systemd; cfg_set desktop none}" b y
  [[ $stderr == *"Desktop   console only, pipewire, Bluetooth"* ]]
  q_run "${code/desktop none/desktop plasma}" b y
  [[ $stderr == *"Desktop   plasma, pipewire, Bluetooth"* ]]
}

@test "Desktop rows follow the desktop: login screen, GNOME variant, and no browser or CJK fonts on the console" {
  q_run 'source "$GI_HOME/lib/steps/hardware.sh"; cfg_defaults_apply; questions_run' 4 1 "$(desktop_choice gnome)" 1 "$(desktop_choice none)" b b y
  [ "$status" -eq 130 ]
  [[ $stderr =~ Login\ screen\ +auto\ \(SDDM\) ]]
  [[ $stderr =~ GNOME\ variant\ +light.*Login\ screen\ +auto\ \(GDM\) ]]
  # The last Desktop submenu, after choosing console only.
  local last=${stderr##*== Desktop ==}
  last=${last%%== Install Gentoo ==*}
  [[ $last =~ Desktop\ +none ]]
  [[ $last != *"Login screen"* && $last != *"GNOME variant"* && $last != *Browser* && $last != *"CJK fonts"* ]]
  # step_desktop_packages installs no browser without a desktop, so the hub doesn't promise one.
  [[ $stderr == *"Desktop   console only, ALSA only, Bluetooth, ppd"$'\n'* ]]
  [[ $stderr != *"console only"*firefox-bin* ]]
  source "$STATE"
  [ "${CFG[desktop]}" = none ]
  [ "${CFG[browser]}" = firefox-bin ]
}

@test "the new desktops: LightDM for Xfce, no login screen row for window managers, overlay help" {
  q_run 'source "$GI_HOME/lib/steps/hardware.sh"; cfg_defaults_apply; questions_run' 4 1 '?' "$(desktop_choice xfce)" 1 "$(desktop_choice i3)" b b y
  [ "$status" -eq 130 ]
  [[ $stderr == *" 13) none      Console only."* ]]
  [[ $stderr == *"Budgie, with LightDM.: From a third-party overlay that Gentoo doesn't review. Builds from source."* ]]
  [[ $stderr == *"Hyprland, tiling for Wayland.: From a third-party overlay that Gentoo doesn't review. Builds from source."* ]]
  [[ $stderr == *"Niri, scrolling tiles, Wayland.: From GURU, a user overlay that Gentoo doesn't review. Builds from source."* ]]
  [[ $stderr == *"MangoWM, tiling for Wayland.: From GURU, a user overlay that Gentoo doesn't review. Builds from source."* ]]
  [[ $stderr =~ Login\ screen\ +auto\ \(LightDM\) ]]
  local last=${stderr##*== Desktop ==}
  last=${last%%== Install Gentoo ==*}
  [[ $last =~ Desktop\ +i3 ]]
  [[ $last != *"Login screen"* ]]
  [[ $last == *Browser* ]]
  [[ $stderr == *"Desktop   i3, pipewire, Bluetooth, ppd, firefox-bin"* ]]
  source "$STATE"
  [ "${CFG[desktop]}" = i3 ]
  [ "${CFG[display_manager]}" = auto ]
}

@test "Media keys: a row for sway, Hyprland and niri only, off by default, with GURU named where it adds it" {
  local code='source "$GI_HOME/lib/steps/hardware.sh"; cfg_defaults_apply; questions_run'
  q_run "$code" 4 1 "$(desktop_choice sway)" 7 '?' 2 1 "$(desktop_choice i3)" b b y
  [ "$status" -eq 130 ]
  # Plasma, the default, has none.
  local first=${stderr#*== Desktop ==}
  first=${first%%== Desktop ==*}
  [[ $first != *"Media keys"* ]]
  [[ $stderr =~ Media\ keys\ +no ]]
  [[ $stderr == *"Sway's default config calls brightnessctl, playerctl and grim for the brightness, player and Print keys. Installing them builds 3 small packages from source."* ]]
  [[ $stderr == *"The volume keys work either way."* ]]
  [[ $stderr == *"Leave them out. Recommended.: Those keys do nothing until you install the programs."* ]]
  [[ $stderr == *"Install them.: brightnessctl is from GURU, a user overlay that Gentoo doesn't review."$'\n'* ]]
  local last=${stderr##*== Desktop ==}
  last=${last%%== Install Gentoo ==*}
  [[ $last =~ Desktop\ +i3 ]]
  [[ $last != *"Media keys"* ]]
  source "$STATE"
  [ "${CFG[media_keys]}" = yes ]
  q_run "$code" 4 1 "$(desktop_choice hyprland)" 7 '?' 2 b b y
  [[ $stderr == *"Hyprland's default config calls brightnessctl and playerctl for the brightness and player keys. Installing them builds 2 small packages from source."* ]]
  [[ $stderr == *"Install them.: brightnessctl is from GURU, a user overlay that Gentoo doesn't review."* ]]
  q_run "$code" 4 1 "$(desktop_choice niri)" 7 '?' 2 b b y
  [[ $stderr == *"Niri's default config calls brightnessctl and playerctl for the brightness and player keys. Installing them builds 2 small packages from source."* ]]
  [[ $stderr == *"Install them.: Builds them from source."* ]]
}

@test "the media keys question names what the desktop step installs, and GURU where the portage step adds it" {
  gi_load core ui config state questions desktop portage
  local d t tools text ovl
  cfg_defaults_apply
  ui_radio() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/radio"; return 1; }
  for d in plasma gnome xfce budgie cinnamon i3 sway hyprland niri mangowm dwm dwl none; do
    CFG[desktop]=$d CFG[media_keys]=yes
    tools=$(_desktop_media_keys) text=$(_q_media_keys)
    if [[ -z $tools ]]; then
      [ -z "$text" ] || { echo "$d: $text"; false; }
      continue
    fi
    for t in $tools; do [[ $text == *" ${t#*/}"[\ ,]* ]] || { echo "$d: $t"; false; }; done
    _q_edit media_keys || true
    ovl=$(_portage_overlay)
    CFG[media_keys]=no
    if [[ $ovl != "$(_portage_overlay)" ]]; then
      grep -q GURU "$BATS_TEST_TMPDIR/radio" || { echo "$d: no GURU"; false; }
    else
      run ! grep -q GURU "$BATS_TEST_TMPDIR/radio"
    fi
  done
}

@test "the media keys and shell choices' help fits the one line dialog shows it on at 80 columns" {
  gi_load core ui config state questions
  local k i
  local -a a=()
  cfg_defaults_apply
  CFG[users]=alice
  ui_radio() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/radio"; return 1; }
  # dialog drops the words past 78 characters.
  for k in sway hyprland niri shell; do
    if [[ $k == shell ]]; then _q_edit user.alice.shell || true; else CFG[desktop]=$k && { _q_edit media_keys || true; }; fi
    mapfile -t a < "$BATS_TEST_TMPDIR/radio"
    for ((i = 5; i < ${#a[@]}; i += 3)); do ((${#a[i]} <= 78)) || { echo "$k: ${a[i]}"; false; }; done
  done
}

@test "the media keys row and question claim only what the desktop and audio answers give" {
  gi_load core ui config state questions desktop
  local d row text
  cfg_defaults_apply
  ui_radio() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/radio"; return 1; }
  for d in sway hyprland niri; do
    CFG[desktop]=$d CFG[media_keys]=yes CFG[audio]=pipewire
    row=$(_q_keys Desktop | grep '^media_keys' | cut -f3)
    ((${#row} <= 78))
    # Only sway's config has a screenshot program to install.
    if [[ $row == *[Ss]creenshot* || $row == *Print* ]]; then [[ $(_desktop_media_keys) == *grim* ]]; fi
    _q_edit media_keys || true
    [[ $(sed -n 2p "$BATS_TEST_TMPDIR/radio") == *" The volume keys work either way." ]]
    # Without a sound server pactl and wpctl have nothing to talk to.
    CFG[audio]=none
    _q_edit media_keys || true
    text=$(sed -n 2p "$BATS_TEST_TMPDIR/radio")
    [[ $text != *"work either way"* && $text == *"With Audio set to none, the volume keys do nothing either way." ]]
  done
}

@test "the login screen the menus name is the one the desktop step installs, for every desktop" {
  gi_load core ui config state questions desktop
  local d q
  CFG[display_manager]=auto
  for d in plasma gnome xfce budgie cinnamon i3 sway hyprland niri mangowm dwm dwl none; do
    CFG[desktop]=$d
    q=$(_q_login_screen)
    [ "${q,,}" = "$(_desktop_dm)" ] || { echo "$d: $q"; false; }
  done
}
