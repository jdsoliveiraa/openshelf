-- Search parity check for the KOReader emulator: home → search → results → home → settings.
-- Logs every result row (title | source | provider | quality) so two runs can be diffed.
-- Run via scripts/emu.sh --walk tools/emu-search-check.lua --shots <dir>. Dev only.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
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
local function dump_results()
    local h = home()
    log("ROWS", #h.entries, "collapsed", h.collapsed)
    for i, e in ipairs(h.entries) do
        log(("ROW %02d | %s | %s | %s | %s | %s"):format(i, e.title, e.source,
            tostring(e.provider), tostring(e.quality), require("entry").id(e)))
    end
    if h.results then
        for __, err in ipairs(h.results:errors()) do log("ERR-STRIP", err) end
    end
end

at(1,  function() shot("home") end, "home")
at(2,  function() home():startSearch("pride and prejudice") end, "search")
at(16, function() shot("results-list"); dump_results() end, "results")
at(17, function() home():goHome() end, "go home")
at(22, function() shot("home-after") end, "home after")
at(23, function() home():openSettings() end, "settings")
at(25, function() shot("settings") end)
at(26, function() UIManager:close(UIManager:getTopmostVisibleWidget()) end, "close settings")
at(27, function() log("done"); os.exit(0) end, "exit")
