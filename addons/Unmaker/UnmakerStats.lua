--[[
UnmakerStats: lifetime totals, fun facts and history for Unmaker, with no game API calls, so it
runs under plain lua5.1 for tests. Unmaker.lua records each disenchant done through its buttons
and the loot that came from it; this file keeps the numbers.

Saved in UnmakerDB, shared by every character on the account:
  stats   = { total, byQuality, mats, items, days, first, best, bestSession }
  history = list of { itemID, name, link, quality, level, character, time, mats }, oldest first
]]

local S = {}
_G.UnmakerStats = S

-- History keeps the newest entries only, so the saved file stays small. Totals count everything.
S.HISTORY_MAX = 500

local QUALITY_NAMES = { [2] = "Uncommon", [3] = "Rare", [4] = "Epic" }

--- Format a time with the game's date function, or Lua's when testing offline.
-- @param format a date format string, such as "%Y-%m-%d"
-- @param seconds a time() value
-- @return the formatted text
local function FormatTime(format, seconds)
    if type(date) == "function" then
        return date(format, seconds)
    end
    return os.date(format, seconds)
end

--- The local calendar day of a time, as a number like 20261112.
-- @param seconds a time() value
-- @return the day key
local function DayKey(seconds)
    return tonumber(FormatTime("%Y%m%d", seconds))
end

--- Make the stats and history usable: fill in anything missing, replace damaged values, and drop
-- damaged history entries.
-- @param db the UnmakerDB table, changed in place
-- @return the same table
function S.EnsureStats(db)
    if type(db.stats) ~= "table" then
        db.stats = {}
    end
    local stats = db.stats
    if type(stats.total) ~= "number" then
        stats.total = 0
    end
    if type(stats.bestSession) ~= "number" then
        stats.bestSession = 0
    end
    for _, key in ipairs({ "byQuality", "mats", "items", "days" }) do
        if type(stats[key]) ~= "table" then
            stats[key] = {}
        end
    end
    if type(stats.first) ~= "number" then
        stats.first = nil
    end
    if type(stats.best) ~= "table" then
        stats.best = nil
    end
    local history = {}
    if type(db.history) == "table" then
        for _, entry in ipairs(db.history) do
            if type(entry) == "table" and type(entry.time) == "number" then
                history[#history + 1] = entry
            end
        end
    end
    db.history = history
    return db
end

--- Whether one item is a better "best item" than another: higher quality, then higher level.
-- @param a an item or entry
-- @param b the current best, or nil
-- @return true when a beats b
local function Better(a, b)
    if not b then
        return true
    end
    if (a.quality or 0) ~= (b.quality or 0) then
        return (a.quality or 0) > (b.quality or 0)
    end
    return (a.level or 0) > (b.level or 0)
end

--- Record one disenchant. Its loot comes later, through S.AddLoot.
-- @param db the saved data, changed in place
-- @param session this session's table, with `unmade`, changed in place
-- @param item the disenchanted item: itemID, name, link, quality, level, character
-- @param now when it happened, a time() value
-- @return the new history entry
function S.Record(db, session, item, now)
    local stats = db.stats
    session.unmade = (session.unmade or 0) + 1
    stats.total = stats.total + 1
    if item.quality then
        stats.byQuality[item.quality] = (stats.byQuality[item.quality] or 0) + 1
    end
    local seen = stats.items[item.itemID] or { name = item.name, link = item.link, count = 0 }
    seen.count = seen.count + 1
    stats.items[item.itemID] = seen
    local day = DayKey(now)
    stats.days[day] = (stats.days[day] or 0) + 1
    stats.first = stats.first or now
    stats.bestSession = math.max(stats.bestSession, session.unmade)

    local entry = {
        itemID = item.itemID, name = item.name, link = item.link, quality = item.quality,
        level = item.level, character = item.character, time = now, mats = {},
    }
    if Better(entry, stats.best) then
        stats.best = { name = entry.name, link = entry.link, quality = entry.quality, level = entry.level, time = now }
    end
    db.history[#db.history + 1] = entry
    while #db.history > S.HISTORY_MAX do
        table.remove(db.history, 1)
    end
    return entry
end

--- Add the loot from one disenchant to its history entry and the lifetime materials. An entry
-- takes loot once, so a loot window that opens twice isn't counted twice.
-- @param db the saved data, changed in place
-- @param entry the history entry from S.Record
-- @param loot list of { name, link, quantity, quality }
function S.AddLoot(db, entry, loot)
    if entry.looted then
        return
    end
    entry.looted = true
    entry.mats = {}
    for _, mat in ipairs(loot) do
        if type(mat.name) == "string" and type(mat.quantity) == "number" then
            entry.mats[#entry.mats + 1] = { name = mat.name, link = mat.link, quantity = mat.quantity,
                quality = mat.quality }
            local total = db.stats.mats[mat.name] or { count = 0, link = mat.link, quality = mat.quality }
            total.count = total.count + mat.quantity
            db.stats.mats[mat.name] = total
        end
    end
end

--- How many items were disenchanted on the day of a time.
-- @param db the saved data
-- @param seconds any time() on that day
-- @return the count
function S.CountOnDay(db, seconds)
    return db.stats.days[DayKey(seconds)] or 0
end

--- One history entry's loot as short text, such as "4 Strange Dust, 1 Small Glimmering Shard".
-- @param entry a history entry
-- @return the text, or "-" when no loot was recorded
function S.LootText(entry)
    if type(entry.mats) ~= "table" or #entry.mats == 0 then
        return "-"
    end
    local parts = {}
    for _, mat in ipairs(entry.mats) do
        parts[#parts + 1] = mat.quantity .. " " .. mat.name
    end
    return table.concat(parts, ", ")
end

--- Lifetime materials, most first.
-- @param db the saved data
-- @return list of { name, link, quality, count }
function S.Materials(db)
    local list = {}
    for name, total in pairs(db.stats.mats) do
        list[#list + 1] = { name = name, link = total.link, quality = total.quality, count = total.count }
    end
    table.sort(list, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.name < b.name
    end)
    return list
end

--- The Stats tab's lines, in order.
-- @param db the saved data
-- @param session this session's table
-- @param now the current time, for "Today"
-- @return list of { label, value } with text values
function S.Facts(db, session, now)
    local stats = db.stats
    local facts = {
        { label = "Lifetime", value = tostring(stats.total) },
        { label = "Today", value = tostring(S.CountOnDay(db, now)) },
        { label = "This session", value = tostring(session.unmade or 0) },
        { label = "Best session", value = tostring(stats.bestSession) },
    }
    for quality = 2, 4 do
        facts[#facts + 1] = { label = QUALITY_NAMES[quality], value = tostring(stats.byQuality[quality] or 0) }
    end

    local most
    for _, seen in pairs(stats.items) do
        if not most or seen.count > most.count then
            most = seen
        end
    end
    facts[#facts + 1] = { label = "Most unmade",
        value = most and ((most.link or most.name) .. " x" .. most.count) or "-" }

    local best = stats.best
    facts[#facts + 1] = { label = "Best item",
        value = best and ((best.link or best.name) .. (best.level and (" (ilvl " .. best.level .. ")") or "")) or "-" }

    local busiestKey, busiestCount
    for key, count in pairs(stats.days) do
        if not busiestCount or count > busiestCount then
            busiestKey, busiestCount = key, count
        end
    end
    facts[#facts + 1] = { label = "Busiest day", value = busiestKey
        and string.format("%04d-%02d-%02d: %d", math.floor(busiestKey / 10000), math.floor(busiestKey / 100) % 100,
            busiestKey % 100, busiestCount) or "-" }
    facts[#facts + 1] = { label = "First", value = stats.first and FormatTime("%Y-%m-%d", stats.first) or "-" }
    return facts
end

-- How each History heading sorts: the field, and whether A to Z (otherwise highest first).
local SORTS = {
    name = { field = "name", ascending = true },
    quality = { field = "quality" },
    level = { field = "level" },
    time = { field = "time" },
}

--- A sorted copy of the history. The saved list is left as it is.
-- @param history the saved history list
-- @param key "time" (newest first), "name" (A to Z), "quality" or "level" (highest first)
-- @return a new list
function S.SortHistory(history, key)
    local sort = SORTS[key] or SORTS.time
    local copy, order = {}, {}
    for index, entry in ipairs(history) do
        copy[index] = entry
        order[entry] = index
    end
    -- Ties go to the newer entry: the later time, then the one recorded later.
    table.sort(copy, function(a, b)
        local va, vb = a[sort.field], b[sort.field]
        if sort.ascending then
            va, vb = va or "", vb or ""
        else
            va, vb = va or 0, vb or 0
        end
        if va ~= vb then
            if sort.ascending then
                return va < vb
            end
            return va > vb
        end
        if a.time ~= b.time then
            return a.time > b.time
        end
        return order[a] > order[b]
    end)
    return copy
end
