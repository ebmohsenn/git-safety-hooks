#!/usr/bin/env bash
# Proof for hooks/commit-msg + lib/stamp-trailer.mjs: where the trailer goes, idempotence,
# merges, opt-in, and agent detection order.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
new_repo
STAMP="$HOOKS/lib/stamp-trailer.mjs"
MSG="$T/msg"

expect() { # expect <name> <input> <expected-output> [key] [value]
  printf '%s' "$2" > "$MSG"
  node "$STAMP" "$MSG" "${4:-Agent}" "${5:-claude-code}"
  if [ "$(cat "$MSG"; echo .)" = "$3." ]; then ok "$1"; else bad "$1"; echo "     got:"; sed 's/^/       |/' "$MSG"; echo "     want:"; printf '%s' "$3" | sed 's/^/       |/'; fi
}

expect "one-line subject → blank line, then trailer" \
  $'fix: thing\n' $'fix: thing\n\nAgent: claude-code\n'
expect "subject containing a colon-URL is NOT treated as a trailer block" \
  $'Merge branch \'main\' of https://example.com/x\n' $'Merge branch \'main\' of https://example.com/x\n\nAgent: claude-code\n'
expect "joins an existing trailer block" \
  $'feat: x\n\nbody text\n\nSigned-off-by: A <a@example.com>\n' $'feat: x\n\nbody text\n\nSigned-off-by: A <a@example.com>\nAgent: claude-code\n'
expect "a prose last paragraph gets its own trailer paragraph" \
  $'feat: x\n\nThis explains: why.\n' $'feat: x\n\nThis explains: why.\n\nAgent: claude-code\n'
expect "idempotent: an existing Agent trailer is kept" \
  $'feat: x\n\nAgent: human\n' $'feat: x\n\nAgent: human\n'
expect "editor comment template stays at the end" \
  $'feat: x\n\n# Please enter the commit message\n# Lines starting with # are ignored\n' \
  $'feat: x\n\nAgent: claude-code\n\n# Please enter the commit message\n# Lines starting with # are ignored\n'
expect "empty message is left alone" $'\n# only comments\n' $'\n# only comments\n'
expect "custom key" $'fix: y\n' $'fix: y\n\nTool: cursor\n' Tool cursor

# through the real hook
cp -R "$HOOKS" .githooks; git config core.hooksPath .githooks
echo a > a.txt; git add a.txt
GIT_AGENT=codex git commit -q -m "first"
if git log -1 --format=%B | grep -q '^Agent:'; then bad "trailer added although trailer.enabled is off"; else ok "off by default: no trailer"; fi
git config safety.trailer.enabled true
echo b > b.txt; git add b.txt
GIT_AGENT=codex git commit -q -m "second"
if [ "$(git log -1 --format='%(trailers:key=Agent,valueonly)' | head -1)" = "codex" ]; then ok "GIT_AGENT=codex → Agent: codex"; else bad "trailer missing: $(git log -1 --format=%B)"; fi
git commit -q --amend --no-edit </dev/null
if [ "$(git log -1 --format=%B | grep -c '^Agent:')" = 1 ]; then ok "amend does not double the trailer"; else bad "amend doubled the trailer"; fi
echo c > c.txt; git add c.txt
CLAUDECODE=1 CURSOR_TRACE_ID=x git commit -q -m "third" </dev/null
if [ "$(git log -1 --format='%(trailers:key=Agent,valueonly)' | head -1)" = "claude-code" ]; then ok "CLAUDECODE=1 wins over CURSOR_*"; else bad "detection order wrong: $(git log -1 --format=%B)"; fi
echo d > d.txt; git add d.txt
git config safety.agent ci-bot
git commit -q -m "fourth" </dev/null
if [ "$(git log -1 --format='%(trailers:key=Agent,valueonly)' | head -1)" = "ci-bot" ]; then ok "git config safety.agent is used"; else bad "safety.agent ignored: $(git log -1 --format=%B)"; fi
git config --unset safety.agent

# merges are not stamped
git checkout -q -b side; echo s > s.txt; git add s.txt; GIT_AGENT=x git commit -q -m "side"
git checkout -q main; echo m > m.txt; git add m.txt; GIT_AGENT=x git commit -q -m "main"
GIT_AGENT=x git merge -q --no-ff side -m "Merge branch 'side'" >/dev/null 2>&1
if git log -1 --format=%B | grep -q '^Agent:'; then bad "merge commit was stamped"; else ok "merge commit not stamped"; fi

finish "commit-msg"
