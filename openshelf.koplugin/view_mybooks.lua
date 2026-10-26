--[[
My books (DESIGN.md §2.5): three shelves by reading status from KOReader's
own sidecars — Reading now (with progress), Not started, Finished. Missing
files stay listed, dimmed; hold offers removal.
--]]
local UIManager = require("ui/uimanager")
local Size = require("ui/size")
local Screen = require("device").screen
local _ = require("gettext")

local App = require("app")
local Collection = require("collection")
local Covers = require("covers")
local Downloader = require("downloader")
local Library = require("library")
local Shelf = require("widget_shelf")
local ViewBase = require("view_base")
local P = require("uiparts")

local MyBooksView = ViewBase:extend{
    on_change = nil,
}

local SECTIONS = {
    { key = "reading",  title = _("Reading now") },
    { key = "new",      title = _("Not started") },
    { key = "finished", title = _("Finished") },
}

function MyBooksView:setup()
    self.wanted_covers = {}
    self.dl_listener = function(event) if event ~= "progress" then self:rebuild() end end
    Downloader.subscribe(self.dl_listener)
    App.push(self)
end

function MyBooksView:teardown()
    Downloader.unsubscribe(self.dl_listener)
    if self.cover_job then self.cover_job:cancel(); self.cover_job = nil end
    App.pop(self)
end

function MyBooksView:titleBarSpec()
    return {
        title = _("My books"),
        left_icon = "chevron.left",
        on_left = function() UIManager:close(self) end,
    }
end

function MyBooksView:onExit()
    App.exitAll()
end

function MyBooksView:onPageBuilt()
    local urls = self.wanted_covers or {}
    if self.cover_job or #urls == 0 then return end
    self.cover_job = Covers.fetch(urls, function(got)
        self.cover_job = nil
        if #got > 0 then self:rebuild() end
    end)
end

-- Bucket every record by KOReader's reading status.
function MyBooksView:buckets()
    local buckets = { reading = {}, new = {}, finished = {} }
    local info = {}
    for __, rec in ipairs(App.library():all()) do
        local entry = Library.toEntry(rec)
        local st = Collection.status(rec.path)
        local key = Collection.bucket(st.status)
        buckets[key][#buckets[key] + 1] = entry
        info[rec.id] = { percent = st.percent, bucket = key }
    end
    return buckets, info
end

function MyBooksView:buildRows()
    local rows = {}
    local urls = {}
    local buckets, info = self:buckets()
    local any = false
    for __, section in ipairs(SECTIONS) do
        local entries = buckets[section.key]
        if #entries > 0 then
            any = true
            local shelf_rows = Shelf.rows(self, {
                title = section.title, entries = entries,
                on_see_all = function() self:openList(section.title, entries) end,
                on_tap = function(e) self:openDetail(e) end,
                on_hold = function(e) self:removeDialog(e) end,
                status = function(e)
                    local st = App.bookStatus(e)
                    local i = st.record and info[st.record.id]
                    if section.key == "reading" then
                        st.progress = (i and i.percent) or 0
                    end
                    return st
                end,
            })
            for ___, r in ipairs(shelf_rows) do rows[#rows + 1] = r end
            for ___, e in ipairs(Shelf.visible(self, entries)) do
                if e.cover_url then urls[#urls + 1] = e.cover_url end
            end
        end
    end
    if not any then
        local h = Screen:scaleBySize(80)
        rows[#rows + 1] = {
            widget = P.row(self.screen_w, h, P.text(_("Nothing downloaded yet. Books you download appear here."), 15,
                { color = P.DARK_GRAY, max_width = self.screen_w - 2 * Size.padding.default })),
            h = h, hits = {},
        }
    end
    self.wanted_covers = urls
    return rows
end

function MyBooksView:openDetail(entry)
    local DetailView = require("view_detail")
    UIManager:show(DetailView:new{ entry = entry, on_change = function() self:refresh() end })
end

function MyBooksView:openList(title, entries)
    local ListView = require("view_list")
    UIManager:show(ListView:new{
        title = title, entries = entries, allow_remove = true,
        on_change = function() self:refresh() end,
    })
end

function MyBooksView:removeDialog(entry)
    App.removeDialog(entry, function() self:refresh() end)
end

function MyBooksView:refresh()
    self:rebuild()
    if self.on_change then self.on_change() end
end

return MyBooksView
