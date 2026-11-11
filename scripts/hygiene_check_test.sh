#!/usr/bin/env bash
# Offline checks for scripts/hygiene_check.sh on small synthetic files.
# Fixtures live in .check-tmp/ (git ignores it), removed on exit.
#
# Usage: scripts/hygiene_check_test.sh
# No -e: each check reports its own result, and a failed one must not stop the rest.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

readonly ROOT="$PWD/.check-tmp/hygiene-test"
failed=0

#######################################
# Remove the fixtures folder, .check-tmp/, if it exists. Runs on exit.
# Globals:
#   PWD (the repo root, after the cd above)
#######################################
cleanup() { [[ ! -d "$PWD/.check-tmp" ]] || rm -r "$PWD/.check-tmp"; }
trap cleanup EXIT

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

#######################################
# Make a fresh fixture with one clean file.
# Globals:
#   ROOT (the fixture folder; replaced)
#######################################
fresh() {
    [[ ! -d "$ROOT" ]] || rm -r "$ROOT"
    mkdir -p "$ROOT"
    printf 'clean line\n' >"$ROOT/clean.txt"
}

#######################################
# Run hygiene_check.sh on the fixture, listing files with find.
# Globals:
#   ROOT
#   out (set to the check's stdout and stderr)
#   status (set to its exit status)
#######################################
run_check() {
    out="$(HYGIENE_NO_GIT=1 scripts/hygiene_check.sh --root "$ROOT" 2>&1)"
    status=$?
}

fresh
run_check
check "clean file passes" "$status"

fresh
printf 'ok\nspace at end \n' >"$ROOT/a.txt"
run_check
if [[ $status -eq 1 && "$out" == *"a.txt:2: trailing whitespace"* ]]; then rc=0; else rc=1; fi
check "trailing whitespace is caught with its line" "$rc"

fresh
printf 'no newline' >"$ROOT/b.txt"
run_check
if [[ $status -eq 1 && "$out" == *"b.txt: does not end with a newline"* ]]; then rc=0; else rc=1; fi
check "missing final newline is caught" "$rc"

fresh
printf 'one\r\ntwo\r\n' >"$ROOT/c.txt"
run_check
if [[ $status -eq 1 && "$out" == *"c.txt: has Windows (CRLF) line endings"* ]]; then rc=0; else rc=1; fi
check "Windows line endings are caught" "$rc"

fresh
printf 'a\n%s HEAD\nb\n' "<<<<<<<" >"$ROOT/d.txt"
run_check
if [[ $status -eq 1 && "$out" == *"d.txt:2: merge-conflict marker"* ]]; then rc=0; else rc=1; fi
check "merge-conflict marker is caught" "$rc"

fresh
head -c 600000 /dev/zero | tr '\0' 'a' >"$ROOT/e.txt"
printf '\n' >>"$ROOT/e.txt"
run_check
if [[ $status -eq 1 && "$out" == *"e.txt: is 585 KB (limit 500 KB)"* ]]; then rc=0; else rc=1; fi
check "file over 500 KB is caught" "$rc"

if [[ $failed -gt 0 ]]; then
    printf '%d failed\n' "$failed"
    exit 1
fi
echo "all passed"
