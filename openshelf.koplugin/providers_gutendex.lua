--[[
Project Gutenberg provider, via the Gutendex JSON API (https://gutendex.com).
~70k public-domain books with direct EPUB links.
--]]
local HttpUtil = require("http_util")
local Entry = require("entry")
local url_escape = require("socket.url").escape

local Gutendex = { name = "Project Gutenberg" }

function Gutendex.search(query, limit)
    limit = limit or 20
    local url = "https://gutendex.com/books/?search=" .. url_escape(query)
    local data, err = HttpUtil.getJSON(url)
    if not data then return nil, err end

    local results = {}
    for _, book in ipairs(data.results or {}) do
        local epub = book.formats and book.formats["application/epub+zip"]
        if epub then
            local author = "Unknown"
            if book.authors and book.authors[1] then
                author = book.authors[1].name
            end
            results[#results + 1] = Entry.download{
                title  = book.title,
                author = author,
                source = Gutendex.name,
                resolve = function() return epub end,
            }
            if #results >= limit then break end
        end
    end
    return results
end

return Gutendex
