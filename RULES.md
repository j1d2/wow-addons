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
- Lists and windows built only from saved scan data: HouseLedger's Market tab (deals, drops and rises) reads saved prices and sends nothing on its tab, arrows, scrolling, row clicks or hovers. Its tab is a plain button of our own and presses nothing on Blizzard's window. Item names and qualities from the scan's own listings may be saved; seller names may not.
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
- `setfenv` or `getfenv`: swapping a function's environment hides what the code really does. Also the `debug` library, which reaches into other code, and `RunMacro`, which plays the character. `scripts/addon_checks.sh policy` blocks them in addon files.

## Disenchanting (Unmaker)

- **Allowed:** one click or one key press disenchants one item. The click goes to a Blizzard `SecureActionButtonTemplate` that is set, in `PreClick`, to `type = "spell"`, `spell = 13262` (Disenchant), `target-bag` and `target-slot`. Blizzard's own code casts, and `PostClick` clears the button. A key binding to that button counts as a press.
- **Allowed:** reading the bags, listing items, and saving which items the player keeps.
- **Not allowed:** casting or using bag items from addon code (`CastSpellByName`, `CastSpellByID`, `SpellTargetItem`, `UseContainerItem`, `PickupContainerItem`). `scripts/addon_checks.sh policy` blocks them.
- **Not allowed:** one click that disenchants more than one item, a timer or loop that clicks, or changing the button in combat. In combat the button is left empty, so a click does nothing.
- Before each cast the bag slot must still hold the row's exact item (item ID and link). If not, nothing is cast.
- Unverified on Forever: whether Enchanting skill limits what can be disenchanted. Unmaker doesn't guess. If a cast fails, Unmaker keeps the item and shows the game's reason; the player unchecks an item the game won't take.

## Allowed only with a reason

These calls send data out of the game, or change the player's own setup. An addon may use one only with a `-- reviewed: <why>` note on the same line, so the reason is read in review. `scripts/addon_checks.sh policy` flags any line that names one without the note, so keeping it in a local can't hide it.

- Chat and messages: `C_ChatInfo.SendChatMessage` (and the older `SendChatMessage`), `C_ChatInfo.SendAddonMessage`, `C_ChatInfo.SendAddonMessageLogged` (and the older `SendAddonMessage`), `C_BattleNet.SendWhisper`, `C_BattleNet.SendGameData`
- Settings: `SetCVar`, `C_CVar.SetCVar`
- Keybindings and macros: `SetBinding`, `SetBindingClick`, `SaveBindings`, `CreateMacro`, `EditMacro`, `DeleteMacro`

A message an addon sends must still come from the player's own action and carry nothing private. HouseLedger uses none of these.

Blizzard can disable any of this later. If an API starts requiring a hardware event or disappears, the addon stops calling it.
