--[[
The Buy and Market tabs: the results list, its column headings and sorting, the filter row,
the clicked row's details, and the one browse query a Search click sends.
]]

local _, ns = ...
local C, ui, state, Price, U, Chart, Buy, Purchase = ns.C, ns.ui, ns.state, ns.Price, ns.U, ns.Chart, ns.Buy,
    ns.Purchase

-- Below this width the Avg 7d column is hidden; a row click still
-- shows the averages in the details block.
local TYPICAL_MIN_WIDTH = 560

-- The filter row's center, below the window's top edge.
local FILTER_ROW_Y = -C.LIST_TOP - 2 - C.FILTER_HEIGHT / 2
local COLUMN_WIDTH = { ilvl = 34, price = 96, avail = 48, typical = 96, trend = 72 }
local COLUMN_GAP = 6
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

-- The Show dropdown's choices: what a Search asks the house for besides the name and quality.
-- Labels stay short enough for the 130 px dropdown (about 12 letters), so none is cut to "...".
local SHOW_CHOICES = {
    { key = "all", label = "Everything" },
    { key = "gear", label = "Gear for me", searching = "Searching gear for this character..." },
    { key = "anygear", label = "Usable gear", searching = "Searching gear for this character..." },
    { key = "recipes", label = "My recipes", searching = "Searching recipes for this character's professions..." },
}

-- The search's page can't show everything: said by the filters and in the status line.
local LOWER_QUALITY_NOTE = "Click Search again to include lower qualities."
local FIRST_RESULTS_NOTE = "These are the first %d results. Add a name or filter to see others."
local DETAIL_HINT = "Click a row for its saved prices over 1, 3, 7 and 14 days."

-- The search results that pass the filters, in the same order.
local shownResults = {}
local scrollOffset = 0

-- The column each list is sorted by, if any ({ key, ascending }); Buy keeps its sort across
-- searches, Market's resets when the view changes.
local buySort = {}

-- The lowest quality the last search asked the house for (0 is every quality). A looser quality
-- filter can't show what that search left out, so the status line says to search again.
local searchedQuality = 0
-- The Show choice's key; "all" until another is picked, and again after Clear.
local showKey = "all"
-- The Market tab's rows (shaped like browse results), how far they're scrolled, and the
-- PriceLedger.Market lists, kept until the house has a newer scan.
local marketList = {}
local marketOffset = 0
local marketCache
-- The overview chart's left edge from the window's left, clear of its text lines (an average
-- like "(avg 5,799)" ends near 365 in game), and its height, leaving a gap under the list.
local OVERVIEW_LEFT = 380
local OVERVIEW_HEIGHT = 80
-- True while the details block shows the house overview, and the overview kept until the house
-- has a newer scan or the history length changes.
local overviewShown = false
local overviewCache
-- True while the details block shows a clicked row's prices, and that row's result (marked in
-- gold in the list, with its Buy button).
local rowShown = false
local pickedResult

--- Marks the picked row in gold, and puts the Buy button on it (Purchase.PlaceRowButtons).
local function MarkPicked()
    for _, row in ipairs(ui.rows) do
        U.MarkRow(row, row.result ~= nil and U.SameItemKey(row.result, pickedResult))
    end
    Purchase.PlaceRowButtons()
end

--- Sets the Buy tab's status line, once the window is built.
-- @param text the line's text
local function SetStatus(text)
    if ui.statusText then
        ui.statusText:SetText(text)
    end
end

--- Shows a message in large text in the middle of the Buy list, where an empty list draws the
-- eye; nil hides it.
-- @param text the message, or nil
local function SetListMessage(text)
    if ui.buyPanel and ui.buyPanel.listMessage then
        ui.buyPanel.listMessage:SetText(text or "")
        if text then ui.buyPanel.listMessage:Show() else ui.buyPanel.listMessage:Hide() end
    end
end
Buy.SetListMessage = SetListMessage

-- Recent searches: a list under the Buy search box of what was searched before (saved in
-- HouseLedgerDB.recentSearches), filtered as you type. Picking one searches it: one click, or one
-- Enter press, sends one search. Typing and the arrow keys send nothing.
local recent = { buttons = {}, matches = {}, selected = 0 }
local RECENT_ROW_HEIGHT = 18

--- Hides the recent-searches list and stops listening for clicks elsewhere.
local function HideRecent()
    recent.selected = 0
    if recent.frame and recent.frame:IsShown() then
        recent.frame:Hide()
        recent.frame:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end
end
Buy.HideRecent = HideRecent

--- Writes the matching searches into the list's lines, the one picked with the arrow keys marked.
local function DrawRecent()
    for index, button in ipairs(recent.buttons) do
        local text = recent.matches[index]
        button.searchText = text
        if text then
            button.label:SetText(text)
            U.MarkRow(button, index == recent.selected)
            button:Show()
        else
            button:Hide()
        end
    end
end

--- Shows the recent searches that match the search box, or hides the list when none do.
local function ShowRecent()
    if recent.frame == nil or ui.buyPanel.marketMode then
        return
    end
    recent.matches = Price.MatchRecent(HouseLedgerDB.recentSearches, ui.searchBox:GetText())
    if #recent.matches == 0 then
        HideRecent()
        return
    end
    if recent.selected > #recent.matches then
        recent.selected = 0
    end
    DrawRecent()
    recent.frame:SetHeight(#recent.matches * RECENT_ROW_HEIGHT + 30)
    recent.frame:Show()
    -- Blizzard's own menus close the same way: any click outside them.
    recent.frame:RegisterEvent("GLOBAL_MOUSE_DOWN")
end

--- Puts a recent search in the box and searches it: the player's click or Enter press.
-- @param text the search
local function PickRecent(text)
    ui.searchBox:SetText(text)
    HideRecent()
    ui.searchBox:ClearFocus()
    Buy.SendSearch()
end

--- Up and Down: moves the mark through the list, and past either end back to what was typed.
-- @param step -1 for up, 1 for down
local function MoveRecent(step)
    if not recent.frame:IsShown() then
        ShowRecent()
        return
    end
    recent.selected = (recent.selected + step) % (#recent.matches + 1)
    DrawRecent()
end

--- Makes the recent-searches list under the search box and gives the box its keys: the list
-- opens when the box is clicked, filters as you type, Up and Down pick, Enter searches the
-- picked one (or what was typed), Escape or a click elsewhere closes it.
function Buy.BuildRecent()
    local box = ui.searchBox
    local frame = CreateFrame("Frame", nil, ui.buyPanel, "TooltipBackdropTemplate")
    frame:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, 0)
    frame:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, 0)
    frame:SetFrameStrata("DIALOG")
    -- The whole list takes the mouse, so a click between its lines never reaches the rows or
    -- the Buy button under it.
    frame:EnableMouse(true)
    frame:Hide()
    frame:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" and not self:IsMouseOver() and not box:IsMouseOver() then
            HideRecent()
        end
    end)
    for index = 1, Price.RECENT_SHOWN do
        local button = CreateFrame("Button", nil, frame)
        button:SetHeight(RECENT_ROW_HEIGHT)
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -6 - (index - 1) * RECENT_ROW_HEIGHT)
        button:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.label:SetPoint("LEFT", button, "LEFT", 4, 0)
        button.label:SetPoint("RIGHT", button, "RIGHT", -4, 0)
        button.label:SetJustifyH("LEFT")
        button.label:SetWordWrap(false)
        U.AddSelection(button)
        button:SetScript("OnClick", function(self, mouseButton)
            if mouseButton == "RightButton" then
                HouseLedgerDB.recentSearches = Price.ForgetRecent(HouseLedgerDB.recentSearches, self.searchText)
                recent.selected = 0
                ShowRecent()
            else
                PickRecent(self.searchText)
            end
        end)
        recent.buttons[index] = button
    end
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 7)
    hint:SetText("Recent searches. Right-click one to forget it.")
    recent.frame = frame
    frame.lines = recent.buttons
    ui.buyPanel.recentList = frame

    -- The arrow keys reach the box's OnArrowPressed only with this off.
    box:SetAltArrowKeyMode(false)
    box:HookScript("OnEditFocusGained", ShowRecent)
    box:HookScript("OnEditFocusLost", function()
        if not frame:IsMouseOver() then
            HideRecent()
        end
    end)
    box:HookScript("OnTextChanged", function(self, userInput)
        -- Only the player's typing filters; text put in by a pick doesn't.
        if userInput then
            recent.selected = 0
            if self:HasFocus() then
                ShowRecent()
            end
        end
    end)
    box:SetScript("OnArrowPressed", function(_, key)
        if key == "UP" then
            MoveRecent(-1)
        elseif key == "DOWN" then
            MoveRecent(1)
        end
    end)
    box:HookScript("OnEscapePressed", HideRecent)
    box:SetScript("OnEnterPressed", function(self)
        local picked = frame:IsShown() and recent.matches[recent.selected]
        if picked then
            PickRecent(picked)
            return
        end
        HideRecent()
        Buy.SendSearch()
        self:ClearFocus()
    end)
end

--- Shows a note in orange beside the filters, for something the player needs to act on; nil
-- hides it.
-- @param text the note, or nil
local function SetNotice(text)
    if ui.buyPanel and ui.buyPanel.notice then
        ui.buyPanel.notice:SetText(text or "")
        if text then ui.buyPanel.notice:Show() else ui.buyPanel.notice:Hide() end
    end
end

--- Lights up the Search button while a new search would show more, or turns that off.
-- @param on true to light it
local function HighlightSearch(on)
    local button = ui.buyPanel and ui.buyPanel.searchButton
    if button then
        if on then button:LockHighlight() else button:UnlockHighlight() end
    end
end

--- Fills one list row from a browse result and shows it.
-- The trend and deal mark judge the live price against the saved stats.
-- @param row a row button from BuildRow
-- @param result one entry of C_AuctionHouse.GetBrowseResults
local function FillRow(row, result)
    local name, icon, quality = U.ItemLook(result.itemKey, result)
    row.result = result
    row.nameText:SetText(name)
    local r, g, b = 1, 1, 1
    -- The game rejects anything but a real quality, such as a scan's -1 for "not known yet".
    if Price.IsQuality(quality) and C_Item and type(C_Item.GetItemQualityColor) == "function" then
        r, g, b = C_Item.GetItemQualityColor(quality)
    end
    row.nameText:SetTextColor(r, g, b)
    row.icon:SetTexture(icon)
    row.ilvlText:SetText(tostring(U.RowLevel(result) or ""))
    row.priceText:SetText(U.CopperToText(result.minPrice))
    row.availText:SetText(tostring(result.totalQuantity or 0))

    local stats = U.SavedStats(result.itemKey and result.itemKey.itemID)
    row.typicalText:SetText(stats and stats.typical and U.CopperToText(stats.typical) or "-")
    -- Judge the live price, not the last scan's: that is what you would pay.
    local verdict = Price.Judge(stats, result.minPrice)
    local mark = Price.TrendText(verdict, "buyer")
    if mark == "" then
        mark = Price.SteadyText(verdict)
    end
    if verdict.deal then
        mark = mark .. " " .. Price.DEAL_ICON
    end
    row.trendText:SetText(mark)
    U.MarkRow(row, U.SameItemKey(result, pickedResult))
    row:Show()
end

--- The list the Buy panel shows now: the Market list on the Market tab, else the search results.
-- @return the list, and its scroll offset
local function ActiveList()
    if state.currentTab == C.MARKET_TAB then
        return marketList, marketOffset
    end
    return shownResults, scrollOffset
end

--- A row's value in one column, for sorting. Reads saved data and the game's item data only.
-- @param result a search result or a Market row
-- @param key the column: name, ilvl, price, avail, typical or trend
-- @return a number or lowercase name, or nil when not known
local function SortValue(result, key)
    if key == "name" then
        local name = U.ItemLook(result.itemKey, result)
        return name and name:lower()
    elseif key == "ilvl" then
        return U.RowLevel(result)
    elseif key == "price" then
        return result.minPrice
    elseif key == "avail" then
        return result.totalQuantity
    end
    if result.market then
        return key == "typical" and result.typical or result.trendPct
    end
    local stats = U.SavedStats(result.itemKey and result.itemKey.itemID)
    if key == "typical" then
        return stats and stats.typical
    end
    return Price.Judge(stats, result.minPrice).trendPct
end

--- A list sorted by the chosen column, keeping its "filtered from" count; as it was without one.
-- @param list the rows to sort
-- @param sort { key, ascending }
-- @return the sorted list
local function Sorted(list, sort)
    if sort.key == nil then
        return list
    end
    local sorted = Price.SortList(list, function(result)
        return SortValue(result, sort.key)
    end, sort.ascending)
    sorted.from = list.from
    return sorted
end

--- Keeps the search results that pass the quality and item level filters, using each result's
-- own item level. Reads what the search brought back; sends nothing.
function Buy.FilterResults()
    shownResults = {}
    local check = Price.FilterActive(state.filter)
    for _, result in ipairs(state.results) do
        local name, _, quality = U.ItemLook(result.itemKey, result)
        local level = result.itemKey and result.itemKey.itemLevel
        if not check or Price.PassesFilter({ name = name, quality = quality, level = level }, state.filter) then
            shownResults[#shownResults + 1] = result
        end
    end
    shownResults.from = #state.results
    shownResults = Sorted(shownResults, buySort)
end

--- Rebuilds the Market rows for the chosen view. The three lists are worked out once per scan.
-- Reads saved data only.
function Buy.RefreshMarket()
    local house = U.MarketHouse()
    if marketCache == nil or marketCache.house ~= house or marketCache.scannedAt ~= (house and house.scannedAt) then
        marketCache = Price.Market(house)
        marketCache.house = house
    end
    marketList = {}
    local view = marketCache[C.MARKET_VIEWS[state.marketView].key]
    local limits = { text = state.marketText, minQuality = state.filter.minQuality, minLevel = state.filter.minLevel,
        maxLevel = state.filter.maxLevel }
    local check = limits.text ~= "" or Price.FilterActive(limits)
    local needs = { name = limits.text ~= "", quality = limits.minQuality ~= nil,
        level = limits.minLevel ~= nil or limits.maxLevel ~= nil }
    for _, entry in ipairs(view) do
        if not check or Price.PassesFilter(U.SavedItemLook(entry, needs), limits) then
            marketList[#marketList + 1] = {
                itemKey = U.SavedItemKey(entry.itemID), minPrice = entry.unit, totalQuantity = entry.qty,
                savedName = entry.name, savedQuality = entry.quality, market = true,
                typical = entry.typical, trendPct = entry.trendPct,
            }
        end
    end
    marketList.from = #view
    marketList = Sorted(marketList, state.marketSort)
    marketOffset = math.min(marketOffset, math.max(0, #marketList - C.VISIBLE_ROWS))
end

--- The text beside the Market view dropdown: how old the scan is.
-- @return text like "at last scan (12 min ago)", or "" before any scan
function Buy.MarketLabel()
    local scannedAt = marketCache and marketCache.scannedAt
    if scannedAt == nil then
        return ""
    end
    return "at last scan (" .. U.AgoText(math.max(0, time() - scannedAt)) .. ")"
end

--- The status line for an empty Market view.
-- @return the text
local function MarketEmptyText()
    if marketCache == nil or marketCache.scannedAt == nil then
        return "No prices saved yet. Click Scan once."
    end
    return string.format(C.MARKET_VIEWS[state.marketView].empty, Price.DEAL_MIN_SCANS + 1)
end

--- Draws the visible rows from the active list at its scroll offset.
-- Also sets the status line to the range shown, or says the list is empty.
function Buy.RenderRows()
    if Purchase.IsOpen() then
        Purchase.Render()
        return
    end
    local list, offset = ActiveList()
    local market = state.currentTab == C.MARKET_TAB
    for index = 1, C.VISIBLE_ROWS do
        local result = list[offset + index]
        if result then
            FillRow(ui.rows[index], result)
        else
            ui.rows[index].result = nil
            ui.rows[index]:Hide()
        end
    end
    if market then
        ui.buyPanel.marketLabel:SetText(Buy.MarketLabel())
    end
    local from = list.from or #list
    -- What the search's page can't show: qualities it didn't ask for, or more on the house. The
    -- first one also shows in orange beside the filters, and lights up Search when a new search
    -- would bring more.
    local notes = {}
    local lowerQuality = not market and (state.filter.minQuality or 0) < searchedQuality
    if lowerQuality then
        notes[#notes + 1] = LOWER_QUALITY_NOTE
    end
    if not market and type(C_AuctionHouse.HasFullBrowseResults) == "function"
        and not C_AuctionHouse.HasFullBrowseResults() then
        notes[#notes + 1] = string.format(FIRST_RESULTS_NOTE, #state.results)
    end
    SetNotice(notes[1])
    if not market then
        HighlightSearch(lowerQuality)
    end
    local noteText = #notes > 0 and (" " .. table.concat(notes, " ")) or ""
    if #list == 0 then
        if from > 0 then
            SetListMessage(market and "Nothing matches the filters." or "Nothing on this page matches the filters.")
            SetStatus(string.format(market and "Nothing matches the filters (%d hidden)."
                or "Nothing on this page matches the filters (%d hidden).", from) .. noteText)
        else
            local empty = market and MarketEmptyText() or "No results."
            SetListMessage(empty)
            SetStatus(empty)
        end
        return
    end
    SetListMessage(nil)
    Purchase.PlaceRowButtons()
    local last = math.min(#list, offset + C.VISIBLE_ROWS)
    local filtered = from > #list and string.format(" (filtered from %d)", from) or ""
    if market then
        SetStatus(string.format("Showing %d-%d of %d %s%s.", offset + 1, last, #list,
            C.MARKET_VIEWS[state.marketView].noun, filtered))
        return
    end
    SetStatus(string.format("Showing %d-%d of %d%s.", scrollOffset + 1, last, #list, filtered) .. noteText)
end

--- Empties the details block under the list: the hint, no lines, no chart.
local function EmptyDetails()
    overviewShown, rowShown, pickedResult = false, false, nil
    Purchase.SetPicked(nil)
    MarkPicked()
    ui.buyPanel.detailTitle:SetText(DETAIL_HINT)
    for _, line in ipairs(ui.buyPanel.detailLines) do
        line.left:SetText("")
        line.right:SetText("")
    end
    ui.buyPanel.chart:Hide()
    ui.buyPanel.overviewChart:Hide()
end

--- Fills the details block with the house overview: items listed each day, its trend and the
-- day's totals, with the overview chart when the window is wide enough. Before any scan it keeps
-- the hint. Reads saved data only.
function Buy.ShowOverview()
    EmptyDetails()
    local house = U.MarketHouse()
    if house == nil then
        return
    end
    local cache = overviewCache
    if cache == nil or cache.house ~= house or cache.scannedAt ~= house.scannedAt or cache.days ~= Price.DAYS_KEPT then
        cache = { house = house, scannedAt = house.scannedAt, days = Price.DAYS_KEPT,
            overview = Price.HouseOverview(house) }
        overviewCache = cache
    end
    if cache.overview == nil then
        return
    end
    overviewShown = true
    local title, lines = Price.OverviewLines(cache.overview, U.CopperToText)
    ui.buyPanel.detailTitle:SetText(title)
    for index, line in ipairs(ui.buyPanel.detailLines) do
        line.left:SetText(lines[index] and lines[index].left or "")
        line.right:SetText(lines[index] and lines[index].right or "")
    end
    if ui.buyPanel.chartRoom then
        Chart.ShowOverview(ui.buyPanel.overviewChart, cache.overview)
    end
end

--- Shows the overview again unless a clicked row's prices or Market are showing: after a scan
-- saved new data, or when the auction house opens (its house may differ from the last one).
function Buy.RefreshOverview()
    if not rowShown and not ui.buyPanel.marketMode then
        Buy.ShowOverview()
    end
end

--- Clears a picked row from the details block: the house overview on Buy, the hint on Market.
function Buy.ClearDetails()
    if ui.buyPanel.marketMode then
        EmptyDetails()
    else
        Buy.ShowOverview()
    end
end

--- Reads the new browse results, scrolls to the top and draws them.
function Buy.ShowResults()
    state.results = C_AuctionHouse.GetBrowseResults() or {}
    Buy.FilterResults()
    scrollOffset = 0
    if state.currentTab == C.MARKET_TAB or Purchase.IsOpen() then
        -- Kept for when the Buy tab opens again, or Back leaves an item's listings (a search in
        -- Blizzard's window brings results too).
        return
    end
    -- The clicked row may not be in the new list.
    Buy.ClearDetails()
    Buy.RenderRows()
end

--- Mouse wheel over the list.
-- Moves through results already received.
-- @param rowsDown rows to move; negative moves up. Clamped to the list.
function Buy.Scroll(rowsDown)
    if Purchase.IsOpen() then
        Purchase.Scroll(rowsDown)
        return
    end
    local list, current = ActiveList()
    local maxOffset = math.max(0, #list - C.VISIBLE_ROWS)
    local offset = math.min(maxOffset, math.max(0, current + rowsDown))
    if offset == current then
        return
    end
    if state.currentTab == C.MARKET_TAB then
        marketOffset = offset
    else
        scrollOffset = offset
    end
    Buy.RenderRows()
end

--- A row click: its saved stats in the details block, and the Listings button for it. While an
-- item's listings show, the click picks a listing instead (Purchase.PickRow).
-- Reads saved data only; the house is not asked anything.
-- @param row the clicked row button
local function ShowRowDetails(row)
    if Purchase.IsOpen() then
        Purchase.PickRow(row)
        return
    end
    if row.result == nil then
        return
    end
    EmptyDetails()
    rowShown, pickedResult = true, row.result
    Purchase.SetPicked(row.result)
    MarkPicked()
    local name = U.ItemLook(row.result.itemKey, row.result)
    local stats = U.SavedStats(row.result.itemKey and row.result.itemKey.itemID)
    if stats == nil then
        ui.buyPanel.detailTitle:SetText(name .. ": no saved prices yet. Click Scan.")
        return
    end
    ui.buyPanel.detailTitle:SetText(name .. ", " .. Price.CountText(stats))
    if ui.buyPanel.chartRoom then
        Chart.Show(ui.buyPanel.chart, Price.Lookup(HouseLedgerDB, row.result.itemKey.itemID, U.ViewHouseKey()))
    end
    local lines = Price.WindowLines(stats, U.CopperToText) or {}
    for index, line in ipairs(ui.buyPanel.detailLines) do
        local source = lines[index]
        line.left:SetText(source and source.left or "")
        line.right:SetText(source and source.right or "")
    end
end

--- Writes the column headings: Market's price is "Scanned", and the sorted column gets an arrow.
function Buy.RefreshHeader()
    local sort = state.currentTab == C.MARKET_TAB and state.marketSort or buySort
    for key, text in pairs(ui.buyPanel.headerTexts) do
        local label = C.HEADER_LABELS[key]
        if key == "price" and ui.buyPanel.marketMode then
            label = "Scanned"
        end
        if sort.key == key then
            label = label .. " |A:" .. (sort.ascending and "NPE_ArrowUp" or "NPE_ArrowDown") .. ":10:10|a"
        end
        text:SetText(label)
    end
end

--- A column heading click: sorts the list by it, or reverses the sort when it is already sorted
-- by it. Reorders what is already here; sends nothing.
-- @param key the column
local function SortByColumn(key)
    if Purchase.IsOpen() then
        return -- listings are always cheapest first
    end
    local market = state.currentTab == C.MARKET_TAB
    local sort = market and state.marketSort or buySort
    if sort.key == key then
        sort.ascending = not sort.ascending
    else
        sort.key, sort.ascending = key, C.SORT_FIRST_ASCENDING[key]
    end
    if market then
        marketOffset = 0
        Buy.RefreshMarket()
    else
        scrollOffset = 0
        Buy.FilterResults()
    end
    Buy.RefreshHeader()
    Buy.RenderRows()
end

--- Switches the Buy panel between its search (Buy tab) and the Market tab.
-- On Market the search box, Clear and Search hide and the view switcher shows in their place;
-- both share the list, its rows and the details block. Nothing is sent either way.
-- @param market true for the Market tab
function Buy.SetMarketMode(market)
    ui.buyPanel.marketMode = market
    HideRecent()
    for _, control in ipairs(ui.buyPanel.searchControls) do
        if market then control:Hide() else control:Show() end
    end
    for _, control in ipairs(ui.buyPanel.marketControls) do
        if market then control:Show() else control:Hide() end
    end
    -- Market's name filter takes the start of the filter row; Buy's name is its search box.
    local quality = ui.buyPanel.qualityDropdown
    quality:ClearAllPoints()
    if market then
        ui.buyPanel.filterNameBox:Show()
        quality:SetPoint("LEFT", ui.buyPanel.filterNameBox, "RIGHT", 10, 0)
    else
        ui.buyPanel.filterNameBox:Hide()
        quality:SetPoint("LEFT", ui.frame, "TOPLEFT", 14, FILTER_ROW_Y)
    end
    -- The note sits after the last control that shows: Show on Buy, the item level on Market.
    local notice = ui.buyPanel.notice
    notice:ClearAllPoints()
    notice:SetPoint("LEFT", market and ui.buyPanel.maxLevelBox or ui.buyPanel.showDropdown, "RIGHT", 12, 0)
    notice:SetPoint("RIGHT", ui.frame, "RIGHT", -14, 0)
    Buy.ClearDetails()
    Buy.RefreshHeader()
    if market then
        Buy.RefreshMarket()
        Buy.RenderRows()
    elseif #state.results > 0 then
        Buy.FilterResults()
        Buy.RenderRows()
    else
        for _, row in ipairs(ui.rows) do
            row.result = nil
            row:Hide()
        end
        SetNotice(nil)
        SetListMessage(C.BUY_START)
        SetStatus(C.BUY_HELP)
    end
end

--- After a filter changed: filters the open list again from what is already here. Sends nothing.
local function ApplyFilters()
    state.filter.minLevel = Price.ParseLevel(ui.buyPanel.minLevelBox:GetText())
    state.filter.maxLevel = Price.ParseLevel(ui.buyPanel.maxLevelBox:GetText())
    state.marketText = strtrim(ui.buyPanel.filterNameBox:GetText() or "")
    if state.currentTab == C.MARKET_TAB then
        marketOffset = 0
        Buy.RefreshMarket()
    else
        scrollOffset = 0
        Buy.FilterResults()
        if #state.results == 0 then
            return
        end
    end
    Buy.ClearDetails()
    Buy.RenderRows()
end

--- Market's view dropdown: shows Deals, Biggest drops or Biggest rises.
-- @param view the index in MARKET_VIEWS
function Buy.SetMarketView(view)
    Purchase.Close()
    state.marketView = view
    marketOffset = 0
    -- Each view has its own order (biggest move first); a column sort starts over.
    state.marketSort.key = nil
    Buy.RefreshHeader()
    Buy.RefreshMarket()
    Buy.ClearDetails()
    Buy.RenderRows()
end

--- Clear on the Buy tab: empties the search box and the list.
-- The house is not asked anything; a result that still arrives shows as usual.
function Buy.ClearSearch()
    Purchase.Close()
    HideRecent()
    ui.searchBox:SetText("")
    ui.searchBox:ClearFocus()
    state.results = {}
    shownResults = {}
    scrollOffset = 0
    -- Clear starts over: the quality and item level filters go back to none too.
    state.filter.minQuality, state.filter.minLevel, state.filter.maxLevel = nil, nil, nil
    ui.buyPanel.minLevelBox:SetText("")
    ui.buyPanel.maxLevelBox:SetText("")
    showKey = "all"
    for _, dropdown in ipairs({ ui.buyPanel.qualityDropdown, ui.buyPanel.showDropdown }) do
        if type(dropdown.GenerateMenu) == "function" then
            dropdown:GenerateMenu() -- shows "Any quality" and "Everything" on the buttons again
        end
    end
    searchedQuality = 0
    for _, row in ipairs(ui.rows) do
        row.result = nil
        row:Hide()
    end
    Buy.ClearDetails()
    SetNotice(nil)
    HighlightSearch(false)
    SetListMessage(C.BUY_START)
    SetStatus(C.BUY_HELP)
end

--- Search click or Enter: sends one browse query for the search box text.
-- Sends nothing for a too-short text, a closed house, or a busy throttle.
function Buy.SendSearch()
    local text = strtrim(ui.searchBox:GetText() or "")
    -- A quality filter makes an empty name a real search, as in Blizzard's window. Item level
    -- alone doesn't: it only filters the page that comes back, so the house would send its first
    -- page of everything.
    --- Says why nothing was sent: in the status line, beside the filters, and in the list if empty.
    -- @param why the reason
    local function Refuse(why)
        SetStatus(why)
        SetNotice(why)
        if #shownResults == 0 then
            SetListMessage(why)
        end
    end
    if strlenutf8(text) < C.MIN_SEARCH_LENGTH and not (text == "" and (state.filter.minQuality or showKey ~= "all")) then
        Refuse("Type at least 2 letters, or pick a quality.")
        return
    end
    -- Show: gear this character wears best or can use at all (the house's own usable-only filter
    -- does the class and level check), or recipes for its professions.
    local classes, usable, searching
    if showKey == "gear" then
        local best
        classes, best = U.BestGearFilters()
        if best then
            searching = "Searching weapons and " .. best:lower() .. " armor for this character..."
        end
    end
    if showKey == "gear" or showKey == "anygear" then
        classes = classes or { { classID = Enum.ItemClass.Weapon }, { classID = Enum.ItemClass.Armor } }
        usable = true
    elseif showKey == "recipes" then
        classes = {}
        for _, subclass in ipairs(U.RecipeSubclasses()) do
            classes[#classes + 1] = { classID = Enum.ItemClass.Recipe, subClassID = subclass }
        end
        if #classes == 0 then
            Refuse("This character has no profession with recipes.")
            return
        end
    end
    if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
        Refuse("Open the auction house first.")
        return
    end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        Refuse("The auction house is still busy. Wait, then click Search again.")
        return
    end
    SetNotice(nil)
    Purchase.Close()

    -- One click, one query. No follow-up timer.
    -- The quality filter goes with the search; item level filters the results it brings back.
    local qualities = {}
    for quality = state.filter.minQuality or 0, #QUALITY_FILTERS - 1 do
        qualities[#qualities + 1] = QUALITY_FILTERS[quality + 1]
    end
    if usable then
        qualities[#qualities + 1] = Enum.AuctionHouseFilter.UsableOnly
    end
    C_AuctionHouse.SendBrowseQuery({
        searchString = text,
        sorts = PRICE_SORT,
        filters = qualities,
        itemClassFilters = classes,
    })
    searchedQuality = state.filter.minQuality or 0
    -- Only a search that went out is remembered.
    if text ~= "" then
        HouseLedgerDB.recentSearches = Price.AddRecent(HouseLedgerDB.recentSearches, text)
    end
    HideRecent()
    for _, choice in ipairs(SHOW_CHOICES) do
        if choice.key == showKey and searching == nil then
            searching = choice.searching
        end
    end
    searching = searching or "Searching..."
    SetStatus(text ~= "" and ("Searching for " .. text .. "...") or searching)
end

--- Anchors one line of cells, right to left.
-- The order is trend, typical, available, price; then the name fills what is
-- left beside the icon.
-- @param cells { parent, icon?, name, price, avail, typical, trend }
-- @param showTypical false hides the Avg 7d column on a narrow window
local function AnchorCells(cells, showTypical)
    for _, key in ipairs({ "name", "ilvl", "price", "avail", "typical", "trend" }) do
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
    cells.ilvl:SetPoint("RIGHT", cells.price, "LEFT", -COLUMN_GAP, 0)
    cells.ilvl:SetWidth(COLUMN_WIDTH.ilvl)
    if cells.icon then
        cells.name:SetPoint("LEFT", cells.icon, "RIGHT", 4, 0)
    else
        cells.name:SetPoint("LEFT", cells.parent, "LEFT", 4 + C.ICON_SIZE + 4, 0)
    end
    cells.name:SetPoint("RIGHT", cells.ilvl, "LEFT", -COLUMN_GAP, 0)
end

--- Makes one list row, hidden until it has a result.
-- @param list the list frame
-- @param index row number from the top, from 1
-- @return the row button
function Buy.BuildRow(list, index)
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(C.ROW_HEIGHT)
    row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -C.HEADER_HEIGHT - (index - 1) * C.ROW_HEIGHT)
    row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    U.AddSelection(row)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(C.ICON_SIZE, C.ICON_SIZE)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.nameText = U.Cell(row, "GameFontHighlightSmall", "LEFT")
    row.ilvlText = U.Cell(row, "GameFontHighlightSmall", "RIGHT")
    row.priceText = U.Cell(row, "GameFontHighlightSmall", "RIGHT")
    row.availText = U.Cell(row, "GameFontHighlightSmall", "RIGHT")
    row.typicalText = U.Cell(row, "GameFontHighlightSmall", "RIGHT")
    row.trendText = U.Cell(row, "GameFontHighlightSmall", "RIGHT")
    -- A click or hover reads saved data and the game's item cache only.
    row:SetScript("OnClick", ShowRowDetails)
    row:SetScript("OnEnter", U.ShowRowTooltip)
    row:SetScript("OnLeave", U.HideRowTooltip)
    row:Hide()
    return row
end

--- Makes the column header above the list.
-- @param list the list frame
function Buy.BuildHeader(list)
    ui.header = CreateFrame("Frame", nil, list)
    ui.header:SetHeight(C.HEADER_HEIGHT)
    ui.header:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
    ui.header:SetPoint("RIGHT", list, "RIGHT", 0, 0)
    ui.header.nameText = U.Cell(ui.header, "GameFontNormalSmall", "LEFT")
    ui.header.ilvlText = U.Cell(ui.header, "GameFontNormalSmall", "RIGHT")
    ui.header.priceText = U.Cell(ui.header, "GameFontNormalSmall", "RIGHT")
    ui.header.availText = U.Cell(ui.header, "GameFontNormalSmall", "RIGHT")
    ui.header.typicalText = U.Cell(ui.header, "GameFontNormalSmall", "RIGHT")
    ui.header.trendText = U.Cell(ui.header, "GameFontNormalSmall", "RIGHT")
    ui.header.texts = {
        name = ui.header.nameText, ilvl = ui.header.ilvlText, price = ui.header.priceText,
        avail = ui.header.availText, typical = ui.header.typicalText, trend = ui.header.trendText,
    }
    -- Each heading is a button over its text: a click sorts the list by that column.
    ui.header.sortButtons = {}
    for _, key in ipairs(C.SORT_KEYS) do
        local text = ui.header.texts[key]
        text:SetText(C.HEADER_LABELS[key])
        local button = CreateFrame("Button", nil, ui.header)
        button:SetPoint("TOPLEFT", text, "TOPLEFT", -2, 4)
        button:SetPoint("BOTTOMRIGHT", text, "BOTTOMRIGHT", 2, -4)
        button:SetScript("OnClick", function()
            SortByColumn(key)
        end)
        ui.header.sortButtons[key] = button
    end
end

--- Lays out the header and every row for a window width.
-- @param width the window width; below TYPICAL_MIN_WIDTH the Avg 7d column is hidden
function Buy.LayoutColumns(width)
    local showTypical = width >= TYPICAL_MIN_WIDTH
    AnchorCells(U.CellsOf(ui.header), showTypical)
    for _, row in ipairs(ui.rows) do
        AnchorCells(U.CellsOf(row), showTypical)
    end
    -- The chart beside the details needs the same room as the Avg 7d column.
    ui.buyPanel.chartRoom = showTypical
    if not showTypical then
        ui.buyPanel.chart:Hide()
        ui.buyPanel.overviewChart:Hide()
    else
        -- The overview's chart takes the room right of its text, up to the list.
        Chart.Resize(ui.buyPanel.overviewChart, width - OVERVIEW_LEFT - 16, OVERVIEW_HEIGHT)
        if overviewShown then
            Buy.ShowOverview()
        end
    end
    for _, line in ipairs(ui.buyPanel.detailLines or {}) do
        line.right:SetPoint("RIGHT", ui.frame, "RIGHT", showTypical and -(C.CHART_WIDTH + 24) or -16, 0)
    end
end

--- After a pick in a Buy dropdown (quality or Show), searches right away: the pick is the
-- player's click, so it is that click's one search. Only when a search would go out (a name, a
-- quality or a Show choice); otherwise the pick just filters what is shown. Never on Market.
local function SearchAfterPick()
    if ui.buyPanel.marketMode then
        return
    end
    if strtrim(ui.searchBox:GetText() or "") == "" and not state.filter.minQuality and showKey == "all" then
        return
    end
    Buy.SendSearch()
end

--- Makes the filter row: Market's name filter, the quality dropdown, the item level range and
-- Buy's Show dropdown. Item level and Market's filters only filter what is shown; on Buy, a
-- quality or Show pick also searches again (SearchAfterPick), as the house does that filtering.
function Buy.BuildFilterRow()
    -- One frame holds the row, so an item's listings can put their buy bar in its place.
    local filterRow = CreateFrame("Frame", nil, ui.buyPanel)
    filterRow:SetAllPoints(ui.buyPanel)
    ui.buyPanel.filterRow = filterRow
    --- A small edit box that filters as the player types.
    -- @param width the box width
    -- @param numeric true for an item level box
    -- @return the edit box
    local function FilterBox(width, numeric)
        local box = CreateFrame("EditBox", nil, filterRow, "InputBoxTemplate")
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
    nameBox:SetPoint("LEFT", ui.frame, "TOPLEFT", 20, FILTER_ROW_Y)
    nameBox:Hide()
    ui.buyPanel.filterNameBox = nameBox

    -- Blizzard's own dropdown, as its auction house filter uses on Forever.
    local quality = CreateFrame("DropdownButton", nil, filterRow, "WowStyle1DropdownTemplate")
    -- Wide enough for "Uncommon & up", the longest quality choice.
    quality:SetWidth(145)
    quality:SetPoint("LEFT", ui.frame, "TOPLEFT", 14, FILTER_ROW_Y)
    quality:SetupMenu(function(_, root)
        for _, choice in ipairs(Price.QUALITY_CHOICES) do
            root:CreateRadio(choice.label, function(picked)
                return state.filter.minQuality == picked.min
            end, function(picked)
                state.filter.minQuality = picked.min
                ApplyFilters()
                SearchAfterPick()
            end, choice)
        end
    end)
    ui.buyPanel.qualityDropdown = quality

    local levelLabel = U.Cell(filterRow, "GameFontNormalSmall", "LEFT")
    levelLabel:SetPoint("LEFT", quality, "RIGHT", 12, 0)
    levelLabel:SetText("ilvl")
    local minBox = FilterBox(34, true)
    minBox:SetPoint("LEFT", levelLabel, "RIGHT", 10, 0)
    local dash = U.Cell(filterRow, "GameFontHighlightSmall", "LEFT")
    dash:SetPoint("LEFT", minBox, "RIGHT", 2, 0)
    dash:SetText("-")
    local maxBox = FilterBox(34, true)
    maxBox:SetPoint("LEFT", dash, "RIGHT", 8, 0)
    ui.buyPanel.minLevelBox, ui.buyPanel.maxLevelBox = minBox, maxBox

    -- Show (Buy only): what the search asks the house for. Picking one searches (SearchAfterPick).
    local show = CreateFrame("DropdownButton", nil, filterRow, "WowStyle1DropdownTemplate")
    show:SetWidth(130)
    show:SetPoint("LEFT", maxBox, "RIGHT", 14, 0)
    show:SetupMenu(function(_, root)
        for _, choice in ipairs(SHOW_CHOICES) do
            root:CreateRadio(choice.label, function(picked)
                return showKey == picked
            end, function(picked)
                showKey = picked
                SearchAfterPick()
            end, choice.key)
        end
    end)
    ui.buyPanel.showDropdown = show
    -- A search control: Market hides it with the search box.
    table.insert(ui.buyPanel.searchControls, show)

    -- An orange note right of the filters, for something to act on (two short lines at most).
    local notice = U.Cell(filterRow, "GameFontNormalSmall", "LEFT")
    notice:SetPoint("LEFT", show, "RIGHT", 12, 0)
    notice:SetPoint("RIGHT", ui.frame, "RIGHT", -14, 0)
    notice:SetWordWrap(true)
    notice:SetTextColor(1, 0.5, 0.1)
    notice:Hide()
    ui.buyPanel.notice = notice
end
