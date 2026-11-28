--[[
Shared pieces of HouseLedger's window code: the addon namespace tables, the layout
constants and state more than one file uses, and small helpers (money text, the player's house,
item looks, font-string cells).
]]

local _, ns = ...
ns.C, ns.ui, ns.state = {}, {}, {}
-- One table per file, made here so any file can name another's before it loads.
for _, name in ipairs({ "U", "Chart", "Scan", "Tooltip", "Buy", "Sell", "Purchase", "Post", "PC", "History", "Auctions",
    "Settings", "Window" }) do
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
-- Where a details line's price starts, from the window's left edge (Buy and Price Check).
C.DETAIL_VALUE_LEFT = 180
C.DETAIL_HEIGHT = (C.DETAIL_LINES + 1) * C.DETAIL_LINE_HEIGHT + 10
-- The Buy details charts (an item's prices, the house overview) fill the details block's height,
-- this far from the dark box above and the status lines below.
C.DETAIL_CHART_MARGIN = 6
C.DETAIL_CHART_HEIGHT = C.DETAIL_HEIGHT - 2 * C.DETAIL_CHART_MARGIN

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
-- Room kept at a list's right edge for its scroll bar (Blizzard's MinimalScrollBar is 8 wide),
-- whether or not the bar shows, so the columns never jump.
C.SCROLL_GUTTER = 14
-- The Buy details charts' width when built; Buy sizes them to the window when it lays out.
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
C.MARKET_TAB = 4
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
-- Under the start message, in red, until the house has a scan from today.
C.SCAN_REMINDER = "You haven't scanned today. Click Scan once a day to build your price history."

-- Frames more than one file uses, set when they are built (Window.Build, PC.Build). The rest
-- start nil: frame, searchBox, statusText, scanText, scanBar (the read's progress, shown only
-- while reading), scanButton, buyPanel, sellPanel, historyPanel, settingsPanel, priceCheck (the /pc window,
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
-- The house key of the auction house that is open (a goblin one is its own house), set when it
-- opens and cleared when it closes. The window reads this house; tooltips always read the
-- player's own faction's.
state.openHouseKey = nil

-- A profession's recipes by its skill line, for when the game doesn't name the profession: the
-- skill line IDs the game has used since its first release.
local RECIPES_BY_SKILL_LINE = {
    [129] = "FirstAid", [164] = "Blacksmithing", [165] = "Leatherworking", [171] = "Alchemy", [185] = "Cooking",
    [197] = "Tailoring", [202] = "Engineering", [333] = "Enchanting", [356] = "Fishing", [755] = "Jewelcrafting",
    [773] = "Inscription",
}

-- Each class's armor: its best type before and from LATE_ARMOR_LEVEL (when warriors and paladins
-- learn plate, and hunters and shamans mail), whether it carries a shield, and its relic kind.
-- Names are Enum.ItemArmorSubclass keys.
local CLASS_ARMOR = {
    WARRIOR = { early = "Mail", late = "Plate", shield = true },
    PALADIN = { early = "Mail", late = "Plate", shield = true, relic = "Libram" },
    HUNTER = { early = "Leather", late = "Mail" },
    SHAMAN = { early = "Leather", late = "Mail", shield = true, relic = "Totem" },
    ROGUE = { early = "Leather" },
    DRUID = { early = "Leather", relic = "Idol" },
    MAGE = { early = "Cloth" },
    PRIEST = { early = "Cloth" },
    WARLOCK = { early = "Cloth" },
}
local LATE_ARMOR_LEVEL = 40

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

--- The width of a cell's whole text, even when the cell cuts it short.
-- @param cell a font string
-- @return pixels
function U.TextWidth(cell)
    -- GetStringWidth can stop at the cell's width; the unbounded width is the whole text's.
    return cell.GetUnboundedStringWidth and cell:GetUnboundedStringWidth() or cell:GetStringWidth() or 0
end

-- The coin sizes FitMoney tries, smallest kept coin first: every coin, then no copper on amounts
-- of 1 gold or more, then no silver either.
local MONEY_UNITS = { 1, 100, 10000 }

--- Writes text holding money into a cell, rounding amounts of 1 gold or more until it fits.
-- A cell cuts long text with "...", and a cut through a coin icon's markup leaves a stray "|".
-- The width is the one the code gave the cell, not the cell's own: a cell's size can be unknown
-- until the game first lays it out.
-- @param cell the font string
-- @param width the room it has, in pixels
-- @param build function(coins) returning the text, writing each amount with coins(copper)
-- @return the text it set
function U.FitMoney(cell, width, build)
    local text
    for _, unit in ipairs(MONEY_UNITS) do
        text = build(function(copper)
            return U.CopperToText(Price.RoundCoins(copper, unit))
        end)
        cell:SetText(text)
        if U.TextWidth(cell) <= width then
            break
        end
    end
    return text
end

--- Fills the details block's lines from PriceLedger.WindowLines. A price line is rounded (FitMoney)
-- only when it can't fit whole.
-- @param lines the line cells: { left, right } each
-- @param stats the item's saved stats, or nil to empty the lines
-- @param width the room each line's right cell has, in pixels
function U.ShowWindowLines(lines, stats, width)
    local exact = stats and Price.WindowLines(stats, U.CopperToText) or {}
    for index, line in ipairs(lines) do
        local source = exact[index]
        line.left:SetText(source and source.left or "")
        if source then
            U.FitMoney(line.right, width, function(coins)
                return Price.WindowLines(stats, coins)[index].right
            end)
        else
            line.right:SetText("")
        end
    end
end

--- This character's name, with its Forever surname when the game gives one.
-- @return the name
function U.CharacterName()
    local name, surname = UnitName("player")
    if type(surname) == "string" and surname ~= "" then
        local consts = type(Constants) == "table" and Constants.CharacterNameSeparatorConsts
        local separator = type(consts) == "table" and consts.CHARACTERNAME_SURNAME_SEPARATOR or " "
        return name .. separator .. surname
    end
    return name
end

--- This character's realm, as prices are filed.
-- @return the realm
function U.RealmName()
    return Price.RealmFor(HouseLedgerDB, GetRealmName())
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

--- The house the window reads: the auction house that is open, or the player's own faction's
-- when none is.
-- @return the house key
function U.ViewHouseKey()
    return state.openHouseKey or U.PlayerHouseKey()
end

--- Saved stats for an item at the house the window reads, or nil.
-- @param itemID the item's id, or nil
-- @return stats from PriceLedger.Stats, or nil
function U.SavedStats(itemID)
    local saved = Price.Lookup(HouseLedgerDB, itemID, U.ViewHouseKey())
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

--- The house the Market tab and the house overview read: the open auction house's, from
-- U.ViewHouseKey, once it has a scan.
-- @return the house table, or nil
function U.MarketHouse()
    local house = (HouseLedgerDB.houses or {})[U.ViewHouseKey()]
    if type(house) == "table" and house.scannedAt then
        return house
    end
    return nil
end

--- The player's own faction's house, which Price Check reads like the tooltips, once it has a scan.
-- @return the house table, or nil
function U.PlayerHouse()
    local house = (HouseLedgerDB.houses or {})[U.PlayerHouseKey()]
    if type(house) == "table" and house.scannedAt then
        return house
    end
    return nil
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
    if itemKey == nil and row.listing then
        -- A listing: gear shows its own link (its item level and stats), stackables their item.
        itemKey = row.listingKey
        if row.listing.link and GameTooltip then
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(row.listing.link)
            GameTooltip:Show()
            return
        end
    end
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

--- True when two results are the same item: same item ID, item level and suffix. Market's list
-- is rebuilt with new tables, so a picked row is found again by its item, not its table.
-- @param a a browse result or Market row, or nil
-- @param b another, or nil
-- @return true when both are the same item
function U.SameItemKey(a, b)
    local keyA, keyB = a and a.itemKey, b and b.itemKey
    if keyA == nil or keyB == nil then
        return false
    end
    return keyA.itemID == keyB.itemID and (keyA.itemLevel or 0) == (keyB.itemLevel or 0)
        and (keyA.itemSuffix or 0) == (keyB.itemSuffix or 0)
end

--- Gives a list row a gold background that marks it as the picked row (as Unmaker's list
-- does), hidden until U.MarkRow shows it. The hover highlight stays as it was.
-- @param row the row button
function U.AddSelection(row)
    row.selection = row:CreateTexture(nil, "BACKGROUND")
    row.selection:SetAllPoints()
    row.selection:SetColorTexture(1, 0.82, 0, 0.2)
    row.selection:Hide()
end

--- Shows or hides a row's picked mark.
-- @param row a row from U.AddSelection
-- @param picked true to mark it
function U.MarkRow(row, picked)
    if picked then row.selection:Show() else row.selection:Hide() end
end

--- Hides the item tooltip when the mouse leaves a row.
function U.HideRowTooltip()
    if GameTooltip then
        GameTooltip:Hide()
    end
end

--- False only when the house says a search's list is not complete.
-- @param check the game's Has...Full...Results function, or nil when missing
-- @param ... the arguments for check
-- @return true unless check returns false
function U.IsComplete(check, ...)
    if type(check) ~= "function" then
        return true
    end
    return check(...) ~= false
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

--- Puts Blizzard's thin scroll bar (MinimalScrollBar) beside a list. It shows only while the
-- list has more rows than fit. Its thumb, arrows and wheel move the list through the list's own
-- scroll function, so they read rows already received and send nothing.
-- @param parent the frame that owns the bar
-- @param scroll the list's scroll function, called with the rows to move (negative moves up)
-- @return the bar; place it with SetPoint, then call U.SetScrollBar on every render
function U.ScrollBar(parent, scroll)
    local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    bar.offset, bar.maxOffset = 0, 0
    -- The wheel over the bar moves as far as the wheel over the list: WHEEL_STEP rows (the
    -- game's default is two arrow clicks).
    bar.wheelPanScalar = C.WHEEL_STEP
    bar:SetHideIfUnscrollable(true)
    bar:RegisterCallback("OnScroll", function(_, percentage)
        local target = U.ScrollTarget(percentage, bar.maxOffset)
        if target ~= bar.offset then
            -- The list redraws and calls U.SetScrollBar; the bar is already where the hand put it.
            bar.moving = true
            scroll(target - bar.offset)
            bar.moving = false
        end
    end, bar)
    return bar
end

--- The first row to show for a scroll bar position.
-- @param percentage the bar's position, 0 (top) to 1 (bottom)
-- @param maxOffset the last offset the list can scroll to
-- @return the offset, a whole row
function U.ScrollTarget(percentage, maxOffset)
    if maxOffset <= 0 or type(percentage) ~= "number" then
        return 0
    end
    return math.max(0, math.min(maxOffset, math.floor(percentage * maxOffset + 0.5)))
end

--- Matches a scroll bar to its list: thumb size from how much shows, thumb place from the offset,
-- one row per arrow click. The bar hides itself when everything fits.
-- @param bar a bar from U.ScrollBar
-- @param offset the list's first shown row, from 0
-- @param shown how many rows fit
-- @param total how many rows the list has
function U.SetScrollBar(bar, offset, shown, total)
    if bar == nil then
        return
    end
    local maxOffset = math.max(0, total - shown)
    bar.offset, bar.maxOffset = math.min(offset, maxOffset), maxOffset
    bar:SetVisibleExtentPercentage(total > 0 and math.min(1, shown / total) or 1)
    bar:SetPanExtentPercentage(maxOffset > 0 and 1 / maxOffset or 1)
    if not bar.moving then
        bar:SetScrollPercentage(maxOffset > 0 and bar.offset / maxOffset or 0)
    end
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

--- The recipe kinds (Enum.ItemRecipeSubclass values) of this character's professions, in the
-- order the game lists them: two main professions, then first aid, fishing and cooking. A
-- gathering profession has no recipes and is left out. Asks the game about the character only.
-- @return a list of subclass numbers; empty without professions or the game's tables
function U.RecipeSubclasses()
    local list = {}
    if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" or Enum == nil
        or type(Enum.ItemRecipeSubclass) ~= "table" then
        return list
    end
    local names = {}
    for name, value in pairs(type(Enum.Profession) == "table" and Enum.Profession or {}) do
        names[value] = name
    end
    local indexes = { GetProfessions() }
    for slot = 1, 5 do
        local index = indexes[slot]
        local skillLine = index and select(7, GetProfessionInfo(index))
        if skillLine then
            local info = C_TradeSkillUI and type(C_TradeSkillUI.GetProfessionInfoBySkillLineID) == "function"
                and C_TradeSkillUI.GetProfessionInfoBySkillLineID(skillLine)
            local name = info and info.profession and names[info.profession] or RECIPES_BY_SKILL_LINE[skillLine]
            local subclass = name and Enum.ItemRecipeSubclass[name]
            if subclass then
                list[#list + 1] = subclass
            end
        end
    end
    return list
end

--- The class filters for gear this character wears best: all weapons, its best armor type, the
-- armor every class wears (rings, necks, trinkets, off-hands, and cloaks, which are cloth), and its
-- shield and relic kind. The search's usable-only filter then drops weapons it can't use.
-- @return the list of AuctionHouseItemClassFilter tables and the armor type's name (like
--   "Plate"), or nil for a class this doesn't know
function U.BestGearFilters()
    local _, classFile = UnitClass("player")
    local armor = CLASS_ARMOR[classFile]
    if armor == nil then
        return nil
    end
    local level = UnitLevel("player") or 0
    local best = (armor.late and level >= LATE_ARMOR_LEVEL) and armor.late or armor.early
    local kinds = Enum.ItemArmorSubclass
    local classes = {
        { classID = Enum.ItemClass.Weapon },
        { classID = Enum.ItemClass.Armor, subClassID = kinds[best] },
        { classID = Enum.ItemClass.Armor, subClassID = kinds.Generic },
    }
    if best ~= "Cloth" then
        classes[#classes + 1] = { classID = Enum.ItemClass.Armor, subClassID = kinds.Cloth,
            inventoryType = Enum.InventoryType.IndexCloakType }
    end
    if armor.shield then
        classes[#classes + 1] = { classID = Enum.ItemClass.Armor, subClassID = kinds.Shield }
    end
    if armor.relic then
        classes[#classes + 1] = { classID = Enum.ItemClass.Armor, subClassID = kinds[armor.relic] }
    end
    return classes, best
end

-- ---------------------------------------------------------------------
-- Recent searches: one list (HouseLedgerDB.recentSearches) shown under the Buy tab's search box
-- and Price Check's. Clicking into a box shows it, typing narrows it, Up and Down put one in the
-- box, Enter or a click searches. Typing and the arrow keys send nothing.
-- ---------------------------------------------------------------------

local RECENT_ROW_HEIGHT = 18

--- Remembers a search in the shared recent list (newest first).
-- @param text what was searched
function U.RememberSearch(text)
    HouseLedgerDB.recentSearches = Price.AddRecent(HouseLedgerDB.recentSearches, text)
end

--- Puts a recent-searches list under a search box and gives the box its keys: the list opens when
-- the box is clicked, narrows as you type, Up and Down put a search in the box (past either end,
-- what was typed), Enter searches what the box shows, a click on a line searches it, a right-click
-- forgets it, and Escape or a click anywhere else closes it.
-- @param box the search box
-- @param parent the frame the list belongs to
-- @param search function() that searches what the box holds (Enter, or a click on a line)
-- @param allowed optional function() returning false while the list must not show
-- @return { frame, Hide = function() }
function U.AttachRecent(box, parent, search, allowed)
    local recent = { buttons = {}, matches = {}, selected = 0 }
    local frame = CreateFrame("Frame", nil, parent, "TooltipBackdropTemplate")

    local function Hide()
        recent.selected = 0
        if frame:IsShown() then
            frame:Hide()
            frame:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        end
    end

    local function Draw()
        for index, button in ipairs(recent.buttons) do
            local text = recent.matches[index]
            button.searchText = text
            if text then
                button.label:SetText(text)
                U.MarkRow(button, index == recent.selected)
                button:Show()
            else
                button:Hide()
            end
        end
    end

    local function Show()
        if allowed and not allowed() then
            return
        end
        recent.matches = Price.MatchRecent(HouseLedgerDB.recentSearches, recent.typed or box:GetText())
        if #recent.matches == 0 then
            Hide()
            return
        end
        if recent.selected > #recent.matches then
            recent.selected = 0
        end
        Draw()
        frame:SetHeight(#recent.matches * RECENT_ROW_HEIGHT + 30)
        frame:Show()
        -- Blizzard's own menus close the same way: any click outside them.
        frame:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end

    local function Search()
        Hide()
        box:ClearFocus()
        search()
    end

    local function Move(step)
        if not frame:IsShown() then
            recent.typed = box:GetText()
            Show()
            return
        end
        recent.selected = (recent.selected + step) % (#recent.matches + 1)
        -- Not typing, so the list stays as it is (OnTextChanged narrows only on typing).
        box:SetText(recent.matches[recent.selected] or recent.typed or "")
        Draw()
    end

    frame:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, 0)
    frame:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, 0)
    frame:SetFrameStrata("DIALOG")
    -- The whole list takes the mouse, so a click between its lines never reaches what is under it.
    frame:EnableMouse(true)
    frame:Hide()
    frame:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" and not self:IsMouseOver() and not box:IsMouseOver() then
            Hide()
        end
    end)
    for index = 1, Price.RECENT_SHOWN do
        local button = CreateFrame("Button", nil, frame)
        button:SetHeight(RECENT_ROW_HEIGHT)
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -6 - (index - 1) * RECENT_ROW_HEIGHT)
        button:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.label:SetPoint("LEFT", button, "LEFT", 4, 0)
        button.label:SetPoint("RIGHT", button, "RIGHT", -4, 0)
        button.label:SetJustifyH("LEFT")
        button.label:SetWordWrap(false)
        U.AddSelection(button)
        button:SetScript("OnClick", function(self, mouseButton)
            if mouseButton == "RightButton" then
                HouseLedgerDB.recentSearches = Price.ForgetRecent(HouseLedgerDB.recentSearches, self.searchText)
                recent.selected = 0
                Show()
            else
                box:SetText(self.searchText)
                Search()
            end
        end)
        recent.buttons[index] = button
    end
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 7)
    hint:SetText("Recent searches. Right-click one to forget it.")
    frame.lines = recent.buttons

    -- The arrow keys reach the box's OnArrowPressed only with this off.
    box:SetAltArrowKeyMode(false)
    box:HookScript("OnEditFocusGained", function(self)
        recent.typed = self:GetText()
        Show()
    end)
    box:HookScript("OnEditFocusLost", function()
        if not frame:IsMouseOver() then
            Hide()
        end
    end)
    box:HookScript("OnTextChanged", function(self, userInput)
        -- Only the player's typing narrows the list; text put in from it doesn't.
        if userInput then
            recent.selected, recent.typed = 0, self:GetText()
            if self:HasFocus() then
                Show()
            end
        end
    end)
    box:SetScript("OnArrowPressed", function(_, key)
        if key == "UP" then
            Move(-1)
        elseif key == "DOWN" then
            Move(1)
        end
    end)
    box:HookScript("OnEscapePressed", Hide)
    -- Enter searches what the box shows: typed, or put in from the list.
    box:SetScript("OnEnterPressed", Search)
    return { frame = frame, Hide = Hide }
end
