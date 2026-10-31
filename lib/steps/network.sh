# shellcheck shell=bash
# Networking step: NetworkManager with the saved Wi-Fi network, dhcpcd or systemd-networkd.

step_define network "Networking" \
  "The new system needs exactly one network manager to get online by itself after the first boot. NetworkManager also keeps the Wi-Fi network the installer used." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/System#Network"

step_network_portage() {
  local f=/etc/portage/package.use/network
  # The plasma and gnome profiles already set networkmanager, and every desktop profile sets
  # dbus, which wpa_supplicant needs for NetworkManager.
  if [[ ${CFG[network]} == networkmanager && ${CFG[desktop]} != plasma && ${CFG[desktop]} != gnome ]]; then
    make_conf_use_add networkmanager
  fi
  if [[ ${CFG[network]} == networkmanager && ${CFG[desktop]} == none ]]; then
    portage_file package.use network <<< 'net-wireless/wpa_supplicant dbus'
  elif [[ -e $GI_TARGET$f ]]; then
    # The preview step reruns the hooks after the answers change.
    run_cmd rm -f -- "$GI_TARGET$f"
  fi
}

step_network_packages() {
  printf '%s\n' net-wireless/iw net-wireless/wpa_supplicant
  case ${CFG[network]} in
    networkmanager) echo net-misc/networkmanager ;;
    dhcpcd) echo net-misc/dhcpcd ;;
  esac
}

step_network() {
  local m
  local -A svc=([networkmanager]=NetworkManager [dhcpcd]=dhcpcd [networkd]=systemd-networkd)
  # systemctl preset-all enables systemd-networkd, and the stage3 ships dhcpcd.
  for m in networkmanager dhcpcd networkd; do
    if [[ $m != "${CFG[network]}" ]]; then _network_disable "${svc[$m]}"; fi
  done
  service_enable "${svc[${CFG[network]}]}"
  case ${CFG[network]} in
    networkmanager)
      if [[ ${CFG[keep_wifi]} == yes && -n ${CFG[wifi_ssid]} ]]; then _network_wifi; fi
      ;;
    networkd)
      printf '[Match]\nName=en*\n\n[Network]\nDHCP=yes\n' | write_file /etc/systemd/network/50-dhcp.network
      # The stub keeps DHCP search domains. arch-chroot 31 binds the live resolv.conf over the link
      # itself, not its target, so later steps still resolve names although /run is empty here.
      run_cmd ln -sfn ../run/systemd/resolve/stub-resolv.conf "$GI_TARGET/etc/resolv.conf"
      service_enable systemd-resolved
      ;;
  esac
}

_network_disable() { # SERVICE
  if is_systemd; then
    [[ -L $GI_TARGET/etc/systemd/system/multi-user.target.wants/$1.service ]] || return 0
    run_chroot systemctl disable "$1"
  else
    [[ -L $GI_TARGET/etc/runlevels/default/$1 ]] || return 0
    run_chroot rc-update del "$1" default
  fi
}

# A NetworkManager keyfile. The SSID goes in as a list of byte values, which
# NetworkManager reads for any SSID, so it needs no escaping.
_network_wifi() {
  # Byte-wise, so the file name doesn't depend on the live system's locale.
  local LC_ALL=C ssid=${CFG[wifi_ssid]} name
  [[ -n ${SECRET[wifi_psk]+x} ]] || die "No key was given for the Wi-Fi network $ssid."
  name=${ssid//[^A-Za-z0-9_-]/_}
  {
    printf '[connection]\nid=%s\ntype=wifi\n\n[wifi]\nssid=%s\n' "$name" "$(_network_ssid_bytes "$ssid")"
    # An empty key means an open network.
    if [[ -n ${SECRET[wifi_psk]} ]]; then
      printf '\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n' "$(_network_keyfile_escape "${SECRET[wifi_psk]}")"
    fi
  } | write_secret_file "/etc/NetworkManager/system-connections/$name.nmconnection"
}

_network_ssid_bytes() { # SSID
  local LC_ALL=C s=$1 b out='' i
  for ((i = 0; i < ${#s}; i++)); do
    printf -v b '%d;' "'${s:i:1}"
    out+=$b
  done
  printf '%s' "$out"
}

# GLib keyfile string escaping: the reader drops leading spaces and treats backslashes as escapes.
_network_keyfile_escape() { # STRING
  local s=${1//\\/\\\\}
  if [[ $s == ' '* ]]; then s="\\s${s:1}"; fi
  printf '%s' "$s"
}
