--- JSON reading and writing for scripts/store_upload.sh, so the store uploads need no jq.
-- Plain Lua 5.1 and its standard library only. It reads the stores' game version lists and
-- writes the upload metadata. Loaded with dofile it returns the module (the tests use that);
-- run as a script it does one command and prints the answer to stdout.
--
-- Usage:
--   lua5.1 scripts/store_json.lua cf-version <versions.json> <type id> <X.Y.Z>
--       prints "<id> <name> exact|older": that CurseForge version, or the closest older one
--   lua5.1 scripts/store_json.lua wago-patch <game.json> <flavor> <X.Y.Z>
--       prints "<patch> exact|older" from Wago's patch list for that flavor
--   lua5.1 scripts/store_json.lua cf-metadata <notes file> <display name> <version id> <true|false>
--   lua5.1 scripts/store_json.lua wago-metadata <notes file> <label> <flavor> <patch>
--       print the upload metadata as one line of JSON
-- Errors go to stderr as "store_json: <why>", with exit status 1.

local M = {}

--- Stands for JSON null, which a Lua table can't hold as nil.
M.null = setmetatable({}, { __tostring = function() return "null" end })

local ObjectMeta = {}

--- Make an object whose keys are written in the given order.
-- @param fields A list of {key, value} pairs.
-- @return The object, for M.encode.
function M.object(fields)
    return setmetatable({ fields = fields }, ObjectMeta)
end

-- Decoding ------------------------------------------------------------------------------------

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n",
    r = "\r", t = "\t" }

--- Stop decoding with the reason and where it happened.
-- @param pos Byte position in the text.
-- @param what What is wrong.
local function fail(pos, what)
    error(("JSON: %s at byte %d"):format(what, pos), 0)
end

--- Find the next byte that isn't JSON whitespace.
-- @param text The JSON text.
-- @param pos Where to start.
-- @return Its position, or #text + 1 at the end.
local function skipSpace(text, pos)
    return text:find("[^ \t\r\n]", pos) or #text + 1
end

--- Encode one Unicode code point as UTF-8.
-- @param code The code point, 0 to 0x10FFFF.
-- @return The UTF-8 bytes.
local function utf8(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

--- Read a \uXXXX escape, and the low half that must follow a high surrogate.
-- @param text The JSON text.
-- @param pos Position of the backslash.
-- @return The UTF-8 bytes and the position after the escape.
local function decodeUnicode(text, pos)
    local hex = text:match("^\\u(%x%x%x%x)", pos)
    if not hex then fail(pos, "bad \\u escape") end
    local code = tonumber(hex, 16)
    pos = pos + 6
    if code >= 0xDC00 and code <= 0xDFFF then fail(pos - 6, "lone low surrogate") end
    if code >= 0xD800 and code <= 0xDBFF then
        local low = text:match("^\\u(%x%x%x%x)", pos)
        local lowCode = low and tonumber(low, 16)
        if not lowCode or lowCode < 0xDC00 or lowCode > 0xDFFF then
            fail(pos - 6, "high surrogate without its low half")
        end
        code = 0x10000 + (code - 0xD800) * 0x400 + (lowCode - 0xDC00)
        pos = pos + 6
    end
    return utf8(code), pos
end

--- Read a string.
-- @param text The JSON text.
-- @param pos Position of the opening quote.
-- @return The string and the position after the closing quote.
local function decodeString(text, pos)
    local parts, i = {}, pos + 1
    while true do
        local c = text:sub(i, i)
        if c == "" then
            fail(pos, "unfinished string")
        elseif c == '"' then
            return table.concat(parts), i + 1
        elseif c == "\\" then
            local e = text:sub(i + 1, i + 1)
            if e == "u" then
                parts[#parts + 1], i = decodeUnicode(text, i)
            elseif ESCAPES[e] then
                parts[#parts + 1] = ESCAPES[e]
                i = i + 2
            else
                fail(i, "bad escape")
            end
        elseif c:byte() < 0x20 then
            fail(i, "control character in a string")
        else
            local stop = text:find('[%z\1-\31"\\]', i) or #text + 1
            parts[#parts + 1] = text:sub(i, stop - 1)
            i = stop
        end
    end
end

local decodeValue

--- Read the items of a list or the members of an object, up to the closing bracket.
-- @param text The JSON text.
-- @param pos Position after the opening bracket.
-- @param close "]" or "}".
-- @param readItem function(pos) that reads one item and returns the position after it.
-- @return The position after the closing bracket.
local function decodeItems(text, pos, close, readItem)
    pos = skipSpace(text, pos)
    if text:sub(pos, pos) == close then return pos + 1 end
    while true do
        pos = skipSpace(text, readItem(pos))
        local c = text:sub(pos, pos)
        if c == close then return pos + 1 end
        if c ~= "," then fail(pos, "expected ',' or '" .. close .. "'") end
        pos = skipSpace(text, pos + 1)
        if text:sub(pos, pos) == close then fail(pos, "trailing comma") end
    end
end

--- Read one value of any kind.
-- @param text The JSON text.
-- @param pos Position of its first byte (whitespace already skipped).
-- @return The value and the position after it.
decodeValue = function(text, pos)
    local c = text:sub(pos, pos)
    if c == '"' then
        return decodeString(text, pos)
    elseif c == "{" then
        local result = {}
        local after = decodeItems(text, pos + 1, "}", function(at)
            if text:sub(at, at) ~= '"' then fail(at, "expected a key") end
            local key, nextPos = decodeString(text, at)
            nextPos = skipSpace(text, nextPos)
            if text:sub(nextPos, nextPos) ~= ":" then fail(nextPos, "expected ':'") end
            local value
            value, nextPos = decodeValue(text, skipSpace(text, nextPos + 1))
            result[key] = value
            return nextPos
        end)
        return result, after
    elseif c == "[" then
        local result = {}
        local after = decodeItems(text, pos + 1, "]", function(at)
            local value, nextPos = decodeValue(text, at)
            result[#result + 1] = value
            return nextPos
        end)
        return result, after
    end
    for word, value in pairs({ ["true"] = true, ["false"] = false, ["null"] = M.null }) do
        if text:sub(pos, pos + #word - 1) == word then return value, pos + #word end
    end
    local number = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if number and tonumber(number) then return tonumber(number), pos + #number end
    fail(pos, "unexpected text")
end

--- Read a whole JSON text.
-- @param text The JSON text.
-- @return The value: tables for objects and lists, M.null for null.
-- @raise "JSON: <why> at byte <n>" when the text isn't valid JSON.
function M.decode(text)
    local pos = skipSpace(text, 1)
    if pos > #text then fail(pos, "no value") end
    local value
    value, pos = decodeValue(text, pos)
    pos = skipSpace(text, pos)
    if pos <= #text then fail(pos, "text after the value") end
    return value
end

-- Encoding ------------------------------------------------------------------------------------

local SHORT = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n",
    ["\r"] = "\\r", ["\t"] = "\\t" }

--- Write a string as JSON: quotes, backslashes and control characters escaped, UTF-8 kept.
-- @param s The string.
-- @return The JSON string.
local function encodeString(s)
    local escaped = s:gsub('[%z\1-\31"\\]', function(c)
        return SHORT[c] or ("\\u%04x"):format(c:byte())
    end)
    return '"' .. escaped .. '"'
end

--- Write a value as JSON on one line.
-- @param value A string, number, boolean, M.null, M.object(...) or a list (a plain table).
-- @return The JSON text.
-- @raise When the value holds something JSON can't (a function, NaN, infinity).
function M.encode(value)
    local kind = type(value)
    if kind == "string" then
        return encodeString(value)
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("JSON can't hold " .. tostring(value), 0)
        end
        if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
            return ("%d"):format(value)
        end
        return ("%.17g"):format(value)
    elseif value == M.null then
        return "null"
    elseif getmetatable(value) == ObjectMeta then
        local parts = {}
        for i, field in ipairs(value.fields) do
            parts[i] = encodeString(field[1]) .. ":" .. M.encode(field[2])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif kind == "table" then
        local parts = {}
        for i, item in ipairs(value) do parts[i] = M.encode(item) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    error("JSON can't hold a " .. kind, 0)
end

-- Versions -------------------------------------------------------------------------------------

--- Split "X.Y.Z" into numbers.
-- @param name The version text.
-- @return {X, Y, Z}, or nil if it isn't three whole numbers.
local function parseVersion(name)
    if type(name) ~= "string" then return nil end
    local a, b, c = name:match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
end

--- True when version x comes before version y.
local function before(x, y)
    for i = 1, 3 do
        if x[i] ~= y[i] then return x[i] < y[i] end
    end
    return false
end

--- Choose a game version: the wanted one if the store has it, else the closest older one. A
-- newer one is never chosen, since the addon hasn't been checked against it.
-- @param names The store's version names.
-- @param want The version the addon's .toc names, "X.Y.Z".
-- @return The chosen name and "exact" or "older", or nil when nothing fits.
function M.pickVersion(names, want)
    local wanted = assert(parseVersion(want), "not a version: " .. tostring(want))
    local best, bestVersion
    for _, name in ipairs(names) do
        local version = parseVersion(name)
        if version and not before(wanted, version) then
            if not before(version, wanted) then return name, "exact" end
            if not bestVersion or before(bestVersion, version) then
                best, bestVersion = name, version
            end
        end
    end
    if best then return best, "older" end
    return nil
end

--- Choose a CurseForge game version for one game version type.
-- @param list CurseForge's /api/game/versions answer: {{id, gameVersionTypeID, name}, ...}.
-- @param typeId The game version type, such as 88568 for WoW Forever.
-- @param want "X.Y.Z".
-- @return The version's id, its name and "exact" or "older", or nil when none fits.
function M.cfVersion(list, typeId, want)
    local names, idByName = {}, {}
    for _, entry in ipairs(list) do
        if type(entry) == "table" and entry.gameVersionTypeID == typeId
            and type(entry.id) == "number" and parseVersion(entry.name) then
            if not idByName[entry.name] then names[#names + 1] = entry.name end
            idByName[entry.name] = math.max(idByName[entry.name] or entry.id, entry.id)
        end
    end
    local name, match = M.pickVersion(names, want)
    if not name then return nil end
    return idByName[name], name, match
end

--- Choose a Wago patch for one game flavor.
-- @param game Wago's /api/data/game answer: {patches = {<flavor> = {"X.Y.Z", ...}}}.
-- @param flavor Such as "forever".
-- @param want "X.Y.Z".
-- @return The patch and "exact" or "older", or nil when none fits.
function M.wagoPatch(game, flavor, want)
    local patches = type(game) == "table" and type(game.patches) == "table"
        and game.patches[flavor]
    if type(patches) ~= "table" then return nil end
    return M.pickVersion(patches, want)
end

-- Metadata ------------------------------------------------------------------------------------

--- CurseForge upload metadata (support.curseforge.com, "CurseForge Upload API").
-- @param notes The changelog section, Markdown.
-- @param displayName Such as "HouseLedger 0.3.0".
-- @param versionId The game version id from M.cfVersion.
-- @param manual True to hold the file until the owner releases it on the site.
-- @return The JSON text.
function M.cfMetadata(notes, displayName, versionId, manual)
    return M.encode(M.object({
        { "displayName", displayName },
        { "gameVersions", { versionId } },
        { "releaseType", "release" },
        { "changelogType", "markdown" },
        { "changelog", notes },
        { "isMarkedForManualRelease", manual },
    }))
end

--- Wago upload metadata, with the patch field named as the BigWigs packager sends it
-- ("supported_<flavor>_patches", a list).
-- @param notes The changelog section, Markdown.
-- @param label Such as "0.3.0".
-- @param flavor Such as "forever".
-- @param patch The patch from M.wagoPatch.
-- @return The JSON text.
function M.wagoMetadata(notes, label, flavor, patch)
    return M.encode(M.object({
        { "label", label },
        { "stability", "stable" },
        { "changelog", notes },
        { "supported_" .. flavor .. "_patches", { patch } },
    }))
end

-- Command line ----------------------------------------------------------------------------------

--- Read a whole file.
-- @param path The file.
-- @return Its text.
-- @raise When it can't be read.
local function readFile(path)
    local file, err = io.open(path, "rb")
    if not file then error(err, 0) end
    local text = file:read("*a")
    file:close()
    return text
end

-- Each command with how many arguments it takes.
local ARITY = { ["cf-version"] = 3, ["wago-patch"] = 3, ["cf-metadata"] = 4, ["wago-metadata"] = 4 }

local COMMANDS = {
    ["cf-version"] = function(path, typeId, want)
        local id, name, match = M.cfVersion(M.decode(readFile(path)),
            assert(tonumber(typeId), "the type id must be a number"), want)
        if not id then error("CurseForge lists no version " .. want .. " or older for this game", 0) end
        return ("%d %s %s"):format(id, name, match)
    end,
    ["wago-patch"] = function(path, flavor, want)
        local patch, match = M.wagoPatch(M.decode(readFile(path)), flavor, want)
        if not patch then error("Wago lists no " .. flavor .. " patch " .. want .. " or older", 0) end
        return patch .. " " .. match
    end,
    ["cf-metadata"] = function(notesPath, displayName, versionId, manual)
        if manual ~= "true" and manual ~= "false" then error("manual must be true or false", 0) end
        local id = tonumber(versionId)
        if not id or id ~= math.floor(id) then error("the version id must be a whole number", 0) end
        return M.cfMetadata(readFile(notesPath), displayName, id, manual == "true")
    end,
    ["wago-metadata"] = function(notesPath, label, flavor, patch)
        return M.wagoMetadata(readFile(notesPath), label, flavor, patch)
    end,
}

--- Run one command.
-- @param args The command name and its arguments.
-- @return The exit status: 0 done, 1 failed, 2 usage.
local function main(args)
    local command = COMMANDS[args[1]]
    if not command or #args ~= ARITY[args[1]] + 1 then
        io.stderr:write("usage: store_json.lua <cf-version|wago-patch|cf-metadata|wago-metadata> ...\n")
        return 2
    end
    local ok, result = pcall(command, args[2], args[3], args[4], args[5])
    if not ok then
        io.stderr:write("store_json: ", tostring(result), "\n")
        return 1
    end
    io.write(result, "\n")
    return 0
end

local args = { ... }
if #args > 0 then os.exit(main(args)) end
return M
