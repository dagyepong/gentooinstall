# shellcheck shell=bash
# Stage3 step: pick mirrors, download and verify the newest stage3, unpack it, check timezone and locales.

step_define stage3 "Stage3" \
  "Download the newest hardened stage3 for the chosen init system, check it with the Gentoo release keys and its signed checksums, and unpack it as the base of the new system." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Stage"

step_stage3() {
  # Always use the hardened Stage 3 for the selected init system.
  local variant=hardened-${CFG[init]} file mirrors

  mirrors=$(stage3_mirrors)
  file=$(state_get stage3.file)

  # Set once the tarball is verified, right before it's unpacked. A retry or resume unpacks that
  # one again: another stage3 on top would mix two package databases. The profile still follows
  # a desktop answer changed since, as it does after a change in the compile preview.
  if [[ -z $file ]]; then
    _stage3_download "${mirrors%% *}" "$variant"
    file=$(state_get stage3.file)
  elif [[ $file == */* || ! -f $GI_TARGET/$file ]]; then
    die "An earlier attempt unpacked $file into $GI_TARGET, and that file is gone, so it can't be unpacked again. Start over without --resume."
  elif [[ $file != stage3-amd64-"$variant"-* ]]; then
    info "Keeping $file, which an earlier attempt unpacked, although the answers now pick stage3-amd64-$variant."
  fi

  run_cmd tar xpf "$GI_TARGET/$file" --xattrs-include='*.*' --numeric-owner -C "$GI_TARGET"

  # No stage3 has /etc/resolv.conf, and arch-chroot binds the live one only over an existing
  # file, so without this copy nothing in the chroot resolves names. Not written through a link.
  run_cmd cp --dereference --remove-destination "${GI_HOST_ROOT:-}/etc/resolv.conf" "$GI_TARGET/etc/resolv.conf"

  if ((!GI_DRY_RUN)); then
    stage3_check_answers
  fi
}

# Prints the mirror base URLs for the mirror answer. For fastest, the first call measures them
# with mirrorselect and keeps them in mirror.fastest, so later calls and a resume reuse them.
# Called as $(...): call it as an assignment of its own, so a failed measurement stops the step.
stage3_mirrors() {
  local u out=''
  local -a found=()

  case ${CFG[mirror]} in
    cdn)
      echo https://distfiles.gentoo.org
      ;;
    fastest)
      if [[ -z $(state_get mirror.fastest) ]]; then
        _stage3_measure
      fi

      # The ISO's mirrorselect measures with netselect, which can name a mirror by one of its IP
      # addresses. No mirror's certificate covers an IP, so HTTPS to one fails: drop them.
      read -ra found <<< "$(state_get mirror.fastest)"
      for u in "${found[@]}"; do
        [[ $u =~ ^https://([0-9.]+|\[[0-9A-Fa-f:.]+\])(:[0-9]+)?(/|$) ]] || out+=${out:+ }$u
      done
      echo "${out:-https://distfiles.gentoo.org}"
      ;;
    *)
      printf '%s\n' "${CFG[mirror]}"
      ;;
  esac
}

_stage3_measure() {
  local out u urls='' next="Retry, or stop and resume with mirror=cdn in a --config file."
  local -a words=()

  info "Looking for the fastest mirrors with mirrorselect. This can take several minutes."

  # -S: https only. Without it some hosts come back as ftp, which serves binary packages poorly.
  out=$(mirrorselect -S -s3 -b10 -o) || die "mirrorselect failed. $next"

  # It prints GENTOO_MIRRORS="url \<newline>    url", the form make.conf takes.
  [[ $out == *'GENTOO_MIRRORS="'*\"* ]] || die "mirrorselect printed no GENTOO_MIRRORS line. $next"
  out=${out#*GENTOO_MIRRORS=\"}
  out=${out%%\"*}
  out=${out//\\/ }

  read -ra words <<< "${out//$'\n'/ }"
  for u in "${words[@]}"; do
    [[ $u =~ ^https://[^[:space:]]+$ ]] || die "mirrorselect printed something that isn't an https mirror URL: $u"
    urls+=${urls:+ }$u
  done

  [[ -n $urls ]] || die "mirrorselect found no mirrors. $next"
  state_set mirror.fastest "$urls"
}

# Reads the stage3 name from the signed pointer file, downloads it and verifies it; sets stage3.file.
_stage3_download() { # MIRROR VARIANT
  local base=${1%/}/releases/amd64/autobuilds
  local gpgdir=$GI_RUN_DIR/gnupg
  local ptr=$GI_RUN_DIR/latest-stage3-amd64-$2.txt
  local found path size file attempt ext old ok=0

  # A keyring of its own keeps the live system's root keyring untouched.
  run_cmd rm -rf "$gpgdir"
  run_cmd mkdir -m 0700 "$gpgdir"
  run_cmd gpg --homedir "$gpgdir" --batch --import /usr/share/openpgp-keys/gentoo-release.asc
  run_cmd curl -fsSL --retry 5 -o "$ptr" "$base/latest-stage3-amd64-$2.txt"

  # gpg writes only the signed lines to --output, so unsigned text around them is never read.
  run_cmd gpg --homedir "$gpgdir" --batch --yes --output "$ptr.verified" --verify "$ptr"

  found=$(dry_value "<date>/stage3-amd64-$2-<date>.tar.xz 0" _stage3_pointer "$ptr.verified" "$2")
  read -r path size <<< "$found"
  file=${path##*/}

  # An earlier attempt's download of another stage3 (an older pointer, or the variant of earlier
  # answers) would stay in the new system's root, since the finish step deletes only this one.
  for old in "$GI_TARGET"/stage3-*; do
    if [[ -f $old && ${old##*/} != "$file"* ]]; then
      run_cmd rm -f -- "$old"
    fi
  done

  for attempt in 1 2; do
    _stage3_fetch "$base/$path" "$GI_TARGET/$file" "$size"

    for ext in .asc .DIGESTS .sha256; do
      run_cmd curl -fsSL --retry 5 -o "$GI_TARGET/$file$ext" "$base/$path$ext"
    done

    if _stage3_verify "$gpgdir" "$GI_TARGET/$file"; then
      ok=1
      break
    fi

    run_cmd rm -f "$GI_TARGET/$file" "$GI_TARGET/$file.asc" "$GI_TARGET/$file.DIGESTS" "$GI_TARGET/$file.sha256"
    warn "The stage3 failed verification (attempt $attempt of 2) and was deleted."
  done

  # The key import started a gpg-agent for this keyring; failing to stop it is harmless.
  run_cmd gpgconf --homedir "$gpgdir" --kill all || true

  ((ok)) || die "The stage3 failed verification twice. The mirror may be broken; try another one."
  state_set stage3.file "$file"
}

# Prints "PATH SIZE" for the tarball named in a verified pointer file.
_stage3_pointer() { # FILE VARIANT
  local line re="^([A-Za-z0-9._-]+/stage3-amd64-$2-[A-Za-z0-9._-]+\.tar\.xz) ([0-9]+)\$"

  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then
      printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      return 0
    fi
  done < "$1"

  error "$1 names no stage3-amd64-$2 tarball."
  return 1
}

_stage3_fetch() { # URL FILE SIZE
  local me=$BASHPID pid='' have rc=0

  # curl stays in the foreground: a background job ignores Ctrl+C, so it would keep writing after
  # the step stopped, and a retry would append a second download to the same file.
  # The progress loop is the background job instead; it ends with this step at the latest.
  if (($3)) && [[ -t 2 ]]; then
    while kill -0 "$me" 2> /dev/null; do
      have=$(stat -c %s -- "$2" 2> /dev/null) || have=0
      progress_status "Downloading ${2##*/}: $((have * 100 / $3))% of $(($3 >> 20)) MiB"
      sleep 1
    done &
    pid=$!
  fi

  run_cmd curl -fsSL --retry 5 --retry-all-errors -C - -o "$2" "$1" || rc=$?
  if [[ -n $pid ]]; then
    kill "$pid" 2> /dev/null || true
  fi
  return "$rc"
}

_stage3_verify() { # GPGDIR TARBALL
  local t=$2 name=${2##*/}
  local digests=$GI_RUN_DIR/${2##*/}.DIGESTS.verified
  local sum

  run_cmd gpg --homedir "$1" --batch --verify "$t.asc" "$t" || return 1
  run_cmd gpg --homedir "$1" --batch --yes --output "$digests" --verify "$t.DIGESTS" || return 1

  if ((GI_DRY_RUN)); then
    return 0
  fi

  read -r sum _ < <(sha512sum -- "$t")
  [[ -n $sum && $sum == "$(_stage3_digest "$digests" SHA512 "$name")" ]] || return 1

  read -r sum _ < <(b2sum -- "$t")
  [[ -n $sum && $sum == "$(_stage3_digest "$digests" BLAKE2B "$name")" ]] || return 1
}

# Prints the hash a DIGESTS file lists for NAME under "# ALGO HASH".
_stage3_digest() { # FILE ALGO NAME
  local line algo=''

  while IFS= read -r line; do
    if [[ $line =~ ^#\ ([A-Z0-9]+)\ HASH$ ]]; then
      algo=${BASH_REMATCH[1]}
    elif [[ $algo == "$2" && $line =~ ^([0-9a-f]+)\ \ (.+)$ && ${BASH_REMATCH[2]} == "$3" ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$1"
}

# The ISO ships no zoneinfo or locale list, so these answers are checked against the stage3.
# The locale step checks again, for answers changed since in the compile preview or on --resume.
stage3_check_answers() {
  local tz=${CFG[timezone]} l
  local -a locs=() bad=()

  until [[ -f $GI_TARGET/usr/share/zoneinfo/$tz ]] && cfg_set timezone "$tz"; do
    ((!GI_YES)) || die "The timezone $tz doesn't exist. Set timezone to one like Europe/Berlin in a --config file and resume with it."
    tz=$(ui_input "Timezone" "There's no timezone called $tz. Type one like Europe/Berlin, or UTC." "$tz") ||
      die "No timezone chosen. Retry to type one."
  done

  while :; do
    read -ra locs <<< "${CFG[locales]}"
    bad=()

    for l in "${locs[@]}"; do
      _stage3_supported "$l" || bad+=("$l")
    done

    ((${#bad[@]})) || break
    ((!GI_YES)) || die "glibc doesn't support these locales: ${bad[*]}. Fix locales in a --config file and resume with it."

    l=$(ui_input "Locales" "glibc doesn't support: ${bad[*]}"$'\n'"Type the locales again, separated by spaces, like en_US.UTF-8 de_DE.UTF-8." "${CFG[locales]}") ||
      die "No locales chosen. Retry to type one."
    cfg_set locales "$l" || true
  done

  if [[ " ${locs[*]} " != *" ${CFG[lang]} "* ]]; then
    info "The system language ${CFG[lang]} is no longer among the locales; it is now ${locs[0]}."
    cfg_set lang "${locs[0]}"
  fi

  cfg_save
}

_stage3_supported() { # LOCALE
  local name

  while read -r name _; do
    if [[ $name == "$1" ]]; then
      return 0
    fi
  done < "$GI_TARGET/usr/share/i18n/SUPPORTED"

  return 1
}
