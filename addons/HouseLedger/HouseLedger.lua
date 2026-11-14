--[[
Personal auction-house helper for WoW Forever.

Search: one click sends one browse query, and only when Blizzard's
throttle says another query is allowed.

Scan: one click asks for the whole house once. Blizzard allows that
about every 15 minutes. Listings are read across frames. The lowest
buyout per item is saved on this computer and shown on item mouseovers.
Seller names are not saved.

This addon does not post, buy, bid, or cancel, and it does not scan
when the auction house opens.
]]

local ADDON_NAME = "HouseLedger"

local HouseLedger = {}
_G[ADDON_NAME] = HouseLedger

local MIN_SEARCH_LENGTH = 2
-- Stay under the roughly 2000 replicate reads per frame that start
-- getting dropped. count, buyout, and item id are already filled in.
local READ_BATCH = 500
-- Long enough for a full-house reply. time() is whole seconds and can
-- make a short deadline expire early.
local ANSWER_WAIT = 60
-- Space between Blizzard's auction house window and this one.
local PIN_GAP = 4

-- Window size. The height follows Blizzard's auction house window (538
-- in its XML). The width fills the room to the right of it, between
-- these limits; the screen clamp slides a too-wide window back on.
local HOUSE_HEIGHT = 538
local FRAME_WIDTH_MIN = 440
local FRAME_WIDTH_MAX = 640
local SCREEN_MARGIN = 8
-- Below this width the Avg 7d column is hidden; a row click still
-- shows the averages in the details block.
local TYPICAL_MIN_WIDTH = 560

-- Under the list: the details block for a clicked row (a title and the
-- five lines of PriceLedger.WindowLines), then two status lines.
local STATUS_HEIGHT = 48
local DETAIL_LINES = 5
local DETAIL_LINE_HEIGHT = 15
local DETAIL_HEIGHT = (DETAIL_LINES + 1) * DETAIL_LINE_HEIGHT + 10

-- The results list sits in the template's inset, between the search
-- bar (60 from the top) and the details block.
local LIST_TOP = 60
local LIST_BOTTOM = STATUS_HEIGHT + DETAIL_HEIGHT
local HEADER_HEIGHT = 26
local ROW_HEIGHT = 18
-- (538 - 60 - 148 - 26) / 18 = 16 rows.
-- The filter row (quality, item level, and Market's name filter) sits between the top row and the list.
local FILTER_HEIGHT = 26
-- The 14-day chart: beside the Buy details on a wide window, and under the Sell lines.
local CHART_WIDTH = 170
local CHART_HEIGHT = 74
local SELL_CHART_WIDTH = 260
local SELL_CHART_HEIGHT = 70
-- Bar colors: earlier days blue, the latest day gold, a day's range a faint band above its low.
local CHART_BAR_COLOR = { 0.35, 0.6, 1, 0.9 }
local CHART_LATEST_COLOR = { 1, 0.82, 0, 1 }
local CHART_RANGE_COLOR = { 0.35, 0.6, 1, 0.3 }
-- The filter row's center, below the window's top edge.
local FILTER_ROW_Y = -LIST_TOP - 2 - FILTER_HEIGHT / 2
local VISIBLE_ROWS = math.floor((HOUSE_HEIGHT - LIST_TOP - FILTER_HEIGHT - LIST_BOTTOM - HEADER_HEIGHT) / ROW_HEIGHT)
local WHEEL_STEP = 3

local COLUMN_WIDTH = { price = 96, avail = 48, typical = 96, trend = 72 }
local COLUMN_GAP = 6
local ICON_SIZE = 16
-- Shown until the game has loaded an item's icon.
local QUESTION_MARK_ICON = 134400
local PORTRAIT_ICON = "Interface\\Icons\\INV_Misc_Coin_02"

local QUALITY_FILTERS = {
    Enum.AuctionHouseFilter.PoorQuality,
    Enum.AuctionHouseFilter.CommonQuality,
    Enum.AuctionHouseFilter.UncommonQuality,
    Enum.AuctionHouseFilter.RareQuality,
    Enum.AuctionHouseFilter.EpicQuality,
}

local PRICE_SORT = {
    { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
    { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
}
local SELL_SORT = {
    { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
}

local BUY_TAB = 1
local SELL_TAB = 2
-- Market is ours alone: a plain tab that presses nothing on Blizzard's window.
local MARKET_TAB = 3
-- Settings is ours alone too.
local SETTINGS_TAB = 4
-- The Market tab's views, in switcher order. All read saved data only.
local MARKET_VIEWS = {
    { key = "deals", title = "Deals", noun = "deals",
        empty = "No deals at your last scan. A deal needs %d scans of an item." },
    { key = "drops", title = "Biggest drops", noun = "drops", empty = "No prices went down at your last scan." },
    { key = "rises", title = "Biggest rises", noun = "rises", empty = "No prices went up at your last scan." },
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
local BUY_HELP = "Type an item name. One click sends one search."
local DETAIL_HINT = "Click a row for its saved prices over 1, 3, 7 and 14 days."
-- The Sell lines filled in order from PriceLedger.WindowLines.
local WINDOW_KEYS = { "w1", "w3", "w7", "w14", "spread" }
local SELL_PROMPT = "Drop an item from your bags here"
local SELL_HELP = "Drop an item from your bags. One drop sends one search. Nothing is saved."
local EMPTY_SLOT_TEXTURE = "Interface\\Buttons\\UI-EmptySlot"

local frame
local searchBox
local statusText
local scanText
local scanBar -- the read's progress, shown only while reading
local scanButton
local buyPanel
local sellPanel
local settingsPanel
local header
-- The item on the Sell tab (dropped here, or put in Blizzard's Sell
-- window), until the next one. Never saved.
local pendingSell
local rows = {}
-- Last browse results and how far the list is scrolled. Scrolling and
-- clicking only re-read these; they never ask the house again.
local results = {}
-- The search results that pass the filters, in the same order.
local shownResults = {}
local scrollOffset = 0
-- Quality and item level limits, shared by Buy and Market; Market's name filter text.
local filter = {}
local marketText = ""
-- True while one refilter waits for the next frame, so a burst of item-info events filters once.
local refilterPending = false
-- The Market tab: which view, its rows (shaped like browse results), and the
-- PriceLedger.Market lists, kept until the house has a newer scan.
local marketView = 1
local marketList = {}
local marketOffset = 0
local marketCache

local scanState = "idle"
local readToken = 0
local waitStarted = 0
local acceptAnswerUntil = 0
local holdStatusUntil = 0
local scanHouseKey
local tooltipsHooked = false
-- Blizzard's auction window is followed through hooksecurefunc, set once.
local houseHooked = false
-- Our tabs are secure click buttons pointed at Blizzard's tabs, set once.
local tabsLinked = false
local currentTab = BUY_TAB
-- The tabs make the window protected: in combat the game blocks addon
-- changes to it. These mark what to catch up on when combat ends.
local afterCombat = false
local buildAfterCombat = false

--- True while the game blocks addon changes to protected frames.
-- @return true in combat lockdown, false otherwise or without InCombatLockdown
local function InCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() == true
end

--- True when the game would block an addon change to this frame now.
-- That is in combat, and the game counts the frame as protected. The game is
-- asked rather than assumed; without IsProtected, assume it is.
-- @param region the frame to check
-- @return true when a change would be blocked
local function Locked(region)
    if not InCombat() then
        return false
    end
    return type(region.IsProtected) ~= "function" or region:IsProtected() == true
end

--- Sets the Buy tab's status line, once the window is built.
-- @param text the line's text
local function SetStatus(text)
    if statusText then
        statusText:SetText(text)
    end
end

--- Sets the scan line at the bottom of the window.
-- @param text the line's text
-- @param holdSeconds optional; keeps the idle refresh from replacing the text this long
local function SetScanStatus(text, holdSeconds)
    if scanText then
        scanText:SetText(text)
    end
    if holdSeconds and holdSeconds > 0 then
        holdStatusUntil = time() + holdSeconds
    end
end

--- Shows a copper amount the way the game does: gold, silver and copper, each with its coin icon.
-- GetMoneyString is Blizzard's own formatter on
-- Forever, which has no GetCoinTextureString. It switches to "1g 2s 3c"
-- text when the player has colorblind mode on. If it is ever missing, the
-- plain-text version from PriceLedger keeps the price readable.
-- @param copper whole copper, or nil
-- @return the text, or "-" for no price (nil, 0 or less)
local function CopperToText(copper)
    if not copper or copper <= 0 then
        return "-"
    end
    if GetMoneyString then
        return GetMoneyString(copper, true)
    end
    return HouseLedgerPrice.CoinText(copper)
end

--- A wait as whole minutes (rounded up) from 60 seconds on, otherwise seconds.
-- @param seconds the wait
-- @return text like "15 min" or "40 sec"
local function RemainingText(seconds)
    seconds = math.ceil(seconds)
    if seconds >= 60 then
        return string.format("%d min", math.ceil(seconds / 60))
    end
    return string.format("%d sec", seconds)
end

--- The realm name, or "Forever" when the game gives none.
-- @return the realm name
local function RealmLabel()
    if type(GetRealmName) ~= "function" then
        return "Forever"
    end
    local name = GetRealmName()
    if type(name) ~= "string" or name == "" then
        return "Forever"
    end
    return name
end

--- The house key for the player's own faction on this realm.
-- @return the key, from PriceLedger.HouseKey
local function PlayerHouseKey()
    local side = "Unknown"
    if type(UnitFactionGroup) == "function" then
        side = UnitFactionGroup("player") or "Unknown"
    end
    return HouseLedgerPrice.HouseKey(side, RealmLabel())
end

--- The house key for the auctioneer you have open.
-- A goblin house has no Alliance or Horde faction group, so those scans are
-- stored on their own, as "Neutral". Without an npc unit, the player's
-- faction is used.
-- @return the key, from PriceLedger.HouseKey
local function CurrentScanKey()
    local side
    if type(UnitExists) == "function" and UnitExists("npc") and type(UnitFactionGroup) == "function" then
        local npcSide = UnitFactionGroup("npc")
        if npcSide == "Alliance" or npcSide == "Horde" then
            side = npcSide
        else
            side = "Neutral"
        end
    elseif type(UnitFactionGroup) == "function" then
        side = UnitFactionGroup("player")
    end
    return HouseLedgerPrice.HouseKey(side, RealmLabel())
end

--- The game's clock in seconds, for timing the wait for an answer.
-- @return GetTime(), or time() when GetTime is missing
local function Clock()
    if type(GetTime) == "function" then
        return GetTime()
    end
    return time()
end

--- Updates the Scan button while no scan runs: "Scan" and enabled when a scan is allowed,
-- otherwise greyed out with the wait, like "Scan (12m)". Only the button's own text and state
-- change; nothing is sent.
local function RefreshScanButton()
    if not scanButton or scanState ~= "idle" then
        return
    end
    local wait = HouseLedgerPrice.SecondsUntil(HouseLedgerDB.replicateAt, time())
    local text = HouseLedgerPrice.ScanButtonText(wait)
    if scanButton:GetText() ~= text then
        scanButton:SetText(text)
    end
    if wait > 0 then
        scanButton:Disable()
    else
        scanButton:Enable()
    end
end

--- Shows the read's progress bar at a number of listings read, or hides it.
-- @param read listings read so far, or nil to hide the bar
-- @param total how many listings the house sent
local function ShowScanProgress(read, total)
    if not scanBar then
        return
    end
    if read == nil or total == nil or total <= 0 then
        scanBar:Hide()
        return
    end
    scanBar:SetMinMaxValues(0, total)
    scanBar:SetValue(read)
    scanBar:Show()
end

--- Updates the scan line while no scan is running.
-- Shows how many prices the player's house has and when the next scan is
-- allowed. Does nothing while a scan runs or a held message is still up.
local function RefreshIdleScanLine()
    if scanState ~= "idle" or time() < holdStatusUntil then
        return
    end
    local wait = HouseLedgerPrice.SecondsUntil(HouseLedgerDB.replicateAt, time())
    local key = PlayerHouseKey()
    local house = HouseLedgerDB.houses and HouseLedgerDB.houses[key]
    local priced = 0
    if type(house) == "table" and type(house.items) == "table" then
        for _ in pairs(house.items) do
            priced = priced + 1
        end
    end
    local label = HouseLedgerPrice.HouseLabel(key)
    if wait > 0 and priced > 0 then
        SetScanStatus(string.format(
            "%d prices (%s). Next scan in %s.",
            priced, label, RemainingText(wait)
        ))
        return
    end
    if priced > 0 then
        SetScanStatus(string.format("%d prices (%s). Scan is ready.", priced, label))
        return
    end
    if wait > 0 then
        SetScanStatus("Next scan in " .. RemainingText(wait) .. ".")
        return
    end
    SetScanStatus("No prices saved yet. Click Scan once.")
end

--- Name, icon and quality for a result.
-- The game may not have loaded the item yet; ITEM_KEY_ITEM_INFO_RECEIVED
-- redraws the rows.
-- A Market row carries the name and quality its scan saved; those come first.
-- @param itemKey the result's item key, or nil
-- @param result optional; the row's result, with savedName and savedQuality on Market rows
-- @return the name, or "item <id>" (or "unknown item") until it is loaded
-- @return the icon, or a question mark until it is loaded
-- @return the item quality, or nil until it is loaded
local function ItemLook(itemKey, result)
    local info = itemKey and C_AuctionHouse.GetItemKeyInfo(itemKey)
    if result and result.savedName then
        local quality = result.savedQuality
        if not HouseLedgerPrice.IsQuality(quality) then
            quality = info and info.quality
        end
        return result.savedName, info and info.iconFileID or QUESTION_MARK_ICON, quality
    end
    if info and info.itemName and info.itemName ~= "" then
        return info.itemName, info.iconFileID or QUESTION_MARK_ICON, info.quality
    end
    local itemID = itemKey and itemKey.itemID
    if itemID then
        return "item " .. itemID, QUESTION_MARK_ICON, nil
    end
    return "unknown item", QUESTION_MARK_ICON, nil
end

--- Saved stats for an item at the player's own house, or nil.
-- Falls back to the last scanned house as PriceLedger.Lookup does.
-- @param itemID the item's id, or nil
-- @return stats from PriceLedger.Stats, or nil
local function SavedStats(itemID)
    local saved = HouseLedgerPrice.Lookup(HouseLedgerDB, itemID, PlayerHouseKey())
    return saved and saved.stats
end

--- Fills one list row from a browse result and shows it.
-- The trend and deal mark judge the live price against the saved stats.
-- @param row a row button from BuildRow
-- @param result one entry of C_AuctionHouse.GetBrowseResults
local function FillRow(row, result)
    local name, icon, quality = ItemLook(result.itemKey, result)
    row.result = result
    row.nameText:SetText(name)
    local r, g, b = 1, 1, 1
    -- The game rejects anything but a real quality, such as a scan's -1 for "not known yet".
    if HouseLedgerPrice.IsQuality(quality) and C_Item and type(C_Item.GetItemQualityColor) == "function" then
        r, g, b = C_Item.GetItemQualityColor(quality)
    end
    row.nameText:SetTextColor(r, g, b)
    row.icon:SetTexture(icon)
    row.priceText:SetText(CopperToText(result.minPrice))
    row.availText:SetText(tostring(result.totalQuantity or 0))

    local stats = SavedStats(result.itemKey and result.itemKey.itemID)
    row.typicalText:SetText(stats and stats.typical and CopperToText(stats.typical) or "-")
    -- Judge the live price, not the last scan's: that is what you would pay.
    local verdict = HouseLedgerPrice.Judge(stats, result.minPrice)
    local mark = HouseLedgerPrice.TrendText(verdict, "buyer")
    if mark == "" then
        mark = HouseLedgerPrice.SteadyText(verdict)
    end
    if verdict.deal then
        mark = mark .. " " .. HouseLedgerPrice.DEAL_ICON
    end
    row.trendText:SetText(mark)
    row:Show()
end

--- How long ago a time was, for the Market switcher.
-- @param seconds seconds since then
-- @return text like "just now", "12 min ago", "2 h ago" or "3 days ago"
local function AgoText(seconds)
    if seconds < 60 then
        return "just now"
    elseif seconds < 60 * 60 then
        return string.format("%d min ago", math.floor(seconds / 60))
    elseif seconds < 48 * 60 * 60 then
        return string.format("%d h ago", math.floor(seconds / (60 * 60)))
    end
    return string.format("%d days ago", math.floor(seconds / (24 * 60 * 60)))
end

--- The list the Buy panel shows now: the Market list on the Market tab, else the search results.
-- @return the list, and its scroll offset
local function ActiveList()
    if currentTab == MARKET_TAB then
        return marketList, marketOffset
    end
    return shownResults, scrollOffset
end

--- The house the Market tab reads: the player's own once it has a scan, else the last one scanned.
-- @return the house table, or nil
local function MarketHouse()
    local houses = HouseLedgerDB.houses or {}
    local house = houses[PlayerHouseKey()]
    if type(house) == "table" and house.scannedAt then
        return house
    end
    return houses[HouseLedgerDB.lastHouseKey or ""]
end

--- An item key for a saved item: the game's own maker when it has one.
-- Saved rows have the item id only, so gear shows as its base item.
-- @param itemID the item's id
-- @return the item key
local function SavedItemKey(itemID)
    if type(C_AuctionHouse.MakeItemKey) == "function" then
        return C_AuctionHouse.MakeItemKey(itemID)
    end
    return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
end

--- A saved item's name, quality and base item level, for Market's filters: the scan's saved
-- name and quality first, then the game's item data. The game loads an item it doesn't have yet;
-- GET_ITEM_INFO_RECEIVED filters again once it arrives.
-- @param entry a PriceLedger.Market entry
-- @return { name, quality, level }, any of them nil when not known
local function SavedItemLook(entry)
    local name, quality, level
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    if type(getInfo) == "function" then
        local _
        name, _, quality, level = getInfo(entry.itemID)
    end
    if HouseLedgerPrice.IsQuality(entry.quality) then
        quality = entry.quality
    end
    return { name = entry.name or name, quality = quality, level = level }
end

--- Keeps the search results that pass the quality and item level filters, using each result's
-- own item level. Reads what the search brought back; sends nothing.
local function FilterResults()
    shownResults = {}
    local check = HouseLedgerPrice.FilterActive(filter)
    for _, result in ipairs(results) do
        local name, _, quality = ItemLook(result.itemKey, result)
        local level = result.itemKey and result.itemKey.itemLevel
        if not check or HouseLedgerPrice.PassesFilter({ name = name, quality = quality, level = level }, filter) then
            shownResults[#shownResults + 1] = result
        end
    end
    shownResults.from = #results
end

--- Rebuilds the Market rows for the chosen view. The three lists are worked out once per scan.
-- Reads saved data only.
local function RefreshMarket()
    local house = MarketHouse()
    if marketCache == nil or marketCache.house ~= house or marketCache.scannedAt ~= (house and house.scannedAt) then
        marketCache = HouseLedgerPrice.Market(house)
        marketCache.house = house
    end
    marketList = {}
    local view = marketCache[MARKET_VIEWS[marketView].key]
    local limits = { text = marketText, minQuality = filter.minQuality, minLevel = filter.minLevel,
        maxLevel = filter.maxLevel }
    local check = limits.text ~= "" or HouseLedgerPrice.FilterActive(limits)
    for _, entry in ipairs(view) do
        if not check or HouseLedgerPrice.PassesFilter(SavedItemLook(entry), limits) then
            marketList[#marketList + 1] = {
                itemKey = SavedItemKey(entry.itemID), minPrice = entry.unit, totalQuantity = entry.qty,
                savedName = entry.name, savedQuality = entry.quality,
            }
        end
    end
    marketList.from = #view
    marketOffset = math.min(marketOffset, math.max(0, #marketList - VISIBLE_ROWS))
end

--- The Market switcher's text: the view and how old the scan is.
-- @return text like "Deals at last scan (12 min ago)"
local function MarketLabel()
    local title = MARKET_VIEWS[marketView].title
    local scannedAt = marketCache and marketCache.scannedAt
    if scannedAt == nil then
        return title
    end
    return title .. " at last scan (" .. AgoText(math.max(0, time() - scannedAt)) .. ")"
end

--- The status line for an empty Market view.
-- @return the text
local function MarketEmptyText()
    if marketCache == nil or marketCache.scannedAt == nil then
        return "No prices saved yet. Click Scan once."
    end
    return string.format(MARKET_VIEWS[marketView].empty, HouseLedgerPrice.DEAL_MIN_SCANS + 1)
end

--- Draws the visible rows from the active list at its scroll offset.
-- Also sets the status line to the range shown, or says the list is empty.
local function RenderRows()
    local list, offset = ActiveList()
    local market = currentTab == MARKET_TAB
    for index = 1, VISIBLE_ROWS do
        local result = list[offset + index]
        if result then
            FillRow(rows[index], result)
        else
            rows[index].result = nil
            rows[index]:Hide()
        end
    end
    if market then
        buyPanel.marketLabel:SetText(MarketLabel())
    end
    local from = list.from or #list
    if #list == 0 then
        if from > 0 then
            SetStatus(string.format("Nothing matches the filters (%d hidden).", from))
        else
            SetStatus(market and MarketEmptyText() or "No results.")
        end
        return
    end
    local last = math.min(#list, offset + VISIBLE_ROWS)
    local filtered = from > #list and string.format(" (filtered from %d)", from) or ""
    if market then
        SetStatus(string.format("Showing %d-%d of %d %s%s.", offset + 1, last, #list,
            MARKET_VIEWS[marketView].noun, filtered))
        return
    end
    local text = string.format("Showing %d-%d of %d%s.", scrollOffset + 1, last, #list, filtered)
    if type(C_AuctionHouse.HasFullBrowseResults) == "function" and not C_AuctionHouse.HasFullBrowseResults() then
        text = text .. " The house has more; narrow the search."
    end
    SetStatus(text)
end

--- Empties the details block under the Buy list.
local function ClearDetails()
    buyPanel.detailTitle:SetText(DETAIL_HINT)
    for _, line in ipairs(buyPanel.detailLines) do
        line.left:SetText("")
        line.right:SetText("")
    end
    buyPanel.chart:Hide()
end

--- Draws an item's saved 14 days on a chart: one bar per day's low, a faint band up to its high,
-- the latest day in gold. Hides the chart when there is nothing to draw. Saved data only.
-- @param chart a chart from BuildChart
-- @param info the item's saved prices from PriceLedger.Lookup, or nil
local function ShowChart(chart, info)
    local data = info and HouseLedgerPrice.ChartDays(info.days, info.seen)
    if data == nil or data.top <= 0 then
        chart:Hide()
        return
    end
    for index, slot in ipairs(data.slots) do
        local bar, band = chart.bars[index], chart.bands[index]
        if slot.low then
            local low = math.max(1, math.floor(slot.low / data.top * chart.barArea + 0.5))
            local high = math.floor(slot.high / data.top * chart.barArea + 0.5)
            bar:SetHeight(low)
            local color = index == #data.slots and CHART_LATEST_COLOR or CHART_BAR_COLOR
            bar:SetColorTexture(color[1], color[2], color[3], color[4])
            bar:Show()
            if high > low then
                band:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, 0)
                band:SetHeight(high - low)
                band:Show()
            else
                band:Hide()
            end
        else
            bar:Hide()
            band:Hide()
        end
    end
    chart.topText:SetText(CopperToText(data.top))
    chart:Show()
end

--- Reads the new browse results, scrolls to the top and draws them.
local function ShowResults()
    results = C_AuctionHouse.GetBrowseResults() or {}
    FilterResults()
    scrollOffset = 0
    if currentTab == MARKET_TAB then
        -- Kept for when the Buy tab opens again.
        return
    end
    -- The clicked row may not be in the new list.
    ClearDetails()
    RenderRows()
end

--- Mouse wheel over the list.
-- Moves through results already received.
-- @param rowsDown rows to move; negative moves up. Clamped to the list.
local function Scroll(rowsDown)
    local list, current = ActiveList()
    local maxOffset = math.max(0, #list - VISIBLE_ROWS)
    local offset = math.min(maxOffset, math.max(0, current + rowsDown))
    if offset == current then
        return
    end
    if currentTab == MARKET_TAB then
        marketOffset = offset
    else
        scrollOffset = offset
    end
    RenderRows()
end

--- A row click: its saved stats in the details block.
-- Reads saved data only; the house is not asked anything.
-- @param row the clicked row button
local function ShowRowDetails(row)
    if row.result == nil then
        return
    end
    ClearDetails()
    local name = ItemLook(row.result.itemKey, row.result)
    local stats = SavedStats(row.result.itemKey and row.result.itemKey.itemID)
    if stats == nil then
        buyPanel.detailTitle:SetText(name .. ": no saved prices yet. Click Scan.")
        return
    end
    buyPanel.detailTitle:SetText(name .. ", " .. HouseLedgerPrice.CountText(stats))
    if buyPanel.chartRoom then
        ShowChart(buyPanel.chart, HouseLedgerPrice.Lookup(HouseLedgerDB, row.result.itemKey.itemID, PlayerHouseKey()))
    end
    local lines = HouseLedgerPrice.WindowLines(stats, CopperToText) or {}
    for index, line in ipairs(buyPanel.detailLines) do
        local source = lines[index]
        line.left:SetText(source and source.left or "")
        line.right:SetText(source and source.right or "")
    end
end

--- Row hover: the game's item tooltip for the row's item.
-- @param row the hovered row button
local function ShowRowTooltip(row)
    local itemKey = row.result and row.result.itemKey
    if itemKey == nil or GameTooltip == nil then
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local requiredLevel
    if type(C_AuctionHouse.GetItemKeyRequiredLevel) == "function" then
        requiredLevel = C_AuctionHouse.GetItemKeyRequiredLevel(itemKey)
    end
    GameTooltip:SetItemKey(itemKey.itemID, itemKey.itemLevel, itemKey.itemSuffix, requiredLevel)
    GameTooltip:Show()
end

--- Hides the item tooltip when the mouse leaves a row.
local function HideRowTooltip()
    if GameTooltip then
        GameTooltip:Hide()
    end
end

--- True when Blizzard's auction house window exists and is shown.
-- @return true when open; false or nil otherwise
local function HouseIsOpen()
    return AuctionHouseFrame and AuctionHouseFrame:IsShown()
end

--- Sets the Sell tab's status line, once the panel is built.
-- @param text the line's text
local function SetSellStatus(text)
    if sellPanel then
        sellPanel.statusText:SetText(text)
    end
end

--- Resets the Sell tab's labels and values to "-" and empties its hint.
local function ClearSellValues()
    for _, line in ipairs(SELL_LINES) do
        sellPanel.labels[line[1]]:SetText(line[2])
        sellPanel.values[line[1]]:SetText("-")
    end
    sellPanel.hint:SetText("")
    sellPanel.chart:Hide()
end

--- Shows the live listings for the Sell item next to its saved stats.
-- Colors are the seller's view: a higher price is good news.
-- @param summary from PriceLedger.LowestListing, or nil for none listed
-- @param complete false when the house sent only the first part of a long list
local function ShowSellResults(summary, complete)
    local values = sellPanel.values
    ClearSellValues()
    local stats = SavedStats(pendingSell.itemID)
    if stats then
        local lines = HouseLedgerPrice.WindowLines(stats, CopperToText) or {}
        for index, key in ipairs(WINDOW_KEYS) do
            if lines[index] then
                sellPanel.labels[key]:SetText(lines[index].left)
                values[key]:SetText(lines[index].right)
            end
        end
        values.based:SetText(HouseLedgerPrice.CountText(stats))
        values.typical:SetText(stats.typical and CopperToText(stats.typical) or "-")
        ShowChart(sellPanel.chart, HouseLedgerPrice.Lookup(HouseLedgerDB, pendingSell.itemID, PlayerHouseKey()))
    else
        values.based:SetText("No saved prices yet")
    end
    if summary == nil then
        sellPanel.hint:SetText(HouseLedgerPrice.SellAdvice(nil, false))
        SetSellStatus("No one is selling " .. pendingSell.name .. " right now.")
        return
    end
    values.low:SetText(CopperToText(summary.low))
    values.atLow:SetText(tostring(summary.atLow))
    values.total:SetText(HouseLedgerPrice.ListingText(summary))
    local verdict = HouseLedgerPrice.Judge(stats, summary.low)
    local trend = HouseLedgerPrice.TrendText(verdict, "seller")
    if trend == "" then
        trend = HouseLedgerPrice.SteadyText(verdict)
    end
    values.trend:SetText(trend ~= "" and trend or "-")
    sellPanel.hint:SetText(HouseLedgerPrice.SellAdvice(verdict, true))
    local text = "Lowest of " .. HouseLedgerPrice.ListingText(summary) .. " for " .. pendingSell.name .. "."
    if complete == false then
        -- Asking for the rest would be another query; leave that to a new drop.
        text = text .. " The house has more; these are the first ones."
    end
    SetSellStatus(text)
end

--- False only when the house says the list is not complete.
-- @param check the game's Has...Full...Results function, or nil when missing
-- @param ... the arguments for check
-- @return true unless check returns false
local function IsComplete(check, ...)
    if type(check) ~= "function" then
        return true
    end
    return check(...) ~= false
end

--- Commodity search results came in: shows them if they are for the Sell item.
-- @param itemID the item the results are for
local function OnCommodityResults(itemID)
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
    ShowSellResults(HouseLedgerPrice.LowestListing(listings),
        IsComplete(C_AuctionHouse.HasFullCommoditySearchResults, itemID))
end

--- Item search results came in: shows them if they are for the Sell item.
-- @param itemKey the item key the results are for
local function OnItemResults(itemKey)
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
                HouseLedgerPrice.UnitCopper(result.buyoutAmount, result.quantity),
                result.quantity,
            }
        end
    end
    ShowSellResults(HouseLedgerPrice.LowestListing(listings),
        IsComplete(C_AuctionHouse.HasFullItemSearchResults, searchKey))
end

--- The search key Blizzard's Sell tab uses for gear.
-- Item level and suffix are 0, so every variant of the item comes back in one list.
-- @param itemKey the item's own key; it is not changed
-- @return a new item key
local function AnyVariantKey(itemKey)
    return {
        itemID = itemKey.itemID,
        itemLevel = 0,
        itemSuffix = 0,
        battlePetSpeciesID = itemKey.battlePetSpeciesID or 0,
    }
end

--- Puts an item on the Sell tab with empty values until its prices come in.
-- @param readKey the key its item search results are read with
-- @param name the item name to show
-- @param icon the icon to show
-- @param commodity true for a stackable item (commodity results)
-- @param followed true when the item came from Blizzard's Sell window
local function StartPendingSell(readKey, name, icon, commodity, followed)
    pendingSell = {
        itemID = readKey.itemID, itemKey = readKey, name = name,
        commodity = commodity, followed = followed == true,
    }
    sellPanel.itemName:SetText(name)
    sellPanel.icon:SetTexture(icon)
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

    if not HouseIsOpen() then
        SetSellStatus("Open the auction house first.")
        return
    end
    if not sellable then
        SetSellStatus(name .. " can't be sold at the auction house.")
        return
    end
    if status == Enum.ItemCommodityStatus.Unknown then
        -- Blizzard's Sell tab stops here too: without item data the right
        -- search is not known, and a wrong one would spend the throttle.
        SetSellStatus("The game is still loading " .. name .. ". Drop it again.")
        return
    end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        SetSellStatus("The auction house is still busy. Wait, then drop the item again.")
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
    local searchKey = gear and AnyVariantKey(itemKey) or itemKey
    StartPendingSell(searchKey, name, icon, commodity)
    if gear then
        C_AuctionHouse.SendSellSearchQuery(searchKey, SELL_SORT, false)
    else
        C_AuctionHouse.SendSearchQuery(searchKey, SELL_SORT, false)
    end
    SetSellStatus("Searching for " .. name .. "...")
end

--- Switches the Buy panel between its search (Buy tab) and the Market tab.
-- On Market the search box, Clear and Search hide and the view switcher shows in their place;
-- both share the list, its rows and the details block. Nothing is sent either way.
-- @param market true for the Market tab
local function SetMarketMode(market)
    buyPanel.marketMode = market
    for _, control in ipairs(buyPanel.searchControls) do
        if market then control:Hide() else control:Show() end
    end
    for _, control in ipairs(buyPanel.marketControls) do
        if market then control:Show() else control:Hide() end
    end
    -- Market's name filter takes the start of the filter row; Buy's name is its search box.
    local quality = buyPanel.qualityDropdown
    quality:ClearAllPoints()
    if market then
        buyPanel.filterNameBox:Show()
        quality:SetPoint("LEFT", buyPanel.filterNameBox, "RIGHT", 10, 0)
    else
        buyPanel.filterNameBox:Hide()
        quality:SetPoint("LEFT", frame, "TOPLEFT", 14, FILTER_ROW_Y)
    end
    buyPanel.priceHeading:SetText(market and "Scanned" or "Price")
    ClearDetails()
    if market then
        RefreshMarket()
        RenderRows()
    elseif #results > 0 then
        FilterResults()
        RenderRows()
    else
        for _, row in ipairs(rows) do
            row.result = nil
            row:Hide()
        end
        SetStatus(BUY_HELP)
    end
end

--- After a filter changed: filters the open list again from what is already here. Sends nothing.
local function ApplyFilters()
    filter.minLevel = HouseLedgerPrice.ParseLevel(buyPanel.minLevelBox:GetText())
    filter.maxLevel = HouseLedgerPrice.ParseLevel(buyPanel.maxLevelBox:GetText())
    marketText = strtrim(buyPanel.filterNameBox:GetText() or "")
    if currentTab == MARKET_TAB then
        marketOffset = 0
        RefreshMarket()
    else
        scrollOffset = 0
        FilterResults()
        if #results == 0 then
            return
        end
    end
    ClearDetails()
    RenderRows()
end

--- Market's < and > arrows: the previous or next view, wrapping around.
-- @param step 1 for the next view, -1 for the previous one
local function StepMarket(step)
    marketView = (marketView - 1 + step) % #MARKET_VIEWS + 1
    marketOffset = 0
    RefreshMarket()
    ClearDetails()
    RenderRows()
end

--- Shows the Buy, Sell or Market tab.
-- @param id BUY_TAB, SELL_TAB or MARKET_TAB
local function SelectTab(id)
    currentTab = id
    -- The tab buttons are protected; in combat they are marked afterwards.
    -- The panels switch right away unless the game counts them as
    -- protected too; then OnCombatEnded switches them.
    if InCombat() then
        afterCombat = true
    else
        PanelTemplates_SetTab(frame, id)
    end
    if Locked(buyPanel) or Locked(sellPanel) then
        return
    end
    if id == SETTINGS_TAB then
        buyPanel:Hide()
        sellPanel:Hide()
        settingsPanel:Show()
    elseif id == SELL_TAB then
        buyPanel:Hide()
        settingsPanel:Hide()
        sellPanel:Show()
    else
        sellPanel:Hide()
        settingsPanel:Hide()
        buyPanel:Show()
        if (id == MARKET_TAB) ~= (buyPanel.marketMode == true) then
            SetMarketMode(id == MARKET_TAB)
        end
    end
end

--- Clear on the Buy tab: empties the search box and the list.
-- The house is not asked anything; a result that still arrives shows as usual.
local function ClearSearch()
    searchBox:SetText("")
    searchBox:ClearFocus()
    results = {}
    shownResults = {}
    scrollOffset = 0
    for _, row in ipairs(rows) do
        row.result = nil
        row:Hide()
    end
    ClearDetails()
    SetStatus(BUY_HELP)
end

--- Reset on the Sell tab: empties the slot and its values.
-- Results that still arrive for that item are ignored. Blizzard's window is left as is.
local function ResetSell()
    pendingSell = nil
    sellPanel.itemName:SetText(SELL_PROMPT)
    sellPanel.icon:SetTexture(nil)
    ClearSellValues()
    SetSellStatus(SELL_HELP)
end

--- Search click or Enter: sends one browse query for the search box text.
-- Sends nothing for a too-short text, a closed house, or a busy throttle.
local function SendSearch()
    local text = strtrim(searchBox:GetText() or "")
    -- A quality or item level filter makes an empty name a real search, as in Blizzard's window.
    if strlenutf8(text) < MIN_SEARCH_LENGTH and not (text == "" and HouseLedgerPrice.FilterActive(filter)) then
        SetStatus("Type at least 2 letters, or pick a quality or item level.")
        return
    end
    if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
        SetStatus("Open the auction house first.")
        return
    end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        SetStatus("The auction house is still busy. Wait, then click Search again.")
        return
    end

    -- One click, one query. No follow-up timer.
    -- The quality filter goes with the search; item level filters the results it brings back.
    local qualities = {}
    for quality = filter.minQuality or 0, #QUALITY_FILTERS - 1 do
        qualities[#qualities + 1] = QUALITY_FILTERS[quality + 1]
    end
    C_AuctionHouse.SendBrowseQuery({
        searchString = text,
        sorts = PRICE_SORT,
        filters = qualities,
    })
    SetStatus(text ~= "" and ("Searching for " .. text .. "...") or "Searching...")
end

--- Ends the scan: back to idle with Scan enabled, and a pending read batch does nothing.
local function StopReading()
    readToken = readToken + 1
    scanState = "idle"
    ShowScanProgress(nil)
    RefreshScanButton()
end

--- Saves a finished read and says how many prices were saved.
-- @param token the read's token; a stale one does nothing
-- @param best the lowest-price table built by PriceLedger.Consider
local function FinishRead(token, best)
    if token ~= readToken or scanState ~= "reading" then
        return
    end
    if next(best) == nil then
        StopReading()
        SetScanStatus("The house sent no listings. Nothing saved.", 8)
        return
    end
    local saved = HouseLedgerPrice.Commit(HouseLedgerDB, scanHouseKey, best, time())
    StopReading()
    if currentTab == MARKET_TAB then
        -- The Market lists come from the scan just saved.
        RefreshMarket()
        RenderRows()
    end
    SetScanStatus(string.format("Saved %d prices (%s).", saved, HouseLedgerPrice.HouseLabel(scanHouseKey)), 8)
end

--- Reads one batch of READ_BATCH replicate listings, then the next on the next frame.
-- Stops if the house closed; saves through FinishRead after the last batch.
-- @param token the read's token; a stale one does nothing
-- @param index first listing to read, from 0
-- @param total how many listings the house sent
-- @param best the lowest-price table so far; changed in place
local function ReadListings(token, index, total, best)
    if token ~= readToken or scanState ~= "reading" then
        return
    end
    if not HouseIsOpen() then
        StopReading()
        SetScanStatus("Scan stopped because the auction house closed. Next scan in 15 min.", 8)
        return
    end

    local last = math.min(index + READ_BATCH - 1, total - 1)
    for i = index, last do
        -- One call. The seller fields come back nil and are not stored.
        -- The item's name and quality are kept; the name is nil for an item the game hasn't loaded.
        local name, _, count, quality, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID =
            C_AuctionHouse.GetReplicateItemInfo(i)
        HouseLedgerPrice.Consider(best, itemID, count, buyout, name, quality)
    end

    local nextIndex = last + 1
    if nextIndex >= total then
        FinishRead(token, best)
        return
    end

    SetScanStatus(string.format("Reading listings %d of %d...", nextIndex, total))
    ShowScanProgress(nextIndex, total)
    C_Timer.After(0, function()
        ReadListings(token, nextIndex, total, best)
    end)
end

--- The full-scan answer came in: starts reading the listings for this house.
local function BeginRead()
    HouseLedgerDB.replicateAt = time()
    scanHouseKey = CurrentScanKey()
    local total = 0
    if C_AuctionHouse.GetNumReplicateItems then
        total = C_AuctionHouse.GetNumReplicateItems() or 0
    end
    scanState = "reading"
    readToken = readToken + 1
    acceptAnswerUntil = 0
    SetScanStatus(string.format("Reading %d listings...", total))
    ShowScanProgress(0, total)
    ReadListings(readToken, 0, total, {})
end

--- Scan click: sends one full-house request, at most once each 15 minutes.
-- Sends nothing while a scan runs, with the house closed, without the scan
-- functions, or during the wait.
local function StartScan()
    if scanState ~= "idle" then
        return
    end
    if not HouseIsOpen() then
        SetScanStatus("Open the auction house first.", 4)
        return
    end
    if C_AuctionHouse.ReplicateItems == nil or C_AuctionHouse.GetReplicateItemInfo == nil then
        SetScanStatus("This client has no full-scan function.", 8)
        return
    end

    local wait = HouseLedgerPrice.SecondsUntil(HouseLedgerDB.replicateAt, time())
    if wait > 0 then
        SetScanStatus("Next scan in " .. RemainingText(wait) .. ".", 4)
        return
    end

    scanState = "waiting"
    waitStarted = Clock()
    if scanButton then
        scanButton:Disable()
    end
    -- One click, one full-house request. No retry timer.
    -- Start the 15 minutes now: the request is out even if no answer comes.
    HouseLedgerDB.replicateAt = time()
    C_AuctionHouse.ReplicateItems()
    SetScanStatus("Asking the auction house for every listing...")
end

--- Adds the saved price lines to an item tooltip.
-- Holding Shift adds the detail lines.
-- @param tooltip the tooltip being built
-- @param data the game's tooltip data, with the item id or hyperlink
local function AddPriceLine(tooltip, data)
    if tooltip == nil or type(tooltip.AddLine) ~= "function" or type(data) ~= "table" then
        return
    end
    local itemID = data.id
    if type(itemID) ~= "number" and type(data.hyperlink) == "string" and type(GetItemInfoInstant) == "function" then
        itemID = GetItemInfoInstant(data.hyperlink)
    end
    local info = HouseLedgerPrice.Lookup(HouseLedgerDB, itemID, PlayerHouseKey())
    if info == nil then
        return
    end
    if not HouseLedgerDB.settings.tooltipPrices then
        return
    end
    -- Shift is read when the tooltip is built: hold it, then hover. A setting can always show them.
    local showDetails = HouseLedgerDB.settings.tooltipDetails
        or (type(IsShiftKeyDown) == "function" and IsShiftKeyDown() == true)
    local lines = HouseLedgerPrice.TooltipLines(info, CopperToText, showDetails)
    if lines == nil then
        return
    end
    -- First line in gold like other price lines; details in light gray.
    tooltip:AddLine(lines[1].left, 1, 0.82, 0, true)
    for index = 2, #lines do
        local line = lines[index]
        if line.right and type(tooltip.AddDoubleLine) == "function" then
            tooltip:AddDoubleLine(line.left, line.right, 0.8, 0.8, 0.8, 1, 1, 1)
        else
            tooltip:AddLine(line.left, 0.8, 0.8, 0.8, true)
        end
    end
end

--- Hooks item tooltips once, through TooltipDataProcessor.
-- @return true when hooked (now or before), false when this client cannot be hooked
local function HookTooltips()
    if tooltipsHooked then
        return true
    end
    if TooltipDataProcessor == nil or type(TooltipDataProcessor.AddTooltipPostCall) ~= "function" then
        return false
    end
    if Enum == nil or Enum.TooltipDataType == nil or Enum.TooltipDataType.Item == nil then
        return false
    end
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, AddPriceLine)
    tooltipsHooked = true
    return true
end

--- Anchors one line of cells, right to left.
-- The order is trend, typical, available, price; then the name fills what is
-- left beside the icon.
-- @param cells { parent, icon?, name, price, avail, typical, trend }
-- @param showTypical false hides the Avg 7d column on a narrow window
local function AnchorCells(cells, showTypical)
    for _, key in ipairs({ "name", "price", "avail", "typical", "trend" }) do
        cells[key]:ClearAllPoints()
    end
    cells.trend:SetPoint("RIGHT", cells.parent, "RIGHT", -4, 0)
    cells.trend:SetWidth(COLUMN_WIDTH.trend)
    local rightOfAvail = cells.trend
    if showTypical then
        cells.typical:SetPoint("RIGHT", cells.trend, "LEFT", -COLUMN_GAP, 0)
        cells.typical:SetWidth(COLUMN_WIDTH.typical)
        cells.typical:Show()
        rightOfAvail = cells.typical
    else
        cells.typical:Hide()
    end
    cells.avail:SetPoint("RIGHT", rightOfAvail, "LEFT", -COLUMN_GAP, 0)
    cells.avail:SetWidth(COLUMN_WIDTH.avail)
    cells.price:SetPoint("RIGHT", cells.avail, "LEFT", -COLUMN_GAP, 0)
    cells.price:SetWidth(COLUMN_WIDTH.price)
    if cells.icon then
        cells.name:SetPoint("LEFT", cells.icon, "RIGHT", 4, 0)
    else
        cells.name:SetPoint("LEFT", cells.parent, "LEFT", 4 + ICON_SIZE + 4, 0)
    end
    cells.name:SetPoint("RIGHT", cells.price, "LEFT", -COLUMN_GAP, 0)
end

--- Makes one single-line text cell.
-- @param parent the frame that owns it
-- @param font a font object name, such as "GameFontNormal"
-- @param justify "LEFT" or "RIGHT"
-- @return the font string
local function Cell(parent, font, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", font)
    text:SetJustifyH(justify)
    -- Each cell has a fixed slot. Long text is cut with "..." instead of
    -- wrapping onto the line below.
    text:SetWordWrap(false)
    return text
end

--- The cells of the header or of a row, in the form AnchorCells takes.
-- @param owner the header frame or a row button
-- @return { parent, icon, name, price, avail, typical, trend }
local function CellsOf(owner)
    return {
        parent = owner,
        icon = owner.icon,
        name = owner.nameText,
        price = owner.priceText,
        avail = owner.availText,
        typical = owner.typicalText,
        trend = owner.trendText,
    }
end

--- Makes one list row, hidden until it has a result.
-- @param list the list frame
-- @param index row number from the top, from 1
-- @return the row button
local function BuildRow(list, index)
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -HEADER_HEIGHT - (index - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.nameText = Cell(row, "GameFontHighlightSmall", "LEFT")
    row.priceText = Cell(row, "GameFontHighlightSmall", "RIGHT")
    row.availText = Cell(row, "GameFontHighlightSmall", "RIGHT")
    row.typicalText = Cell(row, "GameFontHighlightSmall", "RIGHT")
    row.trendText = Cell(row, "GameFontHighlightSmall", "RIGHT")
    -- A click or hover reads saved data and the game's item cache only.
    row:SetScript("OnClick", ShowRowDetails)
    row:SetScript("OnEnter", ShowRowTooltip)
    row:SetScript("OnLeave", HideRowTooltip)
    row:Hide()
    return row
end

--- Makes the column header above the list.
-- @param list the list frame
local function BuildHeader(list)
    header = CreateFrame("Frame", nil, list)
    header:SetHeight(HEADER_HEIGHT)
    header:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
    header:SetPoint("RIGHT", list, "RIGHT", 0, 0)
    header.nameText = Cell(header, "GameFontNormalSmall", "LEFT")
    header.priceText = Cell(header, "GameFontNormalSmall", "RIGHT")
    header.availText = Cell(header, "GameFontNormalSmall", "RIGHT")
    header.typicalText = Cell(header, "GameFontNormalSmall", "RIGHT")
    header.trendText = Cell(header, "GameFontNormalSmall", "RIGHT")
    header.nameText:SetText("Item")
    header.priceText:SetText("Price")
    header.availText:SetText("Avail.")
    header.typicalText:SetText("Avg 7d")
    header.trendText:SetText("Trend")
end

--- Room to the right of the auction house, between the width limits.
-- @return the window width; FRAME_WIDTH_MIN when the edges are not known
local function FrameWidth()
    local screenRight = UIParent and UIParent:GetRight()
    local houseRight = AuctionHouseFrame and AuctionHouseFrame:GetRight()
    if type(screenRight) ~= "number" or type(houseRight) ~= "number" then
        return FRAME_WIDTH_MIN
    end
    local room = math.floor(screenRight - houseRight - PIN_GAP - SCREEN_MARGIN)
    return math.max(FRAME_WIDTH_MIN, math.min(FRAME_WIDTH_MAX, room))
end

--- Lays out the header and every row for a window width.
-- @param width the window width; below TYPICAL_MIN_WIDTH the Avg 7d column is hidden
local function LayoutColumns(width)
    local showTypical = width >= TYPICAL_MIN_WIDTH
    AnchorCells(CellsOf(header), showTypical)
    for _, row in ipairs(rows) do
        AnchorCells(CellsOf(row), showTypical)
    end
    -- The chart beside the details needs the same room as the Avg 7d column.
    buyPanel.chartRoom = showTypical
    if not showTypical then
        buyPanel.chart:Hide()
    end
    for _, line in ipairs(buyPanel.detailLines or {}) do
        line.right:SetPoint("RIGHT", frame, "RIGHT", showTypical and -(CHART_WIDTH + 24) or -16, 0)
    end
end

--- Makes a 14-day chart, hidden until ShowChart fills it: a dark box, the top price in its corner,
-- and two textures per day (the low's bar and the faint range band).
-- @param parent the panel it belongs to
-- @param width the chart's width
-- @param height the chart's height
-- @return the chart frame, with bars, bands, barArea and topText
local function BuildChart(parent, width, height)
    local chart = CreateFrame("Frame", nil, parent)
    chart:SetSize(width, height)
    local background = chart:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(chart)
    background:SetColorTexture(0, 0, 0, 0.3)
    chart.topText = Cell(chart, "GameFontHighlightSmall", "LEFT")
    chart.topText:SetPoint("TOPLEFT", chart, "TOPLEFT", 3, -2)
    local caption = Cell(chart, "GameFontDisableSmall", "RIGHT")
    caption:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -3, -2)
    caption:SetText("Daily low, 14 days")
    -- Room under the top line for the bars.
    chart.barArea = height - 18
    chart.bars, chart.bands = {}, {}
    local slotWidth = width / HouseLedgerPrice.DAYS_KEPT
    for index = 1, HouseLedgerPrice.DAYS_KEPT do
        local bar = chart:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", math.floor((index - 1) * slotWidth) + 1, 2)
        bar:SetWidth(math.max(2, math.floor(slotWidth) - 2))
        bar:Hide()
        local band = chart:CreateTexture(nil, "ARTWORK")
        band:SetWidth(math.max(2, math.floor(slotWidth) - 2))
        band:SetColorTexture(CHART_RANGE_COLOR[1], CHART_RANGE_COLOR[2], CHART_RANGE_COLOR[3], CHART_RANGE_COLOR[4])
        band:Hide()
        chart.bars[index], chart.bands[index] = bar, band
    end
    chart:Hide()
    return chart
end

--- Makes the Sell tab: the item slot, the value lines, a status line and Reset.
local function BuildSellPanel()
    sellPanel = CreateFrame("Frame", nil, frame)
    sellPanel:SetAllPoints(frame)
    frame.sellPanel = sellPanel

    local slot = CreateFrame("Button", nil, sellPanel)
    slot:SetSize(37, 37)
    slot:SetPoint("TOPLEFT", sellPanel, "TOPLEFT", 20, -LIST_TOP - 16)
    local slotBackground = slot:CreateTexture(nil, "BACKGROUND")
    slotBackground:SetTexture(EMPTY_SLOT_TEXTURE)
    slotBackground:SetSize(64, 64)
    slotBackground:SetPoint("CENTER", slot, "CENTER", 0, 0)
    sellPanel.icon = slot:CreateTexture(nil, "ARTWORK")
    sellPanel.icon:SetAllPoints(slot)
    -- Drag an item onto the slot, or pick it up and click the slot.
    slot:SetScript("OnReceiveDrag", DropItem)
    slot:SetScript("OnClick", DropItem)
    sellPanel.slot = slot

    sellPanel.itemName = Cell(sellPanel, "GameFontNormalLarge", "LEFT")
    sellPanel.itemName:SetPoint("LEFT", slot, "RIGHT", 12, 0)
    sellPanel.itemName:SetPoint("RIGHT", sellPanel, "RIGHT", -16, 0)
    sellPanel.itemName:SetText(SELL_PROMPT)

    sellPanel.values = {}
    sellPanel.labels = {}
    for index, line in ipairs(SELL_LINES) do
        local y = -LIST_TOP - 72 - (index - 1) * SELL_LINE_HEIGHT
        local label = Cell(sellPanel, "GameFontNormal", "LEFT")
        label:SetPoint("TOPLEFT", sellPanel, "TOPLEFT", 24, y)
        label:SetWidth(150)
        label:SetText(line[2])
        sellPanel.labels[line[1]] = label
        local value = Cell(sellPanel, "GameFontHighlight", "LEFT")
        value:SetPoint("TOPLEFT", sellPanel, "TOPLEFT", 180, y)
        value:SetPoint("RIGHT", sellPanel, "RIGHT", -16, 0)
        sellPanel.values[line[1]] = value
    end
    sellPanel.chart = BuildChart(sellPanel, SELL_CHART_WIDTH, SELL_CHART_HEIGHT)
    sellPanel.chart:SetPoint("TOPLEFT", sellPanel, "TOPLEFT", 24,
        -LIST_TOP - 72 - #SELL_LINES * SELL_LINE_HEIGHT - 48)
    sellPanel.hint = Cell(sellPanel, "GameFontHighlight", "LEFT")
    sellPanel.hint:SetPoint("TOPLEFT", sellPanel, "TOPLEFT", 24, -LIST_TOP - 72 - #SELL_LINES * SELL_LINE_HEIGHT - 10)
    sellPanel.hint:SetPoint("RIGHT", sellPanel, "RIGHT", -16, 0)
    ClearSellValues()

    sellPanel.statusText = Cell(sellPanel, "GameFontHighlightSmall", "LEFT")
    sellPanel.statusText:SetPoint("BOTTOMLEFT", 14, 30)
    sellPanel.statusText:SetPoint("RIGHT", sellPanel, "RIGHT", -14, 0)
    sellPanel.statusText:SetText(SELL_HELP)

    local reset = CreateFrame("Button", nil, sellPanel, "UIPanelButtonTemplate")
    reset:SetSize(80, 22)
    reset:SetPoint("RIGHT", scanButton, "LEFT", -8, 0)
    reset:SetText("Reset")
    reset:SetScript("OnClick", ResetSell)
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
    local tab = CreateFrame("Button", "HouseLedgerFrameTab" .. id, frame,
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
    local buyTab = BuildTab(BUY_TAB, "Buy")
    buyTab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
    local sellTab = BuildTab(SELL_TAB, "Sell")
    --- One of our own tabs: plain, not linked to Blizzard's window.
    -- @param id the tab's id
    -- @param label the tab's text
    -- @return the tab button
    local function PlainTab(id, label)
        local tab = CreateFrame("Button", "HouseLedgerFrameTab" .. id, frame, "PanelTabButtonTemplate")
        tab:SetID(id)
        tab:SetText(label)
        tab:SetScript("OnClick", function()
            SelectTab(id)
        end)
        return tab
    end
    local marketTab = PlainTab(MARKET_TAB, "Market")
    local settingsTab = PlainTab(SETTINGS_TAB, "Settings")
    frame.Tabs = { buyTab, sellTab, marketTab, settingsTab }
    if type(PanelTemplates_TabResize) == "function" then
        for _, tab in ipairs(frame.Tabs) do
            PanelTemplates_TabResize(tab, 0)
        end
    end
    -- Also anchors each tab to the right of the one before.
    PanelTemplates_SetNumTabs(frame, #frame.Tabs)
    SelectTab(BUY_TAB)
end

--- Makes the Settings tab: one checkbox per PriceLedger.SETTINGS entry, saved in
-- HouseLedgerDB.settings as soon as it is clicked. Nothing is sent.
local function BuildSettingsPanel()
    settingsPanel = CreateFrame("Frame", nil, frame)
    settingsPanel:SetAllPoints(frame)
    settingsPanel:Hide()
    frame.settingsPanel = settingsPanel
    settingsPanel.boxes = {}
    for index, setting in ipairs(HouseLedgerPrice.SETTINGS) do
        local box = CreateFrame("CheckButton", nil, settingsPanel, "UICheckButtonTemplate")
        box:SetSize(26, 26)
        box:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", 20, -LIST_TOP - 12 - (index - 1) * 30)
        box:SetChecked(HouseLedgerDB.settings[setting.key] == true)
        box:SetScript("OnClick", function(self)
            HouseLedgerDB.settings[setting.key] = self:GetChecked() == true
        end)
        local label = Cell(settingsPanel, "GameFontHighlight", "LEFT")
        label:SetPoint("LEFT", box, "RIGHT", 4, 0)
        label:SetPoint("RIGHT", settingsPanel, "RIGHT", -16, 0)
        label:SetText(setting.label)
        settingsPanel.boxes[setting.key] = box
    end
end

--- Makes the filter row: Market's name filter, the quality dropdown and the item level range.
-- Every change filters what is already shown; none sends anything.
local function BuildFilterRow()
    --- A small edit box that filters as the player types.
    -- @param width the box width
    -- @param numeric true for an item level box
    -- @return the edit box
    local function FilterBox(width, numeric)
        local box = CreateFrame("EditBox", nil, buyPanel, "InputBoxTemplate")
        box:SetSize(width, 20)
        box:SetAutoFocus(false)
        if numeric then
            box:SetNumeric(true)
            box:SetMaxLetters(3)
        end
        box:SetScript("OnTextChanged", function(_, userInput)
            if userInput then
                ApplyFilters()
            end
        end)
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        return box
    end

    local nameBox = FilterBox(140, false)
    nameBox:SetPoint("LEFT", frame, "TOPLEFT", 20, FILTER_ROW_Y)
    nameBox:Hide()
    buyPanel.filterNameBox = nameBox

    -- Blizzard's own dropdown, as its auction house filter uses on Forever.
    local quality = CreateFrame("DropdownButton", nil, buyPanel, "WowStyle1DropdownTemplate")
    quality:SetWidth(130)
    quality:SetPoint("LEFT", frame, "TOPLEFT", 14, FILTER_ROW_Y)
    quality:SetupMenu(function(_, root)
        for _, choice in ipairs(HouseLedgerPrice.QUALITY_CHOICES) do
            root:CreateRadio(choice.label, function(picked)
                return filter.minQuality == picked.min
            end, function(picked)
                filter.minQuality = picked.min
                ApplyFilters()
            end, choice)
        end
    end)
    buyPanel.qualityDropdown = quality

    local levelLabel = Cell(buyPanel, "GameFontNormalSmall", "LEFT")
    levelLabel:SetPoint("LEFT", quality, "RIGHT", 12, 0)
    levelLabel:SetText("ilvl")
    local minBox = FilterBox(34, true)
    minBox:SetPoint("LEFT", levelLabel, "RIGHT", 10, 0)
    local dash = Cell(buyPanel, "GameFontHighlightSmall", "LEFT")
    dash:SetPoint("LEFT", minBox, "RIGHT", 2, 0)
    dash:SetText("-")
    local maxBox = FilterBox(34, true)
    maxBox:SetPoint("LEFT", dash, "RIGHT", 8, 0)
    buyPanel.minLevelBox, buyPanel.maxLevelBox = minBox, maxBox
end

--- Makes the HouseLedger window, hidden until the auction house opens.
-- Its OnUpdate times out a scan that got no answer and refreshes the idle
-- scan line once a second.
local function BuildFrame()
    -- Blizzard's panel template: the same frame, title bar, close button
    -- and solid background as the auction house beside it.
    frame = CreateFrame("Frame", "HouseLedgerFrame", UIParent, "ButtonFrameTemplate")
    frame:SetSize(FRAME_WIDTH_MIN, HOUSE_HEIGHT)
    -- Fallback spot. PlaceFrame moves it beside the auction house.
    frame:SetPoint("CENTER")
    -- On a narrow screen the spot beside the house runs off the edge;
    -- the clamp slides it back on screen.
    frame:SetClampedToScreen(true)
    -- Blizzard's auction house is toplevel too, so a click on either
    -- window brings that one to the front.
    frame:SetToplevel(true)
    -- A drag lasts until the house closes. PlaceFrame sets the spot on
    -- every open, so the game's saved-position cache is not used.
    frame:SetDontSavePosition(true)
    if type(frame.SetTitle) == "function" then
        frame:SetTitle("HouseLedger")
    end
    if type(frame.SetPortraitToAsset) == "function" then
        frame:SetPortraitToAsset(PORTRAIT_ICON)
    end
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        -- The window is protected; the game blocks moving it in combat.
        if not InCombat() then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        if InCombat() then
            -- OnCombatEnded stops the move and puts the window back.
            afterCombat = true
        else
            self:StopMovingOrSizing()
        end
    end)
    frame:Hide()

    scanButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    scanButton:SetSize(80, 22)
    scanButton:SetPoint("TOPRIGHT", -10, -30)
    scanButton:SetText("Scan")
    scanButton:SetScript("OnClick", StartScan)

    buyPanel = CreateFrame("Frame", nil, frame)
    buyPanel:SetAllPoints(frame)
    frame.buyPanel = buyPanel

    local button = CreateFrame("Button", nil, buyPanel, "UIPanelButtonTemplate")
    button:SetSize(90, 22)
    button:SetPoint("RIGHT", scanButton, "LEFT", -8, 0)
    button:SetText("Search")
    button:SetScript("OnClick", SendSearch)

    local clear = CreateFrame("Button", nil, buyPanel, "UIPanelButtonTemplate")
    clear:SetSize(70, 22)
    clear:SetPoint("RIGHT", button, "LEFT", -6, 0)
    clear:SetText("Clear")
    clear:SetScript("OnClick", ClearSearch)

    searchBox = CreateFrame("EditBox", nil, buyPanel, "InputBoxTemplate")
    searchBox:SetHeight(20)
    -- Left of 70 clears the round portrait in the corner.
    searchBox:SetPoint("LEFT", frame, "TOPLEFT", 72, -41)
    searchBox:SetPoint("RIGHT", clear, "LEFT", -10, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnEnterPressed", function(box)
        SendSearch()
        box:ClearFocus()
    end)
    buyPanel.searchControls = { searchBox, clear, button }

    -- The Market tab's view switcher, in the search box's place: < Deals at last scan (12 min ago) >
    local marketPrev = CreateFrame("Button", nil, buyPanel, "UIPanelButtonTemplate")
    marketPrev:SetSize(24, 22)
    marketPrev:SetPoint("LEFT", frame, "TOPLEFT", 72, -41)
    marketPrev:SetText("<")
    marketPrev:SetScript("OnClick", function() StepMarket(-1) end)
    local marketNext = CreateFrame("Button", nil, buyPanel, "UIPanelButtonTemplate")
    marketNext:SetSize(24, 22)
    marketNext:SetPoint("RIGHT", scanButton, "LEFT", -8, 0)
    marketNext:SetText(">")
    marketNext:SetScript("OnClick", function() StepMarket(1) end)
    local marketLabel = Cell(buyPanel, "GameFontNormal", "CENTER")
    marketLabel:SetPoint("LEFT", marketPrev, "RIGHT", 6, 0)
    marketLabel:SetPoint("RIGHT", marketNext, "LEFT", -6, 0)
    buyPanel.marketPrev, buyPanel.marketNext, buyPanel.marketLabel = marketPrev, marketNext, marketLabel
    buyPanel.marketControls = { marketPrev, marketNext, marketLabel }
    for _, control in ipairs(buyPanel.marketControls) do
        control:Hide()
    end

    local inset = frame.Inset
    if type(inset) == "table" then
        inset:ClearAllPoints()
        inset:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -LIST_TOP)
        inset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, LIST_BOTTOM)
    end

    local list = CreateFrame("Frame", nil, buyPanel)
    list:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -LIST_TOP - 2 - FILTER_HEIGHT)
    list:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, LIST_BOTTOM + 2)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        Scroll(-delta * WHEEL_STEP)
    end)
    BuildHeader(list)
    buyPanel.priceHeading = header.priceText
    BuildFilterRow()
    for index = 1, VISIBLE_ROWS do
        rows[index] = BuildRow(list, index)
    end
    -- The 14-day chart sits right of the details lines, above the status lines.
    buyPanel.chart = BuildChart(buyPanel, CHART_WIDTH, CHART_HEIGHT)
    buyPanel.chart:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, STATUS_HEIGHT + 4)
    LayoutColumns(FRAME_WIDTH_MIN)

    statusText = buyPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("BOTTOMLEFT", 14, 30)
    statusText:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetWordWrap(false)
    statusText:SetText(BUY_HELP)
    buyPanel.statusText = statusText

    -- The details block, between the list and the status lines.
    buyPanel.detailTitle = Cell(buyPanel, "GameFontNormal", "LEFT")
    buyPanel.detailTitle:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 16, LIST_BOTTOM - 6)
    buyPanel.detailTitle:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
    buyPanel.detailLines = {}
    for index = 1, DETAIL_LINES do
        local y = LIST_BOTTOM - 6 - index * DETAIL_LINE_HEIGHT
        local left = Cell(buyPanel, "GameFontHighlightSmall", "LEFT")
        left:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 24, y)
        left:SetWidth(150)
        local right = Cell(buyPanel, "GameFontHighlightSmall", "LEFT")
        right:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 180, y)
        right:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
        buyPanel.detailLines[index] = { left = left, right = right }
    end
    ClearDetails()

    BuildSellPanel()
    BuildSettingsPanel()
    BuildTabs()

    scanText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    scanText:SetPoint("BOTTOMLEFT", 14, 8)
    scanText:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    scanText:SetJustifyH("LEFT")
    scanText:SetWordWrap(false)
    scanText:SetText("")

    -- A thin gold bar in the gap above the scan line, while a scan's listings are read.
    scanBar = CreateFrame("StatusBar", nil, frame)
    scanBar:SetHeight(4)
    scanBar:SetPoint("BOTTOMLEFT", scanText, "TOPLEFT", 0, 3)
    scanBar:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    scanBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    scanBar:SetStatusBarColor(1, 0.82, 0)
    scanBar:Hide()
    frame.scanBar = scanBar

    local tick = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        if scanState == "waiting" and (Clock() - waitStarted) >= ANSWER_WAIT then
            -- The request may already count. Do not send another one.
            HouseLedgerDB.replicateAt = time()
            acceptAnswerUntil = time() + ANSWER_WAIT
            StopReading()
            SetScanStatus("No answer yet. Next scan in 15 min.", 8)
            return
        end
        tick = tick + elapsed
        if tick < 1 then
            return
        end
        tick = 0
        RefreshIdleScanLine()
        RefreshScanButton()
        if currentTab == MARKET_TAB and buyPanel.marketMode then
            buyPanel.marketLabel:SetText(MarketLabel())
        end
    end)

    RefreshIdleScanLine()
    RefreshScanButton()
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
    if frame == nil or modes == nil then
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
        SelectTab(BUY_TAB)
    end
end

--- Blizzard's Sell window took an item: show it on our Sell tab.
-- The item was dropped on it, or right-clicked from a bag, and Blizzard has
-- sent its own search for it. This shows the item here, and the results
-- events fill in its prices. Nothing is sent.
-- @param _ Blizzard's AuctionHouseFrame, unused
-- @param location the ItemLocation Blizzard was given
local function FollowPostItem(_, location)
    if frame == nil or location == nil then
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
            readKey = AnyVariantKey(itemKey)
        end
    end
    local name = C_Item.GetItemName(location) or "This item"
    StartPendingSell(readKey, name, C_Item.GetItemIcon(location), commodity, true)
    SelectTab(SELL_TAB)
    SetSellStatus("Reading the auction house's prices for " .. name .. "...")
    -- Blizzard's answer may already be in; if not, its results event shows it.
    if commodity then
        if (C_AuctionHouse.GetNumCommoditySearchResults(readKey.itemID) or 0) > 0 then
            OnCommodityResults(readKey.itemID)
        end
    elseif (C_AuctionHouse.GetNumItemSearchResults(readKey) or 0) > 0 then
        OnItemResults(readKey)
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
    if tabsLinked or frame == nil or AuctionHouseFrame == nil or InCombat() then
        return
    end
    local blizzardBuy = AuctionHouseFrame.BuyTab
    local blizzardSell = AuctionHouseFrame.SellTab
    if blizzardBuy == nil or blizzardSell == nil then
        return
    end
    frame.Tabs[BUY_TAB]:SetAttribute("clickbutton", blizzardBuy)
    frame.Tabs[SELL_TAB]:SetAttribute("clickbutton", blizzardSell)
    tabsLinked = true
end

--- Puts HouseLedger beside Blizzard's auction house window, not over it.
-- Blizzard loads that window on its own interaction event, so it may
-- not exist yet when AUCTION_HOUSE_SHOW reaches this addon. In that
-- case the frame keeps its current spot and tries once more next frame.
-- @param isRetry true on the one follow-up attempt, so it never loops
local function PlaceFrame(isRetry)
    if frame == nil then
        return
    end
    if AuctionHouseFrame == nil then
        if not isRetry then
            C_Timer.After(0, function()
                PlaceFrame(true)
            end)
        end
        return
    end
    HookHouse()
    if InCombat() then
        afterCombat = true
        return
    end
    LinkTabs()
    frame:ClearAllPoints()
    -- Top and bottom on the house's right edge: beside it, same height.
    frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", PIN_GAP, 0)
    frame:SetPoint("BOTTOMLEFT", AuctionHouseFrame, "BOTTOMRIGHT", PIN_GAP, 0)
    local width = FrameWidth()
    frame:SetWidth(width)
    LayoutColumns(width)
end

--- The full-scan answer event: reads it if a scan is expecting one.
-- An answer after the house closed is not read; the 15-minute wait starts again.
local function OnReplicateList()
    local expecting = scanState == "waiting" or time() <= acceptAnswerUntil
    if not expecting then
        return
    end
    if not HouseIsOpen() then
        HouseLedgerDB.replicateAt = time()
        acceptAnswerUntil = 0
        if scanState ~= "idle" then
            StopReading()
        end
        SetScanStatus("The house answered after it closed. Next scan in 15 min.", 8)
        return
    end
    BeginRead()
end

--- Says so when mouseover prices could not be hooked on this client.
local function NoteTooltips()
    if not tooltipsHooked then
        SetScanStatus("Mouseover prices are unavailable on this client.", 8)
    end
end

--- Combat ended: catch up on the window changes the game blocked.
local function OnCombatEnded()
    if buildAfterCombat then
        buildAfterCombat = false
        BuildFrame()
        NoteTooltips()
        afterCombat = true
    end
    if frame == nil or not afterCombat then
        return
    end
    afterCombat = false
    frame:StopMovingOrSizing()
    if HouseIsOpen() then
        PlaceFrame(false)
        frame:Show()
        frame:Raise()
        RefreshIdleScanLine()
    else
        frame:Hide()
    end
    SelectTab(currentTab)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
eventFrame:RegisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED")
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
eventFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
eventFrame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
eventFrame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then
            return
        end
        HouseLedgerDB = HouseLedgerPrice.EnsureDB(HouseLedgerDB)
        HookTooltips()
        if C_AuctionHouse == nil then
            return
        end
        if C_AuctionHouse.SendBrowseQuery == nil and C_AuctionHouse.ReplicateItems == nil then
            return
        end
        if InCombat() then
            -- A /reload in combat: the window's tabs are protected, so it
            -- is built once combat ends.
            buildAfterCombat = true
            return
        end
        BuildFrame()
        NoteTooltips()
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        OnCombatEnded()
        return
    end

    if event == "REPLICATE_ITEM_LIST_UPDATE" then
        if HouseLedgerDB == nil then
            return
        end
        OnReplicateList()
        return
    end

    if frame == nil then
        return
    end

    if event == "AUCTION_HOUSE_SHOW" then
        -- Hooks Blizzard's window even in combat; the rest waits for it to end.
        PlaceFrame(false)
        if InCombat() then
            afterCombat = true
            return
        end
        frame:Show()
        frame:Raise()
        RefreshIdleScanLine()
        return
    end

    if event == "AUCTION_HOUSE_CLOSED" then
        if InCombat() then
            afterCombat = true
        else
            frame:Hide()
        end
        if scanState == "waiting" then
            acceptAnswerUntil = time() + ANSWER_WAIT
        end
        if scanState == "waiting" or scanState == "reading" then
            local answered = scanState == "reading"
            StopReading()
            if answered then
                SetScanStatus("Scan stopped because the auction house closed. Next scan in 15 min.", 8)
            else
                SetScanStatus("Scan cancelled. Waiting to see if the house accepted it.", 8)
            end
        end
        return
    end

    if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        ShowResults()
        return
    end

    if event == "ITEM_KEY_ITEM_INFO_RECEIVED" or event == "GET_ITEM_INFO_RECEIVED" then
        -- An item's name, icon, quality or level arrived: filter again and redraw in place.
        -- Items arrive one event each, often many at once, so this waits one frame and does it once.
        if frame == nil or not frame:IsShown() or refilterPending then
            return
        end
        local market = currentTab == MARKET_TAB and buyPanel.marketMode
        if market and event == "GET_ITEM_INFO_RECEIVED" and marketText == "" and not HouseLedgerPrice.FilterActive(filter) then
            return
        end
        if not market and (#results == 0 or event ~= "ITEM_KEY_ITEM_INFO_RECEIVED") then
            return
        end
        refilterPending = true
        C_Timer.After(0, function()
            refilterPending = false
            if currentTab == MARKET_TAB and buyPanel.marketMode then
                RefreshMarket()
            else
                FilterResults()
            end
            RenderRows()
        end)
        return
    end

    if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        OnCommodityResults(arg1)
        return
    end

    if event == "ITEM_SEARCH_RESULTS_UPDATED" then
        OnItemResults(arg1)
    end
end)
