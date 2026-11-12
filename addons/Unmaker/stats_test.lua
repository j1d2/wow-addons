--[[
Offline checks for UnmakerStats. The game does not load this file.
Run: lua5.1 stats_test.lua
]]

local folder = arg[0]:match("^(.*)/") or "."
dofile(folder .. "/UnmakerStats.lua")

local S = UnmakerStats
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

-- Fixed times: noon on two days, so day keys don't depend on the time zone.
local DAY1 = os.time({ year = 2026, month = 11, day = 10, hour = 12 })
local DAY2 = os.time({ year = 2026, month = 11, day = 11, hour = 12 })

--- A disenchanted item as Unmaker.lua records it.
-- @param itemID item ID
-- @param name item name
-- @param quality 2 to 4
-- @param level item level
-- @return the item table
local function Unmade(itemID, name, quality, level)
    return { itemID = itemID, name = name, link = "|Hitem:" .. itemID .. "|h[" .. name .. "]|h",
        quality = quality, level = level, character = "Tester" }
end

--- One loot slot from a disenchant.
-- @param name material name
-- @param quantity how many
-- @param quality material quality
-- @return the loot table
local function Mat(name, quantity, quality)
    return { name = name, link = "|Hitem:9|h[" .. name .. "]|h", quantity = quantity, quality = quality or 1 }
end

-- Saved data
do
    local db = S.EnsureStats({})
    Check("empty saved data gets an empty record", db.stats.total == 0 and #db.history == 0
        and next(db.stats.mats) == nil and db.stats.first == nil)
    db = S.EnsureStats({ stats = { total = "lots", byQuality = 5 }, history = "broken" })
    Check("damaged stats are repaired", db.stats.total == 0 and type(db.stats.byQuality) == "table"
        and type(db.history) == "table")
    db = S.EnsureStats({ history = { { name = "ok", time = 1 }, "junk", { time = "x" } } })
    Check("damaged history entries are dropped", #db.history == 1 and db.history[1].name == "ok")
end

-- Recording
do
    local db = S.EnsureStats({})
    local session = { unmade = 0 }
    local entry = S.Record(db, session, Unmade(1, "Linen Boots", 2, 13), DAY1)
    Check("one record counts lifetime, session and today", db.stats.total == 1 and session.unmade == 1
        and S.CountOnDay(db, DAY1) == 1)
    Check("it counts by quality", db.stats.byQuality[2] == 1)
    Check("the first disenchant's time is kept", db.stats.first == DAY1)
    Check("the history entry has the item, the character and the time", entry.name == "Linen Boots"
        and entry.character == "Tester" and entry.time == DAY1 and db.history[1] == entry)

    S.AddLoot(db, entry, { Mat("Strange Dust", 2), Mat("Lesser Magic Essence", 1, 2) })
    Check("loot is added to the entry", #entry.mats == 2 and entry.mats[1].quantity == 2)
    Check("and to the lifetime materials", db.stats.mats["Strange Dust"].count == 2
        and db.stats.mats["Lesser Magic Essence"].count == 1)
    S.AddLoot(db, entry, { Mat("Strange Dust", 5) })
    Check("an entry takes loot only once", db.stats.mats["Strange Dust"].count == 2)

    S.Record(db, session, Unmade(1, "Linen Boots", 2, 13), DAY2)
    local second = S.Record(db, session, Unmade(2, "Ring of Fun", 3, 20), DAY2)
    S.AddLoot(db, second, { Mat("Strange Dust", 3), Mat("Small Glimmering Shard", 1, 3) })
    Check("lifetime materials add up", db.stats.mats["Strange Dust"].count == 5)
    Check("days are counted apart", S.CountOnDay(db, DAY1) == 1 and S.CountOnDay(db, DAY2) == 2)
    Check("the session's best count is kept", db.stats.bestSession == 3)
    Check("the best item is the highest quality, then item level", db.stats.best.name == "Ring of Fun")
end

-- History length
do
    local db = S.EnsureStats({})
    local session = { unmade = 0 }
    for i = 1, S.HISTORY_MAX + 5 do
        S.Record(db, session, Unmade(i, "Item " .. i, 2, 10), DAY1 + i)
    end
    Check("history keeps only the newest entries", #db.history == S.HISTORY_MAX
        and db.history[#db.history].name == "Item " .. (S.HISTORY_MAX + 5) and db.history[1].name == "Item 6")
    Check("but lifetime totals count everything", db.stats.total == S.HISTORY_MAX + 5)
end

-- Fun facts
do
    local db = S.EnsureStats({})
    local session = { unmade = 0 }
    for _ = 1, 3 do
        S.Record(db, session, Unmade(1, "Linen Boots", 2, 13), DAY1)
    end
    S.Record(db, session, Unmade(2, "Ring of Fun", 3, 20), DAY2)
    local facts = S.Facts(db, session, DAY2)
    local byLabel = {}
    for _, fact in ipairs(facts) do
        byLabel[fact.label] = fact.value
    end
    Check("facts list lifetime, today and this session", byLabel["Lifetime"] == "4"
        and byLabel["Today"] == "1" and byLabel["This session"] == "4")
    Check("facts split by quality", byLabel["Uncommon"] == "3" and byLabel["Rare"] == "1"
        and byLabel["Epic"] == "0")
    Check("the most-unmade item shows with its count", byLabel["Most unmade"]:find("Linen Boots", 1, true) ~= nil
        and byLabel["Most unmade"]:find("x3", 1, true) ~= nil)
    Check("the busiest day shows with its count", byLabel["Busiest day"]:find("3", 1, true) ~= nil)
    Check("the first disenchant has a date", byLabel["First"] ~= nil and byLabel["First"] ~= "")
    Check("the best item is listed", byLabel["Best item"]:find("Ring of Fun", 1, true) ~= nil)
    local empty = S.Facts(S.EnsureStats({}), { unmade = 0 }, DAY1)
    Check("with nothing recorded, facts show dashes, not errors", #empty > 0)
end

-- Materials list
do
    local db = S.EnsureStats({})
    local session = { unmade = 0 }
    local entry = S.Record(db, session, Unmade(1, "Linen Boots", 2, 13), DAY1)
    S.AddLoot(db, entry, { Mat("Strange Dust", 4), Mat("Shard", 1, 3), Mat("Essence", 2, 2) })
    local mats = S.Materials(db)
    Check("materials are listed most first", mats[1].name == "Strange Dust" and mats[1].count == 4
        and mats[3].name == "Shard")
    Check("a history entry's loot reads as short text", S.LootText(entry):find("4 Strange Dust", 1, true) ~= nil)
    Check("an entry with no loot yet reads as a dash", S.LootText({}) == "-")
end

-- Sorting history
do
    local history = {
        { name = "B", quality = 2, level = 30, time = 3 },
        { name = "A", quality = 4, level = 10, time = 1 },
        { name = "C", quality = 3, level = 20, time = 2 },
    }
    local sorted = S.SortHistory(history, "time")
    Check("history sorts newest first by default", sorted[1].time == 3 and sorted[3].time == 1)
    Check("sorting makes a new list and leaves history alone", history[1].name == "B" and sorted ~= history)
    Check("by name, A to Z", S.SortHistory(history, "name")[1].name == "A")
    Check("by quality, best first", S.SortHistory(history, "quality")[1].quality == 4)
    Check("by item level, highest first", S.SortHistory(history, "level")[1].level == 30)
    Check("an unknown key sorts by time", S.SortHistory(history, "colour")[1].time == 3)
    local same = { { name = "Older", time = 5 }, { name = "Newer", time = 5 } }
    Check("two entries in the same second: the later one counts as newer",
        S.SortHistory(same, "time")[1].name == "Newer")
    Check("ties on the other keys also put the later one first",
        S.SortHistory({ { name = "X", level = 1, time = 5 }, { name = "Y", level = 1, time = 5 } }, "level")[1].name == "Y")
end

if failed > 0 then
    io.write(string.format("%d failed\n", failed))
    os.exit(1)
end
io.write("all passed\n")
