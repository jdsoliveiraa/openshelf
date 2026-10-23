--[[
CoverBrowser — a full-screen, paged results view that shows a cover thumbnail
next to each result. The base KOReader Menu is text-only, so this is a custom
widget built from primitives.

Design choices for robustness (this can't be unit-tested outside KOReader):
 - Tap handling is done at the parent level by hit-testing ges.pos.y against the
   current page's row heights — no reliance on per-child dimen propagation.
 - Rows can have different heights (short headers, tall entries); pages are
   pre-computed by accumulating heights to fill the screen.
 - Paging via swipe (west = next, east = prev); close via the title bar X or Back.
 - Covers are fetched/decoded lazily per visible row (cached); freed on close.

If anything misbehaves on-device, the plugin's "Show covers" toggle falls back to
the plain text results list.
--]]
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local Covers = require("covers")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local Font = require("ui/font")
local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local CoverBrowser = InputContainer:extend{
    results_title = "",     -- shown in the title bar
    groups = nil,           -- from Catalog.group(entries)
    on_select = nil,        -- function(entry)
    page = 1,
}

function CoverBrowser:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.covers_fullscreen = true

    self.pad = Size.padding.default
    self.header_h = Screen:scaleBySize(42)
    self.row_h = Screen:scaleBySize(104)
    self.cover_h = self.row_h - 2 * self.pad
    self.cover_w = math.floor(self.cover_h * 0.66)

    self.title_face  = Font:getFace("cfont", 18)
    self.author_face = Font:getFace("cfont", 15)
    self.source_face = Font:getFace("cfont", 14)
    self.header_face = Font:getFace("tfont", 18)
    self.ph_face     = Font:getFace("cfont", 24)

    -- flatten groups -> display items (header rows + entry rows)
    self.items = {}
    for _, g in ipairs(self.groups or {}) do
        self.items[#self.items + 1] = { header = T("%1  (%2)", g.heading, #g.items) }
        for _, e in ipairs(g.items) do
            self.items[#self.items + 1] = { entry = e }
        end
    end

    -- title bar height drives the content region; build a throwaway to measure
    local tb = TitleBar:new{ width = self.screen_w, title = self.results_title,
        subtitle = " ", show_parent = self }
    self.title_bar_h = tb:getHeight()
    self.content_top = self.title_bar_h
    self.content_h = self.screen_h - self.title_bar_h

    self:_paginate()

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextPage = { { Device.input.group.PgFwd } },
            PrevPage = { { Device.input.group.PgBack } },
        }
    end
    self.ges_events = {
        Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }

    self:_render()
end

local function item_height(self, it)
    return it.header and self.header_h or self.row_h
end

-- Pre-compute page boundaries by accumulating row heights to fill the screen.
function CoverBrowser:_paginate()
    self.pages = {}
    local i = 1
    while i <= #self.items do
        local start_i = i
        local acc = 0
        while i <= #self.items do
            local h = item_height(self, self.items[i])
            if acc + h > self.content_h and i > start_i then break end
            acc = acc + h
            i = i + 1
        end
        self.pages[#self.pages + 1] = { first = start_i, last = i - 1 }
    end
    if #self.pages == 0 then self.pages = { { first = 1, last = 0 } } end
end

function CoverBrowser:_coverWidget(entry)
    local bb = entry.cover_url and Covers.get(entry.cover_url, self.cover_w, self.cover_h) or nil
    if bb then
        return ImageWidget:new{
            image = bb, width = self.cover_w, height = self.cover_h,
            scale_factor = 0, image_disposable = false,
        }
    end
    return FrameContainer:new{
        width = self.cover_w, height = self.cover_h,
        bordersize = Size.border.thin, padding = 0, margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.cover_w, h = self.cover_h },
            TextWidget:new{ text = (entry.source or "?"):sub(1, 1), face = self.ph_face },
        },
    }
end

function CoverBrowser:_entryRow(entry)
    local text_w = self.screen_w - self.cover_w - 3 * self.pad
    local textcol = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = entry.title or "", face = self.title_face,
            max_width = text_w, truncate_with_ellipsis = true },
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        TextWidget:new{ text = entry.author or "", face = self.author_face,
            max_width = text_w, truncate_with_ellipsis = true },
        VerticalSpan:new{ width = Screen:scaleBySize(2) },
        TextWidget:new{
            text = string.format("%s · %s", entry.source or "", (entry.format or "epub"):upper()),
            face = self.source_face, max_width = text_w, truncate_with_ellipsis = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY },
    }
    return FrameContainer:new{
        width = self.screen_w, height = self.row_h,
        bordersize = 0, padding = self.pad, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            self:_coverWidget(entry),
            HorizontalSpan:new{ width = self.pad },
            textcol,
        },
    }
end

function CoverBrowser:_headerRow(text)
    return FrameContainer:new{
        width = self.screen_w, height = self.header_h,
        bordersize = 0, padding = self.pad, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        TextWidget:new{ text = text, face = self.header_face, bold = true },
    }
end

function CoverBrowser:_render()
    local pg = self.pages[self.page]
    local content = VerticalGroup:new{ align = "left" }
    for i = pg.first, pg.last do
        local it = self.items[i]
        table.insert(content, it.header and self:_headerRow(it.header)
            or self:_entryRow(it.entry))
    end

    local title_bar = TitleBar:new{
        width = self.screen_w,
        title = self.results_title,
        subtitle = T(_("Page %1 / %2  —  swipe to turn"), self.page, #self.pages),
        close_callback = function() UIManager:close(self) end,
        show_parent = self,
    }

    self[1] = FrameContainer:new{
        width = self.screen_w, height = self.screen_h,
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left", title_bar, content },
    }
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function CoverBrowser:_goPage(p)
    if p < 1 or p > #self.pages then return end
    self.page = p
    self:_render()
end

function CoverBrowser:onTap(_, ges)
    local rel = ges.pos.y - self.content_top
    if rel < 0 then return false end   -- let the title bar handle its own taps
    local pg = self.pages[self.page]
    local acc = 0
    for i = pg.first, pg.last do
        local it = self.items[i]
        local h = item_height(self, it)
        if rel < acc + h then
            if it.entry and self.on_select then self.on_select(it.entry) end
            return true
        end
        acc = acc + h
    end
    return true
end

function CoverBrowser:onSwipe(_, ges)
    if ges.direction == "west" then self:_goPage(self.page + 1); return true end
    if ges.direction == "east" then self:_goPage(self.page - 1); return true end
    return false
end

function CoverBrowser:onNextPage() self:_goPage(self.page + 1); return true end
function CoverBrowser:onPrevPage() self:_goPage(self.page - 1); return true end

function CoverBrowser:onClose()
    UIManager:close(self)
    return true
end

function CoverBrowser:onCloseWidget()
    Covers.clearCache()
end

return CoverBrowser
