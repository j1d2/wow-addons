--[[
The price chart, used by Buy, Market, Sell and Price Check: one bar per day's lowest price with a
faint band up to its highest, or one bar per saved scan, picked with the Days | Scans words in its
corner (one saved choice for every chart). And the house overview chart (items listed a day, with
a trend line) on Buy. Both draw saved data only.
]]

local _, ns = ...
local Price, U, Chart = ns.Price, ns.U, ns.Chart

-- Bar colors: earlier days blue, the latest day gold, a day's range a faint band above its low.
local CHART_BAR_COLOR = { 0.35, 0.6, 1, 0.9 }
local CHART_LATEST_COLOR = { 1, 0.82, 0, 1 }
local CHART_RANGE_COLOR = { 0.35, 0.6, 1, 0.3 }

-- Extra space between two days' scans on the scan view, in pixels.
local CHART_DAY_GAP = 3
-- The view words: the one in use bright, the other grey.
local VIEW_ON_COLOR = { 1, 1, 1 }
local VIEW_OFF_COLOR = { 0.5, 0.5, 0.5 }
-- What each view word says, by view.
local VIEW_WORDS = { days = "Days", scans = "Scans" }

-- The price charts Chart.Build made, so a view change redraws every one on screen.
Chart.built = {}

--- Draws bars from chart slots: one bar per filled slot's low, a faint band up to its high, the
-- last slot in gold. A slot that starts a new day gets CHART_DAY_GAP more space before it when
-- `dayGaps` is set.
-- @param chart a chart from Chart.Build
-- @param slots the slots, oldest first; a slot without `low` is left empty
-- @param top the highest price, the top of the bars
-- @param dayGaps true to space out days (the scan view)
local function DrawBars(chart, slots, top, dayGaps)
    -- Which slots start a new day, and how many gaps come before each slot.
    local gapsBefore, gaps, lastDay = {}, 0, nil
    for index, slot in ipairs(slots) do
        if dayGaps and slot.dayKey and lastDay and slot.dayKey ~= lastDay then
            gaps = gaps + 1
        end
        lastDay = slot.dayKey or lastDay
        gapsBefore[index] = gaps
    end
    local slotWidth = (chart.chartWidth - gaps * CHART_DAY_GAP) / #slots
    local barWidth = math.max(2, math.floor(slotWidth) - 2)
    for index = #slots + 1, #chart.bars do
        chart.bars[index]:Hide()
        chart.bands[index]:Hide()
    end
    chart.slotCount = #slots
    for index, slot in ipairs(slots) do
        local bar, band = chart.bars[index], chart.bands[index]
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT",
            math.floor((index - 1) * slotWidth + gapsBefore[index] * CHART_DAY_GAP) + 1, 2)
        bar:SetWidth(barWidth)
        band:SetWidth(barWidth)
        if slot.low then
            local low = math.max(1, math.floor(slot.low / top * chart.barArea + 0.5))
            local high = math.floor(slot.high / top * chart.barArea + 0.5)
            bar:SetHeight(low)
            local color = index == #slots and CHART_LATEST_COLOR or CHART_BAR_COLOR
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
end

--- Shows which view is in use: its word bright, the other grey.
-- @param chart a chart from Chart.Build
-- @param view one of PriceLedger.CHART_VIEWS
local function MarkView(chart, view)
    for name, word in pairs(chart.viewWords) do
        local color = name == view and VIEW_ON_COLOR or VIEW_OFF_COLOR
        word.label:SetTextColor(color[1], color[2], color[3])
    end
end

--- Draws an item's saved prices on a chart, in the saved view.
-- Days: one bar per day's low with a faint band up to its high, one slot per day from the item's
-- oldest saved day (at least 7, at most the history length), so it grows as the history does.
-- Scans: one bar per saved scan (at most PriceLedger.SCANS_KEPT), with a little space between
-- days; an item saved before scans were kept says when they start instead.
-- The latest bar is gold. Hides the chart when there is no item. Saved data only.
-- @param chart a chart from Chart.Build
-- @param info the item's saved prices from PriceLedger.Lookup, or nil
function Chart.Show(chart, info)
    chart.info = info
    local view = Price.ChartView(HouseLedgerDB)
    MarkView(chart, view)
    chart.span = nil
    chart.emptyText:Hide()
    if view == "scans" and info ~= nil then
        local data = Price.ChartScans(info.scans)
        if data == nil or data.top <= 0 then
            DrawBars(chart, {}, 1, false)
            chart.topText:SetText("")
            chart.caption:SetText("Each scan: none saved yet")
            chart.emptyText:Show()
            chart:Show()
            return
        end
        DrawBars(chart, data.slots, data.top, true)
        chart.caption:SetText("Each scan, " .. data.count .. (data.count == 1 and " scan" or " scans"))
        chart.span = Price.ScanSpanText(data)
        chart.topText:SetText(U.CopperToText(data.top))
        chart:Show()
        return
    end
    local data = info and Price.ChartDays(info.days, info.seen)
    if data == nil or data.top <= 0 then
        chart:Hide()
        return
    end
    DrawBars(chart, data.slots, data.top, false)
    chart.caption:SetText("Daily low, " .. #data.slots .. " days")
    chart.topText:SetText(U.CopperToText(data.top))
    chart:Show()
end

--- Switches every price chart to a view and saves it; the charts on screen redraw at once.
-- @param view one of PriceLedger.CHART_VIEWS
function Chart.SetView(view)
    Price.SetChartView(HouseLedgerDB, view)
    for _, chart in ipairs(Chart.built) do
        if chart:IsShown() then
            Chart.Show(chart, chart.info)
        end
    end
end

--- Hover tip for a price chart: what it shows and how to switch.
-- @param chart a chart from Chart.Build
local function ShowChartTip(chart)
    if GameTooltip == nil then
        return
    end
    GameTooltip:SetOwner(chart, "ANCHOR_TOP")
    GameTooltip:SetText(chart.caption:GetText() or "", 1, 1, 1)
    if chart.span then
        GameTooltip:AddLine(chart.span, 0.8, 0.8, 0.8)
    end
    GameTooltip:AddLine("Click Days or Scans to switch.", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

--- Hides the chart's hover tip.
local function HideChartTip()
    if GameTooltip then
        GameTooltip:Hide()
    end
end

--- Makes one view word: a small button that switches every price chart to its view.
-- @param chart the chart it sits on
-- @param view one of PriceLedger.CHART_VIEWS
-- @return the button, with its label
local function ViewWord(chart, view)
    local word = CreateFrame("Button", nil, chart)
    word.label = U.Cell(word, "GameFontHighlightSmall", "RIGHT")
    word.label:SetText(VIEW_WORDS[view])
    word.label:SetPoint("RIGHT", word, "RIGHT", 0, 0)
    word:SetSize(math.max(20, math.ceil(word.label:GetStringWidth() or 0) + 2), 14)
    word:SetScript("OnClick", function()
        Chart.SetView(view)
        ShowChartTip(chart)
    end)
    word:SetScript("OnEnter", function()
        ShowChartTip(chart)
    end)
    word:SetScript("OnLeave", HideChartTip)
    return word
end

--- Makes a price chart, hidden until Chart.Show fills it: a dark box, the top price in its
-- top-left corner, the Days | Scans words in its top-right, and two textures per slot (the
-- low's bar and the faint range band), enough for the longest history and for SCANS_KEPT. What
-- it shows ("Daily low, 14 days") is in its hover tip. Chart.Show places as many as it needs.
-- @param parent the panel it belongs to
-- @param width the chart's width
-- @param height the chart's height
-- @return the chart frame, with bars, bands, barArea, topText, caption, viewWords and emptyText
function Chart.Build(parent, width, height)
    local chart = CreateFrame("Frame", nil, parent)
    chart:SetSize(width, height)
    local background = chart:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(chart)
    background:SetColorTexture(0, 0, 0, 0.3)
    chart.topText = U.Cell(chart, "GameFontHighlightSmall", "LEFT")
    chart.topText:SetPoint("TOPLEFT", chart, "TOPLEFT", 3, -2)
    -- What the chart shows; kept for the hover tip, not drawn (the view words use that corner).
    chart.caption = U.Cell(chart, "GameFontDisableSmall", "RIGHT")
    chart.caption:Hide()
    chart.viewWords = { days = ViewWord(chart, "days"), scans = ViewWord(chart, "scans") }
    chart.viewWords.scans:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -3, -2)
    local bar = U.Cell(chart, "GameFontDisableSmall", "RIGHT")
    bar:SetText("|")
    bar:SetPoint("RIGHT", chart.viewWords.scans, "LEFT", -3, 0)
    chart.viewWords.days:SetPoint("RIGHT", bar, "LEFT", -3, 0)
    chart.emptyText = U.Cell(chart, "GameFontDisableSmall", "LEFT")
    chart.emptyText:SetPoint("LEFT", chart, "LEFT", 6, -6)
    chart.emptyText:SetPoint("RIGHT", chart, "RIGHT", -6, -6)
    chart.emptyText:SetText("Scans show from your next scan.")
    chart.emptyText:Hide()
    chart:EnableMouse(true)
    chart:SetScript("OnEnter", ShowChartTip)
    chart:SetScript("OnLeave", HideChartTip)
    -- Room under the top line for the bars.
    chart.barArea = height - 18
    chart.chartWidth = width
    chart.bars, chart.bands = {}, {}
    local slots = math.max(Price.HISTORY_CHOICES[#Price.HISTORY_CHOICES], Price.SCANS_KEPT)
    for index = 1, slots do
        local barTexture = chart:CreateTexture(nil, "ARTWORK")
        barTexture:Hide()
        local band = chart:CreateTexture(nil, "ARTWORK")
        band:SetColorTexture(CHART_RANGE_COLOR[1], CHART_RANGE_COLOR[2], CHART_RANGE_COLOR[3], CHART_RANGE_COLOR[4])
        band:Hide()
        chart.bars[index], chart.bands[index] = barTexture, band
    end
    Chart.built[#Chart.built + 1] = chart
    chart:Hide()
    return chart
end

-- The house overview chart: items listed a day in blue (the last scan's day in gold), the
-- normal range around the trend line as a faint band, the trend line in white, and the next
-- day's estimate in purple, so it doesn't read as one more day.
local OVERVIEW_BAND_COLOR = { 1, 1, 1, 0.12 }
local OVERVIEW_LINE_COLOR = { 1, 1, 1, 0.8 }
local OVERVIEW_NEXT_COLOR = { 0.72, 0.45, 1, 0.85 }

--- Draws the house overview: one bar per day's items listed, on an axis that starts a little
-- under the lowest day so day-to-day changes show; the trend line and its normal range (one
-- standard deviation around it) once there are enough days; and the next day's estimate.
-- @param chart a chart from Chart.BuildOverview
-- @param overview from PriceLedger.HouseOverview
function Chart.ShowOverview(chart, overview)
    local slots = overview.slots
    local count = #slots + (overview.projection and 1 or 0)
    local spread = overview.residual or 0
    local low, high = overview.low, overview.top
    if overview.fit then
        for x = 1, count do
            low = math.min(low, overview.fit(x) - spread)
            high = math.max(high, overview.fit(x) + spread)
        end
    end
    -- The axis starts below the lowest value by half the data's range, never under 0.
    local bottom = high > low and math.max(0, low - (high - low) / 2) or 0
    local area = chart.barArea
    --- Height in pixels of a value on this axis, kept inside the bar area.
    local function Height(value)
        return math.min(area, math.max(0, (value - bottom) / (high - bottom) * area))
    end
    local slotWidth = chart.chartWidth / count
    local barWidth = math.max(2, math.floor(slotWidth) - 2)
    --- The x of a slot's left edge inside the chart.
    local function Left(index)
        return math.floor((index - 1) * slotWidth) + 1
    end

    for index = 1, #chart.bars do
        chart.bars[index]:Hide()
        chart.bands[index]:Hide()
    end
    for index = 1, count do
        local bar, band = chart.bars[index], chart.bands[index]
        local slot = slots[index]
        local value = slot and slot.items or (index > #slots and overview.projection)
        if value then
            bar:ClearAllPoints()
            bar:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", Left(index), 2)
            bar:SetWidth(barWidth)
            bar:SetHeight(math.max(1, math.floor(Height(value) + 0.5)))
            local color = OVERVIEW_NEXT_COLOR
            if index == #slots then
                color = CHART_LATEST_COLOR
            elseif index < #slots then
                color = CHART_BAR_COLOR
            end
            bar:SetColorTexture(color[1], color[2], color[3], color[4])
            bar:Show()
        end
        if overview.residual and overview.residual > 0 then
            local center = overview.fit(index)
            local from = math.floor(Height(center - spread) + 0.5)
            local to = math.floor(Height(center + spread) + 0.5)
            if to > from then
                band:ClearAllPoints()
                band:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", Left(index) - 1, 2 + from)
                band:SetWidth(math.ceil(slotWidth))
                band:SetHeight(to - from)
                band:Show()
            end
        end
    end
    chart.slotCount = count
    if chart.line then
        if overview.fit then
            local half = slotWidth / 2
            chart.line:SetStartPoint("BOTTOMLEFT", chart, half, 2 + Height(overview.fit(1)))
            chart.line:SetEndPoint("BOTTOMLEFT", chart, (count - 1) * slotWidth + half, 2 + Height(overview.fit(count)))
            chart.line:Show()
        else
            chart.line:Hide()
        end
    end
    chart.topText:SetText(Price.Thousands(high))
    chart.caption:SetText("Items listed, " .. #slots .. " days")
    chart:Show()
end

--- Sets a chart's size, and the width and bar height the next Show or ShowOverview draws in.
-- @param chart a chart from Chart.Build or Chart.BuildOverview
-- @param width the new width
-- @param height the new height
function Chart.Resize(chart, width, height)
    chart:SetSize(width, height)
    chart.chartWidth = width
    chart.barArea = height - 18
end

--- Makes the house overview chart, hidden until Chart.ShowOverview fills it: a dark box, the top
-- of its axis in the corner, a bar and a band texture per day slot plus one for the estimate,
-- and the trend line when the client can draw lines.
-- @param parent the panel it belongs to
-- @param width the chart's width
-- @param height the chart's height
-- @return the chart frame, with bars, bands, line, barArea, topText and caption
function Chart.BuildOverview(parent, width, height)
    local chart = CreateFrame("Frame", nil, parent)
    chart:SetSize(width, height)
    local background = chart:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(chart)
    background:SetColorTexture(0, 0, 0, 0.3)
    chart.topText = U.Cell(chart, "GameFontHighlightSmall", "LEFT")
    chart.topText:SetPoint("TOPLEFT", chart, "TOPLEFT", 3, -2)
    chart.caption = U.Cell(chart, "GameFontDisableSmall", "RIGHT")
    chart.caption:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -3, -2)
    chart.barArea = height - 18
    chart.chartWidth = width
    chart.bars, chart.bands = {}, {}
    local slots = Price.HISTORY_CHOICES[#Price.HISTORY_CHOICES] + 1
    for index = 1, slots do
        chart.bands[index] = chart:CreateTexture(nil, "BORDER")
        chart.bands[index]:SetColorTexture(OVERVIEW_BAND_COLOR[1], OVERVIEW_BAND_COLOR[2], OVERVIEW_BAND_COLOR[3],
            OVERVIEW_BAND_COLOR[4])
        chart.bands[index]:Hide()
        chart.bars[index] = chart:CreateTexture(nil, "ARTWORK")
        chart.bars[index]:Hide()
    end
    if type(chart.CreateLine) == "function" then
        chart.line = chart:CreateLine(nil, "OVERLAY")
        chart.line:SetThickness(2)
        chart.line:SetColorTexture(OVERVIEW_LINE_COLOR[1], OVERVIEW_LINE_COLOR[2], OVERVIEW_LINE_COLOR[3],
            OVERVIEW_LINE_COLOR[4])
        chart.line:Hide()
    end
    chart:Hide()
    return chart
end
