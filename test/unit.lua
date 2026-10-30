--[[
Offline unit test for OpenShelf — pure Lua, no network, no luarocks.
Exercises the pieces that run outside KOReader: the dedup key, dedupe, the
Internet Archive query sanitizer, the OPDS parser, and a guard that no
plugin module is named like a module KOReader has already loaded.

Run (LuaJIT = device semantics; plain lua works too):
    luajit test/unit.lua
Exits non-zero on failure.
--]]
local this = arg[0]:gsub("[^/]*$", "")
if this == "" then this = "./" end
local PLUGIN_DIR = this .. "../openshelf.koplugin"
package.path = PLUGIN_DIR .. "/?.lua;" .. package.path

-- stubs so the provider module loads without LuaSocket
package.preload["http_util"] = function()
    local function offline() return nil, "offline stub" end
    return { getBody = offline, getJSON = offline, head = offline, download = offline }
end
package.preload["logger"] = function() return { warn = function() end, dbg = function() end, info = function() end } end
package.preload["socket.url"] = function()
    return { escape = function(s) return s end }
end
package.preload["json"] = function()
    -- Small real decoder so recorded JSON fixtures load offline (objects,
    -- arrays, strings with escapes, numbers, true/false/null). `null` decodes
    -- to a function, like KOReader's LuaJSON, so the null guards see the
    -- real thing.
    local NULL = function() end
    local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
    local function skip(s, i) return s:find("%S", i) or #s + 1 end
    local function str(s, i)   -- i at the opening quote
        local out, j = {}, i + 1
        while true do
            local c = s:sub(j, j)
            if c == "" then error("unterminated string") end
            if c == '"' then return table.concat(out), j + 1 end
            if c == "\\" then
                local esc = s:sub(j + 1, j + 1)
                if esc == "u" then
                    local cp = tonumber(s:sub(j + 2, j + 5), 16) or 63
                    out[#out + 1] = cp < 128 and string.char(cp) or "?"
                    j = j + 6
                else
                    out[#out + 1] = ESC[esc] or esc
                    j = j + 2
                end
            else
                out[#out + 1] = c
                j = j + 1
            end
        end
    end
    local decode
    decode = function(s, i)
        i = skip(s, i)
        local c = s:sub(i, i)
        if c == "{" then
            local t = {}
            i = skip(s, i + 1)
            if s:sub(i, i) == "}" then return t, i + 1 end
            while true do
                local k, v
                k, i = str(s, skip(s, i))
                i = skip(s, i)
                assert(s:sub(i, i) == ":", "bad object at " .. i)
                v, i = decode(s, i + 1)
                t[k] = v
                i = skip(s, i)
                local d = s:sub(i, i)
                if d == "}" then return t, i + 1 end
                assert(d == ",", "bad object at " .. i)
                i = i + 1
            end
        elseif c == "[" then
            local t = {}
            i = skip(s, i + 1)
            if s:sub(i, i) == "]" then return t, i + 1 end
            while true do
                local v
                v, i = decode(s, i)
                t[#t + 1] = v
                i = skip(s, i)
                local d = s:sub(i, i)
                if d == "]" then return t, i + 1 end
                assert(d == ",", "bad array at " .. i)
                i = i + 1
            end
        elseif c == '"' then
            return str(s, i)
        elseif s:sub(i, i + 3) == "true" then return true, i + 4
        elseif s:sub(i, i + 4) == "false" then return false, i + 5
        elseif s:sub(i, i + 3) == "null" then return NULL, i + 4
        end
        local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        assert(num and num ~= "", "bad JSON at " .. i)
        return tonumber(num), i + #num
    end
    -- Minimal real encoder (strings, numbers, booleans, plain tables) so the
    -- provider check's JSON round trip runs offline. Raises on anything else.
    local function quote(v)
        return '"' .. v:gsub('[%c"\\]', function(ch)
            return ch == '"' and '\\"' or ch == "\\" and "\\\\" or string.format("\\u%04x", ch:byte())
        end) .. '"'
    end
    local encode
    encode = function(v)
        local t = type(v)
        if t == "string" then return quote(v) end
        if t == "number" or t == "boolean" then return tostring(v) end
        if t ~= "table" then error("cannot encode a " .. t) end
        if #v > 0 or next(v) == nil then
            local out = {}
            for i = 1, #v do out[i] = encode(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local out = {}
        for k, x in pairs(v) do out[#out + 1] = quote(tostring(k)) .. ":" .. encode(x) end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return { decode = function(s) return (decode(s, 1)) end, encode = encode, null = NULL }
end

local Entry = require("entry")
local Dedupe = require("dedupe")
local IA = require("providers/internetarchive")
local OPDS = require("opds")

local failures, checks = 0, 0
local function check(cond, label, got)
    checks = checks + 1
    if cond then
        print("ok   " .. label)
    else
        failures = failures + 1
        print("FAIL " .. label .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end
local function eq(a, b, label) check(a == b, label, a) end

print("== Entry.makeKey ==")
eq(Entry.makeKey("The Hound of the Baskervilles", "Doyle, Arthur Conan"),
   Entry.makeKey("Hound of the Baskervilles", "Arthur Conan Doyle"),
   "leading article dropped; author token order ignored")
eq(Entry.makeKey("A Tale of Two Cities", "Charles Dickens"),
   Entry.makeKey("Tale of Two Cities!", "Dickens, Charles"),
   "punctuation ignored")
local accented = Entry.makeKey("Les Misérables", "Victor Hugo")
eq(accented, Entry.makeKey("Les Misérables", "Hugo, Victor"),
   "accented title stable across author forms")
check(accented:find("misérables", 1, true) ~= nil, "multibyte letters kept intact", accented)
check(Entry.makeKey("Emma", "Jane Austen") ~= Entry.makeKey("Persuasion", "Jane Austen"),
      "different titles differ")
eq(Entry.makeKey("Emma", nil), "emma|", "nil author tolerated")

print("== Dedupe.run ==")
local function e(title, source, quality)
    return Entry.download{ title = title, author = "Jane Austen", source = source, quality = quality }
end
local out, collapsed = Dedupe.run({
    e("Emma", "Internet Archive", 60),
    e("Persuasion", "Project Gutenberg", 80),
    e("Emma", "Project Gutenberg", 80),
})
eq(#out, 2, "duplicates collapsed")
eq(collapsed, 1, "collapsed count")
eq(out[1].title, "Emma", "first-seen position kept")
eq(out[1].source, "Project Gutenberg", "upgraded to the higher-quality edition")
eq(out[2].title, "Persuasion", "other entries untouched")

print("== InternetArchive.sanitizeQuery ==")
eq(IA.sanitizeQuery("Dr. Jekyll (and) Mr: Hyde"), "dr. jekyll and mr hyde", "specials stripped, lowercased")
eq(IA.sanitizeQuery('"pride" AND prejudice'), "pride and prejudice", "quotes stripped, AND defused")
eq(IA.sanitizeQuery("  ::: ((( "), nil, "nothing searchable -> nil")
eq(IA.sanitizeQuery(nil), nil, "nil -> nil")
eq(IA.sanitizeQuery("a+b-c/d\\e"), "a b c d e", "operators become spaces")
check(IA.buildQuery("pride and prejudice"):find("AND NOT access-restricted-item:true", 1, true) ~= nil,
      "query excludes lending-library (borrow-only) items", IA.buildQuery("pride and prejudice"))
check(IA.isRestricted({ ["access-restricted-item"] = "true" }), "restricted flag as string")
check(IA.isRestricted({ ["access-restricted-item"] = true }), "restricted flag as boolean")
check(not IA.isRestricted({ ["access-restricted-item"] = "false" }), "unrestricted string")
check(not IA.isRestricted({}), "missing flag -> not restricted")
check(not IA.isRestricted(nil), "nil fields -> not restricted")

print("== OPDS.parse ==")
local feed = [[
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <title>Alice&#39;s Adventures &amp; More</title>
    <author><name>Carroll, Lewis</name></author>
    <summary>A <b>tale</b>.</summary>
    <link rel="http://opds-spec.org/acquisition/buy" href="/buy/1" type="application/epub+zip"/>
    <link rel="http://opds-spec.org/acquisition" href="/dl/1.epub" type="application/epub+zip"/>
  </entry>
  <entry>
    <title>No Epub Here</title>
    <link rel="http://opds-spec.org/acquisition" href="/dl/2.pdf" type="application/pdf"/>
  </entry>
</feed>
]]
local entries = OPDS.parse(feed)
eq(#entries, 2, "two entries parsed")
eq(entries[1].title, "Alice's Adventures & More", "entities unescaped")
eq(entries[1].author, "Carroll, Lewis", "author parsed")
eq(entries[1].summary, "A tale.", "summary tags stripped")
eq(OPDS.acquisition_href(entries[1].links), "/dl/1.epub", "free acquisition chosen, buy link skipped")
eq(OPDS.acquisition_href(entries[2].links), nil, "no epub -> nil")
eq(OPDS.acquisition_href(entries[2].links, "application/pdf"), "/dl/2.pdf", "mime override")


print("== Entry.id / locatorKey ==")
local g1 = Entry.download{ title = "Emma", author = "Jane Austen", source = "Project Gutenberg",
    provider = "gutendex", quality = 80,
    locator = { url = "https://g/158.epub" }, description = "  A   novel.  ", language = "en" }
eq(Entry.id(g1), "gutendex|https://g/158.epub", "id = provider id|url (PROVIDERS.md §4.2)")
eq(Entry.id({ source = "Project Gutenberg", locator = { url = "https://g/158.epub" } }),
   "?|https://g/158.epub", "display name never keys an id")
eq(Entry.locatorKey({ identifier = "emma00aust" }), "emma00aust", "identifier locator")
eq(Entry.locatorKey(nil), "", "nil locator tolerated")
eq(g1.description, "A novel.", "description whitespace collapsed")
eq(Entry.download{ title = "X", source = "DOAB", description = "" }.description, nil, "empty description -> nil")
check(Entry.ACTION_HEADING.borrow:find("\240") == nil, "headings carry no emoji")

local NULL = function() end   -- LuaJSON decodes JSON null as a function
local nulled = Entry.download{ title = NULL, author = NULL, source = "DOAB", cover = NULL,
    locator = { url = "https://d/1", junk = NULL }, description = NULL }
eq(nulled.title, "Untitled", "null title -> Untitled")
eq(nulled.author, "Unknown", "null author -> Unknown")
eq(nulled.cover_url, nil, "null cover -> nil")
eq(nulled.locator.junk, nil, "null locator field dropped")
eq(nulled.locator.url, "https://d/1", "locator url kept")

print("== Entry.new / locator identity ==")
local buy = Entry.new{ action = "buy", title = "Store Book", author = "S", price = " €4.99 ",
    locator = { url = "https://shop/1" } }
eq(buy.action, "buy", "action taken from the constructor")
eq(buy.price, "€4.99", "price kept and trimmed on buy rows")
eq(Entry.new{ title = "X" }.action, "download", "action defaults to download")
eq(Entry.new{ title = "X", action = "steal" }.action, "download", "unknown action becomes download")
eq(Entry.download{ title = "X", action = "buy" }.action, "download", "Entry.download forces download")
eq(Entry.new{ title = "X" }.quality, nil, "quality absent until the host stamps it")
eq(Entry.new{ title = "X", quality = "70" }.quality, 70, "quality coerced to a number")
eq(Entry.new{ title = "X", provider = "examplebooks" }.provider, "examplebooks", "provider field carried")
eq(Entry.locatorKey({ url = "u", identifier = "i", id = 7 }), "u", "url wins")
eq(Entry.locatorKey({ identifier = "i", id = 7 }), "i", "identifier second")
eq(Entry.locatorKey({ id = 7, extra = "x" }), "7", "id third")
eq(Entry.locatorKey({ zeta = "z", alpha = 1 }), "alpha=1;zeta=z", "else every field sorted by name")
eq(Entry.locatorKey({}), "", "empty locator has no identity")
eq(Entry.locatorKey({ url = "" }), "", "blank url is no identity")
eq(Entry.id({ provider = "examplebooks", source = "Example Books", locator = { id = 7 } }),
   "examplebooks|7", "id uses the fallback identity")
eq(Entry.QUALITY, nil, "global per-source quality table gone (providers carry quality)")

print("== Glyphs ==")
local Glyphs = require("glyphs")
eq(Glyphs.utf8(0x41), "A", "ascii passthrough")
eq(Glyphs.utf8(0xE9), "\195\169", "2-byte sequence")
eq(Glyphs.utf8(0xF019), "\239\128\153", "3-byte PUA sequence (download)")
eq(Glyphs.utf8(0x1F4DA), "\240\159\147\154", "4-byte sequence")
eq(#Glyphs.download, 3, "named glyph is a 3-byte string")

print("== Results (slot model) ==")
local Results = require("results")
local RANK = { ["Project Gutenberg"] = 80, ["Internet Archive"] = 60, ["DOAB"] = 50 }
local IDS = { ["Project Gutenberg"] = "gutendex", ["Internet Archive"] = "internetarchive", ["DOAB"] = "doab" }
local function mk(title, source, extra)
    local t = { title = title, author = "A. Author", source = source, provider = IDS[source], quality = RANK[source] }
    for k, v in pairs(extra or {}) do t[k] = v end
    return Entry.download(t)
end
-- Slots are keyed by provider id (DESIGN.md §9.2); names only appear through
-- the label function handed to errors().
local R = Results.new({ "gutendex", "internetarchive", "doab" })
eq(#R:pending(), 3, "all pending at start")
eq(R:pending()[2], "internetarchive", "pending lists provider ids")
R:setProvider("internetarchive", { mk("Emma", "Internet Archive"), mk("Zeta", "Internet Archive") }, true)
local flat = R:flatten()
eq(#flat, 2, "IA alone shows")
eq(flat[1].title, "Emma", "IA first while others pending")
R:setProvider("Project Gutenberg", { mk("Nope", "Project Gutenberg") }, false)
eq(#R:flatten(), 2, "a display name is not a slot")
R:setProvider("gutendex", { mk("Alpha", "Project Gutenberg"), mk("Emma", "Project Gutenberg") }, false)
flat = R:flatten()
eq(flat[1].title, "Alpha", "late Gutenberg lands in its slot ahead of IA")
eq(flat[2].title, "Emma", "Emma kept once")
eq(flat[2].source, "Project Gutenberg", "Emma upgraded to the higher-quality edition")
eq(#flat, 3, "deduped total")
local _, collapsed2 = R:flatten()
eq(collapsed2, 1, "collapsed count")
R:setError("doab", "403 forbidden")
check(R:isComplete(), "complete after the error")
eq(#R:errors(), 1, "error listed")
eq(R:errors()[1], "doab: 403 forbidden", "errors() alone labels by id")
local NAMES = { gutendex = "Project Gutenberg", internetarchive = "Internet Archive", doab = "DOAB" }
eq(R:errors(function(id) return NAMES[id] end)[1], "DOAB: 403 forbidden", "errors(label) shows the display name")
eq(#R:withMore(), 1, "IA reported more")
eq(R:withMore()[1], "internetarchive", "load-more candidate is an id")
flat = R:flatten({ sources = { internetarchive = true } })
eq(#flat, 2, "source filter (by id) keeps IA's own rows")
eq(flat[1].source, "Internet Archive", "filter applied before dedupe")
eq(#R:flatten({ sources = { ["Internet Archive"] = true } }), 0, "filter never matches display names")
R:setProvider("doab", { mk("Paper", "DOAB", { format = "pdf" }) }, false)
eq(#R:flatten({ format = "pdf" }), 1, "format filter")
eq(#R:flatten({ format = "any" }), 4, "format any")
R:appendProvider("internetarchive", { mk("Omega", "Internet Archive") }, false)
eq(R:pageOf("internetarchive"), 2, "append bumps page")
eq(#R:flatten(), 5, "appended rows counted")
check(not R:hasMore(), "no more after last page")

print("== Library ==")
local Library = require("library")
local store, clock = nil, 1000
local lib = Library.new{ load = function() return store end, save = function(d) store = d end,
    now = function() clock = clock + 1; return clock end }
eq(lib:count(), 0, "empty library")
local rec = lib:add(g1, "/mnt/onboard/OpenShelf/Jane Austen - Emma.epub", "abc.jpg")
eq(rec.id, Entry.id(g1), "record id")
eq(lib:count(), 1, "one record")
check(store ~= nil and #store.records == 1, "saved through the injected store")
lib:add(mk("Later", "DOAB", { locator = { url = "https://d/1.pdf" }, format = "pdf" }), "/p/later.pdf")
eq(lib:all()[1].title, "Later", "newest first")
lib:add(g1, "/mnt/onboard/OpenShelf/Jane Austen - Emma.epub")
eq(lib:count(), 2, "re-adding upserts")
eq(lib:all()[1].title, "Emma", "upsert refreshes downloaded_at")
eq(lib:find(g1).cover_file, "abc.jpg", "cover file kept on upsert")
eq(lib:findByPath("/p/later.pdf").source, "DOAB", "findByPath")
local back = Library.toEntry(lib:find(g1))
eq(Entry.id(back), Entry.id(g1), "record round-trips to an entry")
check(lib:remove(rec.id), "remove")
eq(lib:count(), 1, "removed")
local lib2 = Library.new{ load = function() return store end, save = function() end }
eq(lib2:count(), 1, "reload from store")

print("== TTLCache ==")
local TTLCache = require("ttlcache")
local cstore, now = nil, 0
local c = TTLCache.new{ load = function() return cstore end, save = function(d) cstore = d end,
    now = function() return now end, ttl = 100 }
local v, stale = c:get("popular")
check(v == nil and stale, "absent -> nil, stale")
c:set("popular", { 1, 2, 3 })
v, stale = c:get("popular")
check(#v == 3 and not stale, "fresh after set")
now = 101
v, stale = c:get("popular")
check(#v == 3 and stale, "stale after ttl but value kept")

print("== Layout ==")
local Layout = require("layout")
local g = Layout.grid(1072, 1300, { pad = 8, caption_h = 60, target_cols = 3 })
eq(g.cols, 3, "3 columns in portrait")
check(g.rows >= 2 and g.rows <= 3, "2-3 rows fit", g.rows)
eq(g.per_page, g.cols * g.rows, "per_page")
check(g.cover_h > g.cover_w, "cover taller than wide")
local g3 = Layout.grid(1072, 1300, { pad = 8, caption_h = 60, target_cols = 3, target_rows = 3 })
eq(g3.rows, 3, "target_rows honoured by shrinking covers")
check(g3.cover_w < g3.cell_w - 16, "shrunk cover narrower than cell", g3.cover_w)
local gl = Layout.grid(1448, 920, { pad = 8, caption_h = 60, target_cols = 3, portrait_w = 1072 })
check(gl.cols >= 4, "landscape gets more columns", gl.cols)
local sh = Layout.shelf(1040, { gap = 12, target_cover_w = 240 })
eq(sh.count, 4, "four covers on a shelf")
check(sh.count * sh.cover_w + (sh.count - 1) * sh.gap <= 1040, "shelf fits width")
eq(Layout.pageCount(0, 9), 1, "no items -> one page")
eq(Layout.pageCount(10, 9), 2, "pages")
local f1, l1 = Layout.pageRange(2, 9, 10)
check(f1 == 10 and l1 == 10, "last page range")
local f2, l2 = Layout.pageRange(3, 9, 10)
check(f2 == 1 and l2 == 0, "out-of-range page is empty")

print("== Built-in providers (contract shape) ==")
local Catalog = require("catalog")
local Gut = require("providers/gutendex")
local DOABp = require("providers/doab")
local BUILTINS = {
    { "gutendex", "Project Gutenberg", 80, Gut },
    { "internetarchive", "Internet Archive", 60, IA },
    { "doab", "DOAB", 50, DOABp },
}
for i, b in ipairs(BUILTINS) do
    local p = Catalog.providers[i]
    eq(p, b[4], "slot " .. i .. " is " .. b[1])
    eq(b[4].id, b[1], b[1] .. ": id")
    eq(b[4].name, b[2], b[1] .. ": display name unchanged")
    eq(b[4].quality, b[3], b[1] .. ": quality")
    eq(b[4].api, 1, b[1] .. ": api 1")
    eq(Catalog.byId(b[1]), b[4], b[1] .. ": byId")
    eq(Catalog.nameOf(b[1]), b[2], b[1] .. ": nameOf gives the display name")
    eq(Catalog.ids()[i], b[1], b[1] .. ": ids() in slot order")
    local f = assert(io.open(PLUGIN_DIR .. "/providers/" .. b[1] .. ".lua", "r"))
    local src = f:read("*a"); f:close()
    local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")   -- comments may mention it
    check(code:find("require%s*[%(\"']") == nil, b[1] .. ": no require() — ctx is the whole API")
end
eq(#Catalog.providers, 3, "exactly the three built-ins registered")
local CTX = Catalog.ctxFor(Gut)

print("== Provider parsers (fixtures) ==")
local gut_entries, gut_more = Gut.parse({
    next = "https://gutendex.com/books/?page=2",
    results = {
        { id = 158, title = "Emma", authors = { { name = "Austen, Jane" } },
          summaries = { "A comedy of manners." }, languages = { "en" },
          formats = { ["application/epub+zip"] = "https://g/158.epub", ["image/jpeg"] = "https://g/158.jpg" } },
        { id = 1, title = "No epub", authors = {}, formats = { ["text/plain"] = "x" } },
    } }, 10, CTX)
eq(#gut_entries, 1, "gutendex: only epub items")
eq(gut_entries[1].locator.url, "https://g/158.epub", "gutendex: locator url")
eq(gut_entries[1].description, "A comedy of manners.", "gutendex: summary")
eq(gut_entries[1].language, "en", "gutendex: language")
check(gut_more, "gutendex: has_more from next")
eq(Gut.resolve(gut_entries[1].locator, CTX), "https://g/158.epub", "gutendex: resolve")
eq(gut_entries[1].source, nil, "gutendex: provider does not label its rows")
local gut_stamped = Catalog.stamp(Gut, gut_entries)
eq(gut_stamped[1].provider, "gutendex", "gutendex: host stamps provider id")
eq(gut_stamped[1].source, "Project Gutenberg", "gutendex: host stamps display name")
eq(gut_stamped[1].quality, 80, "gutendex: host fills quality")
local ia_entries, ia_more = IA.parse({ response = { numFound = 25, docs = {
    { identifier = "emma00aust", title = "Emma", creator = { "Austen, Jane" },
      description = "Scan.", date = "1816-01-01T00:00:00Z", language = "eng" } } } }, 10, 1, CTX)
eq(ia_entries[1].locator.identifier, "emma00aust", "ia: locator identifier")
eq(ia_entries[1].year, "1816", "ia: year from date")
eq(ia_entries[1].author, "Austen, Jane", "ia: first creator")
check(ia_more, "ia: more pages when numFound > page*limit")
local ia_mixed = IA.parse({ response = { numFound = 2, docs = {
    { identifier = "free1", title = "Free" },
    { identifier = "lend1", title = "Lending", ["access-restricted-item"] = "true" } } } }, 10, 1, CTX)
eq(#ia_mixed, 1, "ia: restricted docs skipped client-side")
eq(ia_mixed[1].locator.identifier, "free1", "ia: the free one kept")
local _, ia_more2 = IA.parse({ response = { numFound = 25, docs = {} } }, 10, 3, CTX)
check(not ia_more2, "ia: no more on last page")
local doab_entries, doab_more = DOABp.parse({
    { name = "Open Book", metadata = { { key = "dc.contributor.author", value = "Someone" },
        { key = "dc.description.abstract", value = "About things." },
        { key = "dc.date.issued", value = "2021-05-01" }, { key = "dc.language", value = "English" } },
      bitstreams = { { bundleName = "ORIGINAL", mimeType = "application/pdf", retrieveLink = "/rest/b/1" },
                     { bundleName = "THUMBNAIL", retrieveLink = "/rest/t/1" } } },
}, 1, CTX)
eq(doab_entries[1].format, "pdf", "doab: pdf fallback")
eq(doab_entries[1].locator.url, "https://directory.doabooks.org/rest/b/1", "doab: absolute locator")
eq(doab_entries[1].year, "2021", "doab: year")
eq(doab_entries[1].cover_url, "https://directory.doabooks.org/rest/t/1", "doab: thumbnail")
check(doab_more, "doab: full page -> maybe more")
local doab_both = DOABp.parse({
    { name = "Both", metadata = {}, bitstreams = {
        { bundleName = "ORIGINAL", mimeType = "application/pdf", retrieveLink = "/rest/b/pdf" },
        { bundleName = "ORIGINAL", mimeType = "application/epub+zip", retrieveLink = "/rest/b/epub" } } },
}, 5, CTX)
eq(doab_both[1].format, "epub", "doab: epub preferred as primary")
eq(doab_both[1].alternates[1].format, "pdf", "doab: pdf offered as alternate")
eq(doab_both[1].alternates[1].locator.url, "https://directory.doabooks.org/rest/b/pdf", "doab: alternate locator")

print("== Gutendex paging: every match exactly once (#1) ==")
-- Synthetic Gutendex: fixed 32 rows per page, `next` a URL string until the
-- last page and JSON null (a function on the device) there. Every 7th row
-- has no EPUB and is dropped by the parser, but still counts toward offsets.
do
    local function gutendex(total)
        local requests = 0
        local function getJSON(url)
            requests = requests + 1
            local n = tonumber(url:match("[?&]page=(%d+)"))
            local first = (n - 1) * 32 + 1
            if first > math.max(total, 1) then return nil, "404 Invalid page." end
            local results = {}
            for id = first, math.min(first + 31, total) do
                local formats = { ["image/jpeg"] = "https://g/" .. id .. ".jpg" }
                if id % 7 ~= 0 then formats["application/epub+zip"] = "https://g/" .. id .. ".epub" end
                results[#results + 1] = { id = id, title = "Book " .. id, authors = { { name = "A" } },
                    languages = { "pt" }, formats = formats }
            end
            local more = first + 31 < total
            return { count = total, results = results,
                     next = more and ("https://gutendex.com/books/?page=" .. (n + 1)) or NULL }
        end
        local ctx = setmetatable({ http = { getJSON = getJSON } }, { __index = CTX })
        return ctx, function() local r = requests; requests = 0; return r end
    end
    local providers = { { "gutendex", Gut }, { "gutenberg_pt", dofile(this .. "../examples/gutenberg_pt.lua") } }
    for __, pv in ipairs(providers) do
        for ___, total in ipairs({ 0, 5, 32, 33, 64, 75, 100 }) do
            for ____, limit in ipairs({ 10, 15, 30 }) do
                local ctx, reqs = gutendex(total)
                local seen, dups, ok_more, max_req, ok_size = {}, 0, true, 0, true
                local page, more = 0, true
                while more and page < 50 do
                    page = page + 1
                    local rows, has_more = pv[2].search("q", limit, page, ctx)
                    assert(rows, pv[1] .. ": search failed: " .. tostring(has_more))
                    max_req = math.max(max_req, reqs())
                    if #rows > limit then ok_size = false end
                    for _____, r in ipairs(rows) do
                        local id = tonumber(r.locator.url:match("/(%d+)%.epub$"))
                        if seen[id] then dups = dups + 1 end
                        seen[id] = true
                    end
                    -- has_more is true exactly while unshown offsets remain
                    if has_more ~= (page * limit < total) then ok_more = false end
                    more = has_more
                end
                local missing = 0
                for id = 1, total do
                    if id % 7 ~= 0 and not seen[id] then missing = missing + 1 end
                end
                local tag = ("%s total=%d limit=%d"):format(pv[1], total, limit)
                eq(missing, 0, tag .. ": every EPUB row shown")
                eq(dups, 0, tag .. ": no row shown twice")
                check(ok_more, tag .. ": has_more true exactly while rows remain")
                check(ok_size, tag .. ": never more than limit rows")
                check(max_req <= 2, tag .. ": at most two requests per page", max_req)
            end
        end
    end
end

print("== Gutendex shelves: See all pages, every row once (#12) ==")
-- Same synthetic Gutendex as #1, keyed by the shelf's sort. Browse pages at
-- the browse page size (32): shelf page N is exactly Gutendex page N.
do
    local function gutendex(total)
        local requests, urls = 0, {}
        local function getJSON(url)
            requests = requests + 1
            urls[#urls + 1] = url
            local n = tonumber(url:match("[?&]page=(%d+)")) or 1   -- page 1 has no page=
            local first = (n - 1) * 32 + 1
            if first > math.max(total, 1) then return nil, "404 Invalid page." end
            local results = {}
            for id = first, math.min(first + 31, total) do
                local formats = { ["image/jpeg"] = "https://g/" .. id .. ".jpg" }
                if id % 7 ~= 0 then formats["application/epub+zip"] = "https://g/" .. id .. ".epub" end
                results[#results + 1] = { id = id, title = "Book " .. id, authors = { { name = "A" } },
                    languages = { "en" }, formats = formats }
            end
            local more = first + 31 < total
            return { count = total, results = results,
                     next = more and ("https://gutendex.com/books/?page=" .. (n + 1)) or NULL }
        end
        local ctx = setmetatable({ http = { getJSON = getJSON } }, { __index = CTX })
        return ctx, function() local r = requests; requests = 0; return r end, urls
    end
    for __, key in ipairs({ "popular", "new" }) do
        for ___, total in ipairs({ 0, 5, 12, 13, 31, 32, 33, 64, 75, 100 }) do
            local ctx, reqs = gutendex(total)
            local seen, dups, ok_more, max_req, ok_size = {}, 0, true, 0, true
            local page, more = 0, true
            while more and page < 50 do
                page = page + 1
                local rows, has_more = Gut.browse(key, 32, ctx, page)
                assert(rows, "gutendex browse failed: " .. tostring(has_more))
                max_req = math.max(max_req, reqs())
                if #rows > 32 then ok_size = false end
                if type(has_more) ~= "boolean" then ok_more = false end
                for ____, r in ipairs(rows) do
                    local id = tonumber(r.locator.url:match("/(%d+)%.epub$"))
                    if seen[id] then dups = dups + 1 end
                    seen[id] = true
                end
                if has_more ~= (page * 32 < total) then ok_more = false end
                more = has_more
            end
            local missing = 0
            for id = 1, total do
                if id % 7 ~= 0 and not seen[id] then missing = missing + 1 end
            end
            local tag = ("gutendex:%s total=%d"):format(key, total)
            eq(missing, 0, tag .. ": every EPUB row shown across pages")
            eq(dups, 0, tag .. ": no row shown twice")
            check(ok_more, tag .. ": has_more is a boolean, true exactly while rows remain")
            check(ok_size, tag .. ": never more than 32 rows")
            check(max_req <= 1, tag .. ": one request per page", max_req)
        end
    end
    local ctx, __, urls = gutendex(100)
    local p1 = Gut.browse("popular", 32, ctx)
    local p1b = Gut.browse("popular", 32, ctx, 1)
    eq(#p1, #p1b, "browse without page = page 1")
    eq(#p1, 28, "page 1 = every EPUB row of Gutendex page 1 (32 rows, 4 without EPUB)")
    eq(p1[1].locator.url, p1b[1].locator.url, "browse without page = page 1 (same rows)")
    eq(urls[1], "https://gutendex.com/books/?sort=popular", "page 1 keeps the plain (cached) shelf URL")
    Gut.browse("new", 32, ctx, 3)
    eq(urls[#urls], "https://gutendex.com/books/?page=3&sort=descending",
       "new shelf page 3 reads Gutendex page 3, in Gutendex's own `next` URL shape")
    local none, berr = Gut.browse("nope", 32, ctx, 1)
    check(none == nil and tostring(berr):find("unknown shelf", 1, true), "unknown shelf key -> error", berr)
    local fctx = setmetatable({ http = { getJSON = function() return nil, "HTTP 503" end } }, { __index = CTX })
    local frows, ferr = Gut.browse("popular", 32, fctx, 2)
    check(frows == nil and ferr == "HTTP 503", "a failed request -> nil, err", ferr)
end

print("== ShelfPager (See all Load more state, #12) ==")
do
    local ShelfPager = require("shelf_pager")
    local function row(n) return { provider = "gutendex", title = "B" .. n, locator = { url = "https://g/" .. n } } end
    local function rows(a, b) local t = {} for i = a, b do t[#t + 1] = row(i) end return t end
    local pg = ShelfPager.new{ entries = rows(1, 12), has_more = true }
    eq(#pg.entries, 12, "page 1 seeded")
    check(pg:canLoadMore(), "has_more -> Load more")
    eq(pg:begin(), 2, "next page is 2")
    check(not pg:canLoadMore(), "no second request while one is running")
    eq(pg:begin(), nil, "begin refused while loading")
    eq(pg:append(rows(11, 22), true), 10, "append drops rows already shown")
    eq(#pg.entries, 22, "appended in order")
    eq(pg.entries[13].title, "B13", "new rows follow the old ones")
    eq(pg:begin(), 3, "then page 3")
    pg:fail("timed out")
    eq(pg.err, "timed out", "failure remembered for the status line")
    check(pg:canLoadMore(), "failure keeps Load more for a retry")
    eq(pg:begin(), 3, "the retry asks for the same page")
    check(pg.err == nil, "a retry clears the error")
    eq(pg:append(rows(23, 25), false), 3, "last page appended")
    eq(pg.page, 3, "page count advanced")
    check(not pg:canLoadMore(), "has_more false -> no Load more")
    eq(pg:begin(), nil, "never asks past a page that said no more")
    local old = ShelfPager.new{ entries = rows(1, 12) }
    check(not old:canLoadMore(), "no has_more (old provider) -> no Load more")
    local legacy = ShelfPager.new{ entries = rows(1, 3), has_more = "yes" }
    check(not legacy:canLoadMore(), "only has_more == true counts")
    -- cache shape
    local ce, more, outdated = ShelfPager.unpack(ShelfPager.pack(rows(1, 2), true, 32), 32)
    check(#ce == 2 and more == true and outdated == false, "pack/unpack keeps entries and has_more at the same size")
    ce, more, outdated = ShelfPager.unpack(ShelfPager.pack(rows(1, 2), true, 12), 32)
    check(#ce == 2 and more == true and outdated == true, "cache fetched at another page size -> outdated (refresh)")
    ce, more, outdated = ShelfPager.unpack({ entries = rows(1, 2), has_more = true }, 32)
    check(#ce == 2 and more == true and outdated == true, "cache without a size (first #12 draft, 12 rows) -> outdated")
    ce, more, outdated = ShelfPager.unpack(rows(1, 2), 32)
    check(#ce == 2 and more == false and outdated == true, "pre-#12 cache (bare list) -> has_more false, outdated")
    ce = ShelfPager.unpack(nil)
    eq(ce, nil, "nothing cached -> nil")
    local JSON_ = require("json")
    ce, more, outdated = ShelfPager.unpack(JSON_.decode(JSON_.encode(ShelfPager.pack(rows(1, 1), true, 32))), 32)
    check(#ce == 1 and more == true and outdated == false, "cache value survives JSON")
end

print("== Library migration v1 -> v2 (recorded v0.5 file) ==")
-- test/fixtures/library_v1.json was written by the v0.5 library/entry/provider
-- code (commit 71eb2a7) and KOReader-style JSON: ids are "<display name>|<locator>".
local JSON = require("json")
local function read_fixture(name)
    local f = assert(io.open(this .. "fixtures/" .. name, "rb"))
    local body = f:read("*a"); f:close()
    return JSON.decode(body)
end
local v1 = read_fixture("library_v1.json")
eq(v1.version, 1, "fixture is a version-1 file")
eq(#v1.records, 3, "fixture holds one record per v0.5 source")
eq(v1.records[1].id, "Project Gutenberg|https://www.gutenberg.org/ebooks/158.epub3.images", "fixture ids are name-keyed")
local saved, backups = nil, {}
local mlib = Library.new{
    load = function() return v1 end,
    save = function(d) saved = d end,
    backup = function(d) backups[#backups + 1] = d end,
}
eq(mlib:count(), 3, "My books unchanged after migration")
eq(#backups, 1, ".v1.bak written once, before the rewrite")
eq(backups[1].version, 1, "backup is the untouched v1 data")
eq(backups[1].records[1].id, "Project Gutenberg|https://www.gutenberg.org/ebooks/158.epub3.images", "backup keeps the old ids")
check(saved ~= nil and saved.version == 2, "migrated file saved as version 2", saved and saved.version)
local by_title = {}
for __, r in ipairs(mlib:all()) do by_title[r.title] = r end
local emma, pride, oa = by_title["Emma"], by_title["Pride and prejudice"], by_title["Open Access and the Humanities"]
eq(emma.provider, "gutendex", "Project Gutenberg record -> gutendex")
eq(pride.provider, "internetarchive", "Internet Archive record -> internetarchive")
eq(oa.provider, "doab", "DOAB record -> doab")
eq(emma.id, "gutendex|https://www.gutenberg.org/ebooks/158.epub3.images", "record rekeyed by provider id")
eq(pride.id, "internetarchive|prideprejudice00aust", "identifier locator rekeyed")
eq(oa.id, "doab|https://directory.doabooks.org/rest/bitstreams/35c4a0e2-5a7f-4b1b-8c8e-1a2b3c4d5e6f/retrieve", "DOAB rekeyed")
eq(emma.quality, 80, "quality recorded from the v0.5 rank (Gutenberg)")
eq(pride.quality, 60, "quality recorded (Internet Archive)")
eq(oa.quality, 50, "quality recorded (DOAB)")
eq(emma.source, "Project Gutenberg", "display name kept on the record")
eq(emma.path, "/mnt/onboard/OpenShelf/Austen, Jane - Emma.epub", "path untouched")
eq(emma.cover_file, "a1b2c3d4e5f60718.jpg", "cover file untouched")
eq(emma.downloaded_at, 1761433600, "download time untouched")
eq(emma.locator.id, 158, "numeric locator field survives the JSON round trip")
-- A v0.6 search row for the same edition must hit the migrated record (the ✓).
local fresh_g = Catalog.stamp(Gut, Gut.parse({ results = { { id = 158, title = "Emma",
    authors = { { name = "Austen, Jane" } },
    formats = { ["application/epub+zip"] = "https://www.gutenberg.org/ebooks/158.epub3.images" } } } }, 10, CTX))
check(mlib:find(fresh_g[1]) == emma, "fresh Gutenberg row finds its migrated record")
local fresh_ia = Catalog.stamp(IA, IA.parse({ response = { numFound = 1, docs = {
    { identifier = "prideprejudice00aust", title = "Pride and prejudice" } } } }, 10, 1, CTX))
check(mlib:find(fresh_ia[1]) == pride, "fresh Internet Archive row finds its migrated record")
local back2 = Library.toEntry(emma)
eq(back2.provider, "gutendex", "toEntry carries the provider id")
eq(back2.quality, 80, "toEntry carries the recorded quality")
eq(Entry.id(back2), emma.id, "toEntry round-trips to the record id")
local relib = Library.new{ load = function() return saved end, save = function() end,
    backup = function(d) backups[#backups + 1] = d end }
eq(relib:count(), 3, "migrated file reloads")
eq(#backups, 1, "no second backup once the file is version 2")
eq(relib:find(fresh_g[1]).id, emma.id, "reloaded record still keyed by id")
local odd_saved, odd_backups = nil, 0
local odd = Library.new{
    load = function() return { version = 1, records = { { id = "Standard Ebooks|https://se/1", title = "Odd",
        source = "Standard Ebooks", locator = { url = "https://se/1" }, path = "/x/odd.epub" } } } end,
    save = function(d) odd_saved = d end, backup = function() odd_backups = odd_backups + 1 end }
eq(odd:count(), 1, "record from an unknown v0.5 source is kept, not dropped")
eq(odd:all()[1].provider, nil, "unknown source gets no provider id")
eq(odd:all()[1].id, "Standard Ebooks|https://se/1", "unknown source keeps its old id")
eq(odd_backups, 1, "unknown-source file still backed up once")
eq(odd_saved.version, 2, "and still bumped to version 2")
local empty_backups = 0
local fresh = Library.new{ load = function() return nil end, save = function() end,
    backup = function() empty_backups = empty_backups + 1 end }
eq(fresh:count(), 0, "no file -> empty library")
eq(empty_backups, 0, "no file -> nothing to back up")
local added = fresh:add(fresh_g[1], "/p/emma.epub")
eq(added.provider, "gutendex", "new records carry the provider id")
eq(added.quality, 80, "new records carry the entry's quality")
eq(added.id, "gutendex|https://www.gutenberg.org/ebooks/158.epub3.images", "new records keyed by provider id")

print("== Catalog ==")
eq(#Catalog.ids(), 3, "three providers")
eq(Catalog.nameOf("nope"), nil, "nameOf unknown id -> nil")
eq(Catalog.byName, nil, "byName gone: names are not keys")
eq(Catalog.providerNames, nil, "providerNames gone: use ids() + nameOf()")
eq(Catalog.resolve(gut_stamped[1]).url, "https://g/158.epub", "catalog resolve dispatches by provider id")
local u0, cerr0 = Catalog.resolve({ source = "Project Gutenberg", locator = { url = "https://g/x.epub" } })
check(u0 == nil and cerr0 ~= nil, "resolve without a provider id fails (records are migrated, names never route)", u0)
local u, cerr = Catalog.resolve({ provider = "nope", locator = {} })
check(u == nil and cerr ~= nil, "unknown provider -> error")

print("== Catalog.resolve -> { url, headers } (PROVIDERS.md 5.2) ==")
local N = Catalog.normalizeResolve
eq(N("https://x/1.epub").url, "https://x/1.epub", "bare url string becomes { url }")
eq(N("https://x/1.epub").headers, nil, "bare url carries no headers")
local nt = N({ url = "https://x/2", headers = { Authorization = "Bearer t", ["X-Num"] = 7,
    Nested = {}, Null = function() end } })
eq(nt.url, "https://x/2", "table url kept")
eq(nt.headers.Authorization, "Bearer t", "string header kept")
eq(nt.headers["X-Num"], "7", "numeric header value sent as text")
eq(nt.headers.Nested, nil, "table header value dropped")
eq(nt.headers.Null, nil, "null (function) header value dropped")
eq(N({ url = "https://x/3" }).headers, nil, "table without headers -> no headers")
eq(N({ url = "https://x/3", headers = "nope" }).headers, nil, "non-table headers ignored")
eq(N({ url = "https://x/4", extra = 1 }).extra, nil, "only url and headers survive normalization")
local nr, nerr = N(nil, "not available")
check(nr == nil and nerr == "not available", "nil + reason passed through verbatim", nerr)
nr, nerr = N(nil)
check(nr == nil and type(nerr) == "string" and #nerr > 0, "nil without reason gets a default message", nerr)
nr, nerr = N({})
check(nr == nil and type(nerr) == "string", "table without url -> error", nerr)
nr, nerr = N("")
check(nr == nil and type(nerr) == "string", "empty string -> error", nerr)
nr, nerr = N({ url = 42 })
check(nr == nil and type(nerr) == "string", "non-string url -> error", nerr)
nr, nerr = N(function() end)
check(nr == nil and type(nerr) == "string", "null (function) -> error", nerr)
Catalog.register{ api = 1, id = "authy", name = "Authy",
    search = function() return {}, false end,
    resolve = function(loc)
        if loc.auth then return { url = loc.url, headers = { Authorization = "Bearer t" } } end
        if loc.url then return loc.url end
        return nil, "gone"
    end }
local ar = Catalog.resolve({ provider = "authy", locator = { url = "https://a/1", auth = true } })
eq(ar.url, "https://a/1", "resolve keeps the provider's url")
eq(ar.headers.Authorization, "Bearer t", "resolve passes the provider's headers through")
eq(Catalog.resolve({ provider = "authy", locator = { url = "https://a/2" } }).headers, nil,
   "string resolve normalized to a table without headers")
local gr, gerr = Catalog.resolve({ provider = "authy", locator = {} })
check(gr == nil and gerr == "gone", "provider's reason shown verbatim", gerr)
local groups = Catalog.group({ gut_entries[1], ia_entries[1] })
eq(#groups, 1, "single download group")
eq(groups[1].glyph, "download", "group carries a glyph name")

print("== Catalog.register (provider contract) ==")
local function fake(over)
    local p = { api = 1, id = "fake", name = "Fake Books", quality = 42,
        search = function() return {}, false end,
        resolve = function(loc) return loc.url end }
    for k, val in pairs(over or {}) do p[k] = val end
    return p
end
local function reason_of(p)
    local ok, why = Catalog.register(p)
    return (not ok) and why or nil
end
check(reason_of(fake{ search = false }) ~= nil, "missing search rejected", reason_of(fake{ search = false }))
check(tostring(reason_of(fake{ search = false })):find("search", 1, true) ~= nil,
      "reason names the missing function")
check(Catalog.register(fake{ id = "fake_ok" }), "valid provider registers")
eq(Catalog.byId("fake_ok").name, "Fake Books", "byId finds the registered provider")
eq(Catalog.ids()[#Catalog.ids()], "fake_ok", "registered provider appended last")
check(tostring(reason_of(fake{ resolve = false })):find("resolve", 1, true) ~= nil, "missing resolve rejected with reason")
check(tostring(reason_of(fake{ api = 3 })):find("api", 1, true) ~= nil, "api 3 rejected", reason_of(fake{ api = 3 }))
check(tostring(reason_of(fake{ api = "1" })):find("api", 1, true) ~= nil, "api as a string rejected")
check(tostring(reason_of(fake{ id = "Bad-Id" })):find("id", 1, true) ~= nil, "uppercase/dash id rejected", reason_of(fake{ id = "Bad-Id" }))
check(reason_of(fake{ id = "9lives" }) ~= nil, "id must start with a letter")
check(reason_of(fake{ id = string.rep("a", 33) }) ~= nil, "id longer than 32 bytes rejected")
check(reason_of(fake{ id = false }) ~= nil, "missing id rejected")
check(reason_of(fake{ name = false }) ~= nil, "missing name rejected")
check(reason_of(fake{ name = string.rep("n", 61) }) ~= nil, "name longer than 60 bytes rejected")
local shelved = fake{ id = "fake_shelf", shelves = { { key = "popular", title = "Popular" } } }
check(tostring(reason_of(shelved)):find("browse", 1, true) ~= nil, "shelves without browse rejected", reason_of(shelved))
shelved.browse = function() return {} end
check(Catalog.register(shelved), "shelves with browse accepted")
check(reason_of(fake{ id = "fake_badkey", browse = function() end,
    shelves = { { key = "Not Valid", title = "x" } } }) ~= nil, "shelf key must follow the id pattern")
check(tostring(reason_of(fake{ id = "gutendex" })):find("duplicate id gutendex", 1, true) ~= nil,
      "built-in id cannot be taken over")
local dup = reason_of(fake{ id = "fake_ok" })
check(dup ~= nil and dup:find("duplicate id fake_ok", 1, true) ~= nil, "duplicate id rejected with the id named", dup)
eq(Catalog.byId("fake_ok").quality, 42, "first registrant kept on duplicate")
check(reason_of("not a table") ~= nil, "non-table rejected without crashing")
local listed = {}
for __, inv in ipairs(Catalog.invalid()) do listed[#listed + 1] = tostring(inv.name or inv.id) .. ": " .. inv.reason end
check(#Catalog.invalid() >= 10, "rejects are listed for Sources", #Catalog.invalid())
check(table.concat(listed, "\n"):find("duplicate id fake_ok", 1, true) ~= nil, "duplicate listed with reason")

print("== host stamping + ctx (searchOne) ==")
local seen_ctx
Catalog.register{ api = 1, id = "stamper", name = "Stamper", quality = 33,
    search = function(_q, _l, _p, ctx)
        seen_ctx = ctx
        return {
            ctx.Entry.new{ title = "Labelled", author = "A", source = "Project Gutenberg", provider = "gutendex",
                quality = 5, locator = { url = "https://s/1" } },
            ctx.Entry.new{ title = "Unranked", author = "B", locator = { identifier = "s2" } },
            ctx.Entry.new{ title = "Homeless", author = "C" },
        }, true
    end,
    resolve = function(loc) return loc.url end }
local stamped, more = Catalog.searchOne("stamper", "anything", 10, 1)
eq(#stamped, 2, "row without a usable locator dropped")
local byname, byname_err = Catalog.searchOne("Stamper", "anything", 10, 1)
check(byname == nil and tostring(byname_err):find("unknown source", 1, true) ~= nil,
      "searchOne takes a provider id, not a display name", byname_err)
eq(stamped[1].provider, "stamper", "provider overwritten by the host")
eq(stamped[1].source, "Stamper", "source overwritten by the host")
eq(stamped[1].quality, 5, "row's own quality kept")
eq(stamped[2].quality, 33, "missing quality defaults to the provider's")
eq(stamped[2].source, "Stamper", "every row stamped")
check(more == true, "has_more passed through")
check(type(seen_ctx) == "table", "search received a ctx")
eq(type(seen_ctx.http.getJSON), "function", "ctx.http.getJSON")
eq(type(seen_ctx.http.getBody), "function", "ctx.http.getBody")
eq(type(seen_ctx.http.head), "function", "ctx.http.head")
eq(type(seen_ctx.http.download), "function", "ctx.http.download")
eq(type(seen_ctx.json.decode), "function", "ctx.json.decode")
eq(type(seen_ctx.json.encode), "function", "ctx.json.encode")
eq(type(seen_ctx.url_escape), "function", "ctx.url_escape")
eq(type(seen_ctx.settings), "table", "ctx.settings is a table")
eq(seen_ctx.Entry.new, Entry.new, "ctx.Entry is the entry module")
eq(seen_ctx.OPDS.parse, OPDS.parse, "ctx.OPDS is the OPDS parser")
eq(type(seen_ctx.log), "function", "ctx.log")
check(pcall(seen_ctx.log, "hello", 42), "ctx.log accepts any values")
local none, why = Catalog.searchOne("stamper", "", 10, 1)
check(none ~= nil or why ~= nil, "searchOne never returns nothing")
Catalog.register{ api = 1, id = "thrower", name = "Thrower",
    search = function() error("boom") end, resolve = function() end }
local tres, terr = Catalog.searchOne("thrower", "x", 10, 1)
check(tres == nil and tostring(terr):find("boom", 1, true) ~= nil, "provider error caught and reported", terr)
local sa_entries, sa_errors, sa_collapsed, sa_results = Catalog.searchAll("anything",
    { enabled = { stamper = true, thrower = true }, per_provider = 5 })
eq(#sa_entries, 2, "searchAll (sequential) over the enabled id set")
eq(sa_collapsed, 0, "nothing collapsed")
eq(sa_results.order[1], "stamper", "searchAll slots keyed by id, in registration order")
eq(sa_results.order[2], "thrower", "only the enabled ids get slots")
eq(#sa_errors, 1, "the throwing provider is reported")
check(sa_errors[1]:find("^Thrower: ") ~= nil, "searchAll errors carry the display name", sa_errors[1])

print("== Settings fields schema (PROVIDERS.md 7) ==")
local function with_fields(id, fields)
    return fake{ id = id, settings = fields }
end
local ALL_FIELDS = {
    { key = "token", title = "API token", type = "secret", required = true, hint = "Stored in plain text" },
    { key = "user", title = "User", type = "text", default = "guest" },
    { key = "covers", title = "Show covers", type = "toggle", default = true },
    { key = "lang", title = "Language", type = "choice", choices = { "any", "en", "pt" }, default = "any" },
}
check(Catalog.register(with_fields("fields_ok", ALL_FIELDS)), "all four field types accepted")
local function field_reason(field) return reason_of(with_fields("fields_bad", { field })) end
check(field_reason("x") ~= nil, "a field must be a table")
check(tostring(field_reason{ key = "Bad Key", title = "T", type = "text" }):find("key", 1, true) ~= nil,
      "field key follows the id pattern", field_reason{ key = "Bad Key", title = "T", type = "text" })
check(field_reason{ key = "k", type = "text" } ~= nil, "field needs a title")
check(tostring(field_reason{ key = "k", title = "T", type = "number" }):find("type", 1, true) ~= nil,
      "unknown field type rejected")
check(field_reason{ key = "k", title = "T", type = "choice" } ~= nil, "choice needs choices")
check(field_reason{ key = "k", title = "T", type = "choice", choices = {} } ~= nil, "choice needs at least one choice")
check(field_reason{ key = "k", title = "T", type = "choice", choices = { "a" }, default = "b" } ~= nil,
      "choice default must be one of the choices")
check(field_reason{ key = "k", title = "T", type = "toggle", required = true } ~= nil, "toggle cannot be required")
check(field_reason{ key = "k", title = "T", type = "toggle", default = "yes" } ~= nil, "toggle default is a boolean")
check(field_reason{ key = "k", title = "T", type = "text", default = 3 } ~= nil, "text default is a string")
check(field_reason{ key = "k", title = "T", type = "text", hint = 3 } ~= nil, "hint is a string")
check(tostring(reason_of(with_fields("fields_dup", { { key = "k", title = "A", type = "text" },
    { key = "k", title = "B", type = "toggle" } }))):find("duplicate", 1, true) ~= nil, "duplicate field key rejected")

print("== Settings field values + Needs setup ==")
local Fields = require("openshelf_fields")
local v0 = Fields.values(ALL_FIELDS, nil)
eq(v0.token, nil, "nothing stored, no default -> nil")
eq(v0.user, "guest", "text default applied")
eq(v0.covers, true, "toggle default applied")
eq(v0.lang, "any", "choice default applied")
local fv1 = Fields.values(ALL_FIELDS, { token = "s3cret", user = "", covers = false, lang = "pt", extra = "x" })
eq(fv1.token, "s3cret", "stored secret passed through")
eq(fv1.user, nil, "empty text is nil, even over a default")
eq(fv1.covers, false, "a stored false toggle beats a true default")
eq(fv1.lang, "pt", "stored choice kept")
eq(fv1.extra, nil, "undeclared keys never reach ctx.settings")
local v2 = Fields.values(ALL_FIELDS, { token = "   ", covers = "yes", lang = "klingon", user = 7 })
eq(v2.token, nil, "whitespace-only text is empty")
eq(v2.covers, true, "wrong-typed toggle falls back to the default")
eq(v2.lang, "any", "a choice no longer offered falls back to the default")
eq(v2.user, "guest", "wrong-typed text falls back to the default")
eq(Fields.missing(ALL_FIELDS, {}), "token", "required secret empty -> needs setup on that field")
eq(Fields.missing(ALL_FIELDS, { token = "" }), "token", "empty string counts as missing")
eq(Fields.missing(ALL_FIELDS, { token = "abc" }), nil, "required field filled -> ready")
eq(Fields.missing(nil, {}), nil, "no schema -> never needs setup")
local REQ_CHOICE = { { key = "a", title = "A", type = "text" },
    { key = "region", title = "Region", type = "choice", choices = { "eu", "us" }, required = true } }
eq(Fields.missing(REQ_CHOICE, {}), "region", "required choice without default needs setup")
eq(Fields.missing(REQ_CHOICE, { region = "us" }), nil, "…until one is picked")
local LANG = ALL_FIELDS[4]
eq(Fields.nextChoice(LANG, "any"), "en", "choice cycles to the next value")
eq(Fields.nextChoice(LANG, "pt"), "any", "…and wraps around")
eq(Fields.nextChoice(REQ_CHOICE[2], nil), "eu", "unset choice starts at the first value")
eq(Fields.nextChoice(LANG, "gone"), "any", "a stale value restarts the cycle")

print("== ctx.settings (PROVIDERS.md 3) ==")
local stored_by_id = { echo = { token = "tok", user = "" } }
Catalog.setSettingsSource(function(id) return stored_by_id[id] end)
local echo_seen = {}
Catalog.register{ api = 1, id = "echo", name = "Echo", settings = ALL_FIELDS,
    shelves = { { key = "s", title = "S" } },
    search = function(q, _l, _p, ctx)
        return { ctx.Entry.new{ title = q .. " via " .. tostring(ctx.settings.token),
            locator = { url = "https://e/1" } } }, false
    end,
    resolve = function(loc, ctx) echo_seen.resolve = ctx.settings; return loc.url end,
    browse = function(_k, _l, ctx) echo_seen.browse = ctx.settings; return {} end,
    check = function(ctx)
        if ctx.settings.token == "tok" then return true, "Signed in as " .. ctx.settings.user end
        return false, "bad token"
    end }
local echo_rows = Catalog.searchOne("echo", "emma", 5, 1)
eq(echo_rows[1].title, "emma via tok", "search sees the stored setting in ctx.settings")
local ectx = Catalog.ctxFor(Catalog.byId("echo"))
eq(ectx.settings.user, nil, "ctx builder: empty text -> nil (default not resurrected)")
eq(ectx.settings.lang, "any", "ctx builder: defaults applied")
Catalog.resolve({ provider = "echo", locator = { url = "https://e/1" } })
eq(echo_seen.resolve and echo_seen.resolve.token, "tok", "resolve gets ctx.settings")
Catalog.browse("echo:s", 3)
eq(echo_seen.browse and echo_seen.browse.covers, true, "browse gets ctx.settings")
eq(next(Catalog.ctxFor(Gut).settings), nil, "provider without fields -> empty ctx.settings")
stored_by_id.echo.user = "jane"
local cok, cmsg = Catalog.check("echo")
check(cok == true and cmsg == "Signed in as jane", "check(ctx) passes settings, returns ok + message", cmsg)
stored_by_id.echo.token = "nope"
cok, cmsg = Catalog.check("echo")
check(cok == false and cmsg == "bad token", "failing check returns false + its reason", cmsg)
Catalog.register{ api = 1, id = "check_throws", name = "CT", search = function() return {} end,
    resolve = function() end, check = function() error("kaput") end }
cok, cmsg = Catalog.check("check_throws")
check(cok == false and tostring(cmsg):find("kaput", 1, true) ~= nil, "throwing check -> false + error", cmsg)
cok, cmsg = Catalog.check("stamper")
check(cok == false and type(cmsg) == "string", "provider without check -> false + reason", cmsg)
Catalog.register{ api = 1, id = "check_silent", name = "CS", search = function() return {} end,
    resolve = function() end, check = function() return true end }
cok, cmsg = Catalog.check("check_silent")
check(cok == true and type(cmsg) == "string" and cmsg ~= "", "check without message still gets one", cmsg)
Catalog.setSettingsSource(nil)
eq(Catalog.ctxFor(Catalog.byId("echo")).settings.token, nil, "no settings source -> nothing stored")
eq(Catalog.ctxFor(Catalog.byId("echo")).settings.lang, "any", "…defaults still applied")

print("== Borrow / buy rows (decisions 49-50) ==")
local Store = { api = 1, id = "store", name = "Example Store", quality = 90,
    search = function() return {} end, resolve = function(l) return l.url end }
local function row(action, title, quality, extra)
    local t = { action = action, title = title, author = "Jane Austen", quality = quality,
        locator = { url = "https://x/" .. action .. "/" .. title } }
    for k, val in pairs(extra or {}) do t[k] = val end
    return Entry.new(t)
end
eq(row("borrow", "Emma").action, "borrow", "constructor accepts borrow")
eq(row("buy", "Emma", nil, { price = "€4.99" }).price, "€4.99", "constructor accepts price")
local s_rows = Catalog.stamp(Store, { row("download", "Emma", 100), row("borrow", "Emma", 100),
    row("buy", "Emma", 100, { price = "€4.99" }), row("buy", "Persuasion") })
eq(s_rows[1].quality, 100, "download keeps its quality")
check(s_rows[2].quality < 0, "borrow capped below zero", s_rows[2].quality)
check(s_rows[3].quality < 0, "buy capped below zero", s_rows[3].quality)
check(s_rows[4].quality < 0, "provider default quality capped on a buy row", s_rows[4].quality)
eq(s_rows[3].price, "€4.99", "price survives the host pass")
local b70 = Catalog.stamp(Store, { row("borrow", "X", 70) })[1]
local b60 = Catalog.stamp(Store, { row("buy", "X", 60) })[1]
check(b70.quality > b60.quality, "relative order among non-downloads kept", b70.quality .. " vs " .. b60.quality)
local d0 = Catalog.stamp(Store, { row("download", "X", 0) })[1]
check(d0.quality > b70.quality, "a quality-0 download outranks a quality-70 borrow", b70.quality)
local R2 = Results.new({ "store", "gutendex" })
R2:setProvider("store", Catalog.stamp(Store, { row("buy", "Emma", nil, { price = "€4.99" }),
    row("buy", "Lady Susan") }), false)
local bb1 = R2:flatten()
eq(#bb1, 2, "store rows show while nothing better exists")
eq(bb1[1].action, "buy", "buy row shown on its own")
R2:setProvider("gutendex", Catalog.stamp(Gut, { Entry.new{ title = "Emma", author = "Jane Austen",
    locator = { url = "https://g/158.epub" } } }), false)
local bb2, merged = R2:flatten()
eq(#bb2, 2, "free edition merged over the buy row")
eq(merged, 1, "one row collapsed")
eq(bb2[1].action, "download", "the free download replaced the buy row")
eq(bb2[1].source, "Project Gutenberg", "replacement comes from the free source")
eq(bb2[1].price, nil, "no price on the download")
eq(bb2[2].action, "buy", "buy-only row survives")
eq(bb2[2].title, "Lady Susan", "the surviving row is the one without a free edition")
local groups2 = Catalog.group(bb2)
eq(#groups2, 2, "two groups when two actions are present")
eq(groups2[1].action, "download", "download group first")
eq(groups2[2].action, "buy", "buy group second")
eq(groups2[2].heading, "Buy", "buy heading")

print("== Catalog.shelves / browse ==")
Catalog.register{ api = 1, id = "shelfy", name = "Shelfy", quality = 10,
    shelves = { { key = "picks", title = "Shelfy picks" } },
    search = function() return {}, false end,
    resolve = function(l) return l.url end,
    browse = function(key, _limit, ctx)
        return { ctx.Entry.new{ title = "Pick " .. key, locator = { url = "https://sh/" .. key } },
                 ctx.Entry.new{ title = "Nowhere" } }
    end }
local shelves = Catalog.shelves()
eq(#shelves, 5, "two Gutenberg shelves + the fakes' (registration order)")
eq(shelves[1].id, "gutendex:popular", "shelf id is <provider id>:<key>")
eq(shelves[1].key, "popular", "bare key kept for the provider")
eq(shelves[1].title, "Popular on Gutenberg", "shelf title from the provider")
eq(shelves[2].id, "gutendex:new", "second Gutenberg shelf")
eq(shelves[3].id, "fake_shelf:popular", "same key on another provider is a distinct shelf")
eq(shelves[5].provider, Catalog.byId("shelfy"), "shelf carries its provider")
local rows = Catalog.browse("shelfy:picks", 5)
eq(#rows, 1, "browse rows stamped; the locator-less one dropped")
eq(rows[1].title, "Pick picks", "provider receives the bare shelf key")
eq(rows[1].source, "Shelfy", "browse rows carry the source")
eq(rows[1].provider, "shelfy", "browse rows carry the provider id")
eq(rows[1].quality, 10, "browse rows get the provider quality")
local none2, berr2 = Catalog.browse("nope:zip", 5)
check(none2 == nil and berr2 ~= nil, "unknown shelf -> error", berr2)
do
local _rows, shelfy_more = Catalog.browse("shelfy:picks", 5)
eq(shelfy_more, false, "old-style browse (entries only) -> has_more false: no Load more")

-- #12: browse(key, limit, ctx, page) -> entries, has_more
local paged_calls = {}
Catalog.register{ api = 1, id = "pagey", name = "Pagey", quality = 10,
    shelves = { { key = "all", title = "All of Pagey" } },
    search = function() return {}, false end,
    resolve = function(l) return l.url end,
    browse = function(key, limit, ctx, page)
        paged_calls[#paged_calls + 1] = { key = key, limit = limit, page = page }
        local got = {}
        for i = (page - 1) * limit + 1, math.min(page * limit, 30) do
            got[#got + 1] = ctx.Entry.new{ title = "P" .. i, locator = { url = "https://pg/" .. i } }
        end
        return got, page * limit < 30
    end }
local pr1, pm1 = Catalog.browse("pagey:all", 12)
check(#pr1 == 12 and pm1 == true, "page defaults to 1; has_more passed through", pm1)
eq(paged_calls[1].page, 1, "provider receives page 1 when none given")
local pr3, pm3 = Catalog.browse("pagey:all", 12, 3)
check(#pr3 == 6 and pm3 == false, "page 3 is the last", pm3)
eq(pr3[1].provider, "pagey", "paged rows are stamped too")
eq(paged_calls[2].page, 3, "provider receives the page number")
Catalog.register{ api = 1, id = "oddmore", name = "Odd", shelves = { { key = "k", title = "K" } },
    search = function() return {}, false end, resolve = function(l) return l.url end,
    browse = function(_k, _l, ctx) return { ctx.Entry.new{ title = "x", locator = { url = "u" } } }, "more!" end }
local _orows, omore = Catalog.browse("oddmore:k", 12)
eq(omore, false, "a non-boolean second return is not has_more")
Catalog.register{ api = 1, id = "nilerr", name = "NilErr", shelves = { { key = "k", title = "K" } },
    search = function() return {}, false end, resolve = function(l) return l.url end,
    browse = function() return nil, "shelf down" end }
local nrows, nil_err = Catalog.browse("nilerr:k", 12, 2)
check(nrows == nil and nil_err == "shelf down", "nil, err still reports the error", nil_err)
-- unregister the three fakes so later shelf-order checks see the usual set
for i = #Catalog.providers, 1, -1 do
    local id = Catalog.providers[i].id
    if id == "pagey" or id == "oddmore" or id == "nilerr" then table.remove(Catalog.providers, i) end
end
end
eq(Catalog.BROWSE, nil, "hardcoded BROWSE table gone")

print("== Catalog.orderIds: arranged source order (DESIGN.md §9.5, decision 44) ==")
local function joined(t) return table.concat(t, ",") end
eq(joined(Catalog.orderIds(nil, { "a", "b", "c" })), "a,b,c", "nothing stored -> registration order")
eq(joined(Catalog.orderIds({ "c", "a", "b" }, { "a", "b", "c" })), "c,a,b", "stored order wins")
eq(joined(Catalog.orderIds({ "b" }, { "a", "b", "c", "d" })), "b,a,c,d",
   "new ids append after the stored ones, in registration order")
eq(joined(Catalog.orderIds({ "c", "gone", "a" }, { "a", "b", "c" })), "c,a,b", "vanished ids drop out silently")
eq(joined(Catalog.orderIds({ "b", "b", 7, "a" }, { "a", "b" })), "b,a", "duplicates and junk in the stored list ignored")
eq(joined(Catalog.orderIds("junk", { "a", "b" })), "a,b", "a non-list stored value -> registration order")
local stored_in = { "x" }
Catalog.orderIds(stored_in, { "y" })
eq(joined(stored_in), "x", "the stored list is not modified")
local reg_ids = Catalog.ids()
local arranged = Catalog.ordered({ "doab", "shelfy" })
eq(arranged[1], Catalog.byId("doab"), "ordered() returns provider tables, stored ones first")
eq(arranged[2], Catalog.byId("shelfy"), "…in stored order")
eq(arranged[3].id, reg_ids[1], "…then the rest in registration order")
eq(#arranged, #reg_ids, "ordered() lists every registered provider once")
eq(joined(Catalog.ids()), joined(reg_ids), "ids() stays in registration order")
local arranged_shelves = Catalog.shelves({ "shelfy", "fake_shelf" })
eq(arranged_shelves[1].id, "shelfy:picks", "shelves(order) follow the arranged order")
eq(arranged_shelves[2].id, "fake_shelf:popular", "…second arranged source next")
eq(arranged_shelves[3].id, "gutendex:popular", "…unarranged sources after, in registration order")

print("== Settings: source keys migrate to ids (pure part) ==")
local Migrate = require("openshelf_migrate")
local mset, mchanged = Migrate.sourceSet({ ["DOAB"] = true, ["Project Gutenberg"] = true,
    ["Standard Ebooks"] = true, internetarchive = true })
check(mchanged, "v0.5 display-name keys were rewritten")
eq(mset.doab, true, "DOAB -> doab")
eq(mset.gutendex, true, "Project Gutenberg -> gutendex")
eq(mset.internetarchive, true, "keys that already are ids are kept")
eq(mset["DOAB"], nil, "old display-name key gone")
eq(mset["Standard Ebooks"], nil, "a name v0.5 never had is dropped, not guessed")
local mset2, mchanged2 = Migrate.sourceSet(mset)
check(not mchanged2, "migrating twice changes nothing (runs once)")
eq(mset2.doab, true, "ids survive a second pass")
local mset3, mchanged3 = Migrate.sourceSet(nil)
check(type(mset3) == "table" and not mchanged3, "nil set -> empty set, unchanged")

print("== Settings: enabled sources by id, enabled_by_default honored ==")
-- settings.lua runs on KOReader's LuaSettings; stub it with an in-memory
-- store seeded like a v0.5 openshelf.lua (DOAB disabled by display name).
local ls_data = { disabled_sources = { ["DOAB"] = true, ["Standard Ebooks"] = true }, recents = { "emma" } }
local ls_flushes = 0
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/nowhere" end }
end
package.preload["luasettings"] = function()
    local LS = {}
    function LS:open()
        return {
            data = ls_data,
            readSetting = function(s_, key) return s_.data[key] end,
            saveSetting = function(s_, key, value) s_.data[key] = value; return s_ end,
            flush = function(s_) ls_flushes = ls_flushes + 1; return s_ end,
        }
    end
    return LS
end
local Settings = require("settings")
local gut_p, ia_p, doab_p = Catalog.byId("gutendex"), Catalog.byId("internetarchive"), Catalog.byId("doab")
eq(Settings.isEnabled(doab_p), false, "DOAB disabled in v0.5 stays disabled after the upgrade")
eq(ls_data.disabled_sources.doab, true, "disabled_sources now keyed by id")
eq(ls_data.disabled_sources["DOAB"], nil, "display-name key removed from the file")
eq(ls_flushes, 1, "migrated settings flushed once on open")
eq(Settings.isEnabled(gut_p), true, "default-on provider enabled when nothing is stored")
eq(Settings.recents()[1], "emma", "other settings untouched by the migration")
local ids_now = Settings.enabledIds({ gut_p, ia_p, doab_p })
eq(#ids_now, 2, "enabledIds skips the disabled one")
eq(ids_now[1], "gutendex", "enabledIds keeps slot order")
eq(ids_now[2], "internetarchive", "…and returns ids")
Settings.setEnabled(doab_p, true)
eq(Settings.isEnabled(doab_p), true, "re-enabled")
eq(ls_data.disabled_sources.doab, nil, "re-enabling clears the disabled key")
Settings.toggle(doab_p)
eq(Settings.isEnabled(doab_p), false, "toggle disables again")
local sleepy = { api = 1, id = "sleepy", name = "Sleepy Books", enabled_by_default = false,
    search = function() return {} end, resolve = function() end }
eq(Settings.isEnabled(sleepy), false, "default-off provider is off until the user enables it (decision 43)")
eq(#Settings.enabledIds({ gut_p, sleepy }), 1, "default-off provider gets no slot")
Settings.setEnabled(sleepy, true)
eq(Settings.isEnabled(sleepy), true, "user enabled the default-off provider")
eq(ls_data.enabled_sources.sleepy, true, "stored under enabled_sources (DESIGN.md §9.5)")
eq(ls_data.disabled_sources.sleepy, nil, "default-off providers never touch disabled_sources")
eq(Settings.enabledIds({ gut_p, sleepy })[2], "sleepy", "enabled default-off provider gets its slot")
Settings.setEnabled(sleepy, false)
eq(ls_data.enabled_sources.sleepy, nil, "disabling a default-off provider clears enabled_sources")
eq(Settings.isEnabled(sleepy), false, "…and it is off again")
local ps = Settings.providerSettings("sleepy")
check(type(ps) == "table" and next(ps) == nil, "provider_settings[id] is an empty table until set")
Settings.setProviderSetting("sleepy", "token", "abc")
eq(Settings.providerSettings("sleepy").token, "abc", "provider setting stored")
eq(Settings.sourceOrder(), nil, "no source_order until the user arranges")
eq(Settings.orderedProviders()[1], Catalog.providers[1], "orderedProviders: registration order by default")
Settings.setSourceOrder({ "doab", "internetarchive", "gutendex" })
eq(table.concat(ls_data.source_order, ","), "doab,internetarchive,gutendex", "source_order stored as an id list")
eq(Settings.orderedProviders()[1], doab_p, "orderedProviders follows the stored order")
eq(Settings.orderedProviders()[3], gut_p, "…all the way down")
eq(#Settings.orderedProviders(), #Catalog.providers, "…and still lists every registered provider")
Settings.setEnabled(doab_p, true)
eq(table.concat(Settings.enabledIds(Settings.orderedProviders()), ",", 1, 3), "doab,internetarchive,gutendex",
   "enabled slot ids come out in the arranged order")
eq(ls_data.provider_settings.sleepy.token, "abc", "under provider_settings[id] in the file")
check(next(Settings.providerSettings("gutendex")) == nil, "other providers' containers untouched")

print("== Settings: Needs setup (PROVIDERS.md 7) ==")
local keyed = { api = 1, id = "keyed", name = "Keyed", settings = {
        { key = "token", title = "Token", type = "secret", required = true },
        { key = "lang", title = "Language", type = "choice", choices = { "any", "en" }, default = "any" } },
    search = function(_q, _l, _p, ctx) return { ctx.Entry.new{ title = "tok=" .. tostring(ctx.settings.token),
        locator = { url = "https://k/1" } } }, false end,
    resolve = function() end }
check(Catalog.register(keyed), "provider with a required field registers")
eq(Settings.needsSetup(keyed), "token", "required field empty -> needs setup on that field")
eq(Settings.needsSetup(gut_p), nil, "provider without fields never needs setup")
eq(Settings.isEnabled(keyed), true, "needs setup is not the same as disabled")
local ids_ns = Settings.enabledIds({ gut_p, keyed })
eq(#ids_ns, 1, "needs-setup source gets no slot")
eq(ids_ns[1], "gutendex", "…the others keep theirs")
eq(Settings.values(keyed).lang, "any", "Settings.values applies defaults")
Settings.setProviderSetting("keyed", "token", "abc123")
eq(Settings.needsSetup(keyed), nil, "filled -> ready")
eq(Settings.enabledIds({ gut_p, keyed })[2], "keyed", "ready source gets its slot")
eq(Catalog.searchOne("keyed", "x", 5, 1)[1].title, "tok=abc123",
   "saved value reaches the provider's search through ctx.settings")
Settings.setProviderSetting("keyed", "token", nil)
eq(ls_data.provider_settings.keyed.token, nil, "clearing a field removes it from the file")
eq(Settings.needsSetup(keyed), "token", "cleared -> needs setup again")

print("== Settings: home shelves (PROVIDERS.md 5.3, DESIGN.md 9.5, decision 53) ==")
local function shelf_ids()
    local ids_out = {}
    for __, s in ipairs(Settings.homeShelves()) do ids_out[#ids_out + 1] = s.id end
    return table.concat(ids_out, ",")
end
local gated = { api = 1, id = "gated", name = "Gated", settings = {
        { key = "token", title = "Token", type = "secret", required = true } },
    shelves = { { key = "top", title = "Gated top" } },
    search = function() return {}, false end, resolve = function() end,
    browse = function() return {} end }
check(Catalog.register(gated), "shelved provider with a required field registers")
Settings.setSourceOrder({ "shelfy", "gated", "gutendex" })
eq(shelf_ids(), "shelfy:picks,gutendex:popular,gutendex:new,fake_shelf:popular",
   "enabled sources' shelves in arranged order; the Needs-setup source has none")
eq(Settings.shelvesOnHome(Catalog.byId("shelfy")), true, "Shelves on home defaults to on")
Settings.setShelvesOnHome(Catalog.byId("shelfy"), false)
eq(Settings.shelvesOnHome(Catalog.byId("shelfy")), false, "toggle off stored")
eq(ls_data.shelves_hidden.shelfy, true, "stored per provider id under shelves_hidden")
eq(shelf_ids(), "gutendex:popular,gutendex:new,fake_shelf:popular", "toggle off hides that source's shelves")
eq(Settings.enabledIds({ Catalog.byId("shelfy") })[1], "shelfy", "…without touching search")
Settings.setShelvesOnHome(Catalog.byId("shelfy"), true)
eq(ls_data.shelves_hidden.shelfy, nil, "toggle back on clears the key")
Settings.setProviderSetting("gated", "token", "t")
eq(shelf_ids(), "shelfy:picks,gated:top,gutendex:popular,gutendex:new,fake_shelf:popular",
   "set up -> its shelves appear in its slot")
Settings.setEnabled(gut_p, false)
eq(shelf_ids(), "shelfy:picks,gated:top,fake_shelf:popular", "disabling a source hides its shelves")
Settings.setEnabled(gut_p, true)

print("== Jobs deadline (DESIGN.md 9.6, decision 45) ==")
-- The real jobs.lua, driven through Jobs.run with a fake UIManager whose
-- clock the test advances and a fake ffi/util whose child only finishes
-- when the test says so. The json stub becomes a pass-through registry so
-- the child's encoded result survives the "pipe".
do
    local tnow, timers = 0, {}
    local UI = {}
    function UI:scheduleIn(t, fn) timers[#timers + 1] = { at = tnow + t, fn = fn } end
    function UI:nextTick(fn) UI:scheduleIn(0, fn) end
    function UI:unschedule(fn)
        for i = #timers, 1, -1 do if timers[i].fn == fn then table.remove(timers, i) end end
    end
    local function advance(seconds)
        local target = tnow + seconds
        while true do
            local idx
            for i, t in ipairs(timers) do
                if t.at <= target and (not idx or t.at < timers[idx].at) then idx = i end
            end
            if not idx then break end
            local t = table.remove(timers, idx)
            tnow = math.max(tnow, t.at)
            t.fn()
        end
        tnow = target
    end
    local children, killed, reaped, next_pid = {}, {}, {}, 100
    local FFI = {}
    function FFI.runInSubProcess(func)
        next_pid = next_pid + 1
        children[next_pid] = { func = func, done = false, output = "" }
        return next_pid, next_pid * 10
    end
    function FFI.isSubProcessDone(pid)
        if children[pid].done then reaped[pid] = true end
        return children[pid].done
    end
    function FFI.terminateSubProcess(pid) killed[pid] = true; children[pid].done = true end
    function FFI.getNonBlockingReadSize(fd) return #children[fd / 10].output end
    function FFI.readAllFromFD(fd)
        local ch = children[fd / 10]
        local s = ch.output
        ch.output, ch.closed = "", true
        return s
    end
    function FFI.writeToFD(fd, data) local ch = children[fd / 10]; ch.output = ch.output .. data; return true end
    local function child_finishes(pid)
        local ch = children[pid]
        local stderr = io.stderr
        rawset(io, "stderr", { write = function() end })   -- the child logs its lifecycle
        ch.func(pid, pid * 10)
        rawset(io, "stderr", stderr)
        collectgarbage("restart")                          -- the child stops GC for its lifetime
        ch.done = true
    end
    package.preload["ffi/util"] = function() return FFI end
    package.preload["ui/uimanager"] = function() return UI end
    local JSONstub, registry = require("json"), {}
    local enc, dec = JSONstub.encode, JSONstub.decode
    JSONstub.encode = function(t) registry[#registry + 1] = t; return "#" .. #registry end
    JSONstub.decode = function(s) return registry[tonumber(tostring(s):match("^#(%d+)$") or 0)] end

    local Jobs = require("jobs")
    Jobs.inline = false
    eq(Jobs.DEADLINE, 60, "shared deadline is 60 s")
    local events = {}
    local function spec(over)
        local s = { task = function() return "never" end,
            on_done = function(r) events[#events + 1] = "done:" .. tostring(type(r) == "table" and r.n or r) end,
            on_error = function(msg) events[#events + 1] = "error:" .. tostring(msg) end }
        for k, val in pairs(over or {}) do s[k] = val end
        return s
    end

    local h = Jobs.run(spec{ timeout = 60 })
    advance(59)
    eq(#events, 0, "nothing reported before the deadline")
    check(not killed[h.pid], "child alive before the deadline")
    advance(2)
    eq(events[1], "error:timed out", "deadline reports 'timed out'")
    check(killed[h.pid], "child killed at the deadline")
    check(h.done, "handle done after the timeout")
    advance(5)
    check(reaped[h.pid], "killed child reaped")
    check(children[h.pid].closed, "killed child's pipe closed")
    eq(#events, 1, "timeout reported once")
    advance(600)
    eq(#events, 1, "nothing more after the timeout")

    events = {}
    local h2 = Jobs.run(spec{ timeout = 60, task = function() return { n = 7 } end })
    advance(1)
    child_finishes(h2.pid)
    advance(1)
    eq(events[1], "done:7", "child's result reaches on_done through the pipe")
    advance(120)
    eq(#events, 1, "no timeout once the job finished")
    check(not killed[h2.pid], "finished child never killed")

    events = {}
    local h3 = Jobs.run(spec())
    advance(600)
    check(not killed[h3.pid] and #events == 0, "no timeout field -> no deadline (downloads)")
    h3:cancel()
    check(killed[h3.pid], "cancel still kills")

    events = {}
    local h4 = Jobs.run(spec{ timeout = 60 })
    advance(10)
    h4:cancel()
    advance(100)
    check(killed[h4.pid] and #events == 0, "cancelled job never reports the deadline")

    events = {}
    Jobs.inline = true
    Jobs.run(spec{ timeout = 1, task = function() return "inline" end })
    advance(0)
    eq(events[1], "done:inline", "inline mode runs the task on the next tick")
    advance(100)
    eq(#events, 1, "inline mode ignores the deadline by design")
    Jobs.inline = false

    JSONstub.encode, JSONstub.decode = enc, dec
end

print("== External providers: registry + drop-ins (PROVIDERS.md 8) ==")
local External = require("openshelf_external")
local function ext(id, over)
    local p = { api = 1, id = id, name = "Ext " .. id,
        search = function() return {}, false end,
        resolve = function(loc) return loc.url end }
    for k, val in pairs(over or {}) do p[k] = val end
    return p
end
-- A fake drop-in folder: file name -> chunk source.
local function fake_fs(files)
    local fs = { dir = "/ko/settings/openshelf/providers", files = files, loads = {} }
    fs.listDir = function()
        local t = {}
        for name in pairs(fs.files) do t[#t + 1] = name end
        return t
    end
    fs.loadFile = function(path)
        fs.loads[#fs.loads + 1] = path
        local name = path:match("[^/]*$")
        local chunk, err = loadstring(fs.files[name], "=" .. name)
        if not chunk then error(err, 0) end
        return chunk()
    end
    return fs
end
local function src(id, extra)
    return "return { api = 1, id = '" .. id .. "', name = 'Drop " .. id .. "', "
        .. "search = function() return {}, false end, resolve = function() return 'u' end"
        .. (extra or "") .. " }"
end
local function ids_after(n)
    local t = {}
    for i = n + 1, #Catalog.ids() do t[#t + 1] = Catalog.ids()[i] end
    return table.concat(t, ",")
end
local before = #Catalog.ids()
local fs = fake_fs({ ["zz.lua"] = src("ext_drop_a"), ["aa.lua"] = src("ext_drop_b"), ["notes.txt"] = "x" })
local scanner = External.new{ catalog = Catalog, listDir = fs.listDir, loadFile = fs.loadFile }
scanner:scan({ zebra = ext("ext_plug_b"), alpha = ext("ext_plug_a") }, fs.dir)
eq(ids_after(before), "ext_plug_a,ext_plug_b,ext_drop_a,ext_drop_b",
   "externals append after built-ins: plugins by id, then drop-ins by id")
eq(#fs.loads, 2, "only *.lua files in the drop-in folder are loaded")

local invalid_before = #Catalog.invalid()
-- Fresh tables under the same registry names: a provider plugin's init()
-- re-runs after every book and dofile()s a new table (PROVIDERS.md §8.2).
local registry = { zebra = ext("ext_plug_b"), alpha = ext("ext_plug_a") }
local n_ids = #Catalog.ids()
scanner:scan(registry, fs.dir)
eq(#fs.loads, 2, "reopening does not load a file again (once per process)")
eq(#Catalog.ids(), n_ids, "reopening registers nothing new")
eq(#Catalog.invalid(), invalid_before, "reopening does not report taken providers as duplicates")

fs.files["mm.lua"] = src("ext_drop_c")
registry.later = ext("ext_plug_c")
scanner:scan(registry, fs.dir)
eq(ids_after(n_ids), "ext_plug_c,ext_drop_c", "a provider added later is picked up on the next open")
eq(#fs.loads, 3, "only the new file is loaded")

local inv_mid = #Catalog.invalid()
registry.impostor = ext("ext_plug_a")   -- another plugin claiming a taken id
scanner:scan(registry, fs.dir)
eq(#Catalog.invalid(), inv_mid + 1, "a different plugin claiming a registered id is still rejected")
check(tostring(Catalog.invalid()[#Catalog.invalid()].reason):find("duplicate id ext_plug_a", 1, true) ~= nil,
      "the impostor is listed as a duplicate")

print("== External providers: broken ones are listed, never block ==")
local function reasons_since(n)
    local t = {}
    for i = n + 1, #Catalog.invalid() do
        local inv = Catalog.invalid()[i]
        t[#t + 1] = tostring(inv.name) .. ": " .. tostring(inv.reason)
    end
    return t
end
local inv0, ids0 = #Catalog.invalid(), #Catalog.ids()
local bad = fake_fs({
    ["syntax.lua"]  = "return { api = 1, id = ",
    ["noresolve.lua"] = "return { api = 1, id = 'ext_nores', name = 'No Resolve', search = function() end }",
    ["api3.lua"]    = src("ext_api3"):gsub("api = 1", "api = 3"),
    ["dup.lua"]     = src("ext_plug_a"),     -- id already taken by a plugin
    ["fine.lua"]    = src("ext_fine"),
    ["notable.lua"] = "return 42",
})
local s2 = External.new{ catalog = Catalog, listDir = bad.listDir, loadFile = bad.loadFile }
s2:scan({ gutendex = ext("gutendex"), nameless = { id = "ext_nameless", api = 1 } }, bad.dir)
local ext_why = table.concat(reasons_since(inv0), "\n")
eq(ids_after(ids0), "ext_fine", "the valid drop-in registers despite its broken neighbours")
check(ext_why:find("syntax.lua: load error", 1, true) ~= nil, "syntax error listed under the file name", ext_why)
check(ext_why:find("No Resolve: missing resolve", 1, true) ~= nil, "missing resolve listed with reason")
check(ext_why:find("Drop ext_api3: api must be 1 or 2", 1, true) ~= nil, "api = 3 listed with reason")
check(ext_why:find("Drop ext_plug_a: duplicate id ext_plug_a", 1, true) ~= nil, "drop-in losing to a plugin id is a duplicate")
check(ext_why:find("Ext gutendex: duplicate id gutendex", 1, true) ~= nil, "a plugin cannot take a built-in id")
check(ext_why:find("nameless: ", 1, true) ~= nil, "a nameless table is listed under its registry name")
check(ext_why:find("notable.lua: not a table", 1, true) ~= nil, "a file not returning a table is listed under its name")
eq(#reasons_since(inv0), 7, "every broken provider is listed once")
local s3 = External.new{ catalog = Catalog, listDir = function() error("no such dir") end, loadFile = bad.loadFile }
check(pcall(s3.scan, s3, nil, "/missing"), "a missing folder and no registry are tolerated")

;(function() -- provider_check: own function, the main chunk is at the 200-local limit
print("== provider_check: arguments (PROVIDERS.md 10) ==")
local Check = dofile(this .. "../tools/provider_check.lua")
local args = Check.parseArgs({ "p.lua", "emma", "--set", "token=abc", "--set", "q=a=b", "--download", "--limit", "5" })
eq(args and args.file, "p.lua", "first positional is the provider file")
eq(args and args.query, "emma", "second positional is the query")
eq(args and args.settings.token, "abc", "--set key=value fills settings")
eq(args and args.settings.q, "a=b", "--set splits on the first = only")
eq(args and args.download, true, "--download is opt-in")
eq(args and args.limit, 5, "--limit sets the page size")
local defaults = Check.parseArgs({ "p.lua" })
eq(defaults and defaults.query, "pride and prejudice", "default query")
eq(defaults and defaults.download, false, "no download by default")
eq(defaults and defaults.offline, false, "network checks on by default")
eq(Check.parseArgs({ "p.lua", "--offline" }).offline, true, "--offline skips the tool's own network checks")
check(Check.parseArgs({}) == nil, "a provider file is required")
check(Check.parseArgs({ "p.lua", "--bogus" }) == nil, "unknown flags are refused")
check(Check.parseArgs({ "p.lua", "--set", "novalue" }) == nil, "--set needs key=value")

print("== provider_check: contract run (offline) ==")
local function good(over)
    local p = {
        api = 1, id = "checkme", name = "Check Me",
        search = function(q, _limit, _page, ctx)
            return { ctx.Entry.new{ title = "Book about " .. q, author = "A. Author",
                                    locator = { url = "https://example.org/a.epub", n = 1 } } }, false
        end,
        resolve = function(loc) return { url = loc.url, headers = { Authorization = "Bearer x" } } end,
    }
    for k, val in pairs(over or {}) do p[k] = val end
    return p
end
local function run_check(p, extra)
    local opts = { provider = p, query = "cats", offline = true, out = function() end }
    for k, val in pairs(extra or {}) do opts[k] = val end
    return Check.run(opts)
end
local function failed_with(p, needle, label, extra)
    local ok, problems = run_check(p, extra)
    local text = table.concat(problems or {}, " | ")
    check(ok == false and text:find(needle, 1, true) ~= nil, label, text)
end
local ok_run, fails = run_check(good())
check(ok_run == true and #fails == 0, "a well-formed provider passes", table.concat(fails or {}, " | "))
failed_with("nope", "not a table", "a non-table is refused")
failed_with(good{ api = 3 }, "api must be 1 or 2", "wrong api is refused")
failed_with(good{ resolve = false }, "missing resolve", "missing resolve is refused")
failed_with(good{ search = function() error("kaboom") end }, "kaboom", "a raising search fails with its message")
failed_with(good{ search = function() return nil, "service down" end }, "service down", "search nil, err fails with err")
failed_with(good{ search = function() return {}, false end }, "no results", "zero rows cannot be checked further")
failed_with(good{ search = function(_q, _l, _p, ctx) return { ctx.Entry.new{ title = "x", locator = { url = "u" } } }, "yes" end },
    "has_more", "has_more must be a boolean")
failed_with(good{ search = function() return { { title = "x", locator = { url = "u" }, fn = print } }, false end },
    "function", "a function inside a row fails the plain-data check")
failed_with(good{ search = function() return { { title = "x" } }, false end },
    "locator", "a row without a locator fails")
failed_with(good{ search = function() return { { title = "x", locator = { url = { "nested" } } } }, false end },
    "locator", "a locator with a nested table fails")
failed_with(good{ search = function(_q, l, _p, ctx)
        local many = {}
        for i = 1, l + 1 do many[i] = ctx.Entry.new{ title = "t" .. i, locator = { id = i } } end
        return many, true
    end }, "limit", "more rows than the limit fails", { limit = 3 })
failed_with(good{ resolve = function() return nil, "gone from the shelf" end }, "gone from the shelf",
    "resolve nil, err fails with err")
failed_with(good{ resolve = function() return { headers = {} } end }, "no URL", "resolve without url fails")

local seen_settings
local needs = good{
    settings = { { key = "token", title = "Token", type = "secret", required = true },
                 { key = "lang", title = "Language", type = "choice", choices = { "any", "en" }, default = "any" } },
    search = function(_q, _l, _p, ctx)
        seen_settings = ctx.settings
        return { ctx.Entry.new{ title = "x", locator = { url = "u" } } }, false
    end,
}
failed_with(needs, "needs setup: token", "a required setting left out fails before searching")
local ok_set = run_check(needs, { settings = { token = "abc" } })
check(ok_set == true, "--set satisfies a required setting")
eq(seen_settings and seen_settings.token, "abc", "ctx.settings carries --set values")
eq(seen_settings and seen_settings.lang, "any", "ctx.settings applies declared defaults")
run_check(needs, { settings = { token = "abc", lang = "en" } })
eq(seen_settings and seen_settings.lang, "en", "--set overrides a default")

failed_with(good{ shelves = { { key = "top", title = "Top" } },
                  browse = function() return nil, "shelf broke" end }, "shelf broke", "a failing shelf browse fails")
failed_with(good{ check = function() return false, "bad token" end }, "bad token", "a failing check() fails")

-- #12: page 2 of a shelf when page 1 says has_more
local function shelf_provider(browse)
    return good{ shelves = { { key = "top", title = "Top" } }, browse = browse }
end
local pages_asked = {}
local ok_paged = run_check(shelf_provider(function(_k, limit, ctx, page)
    pages_asked[#pages_asked + 1] = page
    local got = {}
    for i = (page - 1) * limit + 1, page * limit do
        got[#got + 1] = ctx.Entry.new{ title = "t" .. i, locator = { id = i } }
    end
    return got, page == 1
end))
check(ok_paged == true, "a paged shelf passes")
eq(table.concat(pages_asked, ","), "1,2", "page 1 said has_more -> page 2 checked too")
pages_asked = {}
local ok_old = run_check(shelf_provider(function(_k, _l, ctx, page)
    pages_asked[#pages_asked + 1] = page
    return { ctx.Entry.new{ title = "t", locator = { id = 1 } } }
end))
check(ok_old == true, "an old-style shelf (entries only) passes")
eq(table.concat(pages_asked, ","), "1", "no has_more -> page 2 not asked")
failed_with(shelf_provider(function(_k, _l, ctx)
    return { ctx.Entry.new{ title = "t", locator = { id = 1 } } }, true
end), "repeats 1 row", "has_more but page ignored -> page 2 repeats page 1")
failed_with(shelf_provider(function(_k, _l, ctx, page)
    if page == 2 then return nil, "page two broke" end
    return { ctx.Entry.new{ title = "t", locator = { id = 1 } } }, true
end), "page two broke", "a failing page 2 fails")
failed_with(shelf_provider(function(_k, _l, ctx)
    return { ctx.Entry.new{ title = "t", locator = { id = 1 } } }, "yes"
end), "has_more must be a boolean", "a non-boolean shelf has_more fails")
failed_with(shelf_provider(function(_k, limit, ctx)
    local got = {}
    for i = 1, limit + 1 do got[i] = ctx.Entry.new{ title = "t" .. i, locator = { id = i } } end
    return got
end), "rows for limit", "more rows than the shelf size fails")

local ok_buy = run_check(good{ search = function(_q, _l, _p, ctx)
    return { ctx.Entry.new{ action = "buy", title = "x", locator = { url = "https://shop/x" } },
             ctx.Entry.new{ title = "y", locator = { url = "https://free/y" } } }, false
end, resolve = function(loc) assert(loc.url ~= "https://shop/x", "buy row resolved"); return loc.url end })
check(ok_buy == true, "buy rows are never resolved; the first download row is")

print("== provider_check: shipped template + example ==")
local TEMPLATE = this .. "../provider-openshelf-template.koplugin/openshelf_template.lua"
local ok_tpl, tpl_fails = Check.run{ file = TEMPLATE, query = "pride", offline = true, out = function() end }
check(ok_tpl == true, "template provider passes the offline check", table.concat(tpl_fails or {}, " | "))
local ok_pt = Check.run{ file = TEMPLATE, query = "pride", settings = { lang = "pt" }, offline = true, out = function() end }
check(ok_pt == false, "template honours ctx.settings.lang (no Portuguese Pride and Prejudice)")
local example = dofile(this .. "../examples/gutenberg_pt.lua")
check(Catalog.validate(example), "example drop-in is a valid provider", select(2, Catalog.validate(example)))
local ok_ex, ex_fails = Check.run{ file = this .. "../examples/gutenberg_pt.lua", query = "machado",
    offline = true, out = function() end }
check(ok_ex == false and table.concat(ex_fails or {}, " "):find("offline stub", 1, true) ~= nil,
      "example drop-in reaches ctx.http (offline stub answers)", table.concat(ex_fails or {}, " | "))
end)()

---------------------------------------------------------------------------
-- Folders, api 2 (#23): the contract in entry / catalog / results / dedupe
-- and the provider_check folders step. DESIGN.md §12, PROVIDERS.md §4.5.
---------------------------------------------------------------------------
;(function() -- own function: the main chunk is at the 200-local limit
local function same(a, b)   -- NULL (LuaJSON's null) and Glyphs are the main chunk's
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, val in pairs(a) do if not same(val, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

print("== Folders: Entry.folder (PROVIDERS.md 4.5) ==")
local fo = Entry.folder{ title = "  Theoretical   Classes ", locator = { bucket = "z5", folder = "k3", junk = NULL },
    subtitle = " Software Seguro ", path = { "Software Seguro", "T" }, count = 43, size = 125829120,
    cover = "https://c/1.jpg", provider = "ucs" }
eq(fo.action, "folder", "Entry.folder builds a folder row")
eq(Entry.ACTION.FOLDER, "folder", "Entry.ACTION.FOLDER")
eq(fo.title, "Theoretical Classes", "folder title cleaned")
eq(fo.locator.folder, "k3", "folder locator kept")
eq(fo.locator.junk, nil, "null locator field dropped")
eq(fo.subtitle, "Software Seguro", "subtitle trimmed")
eq(table.concat(fo.path, "/"), "Software Seguro/T", "path kept, outermost first")
eq(fo.count, 43, "count kept")
eq(fo.size, 125829120, "size kept")
eq(fo.cover_url, "https://c/1.jpg", "cover -> cover_url, like file rows")
eq(fo.provider, "ucs", "provider carried until the host stamps it")
eq(fo.author, nil, "a folder row gets no Unknown author")
eq(fo.format, nil, "a folder row gets no epub format")
local fnull = Entry.folder{ title = NULL, locator = { id = 1 }, subtitle = NULL, count = NULL, size = NULL,
    path = NULL, cover = NULL }
eq(fnull.title, "Untitled", "null folder title -> Untitled")
eq(fnull.subtitle, nil, "null subtitle -> nil")
eq(fnull.count, nil, "null count -> nil")
eq(fnull.size, nil, "null size -> nil")
eq(fnull.path, nil, "null path -> nil")
eq(fnull.cover_url, nil, "null cover -> nil")
eq(Entry.folder{ title = "x", locator = { id = 1 }, count = "12", size = "2048" }.count, 12, "numeric string count coerced")
eq(Entry.folder{ title = "x", locator = { id = 1 }, size = -5 }.size, nil, "negative size dropped")
eq(Entry.folder{ title = "x", locator = { id = 1 }, count = 0 / 0 }.count, nil, "NaN count dropped")
eq(Entry.folder{ title = "x", locator = { id = 1 }, size = 1 / 0 }.size, nil, "infinite size dropped")

print("== Folders: path and size on rows ==")
local pth = Entry.folder{ title = "x", locator = { id = 1 },
    path = { "  Lab01 \n Auth ", 2025, NULL, "   ", {}, true } }.path
eq(#pth, 6, "path depth kept, whatever the elements")
eq(pth[1], "Lab01 Auth", "path element cleaned")
eq(pth[2], "2025", "number element -> string")
eq(pth[3], "_", "null element -> _")
eq(pth[4], "_", "element that cleans to nothing -> _")
eq(pth[5], "_", "table element -> _")
eq(pth[6], "_", "boolean element -> _")
local capped = Entry.folder{ title = "x", locator = { id = 1 }, path = { string.rep("y", 500) } }.path[1]
check(#capped > 0 and #capped <= 120, "path element length-capped", #capped)
local deep = {}
for i = 1, 40 do deep[i] = "d" .. i end
eq(#Entry.folder{ title = "x", locator = { id = 1 }, path = deep }.path, 40, "path depth not capped")
local rootlevel = Entry.folder{ title = "x", locator = { id = 1 }, path = {} }.path
check(type(rootlevel) == "table" and #rootlevel == 0, "empty path {} kept: directly under the root", rootlevel)
eq(Entry.folder{ title = "x", locator = { id = 1 }, path = "A/B" }.path, nil, "a non-table path is absent")
local file = Entry.new{ title = "Aula 1", author = "Prof", format = "pdf", locator = { url = "https://f/1" },
    size = 2400000, path = { "Software Seguro", "Labs" } }
eq(file.action, "download", "file row stays a download")
eq(file.size, 2400000, "file row size kept")
eq(table.concat(file.path, "/"), "Software Seguro/Labs", "file row path kept")
eq(Entry.download{ title = "x", locator = { url = "u" }, path = {} }.path and #Entry.download{
    title = "x", locator = { url = "u" }, path = {} }.path, 0, "file row empty path kept")
eq(Entry.new{ title = "x", locator = { url = "u" } }.size, nil, "size absent by default")
eq(Entry.new{ title = "x", locator = { url = "u" } }.path, nil, "path absent by default")

print("== Folders: Entry.new{action = folder} ==")
local spec = { title = "T", locator = { folder = "k3" }, subtitle = "S", path = { "A" }, count = 3, size = 9,
    cover = "https://c/2.jpg", author = "Someone", format = "pdf" }
local via_new = Entry.new{ action = "folder", title = spec.title, locator = spec.locator, subtitle = spec.subtitle,
    path = spec.path, count = spec.count, size = spec.size, cover = spec.cover, author = spec.author, format = spec.format }
check(same(via_new, Entry.folder(spec)), "Entry.new{action = folder} builds the same row as Entry.folder")
eq(via_new.action, "folder", "Entry.new keeps the folder action")
eq(via_new.author, nil, "…with no author")
eq(via_new.format, nil, "…and no format")

print("== Folders: group heading + glyph ==")
for __, action in ipairs(Entry.ACTION_ORDER) do
    check(type(Glyphs[Entry.ACTION_GLYPH[action]]) == "string", "glyph for " .. action .. " exists",
          Entry.ACTION_GLYPH[action])
end
eq(Glyphs.folder, Glyphs.utf8(0xF07B), "folder glyph = U+F07B (in the bundled symbols.ttf)")
eq(Entry.ACTION_HEADING.folder, "Folders", "folder heading")

print("== Folders: api 2 validation (PROVIDERS.md 2, 8.5) ==")
local function api2(over)
    local p = { api = 2, id = "fold", name = "Fold",
        search = function() return {}, false end,
        resolve = function(loc) return loc.url end,
        list = function() return {}, false end }
    for k, val in pairs(over or {}) do p[k] = val end
    return p
end
local function why2(p) return select(2, Catalog.validate(p)) end
check(Catalog.validate(api2()), "api 2 with list validates", why2(api2()))
check(Catalog.validate(api2{ root = "Course materials", dedupe = false, search_in = function() end }),
      "api 2 with root, dedupe and search_in validates")
check(tostring(why2(api2{ list = false })):find("list", 1, true) ~= nil, "api 2 without list rejected", why2(api2{ list = false }))
check(tostring(why2(api2{ list = "x" })):find("list", 1, true) ~= nil, "api 2 list must be a function")
check(tostring(why2(api2{ root = "" })):find("root", 1, true) ~= nil, "empty root rejected", why2(api2{ root = "" }))
check(tostring(why2(api2{ root = 7 })):find("root", 1, true) ~= nil, "non-string root rejected")
check(tostring(why2(api2{ root = string.rep("r", 61) })):find("root", 1, true) ~= nil, "root over 60 bytes rejected")
check(Catalog.validate(api2{ root = string.rep("r", 60) }), "root of 60 bytes accepted")
check(tostring(why2(api2{ search_in = "yes" })):find("search_in", 1, true) ~= nil, "non-function search_in rejected",
      why2(api2{ search_in = "yes" }))
check(tostring(why2(api2{ dedupe = "no" })):find("dedupe", 1, true) ~= nil, "non-boolean dedupe rejected",
      why2(api2{ dedupe = "no" }))
check(tostring(why2(api2{ api = 3 })):find("api must be 1 or 2", 1, true) ~= nil, "api 3 rejected", why2(api2{ api = 3 }))
check(why2(api2{ api = "2" }) ~= nil, "api as a string rejected")
check(why2(api2{ api = 1.5 }) ~= nil, "api 1.5 rejected")

print("== Folders: api 1 never reads the api-2 fields ==")
local helpers = { api = 1, id = "helpy", name = "Helpy",
    root = "https://helpy.example/api", list = function() error("api-1 helper called by the host") end,
    search_in = "not a function", dedupe = "sometimes",
    search = function() return {}, false end, resolve = function(loc) return loc.url end }
check(Catalog.validate(helpers), "api 1 with helpers named root/list/search_in/dedupe validates", why2(helpers))
check(Catalog.register(helpers), "…and registers")
local roots_seen = {}
for __, r in ipairs(Catalog.roots()) do roots_seen[r.provider.id] = r.title end
eq(roots_seen.helpy, nil, "an api-1 root helper makes no Browse root")
check(Catalog.register(api2{ id = "rooty", name = "Rooty", root = "Course materials" }), "api 2 with a root registers")
check(Catalog.register(api2{ id = "rootless", name = "Rootless" }), "api 2 without a root registers")
roots_seen = {}
local root_ids = {}
for __, r in ipairs(Catalog.roots()) do
    roots_seen[r.provider.id] = r.title
    root_ids[#root_ids + 1] = r.provider.id
end
eq(roots_seen.rooty, "Course materials", "an api-2 root is listed with its title")
eq(roots_seen.rootless, nil, "an api-2 provider without root has none")
eq(table.concat(root_ids, ","), "rooty", "only providers with a root are listed")

print("== Folders: Catalog.stamp ==")
local P2 = api2{ id = "stamp2", name = "Stamp Two", quality = 20 }
local P1 = { api = 1, id = "stamp1", name = "Stamp One", search = P2.search, resolve = P2.resolve }
local function rows_for_stamp()
    return {
        Entry.folder{ title = "Built", locator = { folder = "b" }, path = { "A" }, count = 2 },
        { action = "folder", title = "Raw", locator = { folder = "r" }, subtitle = "S" },
        Entry.new{ title = "File", author = "Prof", locator = { url = "https://f/1" }, size = 10, path = { "A", "B" } },
    }
end
local st2 = Catalog.stamp(P2, rows_for_stamp())
eq(#st2, 3, "api 2: folder rows kept")
eq(st2[1].action, "folder", "built folder row stays a folder")
eq(st2[1].provider, "stamp2", "folder row stamped with the provider id")
eq(st2[1].source, "Stamp Two", "folder row stamped with the provider name")
eq(st2[1].author, nil, "stamped folder row has no author")
eq(st2[1].format, nil, "stamped folder row has no format")
eq(st2[1].count, 2, "stamped folder row keeps count")
eq(st2[2].action, "folder", "a raw folder row is normalized as a folder, not a download")
eq(st2[2].subtitle, "S", "raw folder row keeps its subtitle")
eq(st2[2].author, nil, "raw folder row gets no Unknown author")
eq(st2[2].format, nil, "raw folder row gets no epub format")
eq(st2[3].size, 10, "api 2: file size kept")
eq(table.concat(st2[3].path, "/"), "A/B", "api 2: file path kept")
local warned = {}
local Logger = require("logger")
local real_warn = Logger.warn
Logger.warn = function(...) warned[#warned + 1] = table.concat({ tostring(select(1, ...)), tostring(select(2, ...)) }, " ") end
local st1 = Catalog.stamp(P1, rows_for_stamp())
Logger.warn = real_warn
eq(#st1, 1, "api 1: folder rows dropped, built or raw")
eq(st1[1].title, "File", "api 1: the file row stays")
eq(st1[1].size, nil, "api 1: size stripped")
eq(st1[1].path, nil, "api 1: path stripped")
eq(#warned, 2, "api 1: one log line per dropped folder row")
check((warned[1] or ""):find("folder", 1, true) ~= nil, "the log line says why", warned[1])

print("== Folders: dedupe, filters, groups (DESIGN.md 12.5) ==")
local Merge = api2{ id = "merge2", name = "Merge Two" }
local NoMerge = api2{ id = "nomerge", name = "No Merge", dedupe = false }
local function aula(n, loc) return Entry.new{ title = "Aula " .. n, author = "Prof", format = "pdf", locator = { url = loc } } end
local function wk(loc) return Entry.folder{ title = "Week 1", locator = { folder = loc } } end
local RF = Results.new({ "merge2", "nomerge" })
RF:setProvider("merge2", Catalog.stamp(Merge, { wk("w1"), wk("w2"), wk("w1"), aula(1, "https://m/1"), aula(1, "https://m/2") }), false)
local fl, fcol = RF:flatten()
local titles = {}
for i, r in ipairs(fl) do titles[i] = r.title .. "@" .. Entry.locatorKey(r.locator) end
eq(table.concat(titles, ","), "Week 1@folder=w1,Week 1@folder=w2,Aula 1@https://m/1",
   "same-titled folders stay apart; the same folder twice is one row; files still merge")
eq(fcol, 2, "collapsed: the repeated folder and the second Aula 1")
RF:setProvider("nomerge", Catalog.stamp(NoMerge, { aula(1, "https://n/1"), aula(1, "https://n/2"), aula(1, "https://n/1") }), false)
fl = RF:flatten()
local nm = {}
for __, r in ipairs(fl) do if r.provider == "nomerge" then nm[#nm + 1] = r.locator.url end end
eq(table.concat(nm, ","), "https://n/1,https://n/2", "dedupe = false: same-titled files stay apart, the same file once")
eq(#fl, 5, "dedupe = false rows never merge with another provider's same work either")
local api1_nomerge = Catalog.stamp({ api = 1, id = "old", name = "Old", dedupe = false }, { aula(1, "https://o/1"), aula(1, "https://o/2") })
local RO = Results.new({ "old" })
RO:setProvider("old", api1_nomerge, false)
eq(#RO:flatten(), 1, "api 1 ignores a dedupe field: its rows merge as before")
eq(#RF:flatten({ format = "pdf" }), 5, "folders pass the pdf format filter")
eq(#RF:flatten({ format = "epub" }), 2, "folders pass the epub filter; pdf files do not")
eq(#RF:flatten({ sources = { nomerge = true } }), 2, "folders obey the source filter")
local grouped = Catalog.group(RF:flatten())
eq(grouped[1].action, "folder", "folders group first")
eq(grouped[1].heading, "Folders", "under a Folders heading")
eq(grouped[1].glyph, "folder", "with the folder glyph")
eq(#grouped[1].items, 2, "both folders in the group")
eq(grouped[2].action, "download", "files after the folders")

print("== Folders: Catalog.list / Catalog.searchIn (PROVIDERS.md 5.5, 5.6) ==")
local calls = {}
Catalog.register(api2{ id = "lister", name = "Lister", quality = 7, root = "Top",
    list = function(loc, limit, page, ctx)
        calls[#calls + 1] = { what = "list", loc = loc, limit = limit, page = page, ctx = ctx }
        if loc and loc.folder == "boom" then error("list exploded") end
        if loc and loc.folder == "gone" then return nil, "folder gone" end
        return { ctx.Entry.folder{ title = "Sub", locator = { folder = "sub" } },
                 ctx.Entry.new{ title = "File", locator = { url = "https://l/1" } },
                 ctx.Entry.new{ title = "No locator" } }, page == 1 and "yes" or nil
    end,
    search_in = function(loc, query, limit, page, ctx)
        calls[#calls + 1] = { what = "search_in", loc = loc, query = query, limit = limit, page = page, ctx = ctx }
        if query == "fail" then return nil, "search broke" end
        return { ctx.Entry.new{ title = query .. " hit", locator = { url = "https://l/q" }, path = { "Top", "Sub" } } }, false
    end })
local lrows, lmore = Catalog.list("lister", nil, 50, 1)
eq(#lrows, 2, "list rows stamped; the locator-less one dropped")
eq(lrows[1].action, "folder", "list may return folder rows")
eq(lrows[1].provider, "lister", "list rows carry the provider id")
eq(lrows[2].quality, 7, "list rows get the provider quality")
eq(lmore, true, "a truthy has_more reads as true")
eq(calls[1].loc, nil, "list(nil) asks for the root")
eq(calls[1].limit, 50, "limit passed through")
eq(calls[1].page, 1, "page passed through")
eq(type(calls[1].ctx), "table", "ctx last")
local _, lmore2 = Catalog.list("lister", { folder = "sub" }, 50, 2)
eq(lmore2, false, "has_more absent -> false")
eq(calls[2].loc.folder, "sub", "the folder's locator reaches list")
eq(calls[2].page, 2, "page 2 asked")
local lnil, lerr = Catalog.list("lister", { folder = "gone" }, 50, 1)
check(lnil == nil and lerr == "folder gone", "list nil, reason -> nil, reason", lerr)
lnil, lerr = Catalog.list("lister", { folder = "boom" }, 50, 1)
check(lnil == nil and tostring(lerr):find("list exploded", 1, true) ~= nil, "a raising list is caught", lerr)
lnil, lerr = Catalog.list("nope", nil, 50, 1)
check(lnil == nil and tostring(lerr):find("unknown source", 1, true) ~= nil, "list: unknown source", lerr)
local n_calls = #calls
lnil, lerr = Catalog.list("helpy", nil, 50, 1)
check(lnil == nil and type(lerr) == "string", "list on an api-1 provider is an error", lerr)
eq(#calls, n_calls, "…and never calls its list helper")
local qrows, qmore = Catalog.searchIn("lister", { folder = "sub" }, "sso", 15, 1)
eq(#qrows, 1, "searchIn rows stamped")
eq(qrows[1].source, "Lister", "searchIn rows carry the source")
eq(table.concat(qrows[1].path, "/"), "Top/Sub", "searchIn rows keep their path")
eq(qmore, false, "searchIn has_more is a boolean")
local last = calls[#calls]
eq(last.what, "search_in", "search_in called")
eq(last.loc.folder, "sub", "searchIn passes the folder locator")
eq(last.query, "sso", "…the query")
eq(last.limit, 15, "…the search page size")
eq(last.page, 1, "…and the page")
Catalog.searchIn("lister", nil, "x", 10, 1)
eq(calls[#calls].loc, nil, "searchIn(nil) searches the root")
local qnil, qerr = Catalog.searchIn("lister", nil, "fail", 10, 1)
check(qnil == nil and qerr == "search broke", "searchIn nil, reason -> nil, reason", qerr)
qnil, qerr = Catalog.searchIn("rooty", nil, "x", 10, 1)
check(qnil == nil and type(qerr) == "string", "searchIn without search_in is an error", qerr)
qnil, qerr = Catalog.searchIn("helpy", nil, "x", 10, 1)
check(qnil == nil and type(qerr) == "string", "searchIn on an api-1 provider is an error", qerr)
end)()

;(function() -- provider_check folders step (api 2): own function, local limit
print("== provider_check: folders step (api 2, PROVIDERS.md 10) ==")
local Check = dofile(this .. "../tools/provider_check.lua")
local NONE = {}   -- tree{ root = NONE } removes the root (pairs skips nil values)
local function tree(over)
    local seen = { listed = {}, resolved = {}, scoped = {} }
    local p = {
        api = 2, id = "treecheck", name = "Tree Check", root = "Top",
        search = function(q, _l, _p, ctx)
            return { ctx.Entry.folder{ title = "Found " .. q, locator = { folder = "found", n = 3 } },
                     ctx.Entry.new{ title = "Loose", locator = { url = "https://t/loose" } } }, false
        end,
        list = function(loc, limit, page, ctx)
            seen.listed[#seen.listed + 1] = (loc and loc.folder or "<root>") .. ":" .. page .. ":" .. limit
            seen.last_loc = loc
            return { ctx.Entry.folder{ title = "Sub", locator = { folder = "sub" } },
                     ctx.Entry.new{ title = "Inner", locator = { url = "https://t/inner" } } }, false
        end,
        resolve = function(loc)
            seen.resolved[#seen.resolved + 1] = loc.url or ("folder " .. tostring(loc.folder))
            return loc.url
        end,
    }
    for k, val in pairs(over or {}) do
        if val == NONE then p[k] = nil else p[k] = val end
    end
    return p, seen
end
local function run(p, extra)
    local lines = {}
    local opts = { provider = p, query = "cats", offline = true, out = function(l) lines[#lines + 1] = l end }
    for k, val in pairs(extra or {}) do opts[k] = val end
    local ok, problems = Check.run(opts)
    return ok, table.concat(problems or {}, " | "), table.concat(lines, "\n")
end
local function fails_with(p, needle, label, extra)
    local ok, problems = run(p, extra)
    check(ok == false and problems:find(needle, 1, true) ~= nil, label, problems)
end
local function files_only(specs) return function(_q, _l, _p, ctx)
    local built = {}
    for i, r in ipairs(specs) do built[i] = ctx.Entry.new(r) end
    return built, false
end end

local p, seen = tree()
local ok, problems, text = run(p)
check(ok == true, "a well-formed api-2 provider passes", problems)
eq(table.concat(seen.listed, ","), "<root>:1:50,found:1:50", "lists the root, then the first folder row of search, 50 rows a page")
check(text:find("ok    folders", 1, true) ~= nil, "prints the folders step", text)
eq(seen.last_loc and seen.last_loc.n, 3, "the folder locator reaches list after its JSON round trip")
eq(table.concat(seen.resolved, ","), "https://t/loose", "resolve skips the folder row and takes the file")

p, seen = tree{ root = NONE }
run(p)
eq(table.concat(seen.listed, ","), "found:1:50", "no root: only the first folder row is listed")
p, seen = tree{ search = files_only{ { title = "Loose", locator = { url = "https://t/loose" } } } }
run(p)
eq(table.concat(seen.listed, ","), "<root>:1:50,sub:1:50", "no folder in search: the root's first folder row is listed")
p, seen = tree{ root = NONE, search = files_only{ { title = "Loose", locator = { url = "https://t/loose" } } },
    shelves = { { key = "top", title = "Top" } },
    browse = function(_k, _l, ctx) return { ctx.Entry.folder{ title = "Shelved", locator = { folder = "shelved" } } }, false end }
ok, problems = run(p)
check(ok == true, "a shelf of folder rows passes", problems)
eq(table.concat(seen.listed, ","), "shelved:1:50", "no folder in search: the first shelf folder row is listed")
p, seen = tree{ root = NONE, search = files_only{ { title = "Loose", locator = { url = "https://t/loose" } } } }
ok, problems, text = run(p)
check(ok == true, "nothing to list still passes", problems)
check(text:find("nothing to list", 1, true) ~= nil, "…with a nothing-to-list warning", text)
eq(#seen.listed, 0, "…and no list call")

fails_with(tree{ list = function() error("list kaboom") end }, "list kaboom", "a raising list fails")
fails_with(tree{ list = function() return nil, "folder denied" end }, "folder denied", "list nil, err fails with err")
fails_with(tree{ list = function(_l, limit, _p, ctx)
    local many = {}
    for i = 1, limit + 1 do many[i] = ctx.Entry.new{ title = "f" .. i, locator = { id = i } } end
    return many, false
end }, "51 rows for limit 50", "more rows than the folder page size fails")
fails_with(tree{ list = function(_l, _n, _p, ctx)
    return { ctx.Entry.new{ title = "f", locator = { id = 1 } } }, "maybe"
end }, "has_more must be a boolean", "a non-boolean list has_more fails")
fails_with(tree{ list = function() return { { title = "bad", locator = { url = "u" }, fn = print } }, false end },
    "function", "a list row that is not plain data fails")
ok, problems = run(tree{ list = function() return {}, false end })
check(ok == true, "an empty folder passes", problems)

local pages = {}
ok, problems = run(tree{ root = NONE, list = function(_l, _n, page, ctx)
    pages[#pages + 1] = page
    local got = {}
    for i = (page - 1) * 2 + 1, page * 2 do got[#got + 1] = ctx.Entry.new{ title = "f" .. i, locator = { id = i } } end
    return got, page == 1
end })
check(ok == true, "a paged folder passes", problems)
eq(table.concat(pages, ","), "1,2", "page 1 said has_more -> page 2 listed too")
fails_with(tree{ list = function(_l, _n, _p, ctx)
    return { ctx.Entry.new{ title = "f", locator = { id = 1 } } }, true
end }, "repeats 1 row", "page 2 repeating page 1 fails")

local scoped = {}
ok, problems = run(tree{ search_in = function(loc, q, limit, page, ctx)
    scoped[#scoped + 1] = { loc = loc, q = q, limit = limit, page = page }
    return { ctx.Entry.new{ title = q .. " inside", locator = { url = "https://t/s" }, path = { "Found" } } }, false
end }, { limit = 7 })
check(ok == true, "a working search_in passes", problems)
eq(#scoped, 1, "search_in runs once")
eq(scoped[1] and scoped[1].loc and scoped[1].loc.folder, "found", "…on the first folder row")
eq(scoped[1] and scoped[1].q, "cats", "…with the query")
eq(scoped[1] and scoped[1].limit, 7, "…and --limit")
eq(scoped[1] and scoped[1].page, 1, "…page 1")
ok, problems = run(tree{ search_in = function() return {}, false end })
check(ok == true, "search_in with no hits passes", problems)
fails_with(tree{ search_in = function() return nil, "scope broke" end }, "scope broke", "a failing search_in fails")
fails_with(tree{ search_in = function(_l, _q, limit, _p, ctx)
    local many = {}
    for i = 1, limit + 1 do many[i] = ctx.Entry.new{ title = "s" .. i, locator = { id = i } } end
    return many, false
end }, "rows for limit", "search_in over --limit fails")

p, seen = tree{ search = function(_q, _l, _p, ctx)
    return { ctx.Entry.folder{ title = "Only", locator = { folder = "only" } } }, false
end }
ok, problems = run(p)
check(ok == true, "search with only folder rows passes", problems)
eq(table.concat(seen.resolved, ","), "https://t/inner", "resolve uses the first file found inside a folder")
p, seen = tree{ search = function(_q, _l, _p, ctx)
    return { ctx.Entry.folder{ title = "Only", locator = { folder = "only" } } }, false
end, list = function(_l, _n, _p, ctx) return { ctx.Entry.folder{ title = "Deeper", locator = { folder = "d" } } }, false end }
ok, problems, text = run(p)
check(ok == true, "no file anywhere still passes", problems)
check(text:find("warn  resolve", 1, true) ~= nil, "…with resolve skipped and a warning", text)
eq(#seen.resolved, 0, "…and nothing resolved")

fails_with({ api = 1, id = "oldfold", name = "Old Fold",
    search = function(_q, _l, _p, ctx)
        return { ctx.Entry.folder{ title = "F", locator = { folder = "f" } },
                 ctx.Entry.new{ title = "x", locator = { url = "https://o/x" } } }, false
    end, resolve = function(loc) return loc.url end }, "folders need api = 2", "an api-1 provider returning folder rows fails the rows step")
end)()

---------------------------------------------------------------------------
-- Closing a view refreshes the panel (#25): KOReader drops the refresh of a
-- bare UIManager:close, so every OpenShelf view asks for a full-screen "ui"
-- refresh itself, except when OpenShelf is leaving to open a book (the
-- reader does its own full refresh) or the host UI is tearing down.
---------------------------------------------------------------------------
do
local CloseRefresh = require("openshelf_closerefresh")
local fm, reader, gone = {}, {}, { tearing_down = true }
eq(CloseRefresh.mode(fm, nil), "ui", "closing a view over the file manager -> ui refresh")
eq(CloseRefresh.mode(nil, reader), "ui", "closing a view over the reader -> ui refresh")
eq(CloseRefresh.mode(gone, nil), nil, "file manager tearing down -> no refresh")
eq(CloseRefresh.mode(nil, gone), nil, "reader tearing down -> no refresh")
eq(CloseRefresh.mode(gone, reader), "ui", "one live host is enough")
eq(CloseRefresh.mode(nil, nil), nil, "no file manager or reader -> no refresh")
local seen
CloseRefresh.leavingForBook(function() seen = CloseRefresh.mode(fm, nil) end)
eq(seen, nil, "closing while leaving to open a book -> no refresh")
eq(CloseRefresh.mode(fm, nil), "ui", "back to refreshing once the book hand-off is done")
local ok = pcall(CloseRefresh.leavingForBook, function() error("boom") end)
check(not ok, "leavingForBook propagates errors")
eq(CloseRefresh.mode(fm, nil), "ui", "a failed hand-off does not leave refreshes suppressed")
end


---------------------------------------------------------------------------
-- Self-update (#6): version compare, release JSON, checksum file, staged
-- plugin validation, zip entry vetting, 24 h throttle, "Later", folder swap.
---------------------------------------------------------------------------
print("== openshelf_updater_logic ==")
;(function() -- own function: the main chunk is at the 200-local limit
local U = require("openshelf_updater_logic")
eq(U.compare("0.10.0", "0.9.9"), 1, "0.10.0 > 0.9.9 (numeric, not string)")
eq(U.compare("0.6.1", "0.6.1"), 0, "equal versions")
eq(U.compare("v0.6.1", "0.6.2"), -1, "leading v accepted")
eq(U.compare("1.0.0", "0.99.99"), 1, "major wins")
eq(U.compare("0.7.0-rc1", "0.6.1"), nil, "prerelease suffix is not a version")
eq(U.compare("0.7", "0.6.1"), nil, "two-part version rejected")
check(U.isNewer("0.6.2", "0.6.1") and not U.isNewer("0.6.1", "0.6.1") and not U.isNewer("0.6.0", "0.6.1"),
      "isNewer only for strictly newer")
check(not U.isNewer(nil, "0.6.1") and not U.isNewer("garbage", "0.6.1"), "isNewer false on junk")

local function rel_json(over)
    local t = {
        tag_name = "v0.6.2", draft = false, prerelease = false, body = "## What's changed\n* Updater",
        html_url = "https://github.com/x/releases/v0.6.2",
        assets = {
            { name = "openshelf-v0.6.2.zip", browser_download_url = "https://dl/zip", size = 1234 },
            { name = "openshelf-v0.6.2.zip.sha256", browser_download_url = "https://dl/sha", size = 87 },
        },
    }
    for k, val in pairs(over or {}) do t[k] = val end
    return t
end
local r = U.parseRelease(rel_json())
check(r ~= nil, "a well-formed release parses")
eq(r and r.version, "0.6.2", "release version from the tag")
eq(r and r.zip.url, "https://dl/zip", "zip asset found by name")
eq(r and r.zip.size, 1234, "zip asset size kept")
eq(r and r.sha256 and r.sha256.url, "https://dl/sha", "checksum asset found by name")
local r2, e2 = U.parseRelease(rel_json{ prerelease = true })
check(r2 == nil and e2:find("prerelease"), "prerelease ignored", e2)
check(U.parseRelease(rel_json{ draft = true }) == nil, "draft ignored")
check(U.parseRelease(rel_json{ tag_name = "v0.7.0-beta" }) == nil, "suffixed tag ignored")
check(U.parseRelease(rel_json{ tag_name = "0.6.2" }) == nil, "tag without v ignored")
check(U.parseRelease(rel_json{ tag_name = NULL }) == nil, "null tag ignored")
local r3, e3 = U.parseRelease(rel_json{ assets = { { name = "other.zip", browser_download_url = "u" } } })
check(r3 == nil and e3:find("openshelf-v0.6.2.zip", 1, true), "release without the zip refused", e3)
local r4 = U.parseRelease(rel_json{ assets = { { name = "openshelf-v0.6.2.zip", browser_download_url = "u" } } })
check(r4 and r4.sha256 == nil, "missing checksum asset reported as nil (install refuses)")
local r5 = U.parseRelease(rel_json{ body = NULL })
eq(r5 and r5.notes, "", "null release notes -> empty")
check(U.parseRelease(nil) == nil and U.parseRelease({ message = "API rate limit exceeded" }) == nil,
      "error objects are not releases")
local real = U.parseRelease(read_fixture("github_release_latest.json"))
eq(real and real.tag, "v0.6.1", "recorded GitHub /releases/latest parses")
check(real and real.sha256 == nil and real.zip.size and real.zip.size > 0,
      "recorded v0.6.1 has the zip (sized) but no checksum asset")

local H = string.rep("ab", 32)
eq(U.parseChecksum(H .. "  openshelf-v0.6.2.zip\n", "openshelf-v0.6.2.zip"), H, "sha256sum line parses")
eq(U.parseChecksum(H:upper() .. " *openshelf-v0.6.2.zip", "openshelf-v0.6.2.zip"), H, "binary-mode marker, upper hex")
eq(U.parseChecksum(H, "openshelf-v0.6.2.zip"), H, "bare hash accepted")
check(U.parseChecksum(H .. "  other.zip", "openshelf-v0.6.2.zip") == nil, "checksum for another file refused")
check(U.parseChecksum(string.rep("a", 63), "x") == nil, "short hash refused")
check(U.parseChecksum("not a hash", "x") == nil and U.parseChecksum(nil, "x") == nil, "junk refused")

eq(U.notesExcerpt("## What's changed\n\n\n* **Fix** things\r\n", 400), "What's changed\n\n* Fix things",
   "notes: headings and bold dropped, blank runs squeezed")
local long = U.notesExcerpt(string.rep("word ", 200), 100)
check(#long <= 104 and long:sub(-3) == "…", "long notes cut with an ellipsis", #long)
eq(U.notesExcerpt(NULL), "", "null notes -> empty")

eq(U.stagedVersion('-- comment\nreturn "0.6.2"\n'), "0.6.2", "staged version read as text")
eq(U.stagedVersion("return 42"), nil, "non-string version -> nil")
local files = { ["_meta.lua"] = true, ["main.lua"] = true, ["openshelf_version.lua"] = true }
local function has(f) return files[f] end
check(U.validateStaged(has, 'return "0.6.2"', "0.6.2"), "staged plugin with matching version is valid")
local okv, whyv = U.validateStaged(has, 'return "0.6.1"', "0.6.2")
check(not okv and whyv:find("0.6.1", 1, true), "staged version != tag refused", whyv)
files["main.lua"] = nil
local okm, whym = U.validateStaged(has, 'return "0.6.2"', "0.6.2")
check(not okm and whym:find("main.lua", 1, true), "staged plugin without main.lua refused", whym)

check(U.archiveEntryOk("openshelf.koplugin/", "directory"), "root dir entry allowed")
check(U.archiveEntryOk("openshelf.koplugin/providers/doab.lua", "file"), "nested file allowed")
check(not U.archiveEntryOk("openshelf.koplugin/../../x.lua", "file"), ".. refused")
check(not U.archiveEntryOk("/etc/passwd", "file"), "absolute path refused")
check(not U.archiveEntryOk("other.koplugin/main.lua", "file"), "other top-level folder refused")
check(not U.archiveEntryOk("openshelf.koplugin/link", "link"), "symlink entry refused")

local DAY = U.CHECK_INTERVAL
check(U.shouldAutoCheck({ auto = true }, 1000), "never checked -> due")
check(U.shouldAutoCheck({}, 1000), "auto defaults on")
check(not U.shouldAutoCheck({ auto = false }, 1000), "auto off -> never")
check(not U.shouldAutoCheck({ auto = true, last_check = 1000 }, 1000 + DAY - 1), "within 24 h -> not due")
check(U.shouldAutoCheck({ auto = true, last_check = 1000 }, 1000 + DAY), "24 h later -> due")
check(U.shouldAutoCheck({ auto = true, last_check = 5000 }, 1000), "clock went backwards -> due")
check(not U.shouldPrompt({ skipped = "0.6.2" }, "0.6.2", false), "Later suppresses that version on auto checks")
check(U.shouldPrompt({ skipped = "0.6.2" }, "0.6.2", true), "manual check still offers it")
check(U.shouldPrompt({ skipped = "0.6.2" }, "0.6.3", false), "a newer release is offered again")
check(U.shouldPrompt({}, "0.6.2", false), "nothing skipped -> offer")

-- Folder swap over a fake filesystem: { path = "contents" }.
local function fakefs(t, fail_on)
    return {
        exists = function(p) return t[p] ~= nil end,
        remove_tree = function(p) if fail_on ~= "remove" then t[p] = nil end; return true end,
        rename = function(a, b)
            if fail_on == a .. ">" .. b or t[a] == nil then return nil, "EIO" end
            t[b], t[a] = t[a], nil
            return true
        end,
    }
end
local L, S = "p/openshelf.koplugin", "p/openshelf.koplugin.staging/openshelf.koplugin"
local fs1 = { [L] = "v1", [L .. ".old"] = "v0", [S] = "v2" }
check(U.swap(fakefs(fs1), L, S), "swap succeeds")
check(fs1[L] == "v2" and fs1[L .. ".old"] == "v1" and fs1[S] == nil, "new live, one .old backup (the previous one replaced)")
local fs2 = { [L] = "v1", [S] = "v2" }
local ok2, err2 = U.swap(fakefs(fs2, S .. ">" .. L), L, S)
check(not ok2 and fs2[L] == "v1" and fs2[L .. ".old"] == nil, "failed install rename -> live restored", err2)
local fs3 = { [L] = "v1", [S] = "v2" }
local ok3 = U.swap(fakefs(fs3, L .. ">" .. L .. ".old"), L, S)
check(not ok3 and fs3[L] == "v1", "cannot move live aside -> nothing changed")
local fs4 = { [L] = "v1", [L .. ".old"] = "v0", [S] = "v2" }
local ok4 = U.swap(fakefs(fs4, "remove"), L, S)
check(not ok4 and fs4[L] == "v1" and fs4[L .. ".old"] == "v0", "stuck old backup -> abort before touching live")
check(not U.swap(fakefs({ [L] = "v1" }), L, S), "no staged folder -> refuse")

check(U.isZip("PK\3\4rest of zip"), "zip signature accepted")
check(not U.isZip("ustar\0") and not U.isZip("PK") and not U.isZip(nil) and not U.isZip("<html>"),
      "tar / short / html / nil are not zips")

check(U.urlAllowed("https://api.github.com/x", false), "https allowed")
check(U.urlAllowed("HTTPS://objects.githubusercontent.com/x", false), "https scheme case-insensitive")
check(not U.urlAllowed("http://github.com/x", false), "plain http refused")
check(not U.urlAllowed("http://127.0.0.1:8765/ok.json", false), "local http refused without the dev override")
check(U.urlAllowed("http://127.0.0.1:8765/ok.json", true), "local http allowed with the dev override")
check(U.urlAllowed("http://localhost/ok.json", true), "localhost allowed with the dev override")
check(not U.urlAllowed("http://example.com/ok.json", true), "remote http refused even with the override")
check(not U.urlAllowed("http://127.0.0.1.evil.com/x", true), "lookalike host refused")
check(not U.urlAllowed("http://127.0.0.1@evil.com/x", true), "userinfo trick refused")
check(not U.urlAllowed("ftp://x/y", true) and not U.urlAllowed("file:///etc/passwd", true) and not U.urlAllowed(nil, true),
      "other schemes refused")
check(U.releaseUrlsOk(r, false), "GitHub-style https assets pass")
local insecure = U.parseRelease(rel_json{ assets = {
    { name = "openshelf-v0.6.2.zip", browser_download_url = "http://dl/zip", size = 1 },
    { name = "openshelf-v0.6.2.zip.sha256", browser_download_url = "https://dl/sha" } } })
local okr, errr = U.releaseUrlsOk(insecure, false)
check(not okr and errr:find("http://dl/zip", 1, true), "http asset URL refused", errr)
end)()


print("== module names vs KOReader's own ==")
-- Plugins share one flat require() namespace with KOReader. Anything KOReader
-- loaded before plugins is cached in package.loaded, so a sibling with the same
-- name is silently shadowed (v0.4 shipped a version.lua and never loaded).
-- Names below: frontend/*.lua, base dir *.lua and common/*.lua of KOReader
-- v2026.07.2, plus flat modules of its bundled plugins.
local RESERVED = {}
for name in ([[
  cache cacheitem cachesqlite configurable datetime dbg depgraph device dispatcher
  docsettings dump fontlist gettext httpclient languagesupport logger luadata
  luadefaults luasettings luxl optmath persist pluginloader pluginshare provider
  random readcollection readhistory socketutil sort userpatch util version
  datastorage defaults history reader setupkoenv
  Spore dkjson htmlparser json ltn12 mime re socket ssl turbo
  KOSyncClient KOSyncQueue aliases base bookinfomanager calendarview clip
  cloudstorage covermenu db deinflector epubdownloadbackend event_map_keyboard
  extensions feed_config feed_view listmenu metadata migration mosaicmenu
  opdsbrowser opdsparser opdspse readerprogress search suntime terminputtext wireless
]]):gmatch("%S+") do RESERVED[name] = true end
local scanned = {}
local function scan(subdir)
    local ls = io.popen('ls "' .. PLUGIN_DIR .. (subdir and ("/" .. subdir) or "") .. '"')
    for file in ls:lines() do
        local mod = file:match("^(.-)%.lua$")
        if mod then
            local name = subdir and (subdir .. "/" .. mod) or mod
            scanned[name] = true
            check(not RESERVED[mod] and not RESERVED[name], "module name not taken by KOReader: " .. name)
        end
    end
    ls:close()
end
scan(nil)
scan("providers")
local n = 0
for __ in pairs(scanned) do n = n + 1 end
check(n >= 10, "listed the plugin modules", n)
check(scanned["providers/gutendex"] and scanned["providers/internetarchive"] and scanned["providers/doab"],
      "guard scans the providers subfolder")
check(scanned["openshelf_providers"], "guard sees the provider list module")
check(not scanned["providers_gutendex"], "old flat provider modules are gone")
local ver = require("openshelf_version")
check(type(ver) == "string" and ver:match("^%d+%.%d+") ~= nil, "openshelf_version is a dotted string", ver)

print(("RESULT: %s (%d checks, %d failed)"):format(
    failures == 0 and "PASS" or "FAIL", checks, failures))
os.exit(failures == 0 and 0 or 1)
