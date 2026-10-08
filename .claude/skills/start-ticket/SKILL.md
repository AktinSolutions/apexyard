---
name: start-ticket
description: Declare an active ticket so the ticket-first hook lets code edits through. Accepts `<N>` or `<owner>/<repo>#<N>`.
disable-model-invocation: false
argument-hint: "<issue-number> | <owner/repo>#<number>"
effort: low
---

## Writing rule

When this skill writes a durable artifact, read .claude/rules/writing-standard.md. Use the controlled technical writing profile.

# /start-ticket - Declare the Active Ticket

Writes the active-ticket marker for one working tree, so the `require-active-ticket.sh` PreToolUse hook permits Edit/Write on code paths in that tree. Without it, the hook blocks edits to anything outside `.claude/`, `docs/`, `projects/*/docs/`, and `*.md`.

Each working tree keeps its own marker in its own git dir (AgDR-0216):

| Working tree | Marker path |
|--------------|-------------|
| Main clone (the ops fork, or `workspace/<project>/`) | `<repo>/.git/apexyard-ticket` |
| Linked worktree (`git worktree add`) | `<repo>/.git/worktrees/<id>/apexyard-ticket` |

One tree holds one ticket. Parallel sessions on one project no longer overwrite each other, because each linked worktree has its own marker. `git worktree remove` deletes the marker with the worktree. The marker is never tracked, so it does not appear in `git status`.

The hook accepts a git dir only for the ops fork or a registered `workspace/<project>/` clone. The marker is a process gate. Anyone with write access to the git dir can forge it. It is not an authorization boundary.

Old-layout markers under `<ops_root>/.claude/session/` (`current-ticket`, `tickets/<project>`) still work in a main clone, for their own project only, until the legacy reader is removed. Step 4d offers to move one.

This is the mechanical enforcement of the Pre-Build Gate in `.claude/rules/workflow-gates.md` — "do not start coding until the ticket exists".

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Process

### 1. Parse Arguments

Expected forms:

- `42` — plain number, resolves against the current repo. Read `git remote get-url origin` and extract `<owner>/<repo>`. If there's no origin, stop and ask for a fully-qualified reference.
- `other-org/other-repo#128` — fully-qualified reference.
- `apexyard#42` — owner defaults to the current org (parsed from the origin URL).

If `$ARGUMENTS` is empty, stop and ask the user which issue they're starting.

**Cross-repo note:** ApexYard governs a portfolio of repos. If the user is in the ops repo (the apexyard fork) but the ticket lives in a managed project's own repo, they should pass the fully-qualified form so the marker records the correct tracker. Each managed project's tickets live in that project's own GitHub repo — tickets do not cross project boundaries.

### 2. Verify the Issue Exists

Source the tracker library and call `tracker_view`. The library dispatches the right CLI based on `.tracker.kind` in `.claude/project-config.{defaults,}.json` — `gh` (default), `linear`, `jira`, `asana`, `custom`, or `none`. See `.claude/hooks/_lib-tracker.sh` and AgDR-0033.

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-tracker.sh"

issue_json=$(tracker_view "<number>" "<owner/repo>")
state=$(echo "$issue_json" | jq -r '.state // empty')
title=$(echo "$issue_json" | jq -r '.title // empty')
url=$(echo "$issue_json" | jq -r '.url // empty')
```

The lib emits normalised JSON: `{state, title, url, labels}`. Each tracker adapter parses the underlying CLI's JSON into this common shape, so the skill doesn't need to branch per-CLI.

If the lib exits non-zero with empty stdout, the issue does not exist (or the CLI isn't installed / authenticated). Stop and report the error — do not write the marker.

If `state` indicates the ticket is closed (gh: `CLOSED`; linear/jira/asana: `Done` / `Closed` / `Resolved` / `Cancelled`), warn the user and confirm before continuing (sometimes you do want to resume work on a re-opened issue).

**`tracker.kind = none` adopters:** the lib returns no data. Skip the existence check entirely; trust the user's input. Re-verify the shape against `tracker_id_pattern` so obvious typos still block.

### 3. Derive a Branch Suggestion

From the issue title and number, generate: `<type>/<TICKET-ID>-<slug>` where:

- `<type>` guessed from title prefix: `[Feat]` → `feature`, `[Fix]` → `fix`, `[Docs]` → `docs`, `[Chore]` → `chore`, default `feature`
- `<TICKET-ID>` is `GH-<number>` for GitHub Issues, or matches the project's configured `ticket_prefix` from `apexyard.projects.yaml` if set
- `<slug>` = lowercase title, kebab-case, max 40 chars, stopwords trimmed from the edges

Match the convention in `.claude/rules/git-conventions.md`.

### 4. Resolve the target marker

The marker lives in the git dir of the working tree you are in. A ticket on a managed project's repo is declared from that project's clone, or from one of its worktrees.

#### 4a. Locate the ops root

The ops root is the apexyard fork root, anchored by EITHER the `.apexyard-fork` marker (split-portfolio v2, framework ≥ #242 — `onboarding.yaml` and `apexyard.projects.yaml` live in the sibling portfolio repo, not the fork) OR the legacy v1 pair (`onboarding.yaml` AND `apexyard.projects.yaml` both present in the same directory).

Locate `_lib-ops-root.sh` by walking up from `$PWD` — **not** via `git rev-parse --show-toplevel`. Inside a `workspace/<project>/` clone, `--show-toplevel` resolves to the *project* repo, and managed-project clones carry **no `.claude/hooks/` directory at all** (there is no framework mechanism that installs one there) — sourcing from that path silently fails, `resolve_ops_root` is never defined, and this step dead-ends exactly where split-portfolio v2 operators most often run `/start-ticket`. This is the same sibling walk-up pattern `bug`, `feature`, `task`, `migration`, `spike`, `prototype`, and 8 other ticket skills already use to locate `_lib-tracker.sh` — walk up until a directory containing the lib is found, then source it.

Keep two steps distinct: the walk-up below only finds a directory to **source the lib from** (the nearest fork-shaped root above cwd); `resolve_ops_root` then **decides the real ops root**, pin-first (apexyard#381) — the two can differ, e.g. a session pin can point at a different real ops fork than the nearest fork-shaped directory on the walk (say, cwd is inside an ops-fork-shaped `/tmp` build clone).

```bash
ops_lib="$(r="$PWD"; while [ -n "$r" ] && [ "$r" != / ]; do \
  [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] && { echo "$r/.claude/hooks/_lib-ops-root.sh"; break; }; \
  r="${r%/*}"; done)"
if [ -z "$ops_lib" ]; then
  echo "Not inside an apexyard fork (no .claude/hooks/_lib-ops-root.sh found walking up from $PWD)." >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$ops_lib"
ops_root=$(resolve_ops_root)
```

If `$ops_root` is still empty after sourcing (no pin, and `resolve_ops_root`'s own internal walk also found no anchor above cwd), tell the user and stop. Starting a ticket without the fork doesn't make sense.

#### 4b. Look the tracker repo up in the registry

Given the ticket's `owner/repo` (from step 1), resolve the registry path via `portfolio_registry` (see "Path resolution" above — do NOT hardcode `$ops_root/apexyard.projects.yaml`; in split-portfolio v2 the registry lives in the sibling repo, not the ops fork) and grep it for a project whose `repo:` field matches. `$ops_root` is already resolved and guaranteed to carry a `.claude/hooks/` tree (step 4a only succeeds when it does), so source directly from it — no second walk-up needed. One registry-safe way (uses `yq` when available, falls back to a greppy read):

```bash
source "$ops_root/.claude/hooks/_lib-read-config.sh"
source "$ops_root/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)

if command -v yq >/dev/null 2>&1; then
  project=$(yq eval ".projects[] | select(.repo == \"${OWNER_REPO}\") | .name" "$registry")
else
  # Greppy fallback: find the `name:` whose sibling `repo:` matches.
  # Strips surrounding quotes from both `name:` and `repo:` values so the
  # comparison works whether the registry uses bare scalars
  # (`repo: me2resh/sample-app`) or quoted scalars (`repo: "me2resh/…"`).
  project=$(awk -v r="$OWNER_REPO" '
    function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }
    /^[[:space:]]*- name:/ { name = unquote($3) }
    /^[[:space:]]*repo:/   { if (unquote($2) == r) { print name; exit } }
  ' "$registry")
fi
```

Notes on the fallback:

- Handles both `repo: me2resh/sample-app` and `repo: "me2resh/sample-app"` (and single-quoted).
- Assumes `- name:` is the FIRST key in each project entry — that matches the shape in `apexyard.projects.yaml.example` and every entry produced by `/handover`. If your registry reorders keys so `repo:` appears before `name:` in an entry, the lookup misses. Fix: move `name:` to the top, or install `yq` (the preferred path).
- Leading whitespace is tolerated via `^[[:space:]]*` — nested entries under `projects:` parse fine at any indent level, so long as the indent is consistent within the entry.

`$project` is now either a registered project name (e.g. `sample-app`, `demo-svc`) or empty (ticket's tracker repo isn't registered — typically because the ticket is on the ops fork itself, or a repo that's not under management).

#### 4c. Pick the working tree

The marker goes into the tree that holds the code you will change.

- Run the skill from inside the tree. The tree is the git top level of the working directory, so a subdirectory of the tree also works.
- A ticket can map to a registered project (step 4b) while you run from the ops fork's main tree. Then use the project's workspace clone as the tree.
- The workspace dir comes from `portfolio_workspace_dir`. A split-portfolio adopter keeps it outside the ops fork.
- A ticket on the ops fork itself uses the ops root, or the linked worktree of the ops fork you work in.

```bash
workspace_dir=$(portfolio_workspace_dir)
if [ "${workspace_dir#/}" = "$workspace_dir" ]
then
  workspace_dir="$ops_root/${workspace_dir#./}"
fi
cwd_top=$(git rev-parse --show-toplevel 2>/dev/null || true)
ops_top=$(cd "$ops_root" && pwd -P)
if [ -n "$project" ] && [ "$cwd_top" = "$ops_top" ]
then
  tree="$workspace_dir/$project"
else
  tree="${cwd_top:-$PWD}"
fi
```

#### 4d. Offer to move an old marker

If an old-layout file exists for this project (`$ops_root/.claude/session/tickets/<project>`), or for the ops fork (`$ops_root/.claude/session/current-ticket`), ask with `AskUserQuestion`:

> An old marker for `<repo>#<number>` exists. Write it to this tree and delete the old file?

On yes, use the old file's `repo` and `number` for step 5, then delete the old file. On no, continue with the ticket from step 1 and leave the old file. Never move a marker without asking.

### 5. Write the marker

The marker is written by one function, `active_ticket_write`, in `.claude/hooks/_lib-active-ticket.sh`. Run it through `bash -c`, with the values as arguments, so a title with quotes or newlines cannot break the command:

```bash
bash -c '. "$1/.claude/hooks/_lib-active-ticket.sh" && active_ticket_write "$2" "$3" "$4" "$5" "$6" "$7"' _ \
  "$ops_root" "$tree" "<owner/repo>" "<number>" "<title>" "<url>" "<branch>"
```

The function validates the tree, then writes these lines atomically into the tree's git dir:

```
repo=<owner/repo>
number=<number>
title=<title>
url=<url>
suggested_branch=<branch>
started_at=<ISO-8601>
```

It refuses a tree that is not the ops fork or a registered clone. It also refuses a symlink in the path, a repo owned by another user, and a malformed `.git` file. It prints the reason to stderr. If it prints a hint about the sandbox, the session may not write into the git dir. Stop and tell the user. See AgDR-0216 for the allowlist the user can add.

Do NOT write the marker with the Edit or Write tool. `.git` is a protected path for those tools.

### Read the active ticket

Other skills read the active ticket of the working tree through the same resolver. Run this from the tree you are in:

```bash
bash -c '. "$1/.claude/hooks/_lib-active-ticket.sh" && active_ticket_init "$PWD" && active_ticket_lookup_cwd && cat "$REPLY"' _ "$ops_root"
```

The command prints the marker (`repo=`, `number=`, `title=`, `url=`), or nothing when the tree has no marker.

### 6. Move the board card to "In progress" (opt-in)

After writing the marker, call `board_move_card` so the GitHub Projects board
reflects the ticket being picked up. This is a no-op unless `enable_auto_moves`
is `true` in the fork's `github_projects` config.

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-project-board.sh"
board_move_card "<number>" "in_progress"
```

`board_move_card` degrades gracefully: if the board is not configured, the item
is not on the board, or `gh project` scope is absent, it warns to stderr and
returns 0 — it never blocks the ticket start.

### 7. Confirm to the User

Output a confirmation that names the marker path, so the user sees which working tree this ticket governs:

```
Active ticket: <owner/repo>#<number> — <title>
Marker: <tree git dir>/apexyard-ticket  (this working tree only)
Suggested branch: <branch>
```

Do NOT create the branch automatically. The user may already be on a branch, or may want to confirm the branch name first.

## Notes

- The marker lives in the git dir, so it is per machine and per working tree. It is never committed.
- Running `/start-ticket` again in the same tree overwrites that tree's marker. That is how you switch tickets. A linked worktree and its main clone hold separate markers.
- To clear a tree's marker, delete `<git dir>/apexyard-ticket`. `git worktree remove` does it for a linked worktree.
- A tree needs its own `/start-ticket`. A marker in the main clone does not govern a linked worktree.
- Exempt paths (`.claude/`, `docs/`, `projects/*/docs/`, any `*.md`) don't need a ticket. The skill is only required before touching source, config, or infra.
- **Migration from the old layout**: `current-ticket` and `tickets/<project>` files under the ops fork's `.claude/session/` still work in a main clone, for their own project only. A SessionStart notice lists them. Step 4d moves one on request. A future release removes the old reader.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
