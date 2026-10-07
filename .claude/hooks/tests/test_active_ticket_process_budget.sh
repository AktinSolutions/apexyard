#!/bin/bash
# Process budget of the git-dir ticket marker resolver.
#
# The lookup functions in _lib-active-ticket.sh must make no fork and no exec.
# Three checks hold that line:
#   1. Every lookup function runs with PATH=/nonexistent and gives the same
#      result as with the normal PATH. Any external command would fail.
#   2. The writer runs through counting wrappers and makes at most three
#      external commands after init.
#   3. A static scan of the lookup function bodies fails on a command
#      substitution, a backtick, a pipe, a subshell, a background job or exec.
#
# On the commit before the resolver none of the functions exist, so the
# first two checks fail there.

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$SRC_ROOT/.claude/hooks/_lib-active-ticket.sh"

export APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

# shellcheck source=/dev/null
. "$LIB"
if ! command -v active_ticket_lookup >/dev/null 2>&1; then
  bad "resolver functions exist" "active_ticket_lookup is not defined"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

REAL_PATH="$PATH"
B=$(mktemp -d)
B=$(cd -P "$B" && pwd)
trap 'rm -rf "$B"' EXIT

mkrepo() {
  git init -q -b main "$1" 2>/dev/null || git init -q "$1"
  git -C "$1" commit -q --allow-empty -m init
}

OPS="$B/ops"
WS="$OPS/workspace"
mkrepo "$OPS"
: > "$OPS/.apexyard-fork"
printf 'projects:\n  - name: p1\n    repo: org/p1\n' > "$OPS/apexyard.projects.yaml"
mkdir -p "$WS" "$OPS/.claude/session/tickets"
mkrepo "$WS/p1"
git -C "$WS/p1" worktree add -q "$B/wt1" -b wt1
mkrepo "$B/rogue"
printf 'repo=org/p1\nnumber=5\n' > "$WS/p1/.git/apexyard-ticket"
printf 'repo=org/p1\nnumber=6\n' > "$WS/p1/.git/worktrees/wt1/apexyard-ticket"
printf 'repo=org/ops\nnumber=7\n' > "$OPS/.git/apexyard-ticket"

ctx() {
  active_ticket_set_context "$OPS" "$WS"
  _AT_REG="$OPS/apexyard.projects.yaml"
  _at_memo_clear
}
ctx

# --- 1. empty PATH -----------------------------------------------------------
# Each entry is "label|function|path". The legacy cases remove the new markers
# first, then add an old-layout file.
run_all() {
  local out="" e label fn arg
  for e in \
    "main|active_ticket_lookup|$WS/p1/src/a.ts" \
    "linked|active_ticket_lookup|$B/wt1/src/a.ts" \
    "ops|active_ticket_lookup|$OPS/src/a.ts" \
    "refusal|active_ticket_lookup|$B/rogue/a.ts" \
    "tilde|active_ticket_lookup|~nobody/x" \
    "gitdir|active_ticket_gitdir|$WS/p1/src" \
    "cwd|active_ticket_lookup_cwd|" \
    "target_yes|active_ticket_is_marker_target|$WS/p1/.git/apexyard-ticket" \
    "target_tmp|active_ticket_is_marker_target|$WS/p1/.git/apexyard-ticket.tmp.Ab3dE9" \
    "target_no|active_ticket_is_marker_target|$WS/p1/.git/config" \
    "field|active_ticket_read_field|$WS/p1/.git/apexyard-ticket"; do
    label="${e%%|*}"
    fn="${e#*|}"
    arg="${fn#*|}"
    fn="${fn%%|*}"
    _at_memo_clear
    case "$fn" in
      active_ticket_lookup_cwd) "$fn" 2> "$B/err" ;;
      active_ticket_read_field) "$fn" "$arg" number 2> "$B/err" ;;
      *) "$fn" "$arg" 2> "$B/err" ;;
    esac
    out="$out$label:rc=$?:reply=$REPLY:reason=$AT_REASON:err=$(wc -c < "$B/err" 2>/dev/null)
"
  done
  RESULT="$out"
}

# The err length uses wc, so measure it with the normal PATH only. Under the
# empty PATH the stderr file is checked by size with a builtin read instead.
run_all_nopath() {
  local out="" e label fn arg errtxt
  for e in \
    "main|active_ticket_lookup|$WS/p1/src/a.ts" \
    "linked|active_ticket_lookup|$B/wt1/src/a.ts" \
    "ops|active_ticket_lookup|$OPS/src/a.ts" \
    "refusal|active_ticket_lookup|$B/rogue/a.ts" \
    "tilde|active_ticket_lookup|~nobody/x" \
    "gitdir|active_ticket_gitdir|$WS/p1/src" \
    "cwd|active_ticket_lookup_cwd|" \
    "target_yes|active_ticket_is_marker_target|$WS/p1/.git/apexyard-ticket" \
    "target_tmp|active_ticket_is_marker_target|$WS/p1/.git/apexyard-ticket.tmp.Ab3dE9" \
    "target_no|active_ticket_is_marker_target|$WS/p1/.git/config" \
    "field|active_ticket_read_field|$WS/p1/.git/apexyard-ticket"; do
    label="${e%%|*}"
    fn="${e#*|}"
    arg="${fn#*|}"
    fn="${fn%%|*}"
    _at_memo_clear
    : > "$B/err"
    case "$fn" in
      active_ticket_lookup_cwd) "$fn" 2> "$B/err" ;;
      active_ticket_read_field) "$fn" "$arg" number 2> "$B/err" ;;
      *) "$fn" "$arg" 2> "$B/err" ;;
    esac
    rc=$?
    errtxt=""
    IFS= read -r errtxt < "$B/err" || true
    if [ -n "$errtxt" ]; then errtxt="nonempty"; fi
    out="$out$label:rc=$rc:reply=$REPLY:reason=$AT_REASON:err=${errtxt:-0}
"
  done
  RESULT="$out"
}

cd "$WS/p1" || exit 1
# Baseline with the normal PATH (the err field is the stderr byte count).
run_all
BASE="$RESULT"
BASE_NORM="${BASE//err=0$'\n'/err=0$'\n'}"
hash -r
PATH=/nonexistent
hash -r
run_all_nopath
NOPATH="$RESULT"
PATH="$REAL_PATH"
hash -r
# Normalise the baseline stderr count the same way.
BASE_CMP=$(printf '%s' "$BASE_NORM" | sed -E 's/err=[0-9]+/err=X/')
NOPATH_CMP=$(printf '%s' "$NOPATH" | sed -E 's/err=[^ ]*/err=X/')
if [ "$BASE_CMP" = "$NOPATH_CMP" ]; then
  ok "1a lookup functions give the same result with PATH=/nonexistent"
else
  bad "1a" "differs"
  diff <(printf '%s' "$BASE_CMP") <(printf '%s' "$NOPATH_CMP") >&2
fi
case "$NOPATH" in
  *"err=nonempty"*) bad "1b stderr is empty under an empty PATH" "$NOPATH" ;;
  *) ok "1b stderr is empty under an empty PATH" ;;
esac
case "$NOPATH" in
  *"main:rc=0:reply=$WS/p1/.git/apexyard-ticket"*"linked:rc=0:reply=$WS/p1/.git/worktrees/wt1/apexyard-ticket"*"ops:rc=0:reply=$OPS/.git/apexyard-ticket"*"refusal:rc=1:reply=:"*)
    ok "1c the results are the expected markers and a refusal" ;;
  *) bad "1c" "$NOPATH" ;;
esac

# Legacy pass and legacy mismatch, also under an empty PATH.
rm -f "$WS/p1/.git/apexyard-ticket"
printf 'repo=org/p1\nnumber=9\n' > "$OPS/.claude/session/tickets/p1"
_at_memo_clear
active_ticket_lookup "$WS/p1/a.ts"
legacy_normal="rc=$?:$REPLY"
PATH=/nonexistent
hash -r
_at_memo_clear
active_ticket_lookup "$WS/p1/a.ts" 2> "$B/err"
legacy_nopath="rc=$?:$REPLY"
PATH="$REAL_PATH"
hash -r
if [ "$legacy_normal" = "$legacy_nopath" ] && [ "$legacy_normal" = "rc=0:$OPS/.claude/session/tickets/p1" ]; then ok "1d legacy pass needs no external command"; else bad "1d" "$legacy_normal vs $legacy_nopath"; fi
printf 'repo=org/other\nnumber=9\n' > "$OPS/.claude/session/tickets/p1"
PATH=/nonexistent
hash -r
_at_memo_clear
active_ticket_lookup "$WS/p1/a.ts" 2> "$B/err"
legacy_mismatch="rc=$?:$REPLY"
PATH="$REAL_PATH"
hash -r
if [ "$legacy_mismatch" = "rc=1:" ]; then ok "1e legacy mismatch needs no external command"; else bad "1e" "$legacy_mismatch"; fi
rm -f "$OPS/.claude/session/tickets/p1"
printf 'repo=org/p1\nnumber=5\n' > "$WS/p1/.git/apexyard-ticket"

# --- 2. writer counter -------------------------------------------------------
SHIM="$B/shim"
mkdir -p "$SHIM"
COUNT="$B/count"
: > "$COUNT"
for tool in mktemp chmod mv date rm; do
  real=$(command -v "$tool")
  cat > "$SHIM/$tool" <<EOF
#!/bin/bash
printf '%s\n' "$tool" >> "$COUNT"
exec "$real" "\$@"
EOF
  chmod +x "$SHIM/$tool"
done
_at_memo_clear
PATH="$SHIM"
hash -r
active_ticket_write "$WS/p1" org/p1 11 "counted" "http://x/11" "feature/count" 2> "$B/werr"
wrc=$?
PATH="$REAL_PATH"
hash -r
n_main=$(grep -cE '^(mktemp|chmod|mv)$' "$COUNT")
n_date=$(grep -c '^date$' "$COUNT")
if [ "$wrc" = 0 ] && grep -q '^number=11$' "$WS/p1/.git/apexyard-ticket"; then ok "2a the writer works with counting wrappers"; else bad "2a" "rc=$wrc $(cat "$B/werr")"; fi
if [ "$n_main" -le 3 ]; then ok "2b the writer makes at most 3 external commands ($n_main)"; else bad "2b" "$n_main commands"; fi
if [ "$n_date" -le 1 ] && { [ "$n_date" = 0 ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; }; then ok "2c date is used only on a bash older than 4.2"; else bad "2c" "date ran $n_date times on bash $BASH_VERSION"; fi

# --- 3. static fork scan -----------------------------------------------------
# The awk program masks quoted text and strips comments. A double-quoted
# string keeps a command substitution and a backtick, because those still run.
mask_awk() {
  awk '
    {
      line = $0; out = ""; state = 0; n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1); d = substr(line, i + 1, 1)
        if (state == 0) {
          if (c == "\\") { out = out "Q"; i++; continue }
          if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;&|(]/)) break
          if (c == "\047") { state = 1; out = out "Q"; continue }
          if (c == "\"") { state = 2; out = out "Q"; continue }
          out = out c
        } else if (state == 1) {
          if (c == "\047") state = 0
          out = out "Q"
        } else {
          if (c == "\\") { out = out "Q"; i++; continue }
          if (c == "\"") { state = 0; out = out "Q"; continue }
          if (c == "`") { out = out c; continue }
          if (c == "$" && d == "(") { out = out c; continue }
          out = out "Q"
        }
      }
      print out
    }'
}

# classify <masked line>: prints a reason when the line forks, else nothing.
classify() {
  local l="$1" t
  case "$l" in
    *'`'*) echo "backtick"; return ;;
    *'<('*|*'>('*) echo "process substitution"; return ;;
  esac
  if printf '%s\n' "$l" | grep -Eq '(^|[^$])\$\(([^(]|$)|^\$\(([^(]|$)'; then echo "command substitution"; return; fi
  if printf '%s\n' "$l" | grep -Eq '(^|[^[:alnum:]_])(coproc|exec)([^[:alnum:]_]|$)'; then echo "coproc or exec"; return; fi
  if printf '%s\n' "$l" | grep -Eq '(^|;|&&|\|\||[[:space:]])(then|do|else)[[:space:]]*\(|(^|;|&&|\|\|)[[:space:]]*\('; then echo "subshell"; return; fi
  t="${l//&&/}"
  t="${t//&>/}"
  t="${t//>&/}"
  case "$t" in
    *'&'*) echo "background job"; return ;;
  esac
  t="${l//||/}"
  case "$t" in
    *'|'*)
      if ! printf '%s\n' "$l" | grep -Eq '^[[:space:]]*[^[:space:]()]+\)'; then echo "pipe"; return; fi
      ;;
  esac
}

# Known-good and known-bad lines keep the classifier honest.
good=(
  'a || b'
  '*/*|.|..|Q) _at_fail Q; return 1 ;;'
  'x=$((n + 1))'
  '*Q|*Q)'
  'case Q in'
  'cmd >Q 2>&1'
  'exec_count=1'
  '[ -L Q ] && return 1'
  '{ IFS= read -r a; IFS= read -r b; } <<<Q'
)
badl=(
  'x=$(cmd)'
  'x=`cmd`'
  'a | b'
  'cmd &'
  '( cd x )'
  'x && ( cd y )'
  'exec foo'
  'diff <(a) <(b)'
  'coproc x'
  'then (a)'
)
cls_ok=1
for l in "${good[@]}"; do
  r=$(classify "$l")
  [ -z "$r" ] || { cls_ok=0; bad "3a classifier accepts [$l]" "got [$r]"; }
done
for l in "${badl[@]}"; do
  r=$(classify "$l")
  [ -n "$r" ] || { cls_ok=0; bad "3a classifier flags [$l]" "got nothing"; }
done
[ "$cls_ok" = 1 ] && ok "3a the classifier handles known-good and known-bad lines"

# Extract the scanned function bodies from the library.
SCAN_NAMES='^(_at_[a-z_]+|active_ticket_(lookup|lookup_cwd|gitdir|is_marker_target|read_field|set_context))$'
EXTRA_SCAN="${ACTIVE_TICKET_EXTRA_SCAN:-}"
scan_fail=0
scanned=0
while IFS= read -r name; do
  if ! printf '%s\n' "$name" | grep -Eq "$SCAN_NAMES"; then
    case " $EXTRA_SCAN " in *" $name "*) ;; *) continue ;; esac
  fi
  scanned=$((scanned + 1))
  body=$(awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {on=1; next} on && /^}/ {exit} on {print}' "$LIB")
  [ -n "$body" ] || { bad "3b body of $name" "empty"; scan_fail=1; continue; }
  masked=$(printf '%s\n' "$body" | mask_awk)
  lineno=0
  while IFS= read -r ml; do
    lineno=$((lineno + 1))
    r=$(classify "$ml")
    if [ -n "$r" ]; then
      bad "3b $name line $lineno" "$r: $ml"
      scan_fail=1
    fi
  done <<< "$masked"
done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$LIB" | sed -E 's/\(\) \{$//')
if [ "$scan_fail" = 0 ] && [ "$scanned" -ge 20 ]; then ok "3b no lookup function forks ($scanned functions scanned)"; else [ "$scan_fail" != 0 ] || bad "3b" "only $scanned functions scanned"; fi

# The scan must catch a regression: add a command substitution to a copy.
sed 's/^_at_owned() { \[ -O "\$1" \]; }/_at_owned() { local x; x=$(true); [ -O "$1" ]; }/' "$LIB" > "$B/mutant.sh"
mbody=$(awk '$0 ~ "^_at_owned\\(\\) \\{" {print; exit}' "$B/mutant.sh")
mmask=$(printf '%s\n' "$mbody" | mask_awk)
r=$(classify "$mmask")
if [ -n "$r" ]; then ok "3c a command substitution in a lookup function is caught"; else bad "3c" "mutant not caught: $mmask"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
