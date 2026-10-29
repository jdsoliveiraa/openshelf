--[[
Provider check (PROVIDERS.md §10): validate one provider file against the
api 1 contract without KOReader.

    eval "$(luarocks --lua-version=5.1 path)"
    luajit tools/provider_check.lua <provider.lua> ["query"] [flags]

Flags:
    --set key=value   fill ctx.settings (repeatable); declared defaults apply
    --limit N         page size handed to search (default 10)
    --download        also download the resolved file and check EPUB/PDF magic
    --offline         skip the tool's own network checks (HEAD, cover, download);
                      the provider's own calls still go through ctx.http

Steps: load + Catalog.validate → required settings → check(ctx) → search →
plain-data walk + JSON round trip of every row → usable locators →
browse every shelf (page 2 too when page 1 says has_more) → resolve the first non-buy row (from its round-tripped
locator, as a fresh process would) → HEAD with the resolved headers → cover
reachable without headers → optional download. Exit status 1 on any failure.

Also a module: test/unit.lua drives Check.run offline with provider tables,
and test/headless_providers.lua runs it live over the built-ins.
Needs LuaSocket, LuaSec and dkjson built for LuaJIT (see CLAUDE.md) for the
network steps; KOReader-only modules are shimmed below.
--]]
local HERE = (debug.getinfo(1, "S").source:match("^@(.*/)") or "./")
local PLUGIN = HERE .. "../openshelf.koplugin"
package.path = PLUGIN .. "/?.lua;" .. package.path

-- Shims for KOReader-only modules; a caller's own stubs (test/unit.lua) win.
local function shim(name, loader)
    if not package.preload[name] and not package.loaded[name] then package.preload[name] = loader end
end
shim("json", function()
    local dkjson = require("dkjson")
    return { decode = dkjson.decode, encode = dkjson.encode }
end)
shim("socketutil", function()
    -- The API http_util relies on; the timeout-aware sinks fall back to
    -- plain ltn12 ones and LuaSocket's own per-operation timeout.
    local ltn12 = require("ltn12")
    local http, https = require("socket.http"), require("ssl.https")
    local S = {
        LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
        FILE_BLOCK_TIMEOUT = 30, FILE_TOTAL_TIMEOUT = 120,
        total_timeout = -1,
    }
    function S:set_timeout(block, total)
        http.TIMEOUT, https.TIMEOUT = block, block
        return block, total
    end
    function S:reset_timeout() http.TIMEOUT, https.TIMEOUT = 60, 60 end
    function S.table_sink(t) return ltn12.sink.table(t) end
    function S.file_sink(handle) return ltn12.sink.file(handle) end
    function S.describe_error() return nil end
    return S
end)
shim("logger", function()
    local function w(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        io.stderr:write("[logger] " .. table.concat(parts, " ") .. "\n")
    end
    return { warn = w, err = w, info = function() end, dbg = function() end }
end)

local Catalog = require("catalog")
local Entry = require("entry")
local Fields = require("openshelf_fields")

local Check = {}

Check.DEFAULT_QUERY = "pride and prejudice"
Check.DEFAULT_LIMIT = 10
Check.SHELF_LIMIT = 12   -- browse.lua's SHELF_SIZE

Check.USAGE = [==[usage: luajit tools/provider_check.lua <provider.lua> ["query"] [--set key=value]... [--limit N] [--download] [--offline]==]

--- argv (list of strings) → opts for Check.run, or nil + message.
function Check.parseArgs(argv)
    local opts = { settings = {}, query = Check.DEFAULT_QUERY, limit = Check.DEFAULT_LIMIT,
                   download = false, offline = false }
    local positional = {}
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--set" then
            local key, value = tostring(argv[i + 1] or ""):match("^([^=]+)=(.*)$")
            if not key then return nil, "--set needs key=value" end
            opts.settings[key] = value
            i = i + 2
        elseif a == "--limit" then
            local n = tonumber(argv[i + 1])
            if not n or n < 1 then return nil, "--limit needs a positive number" end
            opts.limit = math.floor(n)
            i = i + 2
        elseif a == "--download" then
            opts.download = true; i = i + 1
        elseif a == "--offline" then
            opts.offline = true; i = i + 1
        elseif a:sub(1, 2) == "--" then
            return nil, "unknown flag " .. a
        else
            positional[#positional + 1] = a; i = i + 1
        end
    end
    if not positional[1] then return nil, "missing provider file" end
    if #positional > 2 then return nil, "too many arguments (quote the query)" end
    opts.file = positional[1]
    opts.query = positional[2] or opts.query
    return opts
end

-- First thing in `v` that cannot cross the job pipe as JSON, or nil.
local function impurity(v, path, seen)
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return nil end
    if t ~= "table" then return path .. " is a " .. t end
    if seen[v] then return path .. " is a cycle" end
    seen[v] = true
    for k, x in pairs(v) do
        if type(k) ~= "string" and type(k) ~= "number" then return path .. " has a " .. type(k) .. " key" end
        local bad = impurity(x, path .. "." .. tostring(k), seen)
        if bad then return bad end
    end
    seen[v] = nil
    return nil
end

local function locator_problem(loc)
    if type(loc) ~= "table" then return "no locator table" end
    for k, v in pairs(loc) do
        if type(v) ~= "string" and type(v) ~= "number" then
            return "locator." .. tostring(k) .. " is a " .. type(v) .. " (strings and numbers only)"
        end
    end
    if Entry.locatorKey(loc) == "" then return "locator has no usable field" end
    return nil
end

local VALID_ACTION = {}
for __, a in pairs(Entry.ACTION) do VALID_ACTION[a] = true end

local function image_kind(bytes)
    if type(bytes) ~= "string" or #bytes < 4 then return nil end
    local b1, b2, b3, b4 = bytes:byte(1, 4)
    if b1 == 0xFF and b2 == 0xD8 then return "JPEG" end
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then return "PNG" end
    if bytes:sub(1, 3) == "GIF" then return "GIF" end
    return nil
end

--- Run the check. opts: file | provider, query, limit, settings, download,
-- offline, json (defaults to require("json")), http (defaults to http_util),
-- out (line printer, default print). Returns ok, { failure messages }.
function Check.run(opts)
    local out = opts.out or print
    local failures = {}
    local function pass(step, msg) out(("ok    %-9s %s"):format(step, msg or "")) end
    local function fail(step, msg)
        failures[#failures + 1] = step .. ": " .. tostring(msg)
        out(("FAIL  %-9s %s"):format(step, tostring(msg)))
    end
    local function done()
        out("RESULT: " .. (#failures == 0 and "PASS" or "FAIL"))
        return #failures == 0, failures
    end
    local limit = opts.limit or Check.DEFAULT_LIMIT
    local query = opts.query or Check.DEFAULT_QUERY

    -- 1. load + validate
    local p = opts.provider
    if opts.file then
        local ok, loaded = pcall(dofile, opts.file)
        if not ok then fail("load", loaded); return done() end
        p = loaded
    end
    local valid, reason = Catalog.validate(p)
    if not valid then fail("validate", reason); return done() end
    pass("validate", ("%s (%s) api %d, quality %s"):format(p.id, p.name, p.api, tostring(p.quality or 0)))

    -- 2. settings: --set values read like the stored provider_settings[id],
    -- through the host's own rules (declared keys only, defaults applied,
    -- empty text nil; PROVIDERS.md §3, §7). Toggles take true/false.
    local ctx = Catalog.ctxFor(p)
    local stored, declared = {}, {}
    for __, field in ipairs(p.settings or {}) do declared[field.key] = field end
    for k, v in pairs(opts.settings or {}) do
        local field = declared[k]
        if not field then
            out("warn  settings  --set " .. k .. " is not a declared field (ignored)")
        elseif field.type == "toggle" and type(v) == "string" then
            stored[k] = (v == "true" or v == "1" or v == "yes")
        else
            stored[k] = v
        end
    end
    ctx.settings = Fields.values(p.settings, stored)
    local missing = {}
    for __, field in ipairs(p.settings or {}) do
        if field.required and ctx.settings[field.key] == nil then missing[#missing + 1] = field.key end
    end
    if #missing > 0 then
        fail("settings", "needs setup: " .. table.concat(missing, ", ") .. " (pass --set key=value)")
        return done()
    end
    for k, v in pairs(stored) do
        if ctx.settings[k] ~= v then
            out(("warn  settings  --set %s=%s rejected by the field type; using %s"):format(k, tostring(v), tostring(ctx.settings[k])))
        end
    end

    -- 3. check(ctx)
    if p.check then
        local ok, good, msg = pcall(p.check, ctx)
        if not ok then fail("check", good)
        elseif not good then fail("check", msg or "check returned false")
        else pass("check", msg) end
    end

    local JSON = opts.json or require("json")
    -- A row must be plain data and keep its identity through JSON (the job
    -- pipe and the library). Returns the decoded row, or nil + problem.
    local function roundtrip(row)
        if type(row) ~= "table" then return nil, "is a " .. type(row) .. ", not a table" end
        local bad = impurity(row, "row", {})
        if bad then return nil, bad .. " (rows must be plain data)" end
        local lp = locator_problem(row.locator)
        if lp then return nil, lp end
        if row.action ~= nil and not VALID_ACTION[row.action] then
            return nil, "unknown action " .. tostring(row.action)
        end
        local ok, encoded = pcall(JSON.encode, row)
        if not ok then return nil, "JSON encode failed: " .. tostring(encoded) end
        local ok2, decoded = pcall(JSON.decode, encoded)
        if not ok2 or type(decoded) ~= "table" then return nil, "JSON decode failed" end
        if Entry.locatorKey(decoded.locator) ~= Entry.locatorKey(row.locator) then
            return nil, "locator changed in the JSON round trip"
        end
        return decoded
    end
    local function check_rows(step, rows)
        local decoded, n_bad = {}, 0
        for i, row in ipairs(rows) do
            local d, problem = roundtrip(row)
            if d then
                decoded[#decoded + 1] = d
            else
                n_bad = n_bad + 1
                fail(step, ("row %d %s"):format(i, problem))
            end
        end
        if n_bad == 0 then pass(step, ("%d row(s) plain data, JSON round trip, usable locators"):format(#rows)) end
        return decoded
    end

    -- 4. search
    local ok, rows, has_more = pcall(p.search, query, limit, 1, ctx)
    if not ok then fail("search", "raised: " .. tostring(rows)); return done() end
    if rows == nil then fail("search", has_more or "returned nil"); return done() end
    if type(rows) ~= "table" then fail("search", "returned a " .. type(rows) .. ", want a list"); return done() end
    if type(has_more) ~= "boolean" then
        fail("search", "has_more must be a boolean (got " .. type(has_more) .. ")")
    end
    if #rows > limit then fail("search", ("%d rows for limit %d"):format(#rows, limit)) end
    if #rows == 0 then fail("search", "no results for " .. ("%q"):format(query) .. " (try a query that hits)"); return done() end
    pass("search", ("%q -> %d row(s), has_more=%s"):format(query, #rows, tostring(has_more)))
    local decoded = check_rows("rows", rows)
    local stamped = Catalog.stamp(p, decoded)
    for i = 1, math.min(3, #stamped) do
        local r = stamped[i]
        out(("      %d. [%s] %s — %s (%s)"):format(i, r.action, r.title, r.author, r.format))
    end

    -- 5. shelves: page 1, and page 2 when page 1 says has_more (PROVIDERS.md §5.3)
    local function browse_page(shelf, page)
        local step = "shelf " .. shelf.key .. (page > 1 and (" p" .. page) or "")
        local okb, srows, more = pcall(p.browse, shelf.key, Check.SHELF_LIMIT, ctx, page)
        if not okb then fail(step, "raised: " .. tostring(srows)); return nil end
        if type(srows) ~= "table" then fail(step, more or "browse returned nothing"); return nil end
        if #srows == 0 then fail(step, "empty shelf"); return nil end
        if #srows > Check.SHELF_LIMIT then
            fail(step, ("%d rows for limit %d"):format(#srows, Check.SHELF_LIMIT)); return nil
        end
        -- absent = a single-page shelf (pre-#12 providers); anything else must be a boolean
        if more ~= nil and type(more) ~= "boolean" then
            fail(step, "has_more must be a boolean or absent (got " .. type(more) .. ")"); return nil
        end
        out(("      page %d: %d row(s), has_more=%s"):format(page, #srows, tostring(more == true)))
        check_rows(step, srows)
        return srows, more == true
    end
    for __, shelf in ipairs(p.shelves or {}) do
        local page1, more = browse_page(shelf, 1)
        if page1 and more then
            local page2 = browse_page(shelf, 2)
            if page2 then
                local shown, repeats = {}, 0
                for ___, r in ipairs(page1) do shown[Entry.locatorKey(r.locator)] = true end
                for ___, r in ipairs(page2) do
                    if shown[Entry.locatorKey(r.locator)] then repeats = repeats + 1 end
                end
                if repeats > 0 then
                    fail("shelf " .. shelf.key .. " p2", ("repeats %d row(s) of page 1 (is `page` ignored?)"):format(repeats))
                else
                    pass("shelf " .. shelf.key .. " p2", "no row repeated from page 1")
                end
            end
        end
    end

    -- 6. resolve the first row that is not a buy link, from its decoded locator
    local first
    for __, r in ipairs(stamped) do
        if r.action ~= Entry.ACTION.BUY then first = r; break end
    end
    if not first then
        pass("resolve", "only buy rows; nothing to resolve")
        return done()
    end
    local okr, value, rerr = pcall(p.resolve, first.locator, ctx)
    local resolved, nerr
    if okr then resolved, nerr = Catalog.normalizeResolve(value, rerr) else nerr = "raised: " .. tostring(value) end
    if not resolved then fail("resolve", nerr); return done() end
    local names = {}
    for k in pairs(resolved.headers or {}) do names[#names + 1] = k end
    table.sort(names)
    pass("resolve", resolved.url .. (#names > 0 and ("  headers: " .. table.concat(names, ", ")) or ""))

    if opts.offline then return done() end
    local HttpUtil = opts.http or require("http_util")

    -- 7. HEAD with the resolved headers
    local head, herr = HttpUtil.head(resolved.url, { headers = resolved.headers })
    if head then
        pass("head", ("content-type=%s content-length=%s"):format(
            tostring(head["content-type"]), tostring(head["content-length"])))
    else
        fail("head", herr)
    end

    -- 8. cover: unauthenticated JPEG/PNG (§4.1, §9)
    if type(first.cover_url) == "string" then
        local body, cerr = HttpUtil.getBody(first.cover_url)
        local kind = image_kind(body)
        if kind then pass("cover", ("%s %d bytes"):format(kind, #body))
        else fail("cover", "not an image (" .. tostring(cerr or "bad magic") .. ") <- " .. first.cover_url) end
    else
        out("skip  cover     first row has no cover")
    end

    -- 9. opt-in download: EPUB (zip) or PDF magic
    if opts.download then
        local target = os.tmpname()
        local path, derr = HttpUtil.download(resolved.url, target, { headers = resolved.headers })
        if not path then
            fail("download", derr)
        else
            local f = io.open(path, "rb")
            local magic = f:read(4) or ""
            local size = f:seek("end")
            f:close()
            if magic:sub(1, 2) == "PK" or magic == "%PDF" then
                pass("download", ("%d bytes, valid %s"):format(size, magic == "%PDF" and "PDF" or "EPUB/zip"))
            else
                fail("download", ("%d bytes, bad magic %q (want EPUB or PDF)"):format(size, magic))
            end
        end
        os.remove(target)
    end
    return done()
end

-- CLI entry point (skipped when dofile'd by the tests).
if arg and type(arg[0]) == "string" and arg[0]:match("provider_check%.lua$") then
    local opts, err = Check.parseArgs(arg)
    if not opts then
        io.stderr:write(err .. "\n" .. Check.USAGE .. "\n")
        os.exit(2)
    end
    print(("provider_check — %s, query %q"):format(opts.file, opts.query))
    local ok = Check.run(opts)
    os.exit(ok and 0 or 1)
end

return Check
