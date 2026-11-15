#!/usr/bin/env bash
# Offline checks for scripts/bench.sh: the smoke run passes on today's code, a budget that is
# too small is caught, and the synthetic data gives the same memory numbers on every run.
#
# Usage: scripts/bench_test.sh
# No -e: each check reports its own result, and a failed one must not stop the rest.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

failed=0

#######################################
# Record one result.
# Globals:
#   failed (incremented on a failure)
# Arguments:
#   The check's name.
#   Its status: 0 = passed, anything else = failed.
# Outputs:
#   Writes "ok  name" or "FAIL  name" to stdout.
#######################################
check() {
    if [[ "$2" -eq 0 ]]; then
        printf 'ok  %s\n' "$1"
    else
        printf 'FAIL  %s\n' "$1"
        failed=$((failed + 1))
    fi
}

out="$(scripts/bench.sh --smoke 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == *"Market"* && "$out" == *"Stats, every item"* \
    && "$out" == *"SortHistory"* && "$out" == *"within budget"* ]]; then rc=0; else rc=1; fi
check "the smoke run passes and names each measured step" "$rc"

out="$(BENCH_BUDGET_SCALE=0.000001 scripts/bench.sh --smoke 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == *"over budget"* ]]; then rc=0; else rc=1; fi
check "a step over its budget fails the smoke run" "$rc"

first="$(scripts/bench.sh --smoke 2>&1 | grep -E '^memory')"
second="$(scripts/bench.sh --smoke 2>&1 | grep -E '^memory')"
if [[ -n "$first" && "$first" == "$second" ]]; then rc=0; else rc=1; fi
check "the synthetic data gives the same memory numbers every run" "$rc"

out="$(scripts/bench.sh --nope 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == *"usage:"* ]]; then rc=0; else rc=1; fi
check "an unknown option prints the usage and exits 2" "$rc"

if [[ $failed -gt 0 ]]; then
    printf '%d failed\n' "$failed"
    exit 1
fi
echo "all passed"
