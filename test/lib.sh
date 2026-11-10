# shellcheck shell=bash
# test/lib.sh — shared helpers for the test suite. Source it.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$ROOT/hooks"
export ROOT HOOKS

# Hermetic git: ignore the developer's global/system config (hooksPath, signing, safety.*, templates).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE SAFETY_SKIP GIT_SAFETY_CONFIG GIT_AGENT \
  SECRET_SCAN_ALLOW SECRET_SCAN_ENV_FILES ACK_REVERT RATCHET_OVERRIDE PUSH_GUARD_OVERRIDE 2>/dev/null || true

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ✓ $1"; }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

# new_repo — create a throwaway repo, cd into it, and register cleanup. Prints nothing.
new_repo() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/gsh-test.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$T'" EXIT
  cd "$T" || exit 1
  git -c init.defaultBranch=main init -q .
  git config commit.gpgsign false
}

# now_ms — milliseconds since the epoch (portable: macOS date has no %N).
now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }

finish() { # finish <suite-name>
  echo "$1: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}
