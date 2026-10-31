#!/usr/bin/env bats
# Tests for lib/core.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui
}

fixture() { cp "$GI_HOME/tests/fixtures/emerge/$1.txt" "$STUB_OUT_DIR/arch-chroot"; }

@test "log writes a timestamped line to the log only" {
  run --separate-stderr log INFO "hello there"
  [ -z "$output" ]
  [ -z "$stderr" ]
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} INFO hello there$' "$GI_LOG"
}

@test "info, warn and error print to stderr and log" {
  run --separate-stderr warn "disk is small"
  [ "$stderr" = "warning: disk is small" ]
  grep -q 'WARN disk is small' "$GI_LOG"
}

@test "die exits with the given code" {
  run die "broken" 7
  [ "$status" -eq 7 ]
  [[ $output == *"error: broken"* ]]
}

@test "redact masks secrets, longest first, raw and %q-quoted" {
  SECRET[a]=abc SECRET[b]=abcdef SECRET[c]='pa ss' SECRET[d]=''
  run redact 'x abcdef abc pa\ ss pa ss y'
  [ "$output" = 'x *** *** *** *** y' ]
}

@test "run_cmd executes the command, logs it and keeps its output out of stdout" {
  echo "stub says hi" > "$STUB_OUT_DIR/wipefs"
  run --separate-stderr run_cmd wipefs --all /dev/disk/by-id/x
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qx 'wipefs --all /dev/disk/by-id/x' "$STUB_LOG"
  grep -q 'CMD wipefs --all /dev/disk/by-id/x' "$GI_LOG"
  grep -qx 'stub says hi' "$GI_LOG"
  grep -qx 'wipefs --all /dev/disk/by-id/x' "$GI_RUN_DIR/replay.sh"
}

@test "run_cmd returns the command's status" {
  export STUB_RC_mkfs_ext4=3
  run run_cmd mkfs.ext4 -L root /dev/x
  [ "$status" -eq 3 ]
  grep -q 'ERROR exit status 3 from mkfs.ext4' "$GI_LOG"
}

@test "dry-run prints commands and runs nothing" {
  GI_DRY_RUN=1
  run --separate-stderr run_cmd sfdisk /dev/x
  [ "$status" -eq 0 ]
  [ "$stderr" = "sfdisk /dev/x" ]
  [ ! -s "$STUB_LOG" ]
  grep -qx 'sfdisk /dev/x' "$GI_RUN_DIR/replay.sh"
}

@test "explain mode shows each command" {
  GI_EXPLAIN=1
  run --separate-stderr run_cmd mount /dev/x /mnt
  [[ $stderr == *'$ mount /dev/x /mnt' ]]
}

@test "safety net refuses real commands under test" {
  run --separate-stderr run_cmd uname -a
  [ "$status" -eq 126 ]
  [[ $stderr == *"test safety net: refusing to run uname"* ]]
  run run_cmd /usr/bin/id
  [ "$status" -eq 126 ]
}

@test "safety net allows stubs and file utilities" {
  run run_cmd mkdir -p "$GI_TARGET/a/b"
  [ "$status" -eq 0 ]
  [ -d "$GI_TARGET/a/b" ]
}

@test "run_chroot wraps the command in arch-chroot with /etc/profile" {
  run run_chroot emerge --sync "a b"
  [ "$status" -eq 0 ]
  expected=$(printf 'arch-chroot %q /bin/bash -c %q' "$GI_TARGET" "source /etc/profile && emerge --sync a\\ b; exit \$?")
  [ "$(cat "$STUB_LOG")" = "$expected" ]
  grep -qF "arch-chroot $GI_TARGET /bin/bash -c 'source /etc/profile && emerge --sync a\\ b; exit \$?'" "$GI_RUN_DIR/replay.sh"
}

@test "chroot scripts keep bash as PID 1: arch-chroot's PID namespace would make an exec'd command init" {
  # The child prints its parent, which is bash only if bash forked it instead of exec'ing it.
  script=$(chroot_script 'sh -c "echo \$PPID"')
  bash -c "${script/#source \/etc\/profile/true}" > "$BATS_TEST_TMPDIR/ppid" &
  pid=$!
  wait "$pid"
  [ "$(cat "$BATS_TEST_TMPDIR/ppid")" = "$pid" ]
  # emerge_run builds its script the same way.
  emerge_run --sync
  grep -qF "emerge --sync; exit \$?'" "$GI_RUN_DIR/replay.sh"
}

@test "dry-run runs nothing in the chroot" {
  GI_DRY_RUN=1
  run_chroot rc-update add sshd default 2> /dev/null
  emerge_run --sync 2> /dev/null
  [ ! -s "$STUB_LOG" ]
}

@test "run_stdin feeds data on stdin and records neither it nor its length" {
  export STUB_STDIN_DIR=$BATS_TEST_TMPDIR
  run_stdin $'larry:pw\n' chpasswd
  run_chroot_stdin $'root:pw\n' chpasswd
  [ "$(cat "$BATS_TEST_TMPDIR/chpasswd")" = "larry:pw" ]
  [ "$(head -n 1 "$STUB_LOG")" = "chpasswd" ]
  grep -qx 'chpasswd  # (stdin: not recorded)' "$GI_RUN_DIR/replay.sh"
  grep -q 'CMD chpasswd  # (stdin: not recorded)$' "$GI_LOG"
  grep -q "CMD arch-chroot .*chpasswd; exit \$?'  # (stdin: not recorded)\$" "$GI_LOG"
  run ! grep -rE '[0-9] bytes' "$GI_LOG" "$GI_RUN_DIR/replay.sh"
  GI_DRY_RUN=1
  run --separate-stderr run_stdin 'luks passphrase' cryptsetup open --key-file=- /dev/x root
  [ "$stderr" = 'cryptsetup open --key-file=- /dev/x root  # (stdin: not recorded)' ]
}

@test "run_interactive keeps the terminal, logs the command and is a comment in the replay script" {
  local rc=0
  export STUB_STDIN_DIR=$BATS_TEST_TMPDIR STUB_RC_arch_chroot=3
  echo 'shell output' > "$STUB_OUT_DIR/arch-chroot"
  run_interactive arch-chroot "$GI_TARGET" <<< 'typed by the user' > "$BATS_TEST_TMPDIR/out" || rc=$?
  [ "$rc" -eq 3 ]
  [ "$(cat "$BATS_TEST_TMPDIR/arch-chroot")" = 'typed by the user' ]
  [ "$(cat "$BATS_TEST_TMPDIR/out")" = 'shell output' ]
  run ! grep -q 'shell output' "$GI_LOG"
  grep -q "CMD # interactive: arch-chroot $GI_TARGET\$" "$GI_LOG"
  grep -qx "# interactive: arch-chroot $GI_TARGET" "$GI_RUN_DIR/replay.sh"
}

@test "run_interactive goes through the test safety net and does nothing in a dry run" {
  run --separate-stderr run_interactive arch-chroot "$GI_TARGET"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "arch-chroot $GI_TARGET" ]
  run --separate-stderr run_interactive /bin/sh -i
  [ "$status" -eq 126 ]
  [[ $stderr == *'test safety net: refusing to run /bin/sh'* ]]
  : > "$STUB_LOG"
  GI_DRY_RUN=1
  run --separate-stderr run_interactive arch-chroot "$GI_TARGET"
  [ "$status" -eq 0 ]
  [ "$stderr" = "# interactive: arch-chroot $GI_TARGET" ]
  [ ! -s "$STUB_LOG" ]
}

@test "secrets never reach the log, the replay script or any arguments" {
  local s='S3cr3t pass$word'
  SECRET[root_password]=$s
  export STUB_STDIN_DIR=$BATS_TEST_TMPDIR
  echo "$s" > "$STUB_OUT_DIR/cryptsetup"
  run_stdin "$s" cryptsetup luksFormat --type luks2 /dev/x
  run_chroot_stdin "root:$s" chpasswd
  printf 'psk=%s\n' "$s" | write_secret_file /etc/NetworkManager/system-connections/home.nmconnection
  printf 'oops %s\n' "$s" | write_file /etc/motd
  info "typed $s"
  log INFO "$s"
  run_stdin "$s" cat
  [ "$(cat "$BATS_TEST_TMPDIR/cryptsetup")" = "$s" ]
  run ! grep -rF -- "$s" "$GI_LOG" "$GI_RUN_DIR/replay.sh" "$STUB_LOG"
  run ! grep -rF -- "S3cr3t" "$GI_LOG" "$GI_RUN_DIR/replay.sh" "$STUB_LOG"
  grep -q 'secret content not logged' "$GI_LOG"
  [ "$(stat -c %a "$GI_TARGET/etc/NetworkManager/system-connections/home.nmconnection")" = 600 ]
}

@test "write_file writes atomically with mode and parent dirs" {
  printf 'laptop\n' | write_file /etc/hostname
  [ "$(cat "$GI_TARGET/etc/hostname")" = laptop ]
  [ "$(stat -c %a "$GI_TARGET/etc/hostname")" = 644 ]
  printf 'x' | write_file /etc/sudoers.d/wheel 0440
  [ "$(stat -c %a "$GI_TARGET/etc/sudoers.d/wheel")" = 440 ]
  [ -z "$(find "$GI_TARGET" -name '.gi.*')" ]
  grep -q "cat > $GI_TARGET/etc/hostname <<'GI_EOF'" "$GI_RUN_DIR/replay.sh"
}

@test "write_file keeps trailing newlines" {
  printf 'a\n\n' | write_file /etc/x
  [ "$(od -An -c "$GI_TARGET/etc/x" | tr -d ' ')" = 'a\n\n' ]
}

@test "write_file in dry-run prints and writes nothing" {
  GI_DRY_RUN=1
  run --separate-stderr write_file /etc/hostname <<< laptop
  [ "$status" -eq 0 ]
  [ ! -e "$GI_TARGET/etc/hostname" ]
  [[ $stderr == *"write $GI_TARGET/etc/hostname (mode 0644)"*laptop* ]]
}

@test "write_file replaces a symlink instead of writing through it" {
  mkdir -p "$GI_TARGET/etc"
  echo live > "$BATS_TEST_TMPDIR/live"
  ln -s "$BATS_TEST_TMPDIR/live" "$GI_TARGET/etc/resolv.conf"
  echo new | write_file /etc/resolv.conf
  [ "$(cat "$BATS_TEST_TMPDIR/live")" = live ]
  [ ! -L "$GI_TARGET/etc/resolv.conf" ]
}

@test "write_file refuses paths that resolve outside the target" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  ln -s "$BATS_TEST_TMPDIR/outside" "$GI_TARGET/run"
  run write_file /run/x <<< data
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/outside/x" ]
  run write_file etc/relative <<< data
  [ "$status" -ne 0 ]
}

@test "ensure_line appends once" {
  printf 'a' | write_file /etc/x 0600
  ensure_line /etc/x b
  ensure_line /etc/x b
  ensure_line /etc/x a
  [ "$(cat "$GI_TARGET/etc/x")" = $'a\nb' ]
  [ "$(stat -c %a "$GI_TARGET/etc/x")" = 600 ]
}

@test "set_shell_var replaces, deduplicates and appends" {
  printf '# c\nUSE="a"\nX=1\nUSE="b"\n' | write_file /etc/portage/make.conf
  set_shell_var /etc/portage/make.conf USE 'a b'
  set_shell_var /etc/portage/make.conf FEATURES '${FEATURES} getbinpkg'
  [ "$(cat "$GI_TARGET/etc/portage/make.conf")" = $'# c\nUSE="a b"\nX=1\nFEATURES="${FEATURES} getbinpkg"' ]
  run set_shell_var /etc/portage/make.conf X 'a"b'
  [ "$status" -ne 0 ]
}

@test "portage_file writes under /etc/portage and checks its kind" {
  echo 'sys-kernel/installkernel dracut' | portage_file package.use installkernel
  [ "$(cat "$GI_TARGET/etc/portage/package.use/installkernel")" = 'sys-kernel/installkernel dracut' ]
  run portage_file package.mask x <<< y
  [ "$status" -ne 0 ]
  run portage_file package.use ../x <<< y
  [ "$status" -ne 0 ]
}

@test "make_conf_use_add keeps flags and never duplicates" {
  printf 'COMMON_FLAGS="-O2"\nUSE="dist-kernel"\n' | write_file /etc/portage/make.conf
  make_conf_use_add networkmanager dist-kernel
  make_conf_use_add networkmanager -gtk
  grep -qx 'USE="dist-kernel networkmanager -gtk"' "$GI_TARGET/etc/portage/make.conf"
  grep -qx 'COMMON_FLAGS="-O2"' "$GI_TARGET/etc/portage/make.conf"
}

@test "emerge_run shows N of M progress for binary and source packages" {
  fixture parallel
  progress_status() { echo "$1" >> "$BATS_TEST_TMPDIR/progress"; }
  emerge_run --jobs 2 app-misc/screen
  [ "$(sed -n '1p;2p' "$BATS_TEST_TMPDIR/progress")" = $'1 of 5  app-misc/hello-2.12.3 (source)\n2 of 5  dev-libs/oniguruma-6.9.10 (binary)' ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/progress")" -eq 5 ]
  [ ! -e "$GI_RUN_DIR/last_failure" ]
  grep -q 'Completed (5 of 5)' "$GI_LOG"
}

@test "emerge_run records a serial build failure for the error menu" {
  fixture fail-serial
  export STUB_RC_arch_chroot=1
  mkdir -p "$GI_TARGET/var/tmp/portage/app-misc/hello-2.12.3/temp"
  echo "configure: error" > "$GI_TARGET/var/tmp/portage/app-misc/hello-2.12.3/temp/build.log"
  run emerge_run app-misc/hello
  [ "$status" -eq 1 ]
  [ "$(cat "$GI_RUN_DIR/last_failure")" = "package=app-misc/hello-2.12.3
build_log=$GI_TARGET/var/tmp/portage/app-misc/hello-2.12.3/temp/build.log
exit=1" ]
  [ "$(cat "$GI_RUN_DIR/build-logs/app-misc_hello-2.12.3.log")" = "configure: error" ]
}

@test "emerge_run finds the failed package in parallel output" {
  fixture fail-parallel
  export STUB_RC_arch_chroot=1
  run emerge_run --jobs 2 app-text/tree app-misc/hello
  [ "$status" -eq 1 ]
  grep -qx 'package=app-misc/hello-2.12.3' "$GI_RUN_DIR/last_failure"
  grep -qx "build_log=$GI_TARGET/var/tmp/portage/app-misc/hello-2.12.3/temp/build.log" "$GI_RUN_DIR/last_failure"
}

@test "emerge_run without a package failure still records the exit status" {
  echo '!!! Multiple package instances within a single package slot' > "$STUB_OUT_DIR/arch-chroot"
  export STUB_RC_arch_chroot=1
  run emerge_run @world
  [ "$(cat "$GI_RUN_DIR/last_failure")" = "exit=1" ]
}

@test "service_enable uses rc-update on OpenRC and systemctl on systemd" {
  CFG[init]=openrc
  service_enable sshd
  service_enable elogind boot
  CFG[init]=systemd
  service_enable sshd
  grep -q 'rc-update\\ add\\ sshd\\ default' "$STUB_LOG"
  grep -q 'rc-update\\ add\\ elogind\\ boot' "$STUB_LOG"
  grep -q 'systemctl\\ enable\\ sshd' "$STUB_LOG"
}

@test "user_service_enable_global does nothing on OpenRC" {
  CFG[init]=openrc
  user_service_enable_global pipewire.socket
  [ ! -s "$STUB_LOG" ]
  CFG[init]=systemd
  user_service_enable_global pipewire.socket wireplumber.service
  grep -q 'systemctl\\ --global\\ enable\\ pipewire.socket\\ wireplumber.service' "$STUB_LOG"
}

@test "dry_value prints the placeholder in dry-run and runs the query otherwise" {
  echo 1234-ABCD > "$STUB_OUT_DIR/blkid"
  [ "$(dry_value '<uuid>' blkid -s UUID -o value /dev/x)" = 1234-ABCD ]
  GI_DRY_RUN=1
  [ "$(dry_value '<uuid>' blkid -s UUID -o value /dev/x)" = '<uuid>' ]
}

@test "dry_value runs a step's query function, but a command must pass the safety net" {
  query() { echo "found $1"; }
  [ "$(dry_value '<x>' query disk)" = "found disk" ]
  run --separate-stderr dry_value '<x>' uname -a
  [ "$status" -eq 126 ]
  [[ $stderr == *"test safety net: refusing to run uname"* ]]
}

@test "safety net allows file utilities by bare name only" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\ntouch %s/ran\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/rm"
  chmod +x "$BATS_TEST_TMPDIR/bin/rm"
  run run_cmd "$BATS_TEST_TMPDIR/bin/rm" -f x
  [ "$status" -eq 126 ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "tests/run.sh fails on a file name that doesn't exist" {
  run "$GI_HOME/tests/run.sh" tests/no-such-file.bats
  [ "$status" -eq 1 ]
  [[ $output == *"no such file: tests/no-such-file.bats"* ]]
}

@test "dry-run describes edits to files it never wrote, instead of showing one-line files" {
  GI_DRY_RUN=1
  printf 'COMMON_FLAGS="-O2"\n' | write_file /etc/portage/make.conf 2> /dev/null
  run --separate-stderr make_conf_use_add dist-kernel networkmanager
  [ "$status" -eq 0 ]
  [ "$stderr" = "# add to USE in $GI_TARGET/etc/portage/make.conf: dist-kernel networkmanager" ]
  run --separate-stderr set_shell_var /etc/portage/make.conf GRUB_PLATFORMS efi-64
  [ "$stderr" = "# set GRUB_PLATFORMS=\"efi-64\" in $GI_TARGET/etc/portage/make.conf" ]
  run --separate-stderr ensure_line /efi/loader/loader.conf 'timeout 3'
  [ "$stderr" = "# add this line to $GI_TARGET/efi/loader/loader.conf unless it's there: timeout 3" ]
  grep -qxF "# set GRUB_PLATFORMS=\"efi-64\" in $GI_TARGET/etc/portage/make.conf" "$GI_RUN_DIR/replay.sh"
  [ -z "$(ls -A "$GI_TARGET")" ]
  run make_conf_use_add 'bad;flag'
  [ "$status" -ne 0 ]
  run set_shell_var /etc/x X 'a"b'
  [ "$status" -ne 0 ]
}
