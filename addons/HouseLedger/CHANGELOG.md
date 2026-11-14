# Changelog

All notable changes to HouseLedger. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version starts with 0, anything may still change.

## [Unreleased]

### Added

- Filters on the Buy and Market tabs: a quality dropdown and an item level range, plus a name filter on Market. On Buy the quality goes with your Search click, and you can search with no name once a quality or item level is set. Changing a filter re-filters what's already shown and sends nothing.
- A **Market** tab: the deals, biggest drops and biggest rises from your last scan, switched with **<** and **>**. It reads only saved prices, so it never sends a search.
- Scans also save each item's name and quality, for the Market tab.
- A gold progress bar while a scan reads the auction house's listings.

### Changed

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
