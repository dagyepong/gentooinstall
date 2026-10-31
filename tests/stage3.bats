#!/usr/bin/env bats
# Tests for lib/steps/stage3.sh: mirrors, pointer, download, verification, extraction and answer checks.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  # An unexpected question then fails the test instead of waiting for input.
  exec < /dev/null
  gi_load core ui config state stage3
  GI_UI=plain
  T=$GI_TARGET R=$GI_RUN_DIR G=$GI_RUN_DIR/gnupg
  FIX=$GI_HOME/tests/fixtures/stage3
  BASE=https://distfiles.gentoo.org/releases/amd64/autobuilds
  NAME=stage3-amd64-openrc-20261025T170057Z.tar.xz
  CFG[users]=larry CFG[desktop]=none
  cfg_defaults_apply
  printf 'not really a stage3\n' > "$BATS_TEST_TMPDIR/good.tar.xz"
  # What the tarball would have put in place, for the timezone and locale checks.
  mkdir -p "$T/usr/share/zoneinfo/Europe" "$T/usr/share/i18n"
  touch "$T/usr/share/zoneinfo/UTC" "$T/usr/share/zoneinfo/Europe/Berlin"
  printf '%s\n' 'en_US.UTF-8 UTF-8' 'en_US ISO-8859-1' 'de_DE.UTF-8 UTF-8' > "$T/usr/share/i18n/SUPPORTED"
  mkdir -p "$T/etc"
  # The live system's resolv.conf, a link as NetworkManager makes it.
  GI_HOST_ROOT=$BATS_TEST_TMPDIR/live
  mkdir -p "$GI_HOST_ROOT/etc" "$GI_HOST_ROOT/run/NetworkManager"
  echo 'nameserver 192.0.2.53' > "$GI_HOST_ROOT/run/NetworkManager/resolv.conf"
  ln -s ../run/NetworkManager/resolv.conf "$GI_HOST_ROOT/etc/resolv.conf"
}

# A DIGESTS file in the real clearsigned layout, listing the fake tarball's sums under NAME.
# $WRONG_HASH names an algorithm whose sum is listed wrong.
digests() { # NAME
  local f=$BATS_TEST_TMPDIR/good.tar.xz b2 sha
  b2=$(b2sum < "$f" | cut -d' ' -f1) sha=$(sha512sum < "$f" | cut -d' ' -f1)
  case ${WRONG_HASH:-} in
    BLAKE2B) b2=${b2//?/0} ;;
    SHA512) sha=${sha//?/0} ;;
  esac
  printf -- '-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n'
  printf '# BLAKE2B HASH\n%s  %s\n' "$b2" "$1"
  printf '# SHA512 HASH\n%s  %s\n' "$sha" "$1"
  printf '# SHA512 HASH\n%s  %s.CONTENTS.gz\n' "$(printf x | sha512sum | cut -d' ' -f1)" "$1"
  printf -- '-----BEGIN PGP SIGNATURE-----\n\nAAAA\n-----END PGP SIGNATURE-----\n'
}

# Downloads: the real pointer fixtures, the fake tarball (corrupt while $BATS_TEST_TMPDIR/bad
# counts above 0) and matching DIGESTS.
curl() {
  command curl "$@" || return
  local out='' a prev='' url=${!#} n=0
  for a; do
    if [[ $prev == -o ]]; then out=$a; fi
    prev=$a
  done
  case $url in
    */latest-stage3-*.txt) cp "$FIX/${url##*/}" "$out" ;;
    *.tar.xz)
      awk '/^SigIgn:/ {print $2}' "/proc/$BASHPID/status" > "$BATS_TEST_TMPDIR/sigign"
      if [[ -f $out ]]; then cp "$out" "$BATS_TEST_TMPDIR/resumed"; fi
      if [[ -f $BATS_TEST_TMPDIR/bad ]]; then n=$(< "$BATS_TEST_TMPDIR/bad"); fi
      if ((n > 0)); then
        echo $((n - 1)) > "$BATS_TEST_TMPDIR/bad"
        echo corrupt > "$out"
      else
        cp "$BATS_TEST_TMPDIR/good.tar.xz" "$out"
      fi
      ;;
    *.DIGESTS)
      a=${url##*/}
      digests "${a%.DIGESTS}" > "$out"
      ;;
    *) : > "$out" ;;
  esac
}

# gpg succeeds unless its last argument matches $GPG_FAIL; --output gets the input, as with a good signature.
gpg() {
  command gpg "$@" || return
  # shellcheck disable=SC2053  # GPG_FAIL is a pattern
  if [[ -n ${GPG_FAIL:-} && ${!#} == $GPG_FAIL ]]; then return 1; fi
  local out='' a prev=''
  for a; do
    if [[ $prev == --output ]]; then out=$a; fi
    prev=$a
  done
  if [[ -n $out ]]; then cp -- "${!#}" "$out"; fi
}

in_step() { (set -e && "$@"); }

calls() { grep -E "^($1)( |\$)" "$STUB_LOG" || true; }

@test "openrc from the CDN: exact commands, verified tarball and state" {
  run in_step step_stage3
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "gpg --homedir $G --batch --import /usr/share/openpgp-keys/gentoo-release.asc
curl -fsSL --retry 5 -o $R/latest-stage3-amd64-openrc.txt $BASE/latest-stage3-amd64-openrc.txt
gpg --homedir $G --batch --yes --output $R/latest-stage3-amd64-openrc.txt.verified --verify $R/latest-stage3-amd64-openrc.txt
curl -fsSL --retry 5 --retry-all-errors -C - -o $T/$NAME $BASE/20261025T170057Z/$NAME
curl -fsSL --retry 5 -o $T/$NAME.asc $BASE/20261025T170057Z/$NAME.asc
curl -fsSL --retry 5 -o $T/$NAME.DIGESTS $BASE/20261025T170057Z/$NAME.DIGESTS
curl -fsSL --retry 5 -o $T/$NAME.sha256 $BASE/20261025T170057Z/$NAME.sha256
gpg --homedir $G --batch --verify $T/$NAME.asc $T/$NAME
gpg --homedir $G --batch --yes --output $R/$NAME.DIGESTS.verified --verify $T/$NAME.DIGESTS
gpgconf --homedir $G --kill all
tar xpf $T/$NAME --xattrs-include=\\*.\\* --numeric-owner -C $T" ]
  [ "$(state_get stage3.file)" = "$NAME" ]
  [ "$(stat -c %a "$G")" = 700 ]
}

@test "the live DNS settings are copied into the target, so arch-chroot can resolve names" {
  run in_step step_stage3
  [ "$status" -eq 0 ]
  [ ! -L "$T/etc/resolv.conf" ]
  [ "$(cat "$T/etc/resolv.conf")" = 'nameserver 192.0.2.53' ]
  # A retry replaces the file, and a link in the target is replaced, never written through.
  echo outside > "$BATS_TEST_TMPDIR/outside"
  rm "$T/etc/resolv.conf"
  ln -s "$BATS_TEST_TMPDIR/outside" "$T/etc/resolv.conf"
  run in_step step_stage3
  [ "$status" -eq 0 ]
  [ ! -L "$T/etc/resolv.conf" ]
  [ "$(cat "$T/etc/resolv.conf")" = 'nameserver 192.0.2.53' ]
  [ "$(cat "$BATS_TEST_TMPDIR/outside")" = outside ]
}

@test "the variant follows init and desktop" {
  for pair in "openrc none openrc" "systemd none systemd" "openrc plasma desktop-openrc" "systemd gnome desktop-systemd"; do
    read -r init desktop variant <<< "$pair"
    CFG[init]=$init CFG[desktop]=$desktop
    : > "$STUB_LOG"
    rm -f "$GI_RUN_DIR/state"
    run in_step step_stage3
    [ "$status" -eq 0 ]
    grep -q "^curl .* $BASE/latest-stage3-amd64-$variant.txt\$" "$STUB_LOG"
    [[ $(state_get stage3.file) == stage3-amd64-$variant-20261025T170057Z.tar.xz ]]
  done
}

@test "a custom mirror is used as given, without a doubled slash" {
  CFG[mirror]=https://mirror.example/gentoo/
  run in_step step_stage3
  [ "$status" -eq 0 ]
  grep -q " https://mirror.example/gentoo/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt\$" "$STUB_LOG"
}

@test "fastest parses the GENTOO_MIRRORS line mirrorselect prints, and measures only once" {
  CFG[mirror]=fastest
  printf '\nGENTOO_MIRRORS="https://a.example/gentoo/ \\\n    https://b.example/ \\\n    https://c.example/pub/gentoo"\n' > "$STUB_OUT_DIR/mirrorselect"
  run in_step step_stage3
  [ "$status" -eq 0 ]
  # -S keeps out http and ftp hosts.
  [ "$(calls mirrorselect)" = "mirrorselect -S -s3 -b10 -o" ]
  [ "$(state_get mirror.fastest)" = "https://a.example/gentoo/ https://b.example/ https://c.example/pub/gentoo" ]
  grep -q " https://a.example/gentoo/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt\$" "$STUB_LOG"
  # The portage step, a retry and a resume reuse the measured list.
  [ "$(stage3_mirrors)" = "https://a.example/gentoo/ https://b.example/ https://c.example/pub/gentoo" ]
  [ "$(calls mirrorselect | wc -l)" -eq 1 ]
}

@test "stage3_mirrors follows the answer, and an answer changed to fastest later gets measured then" {
  CFG[mirror]=cdn
  [ "$(stage3_mirrors)" = https://distfiles.gentoo.org ]
  CFG[mirror]=https://mirror.example/gentoo
  [ "$(stage3_mirrors)" = https://mirror.example/gentoo ]
  run ! grep -q mirrorselect "$STUB_LOG"
  # Like --resume --config mirror=fastest after the stage3 step.
  CFG[mirror]=fastest
  echo 'GENTOO_MIRRORS="https://a.example/gentoo/"' > "$STUB_OUT_DIR/mirrorselect"
  [ "$(stage3_mirrors 2> /dev/null)" = https://a.example/gentoo/ ]
  [ "$(calls mirrorselect)" = "mirrorselect -S -s3 -b10 -o" ]
}

@test "fastest fails on mirrorselect output without mirrors" {
  CFG[mirror]=fastest
  for out in 'no mirrors today' 'GENTOO_MIRRORS=""' $'GENTOO_MIRRORS="https://a.example/ \\\n    rm -rf /"' \
    'GENTOO_MIRRORS="https://a.example/ ftp://b.example/"'; do
    printf '%s\n' "$out" > "$STUB_OUT_DIR/mirrorselect"
    run in_step step_stage3
    [ "$status" -ne 0 ]
    run ! grep -q '^curl' "$STUB_LOG"
  done
}

@test "a checksum mismatch downloads once more" {
  echo 1 > "$BATS_TEST_TMPDIR/bad"
  run in_step step_stage3
  [ "$status" -eq 0 ]
  [[ $output == *"failed verification (attempt 1 of 2)"* ]]
  [ "$(grep -c "^curl .* $T/$NAME " "$STUB_LOG")" -eq 2 ]
  [ "$(state_get stage3.file)" = "$NAME" ]
  cmp "$T/$NAME" "$BATS_TEST_TMPDIR/good.tar.xz"
}

@test "a second mismatch fails the step and deletes the download" {
  echo 2 > "$BATS_TEST_TMPDIR/bad"
  run in_step step_stage3
  [ "$status" -ne 0 ]
  [[ $output == *"failed verification twice"* ]]
  grep -qx "gpgconf --homedir $G --kill all" "$STUB_LOG"
  [ ! -e "$T/$NAME" ]
  [ ! -e "$T/$NAME.DIGESTS" ]
  [ -z "$(state_get stage3.file)" ]
  run ! grep -q '^tar' "$STUB_LOG"
}

@test "each checksum is checked on its own" {
  for WRONG_HASH in SHA512 BLAKE2B; do
    : > "$STUB_LOG"
    run in_step step_stage3
    [ "$status" -ne 0 ]
    [[ $output == *"failed verification twice"* ]]
  done
}

@test "a bad tarball signature counts as a mismatch" {
  GPG_FAIL="$T/$NAME"
  run in_step step_stage3
  [ "$status" -ne 0 ]
  [ "$(grep -c "^curl .* $T/$NAME " "$STUB_LOG")" -eq 2 ]
  run ! grep -q '^tar' "$STUB_LOG"
}

@test "a bad pointer signature stops before any download" {
  GPG_FAIL='*.txt'
  run in_step step_stage3
  [ "$status" -ne 0 ]
  run ! grep -q "^curl .* $T/" "$STUB_LOG"
}

@test "the download runs in the foreground, where Ctrl+C stops it" {
  run in_step step_stage3
  [ "$status" -eq 0 ]
  # A background job ignores SIGINT, and curl would keep writing after the step stopped.
  mask=$(< "$BATS_TEST_TMPDIR/sigign")
  (( (16#$mask & 2) == 0 ))
}

@test "a failed download fails the step" {
  export STUB_RC_curl=22
  run in_step step_stage3
  [ "$status" -ne 0 ]
  run ! grep -q '^tar' "$STUB_LOG"
}

@test "a tarball verified by an earlier attempt is only extracted again" {
  state_set stage3.file "$NAME"
  cp "$BATS_TEST_TMPDIR/good.tar.xz" "$T/$NAME"
  run in_step step_stage3
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "tar xpf $T/$NAME --xattrs-include=\\*.\\* --numeric-owner -C $T" ]
}

@test "after a desktop change on resume, the stage3 an earlier attempt unpacked is kept, not mixed with another" {
  old=stage3-amd64-desktop-openrc-20261025T170057Z.tar.xz
  state_set stage3.file "$old"
  touch "$T/$old"
  run in_step step_stage3
  [ "$status" -eq 0 ]
  [[ $output == *"Keeping $old"* ]]
  [ "$(cat "$STUB_LOG")" = "tar xpf $T/$old --xattrs-include=\\*.\\* --numeric-owner -C $T" ]
  [ "$(state_get stage3.file)" = "$old" ]
}

@test "a verified stage3 whose file is gone stops the step instead of unpacking another" {
  state_set stage3.file "$NAME"
  run in_step step_stage3
  [ "$status" -ne 0 ]
  [[ $output == *"$NAME into $T, and that file is gone"* ]]
  [ ! -s "$STUB_LOG" ]
  state_set stage3.file "../$NAME"
  touch "$T/$NAME"
  run in_step step_stage3
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "stage3 files an earlier attempt downloaded under another name are deleted" {
  old=stage3-amd64-desktop-openrc-20261025T170057Z.tar.xz
  # The other variant's download, and a partial one from an older pointer. Neither got verified.
  touch "$T/$old" "$T/$old.asc" "$T/$old.DIGESTS" "$T/$old.sha256" "$T/stage3-amd64-openrc-20261018T170057Z.tar.xz"
  # This attempt's partial download stays for curl -C -; nothing but files at the top goes.
  echo partial > "$T/$NAME"
  mkdir -p "$T/stage3-dir" "$T/var"
  touch "$T/stage3-dir/f" "$T/var/stage3-x"
  ln -s "$T/var/stage3-x" "$T/stage3-link"
  run in_step step_stage3
  [ "$status" -eq 0 ]
  run ! compgen -G "$T/stage3-amd64-desktop-*"
  [ ! -e "$T/stage3-amd64-openrc-20261018T170057Z.tar.xz" ]
  [ "$(cat "$BATS_TEST_TMPDIR/resumed")" = partial ]
  [ -f "$T/$NAME" ]
  [ -f "$T/stage3-dir/f" ]
  [ -f "$T/var/stage3-x" ]
  [ ! -L "$T/stage3-link" ]
}

@test "the pointer parser reads the real format and ignores other variants and odd names" {
  run _stage3_pointer "$FIX/latest-stage3-amd64-desktop-openrc.txt" desktop-openrc
  [ "$status" -eq 0 ]
  [ "$output" = "20261025T170057Z/stage3-amd64-desktop-openrc-20261025T170057Z.tar.xz 754636108" ]
  run _stage3_pointer "$FIX/latest-stage3-amd64-desktop-openrc.txt" openrc
  [ "$status" -ne 0 ]
  printf '%s\n' '20261025T170057Z/../stage3-amd64-openrc-x.tar.xz/../../etc 1' '20261025T170057Z/stage3-amd64-openrc-x.tar.gz 5' > "$BATS_TEST_TMPDIR/p"
  run _stage3_pointer "$BATS_TEST_TMPDIR/p" openrc
  [ "$status" -ne 0 ]
}

@test "the DIGESTS parser picks the right hash from the real file" {
  f=$FIX/$NAME.DIGESTS
  [ "$(_stage3_digest "$f" SHA512 "$NAME")" = 57038349a0ea952514420da9172e7a18a66991c720db93af4cb85f6a4407f386e539f407f259b7184507e2ff58d87cc20f74628632edab015ebb24a85796d02f ]
  [ "$(_stage3_digest "$f" BLAKE2B "$NAME")" = 19176ed046f42550ad5e9e1f4f1e2ed1dedba47afd22bc5ea5f972daa60d0293a258f095f627bc01652853b3ea198eef293ff342894d4fd4a37a3f41efdd8fb8 ]
  [ "$(_stage3_digest "$f" SHA512 "$NAME.CONTENTS.gz")" = 1cf51c8aed8a988ead9d5b16bd3bba553d53b849c6b21094ff79d2afedea7167ba3b78d6cfbde8ae3a78c8aaa5ed7223cb7d2580aa705f72281ebc296e85df77 ]
  [ -z "$(_stage3_digest "$f" SHA512 other.tar.xz)" ]
}

@test "an unknown timezone is asked again and saved" {
  CFG[timezone]=Europe/Nowhere
  run in_step step_stage3 <<< 'Europe/Berlin'
  [ "$status" -eq 0 ]
  grep -qx 'timezone=Europe/Berlin' "$GI_RUN_DIR/config"
}

@test "an invalid timezone answer is asked again" {
  CFG[timezone]=Europe/Nowhere
  run in_step step_stage3 <<< $'../../../etc/passwd\nUTC'
  [ "$status" -eq 0 ]
  grep -qx 'timezone=UTC' "$GI_RUN_DIR/config"
}

@test "unsupported locales are asked again and the language follows" {
  CFG[locales]='en_US.UTF-8 xx_XX.UTF-8' CFG[lang]=xx_XX.UTF-8
  run in_step step_stage3 <<< 'de_DE.UTF-8 en_US.UTF-8'
  [ "$status" -eq 0 ]
  grep -qx 'locales=de_DE.UTF-8 en_US.UTF-8' "$GI_RUN_DIR/config"
  grep -qx 'lang=de_DE.UTF-8' "$GI_RUN_DIR/config"
}

@test "with --yes, a wrong timezone or locale fails the step" {
  GI_YES=1 CFG[timezone]=Europe/Nowhere
  run in_step step_stage3 < /dev/null
  [ "$status" -ne 0 ]
  [[ $output == *"timezone Europe/Nowhere doesn't exist"* ]]
  CFG[timezone]=UTC CFG[locales]=xx_XX.UTF-8 CFG[lang]=xx_XX.UTF-8
  run in_step step_stage3 < /dev/null
  [ "$status" -ne 0 ]
  [[ $output == *"xx_XX.UTF-8"* ]]
}

@test "dry-run prints every command, runs none and skips the answer checks" {
  GI_DRY_RUN=1 CFG[init]=systemd CFG[desktop]=plasma CFG[timezone]=Europe/Nowhere
  run --separate-stderr in_step step_stage3 < /dev/null
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [[ $stderr == *"curl -fsSL --retry 5 -o $R/latest-stage3-amd64-desktop-systemd.txt $BASE/latest-stage3-amd64-desktop-systemd.txt"* ]]
  [[ $stderr == *"gpg --homedir $G --batch --verify $T/stage3-amd64-desktop-systemd-\<date\>.tar.xz.asc"* ]]
  [[ $stderr == *"tar xpf $T/stage3-amd64-desktop-systemd-\<date\>.tar.xz"* ]]
  [ ! -e "$G" ]
}
