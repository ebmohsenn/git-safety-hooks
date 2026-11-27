#!/usr/bin/env bash
# Proof that tc_check_project (hooks/lib/typecheck-staged.sh) refuses to pass a staged file the
# compiler never opened, and still passes the cases it must — by feeding it FABRICATED tsc output.
# No TypeScript install is needed.
#
# THE FABRICATED PROGRAM MUST BE BIG. A first version of the original test used a four-line
# program listing and PASSED against a check that was completely broken: `echo "$program" | grep -qF`
# under `set -o pipefail` reports failure when grep exits early on a match and echo dies of SIGPIPE —
# but only once the input is large enough that echo has not finished writing. A real --listFiles
# run is thousands of lines, so every case pads its program to a realistic size.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# shellcheck source=../hooks/lib/typecheck-staged.sh
. "$HOOKS/lib/typecheck-staged.sh"
new_repo
mkdir -p server/src
SAFETY_ROOT="$T"
# tsc prints the PHYSICAL path of each file (on macOS $TMPDIR is /var/… → /private/var/…): the
# fabricated listings use it, so the test also proves the symlinked spelling of the root is handled.
P="$(cd "$T" && pwd -P)"
PAD="$(for i in $(seq 1 3000); do echo "$P/server/node_modules/typescript/lib/lib.$i.d.ts"; done)"

faketsc() { printf '%s\n' "$FAKE"; }
TC_CMD=faketsc

run_case() { # run_case <name> <staged> <program+errors> <want-exit> [excludes]
  local name="$1" want="$4"
  STAGED="$2"; FAKE="$3
$PAD"; TC_EXCLUDES="${5:-}"
  local got=0
  OUT="$(tc_check_project server/tsconfig.json 2>&1)" || got=1
  if [ "$got" = "$want" ]; then ok "$name (exit $got)"; else bad "$name (exit $got, wanted $want)"; printf '%s\n' "$OUT" | sed 's/^/     /'; fi
}
says() { if grep -qF -- "$1" <<<"$OUT"; then ok "  says: $1"; else bad "  output lacks: $1"; printf '%s\n' "$OUT" | sed 's/^/     /'; fi; }

run_case "covered src file, clean program → pass" \
  "server/src/index.ts" "$P/server/src/index.ts" 0
run_case "covered, listed under the root's symlinked spelling → pass" \
  "server/src/index.ts" "$T/server/src/index.ts" 0
run_case "staged src file ABSENT from the program → MUST FAIL" \
  "server/src/ghost.ts" "$P/server/src/other.ts" 1
run_case "absent but matched by typecheck.exclude → pass" \
  "server/scripts/enrich.ts" "$P/server/src/index.ts" 0 "server/scripts/*"
run_case "a file outside the project dir is not this project's concern → pass" \
  "web/src/app.ts" "$P/server/src/index.ts" 0
run_case "a real type error in a covered staged file still fails" \
  "server/src/index.ts" "$P/server/src/index.ts
src/index.ts(5,1): error TS2304: Cannot find name 'x'." 1
run_case "a type error only in someone else's file → pass (warned)" \
  "server/src/index.ts" "$P/server/src/index.ts
src/other.ts(5,1): error TS2304: Cannot find name 'x'." 0
run_case "non-TypeScript staged files are ignored" \
  "server/README.md" "$P/server/src/index.ts" 0

echo "— a path that merely CONTAINS the staged path is not coverage —"
run_case "same tail in another package → MUST FAIL" \
  "server/src/a.ts" "$P/packages/other/server/src/a.ts" 1
run_case "a.tsx in the program does not cover a.ts → MUST FAIL" \
  "server/src/a.ts" "$P/server/src/a.tsx" 1
run_case "an error in src/utils/index.ts does not block staged utils/index.ts" \
  "server/utils/index.ts" "$P/server/utils/index.ts
src/utils/index.ts(1,1): error TS2304: Cannot find name 'x'." 0
run_case "… while an error in utils/index.ts itself does" \
  "server/utils/index.ts" "$P/server/utils/index.ts
utils/index.ts(1,1): error TS2304: Cannot find name 'x'." 1

echo "— the compiler could not run —"
STAGED="server/src/index.ts"; TC_EXCLUDES=""; FAKE="npm error npx canceled due to missing packages"; got=0
OUT="$(TC_CMD=faketsc tc_check_project server/tsconfig.json 2>&1)" || got=1
if [ "$got" = 1 ]; then ok "no compiler output at all → refused (exit 1)"; else bad "a compiler that did not run passed the commit"; fi
says "typecheck could not run"
if grep -q "NOT CHECKED BY ANYTHING" <<<"$OUT"; then bad "blamed the tsconfig for a compiler that never ran"; else ok "  does not blame the tsconfig"; fi

# mutant: drop the coverage check — the "ABSENT from the program" case must then pass
M="$T/mut.sh"; sed 's/if ! grep -qxF -e "$root\/$file" -e "$SAFETY_ROOT\/$file" <<< "$program"; then/if false; then/' "$HOOKS/lib/typecheck-staged.sh" > "$M"
if cmp -s "$M" "$HOOKS/lib/typecheck-staged.sh"; then bad "mutant: sed no longer matches"
else
  # shellcheck disable=SC1090
  . "$M"; STAGED="server/src/ghost.ts"; FAKE="$P/server/src/other.ts
$PAD"
  if tc_check_project server/tsconfig.json >/dev/null 2>&1; then ok "mutant without the coverage check is caught by the suite"
  else bad "mutant without the coverage check still fails — the suite does not test coverage"; fi
fi

finish "typecheck-coverage"
