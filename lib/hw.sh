# shellcheck shell=bash
# Hardware facts about the live machine: HW, the installable disks and the live Wi-Fi network.

# Declared in core.sh; repeated so shellcheck knows they're associative. Keeps their contents.
declare -gA HW SECRET
# Prefix for every /sys, /proc, /dev, /run, /etc and /lib64 path read here, so tests can feed a fake tree.
: "${GI_HOST_ROOT:=}"
# Why the last network check failed, for messages; empty when online. GI_NET_RC is curl's exit status.
GI_NET_ERROR='' GI_NET_RC=0
# 1 once SECRET[wifi_psk] holds a live key _hw_keep_psk kept, not one the user gave.
_hw_psk_kept=0

hw_detect() {
  local r=$GI_HOST_ROOT line out k s='' threads=0 iface key
  local -a words=()
  HW[boot_mode]=bios HW[efi_bits]='' HW[secure_boot]=unknown
  if [[ -d $r/sys/firmware/efi ]]; then
    HW[boot_mode]=uefi
    HW[efi_bits]=$(_hw_read "$r/sys/firmware/efi/fw_platform_size")
    HW[secure_boot]=$(_hw_secure_boot)
  fi
  # catalyst writes this greeting into /etc/motd for livecd/type gentoo-release-minimal only.
  HW[iso]=other
  if [[ $(_hw_read "$r/etc/motd") == *'Gentoo Linux Minimal Installation CD'* ]]; then HW[iso]=gentoo-minimal; fi

  HW[ram_mib]=0 HW[cpu_vendor]=other HW[vm]=no
  while IFS= read -r line; do
    if [[ $line == MemTotal:* ]]; then
      out=${line//[!0-9]/}
      HW[ram_mib]=$((${out:-0} / 1024))
    fi
  done < <(_hw_read "$r/proc/meminfo")
  while IFS= read -r line; do
    case $line in
      processor*) threads=$((threads + 1)) ;;
      vendor_id*GenuineIntel) HW[cpu_vendor]=intel ;;
      vendor_id*AuthenticAMD) HW[cpu_vendor]=amd ;;
      flags*) if [[ " ${line#*:} " == *' hypervisor '* ]]; then HW[vm]=yes; fi ;;
    esac
  done < <(_hw_read "$r/proc/cpuinfo")
  HW[cpu_threads]=$threads

  HW[x86_64_v3]=no
  out=$("$r/lib64/ld-linux-x86-64.so.2" --help 2> /dev/null) || true
  if [[ $out == *'x86-64-v3 (supported, searched)'* ]]; then HW[x86_64_v3]=yes; fi
  # cpuid2cpuflags 18 prints "*/* CPU_FLAGS_X86: ...", 17 and older "CPU_FLAGS_X86: ...".
  out=$(cpuid2cpuflags 2> /dev/null) || out=''
  out=${out#'*/* '}
  read -ra words <<< "${out#CPU_FLAGS_X86:}"
  HW[cpu_flags]=${words[*]}

  _hw_pci
  HW[wifi]=no HW[bluetooth]=no
  if compgen -G "$r/sys/class/net/*/wireless" > /dev/null; then HW[wifi]=yes; fi
  if compgen -G "$r/sys/class/bluetooth/hci*" > /dev/null; then HW[bluetooth]=yes; fi
  _hw_power
  HW[live_disk]=$(_hw_live_disk)

  _hw_net
  HW[wifi_ssid]=''
  iface=$(_hw_wifi_iface)
  if [[ -n $iface ]]; then
    out=$(iw dev "$iface" link 2> /dev/null) || out=''
    if [[ $out == 'Connected to'* ]]; then
      while IFS= read -r line; do
        # iw writes unprintable SSID bytes as \xNN.
        if [[ $line == $'\tSSID: '* ]]; then printf -v 'HW[wifi_ssid]' '%b' "${line#$'\tSSID: '}"; fi
      done <<< "$out"
    fi
  fi
  if [[ -n ${HW[wifi_ssid]} ]] && key=$(_hw_wifi_key "${HW[wifi_ssid]}"); then
    _hw_keep_psk "${HW[wifi_ssid]}" "$key"
  fi

  for k in "${!HW[@]}"; do s+=" $k=${HW[$k]}"; done
  log INFO "hardware:$s"
}

_hw_read() { cat -- "$1" 2> /dev/null || true; }

# The variable holds 4 attribute bytes, then the value: 1 on, 0 off.
_hw_secure_boot() {
  local w last=''
  local -a bytes=()
  read -ra bytes <<< "$(od -An -tu1 -- "$GI_HOST_ROOT/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c" 2> /dev/null || true)"
  for w in "${bytes[@]}"; do last=$w; done
  case $last in
    1) echo on ;;
    0) echo off ;;
    *) echo unknown ;;
  esac
}

_hw_pci() {
  local d class vendor kind drv line name label desc='' sof=no i physical=0
  local re='^[^ ]+ "[^"]*" "[^"]*" "([^"]*)"' re_bracket='\[([^]]*)\]'
  local -a slots=() kinds=() gpus=() listing=()
  for d in "$GI_HOST_ROOT"/sys/bus/pci/devices/*; do
    [[ -r $d/class && -r $d/vendor ]] || continue
    class=$(< "$d/class") vendor=$(< "$d/vendor")
    case $class in
      0x0300?? | 0x0302?? | 0x0380??)
        case $vendor in
          0x8086) kind=intel ;;
          0x1002) kind=amd ;;
          0x10de) kind=nvidia ;;
          0x1af4 | 0x1b36 | 0x15ad | 0x1234 | 0x80ee) kind=virtual ;; # virtio, QXL, VMware, QEMU VGA, VirtualBox
          *) continue ;;
        esac
        slots+=("${d##*/}") kinds+=("$kind")
        ;;
      0x0401?? | 0x0403?? | 0x0480??) # AMD's audio coprocessor (ACP) is a 0x0480 multimedia controller
        # SOF firmware is needed when the kernel bound a SOF driver (Intel sof-audio-pci-*, AMD snd_sof_*),
        # or when the firmware enabled an Intel audio DSP, which sound/hda/intel-dsp-config.c reads
        # from PCI class 0x040100. On Skylake-era DSPs the kernel may pick another driver; the firmware is harmless there.
        drv=$(readlink -- "$d/driver") || drv=''
        case ${drv##*/} in
          sof-audio-pci-* | snd_sof_*) sof=yes ;;
        esac
        if [[ $vendor == 0x8086 && $class == 0x040100 ]]; then sof=yes; fi
        ;;
    esac
  done

  for kind in intel amd nvidia virtual; do
    if [[ " ${kinds[*]} " == *" $kind "* ]]; then gpus+=("$kind"); fi
    if [[ $kind != virtual && " ${kinds[*]} " == *" $kind "* ]]; then physical=$((physical + 1)); fi
  done
  if ((${#slots[@]})); then mapfile -t listing < <(lspci -Dmm 2> /dev/null); fi
  for i in "${!slots[@]}"; do
    name=''
    for line in "${listing[@]}"; do
      if [[ $line == "${slots[i]} "* && $line =~ $re ]]; then name=${BASH_REMATCH[1]}; fi
    done
    # "TigerLake-LP GT2 [Iris Xe Graphics]": the marketing name is in brackets.
    if [[ $name =~ $re_bracket ]]; then name=${BASH_REMATCH[1]}; fi
    case ${kinds[i]} in
      intel) label=Intel ;;
      amd) label=AMD ;;
      nvidia) label=NVIDIA ;;
      *) label=virtual ;;
    esac
    if [[ -z $name ]]; then
      name="$label GPU"
    elif [[ $label != virtual ]]; then
      name="$label $name"
    fi
    desc+="${desc:+ + }$name"
  done
  if ((physical > 1)); then desc+=" (hybrid)"; fi
  HW[gpus]=${gpus[*]} HW[gpu_desc]=$desc HW[sof]=$sof
}

_hw_power() {
  local d laptop=no mains=0 ac=0
  case $(_hw_read "$GI_HOST_ROOT/sys/class/dmi/id/chassis_type") in
    # SMBIOS: portable, laptop, notebook, hand held, sub notebook, tablet, convertible, detachable
    8 | 9 | 10 | 11 | 14 | 30 | 31 | 32) laptop=yes ;;
  esac
  for d in "$GI_HOST_ROOT"/sys/class/power_supply/*; do
    case $(_hw_read "$d/type") in
      # A battery with scope Device belongs to a mouse or headset, not to this machine.
      Battery) if [[ $(_hw_read "$d/scope") != Device ]]; then laptop=yes; fi ;;
      # USB-C chargers (UCSI, ChromeOS EC) show as type USB, sometimes while the ACPI adapter reads 0.
      Mains | USB)
        mains=1
        if [[ $(_hw_read "$d/online") == 1 ]]; then ac=1; fi
        ;;
    esac
  done
  HW[laptop]=$laptop HW[on_battery]=no
  if [[ $laptop == yes ]] && ((mains && !ac)); then HW[on_battery]=yes; fi
}

# dracut's dmsquash-live links /run/initramfs/livedev to the boot medium, through
# /dev/disk/by-label/<CDLABEL>. It may be the whole USB stick or a partition on it.
_hw_live_disk() {
  local r=$GI_HOST_ROOT dev s
  [[ -e $r/run/initramfs/livedev ]] || return 0
  dev=$(readlink -f -- "$r/run/initramfs/livedev") || return 0
  dev=${dev##*/}
  # Ventoy maps the ISO file through device-mapper; the stick is below the mapping.
  for s in "$r/sys/class/block/$dev/slaves/"*; do
    if [[ -e $s ]]; then dev=${s##*/}; fi
  done
  if [[ -e $r/sys/class/block/$dev/partition ]]; then
    dev=$(readlink -f -- "$r/sys/class/block/$dev/..") || return 0
    dev=${dev##*/}
  fi
  printf '%s\n' "$dev"
}

# shellcheck disable=SC2034  # GI_NET_ERROR and GI_NET_RC are read by lib/preflight.sh
_hw_net() {
  local rc=0
  # curl uses http_proxy and https_proxy from the environment by itself.
  curl -fs --head --max-time 20 -o /dev/null https://distfiles.gentoo.org/ || rc=$?
  GI_NET_RC=$rc
  case $rc in
    0) GI_NET_ERROR='' ;;
    5 | 6) GI_NET_ERROR="DNS can't resolve distfiles.gentoo.org" ;;
    60) GI_NET_ERROR="the certificate of https://distfiles.gentoo.org didn't verify, which a wrong clock causes" ;;
    *) GI_NET_ERROR="https://distfiles.gentoo.org doesn't answer (curl exit status $rc)" ;;
  esac
  HW[online]=no
  if ((rc == 0)); then HW[online]=yes; fi
}

_hw_wifi_iface() {
  local f
  for f in "$GI_HOST_ROOT"/sys/class/net/*/wireless; do
    if [[ -e $f ]]; then
      f=${f%/wireless}
      printf '%s\n' "${f##*/}"
      return 0
    fi
  done
}

# Prints the key that net-setup (through wpa_passphrase) or NetworkManager (nmtui) saved for SSID,
# and nothing for an open network. Returns 1 when no saved network says which.
_hw_wifi_key() { # SSID
  local f line v cur psk none sec wpa rc=1 key=''
  local -a bytes=()
  for f in "$GI_HOST_ROOT"/etc/wpa_supplicant/wpa_supplicant.conf "$GI_HOST_ROOT"/etc/NetworkManager/system-connections/*.nmconnection; do
    [[ -r $f ]] || continue
    wpa=0 cur='' psk='' none=0 sec=0
    if [[ $f == *.conf ]]; then wpa=1; fi
    # The extra "}" ends a keyfile's one network; after wpa_supplicant's last block it ends nothing.
    while IFS= read -r line; do
      line=${line#"${line%%[![:space:]]*}"}
      v=${line#*=}
      if ((wpa)); then
        v=${v#\"} v=${v%\"}
      else
        # GLib keyfile escapes: \\ is a backslash, \s a leading space.
        v=${v//\\\\/$'\1'} v=${v//\\s/ } v=${v//$'\1'/\\}
      fi
      case $line in
        ssid=*)
          # NetworkManager writes ";" in an SSID as "\;", and an SSID with bytes outside printable ASCII as their values: 99;97;102;195;169;
          if ((!wpa)) && [[ $v =~ ^([0-9]{1,3};)+$ ]]; then
            IFS=';' read -ra bytes <<< "$v"
            printf -v v '\\x%x' "${bytes[@]}"
            printf -v v '%b' "$v"
          elif ((!wpa)); then
            v=${v//\\;/;}
          fi
          cur=$v
          ;;
        psk=*) psk=$v ;;
        key_mgmt=NONE) none=1 ;;
        wep_key* | '[wifi-security]' | '[802-11-wireless-security]') sec=1 ;;
        '}')
          if [[ $cur == "$1" ]]; then
            # wpa_supplicant defaults to WPA; NetworkManager is open without a security section.
            key=$psk rc=0
            if [[ -z $psk ]] && ((sec || (wpa && !none))); then rc=1; fi
          fi
          cur='' psk='' none=0 sec=0
          ;;
      esac
    done < <(
      _hw_read "$f"
      printf '\n}\n'
    )
  done
  printf '%s' "$key"
  return "$rc"
}

# Keeps the live Wi-Fi key for the new system, unless a key was given or the config names another network.
# A key kept here gives way: preflight's Wi-Fi offer can join another network than the one hw_detect found.
_hw_keep_psk() { # SSID KEY
  if [[ (-z ${SECRET[wifi_psk]+x} || $_hw_psk_kept == 1) && ${CFG[wifi_ssid]:-$1} == "$1" ]]; then
    SECRET[wifi_psk]=$2 _hw_psk_kept=1
  fi
}

# One line per installable disk: path, kernel name, bytes, kind, model, what's on it now.
# Installable means a whole disk of 20 GiB or more that isn't the live medium.
hw_disks() {
  local r=$GI_HOST_ROOT live link dev rank line name size tran rota pk model
  local re='^KNAME="([^"]*)" TYPE="([^"]*)" SIZE="([^"]*)" TRAN="([^"]*)" ROTA="([^"]*)" FSTYPE="([^"]*)" PARTTYPENAME="([^"]*)" LABEL="([^"]*)" PKNAME="([^"]*)" MODEL="([^"]*)"$'
  local -a lines=() fs=()
  local -A best=() best_rank=() parts=() fstypes=() windows=()
  live=$(_hw_live_disk)
  for link in "$r"/dev/disk/by-id/* "$r"/dev/disk/by-path/*; do
    [[ -L $link && ! $link =~ -part[0-9]+$ ]] || continue
    # wwn-, nvme-eui. and nvme-nvme. names duplicate the readable model_serial ones.
    case ${link#"$r"/dev/disk/} in
      by-id/wwn-* | by-id/nvme-eui.* | by-id/nvme-nvme.*) rank=2 ;;
      # LVM names a PV by its contents, so wiping the disk removes the link.
      by-id/lvm-pv-uuid-*) rank=4 ;;
      by-id/nvme-* | by-id/ata-* | by-id/usb-* | by-id/scsi-* | by-id/virtio-* | by-id/mmc-*) rank=1 ;;
      by-id/*) rank=2 ;;
      *) rank=3 ;;
    esac
    dev=$(readlink -f -- "$link") || continue
    dev=${dev##*/}
    if [[ -z ${best[$dev]:-} ]] || ((rank < ${best_rank[$dev]})); then
      best[$dev]=${link#"$r"} best_rank[$dev]=$rank
    fi
  done

  mapfile -t lines < <(lsblk -P -b -o KNAME,TYPE,SIZE,TRAN,ROTA,FSTYPE,PARTTYPENAME,LABEL,PKNAME,MODEL 2> /dev/null)
  for line in "${lines[@]}"; do
    [[ $line =~ $re ]] || continue
    name=${BASH_REMATCH[1]} pk=${BASH_REMATCH[9]}
    case ${BASH_REMATCH[2]} in
      disk) fstypes[$name]+=" ${BASH_REMATCH[6]}" ;;
      part)
        parts[$pk]=$((${parts[$pk]:-0} + 1))
        fstypes[$pk]+=" ${BASH_REMATCH[6]}"
        case ${BASH_REMATCH[7]} in
          'Microsoft reserved' | 'Windows recovery environment' | 'Hidden NTFS WinRE') windows[$pk]=1 ;;
        esac
        if [[ ${BASH_REMATCH[8]} == 'System Reserved' ]]; then windows[$pk]=1; fi
        ;;
    esac
  done
  for line in "${lines[@]}"; do
    [[ $line =~ $re && ${BASH_REMATCH[2]} == disk ]] || continue
    name=${BASH_REMATCH[1]} size=${BASH_REMATCH[3]} tran=${BASH_REMATCH[4]} rota=${BASH_REMATCH[5]} model=${BASH_REMATCH[10]}
    case $name in
      loop* | zram* | ram* | sr*) continue ;;
    esac
    [[ $name != "$live" && -n ${best[$name]:-} && $size =~ ^[0-9]+$ ]] || continue
    ((size >= 20 * 1024 ** 3)) || continue
    read -r model <<< "$model" || true
    read -ra fs <<< "${fstypes[$name]:-}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${best[$name]}" "$name" "$size" "$(_hw_disk_kind "$name" "$tran" "$rota")" \
      "$model" "$(_hw_disk_summary "${parts[$name]:-0}" "${windows[$name]:-0}" "${fs[@]}")"
  done
}

_hw_disk_kind() { # NAME TRAN ROTA
  case $2:$1 in
    nvme:* | *:nvme*) echo NVMe ;;
    usb:*) echo USB ;;
    virtio:* | *:vd*) echo virtio ;;
    mmc:* | *:mmcblk*) echo eMMC ;;
    *)
      if [[ $3 == 1 ]]; then echo HDD; else echo "${2:+${2^^} }SSD"; fi
      ;;
  esac
}

_hw_disk_summary() { # PARTS WINDOWS FSTYPE...
  local n=$1 win=$2 f vfat=0 s
  local -a fs=() out=()
  shift 2
  for f; do
    case $f in
      vfat) vfat=1 ;;
      ntfs) if ((!win)) && [[ " ${fs[*]} " != *" ntfs "* ]]; then fs+=(ntfs); fi ;;
      *) if [[ " ${fs[*]} " != *" $f "* ]]; then fs+=("$f"); fi ;;
    esac
  done
  # An ESP next to another filesystem says nothing about what's installed.
  if ((vfat && !win && ${#fs[@]} == 0)); then fs=(vfat); fi
  if ((win)); then out=(Windows); fi
  out+=("${fs[@]}")
  if ((n == 1)); then out+=("1 part"); elif ((n > 1)); then out+=("$n parts"); fi
  if ((${#out[@]} == 0)); then
    echo empty
    return 0
  fi
  printf -v s '%s, ' "${out[@]}"
  printf '%s\n' "${s%, }"
}

# Prints "PTTYPE START SECTORS SECTOR_SIZE" for DISK's largest unpartitioned space, counted in its
# own sectors. PTTYPE is gpt, dos or none; START and SECTORS are 0 when nothing is free.
hw_disk_free() { # /dev/disk/by-id/... or /dev/disk/by-path/...
  local dev pt ss start n best=0 at=0
  dev=$(readlink -f -- "$GI_HOST_ROOT$1") || return 1
  dev=${dev##*/}
  pt=$(lsblk -dno PTTYPE -- "/dev/$dev") || return 1
  ss=$(< "$GI_HOST_ROOT/sys/block/$dev/queue/logical_block_size") || return 1
  while read -r start _ n _; do
    if [[ $start =~ ^[0-9]+$ && $n =~ ^[0-9]+$ ]] && ((n > best)); then best=$n at=$start; fi
  done < <(LC_ALL=C sfdisk -F -- "/dev/$dev" 2> /dev/null)
  printf '%s %s %s %s\n' "${pt:-none}" "$at" "$best" "$ss"
}

hw_disk_size_bytes() { # /dev/disk/by-id/... or /dev/disk/by-path/...
  local dev f
  [[ -e $GI_HOST_ROOT$1 ]] || return 1
  dev=$(readlink -f -- "$GI_HOST_ROOT$1") || return 1
  f=$GI_HOST_ROOT/sys/class/block/${dev##*/}/size
  [[ -r $f ]] || return 1
  # sysfs counts 512-byte sectors whatever the disk's own sector size.
  printf '%s\n' $(($(< "$f") * 512))
}
