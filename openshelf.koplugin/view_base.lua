--[[
Base class for OpenShelf's full-screen views (home, detail, My books, lists).

A view is a stack of rows. Each row is { widget, h, hits } where `hits` lists
tappable spans ({ x, w, on_tap, on_hold }; x/w optional = full width). The base
stacks the rows under a TitleBar, records every hit's absolute rectangle, and
hit-tests taps/holds against them — no reliance on per-child dimen propagation.

Rows that don't fit go to the next page (swipe or page keys), unless the
subclass sets `self_paged = true` and does its own slicing (then it sets
`self.total_pages`).

Subclasses implement:
  setup()          -- after init fields, before the first build (optional)
  titleBarSpec()   -- { title, subtitle, left_icon, on_left }
  buildRows()      -- the rows for the current page
  onTitleTap()     -- tap on the title text (optional)
  onPageBuilt()    -- after a page is laid out (optional; e.g. prefetch covers)
  teardown()       -- on close (optional)
  onBack()         -- Back key / left arrow default; onExit() -- title-bar X
--]]
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TitleBar = require("ui/widget/titlebar")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = Device.screen

local ViewBase = InputContainer:extend{
    covers_fullscreen = true,
    self_paged = false,
    page = 1,
    total_pages = 1,
}

function ViewBase:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.hits = {}
    self.pages = { { first = 1, last = 0 } }

    -- Title bars never carry a subtitle, so their height is constant: measure once.
    local probe = TitleBar:new{ width = self.screen_w, title = "x",
        with_bottom_line = true, show_parent = self }
    self.title_bar_h = probe:getHeight()
    probe:free()
    self.content_top = self.title_bar_h
    self.footer_h = Screen:scaleBySize(26)   -- page indicator for auto-paged views
    self.content_h = self.screen_h - self.title_bar_h

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextPage = { { Device.input.group.PgFwd } },
            PrevPage = { { Device.input.group.PgBack } },
        }
    end
    self.ges_events = {
        Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
        Hold  = { GestureRange:new{ ges = "hold",  range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }

    if self.setup then self:setup() end
    self:rebuild()
end

function ViewBase:_titleBar()
    local spec = self.titleBarSpec and self:titleBarSpec() or {}
    return TitleBar:new{
        width = self.screen_w,
        title = spec.title or "",
        title_shrink_font_to_fit = true,
        with_bottom_line = true,
        left_icon = spec.left_icon,
        left_icon_tap_callback = function()
            if spec.on_left then spec.on_left() else self:onBack() end
        end,
        close_callback = function() self:onExit() end,
        show_parent = self,
    }
end

--- Lay the current page out again. refresh = "ui" (default) | "partial" (page turns).
function ViewBase:rebuild(refresh)
    if self[1] and self[1].free then self[1]:free() end
    self.hits = {}

    local rows = self:buildRows() or {}

    if self.self_paged then
        self.pages = { { first = 1, last = #rows } }
    else
        -- auto-paging keeps a slim footer for the page indicator
        local avail = self.content_h - self.footer_h
        self.pages = {}
        local i = 1
        while i <= #rows do
            local start_i, acc = i, 0
            while i <= #rows do
                local h = rows[i].h
                if acc + h > avail and i > start_i then break end
                acc = acc + h
                i = i + 1
            end
            -- keep a header with the row that follows it
            if i <= #rows and i - 1 > start_i and rows[i - 1].keep_with_next then
                i = i - 1
            end
            self.pages[#self.pages + 1] = { first = start_i, last = i - 1 }
        end
        if #self.pages == 0 then self.pages = { { first = 1, last = 0 } } end
        self.total_pages = #self.pages
        if self.page > self.total_pages then self.page = self.total_pages end
        if self.page < 1 then self.page = 1 end
    end

    local pg = self.self_paged and self.pages[1] or self.pages[self.page]
    local content = VerticalGroup:new{ align = "left" }
    local y = self.content_top
    for r = pg.first, pg.last do
        local row = rows[r]
        table.insert(content, row.widget)
        for __, hit in ipairs(row.hits or {}) do
            self.hits[#self.hits + 1] = {
                x = hit.x or 0, y = y, w = hit.w or self.screen_w, h = row.h,
                on_tap = hit.on_tap, on_hold = hit.on_hold,
            }
        end
        y = y + row.h
    end
    if not self.self_paged and #self.pages > 1 then
        local P = require("uiparts")
        local filler = self.content_h - (y - self.content_top) - self.footer_h
        if filler > 0 then table.insert(content, P.vspace(filler)) end
        table.insert(content, P.row(self.screen_w, self.footer_h,
            P.text(string.format("%d / %d", self.page, #self.pages), 12, { color = P.DARK_GRAY }),
            { align = "center" }))
    end

    self.title_bar = self:_titleBar()
    self[1] = FrameContainer:new{
        width = self.screen_w, height = self.screen_h,
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left", self.title_bar, content },
    }
    if self.onPageBuilt then self:onPageBuilt(pg, rows) end
    UIManager:setDirty(self, function() return refresh or "ui", self.dimen end)
end

function ViewBase:pageLabel()
    local total = self.self_paged and (self.total_pages or 1) or #self.pages
    if total <= 1 then return nil end
    return string.format("%d / %d", self.page, total)
end

function ViewBase:goPage(p)
    local total = self.self_paged and (self.total_pages or 1) or #self.pages
    if p < 1 or p > total or p == self.page then return false end
    self.page = p
    self:rebuild("partial")
    return true
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------
function ViewBase:_hitAt(x, y)
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then
            return h
        end
    end
    return nil
end

function ViewBase:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    if y < self.content_top then
        -- the title bar's own icon buttons handled their taps already (children first);
        -- a tap on the title text is ours
        local m = self.title_bar_h
        if x > m and x < self.screen_w - m and self.onTitleTap then
            self:onTitleTap()
            return true
        end
        return false
    end
    local h = self:_hitAt(x, y)
    if h and h.on_tap then h.on_tap() end
    return true
end

function ViewBase:onHold(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    if y < self.content_top then return false end
    local h = self:_hitAt(x, y)
    if h and h.on_hold then
        h.on_hold()
        return true
    end
    return true
end

function ViewBase:onSwipe(_, ges)
    local d = ges.direction
    if d == "west" or d == "north" then return self:goPage(self.page + 1) or true end
    if d == "east" or d == "south" then return self:goPage(self.page - 1) or true end
    return false
end

function ViewBase:onNextPage() self:goPage(self.page + 1); return true end
function ViewBase:onPrevPage() self:goPage(self.page - 1); return true end

-- Back key
function ViewBase:onClose()
    self:onBack()
    return true
end

-- Left arrow / Back key: default closes this view only.
function ViewBase:onBack()
    UIManager:close(self)
end

-- Title-bar X: default closes this view only (home overrides to leave the app).
function ViewBase:onExit()
    UIManager:close(self)
end

function ViewBase:onCloseWidget()
    if self.teardown then self:teardown() end
    if self[1] and self[1].free then self[1]:free() end
end

return ViewBase
