--[[
Offline checks for PriceLedger. The game does not load this file.
Run: lua price_test.lua
]]

local folder = arg[0]:match("^(.*)/") or "."
local P = dofile(folder .. "/PriceLedger.lua")
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
    Check("day keeps its average and spread", today[5] == 11 and today[6] == 1)
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
    -- Item 2589 sells out after day 2; item 4306 keeps being scanned. Each scan also drops
    -- 2589's old days, so a long-gone item doesn't keep its whole history in the saved file.
    local db = P.EmptyDB()
    local function ScanBoth(dayOffset)
        local best = {}
        P.Consider(best, 4306, 1, 100, "Copper Bar", 1)
        if dayOffset <= 2 then
            P.Consider(best, 2589, 1, 40, "Linen Cloth", 1)
        end
        P.Commit(db, "Alliance|Test", best, At(dayOffset))
    end
    for dayOffset = 0, 10 do
        ScanBoth(dayOffset)
    end
    local items = db.houses["Alliance|Test"].items
    local gone = items[2589]
    Check("an item missing from scans keeps its days while they're in the window", #gone.days == 3)
    ScanBoth(14)
    Check("a scan drops a missing item's days older than the window",
        #gone.days == 2 and gone.days[1][1] == P.DayKey(At(1)))
    for dayOffset = 15, 18 do
        ScanBoth(dayOffset)
    end
    Check("a missing item with every day out of the window keeps no days", #gone.days == 0)
    Check("it keeps its last price, time and name", gone.unit == 40 and gone.seen == At(2)
        and gone.name == "Linen Cloth" and gone.qty == 1)
    local info = P.Lookup(db, 2589, "Alliance|Test")
    local lines = P.TooltipLines(info, Coins, true)
    Check("its tooltip still shows the last price and when it was seen",
        info.stats == nil and lines[1].left == "HouseLedger  40c  last seen " .. os.date("%m/%d %H:%M", At(2)))
    -- Scanned on days 0-10 and 14-18: the window back from day 18 starts on day 5.
    Check("the scanned item keeps its days in the window",
        #items[4306].days == 11 and items[4306].days[1][1] == P.DayKey(At(5)))
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
    Check("migration moves saved data to the current version", db.version == P.DB_VERSION and P.DB_VERSION == 4)
    Check("migration drops the old change list", row.history == nil)
    Check("migration keeps the price, stack and seen time",
        row.unit == 60 and row.qty == 3 and row.seen == At(2))
    Check("migration folds changes into days",
        #row.days == 2 and row.days[1][2] == 50 and row.days[1][3] == 70 and row.days[1][4] == 2)
    Check("migration keeps the changes' average and spread", row.days[1][5] == 60 and row.days[1][6] == 10)
    Check("migration keeps an item with an empty change list",
        #items[2589].days == 1 and items[2589].days[1][2] == 9)
    Check("migration keeps an item with no change list",
        #items[118].days == 1 and items[118].days[1][1] == P.DayKey(At(1)))
    Check("migration keeps the house fields", db.lastHouseKey == "Horde|Test"
        and db.houses["Horde|Test"].scannedAt == At(2))
    local again = P.EnsureDB(db)
    Check("current data is left alone", #again.houses["Horde|Test"].items[4306].days == 2
        and again.houses["Horde|Test"].items[4306].days[1][5] == 60 and again.houses["Horde|Test"].items[4306].days[1][6] == 10)
end

do
    -- Version 2 days had low, high and count only. The average and spread are filled in
    -- as if half the scans were at the low and half at the high: exact for one scan, close for more.
    local old = {
        version = 2,
        houses = { ["Horde|Test"] = { items = {
            [4306] = { unit = 12, qty = 1, seen = At(0), days = { { P.DayKey(At(0)), 10, 12, 2 } } },
            [2589] = { unit = 9, qty = 1, seen = At(0), days = { { P.DayKey(At(0)), 9, 9, 1 } } },
        } } },
    }
    local items = P.EnsureDB(old).houses["Horde|Test"].items
    Check("version 2 days get an average and spread from low and high", items[4306].days[1][5] == 11
        and items[4306].days[1][6] == 1)
    Check("version 2 single scans convert exactly", items[2589].days[1][5] == 9 and items[2589].days[1][6] == 0)
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
    Check("house label keeps a key with no realm", P.HouseLabel("Odd key") == "Odd key")
    Check("a goblin house reads as Goblin", P.HouseLabel("Neutral|Some Realm") == "Goblin")
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
    Check("another house's price is never used, even the last one scanned",
        P.Lookup(db, 4306, "Alliance|Test") == nil and P.Lookup(db, 4306, "Neutral|Test").unit == 50)
    local home = {}
    P.Consider(home, 4306, 1, 20)
    P.Commit(db, "Alliance|Test", home, 2000)
    local preferred = P.Lookup(db, 4306, "Alliance|Test")
    Check("each house reads its own price", preferred.unit == 20 and P.Lookup(db, 4306, "Neutral|Test").unit == 50)
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
    Check("empty saved data grows a house table", type(db.houses) == "table" and db.version == P.DB_VERSION)
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

-- Filters: name, quality and item level
do
    local labels = {}
    for index, choice in ipairs(P.QUALITY_CHOICES) do
        labels[index] = choice.label .. "=" .. tostring(choice.min)
    end
    Check("quality choices: any, then each quality and up", table.concat(labels, ",")
        == "Any quality=nil,Common & up=1,Uncommon & up=2,Rare & up=3,Epic & up=4")

    Check("an item level box reads whole numbers only", P.ParseLevel(" 25 ") == 25 and P.ParseLevel("") == nil
        and P.ParseLevel("2x") == nil and P.ParseLevel(nil) == nil and P.ParseLevel("0") == nil)

    local boots = { name = "Linen Boots", quality = 1, level = 10 }
    Check("no filter passes everything", P.PassesFilter(boots, {}) and P.PassesFilter({}, {}))
    Check("name: a part of the name, any case", P.PassesFilter(boots, { text = "LINEN b" })
        and not P.PassesFilter(boots, { text = "wool" }))
    Check("name: special characters are plain text", P.PassesFilter({ name = "Potion (Minor)" }, { text = "(min" })
        and not P.PassesFilter({ name = "Potion" }, { text = "%a" }))
    Check("quality: that quality and up", P.PassesFilter(boots, { minQuality = 1 })
        and not P.PassesFilter(boots, { minQuality = 2 }))
    Check("quality: an unknown quality doesn't pass a quality filter",
        not P.PassesFilter({ name = "x" }, { minQuality = 1 }))
    Check("level: inside the range, ends included", P.PassesFilter(boots, { minLevel = 10, maxLevel = 10 })
        and not P.PassesFilter(boots, { minLevel = 11 }) and not P.PassesFilter(boots, { maxLevel = 9 }))
    Check("level: no item level (0 or unknown) doesn't pass a level filter",
        not P.PassesFilter({ level = 0 }, { minLevel = 1 }) and not P.PassesFilter({}, { maxLevel = 50 }))
    Check("a filter is active once a quality or level is set", not P.FilterActive({})
        and not P.FilterActive({ text = "x" }) and P.FilterActive({ minQuality = 2 }) and P.FilterActive({ maxLevel = 3 }))
end

-- Settings
do
    local keys = {}
    for index, setting in ipairs(P.SETTINGS) do
        keys[index] = setting.key .. "=" .. tostring(setting.default)
    end
    Check("settings: tooltip prices on, details without Shift off, the bag button on",
        table.concat(keys, ",") == "tooltipPrices=true,tooltipDetails=false,priceCheckButton=true")
    local db = P.EnsureDB(nil)
    Check("new saved data gets every default", db.settings.tooltipPrices == true and db.settings.tooltipDetails == false)
    db = P.EnsureDB({ version = 3, houses = {}, settings = { tooltipPrices = false, tooltipDetails = "yes" } })
    Check("a saved choice stays and a damaged one goes back to its default",
        db.settings.tooltipPrices == false and db.settings.tooltipDetails == false)
    Check("damaged settings are replaced", type(P.EnsureDB({ settings = 5 }).settings) == "table")
end

-- Chart: one slot per day from the oldest saved day (at least 7), up to the history length
do
    local db = P.EmptyDB()
    ScanOn(db, -10, 80)
    ScanOn(db, -3, 120)
    ScanOn(db, -3, 100, 60)
    local row = ScanOn(db, 0, 90)
    local chart = P.ChartDays(row.days, row.seen)
    Check("the chart starts at the oldest saved day, oldest first", chart and #chart.slots == 11
        and chart.days == 11 and chart.slots[11].dayKey == P.DayKey(At(0))
        and chart.slots[1].dayKey == P.DayKey(At(-10)))
    Check("a day with scans has its low and high", chart.slots[8].low == 100 and chart.slots[8].high == 120
        and chart.slots[1].low == 80 and chart.slots[11].low == 90)
    Check("a day without a scan is empty", chart.slots[9].low == nil and chart.slots[2].low == nil)
    Check("the chart's top is the highest price", chart.top == 120)
    Check("no days, no chart", P.ChartDays({}, At(0)) == nil and P.ChartDays(nil, nil) == nil)
    local young = P.ChartDays(ScanOn(P.EmptyDB(), 0, 50).days, At(0))
    Check("a new item's chart still has 7 slots", #young.slots == 7 and young.days == 7
        and young.slots[7].low == 50 and young.slots[1].dayKey == P.DayKey(At(-6)))
end

-- House overview: per-day totals from scans, items listed per day, trend and next-day estimate
do
    Check("thousands get commas", P.Thousands(0) == "0" and P.Thousands(999) == "999"
        and P.Thousands(1000) == "1,000" and P.Thousands(1234567) == "1,234,567" and P.Thousands(-4200) == "-4,200")
    local totals = {}
    P.AddToTotals(totals, 5, 250)
    P.AddToTotals(totals, 20, 1000)
    P.AddToTotals(totals, 1, 0)
    P.AddToTotals(totals, 0, 50)
    P.AddToTotals(totals, nil, 50)
    Check("totals count buyout listings, their units and value", totals.listings == 2 and totals.units == 25
        and totals.value == 1250)
    local best = {}
    P.Consider(best, 7, 1, 999999)
    P.Consider(best, 7, 4, 200)
    P.Consider(best, 7, 2, 100)
    P.Consider(best, 7, 1, 0)
    Check("an item counts all its units with a buyout, whatever their price", best[7].units == 7
        and best[7].qty == 6 and best[7].buyout == 200)
    local valueDB = P.EmptyDB()
    local valueTotals = { listings = 4, units = 8, value = 1000499 }
    P.Commit(valueDB, "Alliance|Test", best, At(0), valueTotals)
    Check("the day's value is each item's units at its cheapest price, not the joke listing",
        valueDB.houses["Alliance|Test"].daily[1][4] == 350)

    local db = P.EmptyDB()
    local function ScanDay(dayOffset, items, seconds)
        local best, sums = {}, {}
        for itemID = 1, items do
            P.Consider(best, itemID, 2, 300)
            P.AddToTotals(sums, 2, 300)
        end
        P.Commit(db, "Alliance|Test", best, At(dayOffset, seconds), sums)
    end
    ScanDay(-2, 10)
    ScanDay(-2, 12, 900)
    local house = db.houses["Alliance|Test"]
    Check("a day keeps its latest scan's totals", #house.daily == 1 and house.daily[1][1] == P.DayKey(At(-2))
        and house.daily[1][2] == 12 and house.daily[1][3] == 24 and house.daily[1][4] == 3600)
    P.Commit(db, "Alliance|Test", { [1] = { buyout = 5, count = 1, qty = 1 } }, At(-1))
    Check("a scan without totals saves none", #house.daily == 1)

    local overview = P.HouseOverview(house)
    Check("the overview counts items listed each day, from saved days", overview.slots[#overview.slots].items == 1
        and overview.slots[#overview.slots - 1].items == 12)
    Check("it has at least 7 slots, ending on the last scan's day", #overview.slots == 7
        and overview.slots[7].dayKey == P.DayKey(At(-1)) and overview.slots[1].items == nil)
    Check("a day's totals come with it", overview.slots[6].listings == 12 and overview.slots[6].units == 24
        and overview.slots[6].value == 3600 and overview.slots[7].listings == nil)
    Check("two days: no trend or estimate yet", overview.scanDays == 2 and overview.projection == nil
        and overview.slope ~= nil)
    Check("no house, no overview", P.HouseOverview(nil) == nil and P.HouseOverview({ items = {} }) == nil)

    -- 6 days rising 100 items a day from 1,000: the fit is exact.
    db = P.EmptyDB()
    for day = 0, 5 do
        ScanDay(day - 5, 1000 + day * 100)
    end
    overview = P.HouseOverview(db.houses["Alliance|Test"])
    Check("the trend line fits the days", math.abs(overview.slope - 100) < 1e-9
        and math.abs(overview.fit(7) - 1500) < 1e-9 and overview.scanDays == 6)
    Check("tomorrow's estimate continues the line", overview.projection == 1600)
    Check("a perfect line has no spread around it", overview.residual < 1e-6)
    Check("the mean and top cover the days", overview.mean == 1250 and overview.top == 1500 and overview.low == 1000)
    Check("trend per day as a share of the mean", math.abs(overview.trendPct - 100 / 1250) < 1e-9)

    -- Up and down around 2,000: spread around the line, and a gap day left out.
    db = P.EmptyDB()
    for index, items in ipairs({ 2000, 2100, 1900, 2050, 1950 }) do
        ScanDay(index * 2 - 10, items)
    end
    overview = P.HouseOverview(db.houses["Alliance|Test"])
    Check("days without a scan stay empty and out of the fit", overview.scanDays == 5 and #overview.slots == 9
        and overview.slots[2].items == nil and overview.residual > 0)
    Check("5 days of scans give an estimate", type(overview.projection) == "number")

    P.SetHistoryDays(db, 30)
    for day = -29, 0 do
        ScanDay(day + 30, 500)
    end
    Check("30 days kept, 30 days of totals", #db.houses["Alliance|Test"].daily == 30)
    P.SetHistoryDays(db, 14)
    Check("going back to 14 days trims the totals too", #db.houses["Alliance|Test"].daily == 14)
    Check("the overview grows to the history length", #P.HouseOverview(db.houses["Alliance|Test"]).slots == 14)
end

do
    local db = P.EnsureDB({ version = 3, houses = { h = { items = {}, scannedAt = At(0),
        daily = { { 20261101, 5, 10, 100 }, { "x", 1, 1, 1 }, "junk", { 20261102, nil, 1, 1 } } },
        g = { items = {}, daily = "junk" } } })
    Check("damaged house totals are dropped on load", #db.houses.h.daily == 1 and db.houses.h.daily[1][1] == 20261101
        and db.houses.g.daily == nil)

    local overview = { slots = {}, scanDays = 1, mean = 6580, top = 6580, low = 6580 }
    overview.slots[1] = { items = 6580 }
    local title, lines = P.OverviewLines(overview, Coins)
    Check("the overview title counts days and points at the rows",
        title == "House overview, 1 day of scans")
    Check("one day: the count, and what the rest waits for", lines[1].left == "Items listed"
        and lines[1].right == "6,580 at the last scan" and lines[2].right == "after 2 days of scans"
        and lines[3].right == "after 5 days of scans" and lines[4].right == "from your next scan"
        and lines[5].right == "from your next scan" and #lines == 5)
    overview = { scanDays = 6, mean = 5900, trendPct = 0.031, projection = 6900,
        slots = { { items = 5000 }, { items = 6580, listings = 41230, units = 1204553, value = 987654321 } } }
    title, lines = P.OverviewLines(overview, Coins)
    Check("with days of scans: average, trend, next day and the totals",
        lines[1].right == "6,580 at the last scan (avg 5,900)" and lines[2].right == "+3.1% a day"
        and lines[3].left == "Next day, about" and lines[3].right == "6,900 items"
        and lines[4].left == "Listings / units" and lines[4].right == "41,230 / 1,204,553"
        and lines[5].left == "Value at lowest prices" and lines[5].right == "987654321c")
    overview.trendPct = -0.004
    Check("a trend under half a percent is steady", select(2, P.OverviewLines(overview, Coins))[2].right == "steady")
    overview.trendPct = -0.12
    Check("a falling trend has a minus", select(2, P.OverviewLines(overview, Coins))[2].right == "-12.0% a day")
end

-- History length: 14 or 30 days, saved in settings, trimmed right away when shortened
do
    Check("history is 14 days by default", P.EnsureDB(P.EmptyDB()).settings.historyDays == nil and P.DAYS_KEPT == 14)
    local db = P.EmptyDB()
    Check("30 days can be picked", P.SetHistoryDays(db, 30) == 30 and P.DAYS_KEPT == 30
        and db.settings.historyDays == 30)
    local row
    for dayOffset = -29, 0 do
        row = ScanOn(db, dayOffset, 100 + dayOffset)
    end
    -- A second house, last scanned on day -10: it trims back from its own last scan.
    for _, dayOffset in ipairs({ -25, -10 }) do
        local best = {}
        P.Consider(best, 2589, 1, 40)
        P.Commit(db, "Horde|Test", best, At(dayOffset))
    end
    Check("30 days keeps 30 days", #row.days == 30)
    local chart = P.ChartDays(row.days, row.seen)
    Check("the chart grows to 30 slots", #chart.slots == 30 and chart.slots[1].low == 71)
    Check("an unknown length is ignored", P.SetHistoryDays(db, 60) == 30 and P.SetHistoryDays(db, "x") == 30
        and P.DAYS_KEPT == 30 and db.settings.historyDays == 30)
    Check("14 days again", P.SetHistoryDays(db, 14) == 14 and P.DAYS_KEPT == 14 and db.settings.historyDays == 14)
    Check("going back to 14 days trims every item at once", #row.days == 14
        and row.days[1][1] == P.DayKey(At(-13)))
    local other = db.houses["Horde|Test"].items[2589].days
    Check("each house trims back from its own last scan", #other == 1 and other[1][1] == P.DayKey(At(-10)))
    Check("its chart is 14 slots again", #P.ChartDays(row.days, row.seen).slots == 14)
    P.SetHistoryDays(db, 30)
    local loaded = P.EnsureDB({ version = 3, houses = {}, settings = { historyDays = 14 } })
    Check("loading saved data uses its history length", P.DAYS_KEPT == 14 and loaded.settings.historyDays == 14)
    P.EnsureDB({ version = 3, houses = {}, settings = { historyDays = 45 } })
    Check("a damaged saved length loads as 14 days", P.DAYS_KEPT == 14)
    P.SetHistoryDays(P.EmptyDB(), 30)
    P.EnsureDB({ version = 3, houses = {} })
    Check("saved data with no length loads as 14 days", P.DAYS_KEPT == 14)
end

-- Sell advice in plain words
do
    Check("advice: no one else selling", P.SellAdvice(nil, false)
        == "No one else is selling it right now, so you set the price.")
    Check("advice: no saved history yet", P.SellAdvice({}, true) == "Not enough saved prices for advice yet."
        and P.SellAdvice(nil, true) == "Not enough saved prices for advice yet.")
    Check("advice: high", P.SellAdvice({ trend = "up" }, true) == "Prices are high today. A good time to sell.")
    Check("advice: low", P.SellAdvice({ trend = "down" }, true) == "Prices are low today. Waiting may sell for more.")
    Check("advice: normal", P.SellAdvice({ trend = "flat" }, true) == "Prices are about normal today.")
    Check("advice: far under is the deal note", P.SellAdvice({ trend = "down", deal = true }, true)
        == P.DEAL_ICON .. " The lowest is far under its 7-day average. Waiting may sell for more.")
end

-- Price Check: find saved items by name
do
    local house = { items = {
        [1] = { unit = 10, seen = 1, days = {}, name = "Linen Cloth", quality = 1 },
        [2] = { unit = 20, seen = 1, days = {}, name = "Bolt of Linen Cloth", quality = 1 },
        [3] = { unit = 30, seen = 1, days = {}, name = "Wool Cloth", quality = 1 },
        [4] = { unit = 40, seen = 1, days = {} },
        [5] = { unit = 50, seen = 1, days = {}, name = "Linen Bag", quality = 1 },
    } }
    local function Names(list)
        local names = {}
        for index, entry in ipairs(list) do
            names[index] = entry.name
        end
        return table.concat(names, ",")
    end
    Check("find: names that start with the text first, then the rest, A to Z",
        Names(P.FindByName(house, "LINEN")) == "Linen Bag,Linen Cloth,Bolt of Linen Cloth")
    Check("find: an entry carries the item id and quality", P.FindByName(house, "wool")[1].itemID == 3
        and P.FindByName(house, "wool")[1].quality == 1)
    Check("find: under 2 letters finds nothing", #P.FindByName(house, "l") == 0 and #P.FindByName(house, nil) == 0)
    Check("find: items without a saved name can't be found by name", #P.FindByName(house, "item") == 0)
    Check("find: a limit keeps the first ones", Names(P.FindByName(house, "cloth", 2)) == "Bolt of Linen Cloth,Linen Cloth")
    local _, total = P.FindByName(house, "cloth", 2)
    local _, all = P.FindByName(house, "linen")
    Check("find: the count is every match, past the limit too", total == 3 and all == 3)
    Check("find: nothing found counts 0", select(2, P.FindByName(house, "zz")) == 0
        and select(2, P.FindByName(nil, "linen")) == 0)
    Check("find: no house, nothing", #P.FindByName(nil, "linen") == 0)
end

-- Sorting a list by a column
do
    local list = { { id = 1, v = 30 }, { id = 2, v = nil }, { id = 3, v = 10 }, { id = 4, v = 30 }, { id = 5, v = 20 } }
    local function IDs(sorted)
        local ids = {}
        for index, item in ipairs(sorted) do
            ids[index] = item.id
        end
        return table.concat(ids, ",")
    end
    local function Value(item) return item.v end
    Check("sort: ascending, ties keep their order, unknown values last",
        IDs(P.SortList(list, Value, true)) == "3,5,1,4,2")
    Check("sort: descending, ties still keep their order, unknown still last",
        IDs(P.SortList(list, Value, false)) == "1,4,5,3,2")
    Check("sort: the list given is left as it was", IDs(list) == "1,2,3,4,5")
    Check("sort: text sorts too", IDs(P.SortList({ { id = 1, v = "b" }, { id = 2, v = "a" } }, Value, true)) == "2,1")
end

-- Damaged day summaries are repaired or dropped on every load
do
    local good = { 20261101, 10, 12, 2, 22, 244 }
    local db = P.EnsureDB({ version = 3, houses = { ["Alliance|Test"] = { scannedAt = 5, items = {
        [1] = { unit = 10, seen = 5, days = { "junk", { 20261102, "x", 12, 1, 12, 144 }, good,
            { 20261103, 8, 9, 2 } } },
        [2] = { unit = 10, seen = 5, days = "broken" },
        [3] = { unit = 10, seen = 5 },
    } } } })
    local items = db.houses["Alliance|Test"].items
    local days = items[1].days
    Check("a day that isn't a table of numbers is dropped", #days == 2 and days[1] == good)
    Check("a day missing its average gets one, as version 2 days did", days[2][5] == 8.5 and days[2][6] == 0.5)
    local fixed = P.EnsureDB({ version = 3, houses = { h = { items = { [1] = { unit = 1, seen = 1,
        days = { { 20261101, 8, 9, 2, "x", 145 } } } } } } }).houses.h.items[1].days[1]
    Check("a day with a damaged average gets it worked out again", fixed[5] == 8.5 and fixed[6] == 0.5)
    Check("a broken day list becomes empty", type(items[2].days) == "table" and #items[2].days == 0
        and type(items[3].days) == "table")
    local market = P.Market(db.houses["Alliance|Test"])
    Check("Market still works with repaired rows", type(market.deals) == "table")
    Check("a v2 day with a bad low is dropped instead of stopping the load",
        #P.EnsureDB({ version = 2, houses = { h = { items = { [1] = { unit = 1, seen = 1,
            days = { { 20261101, "x", 1, 1 } } } } } } }).houses.h.items[1].days == 0)
end

--- The slower Stats from before the one-pass version (0.4.1): each window walks the days again.
-- Stats must give exactly what this gives, for any row.
-- @param row an item row
-- @return the stats table, or nil
local function ReferenceStats(row)
    if type(row) ~= "table" or type(row.days) ~= "table" or #row.days == 0 then
        return nil
    end
    if type(row.unit) ~= "number" or type(row.seen) ~= "number" then
        return nil
    end
    local function Totals(fromKey, toKey)
        local totals = { scans = 0, days = 0, sum = 0, sumOfSquares = 0 }
        for _, day in ipairs(row.days) do
            if day[1] >= fromKey and day[1] <= toKey then
                totals.scans = totals.scans + day[4]
                totals.days = totals.days + 1
                totals.sum = totals.sum + day[5] * day[4]
                totals.sumOfSquares = totals.sumOfSquares + day[4] * (day[6] * day[6] + day[5] * day[5])
                totals.low = math.min(totals.low or day[2], day[2])
                totals.high = math.max(totals.high or day[3], day[3])
            end
        end
        return totals
    end
    local latestKey = P.DayKey(row.seen)
    local function Back(count)
        return P.DayKey(row.seen - count * DAY)
    end
    local stats = { unit = row.unit, seen = row.seen, windows = {} }
    for _, length in ipairs(P.WINDOWS) do
        local totals = Totals(Back(length - 1), latestKey)
        stats.windows[#stats.windows + 1] = {
            days = length, scans = totals.scans, low = totals.low, high = totals.high,
            avg = totals.scans > 0 and math.floor(totals.sum / totals.scans + 0.5) or nil,
        }
    end
    local widest = Totals(Back(P.DAYS_KEPT - 1), latestKey)
    stats.scans, stats.days, stats.low, stats.high = widest.scans, widest.days, widest.low, widest.high
    local base = Totals(Back(P.BASELINE_DAYS - 1), latestKey)
    local count = base.scans - 1
    stats.earlierScans = math.max(0, count)
    if count >= P.TREND_MIN_SCANS then
        local mean = (base.sum - row.unit) / count
        local variance = (base.sumOfSquares - row.unit * row.unit - count * mean * mean) / (count - 1)
        stats.typical = math.floor(mean + 0.5)
        stats.spread = math.sqrt(math.max(0, variance))
    end
    local verdict = P.Judge(stats, row.unit)
    stats.trend, stats.trendPct, stats.deal, stats.dealPct = verdict.trend, verdict.trendPct, verdict.deal, verdict.dealPct
    return stats
end

--- True when two values hold the same keys and values all the way down.
-- @param a a value
-- @param b a value
-- @return true when they match
local function Same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    for key, value in pairs(a) do
        if not Same(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

--- Rows with made-up histories: gaps, several scans a day, a day newer than the latest scan,
-- and runs of rows that share one scan time (as a full scan saves them) or don't.
-- @param count how many rows
-- @return the rows
local function MixedRows(count)
    local state = 12345
    local function Next(top)
        state = (state * 16807) % 2147483647
        return state % top
    end
    local rows = {}
    for index = 1, count do
        local latest = At(-Next(3), Next(5) * 900)
        local row = { unit = 50 + Next(200), seen = latest, days = {} }
        for back = 20, -1, -1 do
            if Next(4) > 0 then
                local scans = 1 + Next(3)
                local low, high = 40 + Next(100), 150 + Next(150)
                row.days[#row.days + 1] = { P.DayKey(latest - back * DAY), low, high, scans,
                    math.floor((low + high) / 2), Next(30) }
            end
        end
        if index % 3 == 0 then
            row.seen = rows[index - 1].seen
        end
        rows[index] = row
    end
    return rows
end

do
    local rows = MixedRows(400)
    local function AllSame()
        for _, row in ipairs(rows) do
            if not Same(P.Stats(row), ReferenceStats(row)) then
                return false
            end
        end
        return true
    end
    Check("Stats gives what the slower version gave, for every kind of row", AllSame())
    local kept, baseline = P.DAYS_KEPT, P.BASELINE_DAYS
    local last = rows[#rows]
    P.Stats(last)
    P.DAYS_KEPT, P.BASELINE_DAYS = 21, 3
    Check("a changed history length counts at once, for the same scan time",
        Same(P.Stats(last), ReferenceStats(last)))
    Check("Stats follows a changed history length and baseline", AllSame())
    P.DAYS_KEPT, P.BASELINE_DAYS = kept, baseline
    Check("Stats goes back to the usual windows afterwards", AllSame())
    P.Stats(last)
    local window = P.WINDOWS[3]
    P.WINDOWS[3] = 5
    Check("a window changed in place counts at once", Same(P.Stats(last), ReferenceStats(last)))
    P.WINDOWS[3] = window
end

do
    local rows = MixedRows(200)
    local house = { scannedAt = rows[1].seen, items = {} }
    for index, row in ipairs(rows) do
        row.seen = house.scannedAt
        house.items[index] = row
    end
    local market = P.Market(house)
    local deals, drops, rises = 0, 0, 0
    for _, row in ipairs(rows) do
        local stats = ReferenceStats(row)
        deals = deals + (stats.deal and 1 or 0)
        drops = drops + (stats.trend == "down" and 1 or 0)
        rises = rises + (stats.trend == "up" and 1 or 0)
    end
    Check("Market lists what the slower Stats found",
        #market.deals == deals and #market.drops == drops and #market.rises == rises and deals > 0 and rises > 0)
    local function EntriesMatch(list)
        for _, entry in ipairs(list) do
            local stats = ReferenceStats(house.items[entry.itemID])
            if entry.unit ~= stats.unit or entry.typical ~= stats.typical or entry.trendPct ~= stats.trendPct
                or entry.deal ~= stats.deal or entry.qty ~= house.items[entry.itemID].qty then
                return false
            end
        end
        return true
    end
    Check("each Market entry has the slower Stats' numbers",
        EntriesMatch(market.deals) and EntriesMatch(market.drops) and EntriesMatch(market.rises))
end

-- A blank realm name (the Forever client since 2026-11-20) files prices under the realm the
-- game last named, and the houses saved under the unknown realm join that realm's house.
do
    local db = P.EnsureDB(nil)
    Check("a blank realm with none seen is the unknown realm", P.RealmFor(db, "") == P.UNKNOWN_REALM
        and P.RealmFor(db, nil) == P.UNKNOWN_REALM and db.homeRealm == nil)
    Check("a real realm name is used and remembered", P.RealmFor(db, "Realm Five") == "Realm Five"
        and db.homeRealm == "Realm Five")
    Check("a blank realm name then means the remembered realm", P.RealmFor(db, "") == "Realm Five"
        and P.RealmFor(db, nil) == "Realm Five" and P.RealmFor(db, 7) == "Realm Five")
end

--- A day row as half its scans at the low and half at the high.
-- @param key the day key
-- @param low the low
-- @param high the high
-- @param scans how many scans
-- @return { key, low, high, scans, average, spread }
local function Day(key, low, high, scans)
    local average, spread = P.DaySummary(low, high, scans, (low + high) / 2 * scans, (low * low + high * high) / 2 * scans)
    return { key, low, high, scans, average, spread }
end

do
    P.DAYS_KEPT = 14
    local nov20 = os.time({ year = 2026, month = 11, day = 20, hour = 7 })
    local nov21 = os.time({ year = 2026, month = 11, day = 21, hour = 2 })
    local into = {
        scannedAt = nov20,
        items = {
            [1] = { unit = 50, qty = 2, seen = nov20, name = "Old name", quality = 1,
                days = { Day(20261119, 40, 60, 2), Day(20261120, 50, 50, 1) } },
            [3] = { unit = 7, qty = 1, seen = nov20, name = "Only old", days = { Day(20261120, 7, 7, 1) } },
        },
        daily = { { 20261119, 10, 20, 300 }, { 20261120, 11, 21, 310 } },
    }
    local from = {
        scannedAt = nov21,
        replicateAt = nov21,
        items = {
            [1] = { unit = 45, qty = 4, seen = nov21, days = { Day(20261120, 30, 55, 1), Day(20261121, 45, 45, 1) } },
            [2] = { unit = 9, qty = 1, seen = nov21, name = "Only new", days = { Day(20261121, 9, 9, 1) } },
        },
        daily = { { 20261120, 12, 22, 320 }, { 20261121, 13, 23, 330 } },
    }
    local merged = P.MergeHouse(into, from)
    local one = merged.items[1]
    Check("merge keeps the house it merged into", merged == into)
    Check("an item in both gets every day once, oldest first", #one.days == 3
        and one.days[1][1] == 20261119 and one.days[2][1] == 20261120 and one.days[3][1] == 20261121)
    local shared = one.days[2]
    -- One scan at 50 and one day of one scan saved as 30 to 55 (average 42.5, no spread): 2 scans,
    -- average 46.25, spread sqrt((2500 + 42.5^2) / 2 - 46.25^2) = 3.75 -> 3.8.
    Check("a day in both adds up: lowest low, highest high, scans, average and spread",
        shared[2] == 30 and shared[3] == 55 and shared[4] == 2 and shared[5] == 46.25 and shared[6] == 3.8)
    Check("the latest price comes from the house that saw it last",
        one.unit == 45 and one.qty == 4 and one.seen == nov21)
    Check("a name the newer row lacks comes from the older", one.name == "Old name" and one.quality == 1)
    Check("an item only in one house is kept", merged.items[2].name == "Only new"
        and merged.items[3].name == "Only old")
    Check("daily totals: every day once, the later scan's on a shared day", #merged.daily == 3
        and merged.daily[2][1] == 20261120 and merged.daily[2][2] == 12 and merged.daily[3][1] == 20261121)
    Check("scan times are the later ones", merged.scannedAt == nov21 and merged.replicateAt == nov21)
    local stats = P.Stats(one)
    Check("Stats works on a merged row", stats ~= nil)
end

do
    P.DAYS_KEPT = 14
    local now = os.time({ year = 2026, month = 11, day = 30, hour = 12 })
    local oldDays, newDays = {}, {}
    for day = 1, 14 do
        oldDays[#oldDays + 1] = Day(20261100 + day, 10, 10, 1)
    end
    for day = 17, 30 do
        newDays[#newDays + 1] = Day(20261100 + day, 10, 10, 1)
    end
    local merged = P.MergeHouse({ scannedAt = now - 86400 * 3, items = { [5] = { seen = 1, days = oldDays } } },
        { scannedAt = now, items = { [5] = { seen = now, days = newDays } } })
    local days = merged.items[5].days
    Check("a merged row is pruned to the history length", #days == 14 and days[1][1] == 20261117
        and days[14][1] == 20261130)
end

do
    local nov20 = os.time({ year = 2026, month = 11, day = 20, hour = 7 })
    local nov21 = os.time({ year = 2026, month = 11, day = 21, hour = 2 })
    local db = P.EnsureDB({
        version = P.DB_VERSION,
        lastHouseKey = "Horde|Forever",
        settings = { historyDays = 30 },
        houses = {
            ["Horde|Realm Five"] = { scannedAt = nov20, items = {
                [1] = { unit = 5, qty = 1, seen = nov20, days = { Day(20261109, 5, 5, 1), Day(20261120, 5, 5, 1) } } } },
            ["Horde|Forever"] = { scannedAt = nov21, items = {
                [1] = { unit = 6, qty = 1, seen = nov21, days = { Day(20261121, 6, 6, 1) } } } },
            ["Neutral|Forever"] = { scannedAt = nov21, items = {
                [8] = { unit = 6, qty = 1, seen = nov21, days = { Day(20261121, 6, 6, 1) } } } },
        },
    })
    Check("a load joins the unknown realm's houses into the only named realm",
        db.houses["Horde|Forever"] == nil and db.houses["Neutral|Forever"] == nil
        and #db.houses["Horde|Realm Five"].items[1].days == 3 and db.houses["Neutral|Realm Five"].items[8] ~= nil)
    Check("the joined house keeps the old days of a 30-day history",
        db.houses["Horde|Realm Five"].items[1].days[1][1] == 20261109)
    Check("the last house key follows the join", db.lastHouseKey == "Horde|Realm Five")
    Check("the named realm becomes the remembered realm", db.homeRealm == "Realm Five")
    Check("the join is listed once, for the addon to say", #P.joined == 2)
    P.EnsureDB(db)
    Check("a second load joins nothing", #P.joined == 0 and #db.houses["Horde|Realm Five"].items[1].days == 3)
end

do
    local db = P.EnsureDB({ version = P.DB_VERSION, houses = {
        ["Horde|Realm A"] = { items = {} }, ["Horde|Realm B"] = { items = {} }, ["Horde|Forever"] = { items = {} } } })
    Check("two named realms and none remembered: the unknown realm stays apart",
        db.houses["Horde|Forever"] ~= nil and db.homeRealm == nil and #P.joined == 0)
    db.homeRealm = "Realm B"
    P.EnsureDB(db)
    Check("with a remembered realm it joins that one", db.houses["Horde|Forever"] == nil
        and db.houses["Horde|Realm B"] ~= nil and db.houses["Horde|Realm A"] ~= nil)
end

do
    local db = P.EnsureDB({ version = P.DB_VERSION, houses = { ["Horde|Forever"] = { items = { [1] = {
        unit = 1, qty = 1, seen = 1, days = { Day(20261121, 1, 1, 1) } } } } } })
    Check("only the unknown realm saved: left as it is", db.houses["Horde|Forever"] ~= nil and db.homeRealm == nil)
    db.homeRealm = ""
    P.EnsureDB(db)
    Check("a blank remembered realm is dropped", db.homeRealm == nil and db.houses["Horde|Forever"] ~= nil)
end
P.DAYS_KEPT = 14

-- Each scan: every item keeps its last SCANS_KEPT scans as time, price pairs, oldest first
do
    P.DAYS_KEPT = 14
    local db = P.EmptyDB()
    ScanOn(db, -1, 80)
    ScanOn(db, 0, 90)
    local row = ScanOn(db, 0, 70, 60)
    Check("each scan saves its time and price, oldest first", row.scans and #row.scans == 6
        and row.scans[1] == At(-1) and row.scans[2] == 80 and row.scans[3] == At(0) and row.scans[4] == 90
        and row.scans[5] == At(0, 60) and row.scans[6] == 70)

    db = P.EmptyDB()
    for scan = 1, P.SCANS_KEPT + 5 do
        row = ScanOn(db, 0, 100 + scan, scan * 60)
    end
    Check("only the last SCANS_KEPT scans are kept", P.SCANS_KEPT == 30 and #row.scans == 2 * P.SCANS_KEPT
        and row.scans[1] == At(0, 6 * 60) and row.scans[2] == 106
        and row.scans[#row.scans] == 100 + P.SCANS_KEPT + 5)

    db = P.EmptyDB()
    ScanOn(db, -20, 50)
    row = ScanOn(db, 0, 60)
    Check("a scan older than the history length is dropped", #row.scans == 2 and row.scans[1] == At(0))

    db = P.EmptyDB()
    local best = {}
    P.Consider(best, 2589, 1, 40)
    P.Commit(db, "Alliance|Test", best, At(-13))
    ScanOn(db, 0, 10)
    local unseen = db.houses["Alliance|Test"].items[2589]
    Check("an item still in the history keeps its scans", #unseen.scans == 2)
    ScanOn(db, 1, 10)
    Check("an item missing from scans has old scans dropped too", type(unseen.scans) == "table"
        and #unseen.scans == 0)
end

do
    P.DAYS_KEPT = 14
    local db = P.EmptyDB()
    P.SetHistoryDays(db, 30)
    ScanOn(db, -20, 50)
    local row = ScanOn(db, 0, 60)
    Check("30 days keeps a 20-day-old scan", #row.scans == 4)
    P.SetHistoryDays(db, 14)
    Check("going back to 14 days trims the scans right away", #row.scans == 2 and row.scans[1] == At(0))
end

do
    P.DAYS_KEPT = 14
    local db = P.EmptyDB()
    ScanOn(db, -1, 80)
    ScanOn(db, 0, 120)
    ScanOn(db, 0, 90, 60)
    local info = P.Lookup(db, 4306, "Alliance|Test")
    Check("Lookup hands out the scans", info and info.scans == db.houses["Alliance|Test"].items[4306].scans)
    local chart = P.ChartScans(info.scans)
    Check("the scan chart has one slot per scan, oldest first, at the right", chart and chart.count == 3
        and #chart.slots == P.CHART_MIN_DAYS and chart.slots[5].time == At(-1) and chart.slots[5].low == 80
        and chart.slots[5].high == 80 and chart.slots[7].time == At(0, 60) and chart.slots[7].low == 90)
    Check("a few scans leave the first slots empty", chart.slots[1].low == nil and chart.slots[4].low == nil)
    Check("each scan slot knows its day", chart.slots[5].dayKey == P.DayKey(At(-1))
        and chart.slots[6].dayKey == P.DayKey(At(0)) and chart.slots[7].dayKey == P.DayKey(At(0)))
    local many = P.EmptyDB()
    for scan = 1, 12 do
        ScanOn(many, 0, scan, scan * 60)
    end
    local full = P.ChartScans(P.Lookup(many, 4306, "Alliance|Test").scans)
    Check("more scans than the minimum: one slot each", full.count == 12 and #full.slots == 12
        and full.slots[12].low == 12 and full.top == 12)
    Check("the scan chart's top is the highest price", chart.top == 120)
    Check("no scans, no scan chart", P.ChartScans(nil) == nil and P.ChartScans({}) == nil)
end

do
    local db = P.EnsureDB({ version = P.DB_VERSION, houses = { ["Alliance|Test"] = { items = {
        [1] = { unit = 5, qty = 1, seen = 100, days = {}, scans = 5 },
        [2] = { unit = 5, qty = 1, seen = 100, days = {}, scans = { 10, 20, "x", 4, 30, 40, 50 } },
        [3] = { unit = 5, qty = 1, seen = 100, days = {} },
    } } } })
    local items = db.houses["Alliance|Test"].items
    Check("a scan list that isn't a table is dropped", items[1].scans == nil)
    Check("a damaged scan pair is dropped, the rest kept", #items[2].scans == 4 and items[2].scans[1] == 10
        and items[2].scans[2] == 20 and items[2].scans[3] == 30 and items[2].scans[4] == 40)
    Check("a row saved before scan lists stays without one", items[3].scans == nil)
end

do
    P.DAYS_KEPT = 14
    local into = { scannedAt = At(0), items = { [1] = { unit = 5, qty = 1, seen = At(0), days = {},
        scans = { At(-2), 50, At(0), 70 } } } }
    local from = { scannedAt = At(-1), items = {
        [1] = { unit = 6, qty = 1, seen = At(-1), days = {}, scans = { At(-1), 60, At(0), 70 } },
        [2] = { unit = 9, qty = 1, seen = At(-1), days = {}, scans = { At(-1), 90 } } } }
    P.MergeHouse(into, from)
    local scans = into.items[1].scans
    Check("joining houses joins the scans by time, once each", #scans == 6 and scans[1] == At(-2)
        and scans[3] == At(-1) and scans[4] == 60 and scans[5] == At(0) and scans[6] == 70)
    Check("an item only in the joined house keeps its scans", #into.items[2].scans == 2)
    into.items[3] = { unit = 1, qty = 1, seen = At(0), days = {} }
    P.MergeHouse(into, { items = { [3] = { unit = 2, qty = 1, seen = At(-1), days = {}, scans = { At(-1), 2 } } } })
    Check("a row without scans takes the other's, once", #into.items[3].scans == 2)

    local bare = { scannedAt = At(-1), items = { [4] = { unit = 1, qty = 1, seen = At(-1) } } }
    P.MergeHouse(bare, { scannedAt = At(0), daily = { { P.DayKey(At(0)), 10, 20, 300 } },
        items = { [4] = { unit = 2, qty = 1, seen = At(0), days = { Day(P.DayKey(At(0)), 2, 2, 1) } } } })
    Check("a house saved before daily totals takes the other's", #bare.daily == 1 and bare.daily[1][2] == 10)
    Check("a row without days takes the other's, counted once", #bare.items[4].days == 1
        and bare.items[4].days[1][2] == 2 and bare.items[4].days[1][4] == 1)
end
-- Chart view: days or scans, saved in settings
do
    local db = P.EnsureDB(nil)
    Check("charts show days by default", P.ChartView(db) == "days" and P.ChartView(nil) == "days")
    Check("scans can be picked and are saved", P.SetChartView(db, "scans") == "scans"
        and db.settings.chartView == "scans" and P.ChartView(db) == "scans")
    Check("an unknown view changes nothing", P.SetChartView(db, "weeks") == "scans" and P.ChartView(db) == "scans")
    Check("days again", P.SetChartView(db, "days") == "days" and P.ChartView(db) == "days")
    db.settings.chartView = 7
    P.EnsureDB(db)
    Check("a damaged view is dropped on load", db.settings.chartView == nil and P.ChartView(db) == "days")
    db.settings.chartView = "scans"
    P.EnsureDB(db)
    Check("a saved view survives a load", P.ChartView(db) == "scans")
end

do
    local chart = P.ChartScans({ At(-1), 80, At(0, 60), 90 })
    Check("the scan span names the first and last scan", P.ScanSpanText(chart)
        == os.date("%m/%d %H:%M", At(-1)) .. " to " .. os.date("%m/%d %H:%M", At(0, 60)))
    Check("one scan: just its time", P.ScanSpanText(P.ChartScans({ At(0), 5 })) == os.date("%m/%d %H:%M", At(0)))
    Check("no chart, no span", P.ScanSpanText(nil) == nil)
end

-- Each day saves its average and spread rounded (average to 4 digits, spread to 2), so a busy
-- house's saved file stays far under Lua's constant limit.
do
    Check("a steady day keeps its exact price", select(1, P.DaySummary(123456, 123456, 3, 370368, 3 * 123456 ^ 2)) == 123456
        and select(2, P.DaySummary(123456, 123456, 3, 370368, 3 * 123456 ^ 2)) == 0)
    local average, spread = P.DaySummary(100000, 130000, 2, 223456, 100000 ^ 2 + 123456 ^ 2)
    Check("an average between low and high keeps 4 digits", average == 111700)
    Check("the spread keeps 2 digits", spread == 12000)
    average = P.DaySummary(12346, 12349, 2, 24697, 12346 ^ 2 + 12351 ^ 2)
    Check("rounding never leaves the day's range", average >= 12346 and average <= 12349)
    Check("a few copper keep their fraction", P.DaySummary(10, 12, 3, 31, 100 + 100 + 144) == 10.33)
    Check("an average equal to the low stays exact", P.DaySummary(10, 12, 2, 20, 200) == 10)

    -- A version 3 day saved sums; a sum of 2 or more scans is always above the day's high.
    local db = P.EnsureDB({ version = 3, houses = { h = { scannedAt = 1, items = {
        [1] = { unit = 70, seen = 1, days = { { 20261101, 50, 70, 2, 120, 7400 }, { 20261102, 40, 40, 1, 40, 1600 } } },
    } } } })
    local days = db.houses.h.items[1].days
    Check("version 3 sums become an average and spread", db.version == 4 and days[1][5] == 60 and days[1][6] == 10)
    Check("a version 3 single scan keeps its price and no spread", days[2][5] == 40 and days[2][6] == 0)
    db.version = 3
    P.EnsureDB(db)
    Check("converting again changes nothing", days[1][5] == 60 and days[1][6] == 10 and days[2][5] == 40)
end

do
    -- Stats from rounded days stay within a fraction of a percent of exact sums.
    local db = P.EmptyDB()
    local prices = { 101234, 99876, 104321, 97654, 100500, 102222, 98765, 103333, 99999, 101010 }
    local exactSum, exactSquares = 0, 0
    for index, price in ipairs(prices) do
        ScanOn(db, math.floor((index - 1) / 2) - 5, price, (index - 1) % 2 * 3600)
    end
    for index = 1, #prices - 1 do
        exactSum, exactSquares = exactSum + prices[index], exactSquares + prices[index] ^ 2
    end
    local count = #prices - 1
    local mean = exactSum / count
    local exactSpread = math.sqrt((exactSquares - count * mean * mean) / (count - 1))
    local stats = P.Stats(db.houses["Alliance|Test"].items[4306])
    Check("typical price within 0.1% of exact", math.abs(stats.typical - mean) / mean < 0.001)
    Check("spread within 1% of the price of exact", math.abs(stats.spread - exactSpread) / mean < 0.01)
end

P.DAYS_KEPT = 14

if failed > 0 then
    io.write(string.format("%d failed\n", failed))
    os.exit(1)
end
io.write("all passed\n")
