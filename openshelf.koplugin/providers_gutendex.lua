--[[
Project Gutenberg provider, via the Gutendex JSON API (https://gutendex.com).
~70k public-domain books with direct EPUB links, summaries and cover images.

Also the only provider with a usable browse feed: Gutendex sorts by download
count by default ("popular") and by id descending ("new").
--]]
local HttpUtil = require("http_util")
local Entry = require("entry")
local url_escape = require("socket.url").escape

local Gutendex = { name = "Project Gutenberg" }
local BASE = "https://gutendex.com/books/"

local function first(t)
    return type(t) == "table" and t[1] or nil
end

--- Pure: Gutendex response table → entries, has_more.
function Gutendex.parse(data, limit)
    limit = limit or 20
    local results = {}
    for __, book in ipairs(data.results or {}) do
        local formats = book.formats or {}
        local epub = formats["application/epub+zip"]
        if epub then
            local author = book.authors and book.authors[1] and book.authors[1].name
            results[#results + 1] = Entry.download{
                title       = book.title,
                author      = author or "Unknown",
                source      = Gutendex.name,
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

--- Search. Returns entries, has_more — or nil, err.
function Gutendex.search(query, limit, page)
    limit = limit or 20
    page = page or 1
    local url = BASE .. "?search=" .. url_escape(query) .. "&page=" .. page
    local data, err = HttpUtil.getJSON(url)
    if not data then return nil, err end
    return Gutendex.parse(data, limit)
end

-- Browse feeds for the home shelves. kind = "popular" | "new".
Gutendex.BROWSE = {
    popular = { title = "Popular on Gutenberg", query = "?sort=popular" },
    new     = { title = "New on Gutenberg",     query = "?sort=descending" },
}

function Gutendex.browse(kind, limit)
    local feed = Gutendex.BROWSE[kind]
    if not feed then return nil, "unknown browse feed: " .. tostring(kind) end
    local data, err = HttpUtil.getJSON(BASE .. feed.query)
    if not data then return nil, err end
    local entries = Gutendex.parse(data, limit or 12)
    return entries
end

--- Turn a locator into the file URL.
function Gutendex.resolve(locator)
    if type(locator) == "table" and locator.url then return locator.url end
    return nil, "no download URL for this book"
end

return Gutendex
