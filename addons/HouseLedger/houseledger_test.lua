--[[
Offline checks for HouseLedger's window files (frames, events, scan flow), loaded from the .toc.
The game does not load this file: it is not listed in the .toc.

It fakes just enough of the WoW API (frames, C_AuctionHouse, C_Timer,
a clock) to drive the scan and search code through real event orders.
The main point is the policy limits in RULES.md: one ReplicateItems
call per 15 minutes, no scan on open, one query per click, and no
seller names saved.

Run with the game's Lua version, from anywhere:
    lua5.1 addons/HouseLedger/houseledger_test.lua
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

-- ---------------------------------------------------------------------
-- Fake game world. Setup() rebuilds it and reloads both addon files.
-- ---------------------------------------------------------------------

local world

--- Does nothing; stands in for game methods the tests don't need.
local function Noop() end

--- Methods every fake frame or font string answers.
-- Unknown methods fall through to a no-op so layout calls (SetSize,
-- SetBackdrop...) do not need their own stubs. The one-line methods below
-- only record what they are given.
local FrameMethods = {}

--- Counts a change the game would block.
-- That is addon code changing a protected frame (a secure button, or its
-- parent) during combat. The count is world.blocked.
-- @param object the fake frame being changed
local function NoteIfBlocked(object)
    if world.inCombat and object.protected then
        world.blocked = (world.blocked or 0) + 1
    end
end

function FrameMethods:SetScript(name, fn) self.scripts[name] = fn end
function FrameMethods:GetScript(name) return self.scripts[name] end
function FrameMethods:RegisterEvent(event) self.events[event] = true end
function FrameMethods:Show() NoteIfBlocked(self) self.shown = true end
function FrameMethods:Hide() NoteIfBlocked(self) self.shown = false end
function FrameMethods:IsShown() return self.shown end
function FrameMethods:HasFocus() return self.focused == true end
function FrameMethods:SetFocus() self.focused = true end
function FrameMethods:ClearFocus() self.focused = false end
function FrameMethods:Enable() NoteIfBlocked(self) self.enabled = true end
function FrameMethods:Disable() NoteIfBlocked(self) self.enabled = false end
function FrameMethods:IsProtected() return self.protected == true, false end
function FrameMethods:StartMoving() NoteIfBlocked(self) end
function FrameMethods:StopMovingOrSizing() NoteIfBlocked(self) end
function FrameMethods:SetAttribute(key, value) NoteIfBlocked(self) self.attributes[key] = value end
function FrameMethods:GetAttribute(key) return self.attributes[key] end
function FrameMethods:IsEnabled() return self.enabled end
function FrameMethods:SetText(text) self.text = text end
function FrameMethods:GetText() return self.text end
function FrameMethods:SetPoint(...) NoteIfBlocked(self) self.points[#self.points + 1] = { ... } end
function FrameMethods:ClearAllPoints() NoteIfBlocked(self) self.points = {} end
function FrameMethods:SetClampedToScreen(on) self.clamped = on end
function FrameMethods:SetToplevel(on) self.toplevel = on end
function FrameMethods:SetDontSavePosition(on) self.dontSave = on end
function FrameMethods:SetWordWrap(on) self.wordWrap = on end
function FrameMethods:Raise() NoteIfBlocked(self) self.raised = (self.raised or 0) + 1 end
function FrameMethods:SetWidth(width) NoteIfBlocked(self) self.width = width end
function FrameMethods:GetWidth() return self.width end
function FrameMethods:GetRight() return self.right end
function FrameMethods:GetHeight() return self.height end
function FrameMethods:SetTextColor(r, g, b) self.color = { r, g, b } end
function FrameMethods:SetTexture(texture) self.texture = texture end
function FrameMethods:SetMinMaxValues(min, max) self.min, self.max = min, max end
-- A dropdown keeps the menu generator it was given, as Blizzard's DropdownButton does.
function FrameMethods:SetupMenu(generator) self.menuGenerator = generator end
function FrameMethods:SetChecked(checked) self.checked = checked == true end
function FrameMethods:SetHeight(height) self.height = height end
function FrameMethods:SetItemByID(itemID) self.itemByID = itemID end
function FrameMethods:LockHighlight() self.highlightLocked = true end
function FrameMethods:UnlockHighlight() self.highlightLocked = false end
function FrameMethods:SetColorTexture(r, g, b, a) self.colorTexture = { r, g, b, a } end
function FrameMethods:GetChecked() return self.checked end
function FrameMethods:SetValue(value) self.value = value end

--- Makes a fake frame, font string or texture with empty state.
-- @param kind the frame type, such as "Button" or "FontString"
-- @param name optional global name
-- @return the fake object
local function NewObject(kind, name)
    local object = {
        kind = kind,
        name = name,
        scripts = {},
        events = {},
        points = {},
        attributes = {},
        shown = true,
        enabled = true,
        text = "",
        fontStrings = {},
    }
    return setmetatable(object, {
        -- WoW methods are capitalized (SetSize, SetBackdrop...); unknown
        -- ones become no-ops. Lowercase keys are fake state and stay nil.
        __index = function(_, key)
            if FrameMethods[key] then
                return FrameMethods[key]
            end
            if type(key) == "string" and key:match("^%u") then
                return Noop
            end
            return nil
        end,
    })
end

--- Makes a fake font string and lists it in the owner's fontStrings.
-- @return the font string
function FrameMethods:CreateFontString()
    local fontString = NewObject("FontString")
    self.fontStrings[#self.fontStrings + 1] = fontString
    return fontString
end

--- Makes a fake texture.
-- @return the texture
function FrameMethods:CreateTexture()
    return NewObject("Texture")
end

--- Makes a fake line, recording where it starts and ends.
-- @return the line
function FrameMethods:CreateLine()
    return NewObject("Line")
end
function FrameMethods:SetStartPoint(...) self.startPoint = { ... } end
function FrameMethods:SetEndPoint(...) self.endPoint = { ... } end

--- Builds one listing for the fake replicate list.
-- The fake GetReplicateItemInfo returns it in the game's order, with owner
-- fields filled on purpose so the tests can prove they are never saved.
-- @param itemID the item's id
-- @param count stack size
-- @param buyout stack buyout in copper
-- @return the listing
-- @param noName optional; true when the game hasn't loaded the item, so its name is nil
local function Listing(itemID, count, buyout, noName)
    return { itemID = itemID, count = count, buyout = buyout, noName = noName }
end

--- Builds a fresh fake game world and loads both addon files into it.
-- @param opts optional: listings (replicate list), savedDB (HouseLedgerDB
--   at load), noMoneyString (no GetMoneyString), npcSide (the auctioneer's
--   faction, default "Alliance"), screenRight (UIParent's right edge,
--   default 1400)
local function Setup(opts)
    opts = opts or {}
    world = {
        now = 100000,
        frames = {},
        timers = {},
        replicateCalls = 0,
        browseQueries = {},
        itemQueries = {},
        blizzardQueries = {},
        hooks = {},
        commodityResults = {},
        itemResults = {},
        throttleReady = true,
        houseOpen = false,
        listings = opts.listings or {},
        tooltipHooks = {},
    }

    _G.HouseLedgerDB = opts.savedDB
    _G.HouseLedger = nil
    _G.HouseLedgerPrice = nil

    _G.time = function() return world.now end
    _G.GetTime = function() return world.now + 0.5 end
    _G.date = function(fmt, t) return os.date(fmt, t) end
    _G.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    _G.strlenutf8 = function(s) return #s end
    -- Forever has GetMoneyString, not GetCoinTextureString. The fake marks
    -- its output so a check can tell it from the plain-text fallback.
    _G.GetCoinTextureString = nil
    _G.GetMoneyString = nil
    if not opts.noMoneyString then
        _G.GetMoneyString = function(copper, separateThousands)
            world.moneyStringArgs = { copper, separateThousands }
            return "<money " .. tostring(copper) .. ">"
        end
    end
    -- The Forever client gives a blank realm name since 2026-11-20; world.realmName sets it.
    _G.GetRealmName = function()
        if world.realmName ~= nil then
            return world.realmName
        end
        return "TestRealm"
    end
    _G.IsShiftKeyDown = function() return world.shiftDown == true end
    -- The game's link insert, which a shift-click on a bag item or chat link calls. A chat box
    -- is open when world.chatOpen is true.
    _G.ChatFrameUtil = {
        InsertLink = function(link)
            world.insertedLinks = (world.insertedLinks or 0) + 1
            return world.chatOpen == true
        end,
        GetActiveWindow = function() return world.chatOpen and {} or nil end,
    }
    _G.UnitFactionGroup = function(unit)
        if unit == "npc" then
            return opts.npcSide or "Alliance"
        end
        return "Alliance"
    end
    _G.UnitExists = function(unit) return unit == "npc" and world.houseOpen end
    _G.GetItemInfoInstant = function() return nil end

    _G.Enum = {
        AuctionHouseFilter = {
            UsableOnly = 2, PoorQuality = 6, CommonQuality = 7, UncommonQuality = 8,
            RareQuality = 9, EpicQuality = 10,
        },
        ItemClass = { Weapon = 2, Armor = 4, Recipe = 9 },
        ItemArmorSubclass = { Generic = 0, Cloth = 1, Leather = 2, Mail = 3, Plate = 4, Shield = 6, Libram = 7,
            Idol = 8, Totem = 9 },
        InventoryType = { IndexCloakType = 16 },
        ItemRecipeSubclass = { Book = 0, Leatherworking = 1, Tailoring = 2, Engineering = 3, Blacksmithing = 4,
            Cooking = 5, Alchemy = 6, FirstAid = 7, Enchanting = 8, Fishing = 9, Jewelcrafting = 10, Inscription = 11 },
        Profession = { FirstAid = 0, Blacksmithing = 1, Leatherworking = 2, Alchemy = 3, Herbalism = 4, Cooking = 5,
            Mining = 6, Tailoring = 7, Engineering = 8, Enchanting = 9, Fishing = 10, Skinning = 11 },
        AuctionHouseSortOrder = { Price = 0, Name = 1 },
        TooltipDataType = { Item = 0 },
        ItemCommodityStatus = { Unknown = 0, Item = 1, Commodity = 2 },
    }

    -- The character's professions, as Forever's GetProfessions gives them: prof1, prof2, first aid,
    -- fishing, cooking (each a spellbook index or nil). world.professions lists
    -- { skillLine, profession } per index; profession nil makes the code fall back on the skill line.
    -- The character: world.class (a class file name like "PALADIN") and world.level.
    _G.UnitClass = function() return "Class", world.class, 0 end
    _G.UnitLevel = function() return world.level or 60 end
    _G.GetProfessions = function()
        local p = world.professions or {}
        return p[1] and 1, p[2] and 2, p[3] and 3, p[4] and 4, p[5] and 5
    end
    _G.GetProfessionInfo = function(index)
        local entry = (world.professions or {})[index]
        return "Profession " .. index, 0, 1, 300, 0, 0, entry.skillLine
    end
    _G.C_TradeSkillUI = {
        GetProfessionInfoBySkillLineID = function(skillLine)
            for _, entry in pairs(world.professions or {}) do
                if entry.skillLine == skillLine then
                    return { profession = entry.profession, professionID = skillLine }
                end
            end
        end,
    }

    _G.UIParent = NewObject("Frame", "UIParent")
    _G.UIParent.right = opts.screenRight or 1400
    _G.CreateFrame = function(kind, name, parent, template)
        local object = NewObject(kind, name)
        object.parent = parent
        object.template = template
        if template == "ButtonFrameTemplate" then
            object.Inset = NewObject("Frame")
        end
        -- Like the game's secure click button: protected, and so is its
        -- parent. Its click runs Blizzard's code, which may press the
        -- button named in "clickbutton".
        if type(template) == "string" and template:find("SecureActionButtonTemplate", 1, true) then
            object.protected = true
            if parent then
                parent.protected = true
            end
            object.scripts.OnClick = function(self, mouseButton)
                local delegate = self.attributes.clickbutton
                if self.attributes.type == "click" and delegate then
                    world.blizzardActing = true
                    delegate:Click(mouseButton)
                    world.blizzardActing = false
                end
            end
        end
        world.frames[#world.frames + 1] = object
        if name then
            _G[name] = object
        end
        return object
    end

    world.tooltip = { items = {} }
    _G.GameTooltip = NewObject("Frame", "GameTooltip")
    _G.SlashCmdList = {}
    _G.UISpecialFrames = {}
    _G.ContainerFrameCombinedBags = NewObject("Frame", "ContainerFrameCombinedBags")
    _G.ContainerFrame1 = NewObject("Frame", "ContainerFrame1")
    _G.GameTooltip.SetItemKey = function(_, itemID)
        world.tooltip.items[#world.tooltip.items + 1] = itemID
    end
    _G.C_Item = {
        -- The item cache: world.itemInfo[itemID] = { name, quality, level }, or nil until loaded.
        GetItemInfo = function(itemID)
            world.itemInfoCalls = (world.itemInfoCalls or 0) + 1
            local info = (world.itemInfo or {})[itemID]
            if info == nil then
                return nil
            end
            return info.name, "|Hitem:" .. itemID .. "|h", info.quality, info.level
        end,
        -- Like the game: a quality outside 0 to 8 (the scan's -1 for "not known yet") is a usage error.
        GetItemQualityColor = function(quality)
            if type(quality) ~= "number" or quality < 0 or quality > 8 then
                error("Usage: local r, g, b, qualityString = C_Item.GetItemQualityColor(quality)")
            end
            return 1, 1, 1
        end,
        GetItemName = function(location) return "Item " .. location.itemID end,
        GetItemIcon = function() return 134400 end,
        -- A bag can be worn but is not equipment to the house; world.equippable
        -- lets a test say so. By default, gear is both.
        IsEquippableItem = function()
            if world.equippable ~= nil then
                return world.equippable
            end
            return world.equipment == true
        end,
    }
    _G.InCombatLockdown = function() return world.inCombat == true end
    -- The game's versions enable, disable and move the tab buttons.
    _G.PanelTemplates_SetNumTabs = function(owner, count)
        for _, tab in ipairs(owner.Tabs or {}) do
            NoteIfBlocked(tab)
        end
        owner.numTabs = count
    end
    _G.PanelTemplates_SetTab = function(owner, id)
        for _, tab in ipairs(owner.Tabs or {}) do
            NoteIfBlocked(tab)
        end
        owner.selectedTab = id
    end
    _G.C_Cursor = { GetCursorItem = function() return world.cursorItem end }
    _G.ClearCursor = function()
        world.cursorItem = nil
        world.cursorCleared = (world.cursorCleared or 0) + 1
    end

    _G.C_Timer = {
        After = function(_, fn) world.timers[#world.timers + 1] = fn end,
    }

    -- opts.noTooltipHook: a client without TooltipDataProcessor.
    _G.TooltipDataProcessor = nil
    if not opts.noTooltipHook then
        _G.TooltipDataProcessor = {
            AddTooltipPostCall = function(kind, fn)
                world.tooltipHooks[#world.tooltipHooks + 1] = { kind = kind, fn = fn }
            end,
        }
    end

    _G.AuctionHouseFrame = nil
    -- Blizzard's display modes are lists of subframe names; only which
    -- table it is matters here.
    _G.AuctionHouseFrameDisplayMode = {
        Buy = {}, ItemBuy = {}, CommoditiesBuy = {}, WoWTokenBuy = {},
        ItemSell = {}, CommoditiesSell = {}, WoWTokenSell = {}, Auctions = {},
    }
    -- Like the game's: the original runs first, then the hook, with the
    -- same arguments. The original's results are returned unchanged.
    _G.hooksecurefunc = function(owner, name, hook)
        local original = owner[name]
        world.hooks[#world.hooks + 1] = { owner = owner, name = name }
        owner[name] = function(...)
            local a, b, c = original(...)
            hook(...)
            return a, b, c
        end
    end

    _G.C_AuctionHouse = {
        ReplicateItems = function() world.replicateCalls = world.replicateCalls + 1 end,
        GetNumReplicateItems = function() return #world.listings end,
        GetReplicateItemInfo = function(index)
            local row = world.listings[index + 1]
            if row == nil then
                return nil
            end
            return (not row.noName) and ("Item " .. row.itemID) or nil, 134400, row.count, 1, true, 1, "",
                0, 0, row.buyout, 0, nil, nil,
                "SellerBob", "SellerBob-TestRealm", 0, row.itemID, true
        end,
        IsThrottledMessageSystemReady = function() return world.throttleReady end,
        SendBrowseQuery = function(query)
            world.browseQueries[#world.browseQueries + 1] = query
        end,
        IsSellItemValid = function(location) return location.sellable ~= false end,
        GetItemKeyFromItem = function(location)
            return {
                itemID = location.itemID, itemLevel = location.itemLevel or 0,
                itemSuffix = location.itemSuffix or 0, battlePetSpeciesID = location.petSpecies or 0,
            }
        end,
        GetItemCommodityStatus = function(location)
            if location.status then
                return location.status
            end
            return location.commodity and 2 or 1
        end,
        SendSearchQuery = function(itemKey)
            world.itemQueries[#world.itemQueries + 1] = { kind = "search", itemID = itemKey.itemID }
        end,
        SendSellSearchQuery = function(itemKey)
            world.itemQueries[#world.itemQueries + 1] = {
                kind = "sell", itemID = itemKey.itemID,
                itemLevel = itemKey.itemLevel, itemSuffix = itemKey.itemSuffix,
                battlePetSpeciesID = itemKey.battlePetSpeciesID,
            }
        end,
        GetNumCommoditySearchResults = function() return #world.commodityResults end,
        GetCommoditySearchResultInfo = function(_, index) return world.commodityResults[index] end,
        HasFullCommoditySearchResults = function() return not world.partialResults end,
        GetNumItemSearchResults = function(itemKey)
            world.readKey = itemKey
            return #world.itemResults
        end,
        GetItemSearchResultInfo = function(_, index) return world.itemResults[index] end,
        HasFullItemSearchResults = function() return not world.partialResults end,
        GetBrowseResults = function() return world.browseResults or {} end,
        HasFullBrowseResults = function() return not world.partialBrowse end,
        MakeItemKey = function(itemID, itemLevel, itemSuffix, petSpecies)
            return { itemID = itemID, itemLevel = itemLevel or 0, itemSuffix = itemSuffix or 0,
                battlePetSpeciesID = petSpecies or 0 }
        end,
        GetItemKeyInfo = function(itemKey)
            if world.noItemInfo then
                return nil
            end
            return {
                itemName = "Item " .. itemKey.itemID, quality = (world.qualities or {})[itemKey.itemID] or 1,
                iconFileID = 134400,
                isEquipment = world.equipment == true,
            }
        end,
    }

    -- Load every file the .toc lists, in its order, the way the game does: each file gets the
    -- addon's name and its one shared table. The checks reach the price module as HouseLedgerPrice.
    local ns = {}
    for line in io.lines(folder .. "/HouseLedger.toc") do
        local file = line:match("^%s*([^#%s][^%s]*%.lua)%s*$")
        if file then
            assert(loadfile(folder .. "/" .. file))("HouseLedger", ns)
        end
    end
    _G.HouseLedgerPrice = ns.Price
end

--- The addon's event frame: the one registered for ADDON_LOADED.
-- @return the fake frame
local function EventFrame()
    for _, object in ipairs(world.frames) do
        if object.events.ADDON_LOADED then
            return object
        end
    end
end

--- Sends one game event to the addon.
-- @param event the event name
-- @param ... the event's arguments
local function Fire(event, ...)
    local handler = EventFrame():GetScript("OnEvent")
    handler(EventFrame(), event, ...)
end

--- The HouseLedger window.
-- @return HouseLedgerFrame, or nil before it is built
local function MainFrame() return _G.HouseLedgerFrame end

--- The first fake button showing this text.
-- @param label the button text
-- @return the button, or nil
local function ButtonNamed(label)
    for _, object in ipairs(world.frames) do
        -- "Scan" also finds the Scan button while it shows its countdown, "Scan (12m)".
        if object.kind == "Button" and (object.text == label or object.text:sub(1, #label + 2) == label .. " (") then
            return object
        end
    end
end

--- The Buy tab's search box.
-- @return the edit box, or nil
local function SearchBox()
    return _G.HouseLedgerFrame.buyPanel.searchControls[1]
end

--- The scan line at the bottom of the window.
-- It is the last font string made on the window frame itself.
-- @return its text
local function ScanLine()
    local list = MainFrame().fontStrings
    return list[#list].text
end

--- The radio choices a fake dropdown's menu shows, as Blizzard's menu would build them.
-- @param dropdown the dropdown
-- @return list of { text, isSelected, setSelected, data }
local function MenuChoices(dropdown)
    local choices = {}
    local root = {
        CreateRadio = function(_, text, isSelected, setSelected, data)
            choices[#choices + 1] = { text = text, isSelected = isSelected, setSelected = setSelected, data = data }
        end,
    }
    setmetatable(root, { __index = function() return Noop end })
    dropdown.menuGenerator(dropdown, root)
    return choices
end

--- Picks a choice in a fake dropdown's menu, as a player's click would.
-- @param dropdown the dropdown
-- @param label the choice's text
local function Pick(dropdown, label)
    for _, choice in ipairs(MenuChoices(dropdown)) do
        if choice.text == label then
            choice.setSelected(choice.data)
            return
        end
    end
    error("no menu choice " .. label)
end

--- The text of the dropdown's selected choice.
-- @param dropdown the dropdown
-- @return the text, or nil
local function Picked(dropdown)
    for _, choice in ipairs(MenuChoices(dropdown)) do
        if choice.isSelected(choice.data) then
            return choice.text
        end
    end
end

--- Types into a fake edit box, firing its OnTextChanged as the player's typing does.
-- @param box the edit box
-- @param text the new text
local function Type(box, text)
    box:SetText(text)
    local changed = box:GetScript("OnTextChanged")
    if changed then
        changed(box, true)
    end
end

--- A mouse click: OnClick, then PostClick when the button has one.
-- @param label the text of the button to click
local function Click(label)
    local button = ButtonNamed(label)
    button:GetScript("OnClick")(button, "LeftButton")
    local after = button:GetScript("PostClick")
    if after then
        after(button, "LeftButton")
    end
end

--- Counts a call on Blizzard's window that Blizzard's own code did not make.
local function NoteHouseCall()
    if not world.blizzardActing then
        world.addonHouseCalls = (world.addonHouseCalls or 0) + 1
    end
end

--- A fake of Blizzard's auction house window.
-- Blizzard's window: 800 x 538 at x 16, so its right edge is at 816.
-- SetDisplayMode and SetPostItem act like Blizzard's: SetPostItem turns
-- away what its Sell tab would, sends Blizzard's one search (counted in
-- world.blizzardQueries, not world.itemQueries) and switches to Sell.
-- Calls that Blizzard's own code did not make are counted by NoteHouseCall.
-- @return the fake window
local function NewHouseFrame()
    local house = NewObject("Frame", "AuctionHouseFrame")
    house.right = 816
    house.height = 538
    house.displayMode = AuctionHouseFrameDisplayMode.Buy
    -- Blizzard's own tab buttons: a click switches its window.
    house.BuyTab = { Click = function() house:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy) end }
    house.SellTab = { Click = function() house:SetDisplayMode(AuctionHouseFrameDisplayMode.ItemSell) end }
    house.ItemSellFrame = { GetItem = function(self) return self.item end }
    house.CommoditiesSellFrame = { GetItem = function(self) return self.item end }
    function house:GetDisplayMode()
        return self.displayMode
    end
    -- Like Blizzard's: an unknown mode (a table another addon passes) shows
    -- no tab of Blizzard's own.
    function house:SetDisplayMode(mode)
        NoteHouseCall()
        self.displayMode = mode
    end
    function house:SetPostItem(location)
        NoteHouseCall()
        -- Blizzard also turns items away while its multi-sell bar is up.
        if world.blizzardBusy or not C_AuctionHouse.IsSellItemValid(location) then
            return
        end
        local status = C_AuctionHouse.GetItemCommodityStatus(location)
        if status == Enum.ItemCommodityStatus.Unknown then
            return
        end
        self.ItemSellFrame.item = nil
        self.CommoditiesSellFrame.item = nil
        world.blizzardQueries[#world.blizzardQueries + 1] = location.itemID
        local modes = AuctionHouseFrameDisplayMode
        local commodity = status == Enum.ItemCommodityStatus.Commodity
        self:SetDisplayMode(commodity and modes.CommoditiesSell or modes.ItemSell)
        if commodity then
            self.CommoditiesSellFrame.item = location
        else
            self.ItemSellFrame.item = location
        end
    end
    return house
end

--- Runs fn as Blizzard's own code: a click on its tab, a drop on its window.
-- @param fn the function to run
local function AsBlizzard(fn)
    world.blizzardActing = true
    fn()
    world.blizzardActing = false
end

--- A click on one of Blizzard's tabs, made by Blizzard's code.
-- @param mode the AuctionHouseFrameDisplayMode to switch to
local function BlizzardTab(mode)
    AsBlizzard(function() AuctionHouseFrame:SetDisplayMode(mode) end)
end

--- An item dropped on Blizzard's Sell window, or right-clicked from a bag.
-- @param item the fake item location
local function BlizzardPostItem(item)
    AsBlizzard(function() AuctionHouseFrame:SetPostItem(item) end)
end

--- Opens the auction house: shows Blizzard's window and fires AUCTION_HOUSE_SHOW.
local function OpenHouse()
    world.houseOpen = true
    _G.AuctionHouseFrame = _G.AuctionHouseFrame or NewHouseFrame()
    _G.AuctionHouseFrame.shown = true
    Fire("AUCTION_HOUSE_SHOW")
end

--- Closes the auction house: hides Blizzard's window and fires AUCTION_HOUSE_CLOSED.
local function CloseHouse()
    world.houseOpen = false
    if _G.AuctionHouseFrame then
        _G.AuctionHouseFrame.shown = false
    end
    Fire("AUCTION_HOUSE_CLOSED")
end

--- Runs queued C_Timer.After callbacks, oldest first.
-- Bounded so a loop bug fails the test instead of hanging it.
local function RunTimers()
    for _ = 1, 10000 do
        if #world.timers == 0 then
            return
        end
        local fn = table.remove(world.timers, 1)
        fn()
    end
    error("timer queue never drained")
end

--- Moves the clock forward, one OnUpdate per second while shown.
-- @param seconds how many seconds to move
local function Advance(seconds)
    for _ = 1, seconds do
        world.now = world.now + 1
        local frame = MainFrame()
        if frame and frame.shown then
            frame:GetScript("OnUpdate")(frame, 1)
        end
    end
end

--- Fires ADDON_LOADED for HouseLedger.
local function Load()
    Fire("ADDON_LOADED", "HouseLedger")
end

--- True when any string key or value in a nested table contains `needle`.
-- @param value a string or table to search
-- @param needle the plain text to find
-- @param seen tables already searched; nil on the first call
-- @return true when found
local function DeepFind(value, needle, seen)
    seen = seen or {}
    if type(value) == "string" then
        return value:find(needle, 1, true) ~= nil
    end
    if type(value) ~= "table" or seen[value] then
        return false
    end
    seen[value] = true
    for key, inner in pairs(value) do
        if DeepFind(key, needle, seen) or DeepFind(inner, needle, seen) then
            return true
        end
    end
    return false
end

--- A long replicate list over 300 item ids, each a single item.
-- @param total how many listings
-- @return the list of listings
local function ManyListings(total)
    local list = {}
    for i = 1, total do
        list[i] = Listing(1000 + (i % 300), 1, 100 + i)
    end
    return list
end

-- ---------------------------------------------------------------------
-- Load and layout
-- ---------------------------------------------------------------------

do
    Setup()
    Load()
    Check("loading builds the frame hidden", MainFrame() ~= nil and not MainFrame().shown)
    Check("loading hooks item tooltips once", #world.tooltipHooks == 1)
    Check("loading makes saved data", type(HouseLedgerDB) == "table" and type(HouseLedgerDB.houses) == "table")
    OpenHouse()
    Check("opening the house shows the frame", MainFrame().shown)
    Check("opening the house does not scan", world.replicateCalls == 0)
    Check("opening the house does not search", #world.browseQueries == 0)
end

-- ---------------------------------------------------------------------
-- Full scan
-- ---------------------------------------------------------------------

do
    Setup({ listings = ManyListings(1200) })
    Load()
    OpenHouse()
    Click("Scan")
    Check("scan click sends one request", world.replicateCalls == 1)
    Check("scan button locks while waiting", not ButtonNamed("Scan").enabled)
    Check("no progress bar before the listings arrive", not MainFrame().scanBar.shown)
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    Check("first batch reads, rest is queued", #world.timers == 1)
    Check("the progress bar shows how much is read", MainFrame().scanBar.shown
        and MainFrame().scanBar.value == 500 and MainFrame().scanBar.max == 1200)
    -- The wiki says the event fires again for each item that loads.
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    Check("repeat events do not restart the read", #world.timers == 1)
    RunTimers()
    local house = HouseLedgerDB.houses["Alliance|TestRealm"]
    local priced = 0
    for _ in pairs(house and house.items or {}) do
        priced = priced + 1
    end
    Check("scan saves one price per item id", priced == 300)
    Check("after the scan the button counts down the 15 minutes", not ButtonNamed("Scan").enabled
        and ButtonNamed("Scan").text == "Scan (15m)")
    Check("the progress bar hides when the read is done", not MainFrame().scanBar.shown)
    Check("status reports the save", ScanLine() == "Saved 300 prices (Alliance).")
    Advance(8)
    Check("then the idle line, without the realm", ScanLine() == "300 prices (Alliance). Next scan in 15 min.")
    Advance(15 * 60)
    Check("15 minutes later the button is ready again", ButtonNamed("Scan").enabled
        and ButtonNamed("Scan").text == "Scan" and ScanLine() == "300 prices (Alliance). Scan is ready.")
    Check("seller names are never saved", not DeepFind(HouseLedgerDB, "SellerBob"))
    Check("item names are saved", house.items[1001] and house.items[1001].name == "Item 1001"
        and house.items[1001].quality == 1)
    Check("one request for the whole scan", world.replicateCalls == 1)
end

do
    Setup({ listings = { Listing(4306, 1, 50) } })
    Load()
    OpenHouse()
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers()
    Advance(5 * 60)
    Click("Scan")
    Check("second click inside 15 min sends nothing", world.replicateCalls == 1)
    Advance(10 * 60)
    Click("Scan")
    Check("click after 15 min sends again", world.replicateCalls == 2)
end

-- The two cases below are the policy check that matters most. A request
-- has gone to the server, so the 15 minutes must count from that click
-- even when the answer never shows up.

do
    Setup({ listings = { Listing(4306, 1, 50) } })
    Load()
    OpenHouse()
    Click("Scan")
    Advance(61) -- ANSWER_WAIT is 60 seconds; no event arrives
    Check("no answer: the button waits out the 15 minutes", not ButtonNamed("Scan").enabled
        and ButtonNamed("Scan").text:find("^Scan %(1[45]m%)$") ~= nil)
    Click("Scan")
    Check("no answer: retry inside 15 min sends nothing", world.replicateCalls == 1)
end

do
    -- Give up on the answer, then it shows up late with the house open.
    Setup({ listings = { Listing(4306, 1, 50) } })
    Load()
    OpenHouse()
    Click("Scan")
    Advance(61)
    world.now = world.now + 5
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers()
    local house = HouseLedgerDB.houses["Alliance|TestRealm"]
    Check("late answer after giving up is still read", house ~= nil and house.items[4306] ~= nil)
end

-- Close the house while waiting. Reopen inside and after the 60 s
-- late-answer window. Either way the request already went out.
for _, waited in ipairs({ 30, 90 }) do
    Setup({ listings = { Listing(4306, 1, 50) } })
    Load()
    OpenHouse()
    Click("Scan")
    CloseHouse()
    Advance(waited) -- frame is hidden, no answer arrives
    OpenHouse()
    Click("Scan")
    Check(
        string.format("closed while waiting, reopened after %d s: retry sends nothing", waited),
        world.replicateCalls == 1
    )
end

do
    Setup({ listings = { Listing(4306, 1, 50) } })
    Load()
    OpenHouse()
    Click("Scan")
    CloseHouse()
    world.now = world.now + 3
    Fire("REPLICATE_ITEM_LIST_UPDATE") -- late answer inside the 60 s window
    OpenHouse()
    Click("Scan")
    Check("late answer still starts the 15 min wait", world.replicateCalls == 1)
end

do
    Setup({ listings = ManyListings(1200) })
    Load()
    OpenHouse()
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    CloseHouse()
    RunTimers()
    local house = HouseLedgerDB.houses["Alliance|TestRealm"]
    Check("closing mid-read saves nothing partial", house == nil)
    OpenHouse()
    Click("Scan")
    Check("closing mid-read still blocks a rescan", world.replicateCalls == 1)
end

do
    -- An earlier scan saved a price. Then the house answers with zero
    -- listings (empty or not ready). The old price should not be marked
    -- stale by a scan that saw nothing.
    local saved = {
        version = 1,
        houses = {
            ["Alliance|TestRealm"] = {
                scannedAt = 1000,
                items = { [4306] = { unit = 50, qty = 1, seen = 1000, history = { { 50, 1000 } } } },
            },
        },
        lastHouseKey = "Alliance|TestRealm",
    }
    Setup({ listings = {}, savedDB = saved })
    Load()
    OpenHouse()
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers()
    local house = HouseLedgerDB.houses["Alliance|TestRealm"]
    Check("empty answer does not mark old prices stale", house.scannedAt == 1000)
end

do
    Setup({ listings = { Listing(4306, 1, 50) }, npcSide = "Neutral" })
    Load()
    OpenHouse()
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers()
    Check("goblin auctioneer scan is stored as Neutral", HouseLedgerDB.houses["Neutral|TestRealm"] ~= nil)
end

do
    -- The game named the realm for old scans, then gave a blank name and a scan went to the
    -- unknown realm. The load joins them, and a new scan with a blank name goes to the old house.
    local saved = {
        version = 3,
        houses = {
            ["Alliance|TestRealm"] = { scannedAt = 1000, items = { [4306] = { unit = 50, qty = 1, seen = 1000,
                days = { { tonumber(os.date("%Y%m%d", 1000)), 50, 50, 1, 50, 2500 } } } } },
            ["Alliance|Forever"] = { scannedAt = 2000, items = { [2589] = { unit = 9, qty = 1, seen = 2000,
                days = { { tonumber(os.date("%Y%m%d", 2000)), 9, 9, 1, 9, 81 } } } } },
        },
        lastHouseKey = "Alliance|Forever",
    }
    Setup({ listings = { Listing(2592, 1, 70) }, savedDB = saved })
    world.realmName = ""
    Load()
    Check("the load joins the blank-realm house into the named one",
        HouseLedgerDB.houses["Alliance|Forever"] == nil and HouseLedgerDB.houses["Alliance|TestRealm"].items[2589] ~= nil)
    OpenHouse()
    Check("the auction house says once that the scans were joined", ScanLine():find("Joined scans", 1, true) ~= nil)
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers()
    Check("a scan with a blank realm name saves into the named realm's house",
        HouseLedgerDB.houses["Alliance|TestRealm"].items[2592] ~= nil and HouseLedgerDB.houses["Alliance|Forever"] == nil)
    Check("the remembered realm is the named one", HouseLedgerDB.homeRealm == "TestRealm")
end

do
    -- At a goblin auction house the window reads the goblin house; tooltips keep the player's
    -- own faction's prices, there and everywhere else.
    local day = tonumber(os.date("%Y%m%d", 1000))
    local saved = {
        version = 3,
        houses = { ["Alliance|TestRealm"] = { scannedAt = 1000, items = {
            [4306] = { unit = 50, qty = 1, seen = 1000, days = { { day, 50, 50, 1, 50, 2500 } } } } } },
        lastHouseKey = "Alliance|TestRealm",
    }
    Setup({ listings = { Listing(4306, 1, 90) }, npcSide = "Neutral", savedDB = saved })
    Load()
    OpenHouse()
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers()
    Check("a goblin scan saves its own house", HouseLedgerDB.houses["Neutral|TestRealm"].items[4306].unit == 90
        and HouseLedgerDB.houses["Alliance|TestRealm"].items[4306].unit == 50)
    Check("the window names it Goblin", ScanLine():find("(Goblin)", 1, true) ~= nil)
    Click("Market")
    local frame = MainFrame()
    Check("Market at a goblin house shows the goblin scan", frame.buyPanel.marketLabel.text:find("just now", 1, true) ~= nil)
    local lines = {}
    local tooltip = {
        AddLine = function(_, text) lines[#lines + 1] = text end,
        AddDoubleLine = function(_, left, right) lines[#lines + 1] = left .. " = " .. right end,
    }
    world.tooltipHooks[1].fn(tooltip, { id = 4306 })
    Check("tooltips at a goblin house still show the player's faction's price", lines[1] == "HouseLedger  <money 50>")
    Click("Buy")
    CloseHouse()
    lines = {}
    world.tooltipHooks[1].fn(tooltip, { id = 4306 })
    Check("and after it closes", lines[1] == "HouseLedger  <money 50>")
    HouseLedgerDB.houses["Alliance|TestRealm"] = nil
    lines = {}
    world.tooltipHooks[1].fn(tooltip, { id = 4306 })
    Check("no faction price: no tooltip line, never the goblin one", #lines == 0)
end

-- ---------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------

do
    Setup()
    Load()
    OpenHouse()
    SearchBox():SetText("a")
    Click("Search")
    Check("one letter sends no query", #world.browseQueries == 0)
    SearchBox():SetText("  linen  ")
    world.throttleReady = false
    Click("Search")
    Check("busy throttle sends no query", #world.browseQueries == 0)
    world.throttleReady = true
    Click("Search")
    Check("one click sends one query", #world.browseQueries == 1)
    Check("query text is trimmed", world.browseQueries[1].searchString == "linen")
    Check("query has a quality filter", #world.browseQueries[1].filters > 0)
    RunTimers()
    Advance(120)
    Check("no follow-up query by timer", #world.browseQueries == 1)
    CloseHouse()
    Click("Search")
    Check("closed house sends no query", #world.browseQueries == 1)
end

--- Result row buttons, top to bottom.
-- @return the list of rows
local function ResultRows()
    local rows = {}
    for _, object in ipairs(world.frames) do
        if object.kind == "Button" and object.nameText and object.typicalText then
            rows[#rows + 1] = object
        end
    end
    return rows
end

--- True when the Avg 7d column shows, read from the first row.
-- @return true when shown
local function TypicalColumnShown()
    return ResultRows()[1].typicalText.shown == true
end

--- The Buy tab's status line under the results.
-- It is the first font string made on the Buy panel.
-- @return its text
local function StatusLine()
    return MainFrame().buyPanel.statusText.text
end

--- The list frame the result rows sit in.
-- @return the list frame
local function ListFrame()
    return ResultRows()[1].parent
end

--- One mouse-wheel step down over the list.
local function WheelDown()
    ListFrame():GetScript("OnMouseWheel")(ListFrame(), -1)
end

--- One mouse-wheel step up over the list.
local function WheelUp()
    ListFrame():GetScript("OnMouseWheel")(ListFrame(), 1)
end

-- ---------------------------------------------------------------------
-- Layout. Blizzard's AuctionHouseFrame is 800 x 538 and toplevel; a
-- centered HouseLedger sat over its results list and went behind it.
-- ---------------------------------------------------------------------

--- True when the frame is pinned beside the auction house.
-- Its top and bottom are both on the auction house's right edge, so it is
-- beside the house and exactly as tall.
-- @param frame the HouseLedger window
-- @return true when pinned
local function PinnedToHouse(frame)
    local top, bottom = frame.points[1], frame.points[2]
    return #frame.points == 2
        and top[1] == "TOPLEFT" and top[2] == _G.AuctionHouseFrame and top[3] == "TOPRIGHT"
        and bottom[1] == "BOTTOMLEFT" and bottom[2] == _G.AuctionHouseFrame and bottom[3] == "BOTTOMRIGHT"
end

do
    Setup()
    Load()
    OpenHouse()
    local frame = MainFrame()
    Check("opening the house pins the frame to its right edge", PinnedToHouse(frame))
    Check("frame is kept on screen", frame.clamped == true)
    Check("frame comes to the front when the house opens", (frame.raised or 0) >= 1)
    Check("clicking the frame brings it to the front", frame.toplevel == true)
    Check("game does not save a dragged spot", frame.dontSave == true)

    -- Drag it somewhere, then close and reopen the house.
    frame:ClearAllPoints()
    frame:SetPoint("CENTER")
    CloseHouse()
    OpenHouse()
    Check("reopening the house pins it again", PinnedToHouse(frame))
end

do
    -- Blizzard loads its AH window on a different event, so it may not
    -- exist yet when HouseLedger hears AUCTION_HOUSE_SHOW.
    Setup()
    Load()
    world.houseOpen = true
    Fire("AUCTION_HOUSE_SHOW")
    Check("no AH window yet: frame still shows", MainFrame().shown)
    _G.AuctionHouseFrame = NewHouseFrame()
    RunTimers()
    Check("AH window a frame later: frame gets pinned", PinnedToHouse(MainFrame()))
end

do
    Setup()
    Load()
    local lines = {}
    -- The large list message and the orange note beside the filters are meant to wrap.
    local panel = MainFrame().buyPanel
    for _, owner in ipairs({ MainFrame(), panel, MainFrame().sellPanel }) do
        for _, line in ipairs(owner.fontStrings) do
            if line ~= panel.listMessage and line ~= panel.notice then
                lines[#lines + 1] = line
            end
        end
    end
    local allSingle = #lines >= 3
    for _, line in ipairs(lines) do
        if line.wordWrap ~= false then
            allSingle = false
        end
    end
    for _, row in ipairs(ResultRows()) do
        for _, cell in ipairs(row.fontStrings) do
            if cell.wordWrap ~= false then
                allSingle = false
            end
        end
    end
    Check("result and status lines never wrap", allSingle)
end

do
    Setup({ screenRight = 1400 })
    Load()
    OpenHouse()
    Check("window looks like Blizzard's panels", MainFrame().template == "ButtonFrameTemplate")
    -- 1400 screen edge - 816 house edge - 4 gap - 8 margin
    Check("window fills the space beside the house", MainFrame().width == 572)
    Check("typical column shows when there is room", TypicalColumnShown())
    Check("rows fill the height above the details block", #ResultRows() == 15)
end

do
    Setup({ screenRight = 2400 })
    Load()
    OpenHouse()
    Check("window stops at its widest", MainFrame().width == 640)
end

do
    Setup({ screenRight = 1100 })
    Load()
    OpenHouse()
    Check("window keeps its narrowest on a small screen", MainFrame().width == 440)
    Check("typical column hides when narrow", not TypicalColumnShown())
end

-- ---------------------------------------------------------------------
-- Buy tab results
-- ---------------------------------------------------------------------

--- Browse results for item ids first..last, cheapest first.
-- @param first first item id
-- @param last last item id
-- @param price optional minPrice for all; default 10 copper times the item id
-- @return the results list
local function BrowseResults(first, last, price)
    local results = {}
    for itemID = first, last do
        results[#results + 1] = {
            itemKey = { itemID = itemID, itemLevel = 0, itemSuffix = 0 },
            minPrice = price or (itemID * 10),
            totalQuantity = itemID,
        }
    end
    return results
end

--- Saves one scan a day of an item at 100c for the days before today.
-- @param days how many days back to start
-- @param itemID optional item id, default 4306
local function SaveDailyHistory(days, itemID)
    local P = HouseLedgerPrice
    for back = days, 1, -1 do
        local best = {}
        P.Consider(best, itemID or 4306, 1, 100)
        P.Commit(HouseLedgerDB, "Alliance|TestRealm", best, world.now - back * 24 * 60 * 60)
    end
end

do
    Setup()
    Load()
    OpenHouse()
    world.browseResults = BrowseResults(1, 30)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    local rows = ResultRows()
    Check("row shows the item name", rows[1].nameText.text == "Item 1")
    Check("row shows the live price with coins", rows[1].priceText.text == "<money 10>")
    Check("row shows how many are up", rows[1].availText.text == "1")
    Check("row shows the item icon", rows[1].icon.texture == 134400)
    -- The filter row and the details block leave room for 15 rows.
    Check("the list has 15 rows", #rows == 15)
    Check("status counts what is shown", StatusLine() == "Showing 1-15 of 30.")
    Check("the last row shows the 15th result", rows[15].nameText.text == "Item 15")

    local queries = #world.browseQueries
    WheelDown()
    Check("mouse wheel scrolls three rows", rows[1].nameText.text == "Item 4")
    Check("status follows the scroll", StatusLine() == "Showing 4-18 of 30.")
    for _ = 1, 5 do
        WheelDown()
    end
    Check("scroll stops at the last result", rows[15].nameText.text == "Item 30" and rows[1].nameText.text == "Item 16")
    for _ = 1, 6 do
        WheelUp()
    end
    Check("scroll stops at the first result", rows[1].nameText.text == "Item 1")
    Check("scrolling sends no query", #world.browseQueries == queries)

    world.browseResults = BrowseResults(1, 3)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    Check("a new search starts at the top", rows[1].nameText.text == "Item 1")
    Check("unused rows are hidden", rows[4].shown == false and rows[3].shown == true)
end

do
    Setup()
    Load()
    SaveDailyHistory(5)
    OpenHouse()
    world.browseResults = BrowseResults(4306, 4306, 70)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    local row = ResultRows()[1]
    Check("typical column shows the saved typical low", row.typicalText.text == "<money 100>")
    Check("trend column judges the live price",
        row.trendText.text:find("NPE_ArrowDown", 1, true) ~= nil)
    Check("trend column marks a deal",
        row.trendText.text:find(HouseLedgerPrice.DEAL_ICON, 1, true) ~= nil)

    local panel = MainFrame().buyPanel
    Check("before a click, the details block shows the house overview",
        panel.detailTitle.text == "House overview, 5 days of scans")
    local queries = #world.browseQueries
    row:GetScript("OnClick")(row)
    local function Detail(index, left, right)
        local line = panel.detailLines[index]
        return line.left.text == left and line.right.text == right
    end
    Check("clicking a row titles the details block", panel.detailTitle.text == "Item 4306, 5 scans over 5 days")
    Check("details: 1 day", Detail(1, "1 day, 1 scan", "<money 100>"))
    Check("details: 3 days", Detail(2, "3 days, 3 scans", "<money 100>"))
    Check("details: 7 days", Detail(3, "7 days, 5 scans", "<money 100>"))
    Check("details: 14 days with no more scans says it matches 7 days", Detail(4, "14 days, 5 scans", "|cff9d9d9dsame as 7 days|r"))
    Check("details: std dev", Detail(5, "Std dev, earlier scans", "none"))
    Check("the status line keeps counting rows", StatusLine() == "Showing 1-1 of 1.")
    row:GetScript("OnEnter")(row)
    Check("hovering a row shows the item tooltip", world.tooltip.items[1] == 4306)
    Check("clicking and hovering send no query", #world.browseQueries == queries)
end

do
    Setup()
    Load()
    OpenHouse()
    world.browseResults = BrowseResults(77, 77)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    local row = ResultRows()[1]
    Check("no saved prices: typical is a dash", row.typicalText.text == "-")
    row:GetScript("OnClick")(row)
    local panel = MainFrame().buyPanel
    Check("no saved prices: the click says so",
        panel.detailTitle.text == "Item 77: no saved prices yet. Click Scan."
        and panel.detailLines[1].left.text == "" and panel.detailLines[1].right.text == "")
    world.noItemInfo = true
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    Check("item data not loaded yet: row shows the id", row.nameText.text == "item 77")
end

-- ---------------------------------------------------------------------
-- Tooltip
-- ---------------------------------------------------------------------

do
    Setup({ listings = { Listing(4306, 5, 250) } })
    Load()
    OpenHouse()
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers()
    local lines = {}
    local tooltip = {
        AddLine = function(_, text) lines[#lines + 1] = text end,
        AddDoubleLine = function(_, left, right) lines[#lines + 1] = left .. " = " .. right end,
    }
    world.tooltipHooks[1].fn(tooltip, { id = 4306 })
    Check("tooltip shows the unit price with coin icons", lines[1] == "HouseLedger  <money 50>")
    Check("without Shift the tooltip is one line", #lines == 1)
    world.shiftDown = true
    world.tooltipHooks[1].fn(tooltip, { id = 4306 })
    Check("holding Shift adds the details",
        #lines == 4 and lines[3] == "1 day, 1 scan = <money 50>" and lines[4] == "Trend after 2 more scans")
    world.shiftDown = false
    lines = {}
    Check("gold amounts get thousands separators", world.moneyStringArgs ~= nil and world.moneyStringArgs[2] == true)
    world.tooltipHooks[1].fn(tooltip, { id = 999 })
    Check("unknown item adds no line", #lines == 0)
end

do
    Setup({ listings = { Listing(4306, 1, 25050) }, noMoneyString = true })
    Load()
    OpenHouse()
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers()
    local lines = {}
    local tooltip = { AddLine = function(_, text) lines[#lines + 1] = text end }
    world.tooltipHooks[1].fn(tooltip, { id = 4306 })
    Check("without GetMoneyString the price is still gold, silver, copper",
        lines[1] == "HouseLedger  2g 50s 50c")
end

do
    Setup({ listings = { Listing(4306, 5, 250) } })
    Load()
    OpenHouse()
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers()
    local lines = {}
    local tooltip = { AddLine = function(_, text) lines[#lines + 1] = text end }
    _G.GetItemInfoInstant = function(link) return tonumber(link:match("item:(%d+)")) end
    world.tooltipHooks[1].fn(tooltip, { hyperlink = "|cffffffff|Hitem:4306::::::::60:::::|h[Copper Ore]|h|r" })
    Check("a tooltip with only a link finds the item from the link", lines[1] == "HouseLedger  <money 50>")
    world.tooltipHooks[1].fn(nil, { id = 4306 })
    world.tooltipHooks[1].fn({}, { id = 4306 })
    world.tooltipHooks[1].fn(tooltip, nil)
    Check("a tooltip that can't take lines, or no data, adds nothing", #lines == 1)
end

do
    Setup({ noTooltipHook = true })
    Load()
    OpenHouse()
    Check("a client without tooltip hooks says mouseover prices are off",
        ScanLine() == "Mouseover prices are unavailable on this client.")
end

do
    Setup()
    local itemKind = Enum.TooltipDataType
    Enum.TooltipDataType = nil
    Load()
    OpenHouse()
    Check("a client without the item tooltip kind says so too", #world.tooltipHooks == 0
        and ScanLine() == "Mouseover prices are unavailable on this client.")
    Enum.TooltipDataType = itemKind
end


-- ---------------------------------------------------------------------
-- Tabs and the Sell tab. One drop sends one search; nothing is saved.
-- ---------------------------------------------------------------------

--- One of our tab buttons, by its text.
-- @param label "Buy" or "Sell"
-- @return the tab, or nil
local function TabNamed(label)
    for _, object in ipairs(world.frames) do
        if type(object.template) == "string" and object.template:find("PanelTabButtonTemplate", 1, true)
            and object.text == label then
            return object
        end
    end
end

--- The text of one Sell tab value.
-- @param key a SELL_LINES key, such as "low"
-- @return its text
local function SellValue(key)
    return MainFrame().sellPanel.values[key].text
end

--- The Sell tab's status line.
-- @return its text
local function SellStatus()
    return MainFrame().sellPanel.statusText.text
end

--- Drops an item on the Sell slot.
-- @param item the fake item location to put on the cursor
local function Drop(item)
    world.cursorItem = item
    local slot = MainFrame().sellPanel.slot
    slot:GetScript("OnReceiveDrag")(slot)
end

--- True when any string saved in the table contains `needle`.
-- @param value a string or table to search
-- @param needle the plain text to find
-- @return true when found
local function SavedAnywhere(value, needle)
    if type(value) == "string" then
        return value:find(needle, 1, true) ~= nil
    end
    if type(value) ~= "table" then
        return false
    end
    for key, inner in pairs(value) do
        if SavedAnywhere(key, needle) or SavedAnywhere(inner, needle) then
            return true
        end
    end
    return false
end

--- How many item rows HouseLedgerDB holds, over every house.
-- @return the count
local function SavedItemCount()
    local count = 0
    for _, house in pairs(HouseLedgerDB.houses) do
        for _ in pairs(house.items) do
            count = count + 1
        end
    end
    return count
end

do
    Setup()
    Load()
    OpenHouse()
    local frame = MainFrame()
    Check("window has Buy, Sell, Market and Settings tabs", TabNamed("Buy") ~= nil and TabNamed("Sell") ~= nil and frame.numTabs == 4)
    Check("Buy tab is open first", frame.selectedTab == 1 and frame.buyPanel.shown and not frame.sellPanel.shown)
    Click("Sell")
    Check("Sell tab click opens the Sell panel", frame.selectedTab == 2 and frame.sellPanel.shown and not frame.buyPanel.shown)
    Check("Sell panel says what to do", SellStatus():find("Drop an item", 1, true) ~= nil)
    Click("Buy")
    Check("Buy tab click goes back", frame.selectedTab == 1 and frame.buyPanel.shown and not frame.sellPanel.shown)
    Check("switching tabs sends no query", #world.itemQueries == 0 and #world.browseQueries == 0)
end

do
    Setup()
    Load()
    SaveDailyHistory(4, 2589)
    OpenHouse()
    Click("Sell")
    local before = SavedItemCount()
    Drop(nil)
    Check("an empty drop sends nothing", #world.itemQueries == 0)

    Drop({ itemID = 2589, commodity = true })
    Check("one drop sends one search", #world.itemQueries == 1 and world.itemQueries[1].itemID == 2589)
    Check("a stackable item uses the item search", world.itemQueries[1].kind == "search")
    Check("the item goes back to the bag", world.cursorItem == nil and world.cursorCleared == 1)
    Check("the slot shows the item", MainFrame().sellPanel.itemName.text == "Item 2589")
    Check("status says it is searching", SellStatus() == "Searching for Item 2589...")
    RunTimers()
    Check("no follow-up search by timer", #world.itemQueries == 1)

    world.commodityResults = {
        { itemID = 2589, unitPrice = 130, quantity = 5, owners = { "SellerBob" } },
        { itemID = 2589, unitPrice = 120, quantity = 2, owners = { "SellerBob" } },
    }
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 999)
    Check("results for another item are ignored", SellValue("low") == "-")
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    Check("Sell shows the lowest price now", SellValue("low") == "<money 120>")
    Check("Sell shows how many at that price", SellValue("atLow") == "2")
    Check("Sell shows how many in all", SellValue("total") == "7 in 2 listings")
    local labels = MainFrame().sellPanel.labels
    Check("Sell shows each window with its scans",
        labels.w1.text == "1 day, 1 scan" and SellValue("w1") == "<money 100>"
        and labels.w7.text == "7 days, 4 scans" and SellValue("w7") == "<money 100>"
        and labels.w14.text == "14 days, 4 scans")
    Check("Sell shows the std dev", SellValue("spread") == "none")
    Check("Sell shows the saved counts", SellValue("based") == "4 scans over 4 days")
    Check("seller view: a higher price is a green up arrow",
        SellValue("trend"):find("NPE_ArrowUp", 1, true) ~= nil and SellValue("trend"):find("20ff20", 1, true) ~= nil)
    Check("Sell shows the typical price", SellValue("typical") == "<money 100>")
    Check("and says what it means in plain words",
        MainFrame().sellPanel.hint.text == "Prices are high today. A good time to sell.")
    Check("Sell saves nothing", SavedItemCount() == before)
    Check("seller names are never saved", not SavedAnywhere(HouseLedgerDB, "SellerBob"))
end

do
    Setup()
    Load()
    OpenHouse()
    Click("Sell")
    world.equipment = true
    Drop({ itemID = 7005, itemLevel = 24, itemSuffix = 1179 })
    local sent = world.itemQueries[1]
    Check("gear uses the sell search", sent.kind == "sell")
    -- Blizzard's Sell tab zeroes these so every variant comes back in one list.
    Check("gear search covers every item level and suffix", sent.itemLevel == 0 and sent.itemSuffix == 0)
    world.itemResults = {
        { itemKey = { itemID = 7005 }, buyoutAmount = 500, quantity = 1, owners = { "SellerBob" } },
        { itemKey = { itemID = 7005 }, buyoutAmount = nil, bidAmount = 50, quantity = 1, owners = {} },
        { itemKey = { itemID = 7005 }, buyoutAmount = 900, quantity = 3, owners = {} },
    }
    Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 7005, itemLevel = 0, itemSuffix = 0 })
    Check("results are read with the key that was sent",
        world.readKey.itemLevel == 0 and world.readKey.itemSuffix == 0)
    Check("Sell works out a unit price from a stack buyout", SellValue("low") == "<money 300>")
    Check("bid-only listings are left out", SellValue("total") == "4 in 2 listings")
    Check("no saved prices: the windows are dashes",
        SellValue("w7") == "-" and MainFrame().sellPanel.labels.w7.text == "7 days")
    Check("no saved prices: Sell says so", SellValue("based") == "No saved prices yet")

    world.equipment = false
    Drop({ itemID = 4306 })
    Check("a single, non-gear item uses the item search", world.itemQueries[2].kind == "search")
    world.itemResults = {}
    Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 4306, itemLevel = 0, itemSuffix = 0 })
    Check("nothing listed: Sell says so", SellStatus() == "No one is selling Item 4306 right now.")
    Check("nothing listed: no price shown", SellValue("low") == "-")
end

do
    Setup()
    Load()
    OpenHouse()
    Click("Sell")
    Drop({ itemID = 6948, sellable = false })
    Check("an item that cannot be sold sends nothing", #world.itemQueries == 0)
    Check("it goes back to the bag", world.cursorItem == nil)
    Check("Sell says it cannot be sold", SellStatus() == "Item 6948 can't be sold at the auction house.")

    world.throttleReady = false
    Drop({ itemID = 2589, commodity = true })
    Check("busy throttle: the drop sends nothing", #world.itemQueries == 0)
    Check("busy throttle: Sell says to wait", SellStatus():find("busy", 1, true) ~= nil)

    world.throttleReady = true
    CloseHouse()
    Drop({ itemID = 2589, commodity = true })
    Check("closed house: the drop sends nothing", #world.itemQueries == 0)
end

do
    Setup()
    Load()
    OpenHouse()
    Click("Sell")
    Drop({ itemID = 2589, status = 0 })
    Check("item data not loaded: the drop sends nothing", #world.itemQueries == 0)
    Check("item data not loaded: the item goes back to the bag", world.cursorItem == nil)
    Check("item data not loaded: Sell says to drop it again", SellStatus() == "The game is still loading Item 2589. Drop it again.")

    -- Gear before the house has its item info: still the any-variant search.
    world.equipment = true
    world.noItemInfo = true
    Drop({ itemID = 7005, itemLevel = 24, itemSuffix = 1179, petSpecies = 0 })
    local sent = world.itemQueries[1]
    Check("cold cache gear still uses the sell search",
        #world.itemQueries == 1 and sent.kind == "sell" and sent.itemLevel == 0 and sent.itemSuffix == 0)
    Check("the sell search keeps the pet species", sent.battlePetSpeciesID == 0)

    world.partialResults = true
    world.itemResults = { { itemKey = { itemID = 7005 }, buyoutAmount = 500, quantity = 1, owners = {} } }
    Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 7005, itemLevel = 0, itemSuffix = 0 })
    Check("a long list says the house has more",
        SellStatus() == "Lowest of 1 in 1 listing for Item 7005. The house has more; these are the first ones.")
end

do
    -- A bag can be worn, but the house does not count it as equipment.
    -- Blizzard's Sell tab uses the gear search only when the house says
    -- equipment, so a loaded bag gets the plain item search.
    Setup()
    Load()
    OpenHouse()
    Click("Sell")
    world.equipment = false
    world.equippable = true
    Drop({ itemID = 4496, itemLevel = 10, itemSuffix = 0 })
    local sent = world.itemQueries[1]
    Check("a bag with loaded item info uses the item search",
        #world.itemQueries == 1 and sent.kind == "search")
end

-- Clear (Buy) and Reset (Sell) only empty this window; they send nothing.
do
    Setup()
    Load()
    OpenHouse()
    SearchBox():SetText("linen")
    Click("Search")
    world.browseResults = BrowseResults(1, 30)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    WheelDown()
    local queries = #world.browseQueries
    local first = ResultRows()[1]
    first:GetScript("OnClick")(first)
    Click("Clear")
    local rows = ResultRows()
    Check("Clear empties the search box", SearchBox():GetText() == "")
    Check("Clear empties the details block",
        MainFrame().buyPanel.detailTitle.text == "Click a row for its saved prices over 1, 3, 7 and 14 days.")
    Check("Clear empties the list", rows[1].shown == false and rows[#rows].shown == false)
    Check("Clear puts the first status line back",
        StatusLine() == "Type an item name. One click sends one search.")
    Check("Clear sends no query", #world.browseQueries == queries)
    world.browseResults = BrowseResults(1, 3)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    Check("the next search starts at the top", rows[1].nameText.text == "Item 1")

    Click("Sell")
    Drop({ itemID = 2589, commodity = true })
    world.commodityResults = { { unitPrice = 120, quantity = 47 } }
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    local sent = #world.itemQueries
    Click("Reset")
    local panel = MainFrame().sellPanel
    Check("Reset empties the slot", panel.itemName.text == "Drop an item from your bags here" and panel.icon.texture == nil)
    Check("Reset empties the values", SellValue("low") == "-" and SellValue("trend") == "-")
    Check("Reset puts the first status line back",
        SellStatus() == "Drop an item from your bags. One drop sends one search. Nothing is saved.")
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    Check("late results for the reset item are ignored", SellValue("low") == "-")
    Check("Reset sends no query", #world.itemQueries == sent and #world.browseQueries == queries)
    Check("Clear and Reset never call Blizzard's window", (world.addonHouseCalls or 0) == 0)
end

-- A price within 10% of its 7-day average reads "steady", not a blank.
do
    Setup()
    Load()
    SaveDailyHistory(4, 2589)
    OpenHouse()
    world.browseResults = BrowseResults(2589, 2589, 103)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    Check("Buy: a quiet price reads steady", ResultRows()[1].trendText.text == HouseLedgerPrice.SteadyText({ trend = "flat", trendPct = 0.03 }))
    Click("Sell")
    Drop({ itemID = 2589, commodity = true })
    world.commodityResults = { { unitPrice = 103, quantity = 5 } }
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    Check("Sell: a quiet price reads steady", SellValue("trend") == "|cff9d9d9dsteady +3%|r")
    Check("Sell: and the advice says normal", MainFrame().sellPanel.hint.text == "Prices are about normal today.")
    Click("Reset")
    Drop({ itemID = 2589, commodity = true })
    world.commodityResults = {}
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    Check("Sell: no one selling says so in the advice",
        MainFrame().sellPanel.hint.text == "No one else is selling it right now, so you set the price.")
end

-- Two-way tabs: our tabs are secure click buttons. The game itself
-- presses Blizzard's matching tab; addon code never calls its window.
do
    Setup()
    Load()
    OpenHouse()
    local frame = MainFrame()
    local buyTab, sellTab = TabNamed("Buy"), TabNamed("Sell")
    Check("our tabs are secure click buttons",
        sellTab.template:find("SecureActionButtonTemplate", 1, true) ~= nil
        and sellTab.attributes.type == "click" and buyTab.attributes.type == "click")
    Check("they act on mouse release", sellTab.attributes.useOnKeyDown == false)
    Check("they point at Blizzard's tabs",
        sellTab.attributes.clickbutton == AuctionHouseFrame.SellTab
        and buyTab.attributes.clickbutton == AuctionHouseFrame.BuyTab)
    Check("their OnClick is the secure one, not ours", sellTab.scripts.PostClick ~= nil)

    Click("Sell")
    Check("our Sell tab switches Blizzard's window",
        AuctionHouseFrame.displayMode == AuctionHouseFrameDisplayMode.ItemSell)
    Check("and opens our Sell tab", frame.selectedTab == 2 and frame.sellPanel.shown)
    Click("Buy")
    Check("our Buy tab switches Blizzard's window back",
        AuctionHouseFrame.displayMode == AuctionHouseFrameDisplayMode.Buy and frame.selectedTab == 1)
    Check("addon code never called Blizzard's window", (world.addonHouseCalls or 0) == 0)
    Check("tab clicks send no query", #world.browseQueries == 0 and #world.itemQueries == 0)
end

do
    -- Before Blizzard's window exists, our tabs still switch our panels.
    Setup()
    Load()
    Click("Sell")
    Check("an unlinked tab still opens our Sell tab", MainFrame().selectedTab == 2)
end

do
    -- Combat: protected frames can't be changed by addon code, so the
    -- window waits for combat to end and then catches up.
    Setup()
    Load()
    local frame = MainFrame()
    world.inCombat = true
    OpenHouse()
    Check("in combat: nothing protected is changed", (world.blocked or 0) == 0)
    Check("in combat: the window waits", frame.shown == false)
    Check("in combat: tabs are not linked yet", TabNamed("Sell").attributes.clickbutton == nil)
    BlizzardTab(AuctionHouseFrameDisplayMode.ItemSell)
    Check("in combat: the Sell panel still follows Blizzard", frame.sellPanel.shown)
    Check("in combat: tab buttons are left alone", (world.blocked or 0) == 0)
    world.inCombat = false
    Fire("PLAYER_REGEN_ENABLED")
    Check("after combat: the window shows beside the house",
        frame.shown == true and frame.points[1] and frame.points[1][2] == AuctionHouseFrame)
    Check("after combat: tabs are linked",
        TabNamed("Sell").attributes.clickbutton == AuctionHouseFrame.SellTab)
    Check("after combat: the Sell tab is marked", frame.selectedTab == 2)

    world.inCombat = true
    frame:GetScript("OnDragStart")(frame)
    frame:GetScript("OnDragStop")(frame)
    Check("in combat: dragging the window changes nothing", (world.blocked or 0) == 0)
    CloseHouse()
    Check("closing in combat: the window waits", frame.shown == true and (world.blocked or 0) == 0)
    world.inCombat = false
    Fire("PLAYER_REGEN_ENABLED")
    Check("after combat: the window hides", frame.shown == false)
    Check("still nothing blocked", (world.blocked or 0) == 0)
end

do
    -- If the game counts the panels as protected too, switching them waits
    -- for combat to end; the game is asked, not assumed.
    Setup()
    Load()
    OpenHouse()
    local frame = MainFrame()
    frame.buyPanel.protected = true
    frame.sellPanel.protected = true
    world.inCombat = true
    BlizzardTab(AuctionHouseFrameDisplayMode.ItemSell)
    Check("in combat: protected panels are left alone", (world.blocked or 0) == 0 and frame.buyPanel.shown)
    world.inCombat = false
    Fire("PLAYER_REGEN_ENABLED")
    Check("after combat: the Sell panel shows", frame.sellPanel.shown and not frame.buyPanel.shown and frame.selectedTab == 2)
end

do
    -- A /reload in combat: the window is built once combat ends.
    Setup()
    world.inCombat = true
    Load()
    local built = false
    for _, object in ipairs(world.frames) do
        built = built or object.name == "HouseLedgerFrame"
    end
    Check("loaded in combat: nothing protected is built or changed", (world.blocked or 0) == 0 and not built)
    world.inCombat = false
    Fire("PLAYER_REGEN_ENABLED")
    Check("after combat: the window is built", MainFrame() ~= nil and TabNamed("Sell") ~= nil)
end

-- Blizzard's window leads; HouseLedger follows it, and its own code never
-- calls that window (our tabs reach it only through the game's secure click).
do
    Setup()
    Load()
    OpenHouse()
    local frame = MainFrame()
    local hooked = {}
    for _, hook in ipairs(world.hooks) do
        hooked[hook.name] = hook.owner == AuctionHouseFrame
    end
    local function HouseHooks()
        local count = 0
        for _, hook in ipairs(world.hooks) do
            count = count + (hook.owner == AuctionHouseFrame and 1 or 0)
        end
        return count
    end
    Check("Blizzard's window is followed with hooksecurefunc",
        HouseHooks() == 2 and hooked.SetPostItem and hooked.SetDisplayMode)
    CloseHouse()
    OpenHouse()
    Check("reopening the house adds no second hook", HouseHooks() == 2)

    BlizzardTab(AuctionHouseFrameDisplayMode.ItemSell)
    Check("Blizzard's Sell tab opens the Sell tab here", frame.selectedTab == 2 and frame.sellPanel.shown)
    BlizzardTab(AuctionHouseFrameDisplayMode.Auctions)
    Check("Blizzard's Auctions tab leaves this window as it was", frame.selectedTab == 2)
    BlizzardTab(AuctionHouseFrameDisplayMode.CommoditiesBuy)
    Check("Blizzard's Buy tab opens the Buy tab here", frame.selectedTab == 1 and frame.buyPanel.shown)

    Click("Sell")
    Click("Buy")
    Click("Sell")
    Drop({ itemID = 2589, commodity = true })
    Check("tabs and drops here never call Blizzard's window", (world.addonHouseCalls or 0) == 0)
    Check("Blizzard's tab follows our last tab click, through the secure click",
        AuctionHouseFrame.displayMode == AuctionHouseFrameDisplayMode.ItemSell)
end

do
    Setup()
    Load()
    OpenHouse()
    local frame = MainFrame()
    BlizzardPostItem({ itemID = 2589, commodity = true })
    Check("an item put in Blizzard's Sell window opens the Sell tab here", frame.selectedTab == 2)
    Check("its name shows here", frame.sellPanel.itemName.text == "Item 2589")
    Check("following Blizzard sends no search of its own",
        #world.itemQueries == 0 and #world.blizzardQueries == 1)
    Check("Sell waits for Blizzard's answer", SellStatus() == "Reading the auction house's prices for Item 2589...")
    world.commodityResults = { { unitPrice = 120, quantity = 47 }, { unitPrice = 130, quantity = 5 } }
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    Check("Blizzard's results show here", SellValue("low") == "<money 120>" and SellValue("atLow") == "47")
    Check("still no search of its own", #world.itemQueries == 0)
    Check("following never calls Blizzard's window", (world.addonHouseCalls or 0) == 0)
end

do
    Setup()
    Load()
    OpenHouse()
    world.equipment = true
    BlizzardPostItem({ itemID = 7005, itemLevel = 24, itemSuffix = 1179 })
    world.itemResults = { { itemKey = { itemID = 7005 }, buyoutAmount = 500, quantity = 1, owners = {} } }
    Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 7005, itemLevel = 0, itemSuffix = 0 })
    Check("gear from Blizzard's Sell window is read with the any-variant key",
        world.readKey ~= nil and world.readKey.itemLevel == 0 and world.readKey.itemSuffix == 0)
    Check("its price shows here", SellValue("low") == "<money 500>")

    -- A bag: Blizzard searched with the item's own key, so it is read with that.
    world.equipment = false
    world.itemResults = {}
    BlizzardPostItem({ itemID = 4496, itemLevel = 10, itemSuffix = 0 })
    world.itemResults = { { itemKey = { itemID = 4496 }, buyoutAmount = 900, quantity = 1, owners = {} } }
    Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 4496, itemLevel = 10, itemSuffix = 0 })
    Check("other items are read with the key Blizzard searched with",
        world.readKey ~= nil and world.readKey.itemLevel == 10)
    Check("no search of its own for either", #world.itemQueries == 0)
end

do
    -- Gear the house has no item info for yet: Blizzard searched with the
    -- full key. Blizzard searches again on its own later (after a post)
    -- with the any-variant key, without SetPostItem; that answer is read
    -- with the key it came back for.
    Setup()
    Load()
    OpenHouse()
    world.equipment = true
    world.noItemInfo = true
    BlizzardPostItem({ itemID = 7005, itemLevel = 24, itemSuffix = 1179 })
    world.noItemInfo = false
    world.itemResults = { { itemKey = { itemID = 7005 }, buyoutAmount = 700, quantity = 1, owners = {} } }
    Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 7005, itemLevel = 0, itemSuffix = 0 })
    Check("a followed item is read with the key its results came back for",
        world.readKey ~= nil and world.readKey.itemLevel == 0 and SellValue("low") == "<money 700>")
end

do
    Setup()
    Load()
    OpenHouse()
    local frame = MainFrame()
    BlizzardPostItem({ itemID = 6948, sellable = false })
    BlizzardPostItem({ itemID = 2589, status = 0 })
    Check("items Blizzard turns away change nothing here",
        frame.selectedTab == 1 and frame.sellPanel.itemName.text ~= "Item 6948"
        and frame.sellPanel.itemName.text ~= "Item 2589")

    -- Blizzard turns an item away while its multi-sell bar is up: the hook
    -- still runs, so the window is read to see what Blizzard really holds.
    world.blizzardBusy = true
    BlizzardPostItem({ itemID = 2592, commodity = true })
    world.blizzardBusy = false
    Check("an item Blizzard did not take changes nothing here", frame.sellPanel.itemName.text ~= "Item 2592")

    -- A WoW Token goes to Blizzard's token frame, with no item search.
    _G.C_WowTokenPublic = { IsAuctionableWowToken = function(itemID) return itemID == 122284 end }
    BlizzardPostItem({ itemID = 122284 })
    _G.C_WowTokenPublic = nil
    Check("a WoW Token is left to Blizzard", frame.sellPanel.itemName.text ~= "Item 122284")

    -- Blizzard's answer can already be in by the time the hook runs.
    world.commodityResults = { { unitPrice = 90, quantity = 3 } }
    BlizzardPostItem({ itemID = 2589, commodity = true })
    Check("results already in show at once", SellValue("low") == "<money 90>")
end

-- ---------------------------------------------------------------------
-- Market tab: deals, drops and rises from saved data only
-- ---------------------------------------------------------------------

do
    Setup({ listings = { Listing(1, 1, 50, true) } })
    world.now = 1762900000
    local P = HouseLedgerPrice
    local db = P.EmptyDB()
    for day = 1, 5 do
        local best = {}
        P.Consider(best, 1, 1, day < 5 and 100 or 50, "Cheap Today", 2)
        P.Consider(best, 3, 1, day < 5 and 100 or 150, "Pricier", 3)
        P.Consider(best, 4, 1, 100, "Same", 1)
        P.Consider(best, 5, 1, day < 5 and 100 or 80, "Unknown Quality", -1) -- down 20%, not a deal
        P.Commit(db, "Alliance|TestRealm", best, world.now - (5 - day) * 24 * 60 * 60 - 2 * 60 * 60)
    end
    _G.HouseLedgerDB = db
    Load()
    OpenHouse()
    local frame = MainFrame()
    world.browseResults = BrowseResults(10, 12)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    local queries, scans = #world.browseQueries, world.replicateCalls

    local market = TabNamed("Market")
    Check("the window has a Market tab", market ~= nil and frame.numTabs == 4)
    Check("Market is a plain tab that presses nothing on Blizzard's window",
        market and not market.template:find("SecureActionButtonTemplate", 1, true)
        and market.attributes.clickbutton == nil)
    Click("Market")
    local panel = frame.buyPanel
    local rows = ResultRows()
    Check("Market shows the list without the search box", frame.selectedTab == 3 and panel.shown
        and not SearchBox().shown and panel.marketLabel.shown and panel.marketDropdown.shown)
    Check("it opens on deals at the last scan", Picked(panel.marketDropdown) == "Deals"
        and panel.marketLabel.text == "at last scan (2 h ago)" and panel.marketDropdown.shown)
    local views = {}
    for index, choice in ipairs(MenuChoices(panel.marketDropdown)) do
        views[index] = choice.text
    end
    Check("the view dropdown lists the three views", table.concat(views, ",") == "Deals,Biggest drops,Biggest rises")
    Check("a deal row shows the saved name, last-scan price and the deal star",
        rows[1].nameText.text == "Cheap Today" and rows[1].priceText.text == "<money 50>"
        and rows[1].trendText.text:find(HouseLedgerPrice.DEAL_ICON, 1, true) ~= nil and not rows[2].shown)
    Check("the Price heading says it is the scanned price", panel.marketMode and frame.buyPanel.priceHeading.text == "Scanned")
    Check("status counts the deals", StatusLine() == "Showing 1-1 of 1 deals.")

    Pick(panel.marketDropdown, "Biggest drops")
    Check("picking Biggest drops shows them", Picked(panel.marketDropdown) == "Biggest drops"
        and rows[1].nameText.text == "Cheap Today")
    Check("an item whose quality the scan didn't know shows without an error",
        rows[2].nameText.text == "Unknown Quality" and rows[2].shown)
    Pick(panel.marketDropdown, "Biggest rises")
    Check("picking Biggest rises shows them", rows[1].nameText.text == "Pricier"
        and StatusLine() == "Showing 1-1 of 1 rises.")

    rows[1]:GetScript("OnClick")(rows[1])
    Check("a row click shows its saved prices", panel.detailTitle.text == "Pricier, 5 scans over 5 days")
    rows[1]:GetScript("OnEnter")(rows[1])
    Check("Market sends nothing: tab, arrows, row click and hover",
        #world.browseQueries == queries and world.replicateCalls == scans)

    Click("Buy")
    Check("Buy brings the search back, with its results kept", SearchBox().shown and not panel.marketLabel.shown
        and not panel.marketDropdown.shown
        and ResultRows()[1].nameText.text == "Item 10" and frame.buyPanel.priceHeading.text == "Price")
    Click("Market")
    BlizzardTab(AuctionHouseFrameDisplayMode.ItemSell)
    Check("a Blizzard tab change moves off Market", frame.selectedTab == 2 and frame.sellPanel.shown)

    -- In combat the tab marking waits, and combat's end lands on Market.
    Click("Buy")
    world.inCombat = true
    Click("Market")
    Check("in combat: nothing protected is changed by the Market tab", (world.blocked or 0) == 0)
    world.inCombat = false
    Fire("PLAYER_REGEN_ENABLED")
    Check("after combat: Market is the open tab", frame.selectedTab == 3 and panel.marketLabel.shown)

    -- A new scan refreshes the list. The game hasn't loaded this item's name: the old one stays.
    Advance(15 * 60)
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers()
    Check("a scan without the item's name keeps the saved one",
        HouseLedgerDB.houses["Alliance|TestRealm"].items[1].name == "Cheap Today")
    Check("after a scan the Market list is from the new scan", panel.marketLabel.text:find("just now", 1, true) ~= nil)
end

do
    Setup()
    Load()
    OpenHouse()
    Click("Market")
    Check("Market with nothing saved says to scan", StatusLine() == "No prices saved yet. Click Scan once."
        and not ResultRows()[1].shown)
end

-- ---------------------------------------------------------------------
-- Filters: quality and item level on Buy and Market, and a name filter on Market
-- ---------------------------------------------------------------------

do
    Setup()
    Load()
    OpenHouse()
    local panel = MainFrame().buyPanel
    Check("Buy shows the quality and item level filters, not Market's name filter",
        panel.qualityDropdown.shown and panel.minLevelBox.shown and panel.maxLevelBox.shown
        and not panel.filterNameBox.shown)
    Check("quality starts at any", Picked(panel.qualityDropdown) == "Any quality")
    Check("an empty Buy list says how to start, in large text in the middle of the list",
        panel.listMessage.shown and panel.listMessage.text == "Type a name or pick a quality, then click Search.")
    SearchBox():SetText("")
    Click("Search")
    Check("no name and no filter sends nothing", #world.browseQueries == 0
        and StatusLine() == "Type at least 2 letters, or pick a quality.")
    Check("and says so where the player looks: the list and the note by the filters",
        panel.listMessage.text == "Type at least 2 letters, or pick a quality."
        and panel.notice.shown and panel.notice.text == "Type at least 2 letters, or pick a quality.")
    Pick(panel.qualityDropdown, "Rare & up")
    local query = world.browseQueries[1]
    Check("picking a quality searches at once; with no name, once, asking for those qualities only",
        #world.browseQueries == 1 and query.searchString == ""
        and table.concat(query.filters, ",") == "9,10")

    world.qualities = { [1] = 3, [2] = 3, [3] = 4, [4] = 2 }
    world.browseResults = {}
    for itemID, level in ipairs({ 5, 10, 20, 30 }) do
        world.browseResults[itemID] = { itemKey = { itemID = itemID, itemLevel = level, itemSuffix = 0 },
            minPrice = 100, totalQuantity = 1 }
    end
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    local rows = ResultRows()
    Check("results below the quality are left out", rows[1].nameText.text == "Item 1" and rows[3].nameText.text == "Item 3"
        and not rows[4].shown and StatusLine() == "Showing 1-3 of 3 (filtered from 4).")
    Check("with rows showing, the big message and the note go away", not panel.listMessage.shown and not panel.notice.shown)
    Type(panel.minLevelBox, "10")
    Check("a minimum item level filters the results by their own item level, sending nothing",
        rows[1].nameText.text == "Item 2" and rows[2].nameText.text == "Item 3" and not rows[3].shown
        and #world.browseQueries == 1)
    Type(panel.maxLevelBox, "15")
    Check("and a maximum", rows[1].nameText.text == "Item 2" and not rows[2].shown)
    Pick(panel.qualityDropdown, "Any quality")
    Type(panel.maxLevelBox, "")
    Check("loosening the filters shows what the search already brought", rows[3].nameText.text == "Item 4"
        and #world.browseQueries == 1)
    Check("and says a lower quality needs a new search, by the filters and on Search itself",
        panel.notice.shown and panel.notice.text == "Click Search again to include lower qualities."
        and ButtonNamed("Search").highlightLocked == true
        and StatusLine():find("Click Search again to include lower qualities.", 1, true) ~= nil)
    Pick(panel.qualityDropdown, "Epic & up")
    Check("picking another quality searches again, for that quality", #world.browseQueries == 2
        and table.concat(world.browseQueries[2].filters, ",") == "10")
    Pick(panel.qualityDropdown, "Any quality")
    Check("Any quality with no name has nothing to search, so the pick only filters", #world.browseQueries == 2)
    Click("Search")
    Check("an empty name with only an item level sends nothing: the house never sees item level",
        #world.browseQueries == 2 and StatusLine() == "Type at least 2 letters, or pick a quality."
        and panel.notice.text == "Type at least 2 letters, or pick a quality.")
    SearchBox():SetText("linen")
    Click("Search")
    Check("a name with a level filter asks for every quality", #world.browseQueries == 3
        and table.concat(world.browseQueries[3].filters, ",") == "6,7,8,9,10")
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    Check("after the new search the lower-quality note goes away", StatusLine():find("Search again", 1, true) == nil)

    world.partialBrowse = true
    Type(panel.minLevelBox, "")
    Check("a partial page says these are only the first results, by the filters",
        panel.notice.text == "These are the first 4 results. Add a name or filter to see others."
        and StatusLine() == "Showing 1-4 of 4. These are the first 4 results. Add a name or filter to see others.")
    Type(panel.minLevelBox, "99")
    Check("when the filters hide a whole partial page, the list says so in large text",
        panel.listMessage.shown and panel.listMessage.text == "Nothing on this page matches the filters."
        and StatusLine() == "Nothing on this page matches the filters (4 hidden). These are the first 4 results."
            .. " Add a name or filter to see others.")

    Pick(panel.qualityDropdown, "Rare & up")
    Type(panel.maxLevelBox, "50")
    Click("Clear")
    Check("Clear empties the name and resets the quality and item level filters",
        SearchBox():GetText() == "" and Picked(panel.qualityDropdown) == "Any quality"
        and panel.minLevelBox:GetText() == "" and panel.maxLevelBox:GetText() == ""
        and panel.listMessage.text == "Type a name or pick a quality, then click Search." and not panel.notice.shown)
end

do
    Setup()
    world.now = 1762900000
    local P = HouseLedgerPrice
    local db = P.EmptyDB()
    for day = 1, 5 do
        local best = {}
        P.Consider(best, 1, 1, day < 5 and 100 or 50, "Cheap Today", 2)
        P.Consider(best, 2, 1, day < 5 and 100 or 70, "Cheap Cloak", 3)
        P.Consider(best, 5, 1, day < 5 and 100 or 80, "Mystery", -1)
        P.Commit(db, "Alliance|TestRealm", best, world.now - (5 - day) * 24 * 60 * 60)
    end
    _G.HouseLedgerDB = db
    world.itemInfo = { [1] = { name = "Cheap Today", quality = 2, level = 12 },
        [2] = { name = "Cheap Cloak", quality = 3, level = 25 } }
    Load()
    OpenHouse()
    local panel = MainFrame().buyPanel
    Click("Market")
    Pick(panel.marketDropdown, "Biggest drops") -- all three
    local rows = ResultRows()
    Check("Market shows its name filter with the others", panel.filterNameBox.shown and panel.qualityDropdown.shown)
    Check("all three drops show unfiltered", rows[3].shown and not rows[4].shown)
    Type(panel.filterNameBox, "CHEAP")
    Check("the name filter keeps matching names, any case", rows[1].nameText.text == "Cheap Today"
        and rows[2].nameText.text == "Cheap Cloak" and not rows[3].shown
        and StatusLine() == "Showing 1-2 of 2 drops (filtered from 3).")
    Pick(panel.qualityDropdown, "Rare & up")
    Check("the quality filter uses the saved quality", rows[1].nameText.text == "Cheap Cloak" and not rows[2].shown)
    Pick(panel.qualityDropdown, "Any quality")
    Type(panel.filterNameBox, "")
    Type(panel.minLevelBox, "20")
    Check("the level filter uses the item's base level; unknown items wait until loaded",
        rows[1].nameText.text == "Cheap Cloak" and not rows[2].shown)
    world.itemInfo[5] = { name = "Mystery", quality = 2, level = 30 }
    local timers = #world.timers
    for _ = 1, 3 do
        Fire("GET_ITEM_INFO_RECEIVED", 5, true)
    end
    Check("a burst of item-info events filters once, on the next frame", #world.timers == timers + 1
        and not rows[2].shown)
    RunTimers()
    Check("once the game loads an item, the filter counts it", rows[1].nameText.text == "Cheap Cloak"
        and rows[2].nameText.text == "Mystery")
    Type(panel.minLevelBox, "")
    Click("Buy")
    Check("Buy hides Market's name filter", not panel.filterNameBox.shown)
    Check("filters send nothing on Market", #world.browseQueries == 0 and world.replicateCalls == 0)
end

-- ---------------------------------------------------------------------
-- Settings tab
-- ---------------------------------------------------------------------

do
    Setup({ listings = { Listing(4306, 5, 250) } })
    Load()
    OpenHouse()
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers()
    local frame = MainFrame()
    local tab = TabNamed("Settings")
    Check("the window has a Settings tab, a plain one", tab ~= nil and frame.numTabs == 4
        and not tab.template:find("SecureActionButtonTemplate", 1, true))
    Click("Settings")
    local panel = frame.settingsPanel
    Check("Settings shows its own panel", frame.selectedTab == 4 and panel.shown and not frame.buyPanel.shown
        and not frame.sellPanel.shown)
    local boxes = panel.boxes
    Check("each box shows its saved setting", boxes.tooltipPrices.checked == true and boxes.tooltipDetails.checked == false)

    local lines = {}
    local tooltip = {
        AddLine = function(_, text) lines[#lines + 1] = text end,
        AddDoubleLine = function(_, left, right) lines[#lines + 1] = left .. " = " .. right end,
    }
    local function Hover()
        lines = {}
        world.tooltipHooks[1].fn(tooltip, { id = 4306 })
        return lines
    end
    boxes.tooltipDetails:SetChecked(true)
    boxes.tooltipDetails:GetScript("OnClick")(boxes.tooltipDetails)
    Check("with the details setting on, tooltips show the day lines without Shift",
        HouseLedgerDB.settings.tooltipDetails == true and #Hover() == 3 and lines[2] == "1 day, 1 scan = <money 50>")
    boxes.tooltipPrices:SetChecked(false)
    boxes.tooltipPrices:GetScript("OnClick")(boxes.tooltipPrices)
    Check("with tooltip prices off, tooltips get nothing", HouseLedgerDB.settings.tooltipPrices == false and #Hover() == 0)
    Check("settings send nothing", #world.browseQueries == 0 and world.replicateCalls == 1)
    Check("the history dropdown shows 14 days at first", Picked(panel.historyDropdown) == "14 days"
        and #MenuChoices(panel.historyDropdown) == 2)
    Pick(panel.historyDropdown, "30 days")
    Check("picking 30 days saves it and keeps 30 days", HouseLedgerDB.settings.historyDays == 30
        and HouseLedgerPrice.DAYS_KEPT == 30 and Picked(panel.historyDropdown) == "30 days")
    Pick(panel.historyDropdown, "14 days")
    Check("picking 14 days again saves it", HouseLedgerDB.settings.historyDays == 14 and HouseLedgerPrice.DAYS_KEPT == 14)
    Click("Buy")
    Check("Buy hides the Settings panel", frame.buyPanel.shown and not panel.shown)
end


-- ---------------------------------------------------------------------
-- Show: everything, gear this character can use, or recipes for its professions
-- ---------------------------------------------------------------------

do
    Setup()
    Load()
    OpenHouse()
    local panel = MainFrame().buyPanel
    local show = panel.showDropdown
    Check("the Show dropdown starts at everything, with four choices", Picked(show) == "Everything"
        and #MenuChoices(show) == 4 and show.shown)
    world.class, world.level = "PALADIN", 45
    Pick(show, "Gear for me")
    Check("picking a choice searches at once, one search", #world.browseQueries == 1)
    local query = world.browseQueries[1]
    --- The query's class filters as text, like "2 4/4 4/0 4/1/16 4/6 4/7".
    local function Classes(sent)
        local parts = {}
        for _, class in ipairs(sent.itemClassFilters or {}) do
            parts[#parts + 1] = class.classID .. (class.subClassID and ("/" .. class.subClassID) or "")
                .. (class.inventoryType and ("/" .. class.inventoryType) or "")
        end
        return table.concat(parts, " ")
    end
    Check("Gear for me, a level 45 paladin: weapons, plate, rings and such, cloaks, shields and librams",
        #world.browseQueries == 1 and query.searchString == "" and Classes(query) == "2 4/4 4/0 4/1/16 4/6 4/7"
        and query.filters[#query.filters] == Enum.AuctionHouseFilter.UsableOnly)
    Check("the status says what it searched for", StatusLine() == "Searching weapons and plate armor for this character...")
    world.level = 30
    Click("Search")
    Check("a paladin under 40 gets mail", Classes(world.browseQueries[2]) == "2 4/3 4/0 4/1/16 4/6 4/7")
    world.class = "MAGE"
    Click("Search")
    Check("a mage gets cloth, which already has the cloaks", Classes(world.browseQueries[3]) == "2 4/1 4/0")
    world.class = "DEMONHUNTER"
    Click("Search")
    Check("a class it doesn't know gets everything it can use", Classes(world.browseQueries[4]) == "2 4"
        and StatusLine() == "Searching gear for this character...")
    world.class = "PALADIN"
    Pick(show, "Usable gear")
    Check("Usable gear: every weapon and armor type the house says it can use",
        Classes(world.browseQueries[5]) == "2 4"
        and world.browseQueries[5].filters[#world.browseQueries[5].filters] == Enum.AuctionHouseFilter.UsableOnly)
    SearchBox():SetText("sword")
    Pick(show, "Gear for me")
    Check("a name narrows it", world.browseQueries[6].searchString == "sword"
        and world.browseQueries[6].itemClassFilters ~= nil)

    world.browseResults = BrowseResults(1, 3)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    Pick(show, "Everything")
    Check("changing Show with results up searches again, now for everything", #world.browseQueries == 7
        and world.browseQueries[7].searchString == "sword" and world.browseQueries[7].itemClassFilters == nil)
    world.professions = { { skillLine = 197, profession = Enum.Profession.Tailoring },
        { skillLine = 186, profession = Enum.Profession.Mining }, nil, nil,
        { skillLine = 185, profession = Enum.Profession.Cooking } }
    SearchBox():SetText("")
    Pick(show, "My recipes")
    query = world.browseQueries[8]
    local subclasses = {}
    for _, class in ipairs(query.itemClassFilters) do
        subclasses[#subclasses + 1] = class.classID == Enum.ItemClass.Recipe and class.subClassID
    end
    Check("My recipes searches recipes of this character's crafting professions",
        #subclasses == 2 and subclasses[1] == Enum.ItemRecipeSubclass.Tailoring
        and subclasses[2] == Enum.ItemRecipeSubclass.Cooking and query.searchString == "")
    Check("recipes aren't limited to usable ones", query.filters[#query.filters] ~= Enum.AuctionHouseFilter.UsableOnly)

    world.professions = { { skillLine = 165 }, { skillLine = 129 } }
    Click("Search")
    query = world.browseQueries[9]
    Check("without the game's profession name, the skill line still finds the recipes",
        #query.itemClassFilters == 2 and query.itemClassFilters[1].subClassID == Enum.ItemRecipeSubclass.Leatherworking
        and query.itemClassFilters[2].subClassID == Enum.ItemRecipeSubclass.FirstAid)

    world.professions = { { skillLine = 182, profession = Enum.Profession.Herbalism } }
    Click("Search")
    Check("a character with no crafting profession is told so, and nothing is sent", #world.browseQueries == 9
        and StatusLine() == "This character has no profession with recipes.")

    Click("Market")
    Check("Market hides the Show dropdown", not show.shown)
    Click("Buy")
    Check("Buy shows it again", show.shown)
    Click("Clear")
    Check("Clear goes back to everything", Picked(show) == "Everything")
    Click("Search")
    Check("then an empty name needs letters or a quality again", #world.browseQueries == 9)
    Click("Market")
    Pick(panel.qualityDropdown, "Rare & up")
    Check("on Market a quality pick only filters saved prices: nothing is sent", #world.browseQueries == 9)
    Pick(panel.qualityDropdown, "Any quality")
end

-- ---------------------------------------------------------------------
-- House overview: the Buy details block while no row is picked
-- ---------------------------------------------------------------------

do
    Setup({ screenRight = 1400 })
    Load()
    OpenHouse()
    local panel = MainFrame().buyPanel
    Check("before any scan the details block keeps its hint",
        panel.detailTitle.text == "Click a row for its saved prices over 1, 3, 7 and 14 days."
        and not panel.overviewChart.shown)
end

do
    Setup({ screenRight = 1400 })
    Load()
    SaveDailyHistory(5)
    OpenHouse()
    local panel = MainFrame().buyPanel
    local chart = panel.overviewChart
    local function Line(index)
        return panel.detailLines[index].left.text .. " = " .. panel.detailLines[index].right.text
    end
    Check("with saved scans, Buy shows the house overview",
        panel.detailTitle.text == "House overview, 5 days of scans"
        and Line(1) == "Items listed = 1 at the last scan (avg 1)" and Line(2) == "Trend = steady"
        and Line(3) == "Next day, about = 1 item" and Line(4) == "Listings / units = from your next scan")
    Check("its chart shows each day and the next day's estimate", chart.shown and chart.slotCount == 8
        and chart.caption.text == "Items listed, 7 days" and chart.bars[7].shown and chart.bars[8].shown
        and not chart.bars[1].shown and not chart.bars[9].shown)
    Check("the last scan's day is gold, the estimate purple", chart.bars[7].colorTexture[1] == 1
        and chart.bars[8].colorTexture[3] == 1 and chart.bars[8].colorTexture[2] < 0.5
        and chart.bars[6].colorTexture[1] < 1)
    Check("the overview chart fills the room right of its lines", chart.chartWidth == MainFrame().width - 396
        and chart.barArea == 62)
    Check("the trend line runs across the chart", chart.line.shown and chart.line.startPoint ~= nil
        and chart.line.endPoint[4] > chart.line.startPoint[3])
    Check("the overview sends nothing", #world.browseQueries == 0 and world.replicateCalls == 0)

    world.browseResults = BrowseResults(4306, 4306, 70)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    Check("new search results keep the overview until a row is clicked",
        panel.detailTitle.text:find("House overview", 1, true) == 1 and chart.shown)
    local row = ResultRows()[1]
    row:GetScript("OnClick")(row)
    Check("a row click swaps in the item's prices and chart", not chart.shown and panel.chart.shown
        and panel.detailTitle.text == "Item 4306, 5 scans over 5 days")
    Click("Clear")
    Check("Clear brings the overview back", chart.shown and not panel.chart.shown
        and panel.detailTitle.text:find("House overview", 1, true) == 1)
    Click("Market")
    Check("Market keeps its hint instead", not chart.shown
        and panel.detailTitle.text == "Click a row for its saved prices over 1, 3, 7 and 14 days.")
    Click("Buy")
    Check("back on Buy, the overview again", chart.shown)
end

do
    Setup({ screenRight = 1400 })
    Load()
    local P = HouseLedgerPrice
    -- Items listed each day go up and down, so there is spread around the trend line.
    -- Oldest day first, the way scans happen.
    for day, items in ipairs({ 3, 5, 4, 6, 5, 7 }) do
        local best = {}
        for itemID = 1, items do
            P.Consider(best, itemID, 1, 100)
        end
        P.Commit(HouseLedgerDB, "Alliance|TestRealm", best, world.now - (6 - day) * 24 * 60 * 60)
    end
    OpenHouse()
    local chart = MainFrame().buyPanel.overviewChart
    local bands = 0
    for index = 1, chart.slotCount do
        bands = bands + (chart.bands[index].shown and 1 or 0)
    end
    Check("days that go up and down get the normal-range band around the line", bands > 0
        and chart.line.shown and MainFrame().buyPanel.detailLines[2].right.text:find("a day", 1, true) ~= nil)
end

do
    Setup({ screenRight = 1400 })
    Load()
    SaveDailyHistory(1)
    OpenHouse()
    local chart = MainFrame().buyPanel.overviewChart
    Check("one day of scans: a bar but no trend line yet", chart.shown and chart.slotCount == 7
        and not chart.line.shown and not chart.bands[1].shown)
end

do
    Setup({ screenRight = 1100 })
    Load()
    SaveDailyHistory(5)
    OpenHouse()
    local panel = MainFrame().buyPanel
    Check("a narrow window shows the overview's lines without its chart",
        panel.detailTitle.text:find("House overview", 1, true) == 1 and not panel.overviewChart.shown)
end

do
    Setup({ screenRight = 1400, listings = { Listing(4306, 5, 250), Listing(4306, 20, 2000), Listing(2589, 3, 0),
        Listing(2589, 2, 90) } })
    Load()
    OpenHouse()
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers()
    local daily = HouseLedgerDB.houses["Alliance|TestRealm"].daily
    -- Value: 25 units of 4306 at its cheapest (50 each) and 2 of 2589 at 45.
    Check("a scan saves the day's listings, units and value, skipping bid-only listings",
        #daily == 1 and daily[1][2] == 3 and daily[1][3] == 27 and daily[1][4] == 1340)
    local panel = MainFrame().buyPanel
    Check("the overview shows the scan it just saved", panel.detailTitle.text
        == "House overview, 1 day of scans"
        and panel.detailLines[4].right.text == "3 / 27" and panel.detailLines[5].right.text == "<money 1340>")
end

-- ---------------------------------------------------------------------
-- Price chart: Buy and Market details, and the Sell tab; it grows with the history
-- ---------------------------------------------------------------------

--- The bars of a chart that show, by day slot.
-- @param chart the chart frame
-- @return list of heights (nil for a hidden bar)
local function BarHeights(chart)
    local heights = {}
    for index, bar in ipairs(chart.bars) do
        heights[index] = bar.shown and bar.height or false
    end
    return heights
end

do
    Setup({ screenRight = 1400 })
    Load()
    SaveDailyHistory(5)
    OpenHouse()
    world.browseResults = BrowseResults(4306, 4306, 70)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    local panel = MainFrame().buyPanel
    Check("the chart waits for a row click", not panel.chart.shown)
    local queries = #world.browseQueries
    local row = ResultRows()[1]
    row:GetScript("OnClick")(row)
    local chart = panel.chart
    local heights = BarHeights(chart)
    Check("a row click shows its chart, 7 days for a young item, and the next day's guess",
        chart.shown and chart.slotCount == 8 and chart.caption.text == "Daily low, 7 days" and #chart.bars == 31)
    Check("days with scans have bars, the rest none", heights[7] and heights[3] and not heights[2] and not heights[1]
        and heights[8] and not heights[9] and not heights[31])
    Check("bars scale to the chart's top price", heights[7] == chart.barArea and heights[3] == chart.barArea)
    Check("the latest day is gold", chart.bars[7].colorTexture[1] == 1 and chart.bars[6].colorTexture[1] < 1)
    Check("7 days and the guess share the chart's width, the guess a gap apart",
        chart.bars[2].points[1][4] == math.floor((chart.chartWidth - 3) / 8) + 1)
    Check("the chart says its top price", chart.topText.text == "<money 100>")
    Check("the chart sends nothing", #world.browseQueries == queries)
    Click("Clear")
    Check("Clear hides the chart", not panel.chart.shown)
end

do
    Setup({ screenRight = 1100 })
    Load()
    SaveDailyHistory(5)
    OpenHouse()
    world.browseResults = BrowseResults(4306, 4306, 70)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    local row = ResultRows()[1]
    row:GetScript("OnClick")(row)
    Check("a narrow window leaves the chart out", not MainFrame().buyPanel.chart.shown)
end

do
    Setup()
    Load()
    SaveDailyHistory(4, 2589)
    OpenHouse()
    Click("Sell")
    local chart = MainFrame().sellPanel.chart
    Check("the Sell chart waits for an item", not chart.shown)
    Drop({ itemID = 2589, commodity = true })
    world.commodityResults = { { itemID = 2589, unitPrice = 120, quantity = 2, owners = {} } }
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    Check("a dropped item with saved prices shows its chart", chart.shown and BarHeights(chart)[7])
    Click("Reset")
    Check("Reset hides it", not chart.shown)
end

do
    -- 20 days of prices with 30 days kept: the chart grows to 20 slots; 14 days trims it.
    Setup({ screenRight = 1400 })
    Load()
    HouseLedgerPrice.SetHistoryDays(HouseLedgerDB, 30)
    SaveDailyHistory(20)
    OpenHouse()
    world.browseResults = BrowseResults(4306, 4306, 70)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    local row = ResultRows()[1]
    row:GetScript("OnClick")(row)
    local chart = MainFrame().buyPanel.chart
    local heights = BarHeights(chart)
    Check("with 30 days kept, the chart grows to the oldest saved day", chart.slotCount == 21
        and chart.caption.text == "Daily low, 20 days" and heights[1] and heights[20] and heights[21]
        and not heights[22])
    Click("Settings")
    Pick(MainFrame().settingsPanel.historyDropdown, "14 days")
    Click("Buy")
    row = ResultRows()[1]
    row:GetScript("OnClick")(row)
    heights = BarHeights(chart)
    Check("14 days trims the history at once, and the chart with it", chart.slotCount == 15
        and #HouseLedgerDB.houses["Alliance|TestRealm"].items[4306].days == 14 and heights[14] and heights[15]
        and not heights[16])
    HouseLedgerPrice.SetHistoryDays(HouseLedgerDB, 14)
end

do
    -- Days | Scans: one saved choice for every price chart; the scan view has a bar per scan.
    Setup({ screenRight = 1400 })
    Load()
    SaveDailyHistory(3)
    local P = HouseLedgerPrice
    local best = {}
    P.Consider(best, 4306, 1, 50)
    P.Commit(HouseLedgerDB, "Alliance|TestRealm", best, world.now - 24 * 60 * 60 + 60)
    OpenHouse()
    world.browseResults = BrowseResults(4306, 4306, 70)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    local row = ResultRows()[1]
    row:GetScript("OnClick")(row)
    local chart = MainFrame().buyPanel.chart
    local queries = #world.browseQueries
    Check("charts open on days, its word bright", chart.caption.text == "Daily low, 7 days"
        and chart.viewWords.days.label.color[1] == 1 and chart.viewWords.scans.label.color[1] < 1)
    chart:GetScript("OnEnter")(chart)
    Check("hovering the chart says what it shows", _G.GameTooltip.text == "Daily low, 7 days")
    chart.viewWords.scans:GetScript("OnClick")(chart.viewWords.scans)
    local heights = BarHeights(chart)
    Check("Scans redraws the chart at once, a bar per scan", chart.shown and chart.slotCount == 7
        and chart.caption.text == "Each scan, 4 scans" and heights[4] and heights[7] and not heights[3])
    Check("the scan view is saved and its word bright", HouseLedgerDB.settings.chartView == "scans"
        and chart.viewWords.scans.label.color[1] == 1 and chart.viewWords.days.label.color[1] < 1)
    Check("the cheaper scan has the shorter bar", heights[7] < heights[6])
    local x = {}
    for index = 5, 7 do
        x[index] = chart.bars[index].points[1][4]
    end
    Check("a new day starts after a little gap", x[6] - x[5] > x[7] - x[6])
    Check("the latest scan is gold", chart.bars[7].colorTexture[1] == 1 and chart.bars[6].colorTexture[1] < 1)
    Check("the hover tip follows the view", _G.GameTooltip.text == "Each scan, 4 scans")
    Check("switching sends nothing", #world.browseQueries == queries)

    Click("Sell")
    Drop({ itemID = 4306, commodity = true })
    world.commodityResults = { { itemID = 4306, unitPrice = 120, quantity = 2, owners = {} } }
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 4306)
    local sellChart = MainFrame().sellPanel.chart
    Check("the Sell chart uses the same view", sellChart.shown and sellChart.caption.text == "Each scan, 4 scans")

    HouseLedgerDB.houses["Alliance|TestRealm"].items[4306].scans = nil
    Click("Reset")
    Drop({ itemID = 4306, commodity = true })
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 4306)
    Check("an item saved before scans says when they start", sellChart.shown and sellChart.emptyText.shown
        and sellChart.caption.text == "Each scan: none saved yet" and not BarHeights(sellChart)[1])
    sellChart.viewWords.days:GetScript("OnClick")(sellChart.viewWords.days)
    Check("Days brings its daily bars back", sellChart.shown and not sellChart.emptyText.shown
        and sellChart.caption.text == "Daily low, 7 days" and HouseLedgerDB.settings.chartView == "days")
end

--- Saves one scan a day for item 4306 at these prices, oldest first, the last one yesterday.
-- @param prices copper per unit, one per day
local function SaveDailyPrices(prices)
    local P = HouseLedgerPrice
    for index, price in ipairs(prices) do
        local best = {}
        P.Consider(best, 4306, 1, price)
        P.Commit(HouseLedgerDB, "Alliance|TestRealm", best, world.now - (#prices - index + 1) * 24 * 60 * 60)
    end
end

--- Opens the house, shows item 4306 on Buy and clicks its row.
-- @return the Buy chart
local function ShowBuyChart()
    OpenHouse()
    world.browseResults = BrowseResults(4306, 4306, 70)
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    local row = ResultRows()[1]
    row:GetScript("OnClick")(row)
    return MainFrame().buyPanel.chart
end

--- Hovers a chart and returns the lines its tip added.
-- @param chart a price chart
-- @return the lines, in order
local function ChartTipLines(chart)
    local lines = {}
    _G.GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
    chart:GetScript("OnEnter")(chart)
    _G.GameTooltip.AddLine = nil
    return lines
end

--- Whether any tip line holds the text.
-- @param lines from ChartTipLines
-- @param text plain text to find
-- @return true when one line holds it
local function TipHas(lines, text)
    for _, line in ipairs(lines) do
        if line:find(text, 1, true) then
            return true
        end
    end
    return false
end

do
    -- Trend line, normal range and guess on a price chart, like the house overview's.
    Setup({ screenRight = 1400 })
    Load()
    -- Rising 10 a day, with one odd cheap day that mustn't tilt the line.
    SaveDailyPrices({ 100, 110, 120, 5, 140, 150, 160 })
    local chart = ShowBuyChart()
    local queries = #world.browseQueries
    local slotWidth = (chart.chartWidth - 3) / 8
    local middle = 1 + math.max(2, math.floor(slotWidth) - 2) / 2
    Check("a price chart gets a trend line from its first bar to the guess", chart.line and chart.line.shown
        and chart.line.startPoint[3] == middle and chart.line.endPoint[3] > chart.bars[8].points[1][4])
    Check("the odd cheap day doesn't tilt it: it runs 100 to 170",
        chart.line.startPoint[4] == 2 + 100 / 170 * chart.barArea and chart.line.endPoint[4] == 2 + chart.barArea)
    Check("the guess is the line at the next day, in purple", chart.slotCount == 8 and chart.bars[8].shown
        and chart.bars[8].height == chart.barArea and chart.bars[8].colorTexture[1] == 0.72)
    Check("the latest real day stays gold", chart.bars[7].colorTexture[1] == 1)
    Check("the axis grows to fit the guess", chart.topText.text == "<money 170>")
    local bands = 0
    for _, band in ipairs(chart.trendBands) do
        bands = bands + (band.shown and 1 or 0)
    end
    Check("prices on the line get no normal-range band", bands == 0)
    local lines = ChartTipLines(chart)
    Check("the hover tip says what the line and the purple bar are", TipHas(lines, "White line")
        and TipHas(lines, "Purple: a guess at the next day, <money 170>.") and not TipHas(lines, "Faint band"))
    Check("drawing it sends nothing", #world.browseQueries == queries)

    chart.viewWords.scans:GetScript("OnClick")(chart.viewWords.scans)
    lines = ChartTipLines(chart)
    Check("Scans draws them per scan, the guess for the next scan", chart.line.shown and chart.slotCount == 8
        and TipHas(lines, "Purple: a guess at the next scan"))

    HouseLedgerDB.houses["Alliance|TestRealm"].items[4306].scans = nil
    local row = ResultRows()[1]
    row:GetScript("OnClick")(row)
    Check("an item without scans hides the line and the guess", chart.emptyText.shown and not chart.line.shown
        and not chart.bars[8].shown and not TipHas(ChartTipLines(chart), "White line"))
    chart.viewWords.days:GetScript("OnClick")(chart.viewWords.days)
end

do
    -- Up and down: a flat line through the middle, with its normal range behind the bars.
    Setup({ screenRight = 1400 })
    Load()
    SaveDailyPrices({ 100, 120, 100, 120, 100, 120 })
    local chart = ShowBuyChart()
    local shown = {}
    for index, band in ipairs(chart.trendBands) do
        shown[index] = band.shown
    end
    Check("prices that go up and down get the normal-range band, first bar to the guess",
        shown[2] and shown[8] and not shown[1] and not shown[9] and chart.line.startPoint[4] == chart.line.endPoint[4])
    Check("the tip names the band", TipHas(ChartTipLines(chart), "Faint band: its normal range."))
    Check("the axis grows to the band's top, in whole copper", chart.topText.text == "<money 125>")
end

do
    -- A steep rise: the line would start under 0, so it starts where it crosses 0.
    Setup({ screenRight = 1400 })
    Load()
    SaveDailyPrices({ 1, 2, 3, 200, 400, 600, 800 })
    local chart = ShowBuyChart()
    Check("a line that would start under 0 starts at 0, a little way in", chart.line.startPoint[4] == 2
        and chart.line.startPoint[3] > chart.bars[2].points[1][4]
        and chart.line.startPoint[3] < chart.bars[3].points[1][4])

    -- A steep fall: the line stops where it reaches 0, and there's no guess under 0.
    Setup({ screenRight = 1400 })
    Load()
    SaveDailyPrices({ 800, 600, 400, 200, 3, 2, 1 })
    chart = ShowBuyChart()
    Check("a line that would end under 0 stops at 0, with no guess", chart.line.endPoint[4] == 2
        and chart.line.endPoint[3] > chart.bars[5].points[1][4] and chart.line.endPoint[3] < chart.bars[7].points[1][4]
        and chart.slotCount == 7 and not chart.bars[8].shown)
end

do
    -- Too few bars: no line, band or guess.
    Setup({ screenRight = 1400 })
    Load()
    SaveDailyPrices({ 100, 110, 120, 130 })
    local chart = ShowBuyChart()
    Check("4 days: no line or guess yet", chart.shown and not chart.line.shown and chart.slotCount == 7
        and not chart.bars[8].shown and not TipHas(ChartTipLines(chart), "White line"))
end

-- ---------------------------------------------------------------------
-- Price Check: saved prices anywhere, no auction house needed
-- ---------------------------------------------------------------------

do
    Setup()
    world.now = 1762900000
    local P = HouseLedgerPrice
    local db = P.EmptyDB()
    for day = 1, 3 do
        local best = {}
        P.Consider(best, 2589, 1, 10 + day, "Linen Cloth", 1)
        P.Consider(best, 2996, 1, 100, "Bolt of Linen Cloth", 1)
        P.Consider(best, 2592, 1, 30, "Wool Cloth", 1)
        P.Commit(db, "Alliance|TestRealm", best, world.now - (3 - day) * 24 * 60 * 60)
    end
    _G.HouseLedgerDB = db
    Load()
    -- The auction house is never opened here.
    local window = _G.HouseLedgerPriceCheck
    Check("the Price Check window starts hidden", window ~= nil and not window.shown)
    Check("Escape closes it, like the game's own windows", _G.UISpecialFrames[1] == "HouseLedgerPriceCheck")
    _G.SlashCmdList.HOUSELEDGERPC("")
    Check("/pc opens it away from the auction house", window.shown
        and window.status.text == "Type 2 letters of an item's name.")
    Type(window.searchBox, "lin")
    local rows = window.rows
    Check("typing finds saved items by name, names that start with it first",
        rows[1].nameText.text == "Linen Cloth" and rows[2].nameText.text == "Bolt of Linen Cloth" and not rows[3].shown)
    Check("a row shows the last price and the trend", rows[1].priceText.text == "<money 13>")
    Check("the status counts the matches", window.status.text == "2 items match.")
    rows[2]:GetScript("OnClick")(rows[2])
    Check("a row click shows its saved prices and chart", window.detailTitle.text == "Bolt of Linen Cloth, 3 scans over 3 days"
        and window.detailLines[1].left.text == "1 day, 1 scan" and window.chart.shown)
    rows[1]:GetScript("OnEnter")(rows[1])
    Check("hovering shows the game's item tooltip", _G.GameTooltip.itemByID == 2589)
    Check("Price Check sends nothing to the auction house", #world.browseQueries == 0 and world.replicateCalls == 0
        and #world.itemQueries == 0)
    _G.SlashCmdList.HOUSELEDGERPC("")
    Check("/pc again closes it", not window.shown)
    _G.SlashCmdList.HOUSELEDGERPC("wool")
    Check("/pc with a name opens it already searched", window.shown and window.searchBox.text == "wool"
        and rows[1].nameText.text == "Wool Cloth")
    Type(window.searchBox, "zzz")
    Check("no match says names fill in from scans", window.status.text
        == "No saved item matches. Names fill in from your scans.")

    local button = window.bagButtons[1]
    Check("a Price Check button sits above the bags", button ~= nil and button.shown and button.text == "Price Check"
        and button.parent == _G.ContainerFrameCombinedBags and window.bagButtons[2].parent == _G.ContainerFrame1)
    button:GetScript("OnClick")(button)
    Check("which closes and opens the window", not window.shown)
    Check("each column heading is there to sort by", window.headerTexts.name.text == "Item"
        and window.headerTexts.price.text == "Price" and window.headerTexts.trend.text == "Trend")
end

--- Saves `count` items named "Ore 01", "Ore 02"..., priced 10 copper apart from the top down,
-- with a scan a day for `days` days, so some have trends.
-- @param count how many items
-- @return the saved db
local function SaveOres(count)
    local P = HouseLedgerPrice
    local db = P.EmptyDB()
    for day = 1, 3 do
        local best = {}
        for index = 1, count do
            -- Item 2 drops on the last day, item 3 rises.
            local price = 1000 - index * 5
            if day == 3 and index == 2 then price = 100 end
            if day == 3 and index == 3 then price = 2000 end
            P.Consider(best, 5000 + index, 1, price, string.format("Ore %02d", index), 1)
        end
        P.Commit(db, "Alliance|TestRealm", best, world.now - (3 - day) * 24 * 60 * 60)
    end
    return db
end

do
    Setup()
    world.now = 1762900000
    Load()
    _G.HouseLedgerDB = HouseLedgerPrice.EnsureDB(SaveOres(30))
    local window = _G.HouseLedgerPriceCheck
    _G.SlashCmdList.HOUSELEDGERPC("ore")
    local rows = window.rows
    Check("more matches than rows: the status says which ones show and how many",
        window.status.text == "1-12 of 30 items. Scroll for more." and rows[12].nameText.text == "Ore 12")
    window:GetScript("OnMouseWheel")(window, -1)
    Check("the wheel scrolls down 3 rows", rows[1].nameText.text == "Ore 04"
        and window.status.text == "4-15 of 30 items. Scroll for more.")
    for _ = 1, 10 do
        window:GetScript("OnMouseWheel")(window, -1)
    end
    Check("it stops at the last match", rows[12].nameText.text == "Ore 30" and window.status.text == "19-30 of 30 items. Scroll for more.")
    window:GetScript("OnMouseWheel")(window, 1)
    Check("and scrolls back up", rows[1].nameText.text == "Ore 16")

    window.sortButtons.price:GetScript("OnClick")(window.sortButtons.price)
    Check("Price sorts cheapest first and goes back to the top", rows[1].nameText.text == "Ore 02"
        and rows[2].nameText.text == "Ore 30" and window.headerTexts.price.text:find("NPE_ArrowUp", 1, true) ~= nil)
    window.sortButtons.price:GetScript("OnClick")(window.sortButtons.price)
    Check("a second click sorts dearest first", rows[1].nameText.text == "Ore 03"
        and window.headerTexts.price.text:find("NPE_ArrowDown", 1, true) ~= nil)
    window.sortButtons.trend:GetScript("OnClick")(window.sortButtons.trend)
    Check("Trend sorts the biggest drop first", rows[1].nameText.text == "Ore 02"
        and window.headerTexts.price.text == "Price")
    window.sortButtons.name:GetScript("OnClick")(window.sortButtons.name)
    Check("Item sorts A to Z", rows[1].nameText.text == "Ore 01")
    Type(window.searchBox, "ore 1")
    Check("a new search keeps the sort", rows[1].nameText.text == "Ore 10" and window.status.text == "10 items match.")
    Check("sorting and scrolling send nothing", #world.browseQueries == 0 and world.replicateCalls == 0)
end

do
    Setup()
    world.now = 1762900000
    Load()
    _G.HouseLedgerDB = HouseLedgerPrice.EnsureDB(SaveOres(130))
    local window = _G.HouseLedgerPriceCheck
    _G.SlashCmdList.HOUSELEDGERPC("ore")
    Check("past the list's limit, the count is still every match",
        window.status.text == "1-12 of 130 items. Type more to narrow them.")
    for _ = 1, 50 do
        window:GetScript("OnMouseWheel")(window, -1)
    end
    Check("scrolling stops at the end of the list", window.rows[12].nameText.text == window.found[100].name
        and window.status.text == "89-100 of 130 items. Type more to narrow them.")
end

do
    Setup()
    world.now = 1762900000
    Load()
    _G.HouseLedgerDB = HouseLedgerPrice.EnsureDB(SaveOres(5))
    local window = _G.HouseLedgerPriceCheck
    local link = "|cffffffff|Hitem:5003::::::::60:::::|h[Ore 03]|h|r"
    ChatFrameUtil.InsertLink(link)
    Check("a shift-click with Price Check closed does nothing to it", window.searchBox.text == "")
    _G.SlashCmdList.HOUSELEDGERPC("")
    ChatFrameUtil.InsertLink(link)
    Check("a shift-clicked item is looked up in Price Check", window.searchBox.text == "Ore 03"
        and window.rows[1].nameText.text == "Ore 03" and window.status.text == "1 item matches.")
    Check("the game's own link insert still ran", world.insertedLinks == 2)
    world.chatOpen = true
    ChatFrameUtil.InsertLink("|cffffffff|Hitem:5001::::::::60:::::|h[Ore 01]|h|r")
    Check("a link going into an open chat box leaves Price Check alone", window.searchBox.text == "Ore 03")
    window.searchBox:SetFocus()
    ChatFrameUtil.InsertLink("|cffffffff|Hitem:5001::::::::60:::::|h[Ore 01]|h|r")
    Check("unless Price Check's box has the focus", window.searchBox.text == "Ore 01")
    world.chatOpen = false
    ChatFrameUtil.InsertLink("|cff71d5ff|Hspell:13262|h[Disenchant]|h|r")
    Check("a spell link is not an item to look up", window.searchBox.text == "Ore 01")
    Check("looking up a link sends nothing", #world.browseQueries == 0 and world.replicateCalls == 0
        and #world.itemQueries == 0)
end

do
    Setup()
    Load()
    OpenHouse()
    Click("Settings")
    local boxes = MainFrame().settingsPanel.boxes
    boxes.priceCheckButton:SetChecked(false)
    boxes.priceCheckButton:GetScript("OnClick")(boxes.priceCheckButton)
    local buttons = _G.HouseLedgerPriceCheck.bagButtons
    Check("the bag button can be turned off in Settings", not buttons[1].shown and not buttons[2].shown)
    _G.SlashCmdList.HOUSELEDGERPC("")
    Check("/pc still opens Price Check", _G.HouseLedgerPriceCheck.shown
        and _G.HouseLedgerPriceCheck.status.text == "Type 2 letters of an item's name.")
end

-- ---------------------------------------------------------------------
-- ilvl column and sorting by a column click
-- ---------------------------------------------------------------------

--- Clicks a column heading's sort button.
-- @param key the column: name, ilvl, price, avail, typical or trend
local function SortBy(key)
    local button = MainFrame().buyPanel.sortButtons[key]
    button:GetScript("OnClick")(button)
end

--- The names in the shown rows, top first.
-- @return the names joined with commas
local function RowNames()
    local names = {}
    for _, row in ipairs(ResultRows()) do
        if row.shown then
            names[#names + 1] = row.nameText.text
        end
    end
    return table.concat(names, ",")
end

do
    Setup()
    Load()
    OpenHouse()
    world.browseResults = {}
    for index, spec in ipairs({ { 30, 300, 5 }, { 10, 100, 0 }, { 20, 200, 25 } }) do
        world.browseResults[index] = { itemKey = { itemID = index, itemLevel = spec[3], itemSuffix = 0 },
            minPrice = spec[2], totalQuantity = spec[1] }
    end
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    local panel = MainFrame().buyPanel
    local rows = ResultRows()
    Check("Buy shows each result's own item level, blank without one", rows[1].ilvlText.text == "5"
        and rows[2].ilvlText.text == "" and rows[3].ilvlText.text == "25" and panel.headerTexts.ilvl.text == "ilvl")
    local queries = #world.browseQueries
    SortBy("price")
    Check("a heading click sorts by it, cheapest first", RowNames() == "Item 2,Item 3,Item 1")
    Check("the heading shows the sort arrow", panel.headerTexts.price.text:find("NPE_ArrowUp", 1, true) ~= nil)
    SortBy("price")
    Check("clicking it again reverses the sort", RowNames() == "Item 1,Item 3,Item 2"
        and panel.headerTexts.price.text:find("NPE_ArrowDown", 1, true) ~= nil)
    SortBy("ilvl")
    Check("ilvl sorts highest first, items without one last", RowNames() == "Item 3,Item 1,Item 2"
        and not panel.headerTexts.price.text:find("Arrow", 1, true))
    SortBy("avail")
    Check("Avail. sorts most first", RowNames() == "Item 1,Item 3,Item 2")
    SortBy("name")
    Check("Item sorts A to Z", RowNames() == "Item 1,Item 2,Item 3")
    Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    Check("a new search keeps the chosen sort", RowNames() == "Item 1,Item 2,Item 3")
    Check("sorting sends nothing", #world.browseQueries == queries)
end

do
    Setup()
    world.now = 1762900000
    local P = HouseLedgerPrice
    local db = P.EmptyDB()
    for day = 1, 5 do
        local best = {}
        P.Consider(best, 1, 1, day < 5 and 100 or 50, "Cheap Today", 2)
        P.Consider(best, 2, 1, day < 5 and 100 or 70, "Also Cheap", 3)
        P.Commit(db, "Alliance|TestRealm", best, world.now - (5 - day) * 24 * 60 * 60)
    end
    _G.HouseLedgerDB = db
    world.itemInfo = { [1] = { name = "Cheap Today", quality = 2, level = 12 },
        [2] = { name = "Also Cheap", quality = 3, level = 25 } }
    Load()
    OpenHouse()
    Click("Market")
    local panel = MainFrame().buyPanel
    Pick(panel.marketDropdown, "Biggest drops")
    local rows = ResultRows()
    Check("Market starts in its own order, biggest drop first", RowNames() == "Cheap Today,Also Cheap")
    Check("Market shows the base item level", rows[1].ilvlText.text == "12" and rows[2].ilvlText.text == "25")
    Check("the Market price heading keeps its name", panel.headerTexts.price.text == "Scanned")
    SortBy("ilvl")
    Check("Market sorts by a heading too", RowNames() == "Also Cheap,Cheap Today")
    Check("with the arrow on its heading", panel.headerTexts.ilvl.text:find("NPE_ArrowDown", 1, true) ~= nil)
    SortBy("price")
    Check("Market's price heading keeps its name with the arrow", panel.headerTexts.price.text:find("^Scanned") ~= nil)
    Pick(panel.marketDropdown, "Biggest rises")
    Pick(panel.marketDropdown, "Biggest drops")
    Check("switching the Market view goes back to its own order", RowNames() == "Cheap Today,Also Cheap"
        and not panel.headerTexts.price.text:find("Arrow", 1, true))
    Click("Buy")
    Check("Buy's heading says Price again", panel.headerTexts.price.text == "Price")
end

-- ---------------------------------------------------------------------
-- Combat: if the game counts our scan widgets or the bag windows as protected
-- ---------------------------------------------------------------------

do
    Setup({ listings = ManyListings(1200) })
    Load()
    OpenHouse()
    Click("Scan")
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    -- Combat starts mid-read, and the game says the Scan button and the bar are protected.
    world.inCombat = true
    ButtonNamed("Scan").protected = true
    MainFrame().scanBar.protected = true
    RunTimers()
    local house = HouseLedgerDB.houses["Alliance|TestRealm"]
    local priced = 0
    for _ in pairs(house and house.items or {}) do
        priced = priced + 1
    end
    Check("a scan that reads into combat still finishes and saves", priced == 300)
    Advance(3)
    Check("and no protected widget was touched in combat", (world.blocked or 0) == 0)
    world.inCombat = false
    Fire("PLAYER_REGEN_ENABLED")
    Advance(1)
    Check("after combat the Scan button counts down again", ButtonNamed("Scan").text == "Scan (15m)"
        and not ButtonNamed("Scan").enabled and not MainFrame().scanBar.shown)
end

do
    -- A /reload in combat: Price Check works, but its bag buttons wait for the fight to end.
    Setup()
    _G.ContainerFrameCombinedBags.protected = true
    _G.ContainerFrame1.protected = true
    world.inCombat = true
    Load()
    local window = _G.HouseLedgerPriceCheck
    Check("in combat Price Check is built, but no bag button yet", window ~= nil and #window.bagButtons == 0)
    _G.SlashCmdList.HOUSELEDGERPC("")
    Check("/pc works in combat", window.shown)
    world.inCombat = false
    Fire("PLAYER_REGEN_ENABLED")
    Check("after combat the bag buttons are made", #window.bagButtons == 2 and window.bagButtons[1].shown)

    world.inCombat = true
    HouseLedgerDB.settings.priceCheckButton = false
    window.updateBagButtons()
    Check("in combat a setting change waits", window.bagButtons[1].shown and (world.blocked or 0) == 0)
    world.inCombat = false
    Fire("PLAYER_REGEN_ENABLED")
    Check("and applies when combat ends", not window.bagButtons[1].shown)
end

-- ---------------------------------------------------------------------
-- Market asks the game's item data only for what saved data lacks
-- ---------------------------------------------------------------------

do
    Setup()
    world.now = 1762900000
    local P = HouseLedgerPrice
    local db = P.EmptyDB()
    for day = 1, 5 do
        local best = {}
        for itemID = 1, 40 do
            P.Consider(best, itemID, 1, day < 5 and 100 or 60, "Item " .. itemID, 2)
        end
        P.Commit(db, "Alliance|TestRealm", best, world.now - (5 - day) * 24 * 60 * 60)
    end
    _G.HouseLedgerDB = db
    world.itemInfo = {}
    for itemID = 1, 40 do
        world.itemInfo[itemID] = { name = "Item " .. itemID, quality = 2, level = itemID }
    end
    Load()
    OpenHouse()
    Click("Market")
    local panel = MainFrame().buyPanel
    Pick(panel.marketDropdown, "Biggest drops")
    world.itemInfoCalls = 0
    Type(panel.filterNameBox, "item 1")
    Pick(panel.qualityDropdown, "Uncommon & up")
    Check("name and quality filters use the saved name and quality, not the game's item data",
        (world.itemInfoCalls or 0) <= 15)
    Type(panel.minLevelBox, "30")
    local first = world.itemInfoCalls
    Type(panel.minLevelBox, "35")
    Check("item levels are asked once, then remembered", world.itemInfoCalls - first <= 15)
    Type(panel.minLevelBox, "")
    Pick(panel.qualityDropdown, "Any quality")
    Type(panel.filterNameBox, "")
    local timers = #world.timers
    Fire("GET_ITEM_INFO_RECEIVED", 7, true)
    Check("with no level filter or level sort, an item arriving doesn't rebuild the list", #world.timers == timers)
end

if failed > 0 then
    io.write(string.format("%d failed\n", failed))
    os.exit(1)
end
io.write("all passed\n")
