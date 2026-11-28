--[[
Personal auction-house helper for WoW Forever.

Search: one click sends one browse query, and only when Blizzard's
throttle says another query is allowed.

Scan: one click asks for the whole house once. Blizzard allows that
about every 15 minutes. Listings are read across frames. The lowest
buyout per item is saved on this computer and shown on item mouseovers.
Seller names are not saved.

Buy: an item's Listings, then Buy and Confirm, each the player's own
click (Purchase.lua). This addon does not post, bid, or cancel, and it
does not scan when the auction house opens.
]]

local ADDON_NAME, ns = ...
local C, ui, state, Price, U, Scan, Tooltip, Buy, Sell, Purchase, Post, PC, History, Auctions, Window = ns.C, ns.ui,
    ns.state, ns.Price, ns.U, ns.Scan, ns.Tooltip, ns.Buy, ns.Sell, ns.Purchase, ns.Post, ns.PC, ns.History,
    ns.Auctions, ns.Window

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
-- Answers to a buy (Purchase.lua): each handler checks the buy is one started here.
eventFrame:RegisterEvent("COMMODITY_PRICE_UPDATED")
eventFrame:RegisterEvent("COMMODITY_PRICE_UNAVAILABLE")
eventFrame:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
eventFrame:RegisterEvent("COMMODITY_PURCHASE_FAILED")
eventFrame:RegisterEvent("AUCTION_HOUSE_PURCHASE_COMPLETED")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW_ERROR")
-- The house's answers to a post from the Sell tab.
eventFrame:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")
eventFrame:RegisterEvent("AUCTION_HOUSE_POST_ERROR")
-- The mailbox: the History tab reads auction house mail while it is open (reads only).
eventFrame:RegisterEvent("MAIL_INBOX_UPDATE")
-- This character's auctions, asked by the Auctions tab or by Blizzard's own (read only).
eventFrame:RegisterEvent("OWNED_AUCTIONS_UPDATED")

-- The buy answers and the handler each one goes to; COMMODITY_PRICE_UPDATED also passes arg2.
local PURCHASE_EVENTS = {
    COMMODITY_PRICE_UPDATED = "OnPriceUpdated",
    COMMODITY_PRICE_UNAVAILABLE = "OnPriceUnavailable",
    COMMODITY_PURCHASE_SUCCEEDED = "OnPurchaseSucceeded",
    COMMODITY_PURCHASE_FAILED = "OnPurchaseFailed",
    AUCTION_HOUSE_PURCHASE_COMPLETED = "OnAuctionBought",
    AUCTION_HOUSE_SHOW_ERROR = "OnHouseError",
}

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
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
        -- The auctioneer is the npc unit now: a goblin one makes the window read the goblin house.
        state.openHouseKey = U.CurrentScanKey()
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
        -- The house the window reads may have changed (a goblin auctioneer), and time has passed.
        Auctions.Render()
        return
    end

    if event == "AUCTION_HOUSE_AUCTION_CREATED" then
        Post.OnAuctionCreated()
        return
    elseif event == "AUCTION_HOUSE_POST_ERROR" then
        Post.OnPostError()
        return
    end

    if event == "OWNED_AUCTIONS_UPDATED" then
        Auctions.OnOwnedUpdated()
        return
    end

    if event == "MAIL_INBOX_UPDATE" then
        History.ReadInbox()
        return
    end

    if PURCHASE_EVENTS[event] then
        Purchase[PURCHASE_EVENTS[event]](arg1, arg2)
        if event == "AUCTION_HOUSE_SHOW_ERROR" then
            -- A refused buy is answered this way; a refused post may be too.
            Post.OnPostError()
        end
        return
    end

    if event == "AUCTION_HOUSE_CLOSED" then
        state.openHouseKey = nil
        -- Leaving the house ends its listings and drops a price it quoted.
        Purchase.Close()
        Post.Close()
        Buy.HideRecent()
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

    -- Item search results: the Sell tab's item, or the listings Buy or Market asked for. Each
    -- checks the results are for its own search.
    if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        Sell.OnCommodityResults(arg1)
        Purchase.OnCommodityResults(arg1)
        return
    end

    if event == "ITEM_SEARCH_RESULTS_UPDATED" then
        Sell.OnItemResults(arg1)
        Purchase.OnItemResults(arg1)
    end
end)
