--[[
Price history for one auction house.

Pure data. No frames, no queries, and no seller names. The scan
code hands in item id, stack size, and buyout. This file keeps the
lowest price per item, one summary per calendar day for the last
14 days (low, high, scan count, sum and sum of squares), and works out
the stats the tooltip and window show: average, range and standard
deviation over the last 1, 3, 7 and 14 days.

Every number here is the cheapest asking price a scan saw, not a
sale price.
]]

local PriceLedger = {}
_G.HouseLedgerPrice = PriceLedger

PriceLedger.DB_VERSION = 3
PriceLedger.SCAN_INTERVAL = 15 * 60

-- Days of summaries kept per item, today included. Matches the widest window.
PriceLedger.DAYS_KEPT = 14
-- Stats windows, in days back from the latest scan's day, that day included.
PriceLedger.WINDOWS = { 1, 3, 7, 14 }
-- Trend and deal compare the latest price with the average of the
-- earlier scans in this window. The latest scan is left out.
PriceLedger.BASELINE_DAYS = 7
PriceLedger.TREND_MIN_SCANS = 2
-- A change smaller than this is "flat", so one scan's noise shows no arrow.
PriceLedger.TREND_THRESHOLD = 0.10
-- A deal is at least DEAL_DROP under the average and also more than
-- DEAL_SIGMAS standard deviations under it, so a noisy item needs a
-- bigger drop. Needs DEAL_MIN_SCANS earlier scans.
PriceLedger.DEAL_MIN_SCANS = 4
PriceLedger.DEAL_DROP = 0.25
PriceLedger.DEAL_SIGMAS = 2

local SECONDS_PER_DAY = 24 * 60 * 60

--- Formats a time with the game's date function, or Lua's offline.
-- @param format a date format string, such as "%Y%m%d"
-- @param seconds a time() value
-- @return the formatted text, or nil when neither date function exists
local function FormatTime(format, seconds)
    if type(date) == "function" then
        return date(format, seconds)
    end
    if os and type(os.date) == "function" then
        return os.date(format, seconds)
    end
    return nil
end

--- Formats when an item was last seen, as month/day and time.
-- @param seen a time() value
-- @return text like "11/09 14:05", or the number as text without a date function
local function FormatStamp(seen)
    return FormatTime("%m/%d %H:%M", seen) or tostring(seen)
end

--- The local calendar day of a time, as a number like 20261109.
-- Larger keys are later days, so keys compare like dates.
-- @param seconds a time() value
-- @return the day key
function PriceLedger.DayKey(seconds)
    return tonumber(FormatTime("%Y%m%d", seconds))
end

--- A new saved-variables table with no houses.
-- @return { version, houses }
function PriceLedger.EmptyDB()
    return {
        version = PriceLedger.DB_VERSION,
        houses = {},
    }
end

--- Adds one scan's unit price to a row's day list.
-- Folds into the last day when it is the same day, otherwise starts a new day.
-- @param days list of { dayKey, low, high, scans, sum, sumOfSquares }, oldest first;
--   changed in place
-- @param unit unit price in copper
-- @param seconds when the scan ran
local function AddToDays(days, unit, seconds)
    local key = PriceLedger.DayKey(seconds)
    local last = days[#days]
    if type(last) == "table" and last[1] == key then
        last[2] = math.min(last[2], unit)
        last[3] = math.max(last[3], unit)
        last[4] = last[4] + 1
        last[5] = last[5] + unit
        last[6] = last[6] + unit * unit
        return
    end
    days[#days + 1] = { key, unit, unit, 1, unit, unit * unit }
end

--- Fills in the sums that version 2 days did not have.
-- Version 2 days had low, high and count only. Fill the sums in as if
-- half the scans were at the low and half at the high: exact for one
-- scan or a steady price, close otherwise.
-- @param days a row's day list; changed in place
local function AddSumsFromV2(days)
    for _, day in ipairs(days) do
        if type(day) == "table" and day[5] == nil then
            local low, high, scans = day[2], day[3], day[4]
            day[5] = (low + high) / 2 * scans
            day[6] = (low * low + high * high) / 2 * scans
        end
    end
end

--- Turns a version 1 row's list of price changes into day summaries.
-- Version 1 moved `seen` on every scan but listed a price
-- only when it changed, so the latest scan's day is added from the last
-- price and seen time when no change was listed that day. The days in
-- between are not known and are not made up.
-- @param row an item row with `history`; changed in place (gets `days`, loses `history`)
local function MigrateRowFromV1(row)
    local days = {}
    if type(row.history) == "table" then
        for _, point in ipairs(row.history) do
            if type(point) == "table" and type(point[1]) == "number" and type(point[2]) == "number" then
                AddToDays(days, point[1], point[2])
            end
        end
    end
    if type(row.unit) == "number" and type(row.seen) == "number" then
        local last = days[#days]
        if last == nil or last[1] ~= PriceLedger.DayKey(row.seen) then
            AddToDays(days, row.unit, row.seen)
        end
    end
    row.days = days
    row.history = nil
end

--- Makes the saved table usable and brings it up to DB_VERSION.
-- Rows without `days` are migrated from version 1; other rows get the
-- version 3 sums from version 2. Runs the migrations only when the version differs.
-- @param db the saved HouseLedgerDB, or nil on a first load
-- @return the same table updated in place, or a new empty one if db was not a table
function PriceLedger.EnsureDB(db)
    if type(db) ~= "table" then
        db = PriceLedger.EmptyDB()
    end
    if type(db.houses) ~= "table" then
        db.houses = {}
    end
    if db.version ~= PriceLedger.DB_VERSION then
        for _, house in pairs(db.houses) do
            if type(house) == "table" and type(house.items) == "table" then
                for _, row in pairs(house.items) do
                    if type(row) == "table" and type(row.days) ~= "table" then
                        MigrateRowFromV1(row)
                    elseif type(row) == "table" then
                        AddSumsFromV2(row.days)
                    end
                end
            end
        end
    end
    db.version = PriceLedger.DB_VERSION
    return db
end

--- The key one house is saved under.
-- @param side "Alliance", "Horde" or "Neutral"; "Unknown" when missing
-- @param realm the realm name; "Forever" when missing
-- @return the key, "<side>|<realm>"
function PriceLedger.HouseKey(side, realm)
    if type(side) ~= "string" or side == "" then
        side = "Unknown"
    end
    if type(realm) ~= "string" or realm == "" then
        realm = "Forever"
    end
    return side .. "|" .. realm
end

--- Finds a house in the db, adding it (with an empty item list) when missing.
-- @param db the saved table, from EnsureDB
-- @param key a house key, from HouseKey
-- @return the house table
function PriceLedger.EnsureHouse(db, key)
    local house = db.houses[key]
    if type(house) ~= "table" then
        house = { items = {} }
        db.houses[key] = house
    end
    if type(house.items) ~= "table" then
        house.items = {}
    end
    return house
end

--- Folds one listing into the lowest-price table for this scan.
-- A buyout of 0 is a bid-only listing and is ignored. A cheaper unit price
-- replaces the stored one; the same unit price adds its stack to qty.
-- @param best itemID -> { buyout, count, qty }; changed in place
-- @param itemID the item's id
-- @param count stack size
-- @param buyout stack buyout in copper
function PriceLedger.Consider(best, itemID, count, buyout)
    if type(itemID) ~= "number" or itemID <= 0 then
        return
    end
    if type(count) ~= "number" or count <= 0 then
        return
    end
    if type(buyout) ~= "number" or buyout <= 0 then
        return
    end

    local current = best[itemID]
    if current == nil then
        best[itemID] = { buyout = buyout, count = count, qty = count }
        return
    end

    local incoming = buyout * current.count
    local stored = current.buyout * count
    if incoming < stored then
        best[itemID] = { buyout = buyout, count = count, qty = count }
        return
    end
    if incoming == stored then
        current.qty = current.qty + count
    end
end

--- The unit price of a stack, rounded to the nearest copper.
-- @param buyout stack buyout in copper
-- @param count stack size
-- @return copper per unit
function PriceLedger.UnitCopper(buyout, count)
    return math.floor((buyout / count) + 0.5)
end

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 100 * COPPER_PER_SILVER

--- Writes copper as plain gold, silver and copper text.
-- This is the way the game does it in colorblind mode. The addon draws coin
-- icons with the game's GetMoneyString; this is the fallback if that function
-- is missing. Empty denominations are left out (10005 -> "1g 5c").
-- @param copper whole copper, 0 or more
-- @return the text, for example "1g 2s 3c"; zero is "0c"
function PriceLedger.CoinText(copper)
    local gold = math.floor(copper / COPPER_PER_GOLD)
    local silver = math.floor(copper / COPPER_PER_SILVER) % 100
    local rest = copper % COPPER_PER_SILVER
    local parts = {}
    if gold > 0 then
        parts[#parts + 1] = gold .. "g"
    end
    if silver > 0 then
        parts[#parts + 1] = silver .. "s"
    end
    if rest > 0 or #parts == 0 then
        parts[#parts + 1] = rest .. "c"
    end
    return table.concat(parts, " ")
end

--- Saves one item's price from a scan: the latest price, and the day summary.
-- Days older than DAYS_KEPT are dropped.
-- @param house the house table
-- @param itemID the item's id
-- @param unit unit price in copper
-- @param qty how many were listed at that price
-- @param now when the scan ran
-- @return the item's row
function PriceLedger.Remember(house, itemID, unit, qty, now)
    local row = house.items[itemID]
    if type(row) ~= "table" then
        row = {}
        house.items[itemID] = row
    end
    if type(row.days) ~= "table" then
        row.days = {}
    end

    local days = row.days
    AddToDays(days, unit, now)
    local oldest = PriceLedger.DayKey(now - (PriceLedger.DAYS_KEPT - 1) * SECONDS_PER_DAY)
    while #days > 0 and (days[1][1] < oldest or #days > PriceLedger.DAYS_KEPT) do
        table.remove(days, 1)
    end

    row.unit = unit
    row.qty = qty
    row.seen = now
    return row
end

--- Saves one finished scan.
-- Items missing from `best` stay in the house with their old seen time,
-- so a later mouseover can still show the last known price. Also sets the
-- house's scannedAt and the db's lastHouseKey.
-- @param db the saved table
-- @param houseKey key of the house that was scanned
-- @param best the lowest-price table from Consider
-- @param now when the scan ran
-- @return how many item prices were saved
function PriceLedger.Commit(db, houseKey, best, now)
    local house = PriceLedger.EnsureHouse(db, houseKey)
    house.scannedAt = now
    local saved = 0
    for itemID, listing in pairs(best) do
        local unit = PriceLedger.UnitCopper(listing.buyout, listing.count)
        if unit > 0 then
            PriceLedger.Remember(house, itemID, unit, listing.qty, now)
            saved = saved + 1
        end
    end
    db.lastHouseKey = houseKey
    return saved
end

--- Rounds to the nearest whole number, halves up.
-- @param value a number
-- @return the rounded number
local function Round(value)
    return math.floor(value + 0.5)
end

--- Adds up the days from `fromKey` to `toKey`, both included.
-- @param days a row's day list
-- @param fromKey first day key to count
-- @param toKey last day key to count
-- @return { scans, days, sum, sumOfSquares, low, high }; low and high are nil with no days
local function Totals(days, fromKey, toKey)
    local totals = { scans = 0, days = 0, sum = 0, sumOfSquares = 0 }
    for _, day in ipairs(days) do
        if day[1] >= fromKey and day[1] <= toKey then
            totals.scans = totals.scans + day[4]
            totals.days = totals.days + 1
            totals.sum = totals.sum + day[5]
            totals.sumOfSquares = totals.sumOfSquares + day[6]
            totals.low = math.min(totals.low or day[2], day[2])
            totals.high = math.max(totals.high or day[3], day[3])
        end
    end
    return totals
end

--- Stats for one item, measured back from its latest scan's day.
-- @param row an item row with unit, seen and days
-- @return nil for a row with no days (or no unit or seen), or a table:
--   unit: latest price; seen: when it was seen
--   windows: for 1, 3, 7 and 14 days, { days, scans, low, high, avg }
--   scans, days, low, high: the 14-day window
--   earlierScans: scans in the 7-day window before the latest one
--   typical: average of those earlier scans, rounded, or nil with fewer
--     than TREND_MIN_SCANS of them
--   spread: their sample standard deviation, with typical
--   trend, trendPct, deal, dealPct: PriceLedger.Judge of the latest price
function PriceLedger.Stats(row)
    if type(row) ~= "table" or type(row.days) ~= "table" or #row.days == 0 then
        return nil
    end
    if type(row.unit) ~= "number" or type(row.seen) ~= "number" then
        return nil
    end

    local latestKey = PriceLedger.DayKey(row.seen)
    --- The day key `count` days before the latest scan.
    local function KeyDaysBack(count)
        return PriceLedger.DayKey(row.seen - count * SECONDS_PER_DAY)
    end

    local stats = { unit = row.unit, seen = row.seen, windows = {} }
    for _, length in ipairs(PriceLedger.WINDOWS) do
        local totals = Totals(row.days, KeyDaysBack(length - 1), latestKey)
        stats.windows[#stats.windows + 1] = {
            days = length,
            scans = totals.scans,
            low = totals.low,
            high = totals.high,
            avg = totals.scans > 0 and Round(totals.sum / totals.scans) or nil,
        }
    end
    local widest = Totals(row.days, KeyDaysBack(PriceLedger.DAYS_KEPT - 1), latestKey)
    stats.scans, stats.days = widest.scans, widest.days
    stats.low, stats.high = widest.low, widest.high

    -- The baseline leaves the latest scan out, so it is not compared
    -- with itself.
    local base = Totals(row.days, KeyDaysBack(PriceLedger.BASELINE_DAYS - 1), latestKey)
    local count = base.scans - 1
    stats.earlierScans = math.max(0, count)
    if count >= PriceLedger.TREND_MIN_SCANS then
        local sum = base.sum - row.unit
        local mean = sum / count
        local variance = (base.sumOfSquares - row.unit * row.unit - count * mean * mean) / (count - 1)
        stats.typical = Round(mean)
        stats.spread = math.sqrt(math.max(0, variance))
    end

    local verdict = PriceLedger.Judge(stats, row.unit)
    stats.trend = verdict.trend
    stats.trendPct = verdict.trendPct
    stats.deal = verdict.deal
    stats.dealPct = verdict.dealPct
    return stats
end

--- Judges a price against an item's saved scans.
-- The price is the latest scan's price, or a live price from a search.
-- @param stats from PriceLedger.Stats, or nil
-- @param price unit price in copper
-- @return { trend, trendPct, deal, dealPct }. trend is "up", "down",
--   "flat" or nil (too few earlier scans). deal is true or false.
function PriceLedger.Judge(stats, price)
    local verdict = { deal = false }
    if type(stats) ~= "table" or type(price) ~= "number" or stats.typical == nil then
        return verdict
    end
    verdict.trendPct = (price - stats.typical) / stats.typical
    if verdict.trendPct >= PriceLedger.TREND_THRESHOLD then
        verdict.trend = "up"
    elseif verdict.trendPct <= -PriceLedger.TREND_THRESHOLD then
        verdict.trend = "down"
    else
        verdict.trend = "flat"
    end
    if (stats.earlierScans or 0) >= PriceLedger.DEAL_MIN_SCANS then
        local farUnder = price < stats.typical - PriceLedger.DEAL_SIGMAS * (stats.spread or 0)
        local wellUnder = price <= stats.typical * (1 - PriceLedger.DEAL_DROP)
        if farUnder and wellUnder then
            verdict.deal = true
            verdict.dealPct = (stats.typical - price) / stats.typical
        end
    end
    return verdict
end

--- Sums up one item's live listings from a search.
-- Nothing is saved.
-- @param listings list of { unitPrice, quantity }; a price of 0 or less is
--   a bid-only listing and is skipped
-- @return nil when nothing has a price, or
--   { low, atLow, total, listings }: lowest unit price, how many are up
--   at that price, how many are up in all, and how many listings
function PriceLedger.LowestListing(listings)
    local summary
    for _, listing in ipairs(listings) do
        local unit, quantity = listing[1], listing[2]
        if type(unit) == "number" and unit > 0 and type(quantity) == "number" and quantity > 0 then
            summary = summary or { atLow = 0, total = 0, listings = 0 }
            summary.total = summary.total + quantity
            summary.listings = summary.listings + 1
            if summary.low == nil or unit < summary.low then
                summary.low = unit
                summary.atLow = quantity
            elseif unit == summary.low then
                summary.atLow = summary.atLow + quantity
            end
        end
    end
    return summary
end

--- A house key as people read it: its side, "Horde|Realm" becomes "Horde". The realm is left
-- out: the player knows it, and it would show in every screenshot of the window.
-- @param key a house key
-- @return the label; "" for a non-string, the key itself when it has no "|"
function PriceLedger.HouseLabel(key)
    if type(key) ~= "string" then
        return ""
    end
    return string.match(key, "^([^|]*)|") or key
end

--- The Scan button's text: "Scan" when a scan is allowed, otherwise the wait, like
-- "Scan (12m)" (minutes rounded up) or "Scan (45s)" under a minute.
-- @param wait seconds until the next scan is allowed
-- @return the text
function PriceLedger.ScanButtonText(wait)
    if type(wait) ~= "number" or wait <= 0 then
        return "Scan"
    end
    wait = math.ceil(wait)
    if wait >= 60 then
        return string.format("Scan (%dm)", math.ceil(wait / 60))
    end
    return string.format("Scan (%ds)", wait)
end

--- Seconds left before the next full scan is allowed.
-- @param replicateAt when the last full-scan request went out, or nil
-- @param now the current time()
-- @return seconds to wait, 0 when a scan is allowed now
function PriceLedger.SecondsUntil(replicateAt, now)
    if type(replicateAt) ~= "number" or type(now) ~= "number" then
        return 0
    end
    local left = PriceLedger.SCAN_INTERVAL - (now - replicateAt)
    if left < 0 then
        return 0
    end
    return left
end

--- Price for a mouseover.
-- The player's own house wins. If that house has never seen the item, the
-- last scanned house is used and its side is returned so the tooltip can say
-- where the price came from.
-- @param db the saved table
-- @param itemID the item's id
-- @param homeKey the player's own house key
-- @return nil when no house has a price, or
--   { unit, qty, seen, scannedAt, stats, side }; side is nil for the own house
function PriceLedger.Lookup(db, itemID, homeKey)
    if type(db) ~= "table" or type(db.houses) ~= "table" then
        return nil
    end
    if type(itemID) ~= "number" then
        return nil
    end

    --- The house and the item's priced row for a house key, or nil.
    local function RowFrom(key)
        if type(key) ~= "string" then
            return nil
        end
        local house = db.houses[key]
        if type(house) ~= "table" or type(house.items) ~= "table" then
            return nil
        end
        local row = house.items[itemID]
        if type(row) ~= "table" or type(row.unit) ~= "number" or row.unit <= 0 then
            return nil
        end
        return house, row
    end

    local house, row = RowFrom(homeKey)
    if row then
        return {
            unit = row.unit,
            qty = row.qty,
            seen = row.seen,
            scannedAt = house.scannedAt,
            stats = PriceLedger.Stats(row),
            side = nil,
        }
    end

    local lastKey = db.lastHouseKey
    if lastKey ~= homeKey then
        house, row = RowFrom(lastKey)
        if row then
            return {
                unit = row.unit,
                qty = row.qty,
                seen = row.seen,
                scannedAt = house.scannedAt,
                stats = PriceLedger.Stats(row),
                side = string.match(lastKey, "^([^|]+)"),
            }
        end
    end
    return nil
end

-- Game icons, checked in the Forever client. |A...|a is the game's atlas
-- markup: name, height, width, x and y offset, then an optional tint.
local ARROW_UP = "NPE_ArrowUp"
local ARROW_DOWN = "NPE_ArrowDown"
local RED = { 255, 32, 32, "ff2020" }
local GREEN = { 32, 255, 32, "20ff20" }
PriceLedger.DEAL_ICON = "|A:Bonus-Objective-Star:16:16:0:0|a"

--- Arrow and percent for a trend, colored for who is looking.
-- @param stats from PriceLedger.Stats, or a table with trend and trendPct
-- @param view "buyer" (up is red, down is green) or "seller" (the reverse)
-- @return markup like an arrow then "+12%", or "" for flat or no trend
function PriceLedger.TrendText(stats, view)
    if type(stats) ~= "table" or (stats.trend ~= "up" and stats.trend ~= "down") then
        return ""
    end
    local rising = stats.trend == "up"
    local good = (view == "seller") == rising
    local color = good and GREEN or RED
    local percent = math.floor(math.abs(stats.trendPct) * 100 + 0.5)
    return string.format("|A:%s:14:14:0:0:%d:%d:%d|a|cff%s%s%d%%|r",
        rising and ARROW_UP or ARROW_DOWN, color[1], color[2], color[3],
        color[4], rising and "+" or "-", percent)
end

--- Grey "steady +3%" for a price within the trend threshold of its 7-day average.
-- This way a quiet price does not look like missing data.
-- @param verdict from PriceLedger.Judge
-- @return the markup, or "" when the trend is up, down or not known yet
function PriceLedger.SteadyText(verdict)
    if type(verdict) ~= "table" or verdict.trend ~= "flat" or type(verdict.trendPct) ~= "number" then
        return ""
    end
    local percent = math.floor(math.abs(verdict.trendPct) * 100 + 0.5)
    if percent == 0 then
        return "|cff9d9d9dsteady|r"
    end
    return string.format("|cff9d9d9dsteady %s%d%%|r", verdict.trendPct < 0 and "-" or "+", percent)
end

--- A count and a word, with an "s" unless the count is 1.
-- @param count a number
-- @param word the singular word
-- @return text like "1 scan" or "3 scans"
local function Plural(count, word)
    if count == 1 then
        return count .. " " .. word
    end
    return count .. " " .. word .. "s"
end

--- A price range like "95s - 1g 40s", or one price when the low and high match.
-- @param stats a table with low and high
-- @param coinText function(copper) -> money text
-- @return the range text
function PriceLedger.RangeText(stats, coinText)
    local range = coinText(stats.low)
    if stats.high ~= stats.low then
        range = range .. " - " .. coinText(stats.high)
    end
    return range
end

--- How many scans over how many days, like "9 scans over 6 days".
-- @param stats a table with scans and days
-- @return the text
function PriceLedger.CountText(stats)
    return Plural(stats.scans, "scan") .. " over " .. Plural(stats.days, "day")
end

--- How many are up in how many listings, like "7 in 2 listings".
-- @param summary from PriceLedger.LowestListing
-- @return the text
function PriceLedger.ListingText(summary)
    return summary.total .. " in " .. Plural(summary.listings, "listing")
end

local RangeText = PriceLedger.RangeText

--- One window as a { left, right } line.
-- Left is like "3 days, 3 scans"; right is like "avg 105c (100c - 115c)",
-- or just the price when low and high match.
-- @param window one entry of the Stats windows list
-- @param coinText function(copper) -> money text
-- @return { left, right }
local function WindowLine(window, coinText)
    local right = coinText(window.avg)
    if window.low ~= window.high then
        right = "avg " .. right .. " (" .. RangeText(window, coinText) .. ")"
    end
    return { left = Plural(window.days, "day") .. ", " .. Plural(window.scans, "scan"), right = right }
end

--- The saved stats for the Buy details block and the Sell tab.
-- One line per window (1, 3, 7 and 14 days, always all four so each keeps its
-- place), then the std dev of the earlier scans. A window with no scans beyond
-- the one before it says so in grey instead of repeating the same numbers.
-- @param stats from PriceLedger.Stats
-- @param coinText function(copper) -> money text
-- @return a list of { left, right }, or nil without stats
function PriceLedger.WindowLines(stats, coinText)
    if type(stats) ~= "table" or type(stats.windows) ~= "table" or type(coinText) ~= "function" then
        return nil
    end
    local lines = {}
    local previous
    for _, window in ipairs(stats.windows) do
        local line = WindowLine(window, coinText)
        if previous and window.scans == previous.scans then
            line.right = "|cff9d9d9dsame as " .. Plural(previous.days, "day") .. "|r"
        end
        lines[#lines + 1] = line
        previous = window
    end
    local spread
    if stats.spread ~= nil and Round(stats.spread) < 1 then
        -- The earlier scans all had the same price.
        spread = "none"
    elseif stats.spread ~= nil then
        spread = coinText(Round(stats.spread))
    else
        spread = "after " .. Plural(PriceLedger.TREND_MIN_SCANS - (stats.earlierScans or 0), "more scan")
    end
    lines[#lines + 1] = { left = "Std dev, earlier scans", right = spread }
    return lines
end

--- Tooltip lines for one item.
-- @param info from PriceLedger.Lookup
-- @param coinText function(copper) -> money text
-- @param showDetails true adds the 1/3/7/14-day rows, std dev and deal
-- @return nil, or a list of { left, right }. A line with a right side
--   is a two-column line.
function PriceLedger.TooltipLines(info, coinText, showDetails)
    if type(info) ~= "table" or type(info.unit) ~= "number" then
        return nil
    end
    if type(coinText) ~= "function" then
        return nil
    end

    local label = "HouseLedger"
    if type(info.side) == "string" and info.side ~= "" then
        label = label .. " (" .. info.side .. ")"
    end

    local stats = info.stats
    local text = label .. "  " .. coinText(info.unit)
    local trend = PriceLedger.TrendText(stats, "buyer")
    if trend ~= "" then
        text = text .. "  " .. trend
    end
    if type(stats) == "table" and stats.deal then
        text = text .. "  " .. PriceLedger.DEAL_ICON
    end
    local stale = type(info.scannedAt) == "number"
        and type(info.seen) == "number"
        and info.seen < info.scannedAt
    if stale then
        text = text .. "  last seen " .. FormatStamp(info.seen)
    end

    local lines = { { left = text } }
    if not showDetails or type(stats) ~= "table" then
        return lines
    end

    -- One row per window; a window with no scans beyond the last row's
    -- would only repeat it.
    local shown = 0
    for _, window in ipairs(stats.windows) do
        if window.scans > shown then
            shown = window.scans
            lines[#lines + 1] = WindowLine(window, coinText)
        end
    end
    if stats.spread and Round(stats.spread) >= 1 then
        lines[#lines + 1] = { left = "Std dev, earlier scans", right = coinText(Round(stats.spread)) }
    end
    if stats.typical == nil then
        local needed = PriceLedger.TREND_MIN_SCANS - stats.earlierScans
        lines[#lines + 1] = { left = "Trend after " .. Plural(needed, "more scan") }
    end
    if stats.deal then
        lines[#lines + 1] = {
            left = PriceLedger.DEAL_ICON .. " Good deal",
            right = Round(stats.dealPct * 100) .. "% under the " .. PriceLedger.BASELINE_DAYS .. "-day average",
        }
    end
    return lines
end
