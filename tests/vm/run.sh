#!/usr/bin/env bash
# Installs Gentoo with gentooinstall in a QEMU VM from CONFIG, boots the result and checks it.
# Usage: tests/vm/run.sh CONFIG [SECRETS]   (SECRETS defaults to CONFIG with .secrets for .conf)
# Prints PASS or FAIL and the run directory; exits 0 on PASS. Never needs root.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/../.." && pwd -P)
cache=${GI_VM_CACHE:-$HOME/.cache/gi-vm}

if (($# < 1 || $# > 2)); then
  printf 'Usage: %s CONFIG [SECRETS]\n' "$0" >&2
  exit 2
fi
config=$1 secrets=${2:-${1%.conf}.secrets}
for f in "$config" "$secrets"; do
  [[ -f $f ]] || { printf '%s: no such file\n' "$f" >&2; exit 2; }
done

name=$(basename -- "$config" .conf)-$(date +%Y%m%d-%H%M%S)
run=$cache/runs/$name
mkdir -p "$run/xfer"
# The repo as a clone would have it right now: tracked and untracked files, minus ignored ones like .tools/.
git -C "$repo" ls-files -z -co --exclude-standard |
  tar -C "$repo" --null -T - --ignore-failed-read -cf "$run/xfer/repo.tar"
cp -- "$config" "$run/xfer/config"
cp -- "$secrets" "$run/xfer/secrets"
cp -- "$here/guest.sh" "$run/xfer/guest.sh"
sha256sum "$run/xfer/repo.tar" > "$run/repo.sha256"

docker build -q --build-arg "UID=$(id -u)" --build-arg "GID=$(id -g)" -t gi-vm "$here" > /dev/null
printf 'Run directory: %s\n' "$run"
rc=0
docker run --rm --init --name "gi-vm-$name" --user "$(id -u):$(id -g)" --device /dev/kvm \
  -v "$cache:/work" -v "$here:/vm:ro" gi-vm python3 /vm/drive.py "/work/runs/$name" || rc=$?
printf 'Logs: %s (result.txt, serial-install.log, out/install.log, out/replay.sh, serial-boot.log, checks.txt, screen.png)\n' "$run"
exit "$rc"
