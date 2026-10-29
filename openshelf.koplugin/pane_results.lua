--[[
Rows for a page of book entries, as a list or a 3-column grid
(DESIGN.md §2.3). Shared by the home screen's results mode and the "See all"
lists. Pure layout: the caller supplies status lookups and tap/hold handlers.
Entries are grouped by action (Catalog.group); a group header row appears
only when more than one action is present, and paging keeps a header with
the row that follows it.

  local rows, total_pages, page_entries = Pane.rows(view, entries, {
      mode = "list"|"grid", page = n, avail_h = px,
      status = function(entry) -> { downloaded, missing, dl } end,
      on_tap = function(entry) end, on_hold = function(entry) end,
  })
  local p = Pane.pageOf(view, entries, { mode =, avail_h = }, entry)   -- page holding entry
--]]
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local Screen = require("device").screen
local _ = require("gettext")
local Catalog = require("catalog")
local Glyphs = require("glyphs")
local Layout = require("layout")
local P = require("uiparts")

local Pane = {}

-- Height of the three-line text column (title / author / meta), measured once
-- so the row is always tall enough for its text.
local text_col_h
local function measure_text_col()
    if text_col_h then return text_col_h end
    local probe = VerticalGroup:new{
        align = "left",
        P.text("Ag", 17, { bold = true }), P.vspace(Screen:scaleBySize(2)),
        P.text("Ag", 15), P.vspace(Screen:scaleBySize(3)),
        P.text("Ag", 13),
    }
    text_col_h = probe:getSize().h
    probe:free()
    return text_col_h
end

function Pane.listGeometry(view)
    local pad = Size.padding.default
    local vpad = Size.padding.default
    local row_h = measure_text_col() + 2 * vpad + Size.line.thin
    local cover_h = row_h - Size.line.thin - 2 * Size.padding.small
    local cover_w = math.floor(cover_h / 1.5)
    return {
        pad = pad, row_h = row_h, cover_w = cover_w, cover_h = cover_h,
        text_w = view.screen_w - 2 * pad - cover_w - pad,
    }
end

function Pane.gridGeometry(view, avail_h)
    return Layout.grid(view.screen_w, avail_h, {
        pad = Screen:scaleBySize(6),
        caption_h = Screen:scaleBySize(40),
        target_cols = 3,
        target_rows = 3,
        portrait_w = math.min(view.screen_w, view.screen_h),
    })
end

function Pane.perPage(view, mode, avail_h)
    if mode == "grid" then
        return Pane.gridGeometry(view, avail_h).per_page
    end
    return math.max(1, math.floor(avail_h / Pane.listGeometry(view).row_h))
end

local function meta_line(entry, st)
    -- Source badge: the registry's current display name for the row's provider
    -- id; a stored row from a provider no longer installed keeps its own label.
    local label = Catalog.nameOf(entry.provider) or entry.source or ""
    local meta = string.format("%s · %s", label, (entry.format or "epub"):upper())
    if entry.price then meta = meta .. " · " .. entry.price end   -- buy rows
    if st.dl and st.dl.status == "queued" then
        meta = meta .. "  ·  " .. _("Queued")
    elseif st.missing then
        meta = meta .. "  ·  " .. _("not on device")
    elseif st.downloaded then
        meta = meta .. "  ·  " .. Glyphs.check .. " " .. _("Downloaded")
    end
    return meta
end

local function dl_progress(st)
    local dl = st.dl
    local pct = (dl.total and dl.total > 0) and math.min(1, (dl.done or 0) / dl.total) or 0
    local label
    if dl.total and dl.total > 0 then
        label = string.format("%d%%  ·  %s", math.floor(pct * 100), P.friendlySize(dl.total))
    else
        label = P.friendlySize(dl.done)
    end
    return pct, label
end

function Pane.listRow(view, entry, g, st, on_tap, on_hold)
    local cover = P.cover(entry.cover_url, g.cover_w, g.cover_h, {
        letter = P.letterFor(entry), dim = st.missing,
        badge = (st.downloaded and not st.missing) and Glyphs.check or nil,
    })
    local title = P.text(entry.title, 17, { bold = true, max_width = g.text_w })
    local author = P.text(entry.author, 15, { max_width = g.text_w })
    local meta
    if st.dl and st.dl.status == "active" then
        local pct, label = dl_progress(st)
        meta = HorizontalGroup:new{
            align = "center",
            P.progress(math.floor(g.text_w * 0.5), Screen:scaleBySize(7), pct),
            P.hspace(g.pad),
            P.text(label, 13, { color = P.DARK_GRAY, max_width = math.floor(g.text_w * 0.45) }),
        }
    else
        meta = P.text(meta_line(entry, st), 13, { color = P.DARK_GRAY, max_width = g.text_w })
    end
    local textcol = VerticalGroup:new{
        align = "left",
        title, P.vspace(Screen:scaleBySize(2)),
        author, P.vspace(Screen:scaleBySize(3)),
        meta,
    }
    local content = HorizontalGroup:new{ align = "center", cover, P.hspace(g.pad), textcol }
    return {
        widget = P.row(view.screen_w, g.row_h, content, { pad = g.pad, line = true }),
        h = g.row_h,
        hits = { { on_tap = on_tap, on_hold = on_hold } },
    }
end

local function grid_cell(entry, g, st)
    local caption_w = g.cover_w
    local badge
    if st.downloaded and not st.missing then badge = Glyphs.check end
    local cover = P.cover(entry.cover_url, g.cover_w, g.cover_h, {
        letter = P.letterFor(entry), dim = st.missing, badge = badge,
    })
    local second
    if st.dl and st.dl.status == "active" then
        local pct, label = dl_progress(st)
        second = HorizontalGroup:new{
            align = "center",
            P.progress(math.floor(caption_w * 0.55), Screen:scaleBySize(6), pct),
            P.hspace(Size.padding.small),
            P.text(label, 11, { color = P.DARK_GRAY, max_width = math.floor(caption_w * 0.4) }),
        }
    else
        local sub = entry.author or ""
        if st.dl and st.dl.status == "queued" then sub = _("Queued") end
        if st.missing then sub = _("not on device") end
        second = P.text(sub, 12, { color = P.DARK_GRAY, max_width = caption_w })
    end
    local cell = VerticalGroup:new{
        align = "center",
        cover,
        P.vspace(Screen:scaleBySize(3)),
        P.text(entry.title, 13, { bold = true, max_width = caption_w }),
        second,
    }
    return P.box(g.cell_w, g.cell_h, cell, "center")
end

function Pane.gridRow(view, entries, g, status, on_tap, on_hold)
    local cells = {}
    local hits = {}
    local left = math.floor((view.screen_w - g.cols * g.cell_w) / 2)
    for i, entry in ipairs(entries) do
        cells[#cells + 1] = grid_cell(entry, g, status(entry))
        hits[#hits + 1] = {
            x = left + (i - 1) * g.cell_w, w = g.cell_w,
            on_tap = function() on_tap(entry) end,
            on_hold = function() on_hold(entry) end,
        }
    end
    local group = HorizontalGroup:new{ align = "top", P.hspace(left), unpack(cells) }
    return { widget = P.box(view.screen_w, g.cell_h, group, "left"), h = g.cell_h, hits = hits }
end

Pane.HEADER_H = Screen:scaleBySize(30)

-- Group header: Nerd Font glyph + heading (DESIGN.md §2.3, no emoji).
local function header_row(view, group)
    local pad = Size.padding.default
    local label = HorizontalGroup:new{
        align = "center",
        P.text(Glyphs[group.glyph] or "", 14, { color = P.DARK_GRAY }),
        P.hspace(pad),
        P.text(_(group.heading), 14, { bold = true, color = P.DARK_GRAY, max_width = view.screen_w - 3 * pad }),
    }
    return {
        widget = P.row(view.screen_w, Pane.HEADER_H, label, { pad = pad }),
        h = Pane.HEADER_H, hits = {}, keep_with_next = true,
    }
end

-- One vertical unit of the pane: a group header, a list row's entry or a grid
-- row's cells. Headers only when the entries span more than one action.
local function build_lines(entries, mode, g)
    local groups = Catalog.group(entries)
    local lines = {}
    for __, grp in ipairs(groups) do
        if #groups > 1 then lines[#lines + 1] = { header = grp, h = Pane.HEADER_H } end
        if mode == "grid" then
            local i = 1
            while i <= #grp.items do
                local cells = {}
                for j = i, math.min(i + g.cols - 1, #grp.items) do cells[#cells + 1] = grp.items[j] end
                lines[#lines + 1] = { cells = cells, h = g.cell_h }
                i = i + g.cols
            end
        else
            for ___, e in ipairs(grp.items) do lines[#lines + 1] = { entry = e, h = g.row_h } end
        end
    end
    return lines
end

-- Slice lines into pages of at most avail_h (a line always gets a page even
-- when taller), keeping a header with the line that follows it.
local function paginate(lines, avail_h)
    local pages = {}
    local i = 1
    while i <= #lines do
        local start_i, acc = i, 0
        while i <= #lines do
            local h = lines[i].h
            if acc + h > avail_h and i > start_i then break end
            acc = acc + h
            i = i + 1
        end
        if i <= #lines and i - 1 > start_i and lines[i - 1].header then i = i - 1 end
        pages[#pages + 1] = { first = start_i, last = i - 1 }
    end
    if #pages == 0 then pages[1] = { first = 1, last = 0 } end
    return pages
end

function Pane.rows(view, entries, opts)
    local mode = opts.mode == "grid" and "grid" or "list"
    local g = mode == "grid" and Pane.gridGeometry(view, opts.avail_h) or Pane.listGeometry(view)
    local lines = build_lines(entries, mode, g)
    local pages = paginate(lines, opts.avail_h)
    local total = #pages
    local page = math.max(1, math.min(opts.page or 1, total))
    local rows, page_entries = {}, {}
    for i = pages[page].first, pages[page].last do
        local line = lines[i]
        if line.header then
            rows[#rows + 1] = header_row(view, line.header)
        elseif line.cells then
            for __, e in ipairs(line.cells) do page_entries[#page_entries + 1] = e end
            rows[#rows + 1] = Pane.gridRow(view, line.cells, g, opts.status, opts.on_tap, opts.on_hold)
        else
            local entry = line.entry
            page_entries[#page_entries + 1] = entry
            rows[#rows + 1] = Pane.listRow(view, entry, g, opts.status(entry),
                function() opts.on_tap(entry) end,
                function() opts.on_hold(entry) end)
        end
    end
    return rows, total, page_entries
end

--- The page (1-based) on which `entry` (a table from `entries`) lands with the
-- same layout Pane.rows uses; nil when absent. No widgets are built.
function Pane.pageOf(view, entries, opts, entry)
    local mode = opts.mode == "grid" and "grid" or "list"
    local g = mode == "grid" and Pane.gridGeometry(view, opts.avail_h) or Pane.listGeometry(view)
    local lines = build_lines(entries, mode, g)
    for p, pg in ipairs(paginate(lines, opts.avail_h)) do
        for i = pg.first, pg.last do
            local line = lines[i]
            if line.entry == entry then return p end
            for __, e in ipairs(line.cells or {}) do
                if e == entry then return p end
            end
        end
    end
    return nil
end

-- Cover URLs of a set of entries (for prefetching).
function Pane.coverUrls(entries)
    local urls = {}
    for __, e in ipairs(entries or {}) do
        if e.cover_url then urls[#urls + 1] = e.cover_url end
    end
    return urls
end

return Pane
