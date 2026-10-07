#!/bin/bash
# SessionStart hook: tell the agent that old-layout ticket markers exist.
#
# Ticket markers moved to each working tree's git dir (AgDR-0216). Old files
# under <ops_root>/.claude/session/ still work in a main clone, for their own
# project only, until the legacy reader is removed. This hook prints one
# notice at session start when any old file exists. SessionStart stdout goes
# into the agent's context, so the notice reaches the agent whether or not a
# later edit is blocked.
#
# Advisory only. It always exits 0, prints nothing when no old file exists,
# and never deletes or moves a file.

set -u

# The hook input is not needed.
if [ ! -t 0 ]; then cat >/dev/null 2>&1 || true; fi

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  ROOT=$(resolve_ops_root "${REPO_ROOT:-$PWD}")
fi
[ -n "$ROOT" ] || exit 0

SESSION_DIR="$ROOT/.claude/session"
found=""
[ -f "$SESSION_DIR/current-ticket" ] && found="$SESSION_DIR/current-ticket"
if [ -d "$SESSION_DIR/tickets" ]; then
  for f in "$SESSION_DIR/tickets"/*; do
    [ -e "$f" ] || continue
    found="${found:+$found, }$f"
  done
fi
[ -n "$found" ] || exit 0

printf "apexyard: ticket markers moved to each working tree's git dir. Old markers are used only in a main clone and only for their own project, until you run /start-ticket <N> in that tree. Found: %s. See AgDR-0216.\n" "$found"
exit 0
