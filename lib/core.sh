# shellcheck shell=bash
# Core helpers: logging, command runners, file writers, Portage and service helpers.

# shellcheck disable=SC2034  # read by the other files
GI_VERSION=0.1.0
: "${GI_TARGET:=/mnt/gentoo}" "${GI_RUN_DIR:=/tmp/gentooinstall}"
: "${GI_LOG:=$GI_RUN_DIR/install.log}"
: "${GI_DRY_RUN:=0}" "${GI_EXPLAIN:=0}" "${GI_YES:=0}" "${GI_RESUME:=0}" "${GI_TEST:=0}"
declare -gA CFG=() SECRET=() HW=()

# --- Logging ---------------------------------------------------------------

log() {
  local level=$1
  shift
  { printf '%(%F %T)T %s ' -1 "$level"; redact "$*"; } >> "$GI_LOG"
}

info() { log INFO "$*"; redact "$*" >&2; }
warn() { log WARN "$*"; redact "warning: $*" >&2; }
error() { log ERROR "$*"; redact "error: $*" >&2; }
die() { error "$1"; exit "${2:-1}"; }

redact() {
  local s=$1 v q i j
  local -a vals=("${SECRET[@]}")
  # Longest first, so a secret that contains a shorter one is masked whole.
  for ((i = 1; i < ${#vals[@]}; i++)); do
    for ((j = i; j > 0 && ${#vals[j - 1]} < ${#vals[j]}; j--)); do
      v=${vals[j]} vals[j]=${vals[j - 1]} vals[j - 1]=$v
    done
  done
  for v in "${vals[@]}"; do
    [[ -n $v ]] || continue
    printf -v q '%q' "$v"
    s=${s//"$v"/***}
    s=${s//"$q"/***}
  done
  printf '%s\n' "$s"
}

# --- Commands --------------------------------------------------------------

run_cmd() {
  _announce "$(_q "$@")" || return 0
  _exec 0 '' "$@"
}

# The note gives no length: that would tell the log how long a password is.
run_stdin() {
  local data=$1
  shift
  _announce "$(_q "$@")  # (stdin: not recorded)" || return 0
  _exec 1 "$data" "$@"
}

run_chroot() { _chroot 0 '' "$(_q "$@")"; }

run_chroot_stdin() {
  local data=$1
  shift
  _chroot 1 "$data" "$(_q "$@")"
}

_chroot() { # HAS_DATA DATA COMMAND_LINE
  local note='' script
  script=$(chroot_script "$3")
  if (($1)); then note='  # (stdin: not recorded)'; fi
  _announce "arch-chroot $(_q "$GI_TARGET") /bin/bash -c $(_sq "$script")$note" || return 0
  _exec "$1" "$2" arch-chroot "$GI_TARGET" /bin/bash -c "$script"
}

# The bash script for COMMAND_LINE in the chroot. arch-chroot runs it as PID 1 of a new PID
# namespace, and bash would exec the last command, making it PID 1; tools like locale-gen fail
# as PID 1, so the exit keeps bash there.
chroot_script() { printf 'source /etc/profile && %s; exit $?' "$1"; }

# Runs CMD on the terminal, for a shell the user types in. The replay script gets it as a
# comment, since what the user types there isn't recorded.
run_interactive() { # CMD [ARGS...]
  _announce "# interactive: $(_q "$@")" || return 0
  _safety_net "$1" || return
  "$@"
}

# Logs TEXT, adds it to the replay script and shows it in explain mode.
# Returns 1 in dry-run, where TEXT is printed and nothing may run.
_announce() {
  local text
  text=$(redact "$1")
  log CMD "$text"
  printf '%s\n' "$text" >> "$GI_RUN_DIR/replay.sh"
  if ((GI_DRY_RUN)); then
    printf '%s\n' "$text" >&2
    return 1
  fi
  if ((GI_EXPLAIN)); then printf '  $ %s\n' "$text" >&2; fi
}

_exec() { # HAS_DATA DATA CMD [ARGS...]
  local - has_data=$1 data=$2 rc=0
  set -o pipefail
  shift 2
  _safety_net "$1" || return
  if ((has_data)); then
    # Process substitution keeps DATA out of every process's arguments and off the disk.
    "$@" < <(printf '%s' "$data") 2>&1 | _log_stream || rc=$?
  else
    "$@" < /dev/null 2>&1 | _log_stream || rc=$?
  fi
  if ((rc)); then log ERROR "exit status $rc from $1"; fi
  return "$rc"
}

_log_stream() {
  local line
  while IFS= read -r line || [[ -n $line ]]; do redact "$line"; done >> "$GI_LOG"
}

# Under test only stubs and a few file utilities may run, so tests never touch the real machine.
_safety_net() {
  ((GI_TEST)) || return 0
  local path
  path=$(type -P -- "$1") || path=''
  [[ -n $path && $path == "$GI_HOME/tests/stubs/${1##*/}" ]] && return 0
  # By bare name only, so /some/dir/rm can't pass as rm.
  case $1 in
    cat | chmod | cp | install | ln | mkdir | mv | rm | rmdir | touch | true | false)
      [[ -n $path ]] && return 0
      ;;
  esac
  error "test safety net: refusing to run $1 (${path:-not found})"
  return 126
}

_q() {
  local a s=''
  for a; do
    printf -v a '%q' "$a"
    s+=" $a"
  done
  printf '%s' "${s# }"
}

_sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

_bytes() {
  local LC_ALL=C
  printf '%s' "${#1}"
}

# --- Files in the target ---------------------------------------------------

write_file() { _write "$1" "${2:-0644}" 1; }
write_secret_file() { _write "$1" "${2:-0600}" 0; }

_write() { # PATH MODE SHOW_CONTENT, content on stdin
  local path=$1 mode=$2 show=$3 dest=$GI_TARGET$1 dir content root real tmp
  [[ $path == /* && $path != */ ]] || die "write_file: need an absolute file path, got: $path"
  [[ $mode =~ ^[0-7]{3,4}$ ]] || die "write_file: bad mode for $path: $mode"
  content=$(
    cat
    printf x
  )
  content=${content%x}
  dir=${dest%/*}
  root=$(realpath -m -- "$GI_TARGET")
  real=$(realpath -m -- "$dir")
  # Absolute symlinks inside the target point at the live system; never write through them.
  [[ $real == "$root" || $real == "$root"/* ]] || die "write_file: $path resolves outside $GI_TARGET"

  if ((show)); then
    log FILE "$dest (mode $mode):"$'\n'"$content"
    {
      printf "mkdir -p %s\ncat > %s <<'GI_EOF'\n" "$(_q "$dir")" "$(_q "$dest")"
      redact "${content%$'\n'}"
      printf 'GI_EOF\nchmod %s %s\n' "$mode" "$(_q "$dest")"
    } >> "$GI_RUN_DIR/replay.sh"
  else
    log FILE "$dest (mode $mode, secret content not logged)"
    printf '# write %s (mode %s): secret content, not recorded\n' "$(_q "$dest")" "$mode" >> "$GI_RUN_DIR/replay.sh"
  fi

  if ((GI_DRY_RUN)); then
    printf 'write %s (mode %s)\n' "$dest" "$mode" >&2
    if ((show)); then redact "${content%$'\n'}" >&2; fi
    return 0
  fi
  if ((GI_EXPLAIN)); then printf '  > %s\n' "$dest" >&2; fi
  mkdir -p -- "$dir"
  tmp=$(mktemp -- "$dir/.gi.XXXXXX")
  printf '%s' "$content" > "$tmp"
  chmod -- "$mode" "$tmp"
  # -T replaces a symlink at PATH instead of following it.
  mv -fT -- "$tmp" "$dest"
}

ensure_line() { # PATH LINE
  local dest=$GI_TARGET$1 content='' mode=0644
  # A dry run never wrote the file, so printing the whole result would show only this line.
  if ((GI_DRY_RUN)); then
    _announce "# add this line to $dest unless it's there: $2" || true
    return 0
  fi
  if [[ -f $dest ]]; then
    grep -qxF -- "$2" "$dest" && return 0
    content=$(
      cat -- "$dest"
      printf x
    )
    content=${content%x}
    [[ -z $content || $content == *$'\n' ]] || content+=$'\n'
    mode=$(stat -c %a -- "$dest")
  fi
  printf '%s%s\n' "$content" "$2" | write_file "$1" "$mode"
}

set_shell_var() { # PATH NAME VALUE
  local dest=$GI_TARGET$1 name=$2 value=$3 line out='' found=0 mode=0644
  [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "set_shell_var: bad name: $name"
  [[ $value != *[\"\\\`$'\n']* ]] || die "set_shell_var: $name can't contain quotes, backslashes, backticks or newlines"
  if ((GI_DRY_RUN)); then
    _announce "# set $name=\"$value\" in $dest" || true
    return 0
  fi
  if [[ -f $dest ]]; then
    mode=$(stat -c %a -- "$dest")
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line == "$name="* ]]; then
        ((found)) && continue
        found=1
        line="$name=\"$value\""
      fi
      out+=$line$'\n'
    done < "$dest"
  fi
  ((found)) || out+="$name=\"$value\""$'\n'
  printf '%s' "$out" | write_file "$1" "$mode"
}

# --- Portage and services --------------------------------------------------

portage_file() { # KIND NAME, content on stdin
  case $1 in
    package.use | package.license | package.accept_keywords | package.env) ;;
    *) die "portage_file: unknown kind: $1" ;;
  esac
  [[ $2 =~ ^[A-Za-z0-9._-]+$ ]] || die "portage_file: bad file name: $2"
  write_file "/etc/portage/$1/$2"
}

make_conf_use_add() { # FLAG...
  local f=/etc/portage/make.conf line='' cur flag
  for flag; do
    [[ $flag =~ ^-?[A-Za-z0-9][A-Za-z0-9+_@.-]*$ ]] || die "make_conf_use_add: bad USE flag: $flag"
  done
  if ((GI_DRY_RUN)); then
    _announce "# add to USE in $GI_TARGET$f: $*" || true
    return 0
  fi
  if [[ -f $GI_TARGET$f ]]; then line=$(grep -m1 '^USE=' -- "$GI_TARGET$f" || true); fi
  cur=${line#USE=}
  cur=${cur#\"}
  cur=${cur%\"}
  for flag; do
    [[ " $cur " == *" $flag "* ]] || cur+=${cur:+ }$flag
  done
  set_shell_var "$f" USE "$cur"
}

emerge_run() { # ARGS...
  local - script found rc=0
  set -o pipefail
  script=$(chroot_script "$(_q emerge "$@")")
  rm -f -- "$GI_RUN_DIR/last_failure"
  _announce "arch-chroot $(_q "$GI_TARGET") /bin/bash -c $(_sq "$script")" || return 0
  _safety_net arch-chroot || return
  found=$(arch-chroot "$GI_TARGET" /bin/bash -c "$script" < /dev/null 2>&1 | _emerge_stream) || rc=$?
  if ((rc)); then
    log ERROR "emerge failed with exit status $rc"
    printf '%s%sexit=%s\n' "$found" "${found:+$'\n'}" "$rc" > "$GI_RUN_DIR/last_failure"
  fi
  return "$rc"
}

# Logs emerge output, shows "N of M  package (binary|source)" and prints
# package= and build_log= lines for the first failed package.
_emerge_stream() {
  local line kind pkg='' blog='' copy
  local re_start='^>>> Emerging (binary )?\(([0-9]+) of ([0-9]+)\) ([^ :]+)'
  local re_fail='^>>> Failed to emerge ([^ ,]+)'
  local re_log="^>>>  '(/[^']+)'\$"
  while IFS= read -r line || [[ -n $line ]]; do
    redact "$line" >> "$GI_LOG"
    if [[ $line =~ $re_start ]]; then
      kind=source
      if [[ -n ${BASH_REMATCH[1]} ]]; then kind=binary; fi
      progress_status "${BASH_REMATCH[2]} of ${BASH_REMATCH[3]}  ${BASH_REMATCH[4]} ($kind)"
    elif [[ -z $pkg && $line =~ $re_fail ]]; then
      pkg=${BASH_REMATCH[1]}
    elif [[ -n $pkg && -z $blog && $line =~ $re_log ]]; then
      blog=$GI_TARGET${BASH_REMATCH[1]}
    fi
  done
  if [[ -n $pkg ]]; then
    printf 'package=%s\nbuild_log=%s\n' "$pkg" "$blog"
    # Portage deletes the build dir on the next attempt; keep a copy for the error menu and the finish step.
    if [[ -f $blog ]]; then
      copy=$GI_RUN_DIR/build-logs/${pkg//\//_}.log
      mkdir -p -- "${copy%/*}" && cp -- "$blog" "$copy" || true
    fi
  fi
}

is_openrc() { [[ ${CFG[init]:-} == openrc ]]; }
is_systemd() { [[ ${CFG[init]:-} == systemd ]]; }

service_enable() { # NAME [RUNLEVEL]
  if is_systemd; then
    run_chroot systemctl enable "$1"
  else
    run_chroot rc-update add "$1" "${2:-default}"
  fi
}

user_service_enable_global() { # UNIT...
  is_systemd || return 0
  run_chroot systemctl --global enable "$@"
}

dry_value() { # PLACEHOLDER COMMAND...
  if ((GI_DRY_RUN)); then
    printf '%s\n' "$1"
    return 0
  fi
  shift
  # A step's own query function may run; a command must pass the test safety net.
  declare -F -- "$1" > /dev/null || _safety_net "$1" || return
  "$@"
}
