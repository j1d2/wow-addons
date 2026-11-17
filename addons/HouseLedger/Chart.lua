--[[
The price chart (one bar per day's lowest price with a faint band up to its highest), used by
Buy, Market, Sell and Price Check, and the house overview chart (items listed a day, with a trend
line) on Buy. Both draw saved data only.
]]

local _, ns = ...
local Price, U, Chart = ns.Price, ns.U, ns.Chart

-- Bar colors: earlier days blue, the latest day gold, a day's range a faint band above its low.
local CHART_BAR_COLOR = { 0.35, 0.6, 1, 0.9 }
local CHART_LATEST_COLOR = { 1, 0.82, 0, 1 }
local CHART_RANGE_COLOR = { 0.35, 0.6, 1, 0.3 }

--- Draws an item's saved days on a chart: one bar per day's low, a faint band up to its high,
-- the latest day in gold. The chart has one slot per day from the item's oldest saved day (at
-- least 7, at most the history length), so it grows as the history does. Hides the chart when
-- there is nothing to draw. Saved data only.
-- @param chart a chart from Chart.Build
-- @param info the item's saved prices from PriceLedger.Lookup, or nil
function Chart.Show(chart, info)
    local data = info and Price.ChartDays(info.days, info.seen)
    if data == nil or data.top <= 0 then
        chart:Hide()
        return
    end
    local slotWidth = chart.chartWidth / #data.slots
    local barWidth = math.max(2, math.floor(slotWidth) - 2)
    for index = #data.slots + 1, #chart.bars do
        chart.bars[index]:Hide()
        chart.bands[index]:Hide()
    end
    chart.slotCount = #data.slots
    chart.caption:SetText("Daily low, " .. #data.slots .. " days")
    for index, slot in ipairs(data.slots) do
        local bar, band = chart.bars[index], chart.bands[index]
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", math.floor((index - 1) * slotWidth) + 1, 2)
        bar:SetWidth(barWidth)
        band:SetWidth(barWidth)
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
    chart.topText:SetText(U.CopperToText(data.top))
    chart:Show()
end

--- Makes a price chart, hidden until Chart.Show fills it: a dark box, the top price in its
-- corner, and two textures per day slot (the low's bar and the faint range band), enough for the
-- longest history. Chart.Show places as many as the item's chart has days.
-- @param parent the panel it belongs to
-- @param width the chart's width
-- @param height the chart's height
-- @return the chart frame, with bars, bands, barArea and topText
function Chart.Build(parent, width, height)
    local chart = CreateFrame("Frame", nil, parent)
    chart:SetSize(width, height)
    local background = chart:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(chart)
    background:SetColorTexture(0, 0, 0, 0.3)
    chart.topText = U.Cell(chart, "GameFontHighlightSmall", "LEFT")
    chart.topText:SetPoint("TOPLEFT", chart, "TOPLEFT", 3, -2)
    local caption = U.Cell(chart, "GameFontDisableSmall", "RIGHT")
    caption:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -3, -2)
    chart.caption = caption
    -- Room under the top line for the bars.
    chart.barArea = height - 18
    chart.chartWidth = width
    chart.bars, chart.bands = {}, {}
    local longest = Price.HISTORY_CHOICES[#Price.HISTORY_CHOICES]
    for index = 1, longest do
        local bar = chart:CreateTexture(nil, "ARTWORK")
        bar:Hide()
        local band = chart:CreateTexture(nil, "ARTWORK")
        band:SetColorTexture(CHART_RANGE_COLOR[1], CHART_RANGE_COLOR[2], CHART_RANGE_COLOR[3], CHART_RANGE_COLOR[4])
        band:Hide()
        chart.bars[index], chart.bands[index] = bar, band
    end
    chart:Hide()
    return chart
end

-- The house overview chart: items listed a day in blue (the last scan's day in gold), the
-- normal range around the trend line as a faint band, the trend line in white, and the next
-- day's estimate as a faint gold bar.
local OVERVIEW_BAND_COLOR = { 1, 1, 1, 0.12 }
local OVERVIEW_LINE_COLOR = { 1, 1, 1, 0.8 }
local OVERVIEW_NEXT_COLOR = { 1, 0.82, 0, 0.35 }

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
