-- Close-refresh check for the KOReader emulator (#25). No network.
-- Opens detail, a "See all" list and My books, leaves each through its real
-- left-arrow callback (and detail through the Back key path), and logs the
-- full-screen refreshes enqueued with no widget (what ViewBase:onCloseWidget
-- adds): each close must add exactly one "ui", and App.openBook none.
-- The SDL emulator redraws the whole window on any refresh, so this checks
-- the enqueued refresh, not the panel; the panel is checked on the Kobo.
-- Run via scripts/emu.sh --walk tools/emu-close-refresh-check.lua --shots <dir>
-- with OPENSHELF_TEST_EPUB=/path/to/some.epub. Dev only.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local Entry = require("entry")
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
local function top() return App.views[#App.views] end
local function home() return App.homeView() end

-- Count widget-less full-screen "ui" refreshes.
local full_ui = 0
local orig = UIManager.setDirty
UIManager.setDirty = function(self, widget, refreshtype, ...)
    if widget == nil and type(refreshtype) == "function" then
        local mode, region = refreshtype()
        if mode == "ui" and region and region.x == 0 and region.y == 0
                and region.w == Screen:getWidth() and region.h == Screen:getHeight() then
            full_ui = full_ui + 1
        end
    end
    return orig(self, widget, refreshtype, ...)
end

local function closes(label, fn)
    local before, views = full_ui, #App.views
    fn()
    log("CHECK", label, "views", views, "->", #App.views, "full ui refreshes +" .. (full_ui - before),
        (full_ui - before == 1 and #App.views == views - 1) and "PASS" or "FAIL")
end
local function left_arrow() top().title_bar.left_icon_tap_callback() end

local e = Entry.new{ title = "Close Refresh Test", author = "Nobody", language = "en",
    source = "dev", provider_id = "dev", locator = { url = "https://example.invalid/x.epub" } }

at(1, function() shot("home") end)
at(2, function() home():openDetail(e) end, "detail")
at(3, function() shot("detail") end)
at(4, function() closes("detail left arrow", left_arrow) end)
at(5, function() shot("after-detail") end)
at(6, function() home():openDetail(e) end, "detail again")
at(7, function() closes("detail Back key", function() top():onClose() end) end)
at(8, function() home():openList("See all test", { e, e }) end, "list")
at(9, function() shot("list") end)
at(10, function() closes("list left arrow", left_arrow) end)
at(11, function() home():openMyBooks() end, "mybooks")
at(12, function() shot("mybooks") end)
at(13, function() closes("mybooks left arrow", left_arrow) end)
at(14, function() shot("after-mybooks") end)
at(15, function()
    assert(EPUB, "OPENSHELF_TEST_EPUB not set")
    home():openDetail(e)
    local before = full_ui
    App.openBook(EPUB)
    log("CHECK", "openBook", "views", #App.views, "full ui refreshes +" .. (full_ui - before),
        (full_ui == before and #App.views == 0) and "PASS" or "FAIL")
end, "open book")
at(19, function() shot("reader") end)
at(20, function() log("done"); os.exit(0) end, "exit")
