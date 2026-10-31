#!/usr/bin/env bash
# Downloads the pinned shellcheck and bats-core into .tools/.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
tools=$root/.tools
sc_version=0.11.0
sc_sha256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
bats_version=1.14.0
mkdir -p -- "$tools/bin"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

if [[ ! -x $tools/bin/shellcheck ]]; then
  tarball=shellcheck-v$sc_version.linux.x86_64.tar.xz
  curl -fsSL -o "$tmp/$tarball" "https://github.com/koalaman/shellcheck/releases/download/v$sc_version/$tarball"
  echo "$sc_sha256  $tmp/$tarball" | sha256sum -c --quiet
  tar -xJf "$tmp/$tarball" -C "$tmp"
  install -m 0755 "$tmp/shellcheck-v$sc_version/shellcheck" "$tools/bin/shellcheck"
fi
if [[ ! -d $tools/bats-core ]]; then
  git clone --quiet --depth 1 --branch "v$bats_version" https://github.com/bats-core/bats-core "$tools/bats-core"
fi
ln -sfn ../bats-core/bin/bats "$tools/bin/bats"
"$tools/bin/shellcheck" --version | sed -n 2p
"$tools/bin/bats" --version
