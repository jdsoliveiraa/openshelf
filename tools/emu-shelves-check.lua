-- Ticket #6 check for the KOReader emulator: shelves from any provider and
-- the per-source "Shelves on home" toggle.
-- Two offline dev providers declare shelves (Alpha: two, Beta: one); Internet
-- Archive and DOAB are switched off so nothing hangs.
--
-- OPENSHELF_SHELVES_PHASE=main (default, inline jobs): home shows Alpha's,
--   Beta's and Gutenberg's shelves in source order -> See all on an Alpha
--   shelf -> Alpha's submenu, "Shelves on home" off -> home without Alpha ->
--   back on, then Beta disabled -> home without Beta -> Beta re-enabled.
-- OPENSHELF_SHELVES_PHASE=stale with OPENSHELF_INLINE_JOBS=0 (real forks; the
--   dev browse does no network, so the child survives on macOS): Gutenberg is
--   off too. Before the run, make "alpha:picks" stale in
--   .kohome/settings/openshelf_browse.json (run main first so it exists; set
--   its "at" to 0 and retitle its rows, e.g. "Old pick N") -> home shows the
--   stale rows while the forked refresh sleeps -> the refresh lands and home
--   repaints with the fresh rows.
-- Run via
--   scripts/emu.sh --walk tools/emu-shelves-check.lua --shots <dir>
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local Browse = require("browse")
local Catalog = require("catalog")
local Settings = require("settings")
local SourceMenu = require("settings_source")
local OUT = os.getenv("OPENSHELF_SHOT_DIR")
local PHASE = os.getenv("OPENSHELF_SHELVES_PHASE") or "main"
local step = 0
local function log(...) print("DEVSCRIPT", os.date("%H:%M:%S"), ...) end
local function shot(name)
    step = step + 1
    local path = string.format("%s/%s-%02d-%s.png", OUT, PHASE, step, name)
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
local function topmost() return UIManager:getTopmostVisibleWidget() end

local function dev(id, name, shelves)
    Catalog.register{ api = 1, id = id, name = name, quality = 10, shelves = shelves,
        search = function() return {}, false end,
        browse = function(key, _limit, ctx)
            if PHASE == "stale" then os.execute("sleep 4") end   -- in the forked child
            local rows = {}
            for i = 1, 4 do
                rows[i] = ctx.Entry.new{ title = name .. " " .. key .. " " .. i .. " (fresh)", author = name,
                    locator = { url = "https://dev/" .. id .. "/" .. key .. "/" .. i } }
            end
            return rows
        end,
        resolve = function(l) return l.url end }
end
dev("alpha", "Alpha Books", { { key = "picks", title = "Alpha picks" }, { key = "new", title = "New at Alpha" } })
dev("beta", "Beta Books", { { key = "staff", title = "Beta staff picks" } })
local off = PHASE == "stale" and { "gutendex", "internetarchive", "doab" } or { "internetarchive", "doab" }
for __, p in ipairs(Catalog.providers) do Settings.setEnabled(p, true) end
for __, id in ipairs(off) do Settings.setEnabled(Catalog.byId(id), false) end
for __, id in ipairs({ "alpha", "beta", "gutendex" }) do Settings.setShelvesOnHome(Catalog.byId(id), true) end
Settings.setSourceOrder({ "alpha", "beta", "gutendex" })

local function dump(tag)
    local ids = {}
    for __, s in ipairs(Settings.homeShelves()) do ids[#ids + 1] = s.id end
    log(tag, "HOME SHELVES", table.concat(ids, ","))
    local v, stale = Browse.get("alpha:picks")
    log(tag, "CACHE alpha:picks", v and v[1] and v[1].title or "none", "stale=" .. tostring(stale))
end

local function item(menu, label)
    for __, it in ipairs(menu.item_table) do
        if it.text == label then return it end
    end
end

if PHASE == "stale" then
    at(1, function() dump("before"); home():goHome() end, "home (stale cache)")
    at(2, function() shot("home-stale"); dump("stale shown") end)
    at(9, function() dump("after refresh"); shot("home-refreshed") end)
    at(10, function() log("done"); os.exit(0) end, "exit")
    return
end

at(1, function() home():goHome() end, "home")
at(6, function() dump("initial"); shot("home-two-providers") end)
at(7, function() home():goPage(2) end, "page 2")
at(9, function() shot("home-page2-gutenberg"); home():goPage(1) end)
at(10, function()
    local e = Browse.get("alpha:picks")
    home():openList("Alpha picks", e)
end, "See all on Alpha picks")
at(12, function() shot("alpha-see-all"); UIManager:close(topmost()) end)
at(13, function() SourceMenu.show(Catalog.byId("alpha")) end, "Alpha submenu")
at(15, function() shot("alpha-submenu-on") end)
at(16, function()
    local m = topmost()
    item(m, "Shelves on home").callback()
end, "toggle Shelves on home off")
at(17, function() shot("alpha-submenu-off"); UIManager:close(topmost()); home():goHome() end)
at(19, function() dump("alpha toggle off"); shot("home-alpha-hidden") end)
at(20, function()
    Settings.setShelvesOnHome(Catalog.byId("alpha"), true)
    SourceMenu.show(Catalog.byId("beta"))
end, "Beta submenu")
at(21, function()
    item(topmost(), "Enabled").callback()
end, "disable Beta")
at(22, function() shot("beta-submenu-disabled"); UIManager:close(topmost()); home():goHome() end)
at(24, function() dump("beta disabled"); shot("home-beta-hidden") end)
at(25, function() Settings.setEnabled(Catalog.byId("beta"), true); home():goHome() end, "re-enable Beta")
at(27, function() dump("restored"); shot("home-restored") end)
at(28, function() log("done"); os.exit(0) end, "exit")
