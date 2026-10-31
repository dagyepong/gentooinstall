# shellcheck shell=bash
# Desktop step: the desktop or window manager, its login screen, fonts, browser and video decoding.

step_define desktop "Desktop" \
  "Installs the desktop or window manager with its login screen, fonts and a browser. On OpenRC, dbus and elogind must run for the desktop session, and display-manager-init starts the login screen." \
  "https://wiki.gentoo.org/wiki/Display_manager"

# Prints sddm, gdm, lightdm, or nothing when the system boots to a text console. The window
# managers never get a login screen; they start from the console.
_desktop_dm() {
  [[ ${CFG[display_manager]} == auto ]] || return 0
  case ${CFG[desktop]} in
    plasma) echo sddm ;;
    gnome) echo gdm ;;
    xfce | budgie | cinnamon) echo lightdm ;;
  esac
}

step_desktop_portage() {
  local f=/etc/portage/package.use/plasma-meta n=/etc/portage/package.use/ngtcp2 kw='' use=''
  if [[ ${CFG[desktop]} == plasma && -z $(_desktop_dm) ]]; then
    # plasma-meta pulls in SDDM through its default display-manager flag.
    echo 'kde-plasma/plasma-meta -display-manager' | portage_file package.use plasma-meta
  elif [[ -e $GI_TARGET$f ]]; then
    run_cmd rm -f -- "$GI_TARGET$f"
  fi
  if [[ ${CFG[desktop]} == gnome && ${CFG[binpkgs]} == no ]] && is_systemd; then
    # Built from source, samba (through cifs-utils) needs ngtcp2 with GnuTLS.
    echo 'net-libs/ngtcp2 gnutls' | portage_file package.use ngtcp2
  elif [[ -e $GI_TARGET$n ]]; then
    run_cmd rm -f -- "$GI_TARGET$n"
  fi
  # Only testing versions exist of these. Budgie 10.10 needs its overlay's other testing
  # packages too, as the overlay's README says, and hyproverlay is Hyprland and its libraries.
  case ${CFG[desktop]} in
    # Budgie's ebuilds depend on these flags, like sys-apps/accountsservice[vala].
    budgie)
      kw=$'*/*::SarahMiaOverlay ~amd64\ngui-wm/labwc ~amd64\ndev-cpp/toml11 ~amd64'
      use=$'app-i18n/ibus vala\ndev-libs/libpeas vala\ngui-apps/swaybg gdk-pixbuf\ngui-libs/gtk-layer-shell introspection vala\nsys-apps/accountsservice vala\nxfce-base/libxfce4windowing vala'
      ;;
    # xdg-desktop-portal-hyprland needs sdbus-c++ 2.
    hyprland) kw=$'*/*::hyproverlay ~amd64\ndev-cpp/sdbus-c++ ~amd64' ;;
    # The binary host's only OpenRC webkit-gtk has keyring; without it webkit-gtk compiles for hours.
    cinnamon) if is_openrc; then use='net-libs/webkit-gtk keyring'; fi ;;
    # screencast builds the screen sharing that xdg-desktop-portal-gnome serves for niri.
    niri) kw=$'gui-wm/niri::guru ~amd64\ngui-apps/fuzzel::guru ~amd64' use='gui-wm/niri screencast' ;;
    mangowm) kw=$'gui-wm/mangowm::guru ~amd64\ngui-libs/scenefx::guru ~amd64' ;;
    dwl) kw='gui-wm/dwl ~amd64' ;;
    # Sway's default config sets its own wallpaper, which only this flag installs; without it every
    # start shows a config error bar.
    sway) use=$'gui-wm/sway wallpapers\ngui-apps/swaybg gdk-pixbuf' ;;
  esac
  _desktop_portage_file package.accept_keywords "$kw"
  _desktop_portage_file package.use "$use"
}

# Writes LINES to /etc/portage/KIND/desktop, or removes the file an earlier answer needed.
_desktop_portage_file() { # KIND LINES
  if [[ -n $2 ]]; then
    printf '%s\n' "$2" | portage_file "$1" desktop
  elif [[ -e $GI_TARGET/etc/portage/$1/desktop ]]; then
    run_cmd rm -f -- "$GI_TARGET/etc/portage/$1/desktop"
  fi
}

step_desktop_packages() {
  local dm
  local -a p=()
  dm=$(_desktop_dm)
  # The window managers come with what their shipped default config starts: terminal, launcher,
  # bar and screen locker. Budgie and Cinnamon open gnome-terminal; xfce4-meta has its own.
  case ${CFG[desktop]} in
    plasma) p=(kde-plasma/plasma-meta kde-apps/konsole kde-apps/dolphin) ;;
    gnome) if [[ ${CFG[gnome_variant]} == full ]]; then p=(gnome-base/gnome); else p=(gnome-base/gnome-light); fi ;;
    xfce) p=(xfce-base/xfce4-meta) ;;
    budgie) p=(budgie-base/budgie-meta x11-terms/gnome-terminal) ;;
    cinnamon) p=(gnome-extra/cinnamon x11-terms/gnome-terminal) ;;
    # i3-sensible-terminal finds xterm. dex runs the XDG autostart files, PipeWire's among them.
    i3) p=(x11-wm/i3 x11-terms/xterm x11-misc/dmenu x11-misc/i3status x11-misc/i3lock x11-misc/xss-lock x11-misc/dex) ;;
    dwm) p=(x11-wm/dwm x11-terms/st x11-misc/dmenu) ;;
    sway) p=(gui-wm/sway gui-apps/foot gui-apps/wmenu) ;;
    dwl) p=(gui-wm/dwl gui-apps/foot gui-apps/wmenu) ;;
    hyprland) p=(gui-wm/hyprland x11-terms/kitty gui-apps/hyprlauncher) ;;
    niri) p=(gui-wm/niri x11-terms/alacritty gui-apps/fuzzel gui-apps/waybar gui-apps/swaylock) ;;
    mangowm) p=(gui-wm/mangowm gui-apps/foot x11-misc/rofi) ;;
    *) return 0 ;;
  esac
  # The X sessions need the X server, and startx for a start from the console. The Wayland
  # compositors get the portal backends their portals.conf names, gtk for the file chooser.
  case ${CFG[desktop]} in
    xfce | cinnamon | i3 | dwm) p+=(x11-base/xorg-server x11-apps/xinit) ;;
    sway | dwl | mangowm) p+=(gui-libs/xdg-desktop-portal-wlr sys-apps/xdg-desktop-portal-gtk) ;;
    hyprland) p+=(gui-libs/xdg-desktop-portal-hyprland sys-apps/xdg-desktop-portal-gtk) ;;
    niri) p+=(sys-apps/xdg-desktop-portal-gnome sys-apps/xdg-desktop-portal-gtk) ;;
  esac
  # Xfce has no network applet of its own, and i3's default config starts this one.
  if [[ ${CFG[network]} == networkmanager && " xfce i3 " == *" ${CFG[desktop]} "* ]]; then p+=(gnome-extra/nm-applet); fi
  case $dm in
    sddm) p+=(gui-apps/sddm) ;;
    gdm) p+=(gnome-base/gdm) ;;
    lightdm) p+=(x11-misc/lightdm x11-misc/lightdm-gtk-greeter) ;;
  esac
  if [[ -n $dm ]] && is_openrc; then p+=(gui-libs/display-manager-init); fi
  p+=(media-fonts/noto media-fonts/noto-emoji media-fonts/dejavu)
  if [[ ${CFG[fonts_cjk]} == yes ]]; then p+=(media-fonts/noto-cjk); fi
  if [[ ${CFG[browser]} != none ]]; then p+=("www-client/${CFG[browser]}"); fi
  if [[ " ${HW[gpus]:-} " == *" intel "* ]]; then p+=(media-libs/libva-intel-media-driver); fi
  printf '%s\n' "${p[@]}"
}

step_desktop() {
  local dm
  [[ ${CFG[desktop]} != none ]] || return 0
  dm=$(_desktop_dm)
  if is_openrc; then
    service_enable dbus
    service_enable elogind boot
    if [[ -n $dm ]]; then
      set_shell_var /etc/conf.d/display-manager DISPLAYMANAGER "$dm"
      service_enable display-manager
    fi
  elif [[ -n $dm ]]; then
    service_enable "$dm"
    run_chroot systemctl set-default graphical.target
  fi
  _desktop_wayland
}

# The Wayland sessions ignore xorg.conf.d, so each gets the locale step's X keyboard layout the way
# it reads one, and xdg-desktop-portal gets what it needs to find sway's session and to open niri's
# file chooser.
_desktop_wayland() {
  local k v vars layout='' model='' variant='' options=''
  case ${CFG[desktop]} in
    sway | dwl | niri | mangowm | hyprland | budgie) ;;
    *) return 0 ;;
  esac
  while IFS='=' read -r k v; do printf -v "$k" '%s' "$v"; done < <(locale_xkb)
  case ${CFG[desktop]} in
    # Their shipped configs set "us"; these are the ones they read while the user has none.
    mangowm)
      for k in layout model variant options; do set_shell_var /etc/mango/config.conf "xkb_rules_$k" "${!k}"; done
      # On AZERTY "\" is AltGr+8, so Alt+backslash clashes with Alt+8 (tag 8) and mango shows an
      # error bar. Keycode 51 is the key that types "\" on a US keyboard ("*" on AZERTY).
      if [[ $layout == fr && -f $GI_TARGET/etc/mango/config.conf ]]; then
        sed 's/^bind=ALT,backslash,togglefloating,/bind=ALT,code:51,togglefloating,/' \
          "$GI_TARGET/etc/mango/config.conf" | write_file /etc/mango/config.conf
      fi
      ;;
    hyprland)
      write_file /etc/xdg/hypr/hyprland.lua << EOF
-- Written by gentooinstall. Hyprland reads this file while ~/.config/hypr/hyprland.lua doesn't
-- exist: Hyprland's own example config, plus the keyboard layout chosen at install.
hl.config({ autogenerated = true }) -- remove this line to remove the warning
dofile("/usr/share/hypr/hyprland.lua")
hl.config({ input = { kb_layout = "$layout", kb_model = "$model", kb_variant = "$variant", kb_options = "$options" } })
EOF
      ;;
    # Budgie's labwc bridge asks systemd-localed, which OpenRC lacks, then reads this file.
    budgie)
      printf 'XKBMODEL="%s"\nXKBLAYOUT="%s"\nXKBVARIANT="%s"\nXKBOPTIONS="%s"\n' "$model" "$layout" "$variant" "$options" |
        write_file /etc/default/keyboard
      ;;
    # libxkbcommon reads these when the config sets no layout; niri asks systemd-localed first, which has the same.
    *)
      vars=$(for k in layout model variant options; do
        if [[ -n ${!k} ]]; then printf 'XKB_DEFAULT_%s="%s"\n' "${k^^}" "${!k}"; fi
      done)
      printf '%s\n' "$vars" | write_file /etc/env.d/90xkb
      run_chroot env-update
      # A fish login shell doesn't read /etc/profile.env, where env-update puts them (Gentoo bug 545830).
      printf '%s\n' "$vars" | sed 's/=/ /; s/^/set -gx /' | write_file /etc/fish/conf.d/90xkb.fish
      ;;
  esac
  case ${CFG[desktop]} in
    # sway sets neither: without them the portal finds no display and doesn't read sway-portals.conf.
    # --systemd also reaches systemd's user services, and is skipped where there are none.
    sway)
      write_file /etc/sway/config.d/50-gentooinstall.conf << 'EOF'
# Written by gentooinstall: lets xdg-desktop-portal find this session and its portals.
exec dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP=sway
EOF
      ;;
    # GNOME's file chooser portal needs Nautilus; GTK's needs nothing more.
    niri)
      write_file /etc/xdg-desktop-portal/niri-portals.conf << 'EOF'
# Written by gentooinstall: niri's niri-portals.conf with GTK's file chooser, since
# GNOME's needs Nautilus, which isn't installed.
[preferred]
default=gnome;gtk;
org.freedesktop.impl.portal.Access=gtk;
org.freedesktop.impl.portal.Notification=gtk;
org.freedesktop.impl.portal.Secret=gnome-keyring;
org.freedesktop.impl.portal.FileChooser=gtk;
EOF
      ;;
  esac
}
