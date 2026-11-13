#!/usr/bin/env bash
# Upload one addon release zip to CurseForge or Wago, the two addon sites with a WoW Forever
# category. The release workflow runs it after the GitHub release is out, once per store.
#
# Everything sent comes from inside the zip, which is the signed one from the GitHub release:
# its .toc gives the store's project ID (## X-Curse-Project-ID or ## X-Wago-ID), the version and
# the interface number (16001 means game version 1.60.1), and its CHANGELOG.md gives that
# version's notes. An addon with no ID line for a store isn't listed there and is skipped.
# With the ID line, the store's token must be set, or the upload fails: a missing secret must
# not look like success. Only Forever interfaces (16xxx) are uploaded, to Forever categories.
#
# Tokens reach curl through stdin, never its command line. Uploads are not retried: a retry
# after a timeout could post the same file twice.
#
# Usage: scripts/store_upload.sh [--dry-run] <curseforge|wago> <Addon-X.Y.Z.zip>
#   --dry-run  read the store's version list and print the metadata, but upload nothing
# Environment:
#   CURSEFORGE_API_TOKEN       token from https://authors.curseforge.com/#/settings/api-tokens
#   WAGO_API_TOKEN             key from https://addons.wago.io/account/apikeys
#   CURSEFORGE_MANUAL_RELEASE  true (default): CurseForge holds the file until the owner
#                              releases it on the site; false: it goes live once approved
# Needs: curl, unzip, lua5.1
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPTS
# shellcheck source=scripts/release_lib.sh
source "$SCRIPTS/release_lib.sh"

readonly LUA="${LUA:-lua5.1}"
readonly CF_SITE="https://wow.curseforge.com"
readonly CF_FOREVER_TYPE=88568  # CurseForge's game version type for WoW Forever
readonly WAGO_SITE="https://addons.wago.io"
readonly WAGO_FLAVOR="forever"
readonly ZIP_RE='^([A-Za-z][A-Za-z0-9_]*)-((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))\.zip$'
# Characters a store token can hold; anything else (a quote, a newline) could break curl's config.
readonly TOKEN_RE='^[A-Za-z0-9._~+/=-]+$'

#######################################
# Print why the upload stopped and exit.
# Arguments:
#   The reason, as one or more words.
# Outputs:
#   Writes the reason to stderr.
# Returns:
#   Never; exits 1.
#######################################
die() {
    printf 'store_upload: %s\n' "$*" >&2
    exit 1
}

#######################################
# Print a progress note.
# Arguments:
#   The note, as one or more words.
# Outputs:
#   Writes it to stdout.
#######################################
note() { printf 'store_upload: %s\n' "$*"; }

#######################################
# Print a warning, as a GitHub annotation when running in Actions.
# Globals:
#   GITHUB_ACTIONS
# Arguments:
#   The warning, as one or more words.
# Outputs:
#   Writes it to stdout.
#######################################
warn() {
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        printf '::warning::%s\n' "$*"
    else
        printf 'store_upload: warning: %s\n' "$*"
    fi
}

#######################################
# Print the usage line.
# Outputs:
#   Writes it to stderr.
#######################################
usage() {
    echo "usage: $0 [--dry-run] <curseforge|wago> <Addon-X.Y.Z.zip>" >&2
}

#######################################
# Print one "## Field: value" from the .toc text, trimmed; nothing if it isn't there.
# Globals:
#   toc_text
# Arguments:
#   The field name, such as Version.
# Outputs:
#   Writes the value to stdout.
#######################################
toc_field() {
    printf '%s\n' "$toc_text" | sed -n -E "s/\r\$//; s/^## $1:[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\1/p" \
        | head -n 1
}

#######################################
# Print a curl config line that sends one header, for curl --config - (stdin).
# Arguments:
#   The header, such as "X-Api-Token: abc".
# Outputs:
#   Writes the config line to stdout.
#######################################
header_config() { printf 'header = "%s"\n' "$1"; }

#######################################
# Upload the zip and its metadata, and report what the store answered.
# Globals:
#   work, zip, dry_run, store_label
# Arguments:
#   The upload URL.
#   The auth header, such as "Authorization: Bearer abc".
# Outputs:
#   Writes progress to stdout and the store's answer on failure to stderr.
# Returns:
#   0 on HTTP 200 or 201; exits 1 otherwise.
#######################################
post_upload() {
    local url="$1" header="$2" code
    if [[ $dry_run -eq 1 ]]; then
        note "dry run: would upload $(basename "$zip") to $url with this metadata:"
        cat "$work/metadata.json"
        return 0
    fi
    note "uploading $(basename "$zip") to $url"
    if ! code="$(header_config "$header" | curl -sS --max-time 300 --config - \
        -o "$work/response.json" -w '%{http_code}' -H 'Accept: application/json' \
        -F "metadata=<$work/metadata.json" -F "file=@$zip" "$url")"; then
        die "the upload to $store_label did not go through (network error); nothing was sent, or check the site before running it again"
    fi
    case "$code" in
        200 | 201)
            note "$store_label took it (HTTP $code): $(head -c 500 "$work/response.json")"
            ;;
        *)
            printf 'store_upload: %s answered HTTP %s:\n' "$store_label" "$code" >&2
            head -c 2000 "$work/response.json" >&2 || true
            printf '\n' >&2
            exit 1
            ;;
    esac
}

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
    shift
fi
if [[ $# -ne 2 || ( "$1" != "curseforge" && "$1" != "wago" ) ]]; then
    usage
    exit 2
fi
store="$1"
zip="$2"

[[ -f "$zip" ]] || die "no zip at $zip"
[[ "$(basename "$zip")" =~ $ZIP_RE ]] || die "'$(basename "$zip")' is not a release zip like HouseLedger-1.2.3.zip"
name="${BASH_REMATCH[1]}"
version="${BASH_REMATCH[2]}"

toc_text="$(unzip -p "$zip" "$name/$name.toc" 2>/dev/null)" || die "the zip has no $name/$name.toc"
toc_version="$(toc_field Version)"
[[ "$toc_version" == "$version" ]] \
    || die "the zip is version $version, but its $name.toc says ${toc_version:-nothing}"
interface="$(toc_field Interface)"
[[ "$interface" =~ ^16[0-9]{3}$ ]] \
    || die "$name.toc says interface ${interface:-nothing}; only WoW Forever (16xxx) is uploaded"
game_version="$((interface / 10000)).$((interface % 10000 / 100)).$((interface % 100))"

case "$store" in
    curseforge)
        store_label="CurseForge" id_field="X-Curse-Project-ID" id_re='^[0-9]+$'
        token_var="CURSEFORGE_API_TOKEN"
        ;;
    wago)
        store_label="Wago" id_field="X-Wago-ID" id_re='^[A-Za-z0-9]+$' token_var="WAGO_API_TOKEN"
        ;;
esac
project_id="$(toc_field "$id_field")"
if [[ -z "$project_id" ]]; then
    note "$name has no '## $id_field:' line, so it is not listed on $store_label; skipped."
    exit 0
fi
[[ "$project_id" =~ $id_re ]] || die "$name.toc's $id_field '$project_id' is not a $store_label project ID"
printf -v token '%s' "${!token_var:-}"
[[ -n "$token" ]] || die "$name is listed on $store_label (## $id_field: $project_id), but $token_var is not set; add it as a secret of the repo's 'stores' environment"
[[ "$token" =~ $TOKEN_RE ]] || die "$token_var holds characters a $store_label token never has; check the secret"

work="$(mktemp -d)"
trap 'rm -r "$work"' EXIT

unzip -p "$zip" "$name/CHANGELOG.md" >"$work/CHANGELOG.md" 2>/dev/null \
    || die "the zip has no $name/CHANGELOG.md"
section="$(changelog_section "$work/CHANGELOG.md" "$version")" \
    || die "$name's CHANGELOG.md has no '## [$version]' section"
[[ -n "$section" ]] || die "the '## [$version]' section of $name's CHANGELOG.md is empty"
printf '%s' "$section" >"$work/notes.md"

note "$name $version, WoW Forever $game_version (interface $interface), to $store_label project $project_id"
case "$store" in
    curseforge)
        manual="${CURSEFORGE_MANUAL_RELEASE:-true}"
        [[ "$manual" == "true" || "$manual" == "false" ]] \
            || die "CURSEFORGE_MANUAL_RELEASE must be true or false, not '$manual'"
        header_config "X-Api-Token: $token" | curl -fsS --max-time 60 --retry 2 --config - \
            -o "$work/versions.json" "$CF_SITE/api/game/versions" \
            || die "could not read CurseForge's game versions"
        picked="$("$LUA" "$SCRIPTS/store_json.lua" cf-version "$work/versions.json" \
            "$CF_FOREVER_TYPE" "$game_version")" || exit 1
        read -r version_id cf_name match <<<"$picked"
        [[ "$match" == "exact" ]] \
            || warn "CurseForge has no Forever $game_version yet, so the file is tagged $cf_name"
        "$LUA" "$SCRIPTS/store_json.lua" cf-metadata "$work/notes.md" "$name $version" \
            "$version_id" "$manual" >"$work/metadata.json" || exit 1
        post_upload "$CF_SITE/api/projects/$project_id/upload-file" "X-Api-Token: $token"
        [[ "$manual" == "false" || $dry_run -eq 1 ]] \
            || note "CurseForge holds the file until you release it on the project's Files page."
        ;;
    wago)
        # The patch list is public, so the token isn't sent for it.
        curl -fsS --max-time 60 --retry 2 -o "$work/game.json" "$WAGO_SITE/api/data/game" \
            || die "could not read Wago's patch list"
        picked="$("$LUA" "$SCRIPTS/store_json.lua" wago-patch "$work/game.json" \
            "$WAGO_FLAVOR" "$game_version")" || exit 1
        read -r patch match <<<"$picked"
        [[ "$match" == "exact" ]] \
            || warn "Wago has no Forever patch $game_version yet, so the file is marked $patch"
        "$LUA" "$SCRIPTS/store_json.lua" wago-metadata "$work/notes.md" "$version" \
            "$WAGO_FLAVOR" "$patch" >"$work/metadata.json" || exit 1
        post_upload "$WAGO_SITE/api/projects/$project_id/version" "Authorization: Bearer $token"
        ;;
esac
