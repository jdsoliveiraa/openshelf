--[[
Headless test for OpenShelf providers.

Runs the REAL plugin code (catalog, providers, http_util) against the live
Gutendex / Internet Archive APIs, stubbing only the KOReader-specific modules
(json, socketutil, logger) that don't exist outside KOReader.

Requirements (once):
    brew install lua luarocks
    luarocks install luasocket luasec dkjson

Run:
    eval "$(luarocks path)"
    lua test/headless_providers.lua "sherlock holmes"
--]]

-- Resolve the plugin dir relative to this script (…/test/ -> …/openshelf.koplugin)
local this = arg[0]:gsub("[^/]*$", "")
if this == "" then this = "./" end
local PLUGIN = this .. "../openshelf.koplugin"
package.path = PLUGIN .. "/?.lua;" .. package.path

-- --- shims for KOReader-only modules -------------------------------------
package.preload["json"] = function()
    local dkjson = require("dkjson")
    return { decode = dkjson.decode, encode = dkjson.encode }
end
package.preload["socketutil"] = function()
    return {
        LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
        FILE_BLOCK_TIMEOUT = 30, FILE_TOTAL_TIMEOUT = 120,
        set_timeout = function() end,
        reset_timeout = function() end,
    }
end
package.preload["logger"] = function()
    local function w(...) io.stderr:write("[logger] " .. table.concat({...}, " ") .. "\n") end
    return { warn = w, info = function() end, dbg = function() end, err = w }
end
-- ------------------------------------------------------------------------

local Catalog = require("catalog")
local HttpUtil = require("http_util")

local function hr() print(string.rep("-", 70)) end
local fail = false

local QUERY = arg[1] or "sherlock holmes"
print("OpenShelf headless test — query: " .. QUERY)
hr()

print("providers registered: " .. #Catalog.providers)
for i, p in ipairs(Catalog.providers) do
    assert(type(p) == "table" and type(p.search) == "function",
        "provider #" .. i .. " is not a valid provider (regression!)")
    print(("  %d. %s"):format(i, p.name))
end
hr()

local results, errors = Catalog.search(QUERY, 8)
print(("Catalog.search returned %d merged results"):format(#results))
if #errors > 0 then
    fail = true
    print("Provider errors:")
    for _, e in ipairs(errors) do print("  ! " .. e) end
end
hr()

local by_source, order = {}, {}
for _, r in ipairs(results) do
    if not by_source[r.source] then by_source[r.source] = {}; order[#order+1] = r.source end
    table.insert(by_source[r.source], r)
end
for _, src in ipairs(order) do
    print(("[%s] %d results:"):format(src, #by_source[src]))
    for i = 1, math.min(3, #by_source[src]) do
        local r = by_source[src][i]
        print(("   %d. %s — %s"):format(i, r.title, r.author))
    end
end
hr()

for _, src in ipairs(order) do
    local r = by_source[src][1]
    local url, err = r.resolve()
    if url then
        print(("resolve OK   [%s] %s\n   -> %s"):format(src, r.title, url))
    else
        fail = true
        print(("resolve FAIL [%s] %s\n   -> %s"):format(src, r.title, tostring(err)))
    end
end
hr()

local g = by_source["Project Gutenberg"] and by_source["Project Gutenberg"][1]
if g then
    local url = g.resolve()
    local target = os.tmpname() .. ".epub"
    local path, derr = HttpUtil.download(url, target)
    if path then
        local f = io.open(path, "rb")
        local head = f:read(4); local size = f:seek("end"); f:close()
        os.remove(path)
        local is_zip = head and head:sub(1, 2) == "PK"
        if not is_zip then fail = true end
        print(("download OK -> %d bytes, valid epub/zip magic: %s"):format(size, tostring(is_zip)))
    else
        fail = true
        print("download FAIL -> " .. tostring(derr))
    end
end
hr()

if fail then
    print("RESULT: FAIL")
    os.exit(1)
else
    print("RESULT: PASS")
end
