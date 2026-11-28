# Development

How to set up, check and try the addons, and how a release is made. [CONTRIBUTING.md](../CONTRIBUTING.md) covers how we work: tests first, commits, pull requests and privacy.

## What you need

| Tool | What it's for |
| --- | --- |
| `git` | the code |
| `bash` 4 or newer, with GNU `sed`, `find` and coreutils | the checks and git hooks in `scripts/` and `.githooks/` |
| `lua5.1` and `luac5.1` | the Lua the game runs: tests, syntax and global checks |
| `shellcheck` | lints the scripts |
| `zip` and `unzip` | release zips and their test |

Nothing else: no package managers, no libraries.

### Linux

| Distribution | Install |
| --- | --- |
| Debian, Ubuntu and their family | `sudo apt install git lua5.1 shellcheck zip unzip` |
| Fedora and its family | `sudo dnf install git compat-lua ShellCheck zip unzip` |
| Arch and its family | `sudo pacman -S git lua51 shellcheck zip unzip` |

Fedora names the Lua tools `lua-5.1` and `luac-5.1`. Tell the scripts by adding this to `~/.bashrc`:

```bash
export LUA=lua-5.1 LUAC=luac-5.1
```

### Windows 11: WSL 2

The scripts are bash, so on Windows they run in WSL 2, Microsoft's built-in Linux. PowerShell alone can't run them.

1. Open PowerShell as administrator (right-click, **Run as administrator**) and run `wsl --install`. Restart when it asks. This installs Ubuntu. For another distribution, list them with `wsl --list --online` and install one with `wsl --install -d <Distro>`.
2. Open the distribution from the Start menu, create your Linux user, and run its install line from the Linux table above.
3. Clone the repo onto a Windows drive, so the game can load the addon from it. In WSL, a Windows drive is under `/mnt/<drive letter>/`.
4. Run git and the scripts from the WSL terminal. Line endings stay Unix style because `.gitattributes` sets them for every system.

### macOS (untested)

macOS ships bash 3.2 and BSD versions of `sed`, `find` and `touch`, and the scripts need the GNU versions. If you set this up, please tell us whether these steps worked.

1. Install the GNU tools with [Homebrew](https://brew.sh/), and put them first on your `PATH` in `~/.zshrc`:

   ```bash
   brew install bash coreutils gnu-sed findutils shellcheck
   export PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:$(brew --prefix)/opt/gnu-sed/libexec/gnubin:$(brew --prefix)/opt/findutils/libexec/gnubin:$(brew --prefix)/bin:$PATH"
   ```

2. Homebrew no longer has Lua 5.1, so build it from [lua.org](https://www.lua.org/ftp/). Check the download against the SHA-256 that lua.org lists. Then tell the scripts where it is:

   ```bash
   curl -O https://www.lua.org/ftp/lua-5.1.5.tar.gz
   shasum -a 256 lua-5.1.5.tar.gz   # 2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333
   tar xzf lua-5.1.5.tar.gz && cd lua-5.1.5 && make macosx && sudo make install
   export LUA=/usr/local/bin/lua LUAC=/usr/local/bin/luac   # add this to ~/.zshrc too
   ```

`zip` and `unzip` come with macOS.

## First run

```bash
git clone https://github.com/j1d2/wow-addons.git
cd wow-addons
scripts/install_hooks.sh   # once per clone: pre-commit, commit-msg and pre-push hooks
scripts/check.sh           # the full gate: what the hooks and CI run
```

`scripts/check.sh` runs every check: hygiene, the privacy and secret scan, shellcheck, the scripts' own tests, the addon checks (syntax, Lua's limits, globals, `.toc` files, `RULES.md` limits, versions), every addon test, line coverage, and the speed and memory smoke run. The hooks and CI run the same script.

**Coverage:** `scripts/addon_checks.sh coverage` runs each addon's tests under `scripts/lua_coverage.lua`, which uses Lua's own line hook (no packages). Each addon file must have at least 90% of its lines run. The report lists the lines that never ran, for example `not run: 6-7, 9`.

## Code layout

Each addon is plain Lua 5.1, the version the game runs, split into files that its `.toc` lists in load order. The game hands every file two values, `local ADDON_NAME, ns = ...`: the addon's folder name and one table that only that addon's files share. The files share code and state through `ns`, not through globals. The only globals an addon makes are its saved variables and slash commands, which `scripts/allowed-globals.txt` lists, and the few frames that need a name (Escape closes a window only by its name).

HouseLedger loads in this order:

| File | What it holds |
| --- | --- |
| `PriceLedger.lua` | Price history and stats as pure data (`ns.Price`): no frames and no game calls, so `price_test.lua` runs it under plain `lua5.1`. |
| `Core.lua` | Makes the shared tables: `ns.C` (constants more than one file uses), `ns.ui` (shared frames), `ns.state` (shared state), and one table per file below. Small helpers (`ns.U`): money text, the player's house, item looks, font-string cells. |
| `Chart.lua` | The price chart (`ns.Chart`). |
| `Tooltip.lua` | Saved prices on item tooltips (`ns.Tooltip`). |
| `Scan.lua` | The full scan and its 15-minute wait (`ns.Scan`). |
| `Buy.lua` | The Buy and Market tabs: list, headings, filters, details, the browse search (`ns.Buy`). |
| `Sell.lua` | The Sell tab (`ns.Sell`). |
| `Purchase.lua` | Buying from Buy and Market: the picked row's Buy (one item search), the listings, Buy and Confirm (`ns.Purchase`). Settings `confirmItemBuys`/`confirmStackBuys` (default on) skip Confirm: gear buys on Buy, a stackable confirms on a quote not above the listings. The only file the `policy` check lets buy. |
| `Post.lua` | Posting from the Sell tab (`ns.Post`): price, how many, how long, warnings, Confirm, Post. The only file the `policy` check lets post. |
| `PriceCheck.lua` | The `/pc` window and its bag button (`ns.PC`). |
| `History.lua` | The History tab: buys and sales from HouseLedger's own buys and the auction house mail (`ns.History`; the pure records are in `PriceLedger`). Reads the mailbox only. |
| `Auctions.lua` | The Auctions tab: the player's own auctions, asked once per tab click (`QueryOwnedAuctions`) or read when Blizzard's tab asks, saved per house and character, and compared with the last scan (`ns.Auctions`; the pure parts are in `PriceLedger`). Never cancels; never reads the bidder. |
| `Settings.lua` | The Settings tab (`ns.Settings`). |
| `Window.lua` | The window, its tabs, its place beside the auction house, and following Blizzard's window (`ns.Window`). |
| `HouseLedger.lua` | Events. It loads last. |

- A function another file calls is a field of its file's table (`function Buy.RenderRows()`); a function only its own file uses stays `local`. Table fields are looked up when the code runs, so a file can call one that loads after it.
- A constant or piece of state that only one file uses stays a `local` in that file.
- `houseledger_test.lua` loads the files the way the game does: it reads the `.toc` and runs each file with the addon's name and one shared table.
- A new file in the `.toc` needs a full game restart; `/reload` doesn't read the `.toc` again.

**Lua 5.1 limits.** One function, a file's main chunk included, holds at most 200 local variables, and one closure at most 60 upvalues (the outer locals it uses). `luac` refuses a file past either. `scripts/addon_checks.sh limits` fails earlier, at 160 locals or 48 upvalues, and says where. The fix is to move code into another file, or read shared names through a table such as `ns.C` or `ns.state`, which counts as one name.

## Speed and memory

`scripts/bench.sh` times the pure Lua parts of both addons (price math, the Market lists, Price Check search, Unmaker's history) on made-up data from `bench/synth.lua`. It never reads a real saved file.

```bash
scripts/bench.sh --smoke   # small sizes with budgets; the gate runs it
scripts/bench.sh --full    # 6,600 and 20,000 items at 14, 30 and 60 days; about 30 seconds
```

Each step prints its time and the memory it allocates. Each data set prints the memory it keeps and how many different values its saved file holds. [bench/README.md](../bench/README.md) explains the numbers, the budgets and the constant limit.

## Try an addon in game

Link the addon's folder into the game's `AddOns` folder, so a `/reload` in game picks up your edits. A new addon folder needs a game restart. Turn on Lua errors in game with `/console scriptErrors 1`.

**Linux and macOS**, from the repo root:

```bash
ln -s "$PWD/addons/HouseLedger" "<WoW folder>/_forever_/Interface/AddOns/HouseLedger"
```

**Windows 11**, in PowerShell (no administrator needed). A junction is a folder link that Windows and the game follow:

```powershell
New-Item -ItemType Junction -Path "<WoW folder>\_forever_\Interface\AddOns\HouseLedger" -Target "<repo folder>\addons\HouseLedger"
```

`<WoW folder>` is the `World of Warcraft` folder, and `<repo folder>` is the clone on your Windows drive.

## Versions and releases

Each addon has its own version, changelog, tags, zips and releases.

**Versions** follow [Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH` in the `## Version:` line of the addon's `.toc`.

| Bump | When |
| --- | --- |
| PATCH (0.3.0 to 0.3.1) | Bug fixes only. Saved data still loads. |
| MINOR (0.3.1 to 0.4.0) | New features. Saved data from older versions still loads, migrated if needed. |
| MAJOR (0.4.0 to 1.0.0) | Saved data an older version can't read, or a removed feature. |

While the version starts with 0, a MINOR bump may also change or remove things.

**Changelog:** each addon has a `CHANGELOG.md` in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. A pull request that changes what players see adds a line under `## [Unreleased]`. The `version` check fails if the `.toc` version has no `## [X.Y.Z]` section.

**Making a release** (maintainer):

1. In a pull request, rename the `## [Unreleased]` lines to a new `## [X.Y.Z] - YYYY-MM-DD` section, add an empty `## [Unreleased]` above it, and set `## Version: X.Y.Z` in the `.toc`.
2. Merge it. Then tag the merged commit on `main` and push the tag:

   ```bash
   git switch main && git pull --ff-only
   git tag -a HouseLedger-vX.Y.Z -m "HouseLedger X.Y.Z"
   git push origin HouseLedger-vX.Y.Z
   ```

3. The `release` workflow checks that the tag is on `main` and runs the full gate. It builds `HouseLedger-X.Y.Z.zip` (the addon's folder with its `CHANGELOG.md`, `LICENSE` and `NOTICE`, no test files) and signs its build provenance. Then it publishes the release, with this version's changelog section as the notes.

4. The `stores` jobs then upload the same zip to CurseForge and Wago, one job per site (see below). An addon that isn't listed on a site is skipped there.

Tags and published releases can't be changed or deleted. A mistake gets a new PATCH version.

### CurseForge and Wago

Both sites have a WoW Forever category, and the upload puts the addon only there. WoWInterface has no Forever category, so we don't publish there. Other game versions (Retail, Classic) are not supported unless someone contributes them.

`scripts/store_upload.sh` does the upload with plain `curl`; it doesn't use the BigWigs packager, which is a third-party action. It reads everything from inside the release zip:

- the site's project ID from the `.toc`: `## X-Curse-Project-ID: <number>` and `## X-Wago-ID: <id>`. No line means the addon isn't listed on that site, and the job skips it;
- the game version from `## Interface:` (16001 is Forever 1.60.1). If a site doesn't list that version yet, the file gets the closest older one, with a warning. The script uploads only Forever interfaces (16xxx);
- the notes from this version's `CHANGELOG.md` section.

CurseForge holds each new file until you press release on the project's Files page. To let files go live once CurseForge approves them, set the repo variable `CURSEFORGE_MANUAL_RELEASE` to `false`.

**One-time setup** (maintainer, per site):

1. Make the project on [CurseForge](https://authors.curseforge.com/) or [Wago](https://addons.wago.io/developers), with WoW Forever as its game version. CurseForge wants a one-sentence summary and a 400×400 icon that isn't one flat color, and doesn't allow download links to other sites (a link to this repo goes at the bottom of the description).
2. Add the project's ID line to the addon's `.toc` in a pull request.
3. Make an API token ([CurseForge](https://authors.curseforge.com/#/settings/api-tokens), [Wago](https://addons.wago.io/account/apikeys)) and save it in the repo's `stores` environment. Paste it when asked, so it stays out of your shell history:

   ```bash
   gh secret set CURSEFORGE_API_TOKEN --env stores --repo j1d2/wow-addons
   gh secret set WAGO_API_TOKEN --env stores --repo j1d2/wow-addons
   ```

The next release tag uploads it. Check what would be sent, without uploading: `CURSEFORGE_API_TOKEN=... scripts/store_upload.sh --dry-run curseforge dist/HouseLedger-X.Y.Z.zip` (a dry run also needs the site's token). If one site's job fails, use **Re-run failed jobs**: it retries only that site, so the other site doesn't get the file twice.

To build the zip locally without releasing: `scripts/package_addon.sh HouseLedger-vX.Y.Z dist`. To check a downloaded zip was built here: `gh attestation verify HouseLedger-X.Y.Z.zip --repo j1d2/wow-addons`.

## Client updates

Blizzard updates the Forever client often, usually in the Tuesday maintenance from 8:00 AM Pacific. Two kinds of update matter here:

- **A new version** (1.60.1 to 1.61.0) raises the interface number (16001 to 16100). The game then marks every addon with a lower `## Interface:` as out of date, and players must tick "Load out of date AddOns" to use it.
- **A new build** of the same version (70862 to 70888) keeps the interface number, but can still change game functions an addon calls.

The `client-watch` workflow runs `scripts/client_watch.sh` at 11:00 AM and 7:00 PM Pacific, and can be started by hand from the Actions tab. It opens an issue labeled `client-update` when:

- the version's interface number is above an addon's `## Interface:`, with a checklist for each addon; or
- a build from the last four days changed the documentation of a function or event an addon uses, or a Blizzard file an addon follows (the auction window, the secure button code, the bag windows).
- a build changed 300 or more files (the most GitHub's comparison lists), or an API file too large to show, so it must be checked by hand.

It reads Forever's version from Blizzard's version server (`us.version.battle.net`), and the build changes from [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source/tree/forever), a community mirror of Blizzard's interface code. It never edits code, raises versions or releases. An addon is updated after it is tested on the new client:

1. Read what changed, run `scripts/check.sh`, and try the addon in game.
2. Fix what broke, set `## Interface:` to the new number, raise the PATCH version, and add a changelog line.
3. Merge, then tag and release as above.

Try it without opening issues: `scripts/client_watch.sh --dry-run`.

GitHub can start a scheduled run late, and pauses schedules on a public repo after 60 days with no activity (it emails first); turn it back on from the Actions tab.

## More

- [CONTRIBUTING.md](../CONTRIBUTING.md): how we work, with notes for each addon
- [RULES.md](../RULES.md): what the addons may and may not do
- [AGENTS.md](../AGENTS.md): the rules AI coding agents follow here
- [security/README.md](../security/README.md): the scans and the repository settings
- [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) and [SECURITY.md](../SECURITY.md)
