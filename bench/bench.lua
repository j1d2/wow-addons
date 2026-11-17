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

dofile("addons/Unmaker/UnmakerStats.lua")
local P = dofile("addons/HouseLedger/PriceLedger.lua")
local S = UnmakerStats
local Synth = dofile("bench/synth.lua")

local scale = tonumber(os.getenv("BENCH_BUDGET_SCALE") or "") or 1
--- Lua 5.1 loads a file as one function, and one function holds at most 262,143 constants
-- (each different number or string once). A saved file over that fails to load, and the game
-- may then save over it. WoW's own limit is not documented; this is stock Lua 5.1's.
local CONSTANT_LIMIT = 262143
local overBudget = 0

--- Smoke budgets per step: kb = most memory the step may allocate, ms = loose time guard.
-- Kept memory is checked per day row. Set from measured values with about 1.5x headroom
-- (2026-11-15); see bench/README.md before raising one.
local BUDGETS = {
    keptPerDayRow = 300,
    -- Share of CONSTANT_LIMIT the smoke data may use.
    constantShare = 0.5,
    ["Load saved file"] = { kb = 13000, ms = 2000 },
    EnsureDB = { kb = 1000, ms = 2000 },
    ["Stats, every item"] = { kb = 7600, ms = 2000 },
    Market = { kb = 1100, ms = 2000 },
    FindByName = { kb = 600, ms = 2000 },
    HouseOverview = { kb = 10, ms = 2000 },
    ["ChartDays, every item"] = { kb = 13000, ms = 2000 },
    ["Commit, full scan"] = { kb = 500, ms = 2000 },
    SortHistory = { kb = 200, ms = 2000 },
    FilterHistory = { kb = 60, ms = 2000 },
    ["Record, full history"] = { kb = 20, ms = 2000 },
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
local function BenchHouseLedger(items, days)
    print(string.format("\nHouseLedger, %d items x %d days", items, days))
    local base = KeptKB()
    local db, houseKey = Synth.HouseLedgerDB(items, days, P.DayKey)
    -- Keep the history length being measured, so loading the data doesn't set it back to 14 and
    -- turn the Commit step into a mass trim. 60 days isn't a Settings choice: it stays at 14 here
    -- and is a what-if for the saved file's size only.
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

    Step("EnsureDB", function() P.EnsureDB(db) end)
    Step("Stats, every item", function()
        for _, row in pairs(house.items) do
            P.Stats(row)
        end
    end)
    Step("Market", function() P.Market(house) end)
    Step("FindByName", function() P.FindByName(house, "bench item 1", 100) end)
    Step("HouseOverview", function() P.HouseOverview(house) end)
    Step("ChartDays, every item", function()
        for _, row in pairs(house.items) do
            P.ChartDays(row.days, row.seen)
        end
    end)
    local best = Synth.FullScan(house)
    Step("Commit, full scan", function() P.Commit(db, houseKey, best, Synth.NOW + 24 * 60 * 60) end)
    HouseLedgerDB = nil
end

--- Benchmarks Unmaker's history functions on one synthetic history.
-- @param entries how many history entries
local function BenchUnmaker(entries)
    print(string.format("\nUnmaker, %d history entries", entries))
    local base = KeptKB()
    local db = { history = Synth.UnmakerHistory(entries) }
    S.EnsureStats(db, "Bench Realm")
    print(string.format("memory  Unmaker %d entries: %.2f MB kept", entries, (KeptKB() - base) / 1024))
    Step("SortHistory", function() S.SortHistory(db.history, "name", false) end)
    Step("FilterHistory", function() S.FilterHistory(db.history, "Benchmain-Bench Realm", "Bench Realm") end)
    local limit = S.HISTORY_MAX
    S.HISTORY_MAX = entries
    local item = { itemID = 1001, name = "Bench Gear 1001", link = "x", quality = 2, level = 20,
        character = "Benchmain", realm = "Bench Realm" }
    Step("Record, full history", function()
        for _ = 1, 10 do
            S.Record(db, {}, item, Synth.NOW)
        end
    end, "10 disenchants")
    S.HISTORY_MAX = limit
end

if mode == "--smoke" then
    BenchHouseLedger(2000, 14)
    BenchUnmaker(2000)
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
    for _, entries in ipairs({ 500, 2500, 5000, 10000 }) do
        BenchUnmaker(entries)
    end
end
