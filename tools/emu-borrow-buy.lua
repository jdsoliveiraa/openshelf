-- Borrow / buy walkthrough for the KOReader emulator (#7, decisions 49-50).
-- Registers a dev provider returning one row per action (plus a buy duplicate
-- of the free title, which dedupe must drop), then: grouped results in list
-- and grid, the buy detail page (URL as text + QR, price in the meta line),
-- the downloader refusing the buy row, hold on the buy row opening detail,
-- and the borrow row downloading and landing in My books.
-- Run via scripts/emu.sh --walk tools/emu-borrow-buy.lua --shots <dir>. Dev only.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local Catalog = require("catalog")
local Downloader = require("downloader")
local Settings = require("settings")
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
local function top() return App.views[#App.views] end
local function home() return App.homeView() end
local function find(action)
    for __, e in ipairs(home().entries) do
        if e.action == action then return e end
    end
end
local function dump_results()
    local h = home()
    log("ROWS", #h.entries, "collapsed", h.collapsed, "groups", #Catalog.group(h.entries))
    for i, e in ipairs(h.entries) do
        log(("ROW %02d | %-8s | %s | %s | q=%s | price=%s"):format(i, e.action, e.title, e.source,
            tostring(e.quality), tostring(e.price)))
    end
end

local BUILTINS = { "gutendex", "internetarchive", "doab" }
local function set_builtins(enabled)
    for __, id in ipairs(BUILTINS) do Settings.setEnabled(Catalog.byId(id), enabled) end
end

-- The dev provider. Borrow resolves to a plain Gutenberg URL (the pipeline is
-- the download pipeline; auth would live in resolve).
Catalog.register{
    api = 1, id = "devstore", name = "Dev Store", quality = 70,
    search = function(_query, _limit, _page, ctx)
        return {
            ctx.Entry.new{ title = "Pride and Prejudice", author = "Jane Austen", language = "en", year = "1813",
                locator = { url = "https://www.gutenberg.org/ebooks/1342.epub.noimages" },
                description = "Free edition from the dev provider." },
            ctx.Entry.new{ action = "borrow", title = "Emma", author = "Jane Austen", language = "en", year = "1815",
                locator = { url = "https://www.gutenberg.org/ebooks/158.epub.noimages" },
                description = "Borrowed through the dev provider: resolve hands back a file URL and the "
                    .. "download pipeline does the rest. Recorded in My books like any download." },
            ctx.Entry.new{ action = "buy", title = "Persuasion", author = "Jane Austen", language = "en",
                year = "1817", price = "€4.99",
                locator = { url = "https://example.com/store/persuasion?ref=openshelf&edition=epub" },
                description = "Store-only edition: the page URL is shown as text and as a QR code to scan "
                    .. "with a phone. Nothing is downloaded on the device." },
            ctx.Entry.new{ action = "buy", title = "Pride and Prejudice", author = "Jane Austen", price = "€3.49",
                locator = { url = "https://example.com/store/pride" } },   -- must lose to the free edition
        }, false
    end,
    resolve = function(loc) return loc.url end,
}
set_builtins(false)

at(1,  function() shot("home") end, "home")
at(2,  function() home():startSearch("jane austen") end, "search")
at(5,  function() shot("results-grouped-list"); dump_results() end, "results list")
at(6,  function() home():toggleView() end, "grid")
at(8,  function() shot("results-grouped-grid") end)
at(9,  function() home():toggleView() end, "list again")
at(10, function() home():openDetail(find("buy")) end, "buy detail")
at(12, function() shot("detail-buy") end)
at(13, function() top():showQR() end, "show QR")
at(15, function() shot("qr-message") end)
at(16, function() UIManager:close(UIManager:getTopmostVisibleWidget()) end, "close QR")
at(17, function() UIManager:close(top()) end, "close buy detail")
at(18, function()
    local buy = find("buy")
    local ok, why = Downloader.enqueue(buy)
    log("ENQUEUE-BUY", tostring(ok), tostring(why), "state", tostring(Downloader.state(buy)))
end, "downloader refuses buy")
at(19, function() App.holdDownload(find("buy"), home()) end, "hold on buy row")
at(21, function()
    local t = top()
    log("HOLD-BUY-TOP", tostring(t and t.entry and t.entry.action), tostring(t and t.entry and t.entry.title))
    shot("hold-buy-opens-detail")
end, "hold result")
at(22, function() UIManager:close(top()) end, "close detail")
at(23, function() home():openDetail(find("borrow")) end, "borrow detail")
at(25, function() shot("detail-borrow") end)
at(26, function() top():startDownload() end, "borrow download")
at(28, function() shot("detail-borrow-downloading") end)
at(40, function() shot("detail-borrow-after") end)
at(41, function()
    local rec = App.library():find(find("borrow"))
    log("LIBRARY", rec and rec.title, rec and rec.path, rec and rec.source)
end, "library record")
at(42, function() UIManager:close(top()) end, "close borrow detail")
at(44, function() shot("results-after-borrow") end)
at(45, function() home():goHome() end, "go home")
at(48, function() shot("home-mybooks") end)
at(49, function() set_builtins(true); log("done"); os.exit(0) end, "exit")
