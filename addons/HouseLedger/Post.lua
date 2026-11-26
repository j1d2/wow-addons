--[[
Posting from the Sell tab: the item dropped on the Sell slot, a price filled in from the listings
(PriceLedger.PostPrice), how many, how long, and a Post button.

One Post click makes one post (the game's PostCommodity or PostItem), and only on the player's click.
A price warning (PriceLedger.PostWarnings) or the "Confirm before posting" setting turns the button
into a second click first; a warning click counts as the confirm, so it is never three clicks.
Stackables post as many as the player asks for; other items post one copy per click, until a test
shows that a post of several copies works on Forever.

Never Blizzard's sell window, its price box or its Post button: only our own button and the
C_AuctionHouse calls, which the policy check allows only in this file.
]]

local _, ns = ...
local C, ui, Price, U, Sell, Post = ns.C, ns.ui, ns.Price, ns.U, ns.Sell, ns.Post

-- Durations by the game's own names; the index is what PostCommodity and PostItem take.
local DURATION_NAMES = { "AUCTION_DURATION_ONE", "AUCTION_DURATION_TWO", "AUCTION_DURATION_THREE" }
local DURATION_FALLBACK = { "Short", "Medium", "Long" }
local DEFAULT_DURATION = 2
-- After a post is sent with no answer this long (seconds), it is taken as posted: whether the
-- house answers a post with AUCTION_HOUSE_AUCTION_CREATED on Forever isn't known yet.
local POST_ANSWER_WAIT = 5
local COPPER_PER_SILVER, COPPER_PER_GOLD = 100, 10000

-- The item on the Sell slot (Sell's pending item: itemID, name, commodity, location), its
-- listings cheapest first, and whether the price was filled in for it already.
local item
local tiers = {}
local prefilled = false
-- The post under way: { step = "warned" | "confirm" | "posting" | "needsConfirm", args, ... }.
local post

--- The game's name for a duration, or a plain one.
-- @param index 1, 2 or 3
-- @return the text
local function DurationText(index)
    local text = _G[DURATION_NAMES[index]]
    return type(text) == "string" and text or DURATION_FALLBACK[index]
end

--- The chosen duration index.
-- @return 1, 2 or 3
local function Duration()
    return HouseLedgerDB.settings.postDuration or DEFAULT_DURATION
end

--- The chosen pricing: "best", "fast" or "last".
-- @return the key
local function Pricing()
    return HouseLedgerDB.settings.postPricing or Price.POST_PRICING_ORDER[1]
end

--- The price in the gold, silver and copper boxes.
-- @return copper, or 0
local function TypedPrice()
    local boxes = ui.postPanel.priceBoxes
    local gold = tonumber(boxes.gold:GetText()) or 0
    local silver = tonumber(boxes.silver:GetText()) or 0
    local copper = tonumber(boxes.copper:GetText()) or 0
    return gold * COPPER_PER_GOLD + silver * COPPER_PER_SILVER + copper
end

--- Puts a price in the gold, silver and copper boxes (not the player's typing).
-- @param copper the price, or nil to empty them
local function SetPrice(copper)
    local boxes = ui.postPanel.priceBoxes
    if copper == nil then
        boxes.gold:SetText("")
        boxes.silver:SetText("")
        boxes.copper:SetText("")
        return
    end
    local gold = math.floor(copper / COPPER_PER_GOLD)
    local silver = math.floor((copper % COPPER_PER_GOLD) / COPPER_PER_SILVER)
    boxes.gold:SetText(gold > 0 and tostring(gold) or "")
    boxes.silver:SetText((gold > 0 or silver > 0) and tostring(silver) or "")
    boxes.copper:SetText(tostring(copper % COPPER_PER_SILVER))
end

--- How many of the item are in the bags to post, or 0.
-- @return the count
local function Available()
    if item == nil or item.location == nil or not C_Item.DoesItemExist(item.location) then
        return 0
    end
    if not item.commodity then
        return 1 -- one copy per click, for now
    end
    return C_AuctionHouse.GetAvailablePostCount(item.location) or 0
end

--- How many to post.
-- @return the count
local function Quantity()
    if item and not item.commodity then
        return 1
    end
    return tonumber(ui.postPanel.qtyBox:GetText()) or 0
end

--- The deposit for the post as it stands, or nil when the game can't say.
-- @return copper, or nil
local function Deposit()
    local quantity = Quantity()
    if item == nil or item.location == nil or quantity < 1 then
        return nil
    end
    if item.commodity then
        return C_AuctionHouse.CalculateCommodityDeposit(item.itemID, Duration(), quantity)
    end
    return C_AuctionHouse.CalculateItemDeposit(item.location, Duration(), 1)
end

--- The cheapest listing that isn't the player's own, or nil.
-- @return copper, or nil
local function CheapestOther()
    for _, tier in ipairs(tiers) do
        if not tier.own then
            return tier.price
        end
    end
end

--- What's risky about the price as it stands.
-- @return list of warning texts
local function Warnings()
    local vendor = select(11, C_Item.GetItemInfo(item.itemID))
    return Price.PostWarnings(TypedPrice(), U.SavedStats(item.itemID), CheapestOther(), vendor,
        Price.HouseCut(U.ViewHouseKey()))
end

--- The Post button's text and whether it can be clicked, from the step and what's filled in.
local function RefreshButton()
    local panel = ui.postPanel
    local step = post and post.step
    local text = "Post"
    if step == "warned" then
        text = "Post anyway"
    elseif step == "confirm" or step == "needsConfirm" then
        text = "Confirm"
    elseif step == "posting" then
        text = "Posting..."
    end
    panel.postButton:SetText(text)
    local ready = item ~= nil and item.location ~= nil and TypedPrice() > 0 and Quantity() >= 1
        and Quantity() <= Available() and step ~= "posting"
    panel.postButton:SetEnabled(ready)
end

--- Deposit and what the sale would bring in after the house's cut.
local function RefreshMoney()
    local panel = ui.postPanel
    if item == nil or item.location == nil then
        panel.moneyText:SetText("")
        return
    end
    local deposit = Deposit()
    local total = TypedPrice() * Quantity()
    local cut = Price.HouseCut(U.ViewHouseKey())
    local parts = { "Deposit " .. (deposit and U.CopperToText(deposit) or "?") }
    if total > 0 then
        parts[#parts + 1] = cut and ("you get " .. U.CopperToText(Price.AfterCut(total, cut)) .. " after the cut")
            or ("sells for " .. U.CopperToText(total) .. "; the goblin cut isn't known yet")
    end
    panel.moneyText:SetText(table.concat(parts, ", "))
end

--- Drops a post that was armed but not sent, or one the game asked to confirm: any change means a
-- fresh look before posting.
local function Disarm()
    if post and (post.step == "warned" or post.step == "confirm" or post.step == "needsConfirm") then
        post = nil
    end
end

--- Redraws the post controls.
function Post.Refresh()
    local panel = ui.postPanel
    if panel == nil then
        return
    end
    local usable = item ~= nil and item.location ~= nil
    panel.qtyBox:SetShown(usable and item.commodity)
    panel.maxButton:SetShown(usable and item.commodity)
    -- No item, or one followed from Blizzard's window: no count to set, so no label either.
    panel.qtyLabel:SetShown(usable)
    panel.qtyLabel:SetText((usable and not item.commodity) and "One copy per post" or "How many")
    if item ~= nil and item.location == nil then
        panel.reasonText:SetText("Drop the item on the slot above to post it from here.")
    end
    RefreshMoney()
    RefreshButton()
end

--- Fills in the price from the listings with the chosen pricing, and says why.
local function Prefill()
    local last = (HouseLedgerDB.lastPosts[U.ViewHouseKey()] or {})[item.itemID]
    local price, reason = Price.PostPrice(Pricing(), tiers, U.SavedStats(item.itemID), last, item.commodity)
    SetPrice(price)
    ui.postPanel.reasonText:SetText(reason)
end

--- A new item on the Sell slot, or none: starts over.
-- @param pending Sell's pending item, or nil
function Post.OnNewItem(pending)
    item, tiers, prefilled, post = pending, {}, false, nil
    if ui.postPanel == nil then
        return
    end
    SetPrice(nil)
    ui.postPanel.reasonText:SetText("")
    ui.postPanel.qtyBox:SetText(item and item.commodity and tostring(Available()) or "")
    Post.Refresh()
end

--- The Sell item's listings came in. The price is filled in once per item: later listings (the
-- house may send new ones after a post) never change a price that is already there.
-- @param newTiers { price, quantity, own } in any order
function Post.OnListings(newTiers)
    if item == nil then
        return
    end
    table.sort(newTiers, function(a, b) return a.price < b.price end)
    tiers = newTiers
    if not prefilled and item.location then
        prefilled = true
        if item.commodity then
            ui.postPanel.qtyBox:SetText(tostring(Available()))
        end
        Prefill()
    end
    Disarm()
    Post.Refresh()
end

--- The player changed the price, how many, how long or the pricing: a fresh look before posting.
local function OnChanged()
    Disarm()
    Post.Refresh()
end

--- What the post would be, as a line: "Post 20 Linen Cloth at 20c each for 24 Hours?".
-- @return the text
local function PostLine()
    return string.format("Post %d %s at %s each for %s?", Quantity(), item.name, U.CopperToText(TypedPrice()),
        DurationText(Duration()))
end

--- Why a post can't go now, or nil when it can.
-- @return the reason, or nil
local function Blocked()
    if U.InCombat() then
        return "Not in combat: post after the fight."
    elseif not U.HouseIsOpen() then
        return "Open the auction house first."
    elseif item == nil or item.location == nil then
        return "Drop the item on the slot to post it."
    elseif not C_Item.DoesItemExist(item.location) or C_Item.GetItemID(item.location) ~= item.itemID then
        return "That item has moved in your bags. Drop it on the slot again."
    elseif Quantity() < 1 or Quantity() > Available() then
        return string.format("You have %d to post.", Available())
    elseif (Deposit() or 0) > GetMoney() then
        return "You can't pay the deposit."
    elseif not C_AuctionHouse.IsThrottledMessageSystemReady() then
        return "The auction house is still busy. Wait, then click Post again."
    end
    return nil
end

--- Sends the post: the player's click. Stackables with PostCommodity, other items one copy with
-- PostItem (a buyout, no bid).
local function Send()
    local price, quantity, duration = TypedPrice(), Quantity(), Duration()
    -- How many were in the bags before: a post that went up takes them out.
    post = { step = "posting", sentAt = U.Clock(), itemID = item.itemID, name = item.name, price = price,
        quantity = quantity, commodity = item.commodity, location = item.location, duration = duration,
        before = Available() }
    local needsConfirmation
    if item.commodity then
        needsConfirmation = C_AuctionHouse.PostCommodity(item.location, duration, quantity, price) -- reviewed: the player's own Post click posts this stack
    else
        needsConfirmation = C_AuctionHouse.PostItem(item.location, duration, 1, nil, price) -- reviewed: the player's own Post click posts one copy at this buyout
    end
    if needsConfirmation then
        post.step = "needsConfirm"
        Sell.SetStatus("The game asks to confirm this post. Click Confirm to post it.")
    else
        Sell.SetStatus("Posting...")
    end
    RefreshButton()
end

--- The game asked to confirm the post it was sent: the player's Confirm click.
local function ConfirmSent()
    post.step, post.sentAt = "posting", U.Clock()
    if post.commodity then
        C_AuctionHouse.ConfirmPostCommodity(post.location, post.duration, post.quantity, post.price) -- reviewed: the player's own Confirm click, as the game asked
    else
        C_AuctionHouse.ConfirmPostItem(post.location, post.duration, 1, nil, post.price) -- reviewed: the player's own Confirm click, as the game asked
    end
    Sell.SetStatus("Posting...")
    RefreshButton()
end

--- The Post button: each click is one step. A warning, or the Confirm setting, asks first.
function Post.OnPostClick()
    local step = post and post.step
    if step == "posting" then
        return
    end
    local blocked = Blocked()
    if blocked then
        Sell.SetStatus(blocked)
        return
    end
    if step == "needsConfirm" then
        ConfirmSent()
        return
    end
    if step == nil then
        local warnings = Warnings()
        if #warnings > 0 then
            post = { step = "warned" }
            Sell.SetStatus("Check the price: it is " .. table.concat(warnings, ", and ") .. ". Click Post anyway to post.")
            RefreshButton()
            return
        end
        if HouseLedgerDB.settings.confirmPosts then
            post = { step = "confirm" }
            Sell.SetStatus(PostLine() .. " Click Confirm.")
            RefreshButton()
            return
        end
    end
    -- The warning click counts as the confirm: never a third click.
    Send()
end

--- Ends a post with a line in the status bar; a post that went up is remembered for My last price.
-- @param text the line
-- @param posted true when it went up
local function EndPost(text, posted)
    if posted then
        Price.RememberPost(HouseLedgerDB, U.ViewHouseKey(), post.itemID, post.price, time())
    end
    post = nil
    Sell.SetStatus(text)
    if item and item.commodity then
        ui.postPanel.qtyBox:SetText(tostring(Available()))
    end
    Post.Refresh()
end

--- The text for a post that went up.
-- @return the line
local function PostedText()
    return string.format("Posted %d %s at %s each.", post.quantity, post.name, U.CopperToText(post.price))
end

--- The house made the auction (AUCTION_HOUSE_AUCTION_CREATED).
function Post.OnAuctionCreated()
    if post and post.step == "posting" then
        EndPost(PostedText(), true)
    end
end

--- The house refused the post (AUCTION_HOUSE_POST_ERROR, or AUCTION_HOUSE_SHOW_ERROR while one is
-- in flight, as a refused buy is answered).
function Post.OnPostError()
    if post and post.step == "posting" then
        EndPost("The house refused the post. Nothing was posted.", false)
    end
end

--- True when the items sent have left the bags, which a post that went up does.
-- @return true when they have
local function LeftTheBags()
    if not post.commodity then
        return not C_Item.DoesItemExist(post.location) or C_Item.GetItemID(post.location) ~= post.itemID
    end
    return post.before - Available() >= post.quantity
end

--- Each second: with no answer after POST_ANSWER_WAIT (whether the house answers a post on
-- Forever isn't known yet), the bags decide: items gone means posted; still there means it
-- isn't known, and the price isn't remembered.
function Post.Tick()
    if post and post.step == "posting" and U.Clock() - post.sentAt >= POST_ANSWER_WAIT then
        if LeftTheBags() then
            EndPost(PostedText() .. " Check Blizzard's Auctions tab.", true)
        else
            EndPost("No answer from the house, and the items are still in your bags: it may not have posted. "
                .. "Check Blizzard's Auctions tab.", false)
        end
    end
end

--- Leaving the Sell tab or the house: an armed post is dropped. One already sent waits for its answer.
function Post.Close()
    Disarm()
    Post.Refresh()
end

--- A numeric edit box for the post controls.
-- @param parent the panel
-- @param width its width
-- @param letters the most digits
-- @return the box
local function NumberBox(parent, width, letters)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(letters)
    box:SetScript("OnTextChanged", function(_, userInput)
        if userInput then
            OnChanged()
        end
    end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return box
end

--- A coin icon after a price box.
-- @param parent the panel
-- @param box the box it follows
-- @param texture the coin's texture
-- @return the icon
local function Coin(parent, box, texture)
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetSize(12, 12)
    icon:SetPoint("LEFT", box, "RIGHT", 2, 0)
    icon:SetTexture(texture)
    return icon
end

--- Makes the post controls at the bottom of the Sell tab: pricing and duration dropdowns, the
-- deposit, the price boxes, how many, the reason line and the Post button.
-- @param top the y offset of their first row, from the Sell panel's top
function Post.Build(top)
    local panel = CreateFrame("Frame", nil, ui.sellPanel)
    panel:SetPoint("TOPLEFT", ui.sellPanel, "TOPLEFT", 20, top)
    panel:SetPoint("RIGHT", ui.sellPanel, "RIGHT", -16, 0)
    panel:SetHeight(72)
    ui.postPanel, ui.sellPanel.postPanel = panel, panel

    local pricing = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    pricing:SetWidth(130)
    pricing:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    pricing:SetupMenu(function(_, root)
        for _, key in ipairs(Price.POST_PRICING_ORDER) do
            root:CreateRadio(Price.POST_PRICINGS[key], function(picked)
                return Pricing() == picked
            end, function(picked)
                HouseLedgerDB.settings.postPricing = picked
                -- The player picked a way to price it: filling the price in again is what they asked.
                if item and item.location then
                    Prefill()
                end
                OnChanged()
            end, key)
        end
    end)
    local duration = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    duration:SetWidth(110)
    duration:SetPoint("LEFT", pricing, "RIGHT", 8, 0)
    duration:SetupMenu(function(_, root)
        for index = 1, #DURATION_NAMES do
            root:CreateRadio(DurationText(index), function(picked)
                return Duration() == picked
            end, function(picked)
                HouseLedgerDB.settings.postDuration = picked
                OnChanged()
            end, index)
        end
    end)
    panel.pricingDropdown, panel.durationDropdown = pricing, duration
    panel.moneyText = U.Cell(panel, "GameFontHighlightSmall", "LEFT")
    panel.moneyText:SetPoint("LEFT", duration, "RIGHT", 8, 0)
    panel.moneyText:SetPoint("RIGHT", panel, "RIGHT", 0, 0)

    local priceLabel = U.Cell(panel, "GameFontNormal", "LEFT")
    priceLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -30)
    priceLabel:SetText("Price")
    panel.priceBoxes = {}
    local gold = NumberBox(panel, 44, 6)
    gold:SetPoint("LEFT", priceLabel, "RIGHT", 10, 0)
    local silver = NumberBox(panel, 26, 2)
    silver:SetPoint("LEFT", Coin(panel, gold, "Interface\\MoneyFrame\\UI-GoldIcon"), "RIGHT", 8, 0)
    local copper = NumberBox(panel, 26, 2)
    copper:SetPoint("LEFT", Coin(panel, silver, "Interface\\MoneyFrame\\UI-SilverIcon"), "RIGHT", 8, 0)
    local each = U.Cell(panel, "GameFontHighlightSmall", "LEFT")
    each:SetPoint("LEFT", Coin(panel, copper, "Interface\\MoneyFrame\\UI-CopperIcon"), "RIGHT", 4, 0)
    each:SetText("each")
    panel.priceBoxes.gold, panel.priceBoxes.silver, panel.priceBoxes.copper = gold, silver, copper

    panel.qtyLabel = U.Cell(panel, "GameFontNormal", "LEFT")
    panel.qtyLabel:SetPoint("LEFT", each, "RIGHT", 14, 0)
    panel.qtyLabel:SetText("How many")
    panel.qtyBox = NumberBox(panel, 40, 5)
    panel.qtyBox:SetPoint("LEFT", panel.qtyLabel, "RIGHT", 8, 0)
    panel.maxButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.maxButton:SetSize(44, 20)
    panel.maxButton:SetPoint("LEFT", panel.qtyBox, "RIGHT", 4, 0)
    panel.maxButton:SetText("Max")
    panel.maxButton:SetScript("OnClick", function()
        panel.qtyBox:SetText(tostring(Available()))
        OnChanged()
    end)

    panel.postButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.postButton:SetSize(100, 22)
    panel.postButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -52)
    panel.postButton:SetText("Post")
    panel.postButton:SetScript("OnClick", Post.OnPostClick)
    panel.reasonText = U.Cell(panel, "GameFontHighlightSmall", "LEFT")
    panel.reasonText:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -56)
    panel.reasonText:SetPoint("RIGHT", panel.postButton, "LEFT", -8, 0)
    Post.Refresh()
end
