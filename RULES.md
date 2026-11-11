# Rules for these addons

Checked against Blizzard's published rules on 2026-11-09, before this repository was created.

Sources:

- [UI Add-On Development Policy](https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534) (Kaivax, still the posted policy)
- Blizzard End User License Agreement, license limits on bots, cheats, and hacks
- [Policy update for input broadcasting software](https://worldofwarcraft.blizzard.com/en-us/news/23558957/policy-update-for-input-broadcasting-software)
- Warcraft Wiki, Patch 1.60.1 API changes, and `C_AuctionHouse.SendBrowseQuery`

## Allowed

- Plain Lua addons that use the API the Forever client exposes. Forever is interface `16001` and the mainline API, not the Classic Era API.
- Showing auction data the server already returned.
- A search that starts from a button click, or from an item dropped on a slot (one mouse release), and only when `C_AuctionHouse.IsThrottledMessageSystemReady()` is true. One click or drop sends one search. Item searches (`SendSearchQuery`, `SendSellSearchQuery`) follow the same rule as `SendBrowseQuery`, and their results are shown, not saved.
- A full-house price scan that starts from a Scan click, calls `C_AuctionHouse.ReplicateItems` once, and then waits out the 15 minute account throttle. The listing reads are spread across frames. Seller names are not saved. Saved prices may be shown on item mouseovers.
- Following Blizzard's auction window with `hooksecurefunc`: its tab, and the item put in its Sell window, so HouseLedger shows the results Blizzard's own search brought back. Following sends no search.
- In-game macros made in Blizzard's macro window. One press, one action. A `/castsequence` still needs a press for each step.

## Not allowed

- Copying another addon's code, name, or art. Auctionator is the feature reference only.
- CurseForge, Overwolf, or any outside program that installs or runs addon code.
- Obfuscated or encoded Lua.
- Charging for an addon, a "premium" feature, or a service required to use it. No donation nag inside the game.
- Ads inside the game.
- Bots, AutoHotkey, hardware repeaters, and software that broadcasts one key to more than one client.
- Posting, buying, bidding, or canceling without a fresh click for that action.
- Another full scan inside the 15 minute throttle, a scan that starts by itself when the auction house opens, or a loop of browse queries that dumps the house in the background.
- Calling `C_AuctionHouse.SendBrowseQuery` from `/run` or `/script`. Blizzard marks that function `#noscript` because doing so breaks the auction house. This repo treats every `C_AuctionHouse` search the same way.
- Calling a method on Blizzard's auction window or changing it from addon code: switching its tab, putting an item in it, filling its search box. On Forever, `/run AuctionHouseFrame:SetDisplayMode(...)` left every auction house search spinning until the game restarted, though Blizzard's own tab button calls the same method. Blizzard's searches are `#noscript`, and Blizzard's window keeps what script code set up, so its later searches stall (players call this bricking the auction house). Changes from addon code leave taint on that window too; Auctionator resets fields after it touches it. Read it, anchor to it, or follow it with `hooksecurefunc`; `scripts/addon_checks.sh policy` flags anything else. The one way to switch its tabs: our tab is a `SecureActionButtonTemplate` with `type="click"` and `clickbutton` set to Blizzard's tab, so on the player's click the game's own secure code presses Blizzard's tab. Blizzard's Buy and Sell panels send no query when shown, so that click is still one action. The secure tabs make our window protected: in combat it waits (showing, hiding, moving, tab marking, and the panels if the game's `IsProtected` says they are protected too), and catches up when combat ends.
- Combat automation, secret-value math, or anything that plays the character.

Blizzard can disable any of this later. If an API starts requiring a hardware event or disappears, the addon stops calling it.
