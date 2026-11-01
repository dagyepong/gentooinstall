# shellcheck shell=bash
# User interface: dialog and plain-text widgets, and install progress output.

: "${GI_UI:=}"

ui_init() {
  if [[ $GI_UI != plain ]] && command -v dialog > /dev/null && [[ -t 0 && -t 1 && -t 2 ]]; then
    GI_UI=dialog
    export DIALOGRC=$GI_HOME/lib/dialogrc
  else
    GI_UI=plain
  fi
  log INFO "interface: $GI_UI"
}

ui_backtitle() {
  local s="gentooinstall $GI_VERSION" ram=${HW[ram_mib]:-}
  if [[ -n ${HW[boot_mode]:-} ]]; then s+=" | ${HW[boot_mode]^^}"; fi
  if [[ $ram =~ ^[0-9]+$ ]]; then s+=" | $(((ram + 512) / 1024)) GiB RAM"; fi
  if [[ ${HW[cpu_threads]:-} =~ ^[0-9]+$ ]]; then s+=" | ${HW[cpu_threads]} threads"; fi
  case ${HW[online]:-} in
    yes) s+=" | online" ;;
    no) s+=" | offline" ;;
  esac
  printf '%s\n' "$s"
}

ui_menu() { _ui_list menu "$@"; }
ui_radio() { _ui_list radio "$@"; }

_ui_list() { # KIND [--extra L] [--ok L] [--back L] TITLE TEXT DEFAULT ITEMS...
  local kind=$1 extra='' ok='' back=Back title text def i ans out='' n w rc=0 tw=0 dup=1 found=0
  shift
  while [[ ${1:-} == --* ]]; do
    case $1 in
      --extra) extra=$2 ;;
      --ok) ok=$2 ;;
      --back) back=$2 ;;
      *) die "ui: unknown option $1" ;;
    esac
    shift 2
  done
  title=$1 text=$2 def=$3
  shift 3
  local -a tags=() items=() helps=() args=() labels=()
  while (($#)); do
    tags+=("$1") items+=("$2") helps+=("$3")
    shift 3
  done
  n=${#tags[@]}

  if [[ $GI_UI == dialog ]]; then
    args=(--title "$title" --cancel-label "$back" --item-help)
    if [[ -n $ok ]]; then args+=(--ok-label "$ok"); fi
    if [[ -n $extra ]]; then args+=(--extra-button --extra-label "$extra"); fi
    if [[ -n $def ]]; then args+=(--default-item "$def"); fi
    if [[ $kind == menu ]]; then args+=(--menu "$text" 0 0 0); else args+=(--radiolist "$text" 0 0 0); fi
    for ((i = 0; i < n; i++)); do
      args+=("${tags[i]}" "${items[i]}")
      if [[ $kind == radio ]]; then
        w=off
        if [[ ${tags[i]} == "$def" ]]; then w=on; fi
        args+=("$w")
      fi
      args+=("${helps[i]}")
    done
    out=$(_ui_dialog "${args[@]}") || rc=$?
    if ((rc != 2)); then
      if ((rc == 0)); then printf '%s\n' "$out"; fi
      return "$rc"
    fi
  fi

  # TAG and ITEM in two columns, as dialog shows them, unless every tag just repeats its item.
  for ((i = 0; i < n; i++)); do
    labels[i]=${items[i]}
    if ((${#tags[i]} > tw)); then tw=${#tags[i]}; fi
    if [[ ${tags[i],,} != "${items[i],,}" ]]; then dup=0; fi
  done
  for ((i = 0; i < n && !dup; i++)); do printf -v 'labels[i]' '%-*s  %s' "$tw" "${tags[i]}" "${items[i]}"; done
  # A default that isn't on offer, like a timezone from another region, isn't Enter's answer.
  for ((i = 0; i < n; i++)); do
    if [[ ${tags[i]} == "$def" ]]; then found=1; fi
  done
  if ((!found)); then def=''; fi
  while :; do
    _ui_header "$title" "$text"
    for ((i = 0; i < n; i++)); do
      w=' '
      if [[ ${tags[i]} == "$def" ]]; then w='*'; fi
      printf ' %s%3d) %s\n' "$w" $((i + 1)) "${labels[i]}" >&2
    done
    if [[ -n $extra ]]; then printf '     x) %s\n' "$extra" >&2; fi
    printf 'Choice%s, b = %s, ? = help: ' "${def:+ [Enter = $def]}" "$back" >&2
    _ui_read ans
    case $ans in
      b | B) return 1 ;;
      '?')
        for ((i = 0; i < n; i++)); do printf '%4d) %s: %s\n' $((i + 1)) "${items[i]}" "${helps[i]}" >&2; done
        continue
        ;;
      x | X)
        if [[ -n $extra ]]; then return 3; fi
        ;;
      '')
        if [[ -n $def ]]; then
          printf '%s\n' "$def"
          return 0
        fi
        ;;
      *)
        if [[ $ans =~ ^[0-9]+$ ]] && ((10#$ans >= 1 && 10#$ans <= n)); then
          printf '%s\n' "${tags[10#$ans - 1]}"
          return 0
        fi
        ;;
    esac
    printf 'Not a valid choice.\n' >&2
  done
}

ui_input() { # TITLE TEXT DEFAULT
  local ans rc=0
  if [[ $GI_UI == dialog ]]; then
    _ui_dialog --title "$1" --cancel-label Back --inputbox "$2" 0 0 "${3:-}" || rc=$?
    ((rc == 2)) || return "$rc"
  fi
  _ui_header "$1" "$2"
  printf 'Value%s, b = back: ' "${3:+ [Enter = $3, - = empty]}" >&2
  _ui_read ans
  case $ans in
    b | B) return 1 ;;
    '') ans=${3:-} ;;
    -) ans='' ;; # Enter keeps the default, so this is the way to clear it
  esac
  printf '%s\n' "$ans"
}

# Asks once and prints the value, which may be empty. Never echoes it.
ui_password() { # TITLE TEXT
  local a rc=0
  if [[ $GI_UI == dialog ]]; then
    a=$(_ui_dialog --title "$1" --cancel-label Back --passwordbox "$2" 0 0) || rc=$?
    if ((rc == 0)); then printf '%s\n' "$a"; fi
    ((rc == 2)) || return $((rc != 0))
  fi
  _ui_header "$1" "$2"
  printf 'Password (b = back): ' >&2
  _ui_read -s a
  printf '\n' >&2
  if [[ $a == [bB] ]]; then return 1; fi
  printf '%s\n' "$a"
}

ui_password_twice() { # TITLE TEXT
  local a b
  while :; do
    a=$(ui_password "$1" "$2") || return 1
    b=$(ui_password "$1" "Type it again.") || return 1
    if [[ -z $a ]]; then
      ui_msg "$1" "It can't be empty."
    elif [[ $a != "$b" ]]; then
      ui_msg "$1" "The two entries don't match. Try again."
    else
      printf '%s\n' "$a"
      return 0
    fi
  done
}

ui_yesno() { # [--defaultno] [--yes LABEL] [--no LABEL] TITLE TEXT
  local defno=0 yes='' no='' ans rc=0 prompt='Yes or no'
  local -a args=()
  while [[ ${1:-} == --* ]]; do
    case $1 in
      --defaultno) defno=1 args+=(--defaultno) ;;
      --yes) yes=$2 args+=(--yes-label "$2") ;;
      --no) no=$2 args+=(--no-label "$2") ;;
      *) die "ui: unknown option $1" ;;
    esac
    if [[ $1 != --defaultno ]]; then shift; fi
    shift
  done
  if [[ -n $yes$no ]]; then prompt="y = ${yes:-Yes}, n = ${no:-No}"; fi
  if [[ $GI_UI == dialog ]]; then
    _ui_dialog --title "$1" "${args[@]}" --yesno "$2" 0 0 > /dev/null || rc=$?
    if ((rc != 2)); then return $((rc != 0)); fi
  fi
  _ui_header "$1" "$2"
  while :; do
    if ((defno)); then printf '%s [y/N]: ' "$prompt" >&2; else printf '%s [Y/n]: ' "$prompt" >&2; fi
    _ui_read ans
    case ${ans,,} in
      y | yes) return 0 ;;
      n | no | b) return 1 ;;
      '') return "$defno" ;;
    esac
  done
}

ui_msg() { # TITLE TEXT
  local rc=0
  if [[ $GI_UI == dialog ]]; then
    _ui_dialog --title "$1" --msgbox "$2" 0 0 > /dev/null || rc=$?
    if ((rc != 2)); then return 0; fi
  fi
  _ui_header "$1" "$2"
}

# Shows TEXT and returns at once, for something that takes a while.
ui_info() { # TITLE TEXT
  local rc=0
  if [[ $GI_UI == dialog ]]; then
    _ui_dialog --title "$1" --infobox "$2" 0 0 > /dev/null || rc=$?
    if ((rc != 2)); then return 0; fi
  fi
  _ui_header "$1" "$2"
}

ui_textbox() { # TITLE FILE
  local rc=0
  if [[ $GI_UI == dialog ]]; then
    _ui_dialog --title "$1" --exit-label OK --textbox "$2" 0 0 > /dev/null || rc=$?
    if ((rc != 2)); then return 0; fi
  fi
  _ui_header "$1" ''
  cat -- "$2" >&2
}

ui_confirm_text() { # TITLE TEXT EXPECTED
  local ans
  while :; do
    ans=$(ui_input "$1" "$2" '') || return 1
    if [[ $ans == "$3" ]]; then return 0; fi
    ui_msg "$1" "That doesn't match. Type $3 exactly, or go back."
  done
}

# dialog writes the answer to fd 1 and draws on the terminal, so widgets work inside $(...).
# Esc and a dialog failure (a box too big for the screen) both exit 255; only a failure
# writes to stderr. Returns 0 OK, 1 back, 3 extra, or 2 on a failure so the widget asks
# in plain text instead: a caller that repeats on back would otherwise spin forever.
_ui_dialog() {
  local rc=0 err
  { err=$({ dialog --backtitle "$(ui_backtitle)" --cr-wrap --no-collapse --output-fd 1 "$@" >&3; } 2>&1) || rc=$?; } 3>&1
  case $rc in
    0 | 1 | 3) return "$rc" ;;
  esac
  if [[ -z $err ]]; then return 1; fi
  log WARN "dialog failed, asking in plain text instead: $err"
  return 2
}

_ui_header() {
  printf '\n== %s ==\n' "$1" >&2
  if [[ -n $2 ]]; then printf '%s\n' "$2" >&2; fi
}

# A closed stdin can never answer, so stop the installer instead of looping on "back".
_ui_read() {
  local rc=0 _ui_var=${!#}
  IFS= read -r "$@" || rc=$?
  if ((rc == 0)); then return 0; fi
  if ((rc > 128)); then return 1; fi # interrupted by a signal: treat as back
  if [[ -n ${!_ui_var} ]]; then return 0; fi # a last answer without a newline
  error "Standard input closed; can't ask any more questions."
  _ui_stop_installer
  exit 2
}

# Signals the installer and every subshell between it and here (not this one, which
# exits next); a caller that retries on failure would otherwise spin forever.
_ui_stop_installer() {
  local pid=$BASHPID line
  local -a pids=("$$")
  while [[ $pid != "$$" && $pid -gt 1 && -r /proc/$pid/status ]]; do
    if [[ $pid != "$BASHPID" ]]; then pids+=("$pid"); fi
    while IFS= read -r line; do
      if [[ $line == PPid:* ]]; then pid=${line//[!0-9]/}; fi
    done < "/proc/$pid/status"
  done
  if [[ $BASHPID != "$$" ]]; then kill -s TERM "${pids[@]}" 2> /dev/null || true; fi
}

# --- Install progress --------------------------------------------------------

progress_begin() { GI_PROGRESS_TOTAL=$1; }

progress_step_start() { # INDEX ID TITLE
  GI_PROGRESS_START=$SECONDS
  printf '\n[%2d/%d] %s\n' "$1" "${GI_PROGRESS_TOTAL:-0}" "$3" >&2
  log INFO "step $1/${GI_PROGRESS_TOTAL:-0} $2: $3"
}

progress_explain() { # WHY HANDBOOK
  ((GI_EXPLAIN)) || return 0
  printf '%s\n' "$1" | fold -s -w 70 | sed 's/^/        /' >&2
  printf '        Handbook: %s\n' "$2" >&2
}

progress_status() { # TEXT
  [[ -t 2 ]] || return 0
  local t=$1 width=$((${COLUMNS:-80} - 9))
  printf '\r\e[K        %s' "${t:0:width}" >&2
}

progress_step_end() { # ok|skip|fail
  local s=$((SECONDS - ${GI_PROGRESS_START:-$SECONDS})) word="done" time
  case $1 in
    skip) word=skipped ;;
    fail) word=FAILED ;;
  esac
  if ((s >= 3600)); then
    printf -v time '%dh %02dm' $((s / 3600)) $((s % 3600 / 60))
  elif ((s >= 60)); then
    printf -v time '%dm %02ds' $((s / 60)) $((s % 60))
  else
    time="${s}s"
  fi
  if [[ -t 2 ]]; then printf '\r\e[K' >&2; fi
  printf '        %s (%s)\n' "$word" "$time" >&2
  log INFO "step $word after $time"
}
