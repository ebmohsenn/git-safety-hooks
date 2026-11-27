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
# $TYPECHECK_CMD or `git config safety.typecheck.command` (default: npx --no-install tsc); it is
# never read from the committed .git-safety.conf, because it is executed.
#
# The compiler reads the WORKING TREE, not the index: "staged-only" describes which files can
# block the commit, not which bytes are compiled. A partially staged file is checked as it is on
# disk.
#
# If the compiler cannot run at all (not installed, a broken command), nothing was checked, and the
# commit is refused with a message that says exactly that. SKIP_TYPECHECK=1 is the way past.
#
# tc_check_project <tsconfig-path relative to repo root>
#   needs: $STAGED (newline list of staged paths), $SAFETY_ROOT, $TC_CMD, $TC_EXCLUDES (newline globs)
#   exit 1 = the compiler did not run, an uncovered staged file, or a type error in a staged file
tc_check_project() {
  local tsconfig="$1"
  local dir_rel dir base
  dir_rel="$(dirname "$tsconfig")"; base="$(basename "$tsconfig")"
  dir="$SAFETY_ROOT/$dir_rel"
  [ "$dir_rel" = "." ] && dir="$SAFETY_ROOT"
  echo "🔷 typecheck: $tsconfig"
  local raw program out root
  # shellcheck disable=SC2086  # TC_CMD is a command line, word-splitting intended
  raw="$( (cd "$dir" && $TC_CMD --noEmit --listFiles -p "$base") 2>&1 || true )"
  program="$(grep -v 'error TS' <<< "$raw" || true)"
  out="$(grep 'error TS' <<< "$raw" || true)"

  # DID IT RUN? A compiler that ran lists at least its own lib .d.ts files, or reports an error TS.
  # Neither means the command itself failed (tsc is not installed, npx refused, a typo): say that,
  # instead of blaming the tsconfig for files "nothing checked".
  if [ -z "$out" ] && ! grep -qE '^(/|[A-Za-z]:[\\/]).*\.[cm]?tsx?$' <<< "$program"; then
    echo "❌ typecheck could not run — nothing was type-checked. The compiler command printed:"
    head -n 3 <<< "$raw" | sed 's/^/   /'
    echo "   Install the project's dependencies, or set the compiler for this machine:"
    echo "     git config safety.typecheck.command '<command>'"
    return 1
  fi
  # tsc prints absolute paths: the physical one (symlinks resolved), which is not always how the
  # repo root is spelled (macOS: /var → /private/var). Accept either, and match the WHOLE line.
  root="$(cd "$SAFETY_ROOT" && pwd -P)"

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
    # --listFiles run. EXACT LINE, NOT A SUBSTRING: «/src/a.ts» is also a substring of
    # «/repo/packages/other/src/a.ts» and of «/repo/src/a.tsx», neither of which covers src/a.ts.
    if ! grep -qxF -e "$root/$file" -e "$SAFETY_ROOT/$file" <<< "$program"; then
      uncovered="${uncovered}   $file"$'\n'
    fi
  done <<< "$STAGED"

  if [ -n "$uncovered" ]; then
    echo "❌ NOT CHECKED BY ANYTHING — the compiler never opened these staged files:"
    printf '%s' "$uncovered"
    echo "   They are outside $tsconfig \"include\", so a clean run says nothing about them."
    echo "   Add them to a tsconfig, or list them under typecheck.exclude if something else checks them."
    return 1
  fi

  [ -z "$out" ] && return 0

  local mine="" rel line
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if [ "$dir_rel" != "." ]; then case "$file" in "$dir_rel"/*) ;; *) continue ;; esac; fi
    # tsc prints paths relative to its own project dir. The error line must START with that path:
    # «utils/index.ts(» is also a substring of an error in «src/utils/index.ts(».
    rel="$file"; [ "$dir_rel" != "." ] && rel="${file#"$dir_rel"/}"
    while IFS= read -r line; do
      case "$line" in "$rel("*|"./$rel("*) mine="${mine}   ${line}"$'\n' ;; esac
    done <<< "$out"
  done <<< "$STAGED"

  if [ -n "$mine" ]; then
    echo "❌ type errors in files you are committing:"
    printf '%s' "$mine"
    return 1
  fi

  echo "   ⚠️  project has type errors, but none in your staged files — continuing."
  head -n 3 <<< "$out" | sed 's/^/      /' || true
  return 0
}
