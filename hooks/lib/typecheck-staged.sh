# shellcheck shell=bash
# typecheck-staged.sh — OPTIONAL TypeScript gate: typecheck a project, but only block on errors in
# files THIS commit stages — and refuse a staged file the compiler never even opened.
#
# Two ideas, both learned the hard way:
#
# 1. COVERAGE BEFORE "NO ERRORS". "tsc printed no error about your file" and "tsc never opened
#    your file" (it is outside the tsconfig `include`) produce byte-identical output. A hook that
#    greps tsc output for the staged path reports success for files nothing checked. Asking the
#    same run for --listFiles costs nothing and turns the second case into a loud failure.
#
# 2. ONLY YOUR FILES BLOCK. tsc checks the whole project. On a shared tree somebody else's
#    half-written file is often red; blocking your commit on THEIR work-in-progress is how hooks
#    end up disabled. Errors elsewhere are printed as a warning, not a failure.
#
# Configure one or more projects (`typecheck.project = path/to/tsconfig.json`). Staged .ts/.tsx/
# .mts/.cts files under that tsconfig's directory must be in its program, unless they match a
# `typecheck.exclude` glob (files you check some other way). The compiler command is
# `typecheck.command` (default: npx --no-install tsc).
#
# tc_check_project <tsconfig-path relative to repo root>
#   needs: $STAGED (newline list of staged paths), $SAFETY_ROOT, $TC_CMD, $TC_EXCLUDES (newline globs)
#   exit 1 = an uncovered staged file or a type error in a staged file
tc_check_project() {
  local tsconfig="$1"
  local dir_rel dir base
  dir_rel="$(dirname "$tsconfig")"; base="$(basename "$tsconfig")"
  dir="$SAFETY_ROOT/$dir_rel"
  [ "$dir_rel" = "." ] && dir="$SAFETY_ROOT"
  echo "🔷 typecheck: $tsconfig"
  local raw program out
  # shellcheck disable=SC2086  # TC_CMD is a command line, word-splitting intended
  raw="$( (cd "$dir" && $TC_CMD --noEmit --listFiles -p "$base") 2>&1 || true )"
  program="$(printf '%s\n' "$raw" | grep -v 'error TS' || true)"
  out="$(printf '%s\n' "$raw" | grep 'error TS' || true)"

  # COVERAGE FIRST. An unchecked file must never reach the "no errors" branch.
  local uncovered="" file pat skip
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in *.ts|*.tsx|*.mts|*.cts) ;; *) continue ;; esac
    case "$file" in *.d.ts) continue ;; esac
    if [ "$dir_rel" != "." ]; then case "$file" in "$dir_rel"/*) ;; *) continue ;; esac; fi
    skip=0
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      # shellcheck disable=SC2254  # pattern match intended
      case "$file" in $pat) skip=1; break ;; esac
    done <<EOF
${TC_EXCLUDES:-}
EOF
    [ "$skip" = 1 ] && continue
    # HERE-STRING, NOT A PIPE: with `set -o pipefail`, `echo big | grep -q` reports failure exactly
    # when grep matches early (echo dies of SIGPIPE) — only on LARGE input, i.e. every real
    # --listFiles run. tsc prints absolute paths; match the repo-relative tail.
    if ! grep -qF "/$file" <<< "$program"; then
      uncovered="${uncovered}   $file\n"
    fi
  done <<< "$STAGED"

  if [ -n "$uncovered" ]; then
    echo "❌ NOT CHECKED BY ANYTHING — the compiler never opened these staged files:"
    printf "%b" "$uncovered"
    echo "   They are outside $tsconfig \"include\", so a clean run says nothing about them."
    echo "   Add them to a tsconfig, or list them under typecheck.exclude if something else checks them."
    return 1
  fi

  [ -z "$out" ] && return 0

  local mine="" rel hits
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    # tsc prints paths relative to its own project dir
    rel="$file"; [ "$dir_rel" != "." ] && rel="${file#"$dir_rel"/}"
    hits="$(printf '%s\n' "$out" | grep -F "$rel(" || true)"
    [ -n "$hits" ] && mine="${mine}${hits}\n"
  done <<< "$STAGED"

  if [ -n "$mine" ]; then
    echo "❌ type errors in files you are committing:"
    printf "%b" "$mine" | sed 's/^/   /'
    return 1
  fi

  echo "   ⚠️  project has type errors, but none in your staged files — continuing."
  printf '%s\n' "$out" | head -3 | sed 's/^/      /' || true
  return 0
}
