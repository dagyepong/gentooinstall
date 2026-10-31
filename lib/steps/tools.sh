# shellcheck shell=bash
# System tools step: logger, cron, time sync, filesystem tools, TRIM, zram and sshd.

step_define tools "System tools" \
  "A system logger, cron and time sync keep the system running well. SSDs get a weekly TRIM, zram gives compressed swap in RAM, and sshd allows remote logins when chosen." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Tools"

step_tools_portage() {
  local f=/etc/portage/package.use/zram-generator
  # Building its man pages pulls in Ruby and about 70 gems; the binary package already has them.
  if [[ ${CFG[swap]} == zram && ${CFG[binpkgs]} == no ]] && is_systemd; then
    echo 'sys-apps/zram-generator -man' | portage_file package.use zram-generator
  elif [[ -e $GI_TARGET$f ]]; then
    # The preview step reruns the hooks after the answers change.
    run_cmd rm -f -- "$GI_TARGET$f"
  fi
}

step_tools_packages() {
  local -a p=(sys-fs/dosfstools sys-block/io-scheduler-udev-rules app-shells/bash-completion
    app-portage/gentoolkit sys-apps/pciutils sys-apps/usbutils "app-admin/${CFG[privilege]}")
  # systemd brings journald, timers and timesyncd instead.
  if is_openrc; then p+=(app-admin/sysklogd sys-process/cronie net-misc/chrony); fi
  case ${CFG[filesystem]} in
    ext4) p+=(sys-fs/e2fsprogs) ;;
    xfs) p+=(sys-fs/xfsprogs) ;;
    btrfs) p+=(sys-fs/btrfs-progs) ;;
  esac
  if [[ ${CFG[encryption]} == luks2 ]]; then p+=(sys-fs/cryptsetup); fi
  if [[ ${CFG[swap]} == zram ]]; then
    if is_openrc; then p+=(sys-block/zram-init); else p+=(sys-apps/zram-generator); fi
  fi
  if [[ ${CFG[sshd]} == yes ]]; then p+=(net-misc/openssh); fi
  printf '%s\n' "${p[@]}"
}

step_tools() {
  local ram_mib=${HW[ram_mib]}
  if is_openrc; then
    service_enable sysklogd
    service_enable cronie
    service_enable chronyd
  else
    service_enable systemd-timesyncd
  fi
  if [[ $(state_get disk.ssd) == yes ]]; then
    if is_openrc; then
      # cronie's anacron runs /etc/cron.weekly.
      printf '#!/bin/sh\nfstrim --all\n' | write_file /etc/cron.weekly/fstrim 0755
    else
      service_enable fstrim.timer
    fi
  fi
  if [[ ${CFG[swap]} == zram ]]; then
    if is_openrc; then
      printf 'load_on_start=yes\nunload_on_stop=yes\nnum_devices=1\ntype0=swap\nsize0=%s\nalgo0=zstd\nlabl0=zram_swap\n' \
        "$((ram_mib / 2))" | write_file /etc/conf.d/zram-init
      service_enable zram-init boot
    else
      printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n' | write_file /etc/systemd/zram-generator.conf
    fi
  elif [[ ${CFG[swap]} == file && ${CFG[filesystem]} == btrfs ]] && is_openrc; then
    # The swap file is on @swap, which localmount mounts, and OpenRC's swap service runs before localmount.
    set_shell_var /etc/conf.d/swap rc_before '!localmount'
    set_shell_var /etc/conf.d/swap rc_need localmount
  fi
  if [[ ${CFG[sshd]} == yes ]]; then
    service_enable sshd
    _tools_no_root_login
  fi
}

# sshd keeps the first value it reads for a setting.
_tools_no_root_login() {
  local f=$GI_TARGET/etc/ssh/sshd_config
  if [[ ! -f $f ]] || grep -q '^Include .*sshd_config\.d/' "$f"; then
    echo 'PermitRootLogin no' | write_file /etc/ssh/sshd_config.d/00-no-root-login.conf
  elif ! grep -qx 'PermitRootLogin no' "$f"; then
    { echo 'PermitRootLogin no'; cat -- "$f"; } | write_file /etc/ssh/sshd_config 0600
  fi
}
