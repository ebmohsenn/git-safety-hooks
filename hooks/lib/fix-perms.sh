# shellcheck shell=bash
# fix-perms.sh — make staged files group/world-readable instead of blocking on them.
#
# git records only the exec bit, so a mode-0600 file is a purely LOCAL fact — but on a shared
# machine (a deploy box, a CI runner under another user, a cron job) it makes that file invisible
# to every other user, which then fails with EACCES and says nothing useful. A common cause is
# the "safe atomic write" pattern: write a temp file and rename it over the target. mkstemp()
# creates files at 0600 by design, and the rename carries that mode onto the target, whatever
# your umask is.
#
# It warns and FIXES (chmod g+r,o+r) rather than blocking: the remedy has no effect on content
# or on what git records.
#
# run_fix_perms <file>…   always returns 0
_mode_of() { stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' -- "$1" 2>/dev/null; }
run_fix_perms() {
  local f m
  for f in "$@"; do
    # Never follow a symlink: `[ -f ]` and chmod act on the TARGET, which can be a file outside the
    # repository, while BSD stat reports the link's own mode — so a link made under umask 077 would
    # get its target chmod-ed. A link has no mode of its own worth fixing.
    [ -L "$f" ] && continue
    [ -f "$f" ] || continue
    m="$(_mode_of "$f")" || continue
    case "$m" in ''|*[!0-7]*) continue ;; esac
    if [ "$(( 0$m & 04 ))" -eq 0 ]; then
      chmod g+r,o+r -- "$f" 2>/dev/null || true
      echo "⚠️  $f was mode $m (not world-readable) — fixed to $(_mode_of "$f")."
    fi
  done
  return 0
}
