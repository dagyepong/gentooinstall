# shellcheck shell=bash
# System tools step: logger, cron, time sync, filesystem tools, TRIM, zram, btrfs snapshots and sshd.

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
  elif cfg_swap_file && [[ ${CFG[filesystem]} == btrfs ]] && is_openrc; then
    # The swap file is on @swap, which localmount mounts, and OpenRC's swap service runs before localmount.
    set_shell_var /etc/conf.d/swap rc_before '!localmount'
    set_shell_var /etc/conf.d/swap rc_need localmount
  fi
  if [[ ${CFG[sshd]} == yes ]]; then
    service_enable sshd
    _tools_no_root_login
  fi
  if [[ ${CFG[filesystem]} == btrfs ]]; then _tools_snapshots; fi
}

# On btrfs: snapshot takes a read-only snapshot of / in /.snapshots (@snapshots), and Portage runs
# it after every emerge --sync, so there's one from before each update. rollback makes one the
# root at the next start. /home, the logs, the caches and the swap file are subvolumes of their
# own, which snapshots of / leave out, so a rollback loses none of them.
_tools_snapshots() {
  _tools_snapshot_script | write_file /usr/local/sbin/snapshot 0755
  _tools_rollback_script | write_file /usr/local/sbin/rollback 0755
  printf '#!/bin/sh\n# Written by gentooinstall: a snapshot of / after each sync, before the updates it brings.\nexec /usr/local/sbin/snapshot "before the updates of an emerge --sync"\n' |
    write_file /etc/portage/postsync.d/50-snapshot 0755
}

_tools_snapshot_script() {
  cat << 'EOF'
#!/bin/bash
# Written by gentooinstall. Takes a read-only snapshot of / in /.snapshots, named by the time, with
# a note beside it saying why, and deletes all but the newest 10. /home, the logs, the caches and
# the swap file are subvolumes of their own, which it leaves out. Usage: snapshot [NOTE]
set -euo pipefail
keep=10 dir=/.snapshots
name=$(date +%Y-%m-%d_%H%M%S)
btrfs subvolume snapshot -r / "$dir/$name" > /dev/null
printf '%s\n' "${1:-taken by hand}" > "$dir/$name.txt"
echo "Took the snapshot $name."
mapfile -t all < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort)
for ((i = 0; i < ${#all[@]} - keep; i++)); do
  btrfs subvolume delete "${all[i]}" > /dev/null
  rm -f -- "${all[i]}.txt"
done
EOF
}

_tools_rollback_script() {
  cat << 'EOF'
#!/bin/bash
# Written by gentooinstall. With no argument, lists the snapshots in /.snapshots. With one, makes
# that snapshot the root at the next start; the root it replaces stays beside it, as the subvolume
# @rollback-<time>, until you delete it. Usage: rollback [NAME]
set -euo pipefail
dir=/.snapshots
if (($# == 0)); then
  echo "Snapshots, oldest first. To start one from the next start on: rollback NAME"
  for d in "$dir"/20*/; do
    d=${d%/}
    [[ -d $d ]] || continue
    printf '  %s  %s\n' "${d##*/}" "$(cat -- "$d.txt" 2> /dev/null || true)"
  done
  exit 0
fi
if [[ ! $1 =~ ^[0-9_-]+$ || ! -d $dir/$1 ]]; then
  echo "rollback: there's no snapshot $1 in $dir. Run rollback alone to list them." >&2
  exit 1
fi
# The filesystem /.snapshots is on, without its "[/@snapshots]".
dev=$(findmnt -no SOURCE -T "$dir")
dev=${dev%%\[*}
top=$(mktemp -d)
mount -o subvolid=5 "$dev" "$top"
old=@rollback-$(date +%Y-%m-%d_%H%M%S)
# A mounted subvolume can be renamed; the running system keeps it until the restart.
mv -- "$top/@" "$top/$old"
btrfs subvolume snapshot "$top/@snapshots/$1" "$top/@" > /dev/null
umount "$top"
rmdir "$top"
echo "The next start uses the snapshot $1. The root it replaced is the subvolume $old;"
echo "once you no longer need it, delete it with:"
echo "  mount -o subvolid=5 $dev /mnt && btrfs subvolume delete /mnt/$old && umount /mnt"
EOF
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
