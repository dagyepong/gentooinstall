#!/usr/bin/env bats
# Tests for lib/steps/hardware.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui state config hardware
  HW[laptop]=yes HW[bluetooth]=yes HW[cpu_vendor]=intel
  PW=$GI_TARGET/etc/portage/package.use/pipewire
  TLP=$GI_TARGET/etc/portage/package.use/tlp
  PPD=$GI_TARGET/etc/portage/package.use/power-profiles-daemon
}

chroot_line() { printf 'arch-chroot %q /bin/bash -c %q\n' "$GI_TARGET" "source /etc/profile && $*; exit \$?"; }

@test "laptop defaults: PipeWire, BlueZ, power-profiles-daemon and fwupd" {
  cfg_defaults_apply
  run step_hardware_packages
  [ "$output" = "media-video/pipewire
media-video/wireplumber
media-sound/alsa-utils
net-wireless/bluez
sys-power/power-profiles-daemon
sys-apps/fwupd" ]
}

@test "TLP replaces power-profiles-daemon, and thermald comes on Intel when chosen" {
  CFG[power]=tlp CFG[thermald]=yes
  cfg_defaults_apply
  run step_hardware_packages
  [[ $output == *sys-power/tlp* ]]
  [[ $output == *sys-power/thermald* ]]
  [[ $output != *power-profiles-daemon* ]]
}

@test "thermald is left out on AMD even when chosen" {
  HW[cpu_vendor]=amd
  CFG[thermald]=yes
  cfg_defaults_apply
  run step_hardware_packages
  [[ $output != *thermald* ]]
}

@test "a desktop machine with nothing chosen needs no packages" {
  HW[laptop]=no HW[bluetooth]=no
  CFG[audio]=none
  cfg_defaults_apply
  run step_hardware_packages
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run step_hardware
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "the hook turns on PipeWire's sound server, and removes it when audio is off" {
  cfg_defaults_apply
  step_hardware_portage
  step_hardware_portage
  [ "$(cat "$PW")" = 'media-video/pipewire sound-server' ]
  CFG[audio]=none
  step_hardware_portage
  [ ! -e "$PW" ]
}

@test "OpenRC enables bluetooth, power-profiles-daemon and fwupd, and no user units" {
  cfg_defaults_apply
  step_hardware
  diff -u <(chroot_line rc-update add bluetooth default
    chroot_line rc-update add power-profiles-daemon default
    chroot_line rc-update add fwupd default) "$STUB_LOG"
}

@test "systemd enables PipeWire's user units for everyone and leaves fwupd to D-Bus" {
  CFG[init]=systemd
  cfg_defaults_apply
  step_hardware
  diff -u <(chroot_line systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
    chroot_line systemctl enable bluetooth
    chroot_line systemctl enable power-profiles-daemon) "$STUB_LOG"
}

@test "TLP and thermald services on OpenRC" {
  HW[bluetooth]=no
  CFG[power]=tlp CFG[thermald]=yes CFG[fwupd]=no
  cfg_defaults_apply
  step_hardware
  diff -u <(chroot_line rc-update add tlp default
    chroot_line rc-update add tlp-pd default
    chroot_line rc-update add thermald default) "$STUB_LOG"
}

@test "TLP on systemd masks systemd-rfkill, as TLP's docs say, and a later rerun without TLP unmasks it" {
  HW[bluetooth]=no
  CFG[init]=systemd CFG[power]=tlp CFG[fwupd]=no
  cfg_defaults_apply
  step_hardware
  diff -u <(chroot_line systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
    chroot_line systemctl enable tlp
    chroot_line systemctl enable tlp-pd
    chroot_line systemctl mask systemd-rfkill.service systemd-rfkill.socket) "$STUB_LOG"
  : > "$STUB_LOG"
  CFG[power]=ppd
  step_hardware
  run ! grep -q rfkill "$STUB_LOG"
  mkdir -p "$GI_TARGET/etc/systemd/system"
  ln -s /dev/null "$GI_TARGET/etc/systemd/system/systemd-rfkill.service"
  step_hardware
  [ "$(tail -n 1 "$STUB_LOG")" = "$(chroot_line systemctl unmask systemd-rfkill.service systemd-rfkill.socket)" ]
}

@test "TLP leaves out NetworkManager unless it's the network manager, and the file goes when not needed" {
  CFG[power]=tlp CFG[network]=dhcpcd
  cfg_defaults_apply
  step_hardware_portage
  step_hardware_portage
  [ "$(cat "$TLP")" = 'sys-power/tlp -rdw' ]
  CFG[network]=networkmanager
  step_hardware_portage
  [ ! -e "$TLP" ]
  CFG[network]=networkd CFG[power]=ppd
  step_hardware_portage
  [ ! -e "$TLP" ]
}

@test "running the step twice issues the same idempotent commands" {
  cfg_defaults_apply
  step_hardware
  step_hardware
  [ "$(sort -u "$STUB_LOG" | wc -l)" -eq 3 ]
  [ "$(wc -l < "$STUB_LOG")" -eq 6 ]
}

@test "dry-run prints the commands and runs nothing" {
  CFG[init]=systemd
  cfg_defaults_apply
  GI_DRY_RUN=1
  run --separate-stderr step_hardware
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [[ $stderr == *"systemctl --global enable pipewire.socket"* ]]
  run --separate-stderr step_hardware_portage
  [ ! -e "$PW" ]
}

@test "power-profiles-daemon on systemd turns on systemd's policykit, and the file goes when not needed" {
  CFG[init]=systemd
  cfg_defaults_apply
  step_hardware_portage
  step_hardware_portage
  [ "$(cat "$PPD")" = 'sys-apps/systemd policykit' ]
  CFG[power]=tlp
  step_hardware_portage
  [ ! -e "$PPD" ]
  CFG[power]=ppd CFG[init]=openrc
  step_hardware_portage
  [ ! -e "$PPD" ]
}

@test "console-only OpenRC leaves PipeWire out and says so; systemd and desktops keep it" {
  CFG[desktop]=none
  cfg_defaults_apply
  run step_hardware_packages
  [[ $output == *media-sound/alsa-utils* ]]
  [[ $output != *pipewire* ]]
  [[ $output != *wireplumber* ]]
  mkdir -p "${PW%/*}"
  echo 'media-video/pipewire sound-server' > "$PW"
  step_hardware_portage
  [ ! -e "$PW" ]
  run --separate-stderr step_hardware
  [[ $stderr == *"PipeWire was left out"*alsamixer* ]]
  # alsasound keeps the alsamixer levels across reboots.
  grep -qxF "$(chroot_line rc-update add alsasound boot)" "$STUB_LOG"
  : > "$STUB_LOG"
  CFG[init]=systemd
  run step_hardware_packages
  [[ $output == *media-video/pipewire*media-video/wireplumber*media-sound/alsa-utils* ]]
  step_hardware_portage
  [ "$(cat "$PW")" = 'media-video/pipewire sound-server' ]
  CFG[init]=openrc CFG[desktop]=plasma
  run step_hardware_packages
  [[ $output == *media-video/wireplumber* ]]
  CFG[audio]=none CFG[desktop]=none
  run --separate-stderr step_hardware
  [[ $stderr != *PipeWire* ]]
  run ! grep -q alsasound "$STUB_LOG"
}
