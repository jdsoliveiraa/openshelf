-- Ticket #5 check for the KOReader emulator: Sources -> Arrange sources.
-- Registers three offline dev providers with one shelf each, switches the
-- built-ins off (no network, no IA hang), then:
--   home (shelf order) -> search (slot order) -> filter (checkbox order)
--   -> settings -> Arrange sources row -> SortWidget -> move Gamma to the top
--   -> OK -> search again / filter / home: all follow the new order.
-- Run via
--   scripts/emu.sh --walk tools/emu-arrange-check.lua --shots <dir>
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local Catalog = require("catalog")
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
local function home() return App.homeView() end
local function topmost() return UIManager:getTopmostVisibleWidget() end

local function dev(id, name)
    Catalog.register{ api = 1, id = id, name = name, quality = 10,
        shelves = { { key = "picks", title = name .. " picks" } },
        search = function(q, _l, _p, ctx)
            local rows = {}
            for i = 1, 2 do
                rows[i] = ctx.Entry.new{ title = name .. " book " .. i .. " (" .. q .. ")", author = name,
                    locator = { url = "https://dev/" .. id .. "/" .. i } }
            end
            return rows, false
        end,
        browse = function(_key, _limit, ctx)
            local rows = {}
            for i = 1, 4 do
                rows[i] = ctx.Entry.new{ title = name .. " shelf " .. i, author = name,
                    locator = { url = "https://dev/" .. id .. "/s" .. i } }
            end
            return rows
        end,
        resolve = function(l) return l.url end }
end
dev("alpha", "Alpha Books")
dev("beta", "Beta Books")
dev("gamma", "Gamma Books")
for __, id in ipairs({ "gutendex", "internetarchive", "doab" }) do
    Settings.setEnabled(Catalog.byId(id), false)
end
Settings.setSourceOrder({})   -- start from registration order

local function dump(tag)
    local h = home()
    local slots = {}
    for __, e in ipairs(h.entries or {}) do
        if slots[#slots] ~= e.provider then slots[#slots + 1] = e.provider end
    end
    log(tag, "SLOTS", table.concat(slots, ","))
    local shelves = {}
    for __, s in ipairs(Catalog.shelves(Settings.sourceOrder())) do shelves[#shelves + 1] = s.id end
    log(tag, "SHELVES", table.concat(shelves, ","))
    log(tag, "ENABLED", table.concat(Settings.enabledIds(Settings.orderedProviders()), ","))
end

local function round(t0, tag, after)
    at(t0, function() home():goHome() end, tag .. " home")
    at(t0 + 4, function() shot(tag .. "-home-shelves") end)
    at(t0 + 5, function() home():startSearch("emma") end, tag .. " search")
    at(t0 + 8, function() shot(tag .. "-results"); dump(tag) end)
    at(t0 + 9, function() home():openFilter() end, tag .. " filter")
    at(t0 + 11, function() shot(tag .. "-filter"); UIManager:close(topmost()) end)
    if after then after(t0 + 12) end
end

round(3, "before", function(t)
    at(t, function() home():goHome(); home():openSettings() end, "settings")
    at(t + 2, function() shot("settings-arrange-row") end)
    at(t + 3, function()
        local menu = topmost()
        local row
        for __, item in ipairs(menu.item_table) do
            if item.text and item.text:find("Arrange sources", 1, true) then row = item end
        end
        log("ARRANGE ROW", row and row.text or "MISSING")
        row.callback()
    end, "tap Arrange sources")
    at(t + 5, function() shot("sortwidget-initial") end)
    at(t + 6, function()
        local sw = topmost()
        local idx
        for i, item in ipairs(sw.item_table) do if item.id == "gamma" then idx = i end end
        log("SORTWIDGET items", #sw.item_table, "gamma at", idx)
        sw.marked = idx
        sw:moveItem(1 - idx)      -- to the top
        sw:_populateItems()
    end, "move Gamma to the top")
    at(t + 8, function() shot("sortwidget-moved") end)
    at(t + 9, function()
        local sw = topmost()
        sw:onReturn()              -- confirms the move (callback saves)
        if topmost() == sw then sw:onReturn() end   -- second OK closes
        log("STORED source_order", table.concat(Settings.sourceOrder() or {}, ","))
    end, "OK")
    at(t + 11, function() shot("settings-after-arrange"); UIManager:close(topmost()) end)
    round(t + 13, "after", function(t2)
        at(t2, function() home():goHome() end)
        at(t2 + 2, function() log("done"); os.exit(0) end, "exit")
    end)
end)
