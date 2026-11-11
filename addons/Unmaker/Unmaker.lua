--[[
Unmaker: a window that lists the gear in your bags you can disenchant, with a checkbox on each
item. "Disenchant next" disenchants the first checked item; "Disenchant selected" the item you
clicked. UnmakerRules.lua holds the logic; this file reads the bags and draws the window.

Blizzard's rules (RULES.md, Disenchanting): every cast needs its own click or key press.
Unmaker never casts. Its two buttons are Blizzard secure buttons: on the player's click, PreClick
sets them to cast Disenchant on one bag slot, Blizzard's own code casts, and PostClick clears
them again. In combat nothing can be set, so a click then does nothing.

The secure buttons make the window protected, so in combat it can't be shown, hidden or moved;
those wait until the fight ends, as in HouseLedger.
]]

local R = UnmakerRules

local DISENCHANT_SPELL = 13262
local BAGS = { 0, 1, 2, 3, 4 } -- the backpack and four bags; the reagent bag holds no gear
local ROW_COUNT = 10
local ROW_HEIGHT = 24
local WIDTH = 380
local HEIGHT = 120 + ROW_COUNT * ROW_HEIGHT
-- After a cast, wait at most this many seconds for the loot and bag news before unlocking
-- the buttons, so a missed event can't leave them stuck.
local UNLOCK_AFTER = 10
local PORTRAIT_ICON = "Interface\\Icons\\INV_Enchant_Disenchant"

local db
local session = R.NewSession()
local rows = {}
local offset = 0
local selected
local state = "idle" -- idle, casting (the cast bar is up) or waiting (loot and bags settling)
local pending
local lootOpen = false
local bagsSettled = false
local waited = 0
local seenLinks
local wanted = {} -- show or hide asked for in combat: { shown = true/false }
local built = false
local currentTab = 1

local frame, itemsPanel, settingsPanel, countText, statusText
local selectedButton, nextButton
local rowFrames = {}
local settingBoxes = {}

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
    return {
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
    selectedButton:SetEnabled(ready and selected ~= nil)
    nextButton:SetEnabled(ready and count > 0)
    nextButton:SetText(count > 0 and string.format("Disenchant next (%d)", count) or "Disenchant next")
end

--- Draw the visible rows, the count and the buttons.
local function Render()
    if not built then
        return
    end
    for index, rowFrame in ipairs(rowFrames) do
        local row = rows[offset + index]
        rowFrame.row = row
        if row then
            rowFrame.icon:SetTexture(row.icon)
            rowFrame.nameText:SetText(row.link or row.name)
            rowFrame.levelText:SetText(row.level and ("ilvl " .. row.level) or "")
            rowFrame.check:SetChecked(row.checked)
            rowFrame.highlight:SetShown(row == selected)
            rowFrame:Show()
        else
            rowFrame:Hide()
        end
    end
    if not KnowsDisenchant() then
        countText:SetText("This character doesn't know Disenchant. Learn Enchanting first.")
    elseif #rows == 0 then
        countText:SetText("Nothing in your bags to disenchant.")
    else
        countText:SetText(string.format("%d of %d checked. One click disenchants one item.",
            R.CountChecked(rows), #rows))
    end
    UpdateButtons()
end

--- Read the bags again and redraw. The selection survives if its item is still in its slot.
local function Refresh()
    if not db then
        return
    end
    rows = R.BuildRows(ScanBags(), db, session, SetItemIDs())
    local keep
    for _, row in ipairs(rows) do
        if selected and row.bag == selected.bag and row.slot == selected.slot and row.link == selected.link then
            keep = row
        end
    end
    selected = keep
    offset = math.max(0, math.min(offset, #rows - ROW_COUNT))
    Render()
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
end

--- Back to idle: unlock the buttons and read the bags again.
-- @param message the status line to show
local function Unlock(message)
    state = "idle"
    pending = nil
    Status(message)
    Refresh()
end

--- After a cast: unlock once the loot window is closed and the bags have updated.
local function TryUnlock()
    if state == "waiting" and bagsSettled and not lootOpen then
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

--- Show the window if it is hidden, hide it if it is shown.
local function Toggle()
    SetShown(not (built and frame:IsShown()))
end

--- Switch between the Items tab (1) and the Settings tab (2).
-- @param id tab number
local function SelectTab(id)
    if Locked(itemsPanel) then
        return
    end
    currentTab = id
    PanelTemplates_SetTab(frame, id)
    itemsPanel:SetShown(id == 1)
    settingsPanel:SetShown(id == 2)
end

--- Build one list row: a checkbox, the icon, the item link and its item level. Clicking the
-- row selects it for "Disenchant selected"; hovering shows the item's tooltip.
-- @param index row position, 1 at the top
-- @return the row frame
local function BuildRow(index)
    local rowFrame = CreateFrame("Button", nil, itemsPanel)
    rowFrame:SetSize(WIDTH - 40, ROW_HEIGHT)
    rowFrame:SetPoint("TOPLEFT", itemsPanel, "TOPLEFT", 4, -(index - 1) * ROW_HEIGHT)

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
    rowFrame.nameText:SetPoint("RIGHT", rowFrame, "RIGHT", -60, 0)
    rowFrame.nameText:SetJustifyH("LEFT")

    rowFrame.levelText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rowFrame.levelText:SetPoint("RIGHT", rowFrame, "RIGHT", -4, 0)

    rowFrame:SetScript("OnClick", function()
        selected = rowFrame.row
        Render()
    end)
    rowFrame:SetScript("OnEnter", function()
        if rowFrame.row then
            GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
            GameTooltip:SetBagItem(rowFrame.row.bag, rowFrame.row.slot)
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
    button:RegisterForClicks("AnyUp")
    button:SetAttribute("useOnKeyDown", false)
    button:SetScript("PreClick", function(self)
        PrepareCast(self, pick())
    end)
    button:SetScript("PostClick", function(self)
        ClearCast(self)
    end)
    return button
end

--- Build the Settings tab: one checkbox per setting.
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
            Refresh()
        end)
        settingBoxes[#settingBoxes + 1] = box
    end
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
end

--- Build the window: the frame, the Items and Settings tabs, the list, the two cast buttons,
-- and the bag window buttons.
local function BuildFrame()
    frame = CreateFrame("Frame", "UnmakerFrame", UIParent, "ButtonFrameTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
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
        end
    end)
    frame:Hide()

    itemsPanel = CreateFrame("Frame", nil, frame)
    itemsPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -64)
    itemsPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 64)
    itemsPanel:EnableMouseWheel(true)
    itemsPanel:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, math.min(offset - delta, #rows - ROW_COUNT))
        Render()
    end)
    for index = 1, ROW_COUNT do
        rowFrames[index] = BuildRow(index)
    end

    countText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 52)
    countText:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
    countText:SetJustifyH("LEFT")
    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", countText, "BOTTOMLEFT", 0, -2)
    statusText:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
    statusText:SetJustifyH("LEFT")

    selectedButton = BuildCastButton("UnmakerSelectedButton", "Disenchant selected", function()
        return selected
    end)
    selectedButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 8)
    nextButton = BuildCastButton("UnmakerNextButton", "Disenchant next", function()
        return R.NextRow(rows)
    end)
    nextButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 8)

    BuildSettings()
    BuildTab(1, "Items"):SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
    BuildTab(2, "Settings"):SetPoint("LEFT", _G.UnmakerFrameTab1, "RIGHT", -14, 0)
    PanelTemplates_SetNumTabs(frame, 2)
    PanelTemplates_SetTab(frame, 1)

    AddBagButton(_G.ContainerFrameCombinedBags)
    AddBagButton(_G.ContainerFrame1)
    built = true
end

--- The links of every row now, to spot new gear for "Open when I loot".
-- @return set of links, { [link] = true }
local function CurrentLinks()
    local links = {}
    for _, row in ipairs(rows) do
        links[row.link] = true
    end
    return links
end

--- After the bags change: redraw, and open the window when new gear to disenchant arrived and
-- "Open when I loot" is on.
local function OnBagsChanged()
    Refresh()
    local links = CurrentLinks()
    if seenLinks and db.settings.openOnLoot then
        for link in pairs(links) do
            if not seenLinks[link] then
                SetShown(true)
                break
            end
        end
    end
    seenLinks = links
end

--- When a Blizzard bag window opens: open Unmaker too if "Open with my bags" is on and there is
-- something to disenchant.
local function OnBagOpened()
    if db and db.settings.openOnBags then
        Refresh()
        if #rows > 0 then
            SetShown(true)
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

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name ~= "Unmaker" then
        return
    end
    db = R.EnsureDB(UnmakerDB)
    UnmakerDB = db
    if not InCombat() then
        BuildFrame()
    end
    if type(EventRegistry) == "table" then
        EventRegistry:RegisterCallback("ContainerFrame.OpenAllBags", OnBagOpened, frame or db)
        EventRegistry:RegisterCallback("ContainerFrame.OpenBag", OnBagOpened, frame or db)
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
        state = "casting"
        Status(pending and ("Disenchanting " .. (pending.link or pending.name) .. "...") or "Disenchanting...")
        UpdateButtons()
    end
end

function handlers.UNIT_SPELLCAST_SUCCEEDED(unit, _, spellID)
    if IsDisenchant(unit, spellID) then
        state = "waiting"
        bagsSettled = false
        waited = 0
    end
end

function handlers.UNIT_SPELLCAST_FAILED(unit, _, spellID)
    if IsDisenchant(unit, spellID) and state ~= "waiting" then
        local row = pending
        if row then
            session.refused[R.SlotKey(row.bag, row.slot)] = row.link
        end
        Unlock(row and ((row.link or row.name) .. " couldn't be disenchanted. It's off the list until you log out.")
            or "Disenchant failed.")
    end
end

function handlers.UNIT_SPELLCAST_INTERRUPTED(unit, _, spellID)
    if IsDisenchant(unit, spellID) and state == "casting" then
        Unlock("Disenchant stopped. Click again to retry.")
    end
end

function handlers.LOOT_READY()
    lootOpen = true
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
-- Only unlocks the buttons if the game never sends the loot and bag news; it never casts.
eventFrame:SetScript("OnUpdate", function(_, elapsed)
    if state ~= "waiting" or lootOpen then
        return
    end
    waited = waited + elapsed
    if waited >= UNLOCK_AFTER then
        Unlock("Ready. Click for the next item.")
    end
end)

SLASH_UNMAKER1 = "/unmaker"
SlashCmdList.UNMAKER = Toggle

_G.BINDING_HEADER_UNMAKER = "Unmaker"
_G["BINDING_NAME_CLICK UnmakerNextButton:LeftButton"] = "Disenchant next checked item"
