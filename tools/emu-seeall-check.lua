-- Ticket #12 check for the KOReader emulator: a shelf's "See all" pages past
-- the 12 cached books with Load more.
--   home (Gutenberg shelves) -> tap "See all" on Popular -> last page shows
--   Load more -> tap it -> 24 books, lands on the page with book 13 -> again
--   -> 36 -> grid view (last page full) -> a forced failure shows in the
--   status strip, Load more stays -> retry works and turns to the page with
--   book 37 -> "New on Gutenberg" See all + Load more ->
--   an old-style provider's shelf (browse returns entries only): no Load more.
-- Internet Archive and DOAB are switched off so nothing else hits the network.
-- Run via
--   scripts/emu.sh --walk tools/emu-seeall-check.lua --shots <dir>
-- Gutendex can be slow on URLs its CDN has not cached; every wait polls (up
-- to WAIT seconds) instead of sleeping a fixed time.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local Browse = require("browse")
local Catalog = require("catalog")
local Settings = require("settings")
local Shelf = require("widget_shelf")
local OUT = os.getenv("OPENSHELF_SHOT_DIR")
local WAIT = tonumber(os.getenv("OPENSHELF_SEEALL_WAIT") or "") or 150
local step = 0
local failures = 0
local function log(...) print("DEVSCRIPT", os.date("%H:%M:%S"), ...) end
local function shot(name)
    UIManager:forceRePaint()   -- paint what the last step changed before capturing
    step = step + 1
    local path = string.format("%s/seeall-%02d-%s.png", OUT, step, name)
    local ok, err = pcall(function() return Screen:shot(path) end)
    log("shot", path, ok, err)
end
local function expect(cond, what)
    if not cond then failures = failures + 1 end
    log(cond and "PASS" or "FAIL", what)
end
local function home() return App.homeView() end
local function top() return UIManager:getTopmostVisibleWidget() end

-- An api-1 provider from before #12: 3-arg browse, entries only.
Catalog.register{ api = 1, id = "oldie", name = "Old Books", quality = 10,
    shelves = { { key = "picks", title = "Old-style picks" } },
    search = function() return {}, false end,
    browse = function(key, limit, ctx)
        local rows = {}
        for i = 1, math.min(limit, 12) do
            rows[i] = ctx.Entry.new{ title = "Old pick " .. i, author = "Old Books",
                locator = { url = "https://dev/oldie/" .. key .. "/" .. i } }
        end
        return rows
    end,
    resolve = function(l) return l.url end }
for __, p in ipairs(Catalog.providers) do Settings.setEnabled(p, true) end
for __, id in ipairs({ "internetarchive", "doab" }) do Settings.setEnabled(Catalog.byId(id), false) end
for __, id in ipairs({ "gutendex", "oldie" }) do Settings.setShelvesOnHome(Catalog.byId(id), true) end
Settings.setSourceOrder({ "gutendex", "oldie" })

-- Sequential steps; wait(pred) polls once a second up to WAIT seconds.
local steps, idx = {}, 0
local function run_next()
    idx = idx + 1
    local s = steps[idx]
    if not s then return end
    local started = os.time()
    local function attempt()
        if s.until_ then
            local ok, ready = pcall(s.until_)
            if not (ok and ready) and os.time() - started < WAIT then
                UIManager:scheduleIn(1, attempt)
                return
            end
            if not (ok and ready) then log("TIMEOUT waiting:", s.label) end
        end
        local ok, err = pcall(s.fn or function() end)
        log(s.label or "", ok and "ok" or ("ERR " .. tostring(err)))
        UIManager:scheduleIn(s.pause or 1, run_next)
    end
    attempt()
end
local function add(label, fn, until_, pause) steps[#steps + 1] = { label = label, fn = fn, until_ = until_, pause = pause } end

local function list()
    local w = top()
    if w and w.pager ~= nil then return w end
    local names = {}
    for i, win in ipairs(UIManager._window_stack) do
        local wd = win.widget
        names[i] = tostring(wd.name or wd.title or wd.text or "?") .. (wd.pager and "[pager]" or "")
    end
    log("STACK", table.concat(names, " | "))
    return nil
end
local function dump(tag)
    local l = top()
    local pg = l.pager
    log(tag, "ENTRIES", #l.entries, "page", l.page, "of", l.total_pages,
        "has_more", pg and tostring(pg.has_more), "loading", pg and tostring(pg.loading),
        "err", pg and tostring(pg.err), "shelf page", pg and pg.page)
    local first = l.page_entries[1]
    log(tag, "FIRST ON PAGE", first and first.title or "-")
end
-- Tap the centre of a hit rectangle, as a finger would.
local function tap(view, hit)
    view:onTap(nil, { pos = { x = hit.x + math.floor(hit.w / 2), y = hit.y + math.floor(hit.h / 2) } })
end
-- Load more: the footer's only hit, as wide as the button and as tall as the footer row.
local function load_more_hit(view)
    local bw, fh = Screen:scaleBySize(120), Screen:scaleBySize(40)
    for __, hit in ipairs(view.hits) do
        if hit.w == bw and hit.h == fh then return hit end
    end
    return nil
end
-- "See all" of the shelf titled `title`: the full-width header hit whose tap opens a list.
-- Other full-width rows of that height (the search row) are kept inert while scanning.
local function see_all(title)
    local h = home()
    local opened
    h.openSearchDialog = function() end
    h.openList = function(self, t, ...)
        opened = t
        if t == title then return getmetatable(self).openList(self, t, ...) end
    end
    for page = 1, h.total_pages or 1 do
        h:goPage(page)
        for __, hit in ipairs(h.hits) do
            if hit.h == Shelf.HEADER_H and hit.x == 0 and hit.w == h.screen_w then
                tap(h, hit)
                if opened == title then
                    h.openSearchDialog, h.openList = nil, nil
                    log("tapped See all on", title, "home page", page)
                    return
                end
            end
        end
    end
    h.openSearchDialog, h.openList = nil, nil
    error("no See all for " .. title)
end
local function cached(id) local e = Browse.get(id); return e and #e > 0 end

add("home", function() home():goHome() end, nil, 2)
add("shelves cached", function()
    local e, stale, more = Browse.get("gutendex:popular")
    log("CACHE popular", #e, "stale", tostring(stale), "has_more", tostring(more))
    local n, ___, nmore = Browse.get("gutendex:new")
    log("CACHE new", #n, "has_more", tostring(nmore))
    home():rebuild(); shot("home")
end, function() return cached("gutendex:popular") and cached("gutendex:new") and cached("oldie:picks") end, 3)

-- Popular: page 1 from the cache, Load more on the last list page
add("See all: Popular", function() see_all("Popular on Gutenberg") end, nil, 2)
add("popular p1", function()
    dump("p1 first page"); shot("popular-p1-first-page")
    local l = list(); l:goPage(l.total_pages)
end, list, 2)
add("popular p1 last page", function()
    local l = list()
    dump("p1 last page")
    expect(#l.entries == 12, "See all opens with the 12 cached books")
    expect(load_more_hit(l) ~= nil, "last page ends in Load more")
    shot("popular-p1-last-page-load-more")
    tap(l, load_more_hit(l))
end, nil, 0)
add("popular loading", function() dump("loading") end, nil, 0)
add("popular p2 landed", function()
    local l = list()
    dump("after load more #1")
    expect(#l.entries == 24, "Load more appends the next 12 (24)")
    local shows13 = false
    for __, e in ipairs(l.page_entries) do if e == l.entries[13] then shows13 = true end end
    expect(shows13, "view shows book 13 (same page when it had room, else the next)")
    shot("popular-after-load-more-1")
end, function() local l = list(); return l and not l.pager.loading end, 2)
add("popular load more #2", function()
    local l = list(); l:goPage(l.total_pages)
    tap(l, load_more_hit(l))
end, nil, 0)
add("popular p3 landed", function()
    local l = list()
    dump("after load more #2")
    expect(#l.entries == 36, "second Load more appends again (36)")
    shot("popular-after-load-more-2")
end, function() local l = list(); return l and not l.pager.loading end, 2)

-- Grid: 36 books fill the last 3x3 page exactly, so the next Load more must turn the page
add("grid", function() local l = list(); l:toggleView(); l:goPage(l.total_pages) end, nil, 2)
add("grid last page", function()
    local l = list(); dump("grid")
    expect(#l.page_entries == 9 and l.page_entries[9] == l.entries[36], "grid: last page full (books 28-36)")
    shot("popular-grid-full-last-page")
end, nil, 1)

-- Failure: the next page errors once
add("forced failure", function()
    local real = Catalog.browse
    Catalog.browse = function()
        Catalog.browse = real
        return nil, "HTTP 503 (forced by the check)"
    end
    local l = list(); l:goPage(l.total_pages)
    tap(l, load_more_hit(l))
end, nil, 0)
add("failure shown", function()
    local l = list()
    dump("after failure")
    expect(l.pager.err ~= nil and #l.entries == 36, "failure keeps the 36 books and records the error")
    expect(load_more_hit(l) ~= nil, "Load more stays to retry")
    shot("popular-load-more-failed")
    l:showStatusDetail()
end, function() local l = list(); return l and not l.pager.loading end, 2)
add("failure detail", function()
    shot("popular-failure-detail"); UIManager:close(top())
end, nil, 1)
add("retry", function()
    local l = list(); tap(l, load_more_hit(l))
end, nil, 0)
add("retry landed", function()
    local l = list()
    dump("after retry")
    expect(#l.entries == 48 and l.pager.err == nil, "retry fetches the same page (48), error cleared")
    expect(l.page_entries[1] == l.entries[37], "full last page -> turned to the page starting with book 37")
    shot("popular-grid-after-retry-page-turn")
end, function() local l = list(); return l and not l.pager.loading end, 2)
add("close popular", function() list():close() end, nil, 2)

-- New on Gutenberg
add("See all: New", function() see_all("New on Gutenberg") end, nil, 2)
add("new p1", function()
    local l = list(); l:goPage(l.total_pages); dump("new p1"); shot("new-p1-last-page")
    expect(load_more_hit(l) ~= nil, "New: Load more shown")
    tap(l, load_more_hit(l))
end, list, 0)
add("new p2 landed", function()
    local l = list(); dump("new after load more")
    expect(l.pager.page == 2 and l.pager.err == nil, "New: page 2 appended")
    shot("new-after-load-more")
end, function() local l = list(); return l and not l.pager.loading end, 2)
add("close new", function() list():close() end, nil, 2)

-- Old-style provider: single page, no Load more
add("See all: old-style", function() see_all("Old-style picks") end, nil, 2)
add("old-style", function()
    local l = list(); l:goPage(l.total_pages); dump("old-style")
    expect(#l.entries == 12 and not l.pager.has_more and load_more_hit(l) == nil,
        "old-style provider: 12 books, no Load more")
    shot("oldstyle-no-load-more")
end, list, 2)
add("close old-style", function() list():close() end, nil, 2)
add("home again", function() shot("home-after") end, nil, 1)
add("exit", function() log("done", failures == 0 and "ALL PASS" or (failures .. " FAILED")); os.exit(0) end)

UIManager:scheduleIn(1, run_next)
