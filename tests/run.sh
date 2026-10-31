#!/usr/bin/env bash
# Runs shellcheck and bats on every file, or only on the files given.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
export PATH="$root/.tools/bin:$PATH"
cd -- "$root"
if (($#)); then
  files=("$@")
else
  files=(gentooinstall lib/*.sh lib/steps/*.sh tests/run.sh tests/bootstrap.sh tests/helpers.bash tests/stubs/_stub tests/*.bats)
fi
check=() tests=() rc=0
for f in "${files[@]}"; do
  if [[ ! -e $f ]]; then
    # A misspelled file name must not pass by checking nothing; only the default globs may miss.
    if (($#)); then
      printf 'tests/run.sh: no such file: %s\n' "$f" >&2
      rc=1
    fi
    continue
  fi
  if [[ $f == *.bats ]]; then tests+=("$f"); else check+=("$f"); fi
done
if ((${#check[@]})); then shellcheck -x "${check[@]}" || rc=1; fi
if ((${#tests[@]})); then bats "${tests[@]}" || rc=1; fi
exit "$rc"
