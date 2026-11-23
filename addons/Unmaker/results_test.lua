--[[
Offline checks for UnmakerResults. The game does not load this file.
Run: lua5.1 results_test.lua
]]

local folder = arg[0]:match("^(.*)/") or "."
local D = dofile(folder .. "/UnmakerResults.lua")

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

local ARMOR, WEAPON = 4, 2

--- The result for one material in a prediction, by its English name.
-- @param prediction from D.Predict
-- @param name the material's name
-- @return the result, or nil
local function Result(prediction, name)
    for _, result in ipairs(prediction.results) do
        if result.name == name then
            return result
        end
    end
end

--- True when a result has this chance and count range.
-- @param result one result
-- @param pct the percent
-- @param low the fewest
-- @param high the most
-- @return true when it matches
local function Is(result, pct, low, high)
    return result ~= nil and result.pct == pct and result.min == low and result.max == high
end

do
    -- The guide table (warcraft.wiki.gg): greens by armor or weapon, blues, epics.
    local p = D.Predict({ quality = 2, classID = ARMOR, level = 13 })
    Check("green armor 5-15: mostly dust", p.source == "guide" and #p.results == 2
        and Is(Result(p, "Strange Dust"), 80, 1, 2) and Is(Result(p, "Lesser Magic Essence"), 20, 1, 2))
    Check("most likely first", p.results[1].name == "Strange Dust")
    p = D.Predict({ quality = 2, classID = WEAPON, level = 13 })
    Check("green weapon 6-15: mostly essence", p.results[1].name == "Lesser Magic Essence"
        and Is(p.results[1], 80, 1, 2) and Is(Result(p, "Strange Dust"), 20, 1, 2))
    p = D.Predict({ quality = 2, classID = ARMOR, level = 18 })
    Check("green armor 16-20: a shard sometimes", Is(Result(p, "Strange Dust"), 75, 2, 3)
        and Is(Result(p, "Greater Magic Essence"), 20, 1, 2) and Is(Result(p, "Small Glimmering Shard"), 5, 1, 1))
    p = D.Predict({ quality = 2, classID = WEAPON, level = 58 })
    Check("green weapon 56-60", Is(Result(p, "Greater Eternal Essence"), 75, 1, 2)
        and Is(Result(p, "Illusion Dust"), 22, 1, 2) and Is(Result(p, "Large Brilliant Shard"), 3, 1, 1))
    p = D.Predict({ quality = 3, classID = ARMOR, level = 33 })
    Check("blue 31-35: one shard", p.source == "guide" and #p.results == 1
        and Is(Result(p, "Small Glowing Shard"), 100, 1, 1))
    p = D.Predict({ quality = 3, classID = WEAPON, level = 60 })
    Check("blue 56-65: a shard, or now and then a Nexus Crystal", Is(Result(p, "Large Brilliant Shard"), 99.5, 1, 1)
        and Is(Result(p, "Nexus Crystal"), 0.5, 1, 1))
    p = D.Predict({ quality = 4, classID = ARMOR, level = 48 })
    Check("epic 46-50: 2-4 shards", Is(Result(p, "Large Radiant Shard"), 100, 2, 4))
    p = D.Predict({ quality = 4, classID = WEAPON, level = 70 })
    Check("epic 61-88: 1-2 Nexus Crystals", Is(Result(p, "Nexus Crystal"), 100, 1, 2))

    Check("no row: nothing guessed", D.Predict({ quality = 2, classID = ARMOR, level = 3 }) == nil
        and D.Predict({ quality = 2, classID = ARMOR, level = 70 }) == nil
        and D.Predict({ quality = 4, classID = ARMOR, level = 30 }) == nil
        and D.Predict({ quality = 1, classID = ARMOR, level = 20 }) == nil
        and D.Predict({ quality = 2, classID = 19, level = 20 }) == nil
        and D.Predict({ quality = 2, classID = ARMOR }) == nil)
end

do
    -- Forever's own rules: blues below item level 20, and green weapons 21-30.
    local p = D.Predict({ quality = 3, classID = WEAPON, level = 18 })
    Check("Forever blue weapon below 20: like a green, one more of each", p.source == "forever"
        and Is(Result(p, "Greater Magic Essence"), 75, 2, 3) and Is(Result(p, "Strange Dust"), 20, 3, 4)
        and Is(Result(p, "Small Glimmering Shard"), 5, 1, 1))
    p = D.Predict({ quality = 3, classID = ARMOR, level = 10 })
    Check("Forever blue armor 5-15", Is(Result(p, "Strange Dust"), 80, 2, 3)
        and Is(Result(p, "Lesser Magic Essence"), 20, 2, 3))
    Check("blue weapons below 16: no source, so no guess", D.Predict({ quality = 3, classID = WEAPON, level = 5 }) == nil
        and D.Predict({ quality = 3, classID = WEAPON, level = 15 }) == nil)
    p = D.Predict({ quality = 3, classID = ARMOR, level = 20 })
    Check("Forever blue from 20: a shard, as in the guide", p.source == "guide"
        and Is(Result(p, "Small Glimmering Shard"), 100, 1, 1))
    p = D.Predict({ quality = 2, classID = WEAPON, level = 23 })
    Check("Forever green weapon 21-25: Greater Magic Essence, not astral", p.source == "forever"
        and Is(Result(p, "Greater Magic Essence"), 75, 1, 2) and Result(p, "Lesser Astral Essence") == nil
        and Is(Result(p, "Strange Dust"), 15, 4, 6) and Is(Result(p, "Small Glimmering Shard"), 10, 1, 1))
    p = D.Predict({ quality = 2, classID = WEAPON, level = 28 })
    Check("and 26-30", Is(Result(p, "Greater Magic Essence"), 75, 1, 2) and Result(p, "Greater Astral Essence") == nil)
    p = D.Predict({ quality = 2, classID = ARMOR, level = 23 })
    Check("green armor 21-25 keeps the guide's astral essence", p.source == "guide"
        and Is(Result(p, "Lesser Astral Essence"), 15, 1, 2))
end

do
    -- The player's own results take over at 5 disenchants of that kind of item.
    local kinds = { [1] = ARMOR, [2] = ARMOR, [3] = WEAPON, [9] = 15 }
    --- One history entry with its loot.
    local function Entry(itemID, quality, level, mats, looted)
        return { itemID = itemID, quality = quality, level = level, mats = mats, looted = looted ~= false }
    end
    local dust = function(n) return { name = "Strange Dust", link = "|Hitem:10940|h[Strange Dust]|h", quantity = n } end
    local essence = function(n) return { name = "Lesser Magic Essence", quantity = n } end
    local history = {
        Entry(1, 2, 13, { dust(1) }), Entry(1, 2, 13, { dust(2) }), Entry(2, 2, 14, { dust(2) }),
        Entry(2, 2, 11, { essence(2) }),
        Entry(3, 2, 13, { essence(1) }), -- a weapon: its own group
        Entry(9, 2, 13, { dust(1) }), -- not armor or weapon: left out
        Entry(1, 2, 13, {}, false), -- loot never seen: left out
        Entry(1, 2, 18, { dust(3) }), -- 16-20: another group
    }
    local tally = D.Tally(history, function(itemID) return kinds[itemID] end)
    local p = D.Predict({ quality = 2, classID = ARMOR, level = 12 }, tally)
    Check("under 5 of yours: the guide, saying how many of yours there are", p.source == "guide" and p.yours == 4)
    history[#history + 1] = Entry(2, 2, 15, { dust(1), essence(1) })
    tally = D.Tally(history, function(itemID) return kinds[itemID] end)
    p = D.Predict({ quality = 2, classID = ARMOR, level = 12 }, tally)
    Check("5 of yours: your results", p.source == "yours" and p.count == 5)
    Check("yours: how often each came, and how many", Is(Result(p, "Strange Dust"), 80, 1, 2)
        and Is(Result(p, "Lesser Magic Essence"), 40, 1, 2) and p.results[1].name == "Strange Dust")
    Check("yours keep the loot's link for the icon", Result(p, "Strange Dust").link ~= nil)
    p = D.Predict({ quality = 2, classID = WEAPON, level = 12 }, tally)
    Check("weapons are counted apart from armor", p.source == "guide" and p.yours == 1)
    p = D.Predict({ quality = 3, classID = 19, level = 12 }, tally)
    Check("no guide and none of yours: nothing", p == nil)

    for _ = 1, 5 do
        history[#history + 1] = Entry(4, 3, 18, { { name = "Greater Magic Essence", quantity = 3 } })
    end
    kinds[4] = WEAPON
    tally = D.Tally(history, function(itemID) return kinds[itemID] end)
    p = D.Predict({ quality = 3, classID = WEAPON, level = 17 }, tally)
    Check("Forever blues have their own groups", p.source == "yours" and Is(Result(p, "Greater Magic Essence"), 100, 3, 3))
    p = D.Predict({ quality = 3, classID = WEAPON, level = 70 }, tally)
    Check("past the guide: 5-level groups of your own", p == nil)
    for _ = 1, 5 do
        history[#history + 1] = Entry(4, 3, 6, { { name = "Lesser Magic Essence", quantity = 2 } })
    end
    tally = D.Tally(history, function(itemID) return kinds[itemID] end)
    p = D.Predict({ quality = 3, classID = WEAPON, level = 14 }, tally)
    Check("blue weapons 5-15 group together, so your own results show", p.source == "yours" and p.count == 5)
    for _ = 1, 5 do
        history[#history + 1] = Entry(4, 3, 71, { { name = "Large Brilliant Shard", quantity = 1 } })
    end
    tally = D.Tally(history, function(itemID) return kinds[itemID] end)
    p = D.Predict({ quality = 3, classID = WEAPON, level = 74 }, tally)
    Check("past the guide, yours show once you have 5", p.source == "yours" and p.count == 5)
end

do
    -- Text for the tooltip and the Items column.
    local p = D.Predict({ quality = 2, classID = ARMOR, level = 18 })
    local icons = { [10940] = 132857, [10939] = 132858 }
    local lines = D.TooltipLines(p, function(result) return icons[result.id] end)
    Check("tooltip: two lines, a title with its source and the materials", #lines == 2
        and lines[1].left == "Disenchants into" and lines[1].right == "Guide")
    Check("tooltip: icons with chance and count, a name where there's no icon, no count for one",
        lines[2].left == "|T132857:0|t 75% (2-3)   |T132858:0|t 20% (1-2)   Small Glimmering Shard 5%")
    lines = D.TooltipLines(D.Predict({ quality = 3, classID = WEAPON, level = 18 }))
    Check("tooltip: Forever's own rule says so", lines[1].right == "Forever rule")
    Check("tooltip: without icons, names", lines[2].left:find("Greater Magic Essence 75% (2-3)", 1, true) == 1)
    Check("tooltip: a fixed count shows once", D.TooltipLines({ source = "yours", count = 7,
        results = { { name = "Dust", pct = 100, min = 3, max = 3 } } })[2].left == "Dust 100% (3)")
    Check("tooltip: your own results say how many", D.TooltipLines({ source = "yours", count = 7,
        results = {} })[1].right == "From 7 of yours")
    Check("tooltip: the guide says how many of yours so far", D.TooltipLines({ source = "guide", yours = 2,
        results = {} })[1].right == "Guide (yours: 2 of 5)")
    Check("tooltip: none without a prediction", D.TooltipLines(nil) == nil)
    Check("percent text: whole, or one decimal under 1", D.PercentText(80) == "80%" and D.PercentText(0.5) == "0.5%"
        and D.PercentText(99.5) == "99.5%" and D.PercentText(33.333) == "33%")
    Check("materials have their item IDs for icons", D.MATERIALS.strangeDust.id == 10940
        and D.MATERIALS.nexusCrystal.id == 20725)
end

if failed > 0 then
    io.write(string.format("%d failed\n", failed))
    os.exit(1)
end
io.write("all passed\n")
