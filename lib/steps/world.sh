# shellcheck shell=bash
# Install packages step: one emerge call for @world plus every package the other steps need.

step_define world "Install packages" \
  "Installs every package the chosen setup needs in one emerge call, so Portage resolves dependencies once, runs several jobs in parallel and uses binary packages wherever they match." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Base#Optional:_Updating_the_@world_set"

step_world() {
  local list
  local -a atoms=()
  # A resume with a new --config may have changed the answers since the compile preview.
  portage_refresh
  # --oneshot records nothing, so a failed run leaves nothing in the world file that a resume
  # with changed answers would keep installed.
  world_with_args emerge_run --oneshot --keep-going --verbose || return
  list=$(world_packages) || return
  read -ra atoms <<< "${list//$'\n'/ }"
  # Records them without --update, which would also record each older installed slot of a named
  # package, like the old kernel after a sync and a retry, so depclean would never remove it.
  run_chroot emerge --noreplace "${atoms[@]}"
}

# Every step's package list plus the user's extra packages, deduplicated, in step order.
world_packages() {
  local id out atom
  local -a atoms=() extra=()
  local -A seen=()
  for id in "${GI_STEPS[@]}"; do
    if declare -F "step_${id}_packages" > /dev/null; then
      out=$("step_${id}_packages") || return
      read -ra extra <<< "${out//$'\n'/ }"
      atoms+=("${extra[@]}")
    fi
  done
  read -ra extra <<< "${CFG[packages]:-}"
  for atom in "${atoms[@]}" "${extra[@]}"; do
    if [[ -n ${seen[$atom]:-} ]]; then continue; fi
    seen[$atom]=1
    printf '%s\n' "$atom"
  done
}

# Runs CMD... followed by the emerge options and atoms of the world install, so the
# compile preview checks exactly what this step installs.
world_with_args() { # CMD...
  local list
  local -a atoms=() opts=(--update --deep --newuse)
  list=$(world_packages) || return
  read -ra atoms <<< "${list//$'\n'/ }"
  if [[ ${CFG[binpkgs]} == yes ]]; then opts+=(--getbinpkg); fi
  "$@" "${opts[@]}" @world "${atoms[@]}"
}
