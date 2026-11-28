--- Speed and memory benchmarks for the pure parts of HouseLedger and Unmaker, on synthetic data
-- (bench/synth.lua). Run from the repo root through scripts/bench.sh.
--
--   lua5.1 bench/bench.lua --smoke   small fixed sizes with budgets; exits 1 if a step is over
--   lua5.1 bench/bench.lua --full    the sizes worth knowing (6,600 and 20,000 items at 14, 30
--                                    and 60 days, Unmaker up to 10,000 entries); no budgets
--
-- Each step reports its time (os.clock) and the memory it allocates (counted with the garbage
-- collector stopped, so the number repeats exactly). Each data set reports the memory it keeps
-- after a full collection. Budgets: allocation and kept memory are deterministic, so their limits
-- are close; time varies by machine, so its limit is only a loose guard.
-- Environment: BENCH_BUDGET_SCALE multiplies every budget (the self-test sets it tiny).

local USAGE = "usage: lua5.1 bench/bench.lua --smoke | --full\n"

local mode = arg[1]
if mode ~= "--smoke" and mode ~= "--full" then
    io.stderr:write(USAGE)
    os.exit(2)
end

local S = dofile("addons/Unmaker/UnmakerStats.lua")
local D = dofile("addons/Unmaker/UnmakerResults.lua")
local P = dofile("addons/HouseLedger/PriceLedger.lua")
local Synth = dofile("bench/synth.lua")

local scale = tonumber(os.getenv("BENCH_BUDGET_SCALE") or "") or 1
--- Lua 5.1 loads a file as one function, and one function holds at most 262,143 constants
-- (each different number or string once). A saved file over that fails to load, and the game
-- may then save over it. WoW's own limit is not documented; this is stock Lua 5.1's.
local CONSTANT_LIMIT = 262143
local overBudget = 0

--- Smoke budgets per step: kb = most memory the step may allocate, ms = loose time guard.
-- Kept memory is checked per day row. Set from measured values with about 1.5x headroom
-- (2026-11-15; kept memory, ChartScans and Commit 2026-11-21, when each item started keeping
-- its last 30 scans); see bench/README.md before raising one.
local BUDGETS = {
    keptPerDayRow = 470,
    -- Share of CONSTANT_LIMIT the smoke data may use (3.2% since version 4's rounded days; 5.3% with
    -- a full History tab of 2,000 entries, 2026-11-23: each has its own time and amounts. A real
    -- 15-day file measured 14.2% before the History tab.)
    constantShare = 0.06,
    ["Load saved file"] = { kb = 13000, ms = 2000 },
    ["EnsureDB, from version 3"] = { kb = 1070, ms = 2000 },
    EnsureDB = { kb = 1000, ms = 2000 },
    ["Stats, every item"] = { kb = 7600, ms = 2000 },
    Market = { kb = 1100, ms = 2000 },
    FindByName = { kb = 600, ms = 2000 },
    HouseOverview = { kb = 10, ms = 2000 },
    ["ChartDays, every item"] = { kb = 13000, ms = 2000 },
    ["ChartScans, every item"] = { kb = 18000, ms = 2000 },
    -- 2026-11-21: about 9 KB per item, for one chart click.
    ["ChartFit, every item"] = { kb = 26600, ms = 2000 },
    ["Commit, same day"] = { kb = 410, ms = 2000 },
    ["Commit, full scan"] = { kb = 870, ms = 2000 },
    -- Unmaker at 1,000 entries, a history-length choice (2026-11-22; was 2,000 before it was one).
    SortHistory = { kb = 85, ms = 2000 },
    FilterHistory = { kb = 25, ms = 2000 },
    ["Record, full history"] = { kb = 15, ms = 2000 },
    -- Counting the player's own disenchant results, after each disenchant (2026-11-22).
    ["Tally, full history"] = { kb = 70, ms = 2000 },
    -- HouseLedger's History tab at LEDGER_KEPT entries, worked out when the history changes (2026-11-23).
    -- 300 since every sale has a profit (2026-11-27; measured 201, was 181 with flips only).
    ["LedgerProfits, full"] = { kb = 300, ms = 2000 },
    ["LedgerView"] = { kb = 120, ms = 2000 },
    -- The History stats block and its 14-day chart, on every redraw of the tab (2026-11-27).
    ["Ledger stats + chart"] = { kb = 10, ms = 2000 },
}

--- The memory in use now, in KB, after a full collection.
-- @return kilobytes
local function KeptKB()
    collectgarbage("collect")
    collectgarbage("collect")
    return collectgarbage("count")
end

--- Counts the different numbers and strings in a value, which is how many constants its saved
-- file needs (array positions up to 6 are written without keys, so they don't count).
-- @param value the table to count
-- @return the count
local function CountConstants(value)
    local seen, count = {}, 0
    local function Add(item)
        if not seen[item] then
            seen[item] = true
            count = count + 1
        end
    end
    local function Walk(item)
        local length = #item
        for key, inner in pairs(item) do
            if not (type(key) == "number" and key >= 1 and key <= length and key % 1 == 0) then
                Add(key)
            end
            if type(inner) == "table" then
                Walk(inner)
            else
                Add(inner)
            end
        end
    end
    Walk(value)
    return count
end

--- Runs one step and prints its line; in smoke mode checks it against its budget.
-- @param name the step's name (a key of BUDGETS in smoke mode)
-- @param fn the work, called once
-- @param detail optional extra text for the line
local function Step(name, fn, detail)
    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    local start = os.clock()
    fn()
    local ms = (os.clock() - start) * 1000
    local kb = collectgarbage("count") - before
    collectgarbage("restart")
    local line = string.format("step    %-24s %9.1f ms %10.0f KB allocated", name, ms, kb)
    local budget = mode == "--smoke" and BUDGETS[name]
    if budget then
        local over = {}
        if kb > budget.kb * scale then
            over[#over + 1] = string.format("allocates over %.0f KB", budget.kb * scale)
        end
        if ms > budget.ms * scale then
            over[#over + 1] = string.format("takes over %.0f ms", budget.ms * scale)
        end
        if #over > 0 then
            overBudget = overBudget + 1
            line = line .. "   over budget: " .. table.concat(over, ", ")
        end
    end
    print(line .. (detail and ("   " .. detail) or ""))
end

--- Benchmarks HouseLedger's price module on one synthetic house.
-- @param items how many items
-- @param days how many days of history
-- @param maxScans optional; most scans a day (each day has 1 to this many), 3 by default
local function BenchHouseLedger(items, days, maxScans)
    print(string.format("\nHouseLedger, %d items x %d days%s", items, days,
        maxScans and string.format(", 1 to %d scans a day", maxScans) or ""))
    local base = KeptKB()
    local db, houseKey = Synth.HouseLedgerDB(items, days, P, maxScans)
    -- Keep the history length being measured, so loading the data doesn't set it back to 14 and
    -- turn the Commit step into a mass trim.
    if P.IsHistoryChoice(days) then
        db.settings.historyDays = days
    end
    local house = db.houses[houseKey]
    local dayRows = 0
    for _, row in pairs(house.items) do
        dayRows = dayRows + #row.days
    end
    local keptKB = KeptKB() - base
    local perRow = keptKB * 1024 / dayRows
    local memoryLine = string.format("memory  HouseLedger %d x %d: %d day rows, %.1f MB kept, %.0f bytes per day row",
        items, days, dayRows, keptKB / 1024, perRow)
    if mode == "--smoke" and perRow > BUDGETS.keptPerDayRow * scale then
        overBudget = overBudget + 1
        memoryLine = memoryLine .. string.format("   over budget: over %.0f bytes per day row", BUDGETS.keptPerDayRow * scale)
    end
    print(memoryLine)
    local constants = CountConstants(db)
    local constantLine = string.format("memory  HouseLedger %d x %d: %d different values, %.0f%% of Lua's %d limit",
        items, days, constants, constants / CONSTANT_LIMIT * 100, CONSTANT_LIMIT)
    if mode == "--smoke" and constants > CONSTANT_LIMIT * BUDGETS.constantShare * scale then
        overBudget = overBudget + 1
        constantLine = constantLine .. "   over budget"
    end
    print(constantLine)

    local text = Synth.Serialize("HouseLedgerDB", db)
    local size = #text
    if constants <= CONSTANT_LIMIT then
        db, house = nil, nil
        Step("Load saved file", function()
            assert(loadstring(text))()
        end, string.format("file about %.1f MB", size / 1048576))
        db = HouseLedgerDB
        house = db.houses[houseKey]
    else
        print(string.format("step    %-24s FAILS: over the constant limit, file about %.1f MB",
            "Load saved file", size / 1048576))
        if mode == "--smoke" then
            overBudget = overBudget + 1
        end
    end
    text = nil

    -- The one-off conversion on the first load after updating: the same days as version 3 sums.
    for _, row in pairs(house.items) do
        for _, day in ipairs(row.days) do
            day[5], day[6] = day[5] * day[4], day[4] * (day[6] * day[6] + day[5] * day[5])
        end
    end
    db.version = 3
    Step("EnsureDB, from version 3", function() P.EnsureDB(db) end)
    Step("EnsureDB", function() P.EnsureDB(db) end)
    Step("Stats, every item", function()
        for _, row in pairs(house.items) do
            P.Stats(row)
        end
    end)
    Step("Market", function() P.Market(house) end)
    local profits
    Step("LedgerProfits, full", function() profits = P.LedgerProfits(db.ledger.entries) end,
        #db.ledger.entries .. " entries")
    Step("LedgerView", function() P.LedgerView(db.ledger.entries) end)
    Step("Ledger stats + chart", function()
        P.LedgerPeriods(db.ledger.entries, profits, Synth.NOW, nil)
        P.LedgerLifetime(db.ledger, profits, nil)
        P.LedgerChartDays(db.ledger.entries, profits, Synth.NOW, nil)
    end)
    Step("FindByName", function() P.FindByName(house, "bench item 1", 100) end)
    Step("HouseOverview", function() P.HouseOverview(house) end)
    Step("ChartDays, every item", function()
        for _, row in pairs(house.items) do
            P.ChartDays(row.days, row.seen)
        end
    end)
    Step("ChartScans, every item", function()
        for _, row in pairs(house.items) do
            P.ChartScans(row.scans)
        end
    end)
    -- ChartFit runs on one item per click; every item's 30 scans (435 slope pairs each) is its worst case.
    local scanSlots = {}
    for _, row in pairs(house.items) do
        local chart = P.ChartScans(row.scans)
        scanSlots[#scanSlots + 1] = chart and chart.slots
    end
    Step("ChartFit, every item", function()
        for _, slots in ipairs(scanSlots) do
            P.ChartFit(slots)
        end
    end)
    scanSlots = nil
    local best = Synth.FullScan(house)
    -- A second scan the same day re-rounds every item's day (DaySummary); the next day's starts new days.
    Step("Commit, same day", function() P.Commit(db, houseKey, best, Synth.NOW + 60 * 60) end)
    Step("Commit, full scan", function() P.Commit(db, houseKey, best, Synth.NOW + 24 * 60 * 60) end)
    HouseLedgerDB = nil
end

--- Benchmarks Unmaker's history functions on one synthetic history.
-- @param entries how many history entries
local function BenchUnmaker(entries)
    print(string.format("\nUnmaker, %d history entries", entries))
    local base = KeptKB()
    -- The history length is a Settings choice, so the bench sizes are choices too.
    local db = { history = Synth.UnmakerHistory(entries), settings = { historyMax = entries } }
    S.EnsureStats(db, "Bench Realm")
    print(string.format("memory  Unmaker %d entries: %.2f MB kept", entries, (KeptKB() - base) / 1024))
    Step("SortHistory", function() S.SortHistory(db.history, "name", false) end)
    Step("FilterHistory", function() S.FilterHistory(db.history, "Benchmain-Bench Realm", "Bench Realm") end)
    -- Every other item a weapon, the rest armor, as GetItemInfoInstant would say.
    Step("Tally, full history", function()
        D.Tally(db.history, function(itemID) return itemID % 2 == 0 and 2 or 4 end)
    end)
    local item = { itemID = 1001, name = "Bench Gear 1001", link = "x", quality = 2, level = 20,
        character = "Benchmain", realm = "Bench Realm" }
    Step("Record, full history", function()
        for _ = 1, 10 do
            S.Record(db, {}, item, Synth.NOW)
        end
    end, "10 disenchants")
end

if mode == "--smoke" then
    BenchHouseLedger(2000, 14)
    BenchUnmaker(1000)
    if overBudget > 0 then
        print(string.format("\n%d over budget", overBudget))
        os.exit(1)
    end
    print("\nSmoke run within budget.")
else
    for _, items in ipairs({ 6600, 20000 }) do
        for _, days in ipairs({ 14, 30, 60 }) do
            BenchHouseLedger(items, days)
        end
    end
    -- A heavy scanner: about 5.5 scans a day. Exact day sums (version 3) passed the constant
    -- limit here; rounded days (version 4) keep it far under.
    BenchHouseLedger(20000, 30, 10)
    BenchHouseLedger(20000, 60, 10)
    for _, entries in ipairs(S.HISTORY_CHOICES) do
        BenchUnmaker(entries)
    end
end
