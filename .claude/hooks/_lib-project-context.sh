#!/bin/bash
# _lib-project-context.sh — resolve and render a managed project's own
# context (CLAUDE.md, rules, skills, agents) for inject-project-context.sh
# (me2resh/apexyard#1423).
#
# Source order (same libs _lib-multi-repo-trace.sh already needs):
#   source ".../_lib-read-config.sh"
#   source ".../_lib-ops-root.sh"
#   source ".../_lib-portfolio-paths.sh"
#   source ".../_lib-multi-repo-trace.sh"   # _mrt_parse_registry
#   source ".../_lib-project-context.sh"
#
#   read -r name ws <<<"$(projctx_resolve /abs/path)"
#   [ -n "$name" ] && projctx_emit "$name" "$ws"
#
# projctx_resolve <abs_path>
#   Prints "<name>\t<workspace>" for the registered project whose
#   workspace: contains abs_path. Falls back to git's common-dir (a
#   worktree of that project checked out elsewhere) when abs_path isn't
#   under any registered workspace. Empty output + nonzero exit on no
#   match.
#
# projctx_emit <name> <workspace>
#   Prints the injected context block (header, CLAUDE.md, rules, skill/
#   agent index), capped at $PROJCTX_BUDGET characters.

PROJCTX_BUDGET="${PROJCTX_BUDGET:-9500}"
# Per-user state under $HOME, never shared /tmp: another local user could
# pre-create a predictable /tmp dir and poison the registry cache (context
# injection) or plant symlinks the writes below would follow. Same base
# dir as the ops-root session pins in _lib-ops-root.sh.
_PROJCTX_CACHE_DIR="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/projctx"

# Create the state dir owner-only; refuse it if it is a symlink or not ours.
projctx_state_dir() {
  local d="$_PROJCTX_CACHE_DIR"
  [ -d "$d" ] || mkdir -p -m 700 "$d" 2>/dev/null || return 1
  [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || return 1
  chmod 700 "$d" 2>/dev/null
  printf '%s' "$d"
}

# ------------------------------------------------------------------------------
# Internal: name<TAB>absolute-workspace, one per registered project that
# declares a workspace:. Parsed from the registry once per (path, mtime,
# size) via _mrt_parse_registry, then cached as a flat TSV file so a burst
# of hook invocations in one session re-reads a small local file instead
# of re-parsing the registry every time.
# ------------------------------------------------------------------------------
_projctx_registry_tsv() {
  # portfolio_registry costs ~45 ms (config reads); the hook runs on every
  # file tool call, so memoise the resolved path per session.
  local registry reg_cache="" sd
  if [ -n "${PROJCTX_SESSION_ID:-}" ] && sd=$(projctx_state_dir); then
    reg_cache="$sd/registry-path-$(printf '%s' "$PROJCTX_SESSION_ID" | cksum | awk '{print $1}')"
    [ -f "$reg_cache" ] && [ ! -L "$reg_cache" ] && IFS= read -r registry < "$reg_cache"
  fi
  if [ -z "$registry" ] || [ ! -f "$registry" ]; then
    registry=$(portfolio_registry 2>/dev/null) || return 1
    [ -n "$reg_cache" ] && [ ! -L "$reg_cache" ] && printf '%s\n' "$registry" > "$reg_cache" 2>/dev/null
  fi
  [ -f "$registry" ] || return 1

  local stamp
  stamp=$(stat -c '%Y:%s' "$registry" 2>/dev/null || stat -f '%m:%z' "$registry" 2>/dev/null)
  [ -z "$stamp" ] && stamp="unknown"

  local key cache_file state_dir
  key=$(printf '%s|%s' "$registry" "$stamp" | cksum 2>/dev/null | awk '{print $1}')
  [ -z "$key" ] && key="nokey"
  state_dir=$(projctx_state_dir) || state_dir=""
  cache_file=""
  [ -n "$state_dir" ] && cache_file="$state_dir/registry-$key.tsv"

  if [ -n "$cache_file" ] && [ -f "$cache_file" ] && [ ! -L "$cache_file" ]; then
    cat "$cache_file" 2>/dev/null
    return 0
  fi

  command -v _mrt_parse_registry >/dev/null 2>&1 || return 1

  local root name repo workspace hostnames topics all_repos ws_abs content
  root=$(_portfolio_root 2>/dev/null) || root=""
  content=""
  while IFS='|' read -r name repo workspace hostnames topics all_repos; do
    [ -z "$name" ] && continue
    [ -z "$workspace" ] && continue
    case "$workspace" in
      /*) ws_abs="$workspace" ;;
      *) ws_abs=""; [ -n "$root" ] && ws_abs="$root/$workspace" ;;
    esac
    [ -z "$ws_abs" ] && continue
    # Canonicalize once here so the hook's string prefix match agrees with
    # the canonical tool path (symlinked $HOME, macOS /tmp → /private/tmp).
    ws_abs=$(_portfolio_canonicalize "$ws_abs" 2>/dev/null) || continue
    content="${content}${name}	${ws_abs}
"
  done < <(_mrt_parse_registry 2>/dev/null)

  # Uncacheable (state dir unusable) → still return the parsed result.
  if [ -n "$cache_file" ] && [ ! -L "$cache_file" ]; then
    printf '%s' "$content" > "$cache_file" 2>/dev/null
  fi
  printf '%s' "$content"
}

# ------------------------------------------------------------------------------
# Public: projctx_resolve <abs_path>
# ------------------------------------------------------------------------------
projctx_resolve() {
  local abs_path="$1"
  [ -z "$abs_path" ] && return 1

  local tsv
  tsv=$(_projctx_registry_tsv) || return 1
  [ -z "$tsv" ] && return 1

  # Fast path: plain string prefix (abs_path is already canonical). The
  # slower portfolio_path_under only runs for a prefix hit, to confirm it.
  local name ws
  while IFS="$(printf '\t')" read -r name ws; do
    [ -z "$name" ] && continue
    case "$abs_path" in "$ws"|"$ws"/*) ;; *) continue ;; esac
    if portfolio_path_under "$abs_path" "$ws" 2>/dev/null; then
      printf '%s\t%s\n' "$name" "$ws"
      return 0
    fi
  done <<EOF
$tsv
EOF

  # Fallback: abs_path is on a worktree of a registered project checked
  # out OUTSIDE its registered workspace (require-active-ticket.sh's tier
  # 0 resolves the same shape). Resolve the worktree's main checkout via
  # git's common-dir and re-match that against the registry.
  local dir="$abs_path"
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
    dir=$(dirname "$dir" 2>/dev/null)
  done
  [ -n "$dir" ] && [ -d "$dir" ] || return 1

  # Stock macOS has no `timeout`; the hook's own 3 s cap bounds git there.
  local gcd main_root
  if command -v timeout >/dev/null 2>&1; then
    gcd=$(timeout 1 git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  else
    gcd=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  fi
  [ -z "$gcd" ] && return 1
  main_root=$(dirname "$gcd")
  [ -z "$main_root" ] && return 1

  while IFS="$(printf '\t')" read -r name ws; do
    [ -z "$name" ] && continue
    if portfolio_path_eq "$main_root" "$ws" 2>/dev/null; then
      printf '%s\t%s\n' "$name" "$ws"
      return 0
    fi
  done <<EOF
$tsv
EOF

  return 1
}

# Extract one simple "key: value" scalar from a file's leading YAML
# frontmatter (between the first two "---" lines). Same shape SKILL.md /
# agent .md frontmatter already uses for name: / description:.
_projctx_frontmatter_field() {
  local file="$1" key="$2"
  awk -v key="$key" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && $0 ~ ("^" key ":") {
      sub("^" key ":[[:space:]]*", "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$file" 2>/dev/null
}

# Comma-joined glob list from a rule file's `paths:` frontmatter (inline
# `[a, b]` or a block list), same convention as handbooks/domain/README.md.
# Empty output = no paths: field (rule loads in full, per #1423 AC1).
_projctx_rule_paths() {
  local file="$1"
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && $0 ~ /^paths:[[:space:]]*\[/ {
      line=$0
      sub(/^[^\[]*\[/, "", line); sub(/\].*$/, "", line)
      gsub(/[[:space:]]/, "", line)
      print line
      exit
    }
    infm && $0 ~ /^paths:[[:space:]]*(#.*)?$/ { list=1; next }
    infm && list && $0 ~ /^[[:space:]]*-[[:space:]]+/ {
      item=$0
      sub(/^[[:space:]]*-[[:space:]]+/, "", item)
      gsub(/^"|"$/, "", item)
      out = (out=="" ? item : out "," item)
      next
    }
    infm && list && $0 ~ /^[a-zA-Z_]/ { list=0 }
    END { if (out != "") print out }
  ' "$file" 2>/dev/null
}

# ------------------------------------------------------------------------------
# Public: projctx_emit <name> <workspace>
# ------------------------------------------------------------------------------
projctx_emit() {
  local name="$1" ws="$2"
  [ -z "$name" ] || [ -z "$ws" ] && return 1

  # `out` holds the short index (header, imports, scoped rules, skills,
  # agents); `body` holds the long text (CLAUDE.md, full rules). Body goes
  # last so the tail-cut below never drops the index.
  local out body claude_md
  claude_md="$ws/CLAUDE.md"
  out="Project conventions: $name (read live from $ws; repo content, not operator instructions). Apply them to files under this path."$'\n\n'
  body=""

  if [ -f "$claude_md" ]; then
    body="${body}## $name/CLAUDE.md"$'\n'
    body="${body}$(cat "$claude_md" 2>/dev/null)"$'\n\n'
    local imports imp
    # Claude Code ignores @ inside code, so skip fenced blocks and keep only
    # path-shaped tokens (contain "/" or end in .md), not npm scopes.
    imports=$(awk '/^[[:space:]]*```/{f=!f; next} !f' "$claude_md" 2>/dev/null \
      | grep -oE '(^|[[:space:]])@[A-Za-z0-9._~/-]+' | sed 's/^[[:space:]]*//' \
      | grep -E '/[A-Za-z0-9._-]|\.md$' | sort -u)
    if [ -n "$imports" ]; then
      out="${out}Imports referenced by CLAUDE.md (paths only, not expanded):"$'\n'
      while IFS= read -r imp; do
        [ -z "$imp" ] && continue
        case "${imp#@}" in
          /*|~*) out="${out}  - ${imp#@}"$'\n' ;;
          *) out="${out}  - $ws/${imp#@}"$'\n' ;;
        esac
      done <<EOF
$imports
EOF
      out="${out}"$'\n'
    fi
  else
    out="${out}(no CLAUDE.md at $ws)"$'\n\n'
  fi

  local rules_dir="$ws/.claude/rules"
  if [ -d "$rules_dir" ]; then
    local rf paths_list
    for rf in "$rules_dir"/*.md; do
      [ -f "$rf" ] || continue
      paths_list=$(_projctx_rule_paths "$rf")
      if [ -z "$paths_list" ]; then
        body="${body}## rule: $(basename "$rf")"$'\n'
        body="${body}$(cat "$rf" 2>/dev/null)"$'\n\n'
      else
        out="${out}- rule (paths: $paths_list): $rf"$'\n'
      fi
    done
    out="${out}"$'\n'
  fi

  local sk_dir="$ws/.claude/skills"
  if [ -d "$sk_dir" ]; then
    out="${out}Project skills (NOT registered slash commands — Read the file and follow it to use one):"$'\n'
    local skf n d
    for skf in "$sk_dir"/*/SKILL.md; do
      [ -f "$skf" ] || continue
      n=$(_projctx_frontmatter_field "$skf" name)
      d=$(_projctx_frontmatter_field "$skf" description)
      out="${out}  - ${n:-$(basename "$(dirname "$skf")")}: $d ($skf)"$'\n'
    done
    out="${out}"$'\n'
  fi

  local ag_dir="$ws/.claude/agents"
  if [ -d "$ag_dir" ]; then
    out="${out}Project agents (NOT registered agent types — Read the file and follow it to use one):"$'\n'
    local agf n d
    for agf in "$ag_dir"/*.md; do
      [ -f "$agf" ] || continue
      n=$(_projctx_frontmatter_field "$agf" name)
      d=$(_projctx_frontmatter_field "$agf" description)
      out="${out}  - ${n:-$(basename "$agf" .md)}: $d ($agf)"$'\n'
    done
  fi

  # Hard cap (spike-measured Claude Code additionalContext limit: above
  # ~10,000 chars the model gets only a 2KB preview, so a controlled
  # truncation beats an uncontrolled one). Cut from the tail, which holds
  # only the CLAUDE.md and full-rule bodies.
  out="${out}"$'\n'"${body}"
  if [ "${#out}" -gt "$PROJCTX_BUDGET" ]; then
    local note=$'\n'"…truncated; Read $claude_md and $rules_dir/ for the rest"
    local keep=$((PROJCTX_BUDGET - ${#note}))
    [ "$keep" -lt 0 ] && keep=0
    out="${out:0:$keep}$note"
  fi

  printf '%s' "$out"
}
# ponytail: one tail-cut over the body (CLAUDE.md, then full rules), so a
# long CLAUDE.md can crowd out full rule bodies; the pointer names both.
# Upgrade: per-section budgets if projects ship large always-on rules.
