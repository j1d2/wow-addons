--[[
Offline checks for HouseLedger.lua (frames, events, scan flow).
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

local function Noop() end

--- Methods every fake frame or font string answers. Unknown methods
--- fall through to a no-op so layout calls (SetSize, SetBackdrop...)
--- do not need their own stubs.
local FrameMethods = {}

--- Counts a change the game would block: addon code changing a
--- protected frame (a secure button, or its parent) during combat.
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

function FrameMethods:CreateFontString()
    local fontString = NewObject("FontString")
    self.fontStrings[#self.fontStrings + 1] = fontString
    return fontString
end

function FrameMethods:CreateTexture()
    return NewObject("Texture")
end

--- Build a listing row in GetReplicateItemInfo order. Owner fields are
--- filled on purpose so the tests can prove they are never saved.
local function Listing(itemID, count, buyout)
    return { itemID = itemID, count = count, buyout = buyout }
end

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
    _G.GetRealmName = function() return "TestRealm" end
    _G.IsShiftKeyDown = function() return world.shiftDown == true end
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
            PoorQuality = 6, CommonQuality = 7, UncommonQuality = 8,
            RareQuality = 9, EpicQuality = 10,
        },
        AuctionHouseSortOrder = { Price = 0, Name = 1 },
        TooltipDataType = { Item = 0 },
        ItemCommodityStatus = { Unknown = 0, Item = 1, Commodity = 2 },
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
    _G.GameTooltip.SetItemKey = function(_, itemID)
        world.tooltip.items[#world.tooltip.items + 1] = itemID
    end
    _G.C_Item = {
        GetItemQualityColor = function() return 1, 1, 1 end,
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

    _G.TooltipDataProcessor = {
        AddTooltipPostCall = function(kind, fn)
            world.tooltipHooks[#world.tooltipHooks + 1] = { kind = kind, fn = fn }
        end,
    }

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
            return "Item " .. row.itemID, 134400, row.count, 1, true, 1, "",
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
        HasFullBrowseResults = function() return true end,
        GetItemKeyInfo = function(itemKey)
            if world.noItemInfo then
                return nil
            end
            return {
                itemName = "Item " .. itemKey.itemID, quality = 1, iconFileID = 134400,
                isEquipment = world.equipment == true,
            }
        end,
    }

    dofile(folder .. "/PriceLedger.lua")
    dofile(folder .. "/HouseLedger.lua")
end

local function EventFrame()
    for _, object in ipairs(world.frames) do
        if object.events.ADDON_LOADED then
            return object
        end
    end
end

local function Fire(event, ...)
    local handler = EventFrame():GetScript("OnEvent")
    handler(EventFrame(), event, ...)
end

local function MainFrame() return _G.HouseLedgerFrame end

local function ButtonNamed(label)
    for _, object in ipairs(world.frames) do
        if object.kind == "Button" and object.text == label then
            return object
        end
    end
end

local function SearchBox()
    for _, object in ipairs(world.frames) do
        if object.kind == "EditBox" then
            return object
        end
    end
end

--- Bottom status line. BuildFrame creates font strings in this order:
--- title, search status, MAX_ROWS result rows, scan status (last).
local function ScanLine()
    local list = MainFrame().fontStrings
    return list[#list].text
end

--- A mouse click: OnClick, then PostClick when the button has one.
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

--- Blizzard's window: 800 x 538 at x 16, so its right edge is at 816.
--- SetDisplayMode and SetPostItem act like Blizzard's: SetPostItem turns
--- away what its Sell tab would, sends Blizzard's one search (counted in
--- world.blizzardQueries, not world.itemQueries) and switches to Sell.
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
local function AsBlizzard(fn)
    world.blizzardActing = true
    fn()
    world.blizzardActing = false
end

local function BlizzardTab(mode)
    AsBlizzard(function() AuctionHouseFrame:SetDisplayMode(mode) end)
end

--- An item dropped on Blizzard's Sell window, or right-clicked from a bag.
local function BlizzardPostItem(item)
    AsBlizzard(function() AuctionHouseFrame:SetPostItem(item) end)
end

local function OpenHouse()
    world.houseOpen = true
    _G.AuctionHouseFrame = _G.AuctionHouseFrame or NewHouseFrame()
    _G.AuctionHouseFrame.shown = true
    Fire("AUCTION_HOUSE_SHOW")
end

local function CloseHouse()
    world.houseOpen = false
    if _G.AuctionHouseFrame then
        _G.AuctionHouseFrame.shown = false
    end
    Fire("AUCTION_HOUSE_CLOSED")
end

--- Run queued C_Timer.After callbacks. Bounded so a loop bug fails
--- the test instead of hanging it.
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

--- Move the clock forward, one OnUpdate per second while shown.
local function Advance(seconds)
    for _ = 1, seconds do
        world.now = world.now + 1
        local frame = MainFrame()
        if frame and frame.shown then
            frame:GetScript("OnUpdate")(frame, 1)
        end
    end
end

local function Load()
    Fire("ADDON_LOADED", "HouseLedger")
end

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
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    Check("first batch reads, rest is queued", #world.timers == 1)
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
    Check("scan unlocks the button", ButtonNamed("Scan").enabled)
    Check("status reports the save", ScanLine():find("Saved 300 prices", 1, true) ~= nil)
    Check("seller names are never saved", not DeepFind(HouseLedgerDB, "SellerBob"))
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
    Check("no answer unlocks the button", ButtonNamed("Scan").enabled)
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
local function ResultRows()
    local rows = {}
    for _, object in ipairs(world.frames) do
        if object.kind == "Button" and object.nameText then
            rows[#rows + 1] = object
        end
    end
    return rows
end

local function TypicalColumnShown()
    return ResultRows()[1].typicalText.shown == true
end

--- The line under the results: search status or a clicked row's stats.
local function StatusLine()
    return MainFrame().buyPanel.fontStrings[1].text
end

local function ListFrame()
    return ResultRows()[1].parent
end

local function WheelDown()
    ListFrame():GetScript("OnMouseWheel")(ListFrame(), -1)
end

local function WheelUp()
    ListFrame():GetScript("OnMouseWheel")(ListFrame(), 1)
end

-- ---------------------------------------------------------------------
-- Layout. Blizzard's AuctionHouseFrame is 800 x 538 and toplevel; a
-- centered HouseLedger sat over its results list and went behind it.
-- ---------------------------------------------------------------------

--- True when the frame's top and bottom are both on the auction house's
--- right edge, so it is beside the house and exactly as tall.
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
    for _, owner in ipairs({ MainFrame(), MainFrame().buyPanel, MainFrame().sellPanel }) do
        for _, line in ipairs(owner.fontStrings) do
            lines[#lines + 1] = line
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
    Check("rows fill the height above the details block", #ResultRows() == 16)
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

--- Saves one scan a day of an item (default 4306) at 100c for the days
--- before today.
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
    -- The details block under the list leaves room for 16 rows.
    Check("the list has 16 rows", #rows == 16)
    Check("status counts what is shown", StatusLine() == "Showing 1-16 of 30.")
    Check("the last row shows the 16th result", rows[16].nameText.text == "Item 16")

    local queries = #world.browseQueries
    WheelDown()
    Check("mouse wheel scrolls three rows", rows[1].nameText.text == "Item 4")
    Check("status follows the scroll", StatusLine() == "Showing 4-19 of 30.")
    for _ = 1, 5 do
        WheelDown()
    end
    Check("scroll stops at the last result", rows[16].nameText.text == "Item 30" and rows[1].nameText.text == "Item 15")
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
    Check("before a click, the details block says what it is for",
        panel.detailTitle.text == "Click a row for its saved prices over 1, 3, 7 and 14 days.")
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
    Check("details: 14 days", Detail(4, "14 days, 5 scans", "<money 100>"))
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


-- ---------------------------------------------------------------------
-- Tabs and the Sell tab. One drop sends one search; nothing is saved.
-- ---------------------------------------------------------------------

local function TabNamed(label)
    for _, object in ipairs(world.frames) do
        if type(object.template) == "string" and object.template:find("PanelTabButtonTemplate", 1, true)
            and object.text == label then
            return object
        end
    end
end

local function SellValue(key)
    return MainFrame().sellPanel.values[key].text
end

local function SellStatus()
    return MainFrame().sellPanel.statusText.text
end

local function Drop(item)
    world.cursorItem = item
    local slot = MainFrame().sellPanel.slot
    slot:GetScript("OnReceiveDrag")(slot)
end

--- True when any string saved in the table contains `needle`.
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
    Check("window has Buy and Sell tabs", TabNamed("Buy") ~= nil and TabNamed("Sell") ~= nil and frame.numTabs == 2)
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
    Check("Blizzard's window is followed with hooksecurefunc",
        #world.hooks == 2 and hooked.SetPostItem and hooked.SetDisplayMode)
    CloseHouse()
    OpenHouse()
    Check("reopening the house adds no second hook", #world.hooks == 2)

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

if failed > 0 then
    io.write(string.format("%d failed\n", failed))
    os.exit(1)
end
io.write("all passed\n")
