# shellcheck shell=bash
# migration-numbers.sh — refuse two migrations with the same numeric prefix.
#
# Two people (or agents) each pick "the next number" from the same starting point minutes apart:
# 0042_add_users.sql and 0042_add_orders.sql. Depending on the runner, one is silently skipped,
# applied in the wrong order, or the second deploy fails. Each collision then needs a rename and a
# hand-fix of the migrations ledger.
#
# Looks at the INDEX (what this commit will contain). The prefix is the leading run of digits
# (leading zeros ignored); files without one are ignored. A duplicate pair whose files are ALL
# already in HEAD is settled history (both were applied under their own names; renaming either now
# would break checksums), so only a pair involving a file that is NEW in this commit fails — the
# shape a fresh collision always has. Note the check is "is it in HEAD", not "is it tracked": the
# new file is already in the index when the hook runs.
#
# run_migration_numbers <dir>…   exit 1 = blocked
run_migration_numbers() {
  local bad=0 dir files dupes n f
  for dir in "$@"; do
    dir="${dir%/}"
    files="$(git ls-files -- "$dir/" 2>/dev/null | sed "s|^$dir/||" | grep -v / || true)"
    [ -n "$files" ] || continue
    dupes="$(printf '%s\n' "$files" | sed -n 's/^\([0-9][0-9]*\).*/\1/p' | sed 's/^0*\([0-9]\)/\1/' | sort -n | uniq -d)"
    for n in $dupes; do
      local members="" live=0
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        members="${members}      $f\n"
        git cat-file -e "HEAD:$dir/$f" >/dev/null 2>&1 || live=1
      done <<EOF
$(printf '%s\n' "$files" | grep -E "^0*${n}([^0-9]|\$)")
EOF
      if [ "$live" = 1 ]; then
        [ "$bad" = 0 ] && echo "✖ commit blocked: duplicate migration numbers:"
        echo "  $dir: $n"
        printf "%b" "$members"
        bad=1
      fi
    done
  done
  if [ "$bad" = 1 ]; then
    echo ""
    echo "  Rename the NEW file to the next free number. If one of them is already applied somewhere,"
    echo "  rename the other one and update your migrations ledger to match."
    return 1
  fi
  return 0
}
