# shellcheck shell=bash
# Questions: the console keymap, the section hub, the review and the typed confirmation.

GI_Q_SECTIONS=(Keyboard Disk System Desktop Network Locale Users Packages Options)
declare -ga GI_Q_DISKS=()
# Secrets typed in this session; a keymap change makes them wrong, so they get asked again.
declare -gA GI_Q_TYPED=()
# 1 while questions_hub runs inside the compile preview step.
GI_Q_PREVIEW=0

questions_keymap() {
  # On --resume a config's keymap is the new system's, which gi_resume loads after the disk is unlocked.
  if [[ -n ${CFG[keymap]:-} ]] && ((!${GI_RESUME:-0} || GI_YES)); then
    run_cmd loadkeys "${CFG[keymap]}" || die "Couldn't load the keymap ${CFG[keymap]} from the config. Fix keymap there, or leave it out to pick one from the list." 2
    return 0
  fi
  # Unattended runs type nothing, and cfg_defaults_apply sets the keymap later.
  if ((GI_YES)); then return 0; fi
  local text=''
  # On --resume the saved config's keymap stays the new system's; this one only unlocks and types.
  if ((${GI_RESUME:-0})); then
    text="Pick the keyboard layout you chose when this install started. The disk passphrase and any passwords still needed are typed with it."
  fi
  until _q_keymap Quit "$text"; do _q_quit; done
}

questions_run() {
  if ((GI_YES)); then
    _q_unattended
    return 0
  fi
  _q_hub
}

questions_hub() {
  local GI_Q_PREVIEW=1
  _q_hub
}

_q_unattended() {
  local out k failed=0
  local -a missing=()
  mapfile -t GI_Q_DISKS < <(hw_disks)
  out=$(_q_check) || failed=1
  if [[ -n $out ]]; then info "$out"; fi
  mapfile -t missing < <(cfg_secrets_missing "${GI_STEPS[@]}")
  for k in "${missing[@]}"; do
    error "The --secrets file needs $k."
    failed=1
  done
  if ((failed)); then die "Fix the config before running with --yes. Nothing was changed." 2; fi
}

# --- Hub ---------------------------------------------------------------------

_q_hub() { # returns 0 to go on, 1 on back (compile preview only)
  local last=Install title="Install Gentoo" back=Quit ready="Review and install" text choice s n rc todo
  local -a items=() need=()
  text=$'Pick a section to change it. [!] still needs an answer.\nEnter always lands on the next [!], so you can just keep pressing it.'
  if ((GI_Q_PREVIEW)); then
    last=Continue title="Change answers" back=Back ready="Go on with the install"
    text=$'Change answers before the packages are installed.\nSettings marked (locked) can\'t change any more.'
  fi
  mapfile -t GI_Q_DISKS < <(hw_disks)
  while :; do
    items=() need=()
    for s in "${GI_Q_SECTIONS[@]}"; do
      n=$(_q_section_need "$s")
      if [[ -n $n ]]; then need+=("$s"); fi
      items+=("$s" "${n:-$(_q_summary "$s")}" "$(_q_section_help "$s")")
    done
    case ${#need[@]} in
      0) todo=$ready ;;
      1) todo="1 section needs an answer" ;;
      *) todo="${#need[@]} sections need an answer" ;;
    esac
    rc=0
    choice=$(ui_menu --ok Select --extra "Save config" --back "$back" "$title" "$text" "${need[0]:-$last}" \
      "${items[@]}" "$last" "$todo" "$last: check the answers, then go on") || rc=$?
    if ((rc == 3)); then
      _q_save_as
      continue
    fi
    if ((rc)); then
      if ((!GI_Q_PREVIEW)); then
        _q_quit
        continue
      fi
      # The compile preview keeps the answers on Back too, so they need the same checks.
      choice=$last
    fi
    case $choice in
      Keyboard) _q_edit keymap || true ;;
      "$last")
        if ((${#need[@]})); then
          ui_msg "$last" "These sections still need an answer: $(_q_join "${need[@]}")."
        elif _q_rules_ok; then
          if ((GI_Q_PREVIEW)); then return "$rc"; fi
          if _q_review; then return 0; fi
        fi
        ;;
      *) _q_section "$choice" ;;
    esac
  done
}

_q_section_help() {
  case $1 in
    Keyboard) echo "Keyboard: the console layout every password is typed with" ;;
    Disk) echo "Disk: the disk to erase, filesystem, encryption, swap" ;;
    System) echo "System: init system, kernel, bootloader" ;;
    Desktop) echo "Desktop: desktop, login screen, audio, Bluetooth, power, browser, fonts" ;;
    Network) echo "Network: network manager, Wi-Fi, hostname, SSH" ;;
    Locale) echo "Locale: timezone, languages, keyboard" ;;
    Users) echo "Users: accounts, passwords, root, sudo or doas" ;;
    Packages) echo "Packages: binary packages, extra packages, compiler settings, mirror" ;;
    Options) echo "Options: explain mode, firmware updates, thermald" ;;
  esac
}

_q_summary() { # SECTION: one line for the hub
  local wifi='' extra='' audio=${CFG[audio]#none} browser=''
  case $1 in
    Keyboard) printf '%s' "${CFG[keymap]}" ;;
    Disk) printf '%s, %s' "$(_q_disk_name)" "$(_q_layout)" ;;
    System) _q_join "${CFG[init]}" "${CFG[kernel]}" "${CFG[bootloader]}" ;;
    Desktop)
      # Part H's rules, so the hub says what the desktop and hardware steps will install.
      if [[ $audio == pipewire ]] && ! hardware_pipewire; then audio="ALSA only"; fi
      if [[ ${CFG[desktop]} != none ]]; then browser=${CFG[browser]#none}; fi
      _q_join "${CFG[desktop]/#none/console only}" "$audio" "$(_q_on bluetooth Bluetooth)" \
        "${CFG[power]#none}" "$browser"
      ;;
    Network)
      if [[ ${CFG[keep_wifi]} == yes && ${CFG[network]} == networkmanager && -n ${CFG[wifi_ssid]} ]]; then
        wifi="keep Wi-Fi \"${CFG[wifi_ssid]}\""
      fi
      _q_join "${CFG[network]}" "${CFG[hostname]}" "$wifi" "$(_q_on sshd sshd)"
      ;;
    Locale) _q_join "${CFG[timezone]}" "${CFG[lang]}" ;;
    Users)
      if [[ ${CFG[root]} == locked ]]; then extra="root locked"; fi
      _q_join "${CFG[users]// /, }" "$extra" "${CFG[privilege]}"
      ;;
    Packages)
      local -a pkgs=()
      read -ra pkgs <<< "${CFG[packages]}"
      if ((${#pkgs[@]})); then extra="${#pkgs[@]} extra"; fi
      _q_join "$(if [[ ${CFG[binpkgs]} == yes ]]; then echo binary packages; else echo source only; fi)" \
        "$(_q_on tune tuned)" "$extra"
      ;;
    Options) _q_join "explain mode $(if [[ ${CFG[explain]} == yes ]]; then echo on; else echo off; fi)" \
      "$(_q_on fwupd fwupd)" "$(_q_on thermald thermald)" ;;
  esac
}

_q_section_need() { # SECTION: prints the first "[!] ..." in it
  local key label help n
  while IFS=$'\t' read -r key label help; do
    n=$(_q_need "$key")
    if [[ -n $n ]]; then
      printf '%s' "$n"
      return 0
    fi
  done < <(_q_keys "$1")
}

_q_save_as() {
  local f
  f=$(ui_input "Save config" "Save every answer except passwords to this file. Use it later with --config." \
    /root/gentooinstall.conf) || return 0
  # cfg_save with no file name writes the installer's own config instead.
  if [[ -z $f ]]; then return 0; fi
  if cfg_save "$f" 2> /dev/null; then
    ui_msg "Save config" "Saved to $f."
  else
    ui_msg "Save config" "Couldn't save to $f."
  fi
}

_q_quit() {
  if ui_yesno --defaultno "Quit" "Quit without installing? Nothing on the disks has been changed."; then
    log INFO "quit at the questions"
    exit 130
  fi
}

# --- Sections ----------------------------------------------------------------

_q_row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

_q_keys() { # SECTION: prints KEY<TAB>LABEL<TAB>HELP for each setting it shows
  local u
  local -a users=()
  case $1 in
    Keyboard) _q_row keymap Keymap "The console keyboard layout" ;;
    Disk)
      _q_row disk Disk "The disk to erase and install Gentoo on"
      _q_row filesystem Filesystem "The filesystem for the root partition"
      _q_row encryption Encryption "Encrypt the root partition with a passphrase"
      if [[ ${CFG[encryption]} == luks2 ]]; then
        _q_row luks_discard "TRIM through LUKS" "Let the SSD know which blocks are free"
      fi
      _q_row swap Swap "Where memory goes when RAM is full"
      ;;
    System)
      _q_row init "Init system" "What starts the services at boot"
      _q_row kernel Kernel "A prebuilt kernel, or the same one compiled here"
      _q_row bootloader Bootloader "What starts the kernel"
      if [[ " ${HW[gpus]:-} " == *" nvidia "* ]]; then
        _q_row nvidia_driver "NVIDIA driver" "The driver for the NVIDIA graphics card"
      fi
      ;;
    Desktop)
      _q_row desktop Desktop "The graphical desktop or window manager, or console only"
      if [[ ${CFG[desktop]} == gnome ]]; then
        _q_row gnome_variant "GNOME variant" "Just the GNOME desktop, or GNOME with its apps"
      fi
      # The window managers have no login screen; they start from the console.
      if [[ -n $(_q_login_screen) ]]; then
        _q_row display_manager "Login screen" "A graphical login screen, or log in on the console"
      fi
      _q_row audio Audio "The sound server"
      _q_row bluetooth Bluetooth "Bluetooth support"
      _q_row power Power "Battery and power-saving modes"
      # step_desktop_packages installs neither without a desktop.
      if [[ ${CFG[desktop]} != none ]]; then
        _q_row browser Browser "The web browser to install"
        _q_row fonts_cjk "CJK fonts" "Fonts for Chinese, Japanese and Korean"
      fi
      if [[ -n $(_q_media_keys) ]]; then
        _q_row media_keys "Media keys" "Programs the default config's media keys call"
      fi
      ;;
    Network)
      _q_row network "Network manager" "What connects the new system to the network"
      # Only NetworkManager gets the saved network; the others would never use the key.
      if [[ ${CFG[network]} == networkmanager && -n ${CFG[wifi_ssid]} ]]; then
        _q_row keep_wifi "Keep Wi-Fi" "Save the live session's Wi-Fi network in the new system"
      fi
      _q_row hostname Hostname "The machine's name on the network"
      _q_row sshd "SSH server" "Log in from other machines over SSH"
      ;;
    Locale)
      _q_row timezone Timezone "Region/City, like Europe/Berlin, or UTC"
      _q_row locales Locales "The languages and formats to generate"
      _q_row lang LANG "The system language, one of the locales"
      _q_row keymap Keymap "The console keyboard layout"
      ;;
    Users)
      read -ra users <<< "${CFG[users]}"
      for u in "${users[@]}"; do
        _q_row "user.$u" "$u" "Change the password, admin rights or shell of $u, or remove $u"
      done
      _q_row adduser "Add a user" "Create another user account"
      _q_row root Root "Give root a password, or lock it"
      _q_row privilege "Privilege tool" "How admin users run commands as root"
      ;;
    "User "*)
      u=${1#User }
      # Nothing once the user is removed, which closes the submenu.
      if [[ " ${CFG[users]} " == *" $u "* ]]; then
        _q_row "user.$u.password" Password "Type a new password for $u"
        _q_row "user.$u.admin" Admin "Admins can run commands as root"
        _q_row "user.$u.shell" Shell "The login shell"
        _q_row "remove.$u" Remove "Delete $u from the list"
      fi
      ;;
    Packages)
      _q_row binpkgs "Binary packages" "Download prebuilt packages instead of compiling"
      _q_row packages "Extra packages" "More packages to install, as Portage atoms"
      _q_row tune "Tune for this machine" "CPU and GPU settings for this machine only"
      _q_row cflags "Compiler flags" "COMMON_FLAGS for packages built here"
      _q_row makeopts MAKEOPTS "How many compiler jobs run at once"
      _q_row emerge_jobs "Emerge jobs" "How many packages emerge handles at once"
      _q_row mirror Mirror "Where to download Gentoo files from"
      ;;
    Options)
      _q_row explain "Explain mode" "Explain each step and show each command"
      _q_row fwupd "Firmware updates" "Device firmware updates with fwupd"
      if [[ ${HW[cpu_vendor]:-} == intel ]]; then
        _q_row thermald thermald "Intel's thermal daemon"
      fi
      ;;
  esac
}

_q_section() { # SECTION: the submenu of one section's settings
  local s=$1 def choice row key label help
  local -a rows=() items=()
  while :; do
    mapfile -t rows < <(_q_keys "$s")
    if ((${#rows[@]} == 0)); then return 0; fi
    items=() def=''
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r key label help <<< "$row"
      if [[ -z $def && -n $(_q_need "$key") ]]; then def=$label; fi
      items+=("$label" "$(_q_value "$key")" "$help")
    done
    choice=$(ui_menu --ok Select "$s" "Pick a setting to change it." "${def:-Done}" \
      "${items[@]}" Done "Go back" "Return to the previous menu") || return 0
    if [[ $choice == Done ]]; then return 0; fi
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r key label help <<< "$row"
      if [[ $label == "$choice" ]]; then _q_edit "$key" || true; fi
    done
  done
}

_q_need() { # KEY: prints "[!] why" when KEY still needs an answer
  local k=$1 u=${1#user.}
  u=${u%%.*}
  case $k in
    disk)
      if [[ -z ${CFG[disk]} ]]; then
        printf '[!] not set'
      elif ! cfg_is_locked disk && ! _q_disk_row > /dev/null; then
        printf '[!] not found, pick again'
      fi
      ;;
    encryption)
      # Once the disk is encrypted, the passphrase isn't needed again.
      if [[ ${CFG[encryption]} == luks2 ]] && _q_no_secret luks_passphrase && ! cfg_is_locked encryption; then
        printf '[!] LUKS passphrase not set'
      fi
      ;;
    # _q_keys shows this row only with NetworkManager, the one network setup that uses the key.
    keep_wifi)
      if [[ ${CFG[keep_wifi]} == yes && -n ${CFG[wifi_ssid]} ]] && _q_no_secret wifi_psk; then
        printf '[!] Wi-Fi key not set'
      fi
      ;;
    root) if [[ ${CFG[root]} == password ]] && _q_no_secret root_password; then printf '[!] root password not set'; fi ;;
    adduser) if [[ -z ${CFG[users]} ]]; then printf '[!] none yet'; fi ;;
    user.*.password) if _q_no_secret "$k"; then printf '[!] not set'; fi ;;
    user.*.*) ;;
    user.*) if _q_no_secret "user.$u.password"; then printf '[!] %s has no password' "$u"; fi ;;
  esac
}

# True when the hub must ask for secret KEY. In the compile preview the runner asks once the step ends.
_q_no_secret() { [[ -z ${SECRET[$1]+x} ]] && ((!GI_Q_PREVIEW)); }

# The login screen display_manager=auto installs with the desktop, as part H's step does; nothing
# for the window managers and the console.
_q_login_screen() {
  case ${CFG[desktop]} in
    plasma) echo SDDM ;;
    gnome) echo GDM ;;
    xfce | budgie | cinnamon) echo LightDM ;;
  esac
}

# What media_keys=yes installs, as part H's step does: the programs the window manager's shipped
# config calls that nothing else installs. Nothing for the others; the full desktops have their own.
_q_media_keys() {
  case ${CFG[desktop]} in
    sway) echo "Sway's default config calls brightnessctl, playerctl and grim for the brightness, player and Print keys. Installing them builds 3 small packages from source." ;;
    hyprland) echo "Hyprland's default config calls brightnessctl and playerctl for the brightness and player keys. Installing them builds 2 small packages from source." ;;
    niri) echo "Niri's default config calls brightnessctl and playerctl for the brightness and player keys. Installing them builds 2 small packages from source." ;;
  esac
}

_q_value() { # KEY: the current value as the menus show it
  local k=$1 v u=${1#user.}
  v=$(_q_need "$k")
  if [[ -z $v ]]; then
    case $k in
      disk) v=$(_q_disk_label) ;;
      display_manager)
        v=${CFG[display_manager]}
        if [[ $v == auto ]]; then v+=" ($(_q_login_screen))"; fi
        ;;
      audio)
        v=${CFG[audio]}
        if [[ $v == pipewire ]] && ! hardware_pipewire; then v="ALSA only: PipeWire needs a desktop on OpenRC"; fi
        ;;
      keep_wifi)
        v=${CFG[keep_wifi]}
        if [[ $v == yes ]]; then v+=", \"${CFG[wifi_ssid]}\""; fi
        ;;
      nvidia_driver)
        v=${CFG[nvidia_driver]}
        case $v:$(graphics_nvidia_branch) in
          *:none) v="nouveau (card too old for NVIDIA's driver)" ;;
          proprietary:580) v+=" (580 series)" ;;
        esac
        ;;
      user.*.password)
        v="set"
        if [[ -z ${SECRET[$k]+x} ]]; then v="asked when the compile preview ends"; fi
        ;;
      user.*.*) v=${CFG[$k]:-} ;;
      user.*) v=$(_q_join "$(if [[ ${CFG[user.$u.admin]:-yes} == yes ]]; then echo admin; fi)" "${CFG[user.$u.shell]:-bash}") ;;
      remove.*) v="Delete this user" ;;
      adduser) ;;
      *) v=${CFG[$k]:-none} ;;
    esac
  fi
  if cfg_is_locked "$k"; then v+=" (locked)"; fi
  printf '%s' "$v"
}

_q_join() { # WORD...: joins the non-empty ones with ", "
  local a out=''
  for a; do
    if [[ -n $a ]]; then out+=${out:+, }$a; fi
  done
  printf '%s' "$out"
}

_q_on() { if [[ ${CFG[$1]} == yes ]]; then printf '%s' "$2"; fi; }

_q_hw_yes() { if [[ ${HW[$1]:-} == yes ]]; then echo yes; else echo no; fi; }

# --- Editors -----------------------------------------------------------------

_q_edit() { # KEY: opens the editor for one setting; returns 1 on back
  local key=$1 u=${1#user.} old rec
  local -a locs=()
  u=${u%%.*}
  if cfg_is_locked "$key"; then
    ui_msg "Locked" "$key can't change once the disk step has started."
    return 0
  fi
  case $key in
    keymap)
      old=${CFG[keymap]:-}
      # The initramfs asks for the passphrase with the new layout.
      if cfg_is_locked encryption && [[ ${CFG[encryption]} == luks2 ]] &&
        ! ui_yesno --defaultno "Keyboard layout" "The disk passphrase was typed with the $old layout. If that layout didn't match your keyboard, the passphrase isn't what the keys showed, and it won't unlock the disk at boot with a new layout. Change the layout anyway?"; then
        return 0
      fi
      _q_keymap Back || return 1
      if [[ ${CFG[keymap]} != "$old" ]]; then _q_keymap_changed; fi
      ;;
    disk) _q_disk ;;
    filesystem)
      _q_radio filesystem "Root filesystem" "" ext4 \
        ext4 "The standard Linux filesystem." "Mature and simple; the safe choice." \
        xfs "Fast with large files." "Can grow later but never shrink." \
        btrfs "Snapshots and compression." "Uses subvolumes for /, /home, logs, cache and snapshots."
      ;;
    encryption)
      _q_radio encryption "Encryption" "" none \
        none "No encryption." "Anyone who has the disk can read its files." \
        luks2 "LUKS2 on the root partition." "You type a passphrase at every boot; the boot partition stays unencrypted." ||
        return 1
      if [[ ${CFG[encryption]} == luks2 ]]; then
        _q_secret luks_passphrase "LUKS passphrase" "Type the passphrase for the encrypted disk. You'll type it at every boot, with the ${CFG[keymap]} keyboard layout. If you lose it, the data is gone."
      fi
      ;;
    luks_discard)
      _q_radio luks_discard "TRIM through LUKS" "" yes \
        yes "Pass TRIM through to the SSD." "Keeps the SSD fast; it reveals which blocks are free, which is fine for a laptop." \
        no "Don't pass TRIM through." "Hides which blocks are in use, at some cost to SSD speed and wear."
      ;;
    swap)
      _q_radio swap "Swap" "" zram \
        zram "Compressed swap in RAM." "Fast and needs no disk space; uses up to half of RAM." \
        file "A swap file on the root filesystem." "Sized like RAM, up to 8 GiB." \
        none "No swap." "Programs get stopped when RAM runs out."
      ;;
    init)
      _q_radio init "Init system" "" openrc \
        openrc "Gentoo's own init." "Simple and Gentoo's default; switching later means rebuilding many packages." \
        systemd "What most other distros use." "Brings journald, timers and systemd-networkd." ||
        return 1
      if [[ ${CFG[init]} != systemd && ${CFG[network]} == networkd ]]; then
        cfg_set network networkmanager
        ui_msg "Network manager" "systemd-networkd needs systemd, so the network manager is now NetworkManager."
      fi
      ;;
    kernel)
      _q_radio kernel "Kernel" "" gentoo-kernel-bin \
        gentoo-kernel-bin "Prebuilt distribution kernel." "Installs in minutes." \
        gentoo-kernel "The same kernel, compiled here." "Takes an hour or more to build."
      ;;
    bootloader)
      _q_radio bootloader "Bootloader" "" systemd-boot \
        systemd-boot "A simple UEFI boot menu." "Works with encryption." \
        grub "The classic bootloader." "More features, but can't be used with encryption in this version." \
        limine "A small, fast UEFI boot menu." "Works with encryption. A testing package; building it adds 670 MB of LLVM."
      ;;
    nvidia_driver)
      # Part H's detection, so the menu says what step_graphics_portage will do.
      local branch help="Best performance; its kernel module is built here."
      branch=$(graphics_nvidia_branch)
      if [[ $branch == none ]]; then
        ui_msg "NVIDIA driver" "This NVIDIA card is a Kepler model or older. No NVIDIA driver in Gentoo builds for current kernels, so it gets the open nouveau driver."
        return 0
      fi
      if [[ $branch == 580 ]]; then help="The 580 series, the last one for this card; its kernel module is built here."; fi
      _q_radio nvidia_driver "NVIDIA driver" "" proprietary \
        proprietary "NVIDIA's own driver." "$help" \
        nouveau "The open source driver." "Works out of the box but is slower, especially on new cards."
      ;;
    desktop)
      _q_radio desktop "Desktop" "" plasma \
        plasma "KDE Plasma." "A full desktop with a taskbar and start menu, and the SDDM login screen." \
        gnome "GNOME." "A clean, simple desktop with the GDM login screen." \
        xfce "Xfce." "A light, classic desktop with the LightDM login screen." \
        budgie "Budgie, with LightDM." "From a third-party overlay that Gentoo doesn't review. Builds from source." \
        cinnamon "Cinnamon." "Linux Mint's classic desktop with the LightDM login screen." \
        i3 "i3, tiling for X11." "A window manager with a bar. No login screen: start it from the console." \
        sway "Sway, tiling for Wayland." "Like i3, on Wayland. No login screen: start it from the console." \
        hyprland "Hyprland, tiling for Wayland." "From a third-party overlay that Gentoo doesn't review. Builds from source." \
        niri "Niri, scrolling tiles, Wayland." "From GURU, a user overlay that Gentoo doesn't review. Builds from source." \
        mangowm "MangoWM, tiling for Wayland." "From GURU, a user overlay that Gentoo doesn't review. Builds from source." \
        dwm "dwm, minimal tiling for X11." "Configured by rebuilding it. No login screen: start it from the console." \
        dwl "dwl, dwm for Wayland." "Configured by rebuilding it. No login screen: start it from the console." \
        none "Console only." "No graphical desktop."
      ;;
    gnome_variant)
      _q_radio gnome_variant "GNOME variant" "" light \
        light "Just the desktop." "gnome-base/gnome-light: the shell, settings and a few tools." \
        full "GNOME with its apps." "gnome-base/gnome: the whole set of GNOME applications."
      ;;
    display_manager)
      _q_radio display_manager "Login screen" "" auto \
        auto "A graphical login screen." "SDDM with Plasma, GDM with GNOME, LightDM with Xfce, Budgie and Cinnamon." \
        none "Log in on the console." "Start the desktop yourself after a text login."
      ;;
    audio)
      _q_radio audio "Audio" "" pipewire \
        pipewire "PipeWire." "Handles speakers, headphones, Bluetooth audio and screen sharing." \
        none "No sound server." "Only the bare ALSA drivers. Screen sharing on Wayland needs PipeWire."
      ;;
    bluetooth)
      _q_radio bluetooth "Bluetooth" "" "$(_q_hw_yes bluetooth)" \
        yes "Bluetooth on." "Installs BlueZ and starts the Bluetooth service." \
        no "No Bluetooth." "Leaves Bluetooth support out."
      ;;
    power)
      rec=none
      if [[ ${HW[laptop]:-} == yes ]]; then rec=ppd; fi
      _q_radio power "Power" "" "$rec" \
        ppd "power-profiles-daemon." "Power saver, balanced and performance modes in the desktop's battery menu." \
        tlp "TLP." "Many battery settings to tune; replaces power-profiles-daemon." \
        none "No power management." "Fine for desktop PCs."
      ;;
    browser)
      _q_radio browser "Browser" "" firefox-bin \
        firefox-bin "Firefox, prebuilt by Mozilla." "Installs in seconds." \
        chromium "Chromium." "The open source base of Chrome; the compile preview shows if it builds here." \
        none "No browser." "Install one later if you like."
      ;;
    fonts_cjk)
      _q_radio fonts_cjk "CJK fonts" "" no \
        no "Skip them." "Latin, Greek and Cyrillic text still shows fine." \
        yes "Add Chinese, Japanese and Korean fonts." "media-fonts/noto-cjk, a large download."
      ;;
    media_keys)
      local help="Builds them from source." vol="The volume keys work either way."
      # Niri comes from GURU already; for sway and Hyprland brightnessctl adds it.
      if [[ ${CFG[desktop]} != niri ]]; then help="brightnessctl is from GURU, a user overlay that Gentoo doesn't review."; fi
      # Their pactl and wpctl need the sound server.
      if [[ ${CFG[audio]} != pipewire ]]; then vol="With Audio set to none, the volume keys do nothing either way."; fi
      _q_radio media_keys "Media keys" "$(_q_media_keys) $vol" no \
        no "Leave them out." "Those keys do nothing until you install the programs." \
        yes "Install them." "$help"
      ;;
    network)
      local -a nd=()
      if [[ ${CFG[init]} == systemd ]]; then nd=(networkd "systemd-networkd." "Wired DHCP only, built into systemd."); fi
      _q_radio network "Network manager" "" networkmanager \
        networkmanager "NetworkManager." "Wi-Fi and wired, with an applet in the desktop." \
        dhcpcd "dhcpcd." "Wired networks only, nothing else." "${nd[@]}"
      ;;
    keep_wifi)
      _q_radio keep_wifi "Keep Wi-Fi" "" yes \
        yes "Save \"${CFG[wifi_ssid]}\" in the new system." "It connects to this network on first boot." \
        no "Don't save it." "Connect again after the first boot." ||
        return 1
      # A key from the live session or the secrets file is kept; an open or typed one can change.
      if [[ ${CFG[keep_wifi]} == yes ]] && [[ -z ${SECRET[wifi_psk]:-} || -n ${GI_Q_TYPED[wifi_psk]:-} ]]; then
        # ui_password_twice refuses an empty value, and an open network has no key. In the compile
        # preview the runner asks both questions, so _q_secret only drops the key.
        if ((!GI_Q_PREVIEW)) && ui_yesno --defaultno "Wi-Fi key" "Is ${CFG[wifi_ssid]} an open network, with no key?"; then
          SECRET[wifi_psk]=''
          unset 'GI_Q_TYPED[wifi_psk]'
        else
          _q_secret wifi_psk "Wi-Fi key" "Type the key for \"${CFG[wifi_ssid]}\"."
        fi
      fi
      ;;
    hostname)
      _q_input hostname "Hostname" "The machine's name on the network: lowercase letters, digits and hyphens, like laptop."
      ;;
    sshd)
      _q_radio sshd "SSH server" "" no \
        no "No SSH server." "Nobody can log in over the network." \
        yes "Start an SSH server." "Log in from another machine; root login stays off."
      ;;
    timezone)
      _q_input timezone "Timezone" "Type Region/City, like Europe/Berlin, or UTC. The live system has no zone list, so the name is checked against the stage3 later."
      ;;
    locales)
      _q_input locales "Locales" "Type one or more locales, separated by spaces, like en_US.UTF-8 de_DE.UTF-8. They're checked against the stage3 later." ||
        return 1
      # Split like cfg_check_rules does: the value may hold tabs or a leading space.
      read -ra locs <<< "${CFG[locales]}"
      if [[ " ${locs[*]} " != *" ${CFG[lang]} "* ]]; then cfg_set lang "${locs[0]}"; fi
      ;;
    lang)
      local -a args=()
      read -ra locs <<< "${CFG[locales]}"
      for old in "${locs[@]}"; do args+=("$old" "Use $old." "Messages, dates and numbers follow $old."); done
      _q_radio lang "System language" "LANG for the new system, picked from the locales." '' "${args[@]}"
      ;;
    root)
      _q_radio root "Root account" "" password \
        password "Root gets a password." "You can log in as root on the console." \
        locked "Lock root." "Admin users use sudo or doas instead; needs at least one admin." ||
        return 1
      if [[ ${CFG[root]} == password ]]; then
        _q_secret root_password "Root password" "Type a password for root."
      fi
      ;;
    privilege)
      _q_radio privilege "Privilege tool" "" sudo \
        sudo "sudo." "The usual tool; admins are in the wheel group." \
        doas "doas." "A smaller, simpler alternative to sudo."
      ;;
    adduser) _q_user_add ;;
    user.*.password) _q_secret "$key" "Password for $u" "Type a password for $u." ;;
    user.*.admin)
      _q_radio "$key" "Admin" "Can $u run commands as root?" yes \
        yes "Admin." "In the wheel group, so $u can use sudo or doas." \
        no "Regular user." "Can't run commands as root."
      ;;
    user.*.shell)
      # dialog shows an item's help on one line, cut at the screen width; the question text wraps.
      _q_radio "$key" "Shell" "The login shell for $u. Fish, as a login shell, doesn't read /etc/profile.env, so it misses system variables set through /etc/env.d (Gentoo bug 545830); the installer adds only the keyboard layout ones." bash \
        bash "Bash." "The standard shell." \
        zsh "Zsh." "Bash-like, with more completion and prompt features." \
        fish "Fish. Friendly, not Bash-compatible." "No binary package: builds from source with a Rust toolchain, about 200 MB."
      ;;
    user.*) _q_section "User $u" ;;
    remove.*)
      u=${key#remove.}
      if ui_yesno --defaultno "Remove $u" "Remove the user $u?"; then _q_user_remove "$u"; fi
      ;;
    binpkgs)
      _q_radio binpkgs "Binary packages" "" yes \
        yes "Use Gentoo's binary packages." "Most packages download instead of compiling; a desktop installs in minutes." \
        no "Build everything from source." "A desktop then takes many hours."
      ;;
    packages)
      _q_input packages "Extra packages" "Package atoms separated by spaces, like app-editors/vim dev-vcs/git. The compile preview checks them once the package tree is downloaded."
      ;;
    tune)
      _q_radio tune "Tune for this machine" "" no \
        no "Keep the generic settings." "They match the binary packages, so almost nothing compiles." \
        yes "Tune for this CPU and GPU." "Sets CPU_FLAGS_X86 and VIDEO_CARDS for this machine; some packages then build from source."
      ;;
    cflags)
      _q_input cflags "Compiler flags" "COMMON_FLAGS for packages built here. The default, -march=native -O2 -pipe, suits almost everyone."
      ;;
    makeopts)
      _q_input makeopts "MAKEOPTS" "Type auto to pick from RAM and CPU threads, or flags like -j8 -l8."
      ;;
    emerge_jobs)
      _q_input emerge_jobs "Emerge jobs" "Type auto, or how many packages emerge may handle at once, like 4."
      ;;
    mirror) _q_mirror ;;
    explain)
      _q_radio explain "Explain mode" "" no \
        no "Quiet install." "Shows the steps and their progress." \
        yes "Explain each step." "Before each step, says why and links the Handbook, and shows each command as it runs."
      ;;
    fwupd)
      _q_radio fwupd "Firmware updates" "" "$(_q_hw_yes laptop)" \
        yes "Install fwupd." "Updates laptop and device firmware from the LVFS." \
        no "No fwupd." "Update firmware some other way."
      ;;
    thermald)
      _q_radio thermald "thermald" "" no \
        no "No thermald." "The kernel's own thermal control is enough for most machines." \
        yes "Install thermald." "Intel's thermal daemon; can keep some Intel laptops cooler."
      ;;
  esac
}

# Runs cfg_set in a subshell, so nothing changes, and shows its error.
_q_try() { # KEY VALUE
  local msg
  msg=$(cfg_set "$1" "$2" 2>&1) && return 0
  ui_msg "Try again" "$msg"
  return 1
}

_q_set() { _q_try "$1" "$2" && cfg_set "$1" "$2"; }

_q_radio() { # KEY TITLE TEXT RECOMMENDED [TAG ITEM HELP]...
  local key=$1 title=$2 text=$3 rec=$4 v def=''
  local -a first=() rest=()
  shift 4
  while (($#)); do
    if [[ $1 == "$rec" ]]; then first=("$1" "$2 Recommended." "$3"); else rest+=("$1" "$2" "$3"); fi
    if [[ $1 == "${CFG[$key]-}" ]]; then def=$1; fi
    shift 3
  done
  # A value not on offer (a config's lang outside its locales) would leave nothing selected.
  if [[ -z $def ]]; then def=${first[0]:-${rest[0]}}; fi
  while :; do
    v=$(ui_radio "$title" "$text" "$def" "${first[@]}" "${rest[@]}") || return 1
    if _q_set "$key" "$v"; then return 0; fi
  done
}

_q_input() { # KEY TITLE TEXT [DEFAULT]
  local v
  while :; do
    v=$(ui_input "$2" "$3" "${4-${CFG[$1]-}}") || return 1
    if _q_set "$1" "$v"; then return 0; fi
  done
}

_q_secret() { # KEY TITLE TEXT
  local v msg text="You'll type it when you choose Install in the compile preview."
  # The compile preview runs this in its step's subshell, which loses SECRET; the runner asks instead.
  if ((GI_Q_PREVIEW)); then
    if [[ -z ${SECRET[$1]+x} ]]; then
      ui_msg "$2" "$text"
    elif ! ui_yesno --defaultno "$2" "Change it? $text"; then
      return 1
    fi
    unset 'SECRET[$1]' 'GI_Q_TYPED[$1]'
    return 0
  fi
  while :; do
    v=$(ui_password_twice "$2" "$3") || return 1
    if ! msg=$(cfg_secret_validate "$1" "$v"); then
      ui_msg "$2" "It ${msg#*: }."
      continue
    fi
    if [[ $1 != wifi_psk ]] && ((${#v} < 16)) &&
      ! ui_yesno "$2" "$(_q_short_text "It's")"$'\n\n'"Keep it anyway? Choose No to type another."; then
      continue
    fi
    SECRET[$1]=$v
    GI_Q_TYPED[$1]=1
    return 0
  done
}

_q_short_text() { printf '%s shorter than the 16 characters the Handbook suggests.' "$1"; }

_q_mirror() {
  local v cur=${CFG[mirror]}
  if [[ $cur == https://* ]]; then cur=custom; fi
  v=$(ui_radio "Mirror" "" "$cur" \
    cdn "Gentoo's CDN. Recommended." "https://distfiles.gentoo.org, fast from most places." \
    fastest "The fastest mirrors." "Found by mirrorselect on the live system; can take several minutes." \
    custom "A mirror you type." "Any https:// Gentoo mirror.") || return 1
  if [[ $v != custom ]]; then
    _q_set mirror "$v"
    return
  fi
  cur=${CFG[mirror]}
  if [[ $cur != https://* ]]; then cur=https://; fi
  _q_input mirror "Mirror URL" "Type the mirror's https:// address, like https://mirror.example.org/gentoo." "$cur"
}

_q_user_add() {
  local n
  while :; do
    n=$(ui_input "Add a user" "Type a user name: lowercase letters, digits, _ and -, starting with a letter or _." '') ||
      return 1
    # The per-user key checks the name by itself, before it joins the list.
    _q_try "user.$n.admin" yes || continue
    if _q_set users "${CFG[users]:+${CFG[users]} }$n"; then break; fi
  done
  cfg_set "user.$n.admin" yes
  cfg_set "user.$n.shell" bash
  _q_secret "user.$n.password" "Password for $n" "Type a password for $n."
}

_q_user_remove() { # NAME
  local u w out=''
  local -a users=()
  read -ra users <<< "${CFG[users]}"
  for w in "${users[@]}"; do
    if [[ $w != "$1" ]]; then out+=${out:+ }$w; fi
  done
  cfg_set users "$out"
  u=$1
  unset 'CFG[user.$u.admin]' 'CFG[user.$u.shell]' 'SECRET[user.$u.password]' 'GI_Q_TYPED[user.$u.password]'
}

# --- Keymap ------------------------------------------------------------------

_q_keymap() { # BACK_LABEL [TEXT]: asks for the console keymap and loads it
  local k dir=${GI_HOST_ROOT:-}/usr/share/keymaps
  local text=${2:-"Pick the console keyboard layout. Every password from here on is typed with it, and the new system uses it too."}
  while :; do
    k=$(ui_menu --ok Select --back "$1" "Keyboard layout" "$text" "${CFG[keymap]:-us}" \
      us "English (US)" "US QWERTY." \
      uk "English (UK)" "UK QWERTY." \
      de-latin1 "German" "QWERTZ with umlauts." \
      fr-latin1 "French" "AZERTY with accents." \
      be-latin1 "Belgian" "Belgian AZERTY." \
      es "Spanish" "Spanish QWERTY." \
      it "Italian" "Italian QWERTY." \
      pt-latin1 "Portuguese" "Portuguese QWERTY." \
      br-abnt2 "Brazilian" "Brazilian ABNT2." \
      sg-latin1 "Swiss German" "Swiss QWERTZ, German variant." \
      fr_CH-latin1 "Swiss French" "Swiss QWERTZ, French variant." \
      nl "Dutch" "Dutch QWERTY." \
      dk "Danish" "Danish QWERTY." \
      no "Norwegian" "Norwegian QWERTY." \
      sv-latin1 "Swedish" "Swedish QWERTY." \
      "fi" "Finnish" "Finnish QWERTY." \
      pl "Polish" "Polish QWERTY." \
      ru "Russian" "Russian and Latin letters." \
      jp106 "Japanese" "Japanese 106-key keyboard." \
      dvorak "Dvorak" "US Dvorak." \
      Other... "Type another keymap name" "Any keymap in $dir.") || return 1
    if [[ $k == Other... ]]; then
      k=$(ui_input "Keyboard layout" "Type the keymap name, like de-latin1-nodeadkeys." '') || continue
      if ! _q_keymap_exists "$k" "$dir"; then
        ui_msg "Keyboard layout" "There's no keymap named \"$k\" in $dir."
        continue
      fi
    fi
    _q_try keymap "$k" || continue
    if run_cmd loadkeys "$k"; then
      cfg_set keymap "$k"
      return 0
    fi
    ui_msg "Keyboard layout" "loadkeys couldn't load $k. The log has the details."
  done
}

_q_keymap_exists() { # NAME DIR
  cfg_validate keymap "$1" > /dev/null || return 1
  # The name was validated above, so it holds no glob characters. include/ has partial maps.
  [[ -n $(find "$2" -path '*/include' -prune -o -name "$1.map*" -print -quit 2> /dev/null) ]]
}

_q_keymap_changed() {
  local k dropped=0 next="Type them again where the menu shows [!]."
  for k in "${!GI_Q_TYPED[@]}"; do
    # The disk is already encrypted with it; it can't be typed again.
    if [[ $k == luks_passphrase ]] && cfg_is_locked encryption; then continue; fi
    unset 'SECRET[$k]' 'GI_Q_TYPED[$k]'
    dropped=1
  done
  # The runner drops the ones it asked for itself (on --resume) once the step ends.
  if ((GI_Q_PREVIEW && ${#GI_ASKED_SECRETS[@]})); then dropped=1; fi
  if ((dropped)); then
    if ((GI_Q_PREVIEW)); then next="You'll type them again when you choose Install in the compile preview."; fi
    ui_msg "Keyboard layout" "Passwords typed so far used the old layout, so they were cleared. $next"
  fi
}

# --- Disk --------------------------------------------------------------------

# Reads one hw_disks line into byid name size tran model summary. Tabs become \x1f
# because read merges runs of tabs, which would shift fields after an empty one.
_q_disk_read() { IFS=$'\x1f' read -r byid name size tran model summary <<< "${1//$'\t'/$'\x1f'}"; }

_q_disk_row() { # prints the hw_disks line for CFG[disk]; 1 when it isn't listed
  local line
  for line in "${GI_Q_DISKS[@]}"; do
    if [[ ${line%%$'\t'*} == "${CFG[disk]}" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done
  return 1
}

_q_disk_name() {
  local line byid name size tran model summary
  if line=$(_q_disk_row); then
    _q_disk_read "$line"
    printf '%s' "$name"
  else
    printf '%s' "${CFG[disk]##*/}"
  fi
}

_q_disk_label() {
  local line byid name size tran model summary
  if line=$(_q_disk_row); then
    _q_disk_read "$line"
    # Size before model, so a narrow screen cuts the model, not the size.
    printf '%s, %s, %s' "$name" "$(_q_size "$size")" "${model:-unknown model}"
  else
    printf '%s' "${CFG[disk]##*/}"
  fi
}

_q_size() { # BYTES: decimal units, as disk makers label them
  local b=$1 t
  if [[ ! $b =~ ^[0-9]+$ ]]; then
    printf '? GB'
  elif ((b >= 10 ** 12)); then
    t=$(((b + 5 * 10 ** 10) / 10 ** 11))
    printf '%d.%d TB' $((t / 10)) $((t % 10))
  else
    printf '%d GB' $(((b + 5 * 10 ** 8) / 10 ** 9))
  fi
}

_q_layout() {
  local luks='' swap='no swap'
  if [[ ${CFG[encryption]} == luks2 ]]; then luks=' in LUKS2'; fi
  case ${CFG[swap]} in
    zram) swap='zram swap' ;;
    file) swap='swap file' ;;
  esac
  printf '%s root%s, %s' "${CFG[filesystem]}" "$luks" "$swap"
}

_q_disk() {
  local line byid name size tran model summary v text="Everything on the chosen disk will be deleted."
  local -a items=()
  for line in "${GI_Q_DISKS[@]}"; do
    _q_disk_read "$line"
    # What's on the disk before the model, so an 80-column menu cuts the model instead.
    items+=("$name" "$(_q_size "$size")  ${tran:-?}  ${summary:-no partitions found}  ${model:-unknown model}" "$byid")
  done
  if ((${#items[@]} == 0)); then
    ui_msg "Disk" "No disk to install to was found. The live USB is never offered."
    return 1
  fi
  if [[ -n ${HW[live_disk]:-} ]]; then text+=" The live USB, ${HW[live_disk]}, isn't listed."; fi
  while :; do
    # A menu, not a radiolist: with no disk chosen yet, dialog's Enter on a radiolist returns nothing.
    v=$(ui_menu --ok Select "Disk to erase" "$text" "$(_q_disk_name)" "${items[@]}") || return 1
    for line in "${GI_Q_DISKS[@]}"; do
      _q_disk_read "$line"
      if [[ $name == "$v" ]] && _q_set disk "$byid"; then return 0; fi
    done
  done
}

# --- Install -----------------------------------------------------------------

# cfg_check_rules plus what only this part knows: the disk list and which secrets were typed here.
_q_check() { # prints error: and warn: lines; returns 1 on an error
  local k rc=0
  local -a keys=()
  cfg_check_rules || rc=1
  # After the disk step (the compile preview), the disk is in use and the review showed the rest.
  if cfg_is_locked disk; then return "$rc"; fi
  if [[ -n ${CFG[disk]:-} ]] && ! _q_disk_row > /dev/null; then
    echo "error: disk: ${CFG[disk]} isn't an installable disk: it's missing, under 20 GiB or the live USB."
    rc=1
  fi
  # With SECRET emptied (in this subshell only), it lists every secret the answers use.
  mapfile -t keys < <(SECRET=(); cfg_secrets_missing "${GI_STEPS[@]}")
  for k in "${keys[@]}"; do
    # Typed ones were warned about as they were typed.
    if [[ $k == wifi_psk || -n ${GI_Q_TYPED[$k]:-} || -z ${SECRET[$k]:-} ]]; then continue; fi
    if ((${#SECRET[$k]} < 16)); then echo "warn: $(_q_short_text "$k is")"; fi
  done
  return "$rc"
}

_q_rules_ok() {
  local out rc=0
  out=$(_q_check) || rc=$?
  if [[ -n $out ]]; then log INFO "combination checks: $out"; fi
  if ((rc)); then
    ui_msg "Fix these first" "$out"
    return 1
  fi
  if [[ -n $out ]]; then
    ui_yesno --defaultno "Warnings" "$out"$'\n\n'"Go on anyway?" || return 1
  fi
  return 0
}

_q_review() { # returns 0 once the user typed the disk name
  local f=$GI_RUN_DIR/review.txt
  _q_review_text > "$f"
  ui_textbox "Review" "$f"
  ui_yesno "Review" "Install with these answers? Choose No to go back and change them." || return 1
  if ! cfg_save; then
    ui_msg "Review" "Couldn't save the config to $GI_RUN_DIR/config."
    return 1
  fi
  _q_confirm
}

_q_review_text() {
  local s key label help line byid name size tran model summary
  for s in "${GI_Q_SECTIONS[@]}"; do
    printf '%s\n' "$s"
    while IFS=$'\t' read -r key label help; do
      if [[ $key == adduser ]]; then continue; fi
      printf '  %-22s %s\n' "$label" "$(_q_value "$key")"
      if [[ $key == disk ]] && line=$(_q_disk_row); then
        _q_disk_read "$line"
        printf '  %-22s %s\n' Path "$byid" "Now on" "${summary:-no partitions found}"
      fi
    done < <(_q_keys "$s")
    printf '\n'
  done
  printf 'Disk layout: 1 GiB ESP + %s\n' "$(_q_layout)"
}

_q_confirm() {
  local line byid name size tran model summary text
  line=$(_q_disk_row) || return 1
  _q_disk_read "$line"
  printf -v text 'Disk     %s\nNow on   %s. All of it will be deleted.\nLayout   1 GiB ESP + %s\n\nType %s to confirm:' \
    "$(_q_disk_label)" "${summary:-no partitions found}" "$(_q_layout)" "$name"
  ui_confirm_text "Erase $name and install?" "$text" "$name"
}
