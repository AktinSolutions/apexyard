---
id: AgDR-0216
timestamp: 2026-10-07T00:00:00Z
agent: platform-engineer
model: claude-sonnet-5-5
session: session_01KGvb2ba4gyT3TN8L2uMLTn
trigger: user-prompt
status: executed
category: security
---

# Store the ticket marker in each working tree's git dir

> In the context of parallel sessions on one project, facing last-writer-wins ticket files and a lookup that git environment variables can redirect, I decided to keep one marker file per working tree in that tree's git dir. I find the git dir by reading git's own files, with no git process. I accept that submodules, nested repos and repos with another owner are now blocked.

## Context

Today the active ticket lives in shared files under the ops fork:
`.claude/session/tickets/<project>/<branch>`, `.claude/session/tickets/<project>`
and `.claude/session/current-ticket`.

Three problems follow from that layout.

- Parallel sessions on one project overwrite each other's ticket (me2resh/apexyard#513).
- The lookup runs `git -C` with no `GIT_*` scrub. `GIT_DIR` or a git config override can redirect it.
- A spike ticket in one project can exempt a write in another project.

The spike me2resh/apexyard#1535 showed that hooks and sandboxed Bash can write `<gitdir>/apexyard-ticket`. Each tree then sees only its own marker. `git worktree remove` deletes the marker.

The marker is a process gate. Anyone with write access to the git dir can forge it. It is not an authorization boundary.

## Options Considered

Git-dir discovery:

| Option | Pros | Cons |
|--------|------|------|
| Read git's own files with shell builtins (chosen) | No environment or config influence. 0 forks and 0 execs per lookup once the context is filled. | The code re-implements two git checks. |
| One scrubbed `git rev-parse` per lookup | Git does the discovery. | The scrub list needs upkeep. Earlier review rounds found three gaps in it. Each lookup adds one exec. |
| `git rev-parse` plus an allowed-set cache | Fewer git calls on a hit. | Measured +22 to +49 % per Edit. Review found three cache-signature defects. |

Old-layout markers:

| Option | Pros | Cons |
|--------|------|------|
| Ignore them everywhere | Simplest. | Every project blocks once after `/update`. |
| Honour them in a main clone only (chosen) | Main clones keep working. A linked worktree never reads one. | A temporary reader stays in the trust chain. |
| Honour them in a linked worktree too | Fewest blocks. | It is the last-writer-wins case of #513. |

## Decision

Chosen: **a marker file `apexyard-ticket` in the git dir of each working tree, found by reading files**.

### Discovery and validation

The lookup walks up from the target to the first directory that holds `.git`. It reads that `.git` entry and, for a linked worktree, `commondir` and `gitdir`. It runs no git process.

The lookup accepts a git dir only when all of these hold:

- The common dir is the ops fork's `.git`, or the `.git` of a registered clone that is a direct child of the workspace dir.
- A linked worktree git dir sits under `<common>/worktrees`, and both back-pointers agree.
- The git dir has `HEAD`, and the common dir has `objects` and `refs`.
- The current user owns the git dir and the common dir (`[ -O ]`).
- No symlink sits between the target and the tree root. A `..` that follows a symlinked component is refused, because it would hide the link.
- A `.git` file holds one `gitdir:` line. A main `.git` directory has no `commondir` file.

The workspace root, each workspace entry and its `.git` must be real directories. `$OPS_ROOT` itself may be an alias, but `$OPS_ROOT/.git` must not be a link. A common dir that matches both roots is refused as ambiguous.

### Security properties

| Property | Mechanism |
|----------|-----------|
| `GIT_*` variables and git config cannot redirect the lookup | No git process runs. |
| `core.worktree` cannot move the tree | The tree is the directory that holds `.git`. |
| Only the ops fork or a registered clone counts | The common dir is matched on every call. |
| A planted `.git`, `gitdir` or `commondir` is refused | The common dir must be registered, and the back-pointers must agree. |
| The `.git` write exemption covers only the marker | `active_ticket_is_marker_target` accepts the exact marker and its temporary file. |
| The library's own functions and state cannot be planted by a parent process | Functions are redefined on every source. The one-time state reset is guarded by the process id in an array element. The context names are internal and unexported. |
| Failure closes the gate | Every failure sets `REPLY` to empty. |

### Gap against git

The lookup checks that `HEAD` exists. It does not check that `HEAD` is a valid ref or object id, as git's `is_git_directory` does. The common dir must also be registered and owned by the user, and no git config is read or run. A repo that git accepts and this lookup refuses fails closed.

### Decisions inside this AgDR

- The ownership check replaces git's `safe.directory`. It is stricter, because the library never reads the git config override. A devcontainer or bind mount with another owner is blocked.
- The legacy reader is removed in the release after the one that ships this change.
- The legacy rule gives no cross-project or cross-tree wrong-ticket pass. Inside one project's main clone, an old `tickets/<name>` file still behaves as before until the reader is removed. It can pass a different ticket of the same project.
- The sandbox allowlist may name only the exact marker and temporary file paths, never `.git/**`.
- Blocking a `cd <tree> && write` command is out of scope. A follow-up task tracks it.
- Submodules and nested repos are not trees. Writes inside them are blocked.
- An attacker who controls the hook process environment is out of scope. On bash 5.3 such an attacker can shadow `[`, `declare`, `builtin` or `git` with an inherited `BASH_FUNC_<name>%%` function. This applies to every hook. A possible hardening is to launch hooks as `bash -p <script>`.

This AgDR partly supersedes AgDR-0066 and AgDR-0141, and amends AgDR-0168 and AgDR-0017. It replaces the mechanism that the ticket names (`rev-parse`, `worktree list`, the `GIT_*` unset) with one that reaches the same outcome.

## Consequences

- Each working tree has one ticket. Removing a worktree removes its ticket.
- A linked worktree and any project that relied only on `current-ticket` blocks once until you run `/start-ticket` there.
- Unregistered repos, submodules, nested repos, symlinked roots and repos owned by another user are blocked, each with a reason.
- Once the context is filled, the lookup makes 0 forks. The first lookup in a workspace clone may resolve the registry path once per process, and that step can fork. A test fails when a lookup function gains a command substitution, a pipe, a subshell or an external command.
- A hook-level test fails when a gated write makes more processes than before.

## Build notes

- The legacy reader accepts `number=` in the shape `[A-Za-z0-9_-]+` after one leading `#` is removed, not digits only. Jira and Linear ids need that, and the writer and the migration gate use the same shape.
- The legacy `repo=` match compares case-insensitively and against every slug of a registry entry: `repo:`, each `repos:` item and `primary:`.
- The registry path and the workspace dir come from the portfolio library, and only when that library is loaded in the same process. An inherited `_PP_REG` or `_PP_WS` is never used. Without a trusted resolver the registry path stays unknown, and a workspace lookup fails closed.
- The registry is resolved on demand. A workspace clone or an old `current-ticket` file needs it. A Claude session reads the path from the session cache without a fork.
- The hook-level process count test needs `strace`. It fails on a Linux CI runner without it and prints an `INFO:` line elsewhere, because the suite runner treats a line that starts with `SKIP` as a failure. The limits are the merge-base counts measured on a developer machine. Confirm them on the CI ubuntu leg.
- `/fan-out` creates writer worktrees under `<ops>/.claude/worktrees/`. The ticket gate exempts every path under `.claude/`, so edits in those worktrees pass without a marker. This gap exists today. A follow-up task should narrow that exemption or move the worktrees. The marker is still written, so the gate works once the path is not exempt.
- The ambient tracker guard reads the marker of the tree that runs the command. From the ops fork it also reads the markers of registered workspace clones and their linked worktrees, because `/start-ticket` run at the ops root writes into the project clone.

## Artifacts

- `.claude/hooks/_lib-active-ticket.sh`
- `.claude/hooks/_lib-portfolio-paths.sh` (`portfolio_resolve_into_vars`)
- `.claude/hooks/tests/test_active_ticket_resolver.sh`
- `.claude/hooks/tests/test_active_ticket_process_budget.sh`
- `.claude/hooks/tests/test_agdr_marker_supersession.sh`
- me2resh/apexyard#1576
