#!/usr/bin/env bash
# Build against the local OsmAnd clones instead of the pinned forks.
#
# The flake pins github:aleclearmind/{OsmAnd,OsmAnd-core-legacy}, which is what CI and a
# fresh checkout should build. While working on either fork you want your working tree
# instead, and --override-input is how nix does that without touching flake.nix or
# flake.lock. This is just that, spelled once:
#
#   ./local.sh build .#route
#   ./local.sh run   .#transit -- --obf MAP.obf --from 45.06,7.67 --to 45.07,7.66
#   ./local.sh run   .#transit-datetime-test
#
# git+file: (rather than path:) means nix sees tracked files only — no 1.3 GB .git copied
# into the store on every eval — so `git add` a new file before it can be built. Committing
# is not required: nix uses the working tree of a dirty repo.
#
# The clones are expected beside this repo — ../osmand and ../osmand-core-legacy. Point elsewhere
# with $OSMAND_ANDROID / $OSMAND_CORE_LEGACY.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
android="${OSMAND_ANDROID:-$(dirname "$ROOT")/osmand}"
core="${OSMAND_CORE_LEGACY:-$(dirname "$ROOT")/osmand-core-legacy}"

for d in "$android" "$core"; do
  if [ ! -d "$d/.git" ]; then
    echo "local.sh: not a git clone: $d" >&2
    echo "  clone it, or set \$OSMAND_ANDROID / \$OSMAND_CORE_LEGACY" >&2
    exit 1
  fi
done

flags=(
  --override-input osmand-android "git+file://$android"
  --override-input osmand-core-legacy "git+file://$core"
)

# Every flake command needs these, not just the ones that build the forks: nix resolves all
# inputs to evaluate anything at all, so even `nix build .#emulatorSdk` reaches for the pinned
# branches. `./local.sh --flags` hands them to the other scripts (dev.sh, run-emulator.sh) so
# there is one definition of "where are the clones" — hence one `flags` array, not two spellings.
if [ "${1:-}" = "--flags" ]; then
  printf '%s\n' "${flags[@]}"
  exit 0
fi

if [ $# -eq 0 ]; then
  echo "usage: ./local.sh <nix-subcommand> [args...]   e.g. ./local.sh build .#route" >&2
  echo "       ./local.sh --flags                      print the --override-input flags" >&2
  exit 2
fi

cmd="$1"
shift

exec nix "$cmd" "${flags[@]}" "$@"
