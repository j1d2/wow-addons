--[[
Shared pieces of HouseLedger's window code: the addon namespace tables, the layout
constants and state more than one file uses, and small helpers (money text, the player's house,
item looks, font-string cells).
]]

local _, ns = ...
ns.C, ns.ui, ns.state = {}, {}, {}
-- One table per file, made here so any file can name another's before it loads.
for _, name in ipairs({ "U", "Chart", "Scan", "Tooltip", "Buy", "Sell", "PC", "Settings", "Window" }) do
    ns[name] = {}
end
local C, ui, state, Price, U = ns.C, ns.ui, ns.state, ns.Price, ns.U

-- Layout and text more than one file uses. A constant only one file uses lives in that file.

C.MIN_SEARCH_LENGTH = 2
-- Long enough for a full-house reply. time() is whole seconds and can
-- make a short deadline expire early.
C.ANSWER_WAIT = 60
-- Space between Blizzard's auction house window and this one.
C.PIN_GAP = 4

-- Window size. The height follows Blizzard's auction house window (538
-- in its XML). The width fills the room to the right of it, between
-- FRAME_WIDTH_MIN and FrameWidth's maximum; the screen clamp slides a too-wide window back on.
C.HOUSE_HEIGHT = 538
C.FRAME_WIDTH_MIN = 440

-- Under the list: the details block for a clicked row (a title and the
-- five lines of PriceLedger.WindowLines), then two status lines.
C.STATUS_HEIGHT = 48
C.DETAIL_LINES = 5
C.DETAIL_LINE_HEIGHT = 15
C.DETAIL_HEIGHT = (C.DETAIL_LINES + 1) * C.DETAIL_LINE_HEIGHT + 10

-- The results list sits in the template's inset, between the search
-- bar (60 from the top) and the details block. The filter row (quality, item level, and
-- Market's name filter) sits between the top row and the list.
C.LIST_TOP = 60
C.LIST_BOTTOM = C.STATUS_HEIGHT + C.DETAIL_HEIGHT
C.HEADER_HEIGHT = 26
C.ROW_HEIGHT = 18
C.FILTER_HEIGHT = 26
-- (538 - 60 - 26 - 148 - 26) / 18 = 15 rows.
C.VISIBLE_ROWS = math.floor((C.HOUSE_HEIGHT - C.LIST_TOP - C.FILTER_HEIGHT - C.LIST_BOTTOM - C.HEADER_HEIGHT) / C.ROW_HEIGHT)
C.WHEEL_STEP = 3
-- The price chart's width beside the Buy details on a wide window.
C.CHART_WIDTH = 170

-- Column headings, and the way each first sorts when clicked (true is low to high, A to Z).
C.HEADER_LABELS = { name = "Item", ilvl = "ilvl", price = "Price", avail = "Avail.", typical = "Avg 7d", trend = "Trend" }
C.SORT_FIRST_ASCENDING = { name = true, ilvl = false, price = true, avail = false, typical = true, trend = true }
C.SORT_KEYS = { "name", "ilvl", "price", "avail", "typical", "trend" }
C.ICON_SIZE = 16
-- Shown until the game has loaded an item's icon.
C.QUESTION_MARK_ICON = 134400
C.PORTRAIT_ICON = "Interface\\Icons\\INV_Misc_Coin_02"

C.BUY_TAB = 1
-- Market is ours alone: a plain tab that presses nothing on Blizzard's window.
C.MARKET_TAB = 3
-- The Market tab's views, in switcher order. All read saved data only.
C.MARKET_VIEWS = {
    { key = "deals", title = "Deals", noun = "deals",
        empty = "No deals at your last scan. A deal needs %d scans of an item." },
    { key = "drops", title = "Biggest drops", noun = "drops", empty = "No prices went down at your last scan." },
    { key = "rises", title = "Biggest rises", noun = "rises", empty = "No prices went up at your last scan." },
}
C.BUY_HELP = "Type an item name. One click sends one search."
-- Shown large in the middle of the empty Buy list.
C.BUY_START = "Type a name or pick a quality, then click Search."

-- Frames more than one file uses, set when they are built (Window.Build, PC.Build). The rest
-- start nil: frame, searchBox, statusText, scanText, scanBar (the read's progress, shown only
-- while reading), scanButton, buyPanel, sellPanel, settingsPanel, priceCheck (the /pc window,
-- built at load) and header.
ui.rows = {}

-- State more than one file uses. State only one file uses lives in that file.

-- Last browse results. Scrolling and clicking only re-read these; they never ask the house again.
state.results = {}
-- Quality and item level limits, shared by Buy and Market; Market's name filter text and sort.
state.filter = {}
state.marketText = ""
state.marketSort = {}
-- Base item levels from the game's item data, kept for the session once known, so Market's
-- rebuilds don't ask again.
state.itemLevels = {}
-- Which Market view shows.
state.marketView = 1
-- The scan: "idle", "waiting" or "reading" (see Scan.lua), when the request went out, and how
-- long a late answer still counts after the house closed.
state.scanState = "idle"
state.waitStarted = 0
state.acceptAnswerUntil = 0
state.currentTab = C.BUY_TAB
-- The tabs make the window protected: in combat the game blocks addon
-- changes to it. These mark what to catch up on when combat ends.
state.afterCombat = false
state.buildAfterCombat = false
-- Bag button work that waits for combat to end: making them, or showing or hiding them.
state.bagButtonsPending = false

-- FrameWidth's limits.
local FRAME_WIDTH_MAX = 640
local SCREEN_MARGIN = 8

--- True while the game blocks addon changes to protected frames.
-- @return true in combat lockdown, false otherwise or without InCombatLockdown
function U.InCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() == true
end

--- True when the game would block an addon change to this frame now.
-- That is in combat, and the game counts the frame as protected. The game is
-- asked rather than assumed; without IsProtected, assume it is.
-- @param region the frame to check
-- @return true when a change would be blocked
function U.Locked(region)
    if not U.InCombat() then
        return false
    end
    return type(region.IsProtected) ~= "function" or region:IsProtected() == true
end

--- Shows a copper amount the way the game does: gold, silver and copper, each with its coin icon.
-- GetMoneyString is Blizzard's own formatter on
-- Forever, which has no GetCoinTextureString. It switches to "1g 2s 3c"
-- text when the player has colorblind mode on. If it is ever missing, the
-- plain-text version from PriceLedger keeps the price readable.
-- @param copper whole copper, or nil
-- @return the text, or "-" for no price (nil, 0 or less)
function U.CopperToText(copper)
    if not copper or copper <= 0 then
        return "-"
    end
    if GetMoneyString then
        return GetMoneyString(copper, true)
    end
    return Price.CoinText(copper)
end

--- A wait as whole minutes (rounded up) from 60 seconds on, otherwise seconds.
-- @param seconds the wait
-- @return text like "15 min" or "40 sec"
function U.RemainingText(seconds)
    seconds = math.ceil(seconds)
    if seconds >= 60 then
        return string.format("%d min", math.ceil(seconds / 60))
    end
    return string.format("%d sec", seconds)
end

--- The realm prices are filed under: the game's realm name, or, when the game gives a blank
-- one (the Forever client has since 2026-11-20), the last realm it did name, from
-- PriceLedger.RealmFor. "Forever" when no name was ever seen.
-- @return the realm name
local function RealmLabel()
    local name = type(GetRealmName) == "function" and GetRealmName() or nil
    if type(HouseLedgerDB) ~= "table" then
        return (type(name) == "string" and name ~= "") and name or Price.UNKNOWN_REALM
    end
    return Price.RealmFor(HouseLedgerDB, name)
end

--- The house key for the player's own faction on this realm.
-- @return the key, from PriceLedger.HouseKey
function U.PlayerHouseKey()
    local side = "Unknown"
    if type(UnitFactionGroup) == "function" then
        side = UnitFactionGroup("player") or "Unknown"
    end
    return Price.HouseKey(side, RealmLabel())
end

--- The house key for the auctioneer you have open.
-- A goblin house has no Alliance or Horde faction group, so those scans are
-- stored on their own, as "Neutral". Without an npc unit, the player's
-- faction is used.
-- @return the key, from PriceLedger.HouseKey
function U.CurrentScanKey()
    local side
    if type(UnitExists) == "function" and UnitExists("npc") and type(UnitFactionGroup) == "function" then
        local npcSide = UnitFactionGroup("npc")
        if npcSide == "Alliance" or npcSide == "Horde" then
            side = npcSide
        else
            side = "Neutral"
        end
    elseif type(UnitFactionGroup) == "function" then
        side = UnitFactionGroup("player")
    end
    return Price.HouseKey(side, RealmLabel())
end

--- The game's clock in seconds, for timing the wait for an answer.
-- @return GetTime(), or time() when GetTime is missing
function U.Clock()
    if type(GetTime) == "function" then
        return GetTime()
    end
    return time()
end

--- Name, icon and quality for a result.
-- The game may not have loaded the item yet; ITEM_KEY_ITEM_INFO_RECEIVED
-- redraws the rows.
-- A Market row carries the name and quality its scan saved; those come first.
-- @param itemKey the result's item key, or nil
-- @param result optional; the row's result, with savedName and savedQuality on Market rows
-- @return the name, or "item <id>" (or "unknown item") until it is loaded
-- @return the icon, or a question mark until it is loaded
-- @return the item quality, or nil until it is loaded
function U.ItemLook(itemKey, result)
    local info = itemKey and C_AuctionHouse.GetItemKeyInfo(itemKey)
    if result and result.savedName then
        local quality = result.savedQuality
        if not Price.IsQuality(quality) then
            quality = info and info.quality
        end
        return result.savedName, info and info.iconFileID or C.QUESTION_MARK_ICON, quality
    end
    if info and info.itemName and info.itemName ~= "" then
        return info.itemName, info.iconFileID or C.QUESTION_MARK_ICON, info.quality
    end
    local itemID = itemKey and itemKey.itemID
    if itemID then
        return "item " .. itemID, C.QUESTION_MARK_ICON, nil
    end
    return "unknown item", C.QUESTION_MARK_ICON, nil
end

--- Saved stats for an item at the player's own house, or nil.
-- Falls back to the last scanned house as PriceLedger.Lookup does.
-- @param itemID the item's id, or nil
-- @return stats from PriceLedger.Stats, or nil
function U.SavedStats(itemID)
    local saved = Price.Lookup(HouseLedgerDB, itemID, U.PlayerHouseKey())
    return saved and saved.stats
end

--- The game's item data for an item: name, quality and base item level. The game loads an item
-- it doesn't have yet and sends GET_ITEM_INFO_RECEIVED.
-- @param itemID the item's id
-- @return name, quality, level; each nil until known
local function GameItemInfo(itemID)
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    if type(getInfo) ~= "function" then
        return nil
    end
    local name, _, quality, level = getInfo(itemID)
    return name, quality, level
end

--- An item's base item level, from the session cache or the game's item data.
-- @param itemID the item's id
-- @return the level, or nil until known
local function BaseLevel(itemID)
    if state.itemLevels[itemID] == nil then
        local _, _, level = GameItemInfo(itemID)
        state.itemLevels[itemID] = level
    end
    return state.itemLevels[itemID]
end

--- A row's item level: a search result's own (from its item key); a Market row's base level from
-- the game's item data, kept once known.
-- @param result a search result or a Market row
-- @return the level, or nil when it has none (0) or isn't known yet
function U.RowLevel(result)
    local level
    if result.market then
        level = BaseLevel(result.itemKey.itemID)
    else
        level = result.itemKey and result.itemKey.itemLevel
    end
    if type(level) == "number" and level > 0 then
        return level
    end
    return nil
end

--- How long ago a time was, for the Market switcher.
-- @param seconds seconds since then
-- @return text like "just now", "12 min ago", "2 h ago" or "3 days ago"
function U.AgoText(seconds)
    if seconds < 60 then
        return "just now"
    elseif seconds < 60 * 60 then
        return string.format("%d min ago", math.floor(seconds / 60))
    elseif seconds < 48 * 60 * 60 then
        return string.format("%d h ago", math.floor(seconds / (60 * 60)))
    end
    return string.format("%d days ago", math.floor(seconds / (24 * 60 * 60)))
end

--- The house the Market tab reads: the player's own once it has a scan, else the last one scanned.
-- @return the house table, or nil
function U.MarketHouse()
    local houses = HouseLedgerDB.houses or {}
    local house = houses[U.PlayerHouseKey()]
    if type(house) == "table" and house.scannedAt then
        return house
    end
    return houses[HouseLedgerDB.lastHouseKey or ""]
end

--- An item key for a saved item: the game's own maker when it has one.
-- Saved rows have the item id only, so gear shows as its base item.
-- @param itemID the item's id
-- @return the item key
function U.SavedItemKey(itemID)
    if type(C_AuctionHouse.MakeItemKey) == "function" then
        return C_AuctionHouse.MakeItemKey(itemID)
    end
    return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
end

--- A saved item's name, quality and base item level, for Market's filters: the scan's saved
-- name and quality first, then the game's item data. The game loads an item it doesn't have yet;
-- GET_ITEM_INFO_RECEIVED filters again once it arrives.
-- @param entry a PriceLedger.Market entry
-- @param needs { name, quality, level }: true for each the filter uses
-- @return { name, quality, level }, any of them nil when not known or not needed
function U.SavedItemLook(entry, needs)
    local name = entry.name
    local quality = Price.IsQuality(entry.quality) and entry.quality or nil
    -- The game's item data only for what the saved row lacks and a filter needs.
    if (needs.name and name == nil) or (needs.quality and quality == nil) then
        local gameName, gameQuality = GameItemInfo(entry.itemID)
        name, quality = name or gameName, quality or gameQuality
    end
    return { name = name, quality = quality, level = needs.level and BaseLevel(entry.itemID) or nil }
end

--- Row hover: the game's item tooltip for the row's item.
-- @param row the hovered row button
function U.ShowRowTooltip(row)
    local itemKey = row.result and row.result.itemKey
    if itemKey == nil or GameTooltip == nil then
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local requiredLevel
    if type(C_AuctionHouse.GetItemKeyRequiredLevel) == "function" then
        requiredLevel = C_AuctionHouse.GetItemKeyRequiredLevel(itemKey)
    end
    GameTooltip:SetItemKey(itemKey.itemID, itemKey.itemLevel, itemKey.itemSuffix, requiredLevel)
    GameTooltip:Show()
end

--- Hides the item tooltip when the mouse leaves a row.
function U.HideRowTooltip()
    if GameTooltip then
        GameTooltip:Hide()
    end
end

--- True when Blizzard's auction house window exists and is shown.
-- @return true when open; false or nil otherwise
function U.HouseIsOpen()
    return AuctionHouseFrame and AuctionHouseFrame:IsShown()
end

--- The search key Blizzard's Sell tab uses for gear.
-- Item level and suffix are 0, so every variant of the item comes back in one list.
-- @param itemKey the item's own key; it is not changed
-- @return a new item key
function U.AnyVariantKey(itemKey)
    return {
        itemID = itemKey.itemID,
        itemLevel = 0,
        itemSuffix = 0,
        battlePetSpeciesID = itemKey.battlePetSpeciesID or 0,
    }
end

--- Makes one single-line text cell.
-- @param parent the frame that owns it
-- @param font a font object name, such as "GameFontNormal"
-- @param justify "LEFT" or "RIGHT"
-- @return the font string
function U.Cell(parent, font, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", font)
    text:SetJustifyH(justify)
    -- Each cell has a fixed slot. Long text is cut with "..." instead of
    -- wrapping onto the line below.
    text:SetWordWrap(false)
    return text
end

--- The cells of the header or of a row, in the form AnchorCells takes.
-- @param owner the header frame or a row button
-- @return { parent, icon, name, price, avail, typical, trend }
function U.CellsOf(owner)
    return {
        parent = owner,
        icon = owner.icon,
        name = owner.nameText,
        ilvl = owner.ilvlText,
        price = owner.priceText,
        avail = owner.availText,
        typical = owner.typicalText,
        trend = owner.trendText,
    }
end

--- Room to the right of the auction house, between the width limits.
-- @return the window width; FRAME_WIDTH_MIN when the edges are not known
function U.FrameWidth()
    local screenRight = UIParent and UIParent:GetRight()
    local houseRight = AuctionHouseFrame and AuctionHouseFrame:GetRight()
    if type(screenRight) ~= "number" or type(houseRight) ~= "number" then
        return C.FRAME_WIDTH_MIN
    end
    local room = math.floor(screenRight - houseRight - C.PIN_GAP - SCREEN_MARGIN)
    return math.max(C.FRAME_WIDTH_MIN, math.min(FRAME_WIDTH_MAX, room))
end
