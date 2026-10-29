-- Authenticated download check (issue #3, PROVIDERS.md §5.2): a dev-script
-- provider whose resolve() returns { url, headers } pointing at httpbin's
-- bearer endpoint, which answers 401 unless an Authorization header is sent.
-- The first entry resolves with the header and must download; the second
-- resolves to the bare URL and must fail with 401. Runs in the default
-- (inline) job mode on macOS. Logs every Downloader event; cleans up after.
-- Run via scripts/emu.sh --walk tools/emu-auth-download-check.lua --shots <dir>. Dev only.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local Catalog = require("catalog")
local Downloader = require("downloader")
local Entry = require("entry")
local OUT = os.getenv("OPENSHELF_SHOT_DIR")
local step = 0
local function log(...) print("DEVSCRIPT", os.date("%H:%M:%S"), ...) end
local function shot(name)
    step = step + 1
    local path = string.format("%s/%02d-%s.png", OUT, step, name)
    local ok, err = pcall(function() return Screen:shot(path) end)
    log("shot", path, ok, err)
end
local function at(t, fn, label)
    UIManager:scheduleIn(t, function()
        local ok, err = pcall(fn)
        log(label or "", ok and "ok" or ("ERR " .. tostring(err)))
    end)
end
local function home() return App.homeView() end

local BEARER = "https://httpbin.org/bearer"
local authy = {
    api = 1, id = "authy", name = "Authy Books", quality = 10,
    search = function() return {}, false end,
    resolve = function(loc)
        if loc.auth then
            return { url = loc.url, headers = { Authorization = "Bearer openshelf-emu" } }
        end
        return loc.url   -- bare string: no header, the server answers 401
    end,
}
log("register authy", Catalog.register(authy))
local rows = Catalog.stamp(authy, {
    -- locators keep strings/numbers only (Entry.new), so the flag is a number
    Entry.new{ title = "Bearer OK", author = "Authy", format = "epub", locator = { url = BEARER, auth = 1 } },
    Entry.new{ title = "Bearer Missing", author = "Authy", format = "epub", locator = { url = BEARER } },
})
local with_header, without_header = rows[1], rows[2]
local events = {}
Downloader.subscribe(function(event, entry, state)
    if event == "progress" then return end
    local extra = state and (state.err or state.path) or ""
    events[#events + 1] = entry.title .. " " .. event .. " " .. tostring(extra)
    log("EVENT", entry.title, event, extra)
end)

local function file_report(entry)
    local path = Downloader.exists(entry)
    if not path then log("FILE", entry.title, "absent"); return end
    local f = io.open(path, "rb"); local body = f:read("*a"); f:close()
    log("FILE", entry.title, path, #body, "bytes", body:find('"authenticated": true', 1, true) and "AUTHENTICATED" or "unexpected body")
end

at(1,  function() shot("home") end, "home")
at(2,  function() log("enqueue with header", Downloader.enqueue(with_header)) end, "enqueue auth")
at(10, function() file_report(with_header); shot("after-auth-download") end, "auth result")
at(11, function() log("enqueue without header", Downloader.enqueue(without_header)) end, "enqueue anon")
at(19, function()
    file_report(without_header)
    for __, e in ipairs(events) do log("SUMMARY", e) end
    local rec = App.library():find(with_header)
    log("LIBRARY", rec and rec.path or "no record")
end, "anon result")
at(20, function() home():openMyBooks() end, "my books")
at(22, function() shot("my-books") end)
at(23, function()
    -- clean up: the test file and its library record
    local rec = App.library():find(with_header)
    if rec then App.library():remove(rec.id) end
    local path = Downloader.exists(with_header)
    if path then os.remove(path) end
    log("cleanup", rec and rec.id or "-", path or "-")
end, "cleanup")
at(24, function() log("done"); os.exit(0) end, "exit")
