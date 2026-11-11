--- Line coverage for the addon tests, with Lua 5.1's own debug library and no packages.
--
-- Two commands:
--
--   lua5.1 scripts/lua_coverage.lua run <hits file> <test.lua>
--     Runs one test file with a line hook and appends every "source:line" it ran to the hits
--     file, also when the test ends with os.exit. Exits with the test's own status.
--
--   lua5.1 scripts/lua_coverage.lua report <minimum percent> <hits file> <file.lua>...
--     For each file, compares the lines that ran with the lines that can run, read from
--     `luac -p -l` (LUAC, default luac5.1). Prints one line per file and exits 1 if any file is
--     under the minimum.
--
-- A line "can run" when luac compiled an instruction for it. The one exception is the return
-- that Lua adds at the end of every function: it never runs after an explicit return, so a
-- line whose only instruction is that added return is left out.

local USAGE = "usage: lua5.1 scripts/lua_coverage.lua run <hits file> <test.lua>\n"
    .. "       lua5.1 scripts/lua_coverage.lua report <minimum percent> <hits file> <file.lua>...\n"

--- Turn a chunk name or path into the path form used in reports: no leading "@" or "./".
-- @param name a chunk source such as "@./addons/Demo/Demo.lua", or a path
-- @return the plain path, such as "addons/Demo/Demo.lua"
local function PlainPath(name)
    name = name:gsub("^@", "")
    while name:sub(1, 2) == "./" do
        name = name:sub(3)
    end
    return name
end

--- Append every recorded line to the hits file, one "path:line" per line.
-- @param hitsPath path of the hits file
-- @param hits table of path -> { [line] = true }
local function SaveHits(hitsPath, hits)
    local file = assert(io.open(hitsPath, "a"))
    for path, lines in pairs(hits) do
        for line in pairs(lines) do
            file:write(path, ":", line, "\n")
        end
    end
    file:close()
end

--- Run one test file under a line hook and record which lines ran.
-- @param hitsPath path of the hits file to append to
-- @param testPath path of the *_test.lua file
-- @return never; exits with the test's status
local function Run(hitsPath, testPath)
    local hits = {}
    local getinfo = debug.getinfo
    local realExit = os.exit
    local saved = false

    local function Finish()
        if not saved then
            saved = true
            debug.sethook()
            SaveHits(hitsPath, hits)
        end
    end

    -- Tests find their addon files next to arg[0], as when run directly.
    arg = { [0] = testPath }
    os.exit = function(code)
        Finish()
        realExit(code)
    end
    debug.sethook(function(_, line)
        local path = PlainPath(getinfo(2, "S").source)
        local lines = hits[path]
        if not lines then
            lines = {}
            hits[path] = lines
        end
        lines[line] = true
    end, "l")

    local ok, err = pcall(dofile, testPath)
    Finish()
    if not ok then
        io.stderr:write(tostring(err), "\n")
        realExit(1)
    end
    realExit(0)
end

--- Read the lines that can run in one Lua file from luac's listing.
-- @param path the .lua file
-- @return set of line numbers, { [line] = true }
local function RunnableLines(path)
    local luac = os.getenv("LUAC") or "luac5.1"
    local pipe = assert(io.popen(string.format("%s -p -l %q", luac, path)))
    local counts, runnable = {}, {}
    local addedReturn = nil

    -- The last instruction of each function is the return Lua adds. Drop its line unless
    -- something else on that line compiled too.
    local function EndFunction()
        if addedReturn and counts[addedReturn] == 1 then
            counts[addedReturn] = nil
        end
        addedReturn = nil
    end

    for text in pipe:lines() do
        if text:match("^main <") or text:match("^function <") then
            EndFunction()
        else
            local line, opcode, operands = text:match("^%s+%d+%s+%[(%d+)%]%s+(%u+)%s+([^;]*)")
            if line then
                line = tonumber(line)
                counts[line] = (counts[line] or 0) + 1
                local isAdded = opcode == "RETURN" and operands:match("^0 1%s*$")
                addedReturn = isAdded and line or nil
            end
        end
    end
    EndFunction()
    pipe:close()

    for line in pairs(counts) do
        runnable[line] = true
    end
    return runnable
end

--- Read the hits file into path -> { [line] = true }.
-- @param hitsPath path of the hits file
-- @return the hits table (empty if the file does not exist)
local function LoadHits(hitsPath)
    local hits = {}
    local file = io.open(hitsPath, "r")
    if not file then
        return hits
    end
    for text in file:lines() do
        local path, line = text:match("^(.*):(%d+)$")
        if path then
            hits[path] = hits[path] or {}
            hits[path][tonumber(line)] = true
        end
    end
    file:close()
    return hits
end

--- Write sorted line numbers as compact ranges, such as "6-7, 9".
-- @param lines array of line numbers, sorted
-- @return the ranges as text
local function Ranges(lines)
    local parts = {}
    local first, last = nil, nil
    for _, line in ipairs(lines) do
        if last and line == last + 1 then
            last = line
        else
            if first then
                parts[#parts + 1] = first == last and tostring(first) or (first .. "-" .. last)
            end
            first, last = line, line
        end
    end
    if first then
        parts[#parts + 1] = first == last and tostring(first) or (first .. "-" .. last)
    end
    return table.concat(parts, ", ")
end

--- Report coverage for each file and fail any under the minimum.
-- @param minimum lowest percent of runnable lines that must run
-- @param hitsPath path of the hits file
-- @param paths list of .lua files to measure
-- @return never; exits 0 if every file meets the minimum, 1 if not
local function Report(minimum, hitsPath, paths)
    local hits = LoadHits(hitsPath)
    local under = {}
    for _, given in ipairs(paths) do
        local path = PlainPath(given)
        local ran = hits[path] or {}
        local total, count, missed = 0, 0, {}
        for line in pairs(RunnableLines(given)) do
            total = total + 1
            if ran[line] then
                count = count + 1
            else
                missed[#missed + 1] = line
            end
        end
        table.sort(missed)
        local percent = total == 0 and 100 or count * 100 / total
        local text = string.format("%s: %.1f%% of %d lines run", path, percent, total)
        if #missed > 0 then
            text = text .. "; not run: " .. Ranges(missed)
        end
        print(text)
        if percent < minimum then
            under[#under + 1] = string.format("%s: %.1f%% of lines run, below the %s%% minimum",
                path, percent, tostring(minimum))
        end
    end
    for _, text in ipairs(under) do
        print(text)
    end
    os.exit(#under == 0 and 0 or 1)
end

local command = arg[1]
if command == "run" and arg[2] and arg[3] then
    Run(arg[2], arg[3])
elseif command == "report" and tonumber(arg[2]) and arg[3] and arg[4] then
    local paths = {}
    for i = 4, #arg do
        paths[#paths + 1] = arg[i]
    end
    Report(tonumber(arg[2]), arg[3], paths)
else
    io.stderr:write(USAGE)
    os.exit(2)
end
