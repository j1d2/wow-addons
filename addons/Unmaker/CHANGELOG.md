# Changelog

All notable changes to Unmaker. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version starts with 0, anything may still change.

## [Unreleased]

### Added

- Items tab filters: a quality dropdown ("Rare & down", "Uncommon & down") and an item level range. The count line says how many items the filters hide.
- A **Vendor** column with what a vendor pays for each item, and sortable column headings: click Item, ilvl or Vendor to sort, again to reverse. **Disenchant next** takes the first checked item in the list as you see it.
- A 14-day chart on the Stats tab: how many items you unmade each day, today in gold. It follows the character dropdown.

### Changed

- The Stats tab picks a character from a dropdown instead of the < and > arrows, so any character is one click away.

## [0.3.0] - 2026-11-13

### Added

- A Settings box to hide the **Unmaker** button above your bags. `/unmaker` still opens the window.

## [0.2.0] - 2026-11-13

### Added

- Stats for each character. Use the arrows at the top of the Stats tab to switch between all characters together and each character, from any character. Stats from before this version are counted per character from the History list (your last 500 disenchants); older ones count only in "All characters".

### Changed

- The window remembers where you dragged it, after a reload or logging out. Each character keeps its own spot. It used to open in the middle of the screen each time.

## [0.1.1] - 2026-11-13

### Fixed

- "Open when I loot" and "Open with my bags" no longer open the window on a character without Enchanting. Settings are shared by every character, so they used to open it on alts too. `/unmaker` and the bag button still open it there.

## [0.1.0] - 2026-11-12

First release.

### Added

- A window that lists the gear in your bags you can disenchant: Uncommon, Rare and Epic armor and weapons.
- Checkboxes: an item you uncheck is kept and stays unchecked next time.
- **Disenchant next** disenchants the next checked item, one click per item, and can be bound to a key.
- **Disenchant selected** disenchants the row you clicked, if it is checked.
- A Settings tab: keep epics, keep soulbound gear, hide equipment-set items, open when you loot gear to disenchant, and open with your bags.
- `/unmaker` and an Unmaker button above your bags open the window.
- "Unmade" counts at the top of the window: this session and lifetime.
- A Stats tab: counts by session, day, lifetime and quality, your most-unmade item, best item, busiest day, and lifetime materials.
- A History tab: the last 500 disenchants with the materials each gave, newest first, sortable by item, item level or time.
