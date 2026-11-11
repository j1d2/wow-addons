--[[
Offline checks for UnmakerRules. The game does not load this file.
Run: lua5.1 rules_test.lua
]]

local folder = arg[0]:match("^(.*)/") or "."
dofile(folder .. "/UnmakerRules.lua")

local R = UnmakerRules
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

--- A bag item as Unmaker.lua reads it, with fields overridden by `fields`.
-- Defaults to an unbound Uncommon chest piece in bag 0, slot 1.
-- @param fields table of fields to change
-- @return the item table
local function Item(fields)
    local item = {
        bag = 0, slot = 1, itemID = 100, link = "|Hitem:100|h[Green Vest]|h", name = "Green Vest",
        quality = 2, classID = 4, equipLoc = "INVTYPE_CHEST", cosmetic = false, bound = false,
        level = 20, icon = 1,
    }
    for key, value in pairs(fields or {}) do
        item[key] = value
    end
    return item
end

-- Saved data
do
    local db = R.EnsureDB(nil)
    Check("missing saved data gets every default", db.version == R.DB_VERSION and db.settings.keepEpics == true
        and db.settings.keepSoulbound == true and db.settings.hideSetItems == true
        and db.settings.openOnLoot == false and db.settings.openOnBags == false and next(db.kept) == nil)
    db = R.EnsureDB({ settings = { keepEpics = false, openOnLoot = "yes" }, kept = "broken" })
    Check("a saved choice is kept and a damaged value goes back to its default",
        db.settings.keepEpics == false and db.settings.openOnLoot == false and type(db.kept) == "table")
    db = R.EnsureDB({ kept = { [100] = true, bad = true, [200] = "no" } })
    Check("only item IDs marked true stay on the keep list", db.kept[100] == true and db.kept.bad == nil
        and db.kept[200] == nil)
end

-- What can be disenchanted
do
    Check("Uncommon armor can be disenchanted", R.CanDisenchant(Item()))
    Check("Rare weapons can be disenchanted", R.CanDisenchant(Item({ quality = 3, classID = 2,
        equipLoc = "INVTYPE_WEAPON" })))
    Check("Epic profession gear can be disenchanted", R.CanDisenchant(Item({ quality = 4, classID = 19,
        equipLoc = "" })))
    local ok, why = R.CanDisenchant(Item({ quality = 1 }))
    Check("Common items can't", not ok and why == "quality")
    ok, why = R.CanDisenchant(Item({ quality = 5 }))
    Check("Legendary items can't", not ok and why == "quality")
    ok, why = R.CanDisenchant(Item({ classID = 0, equipLoc = "" }))
    Check("potions and other consumables can't", not ok and why == "class")
    ok, why = R.CanDisenchant(Item({ equipLoc = "INVTYPE_BODY" }))
    Check("shirts can't", not ok and why == "slot")
    ok, why = R.CanDisenchant(Item({ equipLoc = "INVTYPE_TABARD" }))
    Check("tabards can't", not ok and why == "slot")
    ok, why = R.CanDisenchant(Item({ cosmetic = true }))
    Check("cosmetic items can't", not ok and why == "cosmetic")
    local unknown = Item()
    unknown.quality = nil -- a nil field can't be passed through Item(), so clear it here
    ok, why = R.CanDisenchant(unknown)
    Check("an item with no data yet is left out", not ok and why == "unknown")
end

-- Which items start checked
do
    local db = R.EnsureDB(nil)
    Check("an Uncommon item starts checked", R.StartsChecked(Item(), db))
    local checked, why = R.StartsChecked(Item({ quality = 4 }), db)
    Check("an Epic starts unchecked while Keep epics is on", not checked and why == "epic")
    checked, why = R.StartsChecked(Item({ bound = true }), db)
    Check("soulbound gear starts unchecked while Keep soulbound is on", not checked and why == "soulbound")
    db.kept[100] = true
    checked, why = R.StartsChecked(Item(), db)
    Check("an item you unchecked before starts unchecked", not checked and why == "kept")
    db = R.EnsureDB({ settings = { keepEpics = false, keepSoulbound = false } })
    Check("with both settings off, Epic soulbound gear starts checked",
        R.StartsChecked(Item({ quality = 4, bound = true }), db))
end

-- Building the list
do
    local db = R.EnsureDB(nil)
    local session = R.NewSession()
    local items = {
        Item({ bag = 0, slot = 1, itemID = 1, name = "Zeta Boots", quality = 2 }),
        Item({ bag = 0, slot = 2, itemID = 2, name = "Alpha Ring", quality = 3, equipLoc = "INVTYPE_FINGER" }),
        Item({ bag = 1, slot = 1, itemID = 3, name = "Potion", quality = 1, classID = 0, equipLoc = "" }),
        Item({ bag = 1, slot = 2, itemID = 4, name = "Set Helm", quality = 2, equipLoc = "INVTYPE_HEAD" }),
        Item({ bag = 1, slot = 3, itemID = 5, name = "Big Axe", quality = 4, classID = 2, equipLoc = "INVTYPE_2HWEAPON" }),
    }
    local rows = R.BuildRows(items, db, session, { [4] = true })
    Check("the list holds only items that can be disenchanted, without set items", #rows == 3)
    Check("rows are sorted by quality, best first, then by name", rows[1].name == "Big Axe"
        and rows[2].name == "Alpha Ring" and rows[3].name == "Zeta Boots")
    Check("each row knows whether it is checked", rows[1].checked == false and rows[2].checked == true
        and rows[3].checked == true)
    db.settings.hideSetItems = false
    rows = R.BuildRows(items, db, session, { [4] = true })
    Check("set items show when Hide set items is off", #rows == 4)

    session.refused["0:2"] = "|Hitem:100|h[Green Vest]|h"
    rows = R.BuildRows(items, db, session, {})
    local names = {}
    for _, row in ipairs(rows) do
        names[row.name] = true
    end
    Check("an item the game refused stays off the list this session", not names["Alpha Ring"])
end

-- Checking and unchecking
do
    local db = R.EnsureDB(nil)
    local session = R.NewSession()
    R.SetChecked(db, session, Item({ itemID = 7 }), false)
    Check("unchecking puts the item on the saved keep list", db.kept[7] == true)
    Check("and it shows unchecked", not R.IsChecked(Item({ itemID = 7 }), db, session))
    R.SetChecked(db, session, Item({ itemID = 7 }), true)
    Check("checking it again takes it off the keep list", db.kept[7] == nil
        and R.IsChecked(Item({ itemID = 7 }), db, session))
    R.SetChecked(db, session, Item({ itemID = 8, quality = 4 }), true)
    Check("checking an Epic lasts this session only", R.IsChecked(Item({ itemID = 8, quality = 4 }), db, session)
        and not R.IsChecked(Item({ itemID = 8, quality = 4 }), db, R.NewSession()))
end

-- The next item and counts
do
    local rows = {
        { name = "A", checked = false },
        { name = "B", checked = true },
        { name = "C", checked = true },
    }
    Check("the next item is the first checked row", R.NextRow(rows).name == "B")
    Check("the count is the number of checked rows", R.CountChecked(rows) == 2)
    Check("no checked rows means no next item", R.NextRow({ { checked = false } }) == nil
        and R.CountChecked({}) == 0)
end

-- The item must still be the same before a cast
do
    local row = { itemID = 100, link = "|Hitem:100|h[Green Vest]|h" }
    Check("the same item in the slot matches", R.SameItem(row, { itemID = 100,
        hyperlink = "|Hitem:100|h[Green Vest]|h" }))
    Check("a different item in the slot doesn't", not R.SameItem(row, { itemID = 101,
        hyperlink = "|Hitem:101|h[Other]|h" }))
    Check("the same item ID with other stats doesn't", not R.SameItem(row, { itemID = 100,
        hyperlink = "|Hitem:100::::::5|h[Green Vest of the Bear]|h" }))
    Check("an empty slot doesn't", not R.SameItem(row, nil))
end

-- Settings
do
    local db = R.EnsureDB(nil)
    Check("a known setting changes", R.SetSetting(db, "openOnBags", true) and db.settings.openOnBags == true)
    Check("an unknown setting is refused", not R.SetSetting(db, "castFaster", true) and db.settings.castFaster == nil)
    Check("a setting only takes true or false", not R.SetSetting(db, "keepEpics", "no")
        and db.settings.keepEpics == true)
    Check("settings are listed in a fixed order for the Settings tab", #R.SETTINGS == 5
        and R.SETTINGS[1].key == "keepEpics")
end

if failed > 0 then
    io.write(string.format("%d failed\n", failed))
    os.exit(1)
end
io.write("all passed\n")
