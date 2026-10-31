#!/usr/bin/env bats
# Tests for lib/steps/portage.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui config state stage3 portage
  HW=([cpu_threads]=8 [ram_mib]=15872 [x86_64_v3]=yes [cpu_flags]='aes avx avx2 mmx mmxext sse sse2')
  cfg_defaults_apply
  # The stage3 step measured these for mirror=fastest.
  CFG[mirror]=fastest
  state_set mirror.fastest 'https://mirror.example.org/gentoo/ https://distfiles.gentoo.org'
  # Real `eselect profile list` lines from the stage3, so the profile check passes.
  printf '%s\n' '  [1]   default/linux/amd64/23.0 (stable) *' '  [2]   default/linux/amd64/23.0/systemd (stable)' \
    '  [3]   default/linux/amd64/23.0/desktop (stable)' '  [4]   default/linux/amd64/23.0/desktop/systemd (stable)' \
    '  [7]   default/linux/amd64/23.0/desktop/plasma (stable)' '  [8]   default/linux/amd64/23.0/desktop/plasma/systemd (stable)' \
    '  [5]   default/linux/amd64/23.0/desktop/gnome (stable)' '  [6]   default/linux/amd64/23.0/desktop/gnome/systemd (stable)' \
    > "$STUB_OUT_DIR/arch-chroot"
  MC=$GI_TARGET/etc/portage/make.conf
  BR=$GI_TARGET/etc/portage/binrepos.conf/gentoo.conf
}

# Commands run through run_chroot, as the replay script records them.
chroot_cmds() { sed -n "s|^arch-chroot $GI_TARGET /bin/bash -c 'source /etc/profile && \(.*\); exit \$?'\$|\1|p" "$GI_RUN_DIR/replay.sh"; }

@test "make.conf with the defaults: binary packages, -march=native, auto jobs" {
  portage_configure
  grep -qx 'COMMON_FLAGS="-march=native -O2 -pipe"' "$MC"
  grep -qx 'CFLAGS="${COMMON_FLAGS}"' "$MC"
  grep -qx 'FFLAGS="${COMMON_FLAGS}"' "$MC"
  grep -qx 'RUSTFLAGS="${RUSTFLAGS} -C target-cpu=native"' "$MC"
  grep -qx 'MAKEOPTS="-j8 -l8"' "$MC"
  # 16 GiB holds 8 compiler jobs at 2 GiB each, so the load limit stays at 8.
  grep -qx 'EMERGE_DEFAULT_OPTS="--jobs=8 --load-average=8"' "$MC"
  grep -qx 'FEATURES="${FEATURES} getbinpkg binpkg-request-signature"' "$MC"
  grep -qx 'ACCEPT_LICENSE="-\* @FREE @BINARY-REDISTRIBUTABLE"' "$MC"
  grep -qx 'GENTOO_MIRRORS="https://mirror.example.org/gentoo/ https://distfiles.gentoo.org"' "$MC"
  grep -qx 'LC_MESSAGES=C.UTF-8' "$MC"
  run ! grep -q '^L10N=' "$MC"
  run ! grep -q '^USE=' "$MC"
}

@test "every make.conf setting has a comment above it" {
  CFG[binpkgs]=no
  portage_configure
  run awk '/^[A-Z_0-9]+=/ && prev !~ /^#/ && $0 !~ /^(CFLAGS|CXXFLAGS|FCFLAGS|FFLAGS)=/ { print } { prev = $0 }' "$MC"
  [ -z "$output" ]
}

@test "make.conf without binary packages: L10N, custom MAKEOPTS and jobs, no RUSTFLAGS" {
  CFG[binpkgs]=no CFG[makeopts]='-j4 -l5' CFG[emerge_jobs]=3 CFG[cflags]='-O2 -pipe'
  CFG[locales]='en_US.UTF-8 de_DE.UTF-8 en_GB.UTF-8 sr_RS@latin'
  portage_configure
  grep -qx 'MAKEOPTS="-j4 -l5"' "$MC"
  grep -qx 'EMERGE_DEFAULT_OPTS="--jobs=3 --load-average=8"' "$MC"
  grep -qx 'L10N="en en-US de de-DE en-GB sr sr-RS"' "$MC"
  run ! grep -q '^FEATURES=' "$MC"
  run ! grep -q '^RUSTFLAGS=' "$MC"
}

@test "without binary packages emerge jobs times MAKEOPTS jobs fit in RAM at 2 GiB each" {
  check() {
    HW[cpu_threads]=$1 HW[ram_mib]=$2
    [ "$(_portage_emerge_jobs "$(_portage_jobs)")" = "$3" ] || { echo "threads=$1 ram=$2: got $(_portage_emerge_jobs "$(_portage_jobs)"), want $3"; return 1; }
  }
  CFG[binpkgs]=no
  check 8 15872 1
  check 8 32768 2
  check 16 65536 2
  check 4 65536 8
  check 2 3900 1
  check unknown unknown 1
  # A 16 GiB laptop with 8 threads: one package at a time, each with 8 compiler jobs.
  HW[cpu_threads]=8 HW[ram_mib]=15872
  portage_configure
  grep -qx 'MAKEOPTS="-j8 -l8"' "$MC"
  grep -qx 'EMERGE_DEFAULT_OPTS="--jobs=1 --load-average=8"' "$MC"
  CFG[binpkgs]=yes
  check 8 15872 8
  check 2 3900 2
}

@test "with binary packages the load limit rises to the compiler jobs RAM holds, at most twice MAKEOPTS" {
  check() {
    HW[cpu_threads]=$1 HW[ram_mib]=$2
    [ "$(_portage_load "$(_portage_jobs)")" = "$3" ] || { echo "threads=$1 ram=$2: got $(_portage_load "$(_portage_jobs)"), want $3"; return 1; }
  }
  # Low RAM: a second compile beside a -j4 one has no room, so the limit stays at N.
  check 4 7680 4
  check 8 15872 8
  check 32 32768 16
  # RAM to spare: binaries go on beside a compile.
  check 4 16384 8
  check 8 32768 16
  check 8 131072 16
  check unknown unknown 1
  CFG[binpkgs]=no
  check 8 32768 8
  check 4 16384 4
}

@test "MAKEOPTS job count is min(threads, RAM GiB / 2), at least 1" {
  check() {
    HW[cpu_threads]=$1 HW[ram_mib]=$2
    [ "$(_portage_jobs)" = "$3" ] || { echo "threads=$1 ram=$2: got $(_portage_jobs), want $3"; return 1; }
  }
  check 8 16384 8
  check 8 15872 8 # MemTotal of a 16 GiB machine
  check 16 16000 8
  check 4 32768 4
  check 2 3900 2
  check 8 1536 1
  check 8 500 1
  check unknown unknown 1
}

@test "binrepos.conf replaces the stage3's file, uses the first mirror and adds x86-64-v3" {
  mkdir -p "${BR%/*}"
  printf '[gentoo]\npriority = 1\nsync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64\n' > "$BR"
  portage_configure
  [ "$(ls "${BR%/*}")" = gentoo.conf ]
  [ "$(cat "$BR")" = '[gentoo]
priority = 9959
sync-uri = https://mirror.example.org/gentoo/releases/amd64/binpackages/23.0/x86-64/
verify-signature = true
location = /var/cache/binhost/gentoo

[gentoo-x86-64-v3]
priority = 9999
sync-uri = https://mirror.example.org/gentoo/releases/amd64/binpackages/23.0/x86-64-v3/
verify-signature = true
location = /var/cache/binhost/gentoo-x86-64-v3' ]
}

@test "GENTOO_MIRRORS and the binary host follow the mirror answer; only fastest uses the measured list" {
  # The answer changed after the stage3 step, in the compile preview's settings.
  CFG[mirror]=cdn
  portage_configure
  grep -qx 'GENTOO_MIRRORS="https://distfiles.gentoo.org"' "$MC"
  grep -qx 'sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/' "$BR"
  CFG[mirror]=https://mirror.example.net/gentoo
  portage_configure
  grep -qx 'GENTOO_MIRRORS="https://mirror.example.net/gentoo"' "$MC"
  grep -qx 'sync-uri = https://mirror.example.net/gentoo/releases/amd64/binpackages/23.0/x86-64/' "$BR"
  CFG[mirror]=fastest
  portage_configure
  grep -qx 'GENTOO_MIRRORS="https://mirror.example.org/gentoo/ https://distfiles.gentoo.org"' "$MC"
}

@test "binrepos.conf without x86-64-v3 has only the gentoo repo" {
  HW[x86_64_v3]=no
  CFG[mirror]=cdn
  portage_configure
  [ "$(grep -c '^\[' "$BR")" -eq 1 ]
  grep -qx 'sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/' "$BR"
}

@test "without binary packages there is no binrepos.conf write and no getuto" {
  CFG[binpkgs]=no
  portage_configure
  [ ! -e "$BR" ]
  run ! grep -qx getuto <(chroot_cmds)
}

@test "CPU_FLAGS_X86 stays at the profile default with binary packages" {
  mkdir -p "$GI_TARGET/etc/portage/package.use"
  echo stale > "$GI_TARGET/etc/portage/package.use/00cpu-flags"
  portage_configure
  [ ! -e "$GI_TARGET/etc/portage/package.use/00cpu-flags" ]
}

@test "CPU_FLAGS_X86 comes from cpuid2cpuflags with tune=yes or without binary packages" {
  CFG[tune]=yes
  portage_configure
  [ "$(cat "$GI_TARGET/etc/portage/package.use/00cpu-flags")" = '*/* CPU_FLAGS_X86: aes avx avx2 mmx mmxext sse sse2' ]
  rm "$GI_TARGET/etc/portage/package.use/00cpu-flags"
  CFG[tune]=no CFG[binpkgs]=no
  portage_configure
  [ -s "$GI_TARGET/etc/portage/package.use/00cpu-flags" ]
}

@test "the profile name follows the desktop and init answers" {
  check() {
    CFG[desktop]=$1 CFG[init]=$2
    [ "$(_portage_profile)" = "$3" ] || { echo "$1 $2: got $(_portage_profile)"; return 1; }
  }
  check none openrc default/linux/amd64/23.0
  check none systemd default/linux/amd64/23.0/systemd
  check plasma openrc default/linux/amd64/23.0/desktop/plasma
  check plasma systemd default/linux/amd64/23.0/desktop/plasma/systemd
  check gnome openrc default/linux/amd64/23.0/desktop/gnome
  check gnome systemd default/linux/amd64/23.0/desktop/gnome/systemd
  local d
  for d in xfce budgie cinnamon i3 sway hyprland niri mangowm dwm dwl; do
    check "$d" openrc default/linux/amd64/23.0/desktop
    check "$d" systemd default/linux/amd64/23.0/desktop/systemd
  done
}

# git as run_cmd calls it: the stub records the call, and the clone's directory appears.
git_clones() {
  git() {
    command git "$@"
    mkdir -p "${*: -1}/profiles"
  }
}

@test "an overlay desktop gets its overlay in repos.conf, copied once with the live system's git" {
  git_clones
  CFG[desktop]=niri
  portage_configure
  [ "$(cat "$GI_TARGET/etc/portage/repos.conf/guru.conf")" = $'[guru]\nlocation = /var/db/repos/guru\nsync-type = git\nsync-uri = https://github.com/gentoo-mirror/guru.git' ]
  [ "$(grep '^git' "$STUB_LOG")" = "git clone --depth 1 --quiet -- https://github.com/gentoo-mirror/guru.git $GI_TARGET/var/db/repos/guru.new" ]
  [ -d "$GI_TARGET/var/db/repos/guru/profiles" ]
  [ ! -e "$GI_TARGET/var/db/repos/guru.new" ]
  [ "$(step_portage_packages)" = dev-vcs/git ]
  # A rerun, as after a settings change in the compile preview, doesn't copy it again.
  : > "$STUB_LOG"
  CFG[desktop]=mangowm
  portage_configure
  run ! grep -q '^git' "$STUB_LOG"
  [ -d "$GI_TARGET/var/db/repos/guru/profiles" ]
  CFG[desktop]=hyprland
  portage_configure
  grep -qx "git clone --depth 1 --quiet -- https://codeberg.org/hyproverlay/hyproverlay.git $GI_TARGET/var/db/repos/hyproverlay.new" "$STUB_LOG"
  [ ! -e "$GI_TARGET/etc/portage/repos.conf/guru.conf" ]
  [ ! -e "$GI_TARGET/var/db/repos/guru" ]
  CFG[desktop]=budgie
  portage_configure
  grep -q '^sync-uri = https://gitlab.com/SarahMia/sarahmiaoverlay.git$' "$GI_TARGET/etc/portage/repos.conf/SarahMiaOverlay.conf"
  [ ! -e "$GI_TARGET/var/db/repos/hyproverlay" ]
  CFG[desktop]=sway
  portage_configure
  [ -z "$(ls -A "$GI_TARGET/etc/portage/repos.conf")" ]
  [ -z "$(ls -A "$GI_TARGET/var/db/repos")" ]
  [ -z "$(step_portage_packages)" ]
}

@test "media keys add GURU for brightnessctl beside the desktop's own overlay, and take it away when turned off" {
  git_clones
  CFG[desktop]=sway CFG[media_keys]=yes
  portage_configure
  [ "$(ls "$GI_TARGET/etc/portage/repos.conf")" = guru.conf ]
  [ -d "$GI_TARGET/var/db/repos/guru/profiles" ]
  [ "$(step_portage_packages)" = dev-vcs/git ]
  CFG[desktop]=hyprland
  portage_configure
  [ "$(ls "$GI_TARGET/etc/portage/repos.conf" | tr '\n' ' ')" = 'guru.conf hyproverlay.conf ' ]
  [ -d "$GI_TARGET/var/db/repos/hyproverlay/profiles" ]
  [ -d "$GI_TARGET/var/db/repos/guru/profiles" ]
  # Niri comes from GURU already: one copy.
  : > "$STUB_LOG"
  CFG[desktop]=niri
  portage_configure
  [ "$(ls "$GI_TARGET/etc/portage/repos.conf")" = guru.conf ]
  run ! grep -q '^git' "$STUB_LOG"
  CFG[desktop]=hyprland CFG[media_keys]=no
  portage_configure
  [ "$(ls "$GI_TARGET/etc/portage/repos.conf")" = hyproverlay.conf ]
  [ ! -e "$GI_TARGET/var/db/repos/guru" ]
  # The window managers whose default config calls no brightnessctl get no overlay for it.
  CFG[desktop]=i3 CFG[media_keys]=yes
  portage_configure
  [ -z "$(ls -A "$GI_TARGET/etc/portage/repos.conf")" ]
  [ -z "$(step_portage_packages)" ]
}

@test "a clone that failed halfway is thrown away and copied again" {
  CFG[desktop]=hyprland
  mkdir -p "$GI_TARGET/var/db/repos/hyproverlay.new/half"
  export STUB_RC_git=128
  run _portage_repos
  [ "$status" -eq 128 ]
  [ ! -e "$GI_TARGET/var/db/repos/hyproverlay" ]
  git_clones
  unset STUB_RC_git
  portage_configure
  [ -d "$GI_TARGET/var/db/repos/hyproverlay/profiles" ]
  [ ! -e "$GI_TARGET/var/db/repos/hyproverlay/half" ]
  # A half copy left by a failed clone goes too when another desktop no longer needs the overlay.
  mkdir -p "$GI_TARGET/var/db/repos/guru.new/half"
  CFG[desktop]=sway
  portage_configure
  [ -z "$(ls -A "$GI_TARGET/var/db/repos")" ]
}

@test "git fails instead of asking for a login on the terminal when an overlay has moved" {
  CFG[desktop]=budgie
  unset GIT_TERMINAL_PROMPT
  git() {
    env > "$BATS_TEST_TMPDIR/git-env"
    mkdir -p "${*: -1}/profiles"
  }
  _portage_repos
  grep -qx GIT_TERMINAL_PROMPT=0 "$BATS_TEST_TMPDIR/git-env"
}

@test "dry-run prints the overlay's repos.conf and clone and copies nothing" {
  CFG[desktop]=niri GI_DRY_RUN=1
  run --separate-stderr portage_configure
  [ "$status" -eq 0 ]
  [[ $stderr == *"git clone --depth 1 --quiet -- https://github.com/gentoo-mirror/guru.git"* ]]
  [[ $stderr == *"sync-uri = https://github.com/gentoo-mirror/guru.git"* ]]
  run ! grep -q '^git' "$STUB_LOG"
  [ ! -e "$GI_TARGET/var/db/repos" ]
}

@test "the profile is checked against eselect profile list, then set by name" {
  CFG[desktop]=gnome CFG[init]=systemd
  portage_configure
  grep -qx "arch-chroot $GI_TARGET eselect profile list" "$STUB_LOG"
  grep -qx 'eselect profile set default/linux/amd64/23.0/desktop/gnome/systemd' <(chroot_cmds)
}

@test "a profile missing from eselect profile list stops the step" {
  echo '  [1]   default/linux/amd64/17.1 (stable) *' > "$STUB_OUT_DIR/arch-chroot"
  run portage_configure
  [ "$status" -ne 0 ]
  [[ $output == *"default/linux/amd64/23.0/desktop/plasma isn't in eselect profile list"* ]]
  run ! grep -q 'profile set' <(chroot_cmds)
}

@test "hooks run in step order on a fresh make.conf, and a rerun gives the same files" {
  CALLS=$BATS_TEST_TMPDIR/calls
  step_graphics_portage() { echo graphics >> "$CALLS"; make_conf_use_add wayland; }
  step_kernel_portage() { echo kernel >> "$CALLS"; grep -q '^MAKEOPTS=' "$MC"; make_conf_use_add dist-kernel; }
  step_bootloader_portage() { echo bootloader >> "$CALLS"; }
  portage_configure
  [ "$(cat "$CALLS")" = $'kernel\nbootloader\ngraphics' ]
  grep -qx 'USE="dist-kernel wayland"' "$MC"
  cp "$MC" "$BATS_TEST_TMPDIR/first" && cp "$BR" "$BATS_TEST_TMPDIR/first-br"
  portage_configure
  cmp "$MC" "$BATS_TEST_TMPDIR/first"
  cmp "$BR" "$BATS_TEST_TMPDIR/first-br"
}

@test "portage_refresh redoes nothing for the same answers, and reruns after a change or a half-finished run" {
  portage_configure
  cp "$GI_RUN_DIR/replay.sh" "$BATS_TEST_TMPDIR/before"
  portage_refresh
  cmp "$GI_RUN_DIR/replay.sh" "$BATS_TEST_TMPDIR/before"
  CFG[desktop]=gnome
  portage_refresh
  grep -qx 'eselect profile set default/linux/amd64/23.0/desktop/gnome' <(chroot_cmds)
  # The same answers again, but a hook fails halfway, after make.conf was rewritten.
  step_kernel_portage() { return 1; }
  run -1 eval '(set -e; portage_configure)'
  unset -f step_kernel_portage
  : > "$GI_RUN_DIR/replay.sh"
  portage_refresh
  grep -qx 'eselect profile set default/linux/amd64/23.0/desktop/gnome' <(chroot_cmds)
}

@test "step_portage syncs, lists news, sets the profile, then runs getuto, in that order" {
  step_portage
  [ "$(chroot_cmds)" = 'env GENTOO_MIRRORS=https://mirror.example.org/gentoo/\ https://distfiles.gentoo.org emerge-webrsync
eselect news list
eselect profile set default/linux/amd64/23.0/desktop/plasma
getuto' ]
  [ "$(state_get portage.synced)" = yes ]
}

@test "eselect news list exits 1 when it listed any news, which a fresh tree always has; the step goes on" {
  arch-chroot() {
    command arch-chroot "$@"
    if [[ $* == *'eselect news list'* ]]; then return 1; fi
  }
  run eval '(set -e; step_portage)'
  [ "$status" -eq 0 ]
  grep -q getuto <(chroot_cmds)
}

@test "nothing marks the Gentoo news as read, so the finish step can list it" {
  step_portage
  CFG[binpkgs]=no
  portage_configure
  run ! grep -q 'news read' "$GI_RUN_DIR/replay.sh"
}

@test "step_portage skips emerge-webrsync after a finished sync" {
  TS=$GI_TARGET/var/db/repos/gentoo/metadata/timestamp.x
  mkdir -p "${TS%/*}"
  touch "$TS"
  state_set portage.synced yes
  step_portage
  run ! grep -q webrsync <(chroot_cmds)
  [ -e "$TS" ]
}

@test "a timestamp.x left by an interrupted sync is removed and the sync runs again" {
  TS=$GI_TARGET/var/db/repos/gentoo/metadata/timestamp.x
  mkdir -p "${TS%/*}"
  touch "$TS"
  step_portage
  [ ! -e "$TS" ]
  grep -qxF "rm -f -- $TS" "$GI_RUN_DIR/replay.sh"
  [ "$(chroot_cmds | head -n 1)" = 'env GENTOO_MIRRORS=https://mirror.example.org/gentoo/\ https://distfiles.gentoo.org emerge-webrsync' ]
  [ "$(state_get portage.synced)" = yes ]
}

@test "a failed sync records nothing, so the retry syncs again" {
  export STUB_RC_arch_chroot=1
  run -1 eval '(set -e; step_portage)'
  [ -z "$(state_get portage.synced)" ]
  [ "$(grep -c webrsync "$STUB_LOG")" -eq 1 ]
  unset STUB_RC_arch_chroot
  step_portage
  [ "$(grep -c webrsync "$STUB_LOG")" -eq 2 ]
}

@test "step_portage refuses a stage3 whose init doesn't match" {
  state_set stage3.file stage3-amd64-desktop-systemd-20261025T170000Z.tar.xz
  run step_portage
  [ "$status" -ne 0 ]
  [[ $output == *"systemd one, but the init system is openrc"* ]]
  [ ! -s "$STUB_LOG" ]
  state_set stage3.file stage3-amd64-desktop-openrc-20261025T170000Z.tar.xz
  step_portage
}

@test "dry-run prints commands and files and changes nothing" {
  GI_DRY_RUN=1
  run --separate-stderr step_portage
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$GI_TARGET/etc" ]
  [[ $stderr == *"emerge-webrsync"* ]]
  [[ $stderr == *"eselect profile set default/linux/amd64/23.0/desktop/plasma"* ]]
  [[ $stderr == *'MAKEOPTS="-j8 -l8"'* ]]
  [[ $stderr == *"write $GI_TARGET/etc/portage/binrepos.conf/gentoo.conf"* ]]
}

@test "another desktop chosen in the compile preview takes the overlay's keywords, repos.conf entry and copy away" {
  gi_load locale desktop
  git_clones
  CFG[desktop]=hyprland
  portage_configure
  grep -qx '\*/\*::hyproverlay ~amd64' "$GI_TARGET/etc/portage/package.accept_keywords/desktop"
  [ -e "$GI_TARGET/etc/portage/repos.conf/hyproverlay.conf" ]
  # The preview reruns portage_configure through portage_refresh after a settings change.
  CFG[desktop]=sway
  portage_refresh
  [ ! -e "$GI_TARGET/etc/portage/package.accept_keywords/desktop" ]
  [ ! -e "$GI_TARGET/etc/portage/repos.conf/hyproverlay.conf" ]
  [ ! -e "$GI_TARGET/var/db/repos/hyproverlay" ]
}
