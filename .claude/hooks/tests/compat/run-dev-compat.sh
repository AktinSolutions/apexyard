#!/bin/bash
# Runs one original test file from the dev merge base against the current
# hooks (AgDR-0216, Backward compatibility).
#
# Usage: run-dev-compat.sh <test name>, for example
#   run-dev-compat.sh test_status_briefing.sh
#
# dev-base/ holds the original files, unchanged, from the dev commit named in
# dev-base/BASE, for every test that the marker move edited. Refresh them
# after each merge of dev: git show <base>:<path> for each file. They end in .sh.dev, so the suite runner does not run
# them in place. One thin wrapper per file, test_dev_marker_compat_<name>.sh,
# calls this script, so each original gets its own entry and its own time
# limit in bin/run-hook-tests.sh.
#
# This script builds a mirror of the repo in a temporary directory, with the
# current .claude/ copied in and every other top-level entry linked (.git
# too). It puts the original test at its old path, so the test finds the
# hooks the way it did at the merge base.
#
# Exit codes: 0 when the original passes, or when it fails only on lines
# listed in EXPECTED_DIFF and at least one such line matched. 1 otherwise. A
# run that was killed (rc 124 or 137) always fails.

T_NAME="${1:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_ROOT="$(cd "$HERE/../../../.." && pwd)"
# DEV_COMPAT_DIR lets the self-test point at fixture files.
SRC="${DEV_COMPAT_DIR:-$HERE/dev-base}/$T_NAME.dev"
BASE=$(cat "$HERE/dev-base/BASE" 2>/dev/null)
BASE="${BASE:-merge base}"

export APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1

if [ -z "$T_NAME" ] || [ ! -f "$SRC" ]; then
  echo "FAIL [compat file]: no original at $SRC" >&2
  exit 1
fi

# "<test file>|<case text that may fail>|<reason>"
EXPECTED_DIFF=(
  # The old test pins the exact list of SessionStart hooks. The move adds one,
  # the notice that old-layout markers are still read and written.
  "test_dispatch_session_start.sh|dispatcher comment list differs from this test's expected list|a new SessionStart hook prints the transition notice"
)

# A few original tests resolve paths several levels above the repo root, so
# the mirror sits as deep as a usual checkout. They also read the parent
# commit with git, so the mirror links the repository's .git, read-only use.
MT=$(mktemp -d)
MT=$(cd -P "$MT" && pwd)
trap 'rm -rf "$MT"' EXIT
M="$MT/home/user/work/repo"
mkdir -p "$M"

for e in "$SRC_ROOT"/* "$SRC_ROOT"/.[!.]*; do
  [ -e "$e" ] || continue
  name="${e##*/}"
  case "$name" in
    .claude) continue ;;
    # Tests resolve paths under workspace/, so a link there would point them
    # into the real checkout. The mirror gets its own empty directory.
    workspace) mkdir -p "$M/workspace"; continue ;;
  esac
  ln -s "$e" "$M/$name"
done
(cd "$SRC_ROOT" && tar -cf - --exclude=.claude/worktrees --exclude=.claude/session .claude) | (cd "$M" && tar -xf -)

cp "$SRC" "$M/.claude/hooks/tests/$T_NAME"
out=$(cd "$M" && bash "$M/.claude/hooks/tests/$T_NAME" </dev/null 2>&1)
rc=$?

if [ "$rc" = 0 ]; then
  echo "PASS [$T_NAME ($BASE version) passes against the current hooks]"
  exit 0
fi
if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
  echo "FAIL [$T_NAME ($BASE version)]: killed (rc=$rc)" >&2
  exit 1
fi

# A failing run passes only when every failing line is an expected difference
# and at least one expected difference matched.
unexpected=""
matched=0
while IFS= read -r line; do
  case "$line" in
    *FAIL*) ;;
    *) continue ;;
  esac
  case "$line" in
    *'FAIL: 0'*|*'FAIL=0'*|*'Failed: 0'*|*'failed: 0'*) continue ;;
  esac
  allowed=0
  for x in "${EXPECTED_DIFF[@]}"; do
    xf="${x%%|*}"
    rest="${x#*|}"
    xc="${rest%%|*}"
    if [ "$xf" = "$T_NAME" ] && [[ $line == *"$xc"* ]]; then allowed=1; break; fi
  done
  if [ "$allowed" = 1 ]; then matched=$((matched + 1)); else unexpected="$unexpected$line"$'\n'; fi
done <<< "$out"

if [ -z "$unexpected" ] && [ "$matched" -gt 0 ]; then
  echo "PASS [$T_NAME ($BASE version) passes except for $matched expected difference(s)]"
  exit 0
fi
if [ -z "$unexpected" ]; then
  echo "FAIL [$T_NAME ($BASE version)]: rc=$rc with no FAIL line and no expected difference" >&2
  printf '%s\n' "$out" | tail -n 20 >&2
  exit 1
fi
echo "FAIL [$T_NAME ($BASE version)]: rc=$rc" >&2
printf '%s' "$unexpected" >&2
exit 1
