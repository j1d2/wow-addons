#!/usr/bin/env bash
# Build one addon's release zip and release notes from a tag such as HouseLedger-v0.3.0.
#
# The tag must name an addon folder and match the version in its .toc, and the addon's
# CHANGELOG.md must have a section for that version. The zip holds one folder named after the
# addon, which players copy into Interface/AddOns: the .toc files, the files they list,
# Bindings.xml if there is one, CHANGELOG.md, and the repo's LICENSE and NOTICE (Apache License
# 2.0, section 4). Test files
# never ship. With SOURCE_DATE_EPOCH set, every file gets that time, so one commit always
# gives the same zip.
#
# Usage: scripts/package_addon.sh [--root DIR] <Addon-vX.Y.Z> <out dir>
# Writes: <out dir>/<Addon>-<X.Y.Z>.zip and <out dir>/notes.md
# Needs: zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "--root" ]]; then
    ROOT="$(cd "$2" && pwd)"
    shift 2
fi

# <Addon>-v<MAJOR>.<MINOR>.<PATCH>. Addon folder names use letters, digits and _, so the
# "-v" that starts the version can't be part of the name.
readonly TAG_RE='^([A-Za-z][A-Za-z0-9_]*)-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

#######################################
# Print why the build stopped and exit.
# Arguments:
#   The reason, as one or more words.
# Outputs:
#   Writes the reason to stderr.
# Returns:
#   Never; exits 1.
#######################################
die() {
    printf 'package_addon: %s\n' "$*" >&2
    exit 1
}

#######################################
# Print one version's section of a changelog: the lines under its "## [X.Y.Z]" heading, up to
# the next "## [" heading, without blank lines at either end.
# Arguments:
#   Path to the CHANGELOG.md.
#   Version, such as 1.2.3.
# Outputs:
#   Writes the section to stdout.
# Returns:
#   0 if the heading exists, 1 if not.
#######################################
changelog_section() {
    awk -v head="## [$2]" '
        index($0, "## [") == 1 {
            if (found) { done = 1; exit }
            found = ($0 == head || index($0, head " ") == 1)
            next
        }
        found { lines[++count] = $0 }
        END {
            if (!found) exit 1
            first = 1
            while (first <= count && lines[first] ~ /^[[:space:]]*$/) first++
            last = count
            while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
            for (i = first; i <= last; i++) print lines[i]
        }
    ' "$1"
}

#######################################
# Print the files one .toc lists: no blank, ## tag or # comment lines; trimmed, with /
# separators. The same reading as the toc check in addon_checks.sh.
# Arguments:
#   Path to the .toc file.
# Outputs:
#   Writes one file path per line to stdout.
#######################################
toc_entries() {
    sed -E -e 's/\r$//' -e 's/^[[:space:]]+|[[:space:]]+$//g' -e '/^(#|$)/d' -e 's#\\#/#g' "$1"
}

if [[ $# -ne 2 ]]; then
    echo "usage: $0 [--root DIR] <Addon-vX.Y.Z> <out dir>" >&2
    exit 2
fi
tag="$1"
out="$2"

[[ "$tag" =~ $TAG_RE ]] || die "'$tag' is not a release tag like HouseLedger-v1.2.3"
name="${BASH_REMATCH[1]}"
version="${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"

dir="$ROOT/addons/$name"
[[ -d "$dir" ]] || die "no addon folder addons/$name for tag '$tag'"
toc="$dir/$name.toc"
[[ -f "$toc" ]] || die "addons/$name has no $name.toc"
toc_version="$(sed -n -E 's/\r$//; s/^## Version:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$toc" | head -n 1)"
[[ "$toc_version" == "$version" ]] \
    || die "tag '$tag' is version $version, but $name.toc says ${toc_version:-nothing}"

changelog="$dir/CHANGELOG.md"
[[ -f "$changelog" ]] || die "addons/$name has no CHANGELOG.md"
section="$(changelog_section "$changelog" "$version")" \
    || die "addons/$name/CHANGELOG.md has no '## [$version]' section"
[[ -n "$section" ]] || die "the '## [$version]' section of addons/$name/CHANGELOG.md is empty"

for file in LICENSE NOTICE; do
    [[ -f "$ROOT/$file" ]] || die "the repo has no $file to ship"
done
if [[ -n "${SOURCE_DATE_EPOCH:-}" && ! "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]]; then
    die "SOURCE_DATE_EPOCH must be whole seconds since 1970"
fi

mkdir -p "$out"
out="$(cd "$out" && pwd)"
zip_path="$out/$name-$version.zip"
[[ ! -e "$zip_path" ]] || die "$zip_path already exists; build into an empty folder"

stage="$(mktemp -d "$out/.stage.XXXXXX")"
trap 'rm -r "$stage"' EXIT
dest="$stage/$name"
mkdir -p "$dest"

# Every .toc in the folder (a flavor .toc such as Name_Mainline.toc too) and what it lists.
for toc_file in "$dir"/*.toc; do
    cp "$toc_file" "$dest/"
    while IFS= read -r entry; do
        case "$entry" in
            /* | *..*) die "$(basename "$toc_file") lists '$entry', which leaves the addon folder" ;;
            *_test.lua) die "$(basename "$toc_file") lists test file '$entry'" ;;
        esac
        [[ -f "$dir/$entry" ]] || die "$(basename "$toc_file") lists '$entry', which does not exist"
        mkdir -p "$dest/$(dirname "$entry")"
        cp "$dir/$entry" "$dest/$entry"
    done < <(toc_entries "$toc_file")
done
cp "$changelog" "$ROOT/LICENSE" "$ROOT/NOTICE" "$dest/"
# The game loads Bindings.xml by its name, not from the .toc, so it ships when present.
[[ ! -f "$dir/Bindings.xml" ]] || cp "$dir/Bindings.xml" "$dest/"

# Same modes and, with SOURCE_DATE_EPOCH, the same times on every build.
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
    find "$stage" -exec touch -d "@$SOURCE_DATE_EPOCH" {} +
fi

# Sorted names, no directory entries (-D) and no Unix extras such as owner ids (-X). Zip stores
# local time, so TZ is fixed.
(cd "$stage" && find "$name" -type f -print | LC_ALL=C sort | TZ=UTC zip -q -X -D "$zip_path" -@)

{
    printf '%s\n\n---\n\n' "$section"
    printf 'Download **%s** below, unzip it, and copy the %s folder into %s. ' \
        "$name-$version.zip" "\`$name\`" "\`Interface/AddOns\`"
    printf "The README's Install section has the steps for Windows, macOS and Linux.\n"
} >"$out/notes.md"

printf 'Built %s and notes.md\n' "${zip_path#"$ROOT"/}"
