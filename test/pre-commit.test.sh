#!/usr/bin/env bash
# Proof for the REAL hooks/pre-commit dispatcher in a throwaway repo, driven by .git-safety.conf,
# with a PRIVATE GIT_INDEX_FILE (the staged state is the truth, not the working tree):
#   Part A  the shrink-only ratchet
#   Part B  the stale-revert guard wired through the hook
#   Part C  secret-scan wiring, SAFETY_SKIP, enable/disable switches, migrations, fix-perms
#   Part D  what a committed .git-safety.conf must NOT be able to do, and what it must say
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
has 'ratchet skipped — SAFETY_SKIP="ratchet"'

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
stage; echo "-- uno" | put "db/migrations/0001_añadir.sql"
hook 1 "a duplicate number in a non-ASCII file name → blocked"
has "0001_añadir.sql"
git config --unset safety.migrations.dir

echo "x" > perm.txt; chmod 600 perm.txt; git add perm.txt
git config safety.fixPerms.enabled true
out="$(bash .githooks/pre-commit 2>&1)"
# shellcheck source=../hooks/lib/fix-perms.sh
. "$HOOKS/lib/fix-perms.sh"
if [ "$(_mode_of perm.txt)" = 644 ]; then ok "fixPerms: 0600 staged file made world-readable"; else bad "fixPerms did not fix: mode $(_mode_of perm.txt) $out"; fi
# a staged symlink must never get its TARGET chmod-ed (on macOS a link has its own mode, 0700 under
# umask 077, and chmod follows the link — to a file that can be anywhere on the machine)
OUTSIDE="$(mktemp "${TMPDIR:-/tmp}/gsh-outside.XXXXXX")"; chmod 600 "$OUTSIDE"
( umask 077; ln -s "$OUTSIDE" link-out.txt ); git add link-out.txt
bash .githooks/pre-commit >/dev/null 2>&1
if [ "$(_mode_of "$OUTSIDE")" = 600 ]; then ok "fixPerms: the target of a staged symlink is left alone"; else bad "fixPerms chmod-ed a file outside the repo to $(_mode_of "$OUTSIDE")"; fi
rm -f "$OUTSIDE" link-out.txt
git config --unset safety.fixPerms.enabled
git reset -q

echo "— Part D: the committed settings file —"
# 1. It cannot name a program: typecheck.command is read from this machine's git config only.
cat > build.sh <<'E'
#!/bin/sh
echo ran > "$(dirname "$0")/build-ran.marker"
E
chmod +x build.sh; printf '{}\n' > tsconfig.json
printf '[typecheck]\n\tproject = tsconfig.json\n\tcommand = ./build.sh\n' > tc.conf
mkdir -p fakebin; printf '#!/bin/sh\nexit 1\n' > fakebin/npx; chmod +x fakebin/npx    # the default compiler, absent
stage; echo "export const a = 1" | put src/a.ts
hook 1 "typecheck.command in the committed file → not run" GIT_SAFETY_CONFIG=tc.conf PATH="$T/fakebin:$PATH"
if [ -e build-ran.marker ]; then bad "the committed file's command was executed"; else ok "the committed file's command was NOT executed"; fi
has "typecheck.command in"; has "is ignored"; has "typecheck could not run"
git config safety.typecheck.command ./build.sh
hook 1 "the same command from this machine's git config → run" GIT_SAFETY_CONFIG=tc.conf
if [ -e build-ran.marker ]; then ok "the local command was executed"; else bad "git config safety.typecheck.command was not used"; fi
git config --unset safety.typecheck.command; rm -f build-ran.marker
hook 0 "SKIP_TYPECHECK=1 → skipped, and says so" GIT_SAFETY_CONFIG=tc.conf SKIP_TYPECHECK=1 PATH="$T/fakebin:$PATH"
has "typecheck skipped — SKIP_TYPECHECK=1"
git config safety.typecheck.enabled false
hook 0 "git config safety.typecheck.enabled=false → the committed file cannot turn the compiler on" GIT_SAFETY_CONFIG=tc.conf PATH="$T/fakebin:$PATH"
git config --unset safety.typecheck.enabled
if [ -e build-ran.marker ]; then bad "the committed file's command ran in a later case"; else ok "still never executed"; fi

# 2. Its values are data: a migrations.dir written to be a sed program («w <file>» writes a file) is
#    only ever a directory name.
SEDOUT="$(pwd -P)/sedout"; mkdir -p "$SEDOUT"        # pwd -P: no «//» or symlink in the name
EVIL="m||;w $SEDOUT"
mkdir -p "$EVIL"; echo "-- a" > "$EVIL/0001_a.sql"; git add -A -- "$EVIL" && git commit -q --no-verify -m "an oddly named directory"
printf '[migrations]\n\tdir = "%s"\n' "$EVIL" > mig.conf
stage; echo "-- b" | put "$EVIL/0002_b.sql"
hook 0 "migrations.dir shaped like a sed program → treated as a name" GIT_SAFETY_CONFIG=mig.conf
if [ -z "$(ls -A "$SEDOUT")" ]; then ok "nothing was written through sed"; else bad "sed wrote: $(ls -A "$SEDOUT")"; fi
stage; echo "-- dup" | put "$EVIL/0001_dup.sql"
hook 1 "… and duplicates in that directory are still found" GIT_SAFETY_CONFIG=mig.conf

# 3. A file git cannot parse used to disable everything configured in it, silently.
printf '[ratchet]\n\tfile = src/handler.ts\n[secretScan]\n\tpattern = \\dfoo\n' > bad.conf
stage; { cat $M; echo "const extra = 1"; } | put $M
hook 1 "a settings file git cannot parse → refused, not silently ignored" GIT_SAFETY_CONFIG=bad.conf
has "not valid git-config syntax"

# 4. Switching the secret scan off for everyone is said on every commit.
printf '[secretScan]\n\tenabled = false\n' > off.conf
stage; printf 'const t = "%s"\n' "$TOKEN" | put src/leak.ts
hook 0 "secretScan.enabled=false in the committed file → allowed" GIT_SAFETY_CONFIG=off.conf
has "secret scan is switched OFF"

# 5. Messages print file names as git gives them: a name with an ESC in it stays quoted.
ESCNAME="$(printf 'src/esc\033[31mred.ts')"
stage; echo "a" | put "$ESCNAME"; GIT_INDEX_FILE="$IDX" git commit -q --no-verify -m "an escape in a name" >/dev/null; git reset -q --hard
git config safety.ratchet.file 'src/esc*'
stage; printf 'a\nb\n' | put "$ESCNAME"
hook 1 "a ratchet file whose name contains ESC → blocked"
case "$LAST" in *"$(printf '\033')"*) bad "a raw ESC byte reached the terminal" ;; *) ok "the ESC byte is not printed raw" ;; esac
git config --unset safety.ratchet.file

# 6. A large commit must not switch a check off (`printf … | grep -q` under pipefail did, once the
#    list of staged names outgrew a pipe buffer).
mkdir "$T/big" && cd "$T/big" && git -c init.defaultBranch=main init -q . && git config commit.gpgsign false
cp -R "$HOOKS" .githooks; mkdir -p db/migrations; echo 1 > db/migrations/0001_init.sql
git add -A && git commit -q --no-verify -m base
git config safety.migrations.dir db/migrations
echo 2 > db/migrations/0001_users.sql
mkdir -p zzz/some/deeply/nested/generated/output/directory
for i in $(seq 1 4000); do echo x > "zzz/some/deeply/nested/generated/output/directory/file_number_$i.txt"; done
git add -A
if bash .githooks/pre-commit >/dev/null 2>&1; then bad "a duplicate migration among 4,000 staged files went through"; else ok "a duplicate migration among 4,000 staged files → blocked"; fi
cd "$T" || exit 1

finish "pre-commit"
