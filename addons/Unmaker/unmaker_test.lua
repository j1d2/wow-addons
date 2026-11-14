--[[
Offline checks for Unmaker.lua, with a small fake of the game: bags, item data, spell and loot
events, combat lockdown, and Blizzard's secure button (PreClick, then the cast it is set to,
then PostClick). The game does not load this file.
Run: lua5.1 unmaker_test.lua
]]

local folder = arg[0]:match("^(.*)/") or "."
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

-- The fake game ------------------------------------------------------------------------------

local world -- reset by Load() for each scenario

local FrameMethods = {}
FrameMethods.__index = FrameMethods

--- Makes a fake frame, texture or font string with empty state.
-- @param kind "Frame", "Button", "CheckButton", "Texture" or "FontString"
-- @param name global name, or nil
-- @param parent parent frame, or nil
-- @param template template names, or nil
-- @return the fake
local function NewFrame(kind, name, parent, template)
    local f = setmetatable({ kind = kind, name = name, parent = parent, template = template or "",
        scripts = {}, attributes = {}, shown = true, enabled = true, events = {}, children = {} }, FrameMethods)
    f.secure = f.template:find("SecureActionButtonTemplate", 1, true) ~= nil
    if parent then
        parent.children[#parent.children + 1] = f
    end
    if name then
        _G[name] = f
    end
    world.frames[#world.frames + 1] = f
    return f
end

function FrameMethods:SetScript(event, fn) self.scripts[event] = fn end
function FrameMethods:GetScript(event) return self.scripts[event] end
function FrameMethods:Show() self.shown = true end
function FrameMethods:Hide() self.shown = false end
function FrameMethods:SetShown(shown) self.shown = shown and true or false end
function FrameMethods:IsShown() return self.shown end
function FrameMethods:SetText(text) self.text = text end
function FrameMethods:GetText() return self.text end
function FrameMethods:SetEnabled(enabled) self.enabled = enabled and true or false end
function FrameMethods:IsEnabled() return self.enabled end
function FrameMethods:SetChecked(checked) self.checked = checked and true or false end
function FrameMethods:GetChecked() return self.checked end
function FrameMethods:SetTexture(texture) self.texture = texture end
function FrameMethods:RegisterEvent(event) self.events[event] = true end
function FrameMethods:RegisterForClicks(...) self.clicks = table.concat({ ... }, ",") end
function FrameMethods:SetAttribute(key, value)
    if world.inCombat and self:IsProtected() then
        world.blocked = world.blocked + 1
        return
    end
    self.attributes[key] = value
end
function FrameMethods:GetAttribute(key) return self.attributes[key] end
function FrameMethods:IsProtected()
    if self.secure then
        return true
    end
    for _, child in ipairs(self.children) do
        if child:IsProtected() then
            return true
        end
    end
    return false
end
function FrameMethods:CreateTexture() return NewFrame("Texture", nil, self) end
function FrameMethods:CreateFontString() return NewFrame("FontString", nil, self) end
-- Moving a frame makes it "user placed", as in the game; dropping it anchors it where
-- world.dropAt says, the way the game re-anchors a dragged frame.
function FrameMethods:StartMoving() self.moving = true; self.userPlaced = true end
function FrameMethods:StopMovingOrSizing()
    self.moving = false
    if world.dropAt then
        self.point = world.dropAt
    end
end
function FrameMethods:SetUserPlaced(placed) self.userPlaced = placed end
function FrameMethods:ClearAllPoints() self.point = nil end
function FrameMethods:SetPoint(...) self.point = { ... } end
function FrameMethods:GetPoint() return unpack(self.point or {}) end
for _, method in ipairs({ "SetSize", "SetAllPoints", "SetColorTexture", "SetJustifyH", "SetJustifyV",
    "SetHeight", "SetWidth", "SetWordWrap",
    "RegisterForDrag", "EnableMouse", "EnableMouseWheel", "SetMovable",
    "SetClampedToScreen", "SetFrameStrata", "SetTitle", "SetPortraitToAsset", "SetID" }) do
    FrameMethods[method] = function() end
end

--- A mouse click as the game runs it: PreClick, then for a secure button the action its
-- attributes describe, then OnClick and PostClick.
-- @param button the fake button
local function Click(button)
    local pre = button:GetScript("PreClick")
    if pre then
        pre(button, "LeftButton", false)
    end
    if button.secure and button.attributes.type == "spell" then
        world.casts[#world.casts + 1] = { spell = button.attributes.spell,
            bag = button.attributes["target-bag"], slot = button.attributes["target-slot"] }
    end
    local on = button:GetScript("OnClick")
    if on then
        on(button, "LeftButton", false)
    end
    local post = button:GetScript("PostClick")
    if post then
        post(button, "LeftButton", false)
    end
end

--- A bag item in the fake bags.
-- @param itemID item ID
-- @param name item name
-- @param quality 0 to 7
-- @param fields optional extras: classID, equipLoc, bound, link
-- @return the item record
local function Gear(itemID, name, quality, fields)
    fields = fields or {}
    return { itemID = itemID, itemName = name, quality = quality, isBound = fields.bound or false,
        hyperlink = fields.link or ("|Hitem:" .. itemID .. "|h[" .. name .. "]|h"), iconFileID = itemID,
        classID = fields.classID or 4, equipLoc = fields.equipLoc or "INVTYPE_CHEST" }
end

--- Put the fake game in place and load the addon files fresh.
-- @param setup optional table: bags = { [bag] = { [slot] = record } }, knows, sets, db
local function Load(setup)
    setup = setup or {}
    -- Named frames from the last scenario must not leak into this one.
    for _, f in ipairs(world and world.frames or {}) do
        if f.name then
            _G[f.name] = nil
        end
    end
    world = { frames = {}, casts = {}, blocked = 0, inCombat = false, callbacks = {}, now = 1000, loot = {},
        bags = setup.bags or {}, knows = setup.knows ~= false, sets = setup.sets or {} }
    _G.UnmakerDB = setup.db
    _G.UIParent = NewFrame("Frame", "UIParent")
    _G.ContainerFrame1 = NewFrame("Frame", "ContainerFrame1")
    _G.ContainerFrameCombinedBags = NewFrame("Frame", "ContainerFrameCombinedBags")
    _G.CreateFrame = function(kind, name, parent, template)
        return NewFrame(kind, name, parent, template)
    end
    _G.InCombatLockdown = function() return world.inCombat end
    _G.GetTime = function() return world.now end
    _G.time = function() return 1762900000 + world.now end
    _G.UnitName = function() return "Tester" end
    _G.GetNumLootItems = function() return #world.loot end
    _G.GetLootSlotInfo = function(slot)
        local mat = world.loot[slot]
        return mat.icon, mat.name, mat.quantity, nil, mat.quality
    end
    _G.GetLootSlotLink = function(slot) return "|Hitem:9|h[" .. world.loot[slot].name .. "]|h" end
    _G.C_SpellBook = { ContainsAnyDisenchantSpell = function() return world.knows end }
    _G.C_Container = {
        GetContainerNumSlots = function(bag) return world.bags[bag] and 16 or 0 end,
        GetContainerItemInfo = function(bag, slot) return world.bags[bag] and world.bags[bag][slot] end,
    }
    _G.C_Item = {
        GetItemInfoInstant = function(itemID)
            for _, bag in pairs(world.bags) do
                for _, record in pairs(bag) do
                    if record.itemID == itemID then
                        return itemID, "", "", record.equipLoc, record.iconFileID, record.classID, 0
                    end
                end
            end
        end,
        IsCosmeticItem = function() return false end,
        GetCurrentItemLevel = function() return 20 end,
    }
    _G.ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
    _G.C_EquipmentSet = {
        GetEquipmentSetIDs = function() return { 1 } end,
        GetItemIDs = function() return world.sets end,
    }
    _G.GameTooltip = { SetOwner = function() end, SetBagItem = function(_, bag, slot)
        world.tooltip = bag .. ":" .. slot end, Show = function() end, Hide = function() world.tooltip = nil end,
        SetHyperlink = function(_, link) world.tooltip = link end,
        AddLine = function(_, text) world.tooltipLine = text end }
    _G.PanelTemplates_SetNumTabs = function() end
    _G.PanelTemplates_SetTab = function(_, id) world.tab = id end
    _G.PanelTemplates_TabResize = function() end
    _G.EventRegistry = { RegisterCallback = function(_, event, fn) world.callbacks[event] = fn end }
    _G.SlashCmdList = {}
    _G.UnmakerRules = nil
    _G.UnmakerStats = nil
    dofile(folder .. "/UnmakerRules.lua")
    dofile(folder .. "/UnmakerStats.lua")
    dofile(folder .. "/Unmaker.lua")
    for _, f in ipairs(world.frames) do
        if f.events.ADDON_LOADED then
            world.events = f
        end
    end
end

--- Fire a game event at the addon.
-- @param event event name
-- @param ... event arguments
local function Fire(event, ...)
    -- The game only sends events the frame registered for.
    if world.events.events[event] then
        world.events:GetScript("OnEvent")(world.events, event, ...)
    end
end

--- Load the addon and start the session, as the game does after login.
-- @param setup as for Load
local function Start(setup)
    Load(setup)
    Fire("ADDON_LOADED", "Unmaker")
    Fire("PLAYER_ENTERING_WORLD")
end

--- The window's list rows that are shown, top first.
-- @return list of row frames
local function ShownRows()
    local shown = {}
    for _, f in ipairs(world.frames) do
        if f.kind == "Button" and f.nameText and f.shown then
            shown[#shown + 1] = f
        end
    end
    return shown
end

--- The full text of the window's count and status lines.
-- @return count text, status text
local function Lines()
    local count, status
    for _, f in ipairs(world.frames) do
        if f.kind == "FontString" and f.parent == _G.UnmakerNextButton.parent then
            if count == nil then
                count = f.text
            else
                status = f.text
            end
        end
    end
    return count or "", status or ""
end

--- The bags most scenarios use: a green, a blue, an epic, a soulbound green and a potion.
-- @return bags table for Load
local function StandardBags()
    return {
        [0] = {
            [1] = Gear(11, "Green Vest", 2),
            [2] = Gear(12, "Blue Ring", 3, { equipLoc = "INVTYPE_FINGER" }),
            [3] = Gear(13, "Purple Axe", 4, { classID = 2, equipLoc = "INVTYPE_2HWEAPON" }),
        },
        [1] = {
            [1] = Gear(14, "Bound Boots", 2, { bound = true, equipLoc = "INVTYPE_FEET" }),
            [2] = Gear(15, "Potion", 1, { classID = 0, equipLoc = "" }),
        },
    }
end

--- A whole successful disenchant, from the cast starting to the bags settling. The item
-- leaves the bags, as it does in the game.
-- @param bag bag of the item
-- @param slot slot of the item
-- @param loot optional loot window contents: list of { name, quantity, quality }
local function FinishCast(bag, slot, loot)
    world.loot = loot or {}
    Fire("UNIT_SPELLCAST_START", "player", "guid", 13262)
    Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 13262)
    world.bags[bag][slot] = nil
    Fire("LOOT_READY")
    Fire("LOOT_CLOSED")
    Fire("BAG_UPDATE_DELAYED")
end

-- Scenarios ------------------------------------------------------------------------------------

do
    Start({ bags = StandardBags() })
    local frame = _G.UnmakerFrame
    Check("the window starts hidden", not frame.shown)
    _G.SlashCmdList.UNMAKER("")
    Check("/unmaker opens the window", frame.shown)
    local shown = ShownRows()
    Check("the list shows the four items that can be disenchanted", #shown == 4)
    Check("best quality first", shown[1].row.name == "Purple Axe" and shown[2].row.name == "Blue Ring")
    Check("the epic and the soulbound item start unchecked, the others checked",
        shown[1].check.checked == false and shown[2].check.checked == true
        and shown[3].check.checked == false and shown[4].check.checked == true)
    local count = Lines()
    Check("the count line says how many are checked", count:find("2 of 4 checked", 1, true) ~= nil)
    Check("Disenchant next shows how many are left", _G.UnmakerNextButton.text == "Disenchant next (2)")
    Check("Disenchant selected waits for a row to be chosen", not _G.UnmakerSelectedButton.enabled)
    _G.SlashCmdList.UNMAKER("")
    Check("/unmaker again closes it", not frame.shown)
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    Click(_G.UnmakerNextButton)
    Check("Disenchant next casts Disenchant on the first checked item", #world.casts == 1
        and world.casts[1].spell == 13262 and world.casts[1].bag == 0 and world.casts[1].slot == 2)
    Check("the button is cleared after the click", _G.UnmakerNextButton.attributes.type == nil
        and _G.UnmakerNextButton.attributes["target-slot"] == nil)
    Fire("UNIT_SPELLCAST_START", "player", "guid", 13262)
    Check("the buttons lock while the cast runs", not _G.UnmakerNextButton.enabled)
    local _, status = Lines()
    Check("the status line names the item", status:find("Blue Ring", 1, true) ~= nil)
    Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 13262)
    world.bags[0][2] = nil
    Fire("LOOT_READY")
    Fire("BAG_UPDATE_DELAYED")
    Check("still locked while the loot window is open", not _G.UnmakerNextButton.enabled)
    Click(_G.UnmakerNextButton)
    Check("a click while locked casts nothing", #world.casts == 1)
    Fire("LOOT_CLOSED")
    Check("unlocked once the loot is closed and the bags settled", _G.UnmakerNextButton.enabled)
    Check("the item is gone from the list", #ShownRows() == 3)
    Click(_G.UnmakerNextButton)
    Check("the next click goes to the next checked item", #world.casts == 2 and world.casts[2].slot == 1)
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    FinishCast(0, 2)
    Check("loot then bags in the usual order also unlocks", _G.UnmakerNextButton.enabled)
    world.events:GetScript("OnUpdate")(world.events, 1)
    Check("the safety timer does nothing when idle", _G.UnmakerNextButton.enabled)
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    Click(_G.UnmakerNextButton)
    Fire("UNIT_SPELLCAST_START", "player", "guid", 13262)
    Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 13262)
    local onUpdate = world.events:GetScript("OnUpdate")
    onUpdate(world.events, 4)
    Check("before the safety time the buttons stay locked", not _G.UnmakerNextButton.enabled)
    onUpdate(world.events, 7)
    Check("if no loot or bag news comes, the buttons unlock after 10 seconds", _G.UnmakerNextButton.enabled)
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    Click(_G.UnmakerNextButton)
    Fire("UNIT_SPELLCAST_START", "player", "guid", 13262)
    Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 13262)
    world.bags[0][2] = nil
    Fire("BAG_UPDATE_DELAYED")
    Check("the item leaving the bags before the loot window opens doesn't unlock", not _G.UnmakerNextButton.enabled)
    Fire("LOOT_READY")
    Fire("LOOT_CLOSED")
    Check("it unlocks once that loot window has closed", _G.UnmakerNextButton.enabled)
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    Click(_G.UnmakerNextButton)
    Fire("UNIT_SPELLCAST_START", "player", "guid", 13262)
    Fire("UNIT_SPELLCAST_FAILED_QUIET", "player", "guid", 13262)
    Check("a cast that fails quietly unlocks and keeps the item", _G.UnmakerNextButton.enabled and #ShownRows() == 4)
    Click(_G.UnmakerNextButton)
    Fire("UNIT_SPELLCAST_START", "player", "guid", 13262)
    world.events:GetScript("OnUpdate")(world.events, 11)
    Check("a cast that ends with no news unlocks after 10 seconds", _G.UnmakerNextButton.enabled)
end

do
    Start({ bags = StandardBags() })
    Check("only a left click casts", _G.UnmakerNextButton.clicks == "LeftButtonUp"
        and _G.UnmakerSelectedButton.clicks == "LeftButtonUp")
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    local blue = ShownRows()[2]
    world.bags[0][2] = Gear(99, "Something Else", 2)
    Click(_G.UnmakerNextButton)
    Check("if the slot holds a different item now, nothing is cast", #world.casts == 0)
    local _, status = Lines()
    Check("and the status line says the bags changed", status:find("bags changed", 1, true) ~= nil)
    Check("and the list is read again", blue.row == nil or blue.row.name ~= "Blue Ring")
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    local axe = ShownRows()[1]
    axe:GetScript("OnClick")(axe)
    Check("clicking a row selects it", axe.highlight.shown)
    Check("Disenchant selected stays off while the selected row is unchecked", not _G.UnmakerSelectedButton.enabled)
    Click(_G.UnmakerSelectedButton)
    Check("Disenchant selected won't touch an unchecked item", #world.casts == 0)
    local _, status = Lines()
    Check("and says to check it first", status:find("first", 1, true) ~= nil)
    axe.check:SetChecked(true)
    axe.check:GetScript("OnClick")(axe.check)
    Check("checking it turns Disenchant selected on", _G.UnmakerSelectedButton.enabled)
    Click(_G.UnmakerSelectedButton)
    Check("once checked, Disenchant selected casts on that item", #world.casts == 1
        and world.casts[1].bag == 0 and world.casts[1].slot == 3)
    axe:GetScript("OnEnter")(axe)
    Check("hovering a row shows that bag item's tooltip", world.tooltip == "0:3")
    axe:GetScript("OnLeave")(axe)
    Check("leaving hides it", world.tooltip == nil)
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    local green = ShownRows()[4]
    green.check:SetChecked(false)
    green.check:GetScript("OnClick")(green.check)
    Check("unchecking saves the item as kept", _G.UnmakerDB.kept[11] == true)
    Check("and the count drops", _G.UnmakerNextButton.text == "Disenchant next (1)")
    local db = _G.UnmakerDB
    Start({ bags = StandardBags(), db = db })
    _G.SlashCmdList.UNMAKER("")
    Check("after a reload the kept item is still unchecked", ShownRows()[4].check.checked == false)
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    Click(_G.UnmakerNextButton)
    Fire("UI_ERROR_MESSAGE", 50, "Can't do that while moving")
    Fire("UNIT_SPELLCAST_FAILED", "player", "guid", 13262)
    Check("a failed cast keeps the item on the list", #ShownRows() == 4)
    local _, status = Lines()
    Check("and the status line gives the game's reason, ending in a period",
        status:find("Can't do that while moving. If", 1, true) ~= nil)
    Check("the buttons unlock after a failure", _G.UnmakerNextButton.enabled)
    Click(_G.UnmakerNextButton)
    Fire("UNIT_SPELLCAST_FAILED", "player", "guid", 13262)
    Fire("UI_ERROR_MESSAGE", 51, "That item is not a valid target.")
    _, status = Lines()
    Check("the reason shows when the game's message comes after the failure",
        status:find("not a valid target", 1, true) ~= nil and #ShownRows() == 4)
    Fire("UI_ERROR_MESSAGE", 52, "Not enough rage")
    _, status = Lines()
    Check("a later, unrelated error message doesn't change the status line",
        status:find("not a valid target", 1, true) ~= nil)
    Click(_G.UnmakerNextButton)
    Fire("UNIT_SPELLCAST_START", "player", "guid", 13262)
    Fire("UNIT_SPELLCAST_INTERRUPTED", "player", "guid", 13262)
    Check("an interrupted cast unlocks and keeps the item", _G.UnmakerNextButton.enabled and #ShownRows() == 4)
    Fire("UNIT_SPELLCAST_START", "party1", "guid", 13262)
    Fire("UNIT_SPELLCAST_START", "player", "guid", 999)
    Check("other people's casts and other spells are ignored", _G.UnmakerNextButton.enabled)
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    world.inCombat = true
    Fire("PLAYER_REGEN_DISABLED")
    Click(_G.UnmakerNextButton)
    Check("in combat a click casts nothing", #world.casts == 0)
    _G.SlashCmdList.UNMAKER("")
    Check("in combat the window can't close, so it waits", _G.UnmakerFrame.shown)
    world.inCombat = false
    Fire("PLAYER_REGEN_ENABLED")
    Check("after the fight it closes as asked", not _G.UnmakerFrame.shown)
    Check("nothing touched a protected button in combat", world.blocked == 0)
end

do
    Load({ bags = StandardBags() })
    world.inCombat = true
    Fire("ADDON_LOADED", "Unmaker")
    Check("loaded in combat, the window waits to be built", _G.UnmakerFrame == nil)
    _G.SlashCmdList.UNMAKER("")
    world.inCombat = false
    Fire("PLAYER_REGEN_ENABLED")
    Check("after the fight it is built and opens as asked", _G.UnmakerFrame ~= nil and _G.UnmakerFrame.shown)
end

do
    Start({ bags = StandardBags(), knows = false })
    _G.SlashCmdList.UNMAKER("")
    local count = Lines()
    Check("without Disenchant the window says to learn Enchanting", count:find("Learn Enchanting", 1, true) ~= nil)
    Check("and both buttons stay off", not _G.UnmakerNextButton.enabled and not _G.UnmakerSelectedButton.enabled)
    Click(_G.UnmakerNextButton)
    Check("a click casts nothing", #world.casts == 0)
end

do
    Start({ bags = {} })
    _G.SlashCmdList.UNMAKER("")
    local count = Lines()
    Check("empty bags say there is nothing to disenchant", count:find("Nothing in your bags", 1, true) ~= nil)
end

do
    Start({ bags = StandardBags(), sets = { 12 } })
    _G.SlashCmdList.UNMAKER("")
    Check("items in an equipment set are hidden", #ShownRows() == 3)
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    _G.UnmakerFrameTab4:GetScript("OnClick")(_G.UnmakerFrameTab4)
    Check("the Settings tab shows its checkboxes", world.tab == 4)
    local countLine
    for _, f in ipairs(world.frames) do
        if f.kind == "FontString" and f.text and f.text:find("of %d+ checked") then
            countLine = f
        end
    end
    Check("the count line belongs to the Items tab, so it hides on Settings",
        countLine ~= nil and countLine.parent.shown == false)
    local boxes = {}
    for _, f in ipairs(world.frames) do
        if f.kind == "CheckButton" and f.key then
            boxes[f.key] = f
        end
    end
    Check("each setting has a checkbox showing its value", boxes.keepEpics.checked == true
        and boxes.openOnBags.checked == false)
    boxes.keepEpics:SetChecked(false)
    boxes.keepEpics:GetScript("OnClick")(boxes.keepEpics)
    Check("turning off Keep epics saves it", _G.UnmakerDB.settings.keepEpics == false)
    _G.UnmakerFrameTab1:GetScript("OnClick")(_G.UnmakerFrameTab1)
    Check("and the epic is checked now", ShownRows()[1].check.checked == true)
end

do
    Start({ bags = StandardBags() })
    world.callbacks["ContainerFrame.OpenAllBags"]()
    Check("opening bags doesn't open Unmaker while that setting is off", not _G.UnmakerFrame.shown)
    _G.UnmakerDB.settings.openOnBags = true
    world.callbacks["ContainerFrame.OpenBag"]()
    Check("with Open with my bags on, it opens when there is something to disenchant", _G.UnmakerFrame.shown)
    local bagButton
    for _, f in ipairs(world.frames) do
        if f.parent == _G.ContainerFrameCombinedBags and f.text == "Unmaker" then
            bagButton = f
        end
    end
    Check("the bag window has an Unmaker button", bagButton ~= nil)
    bagButton:GetScript("OnClick")(bagButton)
    Check("which closes and opens the window", not _G.UnmakerFrame.shown)
end

do
    Start({ bags = StandardBags() })
    _G.UnmakerDB.settings.openOnLoot = true
    Fire("BAG_UPDATE_DELAYED")
    Check("bag updates with nothing new don't open it", not _G.UnmakerFrame.shown)
    world.bags[2] = { [1] = Gear(21, "New Gloves", 2, { equipLoc = "INVTYPE_HAND" }) }
    Fire("BAG_UPDATE_DELAYED")
    Check("with Open when I loot on, new gear opens it", _G.UnmakerFrame.shown)
end

do
    -- Settings are shared by every character, so an alt without Enchanting has them on too.
    Start({ bags = StandardBags(), knows = false })
    _G.UnmakerDB.settings.openOnLoot = true
    _G.UnmakerDB.settings.openOnBags = true
    Fire("BAG_UPDATE_DELAYED")
    world.bags[2] = { [1] = Gear(21, "New Gloves", 2, { equipLoc = "INVTYPE_HAND" }) }
    Fire("BAG_UPDATE_DELAYED")
    Check("Open when I loot does nothing on a character without Disenchant", not _G.UnmakerFrame.shown)
    world.callbacks["ContainerFrame.OpenBag"]()
    Check("Open with my bags does nothing on a character without Disenchant", not _G.UnmakerFrame.shown)
    _G.SlashCmdList.UNMAKER("")
    Check("but /unmaker still opens it there", _G.UnmakerFrame.shown)
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    local panel = _G.UnmakerNextButton.parent
    for slot = 4, 16 do
        world.bags[0][slot] = Gear(100 + slot, "Extra " .. string.format("%02d", slot), 2)
    end
    Fire("BAG_UPDATE_DELAYED")
    local first = ShownRows()[1].row.name
    panel:GetScript("OnMouseWheel")(panel, -1)
    Check("the mouse wheel scrolls the list", ShownRows()[1].row.name ~= first)
    panel:GetScript("OnMouseWheel")(panel, 1)
    Check("and back", ShownRows()[1].row.name == first)
    _G.UnmakerFrame:GetScript("OnDragStart")(_G.UnmakerFrame)
    Check("the window can be dragged", _G.UnmakerFrame.moving)
    _G.UnmakerFrame:GetScript("OnDragStop")(_G.UnmakerFrame)
    Check("and dropped", not _G.UnmakerFrame.moving)
end

do
    Start({ bags = StandardBags() })
    local point = _G.UnmakerFrame.point
    Check("the window starts in the middle of the screen", point[1] == "CENTER" and point[2] == _G.UIParent
        and point[4] == 0 and point[5] == 0)
    world.dropAt = { "TOPLEFT", _G.UIParent, "TOPLEFT", 120.5, -80 }
    _G.UnmakerFrame:GetScript("OnDragStart")(_G.UnmakerFrame)
    _G.UnmakerFrame:GetScript("OnDragStop")(_G.UnmakerFrame)
    local saved = _G.UnmakerDB.position
    Check("dropping the window saves where it is", saved ~= nil and saved.point == "TOPLEFT"
        and saved.relativePoint == "TOPLEFT" and saved.x == 120.5 and saved.y == -80)
    Check("and Unmaker keeps the spot itself, not the game's layout file", _G.UnmakerFrame.userPlaced == false)

    local db = _G.UnmakerDB
    Start({ bags = StandardBags(), db = db })
    point = _G.UnmakerFrame.point
    Check("after a reload the window opens where it was left", point[1] == "TOPLEFT"
        and point[2] == _G.UIParent and point[3] == "TOPLEFT" and point[4] == 120.5 and point[5] == -80)

    Start({ bags = StandardBags() })
    _G.UnmakerFrame:GetScript("OnDragStart")(_G.UnmakerFrame)
    world.inCombat = true
    world.dropAt = { "BOTTOM", _G.UIParent, "BOTTOM", 5, 5 }
    _G.UnmakerFrame:GetScript("OnDragStop")(_G.UnmakerFrame)
    Check("a drop that the game blocks in combat saves nothing", _G.UnmakerDB.position == nil)
end

--- The text of the window's line that starts with "Unmade:".
-- @return the text, or ""
local function UnmadeLine()
    for _, f in ipairs(world.frames) do
        if f.kind == "FontString" and f.text and f.text:find("^Unmade:") then
            return f.text
        end
    end
    return ""
end

--- Every text on a panel's own font strings and on its children's, joined.
-- @param panel a fake frame
-- @return all the text
local function PanelText(panel)
    local parts = {}
    local function Walk(f)
        if f.text then
            parts[#parts + 1] = f.text
        end
        for _, child in ipairs(f.children) do
            if child.shown ~= false then
                Walk(child)
            end
        end
    end
    Walk(panel)
    return table.concat(parts, "\n")
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    Check("before any disenchant the Unmade line shows zeros", UnmadeLine():find("0 this session", 1, true) ~= nil)
    Click(_G.UnmakerNextButton)
    FinishCast(0, 2, { { name = "Strange Dust", quantity = 2, quality = 1 } })
    local db = _G.UnmakerDB
    Check("a disenchant through Unmaker is recorded", db.stats.total == 1 and #db.history == 1
        and db.history[1].name == "Blue Ring" and db.history[1].character == "Tester")
    Check("with the loot it gave", db.history[1].mats[1] and db.history[1].mats[1].name == "Strange Dust"
        and db.stats.mats["Strange Dust"].count == 2)
    Check("the Unmade line counts it", UnmadeLine():find("1 this session", 1, true) ~= nil
        and UnmadeLine():find("1 lifetime", 1, true) ~= nil)

    Fire("UNIT_SPELLCAST_START", "player", "guid", 13262)
    Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 13262)
    Check("a Disenchant cast from the spellbook isn't recorded", db.stats.total == 1)
    Fire("LOOT_READY")
    Fire("LOOT_CLOSED")
    Fire("BAG_UPDATE_DELAYED")

    Click(_G.UnmakerNextButton)
    world.now = world.now + 5
    Fire("UNIT_SPELLCAST_START", "player", "guid", 13262)
    Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 13262)
    Check("a cast that starts long after a click isn't credited to that item", db.stats.total == 1)
    Fire("LOOT_READY")
    Fire("LOOT_CLOSED")
    Fire("BAG_UPDATE_DELAYED")

    Click(_G.UnmakerNextButton)
    Fire("UNIT_SPELLCAST_FAILED", "player", "guid", 13262)
    Check("a failed cast isn't recorded", db.stats.total == 1)
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    Click(_G.UnmakerNextButton)
    world.loot = { { name = "Lesser Magic Essence", quantity = 1, quality = 2 } }
    Fire("UNIT_SPELLCAST_START", "player", "guid", 13262)
    Fire("LOOT_READY")
    Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 13262)
    Check("loot that shows before the cast reports success is still recorded",
        _G.UnmakerDB.history[1].mats[1] and _G.UnmakerDB.history[1].mats[1].name == "Lesser Magic Essence")
end

do
    Start({ bags = StandardBags() })
    _G.SlashCmdList.UNMAKER("")
    Click(_G.UnmakerNextButton)
    FinishCast(0, 2, { { name = "Strange Dust", quantity = 2, quality = 1 } })
    Click(_G.UnmakerNextButton)
    FinishCast(0, 1, { { name = "Strange Dust", quantity = 1, quality = 1 } })

    _G.UnmakerFrameTab2:GetScript("OnClick")(_G.UnmakerFrameTab2)
    Check("tab 2 is Stats", world.tab == 2)
    local statsPanel
    for _, f in ipairs(world.frames) do
        if f.parent == _G.UnmakerFrame and f.isStats then
            statsPanel = f
        end
    end
    local text = statsPanel and PanelText(statsPanel) or ""
    Check("the Stats tab shows lifetime and quality counts", text:find("Lifetime", 1, true) ~= nil
        and text:find("Uncommon", 1, true) ~= nil)
    Check("and lifetime materials", text:find("3 Strange Dust", 1, true) ~= nil
        or (text:find("Strange Dust", 1, true) ~= nil and text:find("3", 1, true) ~= nil))
    Check("the Items list hides on the Stats tab", _G.UnmakerNextButton.parent.shown == false)

    _G.UnmakerFrameTab3:GetScript("OnClick")(_G.UnmakerFrameTab3)
    Check("tab 3 is History", world.tab == 3)
    local historyRows = {}
    local headers = {}
    for _, f in ipairs(world.frames) do
        if f.historyRow and f.shown then
            historyRows[#historyRows + 1] = f
        end
        if f.sortKey then
            headers[f.sortKey] = f
        end
    end
    Check("History lists both disenchants", #historyRows == 2)
    Check("newest first by default", historyRows[1].entry.name == "Green Vest")
    headers.name:GetScript("OnClick")(headers.name)
    Check("clicking the Item heading sorts by name", historyRows[1].entry.name == "Blue Ring")
    headers.time:GetScript("OnClick")(headers.time)
    Check("clicking the When heading sorts newest first again", historyRows[1].entry.name == "Green Vest")
    Check("each row shows its loot", historyRows[1].lootText.text:find("Strange Dust", 1, true) ~= nil)
    historyRows[1]:GetScript("OnEnter")(historyRows[1])
    Check("hovering a history row shows the item and who unmade it",
        world.tooltip ~= nil and world.tooltipLine ~= nil and world.tooltipLine:find("Tester", 1, true) ~= nil)
    historyRows[1]:GetScript("OnLeave")(historyRows[1])
end

do
    Load({})
    Check("the key binding has a name in the game's Key Bindings menu",
        _G["BINDING_NAME_CLICK UnmakerNextButton:LeftButton"] ~= nil and _G.BINDING_HEADER_UNMAKER == "Unmaker")
    Fire("ADDON_LOADED", "SomeOtherAddon")
    Check("another addon loading changes nothing", _G.UnmakerFrame == nil)
end

if failed > 0 then
    io.write(string.format("%d failed\n", failed))
    os.exit(1)
end
io.write("all passed\n")
