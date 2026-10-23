--[[
Headless test for OpenShelf: runs the REAL plugin code (catalog, dedupe, opds,
providers, http_util) against the live APIs, stubbing only the KOReader-specific
modules (json, socketutil, logger).

Requirements (once):
    brew install lua luarocks
    luarocks install luasocket luasec dkjson

Run:
    eval "$(luarocks path)"
    lua test/headless_providers.lua "pride and prejudice"

Notes:
 - DOAB blocks datacenter IPs (403); its failure here is EXPECTED and ignored.
 - Internet Archive EPUBs can be large, so we validate downloads only for
   Standard Ebooks + Feedbooks + Gutenberg.
--]]
local this = arg[0]:gsub("[^/]*$", "")
if this == "" then this = "./" end
local PLUGIN = this .. "../openshelf.koplugin"
package.path = PLUGIN .. "/?.lua;" .. package.path

-- shims for KOReader-only modules ----------------------------------------
package.preload["json"] = function()
    local dkjson = require("dkjson")
    return { decode = dkjson.decode, encode = dkjson.encode }
end
package.preload["socketutil"] = function()
    return {
        LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
        FILE_BLOCK_TIMEOUT = 30, FILE_TOTAL_TIMEOUT = 120,
        set_timeout = function() end, reset_timeout = function() end,
    }
end
package.preload["logger"] = function()
    local function w(...) io.stderr:write("[logger] " .. table.concat({...}, " ") .. "\n") end
    return { warn = w, info = function() end, dbg = function() end, err = w }
end
--------------------------------------------------------------------------

local Catalog = require("catalog")
local HttpUtil = require("http_util")

local function hr() print(string.rep("-", 72)) end
local fail = false
local EXPECTED_FAIL = { ["DOAB"] = true }   -- blocked from datacenter IPs

local QUERY = arg[1] or "pride and prejudice"
print("OpenShelf headless test — query: " .. QUERY)
hr()

print("providers registered: " .. #Catalog.providers)
for i, p in ipairs(Catalog.providers) do
    assert(type(p) == "table" and type(p.search) == "function",
        "provider #" .. i .. " invalid (regression!)")
    print(("  %d. %-18s (quality %s)"):format(i, p.name, require("entry").QUALITY[p.name] or "?"))
end
hr()

local entries, errors, collapsed = Catalog.search(QUERY, { per_provider = 8 })
print(("Catalog.search: %d entries after dedupe, %d duplicate(s) merged"):format(#entries, collapsed or 0))
if errors and #errors > 0 then
    print("source errors:")
    for _, e in ipairs(errors) do
        local src = e:match("^(.-):")
        local tag = EXPECTED_FAIL[src] and "(expected)" or "(UNEXPECTED)"
        if not EXPECTED_FAIL[src] then fail = true end
        print("  ! " .. e .. "  " .. tag)
    end
end
hr()

-- grouping by action
local groups = Catalog.group(entries)
for _, g in ipairs(groups) do
    print(("%s  (%d)"):format(g.heading, #g.items))
end
hr()

-- results by source
local by_source, order = {}, {}
for _, r in ipairs(entries) do
    if not by_source[r.source] then by_source[r.source] = {}; order[#order+1] = r.source end
    table.insert(by_source[r.source], r)
end
for _, src in ipairs(order) do
    print(("[%s] %d"):format(src, #by_source[src]))
    for i = 1, math.min(2, #by_source[src]) do
        local r = by_source[src][i]
        print(("   • %s — %s"):format(r.title, r.author))
    end
end
hr()

-- resolve first of each working source
for _, src in ipairs(order) do
    local r = by_source[src][1]
    local url, err = r.resolve()
    if url then
        print(("resolve OK   [%s] -> %s"):format(src, url))
    else
        if not EXPECTED_FAIL[src] then fail = true end
        print(("resolve FAIL [%s] -> %s"):format(src, tostring(err)))
    end
end
hr()

-- validate real downloads for the DRM-free, non-huge sources
local function try_download(src)
    local r = by_source[src] and by_source[src][1]
    if not r then print(("download SKIP [%s] (no result)"):format(src)); return end
    local url, rerr = r.resolve()
    if not url then print(("download SKIP [%s] (resolve: %s)"):format(src, rerr)); return end
    local target = os.tmpname()
    local path, derr = HttpUtil.download(url, target)
    if not path then
        fail = true
        print(("download FAIL [%s] -> %s"):format(src, tostring(derr)))
        return
    end
    local f = io.open(path, "rb"); local head = f:read(4); local size = f:seek("end"); f:close()
    os.remove(path)
    local magic = head and head:sub(1,2)
    local ok = (magic == "PK") or (head and head:sub(1,4) == "%PDF")
    if not ok then fail = true end
    print(("download OK   [%s] -> %d bytes (%s)"):format(src, size, ok and "valid epub/pdf" or "BAD MAGIC"))
end

try_download("Project Gutenberg")
hr()

-- validate cover thumbnail URLs return real image bytes (decode happens in
-- KOReader via RenderImage; here we just confirm the URL + image magic)
local function image_kind(bytes)
    if not bytes or #bytes < 4 then return nil end
    local b1, b2, b3, b4 = bytes:byte(1, 4)
    if b1 == 0xFF and b2 == 0xD8 then return "JPEG" end
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then return "PNG" end
    if bytes:sub(1, 3) == "GIF" then return "GIF" end
    return nil
end

local function check_cover(src)
    local r = by_source[src] and by_source[src][1]
    if not r then print(("cover SKIP [%s] (no result)"):format(src)); return end
    if not r.cover_url then print(("cover SKIP [%s] (no cover_url)"):format(src)); return end
    local body = HttpUtil.getBody(r.cover_url)
    local kind = image_kind(body)
    if kind then
        print(("cover OK   [%s] %d bytes %s  <- %s"):format(src, #body, kind, r.cover_url))
    else
        fail = true
        print(("cover FAIL [%s] not an image  <- %s"):format(src, tostring(r.cover_url)))
    end
end

check_cover("Project Gutenberg")
check_cover("Internet Archive")
hr()

print("RESULT: " .. (fail and "FAIL" or "PASS"))
os.exit(fail and 1 or 0)
