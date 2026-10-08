#!/bin/bash
# Backward compatibility rows B1 to B9 of the ticket marker move (AgDR-0216).
#
# Each row is a real-session shape that the first version of the move broke.
# Every row runs twice: against the current hooks and against the hooks of
# the dev merge base named in compat/dev-base/BASE. A row must give the same
# answer on both. When the merge base is not in the local history (a shallow
# clone), the row runs against the current hooks only and an INFO line says
# so.
#
#   B1 a clone at a registry workspace: path outside the workspace dir
#   B2 a linked worktree keeps its old per-branch marker
#   B3 an unregistered repo outside the ops fork
#   B4 a current-ticket that names a managed project, for an ops edit
#   B5 a nested repo, a submodule, a malformed .git file and a symlinked root
#   B6 a Bash write whose target cannot be extracted
#   B7 a fork without the portfolio library
#   B8 a marker written by the new /start-ticket, read by the old hooks
#   B9 hooks swapped mid-task, both ways
#
# A repo owned by another user (part of B5) needs root to set up, so it is
# covered in-process by test_active_ticket_resolver.sh instead.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
NEW_HOOKS="$SRC_ROOT/.claude/hooks"
NEW_DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"
BASE=$(cat "$SRC_ROOT/.claude/hooks/tests/compat/dev-base/BASE" 2>/dev/null)
BASE="${BASE:-HEAD}"

export APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE CLAUDE_WORKTREE_BRANCH

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

T=$(mktemp -d)
T=$(cd -P "$T" && pwd)
trap 'rm -rf "$T"' EXIT

VERSIONS="new"
mkdir -p "$T/base"
if git -C "$SRC_ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null \
  && git -C "$SRC_ROOT" archive "$BASE" .claude/hooks .claude/project-config.defaults.json 2>/dev/null | tar -x -C "$T/base" 2>/dev/null \
  && [ -f "$T/base/.claude/hooks/require-active-ticket.sh" ]; then
  VERSIONS="new base"
else
  echo "INFO: $BASE is not in the local history, so the rows run against the current hooks only"
fi

mkrepo() {
  git init -q "$1"
  git -C "$1" commit -q --allow-empty -m init
}

# make_sb <version> <name>: an ops fork with the hooks of <version>, a
# registered clone workspace/p1 and a registered clone p5 at an absolute
# workspace: path outside the workspace dir. Prints the ops root.
make_sb() {
  local ver="$1" name="$2" ops hooks defaults f
  ops="$T/$ver-$name/ops"
  if [ "$ver" = new ]; then hooks="$NEW_HOOKS"; defaults="$NEW_DEFAULTS"; else hooks="$T/base/.claude/hooks"; defaults="$T/base/.claude/project-config.defaults.json"; fi
  mkrepo "$ops"
  : > "$ops/.apexyard-fork"
  : > "$ops/onboarding.yaml"
  mkdir -p "$ops/.claude/hooks" "$ops/.claude/session" "$ops/workspace" "$T/$ver-$name/ext"
  for f in "$hooks"/*.sh; do cp "$f" "$ops/.claude/hooks/"; done
  chmod +x "$ops/.claude/hooks/"*.sh
  cp "$defaults" "$ops/.claude/project-config.defaults.json"
  printf 'projects:\n  - name: p1\n    repo: org/p1\n  - name: p5\n    repo: org/p5\n    workspace: %s\n' "$T/$ver-$name/ext/p5" > "$ops/apexyard.projects.yaml"
  mkrepo "$ops/workspace/p1"
  mkrepo "$T/$ver-$name/ext/p5"
  printf '%s' "$ops"
}

# gate <ops> <cwd> <payload>: runs the ticket gate of the sandbox, sets RC
# A real session has a session id, and its SessionStart hook pins the ops
# root, so a hook finds the ops root from any target. Each call models that
# with its own pin file in a temporary pin dir. The resolution cache stays
# off, as the session isolation helper sets it.
gate() {
  local ops="$1" cwd="$2" payload="$3"
  mkdir -p "$T/pins"
  printf '%s\n' "$ops" > "$T/pins/ops-root-compat-rows"
  ERR=$(cd "$cwd" && printf '%s' "$payload" \
    | CLAUDE_CODE_SESSION_ID=compat-rows APEXYARD_OPS_DISABLE_PIN='' APEXYARD_OPS_PIN_DIR="$T/pins" \
      bash "$ops/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
  RC=$?
}
edit() { jq -nc --arg p "$1" '{tool_name:"Edit", tool_input:{file_path:$p}}'; }
bashc() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }
marker() { mkdir -p "${1%/*}"; printf 'repo=%s\nnumber=%s\ntitle=t\n' "$2" "$3" > "$1"; }
expect() {
  local name="$1" want="$2"
  if [ "$RC" = "$want" ]; then ok "$name"; else bad "$name" "want rc=$want got $RC (${ERR:0:${ROWS_ERR_LEN:-200}})"; fi
}

# new_start_ticket <ops> <tree> <repo> <number>: what the new /start-ticket
# does, with the current library whatever hooks the sandbox runs.
new_start_ticket() {
  local ops="$1" tree="$2" repo="$3" num="$4"
  (cd "$ops" && bash -c '. "$1" && active_ticket_init "$2"
    if active_ticket_gitdir "$2"; then active_ticket_write "$2" "$3" "$4" t u b; fi
    active_ticket_write_legacy "$2" "$3" "$4" t u b' _ "$NEW_HOOKS/_lib-active-ticket.sh" "$tree" "$repo" "$num") >/dev/null 2>&1
}

for v in $VERSIONS; do
  # B1
  OPS=$(make_sb "$v" b1)
  EXT="$T/$v-b1/ext/p5"
  marker "$OPS/.claude/session/current-ticket" org/p5 1
  gate "$OPS" "$OPS" "$(edit "$EXT/src/a.ts")"
  expect "B1 ($v) a workspace: clone outside the workspace dir uses current-ticket" 0
  rm -f "$OPS/.claude/session/current-ticket"
  marker "$OPS/.claude/session/tickets/p5" org/p5 1
  gate "$OPS" "$OPS" "$(edit "$EXT/src/a.ts")"
  expect "B1 ($v) tickets/p5 alone does not cover that clone" 2

  # B2
  OPS=$(make_sb "$v" b2)
  git -C "$OPS/workspace/p1" worktree add -q "$OPS/workspace/p1/.wt/w2" -b feature/w2
  marker "$OPS/.claude/session/tickets/p1/feature__w2" org/p1 2
  gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/.wt/w2/src/a.ts")"
  expect "B2 ($v) a linked worktree keeps its per-branch marker" 0
  gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
  expect "B2 ($v) the per-branch marker does not cover the main clone" 2

  # B3
  OPS=$(make_sb "$v" b3)
  OTHER="$T/$v-b3/home/work/other"
  mkrepo "$OTHER"
  git -C "$OTHER" remote add origin https://example.test/org/other.git
  marker "$OPS/.claude/session/current-ticket" org/other 3
  gate "$OPS" "$OPS" "$(edit "$OTHER/src/a.ts")"
  expect "B3 ($v) an unregistered repo outside the fork uses current-ticket" 0
  rm -f "$OPS/.claude/session/current-ticket"
  gate "$OPS" "$OPS" "$(edit "$OTHER/src/a.ts")"
  expect "B3 ($v) without current-ticket it is blocked" 2

  # B4
  OPS=$(make_sb "$v" b4)
  marker "$OPS/.claude/session/current-ticket" org/p1 4
  gate "$OPS" "$OPS" "$(edit "$OPS/src/a.ts")"
  expect "B4 ($v) a current-ticket naming a managed project passes an ops edit" 0

  # B5
  OPS=$(make_sb "$v" b5)
  marker "$OPS/.claude/session/current-ticket" org/ops 5
  mkrepo "$OPS/vendor/nested"
  gate "$OPS" "$OPS" "$(edit "$OPS/vendor/nested/a.ts")"
  expect "B5 ($v) a nested repo in the fork uses current-ticket" 0
  mkdir -p "$OPS/broken"
  printf 'not a gitdir line\n' > "$OPS/broken/.git"
  gate "$OPS" "$OPS" "$(edit "$OPS/broken/a.ts")"
  expect "B5 ($v) a malformed .git file uses current-ticket" 0
  mkrepo "$T/$v-b5/subsrc"
  git -C "$OPS" -c protocol.file.allow=always submodule add -q "$T/$v-b5/subsrc" sub >/dev/null 2>&1
  if [ -e "$OPS/sub/.git" ]; then
    gate "$OPS" "$OPS" "$(edit "$OPS/sub/a.ts")"
    expect "B5 ($v) a submodule uses current-ticket" 0
  else
    echo "INFO: git submodule add failed here, so the submodule case did not run"
  fi
  mkrepo "$T/$v-b5/real-p1"
  rm -rf "$OPS/workspace/p1"
  ln -s "$T/$v-b5/real-p1" "$OPS/workspace/p1"
  gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
  expect "B5 ($v) a symlinked clone root uses current-ticket" 0

  # B6
  OPS=$(make_sb "$v" b6)
  marker "$OPS/.claude/session/current-ticket" org/p1 6
  gate "$OPS" "$OPS/workspace/p1" "$(bashc 'sed -i "s/x/y/" "$VAR"')"
  expect "B6 ($v) an unextractable Bash target in a clone uses current-ticket" 0
  rm -f "$OPS/.claude/session/current-ticket"
  gate "$OPS" "$OPS/workspace/p1" "$(bashc 'sed -i "s/x/y/" "$VAR"')"
  expect "B6 ($v) without current-ticket it is blocked" 2

  # B7
  OPS=$(make_sb "$v" b7)
  rm -f "$OPS/.claude/hooks/_lib-portfolio-paths.sh"
  marker "$OPS/.claude/session/tickets/p1" org/p1 7
  gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
  expect "B7 ($v) without the portfolio library tickets/p1 still counts" 0

  # B8
  OPS=$(make_sb "$v" b8)
  new_start_ticket "$OPS" "$OPS/workspace/p1" org/p1 8
  gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
  expect "B8 ($v) the new /start-ticket covers a main clone" 0
  git -C "$OPS/workspace/p1" worktree add -q "$OPS/workspace/p1/.wt/w8" -b feature/w8
  new_start_ticket "$OPS" "$OPS/workspace/p1/.wt/w8" org/p1 81
  gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/.wt/w8/src/a.ts")"
  expect "B8 ($v) the new /start-ticket covers a linked worktree" 0
  new_start_ticket "$OPS" "$OPS" org/ops 82
  gate "$OPS" "$OPS" "$(edit "$OPS/src/a.ts")"
  expect "B8 ($v) the new /start-ticket covers an ops edit" 0
done

# B9: one sandbox, hooks swapped mid-task in both directions.
if [ "$VERSIONS" = "new base" ]; then
  OPS=$(make_sb base b9)
  marker "$OPS/.claude/session/tickets/p1" org/p1 9
  gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
  expect "B9 a ticket started under the old hooks passes under them" 0
  for f in "$NEW_HOOKS"/*.sh; do cp "$f" "$OPS/.claude/hooks/"; done
  cp "$NEW_DEFAULTS" "$OPS/.claude/project-config.defaults.json"
  gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
  expect "B9 the same ticket passes after the update to the new hooks" 0
  rm -f "$OPS/.claude/session/tickets/p1"
  new_start_ticket "$OPS" "$OPS/workspace/p1" org/p1 91
  for f in "$T/base/.claude/hooks"/*.sh; do cp "$f" "$OPS/.claude/hooks/"; done
  cp "$T/base/.claude/project-config.defaults.json" "$OPS/.claude/project-config.defaults.json"
  gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
  expect "B9 a ticket started under the new hooks passes after a rollback" 0
else
  OPS=$(make_sb new b9)
  marker "$OPS/.claude/session/tickets/p1" org/p1 9
  gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
  expect "B9 (new) a ticket started under the old layout passes" 0
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
