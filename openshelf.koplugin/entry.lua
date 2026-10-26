--[[
The OpenShelf result model.

Every search result is a plain-data entry (no functions): it has to cross a
subprocess pipe as JSON and be persisted in the library file. Where the file
lives is described by a `locator`, which the entry's provider turns into a URL
at download time (Catalog.resolve → provider.resolve(locator)).

Entry shape:
  {
    title, author, source,          -- display
    action  = Entry.ACTION.*,       -- download | borrow | buy
    format  = "epub" | "pdf",       -- display + download extension
    quality = number,               -- higher wins when deduping editions
    dedup_key = string,             -- normalized title+author signature
    cover_url = string | nil,
    locator = { url = … } | { identifier = … },   -- provider-specific, JSON-safe
    alternates = { {format=, locator=}, … } | nil, -- other formats of the same book
    description, language, year     -- optional metadata (nil when unknown)
  }
--]]
local Entry = {}

Entry.ACTION = {
    DOWNLOAD = "download",
    BORROW   = "borrow",
    BUY      = "buy",
}

-- Display order + headings for grouping in the results view. Headings are
-- plain text; the view prefixes the glyph named in ACTION_GLYPH (see glyphs.lua).
Entry.ACTION_ORDER = { "download", "borrow", "buy" }
Entry.ACTION_HEADING = {
    download = "Download",
    borrow   = "Borrow",
    buy      = "Buy",
}
Entry.ACTION_GLYPH = {
    download = "download",
    borrow   = "book",
    buy      = "cart",
}

-- Per-source quality rank. Higher = preferred when the same title appears in
-- several sources (prefer-best-edition). Standard Ebooks is listed ahead of
-- time for the planned authenticated-OPDS provider.
Entry.QUALITY = {
    ["Standard Ebooks"]   = 100,
    ["Project Gutenberg"] = 80,
    ["Internet Archive"]  = 60,
    ["DOAB"]              = 50,
}

local ARTICLES = { ["the"] = true, ["a"] = true, ["an"] = true }

-- In LuaJIT (C locale) %w / %a only match ASCII. Bytes >= 128 are UTF-8 lead or
-- continuation bytes; keeping them intact means "Misérables" stays one token.
local WORD_BYTE = "[%a\128-\255]"

local function norm_title(title)
    local t = (title or ""):lower()
    t = t:gsub("[^%w%s\128-\255]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local first, rest = t:match("^(%w+)%s+(.*)$")
    if first and ARTICLES[first] then t = rest end
    return t
end

-- Author signature: sorted unique lowercase tokens (2+ bytes) so that
-- "Doyle, Arthur Conan" and "Arthur Conan Doyle" collapse to the same key.
local function author_sig(author)
    local toks, seen = {}, {}
    for w in (author or ""):lower():gmatch(WORD_BYTE .. WORD_BYTE .. "+") do
        if not seen[w] then seen[w] = true; toks[#toks + 1] = w end
    end
    table.sort(toks)
    return table.concat(toks, " ")
end

function Entry.makeKey(title, author)
    return norm_title(title) .. "|" .. author_sig(author)
end

-- A locator's identity as a string (for "already downloaded" matching).
function Entry.locatorKey(locator)
    if type(locator) ~= "table" then return "" end
    return locator.url or locator.identifier or ""
end

-- Stable identity of an edition: source + locator. Two entries with the same
-- id are the same file, whatever search produced them.
function Entry.id(entry)
    return (entry.source or "?") .. "|" .. Entry.locatorKey(entry.locator)
end

-- API JSON is decoded by KOReader's LuaJSON, which turns `null` into a
-- sentinel *function*. Anything that is not a non-empty string is treated as
-- absent, so a null title/author/cover can neither reach the UI nor break the
-- JSON encoding that carries entries out of the search subprocess.
local function clean(s, max)
    if type(s) ~= "string" then return nil end
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    if max and #s > max then s = s:sub(1, max) end
    return s
end

local function clean_locator(loc)
    if type(loc) ~= "table" then return {} end
    local out = {}
    for k, v in pairs(loc) do
        if type(v) == "string" or type(v) == "number" then out[k] = v end
    end
    return out
end

-- Other downloadable formats of the same book: { { format=, locator= }, … }
local function clean_alternates(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for __, alt in ipairs(list) do
        local fmt = type(alt) == "table" and clean(alt.format, 8)
        if fmt then out[#out + 1] = { format = fmt, locator = clean_locator(alt.locator) } end
    end
    if #out == 0 then return nil end
    return out
end

-- Build a DOWNLOAD entry from provider data.
function Entry.download(t)
    local title = clean(t.title, 300) or "Untitled"
    local author = clean(t.author, 200) or "Unknown"
    return {
        title       = title,
        author      = author,
        source      = clean(t.source, 60),
        action      = Entry.ACTION.DOWNLOAD,
        format      = clean(t.format, 8) or "epub",
        quality     = tonumber(t.quality) or Entry.QUALITY[t.source] or 0,
        dedup_key   = Entry.makeKey(title, author),
        cover_url   = clean(t.cover, 1000),
        locator     = clean_locator(t.locator),
        alternates  = clean_alternates(t.alternates),
        description = clean(t.description, 4000),
        language    = clean(t.language, 16),
        year        = clean(t.year, 8),
    }
end

return Entry
