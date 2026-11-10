#!/usr/bin/env bash
# Proof for hooks/lib/stale-revert-guard.mjs: synthetic replays of the stale-copy failure, and of
# the normal commits that look similar but must stay quiet.
#
# Every scenario builds a small history with FIXED commit times, then rebuilds a staged state in a
# PRIVATE index (GIT_INDEX_FILE, the way agents and scripts often commit) and runs the guard with a
# fixed clock (STALE_GUARD_NOW). Nothing depends on the wall clock.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
GUARD="$HOOKS/lib/stale-revert-guard.mjs"
new_repo
BASE_T="$T"
NOW=1800000000
H=3600

fresh() { cd "$BASE_T" && rm -rf r && mkdir r && cd r && git -c init.defaultBranch=main init -q . && git config commit.gpgsign false; IDX="$PWD/.git/private-index"; }
at() { local t="$1"; shift; GIT_AUTHOR_DATE="@$t +0000" GIT_COMMITTER_DATE="@$t +0000" "$@"; }
commit_at() { git add -A && at "$1" git commit -q --no-verify -m "$2"; }
stage_reset() { rm -f "$IDX"; GIT_INDEX_FILE="$IDX" git read-tree HEAD; }
put() { GIT_INDEX_FILE="$IDX" git update-index --add --cacheinfo "100644,$(git hash-object -w --stdin),$1"; }
put_rev() { git show "$1:$2" | put "$2"; }      # stage <path> as it was in <rev>
run_guard() { # run_guard <want> <label> [needle] [ENV=VAL…]
  local want="$1" label="$2" needle="${3:-}"; shift 3 2>/dev/null || shift $#
  local out got=0
  out="$(env GIT_INDEX_FILE="$IDX" STALE_GUARD_NOW="$NOW" "$@" node "$GUARD" 2>&1)" || got=$?
  if [ "$got" != "$want" ]; then bad "$label (exit $got, wanted $want)"; printf '%s\n' "$out" | sed 's/^/       /'; return; fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then bad "$label: output lacks '$needle'"; printf '%s\n' "$out" | sed 's/^/       /'; return; fi
  ok "$label"
}
body() { local p="$1" n="$2" i; for i in $(seq 1 "$n"); do echo "export const ${p}_$i = compute('${p}-value-$i')"; done; }

echo "— must fire —"

# 1. STRONG: A rewrote lines (added + removed); the staged copy is the pre-A file plus nothing.
fresh
body base 20 > svc.ts; commit_at $((NOW - 10*H)) "base"
{ body base 10; body featA 8; body base 20 | sed -n '14,20p'; } > svc.ts; commit_at $((NOW - 2*H)) "feat: session A reworks svc"
stage_reset; put_rev HEAD~1 svc.ts
run_guard 1 "strong: staged file is the exact pre-A copy" "feat: session A reworks svc"

# 2. Same, but the stale copy also carries the committer's OWN new line — still a revert of A.
stage_reset; { git show HEAD~1:svc.ts; echo "export const mine = compute('my-own-change')"; } | put svc.ts
run_guard 1 "strong: stale copy + my own new line" "session A"

# 3. ACK_REVERT lets a deliberate revert through and says so.
run_guard 0 "ACK_REVERT=<sha> → allowed" "ACK_REVERT" ACK_REVERT="reverting A on purpose"

# 4. WEAK x2: B added code AND its test (additions only); both vanish in one commit.
fresh
body core 10 > code.ts; body t 10 > code.test.ts; commit_at $((NOW - 10*H)) "base"
{ body core 10; body featB 6; } > code.ts; { body t 10; body testB 6; } > code.test.ts
commit_at $((NOW - 3*H)) "feat: B adds feature + test"
stage_reset; put_rev HEAD~1 code.ts; put_rev HEAD~1 code.test.ts
run_guard 1 "weak x2: a feature and its test vanish together" "feat: B adds feature + test"

# 5. ... while removing B's lines from ONE file only is a plausible deliberate deletion.
stage_reset; put_rev HEAD~1 code.ts
run_guard 0 "weak x1: one file's recent additions removed → quiet"

# 6. SMALL x2: C added 2 lines in each of two files 5 minutes ago; both are dropped.
fresh
body a 10 > a.ts; body b 10 > b.ts; commit_at $((NOW - 10*H)) "base"
{ body a 10; body smallA 2; } > a.ts; { body b 10; body smallB 2; } > b.ts
commit_at $((NOW - 300)) "fix: C tweaks a and b"
stage_reset; put_rev HEAD~1 a.ts; put_rev HEAD~1 b.ts
run_guard 1 "small x2 within 30 min" "fix: C tweaks a and b"

echo "— must stay quiet —"

# 7. Same small change, but it landed 2 h ago: too small to be evidence outside the short window.
fresh
body a 10 > a.ts; body b 10 > b.ts; commit_at $((NOW - 10*H)) "base"
{ body a 10; body smallA 2; } > a.ts; { body b 10; body smallB 2; } > b.ts
commit_at $((NOW - 2*H)) "fix: C tweaks a and b"
stage_reset; put_rev HEAD~1 a.ts; put_rev HEAD~1 b.ts
run_guard 0 "small x2 but 2 h old → quiet"

# 8. A refactor that removes HALF of what A added: not an inverse.
fresh
body base 20 > svc.ts; commit_at $((NOW - 10*H)) "base"
{ body base 20; body featA 10; } > svc.ts; commit_at $((NOW - 2*H)) "feat: A"
{ body base 20; body featA 5; } > svc.ts.new; stage_reset; put svc.ts < svc.ts.new; rm svc.ts.new
run_guard 0 "refactor removes half of A's lines → quiet"

# 9. A normal edit of A's lines (rewritten, not reverted).
stage_reset; { body base 20; body featA 10 | sed 's/compute/computeBetter/'; } | put svc.ts
run_guard 0 "rewriting A's lines (not an inverse) → quiet"

# 10. The strong pattern, but A is 72 h old: outside the default 48 h window...
fresh
body base 20 > svc.ts; commit_at $((NOW - 100*H)) "base"
{ body base 10; body featA 8; body base 20 | sed -n '14,20p'; } > svc.ts; commit_at $((NOW - 72*H)) "feat: old A"
stage_reset; put_rev HEAD~1 svc.ts
run_guard 0 "A is 72 h old (default window 48 h) → quiet"
# 11. ... and inside a configured 96 h window.
run_guard 1 "same, STALE_GUARD_WINDOW_HOURS=96 → fires" "feat: old A" STALE_GUARD_WINDOW_HOURS=96

# 12. A skipped path is never examined.
fresh
body base 20 > gen.ts; commit_at $((NOW - 10*H)) "base"
{ body base 10; body featA 8; body base 20 | sed -n '14,20p'; } > gen.ts; commit_at $((NOW - 2*H)) "regen"
stage_reset; put_rev HEAD~1 gen.ts
run_guard 0 "STALE_GUARD_SKIP_PATHS matches → quiet" "" STALE_GUARD_SKIP_PATHS='^gen\.ts$'
run_guard 1 "same file without the skip → fires" "regen"

# 13. Additions only, and a brand-new file: nothing to revert.
stage_reset; { git show HEAD:gen.ts; echo "export const more = compute('more')"; } | put gen.ts; echo "export const n = 1" | put new.ts
run_guard 0 "additions only + a new file → quiet"

# 14. Trivial lines (braces, blanks) are never evidence.
fresh
printf 'function f() {\n  return 1\n}\n' > t.ts; commit_at $((NOW - 10*H)) "base"
printf 'function f() {\n  {\n  }\n  {\n  }\n  ;;\n  return 1\n}\n' > t.ts; commit_at $((NOW - 60)) "braces"
stage_reset; put_rev HEAD~1 t.ts
run_guard 0 "only trivial lines removed → quiet"

# 15. A merge in progress is never judged.
fresh
body base 20 > svc.ts; commit_at $((NOW - 10*H)) "base"
{ body base 10; body featA 8; body base 20 | sed -n '14,20p'; } > svc.ts; commit_at $((NOW - 2*H)) "feat: A"
stage_reset; put_rev HEAD~1 svc.ts
git rev-parse HEAD > .git/MERGE_HEAD
run_guard 0 "MERGE_HEAD present → quiet"
rm -f .git/MERGE_HEAD

# 16. Root commit (no HEAD yet): nothing to compare.
fresh; echo "x" | put a.txt
run_guard 0 "no HEAD yet → quiet"

echo "— mutants (a guard with its decision switched off must let case 1 through) —"
fresh
body base 20 > svc.ts; commit_at $((NOW - 10*H)) "base"
{ body base 10; body featA 8; body base 20 | sed -n '14,20p'; } > svc.ts; commit_at $((NOW - 2*H)) "feat: A"
stage_reset; put_rev HEAD~1 svc.ts
mutant() { # mutant <name> <sed-expr>
  local M="$BASE_T/mut.mjs"; sed "$2" "$GUARD" > "$M"
  if cmp -s "$M" "$GUARD"; then bad "mutant '$1': sed no longer matches the guard"; return; fi
  if env GIT_INDEX_FILE="$IDX" STALE_GUARD_NOW="$NOW" node "$M" >/dev/null 2>&1; then ok "mutant '$1' is caught by the suite"
  else bad "mutant '$1' still blocks — the suite does not test it"; fi
}
mutant "no verdicts" 's/if (strong.length > 0 || strong.length + weak.length >= 2)/if (false)/'
mutant "no inverse test" 's/if (rev < Math.ceil(ratio \* nAdd)) continue;/continue;/'

finish "stale-revert"
