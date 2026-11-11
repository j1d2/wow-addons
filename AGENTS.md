# Agent notes

Rules for any AI coding agent working on this repository, whoever runs it. They are the same standards human contributors follow in [CONTRIBUTING.md](CONTRIBUTING.md). Keep your agent's own config (for example `CLAUDE.md` or `.claude/`) local; git ignores those names.

This repository holds free, plain-Lua World of Warcraft addons for the Forever client (interface `16001`, mainline API). It is not a dump of one person's machine.

## Do

- Run `scripts/check.sh` before every commit, and install the hooks once per clone with `scripts/install_hooks.sh`. The hooks and CI run the same gate.
- Follow [RULES.md](RULES.md). One click, one action. At most one full auction house scan per 15 minutes, counted from the click. Seller names are never saved.
- Write the failing test first, then the code. Tests are `*_test.lua` files next to the addon. They run offline under `lua5.1`, use small synthetic data, fake the game API they need, and are never listed in a `.toc`.
- Keep game-free logic in its own file so it can be tested offline. Frames and events go in a separate file.
- Use `local` for everything. A SavedVariables table is the only global an addon writes; list it in `scripts/allowed-globals.txt`.
- Give functions a short `---` doc comment with their arguments, and comment why, not what.
- Check a game API function, event or enum against Blizzard's interface source for the Forever client before relying on it. Mark anything you could not check as unverified.
- Say what you verified (read, ran or tested) and what you inferred. Say "I don't know" rather than guess. Copy numbers from their source.
- Use placeholders such as `<WoW folder>` for paths.
- Use conventional commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`) that explain why. Stage files by name.
- Open a pull request into `main`. Say whether the change was tried in game.
- Ask the maintainer before anything destructive or public: deleting files, publishing, or changing repository settings.

## Do not

- Post, buy, bid on or cancel auctions, or act without a fresh click. Do not send requests from a timer or scan when the auction house opens.
- Run code from text (`loadstring`, `RunScript`) or obfuscate anything.
- Add a third-party library, package or tool without the maintainer's OK. Write our own version instead.
- Copy code, names or art from other addons, or from Blizzard's interface files. Reading them to learn is fine.
- Add emails, account, character or realm names, IP addresses, hostnames, or a home path that identifies someone, in files or commit messages.
- Read or print `.env` files, keys or credentials.
- Skip a check (`--no-verify`), amend a pushed commit, force-push, `git reset --hard`, or commit straight to `main`. A failed hook means no commit: fix it and make a new commit.
- Add a second license. This repository is Apache License 2.0.
- Add Blizzard art, logos, client files or copied text. The one exception is screenshots of these addons in `docs/screenshots/`, cropped and stripped as [CONTRIBUTING.md](CONTRIBUTING.md#privacy) says. The trademark notice in README and NOTICE stays.
