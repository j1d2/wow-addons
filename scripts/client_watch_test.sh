#!/usr/bin/env bash
# Offline checks for scripts/client_watch.sh. Fake `curl` and `gh` commands, first on PATH, serve
# prepared answers from a fixture folder and record the issues the script would open. Fixtures
# live in .check-tmp/ (git ignores it), removed on exit.
#
# Usage: scripts/client_watch_test.sh
# No -e: each check reports its own result, and a failed one must not stop the rest.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

readonly ROOT="$PWD/.check-tmp/watch-test"
readonly FIX="$ROOT/fixtures"
readonly BIN="$ROOT/bin"
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
# Build a repo with two addons, fake curl and gh, and a quiet day: Forever 1.60.1 (interface
# 16001, which both addons list), and one new build that changed nothing they use.
# Globals:
#   ROOT, FIX, BIN
#######################################
setup() {
    [[ ! -d "$ROOT" ]] || rm -r "$ROOT"
    mkdir -p "$ROOT/addons/Alpha" "$ROOT/addons/Beta" "$FIX" "$BIN"
    printf '## Interface: 16001\n## Version: 1.0.0\n\nAlpha.lua\n' >"$ROOT/addons/Alpha/Alpha.toc"
    printf 'local info = C_Container.GetContainerItemInfo(0, 1)\n' >"$ROOT/addons/Alpha/Alpha.lua"
    printf 'GetContainerItemInfo = nil\n' >"$ROOT/addons/Alpha/alpha_test.lua"
    printf '## Interface: 16001\n## Version: 2.0.0\n\nBeta.lua\n' >"$ROOT/addons/Beta/Beta.toc"
    printf 'local ok = C_SpellBook.ContainsAnyDisenchantSpell()\n' >"$ROOT/addons/Beta/Beta.lua"

    cat >"$FIX/versions.txt" <<'EOF'
Region!STRING:0|BuildConfig!HEX:16|CDNConfig!HEX:16|KeyRing!HEX:16|BuildId!DEC:4|VersionsName!String:0|ProductConfig!HEX:16
## seqn = 1
us|aa|bb||70888|1.60.1.70888|cc
eu|aa|bb||70888|1.60.1.70888|cc
EOF
    printf 'bbb222\taaa111\t1.60.1 (70888)\nccc333\tddd444\tMonitor wowf product\n' >"$FIX/commits.tsv"
    cat >"$FIX/compare-bbb222.txt" <<'EOF'
FILE Interface/AddOns/Blizzard_APIDocumentationGenerated/PartyInfoDocumentation.lua
-			Name = "GetPartyThing",
+			Name = "GetPartyThing2",
EOF
    : >"$FIX/issues.txt"
    : >"$FIX/created.txt"

    cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
[[ -f "$WATCH_FIX/curl-fails" ]] && exit 22
cat "$WATCH_FIX/versions.txt"
EOF
    cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"/commits?"*) cat "$WATCH_FIX/commits.tsv" ;;
    *"/compare/"*)
        all="$*" # trim the whole line; ${*##...} would trim each argument on its own
        sha="${all##*...}"
        sha="${sha%% *}"
        [[ ! -f "$WATCH_FIX/compare-$sha.txt" ]] || cat "$WATCH_FIX/compare-$sha.txt"
        ;;
    "issue list"*) cat "$WATCH_FIX/issues.txt" ;;
    "issue create"*)
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --title) printf 'TITLE %s\n' "$2" >>"$WATCH_FIX/created.txt"; shift ;;
                --body-file) cat "$2" >>"$WATCH_FIX/created.txt"; shift ;;
            esac
            shift
        done
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
    chmod +x "$BIN/curl" "$BIN/gh"
}

#######################################
# Run the watcher on the fixture repo with the fakes first on PATH.
# Globals:
#   ROOT, FIX, BIN
#   out, status, created (set to its output, exit status and the issues it opened)
#######################################
run_watch() {
    out="$(PATH="$BIN:$PATH" WATCH_FIX="$FIX" scripts/client_watch.sh --root "$ROOT" 2>&1)"
    status=$?
    created="$(cat "$FIX/created.txt")"
}

setup
run_watch
if [[ $status -eq 0 && -z "$created" && "$out" == *"1.60.1.70888"*"interface 16001"* ]]; then rc=0; else rc=1; fi
check "a quiet day opens no issue and reports the version" "$rc"
if [[ "$out" == *"up to date"* ]]; then rc=0; else rc=1; fi
check "and says the addons are up to date" "$rc"

setup
sed -i 's/1\.60\.1\.70888/1.61.0.71000/g' "$FIX/versions.txt"
run_watch
if [[ $status -eq 0 && "$created" == *"TITLE WoW Forever 1.61.0 is out: update the addons"* ]]; then rc=0; else rc=1; fi
check "a new version opens an update issue" "$rc"
if [[ "$created" == *"Alpha"*"16001"*"16100"* && "$created" == *"Beta"* ]]; then rc=0; else rc=1; fi
check "the issue lists each out-of-date addon with old and new interface numbers" "$rc"

setup
sed -i 's/1\.60\.1\.70888/1.61.0.71000/g' "$FIX/versions.txt"
printf 'WoW Forever 1.61.0 is out: update the addons\n' >"$FIX/issues.txt"
run_watch
if [[ $status -eq 0 && -z "$created" ]]; then rc=0; else rc=1; fi
check "an issue that already exists isn't opened again" "$rc"

setup
cat >"$FIX/compare-bbb222.txt" <<'EOF'
FILE Interface/AddOns/Blizzard_APIDocumentationGenerated/ContainerDocumentation.lua
-			Name = "GetContainerItemInfo",
+			Name = "GetContainerItemInfoNew",
FILE Interface/AddOns/Blizzard_FrameXML/SecureTemplates.lua
+-- a comment
EOF
run_watch
if [[ $status -eq 0 && "$created" == *"TITLE WoW Forever build 70888 changed game APIs our addons use"* ]]; then rc=0; else rc=1; fi
check "a build that changes an API an addon uses opens an issue" "$rc"
if [[ "$created" == *"GetContainerItemInfo"*"addons/Alpha/Alpha.lua"* ]]; then rc=0; else rc=1; fi
check "the issue names the API and the addon file that uses it" "$rc"
if [[ "$created" != *"alpha_test.lua"* ]]; then rc=0; else rc=1; fi
check "test files don't count as uses" "$rc"
if [[ "$created" == *"SecureTemplates.lua"* ]]; then rc=0; else rc=1; fi
check "a change to a Blizzard file the addons rely on is listed too" "$rc"

setup
sed -i 's/1\.60\.1\.70888/1.61.0.71000/g' "$FIX/versions.txt"
out="$(PATH="$BIN:$PATH" WATCH_FIX="$FIX" scripts/client_watch.sh --root "$ROOT" --dry-run 2>&1)"
status=$?
created="$(cat "$FIX/created.txt")"
if [[ $status -eq 0 && -z "$created" && "$out" == *"Would open: WoW Forever 1.61.0 is out"* ]]; then rc=0; else rc=1; fi
check "--dry-run prints the issue instead of opening it" "$rc"

setup
cat >"$FIX/compare-bbb222.txt" <<'EOF2'
FILE Interface/AddOns/Blizzard_APIDocumentationGenerated/OtherDocumentation.lua
@@ -10,7 +10,7 @@
 			Name = "GetSomethingElse",
 			Type = "Function",
-				{ Name = "id", Type = "number", Nilable = false },
+				{ Name = "id", Type = "number", Nilable = true },
EOF2
printf 'local id = 1\n' >>"$ROOT/addons/Beta/Beta.lua"
run_watch
if [[ $status -eq 0 && -z "$created" ]]; then rc=0; else rc=1; fi
check "a changed field like 'id' inside an unrelated function opens no issue" "$rc"

setup
cat >"$FIX/compare-bbb222.txt" <<'EOF2'
FILE Interface/AddOns/Blizzard_APIDocumentationGenerated/ContainerDocumentation.lua
@@ -30,9 +30,9 @@
 			Name = "GetContainerItemInfo",
 			Type = "Function",
 			Arguments =
-				{ Name = "slotIndex", Type = "luaIndex", Nilable = false },
+				{ Name = "slotIndex", Type = "luaIndex", Nilable = true },
EOF2
run_watch
if [[ "$created" == *"GetContainerItemInfo"*"addons/Alpha/Alpha.lua"* && "$created" != *"slotIndex"* ]]; then rc=0; else rc=1; fi
check "a changed argument is reported as its function's change" "$rc"

setup
cat >"$FIX/compare-bbb222.txt" <<'EOF2'
FILE Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua
@@ -1,6 +1,6 @@
 			Name = "UnitSpellcastStart",
 			Type = "Event",
 			LiteralName = "UNIT_SPELLCAST_START",
-				{ Name = "spellID", Type = "number", Nilable = false },
+				{ Name = "spellID", Type = "number", Nilable = true },
EOF2
printf 'frame:RegisterEvent("UNIT_SPELLCAST_START")\n' >>"$ROOT/addons/Beta/Beta.lua"
run_watch
if [[ "$created" == *"UNIT_SPELLCAST_START"*"addons/Beta/Beta.lua"* && "$created" != *"spellID"* ]]; then rc=0; else rc=1; fi
check "a changed event argument is reported under the event's name" "$rc"

setup
touch "$FIX/curl-fails"
run_watch
if [[ $status -ne 0 && "$out" == *"version server"* && -z "$created" ]]; then rc=0; else rc=1; fi
check "if Blizzard's version server can't be read, the run fails loudly" "$rc"

setup
printf 'garbage\n' >"$FIX/versions.txt"
run_watch
if [[ $status -ne 0 && "$out" == *"no Forever version"* ]]; then rc=0; else rc=1; fi
check "an answer with no US version fails loudly too" "$rc"

if [[ $failed -gt 0 ]]; then
    printf '%d watch test(s) failed.\n' "$failed" >&2
    exit 1
fi
echo "all passed"
