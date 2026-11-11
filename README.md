# wow-addons

<p align="center">

[![Lua 5.1](https://img.shields.io/badge/Lua_5.1-2C2D72?style=for-the-badge&logo=lua&logoColor=white)](https://www.lua.org/manual/5.1/)
[![WoW Forever](https://img.shields.io/badge/WoW_Forever-16001-148EFF?style=for-the-badge)](RULES.md)
[![Apache 2.0](https://img.shields.io/badge/Apache_2.0-blue?style=for-the-badge)](LICENSE)

</p>

Free, plain-Lua World of Warcraft addons for the Forever client (interface `16001`).

These are unofficial player addons. They are not affiliated with, endorsed by, or sponsored by Blizzard Entertainment or Microsoft.

**Status: alpha.** HouseLedger is being tested in game. Found a bug or have an idea? [Open an issue](https://github.com/j1d2/wow-addons/issues/new/choose). Every addon here is free and its code stays public, as Blizzard's [UI Add-On Development Policy](https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534) requires.

## Addons

| Addon | In one line |
| --- | --- |
| [HouseLedger](#houseledger) | Remembers auction house prices, so you can see what's cheap today and what to sell for. |

## Install

1. Quit the game. New addon folders are picked up on the next launch.
2. On this page, click **Code**, then **Download ZIP**, and unzip it.
3. Copy the addon's folder (for example `addons/HouseLedger`) into `<WoW folder>/_forever_/Interface/AddOns/`. The folder that holds the `.toc` file goes straight into `AddOns`.
4. Start the game and enable the addon on the character screen's **AddOns** list.

Working on the code? Link the folder instead, so edits load with `/reload`. Run this from the repo root:

```bash
ln -s "$PWD/addons/HouseLedger" \
  "<WoW folder>/_forever_/Interface/AddOns/HouseLedger"
```

---

## HouseLedger

Auction house prices, remembered. One Scan a day builds a 14-day price history on your own computer.

### TL;DR

- **Scan** at the auction house saves today's prices (once each 15 minutes).
- **Hover any item:** the last price, a trend arrow and a deal icon. Hold **Shift** for more.
- **Buy tab:** search, then compare today's price with your 7-day average. Click a row for 1, 3, 7 and 14 days.
- **Sell tab:** drop an item in to see the lowest price now and its history. Then post it in Blizzard's window.
- **Never** buys, posts or scans by itself.

<p align="center">
  <img src="docs/screenshots/houseledger-buy.png" alt="HouseLedger Buy tab: search results with price, available, 7-day average and trend, and the saved stats for the selected row" width="420">
  <img src="docs/screenshots/houseledger-sell.png" alt="HouseLedger Sell tab: lowest price now, how many are up, and saved averages over 1, 3, 7 and 14 days with the trend" width="420">
</p>
<p align="center"><sub>Buy tab (left) and Sell tab (right). Game art in the screenshots © Blizzard Entertainment, Inc.</sub></p>

### How to use it

1. Open the auction house. HouseLedger's window opens on the right.
2. Click **Scan** once. A deal or trend needs a few scans on different days.
3. **Buy:** type a name, then **Search**. A green arrow means cheaper than usual, and a star means a deal. **Clear** empties the list.
4. **Sell:** drop an item from your bags on the Sell tab, or right-click it in your bags. **Reset** empties the tab.

Its Buy and Sell tabs switch Blizzard's tabs too, and the reverse.

### Good to know

- Prices are the **cheapest asking price**, not what items sold for.
- "1 day" means today's scans. History keeps 14 calendar days.
- Trends start from the 3rd scan, deals from the 5th. A price within 10% of its 7-day average shows as a grey "steady".
- A deal is at least 25% under the average and well below the usual range (2 standard deviations).
- Prices are kept per faction house (Alliance, Horde, neutral) and saved per account in `HouseLedgerDB`.
- In combat the window waits until combat ends before it moves or switches tabs. That's a game rule.

### What it does not do

- It does not post, buy, bid or cancel. You do that in Blizzard's window.
- It does not scan when the auction house opens. A full scan needs your click, at most once each 15 minutes, which is the game's limit.
- Search and Sell send one request per click. Scrolling, hovering and clicking a row send nothing.
- It does not save seller names or send anything to other players.

[`RULES.md`](RULES.md) lists everything these addons may and may not do.

---

## Development

One gate runs every check: Lua syntax, tests, TOC files, accidental globals, the `RULES.md` API limits, file hygiene, shell lint and a privacy and secret scan. The git hooks and CI both run it.

```bash
scripts/install_hooks.sh   # once per clone
scripts/check.sh           # run it yourself any time
```

It needs `lua5.1`, `luac5.1` and `shellcheck`.

- [CONTRIBUTING.md](CONTRIBUTING.md): the workflow, with notes for each addon.
- [AGENTS.md](AGENTS.md): the rules AI coding agents follow here.
- [security/README.md](security/README.md): the scans and the repository settings.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md): how we treat each other in issues and pull requests.
- [SECURITY.md](SECURITY.md): report a security or privacy problem privately.

## Trademarks and copyright

World of Warcraft, WoW, Warcraft, Battle.net, and Blizzard are trademarks or registered trademarks of Blizzard Entertainment, Inc. in the U.S. and/or other countries. Other names are the property of their respective owners.

The code is original addon code. It does not include Blizzard's client files, interface code, or copied text from their games or website. The screenshots in `docs/screenshots/` show these addons in the game. The game art in them is © Blizzard Entertainment, Inc., shown here for noncommercial use under the terms of [Blizzard's legal FAQ](https://www.blizzard.com/en-us/legal/28d5ebbf-c245-4408-8ba9-043dd5f056bf/legal-faq), and is not covered by this project's license. Naming a product or a game API here is only so a reader can find it.

## License

[Apache License 2.0](LICENSE). A pull request is a contribution under that license. The license covers this project's own code. It does not cover Blizzard's games, art, or trademarks. Blizzard's addon policy also applies to any shared copy: it must stay free and readable.
