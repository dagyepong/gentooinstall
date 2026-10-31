#!/usr/bin/env bats
# Tests for lib/steps/network.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core state network
  CFG[init]=openrc CFG[desktop]=none CFG[network]=networkmanager CFG[keep_wifi]=yes CFG[wifi_ssid]=''
}

# Runs a step function with errexit on, like the step runner does.
step() { (
  set -e
  "$@"
); }

# Commands run in the chroot, as the replay script records them.
chroot_cmds() {
  sed -n "s|^arch-chroot [^ ]* /bin/bash -c 'source /etc/profile \&\& \(.*\); exit \$?'\(  # (stdin: not recorded)\)\{0,1\}\$|\1|p" "$GI_RUN_DIR/replay.sh"
}

conn() { printf '%s' "$GI_TARGET/etc/NetworkManager/system-connections/$1.nmconnection"; }

@test "portage hook: NetworkManager on a console profile adds the USE flag and wpa_supplicant dbus" {
  step step_network_portage
  step step_network_portage
  [ "$(grep '^USE=' "$GI_TARGET/etc/portage/make.conf")" = 'USE="networkmanager"' ]
  [ "$(cat "$GI_TARGET/etc/portage/package.use/network")" = 'net-wireless/wpa_supplicant dbus' ]
}

@test "portage hook: desktop profiles already set both, so nothing is written" {
  CFG[desktop]=plasma
  step step_network_portage
  [ ! -e "$GI_TARGET/etc/portage/make.conf" ]
  [ ! -e "$GI_TARGET/etc/portage/package.use/network" ]
}

@test "portage hook: the plain desktop profile gets the USE flag, but already has dbus" {
  for d in xfce i3 hyprland; do
    rm -rf "$GI_TARGET/etc"
    CFG[desktop]=$d
    step step_network_portage
    [ "$(grep '^USE=' "$GI_TARGET/etc/portage/make.conf")" = 'USE="networkmanager"' ]
    [ ! -e "$GI_TARGET/etc/portage/package.use/network" ]
  done
  rm -rf "$GI_TARGET/etc"
  CFG[network]=dhcpcd
  step step_network_portage
  [ ! -e "$GI_TARGET/etc/portage/make.conf" ]
}

@test "portage hook: removes its package.use file when the answers change" {
  step step_network_portage
  CFG[network]=dhcpcd
  step step_network_portage
  [ ! -e "$GI_TARGET/etc/portage/package.use/network" ]
  CFG[network]=networkmanager CFG[desktop]=gnome
  step step_network_portage
  [ ! -e "$GI_TARGET/etc/portage/package.use/network" ]
}

@test "packages per network manager, always with iw and wpa_supplicant" {
  run step_network_packages
  [ "$output" = $'net-wireless/iw\nnet-wireless/wpa_supplicant\nnet-misc/networkmanager' ]
  CFG[network]=dhcpcd
  run step_network_packages
  [ "$output" = $'net-wireless/iw\nnet-wireless/wpa_supplicant\nnet-misc/dhcpcd' ]
  CFG[init]=systemd CFG[network]=networkd
  run step_network_packages
  [ "$output" = $'net-wireless/iw\nnet-wireless/wpa_supplicant' ]
}

# The stage3 step copied the live resolv.conf in; NetworkManager and dhcpcd rewrite it at boot.
@test "NetworkManager on OpenRC: enabled in the default runlevel, nothing else touched" {
  mkdir -p "$GI_TARGET/etc"
  echo 'nameserver 192.0.2.1' > "$GI_TARGET/etc/resolv.conf"
  run step step_network
  [ "$status" -eq 0 ]
  run chroot_cmds
  [ "$output" = 'rc-update add NetworkManager default' ]
  [ ! -d "$GI_TARGET/etc/NetworkManager" ]
  [ ! -L "$GI_TARGET/etc/resolv.conf" ]
  [ "$(cat "$GI_TARGET/etc/resolv.conf")" = 'nameserver 192.0.2.1' ]
}

@test "OpenRC: a manager enabled by an earlier run is removed from the runlevel" {
  mkdir -p "$GI_TARGET/etc/runlevels/default"
  ln -s /etc/init.d/dhcpcd "$GI_TARGET/etc/runlevels/default/dhcpcd"
  step step_network
  run chroot_cmds
  [ "$output" = $'rc-update del dhcpcd default\nrc-update add NetworkManager default' ]
}

@test "NetworkManager on systemd disables the networkd that preset-all enabled" {
  CFG[init]=systemd
  mkdir -p "$GI_TARGET/etc/systemd/system/multi-user.target.wants"
  ln -s /usr/lib/systemd/system/systemd-networkd.service \
    "$GI_TARGET/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
  step step_network
  run chroot_cmds
  [ "$output" = $'systemctl disable systemd-networkd\nsystemctl enable NetworkManager' ]
}

@test "dhcpcd: enables only dhcpcd" {
  CFG[network]=dhcpcd CFG[wifi_ssid]=Home
  SECRET[wifi_psk]=secretkey1
  step step_network
  run chroot_cmds
  [ "$output" = 'rc-update add dhcpcd default' ]
  [ ! -e "$(conn Home)" ]
  CFG[init]=systemd
  : > "$GI_RUN_DIR/replay.sh"
  step step_network
  run chroot_cmds
  [ "$output" = 'systemctl enable dhcpcd' ]
  [ ! -e "$GI_TARGET/etc/resolv.conf" ]
}

@test "systemd-networkd: DHCP on en*, resolved enabled, resolv.conf linked to the resolved stub" {
  CFG[init]=systemd CFG[network]=networkd
  mkdir -p "$GI_TARGET/etc/systemd/system/multi-user.target.wants"
  ln -s /usr/lib/systemd/system/NetworkManager.service \
    "$GI_TARGET/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
  echo 'nameserver 192.0.2.1' > "$GI_TARGET/etc/resolv.conf"
  step step_network
  step step_network
  [ "$(cat "$GI_TARGET/etc/systemd/network/50-dhcp.network")" = $'[Match]\nName=en*\n\n[Network]\nDHCP=yes' ]
  [ "$(readlink "$GI_TARGET/etc/resolv.conf")" = ../run/systemd/resolve/stub-resolv.conf ]
  run chroot_cmds
  [ "${lines[0]}" = 'systemctl disable NetworkManager' ]
  [ "${lines[1]}" = 'systemctl enable systemd-networkd' ]
  [ "${lines[2]}" = 'systemctl enable systemd-resolved' ]
}

@test "Wi-Fi: WPA-PSK keyfile with mode 600, and the key never reaches the log or replay script" {
  CFG[wifi_ssid]=HomeNet
  SECRET[wifi_psk]='correct horse battery'
  step step_network
  step step_network
  f=$(conn HomeNet)
  [ "$(stat -c %a "$f")" = 600 ]
  [ "$(cat "$f")" = $'[connection]\nid=HomeNet\ntype=wifi\n\n[wifi]\nssid=72;111;109;101;78;101;116;\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=correct horse battery' ]
  run ! grep -rqF 'correct horse' "$GI_LOG" "$GI_RUN_DIR/replay.sh" "$STUB_LOG"
}

@test "Wi-Fi: special characters in the SSID and key" {
  CFG[wifi_ssid]='Café ;#\x'
  SECRET[wifi_psk]=' lead\back'
  step step_network
  f=$(conn 'Caf______x')
  [ -f "$f" ]
  grep -qx 'id=Caf______x' "$f"
  grep -qx 'ssid=67;97;102;195;169;32;59;35;92;120;' "$f"
  grep -qxF 'psk=\slead\\back' "$f"
}

@test "Wi-Fi: an empty key saves an open network" {
  CFG[wifi_ssid]=Cafe
  SECRET[wifi_psk]=''
  step step_network
  run cat "$(conn Cafe)"
  [ "$output" = $'[connection]\nid=Cafe\ntype=wifi\n\n[wifi]\nssid=67;97;102;101;' ]
}

@test "Wi-Fi: a missing key stops the step" {
  CFG[wifi_ssid]=Cafe
  run step step_network
  [ "$status" -eq 1 ]
  [[ $output == *"No key was given for the Wi-Fi network Cafe"* ]]
  [ ! -e "$(conn Cafe)" ]
}

# The runner asks for exactly the key cfg_secrets_missing names, so the step must need no other.
@test "Wi-Fi: the step needs the key exactly when cfg_secrets_missing asks for it" {
  gi_load config
  local net keep ssid need hits=0
  CFG[init]=systemd
  for net in networkmanager dhcpcd networkd; do
    for keep in yes no; do
      for ssid in '' Cafe; do
        CFG[network]=$net CFG[keep_wifi]=$keep CFG[wifi_ssid]=$ssid
        unset 'SECRET[wifi_psk]'
        need=$(cfg_secrets_missing network)
        run step step_network
        if [[ $need == wifi_psk ]]; then
          hits=$((hits + 1))
          [ "$status" -eq 1 ]
          [[ $output == *"No key was given"* ]]
          # An open network: the key is given, and empty.
          SECRET[wifi_psk]=''
          step step_network
          [ -f "$(conn Cafe)" ]
          rm -f -- "$(conn Cafe)"
        else
          [ "$status" -eq 0 ]
          [ -z "$need" ]
          [ ! -e "$(conn Cafe)" ]
        fi
      done
    done
  done
  # Only NetworkManager, keep_wifi=yes and an SSID need it.
  [ "$hits" -eq 1 ]
}

@test "Wi-Fi: not saved with keep_wifi=no" {
  CFG[wifi_ssid]=Cafe CFG[keep_wifi]=no
  step step_network
  [ ! -e "$(conn Cafe)" ]
}

@test "dry-run prints the commands and changes nothing" {
  GI_DRY_RUN=1 CFG[init]=systemd CFG[network]=networkd
  run --separate-stderr step step_network
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$GI_TARGET/etc" ]
  [[ $stderr == *"systemctl enable systemd-networkd"* ]]
  [[ $stderr == *"ln -sfn ../run/systemd/resolve/stub-resolv.conf"* ]]
  [[ $stderr == *"50-dhcp.network"* ]]
}

@test "dry-run with Wi-Fi shows the keyfile path but not the key" {
  GI_DRY_RUN=1 CFG[wifi_ssid]=Cafe
  SECRET[wifi_psk]=sekritkey99
  run --separate-stderr step step_network
  [ "$status" -eq 0 ]
  [[ $stderr == *"system-connections/Cafe.nmconnection (mode 0600)"* ]]
  [[ $stderr != *sekritkey99* ]]
  [ ! -e "$(conn Cafe)" ]
}
