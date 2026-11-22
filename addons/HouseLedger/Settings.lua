--[[
The Settings tab: checkboxes from PriceLedger.SETTINGS and the history length dropdown.
]]

local _, ns = ...
local C, ui, Price, U, PC, Settings = ns.C, ns.ui, ns.Price, ns.U, ns.PC, ns.Settings

--- Makes the Settings tab: one checkbox per PriceLedger.SETTINGS entry, saved in
-- HouseLedgerDB.settings as soon as it is clicked. Nothing is sent.
function Settings.BuildPanel()
    ui.settingsPanel = CreateFrame("Frame", nil, ui.frame)
    ui.settingsPanel:SetAllPoints(ui.frame)
    ui.settingsPanel:Hide()
    ui.frame.settingsPanel = ui.settingsPanel
    ui.settingsPanel.boxes = {}
    for index, setting in ipairs(Price.SETTINGS) do
        local box = CreateFrame("CheckButton", nil, ui.settingsPanel, "UICheckButtonTemplate")
        box:SetSize(26, 26)
        box:SetPoint("TOPLEFT", ui.settingsPanel, "TOPLEFT", 20, -C.LIST_TOP - 12 - (index - 1) * 30)
        box:SetChecked(HouseLedgerDB.settings[setting.key] == true)
        box:SetScript("OnClick", function(self)
            HouseLedgerDB.settings[setting.key] = self:GetChecked() == true
            if setting.key == "priceCheckButton" and ui.priceCheck then
                PC.UpdateBagButtons()
            end
        end)
        local label = U.Cell(ui.settingsPanel, "GameFontHighlight", "LEFT")
        label:SetPoint("LEFT", box, "RIGHT", 4, 0)
        label:SetPoint("RIGHT", ui.settingsPanel, "RIGHT", -16, 0)
        label:SetText(setting.label)
        ui.settingsPanel.boxes[setting.key] = box
    end

    local historyLabel = U.Cell(ui.settingsPanel, "GameFontHighlight", "LEFT")
    historyLabel:SetPoint("TOPLEFT", ui.settingsPanel, "TOPLEFT", 26,
        -C.LIST_TOP - 22 - #Price.SETTINGS * 30)
    historyLabel:SetText("Keep price history for")
    local history = CreateFrame("DropdownButton", nil, ui.settingsPanel, "WowStyle1DropdownTemplate")
    history:SetWidth(110)
    history:SetPoint("LEFT", historyLabel, "RIGHT", 10, 0)
    history:SetupMenu(function(_, root)
        for _, days in ipairs(Price.HISTORY_CHOICES) do
            root:CreateRadio(days .. " days", function(picked)
                return Price.DAYS_KEPT == picked
            end, function(picked)
                Price.SetHistoryDays(HouseLedgerDB, picked)
            end, days)
        end
    end)
    local historyHint = U.Cell(ui.settingsPanel, "GameFontDisableSmall", "LEFT")
    historyHint:SetPoint("TOPLEFT", historyLabel, "BOTTOMLEFT", 0, -14)
    historyHint:SetPoint("RIGHT", ui.settingsPanel, "RIGHT", -16, 0)
    historyHint:SetText("Longer history uses more memory and makes a bigger saved file: 60 days takes about"
        .. " three times as much as 14. A shorter one drops older days right away.")
    ui.settingsPanel.historyDropdown, ui.settingsPanel.historyHint = history, historyHint
end
