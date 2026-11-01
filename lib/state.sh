# shellcheck shell=bash
# Steps: registry, runner, error menu, and the state file that makes resume work.

GI_STEPS=(disk stage3 portage preview world locale kernel system network tools bootloader
  users desktop graphics hardware finish)
declare -gA GI_STEP_TITLE=() GI_STEP_WHY=() GI_STEP_HANDBOOK=() GI_STEP_OPTIONAL=()
# Set by the entry point's Ctrl+C handler when the user chose to go on.
GI_INTERRUPTED=0
# SECRET as a step started. Global: a subshell's EXIT trap runs after its function locals are gone.
declare -gA GI_STEP_SECRETS=()
# Secrets _steps_ask_secrets had typed in, which a keymap change makes wrong.
declare -gA GI_ASKED_SECRETS=()

step_define() { # ID TITLE WHY HANDBOOK [optional]
  [[ " ${GI_STEPS[*]} " == *" $1 "* ]] || die "step_define: unknown step id: $1"
  GI_STEP_TITLE[$1]=$2 GI_STEP_WHY[$1]=$3 GI_STEP_HANDBOOK[$1]=$4 GI_STEP_OPTIONAL[$1]=0
  if [[ ${5:-} == optional ]]; then GI_STEP_OPTIONAL[$1]=1; fi
}

# --- State file --------------------------------------------------------------
# The working copy is $GI_RUN_DIR/state. Once relocated, every write also goes to
# the target, so the state survives a reboot of the live system.

state_get() { # KEY [DEFAULT]
  local line
  if [[ -f $GI_RUN_DIR/state ]]; then
    while IFS= read -r line; do
      if [[ $line == "$1="* ]]; then
        printf '%s\n' "${line#*=}"
        return 0
      fi
    done < "$GI_RUN_DIR/state"
  fi
  printf '%s\n' "${2:-}"
}

state_set() { # KEY VALUE
  local key=$1 value=$2 f=$GI_RUN_DIR/state dir=$GI_TARGET/var/lib/gentooinstall line out='' found=0
  [[ $key =~ ^[A-Za-z0-9_.-]+$ ]] || die "state_set: bad key: $key"
  [[ $value != *$'\n'* ]] || die "state_set: $key must be a single line"
  if [[ -f $f ]]; then
    while IFS= read -r line; do
      if [[ $line == "$key="* ]]; then
        line="$key=$value"
        found=1
      fi
      out+=$line$'\n'
    done < "$f"
  fi
  ((found)) || out+="$key=$value"$'\n'
  _state_put "$f" "$out"
  if [[ -d $dir && $(state_get state.relocated) == yes ]]; then _state_put "$dir/state" "$out"; fi
}

_state_put() {
  printf '%s' "$2" > "$1.tmp"
  mv -f -- "$1.tmp" "$1"
}

state_step_done() { state_set "step.$1" "done"; }

state_step_is_done() {
  local v
  v=$(state_get "step.$1")
  [[ $v == "done" || $v == skipped ]]
}

state_relocate_to_target() {
  local dir=$GI_TARGET/var/lib/gentooinstall
  if ((GI_DRY_RUN)); then
    printf 'keep the install state in %s\n' "$dir" >&2
    return 0
  fi
  mkdir -p -- "$dir"
  chmod 0700 -- "$dir"
  state_set state.relocated yes
  cfg_save "$dir/config"
  log INFO "install state is now kept in $dir"
}

# --- Runner ------------------------------------------------------------------

steps_run() {
  local - # restores errexit, which the runner toggles around each step
  local id i=0 rc excerpt k keymap pkg
  cfg_defaults_apply
  cfg_lock disk disk_mode filesystem encryption swap init
  _steps_sync_config
  # Part H reports the install's duration from it, so a resume keeps the first run's value.
  if [[ -z $(state_get install.started) ]]; then state_set install.started "$EPOCHSECONDS"; fi
  progress_begin "${#GI_STEPS[@]}"
  for id in "${GI_STEPS[@]}"; do
    i=$((i + 1))
    [[ -n ${GI_STEP_TITLE[$id]:-} ]] || die "Step $id isn't defined. Is lib/steps/$id.sh missing?"
    if state_step_is_done "$id"; then continue; fi
    while :; do
      _steps_ask_secrets "${GI_STEPS[@]:i-1}"
      GI_STEP_SECRETS=()
      for k in "${!SECRET[@]}"; do GI_STEP_SECRETS[$k]=${SECRET[$k]}; done
      rm -f -- "$GI_RUN_DIR/last_failure" "$GI_RUN_DIR/secrets_changed"
      GI_INTERRUPTED=0 keymap=${CFG[keymap]}
      progress_step_start "$i" "$id" "${GI_STEP_TITLE[$id]}"
      progress_explain "${GI_STEP_WHY[$id]}" "${GI_STEP_HANDBOOK[$id]}"
      printf '\n# === Step %d/%d: %s\n# %s\n# Handbook: %s\n' "$i" "${#GI_STEPS[@]}" "${GI_STEP_TITLE[$id]}" \
        "${GI_STEP_WHY[$id]//$'\n'/$'\n'# }" "${GI_STEP_HANDBOOK[$id]}" >> "$GI_RUN_DIR/replay.sh"
      # errexit must be on inside the subshell; an if or || around it would switch it off there.
      set +e
      (
        set -e
        trap _steps_note_secrets EXIT
        if declare -F "step_$id" > /dev/null; then "step_$id"; fi
      )
      rc=$?
      set -e
      # Taken before the runner logs its own lines, so the error menu shows the step's.
      excerpt=$(tail -n 5 -- "$GI_LOG")
      # A secret the step's subshell typed or changed is lost with it; the next round asks again.
      if [[ -f $GI_RUN_DIR/secrets_changed ]]; then
        while IFS= read -r k; do unset 'SECRET[$k]'; done < "$GI_RUN_DIR/secrets_changed"
      fi
      cfg_load "$GI_RUN_DIR/config" || die "The saved config $GI_RUN_DIR/config is broken."
      _steps_sync_config
      # The compile preview's settings can change the keymap; questions_hub drops what it typed itself.
      if [[ ${CFG[keymap]} != "$keymap" ]]; then
        for k in "${!GI_ASKED_SECRETS[@]}"; do unset 'SECRET[$k]' 'GI_ASKED_SECRETS[$k]'; done
      fi
      # The step's own Abort. After Ctrl+C the user chose to go on in gi_on_int, so the menu shows.
      if ((rc == 130 && !GI_INTERRUPTED)); then
        log INFO "stopped by the user in step $id"
        exit 130
      fi
      if ((rc == 0)); then
        progress_step_end ok
        state_step_done "$id"
        break
      fi
      progress_step_end fail
      # Nobody is there to answer the error menu, unless they just pressed Ctrl+C and chose to go on.
      # The entry point's exit handler names the log.
      if ((GI_YES && !GI_INTERRUPTED)); then
        error "Step $i of ${#GI_STEPS[@]}, ${GI_STEP_TITLE[$id]}, failed with exit status $rc."
        if [[ -f $GI_RUN_DIR/last_failure ]] && pkg=$(_steps_failure_field package) && [[ -n $pkg ]]; then
          error "Package: $pkg, build log: $(_steps_failure_field build_log)"
        fi
        exit 1
      fi
      if _steps_error_menu "$id" "$i" "$rc" "$excerpt"; then continue; fi
      state_set "step.$id" skipped
      progress_step_end skip
      break
    done
  done
}

# Runs as a step's subshell exits: lists the secrets it added, changed or removed (names only).
_steps_note_secrets() {
  local k out=''
  for k in "${!SECRET[@]}" "${!GI_STEP_SECRETS[@]}"; do
    if [[ ${SECRET[$k]+x} != "${GI_STEP_SECRETS[$k]+x}" || ${SECRET[$k]-} != "${GI_STEP_SECRETS[$k]-}" ]]; then out+=$k$'\n'; fi
  done
  if [[ -n $out ]]; then printf '%s' "$out" > "$GI_RUN_DIR/secrets_changed"; fi
}

# Asks for every secret the given steps still need; with --yes a missing one is an error.
# Runs before each step, so it covers --resume and secrets typed inside the compile preview.
_steps_ask_secrets() { # STEP_ID...
  local key msg
  local -a keys=()
  mapfile -t keys < <(cfg_secrets_missing "$@")
  for key in "${keys[@]}"; do
    if ((GI_YES)); then die "The --secrets file needs $key." 2; fi
    # ui_password_twice refuses an empty value, and an open network has no key.
    if [[ $key == wifi_psk ]] && ui_yesno --defaultno "Wi-Fi key" "Is ${CFG[wifi_ssid]} an open network, with no key?"; then
      SECRET["$key"]=''
      continue
    fi
    while :; do
      SECRET["$key"]=$(ui_password_twice "Password needed" "$(_steps_secret_label "$key")") || exit 130
      if ! msg=$(cfg_secret_validate "$key" "${SECRET[$key]}"); then
        ui_msg "Password needed" "$msg"
        continue
      fi
      # Allowed, as at question time, but only after a warning.
      if [[ $key == wifi_psk ]] || ((${#SECRET[$key]} >= 16)); then break; fi
      if ui_yesno "Password needed" "It's shorter than the 16 characters the Handbook suggests. Keep it anyway? Choose No to type another."; then break; fi
    done
    GI_ASKED_SECRETS[$key]=1
  done
}

_steps_secret_label() {
  case $1 in
    luks_passphrase) echo "LUKS passphrase for the root partition:" ;;
    root_password) echo "Password for root:" ;;
    wifi_psk) echo "Key for the Wi-Fi network ${CFG[wifi_ssid]}:" ;;
    *)
      local u=${1#user.}
      printf 'Password for user %s:\n' "${u%.password}"
      ;;
  esac
}

# Steps change answers by calling cfg_save; the runner reloads that file after each step.
_steps_sync_config() {
  cfg_save "$GI_RUN_DIR/config"
  if [[ $(state_get state.relocated) == yes ]]; then cfg_save "$GI_TARGET/var/lib/gentooinstall/config"; fi
}

# Returns 0 to retry, 1 to skip; exits 130 on abort.
_steps_error_menu() { # ID INDEX STATUS LOG_TAIL
  local id=$1 pkg='' blog='' text choice line
  local -a items=()
  if [[ -f $GI_RUN_DIR/last_failure ]]; then
    pkg=$(_steps_failure_field package)
    blog=$(_steps_failure_field build_log)
  fi
  text="Step $2 of ${#GI_STEPS[@]}, ${GI_STEP_TITLE[$id]}, failed with exit status $3."
  if [[ -n $pkg ]]; then text+=$'\n'"Package: $pkg"$'\n'"Build log: $blog"; fi
  text+=$'\n\n'"Last lines of $GI_LOG:"
  # Five lines of at most 70 columns keep the menu inside an 80x24 console. The log's
  # timestamp would take 20 of them from the message.
  while IFS= read -r line; do
    line=${line#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] }
    text+=$'\n'"${line:0:70}"
  done <<< "$4"
  items=(retry Retry "Run this step again"
    log "Show log" "Show the last 40 lines of ${blog:-the install log}"
    shell Shell "Open a shell to look around or fix things; type exit to come back")
  if ((${GI_STEP_OPTIONAL[$id]})); then items+=(skip Skip "Skip this optional step and go on"); fi
  items+=(abort Abort "Stop now; gentooinstall --resume continues from this step later")
  while :; do
    choice=$(ui_menu "Step failed" "$text" retry "${items[@]}") || continue
    case $choice in
      retry) return 0 ;;
      skip) return 1 ;;
      log) _steps_show_log "$blog" ;;
      shell) _steps_shell ;;
      abort)
        log INFO "aborted by the user at step $id"
        exit 130
        ;;
    esac
  done
}

_steps_failure_field() {
  local line
  while IFS= read -r line; do
    if [[ $line == "$1="* ]]; then printf '%s\n' "${line#*=}"; fi
  done < "$GI_RUN_DIR/last_failure"
}

_steps_show_log() { # [BUILD_LOG]
  local src=$GI_LOG tmp=$GI_RUN_DIR/log-tail.txt
  if [[ -n $1 && -f $1 ]]; then src=$1; fi
  { printf 'Last 40 lines of %s\n\n' "$src"; tail -n 40 -- "$src"; } > "$tmp"
  ui_textbox "Log" "$tmp"
}

_steps_shell() {
  local -a cmd=(bash -i)
  if state_step_is_done stage3; then cmd=(arch-chroot "$GI_TARGET"); fi
  ui_msg "Shell" "Starting ${cmd[*]}. Type exit to come back to the menu."
  run_interactive "${cmd[@]}" || true
}
