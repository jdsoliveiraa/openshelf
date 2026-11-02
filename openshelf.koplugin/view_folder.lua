--[[
A folder view (DESIGN.md §12.4, §12.6, decisions 72–73, 76, 83): one
full-screen view per folder, stacked over whatever opened it. It is the
paged See all list (view_list.lua) fed by the provider's list() instead of
browse: 50 rows per page, Load more for the rest, each page in a job under
the 60 s deadline.

  App.openFolder{ provider_id, title, folder = row|nil (root), parent = view|nil }

Offline first: a folder listed before opens from its cached copy
(Folders.cache(), openshelf_folders.json), online or off, and every page
fetched is cached. Once the copy is more than 24 h old the toolbar says
"Updated N d ago", and when Wi-Fi is already on the view refetches the
pages it holds in the background and repaints (it never turns Wi-Fi on for
that). A folder never listed is fetched from page 1 (App.openFolder asked
for Wi-Fi first).

Title = folder name; a tap on it lists the folder views this one was listed
from (root first, nearest last; picking one closes every view above it),
then Refresh, which forces that refetch. Back / chevron = up one level (the
list's on_left closes the view), X = leave OpenShelf. Toolbar `N items ·
Updated 3 d ago · ⚠ failed` (tap for the reason) and list/grid; no filter, a
folder has one source. Empty → "This folder is empty."; a failed first page
→ the provider's reason (PROVIDERS.md §5.5) under "Could not open this
folder." and Retry; a failed refresh keeps the cached rows and shows in the
toolbar.

The view keeps `folder` (the row it was opened from, nil for a root),
`parent` (the folder view it was listed from, if any) and `dir`, its
directory below OpenShelf/ (DESIGN.md §12.8): the root's is the provider's
name, a folder's is the one stamped on the row it was opened from (or
worked out from that row alone: search, shelves). Its rows are shown as
copies stamped with their own directories (Downloader.paths), so detail,
hold and Download all agree on where a file lands; the cache keeps them
unstamped, since the same folder reached another way may get another
directory.
--]]
local ButtonDialog = require("ui/widget/buttondialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Size = require("ui/size")
local Screen = require("device").screen
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local App = require("app")
local Catalog = require("catalog")
local Downloader = require("downloader")
local FolderCache = require("openshelf_foldercache")
local Folders = require("openshelf_folders")
local Glyphs = require("glyphs")
local Jobs = require("jobs")
local ListView = require("view_list")
local ShelfPager = require("shelf_pager")
local P = require("uiparts")

local FolderView = ListView:extend{
    provider_id = nil,
    folder = nil,       -- the folder row this view was opened from; nil = the root
    parent = nil,       -- the folder view it was listed from, if any
    dir = nil,          -- its directory below OpenShelf/ (set in setup)
    in_folder = true,
}

function FolderView:locator()
    return self.folder and self.folder.locator
end

function FolderView:setup()
    ListView.setup(self)
    local paths = Downloader.paths
    if self.folder then
        self.dir = paths:dirFor(self.folder)
    else
        local p = Catalog.byId(self.provider_id)
        self.dir = paths:rootDir(p and p.name or self.provider_id)
    end
    local copy = Folders.cache():open(self.provider_id, self:locator())
    if not copy then
        self.pager = ShelfPager.new{ page = 0, has_more = true }
        self.entries = self.pager.entries
        self:fetch(self.pager:begin())
        return
    end
    self:showCopy(copy)
    if FolderCache.staleDays(copy.at, os.time()) and NetworkMgr:isConnected() then self:reload() end
end

-- The cached copy becomes the view's rows: every page it holds, so Load
-- more goes on from its last one.
function FolderView:showCopy(copy)
    self.pager = ShelfPager.new{ entries = Downloader.paths:stamped(copy.entries, self.dir),
        has_more = copy.has_more, page = copy.pages }
    self.entries = self.pager.entries
    self.updated_at = copy.at
end

-- One page of this folder in a job, not cached.
function FolderView:runPage(page, on_done, on_error)
    return Jobs.runPage(Folders.pageTask(self.provider_id, self:locator(), page), on_done, on_error)
end

-- A page for the list (the first one, Load more, Retry): cached as it
-- arrives, shown stamped.
function FolderView:fetchPage(page, on_done, on_error)
    return self:runPage(page, function(entries, has_more)
        Folders.cache():putPage(self.provider_id, self:locator(), page, entries, has_more)
        on_done(Downloader.paths:stamped(entries, self.dir), has_more)
    end, on_error)
end

function FolderView:fetch(page)
    self.reload_failed = false
    ListView.fetch(self, page)
end

--- Fetch again every page the view holds (Refresh, or a stale copy while
--- Wi-Fi is on), one job per page. The rows and the cached copy are
--- replaced only once every page arrived; a failure keeps the rows and
--- shows in the toolbar. The caller repaints (setup's first build does).
function FolderView:reload()
    if self.pager.loading then return end
    local want, pages = math.max(1, self.pager.page), {}
    self.pager.loading, self.pager.err = true, nil   -- no Load more meanwhile
    self.reloading, self.reload_failed = true, false
    local function step(page)
        self.more_job = self:runPage(page, function(entries, has_more)
            self.more_job = nil
            if self.closed then return end
            pages[page] = { entries = entries, has_more = has_more }
            if has_more and page < want then return step(page + 1) end
            Folders.cache():putPages(self.provider_id, self:locator(), pages)
            self.reloading = false
            self:showCopy(Folders.cache():open(self.provider_id, self:locator()))
            self:rebuild()
        end, function(err)
            self.more_job = nil
            if self.closed then return end
            self.reloading, self.reload_failed = false, true
            self.pager:fail(err)
            self:rebuild()
        end)
    end
    step(1)
end

function FolderView:countText()
    local n = #self.entries
    return T(N_("1 item", "%1 items", n), n)
end

function FolderView:statusParts()
    local parts = { self:countText() }
    local days = self.updated_at and FolderCache.staleDays(self.updated_at, os.time())
    if days then parts[2] = T(_("Updated %1 d ago"), days) end
    return parts
end

function FolderView:loadingText()
    if self.reloading then return _("Refreshing…") end
    return ListView.loadingText(self)
end

function FolderView:failedText()
    return Glyphs.warning .. " " .. _("failed")
end

function FolderView:statusDetail(err)
    if not self.pager:loaded() then
        return T(_("Could not open this folder:\n%1\n\nTap Retry to try again."), err)
    end
    if self.reload_failed then
        return T(_("Could not refresh this folder:\n%1\n\nThese are the rows saved the last time it was listed. Refresh is in the title menu."), err)
    end
    return T(_("Could not load more of this folder:\n%1\n\nTap Load more to try again."), err)
end

function FolderView:emptyRows()
    local w, pad = self.screen_w, Size.padding.default
    local h = Screen:scaleBySize(60)
    local function line(text)
        return {
            widget = P.row(w, h, P.text(text, 15, { color = P.DARK_GRAY, max_width = w - 2 * pad })),
            h = h, hits = {},
        }
    end
    if self.pager:loaded() then return { line(_("This folder is empty.")) } end
    if not self.pager.err then return { line(_("Loading…")) } end
    local reason = P.textBox(self.pager.err, 14, w - 2 * pad, Screen:scaleBySize(66), { color = P.DARK_GRAY })
    local reason_h = reason:getSize().h + pad
    local bw, bh = Screen:scaleBySize(120), Screen:scaleBySize(36)
    local bh_row = bh + 2 * pad
    return {
        line(_("Could not open this folder.")),
        { widget = P.row(w, reason_h, reason), h = reason_h, hits = {} },
        {
            widget = P.row(w, bh_row, P.button(_("Retry"), bw, bh, { size = 15 }), { align = "center" }),
            h = bh_row,
            hits = { { x = math.floor((w - bw) / 2), w = bw, on_tap = function() self:loadMore() end } },
        },
    }
end

-- Rows listed here open their folders on top, with this view as their parent.
function FolderView:openEntry(entry)
    App.openEntry(entry, self, self)
end

-- The title menu: the folder views below this one (picking one closes
-- every view above it), then Refresh.
function FolderView:onTitleTap()
    local dialog
    local buttons = {}
    for __, v in ipairs(Folders.ancestors(self)) do
        buttons[#buttons + 1] = { {
            text = Glyphs.folder .. "  " .. (v.title or ""),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                App.closeAbove(v)
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = Glyphs.refresh .. "  " .. _("Refresh"),
        align = "left",
        callback = function()
            UIManager:close(dialog)
            NetworkMgr:runWhenOnline(function()
                if self.closed or self.pager.loading then return end
                self:reload()
                self:rebuild()
            end)
        end,
    } }
    dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(dialog)
end

return FolderView
