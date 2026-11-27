#!/usr/bin/env bash
# install.sh — install git-safety-hooks into a repository via `git config core.hooksPath`.
#
#   ./install.sh [options] [path/to/repo]       (default repo: the current directory)
#
# Modes:
#   (default)    point core.hooksPath at THIS checkout's hooks/ directory (absolute path).
#                Good for trying it out or for one machine; updates with `git pull` here.
#   --vendor     copy hooks/ into <repo>/.githooks/ and set core.hooksPath=.githooks (relative).
#                Commit .githooks/ so the whole team runs the same version; each clone still
#                needs `git config core.hooksPath .githooks` once (git never auto-enables hooks).
#   --uninstall  unset core.hooksPath, if it points at these hooks (vendored files are left in
#                place for you to delete). A core.hooksPath that belongs to another tool is left alone.
# Options:
#   --config     also write a commented .git-safety.conf into the repo (if absent)
#   --force      replace an existing, different core.hooksPath (e.g. husky's .husky/_); with
#                --uninstall, unset core.hooksPath whatever it points at
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="link"; FORCE=0; CONFIG=0; REPO="."
while [ $# -gt 0 ]; do
  case "$1" in
    --vendor) MODE=vendor ;;
    --uninstall) MODE=uninstall ;;
    --force) FORCE=1 ;;
    --config) CONFIG=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "install.sh: unknown option $1" >&2; exit 2 ;;
    *) REPO="$1" ;;
  esac
  shift
done

ROOT="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || { echo "install.sh: $REPO is not inside a git repository" >&2; exit 2; }
CURRENT="$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || true)"

# ours <dir> — true when <dir> (as core.hooksPath is spelled) holds these hooks.
ours() {
  local d="$1"
  [ -n "$d" ] || return 1
  [ "$d" = "$HERE/hooks" ] && return 0
  case "$d" in /*) ;; *) d="$ROOT/$d" ;; esac
  [ -f "$d/pre-commit" ] && grep -q 'git-safety-hooks' "$d/pre-commit" 2>/dev/null
}

if [ "$MODE" = uninstall ]; then
  if [ -z "$CURRENT" ]; then echo "✓ core.hooksPath is not set in $ROOT — nothing to do"; exit 0; fi
  # Only undo what this installer did: unsetting husky's or lefthook's hooksPath would silently
  # switch off someone else's hooks.
  if ! ours "$CURRENT" && [ "$FORCE" != 1 ]; then
    echo "install.sh: core.hooksPath is '$CURRENT' in $ROOT, which is not git-safety-hooks — left alone." >&2
    echo "  Re-run with --uninstall --force to unset it anyway." >&2
    exit 1
  fi
  git -C "$ROOT" config --unset core.hooksPath 2>/dev/null || true
  echo "✓ core.hooksPath unset in $ROOT (was: $CURRENT)"
  exit 0
fi

if [ "$MODE" = vendor ]; then TARGET=".githooks"; else TARGET="$HERE/hooks"; fi

if [ -n "$CURRENT" ] && [ "$CURRENT" != "$TARGET" ] && [ "$FORCE" != 1 ]; then
  echo "install.sh: core.hooksPath is already '$CURRENT' in $ROOT." >&2
  echo "  Another hook manager (husky, lefthook, …) may own it. See README 'Using with husky / pre-commit'" >&2
  echo "  to call these hooks from it instead, or re-run with --force to replace it." >&2
  exit 1
fi

if [ "$MODE" = vendor ]; then
  # Is there already a copy of these hooks here (an upgrade), or is .githooks/ someone else's?
  UPGRADE=0
  for h in pre-commit commit-msg pre-push; do
    if [ -e "$ROOT/.githooks/$h" ]; then
      if grep -q 'git-safety-hooks' "$ROOT/.githooks/$h"; then UPGRADE=1
      else
        echo "install.sh: $ROOT/.githooks/$h exists and is not ours — not overwriting (move it aside first)." >&2
        exit 1
      fi
    fi
  done
  mkdir -p "$ROOT/.githooks/lib"
  # lib/ files carry plain names (config.sh …). On an upgrade they are our own older copies; in a
  # .githooks/ that was not ours, a different file of the same name is someone else's: keep it.
  for src in "$HERE"/hooks/lib/*; do
    dst="$ROOT/.githooks/lib/$(basename "$src")"
    if [ "$UPGRADE" = 0 ] && [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
      mv "$dst" "$dst.orig"
      echo "  note: existing $dst kept as $(basename "$dst").orig"
    fi
    cp "$src" "$dst"
  done
  cp "$HERE"/hooks/pre-commit "$HERE"/hooks/commit-msg "$HERE"/hooks/pre-push "$ROOT/.githooks/"
  chmod +x "$ROOT/.githooks/pre-commit" "$ROOT/.githooks/commit-msg" "$ROOT/.githooks/pre-push"
fi

git -C "$ROOT" config core.hooksPath "$TARGET"
echo "✓ core.hooksPath = $TARGET  (in $ROOT)"

if [ "$CONFIG" = 1 ]; then
  if [ -e "$ROOT/.git-safety.conf" ]; then echo "  .git-safety.conf already exists — left alone"
  else cp "$HERE/examples/git-safety.conf" "$ROOT/.git-safety.conf"; echo "✓ wrote $ROOT/.git-safety.conf (edit it, then commit it)"; fi
fi

if ! command -v node >/dev/null 2>&1; then
  echo "⚠️  node was not found: secret-scan and stale-revert will be skipped until Node.js >= 18 is on PATH."
fi
COMMON="$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)"
if [ -d "$COMMON/hooks" ]; then
  for h in pre-commit commit-msg pre-push; do
    f="$COMMON/hooks/$h"
    [ -x "$f" ] && echo "  note: existing .git/hooks/$h will still run after ours (safety.chainLocalHooks=false to stop that)."
  done
fi
exit 0
