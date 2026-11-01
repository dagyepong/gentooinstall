# shellcheck shell=bash
# Config: key schema, defaults, validators, load and save, secrets, combination rules.

GI_CFG_KEYS=(format keymap disk disk_mode filesystem home root_size encryption luks_discard swap init desktop
  gnome_variant display_manager bootloader secure_boot kernel kernel_version nvidia_driver network keep_wifi wifi_ssid
  audio bluetooth power thermald fwupd printing fingerprint sshd flatpak hostname timezone locales lang root users
  privilege mirror binpkgs cflags makeopts emerge_jobs tune browser fonts_cjk media_keys packages explain)
declare -gA GI_CFG_LOCKED=()

# Accounts and groups the stage3 or the packages we install already have.
GI_RESERVED_NAMES=(root bin daemon adm lp sync shutdown halt mail news uucp operator man
  postmaster portage nobody sshd messagebus polkitd sddm gdm lightdm avahi colord geoclue rtkit
  usbmux pipewire dhcpcd chrony ntp tss saned nm-openvpn flatpak cron dnsmasq wheel users
  audio video usb input kvm render tty disk floppy cdrom tape dialout plugdev sys utmp
  kmem plocate locate)

cfg_set() { # KEY VALUE
  local msg
  msg=$(_cfg_problem "$1" "$2")
  if [[ -n $msg ]]; then
    printf '%s\n' "$msg" >&2
    return 1
  fi
  CFG[$1]=$2
}

cfg_lock() {
  local k
  for k; do GI_CFG_LOCKED[$k]=1; done
}

cfg_is_locked() { [[ -n ${GI_CFG_LOCKED[$1]:-} ]]; }

# Prints why KEY can't be set to VALUE now, or nothing when it can.
_cfg_problem() {
  cfg_validate "$1" "$2" || return 0
  if cfg_is_locked "$1" && [[ ${CFG[$1]-} != "$2" ]]; then
    printf "%s: can't change once the disk step has started\n" "$1"
  fi
}

cfg_validate() { # KEY VALUE
  local msg
  if msg=$(_cfg_check "$1" "$2"); then return 0; fi
  printf '%s: %s\n' "$1" "${msg:-invalid value}"
  return 1
}

_cfg_check() { # KEY VALUE; prints the problem and returns 1
  local v=$2 w
  local -a words=()
  # The list checks below read one line, and a saved newline would break the config file.
  if [[ $v == *$'\n'* ]]; then
    echo 'must be a single line'
    return 1
  fi
  case $1 in
    format) _cfg_enum "$v" 1 ;;
    keymap) _cfg_re "$v" '^[A-Za-z0-9][A-Za-z0-9._+-]*$' 'must be a console keymap name like us or de-latin1' ;;
    disk)
      [[ -n $v ]] || return 0 # not chosen yet; cfg_check_rules requires it
      # by-path is for disks without a by-id link, like a QEMU virtio disk with no serial.
      _cfg_re "$v" '^/dev/disk/by-(id|path)/[^/[:space:][:cntrl:]]+$' 'must be a whole disk under /dev/disk/by-id/ or /dev/disk/by-path/' || return 1
      if [[ $v == */. || $v == */.. || $v =~ -part[0-9]+$ ]]; then
        echo 'must be a whole disk, not a partition'
        return 1
      fi
      ;;
    disk_mode) _cfg_enum "$v" wipe free ;;
    filesystem) _cfg_enum "$v" ext4 xfs btrfs ;;
    home) _cfg_enum "$v" root partition ;;
    root_size) _cfg_re "$v" '^[1-9][0-9]{1,4}$' 'must be a size in GiB, like 80' ;;
    encryption) _cfg_enum "$v" none luks2 ;;
    swap) _cfg_enum "$v" zram file hibernate none ;;
    init) _cfg_enum "$v" openrc systemd ;;
    desktop) _cfg_enum "$v" plasma gnome xfce budgie cinnamon i3 sway hyprland niri mangowm dwm dwl none ;;
    gnome_variant) _cfg_enum "$v" light full ;;
    display_manager) _cfg_enum "$v" auto none tuigreet gtkgreet sddm gdm lightdm ;;
    bootloader) _cfg_enum "$v" systemd-boot grub limine ;;
    kernel) _cfg_enum "$v" gentoo-kernel-bin gentoo-kernel ;;
    kernel_version) _cfg_enum "$v" lts latest ;;
    nvidia_driver) _cfg_enum "$v" proprietary nouveau ;;
    network) _cfg_enum "$v" networkmanager dhcpcd networkd ;;
    audio) _cfg_enum "$v" pipewire none ;;
    power) _cfg_enum "$v" ppd tlp none ;;
    root) _cfg_enum "$v" password locked ;;
    privilege) _cfg_enum "$v" sudo doas ;;
    browser) _cfg_enum "$v" firefox-bin chromium none ;;
    luks_discard | keep_wifi | bluetooth | thermald | fwupd | sshd | binpkgs | tune | fonts_cjk | media_keys | explain | secure_boot | flatpak | printing | fingerprint)
      _cfg_enum "$v" yes no
      ;;
    wifi_ssid)
      if (($(_bytes "$v") > 32)) || [[ $v == *[[:cntrl:]]* ]]; then
        echo 'must be at most 32 bytes with no control characters'
        return 1
      fi
      ;;
    hostname)
      _cfg_re "$v" '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' 'must be 1 to 63 lowercase letters, digits and inner hyphens'
      ;;
    timezone)
      _cfg_re "$v" '^(UTC|[A-Z][A-Za-z]+(/[A-Za-z0-9_+-]+){1,2})$' 'must be UTC or Region/City, like Europe/Berlin'
      ;;
    locales)
      read -ra words <<< "$v"
      if ((${#words[@]} == 0)); then
        echo 'needs at least one locale, like en_US.UTF-8'
        return 1
      fi
      for w in "${words[@]}"; do _cfg_locale "$w" || return 1; done
      ;;
    lang) _cfg_locale "$v" ;;
    users)
      read -ra words <<< "$v"
      for w in "${words[@]}"; do _cfg_username "$w" || return 1; done
      if [[ $(printf '%s\n' "${words[@]}" | sort | uniq -d) ]]; then
        echo 'lists a user twice'
        return 1
      fi
      ;;
    user.*.admin | user.*.shell)
      w=${1#user.}
      _cfg_username "${w%.*}" || return 1
      case $1 in
        *.admin) _cfg_enum "$v" yes no ;;
        *) _cfg_enum "$v" bash zsh fish ;;
      esac
      ;;
    mirror)
      if [[ $v != cdn && $v != fastest ]]; then
        _cfg_re "$v" '^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/+-]*)?$' 'must be cdn, fastest or an https:// URL'
      fi
      ;;
    cflags)
      if [[ -z $v || $v == *[\"\'\`\$\\]* || $v == *[[:cntrl:]]* ]]; then
        echo "can't be empty or contain quotes, \$, backticks, backslashes or newlines"
        return 1
      fi
      ;;
    makeopts)
      if [[ $v != auto ]]; then
        _cfg_re "$v" '^-[A-Za-z0-9=.,-]+( +-[A-Za-z0-9=.,-]+)*$' 'must be auto or flags like -j8 -l8'
      fi
      ;;
    emerge_jobs) _cfg_re "$v" '^(auto|[1-9][0-9]{0,3})$' 'must be auto or a positive number' ;;
    packages)
      read -ra words <<< "$v"
      for w in "${words[@]}"; do
        _cfg_re "$w" "$(_cfg_atom_re)" "not a package atom like app-editors/vim or >=dev-lang/rust-1.80:0" || return 1
      done
      ;;
    *)
      echo 'unknown key'
      return 1
      ;;
  esac
}

_cfg_enum() { # VALUE CHOICE...
  local v=$1 c
  shift
  for c; do
    if [[ $v == "$c" ]]; then return 0; fi
  done
  printf 'must be one of: %s\n' "$*"
  return 1
}

_cfg_re() { # VALUE REGEX MESSAGE
  [[ $1 =~ $2 ]] && return 0
  printf '%s\n' "$3"
  return 1
}

_cfg_locale() {
  _cfg_re "$1" '^[a-z]{2,3}(_[A-Z]{2})?(\.[A-Za-z0-9-]+)?(@[a-z]+)?$' 'must be locales like en_US.UTF-8'
}

_cfg_username() {
  _cfg_re "$1" '^[a-z_][a-z0-9_-]{0,31}$' 'user names must be lowercase letters, digits, _ and -, starting with a letter or _' || return 1
  if [[ " ${GI_RESERVED_NAMES[*]} " == *" $1 "* || $1 == systemd-* ]]; then
    printf '%s is a system account name\n' "$1"
    return 1
  fi
}

# Portage atom: optional version operator, category/name, version, slot, repo. No shell characters.
_cfg_atom_re() {
  local name='[A-Za-z0-9+_][A-Za-z0-9+_.-]*/[A-Za-z0-9+_][A-Za-z0-9+_-]*'
  local ver='-[0-9][0-9.]*[a-z]?(_(alpha|beta|pre|rc|p)[0-9]*)*(-r[0-9]+)?\*?'
  printf '%s' "^(${name}|(<=|>=|<|>|=|~)${name}${ver})(:[A-Za-z0-9+_.*=/-]+)?(::[A-Za-z0-9_][A-Za-z0-9_-]*)?\$"
}

_cfg_default() { [[ -n ${CFG[$1]+x} ]] || CFG[$1]=$2; }

# True when /home gets a partition of its own.
cfg_home_part() { [[ ${CFG[home]:-root} == partition ]]; }

# The GiB the root filesystem needs at least: the system, and hibernation's swap file.
cfg_root_min() {
  local min=20
  if [[ ${CFG[desktop]:-none} != none ]]; then min=40; fi
  if [[ ${CFG[swap]:-} == hibernate && ${HW[ram_mib]:-} =~ ^[0-9]+$ ]]; then min=$((min + (HW[ram_mib] + 1023) / 1024)); fi
  echo "$min"
}

# True when the swap answer makes a swap file: file, or hibernate, which sizes it for hibernation.
cfg_swap_file() { [[ ${CFG[swap]:-} == file || ${CFG[swap]:-} == hibernate ]]; }

# Fills every key that isn't set yet, so a loaded config always wins. With ask, only the keys the
# questions don't ask: the rest stay unset, and the menus mark them [!] until they're answered.
cfg_defaults_apply() { # [ask]
  local u
  local -a users=() locales=()
  _cfg_default format 1
  _cfg_default disk ''
  _cfg_default wifi_ssid "${HW[wifi_ssid]:-}"
  _cfg_default users ''
  _cfg_default packages ''
  # Tuning knobs whose defaults suit almost everyone.
  _cfg_default mirror cdn
  _cfg_default cflags '-march=native -O2 -pipe'
  _cfg_default makeopts auto
  _cfg_default emerge_jobs auto
  read -ra users <<< "${CFG[users]}"
  for u in "${users[@]}"; do
    _cfg_default "user.$u.admin" yes
    _cfg_default "user.$u.shell" bash
  done
  [[ ${1:-} != ask ]] || return 0
  _cfg_default keymap us
  _cfg_default disk_mode wipe
  _cfg_default filesystem ext4
  _cfg_default home root
  _cfg_default root_size 80
  _cfg_default encryption none
  _cfg_default luks_discard yes
  _cfg_default swap zram
  _cfg_default init openrc
  _cfg_default desktop plasma
  _cfg_default gnome_variant light
  _cfg_default display_manager auto
  _cfg_default bootloader systemd-boot
  _cfg_default secure_boot no
  _cfg_default kernel gentoo-kernel-bin
  _cfg_default kernel_version lts
  _cfg_default nvidia_driver proprietary
  _cfg_default network networkmanager
  _cfg_default keep_wifi yes
  _cfg_default audio pipewire
  _cfg_default bluetooth "$(_cfg_yes_if "${HW[bluetooth]:-}")"
  if [[ ${HW[laptop]:-} == yes ]]; then _cfg_default power ppd; else _cfg_default power none; fi
  _cfg_default thermald no
  _cfg_default fwupd "$(_cfg_yes_if "${HW[laptop]:-}")"
  _cfg_default sshd no
  _cfg_default hostname gentoo
  _cfg_default timezone UTC
  _cfg_default locales en_US.UTF-8
  read -ra locales <<< "${CFG[locales]}"
  _cfg_default lang "${locales[0]:-}"
  _cfg_default root password
  _cfg_default privilege sudo
  _cfg_default binpkgs yes
  _cfg_default tune no
  _cfg_default browser firefox-bin
  _cfg_default fonts_cjk no
  _cfg_default media_keys no
  _cfg_default flatpak no
  _cfg_default printing no
  _cfg_default fingerprint no
  _cfg_default explain no
}

# The login screens DESKTOP can have: its own graphical one first, then the text one and none.
cfg_login_screens() { # DESKTOP
  case $1 in
    plasma) echo sddm tuigreet none ;;
    gnome) echo gdm tuigreet none ;;
    xfce | budgie | cinnamon) echo lightdm tuigreet none ;;
    none) echo none ;;
    *) echo gtkgreet tuigreet none ;;
  esac
}

# The login screen display_manager picks. auto, from older configs, is the full desktops' own
# graphical one and none for the window managers.
cfg_login_screen() {
  local dm=${CFG[display_manager]:-auto}
  if [[ $dm == auto ]]; then
    dm=$(cfg_login_screens "${CFG[desktop]:-none}")
    dm=${dm%% *}
    if [[ $dm == gtkgreet ]]; then dm=none; fi
  fi
  echo "$dm"
}

_cfg_yes_if() { if [[ $1 == yes ]]; then echo yes; else echo no; fi; }

# Reads key=value lines without ever sourcing them and reports every problem at once.
cfg_load() { # FILE
  local file=$1 line key value n=0 msg u
  local -a errors=() users=()
  local -A seen=()
  if [[ ! -f $file || ! -r $file ]]; then
    error "Can't read config file $file"
    return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'} # a file saved with Windows line endings
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    key=${line%%=*} value=${line#*=}
    if [[ $line != *=* || ! $key =~ ^[A-Za-z0-9_.-]+$ ]]; then
      errors+=("line $n: expected key=value")
    elif [[ -n ${seen[$key]:-} ]]; then
      errors+=("line $n: $key is set twice")
    else
      seen[$key]=1
      msg=$(_cfg_problem "$key" "$value")
      if [[ -n $msg ]]; then errors+=("line $n: $msg"); else CFG["$key"]=$value; fi
    fi
  done < "$file"
  read -ra users <<< "${CFG[users]:-}"
  for key in "${!seen[@]}"; do
    if [[ $key =~ ^user\.(.+)\.(admin|shell)$ ]]; then
      u=${BASH_REMATCH[1]}
      [[ " ${users[*]} " == *" $u "* ]] || errors+=("$key: $u is not in users")
    fi
  done
  if ((${#errors[@]})); then
    for msg in "${errors[@]}"; do error "$file: $msg"; done
    return 1
  fi
  log INFO "loaded config $file"
}

cfg_load_secrets() { # FILE
  local file=$1 owner=0 line key value n=0 msg
  local -a errors=()
  local -A seen=()
  if [[ ! -f $file || ! -r $file ]]; then
    error "Can't read secrets file $file"
    return 1
  fi
  if ((GI_TEST)); then owner=$EUID; fi
  if [[ $(stat -c '%u %a' -- "$file") != "$owner 600" ]]; then
    error "$file must be owned by root with mode 600 (chown root:root, chmod 600)"
    return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'} # else a file saved with Windows line endings puts a CR in every password
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    # Messages name the key only once it's known, so a stray password line is never echoed.
    if [[ $line != *=* ]]; then
      errors+=("line $n: expected key=value")
      continue
    fi
    key=${line%%=*} value=${line#*=}
    case $key in
      luks_passphrase | root_password | user.*.password | wifi_psk) ;;
      *)
        errors+=("line $n: unknown key")
        continue
        ;;
    esac
    msg=$(cfg_secret_validate "$key" "$value") || true
    if [[ -n ${seen[$key]:-} ]]; then msg="$key: is set twice"; fi
    seen[$key]=1
    if [[ -n $msg ]]; then errors+=("line $n: $msg"); else SECRET["$key"]=$value; fi
  done < "$file"
  if ((${#errors[@]})); then
    for msg in "${errors[@]}"; do error "$file: $msg"; done
    return 1
  fi
  log INFO "loaded secrets from $file"
}

# Prints "KEY: problem" and returns 1 when VALUE can't be that secret. Never echoes the value.
cfg_secret_validate() { # KEY VALUE
  local LC_ALL=C u # a Wi-Fi key is ASCII, so count and match bytes
  case $1 in
    wifi_psk)
      # Empty means an open network.
      if [[ -z $2 || $2 =~ ^[[:print:]]{8,63}$ || $2 =~ ^[0-9A-Fa-f]{64}$ ]]; then return 0; fi
      echo 'wifi_psk: must be 8 to 63 printable ASCII characters or 64 hex digits'
      return 1
      ;;
    user.*.password)
      u=${1#user.}
      if ! u=$(_cfg_username "${u%.password}"); then
        printf '%s: %s\n' "$1" "$u"
        return 1
      fi
      ;;
    luks_passphrase | root_password) ;;
    *)
      printf '%s: unknown secret\n' "$1"
      return 1
      ;;
  esac
  if [[ -z $2 ]]; then
    printf "%s: can't be empty\n" "$1"
    return 1
  fi
}

# Writes every non-secret key in table order, then the per-user keys. Returns 1 when it can't.
cfg_save() { # [FILE]
  local file=${1:-$GI_RUN_DIR/config} k u tmp='' s
  local -a users=()
  read -ra users <<< "${CFG[users]:-}"
  printf -v s '# gentooinstall %s config, saved %(%F %T)T\n' "$GI_VERSION" -1
  for k in "${GI_CFG_KEYS[@]}"; do
    if [[ -n ${CFG[$k]+x} ]]; then s+="$k=${CFG[$k]}"$'\n'; fi
  done
  for u in "${users[@]}"; do
    s+="user.$u.admin=${CFG[user.$u.admin]:-yes}"$'\n'"user.$u.shell=${CFG[user.$u.shell]:-bash}"$'\n'
  done
  # One write, so a full disk fails it; -T never moves the file into a directory named FILE.
  if tmp=$(mktemp -- "$file.XXXXXX") && printf '%s' "$s" > "$tmp" && mv -fT -- "$tmp" "$file"; then
    log INFO "config saved to $file"
    return 0
  fi
  if [[ -n $tmp ]]; then rm -f -- "$tmp"; fi
  log ERROR "couldn't save the config to $file"
  return 1
}

cfg_secrets_missing() { # [STEP_IDS...]
  local step u
  local -a users=()
  for step; do
    case $step in
      disk) if [[ ${CFG[encryption]:-} == luks2 ]]; then _cfg_need luks_passphrase; fi ;;
      system) if [[ ${CFG[root]:-} == password ]]; then _cfg_need root_password; fi ;;
      users)
        read -ra users <<< "${CFG[users]:-}"
        for u in "${users[@]}"; do _cfg_need "user.$u.password"; done
        ;;
      # Only NetworkManager gets the saved Wi-Fi network.
      network)
        if [[ ${CFG[network]:-networkmanager} == networkmanager && ${CFG[keep_wifi]:-} == yes && -n ${CFG[wifi_ssid]:-} ]]; then
          _cfg_need wifi_psk
        fi
        ;;
    esac
  done
}

_cfg_need() { [[ -n ${SECRET[$1]+x} ]] || printf '%s\n' "$1"; }

cfg_check_rules() {
  local k msg size u admins=0 failed=0
  local -a users=() locales=()
  for k in "${GI_CFG_KEYS[@]}"; do
    if ! msg=$(cfg_validate "$k" "${CFG[$k]-}"); then _cfg_rule error "$msg"; fi
  done
  read -ra users <<< "${CFG[users]:-}"
  read -ra locales <<< "${CFG[locales]:-}"
  if [[ -z ${CFG[disk]:-} ]]; then _cfg_rule error "disk: is required"; fi
  if ((${#users[@]} == 0)); then _cfg_rule error "users: needs at least one user"; fi
  for u in "${users[@]}"; do
    for k in "user.$u.admin" "user.$u.shell"; do
      if [[ -n ${CFG[$k]+x} ]] && ! msg=$(cfg_validate "$k" "${CFG[$k]}"); then _cfg_rule error "$msg"; fi
    done
    if [[ ${CFG[user.$u.admin]:-yes} == yes ]]; then admins=$((admins + 1)); fi
  done
  if [[ " ${locales[*]} " != *" ${CFG[lang]:-} "* ]]; then
    _cfg_rule error "lang must be one of the chosen locales"
  fi
  if [[ ${CFG[encryption]:-} == luks2 && ${CFG[bootloader]:-} == grub ]]; then
    _cfg_rule error "LUKS encryption needs systemd-boot or Limine in this version, so the kernel and initramfs sit on the unencrypted ESP."
  fi
  if [[ ${CFG[desktop]:-none} != none && -n ${CFG[disk]:-} ]]; then
    if ! size=$(hw_disk_size_bytes "${CFG[disk]}") || [[ ! $size =~ ^[0-9]+$ ]]; then
      _cfg_rule warn "Couldn't read the size of ${CFG[disk]}."
    elif ((size < 40 * 1024 ** 3)); then
      _cfg_rule error "A desktop needs a disk of at least 40 GiB."
    fi
  fi
  if cfg_home_part; then
    if [[ ${CFG[filesystem]:-} == btrfs ]]; then
      _cfg_rule error "On btrfs, /home is a subvolume of its own already; a /home partition needs ext4 or xfs."
    elif [[ ${CFG[root_size]:-} =~ ^[0-9]+$ ]] && ((CFG[root_size] < $(cfg_root_min))); then
      _cfg_rule error "The root filesystem needs at least $(cfg_root_min) GiB with these answers, and root_size is ${CFG[root_size]}."
    elif [[ ${CFG[disk_mode]:-wipe} == wipe && -n ${CFG[disk]:-} ]] && size=$(hw_disk_size_bytes "${CFG[disk]}") &&
      [[ $size =~ ^[0-9]+$ && ${CFG[root_size]:-} =~ ^[0-9]+$ ]] && ((size < (CFG[root_size] + 11) * 1024 ** 3)); then
      _cfg_rule error "A ${CFG[root_size]} GiB root, its 1 GiB boot partition and at least 10 GiB for /home don't fit on ${CFG[disk]}."
    fi
  fi
  local dm=${CFG[display_manager]:-auto} desktop=${CFG[desktop]:-none}
  if [[ $dm != auto && " $(cfg_login_screens "$desktop") " != *" $dm "* ]]; then
    _cfg_rule error "The $dm login screen doesn't go with desktop=$desktop; pick one of: $(cfg_login_screens "$desktop")."
  fi
  if [[ ${CFG[swap]:-} == hibernate && ${CFG[secure_boot]:-} == yes ]]; then
    _cfg_rule warn "Hibernation doesn't work while Secure Boot is on: the kernel's lockdown blocks it."
  fi
  if [[ ${CFG[network]:-} == networkd && ${CFG[init]:-} != systemd ]]; then
    _cfg_rule error "systemd-networkd needs systemd as the init system."
  fi
  if [[ ${CFG[root]:-} == locked ]] && ((admins == 0)); then
    _cfg_rule error "Locking root needs at least one admin user."
  fi
  if [[ ${CFG[desktop]:-none} != none && ${CFG[network]:-} != networkmanager ]]; then
    _cfg_rule warn "A desktop without NetworkManager has no network applet."
  fi
  if [[ ${CFG[secure_boot]:-} == yes && ${CFG[bootloader]:-} != systemd-boot ]]; then
    _cfg_rule error "Secure Boot needs systemd-boot in this version."
  elif [[ ${HW[secure_boot]:-} == on && ${CFG[secure_boot]:-} != yes ]]; then
    _cfg_rule error "Secure Boot is on. Set Secure Boot to yes in System, so the installer signs the bootloader and kernels, or turn it off in the firmware setup."
  fi
  local ram=${HW[ram_mib]:-}
  # MemTotal is 100 to 300 MiB under the installed RAM, so compare the rounded GiB the screen shows.
  if [[ $ram =~ ^[0-9]+$ ]] && (((ram + 512) / 1024 < 4)) &&
    [[ ${CFG[desktop]:-none} != none || ${CFG[kernel]:-} == gentoo-kernel ]]; then
    _cfg_rule warn "Less than 4 GiB of RAM: compiling the desktop or gentoo-kernel may run out of memory."
  fi
  return "$failed"
}

_cfg_rule() { # error|warn MESSAGE
  printf '%s: %s\n' "$1" "$2"
  if [[ $1 == error ]]; then failed=1; fi
}
