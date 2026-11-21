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

local ADDON_NAME, ns = ...
local C, ui, state, Price, U, Scan, Tooltip, Buy, Sell, PC, Window = ns.C, ns.ui, ns.state, ns.Price, ns.U, ns.Scan, ns.Tooltip, ns.Buy, ns.Sell, ns.PC, ns.Window

-- True while one refilter waits for the next frame, so a burst of item-info events filters once.
local refilterPending = false

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
        HouseLedgerDB = Price.EnsureDB(HouseLedgerDB)
        Tooltip.Hook()
        -- Price Check works anywhere, so it is built even on a client without the auction house.
        PC.Build()
        if C_AuctionHouse == nil then
            return
        end
        if C_AuctionHouse.SendBrowseQuery == nil and C_AuctionHouse.ReplicateItems == nil then
            return
        end
        if U.InCombat() then
            -- A /reload in combat: the window's tabs are protected, so it
            -- is built once combat ends.
            state.buildAfterCombat = true
            return
        end
        Window.Build()
        Tooltip.NoteUnavailable()
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        Window.OnCombatEnded()
        return
    end

    if event == "REPLICATE_ITEM_LIST_UPDATE" then
        if HouseLedgerDB == nil then
            return
        end
        Scan.OnReplicateList()
        return
    end

    if ui.frame == nil then
        return
    end

    if event == "AUCTION_HOUSE_SHOW" then
        -- Hooks Blizzard's window even in combat; the rest waits for it to end.
        Window.PlaceFrame(false)
        if U.InCombat() then
            state.afterCombat = true
            return
        end
        ui.frame:Show()
        ui.frame:Raise()
        Scan.RefreshIdleLine()
        if #Price.joined > 0 then
            -- Said once: this load joined scans saved under a blank realm name into the old history.
            Scan.SetStatus("Joined scans from after the game update into your saved history.", 12)
            Price.joined = {}
        end
        Buy.RefreshOverview()
        return
    end

    if event == "AUCTION_HOUSE_CLOSED" then
        if U.InCombat() then
            state.afterCombat = true
        else
            ui.frame:Hide()
        end
        if state.scanState == "waiting" then
            state.acceptAnswerUntil = time() + C.ANSWER_WAIT
        end
        if state.scanState == "waiting" or state.scanState == "reading" then
            local answered = state.scanState == "reading"
            Scan.StopReading()
            if answered then
                Scan.SetStatus("Scan stopped because the auction house closed. Next scan in 15 min.", 8)
            else
                Scan.SetStatus("Scan cancelled. Waiting to see if the house accepted it.", 8)
            end
        end
        return
    end

    if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        Buy.ShowResults()
        return
    end

    if event == "ITEM_KEY_ITEM_INFO_RECEIVED" or event == "GET_ITEM_INFO_RECEIVED" then
        -- An item's name, icon, quality or level arrived: filter again and redraw in place.
        -- Items arrive one event each, often many at once, so this waits one frame and does it once.
        if ui.frame == nil or not ui.frame:IsShown() or refilterPending then
            return
        end
        local market = state.currentTab == C.MARKET_TAB and ui.buyPanel.marketMode
        if market and event == "GET_ITEM_INFO_RECEIVED" then
            state.itemLevels[arg1] = nil -- ask again now that the game has it
            -- Only a filter or an ilvl sort needs the whole list again; otherwise redraw the rows
            -- in place, so the visible ilvl column fills in.
            if state.marketText == "" and not Price.FilterActive(state.filter) and state.marketSort.key ~= "ilvl" then
                Buy.RenderRows()
                return
            end
        end
        if not market and (#state.results == 0 or event ~= "ITEM_KEY_ITEM_INFO_RECEIVED") then
            return
        end
        refilterPending = true
        C_Timer.After(0, function()
            refilterPending = false
            if state.currentTab == C.MARKET_TAB and ui.buyPanel.marketMode then
                Buy.RefreshMarket()
            else
                Buy.FilterResults()
            end
            Buy.RenderRows()
        end)
        return
    end

    if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        Sell.OnCommodityResults(arg1)
        return
    end

    if event == "ITEM_SEARCH_RESULTS_UPDATED" then
        Sell.OnItemResults(arg1)
    end
end)
