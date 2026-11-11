#!/usr/bin/env bash
# Offline checks for scripts/addon_checks.sh: each check must pass a good fake addon and
# catch a broken one. Fixtures live in .check-tmp/ (git ignores it), removed on exit.
#
# Usage: scripts/addon_checks_test.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

readonly ROOT="$PWD/.check-tmp/addon-test"
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

# A small addon that passes every check.
good_addon() {
    [[ ! -d "$ROOT" ]] || rm -r "$ROOT"
    mkdir -p "$ROOT/addons/Demo" "$ROOT/scripts"
    printf 'DemoDB\n' >"$ROOT/scripts/allowed-globals.txt"
    printf '## Interface: 16001\n## Title: Demo\n## SavedVariables: DemoDB\n\nDemo.lua\n' \
        >"$ROOT/addons/Demo/Demo.toc"
    printf 'local Demo = {}\n_G.Demo = Demo\nDemoDB = DemoDB or {}\n' >"$ROOT/addons/Demo/Demo.lua"
    printf 'assert(1 + 1 == 2)\nio.write("all passed\\n")\n' >"$ROOT/addons/Demo/demo_test.lua"
}

# Run one check on the fixture. Sets out and status.
# Args:
#   $1  check name for addon_checks.sh
run_check() {
    set +e
    out="$(scripts/addon_checks.sh --root "$ROOT" "$1" 2>&1)"
    status=$?
    set -e
}

good_addon
run_check all
check "good addon passes every check" "$status"

good_addon
printf 'local x = \n' >"$ROOT/addons/Demo/Demo.lua"
run_check syntax
[[ $status -eq 1 && "$out" == *"addons/Demo/Demo.lua: does not parse"* ]]
check "syntax: broken Lua is caught" $?

good_addon
printf 'local Demo = {}\nfunction Helper() end\nCount = 1\n' >"$ROOT/addons/Demo/Demo.lua"
run_check globals
[[ $status -eq 1 && "$out" == *"Demo.lua:2: writes global 'Helper'"* \
    && "$out" == *"Demo.lua:3: writes global 'Count'"* ]]
check "globals: stray global writes are caught with lines" $?

good_addon
printf 'Stub = true\n' >>"$ROOT/addons/Demo/demo_test.lua"
run_check globals
check "globals: test files may set stubs" "$status"

good_addon
printf 'Missing.lua\n' >>"$ROOT/addons/Demo/Demo.toc"
run_check toc
[[ $status -eq 1 && "$out" == *"lists 'Missing.lua', which does not exist"* ]]
check "toc: listed file that is missing is caught" $?

good_addon
printf 'demo_test.lua\n' >>"$ROOT/addons/Demo/Demo.toc"
run_check toc
[[ $status -eq 1 && "$out" == *"lists test file 'demo_test.lua'"* ]]
check "toc: a test file in the .toc is caught" $?

good_addon
printf 'local unused = 1\n' >"$ROOT/addons/Demo/Extra.lua"
run_check toc
[[ $status -eq 1 && "$out" == *"Extra.lua: is not listed"* ]]
check "toc: a .lua the game never loads is caught" $?

good_addon
sed -i '/^## Interface/d' "$ROOT/addons/Demo/Demo.toc"
run_check toc
[[ $status -eq 1 && "$out" == *"has no '## Interface:' number"* ]]
check "toc: missing Interface line is caught" $?

for call in "C_AuctionHouse.PlaceBid(key, 1)" "C_AuctionHouse.PostItem(loc, 1, 1)" \
    "C_AuctionHouse.CancelAuction(id)" "loadstring(text)"; do
    good_addon
    printf 'local function Go()\n    %s\nend\n' "$call" >>"$ROOT/addons/Demo/Demo.lua"
    run_check policy
    [[ $status -eq 1 && "$out" == *"Demo.lua:5: calls"*"which RULES.md forbids"* ]]
    check "policy: '${call%%(*}' is caught" $?
done

# Blizzard's auction window is only read or followed, never changed.
for call in "AuctionHouseFrame:SetDisplayMode(mode)" "AuctionHouseFrame:SetPostItem(loc)" \
    "AuctionHouseFrameSellTab:Click()" "AuctionHouseFrame.SearchBar:SetSearchText(text)"; do
    good_addon
    printf 'local function Go()\n    %s\nend\n' "$call" >>"$ROOT/addons/Demo/Demo.lua"
    run_check policy
    [[ $status -eq 1 && "$out" == *"Demo.lua:5: changes Blizzard's auction window"* ]]
    check "policy: '${call%%(*}' is caught" $?
done

good_addon
printf '%s\n' 'local function Go(frame)' \
    '    local open = AuctionHouseFrame and AuctionHouseFrame:IsShown()' \
    '    local right = AuctionHouseFrame:GetRight()' \
    '    frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)' \
    '    hooksecurefunc(AuctionHouseFrame, "SetPostItem", Go)' \
    '    return open, right' \
    'end' >>"$ROOT/addons/Demo/Demo.lua"
run_check policy
[[ $status -eq 0 ]]
check "policy: reading, anchoring to and hooking Blizzard's auction window pass" $?

good_addon
printf 'error("boom")\n' >"$ROOT/addons/Demo/demo_test.lua"
run_check tests
[[ $status -eq 1 && "$out" == *"demo_test.lua: failed"* ]]
check "tests: a failing test file fails the check" $?

good_addon
rm "$ROOT/addons/Demo/demo_test.lua"
run_check tests
[[ $status -eq 1 && "$out" == *"addons/Demo: has no *_test.lua"* ]]
check "tests: an addon with no tests fails the check" $?

if [[ $failed -gt 0 ]]; then
    printf '%d failed\n' "$failed"
    exit 1
fi
echo "all passed"
