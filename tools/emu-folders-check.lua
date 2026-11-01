-- Folders walkthrough for the KOReader emulator (#17, DESIGN.md §12.3-12.5).
-- Built-ins off; examples/folders_demo.lua registered as the only source,
-- extended here with what the demo tree lacks: an empty folder and a folder
-- whose first listing fails (Retry then works) under the root, and a
-- "Courses" shelf holding the root's folder rows. Then: the Browse chip ->
-- two nested levels (list and grid) -> Back -> the ancestor jump from the
-- title menu -> a folder row in search results -> a folder tile on a shelf
-- -> the empty folder -> the failing folder and Retry, and the folder guards
-- (downloader refuses, hold does nothing). Then the offline cache (#18,
-- §12.6): the folders opened above, aged 3 days, open with Wi-Fi faked off
-- ("Updated 3 d ago", nothing asked), a folder never opened asks for Wi-Fi,
-- Refresh online repaints, a stale copy refreshes by itself while online, a
-- failed refresh keeps the cached rows with the error in the toolbar, and
-- changing the demo's setting clears its folders. Logs CHECK lines (PASS/FAIL).
-- Run: KOREADER_SRC=… scripts/emu.sh --walk tools/emu-folders-check.lua --shots <dir>. Dev only.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local Browse = require("browse")
local Catalog = require("catalog")
local Downloader = require("downloader")
local Folders = require("openshelf_folders")
local Settings = require("settings")
local Shelf = require("widget_shelf")
local NetworkMgr = require("ui/network/manager")
local OUT = os.getenv("OPENSHELF_SHOT_DIR")
local REPO = (debug.getinfo(1, "S").source:match("^@(.*/)tools/") or "./")
local step = 0
local function log(...) print("DEVSCRIPT", os.date("%H:%M:%S"), ...) end
local function shot(name)
    step = step + 1
    local path = string.format("%s/%02d-%s.png", OUT, step, name)
    local ok, err = pcall(function() return Screen:shot(path) end)
    log("shot", path, ok, err)
end
local function check(label, ok, detail)
    log("CHECK", label, ok and "PASS" or "FAIL", detail ~= nil and tostring(detail) or "")
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
local function top() return App.views[#App.views] end
local function home() return App.homeView() end
local function titles(list)
    local t = {}
    for i, v in ipairs(list) do t[i] = v.title end
    return table.concat(t, " > ")
end
-- Tap the centre of a hit rectangle a view built, through its own onTap
-- (the path a finger takes).
local function tap(view, hit)
    view:onTap(nil, { pos = { x = hit.x + math.floor(hit.w / 2), y = hit.y + math.floor(hit.h / 2) } })
end
local function row_named(title, entries)
    for __, e in ipairs(entries or top().entries) do
        if e.title == title then return e end
    end
end
-- The title menu (a ButtonDialog) wherever it sits in the window stack: a
-- fresh emulator home can show a first-run notice on top of it.
local function menu()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w.buttontable and w.buttons then return w end
    end
end
local function dump(label)
    local v = top()
    log(label, "VIEW", v.title, "rows", #(v.entries or {}), "status", v.statusLine and v:statusLine() or "")
    for i, e in ipairs(v.entries or {}) do
        log(("ROW %02d | %-8s | %s | count=%s size=%s"):format(i, e.action, e.title, tostring(e.count), tostring(e.size)))
    end
end
-- Widget-less full-screen "ui" refreshes (what ViewBase:onCloseWidget queues).
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

local BUILTINS = { "gutendex", "internetarchive", "doab" }
local function set_builtins(enabled)
    for __, id in ipairs(BUILTINS) do Settings.setEnabled(Catalog.byId(id), enabled) end
end

-- The demo drop-in, plus an empty and a failing folder and a shelf.
local demo = dofile(REPO .. "examples/folders_demo.lua")
local demo_list = demo.list
local broken_calls = 0
local down = false   -- every list fails (a failed refresh)
local list_calls = 0
demo.list = function(loc, limit, page, ctx)
    list_calls = list_calls + 1
    if down then return nil, "the server is down (emu check)" end
    if loc and loc.folder == "emu-empty" then return {}, false end
    if loc and loc.folder == "emu-broken" then
        broken_calls = broken_calls + 1
        if broken_calls == 1 then return nil, "the server said no (emu check)" end
        return { ctx.Entry.new{ title = "Recovered file", author = "Nobody",
            locator = { file = "emu-recovered" } } }, false
    end
    local rows, more = demo_list(loc, limit, page, ctx)
    if loc == nil and rows then
        rows[#rows + 1] = ctx.Entry.folder{ title = "Empty folder", locator = { folder = "emu-empty" } }
        rows[#rows + 1] = ctx.Entry.folder{ title = "Folder that fails once", subtitle = "Retry works",
            locator = { folder = "emu-broken" } }
    end
    return rows, more
end
demo.shelves = { { key = "courses", title = "Courses" } }
demo.browse = function(_key, limit, ctx, page) return demo_list(nil, limit, page, ctx) end
check("demo registers", Catalog.register(demo) == true, table.concat(Catalog.ids(), ","))
set_builtins(false)
Settings.setProviderSetting("folders_demo", "archive", nil)
Folders.cache():clearProvider("folders_demo")   -- every run starts with nothing cached

-- Wi-Fi faked off: NetworkMgr says so, and asking to turn it on is counted
-- (the callback never runs, as when the user says no).
local real_net = { isConnected = NetworkMgr.isConnected, isOnline = NetworkMgr.isOnline,
    beforeWifiAction = NetworkMgr.beforeWifiAction }
local wifi_asks = 0
local function wifi(on)
    if on then
        for k, f in pairs(real_net) do NetworkMgr[k] = f end
        return
    end
    NetworkMgr.isConnected = function() return false end
    NetworkMgr.isOnline = function() return false end
    NetworkMgr.beforeWifiAction = function() wifi_asks = wifi_asks + 1 end
end
-- Age every cached page of the demo by `days`.
local function age_cache(days)
    for k, f in pairs(Folders.cache().data) do
        if k:find("^folders_demo|") then
            for __, p in ipairs(f.pages) do p.at = p.at - days * 86400 end
        end
    end
end
local function open_chip() home():browseRows()[2].hits[1].on_tap() end
local function menu_button(label)
    local dialog = menu()
    for __, row in ipairs(dialog and dialog.buttons or {}) do
        if row[1].text:find(label, 1, true) then return row[1] end
    end
end

-- 1. home: Browse chip + the Courses shelf of folder tiles
at(1, function() home():rebuild() end, "home rebuild (shelf fetch)")
at(3, function()
    local roots = Settings.browseRoots()
    check("one Browse chip", #roots == 1 and roots[1].title == "Demo courses", #roots)
    shot("home-browse-chip-and-folder-shelf")
end, "home")
-- 2. the chip opens the root (its own on_tap)
at(1, open_chip, "tap Browse chip")
at(2, function()
    local v = top()
    check("root view", v.title == "Demo courses" and v.folder == nil and v.parent == nil, v.title)
    dump("root")
    shot("root-list")
end, "root")
at(1, function() top():toggleView() end, "grid")
at(2, function() shot("root-grid") end, "root grid")
at(1, function() top():toggleView() end, "list again")
-- 3. two nested levels
at(1, function() top():openEntry(row_named("Literature 101")) end, "open Literature 101")
at(2, function() dump("level 1"); shot("lit101-list") end, "level 1")
at(1, function() top():openEntry(row_named("Week 1")) end, "open Week 1")
at(2, function()
    local v = top()
    check("level 2 chain", titles(Folders.ancestors(v)) == "Demo courses > Literature 101", titles(Folders.ancestors(v)))
    dump("level 2")
    shot("week1-list")
end, "level 2")
at(1, function() top():toggleView() end, "grid")
at(2, function() shot("week1-grid") end, "level 2 grid")
at(1, function() top():toggleView() end, "list again")
-- 4. Back = up one level, one full refresh
at(1, function()
    local before, views = full_ui, #App.views
    top().title_bar.left_icon_tap_callback()
    check("Back closes one level with one full refresh",
        #App.views == views - 1 and full_ui - before == 1 and top().title == "Literature 101",
        ("views %d->%d refreshes +%d top %s"):format(views, #App.views, full_ui - before, top().title))
end, "Back")
at(1, function() shot("back-to-lit101") end, "after Back")
-- 5. the title menu: ancestors, nearest last; picking the root closes the two above it
at(1, function() top():openEntry(row_named("Week 1")) end, "open Week 1 again")
at(2, function() top():onTitleTap() end, "title tap")
at(1, function()
    shot("title-menu")
    local dialog = menu()
    local first = dialog and dialog.buttons[1] and dialog.buttons[1][1]
    local second = dialog and dialog.buttons[2] and dialog.buttons[2][1]
    local last = dialog and dialog.buttons[3] and dialog.buttons[3][1]
    check("menu: the root first, the nearest last, then Refresh",
        #dialog.buttons == 3 and first.text:find("Demo courses", 1, true) ~= nil
            and second.text:find("Literature 101", 1, true) ~= nil
            and last.text:find("Refresh", 1, true) ~= nil,
        first and first.text)
    local before, views = full_ui, #App.views
    first.callback()
    check("jump to the root", top().title == "Demo courses" and #App.views == views - 2,
        ("views %d->%d top %s refreshes +%d"):format(views, #App.views, top().title, full_ui - before))
end, "pick the root")
at(1, function() shot("jumped-to-root") end, "after jump")
at(1, function() top():onTitleTap() end, "title tap on the root")
at(1, function()
    local dialog = menu()
    check("the root's menu is just Refresh", dialog and #dialog.buttons == 1
        and dialog.buttons[1][1].text:find("Refresh", 1, true) ~= nil, dialog and #dialog.buttons)
    shot("root-menu-refresh")
    UIManager:close(dialog)
end, "root menu")
-- 6. the empty folder and the failing one (Retry)
at(1, function() top():openEntry(row_named("Empty folder")) end, "open Empty folder")
at(2, function()
    check("empty folder", #top().entries == 0 and top().pager:loaded(), top():statusLine())
    shot("empty-folder")
    top():close()
end, "empty")
at(1, function() top():openEntry(row_named("Folder that fails once")) end, "open failing folder")
at(2, function()
    check("first listing failed", top().pager.err ~= nil and not top().pager:loaded(), top().pager.err)
    check("the provider's reason is shown under the message, then Retry", #top():emptyRows() == 3,
        #top():emptyRows())
    shot("failing-folder-retry")
    local retry
    for __, hit in ipairs(top().hits) do
        if hit.w == Screen:scaleBySize(120) then retry = hit end   -- the Retry button
    end
    tap(top(), retry)
end, "tap Retry")
at(2, function()
    check("Retry lists it", #top().entries == 1 and top().pager.err == nil, top():statusLine())
    shot("failing-folder-after-retry")
    top():close()
end, "after Retry")
at(1, function() top():close() end, "close the root")
-- 7. folder guards
at(1, function()
    local folder = Browse.get("folders_demo:courses")[1]
    local ok, why = Downloader.enqueue(folder)
    check("downloader refuses a folder", ok == false and Downloader.state(folder) == nil, why)
    local views = #App.views
    App.holdDownload(folder, home())
    check("hold on a folder does nothing (yet)", #App.views == views, #App.views)
    check("no status for folder rows", App.bookStatus(folder).record == nil and not App.bookStatus(folder).downloaded)
    require("view_detail").show(folder)
    check("no detail page for a folder", #App.views == views, #App.views)
end, "guards")
-- 8. a folder row in search results
at(1, function() home():startSearch("gothic") end, "search")
at(3, function()
    local h = home()
    for i, e in ipairs(h.entries) do log(("RESULT %02d | %-8s | %s"):format(i, e.action, e.title)) end
    shot("search-folder-row")
    local row_hit
    for __, hit in ipairs(h.hits) do
        if hit.w == h.screen_w then row_hit = hit; break end   -- the first result row
    end
    tap(h, row_hit)
end, "tap the Gothic folder in the results")
at(2, function()
    local v = top()
    check("search opens a folder view with no ancestors", v.title == "Gothic" and #Folders.ancestors(v) == 0, v.title)
    shot("gothic-from-search")
    v:close()
end, "Gothic")
at(1, function() home():toggleView() end, "results grid")
at(2, function() shot("search-folder-grid"); home():toggleView(); home():goHome() end, "home again")
-- 9. a folder tile on the shelf
at(2, function()
    shot("home-folder-shelf")
    local tiles = {}
    for __, hit in ipairs(home().hits) do
        if hit.w == Shelf.geometry(home()).cover_w then tiles[#tiles + 1] = hit end
    end
    tap(home(), tiles[2])   -- Literature 201
end, "tap a shelf tile")
at(2, function()
    check("shelf tile opens its folder", top().title == "Literature 201" and #Folders.ancestors(top()) == 0, top().title)
    dump("from shelf")
    shot("lit201-from-shelf")
    top():close()
end, "shelf folder")
-- 10. the offline cache (#18): what was opened above shows offline
at(1, function()
    local c = Folders.cache()
    check("opened folders are cached", c:has("folders_demo", nil) and c:has("folders_demo", { folder = "lit101" })
        and c:has("folders_demo", { folder = "lit101-w1" }) and c:has("folders_demo", { folder = "emu-empty" }))
    check("a folder never opened is not", not c:has("folders_demo", { folder = "lit101-w2" }))
    age_cache(3)
    wifi(false)
    list_calls = 0
    open_chip()
end, "Wi-Fi off, open the root")
at(2, function()
    local v = top()
    check("offline: the root opens from the cache, nothing asked",
        v.title == "Demo courses" and #v.entries == 5 and wifi_asks == 0 and list_calls == 0,
        ("rows %d asks %d lists %d"):format(#v.entries, wifi_asks, list_calls))
    check("…saying how old the copy is", v:statusLine():find("Updated 3 d ago", 1, true) ~= nil, v:statusLine())
    check("…and not refreshing it offline", not v.pager.loading, v:statusLine())
    shot("offline-root-from-cache")
    v:openEntry(row_named("Literature 101"))
end, "offline root")
at(2, function()
    top():openEntry(row_named("Week 1"))
end, "offline Literature 101")
at(2, function()
    local v = top()
    check("offline: two levels down from the cache",
        v.title == "Week 1" and #v.entries == 2 and list_calls == 0
            and titles(Folders.ancestors(v)) == "Demo courses > Literature 101", v:statusLine())
    shot("offline-week1-from-cache")
    v:close()
end, "offline Week 1")
at(1, function()
    local views = #App.views
    top():openEntry(row_named("Week 2"))
    check("offline: a folder never opened asks for Wi-Fi", wifi_asks == 1 and #App.views == views,
        ("asks %d views %d->%d"):format(wifi_asks, views, #App.views))
end, "offline Week 2")
-- Refresh online: the title menu refetches and repaints
at(1, function()
    wifi(true)
    list_calls = 0
    top():onTitleTap()
end, "Wi-Fi on, title menu")
at(1, function()
    shot("menu-refresh")
    menu_button("Refresh").callback()
    check("Refresh starts at once", top().reloading == true, top():statusLine())
end, "Refresh")
at(2, function()
    local v = top()
    check("Refresh online repaints with a fresh copy",
        not v.reloading and list_calls == 1 and v:statusLine():find("Updated", 1, true) == nil
            and #v.entries == 2, ("%s lists %d"):format(v:statusLine(), list_calls))
    shot("after-refresh")
end, "after Refresh")
-- a stale copy refreshes by itself while Wi-Fi is on
at(1, function()
    age_cache(2)
    top():close()
    list_calls = 0
    top():openEntry(row_named("Literature 101"))
    check("a stale copy opened online refreshes by itself", top().reloading == true, top():statusLine())
    shot("stale-refreshing")
end, "stale online")
at(2, function()
    check("…and repaints", not top().reloading and list_calls == 1
        and top():statusLine():find("Updated", 1, true) == nil, top():statusLine())
end, "background refresh")
-- a failed refresh keeps the cached rows, the error in the toolbar
at(1, function()
    down = true
    top():onTitleTap()
end, "server down, title menu")
at(1, function() menu_button("Refresh").callback() end, "Refresh")
at(2, function()
    local v = top()
    check("a failed refresh keeps the cached rows", #v.entries == 2 and v.pager.err ~= nil, #v.entries)
    check("…with the error in the toolbar", v:statusLine():find("failed", 1, true) ~= nil, v:statusLine())
    check("…and the reason behind it", v:statusDetail(v.pager.err):find("Could not refresh", 1, true) ~= nil
        and v:statusDetail(v.pager.err):find("down", 1, true) ~= nil, v:statusDetail(v.pager.err))
    shot("refresh-failed-cached-rows")
    down = false
    v:close()
end, "failed refresh")
-- changing the demo's setting clears its folders
at(1, function()
    top():close()   -- the root
    Settings.setProviderSetting("folders_demo", "archive", true)
    check("changing a setting clears the demo's folders", not Folders.cache():has("folders_demo", nil)
        and not Folders.cache():has("folders_demo", { folder = "lit101" }))
    open_chip()
end, "archive on")
at(2, function()
    local v = top()
    check("the root is listed again, with the archive", v.entries[1] and v.entries[1].title == "Archive"
        and #v.entries == 6, v.entries[1] and v.entries[1].title)
    shot("root-with-archive")
    v:close()
    Settings.setProviderSetting("folders_demo", "archive", nil)
end, "archive")
at(1, function() set_builtins(true); log("done"); os.exit(0) end, "exit")
run(1)
