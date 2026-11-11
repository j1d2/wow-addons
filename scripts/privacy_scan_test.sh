#!/usr/bin/env bash
# Offline checks for scripts/privacy_scan.sh, on small synthetic files.
#
# Fake identifiers are assembled at run time ("ho""me" and so on), so this file never holds a
# string the scanner would flag. Fixtures live in .check-tmp/ (git ignores it), removed on exit.
#
# Usage: scripts/privacy_scan_test.sh
# No -e: each check reports its own result, and a failed one must not stop the rest.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

readonly ROOT="$PWD/.check-tmp/privacy-test"
failed=0

cleanup() { [[ ! -d "$PWD/.check-tmp" ]] || rm -r "$PWD/.check-tmp"; }
trap cleanup EXIT

# Record one result.
# Args:
#   $1  check name
#   $2  0 = passed, anything else = failed
check() {
    if [[ "$2" -eq 0 ]]; then
        printf 'ok  %s\n' "$1"
    else
        printf 'FAIL  %s\n' "$1"
        failed=$((failed + 1))
    fi
}

# Make an empty fixture repo holding a copy of the scanner. Echoes nothing.
fresh_fixture() {
    [[ ! -d "$ROOT" ]] || rm -r "$ROOT"
    mkdir -p "$ROOT/scripts" "$ROOT/security"
    cp scripts/privacy_scan.sh "$ROOT/scripts/"
}

# Run the fixture's scanner. Sets scan_out and scan_status.
run_scan() {
    scan_out="$(PRIVACY_SCAN_NO_GIT=1 PRIVACY_DENYLIST="$ROOT/security/privacy-denylist.local" \
        "$ROOT/scripts/privacy_scan.sh" "$@" 2>&1)"
    scan_status=$?
}

home_dir="/ho""me/someone/Games"
mount_dir="/m""nt/disk/projects"
wine_dir="drive""_c/Program Files"
account_dir="WTF/Acc""ount/ABC123/SavedVariables"
person_mail="someone""@mail.test.org"
example_mail="you""@example.com"
github_token="gh""p_$(printf 'a%.0s' {1..36})"
private_key="-----BEGIN ""RSA PRIVATE KEY-----"
lan_ip="192.""168.1.20"
fake_name="Zyx""quortan"

fresh_fixture
printf 'Install to <WoW folder>/_forever_/Interface/AddOns.\nVersion 10.2.6 and 1.60.1.\n' \
    >"$ROOT/clean.md"
printf 'Ask %s.\n' "$example_mail" >>"$ROOT/clean.md"
run_scan
check "clean files with placeholders pass" "$scan_status"

for label in "home folder path:$home_dir" "mount path:$mount_dir" "Wine prefix path:$wine_dir" \
    "WoW account folder:$account_dir" "email address:$person_mail" "GitHub token:$github_token" \
    "private key:$private_key" "private IP address:$lan_ip"; do
    rule="${label%%:*}"
    value="${label#*:}"
    fresh_fixture
    printf 'line one\nsee %s here\n' "$value" >"$ROOT/leak.txt"
    run_scan
    if [[ $scan_status -eq 1 && "$scan_out" == *"leak.txt:2: $rule"* ]]; then rc=0; else rc=1; fi
    check "flags $rule with file and line" "$rc"
    if [[ "$scan_out" != *"$value"* ]]; then rc=0; else rc=1; fi
    check "report hides the $rule itself" "$rc"
done

fresh_fixture
printf 'Main is %s.\n' "$fake_name" >"$ROOT/notes.md"
run_scan
check "name passes with no denylist" "$scan_status"
printf '# real names, one per line\n%s\n' "${fake_name,,}" >"$ROOT/security/privacy-denylist.local"
run_scan
if [[ $scan_status -eq 1 && "$scan_out" == *"notes.md:1: local denylist entry"* ]]; then rc=0; else rc=1; fi
check "denylist entry is flagged, any case" "$rc"
if [[ "$scan_out" != *"$fake_name"* ]]; then rc=0; else rc=1; fi
check "report hides the denylist entry" "$rc"

fresh_fixture
printf 'fix: tidy\n\nPath was %s.\n' "$home_dir" >"$ROOT/msg.txt"
run_scan --text "$ROOT/msg.txt"
if [[ $scan_status -eq 1 && "$scan_out" == *"msg.txt:3: home folder path"* ]]; then rc=0; else rc=1; fi
check "--text scans one file, such as a commit message" "$rc"

if [[ $failed -gt 0 ]]; then
    printf '%d failed\n' "$failed"
    exit 1
fi
echo "all passed"
