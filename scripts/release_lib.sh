# shellcheck shell=bash
# Shared by the release scripts (package_addon.sh, store_upload.sh), so both read a release's
# notes the same way. Source it; it defines functions only.

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
