--[[
UnmakerRules: the pure logic behind Unmaker, with no game API calls, so it runs under plain
lua5.1 for tests. Unmaker.lua reads the bags and draws the window; this file decides which
items can be disenchanted, which start checked, and what the next one is.

Items here are plain tables that Unmaker.lua fills from the game:
  { bag, slot, itemID, link, name, quality, classID, equipLoc, cosmetic, bound, level, icon }
]]

local R = {}
_G.UnmakerRules = R

R.DB_VERSION = 1

-- Item qualities that disenchant: Uncommon (2), Rare (3) and Epic (4).
local MIN_QUALITY, MAX_QUALITY = 2, 4
local EPIC = 4

-- Item classes that disenchant: Weapon (2), Armor (4) and Profession gear (19).
local DISENCHANT_CLASSES = { [2] = true, [4] = true, [19] = true }

-- Equip slots that never disenchant, though they are armor: shirts and tabards.
local NEVER_SLOTS = { INVTYPE_BODY = true, INVTYPE_TABARD = true }

--- The Settings tab, in display order. Each entry has its saved key, its label and its
-- default.
R.SETTINGS = {
    { key = "keepEpics", label = "Keep epics (start unchecked)", default = true },
    { key = "keepSoulbound", label = "Keep soulbound gear (start unchecked)", default = true },
    { key = "hideSetItems", label = "Hide items in equipment sets", default = true },
    { key = "openOnLoot", label = "Open when I loot something to disenchant", default = false },
    { key = "openOnBags", label = "Open with my bags", default = false },
}

local SETTING_DEFAULTS = {}
for _, setting in ipairs(R.SETTINGS) do
    SETTING_DEFAULTS[setting.key] = setting.default
end

--- Make saved data usable: fill in anything missing and replace damaged values.
-- @param db the UnmakerDB table from the game, or nil on first load
-- @return the same table, repaired, or a new one
function R.EnsureDB(db)
    if type(db) ~= "table" then
        db = {}
    end
    db.version = R.DB_VERSION
    if type(db.settings) ~= "table" then
        db.settings = {}
    end
    for key, default in pairs(SETTING_DEFAULTS) do
        if type(db.settings[key]) ~= "boolean" then
            db.settings[key] = default
        end
    end
    if type(db.kept) ~= "table" then
        db.kept = {}
    end
    for itemID, flag in pairs(db.kept) do
        if type(itemID) ~= "number" or flag ~= true then
            db.kept[itemID] = nil
        end
    end
    return db
end

--- A fresh session: choices and refusals that last until logout or /reload.
-- @return { choice = { [itemID] = checked }, refused = { ["bag:slot"] = link } }
function R.NewSession()
    return { choice = {}, refused = {} }
end

--- Whether an item can be disenchanted at all. Some items the rules allow are still refused
-- by the game; Unmaker.lua then marks them refused for the session.
-- @param item an item table
-- @return true, or false and the reason: "unknown", "quality", "class", "slot" or "cosmetic"
function R.CanDisenchant(item)
    if type(item.quality) ~= "number" or type(item.classID) ~= "number" then
        return false, "unknown"
    end
    if item.quality < MIN_QUALITY or item.quality > MAX_QUALITY then
        return false, "quality"
    end
    if not DISENCHANT_CLASSES[item.classID] then
        return false, "class"
    end
    if NEVER_SLOTS[item.equipLoc] then
        return false, "slot"
    end
    if item.cosmetic then
        return false, "cosmetic"
    end
    return true
end

--- Whether an item starts checked, before the player changes it.
-- @param item an item table
-- @param db the saved data
-- @return true, or false and the reason: "kept", "epic" or "soulbound"
function R.StartsChecked(item, db)
    if db.kept[item.itemID] then
        return false, "kept"
    end
    if db.settings.keepEpics and item.quality == EPIC then
        return false, "epic"
    end
    if db.settings.keepSoulbound and item.bound then
        return false, "soulbound"
    end
    return true
end

--- Whether an item is checked now: this session's choice, or else where it starts.
-- @param item an item table
-- @param db the saved data
-- @param session the session table
-- @return true when the item is checked
function R.IsChecked(item, db, session)
    local choice = session.choice[item.itemID]
    if choice ~= nil then
        return choice
    end
    return (R.StartsChecked(item, db))
end

--- Check or uncheck an item. Unchecking also saves it as kept, so it starts unchecked next
-- time; checking takes it off that list. Checking an item the settings keep (an Epic, say)
-- lasts this session only.
-- @param db the saved data, changed in place
-- @param session the session table, changed in place
-- @param item the item table
-- @param checked true to check it
function R.SetChecked(db, session, item, checked)
    session.choice[item.itemID] = checked
    if checked then
        db.kept[item.itemID] = nil
    else
        db.kept[item.itemID] = true
    end
end

--- The key a refused bag slot is stored under.
-- @param bag bag index
-- @param slot slot index
-- @return text like "0:2"
function R.SlotKey(bag, slot)
    return bag .. ":" .. slot
end

--- Turn the bag items into the window's rows: only items that can be disenchanted, without
-- set items (when hidden) or items the game refused this session, best quality first.
-- @param items list of item tables
-- @param db the saved data
-- @param session the session table
-- @param setItemIDs set of item IDs used by an equipment set, { [itemID] = true }
-- @return list of item tables, each with `checked` added
function R.BuildRows(items, db, session, setItemIDs)
    local rows = {}
    for _, item in ipairs(items) do
        local hidden = (db.settings.hideSetItems and setItemIDs[item.itemID])
            or session.refused[R.SlotKey(item.bag, item.slot)] == item.link
        if not hidden and R.CanDisenchant(item) then
            item.checked = R.IsChecked(item, db, session)
            rows[#rows + 1] = item
        end
    end
    table.sort(rows, function(a, b)
        if a.quality ~= b.quality then
            return a.quality > b.quality
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        if a.bag ~= b.bag then
            return a.bag < b.bag
        end
        return a.slot < b.slot
    end)
    return rows
end

--- The row "Disenchant next" acts on: the first checked one.
-- @param rows the window's rows
-- @return a row, or nil when none is checked
function R.NextRow(rows)
    for _, row in ipairs(rows) do
        if row.checked then
            return row
        end
    end
    return nil
end

--- How many rows are checked.
-- @param rows the window's rows
-- @return the count
function R.CountChecked(rows)
    local count = 0
    for _, row in ipairs(rows) do
        if row.checked then
            count = count + 1
        end
    end
    return count
end

--- Whether a bag slot still holds the row's exact item, checked right before a cast.
-- The link must match too, so a different copy of the same item (other stats) doesn't count.
-- @param row the row about to be disenchanted
-- @param info what C_Container.GetContainerItemInfo returns for its slot now, or nil
-- @return true only when it is the same item
function R.SameItem(row, info)
    return type(info) == "table" and info.itemID == row.itemID and info.hyperlink == row.link
end

--- Change one setting.
-- @param db the saved data, changed in place
-- @param key a key from R.SETTINGS
-- @param value true or false
-- @return true if it changed, false for an unknown key or a value that isn't true or false
function R.SetSetting(db, key, value)
    if SETTING_DEFAULTS[key] == nil or type(value) ~= "boolean" then
        return false
    end
    db.settings[key] = value
    return true
end
