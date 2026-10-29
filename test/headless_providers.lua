--[[
Headless live test for OpenShelf: a thin wrapper over tools/provider_check.lua
(PROVIDERS.md §10) that runs the check on every built-in provider with the
expectations below, plus the host-side HTTP checks that are not about any one
provider (cross-source dedupe, request headers, dead host).

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
 - Internet Archive EPUBs can be large, so only Project Gutenberg downloads
   a real file (--download).
 - Offline checks (dedup key, query sanitizer, OPDS parser, the check tool's
   contract asserts) live in unit.lua.
--]]
local this = arg[0]:gsub("[^/]*$", "")
if this == "" then this = "./" end
local PLUGIN = this .. "../openshelf.koplugin"
local Check = dofile(this .. "../tools/provider_check.lua")   -- installs the KOReader shims

local Catalog = require("catalog")
local HttpUtil = require("http_util")

local function hr() print(string.rep("-", 72)) end
local fail = false

-- Per built-in: extra Check.run options and whether a failure is expected.
local BUILTINS = {
    { id = "gutendex",        opts = { download = true } },
    { id = "internetarchive", opts = {} },
    { id = "doab",            opts = {}, expected_fail = "blocked from datacenter IPs" },
}

local QUERY = arg[1] or "pride and prejudice"
print("OpenShelf headless test — query: " .. QUERY)
hr()

print("providers registered: " .. #Catalog.providers)
for i, p in ipairs(Catalog.providers) do
    print(("  %d. %-18s id=%-16s quality %s"):format(i, p.name, p.id, tostring(p.quality)))
end
if #Catalog.providers ~= #BUILTINS then
    fail = true
    print("  ! expected " .. #BUILTINS .. " built-ins (regression!)")
end
if #Catalog.invalid() > 0 then
    fail = true
    for __, inv in ipairs(Catalog.invalid()) do print("  ! REJECTED " .. tostring(inv.name) .. ": " .. inv.reason) end
end
hr()

-- provider_check over each built-in file
for __, b in ipairs(BUILTINS) do
    local opts = { file = PLUGIN .. "/providers/" .. b.id .. ".lua", query = QUERY }
    for k, v in pairs(b.opts) do opts[k] = v end
    print(("provider_check %s"):format(b.id))
    local ok = Check.run(opts)
    if not ok then
        if b.expected_fail then
            print(("  (expected: %s)"):format(b.expected_fail))
        else
            fail = true
        end
    end
    hr()
end

-- Internet Archive: punctuation in the query must not break the Lucene syntax
-- (before v0.4 a stray ":" or "(" silently produced zero results).
local tricky = "dr. jekyll (and) mr: hyde"
print(("provider_check internetarchive, punctuation query %q"):format(tricky))
if not Check.run{ file = PLUGIN .. "/providers/internetarchive.lua", query = tricky, limit = 5, offline = true } then
    fail = true
end
hr()

-- Cross-source dedupe over the registered built-ins (sequential searchAll).
local entries, errors, collapsed = Catalog.searchAll(QUERY, { per_provider = 8 })
print(("Catalog.searchAll: %d entries after dedupe, %d duplicate(s) merged"):format(#entries, collapsed or 0))
local expected_name = {}
for __, b in ipairs(BUILTINS) do
    if b.expected_fail then expected_name[Catalog.nameOf(b.id)] = true end
end
for __, e in ipairs(errors or {}) do
    local src = e:match("^(.-):")
    if not expected_name[src] then fail = true end
    print("  ! " .. e .. "  " .. (expected_name[src] and "(expected)" or "(UNEXPECTED)"))
end
for __, g in ipairs(Catalog.group(entries)) do print(("  %s  (%d)"):format(g.heading, #g.items)) end
if #entries == 0 then fail = true; print("  ! no entries (UNEXPECTED)") end
hr()

-- opts.headers (PROVIDERS.md §3): merged over the User-Agent on GET, HEAD and
-- download, which is how a provider's resolve() can hand the host an
-- Authorization header (§5.2). httpbin echoes request headers and has a
-- bearer endpoint that answers 401 unless the token is sent.
do
    local HB = "https://httpbin.org"
    local echo, eerr = HttpUtil.getJSON(HB .. "/headers", { headers = { ["X-OpenShelf-Test"] = "yes" } })
    local got = echo and echo.headers or {}
    if got["X-Openshelf-Test"] == "yes" and tostring(got["User-Agent"]):match("^OpenShelf/") then
        print(("headers OK   -> custom header echoed, UA still %s"):format(got["User-Agent"]))
    else
        fail = true
        print(("headers FAIL -> err=%s custom=%s ua=%s"):format(tostring(eerr),
            tostring(got["X-Openshelf-Test"]), tostring(got["User-Agent"])))
    end
    local auth = { headers = { Authorization = "Bearer openshelf-test" } }
    local anon, aerr = HttpUtil.getJSON(HB .. "/bearer")
    local bearer, berr = HttpUtil.getJSON(HB .. "/bearer", auth)
    if anon == nil and bearer and bearer.authenticated == true and bearer.token == "openshelf-test" then
        print(("bearer OK    -> 401 without the header (%s), authenticated with it"):format(tostring(aerr)))
    else
        fail = true
        print(("bearer FAIL  -> anon=%s/%s auth=%s/%s"):format(tostring(anon), tostring(aerr),
            tostring(bearer), tostring(berr)))
    end
    local hh, hherr = HttpUtil.head(HB .. "/bearer", auth)
    local len = HttpUtil.contentLength(HB .. "/bearer", auth)
    if hh and HttpUtil.head(HB .. "/bearer") == nil and type(len) == "number" then
        print(("HEAD auth OK -> content-length=%d with the header, refused without"):format(len))
    else
        fail = true
        print(("HEAD auth FAIL -> %s / %s len=%s"):format(tostring(hh), tostring(hherr), tostring(len)))
    end
    local target = os.tmpname()
    local path, derr = HttpUtil.download(HB .. "/bearer", target, auth)
    local body = ""
    if path then local f = io.open(path, "rb"); body = f:read("*a"); f:close() end
    os.remove(target)
    local anon_path = HttpUtil.download(HB .. "/bearer", target)
    os.remove(target)
    if path and body:find('"authenticated": true', 1, true) and anon_path == nil then
        print(("download auth OK -> %d bytes with the header, refused without"):format(#body))
    else
        fail = true
        print(("download auth FAIL -> path=%s err=%s anon=%s body=%s"):format(tostring(path),
            tostring(derr), tostring(anon_path), body:sub(1, 80)))
    end
    -- Redirects: provider headers survive a same-host hop but never follow a
    -- redirect to another host. httpbin refuses off-site redirect-to, so the
    -- cross-host hop is postman-echo -> httpbin (which echoes what it got).
    local esc = function(s) return (s:gsub("[^%w]", function(c) return ("%%%02X"):format(c:byte()) end)) end
    local same = HttpUtil.getJSON(HB .. "/redirect-to?url=" .. esc("/headers"), auth)
    local same_auth = same and same.headers and same.headers.Authorization
    local OFFSITE = "https://postman-echo.com/redirect-to?url=" .. esc(HB .. "/headers")
    local cross = HttpUtil.getJSON(OFFSITE, auth)
    local cross_h = cross and cross.headers or {}
    local dl = os.tmpname()
    local dl_path = HttpUtil.download(OFFSITE, dl, auth)
    local dl_body = ""
    if dl_path then local f = io.open(dl_path, "rb"); dl_body = f:read("*a"); f:close() end
    os.remove(dl)
    if same_auth == "Bearer openshelf-test" and cross and cross_h.Authorization == nil
        and tostring(cross_h["User-Agent"]):match("^OpenShelf/")
        and dl_body:find('"User-Agent"', 1, true) and not dl_body:lower():find("authorization", 1, true) then
        print("redirect OK  -> auth kept on same-host hop, dropped on cross-host (GET and download)")
    else
        fail = true
        print(("redirect FAIL -> same=%s cross_auth=%s cross_ua=%s dl=%s"):format(tostring(same_auth),
            tostring(cross_h.Authorization), tostring(cross_h["User-Agent"]), dl_body:sub(1, 120)))
    end
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
