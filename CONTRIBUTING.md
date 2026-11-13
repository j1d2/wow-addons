# Contributing

Thanks for helping. These addons are small, free and plain Lua, and they stay that way.

The first part covers every addon. Then each addon has its own section: [HouseLedger](#houseledger) and [Unmaker](#unmaker).

## Before you start

- Read [`RULES.md`](RULES.md). It lists what the addons may and may not do under Blizzard's addon policy, plus this project's own stricter limits. A change that breaks it won't be merged.
- Open an issue first for anything bigger than a small fix, so we can agree on the approach.
- Be kind: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) covers issues and pull requests.
- Using an AI coding agent? Point it at [AGENTS.md](AGENTS.md). Keep its own config (`CLAUDE.md`, `.claude/` and the like) local; git ignores those names.

## Setup

[docs/development.md](docs/development.md) lists the tools for Linux, Windows (WSL 2) and macOS, and shows how to link an addon into the game. Then:

```bash
scripts/install_hooks.sh   # once per clone: pre-commit, commit-msg and pre-push hooks
scripts/check.sh           # the full gate: what the hooks and CI run
```

## How we work

- **Tests first.** Write a failing test, then the code. Tests live next to the addon as `*_test.lua`, run under `lua5.1`, and are never listed in the `.toc`. Code that needs the game API gets a small fake of that API inside its test.
- **Coverage:** the tests must run at least 90% of the lines in each addon file. The gate prints each file's percent and the lines that never ran. Bash scripts have no coverage tool here; each one has a `*_test.sh` instead.
- **Pure logic in its own file**, with no game API calls, so it can be tested offline. UI and events go in a separate file.
- **No new globals.** Use `local`. A SavedVariables table is the exception; list it in `scripts/allowed-globals.txt`.
- **Comments** explain why, not what. Every function gets a doc comment:
  - Lua: [LDoc](https://lunarmodules.github.io/ldoc/manual/manual.md) style. A `---` summary line, then `-- @param name what it is` and `-- @return what comes back`.
  - Bash: the function header from [Google's Shell Style Guide](https://google.github.io/styleguide/shellguide.html#function-comments). A summary, then `Globals:`, `Arguments:`, `Outputs:` and `Returns:` as they apply.
- **Language style:** Lua 5.1 as the game runs it, `local` everywhere, and early returns over deep nesting. Bash per Google's Shell Style Guide: `set -euo pipefail`, quoted variables, `[[ ]]` tests, and clean `shellcheck`.
- **No third-party code or libraries.** Write it yourself. Don't copy code, names or art from other addons or from Blizzard's interface files. Reading them to learn how something works is fine.
- **One click, one action.** Nothing posts, buys, bids or cancels. Nothing sends a request on its own timer.

## Privacy

The repo may be public one day, so no file or commit message may hold personal or machine details: no home folder paths, account, character, guild or realm names, or emails. Use placeholders like `<WoW folder>`. The privacy scan enforces this. Put your own names in `security/privacy-denylist.local` (git ignores it) so the scan blocks them too.

**Screenshots** go in `docs/screenshots/` as `<addon>-<what>.png`. The scan can't read images, so check them yourself:

- Crop to the addon's window. Leave out character, guild and other players' names, and chat.
- Cover or crop any line that names a realm or account.
- Strip the file's metadata, for example `magick in.png -strip out.png`.
- Keep each file under 500 KB (the hygiene check's limit).

## Commits and pull requests

- Conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`. The message says why, not just what. The `commit-msg` hook checks the subject.
- Small, focused commits. Never skip a hook (`--no-verify`), amend a pushed commit, or force-push. If a hook fails, fix the problem and make a new commit.
- Changed something a player will notice? Add a line under `## [Unreleased]` in that addon's `CHANGELOG.md`.
- Open a PR into `main`. `main` is protected: every change lands through a PR, and CI (`scripts/check.sh`) must pass first. Say in the PR whether the change was tried in game.
- On your first merged PR, add your GitHub handle to [CONTRIBUTORS.md](CONTRIBUTORS.md). Handles only.

## Adding a new addon

1. Make `addons/<Name>/` with `<Name>.toc` (`## Interface: 16001`, `## Version: 0.1.0`, `## X-License: Apache-2.0`) listing its files in load order. Use only letters, digits and `_` in `<Name>`, because release tags are `<Name>-vX.Y.Z`.
2. Put game-free logic in its own file with a `*_test.lua` beside it. Frames and events go in a second file.
3. Add its SavedVariables table to `scripts/allowed-globals.txt`.
4. Check every game API it uses against Blizzard's interface source for the Forever client.
5. Add a README section like HouseLedger's: TL;DR first (five bullets at most), a screenshot, then how to use it and what it does not do. Add a row to the README's addon table.
6. Add a section to this file for it, and to `RULES.md` if it touches a limited game system.
7. Add `CHANGELOG.md` with an `## [Unreleased]` section and a `## [0.1.0]` section. The `version` check needs the `.toc` version there.
8. To publish it on CurseForge or Wago too, the maintainer makes the project there and adds its `## X-Curse-Project-ID:` or `## X-Wago-ID:` line to the `.toc` (see `docs/development.md`).

The gate finds every folder under `addons/` on its own. No script change is needed.

---

## HouseLedger

An auction house price history. Read the auction house part of [`RULES.md`](RULES.md) before changing anything that talks to the auction house.

**Files:**

| File | What goes in it |
| --- | --- |
| `PriceLedger.lua` | Price math, saved-data layout and migrations, tooltip text. No game API calls, so it runs under plain `lua5.1`. Loads first. |
| `HouseLedger.lua` | Frames, events, `C_AuctionHouse` calls and the tooltip hook. Loads second. |
| `price_test.lua` | Tests for `PriceLedger.lua`. |
| `houseledger_test.lua` | Tests for `HouseLedger.lua`, with a fake auction house and a fake of Blizzard's auction window. |

**Limits that matter here:**

- One click sends at most one request. Scrolling, hovering and row clicks send nothing.
- A full scan only from the Scan button, at most once each 15 minutes.
- Never call a method on Blizzard's `AuctionHouseFrame`. In testing, doing that from addon code stopped every auction house search until the game restarted. Read it, anchor to it, or follow it with `hooksecurefunc`. The `policy` check flags other calls.
- The tabs switch Blizzard's tabs through the game's secure click, so the window is protected in combat. Moves, shows and tab changes wait for combat to end.
- Saved data changes need a migration in `PriceLedger.EnsureDB` and a test that loads the old layout.

**Trying it in game:** link the folder (see [docs/development.md](docs/development.md#try-an-addon-in-game)), `/reload`, and turn on Lua errors with `/console scriptErrors 1`. Say in the PR what you checked: Scan, a search, a row click, a Sell drop, and the tooltip.

---

## Unmaker

A disenchanting list. Read the Disenchanting part of [`RULES.md`](RULES.md) before changing how it casts.

**Files:**

| File | What goes in it |
| --- | --- |
| `UnmakerRules.lua` | Which items can be disenchanted, which start checked, the keep list, settings, the next item, and the same-item check. No game API calls. Loads first. |
| `UnmakerStats.lua` | Lifetime totals, fun facts, materials and the history (500 newest), with sorting. No game API calls. Loads second. |
| `Unmaker.lua` | The window and its Items, Stats, History and Settings tabs, the two secure cast buttons, events, recording each disenchant and its loot, the bag-window button, and the slash command. Loads last. |
| `Bindings.xml` | The key binding for "Disenchant next". The game loads it by name, and the release zip ships it. |
| `rules_test.lua` | Tests for `UnmakerRules.lua`. |
| `stats_test.lua` | Tests for `UnmakerStats.lua`. |
| `unmaker_test.lua` | Tests for `Unmaker.lua`, with a fake of the bags, spell and loot events, combat, and the secure click. |

**Limits that matter here:**

- Only the secure buttons cast. Set them in `PreClick`, clear them in `PostClick`, never in combat.
- Check the slot still holds the exact item before every cast.
- The buttons stay locked from the cast's start until the loot window closes and the bags update, with a 10-second fallback.
- The secure buttons make the window protected. Showing, hiding and moving wait for combat to end.

**Trying it in game:** use a character with Enchanting. Check a full cycle (cast, loot, unlock), an Epic (starts unchecked), a failed cast (moving) that keeps the item, an equipment-set item (hidden), the key binding, and combat (clicks do nothing).

---

## License

By contributing, you agree that your work is licensed under the [Apache License 2.0](LICENSE), the same as the rest of the project (section 5 of the license).
