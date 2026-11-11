#!/usr/bin/env bash
# Offline checks for scripts/package_addon.sh: a good tag builds the expected zip and release
# notes, and every mismatch between the tag, the .toc version and CHANGELOG.md stops it.
# Fixtures live in .check-tmp/ (git ignores it), removed on exit.
#
# Usage: scripts/package_addon_test.sh
# No -e: each check reports its own result, and a failed one must not stop the rest.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

readonly ROOT="$PWD/.check-tmp/package-test"
readonly OUT="$ROOT/dist"
failed=0

cleanup() { [[ ! -d "$PWD/.check-tmp" ]] || rm -r "$PWD/.check-tmp"; }
trap cleanup EXIT

#######################################
# Record one result.
# Globals:
#   failed (counts failures)
# Arguments:
#   Check name.
#   0 if it passed, anything else if it failed.
# Outputs:
#   Writes "ok  <name>" or "FAIL  <name>" to stdout.
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
# Build a small repo with one addon, Demo 1.2.3: a file in a subfolder, a test file and a
# changelog with two versions. Replaces any earlier fixture.
# Globals:
#   ROOT
#######################################
good_repo() {
    [[ ! -d "$ROOT" ]] || rm -r "$ROOT"
    mkdir -p "$ROOT/addons/Demo/ui"
    printf 'license text\n' >"$ROOT/LICENSE"
    printf 'notice text\n' >"$ROOT/NOTICE"
    printf '## Interface: 16001\n## Title: Demo\n## Version: 1.2.3\n\nDemo.lua\nui\\Window.lua\n' \
        >"$ROOT/addons/Demo/Demo.toc"
    printf 'local Demo = {}\n' >"$ROOT/addons/Demo/Demo.lua"
    printf 'local Window = {}\n' >"$ROOT/addons/Demo/ui/Window.lua"
    printf 'assert(true)\n' >"$ROOT/addons/Demo/demo_test.lua"
    cat >"$ROOT/addons/Demo/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [1.2.3] - 2026-11-10

### Added

- New thing in 1.2.3.

## [1.2.2] - 2026-11-01

### Fixed

- Old fix in 1.2.2.
EOF
}

#######################################
# Run the packager on the fixture.
# Globals:
#   ROOT, OUT
#   out, status (set to the packager's output and exit status)
# Arguments:
#   Release tag.
#######################################
package() {
    out="$(scripts/package_addon.sh --root "$ROOT" "$1" "$OUT" 2>&1)"
    status=$?
}

good_repo
package Demo-v1.2.3
check "good tag builds" "$status"
if [[ -f "$OUT/Demo-1.2.3.zip" ]]; then rc=0; else rc=1; fi
check "zip is named <Addon>-<version>.zip" "$rc"

listing="$(unzip -Z1 "$OUT/Demo-1.2.3.zip" 2>/dev/null | LC_ALL=C sort || true)"
expected="$(printf '%s\n' Demo/CHANGELOG.md Demo/Demo.lua Demo/Demo.toc Demo/LICENSE \
    Demo/NOTICE Demo/ui/Window.lua | LC_ALL=C sort)"
if [[ "$listing" == "$expected" ]]; then rc=0; else rc=1; fi
check "zip holds the addon folder: .toc, listed files, CHANGELOG, LICENSE, NOTICE" "$rc"
if [[ -n "$listing" && "$listing" != *"_test.lua"* ]]; then rc=0; else rc=1; fi
check "zip leaves out test files" "$rc"

notes="$(cat "$OUT/notes.md" 2>/dev/null || true)"
if [[ "$notes" == *"New thing in 1.2.3."* && "$notes" != *"Old fix in 1.2.2."* \
    && "$notes" != *"## [1.2.3]"* ]]; then rc=0; else rc=1; fi
check "notes hold only this version's changelog section" "$rc"

first="$(sha256sum "$OUT/Demo-1.2.3.zip" 2>/dev/null | cut -d' ' -f1 || true)"
[[ ! -d "$OUT" ]] || rm -r "$OUT"
touch "$ROOT/addons/Demo/Demo.lua"
SOURCE_DATE_EPOCH=1700000000 package Demo-v1.2.3
second="$(sha256sum "$OUT/Demo-1.2.3.zip" 2>/dev/null | cut -d' ' -f1 || true)"
[[ ! -d "$OUT" ]] || rm -r "$OUT"
touch -d '2001-01-01' "$ROOT/addons/Demo/Demo.lua"
SOURCE_DATE_EPOCH=1700000000 package Demo-v1.2.3
third="$(sha256sum "$OUT/Demo-1.2.3.zip" 2>/dev/null | cut -d' ' -f1 || true)"
if [[ -n "$second" && "$second" == "$third" && -n "$first" ]]; then rc=0; else rc=1; fi
check "same SOURCE_DATE_EPOCH gives the same zip, whatever the file times" "$rc"

good_repo
package Demo-v1.2.4
if [[ $status -ne 0 && "$out" == *"Demo.toc says 1.2.3"* && ! -f "$OUT/Demo-1.2.4.zip" ]]; then rc=0; else rc=1; fi
check "tag version that differs from the .toc is refused" "$rc"

good_repo
sed -i 's/^## \[1.2.3\].*/## [Unreleased-old]/' "$ROOT/addons/Demo/CHANGELOG.md"
package Demo-v1.2.3
if [[ $status -ne 0 && "$out" == *"no '## [1.2.3]' section"* ]]; then rc=0; else rc=1; fi
check "version with no changelog section is refused" "$rc"

good_repo
package Nope-v1.0.0
if [[ $status -ne 0 && "$out" == *"no addon folder"* ]]; then rc=0; else rc=1; fi
check "tag for an unknown addon is refused" "$rc"

good_repo
for bad in Demo-1.2.3 Demo-v1.2 Demo-v1.2.3.4 v1.2.3 'Demo-v1.2.3;x'; do
    package "$bad"
    if [[ $status -ne 0 && "$out" == *"not a release tag"* ]]; then rc=0; else rc=1; fi
    check "malformed tag '$bad' is refused" "$rc"
done

if [[ $failed -gt 0 ]]; then
    printf '%d package test(s) failed.\n' "$failed" >&2
    exit 1
fi
echo "all passed"
