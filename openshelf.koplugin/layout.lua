--[[
Pure layout math shared by the views (DESIGN.md §2): grid geometry, shelf cover
counts and pagination. Everything derives from the screen size so portrait and
landscape, and other devices, fall out without a second design.
--]]
local Layout = {}

local COVER_ASPECT = 1.5   -- height / width of a book cover box

-- Grid: `cols` columns by `rows` rows that fit content_w × content_h.
-- target_cols is what the design asks for (3 on the Clara in portrait); in
-- landscape the same cell width yields more columns and fewer rows.
function Layout.grid(content_w, content_h, opts)
    opts = opts or {}
    local pad = opts.pad or 8
    local caption_h = opts.caption_h or 0
    local target_cols = opts.target_cols or 3
    -- cell width from the shorter screen side so cells look the same either way
    local base_w = math.min(content_w, opts.portrait_w or content_w)
    local cell_w = math.floor(base_w / target_cols)
    local cols = math.max(1, math.floor(content_w / cell_w))
    cell_w = math.floor(content_w / cols)
    local cover_w = cell_w - 2 * pad
    local cover_h = math.floor(cover_w * COVER_ASPECT)
    -- Fit the asked-for number of rows by shrinking the cover (kept centred
    -- in its cell) rather than letting a wide screen dictate huge covers.
    if opts.target_rows then
        local max_cover_h = math.floor(content_h / opts.target_rows) - caption_h - 2 * pad
        if max_cover_h < cover_h then
            cover_h = math.max(1, max_cover_h)
            cover_w = math.floor(cover_h / COVER_ASPECT)
        end
    end
    local cell_h = cover_h + caption_h + 2 * pad
    local rows = math.max(1, math.floor(content_h / cell_h))
    return {
        cols = cols, rows = rows, per_page = cols * rows,
        cell_w = cell_w, cell_h = cell_h,
        cover_w = cover_w, cover_h = cover_h,
        caption_h = caption_h, pad = pad,
    }
end

-- Shelf: one row of `count` covers that exactly fills content_w.
function Layout.shelf(content_w, opts)
    opts = opts or {}
    local gap = opts.gap or 12
    local target_cover_w = opts.target_cover_w or 200
    local count = math.max(2, math.floor((content_w + gap) / (target_cover_w + gap)))
    if opts.max_count then count = math.min(count, opts.max_count) end
    local cover_w = math.floor((content_w - gap * (count - 1)) / count)
    local cover_h = math.floor(cover_w * COVER_ASPECT)
    return { count = count, cover_w = cover_w, cover_h = cover_h, gap = gap }
end

function Layout.pageCount(n, per_page)
    if n <= 0 or per_page <= 0 then return 1 end
    return math.ceil(n / per_page)
end

-- 1-based inclusive range of items on `page`.
function Layout.pageRange(page, per_page, n)
    local first = (page - 1) * per_page + 1
    local last = math.min(page * per_page, n)
    if first > last then return 1, 0 end
    return first, last
end

return Layout
