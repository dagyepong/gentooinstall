#!/usr/bin/env bats
# Tests for lib/hw.sh: hardware facts read from a fake /sys, /proc, /dev, /run and /etc tree.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core hw
  H=$BATS_TEST_TMPDIR/host
  GI_HOST_ROOT=$H
  mkdir -p "$H"
}

put() { # PATH CONTENT
  mkdir -p "$H/$(dirname "$1")"
  printf '%s\n' "$2" > "$H/$1"
}

link() { # PATH TARGET
  mkdir -p "$H/$(dirname "$1")"
  ln -s "$2" "$H/$1"
}

pci() { # SLOT CLASS VENDOR [DRIVER]
  put "sys/bus/pci/devices/$1/class" "$2"
  put "sys/bus/pci/devices/$1/vendor" "$3"
  if [[ -n ${4:-} ]]; then ln -s "../../../bus/pci/drivers/$4" "$H/sys/bus/pci/devices/$1/driver"; fi
}

secure_boot() { # BYTE
  mkdir -p "$H/sys/firmware/efi/efivars"
  printf "\\x06\\x00\\x00\\x00\\x$1" > "$H/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
}

# A hybrid-GPU Intel laptop on battery, booted from the minimal ISO on a USB stick, on Wi-Fi.
fake_laptop() {
  put sys/firmware/efi/fw_platform_size 64
  secure_boot 00
  put etc/motd $'\nWelcome to the Gentoo Linux Minimal Installation CD!\n'
  put proc/meminfo $'MemTotal:       16303428 kB\nMemFree:          812000 kB'
  local i cpu=''
  for i in 0 1 2 3 4 5 6 7; do
    cpu+="processor	: $i"$'\n'"vendor_id	: GenuineIntel"$'\n'"flags		: fpu sse2 avx2 aes"$'\n\n'
  done
  put proc/cpuinfo "$cpu"
  put lib64/ld-linux-x86-64.so.2 $'#!/bin/sh\nprintf \'Subdirectories of glibc-hwcaps directories, in priority order:\\n  x86-64-v4\\n  x86-64-v3 (supported, searched)\\n  x86-64-v2 (supported, searched)\\n\''
  chmod +x "$H/lib64/ld-linux-x86-64.so.2"
  printf '*/* CPU_FLAGS_X86: aes avx avx2 sse4_2\n' > "$STUB_OUT_DIR/cpuid2cpuflags"

  pci 0000:00:02.0 0x030000 0x8086 i915
  pci 0000:01:00.0 0x030200 0x10de
  pci 0000:00:1f.3 0x040100 0x8086 sof-audio-pci-intel-tgl
  pci 0000:00:14.0 0x0c0330 0x8086 xhci_hcd
  cat > "$STUB_OUT_DIR/lspci" << 'EOF'
0000:00:02.0 "VGA compatible controller" "Intel Corporation" "TigerLake-LP GT2 [Iris Xe Graphics]" -r01 -p00 "Lenovo" "Device 380c"
0000:00:1f.3 "Multimedia audio controller" "Intel Corporation" "Tiger Lake-LP Smart Sound Technology Audio Controller" -r20 -p00 "Lenovo" "Device 380c"
0000:01:00.0 "3D controller" "NVIDIA Corporation" "GA107M [GeForce RTX 3050 Mobile]" -ra1 -p00 "Lenovo" "Device 380c"
EOF
  mkdir -p "$H/sys/class/net/wlan0/wireless" "$H/sys/class/net/enp0s31f6" "$H/sys/class/bluetooth/hci0"
  put sys/class/dmi/id/chassis_type 10
  put sys/class/power_supply/BAT0/type Battery
  put sys/class/power_supply/BAT0/scope System
  put sys/class/power_supply/AC/type Mains
  put sys/class/power_supply/AC/online 0

  link run/initramfs/livedev ../../dev/disk/by-label/Gentoo-amd64-20261026
  link dev/disk/by-label/Gentoo-amd64-20261026 ../../sdb1
  put dev/sdb1 ''
  put sys/devices/pci0000:00/usb1/block/sdb/sdb1/partition 1
  link sys/class/block/sdb1 ../../devices/pci0000:00/usb1/block/sdb/sdb1

  printf 'Connected to 66:55:44:33:22:11 (on wlan0)\n\tSSID: home-5g\n\tfreq: 5180\n' > "$STUB_OUT_DIR/iw"
  put etc/wpa_supplicant/wpa_supplicant.conf $'network={\n\tssid="home-5g"\n\t#psk="correct horse"\n\tpsk=5a8f9b6c7d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809a1b\n}'
}

fake_disks() {
  link dev/disk/by-id/nvme-eui.0025385b71b05b9c ../../nvme0n1
  link dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456 ../../nvme0n1
  link dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456-part1 ../../nvme0n1p1
  link dev/disk/by-id/wwn-0x50014ee2b5a1c3d4 ../../sda
  link dev/disk/by-id/ata-WDC_WD5000LPCX_WD-WX12A3456789 ../../sda
  link dev/disk/by-id/usb-SanDisk_Cruzer_Blade_4C530001-0:0 ../../sdb
  link dev/disk/by-path/pci-0000:00:17.0-ata-1 ../../sda
  mkdir -p "$H/dev/disk/by-path/pci-0000:00:17.0-ata-1-part"
  link dev/disk/by-path/pci-0000:00:04.0 ../../vda
  link dev/disk/by-path/platform-mmc0 ../../mmcblk0
  put sys/class/block/nvme0n1/size 1953525168
  put dev/nvme0n1 ''
  put dev/sda ''
  cat > "$STUB_OUT_DIR/lsblk" << 'EOF'
KNAME="nvme0n1" TYPE="disk" SIZE="1000204886016" TRAN="nvme" ROTA="0" FSTYPE="" PARTTYPENAME="" LABEL="" PKNAME="" MODEL="Samsung SSD 980 1TB                     "
KNAME="nvme0n1p1" TYPE="part" SIZE="104857600" TRAN="nvme" ROTA="0" FSTYPE="vfat" PARTTYPENAME="EFI System" LABEL="" PKNAME="nvme0n1" MODEL=""
KNAME="nvme0n1p2" TYPE="part" SIZE="16777216" TRAN="nvme" ROTA="0" FSTYPE="" PARTTYPENAME="Microsoft reserved" LABEL="" PKNAME="nvme0n1" MODEL=""
KNAME="nvme0n1p3" TYPE="part" SIZE="998000000000" TRAN="nvme" ROTA="0" FSTYPE="ntfs" PARTTYPENAME="Microsoft basic data" LABEL="Windows" PKNAME="nvme0n1" MODEL=""
KNAME="nvme0n1p4" TYPE="part" SIZE="800000000" TRAN="nvme" ROTA="0" FSTYPE="ntfs" PARTTYPENAME="Windows recovery environment" LABEL="" PKNAME="nvme0n1" MODEL=""
KNAME="sda" TYPE="disk" SIZE="500107862016" TRAN="sata" ROTA="1" FSTYPE="" PARTTYPENAME="" LABEL="" PKNAME="" MODEL="WDC WD5000LPCX-24C6HT0"
KNAME="sda1" TYPE="part" SIZE="536870912" TRAN="sata" ROTA="1" FSTYPE="vfat" PARTTYPENAME="EFI System" LABEL="" PKNAME="sda" MODEL=""
KNAME="sda2" TYPE="part" SIZE="499570991104" TRAN="sata" ROTA="1" FSTYPE="ext4" PARTTYPENAME="Linux filesystem" LABEL="" PKNAME="sda" MODEL=""
KNAME="sdb" TYPE="disk" SIZE="30752000000" TRAN="usb" ROTA="0" FSTYPE="iso9660" PARTTYPENAME="" LABEL="Gentoo-amd64-20261026" PKNAME="" MODEL="Cruzer Blade    "
KNAME="sdb1" TYPE="part" SIZE="1000000000" TRAN="usb" ROTA="0" FSTYPE="iso9660" PARTTYPENAME="" LABEL="Gentoo-amd64-20261026" PKNAME="sdb" MODEL=""
KNAME="vda" TYPE="disk" SIZE="42949672960" TRAN="virtio" ROTA="1" FSTYPE="" PARTTYPENAME="" LABEL="" PKNAME="" MODEL=""
KNAME="zram0" TYPE="disk" SIZE="34359738368" TRAN="" ROTA="0" FSTYPE="" PARTTYPENAME="" LABEL="" PKNAME="" MODEL=""
KNAME="loop0" TYPE="loop" SIZE="700000000" TRAN="" ROTA="0" FSTYPE="squashfs" PARTTYPENAME="" LABEL="" PKNAME="" MODEL=""
KNAME="sr0" TYPE="rom" SIZE="0" TRAN="sata" ROTA="0" FSTYPE="" PARTTYPENAME="" LABEL="" PKNAME="" MODEL="DVD-RW"
KNAME="mmcblk0" TYPE="disk" SIZE="15931539456" TRAN="mmc" ROTA="0" FSTYPE="" PARTTYPENAME="" LABEL="" PKNAME="" MODEL=""
EOF
}

@test "hw_detect on a laptop fills every key" {
  fake_laptop
  hw_detect
  [ "${HW[boot_mode]}" = uefi ]
  [ "${HW[efi_bits]}" = 64 ]
  [ "${HW[secure_boot]}" = off ]
  [ "${HW[iso]}" = gentoo-minimal ]
  [ "${HW[online]}" = yes ]
  [ "${HW[wifi_ssid]}" = home-5g ]
  [ "${HW[ram_mib]}" = 15921 ]
  [ "${HW[cpu_threads]}" = 8 ]
  [ "${HW[cpu_vendor]}" = intel ]
  [ "${HW[x86_64_v3]}" = yes ]
  [ "${HW[cpu_flags]}" = "aes avx avx2 sse4_2" ]
  [ "${HW[gpus]}" = "intel nvidia" ]
  [ "${HW[gpu_desc]}" = "Intel Iris Xe Graphics + NVIDIA GeForce RTX 3050 Mobile (hybrid)" ]
  [ "${HW[sof]}" = yes ]
  [ "${HW[wifi]}" = yes ]
  [ "${HW[bluetooth]}" = yes ]
  [ "${HW[laptop]}" = yes ]
  [ "${HW[on_battery]}" = yes ]
  [ "${HW[vm]}" = no ]
  [ "${HW[live_disk]}" = sdb ]
  [ "${SECRET[wifi_psk]}" = 5a8f9b6c7d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809a1b ]
  grep -qxF 'curl -fs --head --max-time 20 -o /dev/null https://distfiles.gentoo.org/' "$STUB_LOG"
  grep -qxF 'iw dev wlan0 link' "$STUB_LOG"
  grep -qxF 'lspci -Dmm' "$STUB_LOG"
  grep -q 'hardware:.* live_disk=sdb' "$GI_LOG"
  run ! grep -q 5a8f9b6c "$GI_LOG"
}

@test "hw_detect sets every key from ARCHITECTURE.md on an empty tree, even under errexit" {
  export GI_HOME GI_HOST_ROOT GI_RUN_DIR GI_LOG GI_TARGET
  run bash -c 'set -Eeuo pipefail; shopt -s inherit_errexit
    source "$1/lib/core.sh"; source "$1/lib/hw.sh"; hw_detect
    for k in "${!HW[@]}"; do printf "%s=%s\n" "$k" "${HW[$k]}"; done | sort' _ "$GI_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "bluetooth=no
boot_mode=bios
cpu_flags=
cpu_threads=0
cpu_vendor=other
efi_bits=
gpu_desc=
gpus=
iso=other
laptop=no
live_disk=
on_battery=no
online=yes
ram_mib=0
secure_boot=unknown
sof=no
vm=no
wifi=no
wifi_ssid=
x86_64_v3=no" ]
}

@test "hw_detect on a full laptop tree survives errexit, nounset and pipefail" {
  fake_laptop
  fake_disks
  export GI_HOME GI_HOST_ROOT GI_RUN_DIR GI_LOG GI_TARGET
  run bash -c 'set -Eeuo pipefail; shopt -s inherit_errexit
    source "$1/lib/core.sh"; source "$1/lib/hw.sh"; hw_detect; hw_disks > /dev/null
    hw_disk_size_bytes /dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456
    echo "${HW[gpu_desc]}"' _ "$GI_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = $'1000204886016\nIntel Iris Xe Graphics + NVIDIA GeForce RTX 3050 Mobile (hybrid)' ]
}

@test "Secure Boot on and 32-bit UEFI" {
  put sys/firmware/efi/fw_platform_size 32
  secure_boot 01
  hw_detect
  [ "${HW[secure_boot]}" = on ]
  [ "${HW[efi_bits]}" = 32 ]
}

@test "older cpuid2cpuflags output without the */* prefix" {
  printf 'CPU_FLAGS_X86: aes avx\n' > "$STUB_OUT_DIR/cpuid2cpuflags"
  hw_detect
  [ "${HW[cpu_flags]}" = "aes avx" ]
}

@test "a desktop VM: virtual GPU, AMD SOF driver, mains power, a mouse battery" {
  put proc/cpuinfo $'processor\t: 0\nvendor_id\t: AuthenticAMD\nflags\t\t: fpu sse2 hypervisor\n'
  pci 0000:00:01.0 0x030000 0x1af4 virtio-pci
  # AMD's audio coprocessor is a 0x0480 multimedia controller, not an audio-class device.
  pci 0000:04:00.5 0x048000 0x1022 snd_sof_amd_rembrandt
  echo '0000:00:01.0 "VGA compatible controller" "Red Hat, Inc." "Virtio 1.0 GPU" -r01 -p00 "Red Hat, Inc." "QEMU"' > "$STUB_OUT_DIR/lspci"
  put sys/class/dmi/id/chassis_type 3
  put sys/class/power_supply/hidpp_battery_0/type Battery
  put sys/class/power_supply/hidpp_battery_0/scope Device
  put sys/class/power_supply/AC/type Mains
  put sys/class/power_supply/AC/online 1
  hw_detect
  [ "${HW[cpu_vendor]}" = amd ]
  [ "${HW[vm]}" = yes ]
  [ "${HW[gpus]}" = virtual ]
  [ "${HW[gpu_desc]}" = "Virtio 1.0 GPU" ]
  [ "${HW[sof]}" = yes ]
  [ "${HW[laptop]}" = no ]
  [ "${HW[on_battery]}" = no ]
}

@test "plain HDA audio needs no SOF; GPU names fall back without lspci output" {
  pci 0000:00:1f.3 0x040300 0x8086 snd_hda_intel
  pci 0000:03:00.0 0x030000 0x1002 amdgpu
  pci 0000:02:00.0 0x030000 0x102b mgag200
  hw_detect
  [ "${HW[sof]}" = no ]
  [ "${HW[gpus]}" = amd ]
  [ "${HW[gpu_desc]}" = "AMD GPU" ]
}

@test "an AMD + NVIDIA hybrid laptop" {
  pci 0000:01:00.0 0x030000 0x10de nvidia
  pci 0000:05:00.0 0x030000 0x1002 amdgpu
  cat > "$STUB_OUT_DIR/lspci" << 'EOF'
0000:01:00.0 "VGA compatible controller" "NVIDIA Corporation" "GA106M [GeForce RTX 3060 Mobile / Max-Q]" -ra1 -p00 "ASUSTeK Computer Inc." "Device 16a2"
0000:05:00.0 "VGA compatible controller" "Advanced Micro Devices, Inc. [AMD/ATI]" "Cezanne [Radeon Vega Series / Radeon Vega Mobile Series]" -rc4 -p00 "ASUSTeK Computer Inc." "Device 16a2"
EOF
  hw_detect
  [ "${HW[gpus]}" = "amd nvidia" ]
  [ "${HW[gpu_desc]}" = "NVIDIA GeForce RTX 3060 Mobile / Max-Q + AMD Radeon Vega Series / Radeon Vega Mobile Series (hybrid)" ]
}

@test "a laptop charging over USB-C is not on battery, even when the ACPI adapter reads 0" {
  put sys/class/dmi/id/chassis_type 10
  put sys/class/power_supply/BAT0/type Battery
  put sys/class/power_supply/AC/type Mains
  put sys/class/power_supply/AC/online 0
  put sys/class/power_supply/ucsi-source-psy-USBC000:001/type USB
  put sys/class/power_supply/ucsi-source-psy-USBC000:001/online 1
  hw_detect
  [ "${HW[on_battery]}" = no ]
  put sys/class/power_supply/ucsi-source-psy-USBC000:001/online 0
  hw_detect
  [ "${HW[on_battery]}" = yes ]
}

@test "a laptop on mains power is not on battery" {
  put sys/class/dmi/id/chassis_type 9
  put sys/class/power_supply/ADP1/type Mains
  put sys/class/power_supply/ADP1/online 1
  hw_detect
  [ "${HW[laptop]}" = yes ]
  [ "${HW[on_battery]}" = no ]
}

@test "network check: DNS failure, no answer, a certificate that fails on a wrong clock, and success" {
  STUB_RC_curl=6 hw_detect
  [ "${HW[online]}" = no ]
  [ "$GI_NET_ERROR" = "DNS can't resolve distfiles.gentoo.org" ]
  STUB_RC_curl=28 _hw_net
  [ "${HW[online]}" = no ]
  [ "$GI_NET_ERROR" = "https://distfiles.gentoo.org doesn't answer (curl exit status 28)" ]
  STUB_RC_curl=60 _hw_net
  [ "$GI_NET_RC" -eq 60 ]
  [[ $GI_NET_ERROR == *"didn't verify, which a wrong clock causes" ]]
  _hw_net
  [ "${HW[online]}" = yes ]
  [ -z "$GI_NET_ERROR" ]
  [ "$GI_NET_RC" -eq 0 ]
}

@test "Wi-Fi: not connected, and an escaped SSID" {
  mkdir -p "$H/sys/class/net/wlan0/wireless"
  echo 'Not connected.' > "$STUB_OUT_DIR/iw"
  hw_detect
  [ "${HW[wifi]}" = yes ]
  [ -z "${HW[wifi_ssid]}" ]
  printf 'Connected to 66:55:44:33:22:11 (on wlan0)\n\tSSID: caf\\xc3\\xa9\\x20\n' > "$STUB_OUT_DIR/iw"
  hw_detect
  [ "${HW[wifi_ssid]}" = "café " ]
  [ -z "${SECRET[wifi_psk]+x}" ]
}

@test "Wi-Fi key from a NetworkManager keyfile" {
  mkdir -p "$H/sys/class/net/wlp2s0/wireless"
  printf 'Connected to 66:55:44:33:22:11 (on wlp2s0)\n\tSSID: Office Net\n' > "$STUB_OUT_DIR/iw"
  put "etc/NetworkManager/system-connections/Other.nmconnection" $'[wifi]\nssid=Other\n[wifi-security]\npsk=not-this-one'
  put "etc/NetworkManager/system-connections/Office Net.nmconnection" $'[connection]\nid=Office Net\n[wifi]\nmode=infrastructure\nssid=Office Net\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=my secret key'
  hw_detect
  grep -qxF 'iw dev wlp2s0 link' "$STUB_LOG"
  [ "${HW[wifi_ssid]}" = "Office Net" ]
  [ "${SECRET[wifi_psk]}" = "my secret key" ]
}

@test "Wi-Fi key from a keyfile: GLib escapes are undone, quotes kept" {
  mkdir -p "$H/sys/class/net/wlan0/wireless"
  printf 'Connected to 66:55:44:33:22:11 (on wlan0)\n\tSSID: Office\n' > "$STUB_OUT_DIR/iw"
  # NetworkManager wrote the key "  a\b\sc" as \s\sa\\b\\sc.
  put etc/NetworkManager/system-connections/Office.nmconnection '[wifi]
ssid=Office
[wifi-security]
psk=\s\sa\\b\\sc'
  hw_detect
  [ "${SECRET[wifi_psk]}" = '  a\b\sc' ]
  SECRET=()
  put etc/NetworkManager/system-connections/Office.nmconnection $'[wifi]\nssid=Office\n[wifi-security]\npsk="quoted"'
  hw_detect
  [ "${SECRET[wifi_psk]}" = '"quoted"' ]
}

@test "Wi-Fi key from a keyfile: an SSID NetworkManager escaped or wrote as bytes still matches iw's" {
  mkdir -p "$H/sys/class/net/wlan0/wireless"
  # As nmcli 1.58 writes the SSIDs " a;b\c " and "café".
  put etc/NetworkManager/system-connections/odd.nmconnection $'[wifi]\nssid=\\sa\\\\;b\\\\c \n[wifi-security]\npsk=odd key 1'
  put etc/NetworkManager/system-connections/cafe.nmconnection $'[wifi]\nssid=99;97;102;195;169;\n[wifi-security]\npsk=cafe key 1'
  printf 'Connected to 66:55:44:33:22:11 (on wlan0)\n\tSSID: \\x20a;b\\x5cc\\x20\n' > "$STUB_OUT_DIR/iw"
  hw_detect
  [ "${HW[wifi_ssid]}" = ' a;b\c ' ]
  [ "${SECRET[wifi_psk]}" = 'odd key 1' ]
  SECRET=()
  printf 'Connected to 66:55:44:33:22:11 (on wlan0)\n\tSSID: caf\\xc3\\xa9\n' > "$STUB_OUT_DIR/iw"
  hw_detect
  [ "${HW[wifi_ssid]}" = café ]
  [ "${SECRET[wifi_psk]}" = 'cafe key 1' ]
}

@test "an open live Wi-Fi network keeps an empty key; a saved network without its key keeps none" {
  mkdir -p "$H/sys/class/net/wlan0/wireless"
  printf 'Connected to 66:55:44:33:22:11 (on wlan0)\n\tSSID: Cafe\n' > "$STUB_OUT_DIR/iw"
  put etc/NetworkManager/system-connections/Cafe.nmconnection $'[connection]\nid=Cafe\ntype=wifi\n[wifi]\nssid=Cafe\n[ipv4]\nmethod=auto'
  hw_detect
  [ -n "${SECRET[wifi_psk]+x}" ]
  [ -z "${SECRET[wifi_psk]}" ]
  # nmtui with "don't store the key": a security section but no psk.
  SECRET=()
  put etc/NetworkManager/system-connections/Cafe.nmconnection $'[wifi]\nssid=Cafe\n[wifi-security]\nkey-mgmt=wpa-psk\npsk-flags=1'
  hw_detect
  [ -z "${SECRET[wifi_psk]+x}" ]
  # wpa_supplicant: open only with key_mgmt=NONE and no WEP key.
  rm "$H/etc/NetworkManager/system-connections/Cafe.nmconnection"
  put etc/wpa_supplicant/wpa_supplicant.conf $'network={\n\tssid="Other"\n\tpsk="other key"\n}\nnetwork={\n\tssid="Cafe"\n}'
  hw_detect
  [ -z "${SECRET[wifi_psk]+x}" ]
  put etc/wpa_supplicant/wpa_supplicant.conf $'network={\n\tssid="Cafe"\n\tkey_mgmt=NONE\n\twep_key0="abcde"\n}'
  hw_detect
  [ -z "${SECRET[wifi_psk]+x}" ]
  put etc/wpa_supplicant/wpa_supplicant.conf $'network={\n\tssid="Cafe"\n\tkey_mgmt=NONE\n}\nnetwork={\n\tssid="Other"\n\tpsk="other key"\n}'
  hw_detect
  [ -n "${SECRET[wifi_psk]+x}" ]
  [ -z "${SECRET[wifi_psk]}" ]
}

@test "the live Wi-Fi key never replaces a given key or fills one for another network" {
  fake_laptop
  SECRET[wifi_psk]=from-secrets-file
  hw_detect
  [ "${SECRET[wifi_psk]}" = from-secrets-file ]
  SECRET=()
  CFG[wifi_ssid]=Office
  hw_detect
  [ -z "${SECRET[wifi_psk]+x}" ]
  CFG[wifi_ssid]=home-5g
  hw_detect
  [ -n "${SECRET[wifi_psk]}" ]
}

@test "live disk: the whole USB stick, or none outside the ISO" {
  link run/initramfs/livedev ../../dev/sdc
  put dev/sdc ''
  mkdir -p "$H/sys/class/block/sdc"
  run _hw_live_disk
  [ "$output" = sdc ]
  rm "$H/run/initramfs/livedev"
  run _hw_live_disk
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hw_disks lists installable disks with their best path, kind, model and contents" {
  fake_laptop
  fake_disks
  run hw_disks
  [ "$status" -eq 0 ]
  [ "$output" = "/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456	nvme0n1	1000204886016	NVMe	Samsung SSD 980 1TB	Windows, 4 parts
/dev/disk/by-id/ata-WDC_WD5000LPCX_WD-WX12A3456789	sda	500107862016	HDD	WDC WD5000LPCX-24C6HT0	ext4, 2 parts
/dev/disk/by-path/pci-0000:00:04.0	vda	42949672960	virtio		empty" ]
  grep -qxF 'lsblk -P -b -o KNAME\,TYPE\,SIZE\,TRAN\,ROTA\,FSTYPE\,PARTTYPENAME\,LABEL\,PKNAME\,MODEL' "$STUB_LOG"
}

@test "live disk: the stick under Ventoy's device-mapper volume" {
  link run/initramfs/livedev ../../dev/dm-0
  put dev/dm-0 ''
  put sys/devices/pci0000:00/usb1/block/sdc/sdc1/partition 1
  link sys/class/block/sdc1 ../../devices/pci0000:00/usb1/block/sdc/sdc1
  mkdir -p "$H/sys/devices/virtual/block/dm-0/slaves"
  link sys/class/block/dm-0 ../../devices/virtual/block/dm-0
  ln -s ../../../../pci0000:00/usb1/block/sdc/sdc1 "$H/sys/devices/virtual/block/dm-0/slaves/sdc1"
  run _hw_live_disk
  [ "$output" = sdc ]
}

@test "hw_disks never offers namespaces' shared names, RAID, mappings, empty readers or loops" {
  fake_disks
  # udev 260: nvme-MODEL_SERIAL is namespace 1's, every namespace has MODEL_SERIAL_NSID.
  link dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456_1 ../../nvme0n1
  link dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456_2 ../../nvme0n2
  link dev/disk/by-id/nvme-eui.0025385b71b05b9d ../../nvme0n2
  link dev/disk/by-id/md-uuid-1b2c3d4e:5f6a7b8c:9d0e1f2a:3b4c5d6e ../../md127
  link dev/disk/by-id/dm-name-root ../../dm-0
  link dev/disk/by-id/dm-uuid-CRYPT-LUKS2-abc-root ../../dm-0
  link dev/disk/by-id/dm-name-vg-home ../../dm-1
  link dev/disk/by-id/usb-Generic_SD_Reader_0000-0:0 ../../sdd
  # A whole-disk LVM PV with no serial: its by-id name goes away with the PV.
  link dev/disk/by-id/lvm-pv-uuid-AbCdEf-1234-5678 ../../vdb
  link dev/disk/by-path/pci-0000:00:05.0 ../../vdb
  printf '%s\n' \
    'KNAME="nvme0n2" TYPE="disk" SIZE="500107862016" TRAN="nvme" ROTA="0" FSTYPE="" PARTTYPENAME="" LABEL="" PKNAME="" MODEL="Samsung SSD 980 1TB"' \
    'KNAME="md127" TYPE="raid1" SIZE="500107862016" TRAN="" ROTA="0" FSTYPE="ext4" PARTTYPENAME="" LABEL="" PKNAME="" MODEL=""' \
    'KNAME="dm-0" TYPE="crypt" SIZE="500107862016" TRAN="" ROTA="0" FSTYPE="ext4" PARTTYPENAME="" LABEL="" PKNAME="" MODEL=""' \
    'KNAME="dm-1" TYPE="lvm" SIZE="500107862016" TRAN="" ROTA="0" FSTYPE="xfs" PARTTYPENAME="" LABEL="" PKNAME="" MODEL=""' \
    'KNAME="sdd" TYPE="disk" SIZE="0" TRAN="usb" ROTA="0" FSTYPE="" PARTTYPENAME="" LABEL="" PKNAME="" MODEL="SD Reader"' \
    'KNAME="vdb" TYPE="disk" SIZE="107374182400" TRAN="" ROTA="1" FSTYPE="LVM2_member" PARTTYPENAME="" LABEL="" PKNAME="" MODEL=""' \
    >> "$STUB_OUT_DIR/lsblk"
  run hw_disks
  [ "$status" -eq 0 ]
  [ "$(cut -f1,2 <<< "$output")" = "/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456	nvme0n1
/dev/disk/by-id/ata-WDC_WD5000LPCX_WD-WX12A3456789	sda
/dev/disk/by-id/usb-SanDisk_Cruzer_Blade_4C530001-0:0	sdb
/dev/disk/by-path/pci-0000:00:04.0	vda
/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456_2	nvme0n2
/dev/disk/by-path/pci-0000:00:05.0	vdb" ]
}

@test "hw_disks shows the USB stick when it isn't the live medium" {
  fake_disks
  run hw_disks
  [[ $output == *"/dev/disk/by-id/usb-SanDisk_Cruzer_Blade_4C530001-0:0	sdb	30752000000	USB	Cruzer Blade	iso9660, 1 part"* ]]
}

@test "disk summary: what's on a disk now" {
  run _hw_disk_summary 0 0
  [ "$output" = empty ]
  run _hw_disk_summary 3 0
  [ "$output" = "3 parts" ]
  run _hw_disk_summary 1 0 vfat
  [ "$output" = "vfat, 1 part" ]
  run _hw_disk_summary 3 0 vfat btrfs swap
  [ "$output" = "btrfs, swap, 3 parts" ]
  run _hw_disk_summary 2 0 vfat crypto_LUKS
  [ "$output" = "crypto_LUKS, 2 parts" ]
  run _hw_disk_summary 1 0 ntfs
  [ "$output" = "ntfs, 1 part" ]
  run _hw_disk_summary 5 1 vfat ntfs ntfs ext4
  [ "$output" = "Windows, ext4, 5 parts" ]
  run _hw_disk_summary 0 0 ext4
  [ "$output" = ext4 ]
}

@test "disk kind from transport, name and rotation" {
  run _hw_disk_kind nvme0n1 nvme 0
  [ "$output" = NVMe ]
  run _hw_disk_kind sda sata 0
  [ "$output" = "SATA SSD" ]
  run _hw_disk_kind sda sata 1
  [ "$output" = HDD ]
  run _hw_disk_kind sdb usb 0
  [ "$output" = USB ]
  run _hw_disk_kind vda '' 1
  [ "$output" = virtio ]
  run _hw_disk_kind mmcblk0 '' 0
  [ "$output" = eMMC ]
  run _hw_disk_kind sdc '' 0
  [ "$output" = SSD ]
}

@test "hw_disk_size_bytes reads sysfs through a by-id link; unknown disks fail" {
  fake_disks
  run hw_disk_size_bytes /dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456
  [ "$status" -eq 0 ]
  [ "$output" = 1000204886016 ]
  run hw_disk_size_bytes /dev/disk/by-id/ata-Nothing_Here
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run hw_disk_size_bytes /dev/disk/by-id/ata-WDC_WD5000LPCX_WD-WX12A3456789
  [ "$status" -eq 1 ]
}

@test "hw_disk_free names the table type and the largest free space, in the disk's own sectors" {
  fake_disks
  put sys/block/nvme0n1/queue/logical_block_size 4096
  lsblk() { echo gpt; }
  # sfdisk -F as util-linux 2.42 prints it.
  cat > "$STUB_OUT_DIR/sfdisk" << 'EOF'
Unpartitioned space /dev/nvme0n1: 39.2 GiB, 42092969472 bytes, 82212831 sectors
Units: sectors of 1 * 4096 = 4096 bytes
Sector size (logical/physical): 4096 bytes / 4096 bytes

    Start       End  Sectors  Size
  5272832  13107199  7834368 29.9G
 13286400  15728634  2442235  9.3G
EOF
  run hw_disk_free /dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456
  [ "$status" -eq 0 ]
  [ "$output" = "gpt 5272832 7834368 4096" ]
  grep -qx 'sfdisk -F -- /dev/nvme0n1' "$STUB_LOG"
  # No partition table, so nothing is free to install into.
  lsblk() { echo; }
  rm "$STUB_OUT_DIR/sfdisk"
  run hw_disk_free /dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456
  [ "$output" = "none 0 0 4096" ]
}
