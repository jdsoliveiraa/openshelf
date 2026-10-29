--[[
Project Gutenberg provider, via the Gutendex JSON API (https://gutendex.com).
~70k public-domain books with direct EPUB links, summaries and cover images.

Also the only built-in with home shelves: Gutendex sorts by download count
by default ("popular") and by id descending ("new").

Contract: PROVIDERS.md (api 1). Everything from the host arrives in `ctx`;
this file must not require() any OpenShelf module.
--]]
local P = {
    api     = 1,
    id      = "gutendex",
    name    = "Project Gutenberg",
    quality = 80,
    shelves = {
        { key = "popular", title = "Popular on Gutenberg" },
        { key = "new",     title = "New on Gutenberg" },
    },
}

local BASE = "https://gutendex.com/books/"
local SHELF_QUERY = { popular = "sort=popular", new = "sort=descending" }

-- Gutendex is fast only on URLs it has cached and can take a minute on
-- others (2026-10-29: "?sort=popular" 0.06 s, "?sort=popular&page=2" 98 s,
-- "?page=2&sort=popular" 15 s cold, then cached). So page 1 keeps the plain
-- shelf URL and later pages use the exact shape of Gutendex's own `next`
-- links, which every client following them warms.
local function shelf_url(q, n)
    if n == 1 then return BASE .. "?" .. q end
    return BASE .. "?page=" .. n .. "&" .. q
end

local function first(t)
    return type(t) == "table" and t[1] or nil
end

--- Pure: Gutendex response table → entries, has_more.
function P.parse(data, limit, ctx)
    limit = limit or 20
    local results = {}
    for __, book in ipairs(data.results or {}) do
        local formats = book.formats or {}
        local epub = formats["application/epub+zip"]
        if type(epub) == "string" then
            local author = book.authors and book.authors[1] and book.authors[1].name
            results[#results + 1] = ctx.Entry.new{
                title       = book.title,
                author      = author,
                cover       = formats["image/jpeg"],
                locator     = { url = epub, id = book.id },
                description = first(book.summaries),
                language    = first(book.languages),
            }
            if #results >= limit then break end
        end
    end
    local has_more = type(data.next) == "string" and data.next ~= ""
    return results, has_more
end

-- Gutendex serves a fixed 32 rows per page; OpenShelf pages by `limit`
-- (10, 15 or 30 for search, 12 for shelves). OpenShelf page N is result
-- offsets [(N-1)*limit, N*limit), so it spans one or two Gutendex pages;
-- fetch those and slice.
local GUTENDEX_PAGE = 32

--- Rows of OpenShelf page `page` from `fetch(gutendex_page) → data, err`.
--- At most two requests (limit <= 32). Returns raw rows, has_more.
function P.window(fetch, limit, page)
    local start = (page - 1) * limit                    -- 0-based offset
    local gpage = math.floor(start / GUTENDEX_PAGE) + 1
    local skip = start - (gpage - 1) * GUTENDEX_PAGE    -- rows of gpage before ours
    local rows, more = {}, true
    while more and #rows < skip + limit do
        local data, err = fetch(gpage)
        if not data then return nil, err end
        for __, row in ipairs(type(data.results) == "table" and data.results or {}) do
            rows[#rows + 1] = row
        end
        -- JSON null is a function on the device: test the type.
        more = type(data.next) == "string" and data.next ~= ""
        gpage = gpage + 1
    end
    local window = {}
    for i = skip + 1, math.min(skip + limit, #rows) do window[#window + 1] = rows[i] end
    return window, more or #rows > skip + limit
end

function P.search(query, limit, page, ctx)
    limit = limit or 20
    page = page or 1
    local base = BASE .. "?search=" .. ctx.url_escape(query) .. "&page="
    local rows, has_more = P.window(function(n) return ctx.http.getJSON(base .. n) end, limit, page)
    if not rows then return nil, has_more end
    local entries = P.parse({ results = rows }, limit, ctx)
    return entries, has_more
end

-- Shelves page like search (PROVIDERS.md §5.3): page N of `limit` rows
-- through the same Gutendex window, so "See all" shows every book once.
function P.browse(key, limit, ctx, page)
    local q = SHELF_QUERY[key]
    if not q then return nil, "unknown shelf: " .. tostring(key) end
    limit = limit or 12
    local rows, has_more = P.window(function(n) return ctx.http.getJSON(shelf_url(q, n)) end, limit, page or 1)
    if not rows then return nil, has_more end
    local entries = P.parse({ results = rows }, limit, ctx)
    return entries, has_more
end

function P.resolve(locator)
    if type(locator) == "table" and type(locator.url) == "string" then return locator.url end
    return nil, "no download URL for this book"
end

return P
