-- Ticket #2 check for the KOReader emulator: provider ids as the key everywhere,
-- one-time migration of a v0.5 library + settings, names only on screen.
-- Seed .kohome/settings with a version-1 openshelf_library.json, an openshelf.lua
-- whose disabled_sources are display names, and an openshelf_browse.json with
-- the old "popular"/"new" keys; then run via
--   scripts/emu.sh --walk tools/emu-ids-check.lua --shots <dir>
-- Walk: home (migrated My books, shelves repopulate) → search → results (✓ on the
-- migrated edition, badges, strip) → filter by source → My books → Sources toggles.
-- Steps after the search are scheduled once it completes: on the inline-jobs
-- emulator a search blocks the UI loop, and fixed times would all fire at once.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local DataStorage = require("datastorage")
local App = require("app")
local Catalog = require("catalog")
local Settings = require("settings")
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
local function top() return App.views[#App.views] end
local function slurp(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end
local SETTINGS = DataStorage:getSettingsDir()

-- Providers that only exist in this walkthrough: one that answers (rows to
-- filter on), one that fails (status strip), one that is off by default.
Catalog.register{ api = 1, id = "fakebooks", name = "Fake Books", quality = 10,
    search = function(q, _l, _p, ctx)
        return { ctx.Entry.new{ title = "Emma", author = "Austen, Jane", locator = { url = "https://fake/emma.epub" } },
                 ctx.Entry.new{ title = "Fake only: " .. q, author = "Nobody", locator = { url = "https://fake/" .. q } } }, false
    end,
    resolve = function(l) return l.url end }
Catalog.register{ api = 1, id = "thrower", name = "Thrower Books",
    search = function() error("simulated outage", 0) end, resolve = function() end }
Catalog.register{ api = 1, id = "sleepy", name = "Sleepy Books", enabled_by_default = false,
    search = function() return {}, false end, resolve = function() end }

local function dump_results()
    local h = home()
    log("ROWS", #h.entries, "collapsed", h.collapsed)
    for i, e in ipairs(h.entries) do
        log(("ROW %02d | %s | %s | %s | %s | %s | downloaded=%s"):format(i, e.title, tostring(e.source),
            tostring(e.provider), tostring(e.quality), Entry.id(e), tostring(App.bookStatus(e).downloaded)))
    end
    if h.results then
        for __, err in ipairs(h.results:errors(Catalog.nameOf)) do log("ERR-STRIP", err) end
        log("STATUS-LINE", h:statusLine())
    end
end

at(1, function()
    -- library migrated on first open (home builds the My books shelf)
    local lib = App.library()
    log("LIBRARY version", lib.data.version, "records", lib:count())
    for __, r in ipairs(lib:all()) do log("REC", r.id, "provider=" .. tostring(r.provider), "quality=" .. tostring(r.quality), "source=" .. tostring(r.source)) end
    local bak = slurp(SETTINGS .. "/openshelf_library.json.v1.bak")
    log("V1.BAK", bak and ("present, version 1: " .. tostring(bak:find('"version":1', 1, true) ~= nil)) or "MISSING")
    local cur = slurp(SETTINGS .. "/openshelf_library.json")
    log("LIBRARY FILE", cur and ("version 2: " .. tostring(cur:find('"version":2', 1, true) ~= nil)
        .. " provider ids: " .. tostring(cur:find('"provider":"gutendex"', 1, true) ~= nil)) or "MISSING")
    -- settings migrated: disabled by display name -> by id
    log("SETTINGS enabledIds", table.concat(Settings.enabledIds(Catalog.providers), ","))
    log("SETTINGS doab enabled?", Settings.isEnabled(Catalog.byId("doab")), "ia enabled?", Settings.isEnabled(Catalog.byId("internetarchive")),
        "sleepy enabled?", Settings.isEnabled(Catalog.byId("sleepy")))
    log("SETTINGS FILE", (slurp(SETTINGS .. "/openshelf.lua") or "MISSING"):gsub("\n", " "))
    -- the ✓ path without the network: a v0.6 Gutendex row for the edition the
    -- v0.5 library recorded must read as downloaded (id match + file on disk)
    local Gut = Catalog.byId("gutendex")
    local fresh = Catalog.stamp(Gut, Gut.parse({ results = { { id = 158, title = "Emma",
        authors = { { name = "Austen, Jane" } },
        formats = { ["application/epub+zip"] = "https://www.gutenberg.org/ebooks/158.epub3.images" } } } }, 10,
        Catalog.ctxFor(Gut)))[1]
    local st = App.bookStatus(fresh)
    log("BOOKSTATUS fresh Gutendex Emma:", Entry.id(fresh), "downloaded=" .. tostring(st.downloaded), "path=" .. tostring(st.path))
    shot("home-migrated")
end, "migration")
at(12, function() shot("home-shelves") end, "home after browse refresh")

local function after_search()
    at(1, function() shot("results-list"); dump_results() end, "results")
    at(2, function() home():showStatusDetail() end, "status detail")
    at(4, function() shot("status-detail"); UIManager:close(UIManager:getTopmostVisibleWidget()) end)
    at(5, function() home():openFilter() end, "filter dialog")
    at(7, function() shot("filter-dialog"); UIManager:close(UIManager:getTopmostVisibleWidget()) end)
    at(8, function()
        -- the dialog's on_change hands back an id set; apply the same shape
        home().filter = { sources = { fakebooks = true }, format = "any" }
        home().page = 1
        home():onResults(home().results)
    end, "filter only Fake Books")
    at(10, function() shot("results-filtered-fakebooks"); dump_results() end)
    at(11, function()
        home().filter = { sources = nil, format = "any" }
        home():onResults(home().results)
        home():goHome()
    end, "reset + home")
    at(13, function() home():openMyBooks() end, "my books")
    at(15, function() shot("my-books") end)
    at(16, function() UIManager:close(top()) end, "close my books")
    at(17, function() home():openSettings() end, "settings")
    at(19, function() shot("settings-sources") end)
    at(20, function()
        Settings.toggle(Catalog.byId("doab"))
        Settings.toggle(Catalog.byId("sleepy"))
        UIManager:close(UIManager:getTopmostVisibleWidget())
        home():openSettings()
    end, "toggle doab on, sleepy on")
    at(22, function()
        shot("settings-toggled")
        log("SETTINGS after toggles", (slurp(SETTINGS .. "/openshelf.lua") or "MISSING"):gsub("\n", " "))
        log("SETTINGS enabledIds", table.concat(Settings.enabledIds(Catalog.providers), ","))
        UIManager:close(UIManager:getTopmostVisibleWidget())
    end, "settings after")
    at(23, function() log("done"); os.exit(0) end, "exit")
end

local function wait_search(started_at)
    if home():isSearching() and os.time() - started_at < 120 then
        UIManager:scheduleIn(1, function() wait_search(started_at) end)
        return
    end
    log("search finished after", os.time() - started_at, "s")
    after_search()
end

at(13, function()
    local Browse = require("browse")
    local pop = Browse.get("gutendex:popular")
    log("BROWSE gutendex:popular", pop and #pop or "nil", pop and pop[1] and pop[1].title)
    home():startSearch("emma")
    UIManager:scheduleIn(1, function() wait_search(os.time()) end)
end, "search")
