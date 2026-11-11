#!/usr/bin/env bash
# File hygiene for every tracked or new (not ignored) text file: no trailing whitespace, a final
# newline, Unix line endings, no merge-conflict markers, and nothing over 500 KB.
# Our own version of the usual pre-commit-hooks checks, so no package is needed.
#
# Usage: scripts/hygiene_check.sh [--root DIR]
# Environment: HYGIENE_NO_GIT=1 lists files with find instead of git (snapshots and tests)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "--root" ]]; then
    ROOT="$(cd "$2" && pwd)"
fi
cd "$ROOT"

readonly MAX_KB=500
failures=0

#######################################
# Report one problem and count it.
# Globals:
#   failures (incremented)
# Arguments:
#   Where: "file" or "file:line".
#   What is wrong.
# Outputs:
#   Writes "where: what" to stdout.
#######################################
problem() {
    printf '%s: %s\n' "$1" "$2"
    failures=$((failures + 1))
}

#######################################
# List the repo's files: git's list in a work tree, otherwise everything but .git.
# Globals:
#   HYGIENE_NO_GIT (1 = always use find)
# Outputs:
#   Writes the paths, relative to the current folder and NUL separated, to stdout.
#######################################
list_files() {
    if [[ "${HYGIENE_NO_GIT:-0}" != 1 ]] \
        && [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == true ]]; then
        git ls-files -z --cached --others --exclude-standard
    else
        find . -type f -not -path './.git/*' -printf '%P\0'
    fi
}

while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    size_kb=$(( $(wc -c <"$file") / 1024 ))
    [[ $size_kb -le $MAX_KB ]] || problem "$file" "is ${size_kb} KB (limit ${MAX_KB} KB)"
    # Binary files (images and such) only get the size check.
    grep -I -q '' "$file" 2>/dev/null || continue
    if grep -q $'\r' "$file"; then
        problem "$file" "has Windows (CRLF) line endings"
    fi
    while IFS= read -r line; do
        problem "$file:$line" "trailing whitespace"
    done < <(grep -n -E '[[:blank:]]+$' "$file" | cut -d: -f1)
    while IFS= read -r line; do
        problem "$file:$line" "merge-conflict marker"
    done < <(grep -n -E '^(<<<<<<<|>>>>>>>) ' "$file" | cut -d: -f1)
    if [[ -s "$file" && "$(tail -c 1 "$file" | od -An -c | tr -d ' ')" != '\n' ]]; then
        problem "$file" "does not end with a newline"
    fi
done < <(list_files)

if [[ $failures -gt 0 ]]; then
    printf '%d problem(s) found.\n' "$failures" >&2
    exit 1
fi
echo "Hygiene check passed."
