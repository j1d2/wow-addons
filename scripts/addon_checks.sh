#!/usr/bin/env bash
# Checks for every addon under addons/. Plain bash plus the Lua 5.1 tools, no packages.
#
#   syntax   every .lua parses (luac5.1 -p)
#   globals  addon files only write globals listed in scripts/allowed-globals.txt
#            (reads luac's SETGLOBAL listing, the core idea of luacheck, without the package)
#   toc      each addon has a .toc with ## Interface, every listed file exists, test files are
#            never listed, and every non-test .lua is listed
#   policy   no call to an API that RULES.md forbids (post, buy, bid, cancel, run code from text,
#            setfenv/getfenv, debug, RunMacro); chat, addon messages and setting changes only
#            with a "-- reviewed: <why>" note; no change to Blizzard's auction window
#   version  each addon's <Name>.toc has a "## Version: X.Y.Z" (semver), and its CHANGELOG.md
#            has a "## [X.Y.Z]" section for it, so every release has notes
#   tests    each addon has at least one *_test.lua, and all of them pass under lua5.1
#   coverage the tests run at least COVERAGE_MIN percent (default 90) of the lines in each
#            addon file (scripts/lua_coverage.lua: Lua's own line hook, no packages)
#
# Usage: scripts/addon_checks.sh [--root DIR] <syntax|globals|toc|policy|version|tests|coverage|all>
# Environment: LUA (default lua5.1), LUAC (default luac5.1), COVERAGE_MIN (default 90)
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPTS")"
LUA="${LUA:-lua5.1}"
LUAC="${LUAC:-luac5.1}"

if [[ "${1:-}" == "--root" ]]; then
    ROOT="$(cd "$2" && pwd)"
    shift 2
fi

ALLOWED_GLOBALS="$ROOT/scripts/allowed-globals.txt"

# RULES.md: never post, buy, bid or cancel, and no code run from text (it hides what runs).
# Also never: swapping a function's environment (setfenv, getfenv) hides what code does, the
# debug library reaches into other code, and RunMacro plays the character.
readonly BANNED_API='C_AuctionHouse\.(PostItem|PostCommodity|PlaceBid|CancelAuction|CancelSell|StartCommoditiesPurchase|ConfirmCommoditiesPurchase)|\b(PlaceAuctionBid|PostAuction|StartAuction|CancelAuction|loadstring|RunScript|RunMacroText|RunMacro|setfenv|getfenv)\b|\bdebug\.[A-Za-z_]+'

# RULES.md: calls that send data out of the game (chat, addon messages, Battle.net) or change
# the player's setup (keybindings, macros, settings) need a "-- reviewed: <why>" note on the
# same line. Names checked against Blizzard's interface source for the Forever client.
readonly REVIEW_API='(C_ChatInfo\.(SendChatMessage|SendAddonMessage|SendAddonMessageLogged)|C_BattleNet\.(SendWhisper|SendGameData)|C_CVar\.SetCVar|(^|[^A-Za-z0-9_.:])(SendChatMessage|SendAddonMessage|SetCVar|SetBinding|SetBindingClick|SaveBindings|CreateMacro|EditMacro|DeleteMacro))[[:space:]]*\('
readonly REVIEW_NOTE='--[[:space:]]*reviewed:[[:space:]]*[^[:space:]]'

# RULES.md: Blizzard's auction window is read or followed (hooksecurefunc), never
# changed. A method call on it or on one of its parts (AuctionHouseFrame.SearchBar,
# AuctionHouseFrameSellTab) is flagged unless it only reads.
readonly HOUSE_CALL='AuctionHouseFrame[A-Za-z0-9_.]*:[A-Za-z_]+'
readonly HOUSE_READS=':(IsShown|IsVisible|GetRight|GetLeft|GetTop|GetBottom|GetWidth|GetHeight|GetDisplayMode|GetItem)$'

# MAJOR.MINOR.PATCH with no leading zeros, the form release tags use (see package_addon.sh).
readonly SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

failures=0

#######################################
# Report one problem and count it.
# Globals:
#   failures (incremented)
# Arguments:
#   Where: "file:line" or "file".
#   What is wrong.
# Outputs:
#   Writes "where: what" to stdout.
#######################################
problem() {
    printf '%s: %s\n' "$1" "$2"
    failures=$((failures + 1))
}

#######################################
# Print a path relative to ROOT for reports.
# Globals:
#   ROOT
# Arguments:
#   A path under ROOT.
# Outputs:
#   Writes the path without the ROOT/ prefix, and no newline, to stdout.
#######################################
rel() { printf '%s' "${1#"$ROOT"/}"; }

#######################################
# List all addon folders.
# Globals:
#   ROOT
# Outputs:
#   Writes each folder under ROOT/addons/, one per line and without a trailing /, to stdout.
#######################################
addon_dirs() {
    local dir
    for dir in "$ROOT"/addons/*/; do
        [[ -d "$dir" ]] && printf '%s\n' "${dir%/}"
    done
}

# All .lua files under addons/, NUL separated.
lua_files() { find "$ROOT/addons" -type f -name '*.lua' -print0 2>/dev/null; }

#######################################
# Tell whether a path is a test file.
# Arguments:
#   A file path or name.
# Returns:
#   0 if it ends in _test.lua, 1 if not.
#######################################
is_test() { [[ "$1" == *_test.lua ]]; }

#######################################
# Check that every .lua under addons/ parses (luac -p).
# Globals:
#   LUAC
#   failures (counted through problem)
# Outputs:
#   Writes each file that does not parse, with luac's message, to stdout.
#######################################
check_syntax() {
    local file out
    while IFS= read -r -d '' file; do
        if ! out="$("$LUAC" -p "$file" 2>&1)"; then
            problem "$(rel "$file")" "does not parse: ${out##*: }"
        fi
    done < <(lua_files)
}

#######################################
# Check that addon files (not tests) write only globals listed in scripts/allowed-globals.txt.
# Reads the SETGLOBAL lines of luac's listing, so each write is reported with its line.
# Globals:
#   ALLOWED_GLOBALS, LUAC
#   failures (counted through problem)
# Outputs:
#   Writes each stray global write to stdout.
#######################################
check_globals() {
    local allowed="" file line name
    if [[ -f "$ALLOWED_GLOBALS" ]]; then
        allowed="$(grep -v -E '^[[:space:]]*(#|$)' "$ALLOWED_GLOBALS" || true)"
    fi
    while IFS= read -r -d '' file; do
        is_test "$file" && continue
        while read -r line name; do
            [[ -n "$name" ]] || continue
            if ! grep -q -x -F -- "$name" <<<"$allowed"; then
                problem "$(rel "$file"):$line" "writes global '$name' (make it local, or add it to scripts/allowed-globals.txt)"
            fi
        done < <("$LUAC" -p -l "$file" 2>/dev/null \
            | sed -n -E 's/^[[:space:]]*[0-9]+[[:space:]]+\[([0-9]+)\][[:space:]]+SETGLOBAL.*; (.*)$/\1 \2/p')
    done < <(lua_files)
}

#######################################
# Check each addon's .toc files: an "## Interface:" number, every listed file exists, no test
# file is listed, and every non-test .lua is listed in one of them.
# Globals:
#   failures (counted through problem)
# Outputs:
#   Writes each problem to stdout.
#######################################
check_toc() {
    local dir name tocs toc entry listed file
    while IFS= read -r dir; do
        name="$(basename "$dir")"
        tocs=("$dir"/*.toc)
        if [[ ! -f "${tocs[0]}" ]]; then
            problem "$(rel "$dir")" "has no .toc file"
            continue
        fi
        listed=""
        for toc in "${tocs[@]}"; do
            local toc_name entries=()
            toc_name="$(rel "$toc")"
            grep -q -E '^## Interface:[[:space:]]*[0-9]+' "$toc" \
                || problem "$toc_name" "has no '## Interface:' number"
            # File lines: not blank, not a ## tag or # comment; trimmed, with / separators.
            mapfile -t entries < <(sed -E -e 's/\r$//' -e 's/^[[:space:]]+|[[:space:]]+$//g' \
                -e '/^(#|$)/d' -e 's#\\#/#g' "$toc")
            for entry in "${entries[@]}"; do
                listed+="$entry"$'\n'
                [[ -f "$dir/$entry" ]] || problem "$toc_name" "lists '$entry', which does not exist"
                if is_test "$entry"; then
                    problem "$toc_name" "lists test file '$entry'; the game must never load tests"
                fi
            done
        done
        while IFS= read -r -d '' file; do
            file="${file#"$dir"/}"
            is_test "$file" && continue
            grep -q -x -F -- "$file" <<<"$listed" \
                || problem "$(rel "$dir")/$file" "is not listed in any $name .toc, so the game never loads it"
        done < <(find "$dir" -type f -name '*.lua' -print0)
    done < <(addon_dirs)
}

#######################################
# Check addon files (not tests) for API calls RULES.md forbids (BANNED_API), for calls that
# need a reviewed note and lack one (REVIEW_API, REVIEW_NOTE), and for method calls on
# Blizzard's auction window that do more than read it (HOUSE_CALL, HOUSE_READS).
# Globals:
#   BANNED_API, REVIEW_API, REVIEW_NOTE, HOUSE_CALL, HOUSE_READS
#   failures (counted through problem)
# Outputs:
#   Writes each hit, with file and line, to stdout.
#######################################
check_policy() {
    local file hit name
    while IFS= read -r -d '' file; do
        is_test "$file" && continue
        while IFS= read -r hit; do
            problem "$(rel "$file"):${hit%%:*}" "calls '${hit#*:}', which RULES.md forbids"
        done < <(grep -n -o -E -- "$BANNED_API" "$file" || true)
        while IFS= read -r hit; do
            grep -q -E -- "$REVIEW_NOTE" <<<"${hit#*:}" && continue
            name="$(grep -o -E -- "$REVIEW_API" <<<"${hit#*:}" | head -n 1 \
                | sed -E -e 's/^[^A-Za-z_]//' -e 's/[[:space:]]*\($//')"
            problem "$(rel "$file"):${hit%%:*}" \
                "calls '$name', which needs a '-- reviewed: <why>' note on the same line (RULES.md)"
        done < <(grep -n -E -- "$REVIEW_API" "$file" || true)
        while IFS= read -r hit; do
            problem "$(rel "$file"):${hit%%:*}" "changes Blizzard's auction window ('${hit#*:}'); only read or hook it"
        done < <(grep -n -o -E -- "$HOUSE_CALL" "$file" | grep -v -E -- "$HOUSE_READS" || true)
    done < <(lua_files)
}

#######################################
# Check each addon's version: <Name>.toc has a "## Version: X.Y.Z" line in semver form, and
# the addon's CHANGELOG.md has a "## [X.Y.Z]" section for it.
# Globals:
#   SEMVER
#   failures (counted through problem)
# Outputs:
#   Writes each problem to stdout.
#######################################
check_version() {
    local dir name toc version changelog
    while IFS= read -r dir; do
        name="$(basename "$dir")"
        toc="$dir/$name.toc"
        [[ -f "$toc" ]] || continue  # the toc check reports a missing .toc
        version="$(sed -n -E 's/\r$//; s/^## Version:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$toc" \
            | head -n 1)"
        if [[ -z "$version" ]]; then
            problem "$(rel "$toc")" "has no '## Version: X.Y.Z' line"
            continue
        fi
        if [[ ! "$version" =~ $SEMVER ]]; then
            problem "$(rel "$toc")" "version '$version' is not X.Y.Z"
            continue
        fi
        changelog="$dir/CHANGELOG.md"
        if [[ ! -f "$changelog" ]]; then
            problem "$(rel "$dir")" "has no CHANGELOG.md"
            continue
        fi
        grep -q -x -F -- "## [$version]" "$changelog" \
            || grep -q -F -- "## [$version] " "$changelog" \
            || problem "$(rel "$changelog")" "has no '## [$version]' section for the .toc version"
    done < <(addon_dirs)
}

#######################################
# Run each addon's *_test.lua files under LUA, and fail an addon that has none.
# Globals:
#   LUA
#   failures (counted through problem)
# Outputs:
#   Writes each passing test's last line, or a failing test's FAIL and error lines, to stdout.
#######################################
check_tests() {
    local dir test count out
    while IFS= read -r dir; do
        count=0
        for test in "$dir"/*_test.lua; do
            [[ -f "$test" ]] || continue
            count=$((count + 1))
            if out="$("$LUA" "$test" 2>&1)"; then
                printf '%s: %s\n' "$(rel "$test")" "$(tail -n 1 <<<"$out")"
            else
                printf '%s\n' "$out" | grep -E '^FAIL|rror' || true
                problem "$(rel "$test")" "failed"
            fi
        done
        [[ $count -gt 0 ]] || problem "$(rel "$dir")" "has no *_test.lua"
    done < <(addon_dirs)
}

#######################################
# Run each addon's tests under scripts/lua_coverage.lua, print the coverage of each addon file,
# and fail any file whose tests run less than COVERAGE_MIN percent of its lines.
# Globals:
#   ROOT, SCRIPTS, LUA, LUAC, COVERAGE_MIN
#   failures (counted through problem)
# Outputs:
#   Writes one coverage line per addon file, and each problem, to stdout.
#######################################
check_coverage() {
    local minimum="${COVERAGE_MIN:-90}" dir test hits file out line
    local -a files
    mkdir -p "$ROOT/.check-tmp"
    hits="$(mktemp "$ROOT/.check-tmp/coverage.XXXXXX")"
    while IFS= read -r dir; do
        : >"$hits"
        # Run from ROOT with relative paths, so reports name files the way the repo does.
        for test in "$dir"/*_test.lua; do
            [[ -f "$test" ]] || continue
            if ! out="$(cd "$ROOT" && "$LUA" "$SCRIPTS/lua_coverage.lua" run "$hits" "$(rel "$test")" 2>&1)"; then
                printf '%s\n' "$out" | grep -E '^FAIL|rror' || true
                problem "$(rel "$test")" "failed"
            fi
        done
        files=()
        while IFS= read -r -d '' file; do
            is_test "$file" || files+=("$(rel "$file")")
        done < <(find "$dir" -type f -name '*.lua' -print0 | sort -z)
        [[ ${#files[@]} -gt 0 ]] || continue
        out="$(cd "$ROOT" && LUAC="$LUAC" "$LUA" "$SCRIPTS/lua_coverage.lua" report "$minimum" "$hits" \
            "${files[@]}" 2>&1)" || true
        while IFS= read -r line; do
            if [[ "$line" == *"% minimum" ]]; then
                problem "${line%%: *}" "${line#*: }"
            else
                printf '%s\n' "$line"
            fi
        done <<<"$out"
    done < <(addon_dirs)
    rm "$hits"
}

case "${1:-}" in
    syntax) check_syntax ;;
    globals) check_globals ;;
    toc) check_toc ;;
    policy) check_policy ;;
    version) check_version ;;
    tests) check_tests ;;
    coverage) check_coverage ;;
    all)
        check_syntax
        check_globals
        check_toc
        check_policy
        check_version
        check_tests
        check_coverage
        ;;
    *)
        echo "usage: $0 [--root DIR] <syntax|globals|toc|policy|version|tests|coverage|all>" >&2
        exit 2
        ;;
esac

if [[ $failures -gt 0 ]]; then
    printf '%d problem(s) found.\n' "$failures" >&2
    exit 1
fi
