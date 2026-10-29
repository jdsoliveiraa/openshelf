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

function P.search(query, limit, page, ctx)
    local url = ("%s&search=%s&page=%d"):format(BASE, ctx.url_escape(query), page)
    local data, err = ctx.http.getJSON(url)
    if not data then return nil, err end
    return P.parse(data, limit, ctx)
end

function P.resolve(locator)
    if type(locator) == "table" and type(locator.url) == "string" then return locator.url end
    return nil, "no download URL for this book"
end

return P
