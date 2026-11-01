--[[
A full-screen list/grid of entries with paging: "See all" for a browse shelf
or a My books section. Tap → App.openEntry (detail, or a folder view for a
folder row), hold → download (or, with allow_remove, "Remove from My
books").

A browse shelf passes `shelf_id` and page 1's `has_more` (ticket #12): the
last page then ends in "Load more", which fetches the shelf's next page in a
job (Jobs.DEADLINE) and appends it, like search results. A failure shows in
the toolbar (tap for the reason) and leaves Load more in place to retry.

view_folder.lua builds the folder view on this list: it extends setup
(page 1 is fetched by the view) and overrides fetchPage (its pages come from
Catalog.list), countText, failedText, statusDetail, emptyRows and
openEntry, adds onTitleTap, and sets in_folder.
--]]
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Size = require("ui/size")
local Screen = require("device").screen
local _ = require("gettext")
local T = require("ffi/util").template

local App = require("app")
local Browse = require("browse")
local Covers = require("covers")
local Downloader = require("downloader")
local Entry = require("entry")
local Glyphs = require("glyphs")
local Pane = require("pane_results")
local Settings = require("settings")
local ShelfPager = require("shelf_pager")
local ViewBase = require("view_base")
local P = require("uiparts")

local ListView = ViewBase:extend{
    title = "",
    entries = nil,
    allow_remove = false,
    on_change = nil,
    shelf_id = nil,     -- browse shelf id: enables Load more
    has_more = false,   -- page 1's has_more (from the browse cache)
    in_folder = false,  -- a folder view: folder rows show no path
    self_paged = true,
}

function ListView:setup()
    self.entries = self.entries or {}
    if self.shelf_id then
        self.pager = ShelfPager.new{ entries = self.entries, has_more = self.has_more }
        self.entries = self.pager.entries
    end
    self.view_mode = Settings.defaultView()
    self.page_entries = {}
    self.dl_listener = function(event, entry, state) self:onDownloadEvent(event, entry, state) end
    Downloader.subscribe(self.dl_listener)
    App.push(self)
end

function ListView:teardown()
    Downloader.unsubscribe(self.dl_listener)
    if self.cover_job then self.cover_job:cancel(); self.cover_job = nil end
    if self.more_job then self.more_job:cancel(); self.more_job = nil end
    self.closed = true
    App.pop(self)
end

function ListView:titleBarSpec()
    return {
        title = self.title,
        left_icon = "chevron.left",
        on_left = function() self:close() end,
    }
end

function ListView:onExit()
    App.exitAll()
end

function ListView:onPageBuilt()
    local urls = Pane.coverUrls(self.page_entries)
    if self.cover_job or #urls == 0 then return end
    self.cover_job = Covers.fetch(urls, function(got)
        self.cover_job = nil
        if #got > 0 then self:rebuild() end
    end)
end

-- Toolbar and footer heights, and the pane height between them.
function ListView:geometry()
    local tb_h, footer_h = Screen:scaleBySize(36), Screen:scaleBySize(40)
    return tb_h, footer_h, self.content_h - tb_h - footer_h
end

function ListView:countText()
    return T(_("%1 books"), #self.entries)
end

function ListView:failedText()
    return Glyphs.warning .. " " .. _("Load more failed")
end

function ListView:statusLine()
    local parts = { self:countText() }
    if self.pager and self.pager.loading then
        parts[#parts + 1] = self.pager:loaded() and _("Loading more…") or _("Loading…")
    elseif self.pager and self.pager.err then
        parts[#parts + 1] = self:failedText()
    end
    return table.concat(parts, "  ·  ")
end

function ListView:statusDetail(err)
    return T(_("Could not load more books:\n%1\n\nTap Load more to try again."), err)
end

function ListView:showStatusDetail()
    if not (self.pager and self.pager.err) then return end
    UIManager:show(InfoMessage:new{ text = self:statusDetail(self.pager.err) })
end

-- What the pane shows when there are no rows.
function ListView:emptyRows()
    local h = Screen:scaleBySize(60)
    return { {
        widget = P.row(self.screen_w, h, P.text(_("Nothing here yet."), 15, { color = P.DARK_GRAY })),
        h = h, hits = {},
    } }
end

function ListView:buildRows()
    local rows = {}
    local w, pad = self.screen_w, Size.padding.default
    local tb_h, footer_h, avail_h = self:geometry()
    local btn_w = Screen:scaleBySize(44)
    local left_w = w - 2 * pad - btn_w - pad
    local toolbar = HorizontalGroup:new{
        align = "center",
        P.box(left_w, tb_h, P.text(self:statusLine(), 13, { color = P.DARK_GRAY, max_width = left_w })),
        P.hspace(pad),
        P.glyphButton(self.view_mode == "grid" and Glyphs.list or Glyphs.grid, btn_w, tb_h),
    }
    rows[#rows + 1] = {
        widget = P.row(w, tb_h, toolbar, { pad = pad, line = true }),
        h = tb_h,
        hits = {
            { x = 0, w = pad + left_w, on_tap = function() self:showStatusDetail() end },
            { x = w - pad - btn_w, w = btn_w, on_tap = function() self:toggleView() end },
        },
    }

    local prows, total, page_entries = Pane.rows(self, self.entries, {
        mode = self.view_mode, page = self.page, avail_h = avail_h,
        status = function(e) return App.bookStatus(e) end,
        on_tap = function(e) self:openEntry(e) end,
        on_hold = function(e) self:hold(e) end,
        in_folder = self.in_folder,
    })
    self.total_pages = total
    if self.page > total then self.page = total end
    self.page_entries = page_entries
    for __, r in ipairs(prows) do rows[#rows + 1] = r end

    if #self.entries == 0 then
        for __, r in ipairs(self:emptyRows()) do rows[#rows + 1] = r end
    end

    -- footer: page label, "Load more" on the last page while the list has
    -- more (a folder's first page is fetched by the view, not the button)
    local label = total > 1 and T(_("Page %1 of %2"), self.page, total) or ""
    local items = { P.text(label, 13, { color = P.DARK_GRAY }) }
    local hits = {}
    if self.pager and self.pager.has_more and self.pager:loaded() and self.page == total then
        local bw, bh = Screen:scaleBySize(120), Screen:scaleBySize(32)
        local lw = items[1]:getSize().w
        items[#items + 1] = P.hspace(math.max(0, w - 2 * pad - lw - bw))
        if self.pager.loading then
            items[#items + 1] = P.box(bw, bh, P.text(_("Loading…"), 14, { color = P.DARK_GRAY }), "center")
        else
            items[#items + 1] = P.button(_("Load more"), bw, bh, { size = 14 })
            hits[#hits + 1] = { x = w - pad - bw, w = bw, on_tap = function() self:loadMore() end }
        end
    end
    rows[#rows + 1] = {
        widget = P.row(w, footer_h, HorizontalGroup:new{ align = "center", unpack(items) }, { pad = pad }),
        h = footer_h, hits = hits,
    }
    return rows
end

--- One page in a job: on_done(entries, has_more) / on_error(err). Returns
--- the job handle.
function ListView:fetchPage(page, on_done, on_error)
    return Browse.fetchPage(self.shelf_id, page, on_done, on_error)
end

--- Fetch the next page and append it.
function ListView:loadMore()
    if not (self.pager and self.pager:canLoadMore()) then return end
    NetworkMgr:runWhenOnline(function()
        if self.closed then return end
        local page = self.pager:begin()
        if not page then return end
        self:rebuild()
        self:fetch(page)
    end)
end

--- Fetch `page` (pager:begin() returned it) and append it. Lands on the page
--- holding the first new book: the same page when the last one had room
--- (refreshed in place, "ui"), else the next one (a page turn, "partial").
function ListView:fetch(page)
    self.more_job = self:fetchPage(page, function(entries, has_more)
        self.more_job = nil
        if self.closed then return end
        local n_old = #self.entries
        local added = self.pager:append(entries, has_more)
        local refresh = "ui"
        if added > 0 then
            local __, ___, avail_h = self:geometry()
            local target = Pane.pageOf(self, self.entries,
                { mode = self.view_mode, avail_h = avail_h }, self.entries[n_old + 1])
            if target and target ~= self.page then
                self.page = target
                refresh = "partial"
            end
        end
        self:rebuild(refresh)
    end, function(err)
        self.more_job = nil
        if self.closed then return end
        self.pager:fail(err)
        self:rebuild()
    end)
end

function ListView:toggleView()
    self.view_mode = self.view_mode == "grid" and "list" or "grid"
    self.page = 1
    self:rebuild("partial")
end

--- Tap on a row: a folder opens its folder view, anything else detail.
function ListView:openEntry(entry)
    App.openEntry(entry, self)
end

function ListView:openDetail(entry)
    require("view_detail").show(entry, function() self:refresh() end)
end

function ListView:refresh()
    self:rebuild()
    if self.on_change then self.on_change() end
end

function ListView:hold(entry)
    if self.allow_remove then
        App.removeDialog(entry, function()
            local kept = {}
            local id = Entry.id(entry)
            for __, e in ipairs(self.entries) do
                if Entry.id(e) ~= id then kept[#kept + 1] = e end
            end
            self.entries = kept
            self:refresh()
        end)
        return
    end
    App.holdDownload(entry, self)
end

function ListView:isOnPage(entry)
    local id = Entry.id(entry)
    for __, e in ipairs(self.page_entries or {}) do
        if Entry.id(e) == id then return true end
    end
    return false
end

function ListView:onDownloadEvent(event, entry, state)
    if not self:isOnPage(entry) then return end
    if event == "progress" then
        if App.progressWorthRepaint(self, entry, state) then self:rebuild() end
        return
    end
    if event == "error" then
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed: %1\n\n%2"), entry.title or "", state and state.err or ""),
        })
    end
    self:rebuild()
end

return ListView
