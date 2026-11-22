--[[
Price history for one auction house.

Pure data. No frames, no queries, and no seller names. The scan
code hands in item id, stack size, and buyout. This file keeps the
lowest price per item, one summary per calendar day for the last
14 or 30 days (low, high, scan count, sum and sum of squares), and works out
the stats the tooltip and window show: average, range and standard
deviation over the last 1, 3, 7 and 14 days.

Every number here is the cheapest asking price a scan saw, not a
sale price.
]]

-- The game hands each addon file its name and the addon's own table; the window code reads this
-- module as ns.Price. Offline (lua5.1 and dofile) there is no table, and dofile returns the
-- module instead (the return at the end).
local _, ns = ...
local PriceLedger = {}
if type(ns) == "table" then
    ns.Price = PriceLedger
end

PriceLedger.DB_VERSION = 3

-- The Settings tab, in display order: saved key, label and default. Saved per account in
-- HouseLedgerDB.settings; an optional table, so no version change.
PriceLedger.SETTINGS = {
    { key = "tooltipPrices", label = "Show prices on item tooltips", default = true },
    { key = "tooltipDetails", label = "Show the day lines on tooltips without holding Shift", default = false },
    { key = "priceCheckButton", label = "Show a Price Check button above the bags", default = true },
}
PriceLedger.SCAN_INTERVAL = 15 * 60

-- Days of summaries kept per item, today included. Set from the saved history length by EnsureDB
-- and SetHistoryDays; 14 until then.
PriceLedger.DAYS_KEPT = 14
-- History lengths the Settings tab offers, in days; the first is the default. 60 waits for a
-- smaller saved format: on a busy realm it could pass the saved file's constant limit.
PriceLedger.HISTORY_CHOICES = { 14, 30 }
-- The chart shows at least this many days, so a new item's few bars aren't stretched wide.
PriceLedger.CHART_MIN_DAYS = 7
-- How many scans each item keeps for the scan chart, as long as they're inside the history length.
PriceLedger.SCANS_KEPT = 30
-- The price chart's views: one bar per day, or one per scan. The first is the default.
PriceLedger.CHART_VIEWS = { "days", "scans" }
-- The house overview estimates the next day only from this many days of scans.
PriceLedger.OVERVIEW_MIN_DAYS = 5
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

--- Whether a value is an item quality the game knows: a whole number from 0 (Poor) to 8.
-- A scan reports -1 for an item it hasn't loaded, and the game's quality color function
-- rejects that.
-- @param quality the value to check
-- @return true for a real quality
function PriceLedger.IsQuality(quality)
    return type(quality) == "number" and quality >= 0 and quality <= 8 and quality == math.floor(quality)
end

-- The quality filter's choices, in menu order: any, or one quality and up.
PriceLedger.QUALITY_CHOICES = {
    { label = "Any quality" },
    { label = "Common & up", min = 1 },
    { label = "Uncommon & up", min = 2 },
    { label = "Rare & up", min = 3 },
    { label = "Epic & up", min = 4 },
}

--- Reads an item level box: a whole number from 1 up, or nil when empty or not a number.
-- @param text the box's text
-- @return the level, or nil
function PriceLedger.ParseLevel(text)
    if type(text) ~= "string" then
        return nil
    end
    local digits = text:match("^%s*(%d+)%s*$")
    local level = digits and tonumber(digits)
    if level and level >= 1 then
        return level
    end
    return nil
end

--- Whether a filter limits quality or item level (a name alone doesn't count).
-- @param filter { text, minQuality, minLevel, maxLevel }, each optional
-- @return true when a quality or level limit is set
function PriceLedger.FilterActive(filter)
    return filter.minQuality ~= nil or filter.minLevel ~= nil or filter.maxLevel ~= nil
end

--- Whether an item passes a filter. Pure: the caller looks the item up.
-- An item whose quality or level isn't known doesn't pass a limit on it; an item level of 0
-- (not gear) counts as unknown.
-- @param item { name, quality, level }, each optional
-- @param filter { text, minQuality, minLevel, maxLevel }, each optional; text matches any part
--   of the name, ignoring case
-- @return true when it passes
function PriceLedger.PassesFilter(item, filter)
    if type(filter.text) == "string" and filter.text ~= "" then
        if type(item.name) ~= "string" or not item.name:lower():find(filter.text:lower(), 1, true) then
            return false
        end
    end
    if filter.minQuality and not (PriceLedger.IsQuality(item.quality) and item.quality >= filter.minQuality) then
        return false
    end
    if filter.minLevel or filter.maxLevel then
        local level = item.level
        if type(level) ~= "number" or level <= 0 then
            return false
        end
        if (filter.minLevel and level < filter.minLevel) or (filter.maxLevel and level > filter.maxLevel) then
            return false
        end
    end
    return true
end

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

-- The realm part of a house key when the realm isn't known.
PriceLedger.UNKNOWN_REALM = "Forever"

--- True for a realm name the game really gave: a string that isn't empty.
-- @param name a value
-- @return true or false
local function IsRealmName(name)
    return type(name) == "string" and name ~= ""
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
        if type(day) == "table" and day[5] == nil
            and type(day[2]) == "number" and type(day[3]) == "number" and type(day[4]) == "number" then
            local low, high, scans = day[2], day[3], day[4]
            day[5] = (low + high) / 2 * scans
            day[6] = (low * low + high * high) / 2 * scans
        end
    end
end

--- Repairs a row's day list in place, on every load: a day that isn't a table with a numeric
-- day key, low, high and scan count is dropped, and a day missing its sums gets them the way
-- version 2 days did. A day list that isn't a table becomes empty. So one damaged day can't
-- break Stats for the tooltip or the whole Market list.
-- @param row an item row, changed in place
local function RepairDays(row)
    if type(row.days) ~= "table" then
        row.days = {}
        return
    end
    local kept = {}
    for _, day in ipairs(row.days) do
        if type(day) == "table" and type(day[1]) == "number" and type(day[2]) == "number"
            and type(day[3]) == "number" and type(day[4]) == "number" and day[4] > 0 then
            if type(day[5]) ~= "number" or type(day[6]) ~= "number" then
                day[5], day[6] = nil, nil
            end
            kept[#kept + 1] = day
        end
    end
    AddSumsFromV2(kept)
    row.days = kept
end

--- Repairs a row's scan list in place, on every load: one that isn't a table is dropped, and a
-- pair without a numeric time and price is left out. A list with nothing wrong isn't copied.
-- @param row an item row, changed in place
local function RepairScans(row)
    local scans = row.scans
    if scans == nil then
        return
    end
    if type(scans) ~= "table" then
        row.scans = nil
        return
    end
    local count = #scans
    local damaged = count % 2 == 1
    for index = 1, count do
        if type(scans[index]) ~= "number" then
            damaged = true
            break
        end
    end
    if not damaged then
        return
    end
    local kept = {}
    for index = 1, count - 1, 2 do
        if type(scans[index]) == "number" and type(scans[index + 1]) == "number" then
            kept[#kept + 1] = scans[index]
            kept[#kept + 1] = scans[index + 1]
        end
    end
    row.scans = kept
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
    if type(db.settings) ~= "table" then
        db.settings = {}
    end
    for _, setting in ipairs(PriceLedger.SETTINGS) do
        if type(db.settings[setting.key]) ~= "boolean" then
            db.settings[setting.key] = setting.default
        end
    end
    if not PriceLedger.IsHistoryChoice(db.settings.historyDays) then
        db.settings.historyDays = nil
    end
    PriceLedger.DAYS_KEPT = db.settings.historyDays or PriceLedger.HISTORY_CHOICES[1]
    if db.settings.chartView ~= nil and PriceLedger.ChartView(db) ~= db.settings.chartView then
        db.settings.chartView = nil
    end
    -- Item names and qualities are optional, saved by scans from late 2026 on, and so are the
    -- house's daily totals.
    for _, house in pairs(db.houses) do
        if type(house) == "table" and house.daily ~= nil then
            if type(house.daily) ~= "table" then
                house.daily = nil
            else
                local kept = {}
                for _, day in ipairs(house.daily) do
                    if type(day) == "table" and type(day[1]) == "number" and type(day[2]) == "number"
                        and type(day[3]) == "number" and type(day[4]) == "number" then
                        kept[#kept + 1] = day
                    end
                end
                house.daily = kept
            end
        end
        if type(house) == "table" and type(house.items) == "table" then
            for _, row in pairs(house.items) do
                if type(row) == "table" then
                    RepairDays(row)
                    RepairScans(row)
                    if row.name ~= nil and type(row.name) ~= "string" then
                        row.name = nil
                    end
                    if row.quality ~= nil and not PriceLedger.IsQuality(row.quality) then
                        row.quality = nil
                    end
                end
            end
        end
    end
    if not IsRealmName(db.homeRealm) then
        db.homeRealm = nil
    end
    PriceLedger.JoinUnknownRealm(db)
    db.version = PriceLedger.DB_VERSION
    return db
end

--- The key one house is saved under.
-- @param side "Alliance", "Horde" or "Neutral"; "Unknown" when missing
-- @param realm the realm name; UNKNOWN_REALM when missing
-- @return the key, "<side>|<realm>"
function PriceLedger.HouseKey(side, realm)
    if type(side) ~= "string" or side == "" then
        side = "Unknown"
    end
    if not IsRealmName(realm) then
        realm = PriceLedger.UNKNOWN_REALM
    end
    return side .. "|" .. realm
end

--- The realm to file prices under. Since the Forever client update of 2026-11-20 the game can
-- give a blank realm name; a blank one means the last realm the game did name, so a character's
-- scans keep going into the same history. A real name is remembered as that realm.
-- @param db the saved table; its homeRealm is set from a real name
-- @param name what GetRealmName() returned
-- @return the realm name, or UNKNOWN_REALM when no name was ever seen
function PriceLedger.RealmFor(db, name)
    if IsRealmName(name) then
        db.homeRealm = name
        return name
    end
    return db.homeRealm or PriceLedger.UNKNOWN_REALM
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
-- The item's name and quality are kept from any listing that has them: the
-- game leaves the name nil for an item it hasn't loaded yet.
-- @param best itemID -> { buyout, count, qty, units, name, quality }; changed in place. qty is how
--   many are up at the cheapest unit price, units how many are up with a buyout at any price
-- @param itemID the item's id
-- @param count stack size
-- @param buyout stack buyout in copper
-- @param name optional item name
-- @param quality optional item quality
function PriceLedger.Consider(best, itemID, count, buyout, name, quality)
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
    if type(name) ~= "string" or name == "" then
        name = current and current.name
    end
    if not PriceLedger.IsQuality(quality) then
        quality = current and current.quality
    end
    if current == nil then
        best[itemID] = { buyout = buyout, count = count, qty = count, units = count, name = name, quality = quality }
        return
    end
    current.name, current.quality = name, quality
    -- Every unit with a buyout counts toward the item's units, whatever its price.
    local units = (current.units or current.qty) + count

    local incoming = buyout * current.count
    local stored = current.buyout * count
    if incoming < stored then
        best[itemID] = { buyout = buyout, count = count, qty = count, units = units, name = name, quality = quality }
        return
    end
    current.units = units
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

--- Removes the first `drop` values of a list, moving the rest down.
-- @param list an array; changed in place
-- @param drop how many to remove from the front
local function DropFirst(list, drop)
    if drop <= 0 then
        return
    end
    local count = #list
    for index = 1, count - drop do
        list[index] = list[index + drop]
    end
    for index = count - drop + 1, count do
        list[index] = nil
    end
end

--- Drops days before `oldest`, and the oldest days past DAYS_KEPT.
-- @param days a row's day list, oldest first; changed in place
-- @param oldest the first day key to keep
local function PruneDays(days, oldest)
    local drop = 0
    while drop < #days and (days[drop + 1][1] < oldest or #days - drop > PriceLedger.DAYS_KEPT) do
        drop = drop + 1
    end
    DropFirst(days, drop)
end

--- Drops a row's scans from days before `oldest`, and the oldest scans past SCANS_KEPT. One scan
-- saves every item with the same time, so the day key of each time is worked out once and kept
-- in `dayKeys`, not once per item.
-- @param scans a row's scan list (time, price, time, price, ...), oldest first; changed in place
-- @param oldest the first day key to keep
-- @param dayKeys time -> day key, shared by the caller across rows; filled in as needed
local function PruneScans(scans, oldest, dayKeys)
    local count = math.floor(#scans / 2)
    local drop = 0
    while drop < count do
        if count - drop <= PriceLedger.SCANS_KEPT then
            local time = scans[2 * drop + 1]
            local key = dayKeys[time]
            if key == nil then
                key = PriceLedger.DayKey(time)
                dayKeys[time] = key
            end
            if key >= oldest then
                break
            end
        end
        drop = drop + 1
    end
    DropFirst(scans, 2 * drop)
end

--- The first day key a scan at `now` keeps.
-- @param now when the scan ran
-- @return the day key DAYS_KEPT - 1 days before now
local function OldestKept(now)
    return PriceLedger.DayKey(now - (PriceLedger.DAYS_KEPT - 1) * SECONDS_PER_DAY)
end

--- Adds one listing to a scan's house totals. A bid-only listing (no buyout) isn't counted.
-- The value counts the listing's own buyout; Commit replaces it with the value at each item's
-- cheapest price, so a few listings at joke prices don't swamp it.
-- @param totals { listings, units, value }, changed in place; starts empty
-- @param count how many items the listing holds
-- @param buyout the listing's buyout in copper
function PriceLedger.AddToTotals(totals, count, buyout)
    if type(count) ~= "number" or count <= 0 or type(buyout) ~= "number" or buyout <= 0 then
        return
    end
    totals.listings = (totals.listings or 0) + 1
    totals.units = (totals.units or 0) + count
    totals.value = (totals.value or 0) + buyout
end

--- Saves a scan's house totals as its day's: { dayKey, listings, units, value }, oldest first.
-- A later scan the same day replaces the day's totals, so each day keeps its last full scan.
-- @param house the house table; its daily list is made when missing
-- @param now when the scan ran
-- @param totals from AddToTotals, or nil to save nothing
local function RecordHouseDay(house, now, totals)
    if type(house.daily) ~= "table" then
        house.daily = {}
    end
    if type(totals) ~= "table" or (totals.listings or 0) <= 0 then
        return
    end
    local key = PriceLedger.DayKey(now)
    local daily = house.daily
    local entry = { key, totals.listings, totals.units, totals.value }
    if #daily > 0 and daily[#daily][1] == key then
        daily[#daily] = entry
    else
        daily[#daily + 1] = entry
    end
end

--- Remember, with the first day to keep worked out by the caller.
-- @param house the house table
-- @param itemID the item's id
-- @param unit unit price in copper
-- @param qty how many were listed at that price
-- @param now when the scan ran
-- @param oldest the first day key to keep
-- @param dayKeys the time -> day key cache for PruneScans
-- @return the item's row
local function RememberFrom(house, itemID, unit, qty, now, oldest, dayKeys)
    local row = house.items[itemID]
    if type(row) ~= "table" then
        row = {}
        house.items[itemID] = row
    end
    if type(row.days) ~= "table" then
        row.days = {}
    end

    AddToDays(row.days, unit, now)
    PruneDays(row.days, oldest)
    if type(row.scans) ~= "table" then
        row.scans = {}
    end
    row.scans[#row.scans + 1] = now
    row.scans[#row.scans + 1] = unit
    PruneScans(row.scans, oldest, dayKeys)

    row.unit = unit
    row.qty = qty
    row.seen = now
    return row
end

--- Saves one item's price from a scan: the latest price, the day summary and the scan.
-- Days older than DAYS_KEPT are dropped, and scans past SCANS_KEPT or that old.
-- @param house the house table
-- @param itemID the item's id
-- @param unit unit price in copper
-- @param qty how many were listed at that price
-- @param now when the scan ran
-- @return the item's row
function PriceLedger.Remember(house, itemID, unit, qty, now)
    return RememberFrom(house, itemID, unit, qty, now, OldestKept(now), {})
end

--- Saves one finished scan.
-- Items missing from `best` stay in the house with their old price, seen
-- time and name, so a later mouseover can still show the last known price,
-- but their days and scans older than DAYS_KEPT are dropped like everyone else's.
-- Also sets the house's scannedAt and the db's lastHouseKey.
-- @param db the saved table
-- @param houseKey key of the house that was scanned
-- @param best the lowest-price table from Consider
-- @param now when the scan ran
-- @param totals optional; the scan's listings, units and value from AddToTotals, saved as the
--   day's house totals
-- @return how many item prices were saved
function PriceLedger.Commit(db, houseKey, best, now, totals)
    local house = PriceLedger.EnsureHouse(db, houseKey)
    house.scannedAt = now
    local oldest = OldestKept(now)
    local dayKeys = {}
    local saved = 0
    for itemID, listing in pairs(best) do
        local unit = PriceLedger.UnitCopper(listing.buyout, listing.count)
        if unit > 0 then
            local row = RememberFrom(house, itemID, unit, listing.qty, now, oldest, dayKeys)
            -- A scan that didn't get the name keeps the one saved before.
            row.name = listing.name or row.name
            row.quality = listing.quality or row.quality
            saved = saved + 1
        end
    end
    for _, row in pairs(house.items) do
        if type(row) == "table" and row.seen ~= now then
            if type(row.days) == "table" then
                PruneDays(row.days, oldest)
            end
            if type(row.scans) == "table" then
                PruneScans(row.scans, oldest, dayKeys)
            end
        end
    end
    if type(totals) == "table" then
        -- Each item's units at its cheapest unit price: what the house holds at the prices
        -- buyers would pay first, not the sum of every asking price.
        local value = 0
        for _, listing in pairs(best) do
            value = value + PriceLedger.UnitCopper(listing.buyout, listing.count) * (listing.units or listing.qty or 0)
        end
        totals.value = value
    end
    RecordHouseDay(house, now, totals)
    PruneDays(house.daily, oldest)
    db.lastHouseKey = houseKey
    return saved
end

--- One day list from two: a day both have becomes one day (lowest low, highest high, the scans
-- and sums added up), oldest first. Neither list is changed.
-- @param first a row's day list
-- @param second another row's day list
-- @return a new day list
local function MergeDays(first, second)
    local byKey, merged = {}, {}
    -- Not ipairs: it would stop at a nil first list.
    local lists = { first, second }
    for which = 1, 2 do
        local list = lists[which]
        for _, day in ipairs(type(list) == "table" and list or {}) do
            local have = byKey[day[1]]
            if have then
                have[2] = math.min(have[2], day[2])
                have[3] = math.max(have[3], day[3])
                have[4] = have[4] + day[4]
                have[5] = have[5] + day[5]
                have[6] = have[6] + day[6]
            else
                local copy = { day[1], day[2], day[3], day[4], day[5], day[6] }
                byKey[day[1]] = copy
                merged[#merged + 1] = copy
            end
        end
    end
    table.sort(merged, function(a, b)
        return a[1] < b[1]
    end)
    return merged
end

--- One scan list from two: each scan time once, oldest first. Neither list is changed.
-- @param first a row's scan list (time, price, ...), or nil
-- @param second another row's scan list, or nil
-- @return a new scan list, or nil when neither row has one
local function MergeScans(first, second)
    if type(first) ~= "table" and type(second) ~= "table" then
        return nil
    end
    local byTime, scans = {}, {}
    -- Not ipairs: it would stop at a nil first list.
    local lists = { first, second }
    for which = 1, 2 do
        local list = lists[which]
        if type(list) == "table" then
            for index = 1, #list - 1, 2 do
                if not byTime[list[index]] then
                    byTime[list[index]] = true
                    scans[#scans + 1] = { list[index], list[index + 1] }
                end
            end
        end
    end
    table.sort(scans, function(a, b)
        return a[1] < b[1]
    end)
    local merged = {}
    for _, scan in ipairs(scans) do
        merged[#merged + 1] = scan[1]
        merged[#merged + 1] = scan[2]
    end
    return merged
end

--- Moves one house's items and daily totals into another, for two houses that are the same
-- auction house saved under two keys. An item in both gets one day list (see MergeDays), one
-- scan list (see MergeScans) and its latest price, count and seen time from whichever saw it last; its name and quality from
-- there too, or from the other when that has none. A day in both daily lists keeps the totals
-- of the house scanned last. Then both lists are pruned to the history length.
-- @param into the house that stays; changed in place
-- @param from the house that goes; its rows are moved, not copied
-- @return into
function PriceLedger.MergeHouse(into, from)
    if type(into.items) ~= "table" then
        into.items = {}
    end
    for itemID, row in pairs(type(from.items) == "table" and from.items or {}) do
        local have = into.items[itemID]
        if type(have) ~= "table" then
            into.items[itemID] = row
        elseif type(row) == "table" then
            local newer, older = row, have
            if (have.seen or 0) >= (row.seen or 0) then
                newer, older = have, row
            end
            have.days = MergeDays(have.days, row.days)
            have.scans = MergeScans(have.scans, row.scans)
            have.unit, have.qty, have.seen = newer.unit, newer.qty, newer.seen
            have.name = newer.name or older.name
            have.quality = newer.quality or older.quality
        end
    end

    local fromLater = (from.scannedAt or 0) >= (into.scannedAt or 0)
    local dailyByKey, daily = {}, {}
    local lists = fromLater and { into.daily, from.daily } or { from.daily, into.daily }
    -- Not ipairs: it would stop at a nil first list.
    for which = 1, 2 do
        local list = lists[which]
        for _, day in ipairs(type(list) == "table" and list or {}) do
            if dailyByKey[day[1]] then
                -- The later list wins the day.
                daily[dailyByKey[day[1]]] = day
            else
                daily[#daily + 1] = day
                dailyByKey[day[1]] = #daily
            end
        end
    end
    table.sort(daily, function(a, b)
        return a[1] < b[1]
    end)
    into.daily = daily

    into.scannedAt = math.max(into.scannedAt or 0, from.scannedAt or 0)
    if into.scannedAt == 0 then
        into.scannedAt = nil
    end
    if from.replicateAt and (into.replicateAt == nil or from.replicateAt > into.replicateAt) then
        into.replicateAt = from.replicateAt
    end
    if into.scannedAt then
        local oldest = OldestKept(into.scannedAt)
        local dayKeys = {}
        for _, row in pairs(into.items) do
            if type(row) == "table" and type(row.days) == "table" then
                PruneDays(row.days, oldest)
            end
            if type(row) == "table" and type(row.scans) == "table" then
                PruneScans(row.scans, oldest, dayKeys)
            end
        end
        PruneDays(into.daily, oldest)
    end
    return into
end

-- The house keys JoinUnknownRealm joined on the last load, so the addon can say so once.
PriceLedger.joined = {}

--- Joins each house saved under the unknown realm into the same side's house on the realm the
-- game last named, so scans saved while the game gave a blank realm name aren't a separate,
-- nearly empty history. The realm comes from homeRealm, or, before that was saved, from the
-- house keys when they name just one realm. With two or more named realms and no homeRealm the
-- houses are left apart: which realm they belong to can't be told.
-- @param db the saved table; changed in place
-- @return the list of keys houses were joined into (also kept in PriceLedger.joined)
function PriceLedger.JoinUnknownRealm(db)
    PriceLedger.joined = {}
    if db.homeRealm == nil then
        local only
        for key in pairs(db.houses) do
            local realm = string.match(key, "^[^|]*|(.*)$")
            if IsRealmName(realm) and realm ~= PriceLedger.UNKNOWN_REALM then
                if only ~= nil and only ~= realm then
                    return PriceLedger.joined
                end
                only = realm
            end
        end
        if only == nil then
            return PriceLedger.joined
        end
        db.homeRealm = only
    end
    if db.homeRealm == PriceLedger.UNKNOWN_REALM then
        return PriceLedger.joined
    end
    local moves = {}
    for key, house in pairs(db.houses) do
        local side, realm = string.match(key, "^([^|]*)|(.*)$")
        if realm == PriceLedger.UNKNOWN_REALM and type(house) == "table" then
            moves[#moves + 1] = { from = key, into = side .. "|" .. db.homeRealm }
        end
    end
    table.sort(moves, function(a, b)
        return a.from < b.from
    end)
    for _, move in ipairs(moves) do
        local from = db.houses[move.from]
        local into = db.houses[move.into]
        if type(into) == "table" then
            PriceLedger.MergeHouse(into, from)
        else
            db.houses[move.into] = from
        end
        db.houses[move.from] = nil
        if db.lastHouseKey == move.from then
            db.lastHouseKey = move.into
        end
        PriceLedger.joined[#PriceLedger.joined + 1] = move.into
    end
    return PriceLedger.joined
end

--- True for a history length the Settings tab offers.
-- @param days a value
-- @return true or false
function PriceLedger.IsHistoryChoice(days)
    for _, choice in ipairs(PriceLedger.HISTORY_CHOICES) do
        if days == choice then
            return true
        end
    end
    return false
end

--- Sets how many days of prices each item keeps, and saves it. A shorter length trims every
-- item's days and scans in every house right away, each house back from its own last scan.
-- @param db the saved table
-- @param days one of HISTORY_CHOICES; anything else changes nothing
-- @return the history length now in use
function PriceLedger.SetHistoryDays(db, days)
    if not PriceLedger.IsHistoryChoice(days) or type(db) ~= "table" then
        return PriceLedger.DAYS_KEPT
    end
    if type(db.settings) ~= "table" then
        db.settings = {}
    end
    db.settings.historyDays = days
    PriceLedger.DAYS_KEPT = days
    for _, house in pairs(type(db.houses) == "table" and db.houses or {}) do
        if type(house) == "table" and type(house.items) == "table" and type(house.scannedAt) == "number" then
            local oldest = OldestKept(house.scannedAt)
            local dayKeys = {}
            for _, row in pairs(house.items) do
                if type(row) == "table" and type(row.days) == "table" then
                    PruneDays(row.days, oldest)
                end
                if type(row) == "table" and type(row.scans) == "table" then
                    PruneScans(row.scans, oldest, dayKeys)
                end
            end
            if type(house.daily) == "table" then
                PruneDays(house.daily, oldest)
            end
        end
    end
    return days
end

--- The price chart's view, saved in settings.
-- @param db the saved table, or nil
-- @return one of CHART_VIEWS; the first when none is saved
function PriceLedger.ChartView(db)
    local saved = type(db) == "table" and type(db.settings) == "table" and db.settings.chartView
    for _, view in ipairs(PriceLedger.CHART_VIEWS) do
        if saved == view then
            return view
        end
    end
    return PriceLedger.CHART_VIEWS[1]
end

--- Sets the price chart's view, and saves it.
-- @param db the saved table
-- @param view one of CHART_VIEWS; anything else changes nothing
-- @return the view now in use
function PriceLedger.SetChartView(db, view)
    for _, choice in ipairs(PriceLedger.CHART_VIEWS) do
        if view == choice and type(db) == "table" then
            if type(db.settings) ~= "table" then
                db.settings = {}
            end
            db.settings.chartView = view
        end
    end
    return PriceLedger.ChartView(db)
end

--- Rounds to the nearest whole number, halves up.
-- @param value a number
-- @return the rounded number
local function Round(value)
    return math.floor(value + 0.5)
end

--- How many days each window holds, in the order Stats reads them: the WINDOWS, then the widest
-- (DAYS_KEPT), then the baseline (BASELINE_DAYS). Rebuilt when any of those changes.
local windowLengths = {}
--- First day key of each window, for the scan time in startsFor. A full scan saves one time for
-- every item it saw, so Market and the tooltips reuse these instead of formatting dates per item.
local windowStarts, latestKeyFor, startsFor = {}, nil, nil

--- True when windowLengths still matches the settings, compared length by length, so a window
-- changed in place counts too.
-- @param windows PriceLedger.WINDOWS
-- @return true or false
local function LengthsCurrent(windows)
    local count = #windows
    if #windowLengths ~= count + 2 or windowLengths[count + 1] ~= PriceLedger.DAYS_KEPT
        or windowLengths[count + 2] ~= PriceLedger.BASELINE_DAYS then
        return false
    end
    for index = 1, count do
        if windowLengths[index] ~= windows[index] then
            return false
        end
    end
    return true
end

--- The window lengths for the current settings.
-- @return the list of lengths, with the widest at #WINDOWS + 1 and the baseline at #WINDOWS + 2
local function WindowLengths()
    local windows = PriceLedger.WINDOWS
    if not LengthsCurrent(windows) then
        windowLengths = {}
        for index, length in ipairs(windows) do
            windowLengths[index] = length
        end
        windowLengths[#windows + 1] = PriceLedger.DAYS_KEPT
        windowLengths[#windows + 2] = PriceLedger.BASELINE_DAYS
        -- New lengths need new first days.
        startsFor = nil
    end
    return windowLengths
end

--- The day key of a scan time and the first day key of each window back from it.
-- @param seen the latest scan's time() value
-- @param lengths from WindowLengths
-- @return the latest day key and the list of first day keys (shared: don't change it)
local function WindowStarts(seen, lengths)
    if seen ~= startsFor then
        windowStarts = {}
        for index, length in ipairs(lengths) do
            windowStarts[index] = PriceLedger.DayKey(seen - (length - 1) * SECONDS_PER_DAY)
        end
        latestKeyFor = PriceLedger.DayKey(seen)
        startsFor = seen
    end
    return latestKeyFor, windowStarts
end

-- Running totals per window, reused by every Stats call so a pass over thousands of items makes
-- no tables for them.
local totalScans, totalDays, totalSum, totalSquares, totalLow, totalHigh = {}, {}, {}, {}, {}, {}

--- Adds up a row's days into windows first..last in one walk over the days.
-- @param days a row's day list
-- @param latestKey the last day to count
-- @param starts first day key of each window
-- @param first the first window to add up
-- @param last the last window to add up
local function AddUpWindows(days, latestKey, starts, first, last)
    for index = first, last do
        totalScans[index], totalDays[index], totalSum[index], totalSquares[index] = 0, 0, 0, 0
        totalLow[index], totalHigh[index] = nil, nil
    end
    for _, day in ipairs(days) do
        local key = day[1]
        if key <= latestKey then
            local scans, low, high, sum, squares = day[4], day[2], day[3], day[5], day[6]
            for index = first, last do
                if key >= starts[index] then
                    totalScans[index] = totalScans[index] + scans
                    totalDays[index] = totalDays[index] + 1
                    totalSum[index] = totalSum[index] + sum
                    totalSquares[index] = totalSquares[index] + squares
                    totalLow[index] = math.min(totalLow[index] or low, low)
                    totalHigh[index] = math.max(totalHigh[index] or high, high)
                end
            end
        end
    end
end

--- Sets earlierScans, typical and spread from the baseline window's totals.
-- The baseline leaves the latest scan out, so it is not compared with itself.
-- @param target the table to set them on
-- @param unit the latest scan's price
-- @param base the baseline window's index in the totals
local function SetBaseline(target, unit, base)
    local count = totalScans[base] - 1
    target.earlierScans = math.max(0, count)
    target.typical, target.spread = nil, nil
    if count >= PriceLedger.TREND_MIN_SCANS then
        local sum = totalSum[base] - unit
        local mean = sum / count
        local variance = (totalSquares[base] - unit * unit - count * mean * mean) / (count - 1)
        target.typical = Round(mean)
        target.spread = math.sqrt(math.max(0, variance))
    end
end

--- True when a row has what Stats needs.
-- @param row an item row
-- @return true or false
local function HasStats(row)
    return type(row) == "table" and type(row.days) == "table" and #row.days > 0
        and type(row.unit) == "number" and type(row.seen) == "number"
end

--- Stats for one item, measured back from its latest scan's day.
-- Walks the row's days once for all windows.
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
    if not HasStats(row) then
        return nil
    end

    local lengths = WindowLengths()
    local latestKey, starts = WindowStarts(row.seen, lengths)
    local windowCount = #PriceLedger.WINDOWS
    AddUpWindows(row.days, latestKey, starts, 1, windowCount + 2)

    local stats = { unit = row.unit, seen = row.seen, windows = {} }
    for index = 1, windowCount do
        local scans = totalScans[index]
        stats.windows[index] = {
            days = lengths[index],
            scans = scans,
            low = totalLow[index],
            high = totalHigh[index],
            avg = scans > 0 and Round(totalSum[index] / scans) or nil,
        }
    end
    local widest = windowCount + 1
    stats.scans, stats.days = totalScans[widest], totalDays[widest]
    stats.low, stats.high = totalLow[widest], totalHigh[widest]

    SetBaseline(stats, row.unit, windowCount + 2)

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

--- The price chart's data: one slot per calendar day, oldest first, ending on the day of the
-- latest scan. It starts at the oldest saved day, so it grows with the history: at least
-- CHART_MIN_DAYS slots, at most DAYS_KEPT. Reads the row's saved day summaries only.
-- @param days a row's day list ({ dayKey, low, high, ... } per day)
-- @param seen when the row's latest scan was
-- @return nil without days, or { slots, top, days }: slots[i] is { dayKey, low, high }, with low
--   and high nil on a day with no scan; top is the highest price in the slots; days is #slots
function PriceLedger.ChartDays(days, seen)
    if type(days) ~= "table" or #days == 0 or type(seen) ~= "number" then
        return nil
    end
    local byKey, oldestKey = {}, nil
    for _, day in ipairs(days) do
        byKey[day[1]] = day
        oldestKey = math.min(oldestKey or day[1], day[1])
    end
    -- Day keys back from the latest scan, as far as the history goes; the chart starts at the
    -- oldest saved day, with at least CHART_MIN_DAYS slots.
    local keys = {}
    for back = 0, PriceLedger.DAYS_KEPT - 1 do
        keys[back + 1] = PriceLedger.DayKey(seen - back * SECONDS_PER_DAY)
    end
    local count = PriceLedger.CHART_MIN_DAYS
    for index = #keys, 1, -1 do
        if keys[index] >= oldestKey then
            count = math.max(count, index)
            break
        end
    end
    count = math.min(count, #keys)
    local chart = { slots = {}, top = 0, days = count }
    for back = count - 1, 0, -1 do
        local key = keys[back + 1]
        local day = byKey[key]
        chart.slots[#chart.slots + 1] = { dayKey = key, low = day and day[2], high = day and day[3] }
        if day then
            chart.top = math.max(chart.top, day[3])
        end
    end
    return chart
end

--- An item's saved scans as chart slots: one per scan, oldest first, with at least
-- CHART_MIN_DAYS slots (empty ones first) so a new item's few bars aren't drawn full width.
-- Reads the row's scan list only.
-- @param scans a row's scan list (time, price, time, price, ...), or nil
-- @return nil without scans, or { slots, top, count }: a filled slot is { time, dayKey, low, high }
--   with low and high both the scan's price, an empty one is {}; top is the highest price and
--   count how many scans there are
function PriceLedger.ChartScans(scans)
    if type(scans) ~= "table" or #scans < 2 then
        return nil
    end
    local count = math.floor(#scans / 2)
    local chart = { slots = {}, top = 0, count = count }
    for _ = count + 1, PriceLedger.CHART_MIN_DAYS do
        chart.slots[#chart.slots + 1] = {}
    end
    for index = 1, 2 * count - 1, 2 do
        local time, price = scans[index], scans[index + 1]
        chart.slots[#chart.slots + 1] = { time = time, dayKey = PriceLedger.DayKey(time), low = price, high = price }
        chart.top = math.max(chart.top, price)
    end
    return chart
end

--- When a scan chart's scans were, for its hover tip.
-- @param chart from ChartScans, or nil
-- @return "first to last" as month/day and time, just the time for one scan, or nil
function PriceLedger.ScanSpanText(chart)
    if type(chart) ~= "table" or type(chart.slots) ~= "table" then
        return nil
    end
    local first, last
    for _, slot in ipairs(chart.slots) do
        if slot.time then
            first = first or slot.time
            last = slot.time
        end
    end
    if first == nil then
        return nil
    end
    if first == last then
        return FormatStamp(first)
    end
    return FormatStamp(first) .. " to " .. FormatStamp(last)
end

--- A whole number with commas between thousands, like 1,234,567.
-- @param number a number; rounded to whole
-- @return the text
function PriceLedger.Thousands(number)
    local text = tostring(math.floor(math.abs(number) + 0.5))
    local grouped = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    grouped = grouped:gsub("^,", "")
    return (number < 0 and "-" or "") .. grouped
end

--- The house overview: how many items each day's scans saw, with the day's totals, and a
-- straight-line fit through the days that had scans. Reads saved data only.
-- One slot per calendar day, oldest first, ending on the day of the house's last scan; it starts
-- at the oldest day with a scan, with at least CHART_MIN_DAYS slots and at most DAYS_KEPT.
-- @param house a house table, or nil
-- @return nil before any scan, or a table:
--   slots[i] = { dayKey, items, listings, units, value }; items is nil on a day with no scan,
--     and the totals are nil on days saved before totals were kept
--   scanDays: days with a scan; mean, low, top: of their item counts
--   slope, intercept, fit(i): the least-squares line through (slot, items), from 2 days
--   residual: the sample standard deviation around that line, from 3 days
--   trendPct: slope as a share of the mean, per day
--   projection: the line at the next day, rounded, from OVERVIEW_MIN_DAYS days
function PriceLedger.HouseOverview(house)
    if type(house) ~= "table" or type(house.items) ~= "table" or type(house.scannedAt) ~= "number" then
        return nil
    end
    local counts = {}
    for _, row in pairs(house.items) do
        if type(row) == "table" and type(row.days) == "table" then
            for _, day in ipairs(row.days) do
                counts[day[1]] = (counts[day[1]] or 0) + 1
            end
        end
    end
    local totals = {}
    for _, entry in ipairs(type(house.daily) == "table" and house.daily or {}) do
        totals[entry[1]] = entry
    end

    local keys = {}
    for back = 0, PriceLedger.DAYS_KEPT - 1 do
        keys[back + 1] = PriceLedger.DayKey(house.scannedAt - back * SECONDS_PER_DAY)
    end
    local count = PriceLedger.CHART_MIN_DAYS
    for index = #keys, 1, -1 do
        if counts[keys[index]] then
            count = math.max(count, index)
            break
        end
    end
    count = math.min(count, #keys)

    local overview = { slots = {}, scanDays = 0 }
    local sumX, sumY, sumXX, sumXY = 0, 0, 0, 0
    for back = count - 1, 0, -1 do
        local key = keys[back + 1]
        local day = totals[key]
        local slot = { dayKey = key, items = counts[key] }
        if day then
            slot.listings, slot.units, slot.value = day[2], day[3], day[4]
        end
        overview.slots[#overview.slots + 1] = slot
        local items = slot.items
        if items then
            local x = #overview.slots
            overview.scanDays = overview.scanDays + 1
            sumX, sumY, sumXX, sumXY = sumX + x, sumY + items, sumXX + x * x, sumXY + x * items
            overview.low = math.min(overview.low or items, items)
            overview.top = math.max(overview.top or items, items)
        end
    end
    local n = overview.scanDays
    if n == 0 then
        return nil
    end
    overview.mean = sumY / n
    if n >= 2 then
        local slope = (n * sumXY - sumX * sumY) / (n * sumXX - sumX * sumX)
        local intercept = (sumY - slope * sumX) / n
        overview.slope, overview.intercept = slope, intercept
        overview.fit = function(x)
            return intercept + slope * x
        end
        overview.trendPct = overview.mean > 0 and slope / overview.mean or 0
    end
    if n >= 3 then
        local squares = 0
        for x, slot in ipairs(overview.slots) do
            if slot.items then
                local off = slot.items - overview.fit(x)
                squares = squares + off * off
            end
        end
        overview.residual = math.sqrt(squares / (n - 2))
    end
    if n >= PriceLedger.OVERVIEW_MIN_DAYS then
        overview.projection = math.max(0, Round(overview.fit(#overview.slots + 1)))
    end
    return overview
end


--- Price Check: the saved items whose name holds the text, ignoring case. Names that start with
-- the text come first, then the rest, each A to Z. Reads saved data only; an item scanned before
-- names were saved has none yet and can't be found by name.
-- @param house a house table, or nil
-- @param text what the player typed; under 2 letters finds nothing
-- @param limit optional; at most this many (default 100)
-- @return list of { itemID, name, quality }, and how many matched in all (more than the list
--   holds when the limit cut it)
function PriceLedger.FindByName(house, text, limit)
    local found = {}
    if type(house) ~= "table" or type(house.items) ~= "table" or type(text) ~= "string" then
        return found, 0
    end
    local needle = text:lower():match("^%s*(.-)%s*$")
    if #needle < 2 then
        return found, 0
    end
    for itemID, row in pairs(house.items) do
        if type(row) == "table" and type(row.name) == "string" then
            local name = row.name:lower()
            local at = name:find(needle, 1, true)
            if at then
                found[#found + 1] = { itemID = itemID, name = row.name, quality = row.quality, starts = at == 1 }
            end
        end
    end
    table.sort(found, function(a, b)
        if a.starts ~= b.starts then
            return a.starts
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.itemID < b.itemID
    end)
    local total = #found
    limit = limit or 100
    for index = total, limit + 1, -1 do
        found[index] = nil
    end
    return found, total
end

--- A sorted copy of a list, by one value per item: a column click in the window. Items with no
-- value go last either way, and equal values keep their order, so sorting is stable.
-- @param list the items; left as it is
-- @param valueOf function(item) -> a number or a string, or nil when unknown
-- @param ascending true for low to high (A to Z), false for high to low
-- @return a new list
function PriceLedger.SortList(list, valueOf, ascending)
    local keyed = {}
    for index, item in ipairs(list) do
        keyed[index] = { item = item, value = valueOf(item), index = index }
    end
    table.sort(keyed, function(a, b)
        if a.value == nil or b.value == nil then
            if (a.value == nil) ~= (b.value == nil) then
                return b.value == nil
            end
            return a.index < b.index
        end
        if a.value ~= b.value then
            if ascending then
                return a.value < b.value
            end
            return a.value > b.value
        end
        return a.index < b.index
    end)
    local sorted = {}
    for index, entry in ipairs(keyed) do
        sorted[index] = entry.item
    end
    return sorted
end

--- Sorts market entries by how far the price moved, then by name and item id.
-- @param list entries from PriceLedger.Market, sorted in place
-- @param biggestRiseFirst true for the highest trendPct first, false for the lowest
local function SortByMove(list, biggestRiseFirst)
    table.sort(list, function(a, b)
        if a.trendPct ~= b.trendPct then
            if biggestRiseFirst then
                return a.trendPct > b.trendPct
            end
            return a.trendPct < b.trendPct
        end
        if (a.name or "") ~= (b.name or "") then
            return (a.name or "") < (b.name or "")
        end
        return a.itemID < b.itemID
    end)
end

--- The Market tab's three lists, from the items the house's last scan saw.
-- Reads saved data only. Items missing from the last scan are left out.
-- @param house a house table, or nil
-- @return { scannedAt, deals, drops, rises }; each list holds entries
--   { itemID, name, quality, unit, qty, typical, trendPct, deal }. Deals are
--   the deals, most under the typical price first; drops are every item
--   trending down (deals included), biggest drop first; rises are items
--   trending up, biggest rise first.
function PriceLedger.Market(house)
    local market = { deals = {}, drops = {}, rises = {} }
    if type(house) ~= "table" or type(house.items) ~= "table" then
        return market
    end
    market.scannedAt = house.scannedAt
    -- Only the baseline window matters here, so this adds up that one window and judges the
    -- price, the same way Stats does, without building the other windows.
    local base = #PriceLedger.WINDOWS + 2
    local baseline = {}
    for itemID, row in pairs(house.items) do
        if HasStats(row) and row.seen == house.scannedAt then
            local latestKey, starts = WindowStarts(row.seen, WindowLengths())
            AddUpWindows(row.days, latestKey, starts, base, base)
            SetBaseline(baseline, row.unit, base)
            local verdict = PriceLedger.Judge(baseline, row.unit)
            local listed = verdict.deal or verdict.trend == "down" or verdict.trend == "up"
            if listed then
                local entry = {
                    itemID = itemID, name = row.name, quality = row.quality, unit = row.unit,
                    qty = row.qty, typical = baseline.typical, trendPct = verdict.trendPct, deal = verdict.deal,
                }
                if entry.deal then
                    market.deals[#market.deals + 1] = entry
                end
                if verdict.trend == "down" then
                    market.drops[#market.drops + 1] = entry
                elseif verdict.trend == "up" then
                    market.rises[#market.rises + 1] = entry
                end
            end
        end
    end
    SortByMove(market.deals, false)
    SortByMove(market.drops, false)
    SortByMove(market.rises, true)
    return market
end

--- A house key as people read it: its side, "Horde|Realm" becomes "Horde", and a goblin
-- house (saved as "Neutral") is "Goblin". The realm is left out: the player knows it, and it
-- would show in every screenshot of the window.
-- @param key a house key
-- @return the label; "" for a non-string, the key itself when it has no "|"
function PriceLedger.HouseLabel(key)
    if type(key) ~= "string" then
        return ""
    end
    local side = string.match(key, "^([^|]*)|") or key
    if side == "Neutral" then
        return "Goblin"
    end
    return side
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

--- An item's saved price at one house.
-- Only that house is read: tooltips show the player's own faction's prices, and the window
-- the house that is open, never another side's.
-- @param db the saved table
-- @param itemID the item's id
-- @param homeKey the house to read
-- @return nil when that house has no price for it, or { unit, qty, seen, scannedAt, stats, days,
--   scans }
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
            days = row.days,
            scans = row.scans,
        }
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

--- The Sell tab's advice in plain words, from the lowest listing's verdict. It says what the
-- numbers on the tab mean; it never suggests or sets a price.
-- @param verdict PriceLedger.Judge of the lowest listing, or nil
-- @param listed false when no one else is selling the item
-- @return the advice line
function PriceLedger.SellAdvice(verdict, listed)
    if listed == false then
        return "No one else is selling it right now, so you set the price."
    end
    if type(verdict) ~= "table" or verdict.trend == nil then
        return "Not enough saved prices for advice yet."
    end
    if verdict.deal then
        return PriceLedger.DEAL_ICON .. " The lowest is far under its 7-day average. Waiting may sell for more."
    elseif verdict.trend == "up" then
        return "Prices are high today. A good time to sell."
    elseif verdict.trend == "down" then
        return "Prices are low today. Waiting may sell for more."
    end
    return "Prices are about normal today."
end

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

    local stats = info.stats
    local text = "HouseLedger  " .. coinText(info.unit)
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

--- The overview's text: a title, then five lines of { left, right } for the details block.
-- @param overview from HouseOverview
-- @param coinText formats copper as money
-- @return the title and the lines
function PriceLedger.OverviewLines(overview, coinText)
    local latest = overview.slots[#overview.slots]
    local lastItems
    for index = #overview.slots, 1, -1 do
        if overview.slots[index].items then
            lastItems = overview.slots[index].items
            break
        end
    end
    local title = "House overview, " .. Plural(overview.scanDays, "day") .. " of scans"
    local listed = PriceLedger.Thousands(lastItems or 0) .. " at the last scan"
    if overview.scanDays >= 2 then
        listed = listed .. " (avg " .. PriceLedger.Thousands(overview.mean) .. ")"
    end
    local lines = { { left = "Items listed", right = listed } }
    if overview.trendPct == nil then
        lines[2] = { left = "Trend", right = "after 2 days of scans" }
    elseif math.abs(overview.trendPct) < 0.005 then
        lines[2] = { left = "Trend", right = "steady" }
    else
        lines[2] = { left = "Trend", right = string.format("%+.1f%% a day", overview.trendPct * 100) }
    end
    if overview.projection then
        lines[3] = { left = "Next day, about",
            right = PriceLedger.Thousands(overview.projection) .. (overview.projection == 1 and " item" or " items") }
    else
        lines[3] = { left = "Next day, about", right = "after " .. PriceLedger.OVERVIEW_MIN_DAYS .. " days of scans" }
    end
    if latest.listings then
        lines[4] = { left = "Listings / units",
            right = PriceLedger.Thousands(latest.listings) .. " / " .. PriceLedger.Thousands(latest.units) }
        lines[5] = { left = "Value at lowest prices", right = coinText(latest.value) }
    else
        lines[4] = { left = "Listings / units", right = "from your next scan" }
        lines[5] = { left = "Value at lowest prices", right = "from your next scan" }
    end
    return title, lines
end

return PriceLedger
