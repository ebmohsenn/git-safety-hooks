#!/usr/bin/env bash
# Proof for hooks/pre-push: unit cases fed through stdin exactly as git does, plus one real push
# to a local bare remote.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
new_repo
Z=0000000000000000000000000000000000000000
A=1111111111111111111111111111111111111111

URL="https://example.invalid/repo.git"
LAST=""
push() { # push <want> <name> <remote-name|url> <stdin> [ENV=VAL…]
  local want="$1" name="$2" remote="$3" input="$4"; shift 4
  # git passes <name> <url>; for `git push <url> …` it passes the URL twice
  local got=0 out url="$URL"
  case "$remote" in *://*) url="$remote" ;; esac
  out="$(printf '%s\n' "$input" | env "$@" bash "$HOOKS/pre-push" "$remote" "$url" 2>&1)" || got=$?
  if [ "$got" = "$want" ]; then ok "$name (exit $got)"; else bad "$name (exit $got, wanted $want)"; printf '%s\n' "$out" | sed 's/^/     /'; fi
  LAST="$out"
}
has() { if grep -qF -- "$1" <<<"$LAST"; then ok "  says: $1"; else bad "  output lacks: $1"; printf '%s\n' "$LAST" | sed 's/^/     /'; fi; }

push 0 "no pushGuard.allow configured → guard off" origin "refs/heads/feature $A refs/heads/feature $Z"

git config --add safety.pushGuard.allow refs/heads/main
git config --add safety.pushGuard.allow 'refs/tags/*'
push 0 "main → allowed" origin "refs/heads/main $A refs/heads/main $Z"
push 0 "a tag → allowed (glob)" origin "refs/tags/v1.0 $A refs/tags/v1.0 $Z"
push 1 "a feature branch → refused" origin "refs/heads/feature $A refs/heads/feature $Z"
push 1 "local main pushed to a remote feature ref → refused (remote ref is what counts)" origin "refs/heads/main $A refs/heads/wip $Z"
push 0 "HEAD:main from a local scratch branch → allowed" origin "refs/heads/scratch $A refs/heads/main $Z"
push 1 "deleting remote main → refused" origin "(delete) $Z refs/heads/main $A"
push 1 "one bad ref among good ones → refused" origin "refs/heads/main $A refs/heads/main $Z
refs/heads/x $A refs/heads/x $Z"
push 0 "PUSH_GUARD_OVERRIDE=1 → allowed" origin "refs/heads/feature $A refs/heads/feature $Z" PUSH_GUARD_OVERRIDE=1
has "push guard overridden — PUSH_GUARD_OVERRIDE=1"
push 0 "SAFETY_SKIP=push-guard → allowed" origin "refs/heads/feature $A refs/heads/feature $Z" SAFETY_SKIP=push-guard
has "push-guard skipped — SAFETY_SKIP"
push 0 "an allowed push says nothing about overrides" origin "refs/heads/main $A refs/heads/main $Z"
if [ -z "$LAST" ]; then ok "  quiet"; else bad "  an ordinary allowed push printed: $LAST"; fi
push 0 "empty stdin (nothing to push) → allowed" origin ""

push 1 "pre-commit framework env (no stdin): feature branch → refused" origin "" \
  PRE_COMMIT_REMOTE_BRANCH=refs/heads/feature PRE_COMMIT_LOCAL_BRANCH=refs/heads/feature PRE_COMMIT_TO_REF=$A PRE_COMMIT_FROM_REF=$Z
push 0 "pre-commit framework env (no stdin): main → allowed" origin "" \
  PRE_COMMIT_REMOTE_BRANCH=refs/heads/main PRE_COMMIT_LOCAL_BRANCH=refs/heads/main PRE_COMMIT_TO_REF=$A PRE_COMMIT_FROM_REF=$Z

git config safety.pushGuard.allowDeletes true
push 0 "allowDeletes=true → deletion allowed" origin "(delete) $Z refs/heads/old $A"
git config --unset safety.pushGuard.allowDeletes

git config safety.pushGuard.remote origin
push 1 "pushGuard.remote=origin: guarded on origin" origin "refs/heads/feature $A refs/heads/feature $Z"
push 0 "pushGuard.remote=origin: other remotes unguarded" fork "refs/heads/feature $A refs/heads/feature $Z"
# `git push <url> feature` hands the hook the URL where the name would be: origin's URL is origin
git remote add origin "$URL"
push 1 "pushGuard.remote=origin: pushing to origin's URL instead of its name → still guarded" "$URL" "refs/heads/feature $A refs/heads/feature $Z"
push 0 "pushGuard.remote=origin: some other URL → unguarded" "https://example.invalid/elsewhere.git" "refs/heads/feature $A refs/heads/feature $Z"
git remote remove origin
git config --unset safety.pushGuard.remote

# a real push through git to a bare remote
git init -q --bare "$T/remote.git"
git remote add origin "$T/remote.git"
git config core.hooksPath "$HOOKS"
echo a > a.txt && git add a.txt && git commit -q --no-verify -m a
if git push -q origin main 2>/dev/null; then ok "real push of main → accepted"; else bad "real push of main refused"; fi
git checkout -q -b feature
if git push -q origin feature 2>/dev/null; then bad "real push of a feature branch went through"; else ok "real push of a feature branch → refused"; fi
if git ls-remote "$T/remote.git" | grep -q refs/heads/feature; then bad "feature branch reached the remote"; else ok "feature branch did not reach the remote"; fi

finish "push-guard"
