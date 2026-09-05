#!/usr/bin/env bash
#
# Run every test suite. Exit 0 only if all of them pass.
#
# The whole suite is offline by design: a fake `curl` on PATH records the argv
# and answers from a fixture, so it runs in about the time one real request
# would take, and it works on a plane, in CI, and with no Bitbucket token.
#
#   tests/run.sh              all suites
#   tests/run.sh api          only suites whose name matches "api"
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.."

filter="${1:-}"
suites=()
for f in tests/*_test.sh; do
    [[ -f "$f" ]] || continue
    [[ -z "$filter" || "$f" == *"$filter"* ]] && suites+=("$f")
done

if [[ ${#suites[@]} -eq 0 ]]; then
    echo "No test suites matched '${filter}'" >&2
    exit 1
fi

# bash -n on the CLI first: a syntax error makes every other failure noise.
if ! bash -n bin/bb-cli; then
    echo "bin/bb-cli does not parse" >&2
    exit 1
fi
echo "bin/bb-cli parses"
echo ""

failed_suites=()
for suite in "${suites[@]}"; do
    if "$suite"; then
        :
    else
        failed_suites+=("$suite")
    fi
    echo ""
done

echo "════════════════════════════════════════════════════════════"
if [[ ${#failed_suites[@]} -eq 0 ]]; then
    echo "all ${#suites[@]} suites passed"
    exit 0
fi

echo "FAILED: ${failed_suites[*]}"
exit 1
