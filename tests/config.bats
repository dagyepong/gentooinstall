#!/usr/bin/env bats
# Tests for lib/config.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core config
  hw_disk_size_bytes() { echo $((500 * 1024 ** 3)); }
}

# The example from SPEC.md.
write_example() {
  cat > "$BATS_TEST_TMPDIR/config" << 'EOF'
# gentooinstall config
format=1
keymap=us
disk=/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456
filesystem=btrfs
encryption=luks2
swap=zram
init=openrc
desktop=plasma
bootloader=systemd-boot
kernel=gentoo-kernel-bin
hostname=laptop
timezone=Europe/Brussels
locales=en_US.UTF-8 de_DE.UTF-8
lang=en_US.UTF-8
users=larry
user.larry.admin=yes
user.larry.shell=bash
packages=app-editors/neovim dev-vcs/git
EOF
}

valid() { cfg_validate "$1" "$2" > /dev/null; }
invalid() { ! cfg_validate "$1" "$2" > /dev/null; }

@test "defaults fill every key, using hardware facts" {
  HW[laptop]=yes HW[bluetooth]=yes HW[wifi_ssid]=home
  cfg_defaults_apply
  for k in "${GI_CFG_KEYS[@]}"; do [ -n "${CFG[$k]+x}" ]; done
  [ "${CFG[power]}" = ppd ]
  [ "${CFG[fwupd]}" = yes ]
  [ "${CFG[bluetooth]}" = yes ]
  [ "${CFG[wifi_ssid]}" = home ]
  [ "${CFG[cflags]}" = "-march=native -O2 -pipe" ]
  [ "${CFG[media_keys]}" = no ]
}

@test "defaults on a desktop machine without bluetooth" {
  HW[laptop]=no HW[bluetooth]=no
  cfg_defaults_apply
  [ "${CFG[power]}" = none ]
  [ "${CFG[fwupd]}" = no ]
  [ "${CFG[bluetooth]}" = no ]
}

@test "defaults never overwrite loaded values, and lang follows locales" {
  printf 'locales=de_DE.UTF-8 en_US.UTF-8\nhostname=box\nusers=anna\n' > "$BATS_TEST_TMPDIR/config"
  cfg_load "$BATS_TEST_TMPDIR/config"
  cfg_defaults_apply
  [ "${CFG[hostname]}" = box ]
  [ "${CFG[lang]}" = de_DE.UTF-8 ]
  [ "${CFG[user.anna.admin]}" = yes ]
  [ "${CFG[user.anna.shell]}" = bash ]
}

@test "cfg_load reads the example config" {
  write_example
  cfg_load "$BATS_TEST_TMPDIR/config"
  [ "${CFG[filesystem]}" = btrfs ]
  [ "${CFG[locales]}" = "en_US.UTF-8 de_DE.UTF-8" ]
  [ "${CFG[packages]}" = "app-editors/neovim dev-vcs/git" ]
  [ "${CFG[hostname]}" = laptop ]
}

@test "cfg_load reports every error at once" {
  cat > "$BATS_TEST_TMPDIR/config" << 'EOF'
hostname=Bad_Host
filesystem=zfs
color=blue
no equals sign
hostname=again
users=root
user.bob.shell=bash
EOF
  run --separate-stderr cfg_load "$BATS_TEST_TMPDIR/config"
  [ "$status" -eq 1 ]
  [[ $stderr == *"line 1: hostname: must be"* ]]
  [[ $stderr == *"line 2: filesystem: must be one of: ext4 xfs btrfs"* ]]
  [[ $stderr == *"line 3: color: unknown key"* ]]
  [[ $stderr == *"line 4: expected key=value"* ]]
  [[ $stderr == *"line 5: hostname is set twice"* ]]
  [[ $stderr == *"line 6: users: root is a system account name"* ]]
  [[ $stderr == *"user.bob.shell: bob is not in users"* ]]
}

@test "cfg_load never runs anything in the file" {
  printf 'hostname=$(touch %s/pwned)\npackages=`touch %s/pwned`\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/config"
  run cfg_load "$BATS_TEST_TMPDIR/config"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "hostname validation" {
  valid hostname gentoo
  valid hostname a
  valid hostname my-laptop-2
  invalid hostname ''
  invalid hostname -x
  invalid hostname x-
  invalid hostname My
  invalid hostname a.b
  invalid hostname "$(printf 'a%.0s' {1..64})"
}

@test "desktop takes every desktop and window manager, or none" {
  local d
  for d in plasma gnome xfce budgie cinnamon i3 sway hyprland niri mangowm dwm dwl none; do valid desktop "$d"; done
  invalid desktop kde
  invalid desktop Sway
  invalid desktop mango
}

@test "username validation" {
  valid users larry
  valid users "_svc anna-b"
  valid user.anna.admin yes
  valid users ''
  invalid users Larry
  invalid users 1abc
  invalid users "a a"
  invalid users root
  invalid users portage
  invalid users nobody
  invalid users wheel
  invalid users systemd-network
  # LightDM's own account, from the Xfce, Budgie and Cinnamon login screen.
  invalid users lightdm
  invalid users "$(printf 'a%.0s' {1..33})"
  invalid user.Root.admin yes
  invalid user.anna.shell tcsh
}

@test "timezone, locale and keymap validation" {
  valid timezone UTC
  valid timezone Europe/Brussels
  valid timezone America/Argentina/Buenos_Aires
  valid timezone Etc/GMT+5
  invalid timezone europe/brussels
  invalid timezone ../etc/passwd
  invalid timezone Europe
  valid locales "en_US.UTF-8 de_DE.UTF-8 sr_RS@latin"
  valid lang de_DE.UTF-8
  invalid locales ''
  invalid locales "en_US.UTF-8;ls"
  invalid lang english
  valid keymap us
  valid keymap de-latin1-nodeadkeys
  invalid keymap 'us;ls'
  invalid keymap ''
}

@test "package atom validation blocks shell syntax" {
  valid packages ''
  valid packages "app-editors/neovim dev-vcs/git::gentoo"
  valid packages ">=dev-lang/python-3.12.1_rc2-r1:3.12"
  valid packages "=www-client/firefox-128*"
  valid packages "~app-misc/foo-1.0 sys-kernel/gentoo-kernel:6.6/6.6.1"
  invalid packages 'vim'
  invalid packages 'app-editors/vim;rm'
  invalid packages '$(id)'
  invalid packages '`id`'
  invalid packages 'app/x|y'
  invalid packages '>=app/x'
  invalid packages 'a/b"'
}

@test "cflags, makeopts, mirror, emerge_jobs and disk validation" {
  valid cflags "-march=native -O2 -pipe"
  invalid cflags ''
  invalid cflags '-O2 "x"'
  invalid cflags "-O2 'x'"
  invalid cflags '-O2 $X'
  invalid cflags '-O2 `x`'
  invalid cflags '-O2 \x'
  invalid cflags $'-O2\n-g'
  valid makeopts auto
  valid makeopts "-j8 -l8"
  invalid makeopts "-j8; ls"
  valid mirror cdn
  valid mirror fastest
  valid mirror https://mirror.example.org/gentoo/
  invalid mirror http://mirror.example.org
  invalid mirror "https://x y"
  valid emerge_jobs auto
  valid emerge_jobs 4
  invalid emerge_jobs 0
  invalid emerge_jobs -1
  valid disk /dev/disk/by-id/usb-SanDisk_Cruzer-0:0
  invalid disk /dev/sda
  invalid disk /dev/disk/by-id/nvme-x-part1
  invalid disk /dev/disk/by-id/..
  valid disk ''
  valid wifi_ssid "Cafe Wi-Fi"
  invalid wifi_ssid "$(printf 'a%.0s' {1..33})"
}

@test "every key in the table has a validator and its default is valid" {
  cfg_defaults_apply
  for k in "${GI_CFG_KEYS[@]}"; do cfg_validate "$k" "${CFG[$k]}"; done
  invalid nonsense x
  valid media_keys yes
  invalid media_keys maybe
}

@test "cfg_set validates and respects locks" {
  run --separate-stderr cfg_set hostname BAD
  [ "$status" -eq 1 ]
  [[ $stderr == "hostname: must be"* ]]
  cfg_set filesystem ext4
  cfg_lock filesystem
  cfg_is_locked filesystem
  cfg_set filesystem ext4
  run --separate-stderr cfg_set filesystem xfs
  [ "$status" -eq 1 ]
  [[ $stderr == *"can't change once the disk step has started"* ]]
  [ "${CFG[filesystem]}" = ext4 ]
}

@test "cfg_save writes keys in table order, then per-user keys, and loads back" {
  write_example
  cfg_load "$BATS_TEST_TMPDIR/config"
  cfg_defaults_apply
  SECRET[root_password]=hunter22
  cfg_save "$BATS_TEST_TMPDIR/saved"
  run ! grep -q hunter22 "$BATS_TEST_TMPDIR/saved"
  [ "$(grep -v '^#' "$BATS_TEST_TMPDIR/saved" | head -3)" = $'format=1\nkeymap=us\ndisk=/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T123456' ]
  [ "$(tail -2 "$BATS_TEST_TMPDIR/saved")" = $'user.larry.admin=yes\nuser.larry.shell=bash' ]
  declare -A before=()
  for k in "${!CFG[@]}"; do before[$k]=${CFG[$k]}; done
  CFG=()
  cfg_load "$BATS_TEST_TMPDIR/saved"
  for k in "${!before[@]}"; do [ "${CFG[$k]}" = "${before[$k]}" ]; done
  [ "${#CFG[@]}" -eq "${#before[@]}" ]
}

@test "cfg_save defaults to the run dir" {
  cfg_defaults_apply
  cfg_save
  [ -f "$GI_RUN_DIR/config" ]
}

@test "cfg_load_secrets needs mode 600 and never logs values" {
  printf 'root_password=Hunter2!x\nuser.larry.password=L4rry pw\nluks_passphrase=correct horse\nwifi_psk=12345678\n' > "$BATS_TEST_TMPDIR/secrets"
  chmod 644 "$BATS_TEST_TMPDIR/secrets"
  run --separate-stderr cfg_load_secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mode 600"* ]]
  chmod 600 "$BATS_TEST_TMPDIR/secrets"
  cfg_load_secrets "$BATS_TEST_TMPDIR/secrets"
  [ "${SECRET[user.larry.password]}" = "L4rry pw" ]
  [ "${SECRET[luks_passphrase]}" = "correct horse" ]
  run ! grep -qE 'Hunter2|L4rry|horse|12345678' "$GI_LOG"
}

@test "cfg_load_secrets reports bad lines without echoing them" {
  printf 'justthepassword\nroot_password=\nshoe_size=9\nwifi_psk=short\nuser.Bad.password=x\n' > "$BATS_TEST_TMPDIR/secrets"
  chmod 600 "$BATS_TEST_TMPDIR/secrets"
  run --separate-stderr cfg_load_secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 1 ]
  [[ $stderr == *"line 1: expected key=value"*"line 2: root_password: can't be empty"*"line 3: unknown key"* ]]
  [[ $stderr == *"line 4: wifi_psk: must be 8 to 63"*"line 5: user.Bad.password: user names must be"* ]]
  [[ $stderr != *justthepassword* && $stderr != *shoe* ]]
}

@test "cfg_secrets_missing lists what the pending steps need" {
  cfg_defaults_apply
  CFG[encryption]=luks2 CFG[users]="larry anna" CFG[wifi_ssid]=home
  SECRET[user.anna.password]=x
  [ "$(cfg_secrets_missing disk system users network)" = $'luks_passphrase\nroot_password\nuser.larry.password\nwifi_psk' ]
  [ -z "$(cfg_secrets_missing world finish)" ]
  CFG[root]=locked CFG[encryption]=none CFG[keep_wifi]=no
  [ "$(cfg_secrets_missing disk system network)" = "" ]
}

ok_config() {
  write_example
  cfg_load "$BATS_TEST_TMPDIR/config"
  cfg_defaults_apply
}

@test "cfg_check_rules passes a good config" {
  ok_config
  run cfg_check_rules
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rule: missing required answers are errors" {
  cfg_defaults_apply
  run cfg_check_rules
  [ "$status" -eq 1 ]
  [[ $output == *"error: disk: is required"*"error: users: needs at least one user"* ]]
}

@test "rule: LUKS needs systemd-boot" {
  ok_config
  CFG[bootloader]=grub
  run cfg_check_rules
  [ "$status" -eq 1 ]
  [[ $output == *"error: LUKS encryption needs systemd-boot"* ]]
}

@test "rule: LUKS with Limine is fine, since its kernels sit on the ESP too" {
  ok_config
  cfg_set bootloader limine
  run cfg_check_rules
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rule: a desktop needs 40 GiB of disk" {
  ok_config
  hw_disk_size_bytes() { echo $((39 * 1024 ** 3)); }
  run cfg_check_rules
  [ "$status" -eq 1 ]
  [[ $output == *"error: A desktop needs a disk of at least 40 GiB."* ]]
  CFG[desktop]=none CFG[display_manager]=none
  run cfg_check_rules
  [ "$status" -eq 0 ]
}

@test "rule: systemd-networkd needs systemd" {
  ok_config
  CFG[network]=networkd
  run cfg_check_rules
  [ "$status" -eq 1 ]
  [[ $output == *"error: systemd-networkd needs systemd"* ]]
  [[ $output == *"warn: A desktop without NetworkManager"* ]]
  CFG[init]=systemd
  run cfg_check_rules
  [ "$status" -eq 0 ]
}

@test "rule: locking root needs an admin user" {
  ok_config
  CFG[root]=locked CFG[user.larry.admin]=no
  run cfg_check_rules
  [ "$status" -eq 1 ]
  [[ $output == *"error: Locking root needs at least one admin user."* ]]
  CFG[user.larry.admin]=yes
  run cfg_check_rules
  [ "$status" -eq 0 ]
}

@test "rule: Secure Boot on blocks the install; lang must be a chosen locale" {
  ok_config
  HW[secure_boot]=on CFG[lang]=fr_FR.UTF-8
  run cfg_check_rules
  [ "$status" -eq 1 ]
  [[ $output == *"error: lang must be one of the chosen locales"*"error: Secure Boot is on"* ]]
}

@test "rule: low RAM warns for desktops and the compiled kernel" {
  ok_config
  HW[ram_mib]=3000
  run cfg_check_rules
  [ "$status" -eq 0 ]
  [[ $output == *"warn: Less than 4 GiB of RAM"* ]]
}

@test "disk takes a whole disk under by-id or by-path" {
  valid disk /dev/disk/by-path/pci-0000:00:04.0
  valid disk /dev/disk/by-path/virtio-pci-0000:00:04.0
  invalid disk /dev/disk/by-path/pci-0000:00:04.0-part1
  invalid disk /dev/disk/by-path/..
  invalid disk /dev/disk/by-uuid/1234
  invalid disk /dev/disk/by-path/../../sda
}

@test "every value must be a single line" {
  invalid packages $'app-editors/vim\n$(id)'
  invalid users $'larry\nroot'
  invalid locales $'en_US.UTF-8\nnot a locale'
  run --separate-stderr cfg_set packages $'app-editors/vim\nx'
  [ "$status" -eq 1 ]
  [[ $stderr == "packages: must be a single line" ]]
}

@test "cfg_load and cfg_load_secrets read files with Windows line endings" {
  printf 'hostname=laptop\r\nusers=larry\r\n\r\n# note\r\n' > "$BATS_TEST_TMPDIR/config"
  cfg_load "$BATS_TEST_TMPDIR/config"
  [ "${CFG[hostname]}" = laptop ]
  printf 'root_password=Hunter2!x\r\nuser.larry.password=L4rry pw\r\n' > "$BATS_TEST_TMPDIR/secrets"
  chmod 600 "$BATS_TEST_TMPDIR/secrets"
  cfg_load_secrets "$BATS_TEST_TMPDIR/secrets"
  [ "${SECRET[root_password]}" = 'Hunter2!x' ]
  [ "${SECRET[user.larry.password]}" = 'L4rry pw' ]
}

@test "cfg_load_secrets rejects a key set twice without echoing values" {
  printf 'root_password=first-pw\nroot_password=second-pw\n' > "$BATS_TEST_TMPDIR/secrets"
  chmod 600 "$BATS_TEST_TMPDIR/secrets"
  run --separate-stderr cfg_load_secrets "$BATS_TEST_TMPDIR/secrets"
  [ "$status" -eq 1 ]
  [[ $stderr == *"line 2: root_password: is set twice"* ]]
  [[ $stderr != *first-pw* && $stderr != *second-pw* ]]
}

@test "lang defaults to the first locale whatever the spacing" {
  CFG[locales]=$' de_DE.UTF-8\ten_US.UTF-8'
  cfg_defaults_apply
  [ "${CFG[lang]}" = de_DE.UTF-8 ]
  valid locales "${CFG[locales]}"
}

@test "cfg_save fails inside a condition when it can't write, and leaves no temp file" {
  cfg_defaults_apply
  if cfg_save "$BATS_TEST_TMPDIR/no-such-dir/config"; then false; fi
  mkdir "$BATS_TEST_TMPDIR/adir"
  if cfg_save "$BATS_TEST_TMPDIR/adir"; then false; fi
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/adir")" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'adir.*')" ]
  grep -q "ERROR couldn't save the config to $BATS_TEST_TMPDIR/adir" "$GI_LOG"
  cfg_save "$BATS_TEST_TMPDIR/ok"
}

@test "cfg_secret_validate checks each secret without echoing it" {
  cfg_secret_validate wifi_psk ''
  cfg_secret_validate wifi_psk 12345678
  cfg_secret_validate wifi_psk "$(printf 'a%.0s' {1..63})"
  cfg_secret_validate wifi_psk "$(printf 'aB%.0s' {1..32})"
  cfg_secret_validate root_password x
  cfg_secret_validate user.larry.password 'pa ss'
  run cfg_secret_validate wifi_psk short7x
  [ "$status" -eq 1 ]
  [ "$output" = "wifi_psk: must be 8 to 63 printable ASCII characters or 64 hex digits" ]
  run ! cfg_secret_validate wifi_psk "$(printf 'g%.0s' {1..64})"
  run ! cfg_secret_validate wifi_psk $'1234567\t8'
  # 8 characters but 10 bytes: WPA keys are ASCII, whatever the locale.
  LC_ALL=C.UTF-8
  run ! cfg_secret_validate wifi_psk 'pässwörd'
  [ "${#LC_ALL}" -eq 7 ]
  run cfg_secret_validate luks_passphrase ''
  [ "$output" = "luks_passphrase: can't be empty" ]
  run cfg_secret_validate user.Bad.password secret-pw
  [[ $output == "user.Bad.password: user names must be"* ]]
  run ! cfg_secret_validate shoe_size 9
}

@test "rule: a 4 GiB machine, whose MemTotal is under 4096 MiB, gets no low-RAM warning" {
  ok_config
  HW[ram_mib]=3850
  run cfg_check_rules
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  HW[ram_mib]=3500
  run cfg_check_rules
  [[ $output == *"warn: Less than 4 GiB of RAM"* ]]
}

@test "cfg_secrets_missing wants the Wi-Fi key only for NetworkManager" {
  cfg_defaults_apply
  CFG[wifi_ssid]=home CFG[root]=locked
  [ "$(cfg_secrets_missing network)" = wifi_psk ]
  CFG[network]=dhcpcd
  [ -z "$(cfg_secrets_missing network)" ]
  CFG[network]=networkd
  [ -z "$(cfg_secrets_missing network)" ]
}
