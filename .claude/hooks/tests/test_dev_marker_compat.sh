#!/bin/bash
# Index and self-test of the merge-base compat runs (AgDR-0216, Backward
# compatibility).
#
# Each original under compat/dev-base/ runs in its own suite entry,
# test_dev_marker_compat_<name>.sh, through compat/run-dev-compat.sh. This
# test does not run the originals. It checks that every original has exactly
# one wrapper, and that the runner judges a run the right way:
#   - rc 0 passes
#   - a failure on expected-difference lines only passes, when one matched
#   - a non-zero rc with no FAIL line and no expected match fails
#   - an unexpected FAIL line fails
#   - a killed run (rc 124 or 137) fails

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
COMPAT="$HERE/compat/dev-base"
RUNNER="$HERE/compat/run-dev-compat.sh"

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

n=0
for f in "$COMPAT"/*.sh.dev; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  t="${f##*/}"
  t="${t%.dev}"
  short="${t#test_}"
  short="${short%.sh}"
  w="$HERE/test_dev_marker_compat_$short.sh"
  if [ -f "$w" ] && grep -q "run-dev-compat.sh\" $t\$" "$w"; then ok "$t has its wrapper"; else bad "$t has its wrapper" "missing or wrong: $w"; fi
done
if [ "$n" = 9 ]; then ok "9 originals are present"; else bad "9 originals are present" "found $n"; fi
for w in "$HERE"/test_dev_marker_compat_*.sh; do
  t=$(sed -n 's/.*run-dev-compat.sh" \(test_[A-Za-z0-9_]*\.sh\)$/\1/p' "$w")
  if [ -n "$t" ] && [ -f "$COMPAT/$t.dev" ]; then ok "${w##*/} names an original"; else bad "${w##*/} names an original" "[$t]"; fi
done

# Self-test of the verdict rules, with fixture originals.
FX=$(mktemp -d)
trap 'rm -rf "$FX"' EXIT
judge() {
  local name="$1" file="$2" body="$3" want="$4" rc
  printf '#!/bin/bash\n%s\n' "$body" > "$FX/$file.dev"
  DEV_COMPAT_DIR="$FX" bash "$RUNNER" "$file" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = "$want" ]; then ok "$name"; else bad "$name" "want rc=$want got $rc"; fi
}
judge "a passing original passes" test_fx_pass.sh 'echo "PASS: x"; exit 0' 0
judge "an expected difference alone passes" test_dispatch_session_start.sh \
  "echo \"FAIL: dispatcher comment list differs from this test's expected list\"; exit 1" 0
judge "a non-zero rc with no FAIL line fails" test_fx_silent.sh 'exit 1' 1
judge "a non-zero rc with only the expected text in another file fails" test_fx_other.sh \
  "echo \"FAIL: dispatcher comment list differs from this test's expected list\"; exit 1" 1
judge "an unexpected FAIL line fails" test_dispatch_session_start.sh \
  "echo \"FAIL: dispatcher comment list differs from this test's expected list\"; echo 'FAIL: something else'; exit 1" 1
judge "a killed run fails (124)" test_dispatch_session_start.sh \
  "echo \"FAIL: dispatcher comment list differs from this test's expected list\"; exit 124" 1
judge "a killed run fails (137)" test_fx_killed.sh 'exit 137' 1

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
