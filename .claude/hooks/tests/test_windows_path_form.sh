#!/bin/bash
# Windows path-form regressions.
# #1724 ticket exemptions, #1725 and #1737 hook-install containment.
#
# git.exe prints C:/... and Git Bash pwd -P prints /c/... for one directory.
# Claude Code sends C:\... to Edit and Write. Those translations exist only
# on Windows. This test drives the string transform directly, the same way
# test_portfolio_paths_windows_drive_letter.sh does for #1018.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"

PASS=0
FAIL=0
FAILED=""

record_pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
record_fail() {
  FAIL=$((FAIL + 1))
  FAILED="${FAILED}$1; "
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && echo "  $2" >&2
}

# shellcheck disable=SC1091
. "$HOOK_DIR/_lib-path-resolve.sh"
# shellcheck disable=SC1091
. "$HOOK_DIR/_lib-ticket-path-exemptions.sh"

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    record_pass "$label"
  else
    record_fail "$label" "want=$want got=$got"
  fi
}

assert_eq "drive slash" "/c/Users/a b/repo" "$(_windows_path_to_posix 'C:/Users/a b/repo')"
assert_eq "drive backslash" "/c/Users/x/repo/.claude/project-config.json" \
  "$(_windows_path_to_posix 'C:\Users\x\repo\.claude\project-config.json')"
assert_eq "lower drive" "/d/Projs/fork" "$(_windows_path_to_posix 'd:/Projs/fork')"
assert_eq "posix unchanged" "/Users/x/repo" "$(_windows_path_to_posix '/Users/x/repo')"
assert_eq "drive-relative unchanged" 'C:foo' "$(_windows_path_to_posix 'C:foo')"

if path_is_under_root 'C:/Users/a b/apexyard' '/c/Users/a b/apexyard/.githooks'; then
  record_pass "containment: mixed forms with a space are inside"
else
  record_fail "containment: mixed forms with a space are inside"
fi
if path_is_under_root 'C:/Users/x/apexyard' '/c/Users/x/apexyard'; then
  record_pass "containment: repo root itself is inside"
else
  record_fail "containment: repo root itself is inside"
fi
if path_is_under_root '/Users/x/repo' '/Users/x/repo/.githooks'; then
  record_pass "containment: posix hooks dir is inside"
else
  record_fail "containment: posix hooks dir is inside"
fi
if path_is_under_root 'C:/Users/x/apexyard' '/c/Users/x/other/.githooks'; then
  record_fail "containment: a different tree is outside"
else
  record_pass "containment: a different tree is outside"
fi
if path_is_under_root '/Users/x/repo' '/Users/x/repo-evil/.githooks'; then
  record_fail "containment: prefix trick is outside"
else
  record_pass "containment: prefix trick is outside"
fi
if path_is_under_root '/Users/x/repo' ''; then
  record_fail "containment: empty resolve is outside"
else
  record_pass "containment: empty resolve is outside"
fi

exempt_rc() {
  if ticket_path_is_meta_exempt "$1"; then
    echo 0
  else
    echo 1
  fi
}

assert_eq "exempt windows .claude json" 0 \
  "$(exempt_rc 'C:\Users\x\apexyard\.claude\project-config.json')"
assert_eq "exempt windows docs" 0 \
  "$(exempt_rc 'C:/Users/x/apexyard/docs/guide.md')"
assert_eq "exempt windows readme" 0 \
  "$(exempt_rc 'C:/Users/x/apexyard/README.md')"
assert_eq "gated windows source" 1 \
  "$(exempt_rc 'C:\Users\x\apexyard\src\app.ts')"
assert_eq "gated windows worktree source" 1 \
  "$(exempt_rc 'C:\Users\x\apexyard\.claude\worktrees\feat\src\a.ts')"
assert_eq "drive-relative source stays gated" 1 \
  "$(exempt_rc 'C:src\app.ts')"

# The reported Write payload, with no active ticket, must pass for .claude
# and block for source. The hook under test is this worktree's copy.
SB=$(mktemp -d)
(
  cd "$SB" || exit 1
  git init -q
  git config user.email t@example.com
  git config user.name t
  mkdir -p .claude/hooks src
  printf 'x\n' > src/app.ts
)
for f in require-active-ticket.sh _lib-path-resolve.sh _lib-ticket-path-exemptions.sh \
  _lib-ops-root.sh _lib-active-ticket.sh _lib-awk-fallback.sh _lib-detect-bash-write.sh \
  _lib-read-config.sh _lib-portfolio-paths.sh _lib-fail-closed-json.sh _lib-mask-quoted.sh
do
  cp "$HOOK_DIR/$f" "$SB/.claude/hooks/$f"
done
cp "$SRC_ROOT/.claude/project-config.defaults.json" "$SB/.claude/project-config.defaults.json"

run_hook() {
  local path="$1" rc=0
  local input
  input=$(jq -nc --arg fp "$path" '{tool_name:"Write", tool_input:{file_path:$fp, content:"x"}}')
  (
    cd "$SB" || exit 99
    bash "$SB/.claude/hooks/require-active-ticket.sh" <<<"$input" >/dev/null 2>&1
  ) || rc=$?
  echo "$rc"
}

assert_eq "hook allows windows .claude write" 0 \
  "$(run_hook 'C:\Users\x\apexyard\.claude\project-config.json')"
assert_eq "hook blocks windows source write" 2 \
  "$(run_hook 'C:\Users\x\apexyard\src\app.ts')"
assert_eq "hook still allows posix .claude write" 0 \
  "$(run_hook "$SB/.claude/project-config.json")"
assert_eq "hook still blocks posix source write" 2 \
  "$(run_hook "$SB/src/app.ts")"

NONGIT=$(mktemp -d /tmp/apex-nongit.XXXXXX)
if git -C "$NONGIT" rev-parse --show-toplevel >/dev/null 2>&1; then
  record_fail "nongit dir is inside a git repo" "$NONGIT"
fi

run_hook_from() {
  local dir="$1" path="$2" rc=0
  local input
  input=$(jq -nc --arg fp "$path" '{tool_name:"Write", tool_input:{file_path:$fp, content:"x"}}')
  (
    cd "$dir" || exit 99
    env -u CLAUDE_CODE_SESSION_ID APEXYARD_OPS_DISABLE_PIN=1 \
      bash "$SB/.claude/hooks/require-active-ticket.sh" <<<"$input" >/dev/null 2>&1
  ) || rc=$?
  echo "$rc"
}

assert_eq "nongit cwd blocks windows source" 2 \
  "$(run_hook_from "$NONGIT" 'C:\Users\x\apexyard\src\app.ts')"
assert_eq "nongit cwd allows windows .claude" 0 \
  "$(run_hook_from "$NONGIT" 'C:\Users\x\apexyard\.claude\project-config.json')"
assert_eq "nongit cwd blocks posix source in a repo" 2 \
  "$(run_hook_from "$NONGIT" "$SB/src/app.ts")"
assert_eq "nongit cwd allows a path outside git" 0 \
  "$(run_hook_from "$NONGIT" "$NONGIT/notes.txt")"

classify_state=$(
  repo=$(mktemp -d /tmp/apex-cls-repo.XXXXXX)
  outside=$(mktemp -d /tmp/apex-cls-out.XXXXXX)
  mkdir -p "$outside/company-hooks"
  git -C "$repo" init -q
  git -C "$repo" config core.hooksPath 'C:/outside/company-hooks'
  # shellcheck disable=SC1091
  . "$HOOK_DIR/_lib-git-hooks-path.sh"
  eval "$(declare -f _resolve_real_path | sed '1s/_resolve_real_path/_resolve_real_path_orig/')"
  _resolve_real_path() {
    if [ "$1" = "/c/outside/company-hooks" ]; then
      printf '%s' "$outside/company-hooks"
      return 0
    fi
    _resolve_real_path_orig "$1"
  }
  ghp_classify "$repo" .githooks
  rm -rf "$repo" "$outside"
)
case "$classify_state" in
  third-party:*)
    record_pass "classify keeps an existing drive-letter hooks dir"
    ;;
  *)
    record_fail "classify keeps an existing drive-letter hooks dir" "$classify_state"
    ;;
esac

rm -rf "$SB" "$NONGIT"

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
