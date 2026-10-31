# shellcheck shell=bash
# Compile preview step: emerge --pretend on the package install, binary and source counts, and fixes.

step_define preview "Compile preview" \
  "Asks Portage what the package install will do: which packages come from the binary host, which get built here and why, so you can change settings before hours of compiling." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Base#Installing_binary_packages"

GI_PREVIEW_HEAVY=" www-client/chromium www-client/firefox dev-qt/qtwebengine net-libs/webkit-gtk llvm-core/llvm llvm-core/clang dev-lang/rust app-office/libreoffice sys-devel/gcc x11-drivers/nvidia-drivers "
declare -gA GI_PREVIEW_ALT=([www-client/firefox]=firefox-bin [app-office/libreoffice]=libreoffice-bin
  [dev-lang/rust]=rust-bin [mail-client/thunderbird]=thunderbird-bin [sys-kernel/gentoo-kernel]=gentoo-kernel-bin)

step_preview() {
  local out=$GI_RUN_DIR/preview.txt rc choice
  if ((GI_DRY_RUN)); then
    info "Dry run: skipping the compile preview, which needs the new system. It would run: $(world_with_args echo emerge --pretend --verbose)"
    return 0
  fi
  portage_refresh
  while :; do
    rc=0
    _preview_pretend "$out" || rc=$?
    # emerge exits 130 on Ctrl+C. The runner asks whether to stop and offers Retry if not.
    if ((rc == 130)); then exit 130; fi
    if ((rc == 0)); then
      choice=$(_preview_ask_ok "$out")
    else
      choice=$(_preview_ask_failed "$out")
    fi
    case $choice in
      install) return 0 ;;
      settings)
        questions_hub || true
        # Measures the mirrors if the answer is now fastest. Before cfg_save, so a failed
        # measurement stops the step with the earlier answers still saved.
        stage3_mirrors > /dev/null
        cfg_save
        portage_refresh
        ;;
      unmask) _preview_unmask "$out" ;;
      abort)
        log INFO "aborted by the user at the compile preview"
        # The runner stops at once: only Ctrl+C sets GI_INTERRUPTED, which would bring its error menu.
        exit 130
        ;;
      *) return 1 ;;
    esac
  done
}

# A read-only query, so it runs directly instead of through run_chroot, to get the output.
_preview_pretend() { # FILE
  local rc=0
  progress_status "Asking Portage what it would install..."
  world_with_args arch-chroot "$GI_TARGET" emerge --pretend --verbose --color=n --autounmask=y \
    > "$1" 2>&1 < /dev/null || rc=$?
  log INFO "emerge --pretend exited with status $rc:"$'\n'"$(< "$1")"
  return "$rc"
}

# Prints install, settings or fail.
_preview_ask_ok() { # FILE
  local summary choice list=$GI_RUN_DIR/preview-list.txt
  summary=$(_preview_summary "$1" 5)
  if ((GI_YES)); then
    log INFO "compile preview:"$'\n'"$summary"
    echo install
    return 0
  fi
  {
    _preview_summary "$1" 0
    printf '\nPortage output:\n\n'
    cat -- "$1"
  } > "$list"
  while :; do
    choice=$(ui_menu "Compile preview" "$summary" install \
      install Install "Install these packages now" \
      settings "Change settings" "Go back to your answers, then check again" \
      list "Full list" "Every package built from source, then Portage's whole output") || choice=settings
    if [[ $choice != list ]]; then break; fi
    ui_textbox "Compile preview: full list" "$list"
  done
  printf '%s\n' "$choice"
}

# Prints settings, unmask, abort or fail.
_preview_ask_failed() { # FILE
  local bad suggest kind entry text="Portage can't install this package set yet." choice
  local -a items=()
  bad=$(_preview_bad_atoms "$1")
  suggest=$(_preview_autounmask "$1")
  if [[ -n $bad ]]; then text+=$'\n\n'"Packages Portage can't install:"$'\n'"$bad"; fi
  if [[ -n $suggest ]]; then
    text+=$'\n\n'"Portage suggests these changes:"
    while read -r kind entry; do text+=$'\n'"  $kind: $entry"; done <<< "$suggest"
  fi
  if ((GI_YES)); then
    error "The compile preview failed. $text"$'\n'"Portage's output is in $GI_LOG."
    echo fail
    return 0
  fi
  ui_textbox "Portage's message" "$1"
  if [[ -n $suggest ]]; then
    items+=(unmask "Apply Portage's changes" "Write the changes above to /etc/portage, then check again")
  fi
  items+=(settings "Change settings" "Go back to your answers, then check again"
    message "Portage's message" "Show Portage's whole output again"
    abort Abort "Stop now; gentooinstall --resume continues from this step later")
  while :; do
    choice=$(ui_menu "Compile preview failed" "$text" "${items[0]}" "${items[@]}") || choice=settings
    if [[ $choice != message ]]; then break; fi
    ui_textbox "Portage's message" "$1"
  done
  printf '%s\n' "$choice"
}

# Prints the counts, the download size and the source builds with Portage's reasons,
# heavy ones first, then an overlay's. MAX limits the source lines, 0 shows them all.
_preview_summary() { # FILE MAX
  local file=$1 max=$2 line block='' cpv name flags f reason bin=0 size='' n=0 r
  local -a src=() heavy=() ovl=() other=() rows=()
  local -A why=() repo=() overlays=()
  local re_pkg='^\[(binary|ebuild)[^]]*\] +([^ ]+)'
  local re_size='^Total:.*Size of downloads: (.+) KiB'
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ $re_pkg ]]; then
      cpv=${BASH_REMATCH[2]%%:*}
      # *-bin packages unpack an upstream binary and virtuals install nothing: neither compiles.
      if [[ ${BASH_REMATCH[1]} == binary || $cpv == virtual/* || $(_preview_name "$cpv") == *-bin ]]; then
        bin=$((bin + 1))
      else
        src+=("$cpv")
        # An overlay's packages are never on the binary host; Portage names the repository.
        r=${BASH_REMATCH[2]##*::}
        if [[ ${BASH_REMATCH[2]} == *::* && $r != gentoo ]]; then
          repo[$cpv]=$r
          overlays[$r]=$((${overlays[$r]:-0} + 1))
        fi
      fi
    elif [[ $line =~ $re_size ]]; then
      size=${BASH_REMATCH[1]//[!0-9]/}
    elif [[ $line == *'ignored due to non matching USE'* ]]; then
      block=use
    elif [[ $line == *'ignored due to changed dependencies'* ]]; then
      block=deps
    elif [[ $line == NOTE:* ]]; then
      block=''
    elif [[ $block == use && $line =~ ^\ +=([^ ]+)\ (.+)$ ]]; then
      cpv=${BASH_REMATCH[1]} flags=''
      read -ra rows <<< "${BASH_REMATCH[2]}"
      # Portage shows the binary's flags; the user's side is the opposite.
      for f in "${rows[@]}"; do
        if [[ $f == -* ]]; then flags+=" +${f#-}"; else flags+=" -$f"; fi
      done
      # One line per binary on the host; the shortest is the closest match.
      if [[ -z ${why[$cpv]:-} || ${#flags} -lt ${#why[$cpv]} ]]; then why[$cpv]=$flags; fi
    elif [[ $block == deps && $line =~ ^\ +([^ :]+):: ]]; then
      why[${BASH_REMATCH[1]}]=${why[${BASH_REMATCH[1]}]:-deps}
    fi
  done < "$file"

  for cpv in "${src[@]}"; do
    name=$(_preview_name "$cpv")
    case ${why[$cpv]:-} in
      '') reason="no binary" ;;
      deps) reason="the binary's dependencies are out of date" ;;
      *) reason="your USE differs:${why[$cpv]}" ;;
    esac
    if [[ $name == x11-drivers/nvidia-drivers ]]; then reason="kernel module, always built here"; fi
    if [[ -n ${repo[$cpv]:-} ]]; then reason="from the ${repo[$cpv]} overlay"; fi
    if [[ -n ${GI_PREVIEW_ALT[$name]:-} ]]; then reason+=". Use ${GI_PREVIEW_ALT[$name]} instead?"; fi
    if [[ $GI_PREVIEW_HEAVY == *" $name "* ]]; then
      heavy+=("$(printf '! %-28s %s' "$name" "$reason")")
    elif [[ -n ${repo[$cpv]:-} ]]; then
      ovl+=("$(printf '  %-28s %s' "$name" "$reason")")
    else
      other+=("$(printf '  %-28s %s' "$name" "$reason")")
    fi
  done

  printf '%d packages' $((bin + ${#src[@]}))
  if [[ -n $size ]]; then printf ', %s to download' "$(_preview_size "$size")"; fi
  printf '\n%7d install as binaries\n%7d build from source\n' "$bin" "${#src[@]}"
  for r in "${!overlays[@]}"; do
    printf "%7s %d of them from the %s overlay, which Gentoo doesn't review\n" '' "${overlays[$r]}" "$r"
  done
  ((${#src[@]})) || return 0
  printf '\nBuilt from source (! = heavy):\n'
  for line in "${heavy[@]}" "${ovl[@]}" "${other[@]}"; do
    if ((max && n == max)); then
      printf '  ...%d more (Full list)\n' $((${#src[@]} - max))
      break
    fi
    printf '%s\n' "$line"
    n=$((n + 1))
  done
}

# category/name of a category/name-version.
_preview_name() {
  if [[ $1 =~ ^(.+)-[0-9][^/]*$ ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; else printf '%s\n' "$1"; fi
}

_preview_size() { # KIB
  local k=$1
  if ((k >= 1048576)); then
    printf '%d.%d GiB\n' $((k / 1048576)) $((k * 10 / 1048576 % 10))
  elif ((k >= 1024)); then
    printf '%d MiB\n' $((k / 1024))
  else
    printf '%d KiB\n' "$k"
  fi
}

# Atoms Portage couldn't satisfy (unknown, masked, or failing REQUIRED_USE), one per line.
_preview_bad_atoms() { # FILE
  local line atom
  local -a extra=()
  local re='^(emerge: there are no ebuilds|!!! All ebuilds that could satisfy|!!! The ebuild selected to satisfy)[^"]*"([^"]+)"'
  read -ra extra <<< "${CFG[packages]:-}"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ $re ]] || continue
    atom=${BASH_REMATCH[2]}
    if [[ " ${extra[*]} " == *" $atom "* ]]; then atom+=" (one of your extra packages)"; fi
    printf '  %s\n' "$atom"
  done < "$1"
}

# Portage's autounmask suggestions as "KIND ENTRY" lines, KIND naming the /etc/portage directory.
_preview_autounmask() { # FILE
  local line kind=''
  local re='^The following (USE|keyword|license|mask) changes are necessary to proceed:'
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ $re ]]; then
      case ${BASH_REMATCH[1]} in
        USE) kind=package.use ;;
        keyword) kind=package.accept_keywords ;;
        license) kind=package.license ;;
        mask) kind=package.unmask ;;
      esac
    elif [[ -z $line ]]; then
      kind=''
    elif [[ -n $kind && $line != '#'* && $line != ' (see '* ]]; then
      printf '%s %s\n' "$kind" "$line"
    fi
  done < "$1"
}

# Runs only after the user chose to apply Portage's suggestions.
_preview_unmask() { # FILE
  local kind entry
  local -a lines=()
  mapfile -t lines < <(_preview_autounmask "$1")
  for entry in "${lines[@]}"; do
    kind=${entry%% *}
    ensure_line "/etc/portage/$kind/zz-autounmask" "${entry#* }"
    info "Added to /etc/portage/$kind/zz-autounmask: ${entry#* }"
  done
}
