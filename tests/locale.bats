#!/usr/bin/env bats
# Tests for lib/steps/locale.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui config state disk stage3 locale
  state_set windows.esp none
  GI_UI=plain
  CFG[keymap]=de-latin1 CFG[timezone]=Europe/Berlin CFG[locales]="en_US.UTF-8 de_DE" CFG[lang]=en_US.UTF-8
  cfg_defaults_apply
  mkdir -p "$GI_TARGET/etc/conf.d" "$GI_TARGET/usr/share/i18n"
  printf 'keymap="us"\nwindowkeys="YES"\n' > "$GI_TARGET/etc/conf.d/keymaps"
  printf 'clock="UTC"\nclock_args=""\n' > "$GI_TARGET/etc/conf.d/hwclock"
  printf 'C.UTF-8 UTF-8\nde_DE.UTF-8 UTF-8\nde_DE ISO-8859-1\nen_US.UTF-8 UTF-8\nen_US ISO-8859-1\n' > "$GI_TARGET/usr/share/i18n/SUPPORTED"
  mkdir -p "$GI_TARGET/usr/share/zoneinfo/Europe"
  touch "$GI_TARGET/usr/share/zoneinfo/Europe/Berlin"
  ln -s ../usr/share/zoneinfo/Factory "$GI_TARGET/etc/localtime"
  echo UTC > "$GI_TARGET/etc/timezone"
}

# The stub records each chroot script %q-quoted.
chroot_ran() { grep -qxF "arch-chroot $(printf '%q' "$GI_TARGET") /bin/bash -c $(printf '%q' "source /etc/profile && $1; exit \$?")" "$STUB_LOG"; }

@test "portage hook: OpenRC keymap in conf.d, other settings kept" {
  step_locale_portage
  [ "$(cat "$GI_TARGET/etc/conf.d/keymaps")" = $'keymap="de-latin1"\nwindowkeys="YES"' ]
  [ ! -e "$GI_TARGET/etc/vconsole.conf" ]
}

@test "portage hook: systemd keymap in vconsole.conf" {
  CFG[init]=systemd
  step_locale_portage
  [ "$(cat "$GI_TARGET/etc/vconsole.conf")" = "KEYMAP=de-latin1" ]
  grep -qx 'keymap="us"' "$GI_TARGET/etc/conf.d/keymaps"
}

@test "step on OpenRC: timezone, locales, LANG through eselect, keyboard and clock" {
  sed -i 's/UTC/local/' "$GI_TARGET/etc/conf.d/hwclock"
  step_locale
  [ "$(readlink "$GI_TARGET/etc/localtime")" = ../usr/share/zoneinfo/Europe/Berlin ]
  [ ! -e "$GI_TARGET/etc/timezone" ]
  [ "$(cat "$GI_TARGET/etc/locale.gen")" = $'en_US.UTF-8 UTF-8\nde_DE ISO-8859-1' ]
  chroot_ran locale-gen
  chroot_ran 'eselect locale set en_US.UTF-8'
  chroot_ran env-update
  [ ! -e "$GI_TARGET/etc/locale.conf" ]
  grep -qx 'clock="UTC"' "$GI_TARGET/etc/conf.d/hwclock"
  grep -qx $'\tOption "XkbLayout" "de"' "$GI_TARGET/etc/X11/xorg.conf.d/00-keyboard.conf"
  run ! grep -q XkbVariant "$GI_TARGET/etc/X11/xorg.conf.d/00-keyboard.conf"
}

@test "beside Windows the hardware clock keeps local time, on OpenRC and systemd" {
  state_set windows.esp '3333-p 3333-f'
  step_locale
  grep -qx 'clock="local"' "$GI_TARGET/etc/conf.d/hwclock"
  CFG[init]=systemd
  step_locale
  [ "$(cat "$GI_TARGET/etc/adjtime")" = $'0.0 0 0.0\n0\nLOCAL' ]
  state_set windows.esp none
  step_locale
  [ "$(cat "$GI_TARGET/etc/adjtime")" = $'0.0 0 0.0\n0\nUTC' ]
}

@test "the X window managers get the X keyboard file too; the console doesn't" {
  local f=$GI_TARGET/etc/X11/xorg.conf.d/00-keyboard.conf
  CFG[desktop]=i3
  step_locale
  grep -qx $'\tOption "XkbLayout" "de"' "$f"
  rm -- "$f"
  CFG[desktop]=none
  step_locale
  [ ! -e "$f" ]
}

@test "step on systemd: locale.conf as well, X layout from systemd's keymap table" {
  CFG[init]=systemd CFG[keymap]=uk
  mkdir -p "$GI_TARGET/usr/share/systemd"
  printf '# comment\nuk\tgb\tpc105\t-\tterminate:ctrl_alt_bksp\nde-latin1-nodeadkeys\tde\tpc105\tnodeadkeys\tterminate:ctrl_alt_bksp\n' \
    > "$GI_TARGET/usr/share/systemd/kbd-model-map"
  step_locale
  [ "$(cat "$GI_TARGET/etc/locale.conf")" = "LANG=en_US.UTF-8" ]
  chroot_ran 'eselect locale set en_US.UTF-8'
  run cat "$GI_TARGET/etc/X11/xorg.conf.d/00-keyboard.conf"
  [ "$output" = $'Section "InputClass"\n\tIdentifier "system-keyboard"\n\tMatchIsKeyboard "on"\n\tOption "XkbLayout" "gb"\n\tOption "XkbModel" "pc105"\n\tOption "XkbOptions" "terminate:ctrl_alt_bksp"\nEndSection' ]
  CFG[keymap]=de-latin1-nodeadkeys
  step_locale
  grep -qx $'\tOption "XkbVariant" "nodeadkeys"' "$GI_TARGET/etc/X11/xorg.conf.d/00-keyboard.conf"
}

@test "X layout without systemd's table: every keymap in the menu maps like localectl would" {
  local k want
  local -A layout=([us]=us [uk]=gb [de-latin1]=de [fr-latin1]=fr [be-latin1]=be [es]=es [it]=it
    [pt-latin1]=pt [br-abnt2]=br [sg-latin1]=ch [fr_CH-latin1]=ch [nl]=nl [dk]=dk [no]=no
    [sv-latin1]=se [fi]=fi [pl]=pl [ru]=ru,us [jp106]=jp [dvorak]=us)
  # The same 20 keymaps the menu in lib/questions.sh offers.
  [ "${#layout[@]}" -eq 20 ]
  for k in "${!layout[@]}"; do
    CFG[keymap]=$k
    run locale_xkb
    [[ ${lines[0]} == "layout=${layout[$k]}" ]] || { echo "$k: $output"; false; }
  done
  CFG[keymap]=sg-latin1
  run locale_xkb
  [ "${lines[2]}" = variant=de_nodeadkeys ]
  CFG[keymap]=dvorak
  run locale_xkb
  [ "${lines[2]}" = variant=dvorak ]
  # Without a switch key the greeter would type only Cyrillic.
  CFG[keymap]=ru
  run locale_xkb
  [ "${lines[3]}" = options=terminate:ctrl_alt_bksp,grp:shifts_toggle,grp_led:scroll ]
  CFG[keymap]=jp106
  run locale_xkb
  [ "${lines[1]}" = model=jp106 ]
  # The desktop step reads these four lines too; the table's - comes out empty.
  CFG[keymap]=uk
  run locale_xkb
  [ "$output" = $'layout=gb\nmodel=pc105\nvariant=\noptions=terminate:ctrl_alt_bksp' ]
  CFG[keymap]=de-latin1-nodeadkeys
  run locale_xkb
  [ "$output" = $'layout=de\nmodel=\nvariant=\noptions=' ]
  run _locale_xorg
  [ "$output" = $'Section "InputClass"\n\tIdentifier "system-keyboard"\n\tMatchIsKeyboard "on"\n\tOption "XkbLayout" "de"\nEndSection' ]
}

@test "step: a keymap changed after the portage hook ran reaches the console keymap file" {
  step_locale_portage
  CFG[keymap]=fr-latin1
  step_locale
  grep -qx 'keymap="fr-latin1"' "$GI_TARGET/etc/conf.d/keymaps"
  CFG[init]=systemd
  step_locale
  [ "$(cat "$GI_TARGET/etc/vconsole.conf")" = "KEYMAP=fr-latin1" ]
}

@test "step: a timezone changed after the stage3 check is checked again before it is linked" {
  # Changed in the compile preview's settings, or by --resume --config.
  CFG[timezone]=Europe/Brlin
  run step_locale <<< Europe/Berlin
  [ "$status" -eq 0 ]
  [[ $output == *"There's no timezone called Europe/Brlin"* ]]
  [ "$(readlink "$GI_TARGET/etc/localtime")" = ../usr/share/zoneinfo/Europe/Berlin ]
  grep -qx 'timezone=Europe/Berlin' "$GI_RUN_DIR/config"
  CFG[timezone]=Europe/Brlin GI_YES=1
  run step_locale
  [ "$status" -eq 1 ]
  [[ $output == *"The timezone Europe/Brlin doesn't exist."* ]]
  [ "$(readlink "$GI_TARGET/etc/localtime")" = ../usr/share/zoneinfo/Europe/Berlin ]
}

@test "step: console-only installs get no X keyboard file" {
  CFG[desktop]=none
  step_locale
  [ ! -e "$GI_TARGET/etc/X11/xorg.conf.d/00-keyboard.conf" ]
}

@test "step: running it twice gives the same files" {
  step_locale
  cp -a "$GI_TARGET/etc" "$BATS_TEST_TMPDIR/first"
  step_locale
  diff -r --no-dereference "$BATS_TEST_TMPDIR/first" "$GI_TARGET/etc"
  [ "$(readlink "$GI_TARGET/etc/localtime")" = ../usr/share/zoneinfo/Europe/Berlin ]
}

@test "dry-run: prints everything, runs and writes nothing" {
  GI_DRY_RUN=1
  cp -a "$GI_TARGET/etc" "$BATS_TEST_TMPDIR/before"
  run --separate-stderr step_locale_portage
  [ "$status" -eq 0 ]
  run --separate-stderr step_locale
  [ "$status" -eq 0 ]
  [[ $stderr == *"eselect locale set en_US.UTF-8"* ]]
  [ ! -s "$STUB_LOG" ]
  diff -r --no-dereference "$BATS_TEST_TMPDIR/before" "$GI_TARGET/etc"
}
