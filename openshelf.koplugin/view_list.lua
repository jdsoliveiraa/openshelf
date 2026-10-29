--[[
A full-screen list/grid of entries with paging: "See all" for a browse shelf
or a My books section. Tap → detail, hold → download (or, with
allow_remove, "Remove from My books").

A browse shelf passes `shelf_id` and page 1's `has_more` (ticket #12): the
last page then ends in "Load more", which fetches the shelf's next page in a
job (Jobs.DEADLINE) and appends it, like search results. A failure shows in
the toolbar (tap for the reason) and leaves Load more in place to retry.
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

function ListView:statusLine()
    local parts = { T(_("%1 books"), #self.entries) }
    if self.pager and self.pager.loading then
        parts[#parts + 1] = _("Loading more…")
    elseif self.pager and self.pager.err then
        parts[#parts + 1] = Glyphs.warning .. " " .. _("Load more failed")
    end
    return table.concat(parts, "  ·  ")
end

function ListView:showStatusDetail()
    if not (self.pager and self.pager.err) then return end
    UIManager:show(InfoMessage:new{
        text = T(_("Could not load more books:\n%1\n\nTap Load more to try again."), self.pager.err),
    })
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
        on_tap = function(e) self:openDetail(e) end,
        on_hold = function(e) self:hold(e) end,
    })
    self.total_pages = total
    if self.page > total then self.page = total end
    self.page_entries = page_entries
    for __, r in ipairs(prows) do rows[#rows + 1] = r end

    if #self.entries == 0 then
        local h = Screen:scaleBySize(60)
        rows[#rows + 1] = {
            widget = P.row(w, h, P.text(_("Nothing here yet."), 15, { color = P.DARK_GRAY })),
            h = h, hits = {},
        }
    end

    -- footer: page label, "Load more" on the last page while the shelf has more
    local label = total > 1 and T(_("Page %1 of %2"), self.page, total) or ""
    local items = { P.text(label, 13, { color = P.DARK_GRAY }) }
    local hits = {}
    if self.pager and self.pager.has_more and self.page == total then
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

--- Fetch the shelf's next page and append it. Lands on the page holding the
--- first new book: the same page when the last one had room (refreshed in
--- place, "ui"), else the next one (a page turn, "partial").
function ListView:loadMore()
    if not (self.pager and self.pager:canLoadMore()) then return end
    NetworkMgr:runWhenOnline(function()
        if self.closed then return end
        local page = self.pager:begin()
        if not page then return end
        self:rebuild()
        self.more_job = Browse.fetchPage(self.shelf_id, page, function(entries, has_more)
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
    end)
end

function ListView:toggleView()
    self.view_mode = self.view_mode == "grid" and "list" or "grid"
    self.page = 1
    self:rebuild("partial")
end

function ListView:openDetail(entry)
    local DetailView = require("view_detail")
    UIManager:show(DetailView:new{ entry = entry, on_change = function() self:refresh() end })
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
