--[[
Small widget builders shared by the OpenShelf views: fonts, text, exact-size
boxes, rows, buttons, cover boxes with badges, progress bars. Everything here
is sized explicitly so a row's height is known before it is painted — the
views hit-test taps against those heights.
--]]
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local Size = require("ui/size")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local Covers = require("covers")

local P = {}

P.WHITE = Blitbuffer.COLOR_WHITE
P.BLACK = Blitbuffer.COLOR_BLACK
P.GRAY = Blitbuffer.COLOR_GRAY
P.DARK_GRAY = Blitbuffer.COLOR_DARK_GRAY
P.LIGHT_GRAY = Blitbuffer.COLOR_LIGHT_GRAY

local faces = {}
function P.face(size, name)
    name = name or "cfont"
    local key = name .. size
    if not faces[key] then faces[key] = Font:getFace(name, size) end
    return faces[key]
end

function P.scale(n) return Screen:scaleBySize(n) end
function P.radius() return Screen:scaleBySize(4) end

-- opts: bold, color, max_width (enables ellipsis), font
function P.text(str, size, opts)
    opts = opts or {}
    return TextWidget:new{
        text = str or "",
        face = P.face(size, opts.font),
        bold = opts.bold,
        fgcolor = opts.color or P.BLACK,
        max_width = opts.max_width,
        truncate_with_ellipsis = opts.max_width ~= nil,
    }
end

function P.textWidth(str, size, opts)
    local w = P.text(str, size, opts)
    local width = w:getSize().w
    w:free()
    return width
end

-- Exact-size box. align = "left" (vertically centred) | "center".
function P.box(w, h, child, align)
    if align == "center" then
        return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, child }
    end
    return LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, child }
end

function P.hspace(w) return HorizontalSpan:new{ width = w } end
function P.vspace(h) return VerticalSpan:new{ width = h } end

-- Full-width row of exact height h with horizontal padding; optional bottom
-- separator line. The child is left-aligned and vertically centred.
function P.row(w, h, child, opts)
    opts = opts or {}
    local pad = opts.pad or Size.padding.default
    local line_h = opts.line and Size.line.thin or 0
    local body = FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0,
        padding_left = pad, padding_right = pad,
        background = opts.bg or P.WHITE,
        P.box(w - 2 * pad, h - line_h, child, opts.align or "left"),
    }
    if line_h == 0 then return body end
    return VerticalGroup:new{
        align = "left",
        body,
        HorizontalGroup:new{
            P.hspace(pad),
            LineWidget:new{ dimen = Geom:new{ w = w - 2 * pad, h = line_h }, background = P.LIGHT_GRAY },
        },
    }
end

-- Bordered button of exact size. opts: filled, size, bold (default true), enabled
function P.button(label, w, h, opts)
    opts = opts or {}
    local b = Size.border.default
    local filled = opts.filled and opts.enabled ~= false
    local color = P.BLACK
    if opts.enabled == false then color = P.GRAY end
    return FrameContainer:new{
        bordersize = b, padding = 0, margin = 0, radius = P.radius(),
        color = color,
        background = filled and P.BLACK or P.WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b },
            TextWidget:new{
                text = label, face = P.face(opts.size or 17), bold = opts.bold ~= false,
                fgcolor = filled and P.WHITE or color,
                max_width = w - 2 * b - 2 * Size.padding.default, truncate_with_ellipsis = true,
            },
        },
    }
end

-- Small glyph button (toolbar). Returns an exact w×h box.
function P.glyphButton(glyph, w, h, opts)
    opts = opts or {}
    return P.box(w, h, P.text(glyph, opts.size or 18, { color = opts.color }), "center")
end

-- Cover box of exact w×h: the cached image fitted inside a thin frame, or a
-- placeholder letter. opts: letter, dim, badge (glyph drawn top-right).
function P.cover(url, w, h, opts)
    opts = opts or {}
    local b = Size.border.thin
    local iw, ih = w - 2 * b, h - 2 * b
    local bb = url and Covers.load(url, iw, ih) or nil
    local inner
    if bb then
        inner = CenterContainer:new{
            dimen = Geom:new{ w = iw, h = ih },
            ImageWidget:new{ image = bb, image_disposable = false, dim = opts.dim or nil },
        }
    else
        inner = CenterContainer:new{
            dimen = Geom:new{ w = iw, h = ih },
            TextWidget:new{
                text = opts.letter or "?",
                face = P.face(math.max(12, math.floor(ih / 7)), "tfont"),
                fgcolor = opts.dim and P.LIGHT_GRAY or P.GRAY,
            },
        }
    end
    local frame = FrameContainer:new{
        bordersize = b, padding = 0, margin = 0,
        color = opts.dim and P.LIGHT_GRAY or P.GRAY,
        background = P.WHITE,
        inner,
    }
    if not opts.badge then return frame end
    local badge = FrameContainer:new{
        bordersize = 0, margin = 0, padding = Size.padding.small,
        background = P.BLACK,
        TextWidget:new{ text = opts.badge, face = P.face(12), fgcolor = P.WHITE },
    }
    badge.overlap_align = "right"
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        allow_mirroring = false,
        frame,
        badge,
    }
end

function P.progress(w, h, pct)
    return ProgressWidget:new{
        width = w, height = h, percentage = math.max(0, math.min(1, pct or 0)),
        margin_h = 0, margin_v = 0,
    }
end

function P.friendlySize(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1048576 then return string.format("%.1f MB", bytes / 1048576) end
    if bytes >= 1024 then return string.format("%d KB", math.floor(bytes / 1024)) end
    return string.format("%d B", bytes)
end

-- First letter of the title for placeholder covers (ASCII upper-cased, UTF-8 kept).
function P.letterFor(entry)
    local t = entry and entry.title or ""
    local ch = t:match("^[%z\1-\127]") or t:match("^[\194-\244][\128-\191]+") or "?"
    return ch:upper()
end

return P
