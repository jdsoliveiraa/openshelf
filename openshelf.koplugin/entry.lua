--[[
The OpenShelf result model — the pluggable "result type" abstraction.

Every search result is an entry carrying an `action` (what the user can DO with
it). Today only DOWNLOAD is produced; BORROW/BUY are reserved so library/purchase
sources can slot in later without touching the UI or catalog — the results view
already groups by action.

Entry shape:
  {
    title, author, source,          -- display
    action  = Entry.ACTION.*,       -- download | borrow | buy
    format  = "epub" | "pdf" | ...  -- display + download extension
    quality = number,               -- higher wins when deduping editions
    dedup_key = string,             -- normalized title+author signature
    resolve = function() -> url[, err]   -- DOWNLOAD: where to fetch the file
    -- BORROW/BUY (future) carry handoff info instead of resolve:
    -- where = string, info = string
  }
--]]
local Entry = {}

Entry.ACTION = {
    DOWNLOAD = "download",
    BORROW   = "borrow",
    BUY      = "buy",
}

-- Display order + headings for grouping in the results view.
Entry.ACTION_ORDER = { "download", "borrow", "buy" }
Entry.ACTION_HEADING = {
    download = "⬇  Download",
    borrow   = "📚  Borrow",
    buy      = "🛒  Buy",
}

-- Per-source quality rank. Higher = preferred when the same title appears in
-- several sources (prefer-best-edition). Tune freely.
Entry.QUALITY = {
    ["Standard Ebooks"]   = 100,
    ["Project Gutenberg"] = 80,
    ["Feedbooks"]         = 70,
    ["Internet Archive"]  = 60,
    ["DOAB"]              = 50,
}

local ARTICLES = { ["the"] = true, ["a"] = true, ["an"] = true }

local function strip_accents(s)
    -- best-effort: drop combining marks is overkill; just lowercase here.
    return s:lower()
end

-- Normalize a title: lowercase, drop a leading article, keep alphanumerics.
local function norm_title(title)
    local t = strip_accents(title or "")
    t = t:gsub("[^%w%s]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local first, rest = t:match("^(%w+)%s+(.*)$")
    if first and ARTICLES[first] then t = rest end
    return t
end

-- Author signature: sorted unique lowercase tokens (len>=2) so that
-- "Doyle, Arthur Conan" and "Arthur Conan Doyle" collapse to the same key.
local function author_sig(author)
    local toks = {}
    local seen = {}
    for w in strip_accents(author or ""):gmatch("%a%a+") do
        if not seen[w] then seen[w] = true; toks[#toks+1] = w end
    end
    table.sort(toks)
    return table.concat(toks, " ")
end

function Entry.makeKey(title, author)
    return norm_title(title) .. "|" .. author_sig(author)
end

-- Build a DOWNLOAD entry. `resolve` returns (url) or (nil, err).
-- `cover` is an optional thumbnail image URL.
function Entry.download(t)
    return {
        title    = t.title or "Untitled",
        author   = t.author or "Unknown",
        source   = t.source,
        action   = Entry.ACTION.DOWNLOAD,
        format   = t.format or "epub",
        quality  = t.quality or Entry.QUALITY[t.source] or 0,
        dedup_key = Entry.makeKey(t.title, t.author),
        cover_url = t.cover,
        resolve  = t.resolve,
    }
end

return Entry
