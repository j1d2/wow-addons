#!/usr/bin/env bash
# Every gate, in order. The git hooks and CI run exactly this; run it yourself before pushing.
#
#   1. tools      lua5.1, luac5.1, shellcheck, zip and unzip are installed
#   2. hygiene    whitespace, final newline, line endings, conflict markers, file size
#   3. privacy    no personal or machine details, no secrets (scripts/privacy_scan.sh)
#   4. shellcheck every script and hook (following sourced files, -x)
#   5. self-tests the check scripts' own tests
#   6. addons     Lua syntax, global writes, .toc files, RULES.md API limits, versions
#   7. tests      every addons/*/*_test.lua under lua5.1
#   8. coverage   those tests run at least 90% of the lines in each addon file
#
# Usage: scripts/check.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

#######################################
# Print a step heading.
# Arguments:
#   The step's name, as one or more words.
# Outputs:
#   Writes a blank line and "==> name" to stdout.
#######################################
step() { printf '\n==> %s\n' "$*"; }

step "tools"
missing=0
for tool in "${LUA:-lua5.1}" "${LUAC:-luac5.1}" shellcheck zip unzip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "missing tool: $tool (install it with the system package manager)" >&2
        missing=1
    fi
done
[[ $missing -eq 0 ]] || exit 1
echo "lua5.1, luac5.1, shellcheck, zip and unzip found."

step "hygiene"
scripts/hygiene_check.sh

step "privacy and secret scan"
scripts/privacy_scan.sh

step "shellcheck"
shellcheck --severity=style -x scripts/*.sh .githooks/*
echo "shellcheck passed."

step "check-script self-tests"
# On success print the last line; on failure print every FAIL line, so CI and the hooks name
# the broken checks instead of only the count.
for test in scripts/*_test.sh; do
    printf '%s: ' "$test"
    if out="$("$test" 2>&1)"; then
        tail -n 1 <<<"$out"
    else
        echo "failed"
        grep -E '^FAIL' <<<"$out" || printf '%s\n' "$out"
        exit 1
    fi
done

step "addon checks: syntax, globals, toc, policy, version"
for check in syntax globals toc policy version; do
    scripts/addon_checks.sh "$check"
    printf '%s passed.\n' "$check"
done

step "addon tests (lua5.1)"
scripts/addon_checks.sh tests

step "line coverage (at least ${COVERAGE_MIN:-90}% of each addon file)"
scripts/addon_checks.sh coverage

printf '\nAll checks passed.\n'
