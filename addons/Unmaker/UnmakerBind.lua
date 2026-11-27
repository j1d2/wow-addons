--[[
UnmakerBind: a key and an action bar button for "Disenchant next", set from Unmaker's own window
instead of the game's Key Bindings menu or macro window.

Both only point at UnmakerNextButton, a Blizzard secure button: one press still disenchants one
item, as with a click (RULES.md, Disenchanting).
- The key is the same binding Bindings.xml lists ("CLICK UnmakerNextButton:LeftButton"), so the
  game's Key Bindings menu and this window always agree. Set the way Blizzard's own menu does it:
  bind the key, then save the binding set in use.
- The action bar button is one account macro, "/click UnmakerNextButton", made once and picked
  up onto the cursor so the player drops it on a slot. A macro of that name already there is
  reused as it is, never changed.
Nothing here runs in combat.
]]

-- The game hands each addon file its name and the addon's own table; Unmaker.lua reads this
-- module as ns.Bind. Offline (lua5.1 and dofile) there is no table, and dofile returns the
-- module instead.
local _, ns = ...
local B = {}
if type(ns) == "table" then
    ns.Bind = B
end

-- The binding Bindings.xml declares: a left click on the Disenchant next button.
B.ACTION = "CLICK UnmakerNextButton:LeftButton"
B.MACRO_NAME = "Unmaker"
B.MACRO_BODY = "/click UnmakerNextButton"
-- The macro's icon: Disenchant's own, asked from the game; the question mark if it can't say.
B.DISENCHANT_SPELL = 13262
B.FALLBACK_ICON = 134400

-- Keys that are only modifiers: held with another key they make a chord, alone they are no key.
local MODIFIER_KEYS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
    LMETA = true, RMETA = true, UNKNOWN = true,
}

--- Whether the game is in combat lockdown.
-- @return true in combat
local function InCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() == true
end

--- The binding text for a key and the modifiers held, in the game's order ("ALT-CTRL-SHIFT-F").
-- @param key the key the game reported, like "F"
-- @param alt true while Alt is held
-- @param ctrl true while Ctrl is held
-- @param shift true while Shift is held
-- @return the chord, or nil for a modifier on its own or no key
function B.Chord(key, alt, ctrl, shift)
    if type(key) ~= "string" or key == "" or MODIFIER_KEYS[key] then
        return nil
    end
    return (alt and "ALT-" or "") .. (ctrl and "CTRL-" or "") .. (shift and "SHIFT-" or "") .. key
end

--- The key that runs Disenchant next, as the game writes it, or nil when none is set.
-- @return the text
function B.KeyText()
    local key = GetBindingKey(B.ACTION)
    if key == nil then
        return nil
    end
    return GetBindingText(key)
end

--- What else a key does now, by the name the Key Bindings menu shows.
-- @param chord the key, like "SHIFT-F"
-- @return the other action's name, or nil when the key is free or already Unmaker's
function B.OtherUse(chord)
    local action = GetBindingAction(chord)
    if action == nil or action == "" or action == B.ACTION then
        return nil
    end
    return _G["BINDING_NAME_" .. action] or action
end

--- Saves the bindings to the set the game is using (account or this character), as the game's
-- own Key Bindings menu does after a change.
local function Save()
    SaveBindings(GetCurrentBindingSet()) -- reviewed: the player picked this key in Unmaker's window
end

--- Removes every key from Disenchant next.
local function Unbind()
    local keys = { GetBindingKey(B.ACTION) }
    for _, key in ipairs(keys) do
        SetBinding(key) -- reviewed: clears Unmaker's own key, on the player's click
    end
end

--- Makes a key run Disenchant next, replacing the key it had. The caller has asked the player
-- first when the key did something else.
-- @param chord the key, like "SHIFT-F"
-- @return true when set; false in combat
function B.SetKey(chord)
    if InCombat() then
        return false
    end
    Unbind()
    SetBinding(chord, B.ACTION) -- reviewed: the key the player pressed for Disenchant next
    Save()
    return true
end

--- Takes the key off Disenchant next.
-- @return true when cleared; false in combat
function B.ClearKey()
    if InCombat() then
        return false
    end
    Unbind()
    Save()
    return true
end

--- Puts the Disenchant next macro on the cursor, making it first if there isn't one.
-- @return true when it's on the cursor; false and why not
function B.PickupMacro()
    if InCombat() then
        return false, "Not in combat. Try again when the fight ends."
    end
    local index = GetMacroIndexByName(B.MACRO_NAME)
    if index == nil or index == 0 then
        local limit = Constants.MacroConsts.MAX_ACCOUNT_MACROS
        local account = GetNumMacros()
        if account >= limit then
            return false, string.format("Your account macros are full (%d). Delete one in the game's macro "
                .. "window, then try again.", limit)
        end
        local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(B.DISENCHANT_SPELL)
        index = CreateMacro(B.MACRO_NAME, icon or B.FALLBACK_ICON, B.MACRO_BODY) -- reviewed: on the player's click
        if index == nil or index == 0 then
            return false, "The game didn't make the macro. Try again."
        end
    end
    PickupMacro(index)
    return true
end

return B
