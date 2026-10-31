# shellcheck shell=bash
# Shared bats helpers: an isolated target and run dir, stubs first in PATH, and module loading.

GI_HOME=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd -P)

gi_setup() {
  export GI_TEST=1
  GI_TARGET=$BATS_TEST_TMPDIR/target
  GI_RUN_DIR=$BATS_TEST_TMPDIR/run
  # shellcheck disable=SC2034  # read by lib/core.sh
  GI_LOG=$GI_RUN_DIR/install.log
  export STUB_LOG=$BATS_TEST_TMPDIR/stub.log STUB_OUT_DIR=$BATS_TEST_TMPDIR/stub-out
  mkdir -p -- "$GI_TARGET" "$GI_RUN_DIR" "$STUB_OUT_DIR"
  : > "$STUB_LOG"
  export PATH="$GI_HOME/tests/stubs:$PATH"
}

# Sources lib/<module>.sh or lib/steps/<module>.sh for each MODULE.
gi_load() {
  local m f
  for m; do
    f=$GI_HOME/lib/$m.sh
    [[ -f $f ]] || f=$GI_HOME/lib/steps/$m.sh
    [[ -f $f ]] || {
      echo "gi_load: no module $m" >&2
      return 1
    }
    # shellcheck source=/dev/null
    source "$f"
  done
}
