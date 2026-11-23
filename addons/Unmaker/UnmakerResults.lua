--[[
UnmakerResults: what an item disenchants into, and how likely each material is. Pure data and
logic with no game API calls, so it runs under plain lua5.1 for tests.

The game doesn't tell addons what a disenchant gives; the server rolls it. So the chances come
from, in order:
1. The player's own results: Unmaker's history of disenchants and their loot, once it holds
   YOURS_MIN of the same kind of item (quality, armor or weapon, item-level band).
2. Forever's own rules, where Forever differs from the published tables: blues below item
   level 20 disenchant like a green of their band with one more of each dust and essence, and
   green weapons from item level 21 to 30 give Greater Magic Essence. These come from what the
   game's players and other tools report for Forever, and match this addon's own results so far.
3. The published tables: warcraft.wiki.gg, "Disenchanting tables" (CC BY-SA 4.0), item levels
   5 to 65 for greens and blues and 40 to 88 for epics, the range Forever's items use.

Items here are plain tables: { quality, classID, level }. History entries are Unmaker's
(UnmakerStats): { itemID, quality, level, looted, mats = { { name, link, quantity }, ... } }.
]]

-- The game hands each addon file its name and the addon's own table; Unmaker.lua reads this
-- module as ns.Results. Offline (lua5.1 and dofile) there is no table, and dofile returns the
-- module instead (the return at the end).
local _, ns = ...
local D = {}
if type(ns) == "table" then
    ns.Results = D
end

-- Disenchants of one kind before the player's own results replace the tables.
D.YOURS_MIN = 5

local UNCOMMON, RARE, EPIC = 2, 3, 4
local WEAPON, ARMOR = 2, 4
-- Blues below this item level follow Forever's own rule (see the top of the file).
local FOREVER_BLUE_BELOW = 20
-- Past the tables, the player's own results are grouped in bands this many levels wide.
local OWN_BAND_WIDTH = 5

--- Every material the tables name: its item ID (checked against Forever's auction house) and
-- its English name, shown until the game has the item's own name.
D.MATERIALS = {
    strangeDust = { id = 10940, name = "Strange Dust" },
    soulDust = { id = 11083, name = "Soul Dust" },
    visionDust = { id = 11137, name = "Vision Dust" },
    dreamDust = { id = 11176, name = "Dream Dust" },
    illusionDust = { id = 16204, name = "Illusion Dust" },
    lesserMagic = { id = 10938, name = "Lesser Magic Essence" },
    greaterMagic = { id = 10939, name = "Greater Magic Essence" },
    lesserAstral = { id = 10998, name = "Lesser Astral Essence" },
    greaterAstral = { id = 11082, name = "Greater Astral Essence" },
    lesserMystic = { id = 11134, name = "Lesser Mystic Essence" },
    greaterMystic = { id = 11135, name = "Greater Mystic Essence" },
    lesserNether = { id = 11174, name = "Lesser Nether Essence" },
    greaterNether = { id = 11175, name = "Greater Nether Essence" },
    lesserEternal = { id = 16202, name = "Lesser Eternal Essence" },
    greaterEternal = { id = 16203, name = "Greater Eternal Essence" },
    smallGlimmering = { id = 10978, name = "Small Glimmering Shard" },
    largeGlimmering = { id = 11084, name = "Large Glimmering Shard" },
    smallGlowing = { id = 11138, name = "Small Glowing Shard" },
    largeGlowing = { id = 11139, name = "Large Glowing Shard" },
    smallRadiant = { id = 11177, name = "Small Radiant Shard" },
    largeRadiant = { id = 11178, name = "Large Radiant Shard" },
    smallBrilliant = { id = 14343, name = "Small Brilliant Shard" },
    largeBrilliant = { id = 14344, name = "Large Brilliant Shard" },
    nexusCrystal = { id = 20725, name = "Nexus Crystal" },
}

-- The published tables (warcraft.wiki.gg). A row: { lowest item level, highest, then one
-- { material, percent, fewest, most } per result }. Each row's first result is its dust, the
-- second its essence, the third its shard.
local GREEN_ARMOR = {
    { 5, 15, { "strangeDust", 80, 1, 2 }, { "lesserMagic", 20, 1, 2 } },
    { 16, 20, { "strangeDust", 75, 2, 3 }, { "greaterMagic", 20, 1, 2 }, { "smallGlimmering", 5, 1, 1 } },
    { 21, 25, { "strangeDust", 75, 4, 6 }, { "lesserAstral", 15, 1, 2 }, { "smallGlimmering", 10, 1, 1 } },
    { 26, 30, { "soulDust", 75, 1, 2 }, { "greaterAstral", 20, 1, 2 }, { "largeGlimmering", 5, 1, 1 } },
    { 31, 35, { "soulDust", 75, 2, 5 }, { "lesserMystic", 20, 1, 2 }, { "smallGlowing", 5, 1, 1 } },
    { 36, 40, { "visionDust", 75, 1, 2 }, { "greaterMystic", 20, 1, 2 }, { "largeGlowing", 5, 1, 1 } },
    { 41, 45, { "visionDust", 75, 2, 5 }, { "lesserNether", 20, 1, 2 }, { "smallRadiant", 5, 1, 1 } },
    { 46, 50, { "dreamDust", 75, 1, 2 }, { "greaterNether", 20, 1, 2 }, { "largeRadiant", 5, 1, 1 } },
    { 51, 55, { "dreamDust", 75, 2, 5 }, { "lesserEternal", 20, 1, 2 }, { "smallBrilliant", 5, 1, 1 } },
    { 56, 60, { "illusionDust", 75, 1, 2 }, { "greaterEternal", 20, 1, 2 }, { "largeBrilliant", 5, 1, 1 } },
    { 61, 65, { "illusionDust", 75, 2, 5 }, { "greaterEternal", 20, 2, 3 }, { "largeBrilliant", 5, 1, 1 } },
}
local GREEN_WEAPON = {
    { 6, 15, { "strangeDust", 20, 1, 2 }, { "lesserMagic", 80, 1, 2 } },
    { 16, 20, { "strangeDust", 20, 2, 3 }, { "greaterMagic", 75, 1, 2 }, { "smallGlimmering", 5, 1, 1 } },
    { 21, 25, { "strangeDust", 15, 4, 6 }, { "lesserAstral", 75, 1, 2 }, { "smallGlimmering", 10, 1, 1 } },
    { 26, 30, { "soulDust", 20, 1, 2 }, { "greaterAstral", 75, 1, 2 }, { "largeGlimmering", 5, 1, 1 } },
    { 31, 35, { "soulDust", 20, 2, 5 }, { "lesserMystic", 75, 1, 2 }, { "smallGlowing", 5, 1, 1 } },
    { 36, 40, { "visionDust", 20, 1, 2 }, { "greaterMystic", 75, 1, 2 }, { "largeGlowing", 5, 1, 1 } },
    { 41, 45, { "visionDust", 20, 2, 5 }, { "lesserNether", 75, 1, 2 }, { "smallRadiant", 5, 1, 1 } },
    { 46, 50, { "dreamDust", 20, 1, 2 }, { "greaterNether", 75, 1, 2 }, { "largeRadiant", 5, 1, 1 } },
    { 51, 55, { "dreamDust", 22, 2, 5 }, { "lesserEternal", 75, 1, 2 }, { "smallBrilliant", 3, 1, 1 } },
    { 56, 60, { "illusionDust", 22, 1, 2 }, { "greaterEternal", 75, 1, 2 }, { "largeBrilliant", 3, 1, 1 } },
    { 61, 65, { "illusionDust", 22, 2, 5 }, { "greaterEternal", 75, 2, 3 }, { "largeBrilliant", 3, 1, 1 } },
}
-- Blues and epics: the same for armor and weapons.
local BLUE = {
    { 20, 25, { "smallGlimmering", 100, 1, 1 } },
    { 26, 30, { "largeGlimmering", 100, 1, 1 } },
    { 31, 35, { "smallGlowing", 100, 1, 1 } },
    { 36, 40, { "largeGlowing", 100, 1, 1 } },
    { 41, 45, { "smallRadiant", 100, 1, 1 } },
    { 46, 50, { "largeRadiant", 100, 1, 1 } },
    { 51, 55, { "smallBrilliant", 100, 1, 1 } },
    { 56, 65, { "largeBrilliant", 99.5, 1, 1 }, { "nexusCrystal", 0.5, 1, 1 } },
}
local EPIC_ROWS = {
    { 40, 45, { "smallRadiant", 100, 2, 4 } },
    { 46, 50, { "largeRadiant", 100, 2, 4 } },
    { 51, 55, { "smallBrilliant", 100, 2, 4 } },
    { 56, 60, { "nexusCrystal", 100, 1, 1 } },
    { 61, 88, { "nexusCrystal", 100, 1, 2 } },
}
-- Forever: green weapons in these item levels give this essence in place of the table's.
local FOREVER_WEAPON_ESSENCE = { low = 21, high = 30, material = "greaterMagic" }

--- Whether an item class is armor or a weapon, the two kinds the tables tell apart.
-- @param classID the item's class (Enum.ItemClass)
-- @return "armor", "weapon", or nil for anything else
local function Kind(classID)
    if classID == ARMOR then
        return "armor"
    elseif classID == WEAPON then
        return "weapon"
    end
end

--- The table row an item level falls in.
-- @param rows a table above
-- @param level the item level
-- @param first true to use the first row for a level just below it (a level-5 blue weapon)
-- @return the row, or nil
local function RowFor(rows, level, first)
    for _, row in ipairs(rows) do
        if level >= row[1] and level <= row[2] then
            return row
        end
    end
    if first and level >= 5 and level < rows[1][1] then
        return rows[1]
    end
end

--- Where an item's prediction comes from in the tables, and its band.
-- @param quality 2 to 4
-- @param kind "armor" or "weapon"
-- @param level the item level
-- @return the row, its source ("guide" or "forever"), the band's lowest and highest level, and
--   how the row changes ("blue" or "weapon"); or nil when no table covers it
local function TableRow(quality, kind, level)
    local greens = kind == "weapon" and GREEN_WEAPON or GREEN_ARMOR
    if quality == UNCOMMON then
        local row = RowFor(greens, level)
        if row == nil then
            return nil
        end
        local forever = kind == "weapon" and level >= FOREVER_WEAPON_ESSENCE.low and level <= FOREVER_WEAPON_ESSENCE.high
        return row, forever and "forever" or "guide", row[1], row[2], forever and "weapon" or nil
    elseif quality == RARE and level < FOREVER_BLUE_BELOW then
        local row = RowFor(greens, level, true)
        if row == nil then
            return nil
        end
        -- The band starts at 5 for weapons too, whose first green row starts at 6.
        local low = row == greens[1] and math.min(row[1], 5) or row[1]
        return row, "forever", low, math.min(row[2], FOREVER_BLUE_BELOW - 1), "blue"
    end
    local row = RowFor(quality == RARE and BLUE or EPIC_ROWS, level)
    if row == nil then
        return nil
    end
    return row, "guide", row[1], row[2]
end

--- The key that groups disenchants of the same kind: quality, armor or weapon, and band.
-- @param quality 2 to 4
-- @param kind "armor" or "weapon"
-- @param level the item level
-- @return the key, like "2:armor:5-15"
local function GroupKey(quality, kind, level)
    local _, _, low, high = TableRow(quality, kind, level)
    if low == nil then
        low = math.floor((level - 1) / OWN_BAND_WIDTH) * OWN_BAND_WIDTH + 1
        high = low + OWN_BAND_WIDTH - 1
    end
    return quality .. ":" .. kind .. ":" .. low .. "-" .. high
end

--- Sorts results most likely first, then by name.
-- @param results a list of { name, pct, ... }, sorted in place
local function SortResults(results)
    table.sort(results, function(a, b)
        if a.pct ~= b.pct then
            return a.pct > b.pct
        end
        return a.name < b.name
    end)
end

--- The tables' prediction for an item.
-- @param quality 2 to 4
-- @param kind "armor" or "weapon"
-- @param level the item level
-- @return { source, results = { { id, name, pct, min, max }, ... } }, or nil
local function FromTables(quality, kind, level)
    local row, source, _, _, change = TableRow(quality, kind, level)
    if row == nil then
        return nil
    end
    local results = {}
    for index = 3, #row do
        local material, pct, low, high = row[index][1], row[index][2], row[index][3], row[index][4]
        local isShard = index == 5
        if change == "blue" and not isShard then
            low, high = low + 1, high + 1
        elseif change == "weapon" and index == 4 then
            material = FOREVER_WEAPON_ESSENCE.material
        end
        local info = D.MATERIALS[material]
        results[#results + 1] = { id = info.id, name = info.name, pct = pct, min = low, max = high }
    end
    SortResults(results)
    return { source = source, results = results }
end

--- Counts the player's own disenchants by kind of item, from Unmaker's history. Entries whose
-- loot was never seen, and items that aren't armor or weapons, are left out.
-- @param history Unmaker's history list
-- @param classOf function(itemID) returning the item's class (the game's GetItemInfoInstant)
-- @return { [group key] = { count, mats = { [name] = { name, link, times, min, max } } } }
function D.Tally(history, classOf)
    local groups = {}
    for _, entry in ipairs(history or {}) do
        local kind = entry.looted and type(entry.level) == "number" and Kind(classOf(entry.itemID))
        if kind and type(entry.quality) == "number" then
            local key = GroupKey(entry.quality, kind, entry.level)
            local group = groups[key] or { count = 0, mats = {} }
            groups[key] = group
            group.count = group.count + 1
            for _, mat in ipairs(entry.mats or {}) do
                local seen = group.mats[mat.name] or { name = mat.name, times = 0 }
                group.mats[mat.name] = seen
                seen.link = seen.link or mat.link
                seen.times = seen.times + 1
                seen.min = math.min(seen.min or mat.quantity, mat.quantity)
                seen.max = math.max(seen.max or mat.quantity, mat.quantity)
            end
        end
    end
    return groups
end

--- What an item disenchants into: the player's own results once there are YOURS_MIN of its
-- kind, else Forever's rules or the published tables.
-- @param item { quality, classID, level }
-- @param tally from D.Tally, or nil
-- @return { source = "yours" | "forever" | "guide", count (yours), yours (how many of yours so
--   far, under YOURS_MIN), results = { { id or link, name, pct, min, max }, ... } most likely
--   first }; or nil when nothing is known
function D.Predict(item, tally)
    local kind = Kind(item.classID)
    if kind == nil or type(item.level) ~= "number" or type(item.quality) ~= "number"
        or item.quality < UNCOMMON or item.quality > EPIC then
        return nil
    end
    local group = tally and tally[GroupKey(item.quality, kind, item.level)]
    if group and group.count >= D.YOURS_MIN then
        local results = {}
        for _, seen in pairs(group.mats) do
            results[#results + 1] = { name = seen.name, link = seen.link, pct = seen.times / group.count * 100,
                min = seen.min, max = seen.max }
        end
        SortResults(results)
        return { source = "yours", count = group.count, results = results }
    end
    local prediction = FromTables(item.quality, kind, item.level)
    if prediction then
        prediction.yours = group and group.count or 0
    end
    return prediction
end

--- A percent as short text: whole numbers, or one decimal below 1 and for halves.
-- @param pct the percent
-- @return text like "80%" or "0.5%"
function D.PercentText(pct)
    local isHalf = pct * 2 == math.floor(pct * 2) and pct ~= math.floor(pct)
    if pct < 1 or isHalf then
        return string.format("%.1f%%", pct)
    end
    return math.floor(pct + 0.5) .. "%"
end

--- How many of a material, as text: "", "3" or "1-2" after the name.
-- @param result one result
-- @return the text, with a leading space, or ""
local function CountText(result)
    if result.min == 1 and result.max == 1 then
        return ""
    elseif result.min == result.max then
        return " " .. result.min
    end
    return " " .. result.min .. "-" .. result.max
end

--- The tooltip lines for a prediction.
-- @param prediction from D.Predict, or nil
-- @param nameOf optional function(result) returning the game's own name for a material
-- @return list of { left, right } (the first is the title, the last where it comes from), or nil
function D.TooltipLines(prediction, nameOf)
    if prediction == nil then
        return nil
    end
    local lines = { { left = "Disenchants into:" } }
    for _, result in ipairs(prediction.results) do
        local name = nameOf and nameOf(result) or result.name
        lines[#lines + 1] = { left = name .. CountText(result), right = D.PercentText(result.pct) }
    end
    local source
    if prediction.source == "yours" then
        source = "From " .. prediction.count .. " of your disenchants"
    elseif prediction.source == "forever" then
        source = "Forever's own results (few seen yet)"
    else
        source = "Guide: warcraft.wiki.gg"
    end
    if (prediction.yours or 0) > 0 then
        source = source .. "; " .. prediction.yours .. " of yours so far"
    end
    lines[#lines + 1] = { left = source }
    return lines
end

return D
