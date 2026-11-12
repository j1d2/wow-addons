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

`scripts/check.sh` runs every check: hygiene, the privacy and secret scan, shellcheck, the scripts' own tests, the addon checks (syntax, globals, `.toc` files, `RULES.md` limits, versions), every addon test, and line coverage. The hooks and CI run the same script.

**Coverage:** `scripts/addon_checks.sh coverage` runs each addon's tests under `scripts/lua_coverage.lua`, which uses Lua's own line hook (no packages). Each addon file must have at least 90% of its lines run. The report lists the lines that never ran, for example `not run: 6-7, 9`.

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

Tags and published releases can't be changed or deleted. A mistake gets a new PATCH version.

To build the zip locally without releasing: `scripts/package_addon.sh HouseLedger-vX.Y.Z dist`. To check a downloaded zip was built here: `gh attestation verify HouseLedger-X.Y.Z.zip --repo j1d2/wow-addons`.

## Client updates

Blizzard updates the Forever client often, usually in the Tuesday maintenance from 8:00 AM Pacific. Two kinds of update matter here:

- **A new version** (1.60.1 to 1.61.0) raises the interface number (16001 to 16100). The game then marks every addon with a lower `## Interface:` as out of date, and players must tick "Load out of date AddOns" to use it.
- **A new build** of the same version (70862 to 70888) keeps the interface number, but can still change game functions an addon calls.

The `client-watch` workflow runs `scripts/client_watch.sh` at 11:00 AM and 7:00 PM Pacific, and can be started by hand from the Actions tab. It opens an issue labeled `client-update` when:

- the version's interface number is above an addon's `## Interface:`, with a checklist for each addon; or
- a build from the last four days changed the documentation of a function or event an addon uses, or a Blizzard file an addon follows (the auction window, the secure button code, the bag windows).

It reads Forever's version from Blizzard's own version server (the one the Battle.net app uses), and the build changes from [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source/tree/forever), a community mirror of Blizzard's interface code. It never edits code, raises versions or releases. An addon is updated after it is tested on the new client:

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
