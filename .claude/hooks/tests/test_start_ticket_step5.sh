#!/bin/bash
# /start-ticket step 5 runs in a tree that has no ticket yet. The ticket gate
# must let both of its tool calls through, whatever the issue title holds.
#
# The test takes the step 5 command from SKILL.md, so a change to the skill
# text is tested as written. For each title it checks that:
#   - the Write of the ticket fields file passes the gate
#   - the fixed command passes the gate
#   - the command writes both markers with the title as given, and deletes
#     the fields file
# A control case shows that the same title on the command line is read as a
# file write and blocked. A symlinked fields file is refused.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS="$SRC_ROOT/.claude/hooks"
SKILL="$SRC_ROOT/.claude/skills/start-ticket/SKILL.md"

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

# The bash block of step 5, with its list indent removed.
STEP5=$(awk '
  /^### 5\. Write the markers/ { in5 = 1; next }
  in5 && /^### / { exit }
  in5 && /^[[:space:]]*```bash[[:space:]]*$/ { code = 1; next }
  in5 && code && /^[[:space:]]*```[[:space:]]*$/ { exit }
  in5 && code { sub(/^   /, ""); print }
' "$SKILL")
if [ -n "$STEP5" ]; then ok "step 5 has a bash command"; else bad "step 5 has a bash command" "no bash block found in $SKILL"; fi
case "$STEP5" in
  *'<title>'*|*'"$3"'*) bad "the step 5 command takes paths only" "$STEP5" ;;
  *) ok "the step 5 command takes paths only" ;;
esac

mkrepo() {
  git init -q "$1"
  git -C "$1" commit -q --allow-empty -m init
}

# make_sb <name>: an ops fork with the current hooks and a registered clone
# workspace/p1. No marker exists anywhere. Prints the ops root.
make_sb() {
  local ops="$T/$1/ops" f
  mkrepo "$ops"
  : > "$ops/.apexyard-fork"
  : > "$ops/onboarding.yaml"
  mkdir -p "$ops/.claude/hooks" "$ops/.claude/session" "$ops/workspace"
  for f in "$HOOKS"/*.sh; do cp "$f" "$ops/.claude/hooks/"; done
  chmod +x "$ops/.claude/hooks/"*.sh
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$ops/.claude/project-config.defaults.json"
  printf 'projects:\n  - name: p1\n    repo: org/p1\n' > "$ops/apexyard.projects.yaml"
  mkrepo "$ops/workspace/p1"
  printf '%s' "$ops"
}

# gate <ops> <payload>: runs the sandbox's ticket gate from the ops root with
# a pinned session, as a real session does. Sets RC and ERR.
gate() {
  mkdir -p "$T/pins"
  printf '%s\n' "$1" > "$T/pins/ops-root-step5"
  ERR=$(cd "$1" && printf '%s' "$2" \
    | CLAUDE_CODE_SESSION_ID=step5 APEXYARD_OPS_DISABLE_PIN='' APEXYARD_OPS_PIN_DIR="$T/pins" \
      bash "$1/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
  RC=$?
}

# step5_cmd <ops> <tree>: the SKILL.md command with the two paths filled in.
step5_cmd() {
  local c="$STEP5"
  c="${c//\"\$ops_root\"/\"$1\"}"
  c="${c//\"\$tree\"/\"$2\"}"
  printf '%s' "$c"
}

fields() {
  printf 'repo=org/p1\nnumber=%s\ntitle=%s\nurl=https://example.test/%s\nsuggested_branch=feature/GH-%s-x\n' "$1" "$2" "$1" "$1"
}

n=10
for title in 'Fix a > b redirect in the report' 'Pipe the log | tee out.txt' 'Stop sed -i on the config'; do
  n=$((n + 1))
  OPS=$(make_sb "t$n")
  TREE="$OPS/workspace/p1"
  PENDING="$OPS/.claude/session/start-ticket.pending"

  gate "$OPS" "$(jq -nc --arg p "$PENDING" --arg c "$(fields "$n" "$title")" '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')"
  if [ "$RC" = 0 ]; then ok "[$title] the Write of the fields file passes the gate"; else bad "[$title] the Write of the fields file passes the gate" "rc=$RC ${ERR:0:300}"; fi
  fields "$n" "$title" > "$PENDING"

  CMD=$(step5_cmd "$OPS" "$TREE")
  gate "$OPS" "$(jq -nc --arg c "$CMD" '{tool_name:"Bash", tool_input:{command:$c}}')"
  if [ "$RC" = 0 ]; then ok "[$title] the step 5 command passes the gate"; else bad "[$title] the step 5 command passes the gate" "rc=$RC ${ERR:0:300}"; fi

  out=$(cd "$OPS" && bash -c "$CMD" 2>&1)
  rc=$?
  if [ "$rc" = 0 ] \
     && grep -qxF "title=$title" "$TREE/.git/apexyard-ticket" 2>/dev/null \
     && grep -qx 'repo=org/p1' "$TREE/.git/apexyard-ticket" \
     && grep -qx "number=$n" "$TREE/.git/apexyard-ticket" \
     && grep -qx "suggested_branch=feature/GH-$n-x" "$TREE/.git/apexyard-ticket"; then
    ok "[$title] the command writes the marker in the tree's git dir"
  else
    bad "[$title] the command writes the marker in the tree's git dir" "rc=$rc out=$out marker=$(cat "$TREE/.git/apexyard-ticket" 2>&1)"
  fi
  if grep -qxF "title=$title" "$OPS/.claude/session/tickets/p1" 2>/dev/null && grep -qx "number=$n" "$OPS/.claude/session/tickets/p1"; then
    ok "[$title] the command writes the old-layout marker"
  else
    bad "[$title] the command writes the old-layout marker" "$(cat "$OPS/.claude/session/tickets/p1" 2>&1)"
  fi
  if [ ! -e "$PENDING" ]; then ok "[$title] the fields file is deleted"; else bad "[$title] the fields file is deleted" "$PENDING still exists"; fi

  # Control: the same title as a command-line argument is read as a write.
  OLD="bash -c '. \"\$1/.claude/hooks/_lib-active-ticket.sh\" && active_ticket_write_legacy \"\$2\" \"\$3\" \"\$4\" \"\$5\"' _ \"$OPS\" \"$TREE\" org/p1 $n \"$title\""
  gate "$OPS" "$(jq -nc --arg c "$OLD" '{tool_name:"Bash", tool_input:{command:$c}}')"
  if [ "$RC" = 2 ]; then ok "[$title] control: the title on the command line is blocked"; else bad "[$title] control: the title on the command line is blocked" "rc=$RC"; fi
done

# A symlinked fields file is refused, removed, and writes no marker.
OPS=$(make_sb sym)
TREE="$OPS/workspace/p1"
fields 20 'Symlinked' > "$T/elsewhere"
ln -s "$T/elsewhere" "$OPS/.claude/session/start-ticket.pending"
out=$(cd "$OPS" && bash -c "$(step5_cmd "$OPS" "$TREE")" 2>&1)
rc=$?
if [ "$rc" != 0 ] && [ ! -e "$TREE/.git/apexyard-ticket" ] && [ ! -e "$OPS/.claude/session/tickets/p1" ] \
   && [ ! -L "$OPS/.claude/session/start-ticket.pending" ] && [ -f "$T/elsewhere" ]; then
  ok "a symlinked fields file is refused"
else
  bad "a symlinked fields file is refused" "rc=$rc out=$out"
fi

# A fields file with no repo= line writes nothing.
OPS=$(make_sb norepo)
TREE="$OPS/workspace/p1"
printf 'number=21\ntitle=x\n' > "$OPS/.claude/session/start-ticket.pending"
out=$(cd "$OPS" && bash -c "$(step5_cmd "$OPS" "$TREE")" 2>&1)
rc=$?
if [ "$rc" != 0 ] && [ ! -e "$TREE/.git/apexyard-ticket" ] && [ ! -e "$OPS/.claude/session/start-ticket.pending" ]; then
  ok "a fields file with no repo is refused"
else
  bad "a fields file with no repo is refused" "rc=$rc out=$out"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
