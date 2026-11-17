--[[
Saved prices on item tooltips. Reads saved data only.
]]

local _, ns = ...
local Price, U, Scan, Tooltip = ns.Price, ns.U, ns.Scan, ns.Tooltip

local tooltipsHooked = false

--- Adds the saved price lines to an item tooltip.
-- Holding Shift adds the detail lines.
-- @param tooltip the tooltip being built
-- @param data the game's tooltip data, with the item id or hyperlink
local function AddPriceLine(tooltip, data)
    if tooltip == nil or type(tooltip.AddLine) ~= "function" or type(data) ~= "table" then
        return
    end
    local itemID = data.id
    if type(itemID) ~= "number" and type(data.hyperlink) == "string" and type(GetItemInfoInstant) == "function" then
        itemID = GetItemInfoInstant(data.hyperlink)
    end
    local info = Price.Lookup(HouseLedgerDB, itemID, U.PlayerHouseKey())
    if info == nil then
        return
    end
    if not HouseLedgerDB.settings.tooltipPrices then
        return
    end
    -- Shift is read when the tooltip is built: hold it, then hover. A setting can always show them.
    local showDetails = HouseLedgerDB.settings.tooltipDetails
        or (type(IsShiftKeyDown) == "function" and IsShiftKeyDown() == true)
    local lines = Price.TooltipLines(info, U.CopperToText, showDetails)
    if lines == nil then
        return
    end
    -- First line in gold like other price lines; details in light gray.
    tooltip:AddLine(lines[1].left, 1, 0.82, 0, true)
    for index = 2, #lines do
        local line = lines[index]
        if line.right and type(tooltip.AddDoubleLine) == "function" then
            tooltip:AddDoubleLine(line.left, line.right, 0.8, 0.8, 0.8, 1, 1, 1)
        else
            tooltip:AddLine(line.left, 0.8, 0.8, 0.8, true)
        end
    end
end

--- Hooks item tooltips once, through TooltipDataProcessor.
-- @return true when hooked (now or before), false when this client cannot be hooked
function Tooltip.Hook()
    if tooltipsHooked then
        return true
    end
    if TooltipDataProcessor == nil or type(TooltipDataProcessor.AddTooltipPostCall) ~= "function" then
        return false
    end
    if Enum == nil or Enum.TooltipDataType == nil or Enum.TooltipDataType.Item == nil then
        return false
    end
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, AddPriceLine)
    tooltipsHooked = true
    return true
end

--- Says so when mouseover prices could not be hooked on this client.
function Tooltip.NoteUnavailable()
    if not tooltipsHooked then
        Scan.SetStatus("Mouseover prices are unavailable on this client.", 8)
    end
end
