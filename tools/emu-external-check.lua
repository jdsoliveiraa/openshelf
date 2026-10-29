-- External providers check (#8) for the KOReader emulator. Expects, in KO_HOME:
--   plugins/provider-openshelf-devplug.koplugin   (registers "devplug" via the core registry)
--   settings/openshelf/providers/*.lua            (a valid "devdrop" + broken variants)
-- Logs ids/invalid after the first open, drops a new file, reopens OpenShelf
-- (it must appear), searches with built-ins disabled, shows Sources.
-- Run via scripts/emu.sh --walk tools/emu-external-check.lua --shots <dir>. Dev only.
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local DataStorage = require("datastorage")
local App = require("app")
local Catalog = require("catalog")
local Settings = require("settings")
local OUT = os.getenv("OPENSHELF_SHOT_DIR")
local DIR = DataStorage:getSettingsDir() .. "/openshelf/providers"
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
local BUILTINS = { "gutendex", "internetarchive", "doab" }

at(1, function()
    state("first-open")
    local f = io.open(DIR .. "/README.txt")
    log("README present", f ~= nil)
    if f then f:close() end
    shot("home")
end, "first open")
at(1, function()
    local f = assert(io.open(DIR .. "/devlate.lua", "w"))
    f:write([[return { api = 1, id = "devlate", name = "Dev Late Drop-in",
        search = function(q, l, p, ctx) return { ctx.Entry.new{ title = "Late book for " .. q,
            author = "L. Ate", format = "epub", locator = { url = "http://example.invalid/late" } } }, false end,
        resolve = function(loc) return loc.url end }]])
    f:close()
    App.exitAll()
end, "drop a new file, close OpenShelf")
at(2, function() UIManager:broadcastEvent(Event:new("OpenShelfOpen")) end, "reopen")
at(3, function()
    state("reopen")
    for __, id in ipairs(BUILTINS) do Settings.setEnabled(Catalog.byId(id), false) end
    App.homeView():startSearch("test")
end, "search externals only")
at(4, function()
    local h = App.homeView()
    for i, e in ipairs(h.entries or {}) do log(("ROW %02d | %s | %s | %s"):format(i, e.title, e.source, tostring(e.provider))) end
    shot("results")
    h:goHome()
end, "results")
at(2, function() App.homeView():openSettings() end, "settings")
at(2, function() shot("sources") end, "sources")
at(1, function()
    for __, id in ipairs(BUILTINS) do Settings.setEnabled(Catalog.byId(id), true) end
    os.remove(DIR .. "/devlate.lua")
    log("done"); os.exit(0)
end, "exit")
run(1)
