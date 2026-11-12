#!/usr/bin/env bash
# Watches the WoW Forever client for changes that matter to these addons, and opens a GitHub
# issue when there is something to do. .github/workflows/client-watch.yml runs it twice a day.
#
#   1. Version: reads Forever's version from Blizzard's version server
#      (us.version.battle.net). If its interface number (1.61.0 is 16100) is above an addon's "## Interface:",
#      the game will mark that addon out of date: open an "update the addons" issue.
#   2. Builds: for each new build in the last few days of the community mirror of Blizzard's
#      interface code (Gethe/wow-ui-source, forever branch), list the game functions and events
#      whose documentation changed, and the Blizzard files the addons follow. If an addon file
#      uses one, open an issue naming them.
#
# It only reads and opens issues. It never edits code, raises versions or releases: an addon is
# updated after it is tested in game.
#
# Usage: scripts/client_watch.sh [--root DIR] [--dry-run]
#   --dry-run  print the issues it would open instead of opening them
# Needs: curl, and gh (GH_TOKEN and GH_REPO set in CI)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root) ROOT="$(cd "$2" && pwd)"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        *) echo "usage: $0 [--root DIR] [--dry-run]" >&2; exit 2 ;;
    esac
    shift
done
cd "$ROOT"

readonly VERSIONS_URL="https://us.version.battle.net/v2/products/wowf/versions"
readonly MIRROR="repos/Gethe/wow-ui-source"
readonly MIRROR_WEB="https://github.com/Gethe/wow-ui-source"
readonly MIRROR_BRANCH="forever"
readonly LOOKBACK_DAYS=4
readonly LABEL="client-update"
# GitHub's compare API lists at most this many changed files, with no way to page past it.
readonly COMPARE_FILE_LIMIT=300
# Blizzard files the addons follow or hook: the auction window (HouseLedger), the secure button
# code and the bag windows (Unmaker).
readonly WATCHED_FILES='Blizzard_AuctionHouseUI/|Blizzard_FrameXML/SecureTemplates\.lua|Blizzard_UIPanels_Game/Mainline/ContainerFrame\.lua'

mkdir -p "$ROOT/.check-tmp"
work="$(mktemp -d "$ROOT/.check-tmp/watch.XXXXXX")"
trap 'rm -r "$work"' EXIT

#######################################
# Print why the run stopped and exit with a failure, so the scheduled job shows red.
# Arguments:
#   The reason.
# Outputs:
#   Writes the reason to stderr.
#######################################
die() {
    printf 'client_watch: %s\n' "$*" >&2
    exit 1
}

#######################################
# The interface number of a client version: 1.60.1 is 16001, 11.0.2 is 110002.
# Arguments:
#   Version as major.minor.patch.
# Outputs:
#   Writes the number to stdout.
#######################################
interface_of() {
    local major minor patch
    IFS=. read -r major minor patch <<<"$1"
    echo $((major * 10000 + minor * 100 + patch))
}

#######################################
# The highest interface number a .toc lists ("## Interface: 16001" or a comma list).
# Arguments:
#   Path to the .toc.
# Outputs:
#   Writes the number to stdout, or 0 when the .toc has none.
#######################################
toc_interface() {
    sed -n -E 's/\r$//; s/^## Interface:[[:space:]]*//p' "$1" | head -n 1 | tr ',' '\n' \
        | tr -d '[:space:]' | grep -E '^[0-9]+$' | sort -n | tail -n 1 || echo 0
}

#######################################
# Open an issue unless one with the same title exists (open or closed).
# Arguments:
#   Issue title.
#   Path to the issue body.
# Globals:
#   DRY_RUN (1 prints the issue instead)
#   WATCH_ASSIGNEE (optional GitHub login to assign the issue to)
# Outputs:
#   Writes what it did to stdout.
#######################################
open_issue() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf 'Would open: %s\n\n' "$1"
        cat "$2"
        return
    fi
    if gh issue list --state all --label "$LABEL" --search "\"$1\" in:title" --json title --jq '.[].title' \
        | grep -q -x -F -- "$1"; then
        echo "Already reported: $1"
        return
    fi
    local assignee=()
    [[ -z "${WATCH_ASSIGNEE:-}" ]] || assignee=(--assignee "$WATCH_ASSIGNEE")
    gh issue create --title "$1" --body-file "$2" --label "$LABEL" "${assignee[@]}" >/dev/null
    echo "Opened: $1"
}

# 1. Version ------------------------------------------------------------------------------------

versions="$(curl -fsS --max-time 20 "$VERSIONS_URL")" \
    || die "couldn't read Blizzard's version server ($VERSIONS_URL)"
version="$(awk -F'|' '$1 == "us" { print $6; exit }' <<<"$versions")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "no Forever version for the US region in the version server's answer"
short="${version%.*}"
build="${version##*.}"
client="$(interface_of "$short")"
echo "WoW Forever $version (interface $client)."

outdated=""
for toc in addons/*/*.toc; do
    [[ -f "$toc" ]] || continue
    has="$(toc_interface "$toc")"
    if [[ "$has" -lt "$client" ]]; then
        outdated+="| $(basename "$(dirname "$toc")") | \`$toc\` | $has | $client |"$'\n'
    fi
done

if [[ -z "$outdated" ]]; then
    echo "The addons are up to date (interface $client)."
else
    {
        printf "WoW Forever %s is out (build %s, interface %s). The game marks an addon whose \`## Interface:\` is lower as out of date, and players must tick \"Load out of date AddOns\" to use it.\n\n" \
            "$short" "$build" "$client"
        printf '| Addon | File | Now | Needs |\n| --- | --- | --- | --- |\n%s\n' "$outdated"
        printf 'For each addon:\n\n'
        printf -- '- [ ] Read what changed in the mirror (%s/commits/%s) and in Blizzard'"'"'s patch notes.\n' "$MIRROR_WEB" "$MIRROR_BRANCH"
        printf -- "- [ ] Run \`scripts/check.sh\`, then try the addon in game on the new client.\n"
        printf -- "- [ ] Fix what broke, set \`## Interface: %s\`, raise the PATCH version, and add a changelog line.\n" "$client"
        printf -- '- [ ] Merge, then tag and release (see docs/development.md).\n'
    } >"$work/version.md"
    open_issue "WoW Forever $short is out: update the addons" "$work/version.md"
fi

# 2. Builds -------------------------------------------------------------------------------------

since="$(date -u -d "$LOOKBACK_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)"
commits="$(gh api "$MIRROR/commits?sha=$MIRROR_BRANCH&since=$since&per_page=30" \
    --jq '.[] | [.sha, .parents[0].sha, (.commit.message | split("\n")[0])] | @tsv')" \
    || die "couldn't read the interface-code mirror ($MIRROR_WEB)"

while IFS=$'\t' read -r sha parent message; do
    [[ -n "$sha" && "$message" =~ ^[0-9.]+\ \(([0-9]+)\)$ ]] || continue
    build_id="${BASH_REMATCH[1]}"
    gh api "$MIRROR/compare/$parent...$sha" --jq '.files[] | "FILE " + .filename, (.patch // "")' \
        >"$work/diff.txt" || die "couldn't compare mirror builds $parent and $sha"

    # Functions and events whose documentation changed. A changed argument or field line is
    # credited to the function or event that holds it (the last "Name = ..." line standing on
    # its own), never by its own name: field names such as "id" would match unrelated code.
    names="$(awk '
        /^FILE / { api = ($2 ~ /Blizzard_APIDocumentationGenerated\//); name = ""; literal = ""; next }
        !api { next }
        /^@@/ { name = ""; literal = ""; next }
        {
            sign = substr($0, 1, 1)
            text = substr($0, 2)
            if (text ~ /^[[:space:]]*Name = "[A-Za-z_][A-Za-z0-9_]*",?[[:space:]]*$/) {
                name = text; sub(/^[^"]*"/, "", name); sub(/".*$/, "", name); literal = ""
            } else if (text ~ /^[[:space:]]*LiteralName = "[A-Za-z_][A-Za-z0-9_]*",?[[:space:]]*$/) {
                literal = text; sub(/^[^"]*"/, "", literal); sub(/".*$/, "", literal)
            }
            if ((sign == "+" || sign == "-") && name != "") {
                print name
                if (literal != "") print literal
            }
        }
    ' "$work/diff.txt" | sort -u || true)"
    watched="$(sed -n 's/^FILE //p' "$work/diff.txt" | grep -E -- "$WATCHED_FILES" | sort -u || true)"
    # API files GitHub listed without their change (too large to show): can't be read, so listed.
    unread="$(awk '
        /^FILE / {
            if (file != "" && api && lines == 0) print file
            file = $2; api = (file ~ /Blizzard_APIDocumentationGenerated\//); lines = 0; next
        }
        NF { lines++ }
        END { if (file != "" && api && lines == 0) print file }
    ' "$work/diff.txt")"
    file_count="$(grep -c '^FILE ' "$work/diff.txt" || true)"

    used=""
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        files="$(grep -r -l -w --include='*.lua' -- "$name" addons | grep -v '_test\.lua$' | sort | tr '\n' ' ' || true)"
        [[ -z "$files" ]] || used+="| \`$name\` | ${files% } |"$'\n'
    done <<<"$names"

    if [[ -z "$used" && -z "$watched" && -z "$unread" && "$file_count" -lt "$COMPARE_FILE_LIMIT" ]]; then
        echo "Build $build_id: no change to APIs or Blizzard files the addons use."
        continue
    fi
    {
        printf 'Mirror build %s changed game code these addons use. Compare: %s/compare/%s...%s\n\n' \
            "$build_id" "$MIRROR_WEB" "$parent" "$sha"
        if [[ -n "$used" ]]; then
            printf 'Game functions or events whose documentation changed:\n\n| Name | Used in |\n| --- | --- |\n%s\n' "$used"
        fi
        if [[ "$file_count" -ge "$COMPARE_FILE_LIMIT" ]]; then
            printf 'This build changed %s or more files, the most GitHub lists, so some changes may not be listed below. Check the comparison by hand.\n\n' "$COMPARE_FILE_LIMIT"
        fi
        if [[ -n "$unread" ]]; then
            printf 'API files whose change was too large to show (check them by hand):\n\n'
            while IFS= read -r file; do
                printf -- "- \`%s\`\n" "$file"
            done <<<"$unread"
            printf '\n'
        fi
        if [[ -n "$watched" ]]; then
            printf 'Blizzard files the addons follow that changed:\n\n'
            while IFS= read -r file; do
                printf -- "- \`%s\`\n" "$file"
            done <<<"$watched"
            printf '\n'
        fi
        printf -- '- [ ] Read the changes above and check the addons in game.\n'
        printf -- '- [ ] Close this issue if nothing needs fixing, or fix it in a pull request.\n'
    } >"$work/build.md"
    open_issue "WoW Forever build $build_id changed game APIs our addons use" "$work/build.md"
done <<<"$commits"
