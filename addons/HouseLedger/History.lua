--[[
The History tab: what this account's characters bought and sold, and the auctions that came back.

Two sources, both read-only:
- HouseLedger's own buys, recorded the moment the house says they went through (Purchase.lua).
- The auction house mail in a character's mailbox ("Auction won", "Auction successful", and
  expired or cancelled auctions), read while the player has the mailbox open. Reading takes,
  deletes, returns and opens nothing, and the other player's name is never read or saved.

The records and their sums are pure (PriceLedger: RecordBuy, RecordMail, LedgerView,
LedgerTotals, LedgerProfits); this file reads the game and draws the tab.
]]

local _, ns = ...
local C, ui, Price, U, History = ns.C, ns.ui, ns.Price, ns.U, ns.History

-- The dark box's bottom on this tab: it takes the details block's space, down to just above the
-- totals (two lines) and the scan line. Window.lua moves the box when the tab shows.
History.INSET_BOTTOM = C.STATUS_HEIGHT + 40
-- Where the headings sit, under the dropdowns.
local LIST_TOP = C.LIST_TOP + C.FILTER_HEIGHT + 4
-- The rows that fit between the headings and the box's bottom: 18.
local ROWS = math.floor((C.HOUSE_HEIGHT - History.INSET_BOTTOM - 2 - LIST_TOP - C.ROW_HEIGHT) / C.ROW_HEIGHT)
-- Below this window width the Who column hides (the hover still says who).
local WHO_MIN_WIDTH = 540
local KIND_CHOICES = {
    { key = nil, label = "Everything" },
    { key = "bought", label = "Bought" },
    { key = "sold", label = "Sold" },
    { key = "returned", label = "Came back" },
}
-- Column headings and what each sorts by; nil sorts by time.
local COLUMNS = {
    { key = "when", label = "When" },
    { key = "name", label = "Item" },
    { key = "count", label = "Qty" },
    { key = "amount", label = "Amount" },
    { key = "profit", label = "Profit" },
    { key = "who", label = "Who" },
}
local EMPTY_TEXT = "Nothing recorded yet. Buys made in HouseLedger show at once. Open your mailbox to add"
    .. " sales, other buys, and auctions that came back."

local panel
local view = {}
local offset = 0
local filter = { who = nil, kind = nil }
local sort = { key = nil, ascending = false }
local profits, profitsStamp = {}, nil

--- Records a buy HouseLedger made, the moment the house says it went through.
-- @param itemID the item
-- @param name its plain name
-- @param count how many
-- @param copper what was paid in all
function History.RecordBuy(itemID, name, count, copper)
    Price.RecordBuy(HouseLedgerDB.ledger, { time = time(), who = U.CharacterName(), realm = U.RealmName(),
        itemID = itemID, name = name, count = count, bid = copper })
    History.Render()
end

--- The item ID in an item link, or nil.
-- @param link an item link, or nil
-- @return the ID, or nil
local function LinkItemID(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

--- Reads one mail into a record, or nil when it isn't one the History tab keeps.
-- @param index the mail's place in the inbox
-- @param now the time
-- @return { kind, name, itemID, count, bid, deposit, cut, expires }, or nil
local function ReadMail(index, now)
    local _, _, _, subject, _, _, daysLeft, _, _, _, _, _, _, firstQuantity, firstLink = GetInboxHeaderInfo(index)
    if type(daysLeft) ~= "number" then
        return nil
    end
    local expires = math.floor(now + daysLeft * 86400 + 0.5)
    -- The third value is the other player's name: never read.
    local invoiceType, itemName, _, bid, _, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(index)
    if (invoiceType == "buyer" or invoiceType == "seller") and type(itemName) == "string" and type(bid) == "number" then
        count = type(count) == "number" and count > 0 and count or firstQuantity or 1
        return { kind = invoiceType == "buyer" and "bought" or "sold", name = itemName, itemID = LinkItemID(firstLink),
            count = count, bid = bid, deposit = invoiceType == "seller" and deposit or nil,
            cut = invoiceType == "seller" and consignment or nil, expires = expires }
    end
    if invoiceType ~= nil then
        return nil -- a sale whose money hasn't come yet: its own mail follows
    end
    -- Auctions that came back have no invoice; only the game's own subject says which.
    for kind, format in pairs({ expired = AUCTION_EXPIRED_MAIL_SUBJECT, cancelled = AUCTION_REMOVED_MAIL_SUBJECT }) do
        local name = Price.SubjectItem(format, subject)
        if name then
            return { kind = kind, name = name, itemID = LinkItemID(firstLink), count = firstQuantity or 1, bid = 0,
                expires = expires }
        end
    end
    return nil
end

--- The mailbox changed (MAIL_INBOX_UPDATE): records the auction house mail in it. Reads only.
function History.ReadInbox()
    if type(GetInboxNumItems) ~= "function" or type(GetInboxInvoiceInfo) ~= "function" then
        return
    end
    local now, mails = time(), {}
    for index = 1, GetInboxNumItems() do
        local mail = ReadMail(index, now)
        if mail then
            mails[#mails + 1] = mail
        end
    end
    if #mails > 0 and Price.RecordMail(HouseLedgerDB.ledger, mails, now, U.CharacterName(), U.RealmName()) > 0 then
        History.Render()
    end
end

--- The profit of each sale, worked out again only when the history changed.
-- @return table entry -> copper
local function Profits()
    local entries = HouseLedgerDB.ledger.entries
    local last = entries[#entries]
    local stamp = #entries .. ":" .. tostring(last and last.time)
    if stamp ~= profitsStamp then
        profits, profitsStamp = Price.LedgerProfits(entries), stamp
    end
    return profits
end

--- What an entry's Amount column shows, and its color.
-- @param entry the entry
-- @return text, r, g, b
local function AmountText(entry)
    if entry.kind == "bought" then
        return U.CopperToText(entry.bid), 1, 0.5, 0.5
    elseif entry.kind == "sold" then
        return U.CopperToText(Price.SaleProceeds(entry)), 0.4, 1, 0.4
    end
    return Price.LEDGER_KINDS[entry.kind], 0.6, 0.6, 0.6
end

--- A copper amount with its sign, for profit.
-- @param copper the amount, or nil
-- @return text, r, g, b
local function ProfitText(copper)
    if copper == nil then
        return "", 1, 1, 1
    elseif copper < 0 then
        return "-" .. U.CopperToText(-copper), 1, 0.5, 0.5
    end
    return U.CopperToText(copper), 0.4, 1, 0.4
end

--- The value an entry sorts by under a heading.
-- @param entry the entry
-- @param key the heading's key
-- @return a number or a string, or nil
local function SortValue(entry, key)
    if key == "name" then
        return entry.name:lower()
    elseif key == "count" then
        return entry.count
    elseif key == "amount" then
        return entry.kind == "bought" and -(entry.bid or 0) or entry.kind == "sold" and Price.SaleProceeds(entry) or nil
    elseif key == "profit" then
        return profits[entry]
    elseif key == "who" then
        return entry.who
    end
    return entry.time
end

--- Places the columns for the window's width: Who hides on a narrow window.
-- @param row a row
-- @param showWho true to show the Who column
local function LayOut(row, showWho)
    local cells = row.cells
    for _, cell in pairs(cells) do
        cell:ClearAllPoints()
    end
    cells.who:SetShown(showWho)
    cells.when:SetPoint("LEFT", row, "LEFT", 4, 0)
    cells.when:SetWidth(70)
    local right = row
    local point = "RIGHT"
    if showWho then
        cells.who:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        cells.who:SetWidth(84)
        right, point = cells.who, "LEFT"
    end
    for _, column in ipairs({ { "profit", 84 }, { "amount", 92 }, { "count", 34 } }) do
        local cell = cells[column[1]]
        cell:SetPoint("RIGHT", right, point, right == row and -4 or -6, 0)
        cell:SetWidth(column[2])
        right, point = cell, "LEFT"
    end
    cells.name:SetPoint("LEFT", cells.when, "RIGHT", 4, 0)
    cells.name:SetPoint("RIGHT", cells.count, "LEFT", -6, 0)
end

--- The totals line for what's shown.
-- @param totals from PriceLedger.LedgerTotals
-- @return the text
local function TotalsText(totals)
    local parts = {}
    if totals.boughtCount > 0 then
        parts[#parts + 1] = string.format("Bought %d for %s", totals.boughtCount, U.CopperToText(totals.boughtCopper))
    end
    if totals.soldCount > 0 then
        parts[#parts + 1] = string.format("sold %d for %s after the house's cut", totals.soldCount,
            U.CopperToText(totals.soldCopper))
    end
    if totals.returnedCount > 0 then
        parts[#parts + 1] = string.format("%d came back", totals.returnedCount)
    end
    local text = table.concat(parts, "; ")
    text = text:sub(1, 1):upper() .. text:sub(2)
    if totals.profitSales > 0 then
        local profit = ProfitText(totals.profit)
        text = text .. string.format(".\nProfit on %d sale%s with a recorded buy: %s", totals.profitSales,
            totals.profitSales == 1 and "" or "s", profit)
    end
    return text
end

--- Draws the History tab from the saved history: filters, sort, rows and totals.
function History.Render()
    if panel == nil or not panel:IsShown() then
        return
    end
    local entries = HouseLedgerDB.ledger.entries
    Profits()
    view = Price.LedgerView(entries, filter.who, filter.kind)
    local totals = Price.LedgerTotals(view, profits)
    if sort.key or sort.ascending then
        view = Price.SortList(view, function(entry) return SortValue(entry, sort.key) end, sort.ascending)
    end
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
            cells.when:SetText(Price.WhenText(entry.time))
            cells.name:SetText(entry.name)
            cells.count:SetText(tostring(entry.count))
            local amount, ar, ag, ab = AmountText(entry)
            cells.amount:SetText(amount)
            cells.amount:SetTextColor(ar, ag, ab)
            local profit, r, g, b = ProfitText(profits[entry])
            cells.profit:SetText(profit)
            cells.profit:SetTextColor(r, g, b)
            cells.who:SetText(entry.who or "")
            row:Show()
        else
            row:Hide()
        end
    end
    panel.empty:SetShown(#view == 0)
    panel.empty:SetText(#entries == 0 and EMPTY_TEXT or "Nothing recorded for this choice.")
    panel.totals:SetText(#view > 0 and TotalsText(totals) or "")
    for key, heading in pairs(panel.headings) do
        local label = heading.labelText
        if sort.key == key or (sort.key == nil and key == "when") then
            -- The game's arrow, as on the Buy tab and Price Check: down for newest or most first.
            label = label .. " |A:" .. (sort.ascending and "NPE_ArrowUp" or "NPE_ArrowDown") .. ":10:10|a"
        end
        heading.label:SetText(label)
    end
end

--- The hover lines for a row's entry: what happened, its money, and where it came from.
-- @param row the row
local function ShowEntryTooltip(row)
    local entry = row.entry
    if entry == nil then
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if entry.itemID then
        GameTooltip:SetItemByID(entry.itemID)
    else
        GameTooltip:AddLine(entry.name, 1, 1, 1)
    end
    local each = entry.count > 1 and entry.bid and entry.bid > 0
        and (" (" .. U.CopperToText(math.floor(entry.bid / entry.count + 0.5)) .. " each)") or ""
    if entry.kind == "bought" then
        GameTooltip:AddLine(string.format("Bought %d for %s%s", entry.count, U.CopperToText(entry.bid), each), 1, 1, 1)
    elseif entry.kind == "sold" then
        GameTooltip:AddLine(string.format("Sold %d for %s%s", entry.count, U.CopperToText(entry.bid), each), 1, 1, 1)
        GameTooltip:AddLine("House cut " .. U.CopperToText(entry.cut or 0) .. "; you got "
            .. U.CopperToText(Price.SaleProceeds(entry)) .. " (and the deposit back)", 1, 1, 1)
        local profit = profits[entry]
        GameTooltip:AddLine(profit and ("Profit: " .. ProfitText(profit) .. ", against the average you paid before")
            or "No recorded buy of this item before it, so no profit shown.", 0.8, 0.8, 0.8, true)
    else
        GameTooltip:AddLine(string.format("%s: %d came back by mail", Price.LEDGER_KINDS[entry.kind], entry.count),
            1, 1, 1)
    end
    -- A mail's time is worked out from its days left, so it is about right, not exact.
    GameTooltip:AddLine(string.format("%s, %s%s", entry.who or "?", entry.estimated and "about " or "",
        Price.WhenText(entry.time)), 0.8, 0.8, 0.8)
    GameTooltip:AddLine(entry.source == "hl" and "Bought in HouseLedger" or "From the auction house mail",
        0.6, 0.6, 0.6)
    GameTooltip:Show()
end

--- Moves the list by whole rows, through what is already shown. Sends nothing.
-- @param rowsDown rows to move; negative moves up. Clamped to the list.
local function Scroll(rowsDown)
    local moved = math.max(0, math.min(offset + rowsDown, #view - ROWS))
    if moved ~= offset then
        offset = moved
        History.Render()
    end
end

--- Makes a row: when, item, qty, amount, profit and who, with the item's tooltip on hover.
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
        local right = column.key == "count" or column.key == "amount" or column.key == "profit"
        row.cells[column.key] = U.Cell(row, header and "GameFontNormalSmall" or "GameFontHighlightSmall",
            right and "RIGHT" or "LEFT")
    end
    if not header then
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row:SetScript("OnEnter", ShowEntryTooltip)
        row:SetScript("OnLeave", U.HideRowTooltip)
        row.historyRow = true
    end
    return row
end

--- Makes the History tab: what to show (kind, character), sortable headings, the rows and the
-- totals. Reads saved data only; sends nothing.
function History.BuildPanel()
    panel = CreateFrame("Frame", nil, ui.frame)
    panel:SetAllPoints(ui.frame)
    panel:Hide()
    ui.frame.historyPanel, ui.historyPanel = panel, panel

    local kindDropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    kindDropdown:SetWidth(150)
    kindDropdown:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -C.LIST_TOP - 2)
    kindDropdown:SetupMenu(function(_, root)
        for _, choice in ipairs(KIND_CHOICES) do
            root:CreateRadio(choice.label, function(picked)
                return filter.kind == picked
            end, function(picked)
                filter.kind, offset = picked, 0
                History.Render()
            end, choice.key)
        end
    end)
    local whoDropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    whoDropdown:SetWidth(170)
    whoDropdown:SetPoint("LEFT", kindDropdown, "RIGHT", 10, 0)
    whoDropdown:SetupMenu(function(_, root)
        local choices = { false } -- false stands for all characters
        for _, name in ipairs(Price.LedgerCharacters(HouseLedgerDB.ledger.entries)) do
            choices[#choices + 1] = name
        end
        for _, choice in ipairs(choices) do
            root:CreateRadio(choice or "All characters", function(picked)
                return (filter.who or false) == picked
            end, function(picked)
                filter.who, offset = picked or nil, 0
                History.Render()
            end, choice)
        end
    end)
    panel.kindDropdown, panel.whoDropdown = kindDropdown, whoDropdown

    local top = -LIST_TOP
    panel.header = BuildRow(panel, top, true)
    panel.headings = {}
    for _, column in ipairs(COLUMNS) do
        local cell = panel.header.cells[column.key]
        local heading = CreateFrame("Button", nil, panel.header)
        heading:SetAllPoints(cell)
        heading.label, heading.labelText = cell, column.label
        cell:SetText(column.label)
        heading:SetScript("OnClick", function()
            -- When sorts newest first by default; a heading clicked again reverses.
            local key = column.key ~= "when" and column.key or nil
            if sort.key == key then
                sort.ascending = not sort.ascending
            else
                sort.key, sort.ascending = key, key == "name" or key == "who"
            end
            offset = 0
            History.Render()
        end)
        panel.headings[column.key] = heading
    end
    panel.rows = {}
    for index = 1, ROWS do
        panel.rows[index] = BuildRow(panel, top - index * C.ROW_HEIGHT)
    end
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        Scroll(-delta * C.WHEEL_STEP)
    end)
    panel.scrollBar = U.ScrollBar(panel, Scroll)
    panel.scrollBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, top - C.ROW_HEIGHT)
    panel.scrollBar:SetHeight(ROWS * C.ROW_HEIGHT)
    panel.empty = U.Cell(panel, "GameFontHighlight", "LEFT")
    panel.empty:SetPoint("TOPLEFT", panel, "TOPLEFT", 22, top - C.ROW_HEIGHT - 8)
    panel.empty:SetPoint("RIGHT", panel, "RIGHT", -22, 0)
    panel.empty:SetWordWrap(true)
    panel.totals = U.Cell(panel, "GameFontNormalSmall", "LEFT")
    panel.totals:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 20, C.STATUS_HEIGHT + 8)
    panel.totals:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
    panel.totals:SetWordWrap(true)
end
