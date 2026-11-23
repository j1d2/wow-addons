--[[
Buying, on the Buy and Market tabs. The picked row's Buy button sends one item search; the
list then shows that item's listings, cheapest first, and a bar in the filter row's place buys
from them (the picked listing gets its own Buy button too, which does what the bar's does):

- Stackable items: how many, then Buy asks the house for its price (a quote), then Confirm buys
  at that price.
- Gear: pick one listing, then Buy, then Confirm.

Every step is the player's own click, and nothing repeats or follows up on its own: no search
after a buy, no retry. Only buyouts are used; bids stay in Blizzard's window. Seller names are
never read. The player's own listings and bid-only ones are left out.

The game holds one commodity quote at a time, shared with Blizzard's buy window, so every answer
is checked against the buy started here (`buy`), and the quote is dropped
(CancelCommoditiesPurchase) whenever the listings close, as Blizzard's window does.
]]

local _, ns = ...
local C, ui, state, Price, U, Buy, Purchase = ns.C, ns.ui, ns.state, ns.Price, ns.U, ns.Buy, ns.Purchase

-- The sorts Blizzard's own buy window sends: stackables by price; gear by buyout, then bid, so the
-- first page of a big list holds the cheapest buyouts.
local COMMODITY_SORT = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
local GEAR_SORT = {
    { sortOrder = Enum.AuctionHouseSortOrder.Buyout, reverseSort = false },
    { sortOrder = Enum.AuctionHouseSortOrder.Bid, reverseSort = false },
}
-- Seconds to wait for the house's answer. A price that doesn't come is given up; a buy already
-- sent stays locked (a late answer may still buy), and only says it is still waiting.
local NO_ANSWER_WAIT = 10
-- The bar's widths, in the filter row's place.
local BACK_WIDTH, QTY_WIDTH, MAX_WIDTH, BUY_WIDTH = 60, 52, 44, 96
-- The Buy button on the picked row, at its right end (over the Trend cell).
local ROW_BUTTON_WIDTH, ROW_BUTTON_HEIGHT = 64, 16

-- The row picked on Buy or Market (a browse result or Market row), which Listings searches for.
local picked
-- The open listings, or nil: { itemID, readKey, name, commodity, rows (PriceLedger.BuyRows),
-- ownCount, complete, offset, waiting (no answer yet), chosen (a gear row's auctionID), picked
-- (the listing row clicked last, marked in gold) }.
local listing
-- A buy under way, or nil: { step, commodity, itemID, quantity, estimate, total, auctionID,
-- buyout, name, sentAt, late }. step is "quoting" (asked the house's price), "quoted" (Confirm
-- buys), "armed" (gear: Confirm buys) or "buying" (sent; locked until the answer, or until the
-- player opens the listings again after NO_ANSWER_WAIT, when late is true).
local buy

--- Sets the Buy panel's status line.
-- @param text the line's text
local function SetStatus(text)
    ui.statusText:SetText(text)
end

--- A count and a word, with an "s" unless the count is 1.
-- @param count a number
-- @param word the singular word
-- @return text like "1 listing" or "3 listings"
local function Counted(count, word)
    return count .. " " .. word .. (count == 1 and "" or "s")
end

--- True while the list shows an item's listings.
-- @return true when open
function Purchase.IsOpen()
    return listing ~= nil
end

--- The saved stats of the item the listings are for.
-- @return the stats, or nil
local function ListingStats()
    return listing and U.SavedStats(listing.itemID)
end

--- The status line for the listings: how many, what to do next, and what was left out.
-- @return the text
local function ListingStatus()
    if listing.waiting then
        return "Searching the listings for " .. listing.name .. "..."
    end
    local rows = listing.rows
    local text
    if #rows == 0 then
        text = listing.name .. ": nothing for sale with a buyout."
    elseif listing.commodity then
        text = string.format("%s: %s, %d for sale. Type how many, then click Buy.", listing.name,
            Counted(#rows, "listing"), rows[#rows].upTo)
    else
        text = string.format("%s: %s. Click one, then click Buy.", listing.name, Counted(#rows, "listing"))
    end
    if listing.ownCount > 0 then
        text = text .. " " .. listing.ownCount .. " of your own are left out."
    end
    if not listing.complete then
        text = text .. " The house has more; these are the first ones."
    end
    return text
end

--- How a listing reads in the status line: its link, or the item's name.
-- @param row a listing row
-- @return the text
local function ListingLabel(row)
    return row.link or listing.name
end

--- The gear row the player picked, or nil.
-- @return the row from listing.rows
local function ChosenRow()
    for _, row in ipairs(listing.rows) do
        if row.auctionID == listing.chosen then
            return row
        end
    end
end

--- How many the box asks for, and what that costs from the listings shown.
-- @return the number asked (0 when empty), and PriceLedger.FillCost's cost
local function AskedCost()
    local asked = tonumber(ui.buyPanel.qtyBox:GetText() or "") or 0
    return asked, Price.FillCost(listing.rows, asked)
end

--- Sets the Buy buttons' text and whether they can be clicked, from the buy step: the bar's,
-- and the one on the picked listing, which does the same.
-- @param ready true when a Buy click would start a buy (a number or listing picked, affordable)
local function ShowBuyButton(ready)
    local step = buy and buy.step
    local text, enabled = "Buy", ready
    if step == "quoting" then
        text, enabled = "Waiting...", false
    elseif step == "buying" then
        text, enabled = "Buying...", false
    elseif step == "quoted" or step == "armed" then
        text, enabled = "Confirm", true
    end
    for _, button in ipairs({ ui.buyPanel.buyButton, ui.buyPanel.rowBuyButton }) do
        button:SetText(text)
        if enabled then button:Enable() else button:Disable() end
    end
end

--- Works out what a Buy click would buy, says it in the status line, and sets the Buy button.
-- Reads the listings already here; sends nothing.
local function RefreshBuy()
    if listing == nil then
        return
    end
    if buy ~= nil or listing.waiting then
        ShowBuyButton(false)
        return
    end
    local ready = false
    local text = ListingStatus()
    local money = GetMoney()
    if listing.commodity then
        local asked, cost = AskedCost()
        if asked > 0 and cost.count > 0 then
            local each = math.floor(cost.total / cost.count + 0.5)
            text = string.format("%d for %s (%s each)", cost.count, U.CopperToText(cost.total), U.CopperToText(each))
            if cost.count < asked then
                text = "Only " .. cost.count .. " are up: " .. text
            end
            local warning = Price.BuyWarningText(ListingStats(), each)
            text = text .. (warning ~= "" and (", " .. warning) or "") .. "."
            ready = cost.total <= money
            if not ready then
                text = string.format("You have %s; %d cost %s.", U.CopperToText(money), cost.count,
                    U.CopperToText(cost.total))
            end
        end
    else
        local row = ChosenRow()
        if row then
            local warning = Price.BuyWarningText(ListingStats(), row.unit)
            text = string.format("%s for %s%s.", ListingLabel(row), U.CopperToText(row.buyout),
                warning ~= "" and (", " .. warning) or "")
            ready = row.buyout <= money
            if not ready then
                text = string.format("You have %s; this costs %s.", U.CopperToText(money), U.CopperToText(row.buyout))
            end
        end
    end
    SetStatus(text)
    ShowBuyButton(ready)
end

--- Draws the visible listings at the scroll offset, in the result rows.
function Purchase.Render()
    local _, icon = U.ItemLook(listing.readKey)
    local stats = ListingStats()
    for index = 1, C.VISIBLE_ROWS do
        local row = ui.rows[index]
        local entry = listing.rows[listing.offset + index]
        row.result, row.listing = nil, entry
        if entry then
            row.listingKey = listing.readKey
            row.icon:SetTexture(icon)
            row.nameText:SetText(entry.link or listing.name)
            row.nameText:SetTextColor(1, 1, 1)
            row.ilvlText:SetText(entry.level and entry.level > 0 and tostring(entry.level) or "")
            row.priceText:SetText(U.CopperToText(listing.commodity and entry.unit or entry.buyout))
            row.availText:SetText(tostring(entry.quantity))
            row.typicalText:SetText(listing.commodity and tostring(entry.upTo) or Price.TimeLeftText(entry.timeLeft))
            local verdict = Price.Judge(stats, entry.unit)
            local mark = Price.TrendText(verdict, "buyer")
            row.trendText:SetText(mark ~= "" and mark or Price.SteadyText(verdict))
            U.MarkRow(row, entry == listing.picked)
            row:Show()
        else
            row:Hide()
        end
    end
    Purchase.PlaceRowButtons()
    local message
    if listing.waiting then
        message = "Searching..."
    elseif #listing.rows == 0 then
        message = "None for sale with a buyout."
    end
    Buy.SetListMessage(message)
end

--- Mouse wheel over the listings.
-- @param rowsDown rows to move; negative moves up. Clamped to the list.
function Purchase.Scroll(rowsDown)
    local maxOffset = math.max(0, #listing.rows - C.VISIBLE_ROWS)
    local offset = math.min(maxOffset, math.max(0, listing.offset + rowsDown))
    if offset ~= listing.offset then
        listing.offset = offset
        Purchase.Render()
    end
end

--- Writes the column headings for the listings.
local function ListingHeader()
    local texts = ui.buyPanel.headerTexts
    texts.name:SetText(C.HEADER_LABELS.name)
    texts.ilvl:SetText(C.HEADER_LABELS.ilvl)
    texts.price:SetText(listing.commodity and "Each" or "Price")
    texts.avail:SetText(C.HEADER_LABELS.avail)
    texts.typical:SetText(listing.commodity and "Up to" or "Time left")
    texts.trend:SetText("vs avg")
end

--- The shown list row that passes a test, or nil (the picked row may be scrolled away).
-- @param test function(row) returning true for the one wanted
-- @return the row, or nil
local function ShownRow(test)
    for _, row in ipairs(ui.rows) do
        if row:IsShown() and test(row) then
            return row
        end
    end
end

--- Puts a button at the right end of a row, or hides it when there is no row. The row's last
-- column (trend or vs avg) sits under the button, so it is hidden there and shown again when the
-- button moves on.
-- @param button the button
-- @param row the row, or nil
local function PlaceOn(button, row)
    if button.covered then
        button.covered:SetAlpha(1)
        button.covered = nil
    end
    if row == nil then
        button:Hide()
        return
    end
    row.trendText:SetAlpha(0)
    button.covered = row.trendText
    -- A child of the row, so it draws over the row and its clicks reach it.
    button:SetParent(row)
    button:ClearAllPoints()
    button:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    button:Show()
end

--- Puts the Buy button on the picked row: on a search result or Market row it opens that item's
-- listings; on a picked listing it buys, like the bar's Buy. Hidden when that row isn't shown.
function Purchase.PlaceRowButtons()
    local panel = ui.buyPanel
    if panel == nil or panel.listingsButton == nil then
        return
    end
    local resultRow = listing == nil and picked ~= nil and ShownRow(function(row)
        return U.SameItemKey(row.result, picked)
    end)
    PlaceOn(panel.listingsButton, resultRow or nil)
    local listingRow = listing ~= nil and listing.picked ~= nil and ShownRow(function(row)
        return row.listing == listing.picked
    end)
    PlaceOn(panel.rowBuyButton, listingRow or nil)
end

--- The row whose prices the details block shows, which Listings would search for; nil for none.
-- @param result a browse result or Market row, or nil
function Purchase.SetPicked(result)
    picked = result
    Purchase.PlaceRowButtons()
end

--- Drops a quote the house holds for us. A buy already sent is kept, so its answer still shows.
local function DropQuote()
    if buy == nil or buy.step == "buying" then
        return
    end
    if buy.commodity then
        C_AuctionHouse.CancelCommoditiesPurchase()
    end
    buy = nil
end

--- Leaves the listings: drops any quote, and shows the search results or Market list again.
-- Sends nothing. Back, another tab, Clear, a new search, a Market view or the house closing.
function Purchase.Close()
    DropQuote()
    if listing == nil then
        return
    end
    listing = nil
    ui.buyPanel.purchaseBar:Hide()
    ui.buyPanel.filterRow:Show()
    for _, row in ipairs(ui.rows) do
        row.listing = nil
        U.MarkRow(row, false)
    end
    Buy.RefreshHeader()
    Buy.RenderRows()
    Purchase.PlaceRowButtons()
end

--- The Listings click: one search for the picked item's listings, when the house's throttle
-- allows it. The list then shows its listings. Nothing else is sent.
function Purchase.ShowListings()
    if picked == nil then
        return
    end
    if buy and buy.step == "buying" and buy.late then
        -- The house never answered that buy. Fresh listings show what it did; unlock.
        buy = nil
    end
    local itemKey = picked.itemKey
    local name = U.ItemLook(itemKey, picked)
    if not U.HouseIsOpen() then
        SetStatus("Open the auction house first.")
        return
    end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        SetStatus("The auction house is still busy. Wait, then click Buy again.")
        return
    end
    -- Stackable or not decides the search and how its answer is read, as in Blizzard's window.
    local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
    if info == nil then
        SetStatus("The game is still loading " .. name .. ". Click Buy again.")
        return
    end
    local commodity = info.isCommodity == true
    -- A Market row's gear has no item level of its own, so its search covers every item level,
    -- the way Blizzard's Sell tab searches gear. A Buy row has the listed one.
    local sellSearch = not commodity and info.isEquipment == true and picked.market == true
    local readKey = sellSearch and U.AnyVariantKey(itemKey) or itemKey
    listing = { itemID = itemKey.itemID, readKey = readKey, name = name, commodity = commodity, rows = {},
        ownCount = 0, complete = true, offset = 0, waiting = true }
    local panel = ui.buyPanel
    panel.filterRow:Hide()
    panel.purchaseBar:Show()
    panel.qtyBox:SetText("")
    for _, control in ipairs({ panel.qtyLabel, panel.qtyBox, panel.maxButton }) do
        if commodity then control:Show() else control:Hide() end
    end
    panel.buyButton:ClearAllPoints()
    panel.buyButton:SetPoint("LEFT", commodity and panel.maxButton or panel.backButton, "RIGHT", 8, 0)
    ListingHeader()
    -- One click, one search. Its answer comes as a results event; nothing follows up.
    local sorts = commodity and COMMODITY_SORT or GEAR_SORT
    if sellSearch then
        C_AuctionHouse.SendSellSearchQuery(readKey, sorts, false)
    else
        C_AuctionHouse.SendSearchQuery(readKey, sorts, false)
    end
    Purchase.Render()
    RefreshBuy()
    SetStatus(ListingStatus())
end

--- After new listings arrived: keep the scroll in range and the gear pick if still listed, then draw.
-- @param raw list of { unit, quantity, own, ... } for PriceLedger.BuyRows
-- @param complete false when the house says it has more
local function TakeListings(raw, complete)
    listing.rows, listing.ownCount = Price.BuyRows(raw)
    listing.complete, listing.waiting = complete, false
    listing.offset = math.min(listing.offset, math.max(0, #listing.rows - C.VISIBLE_ROWS))
    if listing.chosen and ChosenRow() == nil then
        listing.chosen = nil
    end
    -- The new rows are new tables: gear keeps its pick by auction; a stackable's pick ends.
    listing.picked = listing.chosen and ChosenRow() or nil
    Purchase.Render()
    RefreshBuy()
end

--- Commodity search results came in: shows them if they are for the open listings.
-- Only price and quantity are read; owners stay in the result.
-- @param itemID the item the results are for
function Purchase.OnCommodityResults(itemID)
    if listing == nil or not listing.commodity or itemID ~= listing.itemID then
        return
    end
    local raw = {}
    for index = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0 do
        local result = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, index)
        if result then
            local own = result.numOwnerItems
            if type(own) ~= "number" then
                own = result.containsOwnerItem == true
            end
            raw[#raw + 1] = { unit = result.unitPrice, quantity = result.quantity, own = own }
        end
    end
    TakeListings(raw, U.IsComplete(C_AuctionHouse.HasFullCommoditySearchResults, itemID))
end

--- Item search results came in: shows them if they are for the open listings.
-- A listing with no buyout is bid-only and is left out; owners stay in the result.
-- On Forever, one buy of a listing gets one item for its whole buyout (tested in game: a Silver
-- Rod listing of "quantity" 50 delivered 1 rod), so the buyout is the price, never divided by the
-- quantity. The scans agree: an item's saved price matched the lowest listing buyout and the
-- browse price exactly. The quantity is how many copies that listing holds: Blizzard's own window
-- shows the same numbers beside the same buyouts, and its "Available" is their sum.
-- @param itemKey the item key the results are for
function Purchase.OnItemResults(itemKey)
    if listing == nil or listing.commodity or type(itemKey) ~= "table" or itemKey.itemID ~= listing.itemID then
        return
    end
    local key = listing.readKey
    local raw = {}
    for index = 1, C_AuctionHouse.GetNumItemSearchResults(key) or 0 do
        local result = C_AuctionHouse.GetItemSearchResultInfo(key, index)
        if result and result.buyoutAmount and result.quantity and result.quantity > 0 then
            raw[#raw + 1] = {
                unit = result.buyoutAmount, quantity = result.quantity,
                own = result.containsOwnerItem == true, buyout = result.buyoutAmount, auctionID = result.auctionID,
                link = result.itemLink, level = result.itemKey and result.itemKey.itemLevel, timeLeft = result.timeLeft,
            }
        end
    end
    TakeListings(raw, U.IsComplete(C_AuctionHouse.HasFullItemSearchResults, key))
end

--- A listing row click: a stackable item's number goes up to and including that listing; a
-- piece of gear is picked for Buy. Starts over if a buy was waiting for Confirm. Sends nothing.
-- @param row the clicked row button
function Purchase.PickRow(row)
    local entry = row.listing
    if entry == nil or (buy and (buy.step == "buying" or buy.step == "quoting")) then
        return
    end
    DropQuote()
    listing.picked = entry
    if listing.commodity then
        ui.buyPanel.qtyBox:SetText(tostring(entry.upTo))
    else
        listing.chosen = entry.auctionID
    end
    Purchase.Render()
    RefreshBuy()
end

--- Max: everything the listings shown hold.
function Purchase.PickMax()
    if listing == nil or #listing.rows == 0 or (buy and buy.step ~= "quoted") then
        return
    end
    DropQuote()
    ui.buyPanel.qtyBox:SetText(tostring(listing.rows[#listing.rows].upTo))
    RefreshBuy()
end

--- The number box changed. A new number drops a waiting quote; while a buy is sent it can't change.
-- @param userInput true when the player typed
local function OnQuantityChanged(userInput)
    if not userInput or listing == nil then
        return
    end
    if buy and (buy.step == "buying" or buy.step == "quoting") then
        ui.buyPanel.qtyBox:SetText(tostring(buy.quantity))
        return
    end
    DropQuote()
    RefreshBuy()
end

--- Buy, then Confirm. Each click is one step, and only when the step before it is done:
-- a stackable item asks the house's price, then buys at it; gear asks to confirm, then buys.
function Purchase.OnBuyClick()
    if listing == nil then
        return
    end
    if U.InCombat() then
        SetStatus("Not in combat: buy after the fight.")
        return
    end
    local step = buy and buy.step
    if listing.commodity and step == nil then
        local asked, cost = AskedCost()
        if asked <= 0 or cost.count == 0 or cost.total > GetMoney() then
            return
        end
        buy = { step = "quoting", commodity = true, itemID = listing.itemID, quantity = cost.count,
            estimate = cost.total, name = listing.name, sentAt = U.Clock() }
        C_AuctionHouse.StartCommoditiesPurchase(listing.itemID, cost.count) -- reviewed: the player's Buy click asks the house's price
        SetStatus("Asking the house for its price...")
    elseif listing.commodity and step == "quoted" then
        buy.step, buy.sentAt = "buying", U.Clock()
        C_AuctionHouse.ConfirmCommoditiesPurchase(buy.itemID, buy.quantity) -- reviewed: the player's Confirm click buys at the house's quoted price
        SetStatus("Buying...")
    elseif not listing.commodity and step == nil then
        local row = ChosenRow()
        if row == nil or row.buyout > GetMoney() then
            return
        end
        buy = { step = "armed", auctionID = row.auctionID, buyout = row.buyout, name = ListingLabel(row) }
        local warning = Price.BuyWarningText(ListingStats(), row.unit)
        SetStatus(string.format("Buy %s for %s?%s Click Confirm.", buy.name, U.CopperToText(row.buyout),
            warning ~= "" and (" " .. warning .. ".") or ""))
    elseif step == "armed" then
        buy.step, buy.sentAt = "buying", U.Clock()
        C_AuctionHouse.PlaceBid(buy.auctionID, buy.buyout) -- reviewed: the player's Confirm click buys this listing at its buyout
        SetStatus("Buying...")
    end
    ShowBuyButton(false)
end

--- The house's price for the stackable buy we asked about (COMMODITY_PRICE_UPDATED). Like
-- Blizzard's window: over 5% more than the listings is refused, a smaller rise is shown, and
-- Confirm then buys at the house's price.
-- @param unit the quoted copper per unit
-- @param total the quoted copper in all
function Purchase.OnPriceUpdated(unit, total)
    if buy == nil or not buy.commodity or (buy.step ~= "quoting" and buy.step ~= "quoted") then
        return
    end
    local verdict, rise = Price.QuoteCheck(buy.estimate, total)
    local quantity = buy.quantity
    if verdict == "too high" then
        DropQuote()
        RefreshBuy()
        SetStatus(string.format("The price went up by more than 5%% (now %d for %s). Nothing was bought. "
            .. "Click Back, then Buy, to see the new prices.", quantity, U.CopperToText(total)))
        return
    end
    if total > GetMoney() then
        DropQuote()
        RefreshBuy()
        SetStatus(string.format("You have %s; the house's price for %d is %s.", U.CopperToText(GetMoney()),
            quantity, U.CopperToText(total)))
        return
    end
    buy.step, buy.total, buy.unit = "quoted", total, unit
    if verdict == "rose" then
        SetStatus(string.format("The price went up by %s since the listings: now %d for %s. "
            .. "Click Confirm to buy at this price.", U.CopperToText(rise), buy.quantity, U.CopperToText(total)))
    else
        SetStatus(string.format("The house's price: %d for %s. Click Confirm to buy.", buy.quantity,
            U.CopperToText(total)))
    end
    ShowBuyButton(false)
end

--- Ends a buy with a line in the status bar, and sets the Buy button again.
-- @param text the line
local function EndBuy(text)
    buy = nil
    RefreshBuy()
    SetStatus(text)
end

--- The house has no price for our stackable buy any more (COMMODITY_PRICE_UNAVAILABLE).
function Purchase.OnPriceUnavailable()
    if buy == nil or not buy.commodity or buy.step == "buying" then
        return
    end
    DropQuote()
    EndBuy("Those listings are gone. Nothing was bought. Click Back, then Buy, to see the new prices.")
end

--- Our stackable buy went through (COMMODITY_PURCHASE_SUCCEEDED).
function Purchase.OnPurchaseSucceeded()
    if buy == nil or not buy.commodity or buy.step ~= "buying" then
        return
    end
    EndBuy(string.format("Bought %d %s for %s. Check your mailbox. Click Back, then Buy, to see what's left.",
        buy.quantity, buy.name, U.CopperToText(buy.total)))
end

--- Our stackable buy failed (COMMODITY_PURCHASE_FAILED).
function Purchase.OnPurchaseFailed()
    if buy == nil or not buy.commodity or buy.step ~= "buying" then
        return
    end
    EndBuy("The house refused the purchase. Nothing was bought.")
end

--- A buyout went through (AUCTION_HOUSE_PURCHASE_COMPLETED): if it is ours, that listing is
-- taken off the list.
-- @param auctionID the auction bought
function Purchase.OnAuctionBought(auctionID)
    if buy == nil or buy.commodity or buy.step ~= "buying" or auctionID ~= buy.auctionID then
        return
    end
    if listing then
        for index, row in ipairs(listing.rows) do
            if row.auctionID == auctionID then
                table.remove(listing.rows, index)
                break
            end
        end
        listing.chosen, listing.picked = nil, nil
        Purchase.Render()
    end
    EndBuy(string.format("Bought %s for %s. Check your mailbox.", buy.name, U.CopperToText(buy.buyout)))
end

--- The house showed an error (AUCTION_HOUSE_SHOW_ERROR): our buyout, if one was sent, failed.
function Purchase.OnHouseError()
    if buy == nil or buy.commodity or buy.step ~= "buying" then
        return
    end
    EndBuy("The house refused the purchase. Nothing was bought.")
end

--- Once a second: a quote that ran out is dropped, and a price that never came is given up. A
-- buy already sent stays locked, so a late answer can't let a second one through; the status
-- line says what to do.
function Purchase.Tick()
    if buy == nil then
        return
    end
    if buy.step == "quoted" and C_AuctionHouse.GetQuoteDurationRemaining() <= 0 then
        DropQuote()
        EndBuy("The price quote ran out. Nothing was bought. Click Buy to ask again.")
    elseif buy.step == "quoting" and U.Clock() - buy.sentAt >= NO_ANSWER_WAIT then
        DropQuote()
        EndBuy("No price from the house. Nothing was bought. Click Buy to ask again.")
    elseif buy.step == "buying" and not buy.late and U.Clock() - buy.sentAt >= NO_ANSWER_WAIT then
        buy.late = true
        SetStatus("No answer from the house yet. Check your mailbox, then click Back and Buy to see "
            .. "what's left before buying again.")
    end
end

--- Makes the Listings button (in the details block) and the buy bar (in the filter row's place,
-- shown with the listings): Back, how many, Max and Buy.
function Purchase.Build()
    local panel = ui.buyPanel
    -- On the picked search result or Market row: opens its listings.
    local listings = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    listings:SetSize(ROW_BUTTON_WIDTH, ROW_BUTTON_HEIGHT)
    listings:SetText("Buy")
    listings:SetScript("OnClick", Purchase.ShowListings)
    listings:Hide()
    panel.listingsButton = listings
    -- On the picked listing: the bar's Buy (then Confirm), one row closer.
    local rowBuy = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    rowBuy:SetSize(ROW_BUTTON_WIDTH, ROW_BUTTON_HEIGHT)
    rowBuy:SetText("Buy")
    rowBuy:SetScript("OnClick", Purchase.OnBuyClick)
    rowBuy:Hide()
    panel.rowBuyButton = rowBuy

    local bar = CreateFrame("Frame", nil, panel)
    bar:SetAllPoints(panel)
    bar:Hide()
    panel.purchaseBar = bar
    local y = -C.LIST_TOP - 2 - C.FILTER_HEIGHT / 2

    local back = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    back:SetSize(BACK_WIDTH, 22)
    back:SetPoint("LEFT", ui.frame, "TOPLEFT", 14, y)
    back:SetText("Back")
    back:SetScript("OnClick", Purchase.Close)
    panel.backButton = back

    local label = U.Cell(bar, "GameFontNormalSmall", "LEFT")
    label:SetPoint("LEFT", back, "RIGHT", 10, 0)
    label:SetText("How many")
    panel.qtyLabel = label
    local box = CreateFrame("EditBox", nil, bar, "InputBoxTemplate")
    box:SetSize(QTY_WIDTH, 20)
    box:SetPoint("LEFT", label, "RIGHT", 10, 0)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(6)
    box:SetScript("OnTextChanged", function(_, userInput)
        OnQuantityChanged(userInput)
    end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    panel.qtyBox = box

    local max = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    max:SetSize(MAX_WIDTH, 22)
    max:SetPoint("LEFT", box, "RIGHT", 6, 0)
    max:SetText("Max")
    max:SetScript("OnClick", Purchase.PickMax)
    panel.maxButton = max

    local buyButton = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    buyButton:SetSize(BUY_WIDTH, 22)
    buyButton:SetPoint("LEFT", max, "RIGHT", 8, 0)
    buyButton:SetText("Buy")
    buyButton:SetScript("OnClick", Purchase.OnBuyClick)
    panel.buyButton = buyButton
end
