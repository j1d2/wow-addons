--[[
Offline checks for PriceLedger. The game does not load this file.
Run: lua price_test.lua
]]

local folder = arg[0]:match("^(.*)/") or "."
dofile(folder .. "/PriceLedger.lua")

local P = HouseLedgerPrice
local failed = 0

--- Records one check: prints "ok  <name>", or "FAIL  <name>" and counts the failure.
-- @param name what the check proves
-- @param ok true when it passed
local function Check(name, ok)
    if ok then
        io.write("ok  " .. name .. "\n")
        return
    end
    failed = failed + 1
    io.write("FAIL  " .. name .. "\n")
end

--- A plain stand-in for the money formatter, so expected text stays short.
-- @param copper whole copper
-- @return text like "105c"
local function Coins(copper)
    return tostring(copper) .. "c"
end

do
    local best = {}
    P.Consider(best, 4306, 1, 10)
    P.Consider(best, 4306, 5, 40)
    Check("cheaper stack wins", best[4306].buyout == 40 and best[4306].count == 5)
    Check("unit rounds to nearest copper", P.UnitCopper(40, 5) == 8)
    Check("unit rounds 10/3 to 3", P.UnitCopper(10, 3) == 3)
end

do
    local best = {}
    P.Consider(best, 2589, 1, 10)
    P.Consider(best, 2589, 20, 200)
    Check("same unit price adds quantity", best[2589].qty == 21)
end

do
    local best = {}
    P.Consider(best, 1234, 1, 0)
    P.Consider(best, 0, 1, 50)
    P.Consider(best, 1234, 0, 50)
    P.Consider(best, nil, 1, 50)
    Check("bid-only and bad rows are ignored", next(best) == nil)
end

-- Scans at local noon, so a few seconds either way and a daylight saving
-- shift stay on the same calendar day in any time zone.
local NOON = os.time({ year = 2026, month = 11, day = 1, hour = 12 })
local DAY = 24 * 60 * 60

--- A time on a day counted from day 0, at noon.
-- @param dayOffset days from day 0; negative is earlier
-- @param seconds optional seconds after noon
-- @return a time() value
local function At(dayOffset, seconds)
    return NOON + dayOffset * DAY + (seconds or 0)
end

--- Commits one scan of item 4306 at house "Alliance|Test".
-- @param db the saved table to commit to
-- @param dayOffset day of the scan, from day 0
-- @param unit the unit price in copper
-- @param seconds optional seconds after noon
-- @return the item's row
local function ScanOn(db, dayOffset, unit, seconds)
    local best = {}
    P.Consider(best, 4306, 1, unit)
    P.Commit(db, "Alliance|Test", best, At(dayOffset, seconds))
    return db.houses["Alliance|Test"].items[4306]
end

--- Saves one scan per day at the given unit prices, then one on day 0.
-- The scans start `#lows` days before day 0, into a fresh db.
-- @param lows unit prices for the days before day 0, oldest first
-- @param today the unit price on day 0
-- @return the item's row
local function History(lows, today)
    local db = P.EmptyDB()
    for index, unit in ipairs(lows) do
        ScanOn(db, index - #lows - 1, unit)
    end
    return ScanOn(db, 0, today)
end

do
    local db = P.EmptyDB()
    ScanOn(db, 0, 10)
    local row = ScanOn(db, 0, 12, 60)
    Check("same-day scans share one day", #row.days == 1)
    local today = row.days[1]
    Check("day keeps its low, high and scan count",
        today[1] == P.DayKey(At(0)) and today[2] == 10 and today[3] == 12 and today[4] == 2)
    Check("day keeps the sum and sum of squares", today[5] == 22 and today[6] == 244)
    Check("latest price is kept", row.unit == 12 and row.seen == At(0, 60))
    row = ScanOn(db, 1, 9)
    Check("a new day adds a day", #row.days == 2 and row.days[2][2] == 9)
    Check("day keys sort by date", row.days[1][1] < row.days[2][1])
end

do
    local db = P.EmptyDB()
    local row
    for dayOffset = 0, 19 do
        row = ScanOn(db, dayOffset, 100 + dayOffset)
    end
    Check("days older than the window drop", #row.days == P.DAYS_KEPT)
    Check("oldest kept day is 13 days back", row.days[1][1] == P.DayKey(At(19 - 13)))
end

do
    -- Version 1 saved a list of price changes. Every saved item has to
    -- carry over: there are thousands of them in real saved data.
    local old = {
        version = 1,
        lastHouseKey = "Horde|Test",
        houses = {
            ["Horde|Test"] = {
                scannedAt = At(2),
                items = {
                    [4306] = { unit = 60, qty = 3, seen = At(2),
                        history = { { 50, At(0) }, { 70, At(0, 30) }, { 60, At(2) } } },
                    [2589] = { unit = 9, qty = 1, seen = At(1), history = {} },
                    [118] = { unit = 5, qty = 1, seen = At(1) },
                },
            },
        },
    }
    local db = P.EnsureDB(old)
    local items = db.houses["Horde|Test"].items
    local row = items[4306]
    Check("migration moves saved data to version 3", db.version == 3)
    Check("migration drops the old change list", row.history == nil)
    Check("migration keeps the price, stack and seen time",
        row.unit == 60 and row.qty == 3 and row.seen == At(2))
    Check("migration folds changes into days",
        #row.days == 2 and row.days[1][2] == 50 and row.days[1][3] == 70 and row.days[1][4] == 2)
    Check("migration sums the changes", row.days[1][5] == 120 and row.days[1][6] == 7400)
    Check("migration keeps an item with an empty change list",
        #items[2589].days == 1 and items[2589].days[1][2] == 9)
    Check("migration keeps an item with no change list",
        #items[118].days == 1 and items[118].days[1][1] == P.DayKey(At(1)))
    Check("migration keeps the house fields", db.lastHouseKey == "Horde|Test"
        and db.houses["Horde|Test"].scannedAt == At(2))
    local again = P.EnsureDB(db)
    Check("version 3 data is left alone", #again.houses["Horde|Test"].items[4306].days == 2
        and again.houses["Horde|Test"].items[4306].days[1][5] == 120)
end

do
    -- Version 2 days had low, high and count only. The sums are filled in
    -- from the low and high: exact for one scan, close for more.
    local old = {
        version = 2,
        houses = { ["Horde|Test"] = { items = {
            [4306] = { unit = 12, qty = 1, seen = At(0), days = { { P.DayKey(At(0)), 10, 12, 2 } } },
            [2589] = { unit = 9, qty = 1, seen = At(0), days = { { P.DayKey(At(0)), 9, 9, 1 } } },
        } } },
    }
    local items = P.EnsureDB(old).houses["Horde|Test"].items
    Check("version 2 days get sums from low and high", items[4306].days[1][5] == 22 and items[4306].days[1][6] == 244)
    Check("version 2 single scans convert exactly", items[2589].days[1][5] == 9 and items[2589].days[1][6] == 81)
end

do
    -- Version 1 moved `seen` on every scan but only listed price changes.
    -- A price that held still has one change on day 0 and seen on day 10.
    local old = {
        version = 1,
        houses = {
            ["Horde|Test"] = {
                items = {
                    [4306] = { unit = 100, qty = 1, seen = At(10), history = { { 100, At(0) } } },
                    [2589] = { unit = 9, qty = 1, seen = At(0, 60), history = { { 8, At(0) }, { 9, At(0, 30) } } },
                },
            },
        },
    }
    local items = P.EnsureDB(old).houses["Horde|Test"].items
    local days = items[4306].days
    Check("migration keeps the latest scan's day",
        #days == 2 and days[2][1] == P.DayKey(At(10)) and days[2][2] == 100 and days[2][4] == 1)
    Check("migration does not invent the days between", days[1][1] == P.DayKey(At(0)))
    days = items[2589].days
    Check("migration does not count the latest day twice", #days == 1 and days[1][4] == 2)
end

--- Saves scans of item 4306 on day 0, 15 minutes apart, at these prices.
-- @param prices unit prices in scan order
-- @return the item's row
local function SameDay(prices)
    local db = P.EmptyDB()
    local row
    for index, unit in ipairs(prices) do
        row = ScanOn(db, 0, unit, (index - 1) * 900)
    end
    return row
end

do
    local stats = P.Stats(History({}, 100))
    Check("one scan: counts but no trend yet",
        stats.scans == 1 and stats.days == 1 and stats.trend == nil and stats.typical == nil)
    Check("one scan: no deal", stats.deal == false)
    Check("one earlier scan is not enough for a trend", P.Stats(SameDay({ 100, 150 })).trend == nil)
end

do
    -- Three scans on the same day are enough for a trend.
    local stats = P.Stats(SameDay({ 100, 100, 115 }))
    Check("same-day scans give a trend from the 3rd scan",
        stats.typical == 100 and stats.trend == "up" and math.abs(stats.trendPct - 0.15) < 1e-9)
    Check("1-day window counts today's scans",
        stats.windows[1].days == 1 and stats.windows[1].scans == 3 and stats.windows[1].avg == 105
            and stats.windows[1].low == 100 and stats.windows[1].high == 115)
    Check("trend flat inside 10%", P.Stats(History({ 100, 100, 100 }, 105)).trend == "flat")
    Check("trend down at 10% or more under", P.Stats(History({ 100, 100, 100 }, 85)).trend == "down")
    Check("the average is of earlier scans, rounded", P.Stats(History({ 100, 101 }, 100)).typical == 101)
end

do
    -- One scan a day: days -10 to -8 at 500, days -7 to 0 at 100.
    local stats = P.Stats(History({ 500, 500, 500, 100, 100, 100, 100, 100, 100, 100 }, 100))
    Check("7-day average covers today and the 6 days before", stats.typical == 100)
    Check("windows are 1, 3, 7 and 14 days",
        #stats.windows == 4 and stats.windows[2].days == 3 and stats.windows[4].days == 14)
    Check("3-day window counts 3 scans", stats.windows[2].scans == 3)
    Check("7-day window counts 7 scans", stats.windows[3].scans == 7)
    Check("14-day window covers everything kept",
        stats.windows[4].scans == 11 and stats.windows[4].low == 100 and stats.windows[4].high == 500)
    Check("range and counts are the 14-day window", stats.low == 100 and stats.high == 500
        and stats.scans == 11 and stats.days == 11)
end

do
    -- Earlier scans 100, 104, 96, 100: average 100, std dev 3.27.
    local stats = P.Stats(History({ 100, 104, 96, 100 }, 70))
    Check("deal: 25% under the average and 2 std devs under it",
        stats.deal == true and math.abs(stats.dealPct - 0.30) < 1e-9)
    Check("std dev of the earlier scans", math.abs(stats.spread - math.sqrt(32 / 3)) < 1e-9)
    Check("not a deal at 20% under", P.Stats(History({ 100, 104, 96, 100 }, 80)).deal == false)
    Check("deal needs 4 earlier scans", P.Stats(History({ 100, 100, 100 }, 10)).deal == false)
    -- Earlier 50, 150, 100, 60, 140: average 100, std dev 45.3.
    Check("a noisy item needs a bigger drop to be a deal",
        P.Stats(History({ 50, 150, 100, 60, 140 }, 70)).deal == false)
    stats = P.Stats(SameDay({ 100, 100, 100, 100, 60 }))
    Check("the latest scan is not part of its own average", stats.typical == 100 and stats.deal == true)
    Check("stats read the latest price", stats.unit == 60)
end

do
    -- The Buy and Sell tabs judge a live price against the saved scans.
    local stats = P.Stats(History({ 100, 104, 96, 100 }, 100))
    local live = P.Judge(stats, 70)
    Check("live price: deal against the earlier scans", live.deal == true and math.abs(live.dealPct - 0.30) < 1e-9)
    Check("live price: trend against the 7-day average", live.trend == "down" and math.abs(live.trendPct + 0.30) < 1e-9)
    live = P.Judge(stats, 125)
    Check("live price: dearer is up, not a deal", live.trend == "up" and live.deal == false)
    local young = P.Judge(P.Stats(History({}, 100)), 10)
    Check("live price: no judgment without earlier scans", young.trend == nil and young.deal == false)
    Check("live price: no stats, no judgment", P.Judge(nil, 50).trend == nil and P.Judge(nil, 50).deal == false)
end

do
    -- The Buy details block and the Sell tab: all four windows, always,
    -- so the rows keep their places, then the spread.
    local lines = P.WindowLines(P.Stats(History({ 100, 100, 100 }, 115)), Coins)
    local function Line(index, left, right)
        return lines[index] ~= nil and lines[index].left == left and lines[index].right == right
    end
    Check("window lines: 1 day with one scan is just its price", Line(1, "1 day, 1 scan", "115c"))
    Check("window lines: 3 days, average and range", Line(2, "3 days, 3 scans", "avg 105c (100c - 115c)"))
    Check("window lines: 7 days", Line(3, "7 days, 4 scans", "avg 104c (100c - 115c)"))
    Check("window lines: 14 days keeps its place but doesn't repeat 7 days' numbers",
        Line(4, "14 days, 4 scans", "|cff9d9d9dsame as 7 days|r"))
    Check("window lines: no spread when the earlier scans match", Line(5, "Std dev, earlier scans", "none"))
    local spread = P.WindowLines(P.Stats(History({ 100, 110, 90 }, 100)), Coins)
    Check("window lines: the spread of the earlier scans", spread[5].right == "10c")
    Check("window lines: nothing else", #lines == 5)

    local young = P.WindowLines(P.Stats(History({}, 100)), Coins)
    Check("window lines: no spread before 2 earlier scans",
        young[5].left == "Std dev, earlier scans" and young[5].right == "after 2 more scans")
    Check("window lines: no stats, no lines", P.WindowLines(nil, Coins) == nil)
    local longer = P.WindowLines(P.Stats(History({ 100, 100, 100, 100, 100, 100, 100, 100, 100 }, 100)), Coins)
    Check("window lines: a window with more scans than the last shows its numbers",
        longer[4].left == "14 days, 10 scans" and not longer[4].right:find("same as", 1, true))
end

do
    Check("scan button: ready", P.ScanButtonText(0) == "Scan")
    Check("scan button: seconds under a minute", P.ScanButtonText(45) == "Scan (45s)")
    Check("scan button: whole minutes, rounded up", P.ScanButtonText(61) == "Scan (2m)"
        and P.ScanButtonText(900) == "Scan (15m)")
end

do
    -- The Sell tab sums up one item's live listings: { unit, quantity }.
    local live = P.LowestListing({ { 120, 5 }, { 100, 2 }, { 100, 3 }, { 150, 1 } })
    Check("live listings: lowest unit price", live.low == 100)
    Check("live listings: how many at the lowest", live.atLow == 5)
    Check("live listings: total up for sale", live.total == 11 and live.listings == 4)
    Check("live listings: none is nil", P.LowestListing({}) == nil)
    live = P.LowestListing({ { 0, 4 }, { 90, 1 } })
    Check("live listings: no-price rows are skipped", live.low == 90 and live.total == 1 and live.listings == 1)
end

do
    Check("house label is the side only, so the realm stays off screen", P.HouseLabel("Horde|Some Realm") == "Horde")
    Check("house label keeps a key with no realm", P.HouseLabel("Neutral") == "Neutral")
    Check("house label handles nil", P.HouseLabel(nil) == "")
end

do
    Check("stats reject a missing row", P.Stats(nil) == nil)
    Check("stats reject a row with no days", P.Stats({ unit = 5, seen = At(0) }) == nil)
end

do
    local db = P.EmptyDB()
    local first = {}
    P.Consider(first, 4306, 1, 25)
    P.Consider(first, 2589, 1, 9)
    P.Commit(db, "Alliance|Test", first, 1000)
    local second = {}
    P.Consider(second, 2589, 1, 8)
    P.Commit(db, "Alliance|Test", second, 5000)
    local info = P.Lookup(db, 4306, "Alliance|Test")
    Check("missing item keeps its last price", info ~= nil and info.unit == 25 and info.seen == 1000)
    local lines = P.TooltipLines(info, Coins, false)
    local stamp = os.date("%m/%d %H:%M", 1000)
    Check("stale tooltip says when it was seen", lines[1].left == "HouseLedger  25c  last seen " .. stamp)
    local fresh = P.Lookup(db, 2589, "Alliance|Test")
    lines = P.TooltipLines(fresh, Coins, false)
    Check("fresh tooltip is the price alone", #lines == 1 and lines[1].left == "HouseLedger  8c")
end

do
    local db = P.EmptyDB()
    local neutral = {}
    P.Consider(neutral, 4306, 1, 50)
    P.Commit(db, "Neutral|Test", neutral, 1000)
    local info = P.Lookup(db, 4306, "Alliance|Test")
    Check("other house is labeled", info ~= nil and info.side == "Neutral" and info.unit == 50)
    local home = {}
    P.Consider(home, 4306, 1, 20)
    P.Commit(db, "Alliance|Test", home, 2000)
    local preferred = P.Lookup(db, 4306, "Alliance|Test")
    Check("own house wins over the last scan", preferred.unit == 20 and preferred.side == nil)
    Check("unknown item has no tooltip", P.Lookup(db, 999999, "Alliance|Test") == nil)
    Check("tooltip helper rejects a missing price", P.TooltipLines(nil, Coins, false) == nil)
end

do
    local up = P.TrendText({ trend = "up", trendPct = 0.15 }, "buyer")
    Check("buyer view: up is a red up arrow",
        up == "|A:NPE_ArrowUp:14:14:0:0:255:32:32|a|cffff2020+15%|r")
    Check("buyer view: down is a green down arrow",
        P.TrendText({ trend = "down", trendPct = -0.204 }, "buyer")
            == "|A:NPE_ArrowDown:14:14:0:0:32:255:32|a|cff20ff20-20%|r")
    Check("seller view: up is green",
        P.TrendText({ trend = "up", trendPct = 0.15 }, "seller")
            == "|A:NPE_ArrowUp:14:14:0:0:32:255:32|a|cff20ff20+15%|r")
    Check("seller view: down is red",
        P.TrendText({ trend = "down", trendPct = -0.2 }, "seller")
            == "|A:NPE_ArrowDown:14:14:0:0:255:32:32|a|cffff2020-20%|r")
    Check("flat trend shows nothing", P.TrendText({ trend = "flat", trendPct = 0.02 }, "buyer") == "")
    Check("no trend yet shows nothing", P.TrendText({}, "buyer") == "")
    Check("deal icon is the yellow burst", P.DEAL_ICON == "|A:Bonus-Objective-Star:16:16:0:0|a")
end

do
    -- Within 10% of the 7-day average: a grey "steady", so a quiet price
    -- does not look like missing data.
    Check("a flat trend reads steady, with its percent",
        P.SteadyText({ trend = "flat", trendPct = 0.025 }) == "|cff9d9d9dsteady +3%|r")
    Check("a flat trend below the average keeps its minus",
        P.SteadyText({ trend = "flat", trendPct = -0.04 }) == "|cff9d9d9dsteady -4%|r")
    Check("a flat trend that rounds to 0% is just steady",
        P.SteadyText({ trend = "flat", trendPct = 0.002 }) == "|cff9d9d9dsteady|r")
    Check("an up or down trend is not steady", P.SteadyText({ trend = "up", trendPct = 0.2 }) == "")
    Check("no trend yet is not steady", P.SteadyText({}) == "" and P.SteadyText(nil) == "")
end

--- Saves daily scans of item 4306 into a fresh db and looks it up.
-- @param lows unit prices for the days before day 0, oldest first
-- @param today the unit price on day 0
-- @return the PriceLedger.Lookup result for "Alliance|Test"
local function InfoFor(lows, today)
    local db = P.EmptyDB()
    for index, unit in ipairs(lows) do
        ScanOn(db, index - #lows - 1, unit)
    end
    ScanOn(db, 0, today)
    return P.Lookup(db, 4306, "Alliance|Test")
end

do
    local info = InfoFor({ 100, 100, 100 }, 115)
    Check("lookup carries the stats", info.stats ~= nil and info.stats.trend == "up")
    local lines = P.TooltipLines(info, Coins, false)
    Check("short tooltip: price and trend on one line",
        #lines == 1 and lines[1].left == "HouseLedger  115c  " .. P.TrendText(info.stats, "buyer"))

    lines = P.TooltipLines(InfoFor({ 100, 104, 96, 100 }, 70), Coins, false)
    Check("short tooltip: a deal adds the icon",
        lines[1].left:find(P.DEAL_ICON, 1, true) ~= nil)

    lines = P.TooltipLines(info, Coins, true)
    Check("details: 1-day row", lines[2].left == "1 day, 1 scan" and lines[2].right == "115c")
    Check("details: 3-day row", lines[3].left == "3 days, 3 scans" and lines[3].right == "avg 105c (100c - 115c)")
    Check("details: 7-day row", lines[4].left == "7 days, 4 scans" and lines[4].right == "avg 104c (100c - 115c)")
    Check("details: a window with no new scans is left out", #lines == 4)

    lines = P.TooltipLines(InfoFor({ 100, 104, 96, 100 }, 70), Coins, true)
    Check("details: std dev line", lines[#lines - 1].left == "Std dev, earlier scans" and lines[#lines - 1].right == "3c")
    Check("details: deal line says how far under",
        lines[#lines].left == P.DEAL_ICON .. " Good deal" and lines[#lines].right == "30% under the 7-day average")
end

do
    local lines = P.TooltipLines(InfoFor({}, 100), Coins, true)
    Check("details: one scan shows one row", lines[2].left == "1 day, 1 scan" and lines[2].right == "100c")
    Check("details: a new item says what it still needs",
        lines[3].left == "Trend after 2 more scans" and lines[3].right == nil and #lines == 3)
    lines = P.TooltipLines(P.Lookup((function()
        local db = P.EmptyDB()
        ScanOn(db, 0, 100)
        ScanOn(db, 0, 100, 900)
        return db
    end)(), 4306, "Alliance|Test"), Coins, true)
    Check("details: singular count of scans still needed", lines[#lines].left == "Trend after 1 more scan")
end

do
    Check("coins roll up to gold, silver and copper", P.CoinText(10203) == "1g 2s 3c")
    Check("copper alone stays copper", P.CoinText(50) == "50c")
    Check("empty silver and copper are left out", P.CoinText(10000) == "1g")
    Check("empty silver between gold and copper is left out", P.CoinText(10005) == "1g 5c")
    Check("silver alone", P.CoinText(500) == "5s")
    Check("large gold is not split", P.CoinText(12345678) == "1234g 56s 78c")
    Check("zero shows as copper", P.CoinText(0) == "0c")
end

do
    Check("scan is ready with no previous time", P.SecondsUntil(nil, 1000) == 0)
    Check("scan waits the rest of 15 minutes", P.SecondsUntil(1000, 1000 + 899) == 1)
    Check("scan is ready at 15 minutes", P.SecondsUntil(1000, 1000 + 900) == 0)
end

do
    local db = P.EnsureDB({})
    Check("empty saved data grows a house table", type(db.houses) == "table" and db.version == 3)
    local key = P.HouseKey("", "")
    Check("blank side and realm get a stable key", key == "Unknown|Forever")
end

-- Item names from the scan
do
    local best = {}
    P.Consider(best, 2589, 1, 10)
    P.Consider(best, 2589, 1, 12, "Linen Cloth", 1)
    Check("a name comes from any listing of the item, not only the cheapest",
        best[2589].name == "Linen Cloth" and best[2589].quality == 1 and best[2589].buyout == 10)
    P.Consider(best, 2589, 1, 8)
    Check("a cheaper listing without a name keeps the name", best[2589].name == "Linen Cloth"
        and best[2589].buyout == 8)
    P.Consider(best, 2590, 1, 5, "Odd Item", -1)
    Check("a quality the scan didn't know (-1) isn't kept", best[2590].quality == nil)

    local db = P.EmptyDB()
    P.Commit(db, "Alliance|Test", best, At(0))
    local row = db.houses["Alliance|Test"].items[2589]
    Check("the scan saves the item's name and quality", row.name == "Linen Cloth" and row.quality == 1)
    local later = {}
    P.Consider(later, 2589, 1, 9)
    P.Commit(db, "Alliance|Test", later, At(1))
    Check("a later scan without the name keeps the saved one", row.name == "Linen Cloth" and row.unit == 9)

    local items = P.EnsureDB({ version = 3, houses = { ["Alliance|Test"] = { items = {
        [1] = { unit = 5, seen = 1, days = {}, name = 7, quality = "rare" },
        [2] = { unit = 5, seen = 1, days = {}, name = "Odd", quality = -1 },
        [3] = { unit = 5, seen = 1, days = {}, name = "Epic", quality = 4 } } } } }).houses["Alliance|Test"].items
    Check("a damaged saved name or quality is dropped", items[1].name == nil and items[1].quality == nil)
    Check("a saved -1 quality (not known) is dropped; a real one stays", items[2].quality == nil
        and items[3].quality == 4)
end

-- Market: deals, drops and rises at the last scan
do
    local db = P.EmptyDB()
    local plan = {
        [1] = { name = "Cheap Today", prices = { 100, 100, 100, 100, 50 } },  -- deal, -50%
        [2] = { name = "Bit Lower", prices = { 100, 110, 90, 100, 80 } },     -- down, no deal
        [3] = { name = "Pricier", prices = { 100, 100, 100, 100, 150 } },     -- up +50%
        [4] = { name = "Same", prices = { 100, 100, 100, 100, 100 } },        -- flat
        [5] = { name = "Gone Now", prices = { 100, 100, 100, 100 } },         -- not in the last scan
        [6] = { name = "Also Cheap", prices = { 200, 200, 200, 200, 120 } },  -- deal, -40%
    }
    for day = 1, 5 do
        local best = {}
        for itemID, item in pairs(plan) do
            if item.prices[day] then
                P.Consider(best, itemID, 1, item.prices[day], item.name, 2)
            end
        end
        P.Commit(db, "Alliance|Test", best, At(day - 5))
    end
    local house = db.houses["Alliance|Test"]
    local function IDs(list)
        local ids = {}
        for index, entry in ipairs(list) do
            ids[index] = entry.itemID
        end
        return table.concat(ids, ",")
    end
    local market = P.Market(house)
    Check("deals: only deals at the last scan, most under typical first", IDs(market.deals) == "1,6")
    Check("drops: every item down at the last scan, deals included, biggest drop first",
        IDs(market.drops) == "1,6,2")
    Check("rises: items up at the last scan, biggest rise first", IDs(market.rises) == "3")
    local first = market.deals[1]
    Check("an entry carries what the row shows", first.name == "Cheap Today" and first.quality == 2
        and first.unit == 50 and first.qty == 1 and first.typical == 100 and first.deal == true
        and math.abs(first.trendPct + 0.5) < 1e-9)
    Check("the market remembers which scan it is from", market.scannedAt == house.scannedAt)
    Check("an empty house has empty views", #P.Market({ items = {} }).deals == 0
        and #P.Market(nil).rises == 0)
end

if failed > 0 then
    io.write(string.format("%d failed\n", failed))
    os.exit(1)
end
io.write("all passed\n")
