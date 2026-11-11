# Security and privacy checks

How this repo stays safe to share. The policy for reporting a problem is in [`SECURITY.md`](../SECURITY.md).

## Automatic scans (every commit, push and PR)

`scripts/check.sh` runs these. The git hooks and CI run the same script.

| Check | Script | What it stops |
| --- | --- | --- |
| Privacy | `scripts/privacy_scan.sh` | Home, mount and Wine paths, WoW account folders, email addresses, private IP addresses, plus any name in your local denylist |
| Secrets | `scripts/privacy_scan.sh` | Private keys, AWS keys, GitHub, Slack and API tokens, hard-coded passwords |
| Commit messages | `.githooks/commit-msg` | The same privacy and secret rules, run on the message text |
| Addon policy | `scripts/addon_checks.sh policy` | Calls that `RULES.md` forbids: post, buy, bid or cancel, code run from text (`loadstring`, `RunScript`), `setfenv`/`getfenv`, the `debug` library and `RunMacro`. Chat, addon and Battle.net messages, and changes to settings, keybindings or macros, need a `-- reviewed: <why>` note on the line. |
| Globals | `scripts/addon_checks.sh globals` | Stray global variables, which can collide with other addons or be overwritten by them |
| File hygiene | `scripts/hygiene_check.sh` | Big files (over 500 KB), conflict markers, mixed line endings |

The scans print only the file, line and rule, never the matched text, so CI logs don't leak anything either.

**Your own names:** copy `privacy-denylist.example` to `privacy-denylist.local` (git ignores it) and list your account, character and realm names. The local checks then block them too.

**Screenshots:** the scans skip images, so a person checks each one before it is committed. [CONTRIBUTING.md](../CONTRIBUTING.md#privacy) has the steps: crop out names and realms, and strip the metadata.

**Git history:** `scripts/privacy_scan.sh --history` reports matches in old commits. It never fails, because removing them would need a history rewrite, which this repo never does. Run it before the repo is made public. If it finds anything, publish a fresh repo instead of flipping this one to public. That is how this public repo started (2026-11-10): its history begins with one commit of the files as they were, and the earlier work stays in a private archive.

## Supply chain

- No third-party packages. The checks are plain bash plus the Lua 5.1 tools.
- CI installs only Ubuntu's own `lua5.1` and `shellcheck` packages, on a GitHub-hosted runner.
- Only GitHub's own actions are used (`actions/checkout`, and `actions/attest-build-provenance` for releases), each pinned to a full commit SHA. Dependabot proposes updates after a 14-day cooldown.
- Release zips are built by the `release` workflow from a tag on `main`, after the full gate passes, and get a signed build-provenance record. Check a zip with `gh attestation verify <zip> --repo j1d2/wow-addons`.
- A dedicated secret scanner such as gitleaks would add more rules. It is a third-party tool, so it is not used without the owner's OK.

## Repository settings

Set on GitHub, not in files, so they are written down here. Re-check them after any change of visibility.

- **Ruleset "Protect main"** (no one can bypass it, the owner included): changes land only through a pull request, CI's `check` must pass on a branch that is up to date with `main`, review threads must be resolved, and `main` can't be force-pushed or deleted. No approval count is set, because a sole maintainer can't approve their own pull request.
- **Actions:** only GitHub's own actions may run, pinned to a full commit SHA. Workflows get a read-only token and can't approve pull requests.
- **Ruleset "Protect release tags"** (no bypass): tags like `HouseLedger-v0.3.0` can't be moved or deleted.
- **Releases are immutable:** once published, a release's zip and tag can't change. A fix is a new version.
- **Merged branches** are deleted automatically.
- **Dependabot alerts** are on.

**Before making the repo public:**

1. Run `scripts/privacy_scan.sh --history`. If it finds anything, see the Git history note above.
2. Read the pull request and issue text too. It goes public with the repo, and the history scan doesn't cover it.

**Right after making it public** (these need a public repo, or a paid plan):

1. Turn on secret scanning and push protection.
2. Turn on private vulnerability reporting. `SECURITY.md` points people to it.
3. Under Actions, require approval before workflows run on pull requests from all outside contributors.
4. Turn on CodeQL default setup. It checks the workflow files; it has no Lua support.
5. Check the community profile under **Insights**. Every file it asks for is already here.

## Addon security review (2026-11-09, HouseLedger)

An addon runs inside the game client's Lua sandbox, which Blizzard controls. The review looked at what the addon itself could get wrong.

- **No network and no messages:** it sends no chat or addon messages and no data to other players. It talks only to Blizzard's auction house API.
- **No code from text:** no `loadstring` or `RunScript`, and the policy check blocks them.
- **Saved data:** `HouseLedgerDB` is a local file the player owns. `PriceLedger.EnsureDB` and the lookup code check types before use, so a damaged file can't crash the tooltip.
- **User input:** search text goes only to Blizzard's `SendBrowseQuery` (from a click or Enter) and back into the addon's own status line.
- **Privacy:** seller names are never saved. The HouseLedger harness (`houseledger_test.lua`) feeds seller names in and checks that none reach saved data.

Verdict: low risk. Recheck this section when an addon adds chat or addon messages, slash commands that run actions, or reads data from other players. The policy check makes the first of those visible: each such call needs a `-- reviewed:` note.

**No Lua security scanner:** there is no official one. Semgrep's Lua support is experimental, with mostly code-quality rules, and it would be a third-party tool. These addons have no dependencies to scan, so the project's own policy check, written for WoW's API, is the security scan.
