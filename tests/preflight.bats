#!/usr/bin/env bats
# Tests for lib/preflight.sh. hw_detect and hw_disks are replaced by fakes; FAKE changes single facts.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui config hw preflight
  GI_UI=plain
  GI_HOST_ROOT=$BATS_TEST_TMPDIR/host
  mkdir -p "$GI_HOST_ROOT/etc/chrony"
  : > "$GI_HOST_ROOT/etc/chrony/chrony.conf"
  FAKE=()
  DISKS=$'/dev/disk/by-id/nvme-Fake_SSD_1\tnvme0n1\t1000204886016\tNVMe\tFake SSD\tempty'
  # Replaces the real functions lib/hw.sh just defined.
  hw_detect() { fake_hw_detect; }
  hw_disks() { if [[ -n $DISKS ]]; then printf '%s\n' "$DISKS"; fi; }
}

fake_hw_detect() {
  local kv
  HW=([boot_mode]=uefi [efi_bits]=64 [secure_boot]=off [iso]=gentoo-minimal [online]=yes
    [wifi_ssid]='' [ram_mib]=15921 [cpu_threads]=8 [cpu_vendor]=intel [x86_64_v3]=yes
    [cpu_flags]='aes avx' [gpus]='intel nvidia' [gpu_desc]='Intel Iris Xe Graphics + NVIDIA GeForce RTX 3050 Mobile (hybrid)'
    [sof]=yes [wifi]=no [bluetooth]=yes [laptop]=yes [on_battery]=no [vm]=no [live_disk]=sdb)
  for kv in "${FAKE[@]}"; do HW[${kv%%=*}]=${kv#*=}; done
  GI_NET_ERROR=''
  if [[ ${HW[online]} == no ]]; then GI_NET_ERROR="DNS can't resolve distfiles.gentoo.org"; fi
}

# A machine that is offline until NetworkManager brings a Wi-Fi profile up.
wifi_machine() {
  FAKE=(online=no wifi=yes)
  mkdir -p "$GI_HOST_ROOT/sys/class/net/wlan0/wireless"
  _hw_net() {
    if grep -q '^nmcli --wait 60 connection up ' "$STUB_LOG"; then HW[online]=yes GI_NET_ERROR=''; else HW[online]=no; fi
  }
  # NetworkManager runs; a profile exists once added. The passwd-file's path and contents are kept as nmcli sees them.
  nmcli() {
    case $* in
      '-t -f RUNNING general') echo running ;;
      'connection show id gentooinstall-wifi') grep -q '^nmcli connection add ' "$STUB_LOG" ;;
      *)
        if [[ $* == *' passwd-file '* ]]; then
          printf '%s' "${*: -1}" > "$BATS_TEST_TMPDIR/passwd-path"
          cat -- "${*: -1}" > "$BATS_TEST_TMPDIR/passwd-file"
        fi
        command nmcli "$@"
        ;;
    esac
  }
  cat > "$STUB_OUT_DIR/iw" << 'EOF'
BSS 11:11:11:11:11:11(on wlan0)
	freq: 2412
	SSID: Open Cafe
BSS 22:22:22:22:22:22(on wlan0)
	freq: 5180
	SSID: home-5g
	RSN:	 * Version: 1
BSS 33:33:33:33:33:33(on wlan0)
	freq: 2437
	SSID: home-5g
	RSN:	 * Version: 1
BSS 44:44:44:44:44:44(on wlan0)
	SSID:
	RSN:	 * Version: 1
BSS 55:55:55:55:55:55(on wlan0)
	HESSID: 00:11:22:33:44:55
	SSID: caf\xc3\xa9
	WPA:	 * Version: 1
EOF
}

@test "a good machine: every check passes and nothing is asked" {
  run --separate-stderr preflight_run < /dev/null
  [ "$status" -eq 0 ]
  [[ $stderr == *"== Checking this machine =="* ]]
  [[ $stderr == *"[ ok ]  Booted in UEFI mode (64-bit)"* ]]
  [[ $stderr == *"[ ok ]  Secure Boot is off"* ]]
  [[ $stderr == *"[ ok ]  Running on the Gentoo minimal install ISO"* ]]
  [[ $stderr == *"[ ok ]  All required tools are installed"* ]]
  [[ $stderr == *"[ ok ]  distfiles.gentoo.org reachable"$'\n'* ]]
  [[ $stderr == *"[ ok ]  Clock synced with chronyd"* ]]
  [[ $stderr == *"[ ok ]  16 GiB RAM, 8 threads, x86-64-v3"* ]]
  [[ $stderr == *"[ ok ]  GPU: Intel Iris Xe Graphics + NVIDIA GeForce RTX 3050 Mobile (hybrid)"* ]]
  [[ $stderr == *"[ ok ]  1 disk of 20 GiB or more"* ]]
  [[ $stderr != *"[warn]"* ]]
  grep -qxF 'chronyd -q -t 30' "$STUB_LOG"
  grep -q 'check ok: Clock synced with chronyd' "$GI_LOG"
}

@test "the Wi-Fi network shows in the checklist; v3 missing and two disks" {
  FAKE=(wifi_ssid=home-5g x86_64_v3=no gpu_desc=)
  DISKS+=$'\n/dev/disk/by-id/ata-Fake_HDD_2\tsda\t500107862016\tHDD\tFake HDD\text4, 2 parts'
  run --separate-stderr preflight_run < /dev/null
  [ "$status" -eq 0 ]
  [[ $stderr == *'[ ok ]  distfiles.gentoo.org reachable over Wi-Fi "home-5g"'* ]]
  [[ $stderr == *"[ ok ]  16 GiB RAM, 8 threads, no x86-64-v3"* ]]
  [[ $stderr == *"[ ok ]  GPU: none found"* ]]
  [[ $stderr == *"[ ok ]  2 disks of 20 GiB or more"* ]]
}

@test "dialog mode shows the checklist in a message box" {
  GI_UI=dialog
  run --separate-stderr preflight_run < /dev/null
  [ "$status" -eq 0 ]
  grep -q -- '--title Checking\\ this\\ machine --msgbox' "$STUB_LOG"
  grep -qF -- "--msgbox \$'[ ok ]  Booted in UEFI mode (64-bit)\\n" "$STUB_LOG"
}

@test "warnings ask whether to go on; no stops with 130" {
  FAKE=(on_battery=yes secure_boot=on iso=other)
  run --separate-stderr preflight_run <<< n
  [ "$status" -eq 130 ]
  [[ $stderr == *"[warn]  Running on battery. Plug in the charger."* ]]
  [[ $stderr == *"[warn]  Secure Boot is on."* ]]
  [[ $stderr == *"[warn]  This isn't the Gentoo minimal install ISO."* ]]
  [[ $stderr == *"Continue anyway?"* ]]
  run --separate-stderr preflight_run <<< y
  [ "$status" -eq 0 ]
}

@test "dialog mode asks with a yes/no box" {
  GI_UI=dialog FAKE=(on_battery=yes)
  STUB_RC_dialog=1 run preflight_run < /dev/null
  [ "$status" -eq 130 ]
  grep -q -- '--yesno' "$STUB_LOG"
}

@test "--yes only logs warnings and never waits, even in dialog mode" {
  GI_YES=1 GI_UI=dialog FAKE=(on_battery=yes)
  run --separate-stderr preflight_run < /dev/null
  [ "$status" -eq 0 ]
  [[ $stderr == *"[warn]  Running on battery."* ]]
  run ! grep -q '^dialog' "$STUB_LOG"
  grep -q 'WARN check: Running on battery' "$GI_LOG"
}

@test "BIOS boot fails with UEFI instructions, before any network step" {
  FAKE=(boot_mode=bios efi_bits= secure_boot=unknown online=no wifi=yes)
  run --separate-stderr preflight_run < /dev/null
  [ "$status" -eq 1 ]
  [[ $stderr == *"[FAIL]  Booted in legacy BIOS mode; this version needs UEFI"* ]]
  [[ $stderr == *'pick the entry for the stick that begins with "UEFI:"'* ]]
  [[ $stderr == *"error: This machine failed the checks marked [FAIL]."* ]]
  [[ $stderr != *"Offline"* ]]
  run ! grep -q 'chronyd' "$STUB_LOG"
}

@test "32-bit UEFI and a non-x86_64 machine fail" {
  FAKE=(efi_bits=32)
  uname() { echo aarch64; }
  run --separate-stderr preflight_run < /dev/null
  [ "$status" -eq 1 ]
  [[ $stderr == *"[FAIL]  This is a aarch64 machine; gentooinstall installs x86_64 (amd64) only"* ]]
  [[ $stderr == *"[FAIL]  32-bit UEFI firmware; this version supports 64-bit UEFI only"* ]]
}

@test "missing tools are all listed" {
  local dir=$BATS_TEST_TMPDIR/bin t
  mkdir -p "$dir"
  for t in "${GI_TOOLS[@]}"; do
    if [[ $t != xz && $t != lspci && $t != git ]]; then ln -s "$GI_HOME/tests/stubs/_stub" "$dir/$t"; fi
  done
  ln -s "$(type -P uname)" "$dir/uname"
  limited() { PATH=$dir preflight_run; }
  run --separate-stderr limited < /dev/null
  [ "$status" -eq 1 ]
  # git copies a desktop's overlay.
  [[ $stderr == *"[FAIL]  Missing tools: xz lspci git"* ]]
}

@test "too little RAM and no usable disk fail" {
  FAKE=(ram_mib=1400)
  DISKS=''
  run --separate-stderr preflight_run < /dev/null
  [ "$status" -eq 1 ]
  [[ $stderr == *"[FAIL]  1 GiB RAM; at least 2 GiB is needed"* ]]
  [[ $stderr == *"[FAIL]  No disk of 20 GiB or more, apart from the live USB"* ]]
}

@test "offline under --yes fails without offering Wi-Fi" {
  GI_YES=1 FAKE=(online=no wifi=yes)
  run --separate-stderr preflight_run < /dev/null
  [ "$status" -eq 1 ]
  [[ $stderr == *"[FAIL]  Offline: DNS can't resolve distfiles.gentoo.org"* ]]
  [[ $stderr == *"connect to Wi-Fi with nmtui or net-setup"* ]]
  run ! grep -q 'chronyd' "$STUB_LOG"
}

@test "offline in a dry run only warns" {
  GI_DRY_RUN=1 FAKE=(online=no wifi=yes)
  run --separate-stderr preflight_run <<< y
  [ "$status" -eq 0 ]
  [[ $stderr == *"[warn]  Offline: DNS can't resolve distfiles.gentoo.org. A dry run doesn't need the network"* ]]
  [[ $stderr != *"Connect to a Wi-Fi network now?"* ]]
}

@test "Wi-Fi: scan, pick, type the key, connect through NetworkManager, and keep the key" {
  wifi_machine
  preflight_run < <(printf 'y\n2\ncorrect horse\ncorrect horse\n') 2> "$BATS_TEST_TMPDIR/err"
  local err
  err=$(< "$BATS_TEST_TMPDIR/err")
  [[ $err == *"Connect to a Wi-Fi network now?"* ]]
  [[ $err == *"Open Cafe (open)"*"home-5g"*"café"*"Other network"* ]]
  [[ $err != *"5) "* ]]
  [[ $err == *'[ ok ]  distfiles.gentoo.org reachable over Wi-Fi "home-5g"'* ]]
  [ "${HW[wifi_ssid]}" = home-5g ]
  [ "${SECRET[wifi_psk]}" = "correct horse" ]
  local fd
  fd=$(< "$BATS_TEST_TMPDIR/passwd-path")
  [ "$(grep -v '^chronyd' "$STUB_LOG")" = "iw dev wlan0 scan
nmcli connection add type wifi con-name gentooinstall-wifi ifname wlan0 ssid home-5g wifi.hidden yes wifi-sec.key-mgmt wpa-psk
nmcli --wait 60 connection up id gentooinstall-wifi passwd-file $fd" ]
  # A pipe, so no file holds the key, whatever way the installer ends (Ctrl+C included).
  [[ $fd == /dev/fd/* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/passwd-file")" = '802-11-wireless-security.psk:correct\ horse' ]
  run ! grep -rq 'correct' "$GI_RUN_DIR" "$STUB_LOG" "$BATS_TEST_TMPDIR/err"
}

@test "Wi-Fi: an open network keeps an empty key; the key file escapes spaces and backslashes" {
  wifi_machine
  preflight_run < <(printf 'y\n1\n') 2> /dev/null
  grep -qxF 'nmcli connection add type wifi con-name gentooinstall-wifi ifname wlan0 ssid Open\ Cafe wifi.hidden yes' "$STUB_LOG"
  grep -q '^nmcli --wait 60 connection up id gentooinstall-wifi passwd-file /dev/fd/[0-9]*$' "$STUB_LOG"
  [ ! -s "$BATS_TEST_TMPDIR/passwd-file" ]
  [ -n "${SECRET[wifi_psk]+x}" ]
  [ -z "${SECRET[wifi_psk]}" ]
  SECRET=()
  : > "$STUB_LOG"
  local key=' back\slash end '
  preflight_run < <(printf 'y\n3\n%s\n%s\n' "$key" "$key") 2> /dev/null
  [ "${HW[wifi_ssid]}" = café ]
  [ "${SECRET[wifi_psk]}" = "$key" ]
  [ "$(cat "$BATS_TEST_TMPDIR/passwd-file")" = '802-11-wireless-security.psk:\ back\\slash\ end\ ' ]
}

@test "Wi-Fi: a hidden network by name; a bad key or name asks again; the old profile is replaced" {
  wifi_machine
  preflight_run < <(printf 'y\n4\n\n4\nHidden Net\nn\nshort\nshort\n4\nHidden Net\n\nlöng enough\nlöng enough\n4\nHidden Net\nn\nlong enough\nlong enough\n') 2> "$BATS_TEST_TMPDIR/err"
  grep -q "The name can't be empty." "$BATS_TEST_TMPDIR/err"
  [ "$(grep -c "The key must be 8 to 63 printable ASCII characters or 64 hex digits." "$BATS_TEST_TMPDIR/err")" -eq 2 ]
  [ "$(grep -c '^nmcli connection add ' "$STUB_LOG")" -eq 1 ]
  [ "${HW[wifi_ssid]}" = "Hidden Net" ]
  [ "${SECRET[wifi_psk]}" = "long enough" ]
  grep -qxF 'nmcli connection add type wifi con-name gentooinstall-wifi ifname wlan0 ssid Hidden\ Net wifi.hidden yes wifi-sec.key-mgmt wpa-psk' "$STUB_LOG"
  [ "$(grep -c '^nmcli connection delete ' "$STUB_LOG")" -eq 0 ]
  # A rerun of the installer finds the profile from the first run.
  : > "$STUB_LOG"
  echo 'nmcli connection add earlier' > "$STUB_LOG"
  preflight_run < <(printf 'y\n4\nHidden Net\nn\nlong enough\nlong enough\n') 2> /dev/null
  grep -qxF 'nmcli connection delete id gentooinstall-wifi' "$STUB_LOG"
}

@test "Wi-Fi: a hidden open network connects without a key" {
  wifi_machine
  preflight_run < <(printf 'y\n4\nHidden Cafe\ny\n') 2> /dev/null
  grep -qxF 'nmcli connection add type wifi con-name gentooinstall-wifi ifname wlan0 ssid Hidden\ Cafe wifi.hidden yes' "$STUB_LOG"
  [ ! -s "$BATS_TEST_TMPDIR/passwd-file" ]
  [ "${HW[wifi_ssid]}" = "Hidden Cafe" ]
  [ -n "${SECRET[wifi_psk]+x}" ]
  [ -z "${SECRET[wifi_psk]}" ]
}

@test "Wi-Fi: still offline, retry with one profile, then give up" {
  wifi_machine
  _hw_net() { HW[online]=no GI_NET_ERROR="https://distfiles.gentoo.org doesn't answer (curl exit status 28)"; }
  run --separate-stderr preflight_run < <(printf 'y\n1\ny\n1\nn\n')
  [ "$status" -eq 1 ]
  [[ $stderr == *"Still offline over \"Open Cafe\": https://distfiles.gentoo.org doesn't answer"* ]]
  [ "$(grep -c '^nmcli connection add ' "$STUB_LOG")" -eq 2 ]
  # One before the second try, and the profile that never connected goes when the user gives up.
  [ "$(grep -c '^nmcli connection delete id gentooinstall-wifi$' "$STUB_LOG")" -eq 2 ]
  [ "$(grep '^nmcli' "$STUB_LOG" | tail -n 1)" = 'nmcli connection delete id gentooinstall-wifi' ]
  [[ $stderr == *"[FAIL]  Offline: https://distfiles.gentoo.org doesn't answer"* ]]
}

@test "Wi-Fi: giving up keeps a profile that connected, though the mirror didn't answer" {
  wifi_machine
  _hw_net() { HW[online]=no GI_NET_ERROR="https://distfiles.gentoo.org doesn't answer (curl exit status 28)"; }
  echo activated > "$STUB_OUT_DIR/nmcli"
  run --separate-stderr preflight_run < <(printf 'y\n1\nn\n')
  [ "$status" -eq 1 ]
  grep -qxF 'nmcli -g GENERAL.STATE connection show id gentooinstall-wifi' "$STUB_LOG"
  run ! grep -q '^nmcli connection delete ' "$STUB_LOG"
}

@test "Wi-Fi: joining another network replaces the live key kept for the first, never a given key" {
  wifi_machine
  # On a network with no way out (a captive portal), whose key hw_detect kept.
  FAKE=(online=no wifi=yes wifi_ssid=portal)
  hw_detect() {
    fake_hw_detect
    _hw_keep_psk portal 'portal key'
  }
  preflight_run < <(printf 'y\n2\ncorrect horse\ncorrect horse\n') 2> /dev/null
  [ "${HW[wifi_ssid]}" = home-5g ]
  [ "${SECRET[wifi_psk]}" = "correct horse" ]
  # A key from --secrets stays.
  SECRET=([wifi_psk]='from secrets') _hw_psk_kept=0
  : > "$STUB_LOG"
  preflight_run < <(printf 'y\n2\ncorrect horse\ncorrect horse\n') 2> /dev/null
  [ "${HW[wifi_ssid]}" = home-5g ]
  [ "${SECRET[wifi_psk]}" = "from secrets" ]
}

@test "Wi-Fi: a busy scan falls back to the scan results NetworkManager already has" {
  wifi_machine
  # A scan that never ends must not hang the installer.
  timeout() {
    printf 'timeout %s\n' "$*" >> "$STUB_LOG"
    shift
    "$@"
  }
  STUB_RC_iw=240 preflight_run < <(printf 'y\n2\ncorrect horse\ncorrect horse\n') 2> /dev/null
  grep -qxF 'timeout 30 iw dev wlan0 scan' "$STUB_LOG"
  grep -qxF 'iw dev wlan0 scan' "$STUB_LOG"
  grep -qxF 'iw dev wlan0 scan dump' "$STUB_LOG"
  [ "${HW[wifi_ssid]}" = home-5g ]
}

@test "Wi-Fi: declining the offer fails the network check" {
  wifi_machine
  run --separate-stderr preflight_run <<< n
  [ "$status" -eq 1 ]
  run ! grep -q '^nmcli connection' "$STUB_LOG"
}

@test "Wi-Fi: without NetworkManager there is no offer, only the note" {
  wifi_machine
  nmcli() { return 8; }
  run --separate-stderr preflight_run < /dev/null
  [ "$status" -eq 1 ]
  [[ $stderr != *"Connect to a Wi-Fi network now?"* ]]
  [[ $stderr == *"connect to Wi-Fi with nmtui or net-setup"* ]]
}

@test "a certificate check that fails on a wrong clock syncs the clock first, then checks again" {
  FAKE=(online=no)
  hw_detect() { fake_hw_detect; GI_NET_RC=60; }
  _hw_net() { if grep -q '^chronyd' "$STUB_LOG"; then HW[online]=yes GI_NET_ERROR='' GI_NET_RC=0; fi; }
  run --separate-stderr preflight_run < /dev/null
  [ "$status" -eq 0 ]
  [[ $stderr == *"[ ok ]  Clock synced with chronyd"*"[ ok ]  distfiles.gentoo.org reachable"* ]]
  [ "$(grep -c '^chronyd' "$STUB_LOG")" -eq 1 ]
}

@test "clock: chronyd gets a server when the ISO has no chrony config" {
  rm "$GI_HOST_ROOT/etc/chrony/chrony.conf"
  run --separate-stderr preflight_run < /dev/null
  [ "$status" -eq 0 ]
  grep -qxF 'chronyd -q -t 30 pool\ pool.ntp.org\ iburst' "$STUB_LOG"
}

@test "clock: no time server, the user keeps the time and goes on" {
  STUB_RC_chronyd=1 run --separate-stderr preflight_run < <(printf 'b\ny\n')
  [ "$status" -eq 0 ]
  [[ $stderr == *"Type the current UTC time as YYYY-MM-DD HH:MM"* ]]
  [[ $stderr == *"[warn]  No time server answered, and the clock says "* ]]
}

@test "clock: no time server under --yes only warns" {
  GI_YES=1
  STUB_RC_chronyd=1 run --separate-stderr preflight_run < /dev/null
  [ "$status" -eq 0 ]
  [[ $stderr == *"[warn]  No time server answered"* ]]
}

@test "clock: setting it by hand validates the time and runs date" {
  GI_DRY_RUN=1
  run --separate-stderr _pf_set_clock < <(printf 'yesterday\n2026-13-45 99:99\n2026-10-30 14:05\n')
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Not a time like 2026-10-30 14:05' <<< "$stderr")" -eq 2 ]
  [[ $stderr == *'date -u -s 2026-10-30\ 14:05'* ]]
  grep -qxF 'date -u -s 2026-10-30\ 14:05' "$GI_RUN_DIR/replay.sh"
}

@test "preflight_run with the real hw_detect survives errexit, nounset and pipefail" {
  local h=$GI_HOST_ROOT
  mkdir -p "$h/sys/firmware/efi" "$h/proc" "$h/dev/disk/by-id"
  printf 'MemTotal:        4030000 kB\n' > "$h/proc/meminfo"
  printf 'processor\t: 0\nvendor_id\t: AuthenticAMD\n' > "$h/proc/cpuinfo"
  : > "$h/dev/vda"
  ln -s ../../vda "$h/dev/disk/by-id/virtio-root"
  echo 'KNAME="vda" TYPE="disk" SIZE="42949672960" TRAN="virtio" ROTA="1" FSTYPE="" PARTTYPENAME="" LABEL="" PKNAME="" MODEL=""' > "$STUB_OUT_DIR/lsblk"
  export GI_HOME GI_HOST_ROOT GI_RUN_DIR GI_LOG GI_TARGET GI_YES=1
  run --separate-stderr bash -c 'set -Eeuo pipefail; shopt -s inherit_errexit
    for m in core ui config hw preflight; do source "$1/lib/$m.sh"; done
    GI_UI=plain; preflight_run; echo "done ${HW[cpu_vendor]}"' _ "$GI_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "done amd" ]
  [[ $stderr == *"[ ok ]  4 GiB RAM, 1 threads, no x86-64-v3"* ]]
  [[ $stderr == *"[warn]  This isn't the Gentoo minimal install ISO."* ]]
}
