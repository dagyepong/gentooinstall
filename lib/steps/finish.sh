# shellcheck shell=bash
# Finish step and menu: cleanup, logs, first-steps notes and summary, then reboot, shell or exit.

step_define finish "Finish" \
  "Removes packages nothing needs anymore, cleans the download caches and the stage3 tarball, keeps the install logs on the new system, and leaves each user a short note on what to do next." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Finalizing" optional

step_finish() {
  local dir=/var/log/gentooinstall pkgs summary
  _finish_depclean
  # eclean-pkg crashes when PKGDIR has no Packages index, which a system installed only from
  # remote binary packages doesn't have yet (gentoolkit 0.8.1).
  run_chroot emaint binhost --fix
  run_chroot eclean-dist --deep
  run_chroot eclean-pkg --deep
  _finish_rm_stage3
  _finish_first_steps
  run_cmd install -d -m 0700 -- "$GI_TARGET$dir"
  pkgs=$(_finish_packages)
  printf '%s' "$pkgs" | write_file "$dir/packages.txt"
  summary=$(_finish_summary "$pkgs")
  printf '%s\n' "$summary" | write_file "$dir/summary.txt"
  if ((!GI_DRY_RUN)); then printf '\n%s\n' "$summary" >&2; fi
  run_cmd cp -- "$GI_LOG" "$GI_TARGET$dir/install.log"
  run_cmd cp -- "$GI_RUN_DIR/config" "$GI_RUN_DIR/replay.sh" "$GI_TARGET$dir/"
  if [[ -d $GI_RUN_DIR/build-logs ]]; then run_cmd cp -r -- "$GI_RUN_DIR/build-logs" "$GI_TARGET$dir/"; fi
}

# Runs depclean only when its pretend run removes none of the packages this install chose.
_finish_depclean() {
  local out list a line rc=0 vre='^[<>=~]+(.+)-[0-9][^/]*$' re='^ ([^ /]+/[^ ]+) *$'
  local -A chosen=()
  local -a doomed=()
  out=$(dry_value '' arch-chroot "$GI_TARGET" /bin/bash -c "$(chroot_script 'emerge --pretend --depclean')" 2>&1) || rc=$?
  log INFO "emerge --pretend --depclean (exit status $rc):"$'\n'"$out"
  ((rc == 0)) || return "$rc"
  list=$(world_packages)
  while IFS= read -r a; do
    a=${a%%:*} # drops :slot and ::repo
    if [[ $a =~ $vre ]]; then a=${BASH_REMATCH[1]}; fi
    if [[ -n $a ]]; then chosen[$a]=1; fi
  done <<< "$list"
  while IFS= read -r line; do
    if [[ $line =~ $re && -n ${chosen[${BASH_REMATCH[1]}]:-} ]]; then doomed+=("${BASH_REMATCH[1]}"); fi
  done <<< "$out"
  if ((${#doomed[@]})); then
    warn "Skipped emerge --depclean: it would remove ${doomed[*]}, which this install chose. Its full list is in the log."
    return 0
  fi
  run_chroot emerge --depclean
}

_finish_rm_stage3() {
  local f
  f=$(state_get stage3.file)
  # The name comes from the state file on the target disk, so it must not point anywhere else.
  if [[ $f == stage3-* && $f != */* ]]; then
    run_cmd rm -f -- "$GI_TARGET/$f" "$GI_TARGET/$f.asc" "$GI_TARGET/$f.DIGESTS" "$GI_TARGET/$f.sha256"
  fi
}

_finish_first_steps() {
  local u hint windows
  local -a users=()
  hint=$(_finish_desktop_hint)
  windows=$(disk_windows_esp)
  read -ra users <<< "${CFG[users]}"
  for u in "${users[@]}"; do
    {
      printf 'First steps on your new Gentoo system\n\n'
      if [[ -n $hint ]]; then printf '%s\n\n' "$hint"; fi
      if [[ -n $windows ]]; then
        printf 'Windows is in the boot menu too. If it uses BitLocker, start it from the\nfirmware boot menu instead (a key like F12, F11 or Esc while the computer\nstarts): from this menu it asks for its recovery key. The hardware clock\nkeeps local time, as Windows does.\n\n'
      fi
      if [[ ${CFG[disk_mode]} == free ]]; then
        printf 'The systems that were on the disk before are still there. Any not in the\nboot menu start from the firmware boot menu: press a key like F12, F11 or\nEsc while the computer starts.\n\n'
      fi
      printf 'Lines starting with # need root: type %s in front of them if your\naccount is an admin, or log in as root.\n\n' "${CFG[privilege]}"
      _finish_savedconfig_hint
      _finish_hyprland_hint
      _finish_limine_hint
      cat << 'EOF'
Update everything about once a week:
  # emerge --sync
  # emerge -avuDN @world
  # emerge --ask --depclean
The last command also takes old kernels out of the boot menu and deletes
their modules in /lib/modules. An old kernel that is still running stays
until the next kernel removal.

Read the Gentoo news first. It says when an update needs a manual step:
  # eselect news read

Turn package features on or off with USE flags. Put a line like
  media-video/mpv vaapi
in a file under /etc/portage/package.use/, then rebuild what changed:
  # emerge -avuDN @world
See what a package's flags do with: equery uses media-video/mpv

The install log, your answers and every command the installer ran are in
/var/log/gentooinstall/ (readable by root).

Everything else is in the Gentoo Handbook:
  https://wiki.gentoo.org/wiki/Handbook:AMD64
EOF
    } | write_file "/home/$u/first-steps.txt"
    run_chroot chown "$u:" "/home/$u/first-steps.txt"
  done
}

# How to start a desktop that has no login screen; prints nothing when there's no such desktop.
_finish_desktop_hint() {
  local cmd why=''
  [[ ${CFG[desktop]} != none && -z $(_desktop_dm) ]] || return 0
  cmd=$(desktop_start_cmd)
  if [[ $cmd == *gentoo-pipewire-launcher* ]]; then why=$'\nThat starts a D-Bus session and PipeWire for sound first.'; fi
  printf 'There is no login screen: the system starts to a text console. Log in there,\nthen start the desktop with:\n  %s%s\n' "$cmd" "$why"
}

# dwm and dwl are set up by rebuilding them, through Portage's savedconfig.
_finish_savedconfig_hint() {
  local pkg cat
  case ${CFG[desktop]} in
    dwm) cat=x11-wm pkg=dwm ;;
    dwl) cat=gui-wm pkg=dwl ;;
    *) return 0 ;;
  esac
  # No cd or redirection in the root lines: they must work with sudo or doas in front.
  cat << EOF
$pkg reads its keys, colors and programs from config.h when it is built.
To change them, keep your copy of that file under the name $pkg:
  # mv /etc/portage/savedconfig/$cat/$pkg-* /etc/portage/savedconfig/$cat/$pkg
Edit it, add the line "$cat/$pkg savedconfig" to the file
/etc/portage/package.use/$pkg, then rebuild:
  # emerge --oneshot $cat/$pkg
Each build saves a copy named $pkg-VERSION, which wins over $pkg, so run the
mv again before you edit it the next time.

EOF
}

# The desktop step's /etc/xdg/hypr/hyprland.lua stands in for the config Hyprland would write itself.
_finish_hyprland_hint() {
  [[ ${CFG[desktop]} == hyprland ]] || return 0
  cat << 'EOF'
Hyprland reads /etc/xdg/hypr/hyprland.lua while ~/.config/hypr/hyprland.lua
doesn't exist. It runs Hyprland's example config and sets your keyboard layout.
To make your own config, copy /usr/share/hypr/hyprland.lua to
~/.config/hypr/hyprland.lua and add the keyboard line from the end of
/etc/xdg/hypr/hyprland.lua to it.
Super+E starts Dolphin, which isn't installed: set fileManager in your copy,
or install it with:
  # emerge --ask kde-apps/dolphin

EOF
}

# The kernel step's plugin writes Limine's menu, and its Portage hook copies a new loader to the ESP.
_finish_limine_hint() {
  [[ ${CFG[bootloader]} == limine ]] || return 0
  cat << 'EOF'
Limine starts this system. Its menu, /efi/limine.conf, is rewritten on every
kernel install and removal; change its settings in
/etc/kernel/install.d/95-limine.install. An update of sys-boot/limine copies
its new loader to the EFI partition by itself.

EOF
}

# One "category/package-version binary|source" line per installed package. Portage writes
# BINPKGMD5 only when it merges a binary package (make.conf has no buildpkg); the stage3's
# packages have it too, since they came prebuilt.
_finish_packages() {
  local d kind
  for d in "$GI_TARGET"/var/db/pkg/*/*/; do
    [[ -d $d ]] || continue
    d=${d%/}
    kind=source
    if [[ -e $d/BINPKGMD5 ]]; then kind=binary; fi
    printf '%s %s\n' "${d#"$GI_TARGET/var/db/pkg/"}" "$kind"
  done
}

_finish_summary() { # PACKAGE_LIST
  local start s kind id line bin=0 src=0 skipped='' re='^[0-9-]{10} [0-9:]{8} WARN (.*)$'
  local -a warnings=() news=()
  while read -r _ kind; do
    case $kind in
      binary) bin=$((bin + 1)) ;;
      source) src=$((src + 1)) ;;
    esac
  done <<< "$1"
  for id in "${GI_STEPS[@]}"; do
    if [[ $(state_get "step.$id") == skipped ]]; then skipped+=" $id"; fi
  done
  if [[ -f $GI_LOG ]]; then
    while IFS= read -r line; do
      if [[ $line =~ $re ]]; then warnings+=("  ${BASH_REMATCH[1]}"); fi
    done < "$GI_LOG"
  fi
  mapfile -t news < <(_finish_news)
  start=$(state_get install.started)
  # steps_run sets it before the first step; the check keeps a damaged state file out of the arithmetic.
  [[ $start =~ ^[0-9]+$ ]] || start=$EPOCHSECONDS
  s=$((EPOCHSECONDS - start))
  # The live system's clock may have been set back by the time sync after the start.
  if ((s < 0)); then s=0; fi
  printf 'Gentoo is installed. The install took %dh %02dm.\n' $((s / 3600)) $((s % 3600 / 60))
  printf 'Packages: %d from binary packages, %d built from source.\n' "$bin" "$src"
  printf 'Skipped steps:%s\n' "${skipped:- none}"
  if ((${#warnings[@]})); then printf 'Warnings:\n'; printf '%s\n' "${warnings[@]}"; else printf 'Warnings: none\n'; fi
  if ((${#news[@]})); then
    printf 'Unread Gentoo news (read it with: eselect news read):\n'
    printf '%s\n' "${news[@]}"
  fi
  printf 'Logs and the package list: /var/log/gentooinstall/\n'
  _finish_desktop_hint
}

_finish_news() {
  local f=$GI_TARGET/var/lib/gentoo/news/news-gentoo.unread n t line
  [[ -f $f ]] || return 0
  while IFS= read -r n; do
    t=$GI_TARGET/var/db/repos/gentoo/metadata/news/$n/$n.en.txt
    [[ -n $n && -f $t ]] || continue
    while IFS= read -r line; do
      if [[ $line == 'Title: '* ]]; then
        printf '  %s  %s\n' "${n:0:10}" "${line#Title: }"
        break
      fi
    done < "$t"
  done < "$f"
}

finish_menu() {
  local choice=exit summary=$GI_TARGET/var/log/gentooinstall/summary.txt
  if ((GI_DRY_RUN)); then return 0; fi
  if ((!GI_YES)); then
    # dialog draws over the summary the finish step printed.
    if [[ $GI_UI == dialog && -f $summary ]]; then ui_textbox "Install summary" "$summary"; fi
    while :; do
      choice=$(ui_menu "Install complete" "Gentoo is installed. What next?" reboot \
        reboot Reboot "Unmount everything and restart into the new system" \
        shell Shell "Open a shell inside the new system; type exit to come back here" \
        exit Exit "Unmount everything and go back to the live system") || continue
      [[ $choice == shell ]] || break
      # Inside, the prompt still shows the live system's host name.
      info "Starting a shell in the new system at $GI_TARGET. Type exit to come back to this menu."
      run_interactive arch-chroot "$GI_TARGET" || true
    done
  fi
  _finish_unmount
  if [[ $choice == reboot ]]; then
    info "Rebooting. Remove the USB stick while the machine restarts."
    run_cmd reboot
  else
    info "Done. Remove the USB stick before the next boot."
  fi
}

_finish_unmount() {
  local swapfile luks=''
  # The installer's own working directory would keep the target busy.
  if [[ $PWD/ == "$GI_TARGET"/* ]]; then cd /; fi
  if [[ ${CFG[encryption]} == luks2 ]]; then luks=' && cryptsetup close root'; fi
  swapfile=$(state_get disk.swapfile)
  if [[ -n $swapfile ]]; then run_cmd swapoff "$GI_TARGET$swapfile" || warn "Couldn't turn off the swap file $GI_TARGET$swapfile."; fi
  # A busy target fails at once (umount doesn't wait), and LUKS can't close while it's mounted.
  if ! run_cmd umount -R "$GI_TARGET"; then
    warn "Couldn't unmount $GI_TARGET: a program still uses it, like a shell in another terminal whose current directory is in it (fuser -vm $GI_TARGET lists them). A reboot stops them and unmounts it safely. To finish without rebooting, close them, then run: umount -R $GI_TARGET$luks"
  elif [[ -n $luks ]]; then
    run_cmd cryptsetup close root || warn "Couldn't close /dev/mapper/root."
  fi
  run_cmd sync
}
