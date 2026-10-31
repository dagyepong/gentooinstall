# shellcheck shell=bash
# Users step: accounts, passwords, and sudo or doas for the wheel group.

step_define users "Users and privileges" \
  "Daily work happens in a normal user account. Admin users join the wheel group, which sudo or doas lets run commands as root." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Finalizing#User_administration"

step_users_packages() {
  local u
  local -a users=()
  read -ra users <<< "${CFG[users]}"
  for u in "${users[@]}"; do
    case ${CFG[user.$u.shell]} in
      zsh) echo app-shells/zsh ;;
      fish) echo app-shells/fish ;;
    esac
  done
}

step_users() {
  local u pw want groups shell uid stdin=''
  local -a users=()
  read -ra users <<< "${CFG[users]}"
  for u in "${users[@]}"; do
    pw=${SECRET[user.$u.password]:-}
    # chpasswd would happily set an empty password.
    [[ -n $pw ]] || die "No password was given for user $u."
    want=users,audio,video,usb
    if [[ ${CFG[user.$u.admin]} == yes ]]; then want+=,wheel; fi
    groups=$(dry_value "$want" _users_existing_groups "$want")
    case ${CFG[user.$u.shell]} in
      zsh) shell=/bin/zsh ;;
      fish) shell=/usr/bin/fish ;;
      *) shell=/bin/bash ;;
    esac
    uid=$(dry_value '' _users_uid "$u")
    if [[ -z $uid ]]; then
      run_chroot useradd -m -G "$groups" -s "$shell" "$u"
    elif ((uid >= 1000)); then
      # A rerun of this step: the user exists from the earlier attempt.
      run_chroot usermod -G "$groups" -s "$shell" "$u"
    else
      die "$u is a system account in the new system. Choose another user name."
    fi
    stdin+="$u:$pw"$'\n'
  done
  run_chroot_stdin "$stdin" chpasswd
  if [[ ${CFG[privilege]} == sudo ]]; then _users_sudo; else _users_doas; fi
}

_users_existing_groups() { # GROUP,GROUP...
  local g out=''
  local -a list=()
  IFS=, read -ra list <<< "$1"
  for g in "${list[@]}"; do
    if grep -q "^$g:" "$GI_TARGET/etc/group"; then out+=${out:+,}$g; fi
  done
  printf '%s\n' "$out"
}

_users_uid() { # NAME
  local name uid _
  while IFS=: read -r name _ uid _; do
    if [[ $name == "$1" ]]; then
      printf '%s\n' "$uid"
      return 0
    fi
  done < "$GI_TARGET/etc/passwd"
}

_users_sudo() {
  local d=/etc/sudoers.d
  # sudo skips file names with a dot, so a draft that fails the check is never read.
  printf '%%wheel ALL=(ALL:ALL) ALL\n' | write_file "$d/wheel.new" 0440
  run_chroot visudo -cf "$d/wheel.new"
  run_cmd mv -f -- "$GI_TARGET$d/wheel.new" "$GI_TARGET$d/wheel"
}

_users_doas() {
  local opt=''
  if [[ $(dry_value no _users_doas_persist) == yes ]]; then opt='persist '; fi
  printf 'permit %s:wheel\n' "$opt" | write_file /etc/doas.conf 0600
}

# persist needs doas built with USE=persist (off by default); otherwise doas silently ignores it.
_users_doas_persist() {
  if grep -qsw persist "$GI_TARGET"/var/db/pkg/app-admin/doas-*/USE; then echo yes; else echo no; fi
}
