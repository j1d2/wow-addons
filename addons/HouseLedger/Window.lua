--[[
The HouseLedger window beside Blizzard's auction house: the frame, its tabs, where it sits,
and following Blizzard's window through hooksecurefunc (never calling its methods).
]]

local _, ns = ...
local C, ui, state, U, Chart, Scan, Tooltip, Buy, Sell, Purchase, PC, Settings, Window = ns.C, ns.ui, ns.state, ns.U,
    ns.Chart, ns.Scan, ns.Tooltip, ns.Buy, ns.Sell, ns.Purchase, ns.PC, ns.Settings, ns.Window

-- The Buy chart's height, beside the details block.
local CHART_HEIGHT = 74
local SELL_TAB = 2
-- Settings is ours alone, like Market.
local SETTINGS_TAB = 4

-- Blizzard's auction window is followed through hooksecurefunc, set once.
local houseHooked = false

-- Our tabs are secure click buttons pointed at Blizzard's tabs, set once.
local tabsLinked = false

--- Shows the Buy, Sell or Market tab.
-- @param id BUY_TAB, SELL_TAB or MARKET_TAB
local function SelectTab(id)
    if id ~= state.currentTab then
        -- Another tab leaves an item's listings and drops a price the house quoted.
        Purchase.Close()
    end
    state.currentTab = id
    -- The tab buttons are protected; in combat they are marked afterwards.
    -- The panels switch right away unless the game counts them as
    -- protected too; then OnCombatEnded switches them.
    if U.InCombat() then
        state.afterCombat = true
    else
        PanelTemplates_SetTab(ui.frame, id)
    end
    if U.Locked(ui.buyPanel) or U.Locked(ui.sellPanel) then
        return
    end
    if id == SETTINGS_TAB then
        ui.buyPanel:Hide()
        ui.sellPanel:Hide()
        ui.settingsPanel:Show()
    elseif id == SELL_TAB then
        ui.buyPanel:Hide()
        ui.settingsPanel:Hide()
        ui.sellPanel:Show()
    else
        ui.sellPanel:Hide()
        ui.settingsPanel:Hide()
        ui.buyPanel:Show()
        if (id == C.MARKET_TAB) ~= (ui.buyPanel.marketMode == true) then
            Buy.SetMarketMode(id == C.MARKET_TAB)
        end
    end
end

--- One of the Buy and Sell tabs under the window, like the auction house's own.
-- One tab: Blizzard's tab look, and the game's secure click button.
-- Once linked (LinkTabs), a click makes the game itself press
-- Blizzard's matching tab; addon code never calls Blizzard's window.
-- Its OnClick stays the secure one; our panel switch runs after it.
-- @param id BUY_TAB or SELL_TAB
-- @param label the tab's text
-- @return the tab button
local function BuildTab(id, label)
    local tab = CreateFrame("Button", "HouseLedgerFrameTab" .. id, ui.frame,
        "PanelTabButtonTemplate,SecureActionButtonTemplate")
    tab:SetID(id)
    tab:SetText(label)
    tab:SetAttribute("type", "click")
    -- Act on mouse release, like a normal button click.
    tab:SetAttribute("useOnKeyDown", false)
    tab:SetScript("PostClick", function()
        SelectTab(id)
    end)
    return tab
end

--- Makes the Buy, Sell, Market and Settings tabs and shows the Buy tab.
-- Market and Settings are plain tabs: not linked to Blizzard's window, they press nothing there.
local function BuildTabs()
    local buyTab = BuildTab(C.BUY_TAB, "Buy")
    buyTab:SetPoint("TOPLEFT", ui.frame, "BOTTOMLEFT", 12, 2)
    local sellTab = BuildTab(SELL_TAB, "Sell")
    --- One of our own tabs: plain, not linked to Blizzard's window.
    -- @param id the tab's id
    -- @param label the tab's text
    -- @return the tab button
    local function PlainTab(id, label)
        local tab = CreateFrame("Button", "HouseLedgerFrameTab" .. id, ui.frame, "PanelTabButtonTemplate")
        tab:SetID(id)
        tab:SetText(label)
        tab:SetScript("OnClick", function()
            SelectTab(id)
        end)
        return tab
    end
    local marketTab = PlainTab(C.MARKET_TAB, "Market")
    local settingsTab = PlainTab(SETTINGS_TAB, "Settings")
    ui.frame.Tabs = { buyTab, sellTab, marketTab, settingsTab }
    if type(PanelTemplates_TabResize) == "function" then
        for _, tab in ipairs(ui.frame.Tabs) do
            PanelTemplates_TabResize(tab, 0)
        end
    end
    -- Also anchors each tab to the right of the one before.
    PanelTemplates_SetNumTabs(ui.frame, #ui.frame.Tabs)
    SelectTab(C.BUY_TAB)
end

--- Makes the HouseLedger window, hidden until the auction house opens.
-- Its OnUpdate times out a scan that got no answer and refreshes the idle
-- scan line once a second.
function Window.Build()
    -- Blizzard's panel template: the same frame, title bar, close button
    -- and solid background as the auction house beside it.
    ui.frame = CreateFrame("Frame", "HouseLedgerFrame", UIParent, "ButtonFrameTemplate")
    ui.frame:SetSize(C.FRAME_WIDTH_MIN, C.HOUSE_HEIGHT)
    -- Fallback spot. PlaceFrame moves it beside the auction house.
    ui.frame:SetPoint("CENTER")
    -- On a narrow screen the spot beside the house runs off the edge;
    -- the clamp slides it back on screen.
    ui.frame:SetClampedToScreen(true)
    -- Blizzard's auction house is toplevel too, so a click on either
    -- window brings that one to the front.
    ui.frame:SetToplevel(true)
    -- A drag lasts until the house closes. PlaceFrame sets the spot on
    -- every open, so the game's saved-position cache is not used.
    ui.frame:SetDontSavePosition(true)
    if type(ui.frame.SetTitle) == "function" then
        ui.frame:SetTitle("HouseLedger")
    end
    if type(ui.frame.SetPortraitToAsset) == "function" then
        ui.frame:SetPortraitToAsset(C.PORTRAIT_ICON)
    end
    ui.frame:SetMovable(true)
    ui.frame:EnableMouse(true)
    ui.frame:RegisterForDrag("LeftButton")
    ui.frame:SetScript("OnDragStart", function(self)
        -- The window is protected; the game blocks moving it in combat.
        if not U.InCombat() then
            self:StartMoving()
        end
    end)
    ui.frame:SetScript("OnDragStop", function(self)
        if U.InCombat() then
            -- OnCombatEnded stops the move and puts the window back.
            state.afterCombat = true
        else
            self:StopMovingOrSizing()
        end
    end)
    ui.frame:Hide()

    ui.scanButton = CreateFrame("Button", nil, ui.frame, "UIPanelButtonTemplate")
    ui.scanButton:SetSize(80, 22)
    ui.scanButton:SetPoint("TOPRIGHT", -10, -30)
    ui.scanButton:SetText("Scan")
    ui.scanButton:SetScript("OnClick", Scan.Start)

    ui.buyPanel = CreateFrame("Frame", nil, ui.frame)
    ui.buyPanel:SetAllPoints(ui.frame)
    ui.frame.buyPanel = ui.buyPanel

    local button = CreateFrame("Button", nil, ui.buyPanel, "UIPanelButtonTemplate")
    button:SetSize(90, 22)
    button:SetPoint("RIGHT", ui.scanButton, "LEFT", -8, 0)
    button:SetText("Search")
    button:SetScript("OnClick", Buy.SendSearch)
    ui.buyPanel.searchButton = button

    local clear = CreateFrame("Button", nil, ui.buyPanel, "UIPanelButtonTemplate")
    clear:SetSize(70, 22)
    clear:SetPoint("RIGHT", button, "LEFT", -6, 0)
    clear:SetText("Clear")
    clear:SetScript("OnClick", Buy.ClearSearch)

    ui.searchBox = CreateFrame("EditBox", nil, ui.buyPanel, "InputBoxTemplate")
    ui.searchBox:SetHeight(20)
    -- Left of 70 clears the round portrait in the corner.
    ui.searchBox:SetPoint("LEFT", ui.frame, "TOPLEFT", 72, -41)
    ui.searchBox:SetPoint("RIGHT", clear, "LEFT", -10, 0)
    ui.searchBox:SetAutoFocus(false)
    ui.searchBox:SetScript("OnEnterPressed", function(box)
        Buy.SendSearch()
        box:ClearFocus()
    end)
    ui.buyPanel.searchControls = { ui.searchBox, clear, button }

    -- The Market tab's view dropdown, in the search box's place: [Deals v] at last scan (12 min ago).
    -- The same Blizzard dropdown as the quality filter.
    local marketDropdown = CreateFrame("DropdownButton", nil, ui.buyPanel, "WowStyle1DropdownTemplate")
    marketDropdown:SetWidth(150)
    marketDropdown:SetPoint("LEFT", ui.frame, "TOPLEFT", 72, -41)
    marketDropdown:SetupMenu(function(_, root)
        for index, view in ipairs(C.MARKET_VIEWS) do
            root:CreateRadio(view.title, function(picked)
                return state.marketView == picked
            end, function(picked)
                Buy.SetMarketView(picked)
            end, index)
        end
    end)
    local marketLabel = U.Cell(ui.buyPanel, "GameFontNormal", "LEFT")
    marketLabel:SetPoint("LEFT", marketDropdown, "RIGHT", 10, 0)
    marketLabel:SetPoint("RIGHT", ui.scanButton, "LEFT", -8, 0)
    ui.buyPanel.marketDropdown, ui.buyPanel.marketLabel = marketDropdown, marketLabel
    ui.buyPanel.marketControls = { marketDropdown, marketLabel }
    for _, control in ipairs(ui.buyPanel.marketControls) do
        control:Hide()
    end

    local inset = ui.frame.Inset
    if type(inset) == "table" then
        inset:ClearAllPoints()
        inset:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", 4, -C.LIST_TOP)
        inset:SetPoint("BOTTOMRIGHT", ui.frame, "BOTTOMRIGHT", -6, C.LIST_BOTTOM)
    end

    local list = CreateFrame("Frame", nil, ui.buyPanel)
    list:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", 8, -C.LIST_TOP - 2 - C.FILTER_HEIGHT)
    list:SetPoint("BOTTOMRIGHT", ui.frame, "BOTTOMRIGHT", -10, C.LIST_BOTTOM + 2)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        Buy.Scroll(-delta * C.WHEEL_STEP)
    end)
    Buy.BuildHeader(list)
    ui.buyPanel.priceHeading = ui.header.priceText
    ui.buyPanel.headerTexts, ui.buyPanel.sortButtons = ui.header.texts, ui.header.sortButtons
    Buy.BuildFilterRow()

    -- A large message in the middle of the list while it is empty.
    local listMessage = U.Cell(ui.buyPanel, "GameFontNormalLarge", "CENTER")
    listMessage:SetPoint("LEFT", list, "LEFT", 30, 0)
    listMessage:SetPoint("RIGHT", list, "RIGHT", -30, 0)
    listMessage:SetWordWrap(true)
    listMessage:SetText(C.BUY_START)
    ui.buyPanel.listMessage = listMessage
    for index = 1, C.VISIBLE_ROWS do
        ui.rows[index] = Buy.BuildRow(list, index)
    end
    -- The price chart sits right of the details lines, above the status lines.
    ui.buyPanel.chart = Chart.Build(ui.buyPanel, C.CHART_WIDTH, CHART_HEIGHT)
    ui.buyPanel.chart:SetPoint("BOTTOMRIGHT", ui.frame, "BOTTOMRIGHT", -16, C.STATUS_HEIGHT + 4)
    -- The house overview's chart takes the same spot while no row is picked.
    ui.buyPanel.overviewChart = Chart.BuildOverview(ui.buyPanel, C.CHART_WIDTH, CHART_HEIGHT)
    ui.buyPanel.overviewChart:SetPoint("BOTTOMRIGHT", ui.frame, "BOTTOMRIGHT", -16, C.STATUS_HEIGHT + 4)
    Buy.LayoutColumns(C.FRAME_WIDTH_MIN)

    ui.statusText = ui.buyPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.statusText:SetPoint("BOTTOMLEFT", 14, 30)
    ui.statusText:SetPoint("RIGHT", ui.frame, "RIGHT", -14, 0)
    ui.statusText:SetJustifyH("LEFT")
    ui.statusText:SetWordWrap(false)
    ui.statusText:SetText(C.BUY_HELP)
    ui.buyPanel.statusText = ui.statusText

    -- The details block, between the list and the status lines.
    ui.buyPanel.detailTitle = U.Cell(ui.buyPanel, "GameFontNormal", "LEFT")
    ui.buyPanel.detailTitle:SetPoint("TOPLEFT", ui.frame, "BOTTOMLEFT", 16, C.LIST_BOTTOM - 6)
    ui.buyPanel.detailTitle:SetPoint("RIGHT", ui.frame, "RIGHT", -16, 0)
    ui.buyPanel.detailLines = {}
    for index = 1, C.DETAIL_LINES do
        local y = C.LIST_BOTTOM - 6 - index * C.DETAIL_LINE_HEIGHT
        local left = U.Cell(ui.buyPanel, "GameFontHighlightSmall", "LEFT")
        left:SetPoint("TOPLEFT", ui.frame, "BOTTOMLEFT", 24, y)
        left:SetWidth(150)
        local right = U.Cell(ui.buyPanel, "GameFontHighlightSmall", "LEFT")
        right:SetPoint("TOPLEFT", ui.frame, "BOTTOMLEFT", 180, y)
        right:SetPoint("RIGHT", ui.frame, "RIGHT", -16, 0)
        ui.buyPanel.detailLines[index] = { left = left, right = right }
    end
    Buy.ClearDetails()

    Sell.BuildPanel()
    Settings.BuildPanel()
    BuildTabs()
    Purchase.Build()

    ui.scanText = ui.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.scanText:SetPoint("BOTTOMLEFT", 14, 8)
    ui.scanText:SetPoint("RIGHT", ui.frame, "RIGHT", -14, 0)
    ui.scanText:SetJustifyH("LEFT")
    ui.scanText:SetWordWrap(false)
    ui.scanText:SetText("")

    -- A thin gold bar in the gap above the scan line, while a scan's listings are read.
    ui.scanBar = CreateFrame("StatusBar", nil, ui.frame)
    ui.scanBar:SetHeight(4)
    ui.scanBar:SetPoint("BOTTOMLEFT", ui.scanText, "TOPLEFT", 0, 3)
    ui.scanBar:SetPoint("RIGHT", ui.frame, "RIGHT", -14, 0)
    ui.scanBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    ui.scanBar:SetStatusBarColor(1, 0.82, 0)
    ui.scanBar:Hide()
    ui.frame.scanBar = ui.scanBar

    local tick = 0
    ui.frame:SetScript("OnUpdate", function(_, elapsed)
        if state.scanState == "waiting" and (U.Clock() - state.waitStarted) >= C.ANSWER_WAIT then
            -- The request may already count. Do not send another one.
            HouseLedgerDB.replicateAt = time()
            state.acceptAnswerUntil = time() + C.ANSWER_WAIT
            Scan.StopReading()
            Scan.SetStatus("No answer yet. Next scan in 15 min.", 8)
            return
        end
        tick = tick + elapsed
        if tick < 1 then
            return
        end
        tick = 0
        Purchase.Tick()
        Scan.RefreshIdleLine()
        Scan.RefreshButton()
        if state.currentTab == C.MARKET_TAB and ui.buyPanel.marketMode then
            ui.buyPanel.marketLabel:SetText(Buy.MarketLabel())
        end
    end)

    Scan.RefreshIdleLine()
    Scan.RefreshButton()
end

--- The item Blizzard's Sell window holds now, or nil.
-- Reads only.
-- @return the item location from the commodity or item Sell frame, or nil
local function BlizzardSellItem()
    local commodities = AuctionHouseFrame.CommoditiesSellFrame
    local items = AuctionHouseFrame.ItemSellFrame
    return (commodities and commodities:GetItem()) or (items and items:GetItem())
end

-- Following Blizzard's auction window. HouseLedger never calls a method
-- on that window or changes it: addon code that switched its tab once
-- left every auction house search spinning until the game restarted.
-- hooksecurefunc runs these after Blizzard's own code has finished,
-- without touching it.

--- Blizzard's window was asked to switch tabs: show the matching tab here.
-- The mode asked for is not trusted: Blizzard swaps some, skips a switch
-- to the tab already shown, and another addon may pass its own table.
-- So the mode Blizzard's window shows now is read instead.
-- @param _ Blizzard's AuctionHouseFrame, unused
-- @param asked the AuctionHouseFrameDisplayMode Blizzard was asked for
local function FollowDisplayMode(_, asked)
    local modes = AuctionHouseFrameDisplayMode
    if ui.frame == nil or modes == nil then
        return
    end
    local mode = asked
    if type(AuctionHouseFrame.GetDisplayMode) == "function" then
        mode = AuctionHouseFrame:GetDisplayMode()
    end
    if mode == modes.ItemSell or mode == modes.CommoditiesSell or mode == modes.WoWTokenSell then
        SelectTab(SELL_TAB)
    elseif mode == modes.Buy or mode == modes.ItemBuy or mode == modes.CommoditiesBuy
        or mode == modes.WoWTokenBuy then
        SelectTab(C.BUY_TAB)
    end
end

--- Blizzard's Sell window took an item: show it on our Sell tab.
-- The item was dropped on it, or right-clicked from a bag, and Blizzard has
-- sent its own search for it. This shows the item here, and the results
-- events fill in its prices. Nothing is sent.
-- @param _ Blizzard's AuctionHouseFrame, unused
-- @param location the ItemLocation Blizzard was given
local function FollowPostItem(_, location)
    if ui.frame == nil or location == nil then
        return
    end
    -- The hook runs even when Blizzard turned the item away (its
    -- multi-sell bar was up), so check what its Sell window really holds.
    if BlizzardSellItem() ~= location then
        return
    end
    if type(location.IsValid) == "function" and not location:IsValid() then
        return
    end
    -- Blizzard turns these away without a search, so there is nothing to show.
    if not C_AuctionHouse.IsSellItemValid(location, false) then
        return
    end
    local status = C_AuctionHouse.GetItemCommodityStatus(location)
    local commodity = status == Enum.ItemCommodityStatus.Commodity
    if not commodity and status ~= Enum.ItemCommodityStatus.Item then
        return
    end
    local itemKey = C_AuctionHouse.GetItemKeyFromItem(location)
    if itemKey == nil then
        return
    end
    -- A WoW Token goes to Blizzard's token frame, which sends no item search.
    local tokens = C_WowTokenPublic
    if tokens and tokens.IsAuctionableWowToken and tokens.IsAuctionableWowToken(itemKey.itemID) then
        return
    end
    -- Read with the key Blizzard searched with: the any-variant key only
    -- when the house says equipment (AuctionHouseUtil.ConvertItemSellItemKey).
    local readKey = itemKey
    if not commodity then
        local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
        if info ~= nil and info.isEquipment == true then
            readKey = U.AnyVariantKey(itemKey)
        end
    end
    local name = C_Item.GetItemName(location) or "This item"
    Sell.StartPendingSell(readKey, name, C_Item.GetItemIcon(location), commodity, true)
    SelectTab(SELL_TAB)
    Sell.SetStatus("Reading the auction house's prices for " .. name .. "...")
    -- Blizzard's answer may already be in; if not, its results event shows it.
    if commodity then
        if (C_AuctionHouse.GetNumCommoditySearchResults(readKey.itemID) or 0) > 0 then
            Sell.OnCommodityResults(readKey.itemID)
        end
    elseif (C_AuctionHouse.GetNumItemSearchResults(readKey) or 0) > 0 then
        Sell.OnItemResults(readKey)
    end
end

--- Starts following Blizzard's auction window, once it exists.
local function HookHouse()
    if houseHooked or AuctionHouseFrame == nil or type(hooksecurefunc) ~= "function" then
        return
    end
    if type(AuctionHouseFrame.SetPostItem) ~= "function" or type(AuctionHouseFrame.SetDisplayMode) ~= "function" then
        return
    end
    hooksecurefunc(AuctionHouseFrame, "SetDisplayMode", FollowDisplayMode)
    hooksecurefunc(AuctionHouseFrame, "SetPostItem", FollowPostItem)
    houseHooked = true
end

--- Points our tabs' secure click at Blizzard's Buy and Sell tabs.
-- Only an attribute on our own buttons is set; the game's secure code does
-- the pressing. Waits out combat, and skips a client without the tabs.
local function LinkTabs()
    if tabsLinked or ui.frame == nil or AuctionHouseFrame == nil or U.InCombat() then
        return
    end
    local blizzardBuy = AuctionHouseFrame.BuyTab
    local blizzardSell = AuctionHouseFrame.SellTab
    if blizzardBuy == nil or blizzardSell == nil then
        return
    end
    ui.frame.Tabs[C.BUY_TAB]:SetAttribute("clickbutton", blizzardBuy)
    ui.frame.Tabs[SELL_TAB]:SetAttribute("clickbutton", blizzardSell)
    tabsLinked = true
end

--- Puts HouseLedger beside Blizzard's auction house window, not over it.
-- Blizzard loads that window on its own interaction event, so it may
-- not exist yet when AUCTION_HOUSE_SHOW reaches this addon. In that
-- case the frame keeps its current spot and tries once more next frame.
-- @param isRetry true on the one follow-up attempt, so it never loops
function Window.PlaceFrame(isRetry)
    if ui.frame == nil then
        return
    end
    if AuctionHouseFrame == nil then
        if not isRetry then
            C_Timer.After(0, function()
                Window.PlaceFrame(true)
            end)
        end
        return
    end
    HookHouse()
    if U.InCombat() then
        state.afterCombat = true
        return
    end
    LinkTabs()
    ui.frame:ClearAllPoints()
    -- Top and bottom on the house's right edge: beside it, same height.
    ui.frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", C.PIN_GAP, 0)
    ui.frame:SetPoint("BOTTOMLEFT", AuctionHouseFrame, "BOTTOMRIGHT", C.PIN_GAP, 0)
    local width = U.FrameWidth()
    ui.frame:SetWidth(width)
    Buy.LayoutColumns(width)
end

--- Combat ended: catch up on the window changes the game blocked.
function Window.OnCombatEnded()
    if state.bagButtonsPending and ui.priceCheck then
        state.bagButtonsPending = false
        PC.MakeBagButtons()
    end
    if ui.frame and state.scanState == "idle" then
        -- Catch up on what combat held back, if the game counted these as protected.
        Scan.RefreshButton()
        Scan.ShowProgress(nil)
    end
    if state.buildAfterCombat then
        state.buildAfterCombat = false
        Window.Build()
        Tooltip.NoteUnavailable()
        state.afterCombat = true
    end
    if ui.frame == nil or not state.afterCombat then
        return
    end
    state.afterCombat = false
    ui.frame:StopMovingOrSizing()
    if U.HouseIsOpen() then
        Window.PlaceFrame(false)
        ui.frame:Show()
        ui.frame:Raise()
        Scan.RefreshIdleLine()
        Buy.RefreshOverview()
    else
        ui.frame:Hide()
    end
    SelectTab(state.currentTab)
end
