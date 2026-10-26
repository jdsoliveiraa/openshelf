--[[
A full-screen list/grid of entries with paging: "See all" for a browse shelf
or a My books section. Tap → detail, hold → download (or, with
allow_remove, "Remove from My books").
--]]
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Size = require("ui/size")
local Screen = require("device").screen
local _ = require("gettext")
local T = require("ffi/util").template

local App = require("app")
local Covers = require("covers")
local Downloader = require("downloader")
local Entry = require("entry")
local Glyphs = require("glyphs")
local Pane = require("pane_results")
local Settings = require("settings")
local ViewBase = require("view_base")
local P = require("uiparts")

local ListView = ViewBase:extend{
    title = "",
    entries = nil,
    allow_remove = false,
    on_change = nil,
    self_paged = true,
}

function ListView:setup()
    self.entries = self.entries or {}
    self.view_mode = Settings.defaultView()
    self.page_entries = {}
    self.dl_listener = function(event, entry, state) self:onDownloadEvent(event, entry, state) end
    Downloader.subscribe(self.dl_listener)
    App.push(self)
end

function ListView:teardown()
    Downloader.unsubscribe(self.dl_listener)
    if self.cover_job then self.cover_job:cancel(); self.cover_job = nil end
    App.pop(self)
end

function ListView:titleBarSpec()
    return {
        title = self.title,
        left_icon = "chevron.left",
        on_left = function() UIManager:close(self) end,
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

function ListView:buildRows()
    local rows = {}
    local w, pad = self.screen_w, Size.padding.default
    local tb_h = Screen:scaleBySize(36)
    local btn_w = Screen:scaleBySize(44)
    local left_w = w - 2 * pad - btn_w - pad
    local toolbar = HorizontalGroup:new{
        align = "center",
        P.box(left_w, tb_h, P.text(T(_("%1 books"), #self.entries), 13, { color = P.DARK_GRAY, max_width = left_w })),
        P.hspace(pad),
        P.glyphButton(self.view_mode == "grid" and Glyphs.list or Glyphs.grid, btn_w, tb_h),
    }
    rows[#rows + 1] = {
        widget = P.row(w, tb_h, toolbar, { pad = pad, line = true }),
        h = tb_h,
        hits = { { x = w - pad - btn_w, w = btn_w, on_tap = function() self:toggleView() end } },
    }

    local footer_h = Screen:scaleBySize(40)
    local prows, total, page_entries = Pane.rows(self, self.entries, {
        mode = self.view_mode, page = self.page, avail_h = self.content_h - tb_h - footer_h,
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

    local label = total > 1 and T(_("Page %1 of %2"), self.page, total) or ""
    rows[#rows + 1] = {
        widget = P.row(w, footer_h, P.text(label, 13, { color = P.DARK_GRAY }), { pad = pad }),
        h = footer_h, hits = {},
    }
    return rows
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
