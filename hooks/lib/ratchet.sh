# shellcheck shell=bash
# ratchet.sh — shrink-only ratchet: listed files may only get SHORTER (or stay the same).
#
# Some files attract "just one more branch" from everyone: a giant route handler, a god class,
# a 10k-line config. They are where regressions and merge collisions concentrate. List them under
# `ratchet.file` and a commit whose STAGED version of any of them has more lines than HEAD's is
# refused. HEAD itself is the baseline, so there is no baseline file to fight over and the limit
# only ever moves down. Each file is judged on NET lines (added - removed), separately.
#
# Reads the staged side with `git diff --cached --numstat`, which honours GIT_INDEX_FILE.
#   RATCHET_OVERRIDE="<why this must grow>" git commit …     (printed, then allowed)
#
# run_ratchet <hint> <pathspec>…   exit 1 = blocked
run_ratchet() {
  local hint="$1"; shift
  [ $# -gt 0 ] || return 0
  git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || return 0
  local grown="" _add _del _path
  while IFS=$'\t' read -r _add _del _path; do
    [ -z "${_path:-}" ] && continue
    case "$_add" in ''|*[!0-9]*) continue ;; esac   # binary ("-")
    if [ "$(( _add - _del ))" -gt 0 ]; then
      grown="${grown}   $_path  +$(( _add - _del )) lines net (+$_add / -$_del)\n"
    fi
  done < <(git diff --cached --numstat --no-renames HEAD -- "$@" 2>/dev/null || true)
  [ -n "$grown" ] || return 0
  if [ -n "${RATCHET_OVERRIDE:-}" ]; then
    echo "⚠️  shrink-only ratchet overridden — RATCHET_OVERRIDE=\"$RATCHET_OVERRIDE\""
    printf "%b" "$grown"
    return 0
  fi
  echo ""
  echo "✖ commit blocked: these files are shrink-only, and this commit grows them:"
  printf "%b" "$grown"
  echo ""
  [ -n "$hint" ] && echo "   $hint"
  echo "   If this commit genuinely must grow the file (a hotfix, wiring that cannot move out):"
  echo "     RATCHET_OVERRIDE=\"<why>\" git commit …"
  return 1
}
