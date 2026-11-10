#!/usr/bin/env bash
# Run every test suite. Exit 0 only if all pass.  Usage: ./test/run.sh [suite-name…]
set -uo pipefail
cd "$(dirname "$0")" || exit 1
command -v node >/dev/null 2>&1 || { echo "node (>= 18) is required to run the tests" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required to run the tests" >&2; exit 1; }
suites=("$@")
if [ ${#suites[@]} -eq 0 ]; then
  for f in ./*.test.sh; do suites+=("$(basename "$f" .test.sh)"); done
fi
failed=()
for s in "${suites[@]}"; do
  echo "━━ $s"
  if ! bash "./$s.test.sh"; then failed+=("$s"); fi
  echo
done
if [ ${#failed[@]} -gt 0 ]; then echo "FAILED: ${failed[*]}"; exit 1; fi
echo "all ${#suites[@]} suites passed"
