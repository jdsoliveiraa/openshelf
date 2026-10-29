--[[
Template provider (PROVIDERS.md api 1). A stub catalog of three Project
Gutenberg books held in this file, so search works offline; resolve returns
real Gutenberg EPUB URLs, so downloads work on the device.

Replace CATALOG + search with calls to your service through ctx.http
(see PROVIDERS.md §1 for a networked example). Check it with:
    luajit tools/provider_check.lua provider-openshelf-template.koplugin/openshelf_template.lua pride
    luajit tools/provider_check.lua provider-openshelf-template.koplugin/openshelf_template.lua casmurro --set lang=pt

Rules (PROVIDERS.md §3–§5): everything comes from `ctx`; never require()
OpenShelf modules; keep no state between calls; return nil, "reason" on
failure; rows must be plain data with a stable locator.
--]]
local P = {
    api  = 1,
    id   = "template",                 -- final, lower-case; never change once released
    name = "Template Books",
    quality = 10,                      -- below the built-ins, so real editions win dedupe
    enabled_by_default = true,
    shelves = {
        { key = "picks", title = "Template picks" },
    },
    settings = {
        { key = "lang", title = "Language", type = "choice",
          choices = { "any", "en", "pt" }, default = "any",
          hint = "Only show books in this language" },
    },
}

local CATALOG = {
    { id = 1342,  title = "Pride and Prejudice", author = "Jane Austen", language = "en", year = "1813" },
    { id = 11,    title = "Alice's Adventures in Wonderland", author = "Lewis Carroll", language = "en", year = "1865" },
    { id = 55752, title = "Dom Casmurro", author = "Machado de Assis", language = "pt", year = "1899" },
}

-- Pure: catalog records → entries (unit-testable, like the built-ins' parse).
function P.parse(records, ctx)
    local entries = {}
    for __, book in ipairs(records) do
        entries[#entries + 1] = ctx.Entry.new{
            title    = book.title,
            author   = book.author,
            format   = "epub",
            cover    = ("https://www.gutenberg.org/cache/epub/%d/pg%d.cover.medium.jpg"):format(book.id, book.id),
            -- Strings/numbers only; resolve() gets exactly this, maybe in another process.
            locator  = { id = book.id },
            language = book.language,
            year     = book.year,
        }
    end
    return entries
end

local function wanted(book, ctx)
    local lang = ctx.settings.lang
    return lang == nil or lang == "any" or book.language == lang
end

function P.search(query, limit, page, ctx)
    local q = query:lower()
    local hits = {}
    for __, book in ipairs(CATALOG) do
        local hay = (book.title .. " " .. book.author):lower()
        if wanted(book, ctx) and q ~= "" and hay:find(q, 1, true) then hits[#hits + 1] = book end
    end
    -- One page only here; a real backend pages with `page` and says has_more.
    local first = (page - 1) * limit + 1
    local slice = {}
    for i = first, math.min(#hits, first + limit - 1) do slice[#slice + 1] = hits[i] end
    return P.parse(slice, ctx), #hits > first + limit - 1
end

function P.browse(key, limit, ctx)
    if key ~= "picks" then return nil, "unknown shelf " .. tostring(key) end
    local books = {}
    for __, book in ipairs(CATALOG) do
        if wanted(book, ctx) and #books < limit then books[#books + 1] = book end
    end
    return P.parse(books, ctx)
end

function P.resolve(locator, _ctx)   -- ctx.settings would carry a token here
    if type(locator) ~= "table" or tonumber(locator.id) == nil then
        return nil, "no download URL for this book"
    end
    -- A bare URL string; return { url =, headers = } when your files need auth.
    return ("https://www.gutenberg.org/ebooks/%d.epub3.images"):format(tonumber(locator.id))
end

return P
