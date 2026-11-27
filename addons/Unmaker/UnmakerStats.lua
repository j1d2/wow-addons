--[[
UnmakerStats: lifetime totals, fun facts and history for Unmaker, with no game API calls, so it
runs under plain lua5.1 for tests. Unmaker.lua records each disenchant done through its buttons
and the loot that came from it; this file keeps the numbers.

Saved in UnmakerDB, shared by every character on the account, so any character can see them all:
  stats      = { total, byQuality, mats, items, days, first, best, bestSession }, every character
  characters = { ["Name-Realm"] = the same totals, for one character }
  history    = list of { itemID, name, link, quality, level, character, realm, time, mats }, oldest
               first
]]

-- Unmaker.lua reads this module as ns.Stats; offline, dofile returns it (see UnmakerRules.lua).
local _, ns = ...
local S = {}
if type(ns) == "table" then
    ns.Stats = S
end

-- How many disenchants the history keeps, newest first out: the Settings choices, the first the
-- default (saved as settings.historyMax). Lifetime totals count everything either way. 10,000
-- entries keep about 9 MB in memory (bench).
S.HISTORY_CHOICES = { 500, 1000, 5000, 10000 }

--- True for a history length the Settings tab offers.
-- @param count a value
-- @return true or false
function S.IsHistoryChoice(count)
    for _, choice in ipairs(S.HISTORY_CHOICES) do
        if count == choice then
            return true
        end
    end
    return false
end

--- How many disenchants the history keeps.
-- @param db the saved data, or nil
-- @return the saved choice, or the default
function S.HistoryMax(db)
    local saved = type(db) == "table" and type(db.settings) == "table" and db.settings.historyMax
    if S.IsHistoryChoice(saved) then
        return saved
    end
    return S.HISTORY_CHOICES[1]
end

--- Drops the oldest entries past the history length. Works in the same list (the window may
-- hold it), moving the kept entries down in one pass.
-- @param db the saved data, changed in place
local function TrimHistory(db)
    local history = db.history
    local count = #history
    local extra = count - S.HistoryMax(db)
    if extra <= 0 then
        return
    end
    for index = 1, count - extra do
        history[index] = history[index + extra]
    end
    for index = count, count - extra + 1, -1 do
        history[index] = nil
    end
end

--- Sets how many disenchants the history keeps, and saves it. A shorter length drops the
-- oldest entries right away; totals are untouched.
-- @param db the saved data, changed in place
-- @param count one of HISTORY_CHOICES; anything else changes nothing
-- @return the history length now in use
function S.SetHistoryMax(db, count)
    if type(db) ~= "table" or not S.IsHistoryChoice(count) then
        return S.HistoryMax(db)
    end
    if type(db.settings) ~= "table" then
        db.settings = {}
    end
    db.settings.historyMax = count
    if type(db.history) == "table" then
        TrimHistory(db)
    end
    return count
end

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
S.DayKey = DayKey

--- A character's key in the saved totals.
-- @param name the character's name
-- @param realm the character's realm
-- @return "Name-Realm", or nil when either is missing
function S.CharacterKey(name, realm)
    if type(name) == "string" and name ~= "" and type(realm) == "string" and realm ~= "" then
        return name .. "-" .. realm
    end
    return nil
end

-- The realm a character is filed under when the game never named one.
S.UNKNOWN_REALM = "Forever"

--- True for a realm name or surname the game really gave: a string that isn't empty.
-- @param text a value
-- @return true or false
local function IsName(text)
    return type(text) == "string" and text ~= ""
end

--- A character's full name. Forever characters have a first name and a surname, and
-- UnitName("player") gives the surname as its second value; other clients give nothing there.
-- @param name the first name
-- @param surname the surname, or nil
-- @param separator what goes between them; a space when not given
-- @return "Name Surname", or the name alone without a surname
function S.FullName(name, surname, separator)
    if IsName(name) and IsName(surname) then
        return name .. (IsName(separator) and separator or " ") .. surname
    end
    return name
end

--- The realm a character is filed under. Since the Forever client update of 2026-11-20 the game
-- can give a blank realm name; a blank one means the last realm the game did name. Before that
-- was remembered, the realm the history names, when it names just one.
-- @param db the UnmakerDB table; its homeRealm is set from a real name or the history
-- @param name what GetRealmName() returned
-- @return the realm name, or UNKNOWN_REALM when none is known
function S.RealmFor(db, name)
    if IsName(name) then
        db.homeRealm = name
        return name
    end
    if not IsName(db.homeRealm) then
        db.homeRealm = nil
        local only
        for _, entry in ipairs(type(db.history) == "table" and db.history or {}) do
            local realm = type(entry) == "table" and entry.realm
            if IsName(realm) then
                if only ~= nil and only ~= realm then
                    return S.UNKNOWN_REALM
                end
                only = realm
            end
        end
        db.homeRealm = only
    end
    return db.homeRealm or S.UNKNOWN_REALM
end

--- An entry's realm: its own, or this character's when it was saved without one or blank.
-- @param entry a history entry
-- @param realm this character's realm
-- @return the realm
local function EntryRealm(entry, realm)
    if IsName(entry.realm) then
        return entry.realm
    end
    return realm
end

--- How a character is shown: by name on this realm, as "Name-Realm" on another.
-- @param key the character's key
-- @param realm this character's realm
-- @return the text
function S.CharacterLabel(key, realm)
    local suffix = "-" .. tostring(realm)
    if key:sub(-#suffix) == suffix then
        return key:sub(1, -#suffix - 1)
    end
    return key
end

--- Make one set of totals usable: fill in anything missing and replace damaged values.
-- @param totals a totals table, or anything else on first use or when damaged
-- @return the same table, repaired, or a new one
local function EnsureTotals(totals)
    if type(totals) ~= "table" then
        totals = {}
    end
    if type(totals.total) ~= "number" then
        totals.total = 0
    end
    if type(totals.bestSession) ~= "number" then
        totals.bestSession = 0
    end
    for _, key in ipairs({ "byQuality", "mats", "items", "days" }) do
        if type(totals[key]) ~= "table" then
            totals[key] = {}
        end
    end
    if type(totals.first) ~= "number" then
        totals.first = nil
    end
    if type(totals.best) ~= "table" then
        totals.best = nil
    end
    return totals
end

--- Make the stats and history usable: fill in anything missing, replace damaged values, and drop
-- damaged history entries. Data saved before characters were counted gets per-character
-- totals rebuilt from its history, once.
-- @param db the UnmakerDB table, changed in place
-- @param realm this character's realm, for history entries saved without one
-- @return the same table
function S.EnsureStats(db, realm)
    db.stats = EnsureTotals(db.stats)
    local history = {}
    if type(db.history) == "table" then
        for _, entry in ipairs(db.history) do
            if type(entry) == "table" and type(entry.time) == "number" then
                history[#history + 1] = entry
            end
        end
    end
    db.history = history
    if type(db.settings) == "table" and db.settings.historyMax ~= nil
        and not S.IsHistoryChoice(db.settings.historyMax) then
        db.settings.historyMax = nil
    end
    TrimHistory(db)
    if type(db.characters) == "table" then
        for key, totals in pairs(db.characters) do
            if type(key) == "string" and type(totals) == "table" then
                EnsureTotals(totals)
            else
                db.characters[key] = nil
            end
        end
    else
        -- Saved before characters were counted: rebuild them once from the history.
        db.characters = S.CharactersFromHistory(history, realm)
    end
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

--- Count one disenchant in a set of totals. The session's best count is left to the caller.
-- @param totals the totals table, changed in place
-- @param entry the history entry
local function CountItem(totals, entry)
    totals.total = totals.total + 1
    if entry.quality then
        totals.byQuality[entry.quality] = (totals.byQuality[entry.quality] or 0) + 1
    end
    local seen = totals.items[entry.itemID] or { name = entry.name, link = entry.link, count = 0 }
    seen.count = seen.count + 1
    totals.items[entry.itemID] = seen
    local day = DayKey(entry.time)
    totals.days[day] = (totals.days[day] or 0) + 1
    totals.first = math.min(totals.first or entry.time, entry.time)
    if Better(entry, totals.best) then
        totals.best = { name = entry.name, link = entry.link, quality = entry.quality, level = entry.level,
            time = entry.time }
    end
end

--- Count materials in a set of totals.
-- @param totals the totals table, changed in place
-- @param mats list of { name, link, quantity, quality }
local function CountMats(totals, mats)
    for _, mat in ipairs(mats) do
        if type(mat) == "table" and type(mat.name) == "string" and type(mat.quantity) == "number" then
            local total = totals.mats[mat.name] or { count = 0, link = mat.link, quality = mat.quality }
            total.count = total.count + mat.quantity
            totals.mats[mat.name] = total
        end
    end
end

--- The totals of the character that made a history entry, created on first use.
-- @param db the saved data, changed in place
-- @param entry a history entry
-- @return the totals table, or nil when the entry has no character or realm
local function CharacterTotals(db, entry)
    local key = S.CharacterKey(entry.character, entry.realm)
    if not key then
        return nil
    end
    db.characters[key] = db.characters[key] or EnsureTotals(nil)
    return db.characters[key]
end

--- Per-character totals rebuilt from the history, for data saved before characters were
-- counted. Entries saved then have no realm, so they count for this realm. History holds only
-- the newest entries, so older disenchants count only in the account totals.
-- @param history the saved history list
-- @param realm this character's realm
-- @return { ["Name-Realm"] = totals }
function S.CharactersFromHistory(history, realm)
    local characters = {}
    for _, entry in ipairs(history) do
        local key = S.CharacterKey(entry.character, EntryRealm(entry, realm))
        if key then
            characters[key] = characters[key] or EnsureTotals(nil)
            CountItem(characters[key], entry)
            if type(entry.mats) == "table" then
                CountMats(characters[key], entry.mats)
            end
        end
    end
    return characters
end

--- Brings this character's old saved data up to its full name and realm, on each load:
-- - history entries saved under its first name alone get its full name, as long as they are
--   from this realm or have none;
-- - entries saved with a blank realm (the game gave none) get this realm, and, since a blank
--   realm kept them out of every character's totals, are counted in this character's now;
-- - totals saved under "First-Realm" move to "Full Name-Realm" when that has none yet.
-- With two characters sharing a first name, the first to log in takes the old entries.
-- @param db the saved data, from S.EnsureStats; changed in place
-- @param firstName this character's first name
-- @param fullName its full name, from S.FullName
-- @param realm its realm, from S.RealmFor
function S.Adopt(db, firstName, fullName, realm)
    if not IsName(firstName) or not IsName(fullName) or not IsName(realm) then
        return
    end
    local newKey = S.CharacterKey(fullName, realm)
    local oldKey = S.CharacterKey(firstName, realm)
    if oldKey ~= newKey and type(db.characters[oldKey]) == "table" and db.characters[newKey] == nil then
        db.characters[newKey] = db.characters[oldKey]
        db.characters[oldKey] = nil
    end
    for _, entry in ipairs(db.history) do
        local mine = entry.character == fullName or entry.character == firstName
        if mine and (entry.realm == nil or entry.realm == "" or entry.realm == realm) then
            entry.character = fullName
            if entry.realm == "" then
                entry.realm = realm
                local totals = CharacterTotals(db, entry)
                CountItem(totals, entry)
                if type(entry.mats) == "table" then
                    CountMats(totals, entry.mats)
                end
            end
        end
    end
end

--- Record one disenchant. Its loot comes later, through S.AddLoot.
-- @param db the saved data, changed in place
-- @param session this session's table, with `unmade`, changed in place
-- @param item the disenchanted item: itemID, name, link, quality, level, character, realm
-- @param now when it happened, a time() value
-- @return the new history entry
function S.Record(db, session, item, now)
    session.unmade = (session.unmade or 0) + 1
    local entry = {
        itemID = item.itemID, name = item.name, link = item.link, quality = item.quality,
        level = item.level, character = item.character, realm = item.realm, time = now, mats = {},
    }
    CountItem(db.stats, entry)
    db.stats.bestSession = math.max(db.stats.bestSession, session.unmade)
    local mine = CharacterTotals(db, entry)
    if mine then
        CountItem(mine, entry)
        mine.bestSession = math.max(mine.bestSession, session.unmade)
    end
    db.history[#db.history + 1] = entry
    TrimHistory(db)
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
        end
    end
    CountMats(db.stats, entry.mats)
    local mine = CharacterTotals(db, entry)
    if mine then
        CountMats(mine, entry.mats)
    end
end

--- The totals to show: one character's, or every character's together.
-- @param db the saved data
-- @param key a character's key, or nil for all characters
-- @return the totals table; empty totals for a character with none
local function Totals(db, key)
    if key == nil then
        return db.stats
    end
    return db.characters[key] or EnsureTotals(nil)
end

--- Every character with totals, A to Z.
-- @param db the saved data
-- @return list of character keys
function S.Characters(db)
    local keys = {}
    for key in pairs(db.characters) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

--- How many items were disenchanted on the day of a time.
-- @param db the saved data
-- @param seconds any time() on that day
-- @param key a character's key, or nil for all characters
-- @return the count
function S.CountOnDay(db, seconds, key)
    return Totals(db, key).days[DayKey(seconds)] or 0
end

--- One history entry's loot as short text, for the row's tooltip: "4 Strange Dust, 1 Small
-- Glimmering Shard".
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

--- The Stats tab's chart: disenchants per calendar day over the last 14 days, ending today.
-- @param db the saved data
-- @param now the current time
-- @param key a character's key, or nil for all characters
-- @return nil when there were none in those 14 days, or { counts, top }: counts[1] is 13 days
--   ago and counts[14] today; top is the highest count
function S.ChartDays(db, now, key)
    local days = Totals(db, key).days
    local chart = { counts = {}, top = 0 }
    for back = 13, 0, -1 do
        local count = days[DayKey(now - back * 86400)] or 0
        chart.counts[#chart.counts + 1] = count
        chart.top = math.max(chart.top, count)
    end
    if chart.top == 0 then
        return nil
    end
    return chart
end

--- Lifetime materials, most first.
-- @param db the saved data
-- @param key a character's key, or nil for all characters
-- @return list of { name, link, quality, count }
function S.Materials(db, key)
    local list = {}
    for name, total in pairs(Totals(db, key).mats) do
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
-- @param key a character's key, or nil for all characters
-- @return list of { label, value } with text values
function S.Facts(db, session, now, key)
    local stats = Totals(db, key)
    -- A session belongs to the character logged in, so another character has no session count.
    local thisSession = (key == nil or key == session.key) and tostring(session.unmade or 0) or "-"
    -- Totals rebuilt from history have disenchants but no known best session.
    local bestSession = (stats.bestSession == 0 and stats.total > 0) and "-" or tostring(stats.bestSession)
    local facts = {
        { label = "Lifetime", value = tostring(stats.total) },
        { label = "Today", value = tostring(S.CountOnDay(db, now, key)) },
        { label = "This session", value = thisSession },
        { label = "Best session", value = bestSession },
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
    -- Who unmade it, A to Z; entries with no character go last.
    who = { field = "character", ascending = true, missingLast = true },
}

--- The history entries one character made, or all of them. An entry saved before realms were
-- kept counts for this realm, as the per-character totals rebuilt from history do.
-- @param history the saved history list
-- @param key a character's key, or nil for every entry
-- @param realm this character's realm
-- @return a new list, in the same order
function S.FilterHistory(history, key, realm)
    local kept = {}
    for _, entry in ipairs(history) do
        if key == nil or S.CharacterKey(entry.character, EntryRealm(entry, realm)) == key then
            kept[#kept + 1] = entry
        end
    end
    return kept
end

--- Who made a history entry, as the History tab shows it: the name on this realm,
-- "Name-Realm" on another, "?" when not saved.
-- @param entry a history entry
-- @param realm this character's realm
-- @return the text
function S.WhoText(entry, realm)
    local key = S.CharacterKey(entry.character, EntryRealm(entry, realm))
    return key and S.CharacterLabel(key, realm) or "?"
end

--- A sorted copy of the history. The saved list is left as it is.
-- @param history the saved history list
-- @param key "time" (newest first), "name" or "who" (A to Z), "quality" or "level" (highest first)
-- @param reverse optional; true flips the direction (ties still put the newer entry first)
-- @return a new list
function S.SortHistory(history, key, reverse)
    local sort = SORTS[key] or SORTS.time
    local ascending = sort.ascending
    if reverse then
        ascending = not ascending
    end
    local copy, order = {}, {}
    for index, entry in ipairs(history) do
        copy[index] = entry
        order[entry] = index
    end
    -- Ties go to the newer entry: the later time, then the one recorded later.
    table.sort(copy, function(a, b)
        local va, vb = a[sort.field], b[sort.field]
        if sort.missingLast and (va == nil or vb == nil) and va ~= vb then
            return vb == nil
        end
        if sort.ascending then
            va, vb = va or "", vb or ""
        else
            va, vb = va or 0, vb or 0
        end
        if va ~= vb then
            if ascending then
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

return S
