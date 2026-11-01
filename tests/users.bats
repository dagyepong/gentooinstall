#!/usr/bin/env bats
# Tests for lib/steps/users.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core state users
  CFG[init]=openrc CFG[users]=larry CFG[user.larry.admin]=yes CFG[user.larry.shell]=bash CFG[privilege]=sudo
  SECRET[user.larry.password]=correct-horse-battery-staple
  mkdir -p "$GI_TARGET/etc"
  # The stage3's groups that matter here, and a few accounts.
  printf '%s\n' root:x:0: wheel:x:10:root lp:x:7: audio:x:18: video:x:27: usb:x:85: users:x:100: portage:x:250: \
    > "$GI_TARGET/etc/group"
  printf '%s\n' root:x:0:0:root:/root:/bin/bash portage:x:250:250:portage:/var/lib/portage/home:/sbin/nologin \
    > "$GI_TARGET/etc/passwd"
}

step() { (
  set -e
  "$@"
); }

chroot_cmds() {
  sed -n "s|^arch-chroot [^ ]* /bin/bash -c 'source /etc/profile \&\& \(.*\); exit \$?'\(  # (stdin: not recorded)\)\{0,1\}\$|\1|p" "$GI_RUN_DIR/replay.sh"
}

@test "packages: zsh and fish only when a user picked them" {
  run step_users_packages
  [ -z "$output" ]
  CFG[users]='larry anna' CFG[user.anna.shell]=fish CFG[user.larry.shell]=zsh
  run step_users_packages
  [ "$output" = $'app-shells/zsh\napp-shells/fish' ]
}

@test "creates an admin with the Handbook groups and sets the password through chpasswd on stdin" {
  export STUB_STDIN_DIR=$BATS_TEST_TMPDIR/stdin
  mkdir -p "$STUB_STDIN_DIR"
  run --separate-stderr step step_users
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  run chroot_cmds
  [ "${lines[0]}" = 'useradd -m -G users\,audio\,video\,usb\,wheel -s /bin/bash larry' ]
  [ "${lines[1]}" = 'chpasswd' ]
  [ "$(cat "$STUB_STDIN_DIR/arch-chroot")" = 'larry:correct-horse-battery-staple' ]
}

@test "passwords never reach arguments, the log or the replay script" {
  CFG[users]='larry anna' CFG[user.anna.admin]=no CFG[user.anna.shell]=bash
  SECRET[user.anna.password]='an na pass word 1234'
  step step_users
  run ! grep -rqF -e correct-horse -e 'an na pass' -e 'an\ na' "$STUB_LOG" "$GI_LOG" "$GI_RUN_DIR/replay.sh"
  grep -qF 'chpasswd; exit $?'\''  # (stdin: not recorded)' "$GI_RUN_DIR/replay.sh"
}

@test "users: no wheel for non-admins, zsh and fish paths" {
  CFG[users]='larry anna bob' CFG[user.larry.shell]=zsh CFG[user.anna.admin]=no CFG[user.anna.shell]=fish
  CFG[user.bob.admin]=no CFG[user.bob.shell]=bash
  SECRET[user.anna.password]=0123456789abcdef SECRET[user.bob.password]=0123456789abcdef
  step step_users
  run chroot_cmds
  [ "${lines[0]}" = 'useradd -m -G users\,audio\,video\,usb\,wheel -s /bin/zsh larry' ]
  [ "${lines[1]}" = 'useradd -m -G users\,audio\,video\,usb -s /usr/bin/fish anna' ]
  [ "${lines[2]}" = 'useradd -m -G users\,audio\,video\,usb -s /bin/bash bob' ]
}

@test "only groups that exist in the target are used" {
  sed -i '/^usb:/d;/^video:/d' "$GI_TARGET/etc/group"
  step step_users
  run chroot_cmds
  [ "${lines[0]}" = 'useradd -m -G users\,audio\,wheel -s /bin/bash larry' ]
}

@test "a rerun updates an existing user instead of adding it again" {
  echo 'larry:x:1000:1000::/home/larry:/bin/bash' >> "$GI_TARGET/etc/passwd"
  CFG[user.larry.shell]=fish
  step step_users
  run chroot_cmds
  [ "${lines[0]}" = 'usermod -G users\,audio\,video\,usb\,wheel -s /usr/bin/fish larry' ]
  [ "${lines[1]}" = 'chpasswd' ]
}

@test "a name that is a system account in the target is refused" {
  CFG[users]=portage SECRET[user.portage.password]=0123456789abcdef
  CFG[user.portage.admin]=no CFG[user.portage.shell]=bash
  run step step_users
  [ "$status" -eq 1 ]
  [[ $output == *"portage is a system account"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "a missing or empty password stops the step before anything runs" {
  unset 'SECRET[user.larry.password]'
  run step step_users
  [ "$status" -eq 1 ]
  [[ $output == *"No password was given for user larry"* ]]
  SECRET[user.larry.password]=''
  run step step_users
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_LOG" ]
}

# The questions warn about short passwords; the step sets what the user chose to keep.
@test "a short password is set without a second warning" {
  SECRET[user.larry.password]=tiny7
  run --separate-stderr step step_users
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  run chroot_cmds
  [ "${lines[1]}" = 'chpasswd' ]
}

@test "sudo: wheel drop-in, mode 0440, checked with visudo before it's moved in place" {
  step step_users
  f=$GI_TARGET/etc/sudoers.d/wheel
  [ "$(cat "$f")" = '%wheel ALL=(ALL:ALL) ALL' ]
  [ "$(stat -c %a "$f")" = 440 ]
  [ ! -e "$f.new" ]
  run chroot_cmds
  [ "${lines[2]}" = 'visudo -cf /etc/sudoers.d/wheel.new' ]
  [ ! -e "$GI_TARGET/etc/doas.conf" ]
}

@test "sudo: a draft that fails visudo is never put in place" {
  export STUB_RC_arch_chroot=1
  run step _users_sudo
  [ "$status" -eq 1 ]
  [ ! -e "$GI_TARGET/etc/sudoers.d/wheel" ]
}

@test "doas: permit :wheel, mode 0600, without persist unless doas was built with it" {
  CFG[privilege]=doas
  mkdir -p "$GI_TARGET/var/db/pkg/app-admin/doas-6.8.2"
  echo 'abi_x86_64 amd64 elibc_glibc kernel_linux pam' > "$GI_TARGET/var/db/pkg/app-admin/doas-6.8.2/USE"
  step step_users
  [ "$(cat "$GI_TARGET/etc/doas.conf")" = 'permit :wheel' ]
  [ "$(stat -c %a "$GI_TARGET/etc/doas.conf")" = 600 ]
  [ ! -e "$GI_TARGET/etc/sudoers.d" ]
  echo 'abi_x86_64 amd64 elibc_glibc kernel_linux pam persist' > "$GI_TARGET/var/db/pkg/app-admin/doas-6.8.2/USE"
  step step_users
  [ "$(cat "$GI_TARGET/etc/doas.conf")" = 'permit persist :wheel' ]
}

@test "dry-run prints the commands, keeps passwords out and changes nothing" {
  GI_DRY_RUN=1
  # A dry run has an empty target: no accounts, no shells, no sudo.
  rm -rf "$GI_TARGET"/*
  run --separate-stderr step step_users
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$GI_TARGET/etc" ]
  [[ $stderr == *'useradd -m -G users\,audio\,video\,usb\,wheel -s /bin/bash larry'* ]]
  [[ $stderr == *"chpasswd; exit \$?'  # (stdin: not recorded)"* ]]
  [[ $stderr == *'visudo -cf /etc/sudoers.d/wheel.new'* ]]
  [[ $stderr != *correct-horse* ]]
}

@test "with printing, admins join lpadmin, which may add printers" {
  echo 'lpadmin:x:106:' >> "$GI_TARGET/etc/group"
  CFG[printing]=yes CFG[users]="larry anna" CFG[user.anna.admin]=no CFG[user.anna.shell]=bash
  SECRET[user.anna.password]=correct-horse-battery-staple
  step step_users
  run chroot_cmds
  [ "${lines[0]}" = 'useradd -m -G users\,audio\,video\,usb\,wheel\,lpadmin -s /bin/bash larry' ]
  [[ $output == *'useradd -m -G users\,audio\,video\,usb -s /bin/bash anna'* ]]
}
