#!/usr/bin/env bash
# Proof for the REAL hooks/pre-commit dispatcher in a throwaway repo, driven by .git-safety.conf,
# with a PRIVATE GIT_INDEX_FILE (the staged state is the truth, not the working tree):
#   Part A  the shrink-only ratchet
#   Part B  the stale-revert guard wired through the hook
#   Part C  secret-scan wiring, SAFETY_SKIP, enable/disable switches, migrations, fix-perms
set -uo pipefail
. "$(dirname "$0")/lib.sh"
new_repo
cp -R "$HOOKS" .githooks
git config core.hooksPath .githooks
M=src/handler.ts
S=src/shared.ts
mkdir -p src
seq 1 100 | sed 's/^/const handlerLine/;s/$/ = 1/' > $M
seq 1 50  | sed 's/^/export const sharedLine/;s/$/ = 1/' > $S
cat > .git-safety.conf <<'E'
[ratchet]
	file = src/handler.ts
	file = src/shared.ts
	hint = New logic goes into src/services/* as a function with a test.
E
git add -A && git commit -q --no-verify -m base

IDX="$T/.private-index"
LAST=""
# hook <expected-exit> <name> [ENV=VAL …] — run the hook against the private index's staged state.
hook() {
  local want="$1" name="$2"; shift 2
  local out got=0
  out="$(env GIT_INDEX_FILE="$IDX" "$@" bash .githooks/pre-commit 2>&1)" || got=$?
  if [ "$got" = "$want" ]; then ok "$name (exit $got)"; else bad "$name (exit $got, wanted $want)"; printf '%s\n' "$out" | sed 's/^/     /'; fi
  LAST="$out"
}
stage() { rm -f "$IDX"; GIT_INDEX_FILE="$IDX" git read-tree HEAD; }
put()   { GIT_INDEX_FILE="$IDX" git update-index --add --cacheinfo "100644,$(git hash-object -w --stdin),$1"; }
has()   { if grep -qF -- "$1" <<<"$LAST"; then ok "output mentions: $1"; else bad "output lacks: $1"; printf '%s\n' "$LAST" | sed 's/^/     /'; fi; }

echo "— Part A: ratchet —"
stage; { cat $M; echo "const extra = 1"; } | put $M
hook 1 "handler.ts +1 line → blocked"
has "shrink-only"; has "src/services/*"; has 'RATCHET_OVERRIDE="<why>"'

stage; { cat $S; seq 1 5 | sed 's/^/export const more/'; } | put $S
hook 1 "shared.ts +5 lines → blocked"

stage; { cat $M; echo "const extra = 1"; } | put $M
hook 0 "RATCHET_OVERRIDE set → allowed" RATCHET_OVERRIDE="hotfix: wiring cannot move out"
has "hotfix: wiring cannot move out"

stage; { cat $M; echo "const extra = 1"; } | put $M
hook 0 "SAFETY_SKIP=ratchet → allowed" SAFETY_SKIP=ratchet

stage; head -n 99 $M | put $M
hook 0 "handler.ts −1 line → allowed"

stage; { head -n 90 $M; seq 1 10 | sed 's/^/const swapped/'; } | put $M
hook 0 "same line count (10 replaced by 10) → allowed"

stage; { sed '1,3d' $M; echo "const a = 1"; echo "const b = 2"; } | put $M
hook 0 "net −1 although +2 added → allowed (net, not gross)"

stage; { cat $M; echo "const extra = 1"; } | put $M; { cat $S; echo "export const more = 1"; } | put $S
hook 1 "both files grow → blocked, both listed"
has "handler.ts"; has "shared.ts"

stage; echo "x" | put docs/unrelated.md
hook 0 "a commit touching neither file → allowed"

stage; echo "const wt = 1" >> $M
hook 0 "worktree-only growth, index untouched → allowed"
git checkout -q -- $M

git config safety.ratchet.file src/other.ts
stage; echo "x" | put src/other.ts; GIT_INDEX_FILE="$IDX" git commit -q --no-verify -m "add other" >/dev/null; git reset -q --hard
stage; printf 'x\ny\n' | put src/other.ts
hook 1 "a ratchet file from \`git config safety.ratchet.file\` → blocked"
git config --unset safety.ratchet.file

echo "— Part B: stale-revert wiring —"
cat > src/other.ts <<'E'
export function alpha() { return 'alpha-value-one' }
export function beta() { return 'beta-value-two' }
export function gamma() { return 'gamma-value-three' }
E
git add -A && git commit -q --no-verify -m "other base"
STALE_BLOB="$(git rev-parse HEAD:src/other.ts)"
cat > src/other.ts <<'E'
export function alpha() { return 'alpha-value-CHANGED-by-session-A' }
export function beta() { return 'beta-value-CHANGED-by-session-A' }
// session A added this whole block today:
export function delta() { return 'delta-value-from-session-A' }
export function epsilon() { return 'epsilon-value-from-session-A' }
export function gamma() { return 'gamma-value-three' }
E
git add -A && git commit -q --no-verify -m "session A: delta and epsilon"
stage; git cat-file -p "$STALE_BLOB" | put src/other.ts
hook 1 "staged = the stale pre-A copy → blocked as a revert of A"
has "session A: delta and epsilon"; has 'ACK_REVERT='
hook 0 "ACK_REVERT=<sha> → allowed" ACK_REVERT="reverts $(git rev-parse --short HEAD) on purpose"
has "ACK_REVERT"
hook 0 "SAFETY_SKIP=stale-revert → allowed" SAFETY_SKIP=stale-revert
git config safety.staleRevert.enabled false
hook 0 "staleRevert.enabled=false → allowed"
git config --unset safety.staleRevert.enabled

stage; sed 's/delta-value-from-session-A/delta-value-reworked-by-me/' src/other.ts | put src/other.ts
hook 0 "a normal edit of A's lines (not an inverse) → allowed"

echo "— Part C: secret scan, migrations, fix-perms —"
TOKEN="gh""p_$(openssl rand -hex 18)"
stage; printf 'const t = "%s"\n' "$TOKEN" | put src/leak.ts
hook 1 "a github-token shape → blocked by the hook"
has "src/leak.ts:1"; has "github-token pattern"
case "$LAST" in *"$TOKEN"*) bad "hook output printed the secret value" ;; *) ok "hook output does not print the value" ;; esac
hook 0 "SECRET_SCAN_ALLOW → allowed" SECRET_SCAN_ALLOW="proof"
hook 0 "SAFETY_SKIP=secret-scan → allowed" SAFETY_SKIP=secret-scan

printf 'API_SIGNING_SECRET=%s\n' "$(openssl rand -hex 24)" > .env.local
printf '[secretScan]\n\tenvFile = .env.local\n' > alt.conf
stage; printf 'curl -H "x: %s"\n' "$(cut -d= -f2 .env.local)" | put scripts/call.sh
hook 1 "a value from the configured env file (GIT_SAFETY_CONFIG=alt.conf) → blocked" GIT_SAFETY_CONFIG=alt.conf
has "API_SIGNING_SECRET"
hook 0 "same line without that env file configured → allowed"
rm -f .env.local alt.conf

mkdir -p db/migrations
echo "-- one" > db/migrations/0001_init.sql; echo "-- two" > db/migrations/0002_users.sql
git add -A && git commit -q --no-verify -m migrations
git config safety.migrations.dir db/migrations
stage; echo "-- three" | put db/migrations/0002_orders.sql
hook 1 "a new migration reusing number 0002 → blocked"
has "0002_orders.sql"
stage; echo "-- three" | put db/migrations/0003_orders.sql
hook 0 "the next free number → allowed"
git config --unset safety.migrations.dir

echo "x" > perm.txt; chmod 600 perm.txt; git add perm.txt
git config safety.fixPerms.enabled true
out="$(bash .githooks/pre-commit 2>&1)"
# shellcheck source=../hooks/lib/fix-perms.sh
. "$HOOKS/lib/fix-perms.sh"
if [ "$(_mode_of perm.txt)" = 644 ]; then ok "fixPerms: 0600 staged file made world-readable"; else bad "fixPerms did not fix: mode $(_mode_of perm.txt) $out"; fi
git config --unset safety.fixPerms.enabled
git reset -q

finish "pre-commit"
