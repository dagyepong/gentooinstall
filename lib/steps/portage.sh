# shellcheck shell=bash
# Portage setup step: repository snapshot, news, profile, make.conf, binary host and every step's Portage hooks.

GI_PROFILE_VERSION=23.0

step_define portage "Portage setup" \
  "Downloads a verified snapshot of the Gentoo package repository, selects the profile for your desktop and init system, and writes make.conf and the binary package host settings, so the package install can use prebuilt packages." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Base#Configuring_Portage"

step_portage() {
  local s3 mirrors ts=$GI_TARGET/var/db/repos/gentoo/metadata/timestamp.x
  s3=$(state_get stage3.file)
  case $s3 in
    '') ;;
    *-systemd-*) is_systemd || die "The stage3 $s3 is a systemd one, but the init system is ${CFG[init]}." ;;
    *) is_openrc || die "The stage3 $s3 is an OpenRC one, but the init system is ${CFG[init]}." ;;
  esac
  # emerge-webrsync rsyncs the snapshot into place in name order, so timestamp.x lands before
  # net-*, profiles and sys-*. Only the state key proves a finished sync. Without timestamp.x
  # webrsync syncs again instead of calling a half-copied tree up to date.
  if [[ $(state_get portage.synced) != yes || ! -e $ts ]]; then
    if [[ -e $ts ]]; then run_cmd rm -f -- "$ts"; fi
    # make.conf isn't written yet, so the chosen mirrors go in through the environment.
    mirrors=$(stage3_mirrors)
    run_chroot env "GENTOO_MIRRORS=$mirrors" emerge-webrsync
    state_set portage.synced yes
  fi
  # Lists the news in the log without marking it read; the finish step shows what's unread.
  # eselect exits 1 when it listed any item, which a fresh tree always has.
  run_chroot eselect news list || true
  portage_configure
}

# Writes the profile, make.conf, binrepos.conf and CPU flags, then runs every step's Portage hook.
portage_configure() {
  local profile list mirrors id
  # Cleared first, so a run that stops halfway is redone by portage_refresh.
  state_set portage.answers ''
  # The answer may have changed since the stage3 step, in the compile preview or on --resume.
  mirrors=$(stage3_mirrors) || return
  profile=$(_portage_profile)
  list=$(dry_value "  [1]   $profile (stable)" arch-chroot "$GI_TARGET" eselect profile list) || return
  [[ $list == *" $profile "* ]] ||
    die "The profile $profile isn't in eselect profile list. Gentoo has probably moved past profile $GI_PROFILE_VERSION; this gentooinstall needs an update."
  run_chroot eselect profile set "$profile"
  _portage_make_conf "$mirrors"

  if [[ ${CFG[binpkgs]} == yes ]]; then
    _portage_binrepos "${mirrors%% *}"
    run_chroot getuto
  fi

  # A CPU_FLAGS_X86 that differs from the profile default makes every package using it miss the binary host.
  if [[ ${CFG[binpkgs]} == no || ${CFG[tune]} == yes ]]; then
    if [[ -n ${HW[cpu_flags]:-} ]]; then
      printf '*/* CPU_FLAGS_X86: %s\n' "${HW[cpu_flags]}" | portage_file package.use 00cpu-flags
    else
      warn "cpuid2cpuflags found no CPU flags; keeping the profile's CPU_FLAGS_X86."
    fi
  elif [[ -e $GI_TARGET/etc/portage/package.use/00cpu-flags ]]; then
    run_cmd rm -f -- "$GI_TARGET/etc/portage/package.use/00cpu-flags"
  fi
  _portage_repos

  for id in "${GI_STEPS[@]}"; do
    if declare -F "step_${id}_portage" > /dev/null; then "step_${id}_portage"; fi
  done
  state_set portage.answers "$(_portage_answers)"
}

# Runs portage_configure unless it last finished with the current answers. The compile preview and
# the package install call it first: a settings change that failed halfway or a resume with a new
# --config gets matching files, and a retry redoes nothing and keeps fixes made in the error menu's shell.
portage_refresh() {
  local now
  now=$(_portage_answers)
  if [[ -z $now || $(state_get portage.answers) != "$now" ]]; then portage_configure; fi
}

# A digest of the answers Portage's files are written from.
# shortcut: HW is left out, so a resume on another machine keeps the first one's MAKEOPTS and CPU flags; add it if that matters.
_portage_answers() {
  local k
  for k in "${GI_CFG_KEYS[@]}"; do
    if [[ -n ${CFG[$k]+x} ]]; then printf '%s=%s\n' "$k" "${CFG[$k]}"; fi
  done | b2sum
}

_portage_profile() {
  local p=default/linux/amd64/$GI_PROFILE_VERSION
  case ${CFG[desktop]} in
    none) ;;
    plasma | gnome) p+=/desktop/${CFG[desktop]} ;;
    *) p+=/desktop ;;
  esac
  if is_systemd; then p+=/systemd; fi
  printf '%s\n' "$p"
}

# The overlays a desktop can come from, one "NAME URL" line each. The URLs are the ones
# eselect repository uses, from Gentoo's repositories.xml; guru's mirror carries the metadata cache.
_portage_overlays() {
  printf '%s\n' 'guru https://github.com/gentoo-mirror/guru.git' \
    'hyproverlay https://codeberg.org/hyproverlay/hyproverlay.git' \
    'SarahMiaOverlay https://gitlab.com/SarahMia/sarahmiaoverlay.git'
}

# Prints the overlay the chosen desktop comes from, or nothing.
_portage_overlay() {
  case ${CFG[desktop]} in
    budgie) echo SarahMiaOverlay ;;
    hyprland) echo hyproverlay ;;
    niri | mangowm) echo guru ;;
  esac
}

# Adds the desktop's overlay as a plain repos.conf entry with git sync, and removes one an earlier
# answer added. The stage3 has no git, so the first copy comes from the live system's git, which
# the minimal ISO ships; the package install adds git, so emerge --sync updates it later.
_portage_repos() {
  local want name url conf dir
  want=$(_portage_overlay)
  while read -r name url; do
    conf=/etc/portage/repos.conf/$name.conf dir=/var/db/repos/$name
    if [[ $name != "$want" ]]; then
      if [[ -e $GI_TARGET$conf ]]; then run_cmd rm -f -- "$GI_TARGET$conf"; fi
      # .new is a clone that stopped halfway.
      if [[ -e $GI_TARGET$dir || -e $GI_TARGET$dir.new ]]; then run_cmd rm -rf -- "$GI_TARGET$dir" "$GI_TARGET$dir.new"; fi
      continue
    fi
    # No priority line, so at equal versions the overlay's copy beats ::gentoo's: hyproverlay's
    # waybar-0.15.0 carries the patch for Hyprland's Lua IPC. No tie in any install set has a binary.
    printf '[%s]\nlocation = %s\nsync-type = git\nsync-uri = %s\n' "$name" "$dir" "$url" | write_file "$conf"
    [[ ! -d $GI_TARGET$dir ]] || continue
    command -v git > /dev/null || die "The ${CFG[desktop]} desktop comes from the $name overlay, and copying it needs git, which this live system doesn't have."
    # Cloned beside its place and moved there when complete, so a clone that stopped halfway
    # can't pass for the overlay on a retry.
    if [[ -e $GI_TARGET$dir.new ]]; then run_cmd rm -rf -- "$GI_TARGET$dir.new"; fi
    # Codeberg and GitLab answer a moved or deleted repository with a login request, for which
    # git would wait on the terminal; it fails instead.
    GIT_TERMINAL_PROMPT=0 run_cmd git clone --depth 1 --quiet -- "$url" "$GI_TARGET$dir.new" || return
    run_cmd mv -- "$GI_TARGET$dir.new" "$GI_TARGET$dir"
  done < <(_portage_overlays)
}

# git, so emerge --sync can update the overlay later.
step_portage_packages() {
  if [[ -n $(_portage_overlay) ]]; then echo dev-vcs/git; fi
}

# Prints how many compiler jobs fit in RAM at the Handbook's 2 GiB each, at least 1.
_portage_ram_jobs() {
  local m=${HW[ram_mib]:-}
  [[ $m =~ ^[0-9]+$ ]] || m=0
  # MemTotal is a little under the installed RAM, so round to the nearest GiB.
  m=$(((m + 512) / 1024 / 2))
  if ((m < 1)); then m=1; fi
  printf '%s\n' "$m"
}

# Prints N = min(CPU threads, RAM in GiB / 2), at least 1.
_portage_jobs() {
  local t=${HW[cpu_threads]:-} r
  [[ $t =~ ^[0-9]+$ ]] || t=1
  r=$(_portage_ram_jobs)
  if ((r < t)); then t=$r; fi
  if ((t < 1)); then t=1; fi
  printf '%s\n' "$t"
}

# Prints the emerge job count for N compiler jobs per package.
_portage_emerge_jobs() { # N
  local j=$1
  # Without binary packages nearly every package compiles, and the Handbook warns that
  # parallel emerges multiply the compiler jobs, so emerge jobs times N must fit in RAM.
  if [[ ${CFG[binpkgs]} == no ]]; then j=$(($(_portage_ram_jobs) / $1)); fi
  if ((j < 1)); then j=1; fi
  printf '%s\n' "$j"
}

# Prints emerge's --load-average for N compiler jobs per package.
_portage_load() { # N
  local l=$1
  # emerge starts no job at all, binary or source, at this load, and one -jN compile keeps it
  # near N. With binary packages the limit may rise to the compiler jobs RAM holds at 2 GiB each,
  # at most 2N, so unpacks go on beside a compile, but a second compile doesn't start where RAM
  # has no room for it: 16 GiB with 8 threads stays at 8, 32 GiB gets 16.
  if [[ ${CFG[binpkgs]} == yes ]]; then
    l=$(_portage_ram_jobs)
    if ((l > 2 * $1)); then l=$((2 * $1)); fi
  fi
  printf '%s\n' "$l"
}

_portage_make_conf() { # MIRRORS
  local n jobs makeopts load
  n=$(_portage_jobs)
  jobs=$(_portage_emerge_jobs "$n")
  load=$(_portage_load "$n")
  if [[ ${CFG[emerge_jobs]} != auto ]]; then jobs=${CFG[emerge_jobs]}; fi
  makeopts="-j$n -l$n"
  if [[ ${CFG[makeopts]} != auto ]]; then makeopts=${CFG[makeopts]}; fi
  {
    cat << EOF
# Written by gentooinstall, which rewrites this file each time its Portage setup runs.

# Compiler flags for packages built on this machine. Binary packages come prebuilt.
COMMON_FLAGS="${CFG[cflags]}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
EOF
    if [[ " ${CFG[cflags]} " == *" -march=native "* ]]; then
      cat << 'EOF'
# Rust code gets the same CPU tuning as -march=native gives C and C++.
RUSTFLAGS="${RUSTFLAGS} -C target-cpu=native"
EOF
    fi
    cat << EOF

# Compiler jobs per package. The default allows one per CPU thread and per 2 GiB of RAM.
MAKEOPTS="$makeopts"
# Packages emerge works on at once, and the load above which it starts no more.
# With binary packages most jobs only unpack, so jobs default to the MAKEOPTS count, and the
# load limit goes up to twice it as far as RAM allows 2 GiB per compiler job, so unpacks go on
# while a package compiles.
# Without them each job may compile, so jobs times MAKEOPTS stay within RAM / 2 GiB.
EMERGE_DEFAULT_OPTS="--jobs=$jobs --load-average=$load"
EOF
    if [[ ${CFG[binpkgs]} == yes ]]; then
      cat << 'EOF'
# Install signed binary packages from the Gentoo binary host when they match.
FEATURES="${FEATURES} getbinpkg binpkg-request-signature"
EOF
    fi
    cat << EOF
# Free software plus firmware and drivers that may be redistributed as binaries.
# Any other license a package needs goes in /etc/portage/package.license/.
ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"

# Mirrors for source code and repository snapshots.
GENTOO_MIRRORS="$1"
EOF
    # The binary host builds without L10N, so setting it pushes packages like hunspell to source builds.
    if [[ ${CFG[binpkgs]} == no ]]; then
      printf '# Translations and dictionaries for the chosen languages.\nL10N="%s"\n' "$(_portage_l10n)"
    fi
    cat << 'EOF'

# Build output in English, as Gentoo bug reports need it.
LC_MESSAGES=C.UTF-8
EOF
  } | write_file /etc/portage/make.conf
}

# Language tags of the chosen locales: en_US.UTF-8 zh_CN.UTF-8 gives "en en-US zh zh-CN".
# Both forms, since packages translate to zh-CN and pt-BR far more often than to zh and pt.
_portage_l10n() {
  local loc tag out=''
  local -a locs=()
  read -ra locs <<< "${CFG[locales]}"
  for loc in "${locs[@]}"; do
    loc=${loc%%[.@]*}
    for tag in "${loc%%_*}" "${loc/_/-}"; do
      if [[ " $out " != *" $tag "* ]]; then out+=${out:+ }$tag; fi
    done
  done
  printf '%s\n' "$out"
}

# Rewrites the file the stage3 ships, so its [gentoo] repo isn't defined twice.
_portage_binrepos() { # MIRROR
  local base=${1%/}/releases/amd64/binpackages/$GI_PROFILE_VERSION
  {
    printf '[gentoo]\npriority = 9959\nsync-uri = %s/x86-64/\nverify-signature = true\nlocation = /var/cache/binhost/gentoo\n' "$base"
    # Both repos, as the Handbook says: some packages have no x86-64-v3 build yet.
    if [[ ${HW[x86_64_v3]:-} == yes ]]; then
      printf '\n[gentoo-x86-64-v3]\npriority = 9999\nsync-uri = %s/x86-64-v3/\nverify-signature = true\nlocation = /var/cache/binhost/gentoo-x86-64-v3\n' "$base"
    fi
  } | write_file /etc/portage/binrepos.conf/gentoo.conf
}
