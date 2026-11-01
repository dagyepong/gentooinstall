# shellcheck shell=bash
# Audio, Bluetooth and laptop step: PipeWire, BlueZ, power management, thermald and fwupd.

step_define hardware "Audio, Bluetooth and laptop" \
  "PipeWire plays sound, BlueZ runs Bluetooth, power-profiles-daemon or TLP saves battery, thermald keeps Intel CPUs cool, and fwupd updates firmware." \
  "https://wiki.gentoo.org/wiki/PipeWire"

_hardware_thermald() { [[ ${CFG[thermald]} == yes && ${HW[cpu_vendor]:-} == intel ]]; }

# On OpenRC only a desktop session starts PipeWire (its XDG autostart, or for a window manager the
# start command the finish step gives), and a console-only system has neither elogind nor a D-Bus
# session for it, so sound there goes through ALSA alone.
hardware_pipewire() { [[ ${CFG[audio]:-} == pipewire ]] && { [[ ${CFG[desktop]:-none} != none ]] || is_systemd; }; }

step_hardware_portage() {
  local f=/etc/portage/package.use/pipewire t=/etc/portage/package.use/tlp p=/etc/portage/package.use/power-profiles-daemon
  if hardware_pipewire; then
    # The desktop profiles set this already; the console profiles don't.
    echo 'media-video/pipewire sound-server' | portage_file package.use pipewire
  elif [[ -e $GI_TARGET$f ]]; then
    run_cmd rm -f -- "$GI_TARGET$f"
  fi
  if [[ ${CFG[power]} == tlp && ${CFG[network]} != networkmanager ]]; then
    # TLP's radio device wizard (default flag rdw) pulls in NetworkManager.
    echo 'sys-power/tlp -rdw' | portage_file package.use tlp
  elif [[ -e $GI_TARGET$t ]]; then
    run_cmd rm -f -- "$GI_TARGET$t"
  fi
  if [[ ${CFG[power]} == ppd ]] && is_systemd; then
    # Its polkit needs systemd[policykit], which only the desktop profiles turn on.
    echo 'sys-apps/systemd policykit' | portage_file package.use power-profiles-daemon
  elif [[ -e $GI_TARGET$p ]]; then
    run_cmd rm -f -- "$GI_TARGET$p"
  fi
}

step_hardware_packages() {
  local -a p=()
  if hardware_pipewire; then p+=(media-video/pipewire media-video/wireplumber); fi
  if [[ ${CFG[audio]} == pipewire ]]; then p+=(media-sound/alsa-utils); fi
  if [[ ${CFG[bluetooth]} == yes ]]; then p+=(net-wireless/bluez); fi
  case ${CFG[power]} in
    ppd) p+=(sys-power/power-profiles-daemon) ;;
    # TLP blocks power-profiles-daemon, and it satisfies Plasma's need for one of the two.
    tlp) p+=(sys-power/tlp) ;;
  esac
  if _hardware_thermald; then p+=(sys-power/thermald); fi
  if [[ ${CFG[fwupd]} == yes ]]; then p+=(sys-apps/fwupd); fi
  if ((${#p[@]})); then printf '%s\n' "${p[@]}"; fi
}

step_hardware() {
  # On OpenRC, pipewire's own /etc/xdg/autostart/pipewire.desktop starts it with each desktop session,
  # and the window managers' start command runs gentoo-pipewire-launcher.
  if hardware_pipewire; then
    user_service_enable_global pipewire.socket pipewire-pulse.socket wireplumber.service
  elif [[ ${CFG[audio]} == pipewire ]]; then
    warn "PipeWire was left out: on OpenRC only a desktop session starts it. Sound plays through ALSA; set the volume with alsamixer."
    # alsa-utils' elog: alsasound saves the mixer levels at shutdown and restores them at boot.
    service_enable alsasound boot
  fi
  if [[ ${CFG[bluetooth]} == yes ]]; then service_enable bluetooth; fi
  case ${CFG[power]} in
    ppd) service_enable power-profiles-daemon ;;
    # tlp-pd serves the power profiles D-Bus API that Plasma and GNOME use. Its D-Bus
    # activation only works through systemd, so OpenRC needs the service started.
    tlp)
      service_enable tlp
      service_enable tlp-pd
      ;;
  esac
  # TLP's install docs: systemd-rfkill fights TLP's radio device switching.
  if [[ ${CFG[power]} == tlp ]] && is_systemd; then
    run_chroot systemctl mask systemd-rfkill.service systemd-rfkill.socket
  elif [[ -L $GI_TARGET/etc/systemd/system/systemd-rfkill.service ]]; then
    run_chroot systemctl unmask systemd-rfkill.service systemd-rfkill.socket
  fi
  if _hardware_thermald; then service_enable thermald; fi
  # systemd starts fwupd through D-Bus when needed; its unit has nothing to enable.
  if [[ ${CFG[fwupd]} == yes ]] && is_openrc; then service_enable fwupd; fi
}
