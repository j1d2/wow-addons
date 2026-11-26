--[[
The full scan: one Scan click asks the house once (ReplicateItems), then the listings are read
across frames and saved through PriceLedger.Commit. At most once each 15 minutes.
]]

local _, ns = ...
local C, ui, state, Price, U, Buy, Scan = ns.C, ns.ui, ns.state, ns.Price, ns.U, ns.Buy, ns.Scan

-- Stay under the roughly 2000 replicate reads per frame that start
-- getting dropped. count, buyout, and item id are already filled in.
local READ_BATCH = 500
-- Bumped on every stop, so a pending batch from an old read does nothing.
local readToken = 0
-- Until then the idle refresh leaves the scan line's message alone.
local holdStatusUntil = 0
-- The house the current read saves to.
local scanHouseKey

--- Sets the scan line at the bottom of the window.
-- @param text the line's text
-- @param holdSeconds optional; keeps the idle refresh from replacing the text this long
function Scan.SetStatus(text, holdSeconds)
    if ui.scanText then
        ui.scanText:SetText(text)
    end
    if holdSeconds and holdSeconds > 0 then
        holdStatusUntil = time() + holdSeconds
    end
end

--- Updates the Scan button while no scan runs: "Scan" and enabled when a scan is allowed,
-- otherwise greyed out with the wait, like "Scan (12m)". Only the button's own text and state
-- change; nothing is sent.
function Scan.RefreshButton()
    -- In combat the game may count our window's widgets as protected; then it waits for the end.
    if not ui.scanButton or state.scanState ~= "idle" or U.Locked(ui.scanButton) then
        return
    end
    local wait = Price.SecondsUntil(HouseLedgerDB.replicateAt, time())
    local text = Price.ScanButtonText(wait)
    if ui.scanButton:GetText() ~= text then
        ui.scanButton:SetText(text)
    end
    if wait > 0 then
        ui.scanButton:Disable()
    else
        ui.scanButton:Enable()
    end
end

--- Shows the read's progress bar at a number of listings read, or hides it.
-- @param read listings read so far, or nil to hide the bar
-- @param total how many listings the house sent
function Scan.ShowProgress(read, total)
    if not ui.scanBar or U.Locked(ui.scanBar) then
        return
    end
    if read == nil or total == nil or total <= 0 then
        ui.scanBar:Hide()
        return
    end
    ui.scanBar:SetMinMaxValues(0, total)
    ui.scanBar:SetValue(read)
    ui.scanBar:Show()
end

--- Updates the scan line while no scan is running.
-- Shows how many prices the player's house has and when the next scan is
-- allowed. Does nothing while a scan runs or a held message is still up.
function Scan.RefreshIdleLine()
    if state.scanState ~= "idle" or time() < holdStatusUntil then
        return
    end
    local wait = Price.SecondsUntil(HouseLedgerDB.replicateAt, time())
    local key = U.ViewHouseKey()
    local house = HouseLedgerDB.houses and HouseLedgerDB.houses[key]
    local priced = 0
    if type(house) == "table" and type(house.items) == "table" then
        for _ in pairs(house.items) do
            priced = priced + 1
        end
    end
    local label = Price.HouseLabel(key)
    if wait > 0 and priced > 0 then
        Scan.SetStatus(string.format(
            "%s prices (%s). Next scan in %s.",
            Price.Thousands(priced), label, U.RemainingText(wait)
        ))
        return
    end
    if priced > 0 then
        Scan.SetStatus(string.format("%s prices (%s). Scan is ready.", Price.Thousands(priced), label))
        return
    end
    if wait > 0 then
        Scan.SetStatus("Next scan in " .. U.RemainingText(wait) .. ".")
        return
    end
    Scan.SetStatus("No prices saved yet. Click Scan once.")
end

--- Ends the scan: back to idle with Scan enabled, and a pending read batch does nothing.
function Scan.StopReading()
    readToken = readToken + 1
    state.scanState = "idle"
    Scan.ShowProgress(nil)
    Scan.RefreshButton()
end

--- Saves a finished read and says how many prices were saved.
-- @param token the read's token; a stale one does nothing
-- @param best the lowest-price table built by PriceLedger.Consider
local function FinishRead(token, best, totals)
    if token ~= readToken or state.scanState ~= "reading" then
        return
    end
    if next(best) == nil then
        Scan.StopReading()
        Scan.SetStatus("The house sent no listings. Nothing saved.", 8)
        return
    end
    local saved = Price.Commit(HouseLedgerDB, scanHouseKey, best, time(), totals)
    Scan.StopReading()
    if state.currentTab == C.MARKET_TAB then
        -- The Market lists come from the scan just saved.
        Buy.RefreshMarket()
        Buy.RenderRows()
    else
        Buy.RefreshOverview()
    end
    Scan.SetStatus(string.format("Saved %s prices (%s).", Price.Thousands(saved), Price.HouseLabel(scanHouseKey)), 8)
end

--- Reads one batch of READ_BATCH replicate listings, then the next on the next frame.
-- Stops if the house closed; saves through FinishRead after the last batch.
-- @param token the read's token; a stale one does nothing
-- @param index first listing to read, from 0
-- @param total how many listings the house sent
-- @param best the lowest-price table so far; changed in place
-- @param totals the scan's listings, units and value so far (PriceLedger.AddToTotals); changed in place
local function ReadListings(token, index, total, best, totals)
    if token ~= readToken or state.scanState ~= "reading" then
        return
    end
    if not U.HouseIsOpen() then
        Scan.StopReading()
        Scan.SetStatus("Scan stopped because the auction house closed. Next scan in 15 min.", 8)
        return
    end

    local last = math.min(index + READ_BATCH - 1, total - 1)
    for i = index, last do
        -- One call. The seller fields come back nil and are not stored.
        -- The item's name and quality are kept; the name is nil for an item the game hasn't loaded.
        local name, _, count, quality, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID =
            C_AuctionHouse.GetReplicateItemInfo(i)
        Price.Consider(best, itemID, count, buyout, name, quality)
        Price.AddToTotals(totals, count, buyout)
    end

    local nextIndex = last + 1
    if nextIndex >= total then
        FinishRead(token, best, totals)
        return
    end

    -- The next batch is scheduled first, so nothing that shows the progress can stop the read.
    C_Timer.After(0, function()
        ReadListings(token, nextIndex, total, best, totals)
    end)
    Scan.SetStatus(string.format("Reading listings %d of %d...", nextIndex, total))
    Scan.ShowProgress(nextIndex, total)
end

--- The full-scan answer came in: starts reading the listings for this house.
local function BeginRead()
    HouseLedgerDB.replicateAt = time()
    scanHouseKey = U.CurrentScanKey()
    local total = 0
    if C_AuctionHouse.GetNumReplicateItems then
        total = C_AuctionHouse.GetNumReplicateItems() or 0
    end
    state.scanState = "reading"
    readToken = readToken + 1
    state.acceptAnswerUntil = 0
    Scan.SetStatus(string.format("Reading %d listings...", total))
    Scan.ShowProgress(0, total)
    ReadListings(readToken, 0, total, {}, {})
end

--- Scan click: sends one full-house request, at most once each 15 minutes.
-- Sends nothing while a scan runs, with the house closed, without the scan
-- functions, or during the wait.
function Scan.Start()
    if state.scanState ~= "idle" then
        return
    end
    if not U.HouseIsOpen() then
        Scan.SetStatus("Open the auction house first.", 4)
        return
    end
    if C_AuctionHouse.ReplicateItems == nil or C_AuctionHouse.GetReplicateItemInfo == nil then
        Scan.SetStatus("This client has no full-scan function.", 8)
        return
    end

    local wait = Price.SecondsUntil(HouseLedgerDB.replicateAt, time())
    if wait > 0 then
        Scan.SetStatus("Next scan in " .. U.RemainingText(wait) .. ".", 4)
        return
    end

    state.scanState = "waiting"
    state.waitStarted = U.Clock()
    if ui.scanButton then
        ui.scanButton:Disable()
    end
    -- One click, one full-house request. No retry timer.
    -- Start the 15 minutes now: the request is out even if no answer comes.
    HouseLedgerDB.replicateAt = time()
    C_AuctionHouse.ReplicateItems()
    Scan.SetStatus("Asking the auction house for every listing...")
end

--- The full-scan answer event: reads it if a scan is expecting one.
-- An answer after the house closed is not read; the 15-minute wait starts again.
function Scan.OnReplicateList()
    local expecting = state.scanState == "waiting" or time() <= state.acceptAnswerUntil
    if not expecting then
        return
    end
    if not U.HouseIsOpen() then
        HouseLedgerDB.replicateAt = time()
        state.acceptAnswerUntil = 0
        if state.scanState ~= "idle" then
            Scan.StopReading()
        end
        Scan.SetStatus("The house answered after it closed. Next scan in 15 min.", 8)
        return
    end
    BeginRead()
end
