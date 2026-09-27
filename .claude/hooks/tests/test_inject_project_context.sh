#!/bin/bash
# Tests for inject-project-context.sh + _lib-project-context.sh
# (me2resh/apexyard#1423).
#
# Builds a throwaway ops fork (onboarding.yaml + apexyard.projects.yaml
# anchors) registering one project, plus a project workspace with a
# CLAUDE.md, one paths:-free rule, one paths:-scoped rule, a skill and an
# agent. Drives inject-project-context.sh directly via fake PostToolUse
# stdin, exactly as the harness would call it.
#
# Exit 0 = all pass. Exit 1 on any failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_DIR="$SRC_ROOT/.claude/hooks"
HOOK="$HOOK_DIR/inject-project-context.sh"

for f in "$HOOK" "$HOOK_DIR/_lib-project-context.sh" "$HOOK_DIR/_lib-multi-repo-trace.sh" \
         "$HOOK_DIR/_lib-portfolio-paths.sh" "$HOOK_DIR/_lib-read-config.sh" "$HOOK_DIR/_lib-ops-root.sh"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
pass_case() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "   $2" >&2; FAIL=$((FAIL + 1)); }

SB=$(mktemp -d -t projctx-test.XXXXXX)
OUTSIDE=$(mktemp -d -t projctx-outside.XXXXXX)
trap 'rm -rf "$SB" "$OUTSIDE" "$MARKER_DIR"' EXIT

FORK="$SB/fork"
WS="$SB/ws/demo"
mkdir -p "$FORK/.claude/hooks" "$WS/.claude/rules" "$WS/.claude/skills/deploy" "$WS/.claude/agents"

for f in _lib-project-context.sh _lib-multi-repo-trace.sh _lib-portfolio-paths.sh \
         _lib-read-config.sh _lib-ops-root.sh inject-project-context.sh; do
  cp "$HOOK_DIR/$f" "$FORK/.claude/hooks/$f"
done

: > "$FORK/onboarding.yaml"
cat > "$FORK/apexyard.projects.yaml" <<YAML
version: 1
projects:
  - name: demo
    repo: acme/demo
    workspace: $WS
    status: active
YAML

cat > "$WS/CLAUDE.md" <<'MD'
# Demo project

CANARY_CLAUDE_MD_MARKER lives here.

@docs/architecture.md
MD

cat > "$WS/.claude/rules/general.md" <<'MD'
# General rule (no paths:)

CANARY_RULE_FULL_TEXT
MD

cat > "$WS/.claude/rules/scoped.md" <<'MD'
---
paths:
  - "src/payments/**"
---

# Scoped rule (has paths:)

Should be indexed, not inlined.
MD

cat > "$WS/.claude/skills/deploy/SKILL.md" <<'MD'
---
name: deploy
description: CANARY_SKILL_DESCRIPTION
---

# /deploy
MD

cat > "$WS/.claude/agents/releaser.md" <<'MD'
---
name: releaser
description: CANARY_AGENT_DESCRIPTION
---

# Releaser
MD

# State dir lives under the ops pin dir; point it into the sandbox.
export APEXYARD_OPS_PIN_DIR="$SB/pins"
MARKER_DIR="$APEXYARD_OPS_PIN_DIR/projctx"
rm -rf "$MARKER_DIR"

# stdin JSON builder: session_id, optional agent_id, cwd, tool + path key.
payload() {
  local session="$1" agent="$2" cwd="$3" path="$4" path_key="${5:-file_path}"
  if [ -n "$agent" ]; then
    jq -n --arg s "$session" --arg a "$agent" --arg c "$cwd" --arg p "$path" --arg k "$path_key" \
      '{session_id: $s, agent_id: $a, cwd: $c, tool_name: "Read", tool_input: {($k): $p}}'
  else
    jq -n --arg s "$session" --arg c "$cwd" --arg p "$path" --arg k "$path_key" \
      '{session_id: $s, cwd: $c, tool_name: "Read", tool_input: {($k): $p}}'
  fi
}

# Invocation: run from inside the fake fork so ops-root walk-up finds it.
# Unsets the session pin (apexyard#381) — otherwise a real Claude Code
# session's own ops-root pin would win over the fake fork's walk-up
# anchors, exactly as test_multi_repo_registry.sh already guards against.
invoke() {
  local stdin_json="$1"
  ( cd "$FORK" && unset CLAUDE_CODE_SESSION_ID 2>/dev/null
    printf '%s' "$stdin_json" | "$FORK/.claude/hooks/inject-project-context.sh" )
}

# --- (a) matching path → emits additionalContext with CLAUDE.md, rule handling, skill index
OUT=$(invoke "$(payload s1 "" "" "$WS/src/index.ts")")
EXIT=$?
if [ "$EXIT" = 0 ] && echo "$OUT" | grep -q "CANARY_CLAUDE_MD_MARKER" \
   && echo "$OUT" | grep -q "CANARY_RULE_FULL_TEXT" \
   && echo "$OUT" | grep -q "src/payments" \
   && echo "$OUT" | grep -q "CANARY_SKILL_DESCRIPTION" \
   && echo "$OUT" | grep -q "CANARY_AGENT_DESCRIPTION" \
   && echo "$OUT" | grep -q "NOT registered slash commands"; then
  pass_case "(a) matching path injects CLAUDE.md + full rule + scoped-rule index + skill/agent index"
else
  fail_case "(a) matching path" "exit=$EXIT out=$(echo "$OUT" | head -c 400)"
fi
rm -rf "$MARKER_DIR"

# --- (b) non-matching path → no output, exit 0
OUT=$(invoke "$(payload s2 "" "" "$OUTSIDE/somewhere/file.ts")")
EXIT=$?
if [ "$EXIT" = 0 ] && [ -z "$OUT" ]; then
  pass_case "(b) non-matching path: no output, exit 0"
else
  fail_case "(b) non-matching path" "exit=$EXIT out=$(echo "$OUT" | head -c 200)"
fi
rm -rf "$MARKER_DIR"

# --- (c) worktree path OUTSIDE the workspace resolves to the project
git -C "$WS" init -q 2>/dev/null
git -C "$WS" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init 2>/dev/null
WT="$OUTSIDE/demo-worktree"
git -C "$WS" worktree add -q -b projctx-test-wt "$WT" 2>/dev/null
if [ -d "$WT" ]; then
  OUT=$(invoke "$(payload s3 "" "" "$WT/src/index.ts")")
  EXIT=$?
  if [ "$EXIT" = 0 ] && echo "$OUT" | grep -q "CANARY_CLAUDE_MD_MARKER"; then
    pass_case "(c) worktree path outside the workspace resolves to the project"
  else
    fail_case "(c) worktree path" "exit=$EXIT out=$(echo "$OUT" | head -c 200)"
  fi
else
  fail_case "(c) worktree path" "git worktree add failed — could not set up case"
fi
rm -rf "$MARKER_DIR"

# --- (d) dedupe: same session+agent repeats → no output; different agent_id → output again
invoke "$(payload s4 "" "" "$WS/a.ts")" >/dev/null
OUT_REPEAT=$(invoke "$(payload s4 "" "" "$WS/b.ts")")
OUT_OTHER_AGENT=$(invoke "$(payload s4 sub2 "" "$WS/c.ts")")
if [ -z "$OUT_REPEAT" ] && [ -n "$OUT_OTHER_AGENT" ]; then
  pass_case "(d) dedupe: same session+agent silent on repeat, different agent_id injects again"
else
  fail_case "(d) dedupe" "repeat='$(echo "$OUT_REPEAT" | head -c 80)' other_agent_len=${#OUT_OTHER_AGENT}"
fi
rm -rf "$MARKER_DIR"

# --- (e) cwd already inside the workspace → no output (native CLAUDE.md load)
OUT=$(invoke "$(payload s5 "" "$WS" "$WS/src/index.ts")")
EXIT=$?
if [ "$EXIT" = 0 ] && [ -z "$OUT" ]; then
  pass_case "(e) cwd inside workspace: no output (native load)"
else
  fail_case "(e) cwd inside workspace" "exit=$EXIT out=$(echo "$OUT" | head -c 200)"
fi
rm -rf "$MARKER_DIR"

# --- (f) oversize CLAUDE.md (15KB) → total additionalContext <= 9500 chars, contains truncation pointer
cp "$WS/CLAUDE.md" "$WS/CLAUDE.md.bak"
{
  echo "# Demo project"
  echo
  echo "CANARY_CLAUDE_MD_MARKER lives here."
  for i in $(seq 1 400); do
    echo "Padding line $i to blow past the additionalContext budget with filler prose that is not meaningful on its own."
  done
} > "$WS/CLAUDE.md"
[ "$(wc -c < "$WS/CLAUDE.md")" -gt 15000 ] || echo "warning: fixture CLAUDE.md smaller than expected" >&2

RAW=$(invoke "$(payload s6 "" "" "$WS/src/index.ts")")
CTX=$(printf '%s' "$RAW" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
CTX_LEN=${#CTX}
if [ "$CTX_LEN" -gt 0 ] && [ "$CTX_LEN" -le 9500 ] && printf '%s' "$CTX" | grep -q "truncated" \
   && printf '%s' "$CTX" | grep -q "CANARY_SKILL_DESCRIPTION"; then
  pass_case "(f) oversize CLAUDE.md: total additionalContext <= 9500 chars ($CTX_LEN), truncation pointer present, skill index kept"
else
  fail_case "(f) oversize CLAUDE.md" "len=$CTX_LEN contains_truncated=$(printf '%s' "$CTX" | grep -c truncated)"
fi
mv "$WS/CLAUDE.md.bak" "$WS/CLAUDE.md"
rm -rf "$MARKER_DIR"

# --- (g) broken input / missing registry → exit 0, no output
OUT=$(printf 'not json at all' | ( cd "$FORK" && "$FORK/.claude/hooks/inject-project-context.sh" ))
EXIT_BROKEN=$?
mv "$FORK/apexyard.projects.yaml" "$FORK/apexyard.projects.yaml.bak"
OUT2=$(invoke "$(payload s7 "" "" "$WS/src/index.ts")")
EXIT_NOREG=$?
mv "$FORK/apexyard.projects.yaml.bak" "$FORK/apexyard.projects.yaml"
if [ "$EXIT_BROKEN" = 0 ] && [ -z "$OUT" ] && [ "$EXIT_NOREG" = 0 ] && [ -z "$OUT2" ]; then
  pass_case "(g) broken stdin and missing registry both fail open: exit 0, no output"
else
  fail_case "(g) broken input / missing registry" "exit_broken=$EXIT_BROKEN out='$OUT' exit_noreg=$EXIT_NOREG out2='$OUT2'"
fi
rm -rf "$MARKER_DIR"

# --- (h) "<ws>/../x" escapes the workspace → no injection
OUT=$(invoke "$(payload s8 "" "" "$WS/../../outside-file.ts")")
if [ -z "$OUT" ]; then
  pass_case "(h) '..' path that leaves the workspace injects nothing"
else
  fail_case "(h) '..' escape" "out=$(printf '%s' "$OUT" | head -c 200)"
fi
rm -rf "$MARKER_DIR"

# --- (i) state dir pre-planted as a symlink (another user's dir) → refused, fail open
mkdir -p "$OUTSIDE/evil" "$APEXYARD_OPS_PIN_DIR"
ln -s "$OUTSIDE/evil" "$MARKER_DIR"
OUT=$(invoke "$(payload s9 "" "" "$WS/src/index.ts")")
EXIT_I=$?
if [ "$EXIT_I" = 0 ] && [ -z "$OUT" ] && [ -z "$(ls -A "$OUTSIDE/evil")" ]; then
  pass_case "(i) symlinked state dir refused: exit 0, no output, nothing written through the link"
else
  fail_case "(i) symlinked state dir" "exit=$EXIT_I out_len=${#OUT} evil=$(ls -A "$OUTSIDE/evil" | tr '\n' ' ')"
fi
rm -f "$MARKER_DIR"

echo "===== test_inject_project_context.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
