#!/bin/bash
# Shared active-ticket marker resolver.
#
# The active ticket for a working tree lives in that tree's own git dir, in a
# file named apexyard-ticket:
#
#   <repo>/.git/apexyard-ticket                    main clone
#   <repo>/.git/worktrees/<id>/apexyard-ticket     linked worktree
#
# One tree has one ticket. `git worktree remove` deletes the marker with the
# worktree. Both gates (require-active-ticket.sh and require-migration-ticket.sh)
# and every other reader call this library, so no two readers can disagree
# about which marker governs a path.
#
# DISCOVERY RUNS NO GIT PROCESS. The lookup reads the same files git reads
# (.git, <gitdir>/commondir, <gitdir>/gitdir) with shell builtins only. No
# GIT_* variable and no git config can steer it. The lookup makes 0 forks and
# 0 execs. A static test (test_active_ticket_process_budget.sh) fails when a
# lookup function gains a command substitution, a pipe, a subshell or an
# external command. The functions that fork on purpose are
# active_ticket_init and active_ticket_write.
#
# VALIDATION (docs/agdr/AgDR-0216-ticket-marker-in-worktree-git-dir.md):
#   - the git dir must belong to the ops fork or to a registered workspace
#     clone, matched fresh on every validated path
#   - a linked worktree must be listed by its common dir, and both back
#     pointers must agree
#   - no symlink may sit between the target and the tree root
#   - the git dir and the common dir must be owned by the current user
# Any failure sets REPLY to empty and returns 1. AT_REASON names the cause.
#
# This is a process gate. Anyone with write access to the git dir can forge a
# marker. It is not an authorization boundary.
#
# The library keeps its context in internal names (_AT_*) that it clears on
# the first source in a process. It never reads OPS_ROOT, WORKSPACE_DIR or
# the registry path from the environment. Hooks pass them with
# active_ticket_set_context. Every other caller uses active_ticket_init.
# shellcheck disable=SC2088

# ---------------------------------------------------------------------------
# Path helpers (builtins only)
# ---------------------------------------------------------------------------

# Physical path of a directory, or of a file or missing leaf under an existing
# directory. Sets REPLY. Saves and restores PWD and OLDPWD. When the restore
# fails because the working directory is gone, it sets AT_REASON and returns 1.
_at_rp() {
  local o="$PWD" oo="${OLDPWD:-}" had="${OLDPWD+x}" p="$1" leaf=""
  REPLY=""
  [ -n "$p" ] || return 1
  if [ ! -d "$p" ]; then
    leaf="${p##*/}"
    p="${p%/*}"
    [ -n "$p" ] || p=/
  fi
  CDPATH= builtin cd -P -- "$p" 2>/dev/null || return 1
  REPLY="$PWD"
  if ! CDPATH= builtin cd -- "$o" 2>/dev/null; then
    REPLY=""
    AT_REASON="cwd unavailable"
    return 1
  fi
  if [ -n "$had" ]; then OLDPWD="$oo"; else unset OLDPWD; fi
  [ -z "$leaf" ] || REPLY="${REPLY%/}/$leaf"
  [ -n "$REPLY" ]
}

# Lexical normalisation: no link is resolved. A relative path is anchored at
# the physical working directory. A path that starts with ~user, ~+ or ~-
# returns 1, because its expansion depends on state this library cannot see.
_at_lex() {
  local p="$1" rest seg out=""
  REPLY=""
  case "$p" in
    '') return 1 ;;
    '~') p="$HOME" ;;
    '~/'*) p="$HOME/${p#\~/}" ;;
    '~'*) return 1 ;;
  esac
  case "$p" in
    /*) ;;
    *)
      _at_rp "$PWD" || { [ -n "$AT_REASON" ] || AT_REASON="cwd unavailable"; return 1; }
      p="$REPLY/$p"
      ;;
  esac
  rest="$p"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
    case "$seg" in
      ''|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  REPLY="${out:-/}"
}

# The one place that decides ownership. Tests override it to return false.
# It is defined on every source and never guarded.
_at_owned() { [ -O "$1" ]; }

_at_fail() {
  AT_REASON="$1"
  return 1
}

# Strip a trailing CR and trailing blanks, as git does.
_at_trim() {
  local v="$1"
  v="${v%$'\r'}"
  while :; do
    case "$v" in
      *' '|*$'\t') v="${v%?}" ;;
      *) break ;;
    esac
  done
  REPLY="$v"
}

# First line of a file, trimmed, into REPLY.
_at_readfirst() {
  local l
  IFS= read -r l < "$1" || [ -n "$l" ] || return 1
  _at_trim "$l"
  [ -n "$REPLY" ]
}

# A .git file: line 1 must start with "gitdir: ", and no later line may hold
# text. Git accepts only that shape, and the gate must see the same tree.
_at_gitfile() {
  local l1="" l n=0
  while IFS= read -r l || [ -n "$l" ]; do
    n=$((n + 1))
    if [ "$n" = 1 ]; then
      l1="$l"
    else
      _at_trim "$l"
      [ -z "$REPLY" ] || return 1
    fi
  done < "$1"
  _at_trim "$l1"
  case "$REPLY" in
    'gitdir: '?*) REPLY="${REPLY#gitdir: }" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Registry scan (builtins only)
# ---------------------------------------------------------------------------

# Records the entry that has just ended. Reads the caller's locals.
_at_reg_flush() {
  [ -z "$ent_repo" ] || AT_REG_REPOS="$AT_REG_REPOS$ent_repo "
  if [ -n "$want" ] && [ "$ent_name" = "$want" ]; then
    found=0
    AT_REG_REPO="$ent_repo"
  fi
  ent_name=""
  ent_repo=""
}

# Scan the registry for the project <name>. Sets AT_REG_REPO to its repo: value
# and AT_REG_REPOS to every repo: value, each followed by a space. Keys count
# only at the indent of an entry's first key, so a nested repo: key in a
# sub-map never matches. Returns 0 when <name> is registered. An empty <name>
# only collects AT_REG_REPOS and returns 1.
_at_reg_scan() {
  local want="$1" raw line lead rest sp k v eind="" eset=0 kind="" in_proj=0 found=1
  local ent_name="" ent_repo=""
  AT_REG_REPO=""
  AT_REG_REPOS=" "
  [ -n "${_AT_REG:-}" ] && [ -r "$_AT_REG" ] || return 1
  while IFS= read -r raw || [ -n "$raw" ]; do
    raw="${raw%$'\r'}"
    line="${raw%%#*}"
    case "$line" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    case "$line" in
      projects:*) in_proj=1; continue ;;
      [![:space:]-]*)
        [ "$in_proj" = 0 ] || _at_reg_flush
        in_proj=0
        continue ;;
    esac
    [ "$in_proj" = 1 ] || continue
    lead="${line%%[![:space:]]*}"
    line="${line#"$lead"}"
    case "$line" in
      '-'*)
        rest="${line#-}"
        sp="${rest%%[![:space:]]*}"
        if [ "$eset" = 0 ]; then eind="$lead"; eset=1; fi
        [ "$lead" = "$eind" ] || continue
        _at_reg_flush
        kind="$lead $sp"
        line="${rest#"$sp"}"
        ;;
      *)
        [ "$lead" = "$kind" ] || continue
        ;;
    esac
    k="${line%%:*}"
    v="${line#*:}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v="${v#[\"\']}"
    v="${v%[\"\']}"
    case "$k" in
      name) ent_name="$v" ;;
      repo) ent_repo="$v" ;;
    esac
  done < "$_AT_REG"
  [ "$in_proj" = 0 ] || _at_reg_flush
  return "$found"
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

# Forget the per-process validation memo. Tests call it between fixtures.
_at_memo_clear() {
  _AT_MKEY=""
  _AT_MG=""
  _AT_MC=""
  _AT_MT=""
  _AT_MK=""
  _AT_MN=""
  _AT_MOK=1
  _AT_MWHY=""
}

# One-time state reset. It runs only on the first source in a process.
_at_reset_state() {
  _AT_OPS=""
  _AT_WS=""
  _AT_REG=""
  export -n _AT_OPS _AT_WS _AT_REG
  AT_VALIDATIONS=0
  AT_REASON=""
  AT_GITDIR=""
  AT_TREE=""
  AT_LEGACY_FILE=""
  AT_LEGACY_WHY=""
  AT_REG_REPO=""
  AT_REG_REPOS=" "
  _at_memo_clear
}

_AT_LIBDIR=""
case "${BASH_SOURCE[0]:-}" in
  */*) _at_rp "${BASH_SOURCE[0]%/*}" && _AT_LIBDIR="$REPLY" ;;
esac

# The guard value is the process id held in element 1 of an indexed array.
# Bash cannot import an array from the environment, so a parent process cannot
# plant it. A child bash has a new $$, so it always resets. Function
# definitions above are never skipped.
case "${_AT_GUARD[1]:-}" in
  "$$") ;;
  *)
    unset _AT_GUARD
    _at_reset_state
    _AT_GUARD=(x "$$")
    ;;
esac

# Context for a caller that already resolved the ops root and workspace dir.
active_ticket_set_context() {
  _AT_OPS="${1:-}"
  _AT_WS="${2:-}"
  return 0
}

# ---------------------------------------------------------------------------
# Validation of one tree (steps 2 to 5)
# ---------------------------------------------------------------------------

# Validates the tree rooted at W. Sets the _AT_M* memo on success.
_at_validate_w_body() {
  local W="$1" G C T p ws="" name="" ops=0 wsm=0 wslink=0
  [ -n "$_AT_OPS" ] && [ -n "$_AT_WS" ] || { _at_fail "resolver context missing"; return 1; }
  if [ -L "$W/.git" ]; then _at_fail "symlink in marker path: $W/.git"; return 1; fi
  _at_rp "$W" || return 1
  T="$REPLY"
  if [ -d "$W/.git" ]; then
    if [ -e "$W/.git/commondir" ]; then _at_fail "not a git tree (commondir in a main git dir)"; return 1; fi
    _at_rp "$W/.git" || return 1
    G="$REPLY"
    C="$G"
  elif [ -f "$W/.git" ]; then
    _at_gitfile "$W/.git" || { _at_fail "not a git tree (malformed .git file)"; return 1; }
    p="$REPLY"
    case "$p" in
      /*) ;;
      *) p="$W/$p" ;;
    esac
    _at_rp "$p" || return 1
    G="$REPLY"
    if [ -f "$G/commondir" ]; then
      _at_readfirst "$G/commondir" || { _at_fail "not a git tree (empty commondir)"; return 1; }
      p="$REPLY"
      case "$p" in
        /*) ;;
        *) p="$G/$p" ;;
      esac
      _at_rp "$p" || return 1
      C="$REPLY"
    else
      C="$G"
    fi
  else
    _at_fail "not a git tree"
    return 1
  fi
  if [ ! -f "$G/HEAD" ] || [ ! -d "$C/objects" ] || [ ! -d "$C/refs" ]; then
    _at_fail "not a git tree (missing HEAD, objects or refs)"
    return 1
  fi
  if ! _at_owned "$G" || ! _at_owned "$C"; then
    _at_fail "not owned by current user ($G). git's safe.directory setting does not apply to this gate. Run the session as the owner of the repo, or change its owner."
    return 1
  fi

  # An ops .git that is a link could alias a project, so it is refused for
  # every tree.
  if [ -L "$_AT_OPS/.git" ]; then
    _at_fail "symlink in marker path: $_AT_OPS/.git"
    return 1
  fi
  if [ -d "$_AT_OPS/.git" ] && _at_rp "$_AT_OPS/.git" && [ "$C" = "$REPLY" ]; then
    ops=1
  fi
  [ ! -L "$_AT_WS" ] || wslink=1
  if _at_rp "$_AT_WS"; then
    ws="$REPLY"
    case "$C" in
      "$ws"/*/.git)
        name="${C#"$ws"/}"
        name="${name%/.git}"
        case "$name" in
          */*|.|..|'') _at_fail "unregistered common dir"; return 1 ;;
        esac
        if [ "$wslink" = 1 ]; then _at_fail "symlink in marker path: $_AT_WS"; return 1; fi
        [[ $name =~ $_AT_NAME_RE ]] || { _at_fail "unregistered common dir"; return 1; }
        [ -n "$_AT_REG" ] || _AT_REG="${_PP_REG:-}"
        _at_reg_scan "$name" || { _at_fail "unregistered common dir"; return 1; }
        if [ -L "$_AT_WS/$name" ] || [ -L "$_AT_WS/$name/.git" ]; then
          _at_fail "symlink in marker path: $_AT_WS/$name"
          return 1
        fi
        _at_rp "$_AT_WS/$name/.git" || return 1
        [ "$REPLY" = "$C" ] || { _at_fail "unregistered common dir"; return 1; }
        _at_rp "$_AT_WS/$name" || return 1
        [ "${REPLY%/*}" = "$ws" ] || { _at_fail "unregistered common dir"; return 1; }
        wsm=1
        ;;
    esac
  fi
  if [ $((ops + wsm)) = 2 ]; then _at_fail "ambiguous common dir"; return 1; fi
  if [ $((ops + wsm)) = 0 ]; then
    # A tree that sits under a linked workspace entry resolves outside the
    # workspace, so name the link instead of the registry.
    case "$W" in
      "$_AT_WS"/*)
        name="${W#"$_AT_WS"/}"
        name="${name%%/*}"
        if [ -L "$_AT_WS/$name" ]; then _at_fail "symlink in marker path: $_AT_WS/$name"; return 1; fi
        ;;
    esac
    _at_fail "unregistered common dir"
    return 1
  fi
  [ "$ops" = 0 ] || name=""

  if [ "$G" = "$C" ]; then
    [ "$T" = "${C%/*}" ] || { _at_fail "worktree not listed"; return 1; }
    _AT_MK=main
  else
    [ "${G%/*}" = "$C/worktrees" ] || { _at_fail "worktree not listed"; return 1; }
    _at_readfirst "$G/gitdir" || { _at_fail "worktree not listed"; return 1; }
    p="$REPLY"
    case "$p" in
      /*) ;;
      *) p="$G/$p" ;;
    esac
    _at_rp "$p" || { _at_fail "worktree not listed"; return 1; }
    [ "$REPLY" = "$T/.git" ] || { _at_fail "worktree not listed"; return 1; }
    _AT_MK=linked
  fi
  _AT_MG="$G"
  _AT_MC="$C"
  _AT_MT="$T"
  _AT_MN="$name"
  return 0
}

_AT_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# Memoised wrapper. The memo key covers the tree and the context.
_at_validate_w() {
  local W="$1"
  AT_VALIDATIONS=$((AT_VALIDATIONS + 1))
  AT_REASON=""
  _at_memo_clear
  _AT_MKEY="$W|$_AT_OPS|$_AT_WS"
  if _at_validate_w_body "$W"; then
    _AT_MOK=0
    return 0
  fi
  _AT_MG=""
  _AT_MOK=1
  _AT_MWHY="${AT_REASON:-git dir failed validation}"
  # A missing working directory belongs to the caller, not to the tree.
  [ "$AT_REASON" != "cwd unavailable" ] || _AT_MKEY=""
  return 1
}

# Steps 1 to 6: from a path to the validated git dir. Sets AT_GITDIR, AT_TREE
# and D (the nearest existing directory) for the caller through _AT_LD.
_at_resolve_g() {
  local D W p key
  REPLY=""
  AT_REASON=""
  AT_GITDIR=""
  AT_TREE=""
  AT_LEGACY_FILE=""
  AT_LEGACY_WHY=""
  _at_lex "$1" || { [ -n "$AT_REASON" ] || AT_REASON="unresolvable path"; return 1; }
  D="$REPLY"
  if [ ! -d "$D" ]; then
    D="${D%/*}"
    while [ -n "$D" ] && [ ! -d "$D" ]; do D="${D%/*}"; done
  fi
  [ -n "$D" ] || { _at_fail "not a git tree"; return 1; }
  W="$D"
  while [ -n "$W" ] && [ ! -e "$W/.git" ] && [ ! -L "$W/.git" ]; do W="${W%/*}"; done
  [ -n "$W" ] || { _at_fail "not a git tree"; return 1; }
  key="$W|$_AT_OPS|$_AT_WS"
  if [ "$key" != "$_AT_MKEY" ]; then
    _at_validate_w "$W" || true
  fi
  if [ "$_AT_MOK" != 0 ]; then
    AT_REASON="$_AT_MWHY"
    return 1
  fi
  # Link walk on the lexical path, from the directory up to the tree root.
  p="$D"
  while :; do
    if [ -L "$p" ]; then _at_fail "symlink in marker path: $p"; return 1; fi
    [ "$p" != "$W" ] || break
    p="${p%/*}"
    [ -n "$p" ] || { _at_fail "not a git tree"; return 1; }
  done
  if [ -L "$_AT_MG/apexyard-ticket" ]; then
    _at_fail "symlink in marker path: $_AT_MG/apexyard-ticket"
    return 1
  fi
  for p in "$_AT_MG"/apexyard-ticket.tmp.*; do
    if [ -L "$p" ]; then _at_fail "symlink in marker path: $p"; return 1; fi
  done
  AT_GITDIR="$_AT_MG"
  AT_TREE="$_AT_MT"
  return 0
}

# ---------------------------------------------------------------------------
# Old-layout markers (honoured in a main clone only, until they are removed)
# ---------------------------------------------------------------------------

# Sets REPLY to a legacy marker file that may govern the validated tree.
# Records AT_LEGACY_FILE and AT_LEGACY_WHY when a file exists and is not used.
_at_legacy() {
  local s="$_AT_OPS/.claude/session" cand="" l repo="" num=""
  REPLY=""
  if [ -n "$_AT_MN" ]; then
    cand="$s/tickets/$_AT_MN"
    if [ ! -e "$cand" ] && [ ! -L "$cand" ]; then
      if [ -e "$s/current-ticket" ] || [ -L "$s/current-ticket" ]; then
        AT_LEGACY_FILE="$s/current-ticket"
        AT_LEGACY_WHY="current-ticket is not used for a managed project"
      fi
      return 1
    fi
  else
    cand="$s/current-ticket"
    if [ ! -e "$cand" ] && [ ! -L "$cand" ]; then return 1; fi
  fi
  AT_LEGACY_FILE="$cand"
  if [ "$_AT_MK" != main ]; then AT_LEGACY_WHY="linked worktree"; return 1; fi
  if [ -L "$s" ] || [ -L "$s/tickets" ] || [ -L "$cand" ] || [ ! -f "$cand" ]; then
    AT_LEGACY_WHY="not a regular file"
    return 1
  fi
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"
    case "$l" in
      repo=*) [ -n "$repo" ] || repo="${l#repo=}" ;;
      number=*) [ -n "$num" ] || num="${l#number=}" ;;
    esac
  done < "$cand"
  if [ -z "$repo" ] || [ -z "$num" ]; then AT_LEGACY_WHY="missing repo= or number="; return 1; fi
  case "$num" in
    *[!0-9]*) AT_LEGACY_WHY="number= is not all digits"; return 1 ;;
  esac
  [ -n "$_AT_REG" ] || _AT_REG="${_PP_REG:-}"
  if [ -n "$_AT_MN" ]; then
    _at_reg_scan "$_AT_MN" || { AT_LEGACY_WHY="project not in the registry"; return 1; }
    if [ "$repo" != "$AT_REG_REPO" ]; then AT_LEGACY_WHY="repo mismatch"; return 1; fi
  else
    # No registry file means no managed project can own the repo. A registry
    # that exists but cannot be read, or an unknown path, fails closed.
    if [ -z "$_AT_REG" ] || { [ -e "$_AT_REG" ] && [ ! -r "$_AT_REG" ]; }; then
      AT_LEGACY_WHY="registry unreadable"
      return 1
    fi
    _at_reg_scan ""
    case "$AT_REG_REPOS" in
      *" $repo "*) AT_LEGACY_WHY="current-ticket names a managed project"; return 1 ;;
    esac
  fi
  REPLY="$cand"
}

# ---------------------------------------------------------------------------
# Public lookup API. These functions set REPLY, write nothing to stderr and
# make no fork.
# ---------------------------------------------------------------------------

_at_lookup_inner() {
  _at_resolve_g "$1" || return 1
  if [ -f "$AT_GITDIR/apexyard-ticket" ]; then
    REPLY="$AT_GITDIR/apexyard-ticket"
    return 0
  fi
  _at_legacy
}

# REPLY is the marker path, or empty. Return 0 only when a marker governs the
# path. AT_REASON is empty when the tree is valid and holds no marker.
active_ticket_lookup() {
  _at_lookup_inner "$1" && return 0
  REPLY=""
  return 1
}

# The lookup for the physical working directory.
active_ticket_lookup_cwd() {
  _at_rp "$PWD" || { REPLY=""; AT_REASON="cwd unavailable"; return 1; }
  active_ticket_lookup "$REPLY"
}

# REPLY is the validated git dir of the tree that holds <dir>, or empty.
active_ticket_gitdir() {
  _at_resolve_g "$1" && { REPLY="$AT_GITDIR"; return 0; }
  REPLY=""
  return 1
}


# True when <path> names the marker file or its temporary file in the git dir
# of a registered tree. The only write the gates allow into a .git directory.
active_ticket_is_marker_target() {
  local L P base T p G
  _at_lex "$1" || return 1
  L="$REPLY"
  base="${L##*/}"
  case "$base" in
    apexyard-ticket) ;;
    apexyard-ticket.tmp.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;;
    *) return 1 ;;
  esac
  P="${L%/*}"
  [ -n "$P" ] || return 1
  if [ -L "$P" ] || [ -L "$L" ]; then return 1; fi
  [ -d "$P" ] || return 1
  if [ -f "$P/commondir" ]; then
    _at_readfirst "$P/gitdir" || return 1
    p="$REPLY"
    case "$p" in
      /*) ;;
      *) p="$P/$p" ;;
    esac
    T="${p%/*}"
  else
    T="${P%/*}"
  fi
  [ -n "$T" ] || return 1
  _at_resolve_g "$T" || return 1
  G="$AT_GITDIR"
  _at_rp "$P" || return 1
  [ "$REPLY" = "$G" ]
}

# REPLY is the value of the first <key>= line in a marker file.
active_ticket_read_field() {
  local l k="$2"
  REPLY=""
  [ -f "$1" ] || return 1
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"
    case "$l" in
      "$k="*) REPLY="${l#"$k="}"; return 0 ;;
    esac
  done < "$1"
  return 1
}

# ---------------------------------------------------------------------------
# Functions that may fork (outside the lookup budget)
# ---------------------------------------------------------------------------

# Fill every empty context value once per process. A caller that has no
# resolved context uses this. The start directory defaults to the working
# directory.
active_ticket_init() {
  local start="${1:-$PWD}" dir
  if [ -n "$_AT_OPS" ] && [ -n "$_AT_WS" ] && [ -n "$_AT_REG" ]; then return 0; fi
  dir="$_AT_LIBDIR"
  [ -n "$dir" ] || dir="${_AT_OPS:+$_AT_OPS/.claude/hooks}"
  if [ -n "$dir" ]; then
    # Source unconditionally, so an inherited function of the same name is
    # replaced by the real definition.
    [ ! -f "$dir/_lib-ops-root.sh" ] || . "$dir/_lib-ops-root.sh"
    [ ! -f "$dir/_lib-read-config.sh" ] || . "$dir/_lib-read-config.sh"
    [ ! -f "$dir/_lib-portfolio-paths.sh" ] || . "$dir/_lib-portfolio-paths.sh"
  fi
  if [ -z "$_AT_OPS" ] && command -v resolve_ops_root >/dev/null 2>&1; then
    _AT_OPS=$(resolve_ops_root "$start")
    [ -n "$_AT_OPS" ] || _AT_OPS=$(resolve_ops_root "$PWD")
  fi
  if command -v portfolio_resolve_into_vars >/dev/null 2>&1; then
    portfolio_resolve_into_vars
  fi
  [ -n "$_AT_WS" ] || _AT_WS="${_PP_WS:-}"
  [ -n "$_AT_WS" ] || [ -z "$_AT_OPS" ] || _AT_WS="$_AT_OPS/workspace"
  [ -n "$_AT_REG" ] || _AT_REG="${_PP_REG:-}"
  [ -n "$_AT_OPS" ] && [ -n "$_AT_WS" ]
}

# The only marker writer. Validates the tree of <dir>, then writes the marker
# atomically: mktemp, chmod and mv. It needs at most three external commands
# after init, plus date on a bash older than 4.2.
active_ticket_write() {
  local dir="$1" repo="$2" num="$3" title="$4" url="$5" branch="$6" G tmp ts="" hint=""
  if ! active_ticket_init "$dir"; then
    echo "apexyard: cannot write ticket marker in $dir: resolver context missing" >&2
    return 1
  fi
  _at_memo_clear
  if ! active_ticket_gitdir "$dir"; then
    echo "apexyard: cannot write ticket marker in $dir: ${AT_REASON:-git dir failed validation}" >&2
    return 1
  fi
  G="$REPLY"
  if [[ ! $repo =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "apexyard: cannot write ticket marker in $G: repo must be an owner/repo slug" >&2
    return 1
  fi
  if [[ ! $num =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "apexyard: cannot write ticket marker in $G: number must be a ticket id" >&2
    return 1
  fi
  title="${title//$'\r'/ }"; title="${title//$'\n'/ }"
  url="${url//$'\r'/ }"; url="${url//$'\n'/ }"
  branch="${branch//$'\r'/ }"; branch="${branch//$'\n'/ }"
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    TZ=UTC printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  else
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  hint=" The sandbox may deny writes to the git dir. See AgDR-0216 for the allowlist."
  tmp=$(mktemp "$G/apexyard-ticket.tmp.XXXXXX" 2>/dev/null) || {
    echo "apexyard: cannot write ticket marker in $G: mktemp failed.$hint" >&2
    return 1
  }
  if [ -L "$tmp" ]; then
    rm -f "$tmp"
    echo "apexyard: cannot write ticket marker in $G: temporary file is a symlink" >&2
    return 1
  fi
  {
    printf 'repo=%s\n' "$repo"
    printf 'number=%s\n' "$num"
    printf 'title=%s\n' "$title"
    printf 'url=%s\n' "$url"
    printf 'suggested_branch=%s\n' "$branch"
    printf 'started_at=%s\n' "$ts"
  } > "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    echo "apexyard: cannot write ticket marker in $G: write failed.$hint" >&2
    return 1
  }
  if ! chmod 0644 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$G/apexyard-ticket" 2>/dev/null; then
    rm -f "$tmp"
    echo "apexyard: cannot write ticket marker in $G: chmod or mv failed.$hint" >&2
    return 1
  fi
  REPLY="$G/apexyard-ticket"
  return 0
}

# ---------------------------------------------------------------------------
# Path helpers for display only (project name for a path). These fork. They
# do not decide which marker governs a path.
# ---------------------------------------------------------------------------

_atl_resolve_path() {
  local target="$1" base lexical resolved
  [ -n "$target" ] || return 0

  case "$target" in
    '~')    target="$HOME" ;;
    '~/'*)  target="$HOME/${target#\~/}" ;;
    '~'*)   return 0 ;;
  esac

  case "$target" in
    /*) ;;
    *)
      base=$(pwd -P 2>/dev/null) || return 0
      target="$base/$target"
      ;;
  esac

  lexical=$(printf '%s' "$target" | awk -F/ '{
    n = 0
    for (i = 1; i <= NF; i++) {
      if ($i == "" || $i == ".") continue
      if ($i == "..") { if (n > 0) n--; continue }
      out[++n] = $i
    }
    s = ""
    for (i = 1; i <= n; i++) s = s "/" out[i]
    print (s == "" ? "/" : s)
  }')

  if command -v _resolve_real_path >/dev/null 2>&1; then
    resolved=$(_resolve_real_path "$lexical")
  else
    resolved="$lexical"
  fi
  [ -n "$resolved" ] || resolved="$lexical"
  case "$resolved" in
    //*) resolved="/${resolved#//}" ;;
  esac
  printf '%s' "$resolved"
}

_atl_anchor() {
  local raw="$1" resolved=""
  [ -n "$raw" ] || return 0
  if command -v _resolve_real_path >/dev/null 2>&1; then
    resolved=$(_resolve_real_path "$raw")
  fi
  [ -n "$resolved" ] || resolved="$raw"
  printf '%s' "$resolved"
}

_atl_project_for_resolved_path() {
  local path="$1" project="" tail ws ops
  ws=$(_atl_anchor "${WORKSPACE_DIR:-}")
  ops=$(_atl_anchor "${OPS_ROOT:-}")
  if [ -n "$ws" ]; then
    case "$path" in
      "$ws"/*) tail="${path#"$ws"/}"; project="${tail%%/*}" ;;
    esac
  fi
  if [ -z "$project" ] && [ -n "$ops" ]; then
    case "$path" in
      "$ops"/workspace/*) tail="${path#"$ops"/workspace/}"; project="${tail%%/*}" ;;
    esac
  fi
  printf '%s' "$project"
}

active_ticket_resolve_path() {
  _atl_resolve_path "$1"
}

active_ticket_project_for_path() {
  local resolved
  resolved=$(_atl_resolve_path "$1")
  [ -n "$resolved" ] || return 0
  _atl_project_for_resolved_path "$resolved"
}

_atl_existing_dir() {
  local dir="$1"
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
    dir=$(dirname "$dir")
  done
  [ -d "$dir" ] && printf '%s' "$dir"
}

# The tiered marker lookup that the gates use today. The gates switch to
# active_ticket_lookup in a later commit, and this function then becomes a
# thin wrapper around it.
active_ticket_marker_for_path() {
  local raw="$1" resolved project="" marker="" wt safe dir gd gcd
  resolved=$(_atl_resolve_path "$raw")
  local home="${MARKER_HOME:-${OPS_ROOT:-${REPO_ROOT:-.}}}"
  # An empty $resolved has two causes. An empty $raw is an unextractable Bash
  # write target, and the ops-level current-ticket fallback still gates it.
  # A non-empty $raw that failed to resolve (~user, ~+, ~-) must return an
  # empty marker, so the migration gate refuses it instead of using the
  # ticket of a different project.
  if [ -n "$resolved" ]; then
    project=$(_atl_project_for_resolved_path "$resolved")
  fi

  if [ -n "$project" ]; then
    wt="${CLAUDE_WORKTREE_BRANCH:-}"
    if [ -z "$wt" ]; then
      dir=$(_atl_existing_dir "$(dirname "$resolved")")
      gd=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)
      gcd=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
      if [ -n "$gd" ] && [ "$gd" != "$gcd" ]; then
        wt=$(git -C "$dir" branch --show-current 2>/dev/null)
      fi
    fi
    if [ -n "$wt" ]; then
      safe="${wt//\//__}"
      marker="$home/.claude/session/tickets/$project/$safe"
      [ -f "$marker" ] || marker=""
    fi
  fi

  if [ -z "$marker" ] && [ -n "$project" ] && [ -f "$home/.claude/session/tickets/$project" ]; then
    marker="$home/.claude/session/tickets/$project"
  elif [ -z "$marker" ] && { [ -n "$resolved" ] || [ -z "$raw" ]; } \
    && [ -f "$home/.claude/session/current-ticket" ]; then
    marker="$home/.claude/session/current-ticket"
  fi
  printf '%s' "$marker"
}
