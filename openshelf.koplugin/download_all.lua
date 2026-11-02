--[[
Download all (DESIGN.md §12.8, decision 82, ticket #20): the files directly
in one folder, not its subfolders, queued on the one-at-a-time download
queue. The folder view's footer button and hold on a folder row anywhere
(App.holdDownload) start it.

  DownloadAll.start{ provider_id, folder = row|nil (root), dir = its directory, on_change = fn|nil }
  DownloadAll.busy(provider_id, folder)   -> "loading" | "queued" | nil
  DownloadAll.cancel(provider_id, folder)

It needs every row of the folder: the cached pages (this counts as opening
the folder), then the rest fetched one job per page under the 60 s
deadline and cached as they arrive. Files already on the device or on
their way, buy rows and subfolders are skipped (Folders.downloadable). The
confirm says how many files, and how big when every row has a size;
nothing left → a short message instead. The rows are stamped with the
folder's directory, so each file goes to its #19 target (its record's path,
else its own path, else this directory), worked out as its download starts:
two same-named files get Name and Name (2). While files it queued are
queued or downloading, busy() says "queued" and the footer offers Cancel
downloads.
--]]
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local App = require("app")
local Downloader = require("downloader")
local Entry = require("entry")
local FolderCache = require("openshelf_foldercache")
local Folders = require("openshelf_folders")
local Jobs = require("jobs")
local P = require("uiparts")

local DownloadAll = {}

local loading = {}   -- folder key -> true while its pages are fetched
local queued = {}    -- folder key -> the rows Download all queued

local function key(id, folder)
    return FolderCache.key(id, folder and folder.locator)
end

-- Every row of a folder: its cached pages, then the rest, each fetched in a
-- job and cached. A page that adds no row not seen yet ends it even if it
-- says has_more (a provider that ignores `page` would list forever).
local function load_all(id, locator, on_done, on_error)
    local cache = Folders.cache()
    local copy = cache:open(id, locator)
    local rows, seen = {}, {}
    local function add(entries)
        local added = 0
        for __, e in ipairs(entries) do
            local eid = Entry.id(e)
            if not seen[eid] then
                seen[eid] = true
                rows[#rows + 1] = e
                added = added + 1
            end
        end
        return added
    end
    add(copy and copy.entries or {})
    local page, has_more = copy and copy.pages or 0, not copy or copy.has_more
    local function step()
        if not has_more then return on_done(rows) end
        local p = page + 1
        Jobs.runPage(Folders.pageTask(id, locator, p), function(entries, more)
            cache:putPage(id, locator, p, entries, more)
            local added = add(entries)
            page, has_more = p, more and added > 0
            step()
        end, on_error)
    end
    step()
end

function DownloadAll.busy(id, folder)
    local k = key(id, folder)
    if loading[k] then return "loading" end
    for __, e in ipairs(queued[k] or {}) do
        if Downloader.state(e) then return "queued" end
    end
    queued[k] = nil
    return nil
end

-- The queued ones first: cancelling the active download starts the next.
function DownloadAll.cancel(id, folder)
    local k = key(id, folder)
    local rows = queued[k] or {}
    queued[k] = nil
    local active
    for __, e in ipairs(rows) do
        local st = Downloader.state(e)
        if st and st.status == "active" then active = e elseif st then Downloader.cancel(e) end
    end
    if active then Downloader.cancel(active) end
end

local function confirm_text(n, size)
    if size then
        return T(N_("Download 1 file (%2)?", "Download %1 files (%2)?", n), n, P.friendlySize(size))
    end
    return T(N_("Download 1 file?", "Download %1 files?", n), n)
end

function DownloadAll.start(opts)
    local id, folder = opts.provider_id, opts.folder
    local k = key(id, folder)
    local function changed()
        if opts.on_change then opts.on_change() end
    end
    if DownloadAll.busy(id, folder) then return end
    NetworkMgr:runWhenOnline(function()
        if loading[k] then return end
        loading[k] = true
        changed()
        load_all(id, folder and folder.locator, function(rows)
            loading[k] = nil
            local files, size = Folders.downloadable(Downloader.paths:stamped(rows, opts.dir), function(e)
                local st = App.bookStatus(e)
                return st.downloaded or st.dl ~= nil
            end)
            changed()
            if #files == 0 then
                UIManager:show(InfoMessage:new{ text = _("Nothing to download in this folder."), timeout = 3 })
                return
            end
            UIManager:show(ConfirmBox:new{
                text = confirm_text(#files, size),
                ok_text = _("Download"),
                ok_callback = function()
                    queued[k] = files
                    for __, e in ipairs(files) do Downloader.enqueue(e) end
                    changed()
                end,
            })
        end, function(err)
            loading[k] = nil
            changed()
            UIManager:show(InfoMessage:new{ text = T(_("Could not list this folder:\n%1"), err) })
        end)
    end)
end

return DownloadAll
