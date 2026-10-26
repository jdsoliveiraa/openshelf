-- Walkthrough 1 for the KOReader emulator: home → search → list/grid → filter → detail → download → My books → settings.
-- Run via scripts/emu.sh --walk tools/emu-walkthrough.lua (screenshots land in the --shots dir). Dev only.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local OUT = os.getenv("OPENSHELF_SHOT_DIR")
local step = 0
local function log(...) print("DEVSCRIPT", ...) end
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
local function top() return App.views[#App.views] end
local function home() return App.homeView() end

at(1,  function() shot("home") end, "home")
at(2,  function() home():startSearch("pride and prejudice") end, "search")
at(4,  function() shot("results-searching") end)
at(14, function() shot("results-list") end)
at(15, function() home():toggleView() end, "grid")
at(17, function() shot("results-grid") end)
at(18, function() home():goPage(2) end, "page2")
at(20, function() shot("results-grid-p2") end)
at(21, function() home():openFilter() end, "filter")
at(23, function() shot("filter-dialog") end)
at(24, function() UIManager:close(UIManager:getTopmostVisibleWidget()) end, "close filter")
at(25, function() home():toggleView(); home():goPage(1) end, "list p1")
at(26, function() local e = home().entries[1]; log("detail of", e and e.title, e and e.source); home():openDetail(e) end, "detail")
at(29, function() shot("detail") end)
at(30, function() top():startDownload() end, "download")
at(32, function() shot("detail-downloading") end)
at(45, function() shot("detail-after") end)
at(46, function() UIManager:close(top()) end, "close detail")
at(48, function() shot("results-after-download") end)
at(49, function() home():goHome() end, "home again")
at(52, function() shot("home-with-mybooks") end)
at(53, function() home():openMyBooks() end, "mybooks")
at(56, function() shot("mybooks") end)
at(57, function() UIManager:close(top()); home():openSettings() end, "settings")
at(59, function() shot("settings") end)
at(60, function() UIManager:close(UIManager:getTopmostVisibleWidget()) end, "close settings")
at(61, function() home():openSearchDialog("emma") end, "search dialog")
at(63, function() shot("search-dialog") end)
at(64, function() log("done"); os.exit(0) end, "exit")
