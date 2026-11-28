# Changelog

All notable changes to HouseLedger. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version starts with 0, anything may still change.

## [Unreleased]

### Added

- **Auctions tab:** your own auctions, with how many, the price each, time left (orange under 2 hours) and Sold, each compared with your last scan (**cheapest**, or how far under yours someone was) and, on hover, your 7-day average. The totals line shows what's listed, what you'd get after the house's cut, and sold gold waiting in the mail. Opening the tab reads this character's auctions; opening Blizzard's Auctions tab does too. Every character's are saved, so **All characters** shows them together. HouseLedger never cancels, and never reads who bid. Restart the game once after updating (a new file).
- A red reminder on the Buy tab's empty list when you haven't scanned today, so your price history keeps growing: "You haven't scanned today. Click Scan once a day to build your price history." It goes away once today's scan is saved. It never scans by itself.
- **Posting.** Drop an item on the Sell tab's slot and post it from HouseLedger: a price filled in from what's listed now (**Best price**, **Sell fast** or **My last price**), how many, and how long, with the deposit and what you get after the house's cut (5% at the faction houses; not yet known at the goblin house). **Post**, then **Confirm** (Settings can turn Confirm off). A price far from the usual, under half the cheapest listing, or under what a vendor pays always asks first. Stackables post as many as you choose; gear and other single items post one copy per click for now. The Sell tab's price chart now sits beside its price lines, bigger than before. Restart the game once after updating (a new file).
- **Scroll bars** on every list that scrolls: Buy and Market results, an item's listings, History and Price Check. Drag one, click its arrows, or keep using the mouse wheel. A bar shows only when there's more than fits.
- **History tab**: what each of your characters bought and sold, and auctions that came back (expired or cancelled). Buys made in HouseLedger show at once; sales, buys from Blizzard's window and returned auctions are added when you open your mailbox, each mail once. A mail's time is worked out from how long it has left, so a sale shows about when it happened. Filter by character or by Bought / Sold / Came back, sort by any heading, and see totals and the profit on a sale when you bought that item earlier. HouseLedger only reads your mail and never saves the other player's name. Restart the game once after updating (a new file).
- **Recent searches** on the Buy tab: click into the search box to see the last ones you searched, narrowed as you type. Click one to search it again, or use the arrow keys to put one in the box and press Enter or click Search. Right-click one to forget it. Price Check's search box has the same list, and an item you click there is added to it. They're saved for all your characters.
- The row you click is marked in gold on the Buy and Market tabs, in the listings and in Price Check, so you can see which one the details show.
- **Buying.** Click a row on the Buy or Market tab, then the **Buy** button on that row to see the item's listings, cheapest first, with how each compares with your 7-day average. For stackable items, type how many (or click a listing, or **Max**) and click **Buy**: the house quotes its price, and **Confirm** buys at it. If the price went up since the listings, you see by how much first; over 5% more is refused, as in Blizzard's window. For gear, click one listing, then **Buy** and **Confirm**; each listing shows what one buy costs. The picked listing has its own **Buy** button too. Two settings, both on by default, turn **Confirm** off: for gear, **Buy** then buys at once; for stackables, it buys at the house's price when that hasn't gone up (a rise still asks). Only buyouts; your own listings and bid-only ones are left out. HouseLedger never searches again after a buy: click **Back**, then **Buy**, to see what's left. Restart the game once after updating (a new file).
- **Show** on the Buy tab: search **Everything**, **Gear for me** (weapons this character can use and its best armor type, like plate for a paladin from level 40, plus rings, necks, trinkets, cloaks, shields and relics it can use), **Usable gear** (every armor type it can wear) or **My recipes** (recipes for this character's professions). Picking one searches right away, and so does picking a quality on Buy; a name is optional.
- **House overview** on the Buy tab, until you click a row: items listed at the last scan and on average, the trend per day, a next-day projection after 5 days of scans, and the last scan's listings, units and value (each item's units at its cheapest price, so joke-priced listings don't inflate it), with a chart of each day, a trend line and its normal range. Items per day come from the scans you've already saved; listings, units and value start with your next scan.
- **Price history length** on the Settings tab: keep 14, 30 or 60 days of prices. 60 days uses about three times the memory of 14. Going back to a shorter one drops the older days right away.
- **Price Check** scrolls with the mouse wheel through every match, and the bottom line says which ones show and how many there are ("13-24 of 57 items").
- Click **Item**, **Price** or **Trend** in Price Check to sort; click again to reverse.
- With Price Check open, shift-click an item in your bags or a chat link to look it up.
- The price chart grows with your history. It starts at the first day an item was scanned, with at least 7 bars and up to 30; past 30 days, each bar covers 2 days. Hover it to see how many days it shows.
- **Days** and **Scans** buttons in the corner of every price chart. Scans shows one bar per scan (an item's last 30, within your history length) with a little space between days, so you can see a price move during a day. Your choice is saved for every chart. Scans are saved from your first scan after updating.
- Every price chart gets a **trend line**, a shaded band for its normal range, and a purple **projection** for the next day or scan, like the house overview, once it has 5 bars. The line is fit so one odd cheap listing can't tilt it. The projection is the trend line carried one step forward. Hover the chart for what each part means.

### Changed

- **History** profit: every sale now has one, what it sold for after the house's cut, less the average you paid when you bought it on the auction house; a looted, farmed or made item counts in full (its hover says which). Under the list, like the Buy tab's details: your gold for today, 3, 7 and 14 days and lifetime (sold, bought, profit), for all characters or the one picked under Who, and a 14-day profit chart. Lifetime counts everything recorded, also entries the list has since dropped. The list shows 15 rows instead of 18.
- One far-off day or scan no longer flattens a price chart: the chart's height stops at 3 times the usual low price (or the top of the normal range, if higher), and a bar past it reaches the top with a white tip. Hover the chart for its real price.
- The Buy tab's price chart and the house overview chart are bigger: as tall as the space under the list, centred in it, and as wide as the room beside the price lines.
- The 1, 3, 7 and 14-day lines and the std dev leave out the copper on amounts of 1 gold or more, so they show two coins at most ("12g 34s"), and so do a chart's top price and its projection. The current price and the price you'd pay stay exact.
- Each day's prices are now saved as an average and spread rounded to a few digits, instead of exact running totals. On a very busy auction house with many scans a day, the exact totals could make the saved file too big for the game to load, which can lose your saved prices. Typical prices and spreads may change by a fraction of a percent; your saved history converts by itself the first time it loads. Going back to an older HouseLedger after that isn't supported: it would show wrong averages.
- HouseLedger's code is now split into smaller files. Nothing looks or works differently, but restart the game once after updating: a `/reload` doesn't pick up new files.
- The Market tab opens about 6 times faster, and price tooltips and details take about 5 times less work. The numbers are the same as before.
- Items that stop showing up in scans now drop their days older than 14 days too, so the saved file stays smaller. Their tooltip still shows the last price and when it was seen.

### Fixed

- A price too long for its space (a big price on a chart's top line, or in Price Check's details) could end in a stray "|". It's now rounded to fit instead: from 1 gold up, first without copper, then without silver. The price you'd pay is never rounded.
- A price that fell more than 99.5% showed as -100%, as if the item were free. It now shows -99%.
- Big counts get commas: "40,223 in 1,070 listings", "7,441 prices". The posting line shows its prices with coin icons, like the rest of the window.
- On the Settings tab, the dark box now reaches down to the bottom line, as on History, instead of leaving an empty band under it.
- The Sell tab's lowest price for an item that isn't stackable (like Silver Rod) was too low when one listing held several copies: it divided the price by the copies. A listing's price is the price of one copy, as the Buy tab's listings already show.
- Since the game update of November 20, the game can give a blank realm name, and HouseLedger then started a new, empty price history for every scan after it. Your history wasn't lost: HouseLedger now joins those scans back into your saved history the first time it loads, and a blank realm name keeps using the realm the game last named. The auction house window says so once when it has joined them.
- At a goblin auction house, the window (Market, the house overview, Buy and Sell details, and the scan line) now shows that goblin house's prices instead of your faction's, and calls it "Goblin". Tooltips and Price Check always show your own faction's prices, and no longer fall back to another house's.

## [0.4.1] - 2026-11-15

### Changed

- A new one-line description in the game's AddOns list.

## [0.4.0] - 2026-11-14

### Added

- Click a column heading on Buy or Market to sort by it; click it again to reverse. An arrow marks the sorted column.
- An **ilvl** column on Buy (each result's own item level) and Market (the item's base level).
- **Price Check**: look up your saved prices anywhere, no auction house needed. Type `/pc` (or `/pricecheck`), or click **Price Check** above your bags, then type part of an item's name. Click a result for its day lines and 14-day chart. `/pc linen` opens it already searched. The bag button can be turned off in Settings.
- The Sell tab says what the prices mean in plain words, like "Prices are high today. A good time to sell.", and shows a **Typical (7-day avg)** line. It never sets a price for you.
- A 14-day price chart: one bar per day's lowest price (the latest day in gold) with a faint band up to that day's highest. It shows beside a clicked row's details on Buy and Market when the window is wide enough, and under the lines on the Sell tab.
- A **Settings** tab: turn the prices on item tooltips off, or always show the 1, 3, 7 and 14-day lines without holding Shift.
- Filters on the Buy and Market tabs: a quality dropdown and an item level range, plus a name filter on Market. On Buy the quality goes with your Search click, and you can search with no name once a quality is set. Changing a filter re-filters what's already shown and sends nothing; a lower quality than you searched for needs a new search, and the status line says so.
- A **Market** tab: the deals, biggest drops and biggest rises from your last scan, picked from a dropdown. It reads only saved prices, so it never sends a search.
- Scans also save each item's name and quality, for the Market tab.
- A gold progress bar while a scan reads the auction house's listings.

### Changed

- Messages you need to act on are easy to see: in large text in the middle of an empty list, and in orange beside the filters ("Click Search again to include lower qualities.", "These are the first 500 results. Add a name or filter to see others."). Search lights up when a new search would show more.
- **Clear** also resets the quality and item level filters.
- The **Scan** button greys out and counts down the 15-minute wait, like "Scan (12m)", instead of looking ready.
- The status line is shorter and leaves out the realm: "6154 prices (Horde). Next scan in 13 min."
- In the saved price lines, a window with no more scans than the one before says "same as 7 days" instead of repeating the same numbers.

## [0.3.0] - 2026-11-10

First public release.

### Added

- Keeps 14 days of prices, one summary per day, with the average, range and standard deviation over 1, 3, 7 and 14 days.
- Tooltips show a trend arrow and a deal star. Hold Shift for the 1, 3, 7 and 14-day details.
- Buy tab: search results with the live price, how many are up, the 7-day average and the trend. Click a row for its saved stats.
- Sell tab: drop an item from your bags to see the lowest price now, how many are up, and its saved history.
- Follows Blizzard's window: its Sell tab, and the item you put in it, show on HouseLedger's Sell tab.
- HouseLedger's Buy and Sell tabs switch Blizzard's tabs too, through the game's secure click.
- Clear (Buy) and Reset (Sell) buttons.
- A price within 10% of its 7-day average shows as a grey "steady".

### Changed

- The window sits beside Blizzard's auction house window.
- Prices show as gold, silver and copper with coin icons.

### Fixed

- The 15-minute wait between scans starts at the click.
- Gear dropped on the Sell tab is searched across all its variants, and bags and other items use the plain item search, even before the game has loaded the item's data.
- Prices saved before the 14-day history keep their latest scan's day when they are upgraded.

## [0.2.0] - 2026-11-09

### Added

- Scan button: one full auction house scan saves the lowest price of each item.
- Item tooltips show the last saved price.

## [0.1.0] - 2026-11-09

### Added

- Auction house search window.
