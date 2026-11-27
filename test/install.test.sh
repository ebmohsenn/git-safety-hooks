#!/usr/bin/env bash
# Proof for install.sh: link mode, vendor mode, refusal to clobber another hook manager, uninstall,
# chaining of a pre-existing .git/hooks hook — and an end-to-end commit that gets blocked.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
new_repo
INSTALL="$ROOT/install.sh"

out="$(bash "$INSTALL" "$T" 2>&1)" || bad "link install failed: $out"
if [ "$(git config core.hooksPath)" = "$HOOKS" ]; then ok "link mode: core.hooksPath → this checkout's hooks/"; else bad "link mode: core.hooksPath is '$(git config core.hooksPath)'"; fi

echo "x" > a.txt; git add a.txt
printf 'k = "%s"\n' "AKIA$(openssl rand -hex 8 | tr 'a-f' 'A-F')" > key.txt; git add key.txt
if git commit -q -m "leak" >/dev/null 2>&1; then bad "end-to-end: a commit with an AWS key went through"; else ok "end-to-end: a commit with an AWS key is blocked"; fi
git rm -q --cached key.txt; rm key.txt
if git commit -q -m "clean" >/dev/null 2>&1; then ok "end-to-end: a clean commit goes through"; else bad "end-to-end: clean commit blocked"; fi

git config core.hooksPath .husky/_
if bash "$INSTALL" "$T" >/dev/null 2>&1; then bad "overwrote another hook manager's core.hooksPath without --force"; else ok "refuses to replace a foreign core.hooksPath"; fi
# --uninstall undoes OUR install only: husky's hooksPath is not ours to unset
if bash "$INSTALL" --uninstall "$T" >/dev/null 2>&1; then bad "--uninstall claimed success on a foreign core.hooksPath"; else ok "--uninstall leaves a foreign core.hooksPath alone (exit 1)"; fi
if [ "$(git config core.hooksPath)" = ".husky/_" ]; then ok "the foreign core.hooksPath is still set"; else bad "--uninstall unset another tool's core.hooksPath"; fi
# --vendor into a .githooks/ that already holds someone else's lib/config.sh: keep theirs
mkdir -p .githooks/lib; echo "# somebody else's file" > .githooks/lib/config.sh
bash "$INSTALL" --vendor --force --config "$T" >/dev/null 2>&1 || bad "vendor install failed"
if [ "$(cat .githooks/lib/config.sh.orig 2>/dev/null)" = "# somebody else's file" ]; then ok "vendor mode: a foreign lib/ file of the same name is kept as .orig"; else bad "vendor mode overwrote a foreign .githooks/lib/config.sh"; fi
if cmp -s .githooks/lib/config.sh "$HOOKS/lib/config.sh"; then ok "vendor mode: our lib/config.sh is in place"; else bad "vendor mode did not install lib/config.sh"; fi
rm -f .githooks/lib/config.sh.orig
# … and a second run (an upgrade of our own copy) does not litter .orig files
echo "# an older version of ours" >> .githooks/lib/ratchet.sh
bash "$INSTALL" --vendor "$T" >/dev/null 2>&1 || bad "vendor upgrade failed"
if [ ! -e .githooks/lib/ratchet.sh.orig ] && cmp -s .githooks/lib/ratchet.sh "$HOOKS/lib/ratchet.sh"; then ok "vendor mode: upgrading our own copy replaces it"; else bad "vendor upgrade left the old file or a stray .orig"; fi
if [ "$(git config core.hooksPath)" = ".githooks" ] && [ -x .githooks/pre-commit ] && [ -f .githooks/lib/secret-scan.mjs ]; then ok "vendor mode: hooks copied, core.hooksPath=.githooks"; else bad "vendor mode incomplete"; fi
if [ -f .git-safety.conf ] && git config -f .git-safety.conf --get secretScan.enabled >/dev/null; then ok "--config writes a parseable .git-safety.conf"; else bad "--config did not write a parseable config"; fi

# a pre-existing .git/hooks/pre-commit keeps running after ours
printf '#!/bin/sh\necho legacy-ran > "%s/legacy.out"\n' "$T" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
echo y > b.txt; git add b.txt; git commit -q -m "b" >/dev/null 2>&1
if [ -f "$T/legacy.out" ]; then ok "a legacy .git/hooks/pre-commit is chained"; else bad "legacy hook was not chained"; fi
rm -f "$T/legacy.out"
echo w > d.txt; git add d.txt; PRE_COMMIT=1 bash .githooks/pre-commit >/dev/null 2>&1; git reset -q
if [ -f "$T/legacy.out" ]; then bad "chained the legacy hook under the pre-commit framework (recursion risk)"; else ok "no chaining under the pre-commit framework"; fi
rm -f "$T/legacy.out"; git config safety.chainLocalHooks false
echo z > c.txt; git add c.txt; git commit -q -m "c" >/dev/null 2>&1
if [ -f "$T/legacy.out" ]; then bad "chainLocalHooks=false still ran the legacy hook"; else ok "chainLocalHooks=false stops chaining"; fi

bash "$INSTALL" --uninstall "$T" >/dev/null 2>&1
if git config --get core.hooksPath >/dev/null; then bad "uninstall left core.hooksPath set"; else ok "uninstall unsets core.hooksPath"; fi
git config core.hooksPath .husky/_
bash "$INSTALL" --uninstall --force "$T" >/dev/null 2>&1
if git config --get core.hooksPath >/dev/null; then bad "--uninstall --force left core.hooksPath set"; else ok "--uninstall --force unsets a foreign core.hooksPath"; fi

finish "install"
