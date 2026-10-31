#!/usr/bin/env bats
# Tests for lib/steps/desktop.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui state config locale desktop
  HW[gpus]=amd
  PM=$GI_TARGET/etc/portage/package.use/plasma-meta
  DM=$GI_TARGET/etc/conf.d/display-manager
  NG=$GI_TARGET/etc/portage/package.use/ngtcp2
}

chroot_line() { printf 'arch-chroot %q /bin/bash -c %q\n' "$GI_TARGET" "source /etc/profile && $*; exit \$?"; }

@test "Plasma on OpenRC: packages with SDDM, display-manager-init, fonts and Firefox" {
  cfg_defaults_apply
  run step_desktop_packages
  [ "$output" = "kde-plasma/plasma-meta
kde-apps/konsole
kde-apps/dolphin
gui-apps/sddm
gui-libs/display-manager-init
media-fonts/noto
media-fonts/noto-emoji
media-fonts/dejavu
www-client/firefox-bin" ]
}

@test "GNOME light on systemd with Chromium, CJK fonts and Intel video decoding" {
  HW[gpus]="intel nvidia"
  CFG[desktop]=gnome CFG[init]=systemd CFG[browser]=chromium CFG[fonts_cjk]=yes
  cfg_defaults_apply
  run step_desktop_packages
  [ "$output" = "gnome-base/gnome-light
gnome-base/gdm
media-fonts/noto
media-fonts/noto-emoji
media-fonts/dejavu
media-fonts/noto-cjk
www-client/chromium
media-libs/libva-intel-media-driver" ]
}

@test "full GNOME without a display manager or browser" {
  CFG[desktop]=gnome CFG[gnome_variant]=full CFG[display_manager]=none CFG[browser]=none
  cfg_defaults_apply
  run step_desktop_packages
  [ "$output" = "gnome-base/gnome
media-fonts/noto
media-fonts/noto-emoji
media-fonts/dejavu" ]
}

@test "no desktop means no packages, not even a browser" {
  CFG[desktop]=none
  cfg_defaults_apply
  run step_desktop_packages
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "Plasma without a display manager turns off plasma-meta's display-manager flag" {
  CFG[display_manager]=none
  cfg_defaults_apply
  step_desktop_portage
  [ "$(cat "$PM")" = 'kde-plasma/plasma-meta -display-manager' ]
  step_desktop_portage
  [ "$(cat "$PM")" = 'kde-plasma/plasma-meta -display-manager' ]
  CFG[display_manager]=auto
  step_desktop_portage
  [ ! -e "$PM" ]
}

@test "GNOME without a display manager writes no Portage file" {
  CFG[desktop]=gnome CFG[display_manager]=none
  cfg_defaults_apply
  step_desktop_portage
  [ ! -e "$PM" ]
}

@test "Plasma on OpenRC enables dbus, elogind and SDDM through display-manager" {
  cfg_defaults_apply
  mkdir -p "${DM%/*}"
  printf 'CHECKVT=7\nDISPLAYMANAGER="xdm"\n' > "$DM"
  step_desktop
  diff -u <(chroot_line rc-update add dbus default
    chroot_line rc-update add elogind boot
    chroot_line rc-update add display-manager default) "$STUB_LOG"
  [ "$(cat "$DM")" = $'CHECKVT=7\nDISPLAYMANAGER="sddm"' ]
}

@test "running the OpenRC step twice keeps one DISPLAYMANAGER line" {
  CFG[desktop]=gnome
  cfg_defaults_apply
  step_desktop
  step_desktop
  [ "$(cat "$DM")" = 'DISPLAYMANAGER="gdm"' ]
}

@test "OpenRC without a display manager still starts dbus and elogind" {
  CFG[display_manager]=none
  cfg_defaults_apply
  step_desktop
  diff -u <(chroot_line rc-update add dbus default
    chroot_line rc-update add elogind boot) "$STUB_LOG"
  [ ! -e "$DM" ]
}

@test "GNOME on systemd enables GDM and the graphical target" {
  CFG[desktop]=gnome CFG[init]=systemd
  cfg_defaults_apply
  step_desktop
  diff -u <(chroot_line systemctl enable gdm
    chroot_line systemctl set-default graphical.target) "$STUB_LOG"
}

@test "systemd without a display manager and no desktop at all run nothing" {
  CFG[init]=systemd CFG[display_manager]=none
  cfg_defaults_apply
  step_desktop
  CFG[desktop]=none CFG[init]=openrc
  step_desktop
  [ ! -s "$STUB_LOG" ]
}

@test "dry-run prints the commands and runs nothing" {
  cfg_defaults_apply
  GI_DRY_RUN=1
  run --separate-stderr step_desktop
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$DM" ]
  [[ $stderr == *"rc-update add display-manager default"* ]]
  [[ $stderr == *'DISPLAYMANAGER="sddm"'* ]]
}

@test "GNOME on systemd without binary packages gets ngtcp2 with GnuTLS, and the file goes when not needed" {
  CFG[desktop]=gnome CFG[init]=systemd CFG[binpkgs]=no
  cfg_defaults_apply
  step_desktop_portage
  step_desktop_portage
  [ "$(cat "$NG")" = 'net-libs/ngtcp2 gnutls' ]
  CFG[binpkgs]=yes
  step_desktop_portage
  [ ! -e "$NG" ]
  CFG[binpkgs]=no CFG[desktop]=plasma
  step_desktop_portage
  [ ! -e "$NG" ]
  CFG[desktop]=gnome CFG[init]=openrc
  step_desktop_portage
  [ ! -e "$NG" ]
}

# The packages step_desktop_packages lists before the fonts, which every desktop gets.
own_packages() { step_desktop_packages | sed '/^media-fonts\/noto$/,$d' | tr '\n' ' '; }

@test "each new desktop brings what its default config starts, the X server or portal backends, and its login screen" {
  check() {
    CFG[desktop]=$1
    [ "$(own_packages)" = "$2 " ] || { echo "$1: got $(own_packages)"; return 1; }
  }
  cfg_defaults_apply
  local dm='x11-misc/lightdm x11-misc/lightdm-gtk-greeter gui-libs/display-manager-init'
  check xfce "xfce-base/xfce4-meta x11-base/xorg-server x11-apps/xinit gnome-extra/nm-applet $dm"
  check budgie "budgie-base/budgie-meta x11-terms/gnome-terminal $dm"
  check cinnamon "gnome-extra/cinnamon x11-terms/gnome-terminal x11-base/xorg-server x11-apps/xinit $dm"
  check i3 'x11-wm/i3 x11-terms/xterm x11-misc/dmenu x11-misc/i3status x11-misc/i3lock x11-misc/xss-lock x11-misc/dex x11-base/xorg-server x11-apps/xinit gnome-extra/nm-applet'
  check dwm 'x11-wm/dwm x11-terms/st x11-misc/dmenu x11-base/xorg-server x11-apps/xinit'
  check sway 'gui-wm/sway gui-apps/foot gui-apps/wmenu gui-libs/xdg-desktop-portal-wlr sys-apps/xdg-desktop-portal-gtk'
  check dwl 'gui-wm/dwl gui-apps/foot gui-apps/wmenu gui-libs/xdg-desktop-portal-wlr sys-apps/xdg-desktop-portal-gtk'
  check hyprland 'gui-wm/hyprland x11-terms/kitty gui-apps/hyprlauncher gui-libs/xdg-desktop-portal-hyprland sys-apps/xdg-desktop-portal-gtk'
  check niri 'gui-wm/niri x11-terms/alacritty gui-apps/fuzzel gui-apps/waybar gui-apps/swaylock sys-apps/xdg-desktop-portal-gnome sys-apps/xdg-desktop-portal-gtk'
  check mangowm 'gui-wm/mangowm gui-apps/foot x11-misc/rofi gui-libs/xdg-desktop-portal-wlr sys-apps/xdg-desktop-portal-gtk'
  # Fonts and the browser follow, as for Plasma and GNOME.
  CFG[desktop]=sway
  [ "$(step_desktop_packages | tail -n 4 | tr '\n' ' ')" = 'media-fonts/noto media-fonts/noto-emoji media-fonts/dejavu www-client/firefox-bin ' ]
}

@test "LightDM without display-manager-init on systemd, no applet without NetworkManager, no login screen when turned off" {
  CFG[init]=systemd CFG[network]=dhcpcd
  cfg_defaults_apply
  check() {
    CFG[desktop]=$1
    [ "$(own_packages)" = "$2 " ] || { echo "$1: got $(own_packages)"; return 1; }
  }
  check xfce 'xfce-base/xfce4-meta x11-base/xorg-server x11-apps/xinit x11-misc/lightdm x11-misc/lightdm-gtk-greeter'
  check i3 'x11-wm/i3 x11-terms/xterm x11-misc/dmenu x11-misc/i3status x11-misc/i3lock x11-misc/xss-lock x11-misc/dex x11-base/xorg-server x11-apps/xinit'
  CFG[display_manager]=none
  check cinnamon 'gnome-extra/cinnamon x11-terms/gnome-terminal x11-base/xorg-server x11-apps/xinit'
}

@test "testing keywords and USE flags for the desktops that need them, and the files go with the answer" {
  KW=$GI_TARGET/etc/portage/package.accept_keywords/desktop UE=$GI_TARGET/etc/portage/package.use/desktop
  cfg_defaults_apply
  CFG[desktop]=hyprland
  step_desktop_portage
  [ "$(cat "$KW")" = $'*/*::hyproverlay ~amd64\ndev-cpp/sdbus-c++ ~amd64' ]
  [ ! -e "$UE" ]
  CFG[desktop]=niri
  step_desktop_portage
  step_desktop_portage
  [ "$(cat "$KW")" = $'gui-wm/niri::guru ~amd64\ngui-apps/fuzzel::guru ~amd64' ]
  [ "$(cat "$UE")" = 'gui-wm/niri screencast' ]
  CFG[desktop]=mangowm
  step_desktop_portage
  [ "$(cat "$KW")" = $'gui-wm/mangowm::guru ~amd64\ngui-libs/scenefx::guru ~amd64' ]
  [ ! -e "$UE" ]
  CFG[desktop]=budgie
  step_desktop_portage
  [ "$(cat "$KW")" = $'*/*::SarahMiaOverlay ~amd64\ngui-wm/labwc ~amd64\ndev-cpp/toml11 ~amd64' ]
  [ "$(cat "$UE")" = $'app-i18n/ibus vala\ndev-libs/libpeas vala\ngui-apps/swaybg gdk-pixbuf\ngui-libs/gtk-layer-shell introspection vala\nsys-apps/accountsservice vala\nxfce-base/libxfce4windowing vala' ]
  CFG[desktop]=dwl
  step_desktop_portage
  [ "$(cat "$KW")" = 'gui-wm/dwl ~amd64' ]
  [ ! -e "$UE" ]
  # webkit-gtk's only OpenRC binary has keyring.
  CFG[desktop]=cinnamon
  step_desktop_portage
  [ "$(cat "$UE")" = 'net-libs/webkit-gtk keyring' ]
  CFG[init]=systemd
  step_desktop_portage
  # Its default config's wallpaper; the binary host's sway has none, so it shows a config error.
  CFG[desktop]=sway
  step_desktop_portage
  [ "$(cat "$UE")" = $'gui-wm/sway wallpapers\ngui-apps/swaybg gdk-pixbuf' ]
  [ ! -e "$KW" ]
  for d in xfce i3 dwm plasma none; do
    CFG[desktop]=$d
    step_desktop_portage
    [ ! -e "$KW" ]
    [ ! -e "$UE" ]
  done
}

@test "LightDM starts through display-manager on OpenRC and as lightdm.service on systemd" {
  CFG[desktop]=budgie
  cfg_defaults_apply
  step_desktop
  [ "$(cat "$DM")" = 'DISPLAYMANAGER="lightdm"' ]
  grep -qxF "$(chroot_line rc-update add display-manager default)" "$STUB_LOG"
  : > "$STUB_LOG"
  CFG[init]=systemd
  step_desktop
  diff -u <(chroot_line systemctl enable lightdm
    chroot_line systemctl set-default graphical.target) "$STUB_LOG"
}

@test "a window manager gets no login screen: dbus and elogind on OpenRC, nothing on systemd" {
  CFG[desktop]=hyprland
  cfg_defaults_apply
  run step_desktop_packages
  [[ $output != *lightdm* && $output != *sddm* && $output != *display-manager-init* ]]
  step_desktop
  diff -u <(chroot_line rc-update add dbus default
    chroot_line rc-update add elogind boot) "$STUB_LOG"
  [ ! -e "$DM" ]
  : > "$STUB_LOG"
  CFG[init]=systemd
  step_desktop
  [ ! -s "$STUB_LOG" ]
}

@test "Wayland compositors get the keyboard layout the way each reads it, with no duplicate lines on a rerun" {
  local env=$GI_TARGET/etc/env.d/90xkb fish=$GI_TARGET/etc/fish/conf.d/90xkb.fish mango=$GI_TARGET/etc/mango/config.conf
  local hypr=$GI_TARGET/etc/xdg/hypr/hyprland.lua deb=$GI_TARGET/etc/default/keyboard
  CFG[keymap]=de-latin1
  cfg_defaults_apply
  # dwl and niri set no layout, so libxkbcommon takes XKB_DEFAULT_*; login shells get them through
  # env-update, and fish, which doesn't read profile.env, through its conf.d.
  CFG[desktop]=dwl
  step_desktop
  [ "$(cat "$env")" = 'XKB_DEFAULT_LAYOUT="de"' ]
  [ "$(cat "$fish")" = 'set -gx XKB_DEFAULT_LAYOUT "de"' ]
  grep -qxF "$(chroot_line env-update)" "$STUB_LOG"
  [ ! -e "$GI_TARGET/etc/sway" ]
  CFG[keymap]=ru CFG[desktop]=niri
  step_desktop
  [ "$(cat "$env")" = 'XKB_DEFAULT_LAYOUT="ru,us"
XKB_DEFAULT_MODEL="pc105"
XKB_DEFAULT_OPTIONS="terminate:ctrl_alt_bksp,grp:shifts_toggle,grp_led:scroll"' ]
  [ "$(cat "$fish")" = 'set -gx XKB_DEFAULT_LAYOUT "ru,us"
set -gx XKB_DEFAULT_MODEL "pc105"
set -gx XKB_DEFAULT_OPTIONS "terminate:ctrl_alt_bksp,grp:shifts_toggle,grp_led:scroll"' ]
  # mango's /etc config says "us"; the layout replaces that line in place.
  rm -f "$env" "$fish"
  mkdir -p "${mango%/*}"
  printf '%s\n' '# keyboard' 'repeat_rate=25' 'xkb_rules_layout=us' 'tap_to_click=1' > "$mango"
  CFG[keymap]=dvorak CFG[desktop]=mangowm
  step_desktop
  step_desktop
  [ "$(cat "$mango")" = '# keyboard
repeat_rate=25
xkb_rules_layout="us"
tap_to_click=1
xkb_rules_model="pc105"
xkb_rules_variant="dvorak"
xkb_rules_options="terminate:ctrl_alt_bksp"' ]
  # Only French moves Alt+backslash to its keycode; it clashes there with Alt+8.
  printf '%s\n' 'bind=ALT,backslash,togglefloating,' 'bind=Alt,8,tag,8,0' > "$mango"
  step_desktop
  grep -qxF 'bind=ALT,backslash,togglefloating,' "$mango"
  CFG[keymap]=fr-latin1
  step_desktop
  step_desktop
  grep -qxF 'bind=ALT,code:51,togglefloating,' "$mango"
  grep -qxF 'bind=Alt,8,tag,8,0' "$mango"
  [ "$(grep -c togglefloating "$mango")" = 1 ]
  [ ! -e "$env" ]
  # Hyprland's example config sets "us" too, so the system config runs it and sets the layout after.
  CFG[keymap]=uk CFG[desktop]=hyprland
  step_desktop
  grep -qxF 'dofile("/usr/share/hypr/hyprland.lua")' "$hypr"
  # Keeps the example's first-run warning and welcome app.
  grep -qF 'hl.config({ autogenerated = true })' "$hypr"
  [ "$(tail -n 1 "$hypr")" = 'hl.config({ input = { kb_layout = "gb", kb_model = "pc105", kb_variant = "", kb_options = "terminate:ctrl_alt_bksp" } })' ]
  [ ! -e "$env" ]
  # Budgie's labwc bridge reads locale1, which OpenRC lacks, and then this Debian file.
  rm -f "$hypr"
  CFG[desktop]=budgie
  step_desktop
  [ "$(cat "$deb")" = 'XKBMODEL="pc105"
XKBLAYOUT="gb"
XKBVARIANT=""
XKBOPTIONS="terminate:ctrl_alt_bksp"' ]
  [ ! -e "$env" ] && [ ! -e "$hypr" ]
  # X sessions read xorg.conf.d, which the locale step writes.
  rm -f "$deb"
  for d in i3 xfce plasma; do
    CFG[desktop]=$d
    step_desktop
  done
  [ ! -e "$env" ] && [ ! -e "$hypr" ] && [ ! -e "$deb" ] && [ ! -e "$fish" ]
}

@test "sway exports its session to xdg-desktop-portal, and niri's file chooser is GTK's" {
  local sway=$GI_TARGET/etc/sway/config.d/50-gentooinstall.conf portals=$GI_TARGET/etc/xdg-desktop-portal/niri-portals.conf
  cfg_defaults_apply
  CFG[desktop]=sway
  step_desktop
  grep -qxF 'exec dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP=sway' "$sway"
  [ ! -e "$portals" ]
  CFG[desktop]=niri
  step_desktop
  grep -qxF 'org.freedesktop.impl.portal.FileChooser=gtk;' "$portals"
  grep -qxF 'default=gnome;gtk;' "$portals"
}

@test "dry-run prints the compositors' keyboard and portal files and writes none" {
  cfg_defaults_apply
  GI_DRY_RUN=1 CFG[keymap]=de-latin1
  for d in budgie sway hyprland mangowm niri; do
    CFG[desktop]=$d
    run --separate-stderr step_desktop
    [ "$status" -eq 0 ]
  done
  [[ $stderr == *'XKB_DEFAULT_LAYOUT="de"'* ]]
  [ -z "$(find "$GI_TARGET" -type f)" ]
}
