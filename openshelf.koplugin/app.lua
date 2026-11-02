--[[
Shared application context for the views: the library singleton, the stack of
open OpenShelf screens (so "X" can leave the whole app), book status lookups,
the one tap dispatcher (a folder row opens a folder view, any other row its
detail page) and the "open this file in the reader" helper.
--]]
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local CloseRefresh = require("openshelf_closerefresh")
local Collection = require("collection")
local Covers = require("covers")
local Downloader = require("downloader")
local JsonFile = require("jsonfile")
local Library = require("library")
local logger = require("logger")

local App = {}

App.views = {}

function App.push(view)
    App.views[#App.views + 1] = view
end

function App.pop(view)
    for i = #App.views, 1, -1 do
        if App.views[i] == view then table.remove(App.views, i) end
    end
end

-- Close every OpenShelf screen (the title-bar X on any of them).
function App.exitAll()
    local views = App.views
    App.views = {}
    for i = #views, 1, -1 do
        UIManager:close(views[i])
    end
end

function App.homeView()
    return App.views[1]
end

-- Close every OpenShelf screen above `view` (top first): the folder title
-- menu's jump to an ancestor. Each close queues its full refresh; UIManager
-- merges them into one. Nothing happens when `view` is not open.
function App.closeAbove(view)
    local open = false
    for __, v in ipairs(App.views) do
        if v == view then open = true end
    end
    if not open then return end
    for i = #App.views, 1, -1 do
        local v = App.views[i]
        if v == view then return end
        v:close()
    end
end

---------------------------------------------------------------------------
-- Library singleton (My books)
---------------------------------------------------------------------------
local library

function App.library()
    if not library then
        local path = DataStorage:getSettingsDir() .. "/openshelf_library.json"
        library = Library.new{
            load = function() return JsonFile.read(path) end,
            save = function(d) JsonFile.write(path, d) end,
            -- v0.5 file: keep the original beside the rewritten one (decision 38)
            backup = function(d)
                JsonFile.write(path .. ".v1.bak", d)
                logger.info("OpenShelf: library migrated to v2; v1 kept at", path .. ".v1.bak")
            end,
        }
    end
    return library
end

local function file_size(path)
    if not path then return nil end
    local size = lfs.attributes(path, "size")
    if size and size > 0 then return size end
    return nil
end

--- Where an entry stands on this device.
-- { downloaded = bool, path = string|nil, missing = bool, record = rec|nil, dl = Downloader state|nil }
-- A folder row is never on the device (no record, no file, no ✓).
function App.bookStatus(entry)
    local Entry = require("entry")
    if entry.action == Entry.ACTION.FOLDER then return { downloaded = false, missing = false } end
    -- ✓ = a file at the entry's target (DESIGN.md §12.8, Paths:status)
    local st = Downloader.paths:status(entry, Downloader.dirPath(), App.library(), file_size)
    return {
        downloaded = st.downloaded,
        path = st.downloaded and st.target or nil,
        missing = st.missing,
        record = st.record,
        dl = Downloader.state(entry),
    }
end

--- Downloader.on_complete: record the book and add it to the KOReader collection.
function App.recordDownload(entry, path)
    local cover_file
    if entry.cover_url and Covers.isCached(entry.cover_url) then
        cover_file = Covers.fileFor(entry.cover_url)
    end
    App.library():add(entry, path, cover_file)
    Collection.add(path)
    logger.info("OpenShelf: downloaded", path)
end

function App.removeFromLibrary(rec)
    App.library():remove(rec.id)
    if rec.path then Collection.remove(rec.path) end
end

---------------------------------------------------------------------------
-- Shared view helpers
---------------------------------------------------------------------------

--- Tap on a row anywhere (results, See all, shelves, My books, folder
--- views): a folder row opens its folder view, never a detail page; any
--- other row opens view:openDetail. `parent` is the folder view the row was
--- listed in (nil elsewhere).
function App.openEntry(entry, view, parent)
    local Entry = require("entry")
    if entry.action == Entry.ACTION.FOLDER then
        App.openFolder{ provider_id = entry.provider, folder = entry, title = entry.title, parent = parent }
        return
    end
    view:openDetail(entry)
end

--- Open a folder view over the top screen: opts = { provider_id, title,
--- folder = the row (nil for a root), parent = the folder view it was listed
--- from }. A folder listed before opens from its cached copy, online or off
--- (DESIGN.md §12.6); one never listed asks for Wi-Fi, like search.
function App.openFolder(opts)
    local function show()
        local FolderView = require("view_folder")
        UIManager:show(FolderView:new{
            provider_id = opts.provider_id, title = opts.title,
            folder = opts.folder, parent = opts.parent,
        })
    end
    local Folders = require("openshelf_folders")
    if Folders.cache():has(opts.provider_id, opts.folder and opts.folder.locator) then return show() end
    require("ui/network/manager"):runWhenOnline(show)
end

--- Scoped search results over the top screen (DESIGN.md §12.7): opts = {
--- provider_id, folder = the row searched (nil for a root), folder_title,
--- query }. Needs Wi-Fi, like search; never cached.
function App.openSearchIn(opts)
    local _ = require("gettext")
    local T = require("ffi/util").template
    require("ui/network/manager"):runWhenOnline(function()
        local SearchInView = require("view_search_in")
        UIManager:show(SearchInView:new{
            provider_id = opts.provider_id, folder = opts.folder, query = opts.query,
            title = T(_("“%1” in %2"), opts.query, opts.folder_title or ""),
        })
    end)
end

--- Long-press on a book anywhere: download it straight away (DESIGN.md 8/32);
--- on a folder row: Download all into that row's directory (decision 82),
--- so a folder found by search downloads where it would when opened.
function App.holdDownload(entry, view)
    local InfoMessage = require("ui/widget/infomessage")
    local NetworkMgr = require("ui/network/manager")
    local _ = require("gettext")
    local Entry = require("entry")
    if entry.action == Entry.ACTION.FOLDER then
        require("download_all").start{
            provider_id = entry.provider, folder = entry, dir = Downloader.paths:dirFor(entry),
        }
        return
    end
    -- Buy rows have nothing to download: hold opens the detail page with the
    -- store URL + QR instead (decision 49).
    if entry.action == Entry.ACTION.BUY then
        if view and view.openDetail then view:openDetail(entry) end
        return
    end
    local st = App.bookStatus(entry)
    if st.downloaded then
        UIManager:show(InfoMessage:new{ text = _("Already on this device. Tap the book to open it."), timeout = 2 })
        return
    end
    if st.dl then return end
    NetworkMgr:runWhenOnline(function()
        Downloader.enqueue(entry)
        if view then view:rebuild() end
    end)
end

--- Throttle progress repaints: at most every 3 % (or every 2 s when the size
--- is unknown), so e-ink isn't refreshed on every poll tick.
function App.progressWorthRepaint(view, entry, state)
    view._progress_seen = view._progress_seen or {}
    local Entry = require("entry")
    local id = Entry.id(entry)
    local pct = -1
    if state and state.total and state.total > 0 then
        pct = math.floor(100 * (state.done or 0) / state.total)
    end
    local seen = view._progress_seen[id]
    local now = os.time()
    if pct >= 0 then
        if seen and seen.pct and math.abs(pct - seen.pct) < 3 then return false end
    elseif seen and seen.at and now - seen.at < 2 then
        return false
    end
    view._progress_seen[id] = { pct = pct, at = now }
    return true
end

--- "Remove from My books" prompt. on_done() runs after removal.
function App.removeDialog(entry, on_done)
    local ButtonDialog = require("ui/widget/buttondialog")
    local _ = require("gettext")
    local rec = App.library():find(entry)
    if not rec then return end
    local dialog
    dialog = ButtonDialog:new{
        title = rec.title or "",
        buttons = {
            { {
                text = _("Remove from My books"),
                callback = function()
                    UIManager:close(dialog)
                    App.removeFromLibrary(rec)
                    if on_done then on_done() end
                end,
            } },
            { {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            } },
        },
    }
    UIManager:show(dialog)
end

--- Leave OpenShelf and open the file in the reader.
function App.openBook(path)
    -- the reader does its own full refresh: closing the views mustn't add one
    CloseRefresh.leavingForBook(App.exitAll)
    UIManager:nextTick(function()
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(path)
    end)
end

return App
