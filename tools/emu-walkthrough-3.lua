-- Walkthrough 3 for the KOReader emulator: home mode (DESIGN.md §8).
-- home → settings (new toggle) → open a book → close it the way KOReader's "Home"
-- does → OpenShelf must be back on top → X → the file manager underneath.
-- Run via scripts/emu.sh [--no-autoopen] --walk tools/emu-walkthrough-3.lua --shots DIR
-- with OPENSHELF_TEST_EPUB=/path/to/some.epub. Dev only.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local Settings = require("settings")
local OUT = os.getenv("OPENSHELF_SHOT_DIR")
local EPUB = os.getenv("OPENSHELF_TEST_EPUB")
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
local function home() return App.homeView() end
local function top_name()
    local w = UIManager:getTopmostVisibleWidget()
    return w and (w.name or w.title or tostring(w)) or "nil"
end

at(1,  function() log("setting home_mode =", Settings.homeMode(), "autoopen env =", os.getenv("OPENSHELF_AUTOOPEN"), "home open =", home() ~= nil, "top =", top_name()); shot("start") end, "start")
at(2,  function() home():openSettings() end, "settings")
at(4,  function() shot("settings") end)
at(5,  function() UIManager:close(UIManager:getTopmostVisibleWidget()) end, "close settings")
at(6,  function() assert(EPUB, "OPENSHELF_TEST_EPUB not set"); App.openBook(EPUB) end, "open book")
at(10, function() log("in reader, home open =", home() ~= nil, "top =", top_name()); shot("reader") end)
at(11, function() local ReaderUI = require("apps/reader/readerui"); ReaderUI.instance:onHome() end, "close book (Home)")
at(14, function() log("after close, home open =", home() ~= nil, "top =", top_name()); shot("after-book") end)
at(15, function() home():onExit() end, "X on home")
at(17, function() log("after X, home open =", home() ~= nil, "top =", top_name()); shot("filemanager") end)
at(18, function() log("done"); os.exit(0) end, "exit")
