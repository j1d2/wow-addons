#!/usr/bin/env bash
# Checks for every addon under addons/. Plain bash plus the Lua 5.1 tools, no packages.
#
#   syntax   every .lua parses (luac5.1 -p)
#   globals  addon files only write globals listed in scripts/allowed-globals.txt
#            (reads luac's SETGLOBAL listing, the core idea of luacheck, without the package)
#   toc      each addon has a .toc with ## Interface, every listed file exists, test files are
#            never listed, and every non-test .lua is listed
#   policy   no call to an API that RULES.md forbids (post, buy, bid, cancel, run code from text),
#            and no change to Blizzard's auction window (read or hook it only)
#   version  each addon's <Name>.toc has a "## Version: X.Y.Z" (semver), and its CHANGELOG.md
#            has a "## [X.Y.Z]" section for it, so every release has notes
#   tests    each addon has at least one *_test.lua, and all of them pass under lua5.1
#
# Usage: scripts/addon_checks.sh [--root DIR] <syntax|globals|toc|policy|version|tests|all>
# Environment: LUA (default lua5.1), LUAC (default luac5.1)
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
readonly BANNED_API='C_AuctionHouse\.(PostItem|PostCommodity|PlaceBid|CancelAuction|CancelSell|StartCommoditiesPurchase|ConfirmCommoditiesPurchase)|\b(PlaceAuctionBid|PostAuction|StartAuction|CancelAuction|loadstring|RunScript|RunMacroText)\b'

# RULES.md: Blizzard's auction window is read or followed (hooksecurefunc), never
# changed. A method call on it or on one of its parts (AuctionHouseFrame.SearchBar,
# AuctionHouseFrameSellTab) is flagged unless it only reads.
readonly HOUSE_CALL='AuctionHouseFrame[A-Za-z0-9_.]*:[A-Za-z_]+'
readonly HOUSE_READS=':(IsShown|IsVisible|GetRight|GetLeft|GetTop|GetBottom|GetWidth|GetHeight|GetDisplayMode|GetItem)$'

# MAJOR.MINOR.PATCH with no leading zeros, the form release tags use (see package_addon.sh).
readonly SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

failures=0

# Report one problem and count it.
# Args:
#   $1  "file:line" or "file"
#   $2  what is wrong
problem() {
    printf '%s: %s\n' "$1" "$2"
    failures=$((failures + 1))
}

# Print a path relative to ROOT for reports.
rel() { printf '%s' "${1#"$ROOT"/}"; }

# All addon folders, one per line.
addon_dirs() {
    local dir
    for dir in "$ROOT"/addons/*/; do
        [[ -d "$dir" ]] && printf '%s\n' "${dir%/}"
    done
}

# All .lua files under addons/, NUL separated.
lua_files() { find "$ROOT/addons" -type f -name '*.lua' -print0 2>/dev/null; }

is_test() { [[ "$1" == *_test.lua ]]; }

check_syntax() {
    local file out
    while IFS= read -r -d '' file; do
        if ! out="$("$LUAC" -p "$file" 2>&1)"; then
            problem "$(rel "$file")" "does not parse: ${out##*: }"
        fi
    done < <(lua_files)
}

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

check_policy() {
    local file hit
    while IFS= read -r -d '' file; do
        is_test "$file" && continue
        while IFS= read -r hit; do
            problem "$(rel "$file"):${hit%%:*}" "calls '${hit#*:}', which RULES.md forbids"
        done < <(grep -n -o -E -- "$BANNED_API" "$file" || true)
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

case "${1:-}" in
    syntax) check_syntax ;;
    globals) check_globals ;;
    toc) check_toc ;;
    policy) check_policy ;;
    version) check_version ;;
    tests) check_tests ;;
    all)
        check_syntax
        check_globals
        check_toc
        check_policy
        check_version
        check_tests
        ;;
    *)
        echo "usage: $0 [--root DIR] <syntax|globals|toc|policy|version|tests|all>" >&2
        exit 2
        ;;
esac

if [[ $failures -gt 0 ]]; then
    printf '%d problem(s) found.\n' "$failures" >&2
    exit 1
fi
