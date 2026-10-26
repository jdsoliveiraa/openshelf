--[[
A shelf: a header row ("My books" … "See all ›") and one row of covers sized
to fill the width — no horizontal scrolling (DESIGN.md §2.2, decision 14).

  rows = Shelf.rows(view, {
      title = "…", entries = {…}, on_see_all = fn|nil,
      on_tap = fn(entry), on_hold = fn(entry)|nil,
      status = fn(entry) -> { downloaded, missing, progress (0..1|nil) },
      empty_text = "…",     -- shown instead of covers when entries is empty
  })
--]]
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local Screen = require("device").screen
local _ = require("gettext")
local Glyphs = require("glyphs")
local Layout = require("layout")
local P = require("uiparts")

local Shelf = {}

Shelf.HEADER_H = Screen:scaleBySize(32)

function Shelf.geometry(view)
    local pad = Size.padding.default
    local content_w = view.screen_w - 2 * pad
    local sh = Layout.shelf(content_w, {
        gap = Screen:scaleBySize(8),
        target_cover_w = Screen:scaleBySize(100),
        max_count = 6,
    })
    sh.pad = pad
    sh.content_w = content_w
    return sh
end

function Shelf.header(view, title, on_see_all)
    local pad = Size.padding.default
    local content_w = view.screen_w - 2 * pad
    local right_label = on_see_all and (_("See all") .. "  " .. Glyphs.chevron_right) or ""
    local right = P.text(right_label, 14, { color = P.DARK_GRAY })
    local right_w = right:getSize().w
    local left = P.text(title, 17, { bold = true, font = "tfont", max_width = content_w - right_w - pad })
    local left_w = left:getSize().w
    local span = math.max(0, content_w - left_w - right_w)
    local content = HorizontalGroup:new{ align = "center", left, P.hspace(span), right }
    return {
        widget = P.row(view.screen_w, Shelf.HEADER_H, content, { pad = pad }),
        h = Shelf.HEADER_H,
        keep_with_next = true,
        hits = on_see_all and { { on_tap = on_see_all } } or {},
    }
end

function Shelf.rows(view, opts)
    local rows = { Shelf.header(view, opts.title, opts.on_see_all) }
    local entries = opts.entries or {}
    if #entries == 0 then
        local h = Screen:scaleBySize(40)
        rows[#rows + 1] = {
            widget = P.row(view.screen_w, h, P.text(opts.empty_text or "", 14, { color = P.DARK_GRAY })),
            h = h, hits = {},
        }
        return rows
    end
    local g = Shelf.geometry(view)
    local bar_h = Screen:scaleBySize(5)
    local with_progress = false
    local count = math.min(#entries, g.count)
    local states = {}
    for i = 1, count do
        states[i] = opts.status and opts.status(entries[i]) or {}
        if states[i].progress then with_progress = true end
    end
    local extra = with_progress and (bar_h + Screen:scaleBySize(4)) or 0
    local row_h = g.cover_h + extra + 2 * Size.padding.small

    local items = {}
    local hits = {}
    for i = 1, count do
        local entry = entries[i]
        local st = states[i]
        local cover = P.cover(entry.cover_url, g.cover_w, g.cover_h, {
            letter = P.letterFor(entry), dim = st.missing,
            badge = (st.downloaded and not st.missing and opts.mark_downloaded) and Glyphs.check or nil,
        })
        local cell
        if with_progress then
            cell = VerticalGroup:new{
                align = "left", cover, P.vspace(Screen:scaleBySize(4)),
                st.progress and P.progress(g.cover_w, bar_h, st.progress) or P.vspace(bar_h),
            }
        else
            cell = cover
        end
        items[#items + 1] = cell
        if i < count then items[#items + 1] = P.hspace(g.gap) end
        local x = g.pad + (i - 1) * (g.cover_w + g.gap)
        hits[#hits + 1] = {
            x = x, w = g.cover_w,
            on_tap = function() opts.on_tap(entry) end,
            on_hold = opts.on_hold and function() opts.on_hold(entry) end or nil,
        }
    end
    local content = HorizontalGroup:new{ align = "top", unpack(items) }
    rows[#rows + 1] = {
        widget = P.row(view.screen_w, row_h, content, { pad = g.pad }),
        h = row_h, hits = hits,
    }
    return rows
end

-- Entries shown on a shelf (first `count`), for cover prefetching.
function Shelf.visible(view, entries)
    local g = Shelf.geometry(view)
    local out = {}
    for i = 1, math.min(#entries, g.count) do out[i] = entries[i] end
    return out
end

return Shelf
