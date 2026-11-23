--- Synthetic saved data for the benchmarks: made-up items and disenchants shaped like the real
-- saved variables, never copied from a real game install. The same arguments always give the
-- same data (a fixed-seed generator, no math.random), so memory numbers repeat exactly.
--
-- Load with dofile after PriceLedger.lua, which supplies DayKey and DaySummary:
--   local Synth = dofile("bench/synth.lua")

local Synth = {}

local SECONDS_PER_DAY = 24 * 60 * 60
--- The newest synthetic scan: 2026-11-15 12:00 UTC. Fixed so every run builds the same days.
Synth.NOW = 1794744000
--- Share of items listed on any one day. A real 7-day file had 84% of item-days filled.
Synth.LISTED_SHARE = 0.84
--- Chance that a scan finds the same cheapest price as the scan before: the cheapest listing
-- often stays up. Tuned so 6,661 items x 7 days gives about as many different values as a real
-- 7-day file (41,351); without it every price is new and the constant count is far too high.
Synth.PRICE_KEPT = 0.85

--- A tiny deterministic generator (Park-Miller), so the data is the same on every run.
-- @param seed a whole number above 0
-- @return a function that returns the next number in [0, 1)
local function Generator(seed)
    local state = seed % 2147483647
    if state <= 0 then
        state = state + 2147483646
    end
    return function()
        state = (state * 16807) % 2147483647
        return (state - 1) / 2147483646
    end
end

--- Rounds a price to four significant digits, as sellers often do (1,250 copper, 47,500), so
-- prices repeat across items the way real ones do.
-- @param copper a price above 0
-- @return the rounded price, at least 1
local function SellerPrice(copper)
    local step = 1
    while copper >= 10000 * step do
        step = step * 10
    end
    return math.max(1, math.floor(copper / step + 0.5) * step)
end

--- A HouseLedgerDB (version 4) with one house of synthetic items. Each item also keeps its
-- last `scansKept` scans as one flat list (time, price, time, price, ...), oldest first. A day's
-- scans happen at fixed times, the last at 12:00 and the others evenly spaced before it, so every
-- item listed in one scan shares its time, as in a real scan.
-- @param items how many items
-- @param days how many calendar days of history, ending on the day of Synth.NOW
-- @param ledger PriceLedger, to key and summarize the days the way the addon does
-- @param maxScans optional; most scans a day (each day has 1 to this many), 3 by default
-- @param scansKept optional; how many scans each item keeps, 30 by default
-- @return the saved table and the house key
function Synth.HouseLedgerDB(items, days, ledger, maxScans, scansKept)
    maxScans = maxScans or 3
    scansKept = scansKept or 30
    local scanGap = math.floor(12 * 60 * 60 / maxScans)
    local next = Generator(items * 1000 + days)
    local houseKey = "Alliance|Bench Realm"
    local house = { items = {}, scannedAt = Synth.NOW, replicateAt = Synth.NOW }
    for itemID = 1, items do
        local base = SellerPrice(100 + next() * 200000)
        local price = base
        local row = { days = {}, scans = {}, name = "Bench Item " .. itemID, quality = 1 + itemID % 4 }
        for back = days - 1, 0, -1 do
            -- The newest day is always listed, so every item is in the last scan.
            if back == 0 or next() < Synth.LISTED_SHARE then
                local scans = 1 + math.floor(next() * maxScans)
                local low, high, sum, squares = nil, nil, 0, 0
                local seen = Synth.NOW - back * SECONDS_PER_DAY
                for scan = 1, scans do
                    if next() >= Synth.PRICE_KEPT then
                        price = SellerPrice(base * (0.7 + next() * 0.6))
                    end
                    low = math.min(low or price, price)
                    high = math.max(high or price, price)
                    sum = sum + price
                    squares = squares + price * price
                    row.scans[#row.scans + 1] = seen - (scans - scan) * scanGap
                    row.scans[#row.scans + 1] = price
                end
                local average, spread = ledger.DaySummary(low, high, scans, sum, squares)
                row.days[#row.days + 1] = { ledger.DayKey(seen), low, high, scans, average, spread }
                row.unit, row.qty, row.seen = price, 1 + math.floor(next() * 40), seen
            end
        end
        -- Keep the last scansKept scans.
        local extra = #row.scans - 2 * scansKept
        if extra > 0 then
            local kept = {}
            for index = extra + 1, #row.scans do
                kept[#kept + 1] = row.scans[index]
            end
            row.scans = kept
        end
        house.items[itemID] = row
    end
    local db = { version = 4, houses = { [houseKey] = house }, lastHouseKey = houseKey, settings = {} }
    return db, houseKey
end

--- The best-listing table a full scan would hand to PriceLedger.Commit, one day after the data.
-- @param house a house from Synth.HouseLedgerDB
-- @return itemID -> { buyout, count, qty, name, quality }
function Synth.FullScan(house)
    local best = {}
    for itemID, row in pairs(house.items) do
        best[itemID] = { buyout = row.unit * 2, count = 2, qty = row.qty, name = row.name, quality = row.quality }
    end
    return best
end

--- An Unmaker history list of synthetic disenchants, oldest first.
-- @param entries how many entries
-- @return the list, shaped like UnmakerDB.history
function Synth.UnmakerHistory(entries)
    local next = Generator(entries + 7)
    local history = {}
    for index = 1, entries do
        local itemID = 1000 + math.floor(next() * 400)
        history[index] = {
            itemID = itemID, name = "Bench Gear " .. itemID,
            link = "|cff1eff00|Hitem:" .. itemID .. "::::::::20:::::|h[Bench Gear " .. itemID .. "]|h|r",
            quality = 2 + math.floor(next() * 3), level = 5 + math.floor(next() * 55),
            character = (index % 3 == 0) and "Benchalt" or "Benchmain", realm = "Bench Realm",
            time = Synth.NOW - (entries - index) * 600,
            looted = true, mats = { { name = "Strange Dust", quantity = 1 + math.floor(next() * 3) } },
        }
    end
    return history
end

--- Writes a value the way the game writes SavedVariables (checked against a real file): no
-- indentation, array values one per line, other keys as ["key"] = value, Windows line endings.
-- @param name the global's name
-- @param value the table to write
-- @return the file's text
function Synth.Serialize(name, value)
    local parts = { name, " = " }
    local function Write(item)
        if type(item) == "table" then
            parts[#parts + 1] = "{\r\n"
            local count = #item
            for key, inner in pairs(item) do
                local isIndex = type(key) == "number" and key >= 1 and key <= count and key % 1 == 0
                if not isIndex then
                    local keyText = type(key) == "string" and string.format("%q", key) or tostring(key)
                    parts[#parts + 1] = "[" .. keyText .. "] = "
                    Write(inner)
                    parts[#parts + 1] = ",\r\n"
                end
            end
            for index = 1, count do
                Write(item[index])
                parts[#parts + 1] = ",\r\n"
            end
            parts[#parts + 1] = "}"
        elseif type(item) == "string" then
            parts[#parts + 1] = string.format("%q", item)
        else
            parts[#parts + 1] = tostring(item)
        end
    end
    Write(value)
    parts[#parts + 1] = "\r\n"
    return table.concat(parts)
end

return Synth
