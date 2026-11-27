--[[
Unmaker: a window that lists the gear in your bags you can disenchant, with a checkbox on each
item. "Disenchant next" disenchants the first checked item; "Disenchant selected" the item you
clicked. UnmakerRules.lua (ns.Rules), UnmakerStats.lua (ns.Stats) and UnmakerResults.lua
(ns.Results: what an item disenchants into) hold the logic; this file reads the bags and draws
the window, and adds the disenchant results to item tooltips.

Blizzard's rules (RULES.md, Disenchanting): every cast needs its own click or key press.
Unmaker never casts. Its two buttons are Blizzard secure buttons: on the player's click, PreClick
sets them to cast Disenchant on one bag slot, Blizzard's own code casts, and PostClick clears
them again. In combat nothing can be set, so a click then does nothing.

The secure buttons make the window protected, so in combat it can't be shown, hidden or moved;
those wait until the fight ends, as in HouseLedger.
]]

-- The rules and stats modules, shared through the addon's own table (never globals).
local _, ns = ...
local R, S, D = ns.Rules, ns.Stats, ns.Results

local DISENCHANT_SPELL = 13262
local BAGS = { 0, 1, 2, 3, 4 } -- the backpack and four bags; the reagent bag holds no gear
local ROW_COUNT = 10
local ROW_HEIGHT = 24
local WIDTH = 600
local LIST_TOP = 64 -- the Items tab starts this far below the window's top edge
-- On the Items tab: the filter row, then the column headings, then the list.
local FILTER_HEIGHT = 26
local HEADER_HEIGHT = 20
local LIST_START = LIST_TOP + FILTER_HEIGHT + HEADER_HEIGHT
local LIST_HEIGHT = ROW_COUNT * ROW_HEIGHT
-- Under the list: the count line, the status line (room for two lines of text), then the buttons.
local TEXT_HEIGHT = 56
local BUTTON_AREA = 40
local HEIGHT = LIST_START + LIST_HEIGHT + TEXT_HEIGHT + BUTTON_AREA
-- Items tab columns: their headings, and the way each first sorts when clicked (true is A to Z).
local COLUMN_LABELS = { name = "Item", ilvl = "ilvl", gives = "Gives", vendor = "Vendor" }
-- The Gives column: up to this many materials, each an icon and its chance, most likely first.
local GIVES_SHOWN, GIVES_SLOT, GIVES_ICON = 3, 46, 14
-- Items tab cells, from the row's right edge: vendor price, then Gives, then item level.
local VENDOR_RIGHT, GIVES_RIGHT, LEVEL_RIGHT, NAME_RIGHT = -4, -100, -244, -284
local SORT_FIRST_ASCENDING = { name = true, ilvl = false, vendor = false }
-- History headings that sort A to Z (the rest sort highest or newest first).
local HISTORY_ASCENDING = { name = true, who = true }
-- After a cast, wait at most this many seconds for the loot and bag news before unlocking
-- the buttons, so a missed event can't leave them stuck.
local UNLOCK_AFTER = 10
local PORTRAIT_ICON = "Interface\\Icons\\INV_Enchant_Disenchant"
-- A click's cast must start within this many seconds to count as that click's item, so a later
-- Disenchant from the spellbook is never credited to an old row.
local CLICK_WINDOW = 1
local MAT_LINES = 5 -- lifetime materials shown on the Stats tab
-- The Stats chart: right of the short fact lines, under the character dropdown, ending above
-- "Most unmade". Earlier days blue, today gold.
local CHART_WIDTH, CHART_HEIGHT, CHART_TOP = 200, 78, 28
local CHART_BAR_COLOR = { 0.35, 0.6, 1, 0.9 }
local CHART_TODAY_COLOR = { 1, 0.82, 0, 1 }

local db
local playerRealm -- this character's realm, from S.RealmFor once loaded
local playerName -- this character's full name (with its Forever surname), once loaded
local statsView -- the character the Stats tab shows (its key), or nil for all characters
local charDB -- this character's own saved data: the window's position
local session = R.NewSession()
session.unmade = 0
local allRows = {} -- every row the bags hold, for "Open when I loot"
local rows = {} -- the rows the Items tab shows: allRows through the view
local offset = 0
-- The Items tab's filters and sort, kept for the session: { maxQuality, minLevel, maxLevel,
-- sortKey, ascending }.
local view = {}
local selected
local state = "idle" -- idle, casting (the cast bar is up) or waiting (loot and bags settling)
local pending
local pendingAt -- GetTime() when PreClick set the cast up
local currentEntry -- the history entry of the cast now finishing
local earlyLoot -- loot that showed before the cast reported success
local lootOpen = false
local lootSeen = false -- a loot window opened for the current cast
local lastError -- the game's red error text during the current attempt
local awaitingReason = false -- a cast failed and its error text hasn't come yet
local bagsSettled = false
-- True while the window is open because the bags opened it ("Open with my bags"), so closing
-- the bags closes it too. Opening or closing it any other way clears it.
local openedWithBags = false
local waited = 0
local seenLinks
local wanted = {} -- show or hide asked for in combat: { shown = true/false }
local built = false
local currentTab = 1

local frame, itemsPanel, statsPanel, historyPanel, settingsPanel, countText, statusText, unmadeText
local factLines = {}
local matLines = {}
local historyRowFrames = {}
local historyEmpty
local historyMeasure -- a hidden font string that measures Got text (FitsGot)
-- The History tab's Got column: its width, and the space between two materials in it (the two
-- spaces S.LootText puts between them).
local GOT_WIDTH, GOT_GAP = 185, 8
local historyOffset = 0
local historySort = "time"
local historyReverse = false -- a second click on the same heading reverses its sort
local historyWho -- the character the History tab shows (its key), or nil for all characters
local historyHeadings = {}
local historyList = {}
-- The Kept tab: its panel, title, empty text and row frames, the rows it lists, the scroll offset,
-- and whether a row still waits for the game to load its item.
local kept = { rowFrames = {}, list = {}, offset = 0, pending = false }
-- Each list's scroll bar (Blizzard's MinimalScrollBar) in scroll.bars (items, history, kept), and
-- the two functions that make and set them (one table, for the main chunk's locals limit).
local scroll = { bars = {} }
-- The game's question-mark icon, for a kept item it hasn't loaded yet.
local UNKNOWN_ICON = 134400
local selectedButton, nextButton
local rowFrames = {}
local settingBoxes = {}
-- The Unmaker buttons above the game's bag windows, kept here, not on Blizzard's frames.
local bagButtons = {}

--- Whether the game is in combat lockdown.
-- @return true in combat, false otherwise or without InCombatLockdown
local function InCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() == true
end

--- Whether a part of the window can't be changed right now. Unmaker does nothing in combat,
-- so every show, hide, move and tab change waits for the fight to end, without asking the game
-- whether that part counts as protected.
-- @param _ the frame (kept so callers say which part they mean)
-- @return true in combat
local function Locked(_)
    return InCombat()
end

--- Whether this character knows Disenchant.
-- @return true when it does
local function KnowsDisenchant()
    return type(C_SpellBook) == "table" and C_SpellBook.ContainsAnyDisenchantSpell() == true
end

--- Show a short line under the list.
-- @param text the message
local function Status(text)
    if statusText then
        statusText:SetText(text)
    end
end

--- Read one bag slot into an item table for UnmakerRules.
-- @param bag bag index
-- @param slot slot index
-- @return the item table, or nil for an empty slot
local function ReadItem(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if type(info) ~= "table" or not info.itemID then
        return nil
    end
    local _, _, _, equipLoc, icon, classID = C_Item.GetItemInfoInstant(info.itemID)
    local level
    if type(ItemLocation) == "table" and type(C_Item.GetCurrentItemLevel) == "function" then
        level = C_Item.GetCurrentItemLevel(ItemLocation:CreateFromBagAndSlot(bag, slot))
    end
    -- What a vendor pays: GetItemInfo's 11th return. Bag items are always loaded.
    local vendor = select(11, C_Item.GetItemInfo(info.itemID))
    return {
        vendor = type(vendor) == "number" and vendor > 0 and vendor or nil,
        bag = bag, slot = slot, itemID = info.itemID, link = info.hyperlink,
        name = info.itemName or info.hyperlink or "?", quality = info.quality,
        classID = classID, equipLoc = equipLoc or "", icon = info.iconFileID or icon,
        cosmetic = C_Item.IsCosmeticItem(info.itemID) == true, bound = info.isBound == true,
        level = level,
    }
end

--- Read every bag.
-- @return list of item tables
local function ScanBags()
    local items = {}
    for _, bag in ipairs(BAGS) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local item = ReadItem(bag, slot)
            if item then
                items[#items + 1] = item
            end
        end
    end
    return items
end

--- The item IDs any saved equipment set uses.
-- @return set of item IDs, { [itemID] = true }
local function SetItemIDs()
    local ids = {}
    if type(C_EquipmentSet) ~= "table" then
        return ids
    end
    for _, setID in ipairs(C_EquipmentSet.GetEquipmentSetIDs() or {}) do
        for _, itemID in pairs(C_EquipmentSet.GetItemIDs(setID) or {}) do
            if type(itemID) == "number" and itemID > 0 then
                ids[itemID] = true
            end
        end
    end
    return ids
end

--- Set both cast buttons' state and labels from the list and the cast state.
local function UpdateButtons()
    if not built or InCombat() then
        return
    end
    local ready = state == "idle" and KnowsDisenchant()
    local count = R.CountChecked(rows)
    selectedButton:SetEnabled(ready and selected ~= nil and selected.checked == true)
    nextButton:SetEnabled(ready and count > 0)
    nextButton:SetText(count > 0 and string.format("Disenchant next (%d)", count) or "Disenchant next")
end

--- Draw the visible rows, the count and the buttons.
-- The player's own disenchant results, counted from the history (D.Tally), and a stamp of the
-- history they were counted from, so they are counted again only when it changed.
local tally, tallyStamp
local tooltipsHooked = false

--- An item's class, from the game's instant item data (no server query).
-- @param itemID the item's ID
-- @return its class (Enum.ItemClass), or nil
local function ClassOf(itemID)
    -- The game raises an error for a missing item (its argument can't be nil).
    if itemID == nil then
        return nil
    end
    local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
    return classID
end

--- The player's own results, counted again only when the history changed (a new disenchant,
-- its loot, or a trim).
-- @return the tally from D.Tally
local function CurrentTally()
    local history = db.history
    local last = history[#history]
    local stamp = #history .. ":" .. (last and (tostring(last.time) .. tostring(last.looted)) or "")
    if stamp ~= tallyStamp then
        tally, tallyStamp = D.Tally(history, ClassOf), stamp
    end
    return tally
end

--- What an item disenchants into: the player's own results, or the tables (UnmakerResults).
-- @param item { quality, classID, level }
-- @return the prediction from D.Predict, or nil
local function Prediction(item)
    return D.Predict(item, CurrentTally())
end

--- A material's icon: from its link (the player's own results) or its item ID (the tables).
-- @param result one result of a prediction
-- @return the icon, or nil when the material has neither (an old history entry)
local function KnownIcon(result)
    local item = result.id or result.link
    if item == nil then
        return nil
    end
    local _, _, _, _, icon = C_Item.GetItemInfoInstant(item)
    return icon
end

--- A material's icon for the Gives column, with the question mark when it has none.
-- @param result one result of a prediction
-- @return the icon
local function MaterialIcon(result)
    return KnownIcon(result) or UNKNOWN_ICON
end

--- Adds a prediction's two lines to a tooltip: a gold title with a grey note on where the
-- numbers come from, then the materials as icons with their chances.
-- @param tooltip the tooltip
-- @param prediction from Prediction, or nil
-- @return true when lines were added
local function AddPredictionLines(tooltip, prediction)
    local lines = D.TooltipLines(prediction, KnownIcon)
    if lines == nil then
        return false
    end
    tooltip:AddDoubleLine(lines[1].left, lines[1].right, 1, 0.82, 0, 0.6, 0.6, 0.6)
    tooltip:AddLine(lines[2].left, 1, 1, 1)
    return true
end

--- Any item tooltip (bags, links, the auction house, loot): adds what the item disenchants
-- into, if it can be disenchanted and the setting is on. Reads the game's item data only.
-- @param tooltip the tooltip being shown
-- @param data the game's tooltip data for an item ({ id, hyperlink })
local function AddResultsToTooltip(tooltip, data)
    if db == nil or not db.settings.tooltipResults or type(data) ~= "table" or tooltip == nil
        or type(tooltip.AddDoubleLine) ~= "function" then
        return
    end
    local link = type(data.hyperlink) == "string" and data.hyperlink or nil
    local itemID = data.id
    if type(itemID) ~= "number" and link then
        itemID = C_Item.GetItemInfoInstant(link)
    end
    if type(itemID) ~= "number" then
        return
    end
    local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(itemID)
    local _, _, quality, level = C_Item.GetItemInfo(itemID)
    -- The item's own level (upgrades and scaling included), as the Items tab shows it.
    if link and type(C_Item.GetDetailedItemLevelInfo) == "function" then
        level = C_Item.GetDetailedItemLevelInfo(link) or level
    end
    local item = { quality = quality, classID = classID, equipLoc = equipLoc, level = level,
        cosmetic = C_Item.IsCosmeticItem(itemID) == true }
    if R.CanDisenchant(item) then
        AddPredictionLines(tooltip, Prediction(item))
    end
end

--- Adds the disenchant results to every item tooltip, once. A client without the game's
-- tooltip data hooks shows them only on the Items tab.
local function HookTooltips()
    if tooltipsHooked or TooltipDataProcessor == nil or type(TooltipDataProcessor.AddTooltipPostCall) ~= "function"
        or Enum == nil or Enum.TooltipDataType == nil or Enum.TooltipDataType.Item == nil then
        return
    end
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, AddResultsToTooltip)
    tooltipsHooked = true
end

--- A copper amount the way the game shows money, with coin icons; plain "1s 20c" if the game's
-- formatter is missing.
-- @param copper whole copper
-- @return the text
local function MoneyText(copper)
    if type(GetMoneyString) == "function" then
        return GetMoneyString(copper, true)
    end
    local gold, silver = math.floor(copper / 10000), math.floor(copper / 100) % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = gold .. "g" end
    if silver > 0 then parts[#parts + 1] = silver .. "s" end
    if copper % 100 > 0 or #parts == 0 then parts[#parts + 1] = (copper % 100) .. "c" end
    return table.concat(parts, " ")
end

--- Matches a list's scroll bar to it: thumb size from how much shows, thumb place from the first
-- row shown, one row per arrow click. The bar hides itself when every row fits.
-- @param bar a bar from scroll.New, or nil before the window is built
-- @param first the list's first shown row, from 0
-- @param total how many rows the list has
function scroll.Set(bar, first, total)
    if bar == nil then
        return
    end
    local last = math.max(0, total - ROW_COUNT)
    bar.first, bar.last = math.min(first, last), last
    bar:SetVisibleExtentPercentage(total > 0 and math.min(1, ROW_COUNT / total) or 1)
    bar:SetPanExtentPercentage(last > 0 and 1 / last or 1)
    if not bar.moving then
        bar:SetScrollPercentage(last > 0 and bar.first / last or 0)
    end
end

--- Puts Blizzard's thin scroll bar at a list panel's right edge. It shows only while the list is
-- longer than its rows; its thumb, arrows and wheel move the list through the list's own scroll.
-- @param panel the list's panel
-- @param move called with the rows to move (negative moves up)
-- @return the bar
function scroll.New(panel, move)
    local bar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    bar.first, bar.last = 0, 0
    -- The wheel over the bar moves one row, as the wheel over the list does (the game's default is two).
    bar.wheelPanScalar = 1
    bar:SetHideIfUnscrollable(true)
    bar:RegisterCallback("OnScroll", function(_, percentage)
        local target = bar.last > 0 and math.floor((percentage or 0) * bar.last + 0.5) or 0
        target = math.max(0, math.min(bar.last, target))
        if target ~= bar.first then
            bar.moving = true
            move(target - bar.first)
            bar.moving = false
        end
    end, bar)
    return bar
end

local function Render()
    if not built then
        return
    end
    scroll.Set(scroll.bars.items, offset, #rows)
    for index, rowFrame in ipairs(rowFrames) do
        local row = rows[offset + index]
        rowFrame.row = row
        if row then
            rowFrame.icon:SetTexture(row.icon)
            rowFrame.nameText:SetText(row.link or row.name)
            rowFrame.levelText:SetText(row.level and tostring(row.level) or "")
            rowFrame.vendorText:SetText(row.vendor and MoneyText(row.vendor) or "-")
            local prediction = Prediction(row)
            for slot, cell in ipairs(rowFrame.gives) do
                local result = prediction and prediction.results[slot]
                if result then
                    cell.icon:SetTexture(MaterialIcon(result))
                    cell.icon:Show()
                    cell.text:SetText(D.PercentText(result.pct))
                else
                    cell.icon:Hide()
                    cell.text:SetText("")
                end
            end
            rowFrame.check:SetChecked(row.checked)
            rowFrame.highlight:SetShown(row == selected)
            rowFrame:Show()
        else
            rowFrame:Hide()
        end
    end
    unmadeText:SetText(string.format("Unmade: %d this session, %d lifetime", session.unmade, db.stats.total))
    if not KnowsDisenchant() then
        countText:SetText("This character doesn't know Disenchant. Learn Enchanting first.")
    elseif #allRows == 0 then
        countText:SetText("Nothing in your bags to disenchant.")
    elseif #rows == 0 then
        countText:SetText(string.format("Nothing matches the filters (%d hidden).", #allRows))
    else
        local hidden = #allRows - #rows
        countText:SetText(string.format("%d of %d checked%s. One click disenchants one item.",
            R.CountChecked(rows), #rows, hidden > 0 and string.format(" (%d hidden by filters)", hidden) or ""))
    end
    UpdateButtons()
end

--- Format a time for the History tab in year-month-day order: "11-12 03:58" in the column,
-- "2026-11-12 03:58" with the year in the row's tooltip.
-- @param seconds a time() value
-- @param withYear true to include the year
-- @return the text
local function FormatWhen(seconds, withYear)
    local format = withYear and "%Y-%m-%d %H:%M" or "%m-%d %H:%M"
    if type(date) == "function" then
        return date(format, seconds)
    end
    return os.date(format, seconds)
end

--- Fill the Stats tab: the facts, then the lifetime materials, most first.
local function RenderStats()
    if not built then
        return
    end
    for index, fact in ipairs(S.Facts(db, session, time(), statsView)) do
        local line = factLines[index]
        if line then
            line.label:SetText(fact.label)
            line.value:SetText(fact.value)
        end
    end
    local mats = S.Materials(db, statsView)
    for index, line in ipairs(matLines) do
        local mat = mats[index]
        if mat then
            line:SetText(mat.count .. " " .. (mat.link or mat.name))
        else
            line:SetText(index == 1 and "None yet." or "")
        end
    end
    -- The 14-day chart for whoever the dropdown shows; hidden with nothing unmade in 14 days.
    local chart = statsPanel.chart
    local data = S.ChartDays(db, time(), statsView)
    if data == nil then
        chart:Hide()
        return
    end
    for index, count in ipairs(data.counts) do
        local bar = chart.bars[index]
        if count > 0 then
            bar:SetHeight(math.max(1, math.floor(count / data.top * chart.barArea + 0.5)))
            local color = index == #data.counts and CHART_TODAY_COLOR or CHART_BAR_COLOR
            bar:SetColorTexture(color[1], color[2], color[3], color[4])
            bar:Show()
        else
            bar:Hide()
        end
    end
    chart.topText:SetText(tostring(data.top))
    chart:Show()
end

--- True when a material's text fits its share of the History tab's Got column, measured in
-- the column's own font, so each name is cut just where the game would run out of room.
-- @param text one material: count, icon and name
-- @param count how many materials share the column
-- @return true when it fits
local function FitsGot(text, count)
    local share = (GOT_WIDTH - (count - 1) * GOT_GAP) / count
    historyMeasure:SetText(text)
    return historyMeasure:GetStringWidth() <= share
end

--- Fill the History tab from the saved history, sorted by the chosen heading.
local function RenderHistory()
    if not built then
        return
    end
    historyList = S.SortHistory(S.FilterHistory(db.history, historyWho, playerRealm), historySort, historyReverse)
    historyOffset = math.max(0, math.min(historyOffset, #historyList - ROW_COUNT))
    scroll.Set(scroll.bars.history, historyOffset, #historyList)
    for index, rowFrame in ipairs(historyRowFrames) do
        local entry = historyList[historyOffset + index]
        rowFrame.entry = entry
        if entry then
            rowFrame.itemText:SetText(entry.link or entry.name)
            rowFrame.levelText:SetText(entry.level and tostring(entry.level) or "")
            rowFrame.whoText:SetText(S.WhoText(entry, playerRealm))
            rowFrame.lootText:SetText(S.LootText(entry, KnownIcon, FitsGot))
            rowFrame.whenText:SetText(FormatWhen(entry.time))
            rowFrame:Show()
        else
            rowFrame:Hide()
        end
    end
    historyEmpty:SetText(#db.history == 0 and "Nothing unmade yet. Disenchant something on the Items tab."
        or "Nothing unmade by this character in the history kept (see Settings).")
    historyEmpty:SetShown(#historyList == 0)
    -- The arrow marks the sorted heading and its direction.
    for key, heading in pairs(historyHeadings) do
        local label = heading.labelText
        if key == historySort then
            local ascending = HISTORY_ASCENDING[key] == true
            if historyReverse then
                ascending = not ascending
            end
            label = label .. " |A:" .. (ascending and "NPE_ArrowUp" or "NPE_ArrowDown") .. ":10:10|a"
        end
        heading.label:SetText(label)
    end
end

--- Fill the Kept tab: every kept item, A to Z, whether it's in the bags now, each with Forget.
-- Items kept before their looks were saved ask the game, which may still be loading them.
local function RenderKept()
    if not built then
        return
    end
    local inBags = {}
    for _, item in ipairs(ScanBags()) do
        inBags[item.itemID] = true
    end
    kept.list = R.KeptRows(db, inBags, function(itemID)
        local name, link, quality, level, _, _, _, _, _, icon = C_Item.GetItemInfo(itemID)
        return name, link, quality, level, icon
    end)
    kept.offset = math.max(0, math.min(kept.offset, #kept.list - ROW_COUNT))
    scroll.Set(scroll.bars.kept, kept.offset, #kept.list)
    kept.pending = false
    for index, rowFrame in ipairs(kept.rowFrames) do
        local row = kept.list[kept.offset + index]
        rowFrame.row = row
        if row then
            kept.pending = kept.pending or row.pending == true
            rowFrame.icon:SetTexture(row.icon or UNKNOWN_ICON)
            rowFrame.itemText:SetText(row.link or row.name)
            rowFrame.bagText:SetText(row.inBags and "In bags" or "")
            rowFrame:Show()
        else
            rowFrame:Hide()
        end
    end
    kept.title:SetText("Kept items (" .. #kept.list .. ")")
    kept.empty:SetShown(#kept.list == 0)
end

--- Read the bags again and redraw. The selection survives if its item is still in its slot.
local function Refresh()
    if not db then
        return
    end
    allRows = R.BuildRows(ScanBags(), db, session, SetItemIDs())
    rows = R.ViewRows(allRows, view)
    local keep
    for _, row in ipairs(rows) do
        if selected and row.bag == selected.bag and row.slot == selected.slot and row.link == selected.link then
            keep = row
        end
    end
    selected = keep
    offset = math.max(0, math.min(offset, #rows - ROW_COUNT))
    Render()
    if currentTab == 4 then
        RenderKept()
    end
end

--- Clear a cast button, so a later click can't fire on an old slot. Out of combat only.
-- @param button a secure cast button
local function ClearCast(button)
    if InCombat() then
        return
    end
    button:SetAttribute("type", nil)
    button:SetAttribute("spell", nil)
    button:SetAttribute("target-bag", nil)
    button:SetAttribute("target-slot", nil)
end

--- Set a cast button to disenchant one row, just before Blizzard's code runs the click. It
-- checks the slot still holds the exact item; if not, the click does nothing.
-- @param button a secure cast button
-- @param row the row to disenchant, or nil
local function PrepareCast(button, row)
    if InCombat() then
        return
    end
    ClearCast(button)
    lastError = nil
    awaitingReason = false
    if state ~= "idle" or not row or not KnowsDisenchant() then
        return
    end
    if not row.checked then
        Status("Check " .. (row.link or row.name) .. " first. Unchecked items are kept.")
        return
    end
    if not R.SameItem(row, C_Container.GetContainerItemInfo(row.bag, row.slot)) then
        Status("Your bags changed. Check the list and click again.")
        Refresh()
        return
    end
    button:SetAttribute("type", "spell")
    button:SetAttribute("spell", DISENCHANT_SPELL)
    button:SetAttribute("target-bag", row.bag)
    button:SetAttribute("target-slot", row.slot)
    pending = row
    pendingAt = GetTime()
end

--- Back to idle: unlock the buttons and read the bags again.
-- @param message the status line to show
local function Unlock(message)
    state = "idle"
    pending = nil
    currentEntry = nil
    earlyLoot = nil
    Status(message)
    Refresh()
end

--- After a cast: unlock once this cast's loot window has opened and closed and the bags have
-- updated. The item leaves the bags before the loot window opens, so a bag update alone is
-- not enough; the 10-second fallback covers a loot window that never shows.
local function TryUnlock()
    if state == "waiting" and lootSeen and bagsSettled and not lootOpen then
        Unlock("Done. Click again for the next item.")
    end
end

--- Show or hide the window, or wait for the fight to end when it is protected.
-- @param shown true to show it
local function SetShown(shown)
    if not built then
        wanted.shown = shown
        return
    end
    if Locked(frame) then
        wanted.shown = shown
        Status("In combat. The window waits until the fight ends.")
        return
    end
    wanted.shown = nil
    if shown then
        frame:Show()
        Refresh()
    else
        frame:Hide()
    end
end

--- Show the window if it is hidden, hide it if it is shown. A window the player opened or
-- closed by hand no longer closes with the bags.
local function Toggle()
    openedWithBags = false
    SetShown(not (built and frame:IsShown()))
end

--- Switch tabs: Items (1), Stats (2), History (3), Kept (4) or Settings (5).
-- @param id tab number
local function SelectTab(id)
    if Locked(itemsPanel) then
        return
    end
    currentTab = id
    PanelTemplates_SetTab(frame, id)
    itemsPanel:SetShown(id == 1)
    statsPanel:SetShown(id == 2)
    historyPanel:SetShown(id == 3)
    kept.panel:SetShown(id == 4)
    settingsPanel:SetShown(id == 5)
    if id == 2 then
        RenderStats()
    elseif id == 3 then
        RenderHistory()
    elseif id == 4 then
        RenderKept()
    end
end

--- Build one list row: a checkbox, the icon, the item link and its item level. Clicking the
-- row selects it for "Disenchant selected"; hovering shows the item's tooltip.
-- @param index row position, 1 at the top
-- @return the row frame
local function BuildRow(index)
    local rowFrame = CreateFrame("Button", nil, itemsPanel)
    rowFrame:SetSize(WIDTH - 40, ROW_HEIGHT)
    rowFrame:SetPoint("TOPLEFT", itemsPanel, "TOPLEFT", 4, -(FILTER_HEIGHT + HEADER_HEIGHT) - (index - 1) * ROW_HEIGHT)

    rowFrame.highlight = rowFrame:CreateTexture(nil, "BACKGROUND")
    rowFrame.highlight:SetAllPoints()
    rowFrame.highlight:SetColorTexture(1, 0.82, 0, 0.2)
    rowFrame.highlight:Hide()

    rowFrame.check = CreateFrame("CheckButton", nil, rowFrame, "UICheckButtonTemplate")
    rowFrame.check:SetSize(ROW_HEIGHT, ROW_HEIGHT)
    rowFrame.check:SetPoint("LEFT", rowFrame, "LEFT", 0, 0)
    rowFrame.check:SetScript("OnClick", function(box)
        if rowFrame.row then
            R.SetChecked(db, session, rowFrame.row, box:GetChecked() == true)
            Refresh()
        end
    end)

    rowFrame.icon = rowFrame:CreateTexture(nil, "ARTWORK")
    rowFrame.icon:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
    rowFrame.icon:SetPoint("LEFT", rowFrame.check, "RIGHT", 2, 0)

    rowFrame.nameText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    rowFrame.nameText:SetPoint("LEFT", rowFrame.icon, "RIGHT", 6, 0)
    rowFrame.nameText:SetPoint("RIGHT", rowFrame, "RIGHT", NAME_RIGHT, 0)
    rowFrame.nameText:SetJustifyH("LEFT")
    rowFrame.nameText:SetWordWrap(false)

    rowFrame.vendorText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rowFrame.vendorText:SetPoint("RIGHT", rowFrame, "RIGHT", VENDOR_RIGHT, 0)
    rowFrame.vendorText:SetWidth(90)
    rowFrame.vendorText:SetJustifyH("RIGHT")
    rowFrame.vendorText:SetWordWrap(false)

    rowFrame.levelText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rowFrame.levelText:SetPoint("RIGHT", rowFrame, "RIGHT", LEVEL_RIGHT, 0)
    rowFrame.levelText:SetWidth(34)
    rowFrame.levelText:SetJustifyH("RIGHT")

    -- Gives: an icon and a chance per material, left to right, most likely first.
    rowFrame.gives = {}
    local givesLeft = GIVES_RIGHT - GIVES_SHOWN * GIVES_SLOT
    for slot = 1, GIVES_SHOWN do
        local icon = rowFrame:CreateTexture(nil, "ARTWORK")
        icon:SetSize(GIVES_ICON, GIVES_ICON)
        icon:SetPoint("LEFT", rowFrame, "RIGHT", givesLeft + (slot - 1) * GIVES_SLOT, 0)
        icon:Hide()
        local text = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 2, 0)
        text:SetWidth(GIVES_SLOT - GIVES_ICON - 4)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        rowFrame.gives[slot] = { icon = icon, text = text }
    end

    rowFrame:SetScript("OnClick", function()
        selected = rowFrame.row
        Render()
    end)
    rowFrame:SetScript("OnEnter", function()
        if rowFrame.row then
            GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
            GameTooltip:SetBagItem(rowFrame.row.bag, rowFrame.row.slot)
            -- With the tooltip setting on, the tooltip hook has added the results already.
            if not db.settings.tooltipResults or not tooltipsHooked then
                AddPredictionLines(GameTooltip, Prediction(rowFrame.row))
            end
            GameTooltip:Show()
        end
    end)
    rowFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    return rowFrame
end

--- Build one secure cast button. PreClick picks the row and sets the cast; PostClick clears it.
-- @param name global frame name (the key binding clicks UnmakerNextButton)
-- @param label button text
-- @param pick function returning the row this button disenchants
-- @return the button
local function BuildCastButton(name, label, pick)
    local button = CreateFrame("Button", name, itemsPanel, "UIPanelButtonTemplate,SecureActionButtonTemplate")
    button:SetSize(170, 24)
    button:SetText(label)
    button:RegisterForClicks("LeftButtonUp") -- only a left click casts; a key binding sends one too
    button:SetAttribute("useOnKeyDown", false)
    button:SetScript("PreClick", function(self)
        PrepareCast(self, pick())
    end)
    button:SetScript("PostClick", function(self)
        ClearCast(self)
    end)
    return button
end

--- Show one character's stats on the Stats tab, or every character's together.
-- @param view a character key, or false or nil for all characters
local function SetStatsView(view)
    statsView = view or nil
    RenderStats()
end

--- Build the Stats tab: a switcher for whose stats to show, one label and value per fact, then
-- the lifetime materials.
local function BuildStats()
    statsPanel = CreateFrame("Frame", nil, frame)
    statsPanel.isStats = true
    statsPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -70)
    statsPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, BUTTON_AREA)

    -- Whose stats show: a dropdown top right, beside the short numbers of the first fact lines.
    -- Blizzard's own dropdown (as HouseLedger's filters use on Forever), rebuilt each time it
    -- opens, so a character's first disenchant adds it to the list.
    local dropdown = CreateFrame("DropdownButton", nil, statsPanel, "WowStyle1DropdownTemplate")
    dropdown:SetWidth(150)
    dropdown:SetPoint("TOPRIGHT", statsPanel, "TOPRIGHT", 0, 2)
    dropdown:SetupMenu(function(_, root)
        local choices = { false } -- false stands for all characters
        for _, key in ipairs(S.Characters(db)) do
            choices[#choices + 1] = key
        end
        for _, choice in ipairs(choices) do
            local label = choice and S.CharacterLabel(choice, playerRealm) or "All characters"
            root:CreateRadio(label, function(picked)
                return (statsView or false) == picked
            end, SetStatsView, choice)
        end
    end)
    statsPanel.viewDropdown = dropdown

    -- The 14-day chart: a dark box with one bar per day, the busiest day's count in its corner.
    local chart = CreateFrame("Frame", nil, statsPanel)
    chart:SetSize(CHART_WIDTH, CHART_HEIGHT)
    chart:SetPoint("TOPRIGHT", statsPanel, "TOPRIGHT", 0, -CHART_TOP)
    local background = chart:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(chart)
    background:SetColorTexture(0, 0, 0, 0.3)
    chart.topText = chart:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    chart.topText:SetPoint("TOPLEFT", chart, "TOPLEFT", 3, -2)
    local caption = chart:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    caption:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -3, -2)
    caption:SetText("Unmade per day, 14 days")
    chart.barArea = CHART_HEIGHT - 18
    chart.bars = {}
    local slot = CHART_WIDTH / 14
    for index = 1, 14 do
        local bar = chart:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", math.floor((index - 1) * slot) + 1, 2)
        bar:SetWidth(math.max(2, math.floor(slot) - 2))
        bar:Hide()
        chart.bars[index] = bar
    end
    chart:Hide()
    statsPanel.chart = chart

    local facts = S.Facts(db, session, time())
    for index = 1, #facts do
        local line = {}
        line.label = statsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        line.label:SetPoint("TOPLEFT", statsPanel, "TOPLEFT", 0, -(index - 1) * 16)
        line.value = statsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        line.value:SetPoint("TOPLEFT", statsPanel, "TOPLEFT", 120, -(index - 1) * 16)
        line.value:SetPoint("RIGHT", statsPanel, "RIGHT", 0, 0)
        line.value:SetJustifyH("LEFT")
        line.value:SetWordWrap(false)
        factLines[index] = line
    end
    local top = #facts * 16 + 8
    local header = statsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", statsPanel, "TOPLEFT", 0, -top)
    header:SetText("Materials (lifetime)")
    for index = 1, MAT_LINES do
        local line = statsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        line:SetPoint("TOPLEFT", statsPanel, "TOPLEFT", 12, -(top + index * 16))
        matLines[index] = line
    end
    statsPanel:Hide()
end

-- History columns: x offset and width of each, inside the History panel.
local HISTORY_COLUMNS = {
    { key = "name", label = "Item", x = 0, width = 150 },
    { key = "level", label = "ilvl", x = 155, width = 35 },
    { key = "who", label = "Who", x = 195, width = 80 },
    { key = nil, label = "Got", x = 280, width = GOT_WIDTH },
    { key = "time", label = "When", x = 470, width = 80 },
}

--- Build the History tab: clickable headings that sort, then ten rows, newest first by default.
local function BuildHistory()
    historyPanel = CreateFrame("Frame", nil, frame)
    historyPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -LIST_TOP)
    historyPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, BUTTON_AREA)
    historyPanel:EnableMouseWheel(true)
    local function ScrollHistory(rowsDown)
        historyOffset = math.max(0, math.min(historyOffset + rowsDown, #historyList - ROW_COUNT))
        RenderHistory()
    end
    historyPanel:SetScript("OnMouseWheel", function(_, delta)
        ScrollHistory(-delta)
    end)
    scroll.bars.history = scroll.New(historyPanel, ScrollHistory)
    scroll.bars.history:SetPoint("TOPRIGHT", historyPanel, "TOPRIGHT", 4, -(FILTER_HEIGHT + 20))
    scroll.bars.history:SetHeight(LIST_HEIGHT)
    -- Whose disenchants to show: the same kind of dropdown as the Stats tab, rebuilt when opened.
    local whoDropdown = CreateFrame("DropdownButton", nil, historyPanel, "WowStyle1DropdownTemplate")
    whoDropdown:SetWidth(150)
    whoDropdown:SetPoint("TOPLEFT", historyPanel, "TOPLEFT", 0, 0)
    whoDropdown:SetupMenu(function(_, root)
        local choices = { false } -- false stands for all characters
        for _, key in ipairs(S.Characters(db)) do
            choices[#choices + 1] = key
        end
        for _, choice in ipairs(choices) do
            root:CreateRadio(choice and S.CharacterLabel(choice, playerRealm) or "All characters", function(picked)
                return (historyWho or false) == picked
            end, function(picked)
                historyWho = picked or nil
                historyOffset = 0
                RenderHistory()
            end, choice)
        end
    end)
    historyPanel.whoDropdown = whoDropdown

    for _, column in ipairs(HISTORY_COLUMNS) do
        local heading = CreateFrame("Button", nil, historyPanel)
        heading:SetSize(column.width, 18)
        heading:SetPoint("TOPLEFT", historyPanel, "TOPLEFT", column.x, -FILTER_HEIGHT)
        heading.label = heading:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        heading.label:SetPoint("LEFT", heading, "LEFT", 0, 0)
        heading.label:SetText(column.label)
        heading.labelText = column.label
        heading.sortKey = column.key
        if column.key then
            historyHeadings[column.key] = heading
            heading:SetScript("OnClick", function()
                -- The same heading again reverses the sort; another heading starts its own way.
                if historySort == column.key then
                    historyReverse = not historyReverse
                else
                    historySort, historyReverse = column.key, false
                end
                historyOffset = 0
                RenderHistory()
            end)
        end
    end
    for index = 1, ROW_COUNT do
        local rowFrame = CreateFrame("Button", nil, historyPanel)
        rowFrame.historyRow = true
        rowFrame:SetSize(WIDTH - 40, ROW_HEIGHT)
        rowFrame:SetPoint("TOPLEFT", historyPanel, "TOPLEFT", 0, -(FILTER_HEIGHT + 20 + (index - 1) * ROW_HEIGHT))
        for _, field in ipairs({ { "itemText", 1 }, { "levelText", 2 }, { "whoText", 3 }, { "lootText", 4 },
            { "whenText", 5 } }) do
            local column = HISTORY_COLUMNS[field[2]]
            local text = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            text:SetPoint("LEFT", rowFrame, "LEFT", column.x, 0)
            text:SetWidth(column.width)
            text:SetJustifyH("LEFT")
            text:SetWordWrap(false) -- long loot text is cut off, not wrapped into the next row
            rowFrame[field[1]] = text
        end
        rowFrame:SetScript("OnEnter", function()
            local entry = rowFrame.entry
            if entry then
                GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
                if entry.link then
                    GameTooltip:SetHyperlink(entry.link)
                end
                GameTooltip:AddLine("Unmade by " .. S.WhoText(entry, playerRealm) .. ", " .. FormatWhen(entry.time, true))
                GameTooltip:AddLine("Got " .. S.LootText(entry), 1, 1, 1, true)
                GameTooltip:Show()
            end
        end)
        rowFrame:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        historyRowFrames[index] = rowFrame
    end
    -- Never shown: measures loot text in the Got column's font (FitsGot).
    historyMeasure = historyPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    historyMeasure:Hide()
    historyEmpty = historyPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    historyEmpty:SetPoint("TOPLEFT", historyPanel, "TOPLEFT", 0, -(FILTER_HEIGHT + 24))
    historyEmpty:SetText("Nothing unmade yet. Disenchant something on the Items tab.")
    historyPanel:Hide()
end

--- Build the Kept tab: a title with the count, one row per kept item (icon, name, "In bags",
-- Forget), scrolled with the mouse wheel, and what Forget does.
local function BuildKept()
    kept.panel = CreateFrame("Frame", nil, frame)
    kept.panel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -LIST_TOP)
    kept.panel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, BUTTON_AREA)
    kept.panel:EnableMouseWheel(true)
    local function ScrollKept(rowsDown)
        kept.offset = math.max(0, math.min(kept.offset + rowsDown, #kept.list - ROW_COUNT))
        RenderKept()
    end
    kept.panel:SetScript("OnMouseWheel", function(_, delta)
        ScrollKept(-delta)
    end)
    scroll.bars.kept = scroll.New(kept.panel, ScrollKept)
    -- Rows end 4 px short of the panel's right edge (Forget sits there); the bar starts 2 px past it.
    scroll.bars.kept:SetPoint("TOPRIGHT", kept.panel, "TOPRIGHT", 10, -FILTER_HEIGHT)
    scroll.bars.kept:SetHeight(LIST_HEIGHT)
    kept.title = kept.panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    kept.title:SetPoint("TOPLEFT", kept.panel, "TOPLEFT", 4, -4)
    kept.title:SetText("Kept items (0)")
    for index = 1, ROW_COUNT do
        local rowFrame = CreateFrame("Button", nil, kept.panel)
        rowFrame.keptRow = true
        rowFrame:SetSize(WIDTH - 40, ROW_HEIGHT)
        rowFrame:SetPoint("TOPLEFT", kept.panel, "TOPLEFT", 4, -(FILTER_HEIGHT + (index - 1) * ROW_HEIGHT))
        rowFrame.icon = rowFrame:CreateTexture(nil, "ARTWORK")
        rowFrame.icon:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
        rowFrame.icon:SetPoint("LEFT", rowFrame, "LEFT", 0, 0)
        rowFrame.itemText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        rowFrame.itemText:SetPoint("LEFT", rowFrame.icon, "RIGHT", 6, 0)
        rowFrame.itemText:SetPoint("RIGHT", rowFrame, "RIGHT", -160, 0)
        rowFrame.itemText:SetJustifyH("LEFT")
        rowFrame.itemText:SetWordWrap(false)
        rowFrame.bagText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rowFrame.bagText:SetPoint("RIGHT", rowFrame, "RIGHT", -84, 0)
        rowFrame.bagText:SetWidth(70)
        rowFrame.bagText:SetJustifyH("RIGHT")
        rowFrame.forget = CreateFrame("Button", nil, rowFrame, "UIPanelButtonTemplate")
        rowFrame.forget:SetSize(72, ROW_HEIGHT - 2)
        rowFrame.forget:SetPoint("RIGHT", rowFrame, "RIGHT", 0, 0)
        rowFrame.forget:SetText("Forget")
        rowFrame.forget:SetScript("OnClick", function()
            if rowFrame.row then
                R.Forget(db, session, rowFrame.row.itemID)
                Refresh()
                RenderKept()
            end
        end)
        rowFrame:SetScript("OnEnter", function()
            local row = rowFrame.row
            if row then
                GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
                if row.link then
                    GameTooltip:SetHyperlink(row.link)
                elseif GameTooltip.SetItemByID then
                    GameTooltip:SetItemByID(row.itemID)
                end
                GameTooltip:Show()
            end
        end)
        rowFrame:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        kept.rowFrames[index] = rowFrame
    end
    kept.empty = kept.panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    kept.empty:SetPoint("TOPLEFT", kept.panel, "TOPLEFT", 4, -(FILTER_HEIGHT + 4))
    kept.empty:SetPoint("RIGHT", kept.panel, "RIGHT", -4, 0)
    kept.empty:SetJustifyH("LEFT")
    kept.empty:SetText("Nothing kept. Uncheck an item on the Items tab and Unmaker keeps it: it starts"
        .. " unchecked from then on.")
    kept.empty:Hide()
    local hint = kept.panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", kept.panel, "BOTTOMLEFT", 4, 4)
    hint:SetPoint("RIGHT", kept.panel, "RIGHT", -4, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("Forget puts an item back: it starts checked again, unless a setting keeps it (like Keep epics).")
    kept.panel:Hide()
end

--- Shows or hides the Unmaker buttons above the bags, as the "bagButton" setting says.
-- /unmaker opens the window either way.
local function UpdateBagButtons()
    for _, button in ipairs(bagButtons) do
        if db.settings.bagButton then button:Show() else button:Hide() end
    end
end

--- A whole number with commas between thousands, like 10,000.
-- @param number a whole number, 0 or more
-- @return the text
local function WithCommas(number)
    local text = tostring(number):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (text:gsub("^,", ""))
end

--- Build the Settings tab: one checkbox per setting, then how many disenchants History keeps.
local function BuildSettings()
    settingsPanel = CreateFrame("Frame", nil, frame)
    settingsPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -70)
    settingsPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 40)
    for index, setting in ipairs(R.SETTINGS) do
        local box = CreateFrame("CheckButton", nil, settingsPanel, "UICheckButtonTemplate")
        box:SetSize(24, 24)
        box:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", 0, -(index - 1) * 30)
        box.label = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        box.label:SetPoint("LEFT", box, "RIGHT", 4, 0)
        box.label:SetText(setting.label)
        box.key = setting.key
        box:SetChecked(db.settings[setting.key])
        box:SetScript("OnClick", function(self)
            R.SetSetting(db, self.key, self:GetChecked() == true)
            if self.key == "bagButton" then
                UpdateBagButtons()
            end
            Refresh()
        end)
        settingBoxes[#settingBoxes + 1] = box
    end

    local historyLabel = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    historyLabel:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", 4, -#R.SETTINGS * 30 - 12)
    historyLabel:SetText("Keep history for")
    local history = CreateFrame("DropdownButton", nil, settingsPanel, "WowStyle1DropdownTemplate")
    history:SetWidth(160)
    history:SetPoint("LEFT", historyLabel, "RIGHT", 10, 0)
    history:SetupMenu(function(_, root)
        for _, count in ipairs(S.HISTORY_CHOICES) do
            root:CreateRadio(WithCommas(count) .. " disenchants", function(picked)
                return S.HistoryMax(db) == picked
            end, function(picked)
                S.SetHistoryMax(db, picked)
                Refresh()
            end, count)
        end
    end)
    local historyHint = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    historyHint:SetPoint("TOPLEFT", historyLabel, "BOTTOMLEFT", 0, -14)
    historyHint:SetPoint("RIGHT", settingsPanel, "RIGHT", 0, 0)
    historyHint:SetJustifyH("LEFT")
    historyHint:SetText("The Stats totals always count every disenchant. A longer history uses more memory"
        .. " (10,000 takes about 9 MB); a shorter one drops the oldest right away.")
    settingsPanel.historyDropdown, settingsPanel.historyHint = history, historyHint
    settingsPanel:Hide()
end

--- Build a tab under the window.
-- @param id tab number
-- @param label tab text
-- @return the tab button
local function BuildTab(id, label)
    local tab = CreateFrame("Button", "UnmakerFrameTab" .. id, frame, "PanelTabButtonTemplate")
    tab:SetID(id)
    tab:SetText(label)
    tab:SetScript("OnClick", function()
        SelectTab(id)
    end)
    if type(PanelTemplates_TabResize) == "function" then
        PanelTemplates_TabResize(tab, 0)
    end
    return tab
end

--- Put a small "Unmaker" button on a Blizzard bag window. It is a child of that window, so it
-- shows and hides with it, and it only opens or closes Unmaker's own window.
-- @param bagFrame ContainerFrame1 or ContainerFrameCombinedBags, if the game has it
local function AddBagButton(bagFrame)
    if type(bagFrame) ~= "table" then
        return
    end
    local button = CreateFrame("Button", nil, bagFrame, "UIPanelButtonTemplate")
    button:SetSize(80, 20)
    button:SetText("Unmaker")
    button:SetPoint("BOTTOMRIGHT", bagFrame, "TOPRIGHT", 0, 2)
    button:SetScript("OnClick", Toggle)
    bagButtons[#bagButtons + 1] = button
end


--- After the window is dropped: save where it is for this character, so it opens there after
-- a reload. Unmaker keeps the spot itself, so the frame is marked not user placed and
-- the game's own layout file doesn't move it too.
-- @param window the Unmaker frame
local function SavePosition(window)
    if type(window.SetUserPlaced) == "function" then
        window:SetUserPlaced(false)
    end
    local point, relativeTo, relativePoint, x, y = window:GetPoint(1)
    if relativeTo == nil or relativeTo == UIParent then
        charDB.position = R.Position(point, relativePoint, x, y) or charDB.position
    end
end

--- Build the window: the frame, the Items and Settings tabs, the list, the two cast buttons,
-- and the bag window buttons.
--- The column headings' text: an arrow on the column the list is sorted by.
local function RefreshHeader()
    for key, text in pairs(itemsPanel.headerTexts) do
        local label = COLUMN_LABELS[key]
        if view.sortKey == key then
            label = label .. " |A:" .. (view.ascending and "NPE_ArrowUp" or "NPE_ArrowDown") .. ":10:10|a"
        end
        text:SetText(label)
    end
end

--- After a filter or sort changed: show the rows again from the top. Reads the bags as usual;
-- sends nothing.
local function ApplyView()
    view.minLevel = R.ParseLevel(itemsPanel.minLevelBox:GetText())
    view.maxLevel = R.ParseLevel(itemsPanel.maxLevelBox:GetText())
    offset = 0
    RefreshHeader()
    Refresh()
end

--- A heading click: sort by that column, or reverse it when already sorted by it.
-- @param key name, ilvl or vendor
local function SortByColumn(key)
    if view.sortKey == key then
        view.ascending = not view.ascending
    else
        view.sortKey, view.ascending = key, SORT_FIRST_ASCENDING[key]
    end
    ApplyView()
end

--- Make the Items tab's filter row (a quality dropdown and an item level range) and its column
-- headings, which sort the list when clicked.
local function BuildFilterAndHeader()
    local filterRow = CreateFrame("Frame", nil, itemsPanel)
    filterRow:SetPoint("TOPLEFT", itemsPanel, "TOPLEFT", 0, 0)
    filterRow:SetPoint("RIGHT", itemsPanel, "RIGHT", 0, 0)
    filterRow:SetHeight(FILTER_HEIGHT)

    -- Blizzard's own dropdown, as HouseLedger's filters use on Forever.
    local quality = CreateFrame("DropdownButton", nil, filterRow, "WowStyle1DropdownTemplate")
    quality:SetWidth(170) -- room for "Uncommon & down" without cutting it off
    quality:SetPoint("LEFT", filterRow, "LEFT", 2, 0)
    quality:SetupMenu(function(_, root)
        for _, choice in ipairs(R.QUALITY_CHOICES) do
            root:CreateRadio(choice.label, function(picked)
                return view.maxQuality == picked.max
            end, function(picked)
                view.maxQuality = picked.max
                ApplyView()
            end, choice)
        end
    end)
    itemsPanel.qualityDropdown = quality

    local levelLabel = filterRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    levelLabel:SetPoint("LEFT", quality, "RIGHT", 12, 0)
    levelLabel:SetText("ilvl")
    --- A small numeric box that filters as the player types.
    -- @return the edit box
    local function LevelBox()
        local box = CreateFrame("EditBox", nil, filterRow, "InputBoxTemplate")
        box:SetSize(34, 20)
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetMaxLetters(3)
        box:SetScript("OnTextChanged", function(_, userInput)
            if userInput then
                ApplyView()
            end
        end)
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        return box
    end
    local minBox = LevelBox()
    minBox:SetPoint("LEFT", levelLabel, "RIGHT", 10, 0)
    local dash = filterRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dash:SetPoint("LEFT", minBox, "RIGHT", 2, 0)
    dash:SetText("-")
    local maxBox = LevelBox()
    maxBox:SetPoint("LEFT", dash, "RIGHT", 8, 0)
    itemsPanel.minLevelBox, itemsPanel.maxLevelBox = minBox, maxBox

    -- Headings line up with the row cells: name after the checkbox and icon, ilvl, then vendor.
    local header = CreateFrame("Frame", nil, itemsPanel)
    header:SetPoint("TOPLEFT", itemsPanel, "TOPLEFT", 4, -FILTER_HEIGHT)
    header:SetSize(WIDTH - 40, HEADER_HEIGHT)
    local places = {
        { key = "name", point = "LEFT", x = ROW_HEIGHT + 2 + ROW_HEIGHT - 4 + 6, width = 120, justify = "LEFT" },
        { key = "ilvl", point = "RIGHT", x = LEVEL_RIGHT, width = 50, justify = "RIGHT" },
        { key = "gives", point = "RIGHT", x = GIVES_RIGHT, width = GIVES_SHOWN * GIVES_SLOT, justify = "LEFT",
            fixed = true },
        { key = "vendor", point = "RIGHT", x = VENDOR_RIGHT, width = 90, justify = "RIGHT" },
    }
    itemsPanel.headerTexts, itemsPanel.sortButtons = {}, {}
    for _, place in ipairs(places) do
        local text = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint(place.point, header, place.point, place.x, 0)
        text:SetWidth(place.width)
        text:SetJustifyH(place.justify)
        text:SetText(COLUMN_LABELS[place.key])
        itemsPanel.headerTexts[place.key] = text
        -- Gives doesn't sort: its chances aren't one number.
        if not place.fixed then
            local button = CreateFrame("Button", nil, header)
            button:SetPoint("TOPLEFT", text, "TOPLEFT", -2, 3)
            button:SetPoint("BOTTOMRIGHT", text, "BOTTOMRIGHT", 2, -3)
            button:SetScript("OnClick", function()
                SortByColumn(place.key)
            end)
            itemsPanel.sortButtons[place.key] = button
        end
    end
end

local function BuildFrame()
    frame = CreateFrame("Frame", "UnmakerFrame", UIParent, "ButtonFrameTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    local position = charDB.position
    if position then
        frame:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("HIGH")
    if type(frame.SetTitle) == "function" then
        frame:SetTitle("Unmaker")
    end
    if type(frame.SetPortraitToAsset) == "function" then
        frame:SetPortraitToAsset(PORTRAIT_ICON)
    end
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not Locked(self) then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        if not Locked(self) then
            self:StopMovingOrSizing()
            SavePosition(self)
        end
    end)
    frame:Hide()

    itemsPanel = CreateFrame("Frame", nil, frame)
    itemsPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -LIST_TOP)
    itemsPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, BUTTON_AREA)
    itemsPanel:EnableMouseWheel(true)
    local function ScrollItems(rowsDown)
        offset = math.max(0, math.min(offset + rowsDown, #rows - ROW_COUNT))
        Render()
    end
    itemsPanel:SetScript("OnMouseWheel", function(_, delta)
        ScrollItems(-delta)
    end)
    scroll.bars.items = scroll.New(itemsPanel, ScrollItems)
    scroll.bars.items:SetPoint("TOPRIGHT", itemsPanel, "TOPRIGHT", 0, -(FILTER_HEIGHT + HEADER_HEIGHT))
    scroll.bars.items:SetHeight(LIST_HEIGHT)
    BuildFilterAndHeader()
    for index = 1, ROW_COUNT do
        rowFrames[index] = BuildRow(index)
    end

    -- The count and status lines belong to the Items tab, so they hide on Settings.
    countText = itemsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -(LIST_START + LIST_HEIGHT + 8))
    countText:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
    countText:SetJustifyH("LEFT")
    statusText = itemsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", countText, "BOTTOMLEFT", 0, -4)
    statusText:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetJustifyV("TOP")
    statusText:SetHeight(TEXT_HEIGHT - 20)

    selectedButton = BuildCastButton("UnmakerSelectedButton", "Disenchant selected", function()
        return selected
    end)
    selectedButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 8)
    nextButton = BuildCastButton("UnmakerNextButton", "Disenchant next", function()
        return R.NextRow(rows)
    end)
    nextButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 8)

    unmadeText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    unmadeText:SetPoint("TOP", frame, "TOP", 20, -38)

    BuildStats()
    BuildHistory()
    BuildKept()
    BuildSettings()
    BuildTab(1, "Items"):SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
    BuildTab(2, "Stats"):SetPoint("LEFT", _G.UnmakerFrameTab1, "RIGHT", -14, 0)
    BuildTab(3, "History"):SetPoint("LEFT", _G.UnmakerFrameTab2, "RIGHT", -14, 0)
    BuildTab(4, "Kept"):SetPoint("LEFT", _G.UnmakerFrameTab3, "RIGHT", -14, 0)
    BuildTab(5, "Settings"):SetPoint("LEFT", _G.UnmakerFrameTab4, "RIGHT", -14, 0)
    PanelTemplates_SetNumTabs(frame, 5)
    PanelTemplates_SetTab(frame, 1)

    AddBagButton(_G.ContainerFrameCombinedBags)
    AddBagButton(_G.ContainerFrame1)
    UpdateBagButtons()
    built = true
end

--- The links of every row now, to spot new gear for "Open when I loot".
-- @return set of links, { [link] = true }
local function CurrentLinks()
    local links = {}
    -- Every row, not just the ones the filters show: hidden gear still counts as new loot.
    for _, row in ipairs(allRows) do
        links[row.link] = true
    end
    return links
end

--- After the bags change: redraw, and open the window when new gear to disenchant arrived,
-- "Open when I loot" is on and this character knows Disenchant (settings are shared by every
-- character, so an alt without Enchanting has the setting on too).
local function OnBagsChanged()
    Refresh()
    local links = CurrentLinks()
    if seenLinks and db.settings.openOnLoot and KnowsDisenchant() then
        for link in pairs(links) do
            if not seenLinks[link] then
                openedWithBags = false
                SetShown(true)
                break
            end
        end
    end
    seenLinks = links
end

--- When a Blizzard bag window opens: open Unmaker too if "Open and close with my bags" is on, this
-- character knows Disenchant and there is something to disenchant. A window that was already
-- open stays the player's, so it won't close with the bags.
local function OnBagOpened()
    if db and db.settings.openOnBags and KnowsDisenchant() then
        Refresh()
        if #rows > 0 and not (built and frame:IsShown()) then
            openedWithBags = true
            SetShown(true)
        end
    end
end

--- When a Blizzard bag window closes: close Unmaker too once the last bag window is closed, if
-- the bags opened it. It runs after the bag window has hidden, so IsAnyBagOpen already counts
-- the one closing.
local function OnBagClosed()
    if openedWithBags and not IsAnyBagOpen() then
        openedWithBags = false
        -- wanted.shown: the bags opened it in combat and the fight hasn't ended yet.
        if db.settings.openOnBags and ((built and frame:IsShown()) or wanted.shown) then
            SetShown(false)
        end
    end
end

--- Whether a spellcast event is this character casting Disenchant.
-- @param unit the event's unit
-- @param spellID the event's spell ID
-- @return true when it is
local function IsDisenchant(unit, spellID)
    return unit == "player" and spellID == DISENCHANT_SPELL
end

--- What the game puts between a Forever character's first name and surname, or nil when the
-- client has no such constant (then S.FullName uses a space).
-- @return the separator, or nil
local function SurnameSeparator()
    local consts = type(Constants) == "table" and Constants.CharacterNameSeparatorConsts
    return type(consts) == "table" and consts.CHARACTERNAME_SURNAME_SEPARATOR or nil
end

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name ~= "Unmaker" then
        return
    end
    db = R.EnsureDB(UnmakerDB)
    playerRealm = S.RealmFor(db, GetRealmName())
    local firstName, surname = UnitName("player")
    playerName = S.FullName(firstName, surname, SurnameSeparator())
    db = S.EnsureStats(db, playerRealm)
    S.Adopt(db, firstName, playerName, playerRealm)
    session.key = S.CharacterKey(playerName, playerRealm)
    UnmakerDB = db
    charDB = R.EnsureCharDB(UnmakerCharDB)
    UnmakerCharDB = charDB
    HookTooltips()
    if not InCombat() then
        BuildFrame()
    end
    if type(EventRegistry) == "table" then
        EventRegistry:RegisterCallback("ContainerFrame.OpenAllBags", OnBagOpened, frame or db)
        EventRegistry:RegisterCallback("ContainerFrame.OpenBag", OnBagOpened, frame or db)
        EventRegistry:RegisterCallback("ContainerFrame.CloseAllBags", OnBagClosed, frame or db)
        EventRegistry:RegisterCallback("ContainerFrame.CloseBag", OnBagClosed, frame or db)
    end
    -- The combined bag window (one window for all bags) sends no OpenBag or CloseBag event, and
    -- the backpack button shows and hides it without OpenAllBags or CloseAllBags, so follow
    -- its own show and hide too. HookScript only listens; it changes nothing on Blizzard's frame.
    local combined = _G.ContainerFrameCombinedBags
    if type(combined) == "table" and type(combined.HookScript) == "function" then
        combined:HookScript("OnShow", OnBagOpened)
        combined:HookScript("OnHide", OnBagClosed)
    end
end

--- The game loaded an item's data: a Kept row still showing "Item <id>" can show its name now.
-- Only while the Kept tab waits on one, as this event comes often.
function handlers.GET_ITEM_INFO_RECEIVED()
    if currentTab == 4 and kept.pending then
        RenderKept()
    end
end

function handlers.PLAYER_ENTERING_WORLD()
    if built then
        Refresh()
        seenLinks = CurrentLinks()
    end
end

function handlers.BAG_UPDATE_DELAYED()
    if not built then
        return
    end
    if state == "waiting" then
        bagsSettled = true
        TryUnlock()
    elseif state == "idle" then
        OnBagsChanged()
    end
end

function handlers.UNIT_SPELLCAST_START(unit, _, spellID)
    if IsDisenchant(unit, spellID) then
        if pending and (not pendingAt or GetTime() - pendingAt > CLICK_WINDOW) then
            pending = nil -- not this click's cast; don't credit the old row
        end
        state = "casting"
        lootSeen = false
        waited = 0
        currentEntry = nil
        earlyLoot = nil
        Status(pending and ("Disenchanting " .. (pending.link or pending.name) .. "...") or "Disenchanting...")
        UpdateButtons()
    end
end

--- After a recorded disenchant: update the Unmade line and any open Stats or History tab.
local function OnRecorded()
    Render()
    if statsPanel:IsShown() then
        RenderStats()
    end
    if historyPanel:IsShown() then
        RenderHistory()
    end
end

function handlers.UNIT_SPELLCAST_SUCCEEDED(unit, _, spellID)
    if IsDisenchant(unit, spellID) then
        state = "waiting"
        bagsSettled = false
        waited = 0
        if pending and built then
            currentEntry = S.Record(db, session, {
                itemID = pending.itemID, name = pending.name, link = pending.link,
                quality = pending.quality, level = pending.level, character = playerName,
                realm = playerRealm,
            }, time())
            if earlyLoot then
                S.AddLoot(db, currentEntry, earlyLoot)
                earlyLoot = nil
            end
            OnRecorded()
        end
    end
end

--- The status line after a failed cast. The item stays on the list: most failures (moving,
-- another cast, combat) say nothing about the item. One the game won't take, the player unchecks.
-- @param reason the game's red error text, or nil when it hasn't come
-- @return the status text
local function FailText(reason)
    if reason and not reason:find("[.!?]$") then
        reason = reason .. "." -- the game's text often has no period
    end
    return "Disenchant failed" .. (reason and (": " .. reason) or ".")
        .. " If the game won't disenchant this item, uncheck it."
end

function handlers.UNIT_SPELLCAST_FAILED(unit, _, spellID)
    if IsDisenchant(unit, spellID) and state ~= "waiting" then
        local reason = lastError
        lastError = nil
        awaitingReason = reason == nil
        Unlock(FailText(reason))
    end
end

-- The game's red error text. It can come just before or just after the failed cast.
function handlers.UI_ERROR_MESSAGE(_, message)
    if awaitingReason then
        awaitingReason = false
        Status(FailText(message))
    elseif pending then
        lastError = message
    end
end

function handlers.UNIT_SPELLCAST_INTERRUPTED(unit, _, spellID)
    if IsDisenchant(unit, spellID) and state == "casting" then
        Unlock("Disenchant stopped. Click again to retry.")
    end
end

-- A cast that ends without an error message: unlock, and keep the item on the list.
handlers.UNIT_SPELLCAST_FAILED_QUIET = handlers.UNIT_SPELLCAST_INTERRUPTED

--- What the open loot window holds.
-- @return list of { name, link, quantity, quality }
local function ReadLoot()
    local loot = {}
    for slot = 1, GetNumLootItems() or 0 do
        local _, name, quantity, _, quality = GetLootSlotInfo(slot)
        if name and quantity and quantity > 0 then
            loot[#loot + 1] = { name = name, link = GetLootSlotLink(slot), quantity = quantity, quality = quality }
        end
    end
    return loot
end

function handlers.LOOT_READY()
    lootOpen = true
    if state == "idle" then
        return
    end
    lootSeen = true
    if currentEntry then
        S.AddLoot(db, currentEntry, ReadLoot())
        OnRecorded()
    elseif state == "casting" and pending then
        earlyLoot = ReadLoot()
    end
end

function handlers.LOOT_CLOSED()
    lootOpen = false
    TryUnlock()
end

function handlers.PLAYER_REGEN_DISABLED()
    if built then
        Status("In combat. Disenchanting waits until the fight ends.")
    end
end

function handlers.PLAYER_REGEN_ENABLED()
    if not built and db then
        BuildFrame()
    end
    if not built then
        return
    end
    ClearCast(selectedButton)
    ClearCast(nextButton)
    if wanted.shown ~= nil then
        SetShown(wanted.shown)
    end
    SelectTab(currentTab)
    Status("")
    Refresh()
end

local eventFrame = CreateFrame("Frame")
for event in pairs(handlers) do
    eventFrame:RegisterEvent(event)
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
    handlers[event](...)
end)
-- Only unlocks the buttons if the game never sends the end of the cast, or the loot and bag
-- news after it; it never casts. It counts from the cast's start and again from its success.
eventFrame:SetScript("OnUpdate", function(_, elapsed)
    if state == "idle" or lootOpen then
        return
    end
    waited = waited + elapsed
    if waited >= UNLOCK_AFTER then
        Unlock("Ready. Click for the next item.")
    end
end)

-- /unmaker and the short /um open or close the window. No other Forever addon or
-- Blizzard command was found using /um (checked 2026-11-15).
SLASH_UNMAKER1 = "/unmaker"
SLASH_UNMAKER2 = "/um"
SlashCmdList.UNMAKER = Toggle

_G.BINDING_HEADER_UNMAKER = "Unmaker"
_G["BINDING_NAME_CLICK UnmakerNextButton:LeftButton"] = "Disenchant next checked item"
