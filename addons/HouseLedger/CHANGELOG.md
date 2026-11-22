# Changelog

All notable changes to HouseLedger. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version starts with 0, anything may still change.

## [Unreleased]

### Added

- **Show** on the Buy tab: search everything, **Gear for me** (weapons this character can use and its best armor type, like plate for a paladin from level 40, plus rings, necks, trinkets, cloaks, shields and relics it can use), **Any gear I can use** (every armor type it can wear) or **Recipes for me** (recipes for this character's professions). The auction house does the filtering, so pick one and click Search; a name is optional.
- **House overview** on the Buy tab, until you click a row: items listed at the last scan and on average, the trend per day, a next-day estimate after 5 days of scans, and the last scan's listings, units and value (each item's units at its cheapest price, so joke-priced listings don't inflate it), with a chart of each day, a trend line and its normal range. Items per day come from the scans you've already saved; listings, units and value start with your next scan.
- **Price history length** on the Settings tab: keep 14, 30 or 60 days of prices. 60 days uses about three times the memory of 14. Going back to a shorter one drops the older days right away.
- **Price Check** scrolls with the mouse wheel through every match, and the bottom line says which ones show and how many there are ("13-24 of 57 items").
- Click **Item**, **Price** or **Trend** in Price Check to sort; click again to reverse.
- With Price Check open, shift-click an item in your bags or a chat link to look it up.
- The price chart grows with your history. It starts at the first day an item was scanned, with at least 7 bars and up to 30; past 30 days, each bar covers 2 days. Hover it to see how many days it shows.
- **Days | Scans** in the corner of every price chart. Scans shows one bar per scan (an item's last 30, within your history length) with a little space between days, so you can see a price move during a day. Your choice is saved for every chart. Scans are saved from your first scan after updating.
- Every price chart gets a **trend line**, a faint band for its normal range, and a purple **guess** at the next day or scan, like the house overview, once it has 5 bars. The line is fit so one odd cheap listing can't tilt it. The guess is only the line carried on one more step, not a promise. Hover the chart for what each part means.

### Changed

- Each day's prices are now saved as an average and spread rounded to a few digits, instead of exact running totals. On a very busy auction house with many scans a day, the exact totals could make the saved file too big for the game to load, which can lose your saved prices. Typical prices and spreads may change by a fraction of a percent; your saved history converts by itself the first time it loads. Going back to an older HouseLedger after that isn't supported: it would show wrong averages.
- HouseLedger's code is now split into smaller files. Nothing looks or works differently, but restart the game once after updating: a `/reload` doesn't pick up new files.
- The Market tab opens about 6 times faster, and price tooltips and details take about 5 times less work. The numbers are the same as before.
- Items that stop showing up in scans now drop their days older than 14 days too, so the saved file stays smaller. Their tooltip still shows the last price and when it was seen.

### Fixed

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
