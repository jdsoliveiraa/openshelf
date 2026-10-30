-- External providers check (#8, #9) for the KOReader emulator, using the
-- committed dev kit instead of local fixtures:
--   provider-openshelf-template.koplugin  linked by `scripts/emu.sh --template`
--   examples/gutenberg_pt.lua             copied into the drop-in folder below
-- Logs ids/invalid after the first open (the template plugin must be there),
-- drops the example plus a broken file, reopens OpenShelf (both must appear,
-- the broken one dimmed with its reason), searches with the built-ins
-- disabled, shows Sources, then removes the drop-ins and restores settings.
-- Run: scripts/emu.sh --template --walk tools/emu-external-check.lua --shots <dir>. Dev only.
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local DataStorage = require("datastorage")
local App = require("app")
local Catalog = require("catalog")
local Settings = require("settings")
local OUT = os.getenv("OPENSHELF_SHOT_DIR")
local DIR = DataStorage:getSettingsDir() .. "/openshelf/providers"
local REPO = (debug.getinfo(1, "S").source:match("^@(.*/)tools/") or "./")
local EXAMPLE = REPO .. "examples/gutenberg_pt.lua"
local step = 0
local function log(...) print("DEVSCRIPT", os.date("%H:%M:%S"), ...) end
local function shot(name)
    step = step + 1
    local path = string.format("%s/%02d-%s.png", OUT, step, name)
    local ok, err = pcall(function() return Screen:shot(path) end)
    log("shot", path, ok, err)
end
-- Steps run in sequence, each `delay` seconds after the previous one ran
-- (inline jobs can block the loop; absolute timers would all fire at once).
local steps = {}
local function at(delay, fn, label) steps[#steps + 1] = { delay = delay, fn = fn, label = label } end
local function run(i)
    local st = steps[i]
    if not st then return end
    UIManager:scheduleIn(st.delay, function()
        local ok, err = pcall(st.fn)
        log(st.label or "", ok and "ok" or ("ERR " .. tostring(err)))
        run(i + 1)
    end)
end
local function state(label)
    log(label, "IDS", table.concat(Catalog.ids(), ","))
    for __, inv in ipairs(Catalog.invalid()) do log(label, "INVALID", inv.name, inv.reason) end
end
local function copy(from, to)
    local src = assert(io.open(from, "rb"))
    local body = src:read("*a")
    src:close()
    local dst = assert(io.open(to, "wb"))
    dst:write(body)
    dst:close()
end
local BUILTINS = { "gutendex", "internetarchive", "doab" }

at(1, function()
    state("first-open")
    log("template registered", Catalog.byId("template") ~= nil)
    local f = io.open(DIR .. "/README.txt")
    log("README present", f ~= nil)
    if f then f:close() end
    shot("home")
end, "first open")
at(1, function()
    copy(EXAMPLE, DIR .. "/gutenberg_pt.lua")
    local f = assert(io.open(DIR .. "/broken_api.lua", "w"))
    f:write([[return { api = 3, id = "brokenapi", name = "Broken API",
        search = function() return {}, false end, resolve = function() end }]])
    f:close()
    App.exitAll()
end, "drop the example + a broken file, close OpenShelf")
at(2, function() UIManager:broadcastEvent(Event:new("OpenShelfOpen")) end, "reopen")
at(3, function()
    state("reopen")
    log("example registered", Catalog.byId("gutenberg_pt") ~= nil)
    for __, id in ipairs(BUILTINS) do Settings.setEnabled(Catalog.byId(id), false) end
    Settings.setEnabled(Catalog.byId("gutenberg_pt"), true)   -- enabled_by_default = false
    App.homeView():startSearch("machado")
end, "search externals only")
at(8, function()
    local h = App.homeView()
    for i, e in ipairs(h.entries or {}) do log(("ROW %02d | %s | %s | %s"):format(i, e.title, e.source, tostring(e.provider))) end
    shot("results")
    h:goHome()
end, "results")
at(2, function() App.homeView():openSettings() end, "settings")
at(2, function() shot("sources") end, "sources")
at(1, function()
    for __, id in ipairs(BUILTINS) do Settings.setEnabled(Catalog.byId(id), true) end
    Settings.setEnabled(Catalog.byId("gutenberg_pt"), false)
    os.remove(DIR .. "/gutenberg_pt.lua")
    os.remove(DIR .. "/broken_api.lua")
    log("done"); os.exit(0)
end, "exit")
run(1)
