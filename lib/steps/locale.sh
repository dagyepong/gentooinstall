# shellcheck shell=bash
# Locale step: timezone, locales, system language, console and desktop keyboard, hardware clock
# (UTC, or local time beside Windows).

step_define locale "Time, locale and keyboard" \
  "Sets the timezone, builds the chosen locales, picks the system language and sets the console and desktop keyboard layout. The console keymap is written before the kernel is installed, so the initramfs asks for the LUKS passphrase with the right layout." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Base#Timezone"

# The initramfs copies the console keymap while the kernel installs during the world step.
step_locale_portage() {
  if is_openrc; then
    set_shell_var /etc/conf.d/keymaps keymap "${CFG[keymap]}"
  else
    printf 'KEYMAP=%s\n' "${CFG[keymap]}" | write_file /etc/vconsole.conf
  fi
}

step_locale() {
  local loc rtc=UTC
  if ((!GI_DRY_RUN)); then stage3_check_answers; fi
  # Again, for a keymap a --resume --config changed after the package install: the kernel step,
  # which runs next, rebuilds the initramfs with it.
  step_locale_portage
  run_cmd ln -sfn "../usr/share/zoneinfo/${CFG[timezone]}" "$GI_TARGET/etc/localtime"
  # The stage3's /etc/timezone says UTC, and some programs (Java) read it before /etc/localtime.
  run_cmd rm -f "$GI_TARGET/etc/timezone"
  for loc in ${CFG[locales]}; do _locale_gen_line "$loc"; done | write_file /etc/locale.gen
  run_chroot locale-gen
  # Every stage3 sets LANG=C.UTF-8 in /etc/env.d/02locale, which login shells read on systemd too.
  run_chroot eselect locale set "${CFG[lang]}"
  if is_systemd; then printf 'LANG=%s\n' "${CFG[lang]}" | write_file /etc/locale.conf; fi
  run_chroot env-update
  if [[ ${CFG[desktop]} != none ]]; then _locale_xorg | write_file /etc/X11/xorg.conf.d/00-keyboard.conf; fi
  # Windows keeps the hardware clock in local time, so both systems have to read it that way.
  if [[ -n $(disk_windows_esp) ]]; then rtc=local; fi
  if is_openrc; then
    set_shell_var /etc/conf.d/hwclock clock "$rtc"
  else
    printf '0.0 0 0.0\n0\n%s\n' "${rtc^^}" | write_file /etc/adjtime
  fi
}

# The locale's line from the stage3's SUPPORTED list, so non-UTF-8 locales keep their charmap.
_locale_gen_line() {
  local line=''
  if [[ -f $GI_TARGET/usr/share/i18n/SUPPORTED ]]; then
    line=$(awk -v l="$1" '$1 == l { print; exit }' "$GI_TARGET/usr/share/i18n/SUPPORTED")
  fi
  printf '%s\n' "${line:-$1}"
}

# Prints the X keyboard layout for the console keymap as four lines, layout=, model=, variant= and
# options=, in that order, each empty when unset. localectl can't run in a chroot, so this finds
# what it would set.
locale_xkb() {
  local map=$GI_TARGET/usr/share/systemd/kbd-model-map layout='' model='' variant='' options=''
  # systemd's keymap table (missing on OpenRC), then its rows for the menu's keymaps whose X layout
  # isn't the keymap name up to its first dash.
  read -r _ layout model variant options _ < <(
    {
      if [[ -f $map ]]; then cat -- "$map"; fi
      printf '%s\n' 'uk gb pc105 - terminate:ctrl_alt_bksp' \
        'sg-latin1 ch pc105 de_nodeadkeys terminate:ctrl_alt_bksp' \
        'fr_CH-latin1 ch pc105 fr terminate:ctrl_alt_bksp' \
        'sv-latin1 se pc105 - terminate:ctrl_alt_bksp' \
        'br-abnt2 br abnt2 - terminate:ctrl_alt_bksp' \
        'ru ru,us pc105 - terminate:ctrl_alt_bksp,grp:shifts_toggle,grp_led:scroll' \
        'jp106 jp jp106 - terminate:ctrl_alt_bksp' \
        'dvorak us pc105 dvorak terminate:ctrl_alt_bksp'
    } | awk -v k="${CFG[keymap]}" '$1 == k { print; exit }'
  ) || true
  # shortcut: on OpenRC a keymap typed under "Other..." gets its name up to the first dash, without a variant; ship systemd's whole table if users hit it.
  [[ -n $layout ]] || layout=${CFG[keymap]%%-*}
  # The table writes - for an unset field.
  printf 'layout=%s\nmodel=%s\nvariant=%s\noptions=%s\n' "$layout" "$model" "$variant" "$options" | sed 's/=-$/=/'
}

# The X server's keyboard file, as localectl writes it.
_locale_xorg() {
  local k v
  printf 'Section "InputClass"\n\tIdentifier "system-keyboard"\n\tMatchIsKeyboard "on"\n'
  while IFS='=' read -r k v; do
    if [[ -n $v ]]; then printf '\tOption "Xkb%s" "%s"\n' "${k^}" "$v"; fi
  done < <(locale_xkb)
  printf 'EndSection\n'
}
