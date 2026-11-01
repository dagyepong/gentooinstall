# shellcheck shell=bash
# Pre-flight: checks the machine before any question and shows the result as one checklist.

# Declared in core.sh; repeated so shellcheck knows it's associative. Keeps its contents.
declare -gA HW

# Every external tool the install runs on the live system; the minimal ISO ships them all.
GI_TOOLS=(dialog lsblk blkid sfdisk wipefs udevadm mkfs.vfat mkfs.ext4 mkfs.xfs mkfs.btrfs
  cryptsetup gpg curl tar xz arch-chroot genfstab cpuid2cpuflags lspci efibootmgr chronyd git)

preflight_run() {
  local fails=0 warns=0 clock=0
  local -a lines=() notes=()
  hw_detect
  _pf_startup
  if ((fails == 0)); then _pf_network; fi
  if ((fails == 0 && !clock)) && [[ ${HW[online]} == yes ]]; then _pf_clock; fi
  _pf_machine
  _pf_report
}

_pf_line() { # ok|warn|fail TEXT
  case $1 in
    ok)
      lines+=("[ ok ]  $2")
      log INFO "check ok: $2"
      ;;
    warn)
      lines+=("[warn]  $2")
      warns=$((warns + 1))
      log WARN "check: $2"
      ;;
    fail)
      lines+=("[FAIL]  $2")
      fails=$((fails + 1))
      log ERROR "check failed: $2"
      ;;
  esac
}

_pf_startup() {
  local arch t
  local -a missing=()
  arch=$(uname -m)
  if [[ $arch != x86_64 ]]; then _pf_line fail "This is a $arch machine; gentooinstall installs x86_64 (amd64) only"; fi
  if [[ ${HW[boot_mode]} == bios ]]; then
    _pf_line fail "Booted in legacy BIOS mode; this version needs UEFI"
    notes+=("To start the USB stick in UEFI mode: restart, open the firmware's boot menu (often F12, F11, F8 or Esc) and pick the entry for the stick that begins with \"UEFI:\". If there is none, turn on UEFI boot, or turn off CSM or Legacy boot, in the firmware setup.")
  elif [[ ${HW[efi_bits]} == 32 ]]; then
    _pf_line fail "32-bit UEFI firmware; this version supports 64-bit UEFI only"
  else
    _pf_line ok "Booted in UEFI mode${HW[efi_bits]:+ (${HW[efi_bits]}-bit)}"
  fi
  case ${HW[secure_boot]} in
    on) _pf_line warn "Secure Boot is on. Keep it on by setting Secure Boot to yes in System, which needs systemd-boot, or turn it off in the firmware setup." ;;
    off) _pf_line ok "Secure Boot is off" ;;
    *) _pf_line ok "The firmware reports no Secure Boot state" ;;
  esac
  if [[ ${HW[iso]} == gentoo-minimal ]]; then
    _pf_line ok "Running on the Gentoo minimal install ISO"
  else
    _pf_line warn "This isn't the Gentoo minimal install ISO. Other live systems are unsupported."
  fi
  for t in "${GI_TOOLS[@]}"; do
    if ! command -v "$t" > /dev/null; then missing+=("$t"); fi
  done
  if ((${#missing[@]})); then
    _pf_line fail "Missing tools: ${missing[*]}"
  else
    _pf_line ok "All required tools are installed"
  fi
}

_pf_network() {
  # A clock months off fails the certificate check, and NTP needs no TLS: sync it, then check again.
  if [[ ${HW[online]} == no ]] && ((GI_NET_RC == 60)); then
    _pf_clock
    clock=1
    _hw_net
  fi
  if [[ ${HW[online]} == no && ${HW[wifi]} == yes ]] && ((!GI_YES && !GI_DRY_RUN)) && _pf_nm_running &&
    ui_yesno "No network" "$GI_NET_ERROR."$'\n\n'"Connect to a Wi-Fi network now?"; then
    _pf_wifi
  fi
  if [[ ${HW[online]} == yes ]]; then
    _pf_line ok "distfiles.gentoo.org reachable${HW[wifi_ssid]:+ over Wi-Fi \"${HW[wifi_ssid]}\"}"
  elif ((GI_DRY_RUN)); then
    _pf_line warn "Offline: $GI_NET_ERROR. A dry run doesn't need the network; the install does."
  else
    _pf_line fail "Offline: $GI_NET_ERROR"
    notes+=("Plug in a network cable, or connect to Wi-Fi with nmtui or net-setup, then start gentooinstall again.")
  fi
}

# The minimal ISO starts NetworkManager, which then owns Wi-Fi, DHCP and resolv.conf.
_pf_nm_running() { [[ $(nmcli -t -f RUNNING general 2> /dev/null) == running ]]; }

_pf_wifi() {
  local iface line s='' choice ssid key msg secure tried=0 name=gentooinstall-wifi
  local -a ssids=() menu=() add=()
  local -A secured=()
  iface=$(_hw_wifi_iface)
  while :; do
    ssids=() menu=() secured=()
    while IFS= read -r line; do
      case $line in
        'BSS '*) s='' ;;
        $'\tSSID: '*)
          printf -v s '%b' "${line#$'\tSSID: '}"
          if [[ -n $s && -z ${secured[$s]+x} ]]; then
            ssids+=("$s")
            secured[$s]=0
          fi
          ;;
        $'\tRSN:'* | $'\tWPA:'*) if [[ -n $s ]]; then secured[$s]=1; fi ;;
      esac
      # A scan NetworkManager is running makes this one fail as busy; the dump has the results so far.
    done < <(timeout 30 iw dev "$iface" scan 2> /dev/null || iw dev "$iface" scan dump 2> /dev/null)
    for s in "${!ssids[@]}"; do
      if [[ ${secured[${ssids[s]}]} == 1 ]]; then
        menu+=("$((s + 1))" "${ssids[s]}" "Needs a key")
      else
        menu+=("$((s + 1))" "${ssids[s]} (open)" "Open network, no key")
      fi
    done
    choice=$(ui_menu "Wi-Fi" "Pick the network to connect to." "${menu[0]:-other}" "${menu[@]}" \
      other "Other network" "Type the name of a hidden or unlisted network") || break
    if [[ $choice == other ]]; then
      ssid=$(ui_input "Wi-Fi" "Name (SSID) of the network:" '') || continue
      msg="The name can't be empty."
      if [[ -n $ssid ]]; then msg=$(cfg_validate wifi_ssid "$ssid") || true; fi
      if [[ -n $msg ]]; then
        ui_msg "Wi-Fi" "$msg"
        continue
      fi
      secure=1
      if ui_yesno --defaultno "Wi-Fi" "Is \"$ssid\" an open network, with no key?"; then secure=0; fi
    else
      ssid=${ssids[choice - 1]} secure=${secured[${ssids[choice - 1]}]}
    fi
    key=''
    if ((secure)); then
      key=$(ui_password_twice "Wi-Fi" "Key for \"$ssid\":") || continue
      if ! msg=$(cfg_secret_validate wifi_psk "$key"); then
        ui_msg "Wi-Fi" "The key ${msg#wifi_psk: }."
        continue
      fi
    fi
    add=(nmcli connection add type wifi con-name "$name" ifname "$iface" ssid "$ssid" wifi.hidden yes)
    if [[ -n $key ]]; then add+=(wifi-sec.key-mgmt wpa-psk); fi
    _pf_wifi_forget
    tried=1
    if run_cmd "${add[@]}"; then
      # The key reaches nmcli through a pipe: never an argument, never a file.
      run_cmd nmcli --wait 60 connection up id "$name" passwd-file <(_pf_psk_line "$key") || true
    fi
    _hw_net
    if [[ ${HW[online]} == yes ]]; then
      HW[wifi_ssid]=$ssid
      _hw_keep_psk "$ssid" "$key"
      return 0
    fi
    ui_yesno "Wi-Fi" "Still offline over \"$ssid\": $GI_NET_ERROR. Try again?" || break
  done
  # A profile that didn't connect would keep trying in the background, with the key it was given.
  if ((tried)) && [[ $(nmcli -g GENERAL.STATE connection show id "$name" 2> /dev/null || true) != activated ]]; then
    _pf_wifi_forget
  fi
}

# Deletes the profile NAME of _pf_wifi. NetworkManager allows several with one name; this leaves none.
_pf_wifi_forget() {
  if nmcli connection show id "$name" > /dev/null 2>&1; then run_cmd nmcli connection delete id "$name" || true; fi
}

# One line of nmcli's passwd-file, nothing for an open network. nmcli unescapes the value
# and drops unescaped spaces at its ends, so backslashes and spaces are escaped.
_pf_psk_line() { # KEY
  local esc=${1//\\/\\\\}
  if [[ -n $1 ]]; then printf '802-11-wireless-security.psk:%s\n' "${esc// /\\ }"; fi
}

_pf_clock() {
  local -a cmd=(chronyd -q -t 30)
  # Directives on the command line replace the config file, which the ISO normally has.
  if [[ ! -f $GI_HOST_ROOT/etc/chrony/chrony.conf ]]; then cmd+=('pool pool.ntp.org iburst'); fi
  if run_cmd "${cmd[@]}"; then
    _pf_line ok "Clock synced with chronyd"
  elif ((!GI_YES)) && _pf_set_clock; then
    _pf_line ok "Clock set by hand"
  else
    _pf_line warn "No time server answered, and the clock says $(date -u '+%F %H:%M') UTC. Downloads and signature checks fail if that's wrong."
  fi
}

_pf_set_clock() {
  local now t
  now=$(date -u '+%Y-%m-%d %H:%M')
  while :; do
    t=$(ui_input "Set the clock" "No time server answered, and downloads and signature checks fail when the clock is wrong. The clock says $now UTC. Type the current UTC time as YYYY-MM-DD HH:MM, or go back to keep it." "$now") || return 1
    if [[ $t =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] && date -u -d "$t" > /dev/null 2>&1; then
      run_cmd date -u -s "$t" || return 1
      return 0
    fi
    ui_msg "Set the clock" "Not a time like 2026-10-30 14:05: $t"
  done
}

_pf_machine() {
  local gib=$(((HW[ram_mib] + 512) / 1024)) v3=x86-64-v3
  local -a disks=()
  if [[ ${HW[x86_64_v3]} != yes ]]; then v3="no x86-64-v3"; fi
  # MemTotal leaves out what firmware and kernel reserve, so compare the rounded GiB the screen shows.
  if ((gib < 2)); then
    _pf_line fail "$gib GiB RAM; at least 2 GiB is needed"
  else
    _pf_line ok "$gib GiB RAM, ${HW[cpu_threads]} threads, $v3"
  fi
  _pf_line ok "GPU: ${HW[gpu_desc]:-none found}"
  if [[ ${HW[on_battery]} == yes ]]; then _pf_line warn "Running on battery. Plug in the charger."; fi
  mapfile -t disks < <(hw_disks)
  case ${#disks[@]} in
    0) _pf_line fail "No disk of 20 GiB or more, apart from the live USB" ;;
    1) _pf_line ok "1 disk of 20 GiB or more" ;;
    *) _pf_line ok "${#disks[@]} disks of 20 GiB or more" ;;
  esac
}

_pf_report() {
  local title="Checking this machine" text note
  printf -v text '%s\n' "${lines[@]}"
  for note in "${notes[@]}"; do text+=$'\n'$note$'\n'; done
  text=${text%$'\n'}
  if ((fails)); then
    _pf_show "$title" "$text"
    die "This machine failed the checks marked [FAIL]. Fix them and start gentooinstall again."
  fi
  if ((warns && !GI_YES)); then
    if ui_yesno "$title" "$text"$'\n\n'"Continue anyway?"; then return 0; fi
    log INFO "stopped by the user at the pre-flight checks"
    exit 130
  fi
  _pf_show "$title" "$text"
}

# --yes must never wait for a key press, even in dialog mode.
_pf_show() { # TITLE TEXT
  if ((GI_YES)); then
    printf '\n== %s ==\n%s\n' "$1" "$2" >&2
  else
    ui_msg "$1" "$2"
  fi
}
