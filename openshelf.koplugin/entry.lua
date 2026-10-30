--[[
The OpenShelf result model.

Every search result is a plain-data entry (no functions): it has to cross a
subprocess pipe as JSON and be persisted in the library file. Where the file
lives is described by a `locator`, which the entry's provider turns into a URL
at download time (Catalog.resolve → provider.resolve(locator)).

Entry shape:
  {
    title, author,                  -- display
    provider = "gutendex",          -- provider id: the key (slots, settings, Entry.id, library)
    source   = "Project Gutenberg", -- provider display name, for labels only
    action  = Entry.ACTION.*,       -- download | borrow | buy | folder (api 2)
    format  = "epub" | "pdf",       -- display + download extension
    quality = number,               -- higher wins when deduping editions (provider's by default)
    dedup_key = string,             -- normalized title+author signature
    cover_url = string | nil,
    locator = { url = … } | { identifier = … },   -- provider-specific, JSON-safe
    alternates = { {format=, locator=}, … } | nil, -- other formats of the same book
    description, language, year     -- optional metadata (nil when unknown)
    size = bytes | nil,             -- api 2: summed by Download all
    path = { "Course", "Labs" } | nil,  -- api 2: folder titles above the row, outermost first
    dedupe = false | nil,           -- host (Catalog.stamp): its provider opted out; never merged
  }

A folder row (api 2, PROVIDERS.md §4.5) has `action = "folder"`, title,
provider, source, locator, cover_url, path, `subtitle`, `count` (files) and
`size`, and none of the file defaults: no author, no format.
--]]
local Entry = {}

Entry.ACTION = {
    DOWNLOAD = "download",
    BORROW   = "borrow",
    BUY      = "buy",
    FOLDER   = "folder",
}

-- Display order + headings for grouping in the results view. Headings are
-- plain text; the view prefixes the glyph named in ACTION_GLYPH (see glyphs.lua).
Entry.ACTION_ORDER = { "folder", "download", "borrow", "buy" }
Entry.ACTION_HEADING = {
    folder   = "Folders",
    download = "Download",
    borrow   = "Borrow",
    buy      = "Buy",
}
Entry.ACTION_GLYPH = {
    folder   = "folder",
    download = "download",
    borrow   = "book",
    buy      = "cart",
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

local function usable(v)
    return (type(v) == "string" and v ~= "") or type(v) == "number"
end

-- A locator's identity as a string (PROVIDERS.md §4.2): url, else identifier,
-- else id, else every field sorted by name. "" when nothing is usable — the
-- host drops such rows (Catalog.stamp).
function Entry.locatorKey(locator)
    if type(locator) ~= "table" then return "" end
    for __, k in ipairs({ "url", "identifier", "id" }) do
        if usable(locator[k]) then return tostring(locator[k]) end
    end
    local keys = {}
    for k, v in pairs(locator) do
        if type(k) == "string" and usable(v) then keys[#keys + 1] = k end
    end
    if #keys == 0 then return "" end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = k .. "=" .. tostring(locator[k]) end
    return table.concat(parts, ";")
end

-- Stable identity of an edition: provider id + locator (PROVIDERS.md §4.2).
-- Two entries with the same id are the same file, whatever search produced
-- them. Display names never key anything: they may change, ids may not.
function Entry.id(entry)
    return (entry.provider or "?") .. "|" .. Entry.locatorKey(entry.locator)
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

-- A non-negative finite number (bytes, file counts), else nil.
local function amount(v)
    local n = tonumber(v)
    if not n or n ~= n or n < 0 or n == math.huge then return nil end
    return n
end

-- Folder titles above a row, outermost first (PROVIDERS.md §4.5). The depth
-- is kept as given: numbers become strings, and anything that is not a
-- usable string becomes "_". `{}` stays `{}`: "directly under the root".
local PATH_ELEMENT_MAX = 120
local function clean_path(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for i, v in ipairs(list) do
        if type(v) == "number" then v = tostring(v) end
        out[i] = clean(v, PATH_ELEMENT_MAX) or "_"
    end
    return out
end

local ACTION_SET = {}
for __, a in ipairs(Entry.ACTION_ORDER) do ACTION_SET[a] = true end

local function build(t, action)
    local title = clean(t.title, 300) or "Untitled"
    local author = clean(t.author, 200) or "Unknown"
    return {
        title       = title,
        author      = author,
        provider    = clean(t.provider, 32),   -- overwritten by the host (catalog.lua)
        source      = clean(t.source, 60),     -- idem
        action      = action,
        format      = clean(t.format, 8) or "epub",
        quality     = tonumber(t.quality),     -- nil → the host fills in the provider's
        dedup_key   = Entry.makeKey(title, author),
        cover_url   = clean(t.cover, 1000),
        locator     = clean_locator(t.locator),
        alternates  = clean_alternates(t.alternates),
        description = clean(t.description, 4000),
        language    = clean(t.language, 16),
        year        = clean(t.year, 8),
        price       = clean(t.price, 32),      -- buy rows only
        size        = amount(t.size),
        path        = clean_path(t.path),
    }
end

--- A folder row (api 2, PROVIDERS.md §4.5): { title, locator, cover?,
-- subtitle?, path?, count?, size? }. Carries a dedup_key like every built
-- row, so Catalog.stamp keeps it as built; dedupe never merges folders.
function Entry.folder(t)
    t = t or {}
    local title = clean(t.title, 300) or "Untitled"
    return {
        title     = title,
        provider  = clean(t.provider, 32),
        source    = clean(t.source, 60),
        action    = Entry.ACTION.FOLDER,
        quality   = tonumber(t.quality),
        dedup_key = Entry.makeKey(title, ""),
        cover_url = clean(t.cover, 1000),
        locator   = clean_locator(t.locator),
        subtitle  = clean(t.subtitle, 300),
        path      = clean_path(t.path),
        count     = amount(t.count),
        size      = amount(t.size),
    }
end

--- Build an entry from provider data (PROVIDERS.md §4.1). `action` is
-- "download" (default), "borrow", "buy" or "folder" (= Entry.folder);
-- anything else is a download.
function Entry.new(t)
    t = t or {}
    if t.action == Entry.ACTION.FOLDER then return Entry.folder(t) end
    local action = ACTION_SET[t.action] and t.action or Entry.ACTION.DOWNLOAD
    return build(t, action)
end

--- `Entry.new` with action = "download".
function Entry.download(t)
    return build(t or {}, Entry.ACTION.DOWNLOAD)
end

return Entry
