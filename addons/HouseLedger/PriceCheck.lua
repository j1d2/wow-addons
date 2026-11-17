--[[
Price Check (/pc): saved prices anywhere, with no auction house. Sends nothing.
]]

local _, ns = ...
local C, ui, state, Price, U, Chart, PC = ns.C, ns.ui, ns.state, ns.Price, ns.U, ns.Chart, ns.PC

-- Price Check layout: column headings under the search box, the rows, then the details and the
-- chart.
PC.WIDTH = 400
PC.HEADER_HEIGHT = 18
PC.ROWS = 12
PC.LIST_TOP = 64
-- How many matches Price Check lists; the status line still counts them all.
PC.MATCH_LIMIT = 100
-- The sortable headings, left to right.
PC.SORT_KEYS = { "name", "price", "trend" }

PC.HEIGHT = 500 + PC.HEADER_HEIGHT
PC.ROWS_TOP = PC.LIST_TOP + PC.HEADER_HEIGHT
PC.DETAIL_TOP = PC.ROWS_TOP + PC.ROWS * C.ROW_HEIGHT + 8

--- The value a Price Check row sorts by.
-- @param entry a match from FindByName, with its saved prices in entry.info
-- @param key "name", "price" or "trend"
-- @return the value; nil sorts last
function PC.Value(entry, key)
    if key == "name" then
        return entry.name:lower()
    end
    local info = entry.info
    if key == "price" then
        return info and info.unit
    end
    return info and info.stats and info.stats.trendPct
end

--- Writes Price Check's headings, with an arrow on the sorted one.
function PC.RefreshHeader()
    local sort = ui.priceCheck.sort
    for key, text in pairs(ui.priceCheck.headerTexts) do
        local label = C.HEADER_LABELS[key]
        if sort.key == key then
            label = label .. " |A:" .. (sort.ascending and "NPE_ArrowUp" or "NPE_ArrowDown") .. ":10:10|a"
        end
        text:SetText(label)
    end
end

--- Draws Price Check's rows from the scroll position, and the status line.
function PC.Render()
    local list = ui.priceCheck.found
    for index, row in ipairs(ui.priceCheck.rows) do
        local entry = list[ui.priceCheck.offset + index]
        row.entry = entry
        if entry then
            local info = entry.info
            row.nameText:SetText(entry.name)
            local r, g, b = 1, 1, 1
            if Price.IsQuality(entry.quality) and C_Item and type(C_Item.GetItemQualityColor) == "function" then
                r, g, b = C_Item.GetItemQualityColor(entry.quality)
            end
            row.nameText:SetTextColor(r, g, b)
            local icon = C_Item and type(C_Item.GetItemIconByID) == "function" and C_Item.GetItemIconByID(entry.itemID)
            row.icon:SetTexture(icon or C.QUESTION_MARK_ICON)
            row.priceText:SetText(info and U.CopperToText(info.unit) or "-")
            local stats = info and info.stats
            local mark = Price.TrendText(stats, "buyer")
            if mark == "" then
                mark = Price.SteadyText(stats)
            end
            if stats and stats.deal then
                mark = mark .. " " .. Price.DEAL_ICON
            end
            row.trendText:SetText(mark)
            row:Show()
        else
            row:Hide()
        end
    end
    local text = strtrim(ui.priceCheck.searchBox:GetText() or "")
    local total = ui.priceCheck.total
    if strlenutf8(text) < C.MIN_SEARCH_LENGTH then
        ui.priceCheck.status:SetText("Type 2 letters of an item's name.")
    elseif U.MarketHouse() == nil then
        ui.priceCheck.status:SetText("No prices saved yet. Scan once at the auction house.")
    elseif total == 0 then
        ui.priceCheck.status:SetText("No saved item matches. Names fill in from your scans.")
    elseif total <= PC.ROWS then
        ui.priceCheck.status:SetText(total == 1 and "1 item matches." or string.format("%d items match.", total))
    else
        local last = math.min(ui.priceCheck.offset + PC.ROWS, #list)
        local line = string.format("%d-%d of %d items. Scroll for more.", ui.priceCheck.offset + 1, last, total)
        if total > #list then
            line = string.format("%d-%d of %d items. Type more to narrow them.", ui.priceCheck.offset + 1, last, total)
        end
        ui.priceCheck.status:SetText(line)
    end
end

--- Fills Price Check's list from what the search box holds, from saved data only, in the
-- chosen sort, and goes back to the top.
function PC.Refresh()
    local text = strtrim(ui.priceCheck.searchBox:GetText() or "")
    local found, total = Price.FindByName(U.MarketHouse(), text, PC.MATCH_LIMIT)
    for _, entry in ipairs(found) do
        entry.info = Price.Lookup(HouseLedgerDB, entry.itemID, U.PlayerHouseKey())
    end
    local sort = ui.priceCheck.sort
    if sort.key then
        found = Price.SortList(found, function(entry)
            return PC.Value(entry, sort.key)
        end, sort.ascending)
    end
    ui.priceCheck.found, ui.priceCheck.total, ui.priceCheck.offset = found, total, 0
    PC.Render()
end

--- Mouse wheel over Price Check: moves through the matches already found. Sends nothing.
-- @param rowsDown rows to move; negative moves up. Clamped to the list.
function PC.Scroll(rowsDown)
    local maxOffset = math.max(0, #ui.priceCheck.found - PC.ROWS)
    local offset = math.min(maxOffset, math.max(0, ui.priceCheck.offset + rowsDown))
    if offset ~= ui.priceCheck.offset then
        ui.priceCheck.offset = offset
        PC.Render()
    end
end

--- A Price Check heading click: sorts the matches by it, or reverses the sort. Sends nothing.
-- @param key "name", "price" or "trend"
function PC.Sort(key)
    local sort = ui.priceCheck.sort
    if sort.key == key then
        sort.ascending = not sort.ascending
    else
        sort.key, sort.ascending = key, C.SORT_FIRST_ASCENDING[key]
    end
    PC.RefreshHeader()
    PC.Refresh()
end

--- Follows the game's item link insert (a shift-click on a bag item or a chat link): while
-- Price Check is open and no chat box is taking the link, looks the item up by its name.
-- Runs after the game's own code (hooksecurefunc) and sends nothing.
-- @param link the link the game inserted
function PC.FollowLink(link)
    if not (ui.priceCheck and ui.priceCheck:IsShown()) or type(link) ~= "string" then
        return
    end
    if not link:find("|Hitem:", 1, true) then
        return
    end
    local chat = type(ChatFrameUtil) == "table" and type(ChatFrameUtil.GetActiveWindow) == "function"
        and ChatFrameUtil.GetActiveWindow()
    if chat and not ui.priceCheck.searchBox:HasFocus() then
        return
    end
    local name = link:match("|h%[(.-)%]|h")
    if name and name ~= "" then
        ui.priceCheck.searchBox:SetText(name)
        ui.priceCheck.searchBox:ClearFocus()
        PC.Refresh()
    end
end

--- A Price Check row click: its saved day lines and chart under the list. Saved data only.
-- @param row the clicked row
function PC.ShowDetails(row)
    local entry = row.entry
    if entry == nil then
        return
    end
    local info = Price.Lookup(HouseLedgerDB, entry.itemID, U.PlayerHouseKey())
    local stats = info and info.stats
    ui.priceCheck.detailTitle:SetText(stats and (entry.name .. ", " .. Price.CountText(stats)) or entry.name)
    local lines = stats and Price.WindowLines(stats, U.CopperToText) or {}
    for index, line in ipairs(ui.priceCheck.detailLines) do
        line.left:SetText(lines[index] and lines[index].left or "")
        line.right:SetText(lines[index] and lines[index].right or "")
    end
    Chart.Show(ui.priceCheck.chart, info)
end

--- Opens or closes Price Check. With a name, opens it and searches for that name.
-- @param name optional item name to search for
function PC.Toggle(name)
    if name and name ~= "" then
        ui.priceCheck.searchBox:SetText(name)
        PC.Refresh()
        ui.priceCheck:Show()
        return
    end
    if ui.priceCheck:IsShown() then
        ui.priceCheck:Hide()
    else
        PC.Refresh()
        ui.priceCheck:Show()
    end
end

--- Shows or hides the Price Check buttons above the bags, as Settings says. The bag windows can
-- count as protected, so in combat this waits for OnCombatEnded.
function PC.UpdateBagButtons()
    if U.InCombat() then
        state.bagButtonsPending = true
        return
    end
    for _, button in ipairs(ui.priceCheck.bagButtons) do
        if HouseLedgerDB.settings.priceCheckButton then button:Show() else button:Hide() end
    end
end

--- Makes the Price Check buttons above the game's bag windows, once, out of combat; left of
-- Unmaker's so both fit. They are kept here, never written onto Blizzard's bag frames.
function PC.MakeBagButtons()
    if U.InCombat() then
        state.bagButtonsPending = true
        return
    end
    if #ui.priceCheck.bagButtons == 0 then
        for _, bagFrame in ipairs({ _G.ContainerFrameCombinedBags, _G.ContainerFrame1 }) do
            if type(bagFrame) == "table" then
                local button = CreateFrame("Button", nil, bagFrame, "UIPanelButtonTemplate")
                button:SetSize(90, 20)
                button:SetText("Price Check")
                button:SetPoint("BOTTOMRIGHT", bagFrame, "TOPRIGHT", -84, 2)
                button:SetScript("OnClick", function()
                    PC.Toggle()
                end)
                ui.priceCheck.bagButtons[#ui.priceCheck.bagButtons + 1] = button
            end
        end
    end
    PC.UpdateBagButtons()
end

--- Makes the Price Check window: a search box over saved item names, a list with the last price
-- and trend, and the clicked item's day lines and price chart. It works anywhere, with no
-- auction house open, and never sends anything. Escape closes it.
function PC.Build()
    ui.priceCheck = CreateFrame("Frame", "HouseLedgerPriceCheck", UIParent, "ButtonFrameTemplate")
    ui.priceCheck:SetSize(PC.WIDTH, PC.HEIGHT)
    ui.priceCheck:SetPoint("CENTER")
    ui.priceCheck:SetClampedToScreen(true)
    ui.priceCheck:SetToplevel(true)
    if type(ui.priceCheck.SetTitle) == "function" then
        ui.priceCheck:SetTitle("Price Check")
    end
    if type(ui.priceCheck.SetPortraitToAsset) == "function" then
        ui.priceCheck:SetPortraitToAsset(C.PORTRAIT_ICON)
    end
    ui.priceCheck:SetMovable(true)
    ui.priceCheck:EnableMouse(true)
    ui.priceCheck:RegisterForDrag("LeftButton")
    ui.priceCheck:SetScript("OnDragStart", function(self) self:StartMoving() end)
    ui.priceCheck:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    ui.priceCheck:Hide()
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "HouseLedgerPriceCheck")
    end

    local box = CreateFrame("EditBox", nil, ui.priceCheck, "InputBoxTemplate")
    box:SetHeight(20)
    box:SetPoint("LEFT", ui.priceCheck, "TOPLEFT", 72, -41)
    box:SetPoint("RIGHT", ui.priceCheck, "TOPRIGHT", -16, -41)
    box:SetAutoFocus(false)
    box:SetScript("OnTextChanged", function(_, userInput)
        if userInput then
            PC.Refresh()
        end
    end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    ui.priceCheck.searchBox = box

    -- Headings over the rows' columns; each is a button that sorts the matches.
    local headerRow = CreateFrame("Frame", nil, ui.priceCheck)
    headerRow:SetHeight(PC.HEADER_HEIGHT)
    headerRow:SetPoint("TOPLEFT", ui.priceCheck, "TOPLEFT", 12, -PC.LIST_TOP)
    headerRow:SetPoint("RIGHT", ui.priceCheck, "RIGHT", -12, 0)
    local trendHeading = U.Cell(headerRow, "GameFontNormalSmall", "RIGHT")
    trendHeading:SetPoint("RIGHT", headerRow, "RIGHT", -4, 0)
    trendHeading:SetWidth(70)
    local priceHeading = U.Cell(headerRow, "GameFontNormalSmall", "RIGHT")
    priceHeading:SetPoint("RIGHT", trendHeading, "LEFT", -6, 0)
    priceHeading:SetWidth(90)
    local nameHeading = U.Cell(headerRow, "GameFontNormalSmall", "LEFT")
    nameHeading:SetPoint("LEFT", headerRow, "LEFT", 4 + C.ICON_SIZE + 6, 0)
    nameHeading:SetPoint("RIGHT", priceHeading, "LEFT", -6, 0)
    ui.priceCheck.headerTexts = { name = nameHeading, price = priceHeading, trend = trendHeading }
    ui.priceCheck.sortButtons = {}
    for _, key in ipairs(PC.SORT_KEYS) do
        local text = ui.priceCheck.headerTexts[key]
        local button = CreateFrame("Button", nil, headerRow)
        button:SetPoint("TOPLEFT", text, "TOPLEFT", -2, 4)
        button:SetPoint("BOTTOMRIGHT", text, "BOTTOMRIGHT", 2, -4)
        button:SetScript("OnClick", function()
            PC.Sort(key)
        end)
        ui.priceCheck.sortButtons[key] = button
    end
    ui.priceCheck.sort = {}
    ui.priceCheck.found, ui.priceCheck.total, ui.priceCheck.offset = {}, 0, 0
    PC.RefreshHeader()
    ui.priceCheck:EnableMouseWheel(true)
    ui.priceCheck:SetScript("OnMouseWheel", function(_, delta)
        PC.Scroll(-delta * C.WHEEL_STEP)
    end)
    if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.InsertLink) == "function" then
        hooksecurefunc(ChatFrameUtil, "InsertLink", PC.FollowLink)
    end

    ui.priceCheck.rows = {}
    for index = 1, PC.ROWS do
        local row = CreateFrame("Button", nil, ui.priceCheck)
        row:SetHeight(C.ROW_HEIGHT)
        row:SetPoint("TOPLEFT", ui.priceCheck, "TOPLEFT", 12, -PC.ROWS_TOP - (index - 1) * C.ROW_HEIGHT)
        row:SetPoint("RIGHT", ui.priceCheck, "RIGHT", -12, 0)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(C.ICON_SIZE, C.ICON_SIZE)
        row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.trendText = U.Cell(row, "GameFontHighlightSmall", "RIGHT")
        row.trendText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.trendText:SetWidth(70)
        row.priceText = U.Cell(row, "GameFontHighlightSmall", "RIGHT")
        row.priceText:SetPoint("RIGHT", row.trendText, "LEFT", -6, 0)
        row.priceText:SetWidth(90)
        row.nameText = U.Cell(row, "GameFontHighlightSmall", "LEFT")
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.nameText:SetPoint("RIGHT", row.priceText, "LEFT", -6, 0)
        row:SetScript("OnClick", PC.ShowDetails)
        row:SetScript("OnEnter", function(self)
            if self.entry and GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(self.entry.itemID)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function()
            if GameTooltip then
                GameTooltip:Hide()
            end
        end)
        row:Hide()
        ui.priceCheck.rows[index] = row
    end

    ui.priceCheck.detailTitle = U.Cell(ui.priceCheck, "GameFontNormal", "LEFT")
    ui.priceCheck.detailTitle:SetPoint("TOPLEFT", ui.priceCheck, "TOPLEFT", 16, -PC.DETAIL_TOP)
    ui.priceCheck.detailTitle:SetPoint("RIGHT", ui.priceCheck, "RIGHT", -16, 0)
    ui.priceCheck.detailLines = {}
    for index = 1, C.DETAIL_LINES do
        local y = -PC.DETAIL_TOP - index * C.DETAIL_LINE_HEIGHT
        local left = U.Cell(ui.priceCheck, "GameFontHighlightSmall", "LEFT")
        left:SetPoint("TOPLEFT", ui.priceCheck, "TOPLEFT", 24, y)
        left:SetWidth(150)
        local right = U.Cell(ui.priceCheck, "GameFontHighlightSmall", "LEFT")
        right:SetPoint("TOPLEFT", ui.priceCheck, "TOPLEFT", 180, y)
        right:SetPoint("RIGHT", ui.priceCheck, "RIGHT", -16, 0)
        ui.priceCheck.detailLines[index] = { left = left, right = right }
    end
    ui.priceCheck.chart = Chart.Build(ui.priceCheck, PC.WIDTH - 40, 64)
    ui.priceCheck.chart:SetPoint("TOPLEFT", ui.priceCheck, "TOPLEFT", 20,
        -PC.DETAIL_TOP - (C.DETAIL_LINES + 1) * C.DETAIL_LINE_HEIGHT - 4)

    ui.priceCheck.status = U.Cell(ui.priceCheck, "GameFontHighlightSmall", "LEFT")
    ui.priceCheck.status:SetPoint("BOTTOMLEFT", ui.priceCheck, "BOTTOMLEFT", 14, 8)
    ui.priceCheck.status:SetPoint("RIGHT", ui.priceCheck, "RIGHT", -14, 0)

    ui.priceCheck.bagButtons = {}
    ui.priceCheck.updateBagButtons = PC.UpdateBagButtons
    PC.MakeBagButtons()
end

-- /pc and /pricecheck open Price Check; a name after it searches for that name.
SLASH_HOUSELEDGERPC1 = "/pricecheck"
SLASH_HOUSELEDGERPC2 = "/pc"

SlashCmdList.HOUSELEDGERPC = function(message)
    if ui.priceCheck then
        PC.Toggle(strtrim(message or ""))
    end
end
