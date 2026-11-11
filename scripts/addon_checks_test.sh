#!/usr/bin/env bash
# Offline checks for scripts/addon_checks.sh: each check must pass a good fake addon and
# catch a broken one. Fixtures live in .check-tmp/ (git ignores it), removed on exit.
#
# Usage: scripts/addon_checks_test.sh
# No -e: each check reports its own result, and a failed one must not stop the rest.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

readonly ROOT="$PWD/.check-tmp/addon-test"
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
# Make a fresh fixture: a small addon, Demo, that passes every check.
# Globals:
#   ROOT (the fixture folder; replaced)
#######################################
good_addon() {
    [[ ! -d "$ROOT" ]] || rm -r "$ROOT"
    mkdir -p "$ROOT/addons/Demo" "$ROOT/scripts"
    printf 'DemoDB\n' >"$ROOT/scripts/allowed-globals.txt"
    printf '## Interface: 16001\n## Title: Demo\n## Version: 1.0.0\n## SavedVariables: DemoDB\n\nDemo.lua\n' \
        >"$ROOT/addons/Demo/Demo.toc"
    printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-11-10\n\n- First.\n' \
        >"$ROOT/addons/Demo/CHANGELOG.md"
    printf 'local Demo = {}\n_G.Demo = Demo\nDemoDB = DemoDB or {}\n' >"$ROOT/addons/Demo/Demo.lua"
    printf '%s\n' 'dofile((arg[0]:match("^(.*)/") or ".") .. "/Demo.lua")' 'assert(Demo)' \
        'io.write("all passed\\n")' >"$ROOT/addons/Demo/demo_test.lua"
}

#######################################
# Make the good addon, plus Demo.Pick, which the test never calls: lines 6, 7 and 9 never run.
# Lines 4 and 10 (each function's end) run when the file loads: that is where luac puts the
# CLOSURE that makes the function.
# Globals:
#   ROOT (the fixture folder; replaced)
#######################################
coverage_addon() {
    good_addon
    printf '%s\n' 'local Demo = {}' 'function Demo.Add(a, b)' '    return a + b' 'end' \
        'function Demo.Pick(x)' '    if x then' '        return 1' '    end' '    return 2' 'end' \
        '_G.Demo = Demo' 'DemoDB = DemoDB or {}' >"$ROOT/addons/Demo/Demo.lua"
    printf '%s\n' 'dofile((arg[0]:match("^(.*)/") or ".") .. "/Demo.lua")' \
        'assert(Demo.Add(1, 2) == 3)' 'io.write("all passed\\n")' >"$ROOT/addons/Demo/demo_test.lua"
}

#######################################
# Run one check of addon_checks.sh on the fixture.
# Globals:
#   ROOT
#   out (set to the check's stdout and stderr)
#   status (set to its exit status)
# Arguments:
#   The check name for addon_checks.sh, such as syntax or all.
#######################################
run_check() {
    out="$(scripts/addon_checks.sh --root "$ROOT" "$1" 2>&1)"
    status=$?
}

good_addon
run_check all
check "good addon passes every check" "$status"

good_addon
printf 'local x = \n' >"$ROOT/addons/Demo/Demo.lua"
run_check syntax
if [[ $status -eq 1 && "$out" == *"addons/Demo/Demo.lua: does not parse"* ]]; then rc=0; else rc=1; fi
check "syntax: broken Lua is caught" "$rc"

good_addon
printf 'local Demo = {}\nfunction Helper() end\nCount = 1\n' >"$ROOT/addons/Demo/Demo.lua"
run_check globals
if [[ $status -eq 1 && "$out" == *"Demo.lua:2: writes global 'Helper'"* \
    && "$out" == *"Demo.lua:3: writes global 'Count'"* ]]; then rc=0; else rc=1; fi
check "globals: stray global writes are caught with lines" "$rc"

good_addon
printf 'Stub = true\n' >>"$ROOT/addons/Demo/demo_test.lua"
run_check globals
check "globals: test files may set stubs" "$status"

good_addon
printf 'Missing.lua\n' >>"$ROOT/addons/Demo/Demo.toc"
run_check toc
if [[ $status -eq 1 && "$out" == *"lists 'Missing.lua', which does not exist"* ]]; then rc=0; else rc=1; fi
check "toc: listed file that is missing is caught" "$rc"

good_addon
printf 'demo_test.lua\n' >>"$ROOT/addons/Demo/Demo.toc"
run_check toc
if [[ $status -eq 1 && "$out" == *"lists test file 'demo_test.lua'"* ]]; then rc=0; else rc=1; fi
check "toc: a test file in the .toc is caught" "$rc"

good_addon
printf 'local unused = 1\n' >"$ROOT/addons/Demo/Extra.lua"
run_check toc
if [[ $status -eq 1 && "$out" == *"Extra.lua: is not listed"* ]]; then rc=0; else rc=1; fi
check "toc: a .lua the game never loads is caught" "$rc"

good_addon
sed -i '/^## Interface/d' "$ROOT/addons/Demo/Demo.toc"
run_check toc
if [[ $status -eq 1 && "$out" == *"has no '## Interface:' number"* ]]; then rc=0; else rc=1; fi
check "toc: missing Interface line is caught" "$rc"

for call in "C_AuctionHouse.PlaceBid(key, 1)" "C_AuctionHouse.PostItem(loc, 1, 1)" \
    "C_AuctionHouse.CancelAuction(id)" "loadstring(text)"; do
    good_addon
    printf 'local function Go()\n    %s\nend\n' "$call" >>"$ROOT/addons/Demo/Demo.lua"
    run_check policy
    if [[ $status -eq 1 && "$out" == *"Demo.lua:5: calls"*"which RULES.md forbids"* ]]; then rc=0; else rc=1; fi
    check "policy: '${call%%(*}' is caught" "$rc"
done

# No place in these addons: swapping a function's environment hides what code does, the debug
# library reaches into other code, and RunMacro plays the character.
for call in "setfenv(1, {})" "getfenv(1)" "debug.sethook()" "RunMacro(1)"; do
    good_addon
    printf 'local function Go()\n    %s\nend\n' "$call" >>"$ROOT/addons/Demo/Demo.lua"
    run_check policy
    if [[ $status -eq 1 && "$out" == *"Demo.lua:5: calls"*"which RULES.md forbids"* ]]; then rc=0; else rc=1; fi
    check "policy: '${call%%(*}' is caught" "$rc"
done

# Sending data out of the game, or changing the player's keybindings, macros or settings, needs
# a "-- reviewed: <why>" note on the same line.
for call in 'C_ChatInfo.SendChatMessage("hi", "SAY")' 'SendChatMessage("hi", "SAY")' \
    'C_ChatInfo.SendAddonMessage("P", "m", "GUILD")' 'C_ChatInfo.SendAddonMessageLogged("P", "m", "GUILD")' \
    'C_BattleNet.SendWhisper(1, "hi")' 'C_BattleNet.SendGameData(1, "P", "m")' 'SetCVar("x", 1)' \
    'C_CVar.SetCVar("x", 1)' 'SetBinding("A")' 'SetBindingClick("A", "B")' 'SaveBindings(1)' \
    'CreateMacro("m", 1, "")' 'EditMacro(1)' 'DeleteMacro(1)'; do
    good_addon
    printf 'local function Go()\n    %s\nend\n' "$call" >>"$ROOT/addons/Demo/Demo.lua"
    run_check policy
    if [[ $status -eq 1 && "$out" == *"Demo.lua:5: calls '${call%%(*}', which needs a '-- reviewed: <why>' note"* ]]; then rc=0; else rc=1; fi
    check "policy: '${call%%(*}' needs a reviewed note" "$rc"
done

good_addon
printf 'local function Go()\n    %s\nend\n' 'C_ChatInfo.SendChatMessage("deal", "GUILD") -- reviewed: the player asked to share a deal' \
    >>"$ROOT/addons/Demo/Demo.lua"
run_check policy
if [[ $status -eq 0 ]]; then rc=0; else rc=1; fi
check "policy: a call with a reviewed note and a reason passes" "$rc"

good_addon
printf 'local function Go()\n    %s\nend\n' 'SetCVar("x", 1) -- reviewed:' >>"$ROOT/addons/Demo/Demo.lua"
run_check policy
if [[ $status -eq 1 && "$out" == *"calls 'SetCVar', which needs"* ]]; then rc=0; else rc=1; fi
check "policy: a reviewed note with no reason does not count" "$rc"

good_addon
printf 'SendChatMessage("fake", "SAY")\nsetfenv(1, {})\n' >>"$ROOT/addons/Demo/demo_test.lua"
run_check policy
if [[ $status -eq 0 ]]; then rc=0; else rc=1; fi
check "policy: test files may fake these calls" "$rc"

# Blizzard's auction window is only read or followed, never changed.
for call in "AuctionHouseFrame:SetDisplayMode(mode)" "AuctionHouseFrame:SetPostItem(loc)" \
    "AuctionHouseFrameSellTab:Click()" "AuctionHouseFrame.SearchBar:SetSearchText(text)"; do
    good_addon
    printf 'local function Go()\n    %s\nend\n' "$call" >>"$ROOT/addons/Demo/Demo.lua"
    run_check policy
    if [[ $status -eq 1 && "$out" == *"Demo.lua:5: changes Blizzard's auction window"* ]]; then rc=0; else rc=1; fi
    check "policy: '${call%%(*}' is caught" "$rc"
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
if [[ $status -eq 0 ]]; then rc=0; else rc=1; fi
check "policy: reading, anchoring to and hooking Blizzard's auction window pass" "$rc"

# Each addon is versioned on its own: semver in the .toc, with a CHANGELOG.md section.
good_addon
sed -i '/^## Version/d' "$ROOT/addons/Demo/Demo.toc"
run_check version
if [[ $status -eq 1 && "$out" == *"Demo.toc: has no '## Version: X.Y.Z' line"* ]]; then rc=0; else rc=1; fi
check "version: missing Version line is caught" "$rc"

for bad in 1.0 1.0.0.0 v1.0.0 01.0.0 1.0.0-beta; do
    good_addon
    sed -i "s/^## Version: .*/## Version: $bad/" "$ROOT/addons/Demo/Demo.toc"
    run_check version
    if [[ $status -eq 1 && "$out" == *"Demo.toc: version '$bad' is not X.Y.Z"* ]]; then rc=0; else rc=1; fi
    check "version: '$bad' is caught" "$rc"
done

good_addon
rm "$ROOT/addons/Demo/CHANGELOG.md"
run_check version
if [[ $status -eq 1 && "$out" == *"addons/Demo: has no CHANGELOG.md"* ]]; then rc=0; else rc=1; fi
check "version: missing CHANGELOG.md is caught" "$rc"

good_addon
sed -i 's/^## Version: .*/## Version: 1.1.0/' "$ROOT/addons/Demo/Demo.toc"
run_check version
if [[ $status -eq 1 && "$out" == *"CHANGELOG.md: has no '## [1.1.0]' section for the .toc version"* ]]; then rc=0; else rc=1; fi
check "version: .toc version with no changelog section is caught" "$rc"

good_addon
printf '\n## [1.0.0]x\n' >>"$ROOT/addons/Demo/CHANGELOG.md"
sed -i 's/^## \[1.0.0\] - 2026-11-10$/## [1.0.0]/' "$ROOT/addons/Demo/CHANGELOG.md"
run_check version
check "version: a bare '## [X.Y.Z]' heading counts" "$status"

# Coverage: the tests must run at least COVERAGE_MIN percent (default 90) of the lines in each
# addon file. Lines that can run come from luac's listing.
coverage_addon
COVERAGE_MIN=0 run_check coverage
if [[ $status -eq 0 && "$out" == *"addons/Demo/Demo.lua: 72.7% of 11 lines run; not run: 6-7, 9"* ]]; then rc=0; else rc=1; fi
check "coverage: reports the percent and the lines that never ran" "$rc"

coverage_addon
COVERAGE_MIN=90 run_check coverage
if [[ $status -eq 1 && "$out" == *"Demo.lua: 72.7% of lines run, below the 90% minimum"* ]]; then rc=0; else rc=1; fi
check "coverage: a file under the minimum fails" "$rc"

coverage_addon
run_check coverage
if [[ $status -eq 1 && "$out" == *"below the 90% minimum"* ]]; then rc=0; else rc=1; fi
check "coverage: the minimum is 90% by default" "$rc"

coverage_addon
printf '%s\n' 'assert(Demo.Pick(true) == 1 and Demo.Pick(false) == 2)' 'os.exit(0)' \
    >>"$ROOT/addons/Demo/demo_test.lua"
COVERAGE_MIN=100 run_check coverage
if [[ $status -eq 0 && "$out" == *"Demo.lua: 100.0% of 11 lines run"* ]]; then rc=0; else rc=1; fi
check "coverage: lines run before os.exit count" "$rc"

coverage_addon
if [[ "$out" != *"demo_test.lua:"*"lines run"* ]]; then rc=0; else rc=1; fi
check "coverage: test files themselves are not measured" "$rc"

coverage_addon
printf 'error("boom")\n' >>"$ROOT/addons/Demo/demo_test.lua"
COVERAGE_MIN=0 run_check coverage
if [[ $status -eq 1 && "$out" == *"demo_test.lua: failed"* ]]; then rc=0; else rc=1; fi
check "coverage: a failing test still fails" "$rc"

good_addon
printf 'error("boom")\n' >"$ROOT/addons/Demo/demo_test.lua"
run_check tests
if [[ $status -eq 1 && "$out" == *"demo_test.lua: failed"* ]]; then rc=0; else rc=1; fi
check "tests: a failing test file fails the check" "$rc"

good_addon
rm "$ROOT/addons/Demo/demo_test.lua"
run_check tests
if [[ $status -eq 1 && "$out" == *"addons/Demo: has no *_test.lua"* ]]; then rc=0; else rc=1; fi
check "tests: an addon with no tests fails the check" "$rc"

if [[ $failed -gt 0 ]]; then
    printf '%d failed\n' "$failed"
    exit 1
fi
echo "all passed"
