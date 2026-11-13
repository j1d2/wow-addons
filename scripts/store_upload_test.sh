#!/usr/bin/env bash
# Offline checks for scripts/store_upload.sh and scripts/store_json.lua. A fake `curl`, first on
# PATH, serves prepared answers from a fixture folder and records every call: the URL, the
# arguments, the config read from stdin (where the token must be) and the metadata sent.
# Fixtures live in .check-tmp/ (git ignores it), removed on exit.
#
# Usage: scripts/store_upload_test.sh
# No -e: each check reports its own result, and a failed one must not stop the rest.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

readonly ROOT="$PWD/.check-tmp/store-test"
readonly FIX="$ROOT/fixtures"
readonly BIN="$ROOT/bin"
readonly ZIP="$ROOT/Demo-1.2.3.zip"
readonly LOG="$FIX/curl.log"
readonly CF_TOKEN="cf-token-1234"
readonly WAGO_TOKEN="wago-token-5678"
readonly LUA="${LUA:-lua5.1}"
failed=0

cleanup() { [[ ! -d "$PWD/.check-tmp" ]] || rm -r "$PWD/.check-tmp"; }
trap cleanup EXIT

#######################################
# Record one result.
# Globals:
#   failed (counts failures)
# Arguments:
#   Check name.
#   0 if it passed, anything else if it failed.
# Outputs:
#   Writes "ok  <name>" or "FAIL  <name>" to stdout.
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
# Run a test command and record whether it succeeded.
# Arguments:
#   Check name.
#   The command and its arguments.
# Outputs:
#   Writes the check's result line to stdout.
#######################################
expect() {
    local name="$1"
    shift
    if "$@"; then check "$name" 0; else check "$name" 1; fi
}

#######################################
# Write the fake curl. It logs each call to $LOG and answers from $FIX:
#   CurseForge's version list   cf-versions.json, or exit 22 if get-fails exists
#   Wago's game data            wago-game.json, or exit 22 if get-fails exists
#   an upload (POST)            post-body (default {"id":555}) and HTTP post-code (default 200)
# Globals:
#   BIN, FIX, LOG
#######################################
write_fake_curl() {
    cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl for store_upload_test.sh.
all="$*"
url="" out="" fmt="" config="" metadata="" file=""
while (($#)); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -w) fmt="$2"; shift 2 ;;
        --config) config="$(cat)"; shift 2 ;;
        -F)
            case "$2" in
                metadata=\<*) metadata="${2#metadata=<}" ;;
                file=@*) file="${2#file=@}" ;;
            esac
            shift 2 ;;
        -H | --max-time | --retry) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
{
    printf 'CALL %s\n' "$url"
    printf 'ARGV %s\n' "$all"
    [[ -z "$config" ]] || printf 'CONFIG %s\n' "$config"
    [[ -z "$file" ]] || printf 'FILE %s\n' "$file"
} >>"$FAKE_FIX/curl.log"
[[ -z "$metadata" ]] || cp "$metadata" "$FAKE_FIX/sent-metadata.json"

answer() { if [[ -n "$out" ]]; then cat "$1" >"$out"; else cat "$1"; fi; }
case "$url" in
    https://wow.curseforge.com/api/game/versions | https://addons.wago.io/api/data/game)
        if [[ -f "$FAKE_FIX/get-fails" ]]; then
            echo "curl: (6) Could not resolve host" >&2
            exit 22
        fi
        case "$url" in
            *curseforge*) answer "$FAKE_FIX/cf-versions.json" ;;
            *) answer "$FAKE_FIX/wago-game.json" ;;
        esac ;;
    *)
        body="$FAKE_FIX/post-body"
        [[ -f "$body" ]] || { printf '{"id":555}' >"$FAKE_FIX/post-body.default"; body="$FAKE_FIX/post-body.default"; }
        answer "$body"
        code=200
        [[ ! -f "$FAKE_FIX/post-code" ]] || code="$(cat "$FAKE_FIX/post-code")"
        [[ -z "$fmt" ]] || printf '%s' "$code" ;;
esac
EOF
    chmod +x "$BIN/curl"
}

#######################################
# Build the fixture: the fake curl, the stores' version lists, and Demo-1.2.3.zip, whose .toc
# says interface 16001 (Forever 1.60.1) and carries the given extra lines.
# Globals:
#   ROOT, FIX, BIN, ZIP
# Arguments:
#   Extra .toc lines, such as the store ID lines (may be empty).
#   The .toc's version (default 1.2.3).
#   The .toc's interface number (default 16001).
#######################################
setup() {
    [[ ! -d "$ROOT" ]] || rm -r "$ROOT"
    mkdir -p "$ROOT/src/Demo" "$FIX" "$BIN"
    write_fake_curl
    printf '## Interface: %s\r\n## Title: Demo\r\n## Version: %s\r\n%s\r\nDemo.lua\r\n' \
        "${3:-16001}" "${2:-1.2.3}" "$1" >"$ROOT/src/Demo/Demo.toc"
    printf 'local Demo = {}\n' >"$ROOT/src/Demo/Demo.lua"
    printf '# Changelog\n\n## [Unreleased]\n\n## [1.2.3] - 2026-11-13\n\n### Added\n\n' \
        >"$ROOT/src/Demo/CHANGELOG.md"
    printf -- '- Says "hi" with a \\ backslash,\ta tab and an em dash \xe2\x80\x94 too.\n' \
        >>"$ROOT/src/Demo/CHANGELOG.md"
    printf '\n## [1.2.2] - 2026-11-01\n\n- Old notes.\n' >>"$ROOT/src/Demo/CHANGELOG.md"
    (cd "$ROOT/src" && zip -q -r "$ZIP" Demo)

    cat >"$FIX/cf-versions.json" <<'EOF'
[
  {"id": 11, "gameVersionTypeID": 517, "name": "1.60.1", "slug": "retail-decoy"},
  {"id": 9000, "gameVersionTypeID": 88568, "name": "1.60.0", "slug": "1-60-0"},
  {"id": 9001, "gameVersionTypeID": 88568, "name": "1.60.1", "slug": "café 😀 \"q\""},
  {"id": 9100, "gameVersionTypeID": 88568, "name": "1.61.0", "slug": "1-61-0", "x": [true, false, null, -1.5e3]}
]
EOF
    cat >"$FIX/wago-game.json" <<'EOF'
{"stability_values": ["stable", "beta", "alpha"],
 "patches": {"retail": ["12.1.7"], "forever": ["1.61.0", "1.60.1", "1.60.0"]}}
EOF
}

readonly IDS=$'## X-Curse-Project-ID: 123456\r\n## X-Wago-ID: aBcD1234'

#######################################
# Run the uploader with the fake curl first on PATH.
# Globals:
#   BIN, FIX, ZIP
#   out, status (set to the uploader's output and exit status)
# Arguments:
#   Its arguments; env assignments such as TOKEN=x may come first.
#######################################
run_upload() {
    local envs=()
    while [[ $# -gt 0 && "$1" == *=* ]]; do
        envs+=("$1")
        shift
    done
    : >"$LOG"
    rm -f "$FIX/sent-metadata.json"
    out="$(env -u CURSEFORGE_API_TOKEN -u WAGO_API_TOKEN -u CURSEFORGE_MANUAL_RELEASE \
        -u GITHUB_ACTIONS PATH="$BIN:$PATH" FAKE_FIX="$FIX" "${envs[@]}" \
        scripts/store_upload.sh "$@" 2>&1)"
    status=$?
}

#######################################
# True when the output contains the text.
# Globals:
#   out
# Arguments:
#   The text.
#######################################
says() { [[ "$out" == *"$1"* ]]; }

#######################################
# True when the metadata sent with the last upload is exactly the given JSON.
# Globals:
#   FIX
# Arguments:
#   The expected JSON.
#######################################
sent_metadata() { [[ -f "$FIX/sent-metadata.json" && "$(cat "$FIX/sent-metadata.json")" == "$1" ]]; }

#######################################
# True when the fake curl was called the given number of times.
# Globals:
#   LOG
# Arguments:
#   The count.
#######################################
calls() { [[ "$(grep -c '^CALL ' "$LOG")" -eq "$1" ]]; }

#######################################
# True when the output does not contain the text.
# Globals:
#   out
# Arguments:
#   The text.
#######################################
never_says() { [[ "$out" != *"$1"* ]]; }

#######################################
# True when no curl command line in the log holds the text (a token must come through stdin).
# Globals:
#   LOG
# Arguments:
#   The text.
#######################################
not_in_argv() { ! grep '^ARGV' "$LOG" | grep -qF "$1"; }

#######################################
# True when the call to the URL sent no config (so no token) on stdin.
# Globals:
#   LOG
# Arguments:
#   The URL.
#######################################
sent_no_config() {
    awk -v call="CALL $1" '
        $0 == call { inside = 1; next }
        /^CALL / { inside = 0 }
        inside && /^CONFIG / { found = 1 }
        END { exit found ? 1 : 0 }
    ' "$LOG"
}

# The changelog section as JSON: quotes, backslash and tab escaped, the em dash kept as UTF-8.
readonly NOTES_JSON='"### Added\n\n- Says \"hi\" with a \\ backslash,\ta tab and an em dash — too."'

# --- store_json.lua on its own ---------------------------------------------------------------

setup ""
decoded="$("$LUA" -e '
    local J = dofile("scripts/store_json.lua")
    local t = J.decode(io.read("*a"))
    io.write(t[3].slug, "|", tostring(t[4].x[1]), tostring(t[4].x[2]),
        tostring(t[4].x[3] == J.null), t[4].x[4])
' <"$FIX/cf-versions.json" 2>&1)"
expect "json: decodes \\u escapes, a surrogate pair, literals and numbers" \
    test "$decoded" == $'caf\xc3\xa9 \xf0\x9f\x98\x80 "q"|truefalsetrue-1500'

#######################################
# True when store_json.lua accepts the text as JSON.
# Arguments:
#   The text.
#######################################
json_accepts() {
    printf '%s' "$1" | "$LUA" -e '
        local J = dofile("scripts/store_json.lua")
        os.exit(pcall(J.decode, io.read("*a")) and 0 or 1)
    '
}
rejects=0
for broken in '{"a": 1' '[1, 2,]' '"\ud800"' $'"tab\tinside"' '{"a" 1}' '[1] x' '"\q"' 'nul' ''; do
    if json_accepts "$broken"; then
        rejects=1
        printf 'accepted: %s\n' "$broken"
    fi
done
check "json: rejects broken JSON (9 cases)" "$rejects"
expect "json: accepts a plain value with spaces around it" json_accepts ' [ 1 , "a" ] '

encoded="$("$LUA" -e '
    local J = dofile("scripts/store_json.lua")
    io.write(J.encode(J.object({ {"s", "a\"b\\c\n\1"}, {"n", 42}, {"f", 1.5}, {"b", false},
        {"l", {"x", 7}}, {"z", J.null} })))
' 2>&1)"
expect "json: encodes ordered objects, escapes and lists" \
    test "$encoded" == '{"s":"a\"b\\c\n\u0001","n":42,"f":1.5,"b":false,"l":["x",7],"z":null}'

"$LUA" scripts/store_json.lua cf-version only-two-args x >/dev/null 2>&1
expect "json: the command line wants each command's own argument count (exit 2)" test $? -eq 2
"$LUA" scripts/store_json.lua cf-metadata "$FIX/cf-versions.json" "Demo 1.2.3" 9.5 true >/dev/null 2>&1
expect "json: cf-metadata refuses a version id that isn't whole (exit 1)" test $? -eq 1

# --- usage and the zip ---------------------------------------------------------------------

setup "$IDS"
run_upload
expect "usage: no arguments is exit 2" test "$status" -eq 2
run_upload steam "$ZIP"
expect "usage: an unknown store is exit 2" test "$status" -eq 2

run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" curseforge "$ROOT/missing.zip"
expect "zip: a missing zip stops it" test "$status" -eq 1

cp "$ZIP" "$ROOT/demo.zip"
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" curseforge "$ROOT/demo.zip"
expect "zip: a name that isn't <Addon>-X.Y.Z.zip stops it" test "$status" -eq 1

setup "$IDS" 1.2.4
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" curseforge "$ZIP"
expect "zip: a .toc version that differs from the zip's stops it" test "$status" -eq 1
expect "zip: ... and says both versions" says "1.2.4"

setup "$IDS" 1.2.3 120001
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" curseforge "$ZIP"
expect "zip: a non-Forever interface (120001) stops it" test "$status" -eq 1
expect "zip: ... before any network call" calls 0

# --- not listed, or listed without a token --------------------------------------------------

setup ""
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" curseforge "$ZIP"
expect "skip: no X-Curse-Project-ID line is a skip (exit 0)" test "$status" -eq 0
expect "skip: ... that says so" says "not listed on CurseForge"
expect "skip: ... and calls nothing" calls 0
run_upload wago "$ZIP"
expect "skip: no X-Wago-ID line is a skip (exit 0), token or not" test "$status" -eq 0

setup "$IDS"
run_upload curseforge "$ZIP"
expect "token: listed on CurseForge without a token fails" test "$status" -eq 1
expect "token: ... and names the secret" says "CURSEFORGE_API_TOKEN"
expect "token: ... before any network call" calls 0
run_upload wago "$ZIP"
expect "token: listed on Wago without a token fails" test "$status" -eq 1
expect "token: ... and names the secret" says "WAGO_API_TOKEN"

run_upload 'CURSEFORGE_API_TOKEN=abc"def' curseforge "$ZIP"
expect "token: a token with a quote is refused" test "$status" -eq 1
expect "token: ... without printing it" never_says 'abc"def'

setup $'## X-Curse-Project-ID: 12ab\r\n## X-Wago-ID: aBcD1234'
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" curseforge "$ZIP"
expect "id: a CurseForge project ID that isn't a number is refused" test "$status" -eq 1
setup $'## X-Wago-ID: ../x'
run_upload WAGO_API_TOKEN="$WAGO_TOKEN" wago "$ZIP"
expect "id: a Wago ID with a path in it is refused" test "$status" -eq 1

# --- CurseForge -----------------------------------------------------------------------------

setup "$IDS"
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" curseforge "$ZIP"
expect "curseforge: uploads (exit 0)" test "$status" -eq 0
expect "curseforge: reads the version list, then uploads" calls 2
expect "curseforge: the version list comes from the documented address" \
    grep -qxF 'CALL https://wow.curseforge.com/api/game/versions' "$LOG"
expect "curseforge: uploads to the project from the .toc" \
    grep -qxF 'CALL https://wow.curseforge.com/api/projects/123456/upload-file' "$LOG"
expect "curseforge: sends the zip" grep -qxF "FILE $ZIP" "$LOG"
expect "curseforge: the token goes in through stdin" \
    grep -qF "CONFIG header = \"X-Api-Token: $CF_TOKEN\"" "$LOG"
expect "curseforge: ... never on the command line" not_in_argv "$CF_TOKEN"
expect "curseforge: metadata: Forever 1.60.1 (9001, not the retail decoy), held for release" \
    sent_metadata "{\"displayName\":\"Demo 1.2.3\",\"gameVersions\":[9001],\"releaseType\":\"release\",\"changelogType\":\"markdown\",\"changelog\":$NOTES_JSON,\"isMarkedForManualRelease\":true}"
expect "curseforge: prints the new file's id" says "555"

run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" CURSEFORGE_MANUAL_RELEASE=false curseforge "$ZIP"
expect "curseforge: CURSEFORGE_MANUAL_RELEASE=false releases once approved" \
    grep -qF '"isMarkedForManualRelease":false' "$FIX/sent-metadata.json"
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" CURSEFORGE_MANUAL_RELEASE=yes curseforge "$ZIP"
expect "curseforge: CURSEFORGE_MANUAL_RELEASE must be true or false" test "$status" -eq 1

grep -v '"name": "1.60.1", "slug": "caf' "$FIX/cf-versions.json" >"$FIX/v.json"
mv "$FIX/v.json" "$FIX/cf-versions.json"
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" GITHUB_ACTIONS=true curseforge "$ZIP"
expect "curseforge: no 1.60.1 yet uses the closest older Forever version (1.60.0)" \
    grep -qF '"gameVersions":[9000]' "$FIX/sent-metadata.json"
expect "curseforge: ... with a warning GitHub shows" says "::warning::"

printf '[{"id": 11, "gameVersionTypeID": 517, "name": "1.60.1"}]\n' >"$FIX/cf-versions.json"
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" curseforge "$ZIP"
expect "curseforge: no Forever version at all fails" test "$status" -eq 1
expect "curseforge: ... without uploading" calls 1

setup "$IDS"
printf '403' >"$FIX/post-code"
printf '{"errorMessage": "You do not have permission"}' >"$FIX/post-body"
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" curseforge "$ZIP"
expect "curseforge: an HTTP 403 answer fails" test "$status" -eq 1
expect "curseforge: ... and prints what the site said" says "You do not have permission"

setup "$IDS"
: >"$FIX/get-fails"
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" curseforge "$ZIP"
expect "curseforge: an unreachable version list fails" test "$status" -eq 1

setup "$IDS"
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" curseforge --dry-run "$ZIP"
expect "dry run: --dry-run goes before the store" test "$status" -eq 2
run_upload CURSEFORGE_API_TOKEN="$CF_TOKEN" -- --dry-run curseforge "$ZIP"
expect "dry run: -- is not an option" test "$status" -eq 2

# --- Wago -----------------------------------------------------------------------------------

setup "$IDS"
run_upload WAGO_API_TOKEN="$WAGO_TOKEN" wago "$ZIP"
expect "wago: uploads (exit 0)" test "$status" -eq 0
expect "wago: reads the patch list without the token" \
    sent_no_config https://addons.wago.io/api/data/game
expect "wago: uploads to the project from the .toc" \
    grep -qxF 'CALL https://addons.wago.io/api/projects/aBcD1234/version' "$LOG"
expect "wago: the token goes in through stdin as a Bearer header" \
    grep -qF "CONFIG header = \"Authorization: Bearer $WAGO_TOKEN\"" "$LOG"
expect "wago: ... never on the command line" not_in_argv "$WAGO_TOKEN"
expect "wago: metadata: label, stable, notes, Forever patch 1.60.1" \
    sent_metadata "{\"label\":\"1.2.3\",\"stability\":\"stable\",\"changelog\":$NOTES_JSON,\"supported_forever_patches\":[\"1.60.1\"]}"

printf '{"patches": {"forever": ["1.60.0"]}}\n' >"$FIX/wago-game.json"
run_upload WAGO_API_TOKEN="$WAGO_TOKEN" wago "$ZIP"
expect "wago: no 1.60.1 yet uses the closest older patch (1.60.0)" \
    grep -qF '"supported_forever_patches":["1.60.0"]' "$FIX/sent-metadata.json"
expect "wago: ... with a warning" says "warning"
printf '{"patches": {"retail": ["12.1.7"], "forever": ["1.61.0"]}}\n' >"$FIX/wago-game.json"
run_upload WAGO_API_TOKEN="$WAGO_TOKEN" wago "$ZIP"
expect "wago: only newer Forever patches fails" test "$status" -eq 1

setup "$IDS"
printf '500' >"$FIX/post-code"
printf 'Server Error' >"$FIX/post-body"
run_upload WAGO_API_TOKEN="$WAGO_TOKEN" wago "$ZIP"
expect "wago: an HTTP 500 answer fails" test "$status" -eq 1

# --- dry run ----------------------------------------------------------------------------------

setup "$IDS"
run_upload WAGO_API_TOKEN="$WAGO_TOKEN" --dry-run wago "$ZIP"
expect "dry run: exit 0" test "$status" -eq 0
expect "dry run: reads the patch list but uploads nothing" calls 1
expect "dry run: prints the metadata it would send" says '"supported_forever_patches":["1.60.1"]'

if [[ $failed -eq 0 ]]; then
    echo "All store upload checks passed."
else
    echo "$failed store upload check(s) failed."
    exit 1
fi
