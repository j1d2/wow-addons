#!/usr/bin/env bash
# Privacy and secret scan. Fails when a file (or a commit message) holds something that
# identifies a person or a machine, or looks like a secret, so the repo can go public later.
#
# It never prints what it matched, only where and which rule, so CI logs stay clean too.
#
# Generic rules live here. Real names (account, character, realm, username) go one per line in
# security/privacy-denylist.local, which git ignores; see security/privacy-denylist.example.
# This file is skipped by the file scan because its rules would match themselves.
#
# Usage:
#   scripts/privacy_scan.sh             scan every tracked or new (not ignored) file
#   scripts/privacy_scan.sh --text F    scan one text file, e.g. a commit message
#   scripts/privacy_scan.sh --history   report matches anywhere in git history (never fails)
#
# Environment:
#   PRIVACY_DENYLIST     denylist path (the hooks point it at the real repo's file, since a
#                        commit snapshot has no ignored files)
#   PRIVACY_SCAN_NO_GIT  1 = list files with find instead of git (snapshots and tests)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

readonly SELF="scripts/privacy_scan.sh"
readonly DENYLIST="${PRIVACY_DENYLIST:-$PWD/security/privacy-denylist.local}"

# label|extended regex. Placeholders such as <WoW folder> or <ACCOUNT> do not match.
readonly RULES=(
    "home folder path|/home/[A-Za-z0-9._-]+"
    "macOS user path|/Users/[A-Za-z0-9._-]+"
    "Windows user path|[A-Za-z]:[\\\\/]+Users[\\\\/]+[A-Za-z0-9._-]+"
    "mount path|/mnt/[A-Za-z0-9._-]+"
    "Wine prefix path|drive_c"
    "WoW account folder|WTF[\\\\/]Account[\\\\/][A-Za-z0-9#]"
    "email address|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
    "private IP address|(^|[^0-9.])(10(\\.[0-9]{1,3}){3}|192\\.168(\\.[0-9]{1,3}){2}|172\\.(1[6-9]|2[0-9]|3[01])(\\.[0-9]{1,3}){2})([^0-9.]|$)"
    "private key|-----BEGIN [A-Z ]*PRIVATE KEY-----"
    "AWS access key|AKIA[0-9A-Z]{16}"
    "GitHub token|(ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}"
    "Slack token|xox[abprs]-[A-Za-z0-9-]{10,}"
    "API key|sk-(ant-)?[A-Za-z0-9_-]{20,}"
    "hard-coded secret|(api[_-]?key|secret|token|passw(or)?d)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"'[:space:]]{8,}[\"']"
)

# Addresses that are safe by design: documentation examples and no-reply addresses.
readonly EMAIL_OK='@(example\.(com|org|net)|users\.noreply\.github\.com)$|noreply@'

found=0

#######################################
# Drop email hits that are allowed (EMAIL_OK). Reads grep -o output, "file:line:match", on
# stdin; other rules' hits pass through.
# Globals:
#   EMAIL_OK
# Arguments:
#   The rule label; only "email address" is filtered.
# Outputs:
#   Writes the hits that are kept to stdout.
#######################################
filter_hits() {
    if [[ "$1" != "email address" ]]; then
        cat
        return
    fi
    local line
    while IFS= read -r line; do
        if ! grep -q -E -- "$EMAIL_OK" <<<"${line##*:}"; then
            printf '%s\n' "$line"
        fi
    done
}

#######################################
# Report each hit of one rule, never the matched text.
# Globals:
#   found (set to 1 on a hit)
# Arguments:
#   The label shown in the report.
#   The extended regex.
#   The files to search, one or more.
# Outputs:
#   Writes "file:line: label" for each hit to stdout.
#######################################
report_rule() {
    local label="$1" regex="$2"
    shift 2
    local hit
    while IFS= read -r hit; do
        printf '%s: %s\n' "$(cut -d: -f1,2 <<<"$hit")" "$label"
        found=1
    done < <(grep -I -H -n -o -E -- "$regex" "$@" 2>/dev/null | filter_hits "$label")
}

#######################################
# Report each hit of the local denylist, any case. Never prints the entry.
# Globals:
#   DENYLIST (skipped when missing or empty)
#   found (set to 1 on a hit)
# Arguments:
#   The files to search, one or more.
# Outputs:
#   Writes "file:line: local denylist entry" for each hit to stdout.
#######################################
report_denylist() {
    [[ -f "$DENYLIST" ]] || return 0
    local patterns hit
    patterns="$(grep -v -E '^[[:space:]]*(#|$)' "$DENYLIST" || true)"
    [[ -n "$patterns" ]] || return 0
    while IFS= read -r hit; do
        printf '%s: local denylist entry\n' "$(cut -d: -f1,2 <<<"$hit")"
        found=1
    done < <(grep -I -H -n -i -F -- "$patterns" "$@" 2>/dev/null || true)
}

#######################################
# Run every rule and the denylist over the given files.
# Globals:
#   RULES
#   found (set to 1 on a hit, through report_rule and report_denylist)
# Arguments:
#   The files to search, one or more.
# Outputs:
#   Writes each hit to stdout.
#######################################
scan() {
    local rule
    for rule in "${RULES[@]}"; do
        report_rule "${rule%%|*}" "${rule#*|}" "$@"
    done
    report_denylist "$@"
}

#######################################
# Scan the repo's files, or a plain folder when there is no .git (the hooks check an
# exported copy of the commit). This script itself is skipped.
# Globals:
#   PRIVACY_SCAN_NO_GIT (1 = list files with find instead of git)
#   SELF
#   found (set through scan)
# Outputs:
#   Writes each hit to stdout.
#######################################
scan_files() {
    local files=() path
    if [[ "${PRIVACY_SCAN_NO_GIT:-0}" != 1 ]] \
        && [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == true ]]; then
        while IFS= read -r -d '' path; do
            [[ "$path" == "$SELF" || ! -f "$path" ]] || files+=("$path")
        done < <(git ls-files -z --cached --others --exclude-standard)
    else
        while IFS= read -r -d '' path; do
            path="${path#./}"
            [[ "$path" == "$SELF" ]] || files+=("$path")
        done < <(find . -type f -not -path './.git/*' -print0)
    fi
    [[ ${#files[@]} -eq 0 ]] || scan "${files[@]}"
}

# Work folder of scan_history; its EXIT trap removes it.
history_work=""

#######################################
# Write each commit (author, committer, message, diff) to a file named by its id and scan
# those. Reports only: removing history needs a rewrite, which this repo never does.
# Globals:
#   history_work (set to the work folder inside .git)
#   found (set through scan)
# Outputs:
#   Writes each hit as "<commit>:<line>: label" to stdout, then a summary: on a hit, to
#   stderr; otherwise "History scan: nothing found." to stdout.
#######################################
scan_history() {
    local sha
    # Inside .git, never /tmp: the work folder is removed on exit.
    history_work="$(mktemp -d "$(git rev-parse --absolute-git-dir)/privacy-history.XXXXXX")"
    trap 'rm -r "$history_work"' EXIT
    local work="$history_work"
    for sha in $(git rev-list --all); do
        git show --no-color --format='author: %an <%ae>%ncommitter: %cn <%ce>%n%n%B' -p "$sha" \
            >"$work/${sha:0:12}"
    done
    pushd "$work" >/dev/null
    scan ./*
    popd >/dev/null
    if [[ $found -eq 1 ]]; then
        echo "History has the matches above (<commit>:<line>). They can't be removed without a" >&2
        echo "history rewrite; to share the code, publish a fresh repo instead." >&2
    else
        echo "History scan: nothing found."
    fi
}

case "${1:-}" in
    "")
        scan_files
        ;;
    --text)
        [[ -n "${2:-}" ]] || { echo "usage: $0 --text FILE" >&2; exit 2; }
        scan "$2"
        ;;
    --history)
        scan_history
        exit 0
        ;;
    *)
        echo "usage: $0 [--text FILE | --history]" >&2
        exit 2
        ;;
esac

if [[ $found -eq 1 ]]; then
    echo "Privacy scan failed: remove the items above, or use a placeholder like <WoW folder>." >&2
    exit 1
fi
echo "Privacy scan passed."
