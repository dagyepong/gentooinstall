#!/bin/bash
# Runs as root on the live ISO, from the transfer disk mounted at /mnt/xfer: installs Gentoo with
# gentooinstall, saves its log, replay script and run dir to /mnt/xfer/out, and points the installed
# bootloader at the serial console. Lines starting with "GI-VM:" are markers drive.py waits for.
# Usage: guest.sh [resume]   (resume continues an install the harness cut off, with --resume)
set -u
x=/mnt/xfer out=/mnt/xfer/out
resume=()
if [[ ${1:-} == resume ]]; then resume=(--resume); fi
marker() { printf 'GI-VM: %s\n' "$*"; }
cfg() { sed -n "s/^$1=//p" "$x/config"; }

mkdir -p "$out"
n=$(find /sys/firmware/efi/efivars -mindepth 1 -maxdepth 1 2> /dev/null | wc -l)
if ((n == 0)); then
  marker "FAIL no efivars in /sys/firmware/efi/efivars"
  exit 3
fi
marker "efivars ok ($n variables)"

rm -rf /root/gi && mkdir /root/gi && tar -xf "$x/repo.tar" -C /root/gi
# gentooinstall wants the secrets file owned by root with mode 600; the transfer disk has the host's uid.
install -m 600 "$x/config" /root/gi.conf
install -m 600 "$x/secrets" /root/gi.secrets

marker "install start"
start=$(date +%s)
# stdin is /dev/null so a prompt --yes didn't expect (like the error menu) stops the run instead of hanging.
/root/gi/gentooinstall "${resume[@]}" --yes --no-tui --config /root/gi.conf --secrets /root/gi.secrets \
  --log "$out/install.log" < /dev/null
rc=$?
marker "install exit $rc after $(($(date +%s) - start))s"
rm -rf "$out/rundir"
cp -a /tmp/gentooinstall "$out/rundir"
cp /tmp/gentooinstall/replay.sh "$out/replay.sh"
if ((rc != 0)); then exit "$rc"; fi

# Instrumentation, reported as such: the installed kernel gets console=ttyS0 so the harness sees the
# boot and can answer a LUKS prompt. Nothing else on the installed system changes.
add='console=tty0 console=ttyS0,115200'
mkdir -p /mnt/esp
case $(cfg bootloader) in
  grub)
    opt=''
    if [[ $(cfg filesystem) == btrfs ]]; then opt=subvol=@; fi
    mount ${opt:+-o "$opt"} /dev/disk/by-partlabel/gentooinstall-root /mnt/esp || exit 4
    f=/mnt/esp/boot/grub/grub.cfg
    sed -i "/^[[:space:]]*linux[[:space:]]/s|\$| $add|" "$f" || exit 4
    marker "instrumented $f: $(grep -c "$add" "$f") linux lines"
    ;;
  limine)
    mount /dev/disk/by-partlabel/gentooinstall-esp /mnt/esp || exit 4
    f=/mnt/esp/limine.conf
    sed -i "/^[[:space:]]*cmdline:/s|\$| $add|" "$f" || exit 4
    marker "instrumented $f: $(grep "cmdline:" "$f")"
    ;;
  *)
    mount /dev/disk/by-partlabel/gentooinstall-esp /mnt/esp || exit 4
    for f in /mnt/esp/loader/entries/*.conf; do
      sed -i "/^options[[:space:]]/s|\$| $add|" "$f" || exit 4
      marker "instrumented ${f#/mnt/esp}: $(grep '^options' "$f")"
    done
    ;;
esac
umount /mnt/esp || exit 4
sync
marker "guest done"
