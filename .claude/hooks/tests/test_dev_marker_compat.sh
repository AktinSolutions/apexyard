#!/bin/bash
# Backward compatibility of the ticket marker move (AgDR-0216).
#
# compat/dev-27f7565/ holds the original test files, unchanged, from the merge
# base 27f7565, for every test that the marker move edited. Each one runs here
# against the current hooks. They must pass, except for the cases listed in
# EXPECTED_DIFF below, each with its reason.
#
# The files end in .sh.dev, so the suite runner does not run them in place.
# This runner builds a mirror of the repo in a temporary directory, with the
# current .claude/ copied in and every other top-level entry linked (.git
# too). It puts each original test at its old path, so the test finds the
# hooks the way it did at the merge base.

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
COMPAT="$SRC_ROOT/.claude/hooks/tests/compat/dev-27f7565"

export APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

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

ran=0
for f in "$COMPAT"/*.sh.dev; do
  [ -f "$f" ] || continue
  t="${f##*/}"
  t="${t%.dev}"
  cp "$f" "$M/.claude/hooks/tests/$t"
  out=$(cd "$M" && timeout 600 bash "$M/.claude/hooks/tests/$t" </dev/null 2>&1)
  rc=$?
  ran=$((ran + 1))
  if [ "$rc" = 0 ]; then
    ok "$t (27f7565 version) passes against the current hooks"
    continue
  fi
  # A failing run passes only when every failing line is an expected difference.
  unexpected=""
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
      if [ "$xf" = "$t" ] && [[ $line == *"$xc"* ]]; then allowed=1; break; fi
    done
    [ "$allowed" = 1 ] || unexpected="$unexpected$line"$'\n'
  done <<< "$out"
  if [ -z "$unexpected" ]; then
    ok "$t (27f7565 version) passes except for the expected differences"
  else
    bad "$t (27f7565 version)" "rc=$rc"$'\n'"$unexpected"
  fi
done
if [ "$ran" -lt 9 ]; then bad "compat files present" "only $ran found in $COMPAT"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
