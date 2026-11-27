--[[
Offline checks for UnmakerBind: the key for "Disenchant next" and its action bar macro, against
a fake of the game's binding and macro calls that records every change. The game does not load
this file.
Run: lua5.1 bind_test.lua
]]

local folder = arg[0]:match("^(.*)/") or "."
local failed = 0

--- Records one check: prints "ok  <name>", or "FAIL  <name>" and counts the failure.
-- @param name what the check proves
-- @param ok true when it passed
local function Check(name, ok)
    if ok then
        io.write("ok  " .. name .. "\n")
        return
    end
    failed = failed + 1
    io.write("FAIL  " .. name .. "\n")
end

local ACTION = "CLICK UnmakerNextButton:LeftButton"
local game -- the fake game's state, reset by Fake()

--- Puts a fake of the game's binding and macro calls in place.
-- @param setup optional: bindings = { [key] = action }, macros = { { name, icon, body } },
--   account = how many account macros exist, inCombat
local function Fake(setup)
    setup = setup or {}
    game = { bindings = setup.bindings or {}, saved = 0, macros = setup.macros or {}, created = {}, picked = nil,
        account = setup.account or #(setup.macros or {}), inCombat = setup.inCombat == true }
    _G.InCombatLockdown = function() return game.inCombat end
    _G.GetBindingAction = function(key) return game.bindings[key] or "" end
    _G.GetBindingKey = function(action)
        local keys = {}
        for key, bound in pairs(game.bindings) do
            if bound == action then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys)
        return unpack(keys)
    end
    _G.SetBinding = function(key, action)
        game.bindings[key] = action
        return true
    end
    _G.GetCurrentBindingSet = function() return 2 end
    _G.SaveBindings = function(set)
        game.saved = game.saved + 1
        game.savedSet = set
    end
    _G.GetBindingText = function(key) return "<" .. key .. ">" end
    _G.BINDING_NAME_ACTIONBUTTON1 = "Action Button 1"
    _G.GetNumMacros = function() return game.account, 0 end
    _G.GetMacroIndexByName = function(name)
        for index, macro in ipairs(game.macros) do
            if macro[1] == name then
                return index
            end
        end
        return 0
    end
    _G.CreateMacro = function(name, icon, body, perCharacter)
        game.macros[#game.macros + 1] = { name, icon, body }
        game.account = game.account + 1
        game.created[#game.created + 1] = { name = name, icon = icon, body = body, perCharacter = perCharacter }
        return #game.macros
    end
    _G.PickupMacro = function(index) game.picked = index end
    _G.Constants = { MacroConsts = { MAX_ACCOUNT_MACROS = 120 } }
    _G.C_Spell = { GetSpellTexture = function(spell) return spell == 13262 and 999001 or nil end }
end

Fake()
local B = dofile(folder .. "/UnmakerBind.lua")

-- The key: a chord from the key and the modifiers held, in the game's ALT-CTRL-SHIFT order.
do
    Check("chord: a plain key", B.Chord("F", false, false, false) == "F")
    Check("chord: modifiers in the game's order", B.Chord("F", true, true, true) == "ALT-CTRL-SHIFT-F")
    Check("chord: a modifier alone is no key yet", B.Chord("LSHIFT", false, false, true) == nil
        and B.Chord("RCTRL", false, true, false) == nil and B.Chord("LALT", true, false, false) == nil)
    Check("chord: nothing for an unknown key", B.Chord("UNKNOWN", false, false, false) == nil and B.Chord(nil) == nil)
end

do
    Fake()
    Check("key: none bound yet", B.KeyText() == nil)
    Check("key: a free key has no other use", B.OtherUse("F") == nil)
    Check("key: set it", B.SetKey("F") == true and game.bindings.F == ACTION and game.saved == 1
        and game.savedSet == 2)
    Check("key: the button shows it the game's way", B.KeyText() == "<F>")
    Check("key: its own key isn't another use", B.OtherUse("F") == nil)
    B.SetKey("G")
    Check("key: a new key replaces the old one", game.bindings.G == ACTION and game.bindings.F == nil
        and B.KeyText() == "<G>")
    B.ClearKey()
    Check("key: clear unbinds it and saves", game.bindings.G == nil and B.KeyText() == nil and game.saved == 3)
end

do
    Fake({ bindings = { ["1"] = "ACTIONBUTTON1", X = "SOME_ADDON_THING" } })
    Check("key: another use is named the game's way", B.OtherUse("1") == "Action Button 1")
    Check("key: an action without a name shows as itself", B.OtherUse("X") == "SOME_ADDON_THING")
end

do
    Fake({ inCombat = true })
    Check("key: nothing changes in combat", B.SetKey("F") == false and game.bindings.F == nil and game.saved == 0)
end

-- The action bar: one macro, made once, picked up so the player can drop it on a slot.
do
    Fake()
    local ok = B.PickupMacro()
    local made = game.created[1]
    Check("macro: made once, for every character, clicking the Disenchant next button", ok == true and made ~= nil
        and made.name == B.MACRO_NAME and made.body == "/click UnmakerNextButton" and not made.perCharacter
        and made.icon == 999001)
    Check("macro: put on the cursor", game.picked == 1)
    game.picked = nil
    B.PickupMacro()
    Check("macro: the second time it reuses the one there", #game.created == 1 and game.picked == 1)
end

do
    Fake({ macros = { { "Unmaker", 1, "/say mine" } } })
    B.PickupMacro()
    Check("macro: a macro with that name is picked up as it is, never changed", #game.created == 0
        and game.picked == 1 and game.macros[1][3] == "/say mine")
end

do
    Fake({ account = 120 })
    local ok, why = B.PickupMacro()
    Check("macro: no room for one more says so", ok == false and #game.created == 0 and game.picked == nil
        and why:find("120", 1, true) ~= nil)
    Fake({ inCombat = true })
    ok, why = B.PickupMacro()
    Check("macro: nothing in combat", ok == false and #game.created == 0 and why:find("combat", 1, true) ~= nil)
end

if failed > 0 then
    io.write(string.format("%d failed\n", failed))
    os.exit(1)
end
io.write("all passed\n")
