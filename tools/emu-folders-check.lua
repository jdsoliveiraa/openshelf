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
-- changing the demo's setting clears its folders. Then scoped search (#21,
-- §12.7): the search glyph -> the input dialog -> results with folders and
-- nested files, Load more, a folder opened from them, a search inside a
-- folder, offline asking for Wi-Fi, no glyph without search_in. Then Download
-- all (#20): a two-page folder queues all 60 files and Cancel downloads
-- empties the queue, hold on a folder row in search downloads its file,
-- files on the device are skipped, nothing left gives a message. Then files on the device
-- (#19, §12.8): the two Pride and Prejudice files of Literature 101 and 201
-- land in their own mirrored directories, ✓ only on the downloaded one; an
-- recorded file downloaded again from a row with no path keeps its recorded
-- path; an "Editions" shelf's same-named pair (no path, flat) gets Name and
-- Name (2), one after the other and also queued together; My books lists
-- all six, the OpenShelf folder is listed (ls -R) and a folder file opens in
-- the reader. Downloads are real (Project Gutenberg); the flat ones carry the
-- author "OpenShelf Check", so they never meet a real file in OpenShelf/.
-- Logs CHECK lines (PASS/FAIL).
-- Run: KOREADER_SRC=… scripts/emu.sh --walk tools/emu-folders-check.lua --shots <dir>. Dev only.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local Browse = require("browse")
local Catalog = require("catalog")
local Downloader = require("downloader")
local Folders = require("openshelf_folders")
local Glyphs = require("glyphs")
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
    if loc and loc.folder == "emu-stuck" then   -- ignores `page`: the same 3 files, always has_more
        local rows = {}
        for i = 1, 3 do
            rows[i] = ctx.Entry.new{ title = "Loop " .. i, author = "OpenShelf Check", format = "epub",
                locator = { file = "lit101-w1-emma", stuck = i } }
        end
        return rows, true
    end
    if loc and loc.folder == "emu-big" then   -- two pages: 60 files of 1000 bytes
        local first, rows = (page - 1) * limit + 1, {}
        for i = first, math.min(60, first + limit - 1) do
            rows[#rows + 1] = ctx.Entry.new{ title = ("Handout %02d"):format(i), author = "OpenShelf Check",
                format = "epub", size = 1000, locator = { file = "lit101-w1-emma", big = i } }
        end
        return rows, first + limit - 1 < 60
    end
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
demo.shelves = { { key = "courses", title = "Courses" }, { key = "editions", title = "Editions" } }
demo.browse = function(key, limit, ctx, page)
    if key == "editions" then   -- two same-named pairs, no path: all flat
        local function edition(title, file, gutenberg, copy)
            return ctx.Entry.new{ title = title, author = "OpenShelf Check", format = "epub",
                cover = ("https://www.gutenberg.org/cache/epub/%d/pg%d.cover.medium.jpg"):format(gutenberg, gutenberg),
                locator = { file = file, shelf = "editions", copy = copy } }
        end
        return { edition("Pride and Prejudice", "lit101-w1-pp", 1342, 1), edition("Pride and Prejudice", "lit201-w1-pp", 42671, 2),
                 edition("Emma", "lit101-w1-emma", 158, 1), edition("Emma", "lit101-w1-emma", 158, 2) }, false
    end
    local rows, more = demo_list(nil, limit, page, ctx)
    if rows and page == 1 then   -- a two-page folder for Download all (#20)
        rows[#rows + 1] = ctx.Entry.folder{ title = "Big folder", count = 60, size = 60000,
            locator = { folder = "emu-big" } }
        rows[#rows + 1] = ctx.Entry.folder{ title = "Stuck folder", locator = { folder = "emu-stuck" } }
    end
    return rows, more
end
check("demo registers", Catalog.register(demo) == true, table.concat(Catalog.ids(), ","))
set_builtins(false)
Settings.setProviderSetting("folders_demo", "archive", nil)
Folders.cache():clearProvider("folders_demo")   -- every run starts with nothing cached

-- Every run starts with none of the demo's files (#19): its recorded files
-- go, and the files this script downloads, by exact name (another emulator
-- home, e.g. another worktree, shares ~/OpenShelf but not the records), then
-- the directories they leave empty (rmdir never removes anything else).
local ROOT = Downloader.dirPath()
local CHECK_FILES = {
    "Folders demo/Literature 101/Week 1/Pride and Prejudice.epub",
    "Folders demo/Literature 201/Week 1/Pride and Prejudice.epub",
    "OpenShelf Check - Pride and Prejudice.epub", "OpenShelf Check - Pride and Prejudice (2).epub",
    "OpenShelf Check - Emma.epub", "OpenShelf Check - Emma (2).epub",
    "Folders demo/Literature 101/Week 1/Emma.epub", "Folders demo/Literature 101/Week 2/Frankenstein.epub",
}
local function demo_records()
    local t = {}
    for __, r in ipairs(App.library():all()) do
        if r.provider == "folders_demo" then t[#t + 1] = r end
    end
    return t
end
local function remove_demo_files()
    local lfs = require("libs/libkoreader-lfs")
    for __, r in ipairs(demo_records()) do
        App.removeFromLibrary(r)
        if r.path then os.remove(r.path) end
    end
    for __, f in ipairs(CHECK_FILES) do os.remove(ROOT .. "/" .. f) end
    for __, d in ipairs({ "Literature 101/Week 1", "Literature 101/Week 2", "Literature 101",
                          "Literature 201/Week 1", "Literature 201", "Big folder", "" }) do
        lfs.rmdir(ROOT .. "/Folders demo" .. (d ~= "" and ("/" .. d) or ""))
    end
end
remove_demo_files()

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
at(1, function()
    -- the demo's shelves as this script defines them, not a cached older copy
    Browse.refresh("folders_demo:courses")
    Browse.refresh("folders_demo:editions")
end, "refresh the demo's shelves")
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
    -- cover tiles by row, top to bottom: My books (when it has books), then Courses
    local rows, ys = {}, {}
    for __, hit in ipairs(home().hits) do
        if hit.w == Shelf.geometry(home()).cover_w then
            if not rows[hit.y] then rows[hit.y] = {}; ys[#ys + 1] = hit.y end
            table.insert(rows[hit.y], hit)
        end
    end
    table.sort(ys)
    local courses = rows[ys[App.library():count() > 0 and 2 or 1]]
    tap(home(), courses[2])   -- Literature 201
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
            and titles(Folders.ancestors(v)) == "Demo courses > Literature 101"
            and v:statusLine():find("Updated 3 d ago", 1, true) ~= nil, v:statusLine())
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
-- 12. scoped search (#21, §12.7): the search glyph, the results view, Load more
local function input_dialog()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w.getInputText and w.button_table then return w end
    end
end
local function glyphs_of(v)
    local t = {}
    for i, b in ipairs(v:toolbarButtons()) do t[i] = b.glyph end
    return t
end
local recents_before, per_source_before
at(1, function()
    recents_before = table.concat(Settings.recents(), "|")
    per_source_before = Settings.perSource()
    Settings.setPerSource(10)
    open_chip()
end, "open the root for scoped search")
at(2, function()
    local v = top()
    local g = glyphs_of(v)
    check("the root shows a search glyph before list/grid", #g == 2 and g[1] == Glyphs.search, #g)
    -- tap it where a finger would: the toolbar hit right of the status text
    local hit
    for __, h in ipairs(v.hits) do
        if h.y < v.content_top + Screen:scaleBySize(36) and h.x > 0 and not hit then hit = h end
    end
    tap(v, hit)
end, "tap the search glyph")
at(1, function()
    local dialog = input_dialog()
    check("the glyph opens the stock input dialog", dialog ~= nil)
    shot("search-in-dialog")
    dialog:setInputText("e")
    dialog.button_table:getButtonById("search").callback()
end, "search the root for e")
at(2, function()
    local v = top()
    check("results view titled with the query and the folder", v.title == "“e” in Demo courses", v.title)
    check("page 1: 10 rows at the search page size", #v.entries == 10 and v.pager.has_more, #v.entries)
    local folders, nested = 0, false
    for __, e in ipairs(v.entries) do
        if e.action == "folder" then folders = folders + 1 end
        if e.title == "Emma" then nested = true end   -- Demo courses > Literature 101 > Week 1
    end
    check("it finds folders and a nested file", folders > 0 and nested, folders)
    check("…and is not a recent search", table.concat(Settings.recents(), "|") == recents_before)
    dump("search in root")
    shot("search-in-results-p1")
    v:loadMore()
end, "Load more")
at(2, function()
    local v = top()
    check("Load more appends page 2", #v.entries == 12 and not v.pager.has_more, #v.entries)
    v:toggleView()
    shot("search-in-results-grid")
    v:toggleView()
end, "page 2")
at(1, function()
    local v = top()
    local week2
    for __, e in ipairs(v.entries) do
        if e.title == "Week 2" then week2 = e end
    end
    check("a folder row shows its path as the second line", Folders.secondLine(week2, v.in_folder) == "Literature 101",
        Folders.secondLine(week2, v.in_folder))
    check("…and lands under its path (#19)", Downloader.paths:dirFor(week2) == "Folders demo/Literature 101/Week 2",
        Downloader.paths:dirFor(week2))
    v:openEntry(week2)
end, "open a folder from the results")
at(2, function()
    local v = top()
    check("it opens a folder view with no folder views below", v.title == "Week 2" and #Folders.ancestors(v) == 0, v.title)
    shot("search-in-opened-folder")
    v:close()
    top():close()   -- the results
end, "folder from results")
-- inside a folder: a nested file and a folder
at(1, function() top():openEntry(row_named("Literature 201")) end, "Literature 201")
at(2, function() top():searchIn("e") end, "search Literature 201")
at(2, function()
    local v = top()
    local titles_found = {}
    for __, e in ipairs(v.entries) do titles_found[#titles_found + 1] = e.title end
    local found = table.concat(titles_found, ",")
    check("in a folder: its subfolders and a file nested two levels down",
        v.title == "“e” in Literature 201" and found:find("Seminar", 1, true) ~= nil
            and found:find("Dracula", 1, true) ~= nil and not found:find("Emma", 1, true), found)
    shot("search-in-lit201")
    v:close()
end, "results in Literature 201")
-- offline: asks for Wi-Fi, opens nothing
at(1, function()
    wifi(false)
    local asks, views = wifi_asks, #App.views
    top():searchIn("e")
    check("offline: scoped search asks for Wi-Fi", wifi_asks == asks + 1 and #App.views == views,
        ("asks +%d views %d->%d"):format(wifi_asks - asks, views, #App.views))
    wifi(true)
end, "offline scoped search")
-- a provider without search_in: no glyph
at(1, function()
    local p = Catalog.byId("folders_demo")
    local search_in = p.search_in
    p.search_in = nil
    top():rebuild()
    local g = glyphs_of(top())
    check("a provider without search_in shows no search glyph", #g == 1 and g[1] ~= Glyphs.search, #g)
    shot("no-search-glyph")
    p.search_in = search_in
    Settings.setPerSource(per_source_before)
    top():close()
    top():close()
end, "no search_in")
-- 11. files on the device (#19): mirrored directories, names, (2), ✓, My books
local PP = "Pride and Prejudice"
local again_entry, again_mtime
local function downloaded_to(entry, path)
    local st = App.bookStatus(entry)
    return st.downloaded and st.path == path, st.path
end
at(1, function()
    check("no demo file on the device yet", #demo_records() == 0, #demo_records())
    open_chip()
end, "open the root")
at(2, function() top():openEntry(row_named("Literature 101")) end, "Literature 101")
at(2, function() top():openEntry(row_named("Week 1")) end, "Week 1")
at(2, function()
    local pp = row_named(PP)
    check("a listed file is stamped with its folder's directory", pp.dir == "Folders demo/Literature 101/Week 1", pp.dir)
    check("not on the device yet", not App.bookStatus(pp).downloaded)
    Downloader.enqueue(pp)
end, "download Literature 101's Pride and Prejudice")
at(5, function()
    local ok, got = downloaded_to(row_named(PP), ROOT .. "/Folders demo/Literature 101/Week 1/Pride and Prejudice.epub")
    check("it lands in Folders demo/Literature 101/Week 1/Pride and Prejudice.epub", ok, got)
    shot("lit101-week1-downloaded")
    top():close()
    top():close()
    top():openEntry(row_named("Literature 201"))
end, "Literature 201")
at(2, function() top():openEntry(row_named("Week 1")) end, "Literature 201 Week 1")
at(2, function()
    local pp = row_named(PP)
    check("its same-named twin in Literature 201 shows no ✓", not App.bookStatus(pp).downloaded,
        App.bookStatus(pp).path)
    shot("lit201-week1-twin-not-downloaded")
    Downloader.enqueue(pp)
end, "download Literature 201's")
at(5, function()
    local ok, got = downloaded_to(row_named(PP), ROOT .. "/Folders demo/Literature 201/Week 1/Pride and Prejudice.epub")
    check("…and lands in its own directory", ok, got)
    shot("lit201-week1-downloaded")
    -- the same file reached another way (no path, no stamp: as from a shelf):
    -- Download again rewrites the recorded path, never a flat name
    local bare = {}
    for k, v in pairs(row_named(PP)) do bare[k] = v end
    bare.dir, bare.path = nil, nil
    again_entry = bare
    again_mtime = require("libs/libkoreader-lfs").attributes(got, "modification")
    check("a recorded file's target is its recorded path, however it was reached", Downloader.target(bare) == got,
        Downloader.target(bare))
    while #App.views > 1 do top():close() end
    Downloader.enqueue(bare)
end, "Download again from a row with no path")
at(5, function()
    local path = ROOT .. "/Folders demo/Literature 201/Week 1/Pride and Prejudice.epub"
    local lfs = require("libs/libkoreader-lfs")
    check("Download again rewrote the recorded path", (downloaded_to(again_entry, path))
        and (lfs.attributes(path, "modification") or 0) >= again_mtime, path)
    check("…and wrote no flat copy", lfs.attributes(ROOT .. "/Jane Austen - Pride and Prejudice.epub") == nil)
end, "after Download again")
-- the flat pairs from the Editions shelf
local FLAT_PP = ROOT .. "/OpenShelf Check - Pride and Prejudice"
local FLAT_EMMA = ROOT .. "/OpenShelf Check - Emma"
local function editions() return Browse.get("folders_demo:editions") or {} end
at(1, function()
    local ed = editions()
    check("the Editions shelf has two same-named pairs", #ed == 4 and ed[1].title == PP and ed[2].title == PP
        and ed[3].title == "Emma" and ed[4].title == "Emma", #ed)
    check("no path, not listed -> flat", Downloader.paths:dirFor(ed[1]) == "", Downloader.paths:dirFor(ed[1]))
    Downloader.enqueue(ed[1])
end, "download the first edition")
at(5, function()
    local ed = editions()
    local ok, got = downloaded_to(ed[1], FLAT_PP .. ".epub")
    check("the first lands flat as OpenShelf Check - Pride and Prejudice.epub", ok, got)
    check("the other shows no ✓: its target is (2)", not App.bookStatus(ed[2]).downloaded
        and Downloader.target(ed[2]) == FLAT_PP .. " (2).epub", Downloader.target(ed[2]))
    home():rebuild()
    Downloader.enqueue(ed[2])
end, "download the second edition")
at(5, function()
    local ok, got = downloaded_to(editions()[2], FLAT_PP .. " (2).epub")
    check("the second gets OpenShelf Check - Pride and Prejudice (2).epub", ok, got)
    check("…and the first keeps its own", (downloaded_to(editions()[1], FLAT_PP .. ".epub")))
    -- a same-named pair queued together: each target is worked out when its download starts
    Downloader.enqueue(editions()[3])
    Downloader.enqueue(editions()[4])
    check("the Emma pair is queued together", Downloader.state(editions()[4]) ~= nil)
end, "queue the Emma pair together")
at(8, function()
    local ok3, got3 = downloaded_to(editions()[3], FLAT_EMMA .. ".epub")
    local ok4, got4 = downloaded_to(editions()[4], FLAT_EMMA .. " (2).epub")
    check("queued together: Name and Name (2)", ok3 and ok4, tostring(got3) .. " | " .. tostring(got4))
    home():rebuild()
end, "both pairs")
at(2, function() shot("home-editions-downloaded"); home():openMyBooks() end, "My books")
at(2, function()
    local recs = demo_records()
    local all_there = #recs == 6
    for __, r in ipairs(recs) do
        log("RECORD", r.title, r.path)
        all_there = all_there and (require("libs/libkoreader-lfs").attributes(r.path, "size") or 0) > 0
    end
    local listed = 0
    for __, list in pairs(top():buckets()) do
        for ___, e in ipairs(list) do
            if e.provider == "folders_demo" then listed = listed + 1 end
        end
    end
    check("My books records all six, each file on disk", all_there, #recs)
    check("…and lists them", listed == 6, listed)
    shot("mybooks")
    local ls = io.popen("cd '" .. ROOT .. "' && ls -R")
    for line in ls:lines() do log("LS", line) end
    ls:close()
end, "My books")
-- 13. Download all (#20, §12.8): footer button on a two-page folder, Cancel
-- downloads, hold on a folder row in search, skipping files on the device
local function confirm_box()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w.ok_callback and w.text then return w end
    end
end
local function info_text()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w.text and not w.ok_callback and w.timeout then return w.text, w end
    end
end
local function press_ok()
    local box = confirm_box()
    UIManager:close(box)
    box.ok_callback()
end
local function footer_hit(view, width)   -- the footer's Download all: the only hit that wide
    for __, h in ipairs(view.hits) do
        if h.w == width then return h end
    end
end
local function hold(view, hit)
    view:onHold(nil, { pos = { x = hit.x + math.floor(hit.w / 2), y = hit.y + math.floor(hit.h / 2) } })
end
local function big_files(v)
    local t = {}
    for __, e in ipairs(v.entries) do
        if e.action ~= "folder" then t[#t + 1] = e end
    end
    return t
end
at(1, function()
    top():close()   -- My books
    local big
    for __, e in ipairs(Browse.get("folders_demo:courses") or {}) do
        if e.title == "Big folder" then big = e end
    end
    App.openEntry(big, home())
end, "open Big folder from the shelf")
at(2, function()
    local v = top()
    v.page = v.total_pages   -- Load more shows on the last page
    v:rebuild()
    local labels = {}
    for i, b in ipairs(v:footerButtons()) do labels[i] = b.text end
    check("a two-page folder: page 1 of 50 rows, the footer offers Download all and Load more",
        v.title == "Big folder" and #v.entries == 50 and table.concat(labels, ",") == "Download all,Load more",
        table.concat(labels, ","))
    UIManager:forceRePaint()
    shot("big-folder-footer")
    tap(v, footer_hit(v, Screen:scaleBySize(150)))
end, "tap Download all")
at(2, function()
    local box = confirm_box()
    check("Download all fetched page 2 and asks: Download 60 files (58 KB)?",
        box and box.text == "Download 60 files (58 KB)?", box and box.text)
    local copy = Folders.cache():open("folders_demo", { folder = "emu-big" })
    check("…the page it fetched is cached (counts as opening)", copy and copy.pages == 2, copy and copy.pages)
    check("…and joins the view", #top().entries == 60, #top().entries)
    shot("download-all-confirm")
    press_ok()
    local v, n, right = top(), 0, 0
    for i, e in ipairs(big_files(v)) do
        if Downloader.state(e) then n = n + 1 end
        if Downloader.target(e) == ("%s/Folders demo/Big folder/Handout %02d.epub"):format(ROOT, i) then right = right + 1 end
    end
    check("every file queued once", n == 60, n)
    check("…each to the folder's directory", right == 60, right)
    local labels = {}
    for i, b in ipairs(v:footerButtons()) do labels[i] = b.text end
    check("the button reads Cancel downloads", labels[1] == "Cancel downloads", labels[1])
    v:rebuild()
    UIManager:forceRePaint()
    shot("cancel-downloads")
    tap(v, footer_hit(v, Screen:scaleBySize(150)))
    local left = 0
    for __, e in ipairs(big_files(v)) do
        if Downloader.state(e) then left = left + 1 end
    end
    check("Cancel downloads empties the queue", left == 0, left)
    check("…and leaves no empty directory behind",
        require("libs/libkoreader-lfs").attributes(ROOT .. "/Folders demo/Big folder") == nil)
    check("…and the button is Download all again", v:footerButtons()[1].text == "Download all", v:footerButtons()[1].text)
end, "confirm, then cancel")
at(1, function()
    top():close()
    home():startSearch("week 2")
end, "search for Week 2")
at(3, function()
    local h = home()
    local row_hit
    for __, hit in ipairs(h.hits) do
        if hit.w == h.screen_w then row_hit = hit; break end   -- the first result row: the Week 2 folder
    end
    shot("search-week2-folder")
    hold(h, row_hit)
end, "hold on the Week 2 folder row")
at(2, function()
    local box = confirm_box()
    check("hold on a folder row in search: Download 1 file (287 KB)?", box and box.text == "Download 1 file (287 KB)?",
        box and box.text)
    shot("hold-confirm")
    press_ok()
end, "confirm the hold")
at(6, function()
    local path = ROOT .. "/Folders demo/Literature 101/Week 2/Frankenstein.epub"
    check("…downloads where it would from the opened folder", (require("libs/libkoreader-lfs").attributes(path, "size") or 0) > 0,
        path)
    home():goHome()
    open_chip()
end, "Frankenstein")
at(2, function() top():openEntry(row_named("Literature 101")) end, "Literature 101")
at(2, function()
    local week1
    for __, hit in ipairs(top().hits) do
        if hit.w == top().screen_w and not week1 then week1 = hit end   -- the first row: Week 1
    end
    hold(top(), week1)
end, "hold on Week 1 (Pride and Prejudice on the device)")
at(2, function()
    local box = confirm_box()
    check("files on the device are skipped: Download 1 file (483 KB)?", box and box.text == "Download 1 file (483 KB)?",
        box and box.text)
    press_ok()
end, "confirm Emma")
at(6, function()
    local path = ROOT .. "/Folders demo/Literature 101/Week 1/Emma.epub"
    check("…Emma lands beside it", (require("libs/libkoreader-lfs").attributes(path, "size") or 0) > 0, path)
    top():close()
    top():openEntry(row_named("Literature 201"))
end, "Literature 201")
at(2, function()
    local week1
    for __, hit in ipairs(top().hits) do
        if hit.w == top().screen_w and not week1 then week1 = hit end
    end
    hold(top(), week1)
end, "hold on Literature 201's Week 1 (all on the device)")
at(2, function()
    local text = info_text()
    check("nothing left -> a short message, no confirm", text == "Nothing to download in this folder." and not confirm_box(),
        text)
    shot("nothing-to-download")
    local ls = io.popen("cd '" .. ROOT .. "' && ls -R")
    for line in ls:lines() do log("LS2", line) end
    ls:close()
    UIManager:close(select(2, info_text()))
    while #App.views > 1 do top():close() end
    local stuck
    for __, e in ipairs(Browse.get("folders_demo:courses") or {}) do
        if e.title == "Stuck folder" then stuck = e end
    end
    App.holdDownload(stuck, home())
end, "hold on a folder whose provider ignores page")
at(3, function()
    local box = confirm_box()
    check("a provider that ignores page ends the listing: Download 3 files? (no sizes -> the count only)",
        box and box.text == "Download 3 files?", box and box.text)
    check("…and the folder is not left Listing…", require("download_all").busy("folders_demo", { locator = { folder = "emu-stuck" } }) == nil)
    local copy = Folders.cache():open("folders_demo", { folder = "emu-stuck" })
    check("…and the repeated page is not cached", copy and copy.pages == 1, copy and copy.pages)
    if box then UIManager:close(box) end
end, "stuck folder")
at(1, function()
    local Library = require("library")
    local path = ROOT .. "/Folders demo/Literature 101/Week 1/Pride and Prejudice.epub"
    local rec = App.library():findByPath(path)
    local st = rec and App.bookStatus(Library.toEntry(rec))
    check("the record's entry finds its file", st and st.path == path, st and st.path)
    set_builtins(true)
    App.openBook(st.path)
end, "open a folder file")
at(5, function()
    local reader = require("apps/reader/readerui").instance
    local file = reader and reader.document and reader.document.file
    check("it opens in the reader", file == ROOT .. "/Folders demo/Literature 101/Week 1/Pride and Prejudice.epub", file)
    shot("reader-folder-file")
end, "reader")
at(1, function() set_builtins(true); log("done"); os.exit(0) end, "exit")
run(1)
