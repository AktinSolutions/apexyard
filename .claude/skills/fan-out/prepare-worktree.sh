#!/bin/bash
# Prepare one worktree for a /fan-out writer task.
#
# Usage: prepare-worktree.sh <source-tree> <worktree-path> <branch> [<repo> <number> <title> <url>]
#
#   <source-tree>    The working tree the task belongs to. A task on a managed
#                    project uses workspace/<name>/. A task on the ops fork
#                    uses the ops root. The worktree is created from this
#                    tree, never from another repo.
#   <worktree-path>  Where the new linked worktree goes. It must not exist.
#   <branch>         The new branch for the worktree.
#   ticket fields    Optional. Without them, the script copies the ticket of
#                    <source-tree> (its repo, number, title and url).
#
# The script writes the ticket marker into the git dir of the new worktree,
# through the shared resolver, so the ticket gate lets the writer agent edit.
# If the marker write fails, the script removes the worktree and the branch
# it created. It never uses --force.
#
# On success it prints the worktree path. On failure it prints the reason to
# stderr and exits non-zero.

set -u

SOURCE="${1:-}"
WTPATH="${2:-}"
BRANCH="${3:-}"
if [ -z "$SOURCE" ] || [ -z "$WTPATH" ] || [ -z "$BRANCH" ]; then
  echo "usage: prepare-worktree.sh <source-tree> <worktree-path> <branch> [<repo> <number> <title> <url>]" >&2
  exit 2
fi
REPO="${4:-}"
NUMBER="${5:-}"
TITLE="${6:-}"
URL="${7:-}"

HOOK_DIR="$(cd "$(dirname "$0")/../../hooks" && pwd)"
if [ ! -f "$HOOK_DIR/_lib-active-ticket.sh" ]; then
  echo "prepare-worktree: _lib-active-ticket.sh not found next to the hooks" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-active-ticket.sh"

if [ -e "$WTPATH" ]; then
  echo "prepare-worktree: $WTPATH already exists" >&2
  exit 1
fi

if ! active_ticket_init "$SOURCE"; then
  echo "prepare-worktree: cannot resolve the ops root for $SOURCE" >&2
  exit 1
fi

# The source tree must be a valid tree, and it must hold a ticket when the
# caller gave none.
if [ -z "$NUMBER" ]; then
  if ! active_ticket_lookup "$SOURCE"; then
    echo "prepare-worktree: no active ticket for $SOURCE. Run /start-ticket there first." >&2
    exit 1
  fi
  marker="$REPLY"
  active_ticket_read_field "$marker" repo && REPO="$REPLY"
  active_ticket_read_field "$marker" number && NUMBER="$REPLY"
  active_ticket_read_field "$marker" title && TITLE="$REPLY"
  active_ticket_read_field "$marker" url && URL="$REPLY"
  if [ -z "$REPO" ] || [ -z "$NUMBER" ]; then
    echo "prepare-worktree: the ticket marker of $SOURCE has no repo= or number=" >&2
    exit 1
  fi
else
  if ! active_ticket_gitdir "$SOURCE"; then
    echo "prepare-worktree: $SOURCE is not a valid working tree: ${AT_REASON:-git dir failed validation}" >&2
    exit 1
  fi
fi

if ! git -C "$SOURCE" worktree add -q "$WTPATH" -b "$BRANCH" 2>/dev/null; then
  echo "prepare-worktree: git worktree add failed for $WTPATH on branch $BRANCH" >&2
  exit 1
fi

_at_memo_clear
if ! active_ticket_write "$WTPATH" "$REPO" "$NUMBER" "$TITLE" "$URL" "$BRANCH"; then
  echo "prepare-worktree: the marker write failed, so the worktree is removed" >&2
  git -C "$SOURCE" worktree remove "$WTPATH" >/dev/null 2>&1 || true
  git -C "$SOURCE" branch -d "$BRANCH" >/dev/null 2>&1 || true
  exit 1
fi

printf '%s\n' "$WTPATH"
