--[[
The price chart, used by Buy, Market, Sell and Price Check: one bar per day's lowest price with a
faint band up to its highest, or one bar per saved scan, picked with the Days and Scans buttons in its
corner (one saved choice for every chart), with a trend line, its normal range and a projection for the
next day or scan (PriceLedger.ChartFit). And the house overview chart (items listed a day, with the
same three) on Buy. Both draw saved data only.
]]

local _, ns = ...
local Price, U, Chart = ns.Price, ns.U, ns.Chart

-- Bar colors: earlier days blue, the latest day gold, a day's range a faint band above its low.
local CHART_BAR_COLOR = { 0.35, 0.6, 1, 0.9 }
local CHART_LATEST_COLOR = { 1, 0.82, 0, 1 }
local CHART_RANGE_COLOR = { 0.35, 0.6, 1, 0.3 }
-- Both kinds of chart: the normal range around the trend line as a shaded band behind the bars,
-- the trend line in white, and the next day's (or scan's) projection in purple, so it doesn't
-- read as one more bar.
local TREND_BAND_COLOR = { 1, 1, 1, 0.2 }
-- A bar cut at the top of the axis (PriceLedger.ChartCap) gets a white tip this tall.
local CUT_TIP_COLOR = { 1, 1, 1, 0.95 }
local CUT_TIP_HEIGHT = 3
local TREND_LINE_COLOR = { 1, 1, 1, 0.8 }
local ESTIMATE_COLOR = { 0.72, 0.45, 1, 0.85 }

-- Extra space between two days' scans on the scan view, in pixels.
local CHART_DAY_GAP = 3
-- The view buttons: small game buttons, the one in use lit. What each says, by view.
local VIEW_WORDS = { days = "Days", scans = "Scans" }
local VIEW_BUTTON_WIDTH = 40
local VIEW_BUTTON_HEIGHT = 16
-- The chart width the top price can't use: its 3 px inset, the 4 px gap before the Days button,
-- and the two buttons (1 px from the corner, 2 px apart). Chart.Build anchors them that way.
local TOP_TEXT_MARGIN = 3 + 4 + VIEW_BUTTON_WIDTH + 2 + VIEW_BUTTON_WIDTH + 1

-- The price charts Chart.Build made, so a view change redraws every one on screen.
Chart.built = {}

--- Draws the trend line and its normal range on a price chart, on the bars' axis: the band from
-- the first bar to the last slot (the projection included), reaching each next slot so it runs on
-- across a day gap; the line from the first bar's middle to the last slot's. Where the line would
-- go under 0, it stops at 0 instead. Hides both without a fit.
-- @param chart a chart from Chart.Build
-- @param fit from PriceLedger.ChartFit, or nil
-- @param count slots drawn, the projection included
-- @param Left the x of a slot's left edge, as DrawBars places bars
-- @param Height the height in pixels of a price on the axis
-- @param barWidth the bars' width
local function DrawTrend(chart, fit, count, Left, Height, barWidth)
    for index = 1, #chart.trendBands do
        chart.trendBands[index]:Hide()
    end
    if chart.line then
        chart.line:Hide()
    end
    if fit == nil then
        return
    end
    local spread = fit.spread
    if spread > 0 then
        for index = fit.first, count do
            local center = fit.fit(index)
            local from = math.floor(Height(center - spread) + 0.5)
            local to = math.floor(Height(center + spread) + 0.5)
            if to > from then
                local band = chart.trendBands[index]
                local left = Left(index) - 1
                local right = index < count and Left(index + 1) - 1 or Left(index) + barWidth + 1
                band:ClearAllPoints()
                band:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", left, 2 + from)
                band:SetWidth(right - left)
                band:SetHeight(to - from)
                band:Show()
            end
        end
    end
    if chart.line == nil then
        return
    end
    --- The x of a slot's middle; a fraction of a slot lies that far towards the next one.
    local function Middle(slot)
        local whole = math.floor(slot)
        local x = Left(whole) + barWidth / 2
        if whole < count then
            x = x + (slot - whole) * (Left(whole + 1) - Left(whole))
        end
        return x
    end
    -- The line is above 0 at one bar at least (half the bars are on or under it), so only one
    -- end can need moving to where it crosses 0.
    local from, to = fit.first, count
    if fit.fit(from) < 0 then
        from = -fit.intercept / fit.slope
    elseif fit.fit(to) < 0 then
        to = -fit.intercept / fit.slope
    end
    chart.line:SetStartPoint("BOTTOMLEFT", chart, Middle(from), 2 + Height(fit.fit(from)))
    chart.line:SetEndPoint("BOTTOMLEFT", chart, Middle(to), 2 + Height(fit.fit(to)))
    chart.line:Show()
end

--- Draws bars from chart slots: one bar per filled slot's low, a faint band up to its high, the
-- last slot in gold. A slot that starts a new day gets CHART_DAY_GAP more space before it when
-- `dayGaps` is set. With a fit, also the trend line and its normal range (DrawTrend), and the
-- projection as one more bar in purple, a gap apart. The axis runs from 0 to the highest of the
-- prices, the line's range and the projection, but stops at PriceLedger.ChartCap: a bar past it
-- is cut at the top with a white tip, and `chart.cutHigh` keeps the highest such price for the tip.
-- @param chart a chart from Chart.Build
-- @param slots the slots, oldest first; a slot without `low` is left empty
-- @param top the highest price in the slots
-- @param dayGaps true to space out days (the scan view)
-- @param fit from PriceLedger.ChartFit for these slots, or nil
-- @return the top of the axis
local function DrawBars(chart, slots, top, dayGaps, fit)
    local estimate = fit and fit.estimate
    local count = #slots + (estimate and 1 or 0)
    -- Which slots start a new day, and how many gaps come before each slot.
    local gapsBefore, gaps, lastDay = {}, 0, nil
    for index, slot in ipairs(slots) do
        if dayGaps and slot.dayKey and lastDay and slot.dayKey ~= lastDay then
            gaps = gaps + 1
        end
        lastDay = slot.dayKey or lastDay
        gapsBefore[index] = gaps
    end
    if estimate then
        gaps = gaps + 1
        gapsBefore[count] = gaps
    end
    if fit then
        -- A straight line is highest at one of its ends; the top stays a whole copper, as it's shown.
        top = math.ceil(math.max(top, fit.fit(fit.first) + fit.spread, fit.fit(count) + fit.spread))
        top = math.min(top, Price.ChartCap(slots, fit, count))
    end
    chart.cutHigh = nil
    for index = 1, #chart.cutTips do
        chart.cutTips[index]:Hide()
    end
    local area = chart.barArea
    local slotWidth = (chart.chartWidth - gaps * CHART_DAY_GAP) / math.max(1, count)
    local barWidth = math.max(2, math.floor(slotWidth) - 2)
    --- The x of a slot's left edge inside the chart.
    local function Left(index)
        return math.floor((index - 1) * slotWidth + gapsBefore[index] * CHART_DAY_GAP) + 1
    end
    --- Height in pixels of a price on this axis, kept inside the bar area.
    local function Height(value)
        return math.min(area, math.max(0, value / top * area))
    end
    for index = count + 1, #chart.bars do
        chart.bars[index]:Hide()
        chart.bands[index]:Hide()
    end
    chart.slotCount = count
    for index, slot in ipairs(slots) do
        local bar, band = chart.bars[index], chart.bands[index]
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", Left(index), 2)
        bar:SetWidth(barWidth)
        band:SetWidth(barWidth)
        if slot.low then
            local low = math.max(1, math.floor(Height(slot.low) + 0.5))
            local high = math.floor(Height(slot.high) + 0.5)
            bar:SetHeight(low)
            local color = index == #slots and CHART_LATEST_COLOR or CHART_BAR_COLOR
            bar:SetColorTexture(color[1], color[2], color[3], color[4])
            bar:Show()
            if slot.low > top then
                local tip = chart.cutTips[index]
                tip:ClearAllPoints()
                tip:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
                tip:SetWidth(barWidth)
                tip:SetHeight(CUT_TIP_HEIGHT)
                tip:Show()
                chart.cutHigh = math.max(chart.cutHigh or 0, slot.low)
            end
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
    if estimate then
        local bar = chart.bars[count]
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", Left(count), 2)
        bar:SetWidth(barWidth)
        bar:SetHeight(math.max(1, math.floor(Height(estimate) + 0.5)))
        bar:SetColorTexture(ESTIMATE_COLOR[1], ESTIMATE_COLOR[2], ESTIMATE_COLOR[3], ESTIMATE_COLOR[4])
        bar:Show()
        chart.bands[count]:Hide()
    end
    DrawTrend(chart, fit, count, Left, Height, barWidth)
    return top
end

--- Shows which view is in use: its button stays lit, as if under the mouse.
-- @param chart a chart from Chart.Build
-- @param view one of PriceLedger.CHART_VIEWS
local function MarkView(chart, view)
    for name, button in pairs(chart.viewButtons) do
        if name == view then
            button:LockHighlight()
        else
            button:UnlockHighlight()
        end
    end
end

-- Chart prices from 1 gold up leave out the copper, like the day lines (two coins at most).
local CHART_COIN = 100

--- Writes the axis's top price, rounded when the whole price can't fit left of the view buttons.
-- @param chart from Chart.Build
-- @param top copper at the top of the axis
local function SetTopPrice(chart, top)
    U.FitMoney(chart.topText, chart.chartWidth - TOP_TEXT_MARGIN, function(coins)
        return coins(Price.RoundCoins(top, CHART_COIN))
    end)
end

--- Draws an item's saved prices on a chart, in the saved view.
-- Days: one bar per day's low with a faint band up to its high, one slot per day from the item's
-- oldest saved day (at least 7, at most the history length), so it grows as the history does.
-- Scans: one bar per saved scan (at most PriceLedger.SCANS_KEPT), with a little space between
-- days; an item saved before scans were kept says when they start instead.
-- The latest bar is gold. Both views add the trend line, its normal range and a purple projection for
-- the next day or scan from CHART_FIT_MIN_POINTS bars (PriceLedger.ChartFit). Hides the chart
-- when there is no item.
-- Saved data only.
-- @param chart a chart from Chart.Build
-- @param info the item's saved prices from PriceLedger.Lookup, or nil
function Chart.Show(chart, info)
    chart.info = info
    local view = Price.ChartView(HouseLedgerDB)
    MarkView(chart, view)
    chart.span, chart.fit = nil, nil
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
        chart.fit, chart.nextWord = Price.ChartFit(data.slots), "scan"
        local top = DrawBars(chart, data.slots, data.top, true, chart.fit)
        chart.caption:SetText("Each scan, " .. data.count .. (data.count == 1 and " scan" or " scans"))
        chart.span = Price.ScanSpanText(data)
        SetTopPrice(chart, top)
        chart:Show()
        return
    end
    local data = info and Price.ChartDays(info.days, info.seen)
    if data == nil or data.top <= 0 then
        chart:Hide()
        return
    end
    chart.fit = Price.ChartFit(data.slots)
    chart.nextWord = data.perBar > 1 and data.perBar .. " days" or "day"
    local top = DrawBars(chart, data.slots, data.top, false, chart.fit)
    chart.caption:SetText("Daily low, " .. data.days .. " days"
        .. (data.perBar > 1 and " (" .. data.perBar .. " days per bar)" or ""))
    SetTopPrice(chart, top)
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

--- Hover tip for a price chart: what it shows, what its line, band and purple bar mean, and how
-- to switch.
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
    local fit = chart.fit
    if fit then
        GameTooltip:AddLine("White line: which way the price is going. One odd listing can't tilt it.",
            0.8, 0.8, 0.8, true)
        if fit.spread > 0 then
            GameTooltip:AddLine("Shaded band: its normal range.", 0.8, 0.8, 0.8)
        end
        if chart.cutHigh then
            GameTooltip:AddLine("White tip: too high to fit, up to "
                .. U.CopperToText(Price.RoundCoins(chart.cutHigh, CHART_COIN)) .. ".", 0.8, 0.8, 0.8, true)
        end
        if fit.estimate then
            GameTooltip:AddLine("Purple: a projection for the next " .. chart.nextWord .. ", "
                .. U.CopperToText(Price.RoundCoins(fit.estimate, CHART_COIN)) .. ".", ESTIMATE_COLOR[1], ESTIMATE_COLOR[2], ESTIMATE_COLOR[3])
        end
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

--- Makes one view button: a small game button that switches every price chart to its view.
-- @param chart the chart it sits on
-- @param view one of PriceLedger.CHART_VIEWS
-- @return the button
local function ViewButton(chart, view)
    local button = CreateFrame("Button", nil, chart, "UIPanelButtonTemplate")
    button:SetSize(VIEW_BUTTON_WIDTH, VIEW_BUTTON_HEIGHT)
    button:SetNormalFontObject("GameFontNormalSmall")
    button:SetHighlightFontObject("GameFontHighlightSmall")
    button:SetText(VIEW_WORDS[view])
    button:SetScript("OnClick", function()
        Chart.SetView(view)
        ShowChartTip(chart)
    end)
    button:SetScript("OnEnter", function()
        ShowChartTip(chart)
    end)
    button:SetScript("OnLeave", HideChartTip)
    return button
end

--- Makes a price chart, hidden until Chart.Show fills it: a dark box, the top of its axis in its
-- top-left corner, the Days and Scans buttons in its top-right, three textures per slot (the low's
-- bar, the faint range band and the trend line's normal range), enough for the longest history
-- and for SCANS_KEPT plus the projection, and the trend line when the client can draw lines. What it
-- shows ("Daily low, 14 days") is in its hover tip. Chart.Show places as many as it needs.
-- @param parent the panel it belongs to
-- @param width the chart's width
-- @param height the chart's height
-- @return the chart frame, with bars, bands, trendBands, line, barArea, topText, caption,
--   viewButtons and emptyText
function Chart.Build(parent, width, height)
    local chart = CreateFrame("Frame", nil, parent)
    chart:SetSize(width, height)
    local background = chart:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(chart)
    background:SetColorTexture(0, 0, 0, 0.3)
    chart.topText = U.Cell(chart, "GameFontHighlightSmall", "LEFT")
    chart.topText:SetPoint("TOPLEFT", chart, "TOPLEFT", 3, -2)
    -- What the chart shows; kept for the hover tip, not drawn (the view buttons use that corner).
    chart.caption = U.Cell(chart, "GameFontDisableSmall", "RIGHT")
    chart.caption:Hide()
    chart.viewButtons = { days = ViewButton(chart, "days"), scans = ViewButton(chart, "scans") }
    chart.viewButtons.scans:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -1, -1)
    chart.viewButtons.days:SetPoint("RIGHT", chart.viewButtons.scans, "LEFT", -2, 0)
    -- A long price is cut short before it reaches the buttons.
    chart.topText:SetPoint("RIGHT", chart.viewButtons.days, "LEFT", -4, 0)
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
    chart.bars, chart.bands, chart.trendBands, chart.cutTips = {}, {}, {}, {}
    -- One more slot than the most days or scans, for the projection.
    local slots = math.max(Price.CHART_MAX_BARS, Price.SCANS_KEPT) + 1
    for index = 1, slots do
        local barTexture = chart:CreateTexture(nil, "ARTWORK")
        barTexture:Hide()
        local band = chart:CreateTexture(nil, "ARTWORK")
        band:SetColorTexture(CHART_RANGE_COLOR[1], CHART_RANGE_COLOR[2], CHART_RANGE_COLOR[3], CHART_RANGE_COLOR[4])
        band:Hide()
        -- Behind the bars, so the bars and their day ranges stay clear on top of it.
        local trendBand = chart:CreateTexture(nil, "BORDER")
        trendBand:SetColorTexture(TREND_BAND_COLOR[1], TREND_BAND_COLOR[2], TREND_BAND_COLOR[3], TREND_BAND_COLOR[4])
        trendBand:Hide()
        chart.bars[index], chart.bands[index], chart.trendBands[index] = barTexture, band, trendBand
        local cutTip = chart:CreateTexture(nil, "OVERLAY")
        cutTip:SetColorTexture(CUT_TIP_COLOR[1], CUT_TIP_COLOR[2], CUT_TIP_COLOR[3], CUT_TIP_COLOR[4])
        cutTip:Hide()
        chart.cutTips[index] = cutTip
    end
    if type(chart.CreateLine) == "function" then
        chart.line = chart:CreateLine(nil, "OVERLAY")
        chart.line:SetThickness(2)
        chart.line:SetColorTexture(TREND_LINE_COLOR[1], TREND_LINE_COLOR[2], TREND_LINE_COLOR[3], TREND_LINE_COLOR[4])
        chart.line:Hide()
    end
    Chart.built[#Chart.built + 1] = chart
    chart:Hide()
    return chart
end

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
            local color = ESTIMATE_COLOR
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
    local slots = Price.CHART_MAX_BARS + 1
    for index = 1, slots do
        chart.bands[index] = chart:CreateTexture(nil, "BORDER")
        chart.bands[index]:SetColorTexture(TREND_BAND_COLOR[1], TREND_BAND_COLOR[2], TREND_BAND_COLOR[3],
            TREND_BAND_COLOR[4])
        chart.bands[index]:Hide()
        chart.bars[index] = chart:CreateTexture(nil, "ARTWORK")
        chart.bars[index]:Hide()
    end
    if type(chart.CreateLine) == "function" then
        chart.line = chart:CreateLine(nil, "OVERLAY")
        chart.line:SetThickness(2)
        chart.line:SetColorTexture(TREND_LINE_COLOR[1], TREND_LINE_COLOR[2], TREND_LINE_COLOR[3],
            TREND_LINE_COLOR[4])
        chart.line:Hide()
    end
    chart:Hide()
    return chart
end
