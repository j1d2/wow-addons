--[[
The Sell tab: an item dropped on the slot (or put in Blizzard's Sell window) sends one search,
and the lowest price, quantity and saved history show. Nothing is saved or posted.
]]

local _, ns = ...
local C, ui, Price, U, Chart, Sell = ns.C, ns.ui, ns.Price, ns.U, ns.Chart, ns.Sell

-- The Sell tab's chart, under its lines.
local SELL_CHART_WIDTH = 260
local SELL_CHART_HEIGHT = 70
local SELL_SORT = {
    { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
}

-- Sell panel lines, top to bottom: key and label.
local SELL_LINES = {
    { "low", "Lowest now" },
    { "atLow", "Up at that price" },
    { "total", "Up in all" },
    -- Labels of these five are filled from PriceLedger.WindowLines.
    { "w1", "1 day" },
    { "w3", "3 days" },
    { "w7", "7 days" },
    { "w14", "14 days" },
    { "spread", "Std dev, earlier scans" },
    { "based", "Based on" },
    { "trend", "Trend vs 7-day avg" },
    { "typical", "Typical (7-day avg)" },
}
local SELL_LINE_HEIGHT = 20

-- The Sell lines filled in order from PriceLedger.WindowLines.
local WINDOW_KEYS = { "w1", "w3", "w7", "w14", "spread" }
local SELL_PROMPT = "Drop an item from your bags here"
local SELL_HELP = "Drop an item from your bags. One drop sends one search. Nothing is saved."
local EMPTY_SLOT_TEXTURE = "Interface\\Buttons\\UI-EmptySlot"

-- The item on the Sell tab (dropped here, or put in Blizzard's Sell
-- window), until the next one. Never saved.
local pendingSell

--- Sets the Sell tab's status line, once the panel is built.
-- @param text the line's text
function Sell.SetStatus(text)
    if ui.sellPanel then
        ui.sellPanel.statusText:SetText(text)
    end
end

--- Resets the Sell tab's labels and values to "-" and empties its hint.
local function ClearSellValues()
    for _, line in ipairs(SELL_LINES) do
        ui.sellPanel.labels[line[1]]:SetText(line[2])
        ui.sellPanel.values[line[1]]:SetText("-")
    end
    ui.sellPanel.hint:SetText("")
    ui.sellPanel.chart:Hide()
end

--- Shows the live listings for the Sell item next to its saved stats.
-- Colors are the seller's view: a higher price is good news.
-- @param summary from PriceLedger.LowestListing, or nil for none listed
-- @param complete false when the house sent only the first part of a long list
local function ShowSellResults(summary, complete)
    local values = ui.sellPanel.values
    ClearSellValues()
    local stats = U.SavedStats(pendingSell.itemID)
    if stats then
        local lines = Price.WindowLines(stats, U.CopperToText) or {}
        for index, key in ipairs(WINDOW_KEYS) do
            if lines[index] then
                ui.sellPanel.labels[key]:SetText(lines[index].left)
                values[key]:SetText(lines[index].right)
            end
        end
        values.based:SetText(Price.CountText(stats))
        values.typical:SetText(stats.typical and U.CopperToText(stats.typical) or "-")
        Chart.Show(ui.sellPanel.chart, Price.Lookup(HouseLedgerDB, pendingSell.itemID, U.ViewHouseKey()))
    else
        values.based:SetText("No saved prices yet")
    end
    if summary == nil then
        ui.sellPanel.hint:SetText(Price.SellAdvice(nil, false))
        Sell.SetStatus("No one is selling " .. pendingSell.name .. " right now.")
        return
    end
    values.low:SetText(U.CopperToText(summary.low))
    values.atLow:SetText(tostring(summary.atLow))
    values.total:SetText(Price.ListingText(summary))
    local verdict = Price.Judge(stats, summary.low)
    local trend = Price.TrendText(verdict, "seller")
    if trend == "" then
        trend = Price.SteadyText(verdict)
    end
    values.trend:SetText(trend ~= "" and trend or "-")
    ui.sellPanel.hint:SetText(Price.SellAdvice(verdict, true))
    local text = "Lowest of " .. Price.ListingText(summary) .. " for " .. pendingSell.name .. "."
    if complete == false then
        -- Asking for the rest would be another query; leave that to a new drop.
        text = text .. " The house has more; these are the first ones."
    end
    Sell.SetStatus(text)
end

--- Commodity search results came in: shows them if they are for the Sell item.
-- @param itemID the item the results are for
function Sell.OnCommodityResults(itemID)
    if pendingSell == nil or not pendingSell.commodity or itemID ~= pendingSell.itemID then
        return
    end
    local listings = {}
    for index = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0 do
        -- Only price and quantity are read; owners stay in the result.
        local result = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, index)
        if result then
            listings[#listings + 1] = { result.unitPrice, result.quantity }
        end
    end
    ShowSellResults(Price.LowestListing(listings),
        U.IsComplete(C_AuctionHouse.HasFullCommoditySearchResults, itemID))
end

--- Item search results came in: shows them if they are for the Sell item.
-- @param itemKey the item key the results are for
function Sell.OnItemResults(itemKey)
    if pendingSell == nil or pendingSell.commodity then
        return
    end
    if type(itemKey) ~= "table" or itemKey.itemID ~= pendingSell.itemID then
        return
    end
    -- Our own search: read with the key that was sent; for gear it covers
    -- every variant. A followed item: Blizzard may search again on its
    -- own (after a post) with another key, so read with the key these
    -- results came back for.
    local searchKey = pendingSell.followed and itemKey or pendingSell.itemKey
    local listings = {}
    for index = 1, C_AuctionHouse.GetNumItemSearchResults(searchKey) or 0 do
        local result = C_AuctionHouse.GetItemSearchResultInfo(searchKey, index)
        -- A listing with no buyout is bid-only and is left out.
        if result and result.buyoutAmount and result.quantity and result.quantity > 0 then
            listings[#listings + 1] = {
                Price.UnitCopper(result.buyoutAmount, result.quantity),
                result.quantity,
            }
        end
    end
    ShowSellResults(Price.LowestListing(listings),
        U.IsComplete(C_AuctionHouse.HasFullItemSearchResults, searchKey))
end

--- Puts an item on the Sell tab with empty values until its prices come in.
-- @param readKey the key its item search results are read with
-- @param name the item name to show
-- @param icon the icon to show
-- @param commodity true for a stackable item (commodity results)
-- @param followed true when the item came from Blizzard's Sell window
function Sell.StartPendingSell(readKey, name, icon, commodity, followed)
    pendingSell = {
        itemID = readKey.itemID, itemKey = readKey, name = name,
        commodity = commodity, followed = followed == true,
    }
    ui.sellPanel.itemName:SetText(name)
    ui.sellPanel.icon:SetTexture(icon)
    ClearSellValues()
end

--- An item dropped on the Sell slot: one drop, one search for that item.
-- The item goes straight back to its bag slot; only its id is read.
local function DropItem()
    local location = C_Cursor and C_Cursor.GetCursorItem and C_Cursor.GetCursorItem()
    if location == nil then
        return
    end
    local name = C_Item.GetItemName(location) or "This item"
    local icon = C_Item.GetItemIcon(location)
    local sellable = C_AuctionHouse.IsSellItemValid(location, false)
    local itemKey = sellable and C_AuctionHouse.GetItemKeyFromItem(location)
    local status = sellable and C_AuctionHouse.GetItemCommodityStatus(location)
    local commodity = status == Enum.ItemCommodityStatus.Commodity
    ClearCursor()

    if not U.HouseIsOpen() then
        Sell.SetStatus("Open the auction house first.")
        return
    end
    if not sellable then
        Sell.SetStatus(name .. " can't be sold at the auction house.")
        return
    end
    if status == Enum.ItemCommodityStatus.Unknown then
        -- Blizzard's Sell tab stops here too: without item data the right
        -- search is not known, and a wrong one would spend the throttle.
        Sell.SetStatus("The game is still loading " .. name .. ". Drop it again.")
        return
    end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        Sell.SetStatus("The auction house is still busy. Wait, then drop the item again.")
        return
    end

    -- Blizzard's own Sell tab searches the same way: stackable items by
    -- item; gear with item level and suffix set to 0, so every variant
    -- of it comes back in one list under that key.
    -- Once the house's item info is loaded, its isEquipment decides, as in
    -- Blizzard's Sell tab (a bag can be worn but is not equipment). On a
    -- first drop that info may not be loaded yet; then whether the item
    -- can be worn, known from the item itself, stands in for it.
    local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
    local gear
    if info ~= nil then
        gear = info.isEquipment == true
    else
        gear = type(C_Item.IsEquippableItem) == "function" and C_Item.IsEquippableItem(itemKey.itemID) == true
    end
    gear = gear and not commodity
    local searchKey = gear and U.AnyVariantKey(itemKey) or itemKey
    Sell.StartPendingSell(searchKey, name, icon, commodity)
    if gear then
        C_AuctionHouse.SendSellSearchQuery(searchKey, SELL_SORT, false)
    else
        C_AuctionHouse.SendSearchQuery(searchKey, SELL_SORT, false)
    end
    Sell.SetStatus("Searching for " .. name .. "...")
end

--- Reset on the Sell tab: empties the slot and its values.
-- Results that still arrive for that item are ignored. Blizzard's window is left as is.
local function ResetSell()
    pendingSell = nil
    ui.sellPanel.itemName:SetText(SELL_PROMPT)
    ui.sellPanel.icon:SetTexture(nil)
    ClearSellValues()
    Sell.SetStatus(SELL_HELP)
end

--- Makes the Sell tab: the item slot, the value lines, a status line and Reset.
function Sell.BuildPanel()
    ui.sellPanel = CreateFrame("Frame", nil, ui.frame)
    ui.sellPanel:SetAllPoints(ui.frame)
    ui.frame.sellPanel = ui.sellPanel

    local slot = CreateFrame("Button", nil, ui.sellPanel)
    slot:SetSize(37, 37)
    slot:SetPoint("TOPLEFT", ui.sellPanel, "TOPLEFT", 20, -C.LIST_TOP - 16)
    local slotBackground = slot:CreateTexture(nil, "BACKGROUND")
    slotBackground:SetTexture(EMPTY_SLOT_TEXTURE)
    slotBackground:SetSize(64, 64)
    slotBackground:SetPoint("CENTER", slot, "CENTER", 0, 0)
    ui.sellPanel.icon = slot:CreateTexture(nil, "ARTWORK")
    ui.sellPanel.icon:SetAllPoints(slot)
    -- Drag an item onto the slot, or pick it up and click the slot.
    slot:SetScript("OnReceiveDrag", DropItem)
    slot:SetScript("OnClick", DropItem)
    ui.sellPanel.slot = slot

    ui.sellPanel.itemName = U.Cell(ui.sellPanel, "GameFontNormalLarge", "LEFT")
    ui.sellPanel.itemName:SetPoint("LEFT", slot, "RIGHT", 12, 0)
    ui.sellPanel.itemName:SetPoint("RIGHT", ui.sellPanel, "RIGHT", -16, 0)
    ui.sellPanel.itemName:SetText(SELL_PROMPT)

    ui.sellPanel.values = {}
    ui.sellPanel.labels = {}
    for index, line in ipairs(SELL_LINES) do
        local y = -C.LIST_TOP - 72 - (index - 1) * SELL_LINE_HEIGHT
        local label = U.Cell(ui.sellPanel, "GameFontNormal", "LEFT")
        label:SetPoint("TOPLEFT", ui.sellPanel, "TOPLEFT", 24, y)
        label:SetWidth(150)
        label:SetText(line[2])
        ui.sellPanel.labels[line[1]] = label
        local value = U.Cell(ui.sellPanel, "GameFontHighlight", "LEFT")
        value:SetPoint("TOPLEFT", ui.sellPanel, "TOPLEFT", 180, y)
        value:SetPoint("RIGHT", ui.sellPanel, "RIGHT", -16, 0)
        ui.sellPanel.values[line[1]] = value
    end
    ui.sellPanel.chart = Chart.Build(ui.sellPanel, SELL_CHART_WIDTH, SELL_CHART_HEIGHT)
    ui.sellPanel.chart:SetPoint("TOPLEFT", ui.sellPanel, "TOPLEFT", 24,
        -C.LIST_TOP - 72 - #SELL_LINES * SELL_LINE_HEIGHT - 48)
    ui.sellPanel.hint = U.Cell(ui.sellPanel, "GameFontHighlight", "LEFT")
    ui.sellPanel.hint:SetPoint("TOPLEFT", ui.sellPanel, "TOPLEFT", 24, -C.LIST_TOP - 72 - #SELL_LINES * SELL_LINE_HEIGHT - 10)
    ui.sellPanel.hint:SetPoint("RIGHT", ui.sellPanel, "RIGHT", -16, 0)
    ClearSellValues()

    ui.sellPanel.statusText = U.Cell(ui.sellPanel, "GameFontHighlightSmall", "LEFT")
    ui.sellPanel.statusText:SetPoint("BOTTOMLEFT", 14, 30)
    ui.sellPanel.statusText:SetPoint("RIGHT", ui.sellPanel, "RIGHT", -14, 0)
    ui.sellPanel.statusText:SetText(SELL_HELP)

    local reset = CreateFrame("Button", nil, ui.sellPanel, "UIPanelButtonTemplate")
    reset:SetSize(80, 22)
    reset:SetPoint("RIGHT", ui.scanButton, "LEFT", -8, 0)
    reset:SetText("Reset")
    reset:SetScript("OnClick", ResetSell)
end
