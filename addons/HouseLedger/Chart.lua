--[[
The price chart: one bar per day's lowest price with a faint band up to its highest, drawn
from saved data only. Used by Buy, Market, Sell and Price Check.
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
