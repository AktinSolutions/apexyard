#!/bin/bash
# inject-project-context.sh — PostToolUse hook. On the first Read/Glob/
# Grep/Edit/Write/MultiEdit that touches a registered managed project's
# workspace, injects that project's own CLAUDE.md, rules, skills and
# agents as additionalContext (me2resh/apexyard#1423).
#
# WHY: a managed project checkout can live outside the ops fork (split
# portfolio, or any layout where workspace/<project> isn't nested under
# this repo). Claude Code only auto-loads a nested CLAUDE.md — a project
# checked out elsewhere never gets its own conventions in context, so
# build agents write code Rex then has to catch, and Rex reviews against
# framework rules only. This hook reads the project's context LIVE from
# its own repo on every injection; nothing is copied or snapshotted, so
# it can't go stale the way projects/<name>/ docs can.
#
# FAIL-OPEN CONTRACT (mandatory — this is a PostToolUse hook, not a gate):
#   - exit 0 on every path, always. Never exit 2.
#   - jq / registry / any file missing → silent exit 0, no stderr noise.
#   - settings.json pins "timeout": 3 on this hook entry; Claude Code
#     discards the output on a timeout and the tool call is unaffected
#     either way (spike-verified: a hung hook body under `timeout: 3`
#     never delayed the Read it was attached to).
#   - `timeout 1` around the git worktree fallback call inside
#     _lib-project-context.sh, so a stalled repo can't eat the budget.
#
# DEDUPE: one injection per (session_id, agent_id-or-"main", project) —
# a marker directory claimed atomically with mkdir. A subagent has its
# own agent_id (spike-confirmed) and so gets its own injection.
#
# SCOPE: matched on Read|Glob|Grep|Edit|Write|MultiEdit in settings.json.
# Bash writes (`cat > workspace/x/foo.ts`) are NOT covered — see the
# ponytail note at the bottom.

trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

case "$FILE_PATH" in
  /*) ABS_PATH="$FILE_PATH" ;;
  *)
    [ -n "$CWD" ] || exit 0
    ABS_PATH="$CWD/$FILE_PATH"
    ;;
esac

HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || exit 0

for lib in _lib-read-config.sh _lib-ops-root.sh _lib-portfolio-paths.sh _lib-multi-repo-trace.sh _lib-project-context.sh; do
  [ -f "$HOOK_DIR/$lib" ] || exit 0
  # shellcheck source=/dev/null
  . "$HOOK_DIR/$lib" 2>/dev/null || exit 0
done

# Collapse ".." and symlinks so "<ws>/../other/f" can't match <ws>.
ABS_PATH=$(_portfolio_canonicalize "$ABS_PATH" 2>/dev/null) || exit 0
[ -n "$ABS_PATH" ] || exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] || exit 0
export PROJCTX_SESSION_ID="$SESSION_ID"

PROJECT_LINE=$(projctx_resolve "$ABS_PATH" 2>/dev/null) || exit 0
[ -n "$PROJECT_LINE" ] || exit 0

PROJECT_NAME="${PROJECT_LINE%%$'\t'*}"
PROJECT_WS="${PROJECT_LINE#*$'\t'}"
[ -n "$PROJECT_NAME" ] && [ -n "$PROJECT_WS" ] || exit 0

# Already inside the project's own tree → Claude Code loads its CLAUDE.md
# natively; injecting again would duplicate it in context for free.
if [ -n "$CWD" ] && portfolio_path_under "$CWD" "$PROJECT_WS" 2>/dev/null; then
  exit 0
fi

AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
[ -n "$AGENT_ID" ] || AGENT_ID="main"

MARKER_DIR=$(projctx_state_dir) || exit 0
MARKER_KEY=$(printf '%s|%s|%s' "$SESSION_ID" "$AGENT_ID" "$PROJECT_NAME" | cksum 2>/dev/null | awk '{print $1}')
[ -n "$MARKER_KEY" ] || exit 0
MARKER="$MARKER_DIR/injected-$MARKER_KEY"

# Claim the marker atomically BEFORE building the text: mkdir is atomic and
# refuses an existing path (a symlink too). Release it on any failure so the
# next touch retries.
mkdir "$MARKER" 2>/dev/null || exit 0

CONTEXT=$(projctx_emit "$PROJECT_NAME" "$PROJECT_WS" 2>/dev/null) && [ -n "$CONTEXT" ] || { rmdir "$MARKER" 2>/dev/null; exit 0; }

OUTPUT=$(jq -n --arg t "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $t
  }
}' 2>/dev/null) || { rmdir "$MARKER" 2>/dev/null; exit 0; }

printf '%s\n' "$OUTPUT"
exit 0
# ponytail: ~55 ms per call on a path outside every workspace (measured
#   on Linux), spread over jq/cksum/awk/stat process spawns. Upgrade: one
#   jq call for all fields, and bash-only hashing, if it shows up in use.
# ponytail: two known ceilings, not bugs.
#   1. Compaction can drop this turn's additionalContext from the model's
#      working context, and the dedupe marker stays written — the project
#      never gets re-injected in that session. Upgrade: clear
#      ${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/projctx/injected-* markers on PreCompact / a
#      SessionStart that detects a resumed-after-compact session.
#   2. Bash tool calls are not matched (settings.json matcher stops at
#      Read|Glob|Grep|Edit|Write|MultiEdit), so `cat > workspace/x/f.ts`
#      injects nothing. Upgrade: key resolution on `.cwd` alone (no
#      tool_input path needed) so a Bash matcher entry can reuse
#      projctx_resolve unchanged.
