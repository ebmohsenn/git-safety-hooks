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
PAD="$(for i in $(seq 1 3000); do echo "/repo/server/node_modules/typescript/lib/lib.$i.d.ts"; done)"

faketsc() { printf '%s\n' "$FAKE"; }
TC_CMD=faketsc

run_case() { # run_case <name> <staged> <program+errors> <want-exit> [excludes]
  local name="$1" want="$4"
  STAGED="$2"; FAKE="$3
$PAD"; TC_EXCLUDES="${5:-}"
  local got=0 out
  out="$(tc_check_project server/tsconfig.json 2>&1)" || got=1
  if [ "$got" = "$want" ]; then ok "$name (exit $got)"; else bad "$name (exit $got, wanted $want)"; printf '%s\n' "$out" | sed 's/^/     /'; fi
}

run_case "covered src file, clean program → pass" \
  "server/src/index.ts" "/repo/server/src/index.ts" 0
run_case "staged src file ABSENT from the program → MUST FAIL" \
  "server/src/ghost.ts" "/repo/server/src/other.ts" 1
run_case "absent but matched by typecheck.exclude → pass" \
  "server/scripts/enrich.ts" "/repo/server/src/index.ts" 0 "server/scripts/*"
run_case "a file outside the project dir is not this project's concern → pass" \
  "web/src/app.ts" "/repo/server/src/index.ts" 0
run_case "a real type error in a covered staged file still fails" \
  "server/src/index.ts" "/repo/server/src/index.ts
src/index.ts(5,1): error TS2304: Cannot find name 'x'." 1
run_case "a type error only in someone else's file → pass (warned)" \
  "server/src/index.ts" "/repo/server/src/index.ts
src/other.ts(5,1): error TS2304: Cannot find name 'x'." 0
run_case "non-TypeScript staged files are ignored" \
  "server/README.md" "/repo/server/src/index.ts" 0

# mutant: drop the coverage check — the "ABSENT from the program" case must then pass
M="$T/mut.sh"; sed 's/if ! grep -qF "\/$file" <<< "$program"; then/if false; then/' "$HOOKS/lib/typecheck-staged.sh" > "$M"
if cmp -s "$M" "$HOOKS/lib/typecheck-staged.sh"; then bad "mutant: sed no longer matches"
else
  # shellcheck disable=SC1090
  . "$M"; STAGED="server/src/ghost.ts"; FAKE="/repo/server/src/other.ts"
  if tc_check_project server/tsconfig.json >/dev/null 2>&1; then ok "mutant without the coverage check is caught by the suite"
  else bad "mutant without the coverage check still fails — the suite does not test coverage"; fi
fi

finish "typecheck-coverage"
