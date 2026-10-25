--[[
Headless test for OpenShelf: runs the REAL plugin code (catalog, dedupe, opds,
providers, http_util) against the live APIs, stubbing only the KOReader-specific
modules (json, socketutil, logger).

Requirements (once) — rocks built for LuaJIT, i.e. the device's Lua 5.1 ABI:
    brew install luajit luarocks luacheck
    LJ="$(brew --prefix luajit)"
    luarocks --lua-version=5.1 --lua-dir="$LJ" install luasocket
    luarocks --lua-version=5.1 --lua-dir="$LJ" install dkjson
    luarocks --lua-version=5.1 --lua-dir="$LJ" install luasec OPENSSL_DIR="$(brew --prefix openssl@3)"

Run:
    eval "$(luarocks --lua-version=5.1 path)"
    luajit test/headless_providers.lua "pride and prejudice"

Notes:
 - DOAB blocks datacenter IPs (403); its failure here is EXPECTED and ignored.
 - Internet Archive EPUBs can be large, so we validate a real download only
   for Project Gutenberg.
 - Offline checks (dedup key, query sanitizer, OPDS parser) live in unit.lua.
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
    -- Mirrors the KOReader API http_util relies on; the timeout-aware sinks
    -- fall back to plain ltn12 ones here.
    local ltn12 = require("ltn12")
    local http, https = require("socket.http"), require("ssl.https")
    local S = {
        LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
        FILE_BLOCK_TIMEOUT = 30, FILE_TOTAL_TIMEOUT = 120,
        total_timeout = -1,
    }
    -- LuaSocket's own per-operation timeout is enough to make the
    -- connection-failure check below meaningful.
    function S:set_timeout(block, total)
        http.TIMEOUT, https.TIMEOUT = block, block
        return block, total
    end
    function S:reset_timeout() http.TIMEOUT, https.TIMEOUT = 60, 60 end
    function S.table_sink(t) return ltn12.sink.table(t) end
    function S.file_sink(handle) return ltn12.sink.file(handle) end
    function S.describe_error() return nil end
    return S
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

-- Internet Archive: punctuation in the query must not break the Lucene syntax
-- (before v0.4 a stray ":" or "(" silently produced zero results).
local IA = require("providers_internetarchive")
local tricky = "dr. jekyll (and) mr: hyde"
print(("IA sanitizeQuery: %q -> %q"):format(tricky, tostring(IA.sanitizeQuery(tricky))))
local ia_res, ia_err = IA.search(tricky, 5)
if ia_res and #ia_res > 0 then
    print(("IA punctuation query OK   -> %d result(s), first: %s"):format(#ia_res, ia_res[1].title))
else
    fail = true
    print("IA punctuation query FAIL -> " .. tostring(ia_err or "0 results"))
end
hr()

-- A dead host must come back as (nil, message) within the block timeout —
-- exercises the failure path of http_util (no status line, no headers).
do
    local t0 = os.time()
    local body, err = HttpUtil.getBody("http://10.255.255.1:9/", { block_timeout = 3 })
    local took = os.time() - t0
    if body == nil and type(err) == "string" and took <= 10 then
        print(("connection failure OK   -> %q in %ds"):format(err, took))
    else
        fail = true
        print(("connection failure FAIL -> body=%s err=%s took=%ds"):format(
            tostring(body), tostring(err), took))
    end
end
hr()

print("RESULT: " .. (fail and "FAIL" or "PASS"))
os.exit(fail and 1 or 0)
