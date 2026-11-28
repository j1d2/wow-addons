--[[
The Auctions tab: the player's own auctions, with how each compares to the last scan.

Read-only:
- A click on the tab at the auction house asks the house for this character's auctions once
  (C_AuctionHouse.QueryOwnedAuctions), only when its throttle is ready: the tab click is the one
  action. Showing the tab any other way (after combat, the house reopening) only redraws. Blizzard's own Auctions tab asks the same when it opens, and either answer
  (OWNED_AUCTIONS_UPDATED) is read here, so opening Blizzard's tab fills this one too.
- Each character's list is saved when read (only once the house's answer is complete), so the
  tab shows every character's auctions at this house. The other player's name in a bid is never
  read.
- Nothing here cancels, bids or searches.

The entries, their order, the comparison and the totals are pure (PriceLedger: OwnedEntries,
SaveOwned, OwnedView, OwnedVerdict, OwnedTotals); this file reads the game and draws the tab.
]]

local _, ns = ...
local C, ui, state, Price, U, Scan, History, Auctions = ns.C, ns.ui, ns.state, ns.Price, ns.U, ns.Scan, ns.History,
    ns.Auctions

-- The list's top (under the dropdown) and how many rows fit above the totals, like History.
local LIST_TOP = C.LIST_TOP + C.FILTER_HEIGHT + 4
local ROWS = math.floor((C.HOUSE_HEIGHT - History.INSET_BOTTOM - 2 - LIST_TOP - C.ROW_HEIGHT) / C.ROW_HEIGHT)
-- Below this window width the Who column hides (the hover still says whose).
local WHO_MIN_WIDTH = 540
local COLUMNS = {
    { key = "who", label = "Who" },
    { key = "name", label = "Item" },
    { key = "count", label = "Qty" },
    { key = "each", label = "Each" },
    { key = "market", label = "Last scan" },
    { key = "left", label = "Left" },
}
-- Space between two columns, and the Who column's width.
local COLUMN_GAP, WHO_WIDTH = 12, 80
local GREEN, RED, GREY, ORANGE = { 0.4, 1, 0.4 }, { 1, 0.45, 0.45 }, { 0.62, 0.62, 0.62 }, { 1, 0.6, 0.15 }
local EMPTY_TEXT = "No auctions read yet. Open this tab at the auction house (or Blizzard's Auctions tab) "
    .. "to read this character's auctions."

local panel
local view = {}
local offset = 0
local filter = { who = nil }

--- What the game's item key data says about an auction's item: whether it's a stackable (a key
-- it hasn't loaded yet counts as one when the auction holds more than one), and its name and
-- quality (a stackable's auction has no link), else the last scan's.
-- @param auction one of the game's owned auctions
-- @return whether it's a stackable, its name (or nil) and its quality (or nil)
local function Describe(auction)
    local info = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(auction.itemKey)
    local commodity = (auction.quantity or 1) > 1
    local name, quality
    if type(info) == "table" then
        if info.isCommodity ~= nil then
            commodity = info.isCommodity == true
        end
        name, quality = info.itemName, info.quality
    end
    local house = (HouseLedgerDB.houses or {})[U.ViewHouseKey()]
    local saved = house and house.items and house.items[auction.itemKey.itemID]
    if (name == nil or name == "") and saved then
        name, quality = saved.name, quality or saved.quality
    end
    return commodity, name ~= "" and name or nil, quality
end

--- An auction's name, icon and color: the saved name and quality first (U.ItemLook, as the Buy
-- list does), else the game's item data, else the last scan's.
-- @param entry a row from PriceLedger.OwnedView
-- @return the name, the icon, and r, g, b
local function Look(entry)
    local house = (HouseLedgerDB.houses or {})[U.ViewHouseKey()]
    local saved = house and house.items and house.items[entry.itemID]
    local name, icon, quality = U.ItemLook(C_AuctionHouse.MakeItemKey(entry.itemID), {
        savedName = entry.name or (saved and saved.name), savedQuality = entry.quality or (saved and saved.quality) })
    local r, g, b = 1, 1, 1
    if Price.IsQuality(quality) and C_Item and type(C_Item.GetItemQualityColor) == "function" then
        r, g, b = C_Item.GetItemQualityColor(quality)
    end
    return name, icon, r, g, b
end

--- Time left as "2h 10m", "35m" or "under 1m".
-- @param seconds seconds left
-- @return the text
local function LeftText(seconds)
    local hours, minutes = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
    if hours > 0 then
        return string.format("%dh %dm", hours, minutes)
    elseif minutes > 0 then
        return string.format("%dm", minutes)
    end
    return "under 1m"
end

--- The Left cell: time left (orange when it ends soon), or Sold, or Ended.
-- @param row a row from PriceLedger.OwnedView
-- @return the text and its color
local function LeftCell(row)
    if row.sold then
        return "Sold", GREEN
    elseif row.ended then
        return "Ended", GREY
    elseif row.left == nil then
        return "-", GREY
    end
    return LeftText(row.left), row.left < Price.OWNED_SOON and ORANGE or { 1, 1, 1 }
end

--- The Last scan cell: cheapest, how far under it someone was, or not seen.
-- @param verdict from PriceLedger.OwnedVerdict, or nil
-- @return the text and its color
local function MarketCell(verdict)
    if verdict == nil then
        return "", GREY
    elseif verdict.unknown then
        return "not seen", GREY
    elseif verdict.undercut then
        return U.CopperToText(verdict.undercut) .. " under", RED
    end
    return "cheapest", GREEN
end

--- The item's saved row and stats at the house the window reads.
-- @param itemID the item
-- @return the saved row (or nil) and its stats (or nil)
local function Saved(itemID)
    local house = (HouseLedgerDB.houses or {})[U.ViewHouseKey()]
    local saved = house and house.items and house.items[itemID]
    return saved, U.SavedStats(itemID)
end

--- Places the columns for the window's width: Who (first) hides on a narrow window.
-- @param row a row
-- @param showWho true to show the Who column
local function LayOut(row, showWho)
    local cells = row.cells
    for _, cell in pairs(cells) do
        cell:ClearAllPoints()
    end
    cells.who:SetShown(showWho)
    -- Who first, then the item (its icon, then its name), then the numbers from the right.
    local itemLeft = 4
    if showWho then
        cells.who:SetPoint("LEFT", row, "LEFT", 4, 0)
        cells.who:SetWidth(WHO_WIDTH)
        itemLeft = 4 + WHO_WIDTH + COLUMN_GAP
    end
    if row.icon then
        row.icon:ClearAllPoints()
        row.icon:SetPoint("LEFT", row, "LEFT", itemLeft, 0)
    end
    local right, point = row, "RIGHT"
    for _, column in ipairs({ { "left", 62 }, { "market", 84 }, { "each", 78 }, { "count", 30 } }) do
        local cell = cells[column[1]]
        cell:SetPoint("RIGHT", right, point, right == row and -4 or -COLUMN_GAP, 0)
        cell:SetWidth(column[2])
        right, point = cell, "LEFT"
    end
    -- The name starts after the icon's room on every row and the headings, so they line up.
    cells.name:SetPoint("LEFT", row, "LEFT", itemLeft + C.ICON_SIZE + 4, 0)
    cells.name:SetPoint("RIGHT", cells.count, "LEFT", -COLUMN_GAP, 0)
end

--- The totals line: what's up and its worth, and sold gold waiting in the mail.
-- @param totals from PriceLedger.OwnedTotals
-- @return the text
local function TotalsText(totals)
    local text = string.format("%d up for %s", totals.active, U.CopperToText(totals.value))
    if totals.afterCut then
        text = text .. string.format(" (%s after the house's cut)", U.CopperToText(totals.afterCut))
    end
    text = text .. "."
    if totals.sold > 0 then
        text = text .. string.format("\n%d sold: %s waiting in the mail.", totals.sold, U.CopperToText(totals.soldGold))
    end
    return text
end

--- Draws the tab from the saved auctions of the house the window reads.
function Auctions.Render()
    if panel == nil or not panel:IsShown() then
        return
    end
    local houseKey = U.ViewHouseKey()
    view = Price.OwnedView(HouseLedgerDB, houseKey, filter.who, time())
    offset = math.max(0, math.min(offset, #view - ROWS))
    U.SetScrollBar(panel.scrollBar, offset, ROWS, #view)
    local showWho = (ui.frame:GetWidth() or 0) >= WHO_MIN_WIDTH
    panel.headings.who:SetShown(showWho)
    LayOut(panel.header, showWho)
    for index, row in ipairs(panel.rows) do
        local entry = view[offset + index]
        row.entry = entry
        if entry then
            LayOut(row, showWho)
            local cells = row.cells
            local name, icon, r, g, b = Look(entry)
            row.icon:SetTexture(icon)
            cells.name:SetText(name)
            cells.name:SetTextColor(r, g, b)
            cells.count:SetText(tostring(entry.quantity))
            cells.each:SetText(entry.unit and U.CopperToText(entry.unit) or "bid only")
            local saved, stats = Saved(entry.itemID)
            local market, mc = MarketCell(Price.OwnedVerdict(entry, saved, stats))
            cells.market:SetText(market)
            cells.market:SetTextColor(mc[1], mc[2], mc[3])
            local left, lc = LeftCell(entry)
            cells.left:SetText(left)
            cells.left:SetTextColor(lc[1], lc[2], lc[3])
            cells.who:SetText(entry.who)
            row:Show()
        else
            row:Hide()
        end
    end
    panel.empty:SetShown(#view == 0)
    panel.empty:SetText(#Price.OwnedCharacters(HouseLedgerDB, houseKey) == 0 and EMPTY_TEXT
        or "No auctions for this choice.")
    panel.totals:SetText(#view > 0 and TotalsText(Price.OwnedTotals(view, Price.HouseCut(houseKey))) or "")
end

--- The house answered with this character's auctions (asked by this tab or by Blizzard's): saves
-- them for this character and redraws. Reads only; never the bidder's name.
function Auctions.OnOwnedUpdated()
    if state.openHouseKey == nil or type(C_AuctionHouse.GetOwnedAuctions) ~= "function" then
        return
    end
    -- A list still arriving would replace the saved one with part of it: wait for the full one.
    if not U.IsComplete(C_AuctionHouse.HasFullOwnedAuctionResults) then
        return
    end
    local soldStatus = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold or 1
    local entries = Price.OwnedEntries(C_AuctionHouse.GetOwnedAuctions(), time(), Describe, soldStatus)
    Price.SaveOwned(HouseLedgerDB, U.ViewHouseKey(), U.CharacterName(), entries, time())
    Auctions.Render()
end

--- A click on the tab: at the house, asks once for this character's auctions when the house's
-- throttle is ready (the click is the one action). Only the tab's own click calls this.
function Auctions.Ask()
    if state.openHouseKey == nil or type(C_AuctionHouse.QueryOwnedAuctions) ~= "function" then
        return
    end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        Scan.SetStatus("The house is busy. Showing your auctions as last read.", 8)
        return
    end
    local byTime = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.TimeRemaining or 5
    C_AuctionHouse.QueryOwnedAuctions({ { sortOrder = byTime, reverseSort = false } })
end

--- The hover lines: the item, whose auction it is and when it was read, and how it compares.
-- @param row the row
local function ShowEntryTooltip(row)
    local entry = row.entry
    if entry == nil then
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if entry.link then
        GameTooltip:SetHyperlink(entry.link)
    else
        GameTooltip:AddLine(entry.name or ("item " .. entry.itemID), 1, 1, 1)
    end
    if entry.unit then
        GameTooltip:AddLine(string.format("%s's, %d for %s (%s each). Read %s.", entry.who, entry.quantity,
            U.CopperToText(entry.total), U.CopperToText(entry.unit), Price.WhenText(entry.seenAt) or "before"),
            0.8, 0.8, 0.8, true)
    else
        GameTooltip:AddLine(string.format("%s's, %d, bids only. Read %s.", entry.who, entry.quantity,
            Price.WhenText(entry.seenAt) or "before"), 0.8, 0.8, 0.8, true)
    end
    local saved, stats = Saved(entry.itemID)
    local verdict = Price.OwnedVerdict(entry, saved, stats)
    if verdict and verdict.undercut then
        GameTooltip:AddLine(string.format("At the last scan the cheapest was %s, %s under yours%s.",
            U.CopperToText(saved.unit), U.CopperToText(verdict.undercut),
            entry.commodity and "" or " (any version of this item)"), RED[1], RED[2], RED[3], true)
    elseif verdict and verdict.cheapest then
        GameTooltip:AddLine("Yours was the cheapest (or as cheap) at the last scan.", GREEN[1], GREEN[2], GREEN[3])
    end
    if verdict and verdict.vsTypical then
        local percent = math.floor(math.abs(verdict.vsTypical) * 100 + 0.5)
        GameTooltip:AddLine(string.format("%d%% %s your 7-day average.", percent,
            verdict.vsTypical >= 0 and "over" or "under"), 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

--- Moves the list by whole rows, through what is already shown. Sends nothing.
-- @param rowsDown rows to move; negative moves up. Clamped to the list.
local function Scroll(rowsDown)
    local moved = math.max(0, math.min(offset + rowsDown, #view - ROWS))
    if moved ~= offset then
        offset = moved
        Auctions.Render()
    end
end

--- Makes a row: item, qty, each, last scan, time left and who, with the tooltip on hover.
-- @param parent the panel
-- @param y the row's top
-- @param header true for the headings row
-- @return the row
local function BuildRow(parent, y, header)
    local row = CreateFrame(header and "Frame" or "Button", nil, parent)
    row:SetHeight(C.ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    row:SetPoint("RIGHT", parent, "RIGHT", -16 - C.SCROLL_GUTTER, 0)
    row.cells = {}
    for _, column in ipairs(COLUMNS) do
        -- Numbers and the columns about them line up on the right; the item and who on the left.
        local right = column.key ~= "name" and column.key ~= "who"
        row.cells[column.key] = U.Cell(row, header and "GameFontNormalSmall" or "GameFontHighlightSmall",
            right and "RIGHT" or "LEFT")
    end
    if not header then
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(C.ICON_SIZE, C.ICON_SIZE)
        row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row:SetScript("OnEnter", ShowEntryTooltip)
        row:SetScript("OnLeave", U.HideRowTooltip)
        row.auctionRow = true
    end
    return row
end

--- Makes the Auctions tab: a character dropdown, the headings, the rows and the totals.
function Auctions.BuildPanel()
    panel = CreateFrame("Frame", nil, ui.frame)
    panel:SetAllPoints(ui.frame)
    panel:Hide()
    ui.frame.auctionsPanel, ui.auctionsPanel = panel, panel

    local whoDropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    whoDropdown:SetWidth(170)
    whoDropdown:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -C.LIST_TOP - 2)
    whoDropdown:SetupMenu(function(_, root)
        local choices = { false } -- false stands for all characters
        for _, name in ipairs(Price.OwnedCharacters(HouseLedgerDB, U.ViewHouseKey())) do
            choices[#choices + 1] = name
        end
        for _, choice in ipairs(choices) do
            root:CreateRadio(choice or "All characters", function(picked)
                return (filter.who or false) == picked
            end, function(picked)
                filter.who, offset = picked or nil, 0
                Auctions.Render()
            end, choice)
        end
    end)
    panel.whoDropdown = whoDropdown

    panel.header = BuildRow(panel, -LIST_TOP, true)
    panel.headings = {}
    for _, column in ipairs(COLUMNS) do
        local cell = panel.header.cells[column.key]
        cell:SetText(column.label)
        panel.headings[column.key] = cell
    end
    panel.rows = {}
    for index = 1, ROWS do
        panel.rows[index] = BuildRow(panel, -LIST_TOP - index * C.ROW_HEIGHT, false)
    end
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        Scroll(-delta * C.WHEEL_STEP)
    end)
    panel.scrollBar = U.ScrollBar(panel, Scroll)
    panel.scrollBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, -LIST_TOP - C.ROW_HEIGHT)
    panel.scrollBar:SetHeight(ROWS * C.ROW_HEIGHT)

    -- The same places as History's empty text and totals.
    panel.empty = U.Cell(panel, "GameFontHighlight", "LEFT")
    panel.empty:SetPoint("TOPLEFT", panel, "TOPLEFT", 22, -LIST_TOP - C.ROW_HEIGHT - 8)
    panel.empty:SetPoint("RIGHT", panel, "RIGHT", -22, 0)
    panel.empty:SetWordWrap(true)
    panel.totals = U.Cell(panel, "GameFontNormalSmall", "LEFT")
    panel.totals:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 20, C.STATUS_HEIGHT + 8)
    panel.totals:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
    panel.totals:SetWordWrap(true)
end
