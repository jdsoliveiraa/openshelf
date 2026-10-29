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
local SHELF_QUERY = { popular = "?sort=popular", new = "?sort=descending" }

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

function P.search(query, limit, page, ctx)
    limit = limit or 20
    page = page or 1
    local url = BASE .. "?search=" .. ctx.url_escape(query) .. "&page=" .. page
    local data, err = ctx.http.getJSON(url)
    if not data then return nil, err end
    return P.parse(data, limit, ctx)
end

function P.browse(key, limit, ctx)
    local q = SHELF_QUERY[key]
    if not q then return nil, "unknown shelf: " .. tostring(key) end
    local data, err = ctx.http.getJSON(BASE .. q)
    if not data then return nil, err end
    local entries = P.parse(data, limit or 12, ctx)
    return entries
end

function P.resolve(locator)
    if type(locator) == "table" and type(locator.url) == "string" then return locator.url end
    return nil, "no download URL for this book"
end

return P
