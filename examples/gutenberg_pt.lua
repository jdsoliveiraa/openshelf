--[[
Example drop-in provider (PROVIDERS.md §8.3): Project Gutenberg's books in
Portuguese, through the Gutendex JSON API.

Install: copy this file into <KOReader settings>/openshelf/providers/
(on a Kobo: /mnt/onboard/.adds/koreader/settings/openshelf/providers/) and
restart KOReader. The file name does not matter; the id comes from the table.
It starts disabled (enabled_by_default = false): turn it on in
OpenShelf → Settings → Sources.

Check it without KOReader:
    eval "$(luarocks --lua-version=5.1 path)"
    luajit tools/provider_check.lua examples/gutenberg_pt.lua machado

Everything comes from `ctx`; a drop-in never require()s anything.
--]]
local P = {
    api  = 1,
    id   = "gutenberg_pt",
    name = "Gutenberg (Português)",
    quality = 75,                -- just below the built-in Gutenberg (80)
    enabled_by_default = false,
}

local BASE = "https://gutendex.com/books/?languages=pt"

-- Pure: Gutendex payload → entries, has_more.
function P.parse(data, limit, ctx)
    local entries = {}
    for __, book in ipairs(type(data.results) == "table" and data.results or {}) do
        local formats = type(book.formats) == "table" and book.formats or {}
        local epub = formats["application/epub+zip"]
        -- JSON null is a function on the device: test types, not truthiness.
        if type(epub) == "string" and #entries < limit then
            local author = type(book.authors) == "table" and type(book.authors[1]) == "table"
                and book.authors[1].name
            entries[#entries + 1] = ctx.Entry.new{
                title    = book.title,
                author   = author,
                cover    = formats["image/jpeg"],
                locator  = { url = epub },
                language = "pt",
            }
        end
    end
    return entries, type(data.next) == "string"
end

-- Gutendex serves a fixed 32 rows per page, but OpenShelf pages by `limit`
-- (10, 15 or 30): OpenShelf page N is result offsets [(N-1)*limit, N*limit).
-- Fetch the one or two Gutendex pages covering that range and slice it, so
-- Load more shows every book exactly once.
local GUTENDEX_PAGE = 32

function P.search(query, limit, page, ctx)
    local start = (page - 1) * limit                    -- 0-based offset
    local gpage = math.floor(start / GUTENDEX_PAGE) + 1
    local skip = start - (gpage - 1) * GUTENDEX_PAGE
    local rows, more = {}, true
    while more and #rows < skip + limit do              -- at most two requests
        local url = ("%s&search=%s&page=%d"):format(BASE, ctx.url_escape(query), gpage)
        local data, err = ctx.http.getJSON(url)
        if not data then return nil, err end
        for __, book in ipairs(type(data.results) == "table" and data.results or {}) do
            rows[#rows + 1] = book
        end
        more = type(data.next) == "string"
        gpage = gpage + 1
    end
    local window = {}
    for i = skip + 1, math.min(skip + limit, #rows) do window[#window + 1] = rows[i] end
    local entries = P.parse({ results = window }, limit, ctx)
    return entries, more or #rows > skip + limit
end

function P.resolve(locator)
    if type(locator) == "table" and type(locator.url) == "string" then return locator.url end
    return nil, "no download URL for this book"
end

return P
