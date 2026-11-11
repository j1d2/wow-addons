#!/usr/bin/env bash
# Point this clone's git at the repo's hooks in .githooks/ (pre-commit, commit-msg, pre-push).
# Run once per clone. Undo with: git config --unset core.hooksPath
#
# Usage: scripts/install_hooks.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

for hook in .githooks/*; do
    if [[ ! -x "$hook" ]]; then
        echo "$hook is not executable; git would skip it" >&2
        exit 1
    fi
done

git config core.hooksPath .githooks
echo "Hooks installed: git now runs .githooks/ (pre-commit, commit-msg, pre-push)."
echo "Run the gate by hand any time: scripts/check.sh"
