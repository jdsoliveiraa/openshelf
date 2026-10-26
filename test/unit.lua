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
package.path = this .. "../openshelf.koplugin/?.lua;" .. package.path

-- stubs so the provider module loads without LuaSocket
package.preload["http_util"] = function() return {} end
package.preload["logger"] = function() return { warn = function() end, dbg = function() end, info = function() end } end
package.preload["socket.url"] = function()
    return { escape = function(s) return s end }
end

local Entry = require("entry")
local Dedupe = require("dedupe")
local IA = require("providers_internetarchive")
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
    locator = { url = "https://g/158.epub" }, description = "  A   novel.  ", language = "en" }
eq(Entry.id(g1), "Project Gutenberg|https://g/158.epub", "id = source|url")
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

print("== Glyphs ==")
local Glyphs = require("glyphs")
eq(Glyphs.utf8(0x41), "A", "ascii passthrough")
eq(Glyphs.utf8(0xE9), "\195\169", "2-byte sequence")
eq(Glyphs.utf8(0xF019), "\239\128\153", "3-byte PUA sequence (download)")
eq(Glyphs.utf8(0x1F4DA), "\240\159\147\154", "4-byte sequence")
eq(#Glyphs.download, 3, "named glyph is a 3-byte string")

print("== Results (slot model) ==")
local Results = require("results")
local function mk(title, source, extra)
    local t = { title = title, author = "A. Author", source = source }
    for k, v in pairs(extra or {}) do t[k] = v end
    return Entry.download(t)
end
local R = Results.new({ "Project Gutenberg", "Internet Archive", "DOAB" })
eq(#R:pending(), 3, "all pending at start")
R:setProvider("Internet Archive", { mk("Emma", "Internet Archive"), mk("Zeta", "Internet Archive") }, true)
local flat = R:flatten()
eq(#flat, 2, "IA alone shows")
eq(flat[1].title, "Emma", "IA first while others pending")
R:setProvider("Project Gutenberg", { mk("Alpha", "Project Gutenberg"), mk("Emma", "Project Gutenberg") }, false)
flat = R:flatten()
eq(flat[1].title, "Alpha", "late Gutenberg lands in its slot ahead of IA")
eq(flat[2].title, "Emma", "Emma kept once")
eq(flat[2].source, "Project Gutenberg", "Emma upgraded to the higher-quality edition")
eq(#flat, 3, "deduped total")
local _, collapsed2 = R:flatten()
eq(collapsed2, 1, "collapsed count")
R:setError("DOAB", "403 forbidden")
check(R:isComplete(), "complete after the error")
eq(#R:errors(), 1, "error listed")
check(R:errors()[1]:find("DOAB", 1, true) ~= nil, "error names the provider")
eq(#R:withMore(), 1, "IA reported more")
eq(R:withMore()[1], "Internet Archive", "load-more candidate")
flat = R:flatten({ sources = { ["Internet Archive"] = true } })
eq(#flat, 2, "source filter keeps IA's own rows")
eq(flat[1].source, "Internet Archive", "filter applied before dedupe")
R:setProvider("DOAB", { mk("Paper", "DOAB", { format = "pdf" }) }, false)
eq(#R:flatten({ format = "pdf" }), 1, "format filter")
eq(#R:flatten({ format = "any" }), 4, "format any")
R:appendProvider("Internet Archive", { mk("Omega", "Internet Archive") }, false)
eq(R:pageOf("Internet Archive"), 2, "append bumps page")
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

print("== Provider parsers (fixtures) ==")
local Gut = require("providers_gutendex")
local gut_entries, gut_more = Gut.parse({
    next = "https://gutendex.com/books/?page=2",
    results = {
        { id = 158, title = "Emma", authors = { { name = "Austen, Jane" } },
          summaries = { "A comedy of manners." }, languages = { "en" },
          formats = { ["application/epub+zip"] = "https://g/158.epub", ["image/jpeg"] = "https://g/158.jpg" } },
        { id = 1, title = "No epub", authors = {}, formats = { ["text/plain"] = "x" } },
    } }, 10)
eq(#gut_entries, 1, "gutendex: only epub items")
eq(gut_entries[1].locator.url, "https://g/158.epub", "gutendex: locator url")
eq(gut_entries[1].description, "A comedy of manners.", "gutendex: summary")
eq(gut_entries[1].language, "en", "gutendex: language")
check(gut_more, "gutendex: has_more from next")
eq(Gut.resolve(gut_entries[1].locator), "https://g/158.epub", "gutendex: resolve")
local ia_entries, ia_more = IA.parse({ response = { numFound = 25, docs = {
    { identifier = "emma00aust", title = "Emma", creator = { "Austen, Jane" },
      description = "Scan.", date = "1816-01-01T00:00:00Z", language = "eng" } } } }, 10, 1)
eq(ia_entries[1].locator.identifier, "emma00aust", "ia: locator identifier")
eq(ia_entries[1].year, "1816", "ia: year from date")
eq(ia_entries[1].author, "Austen, Jane", "ia: first creator")
check(ia_more, "ia: more pages when numFound > page*limit")
local ia_mixed = IA.parse({ response = { numFound = 2, docs = {
    { identifier = "free1", title = "Free" },
    { identifier = "lend1", title = "Lending", ["access-restricted-item"] = "true" } } } }, 10, 1)
eq(#ia_mixed, 1, "ia: restricted docs skipped client-side")
eq(ia_mixed[1].locator.identifier, "free1", "ia: the free one kept")
local _, ia_more2 = IA.parse({ response = { numFound = 25, docs = {} } }, 10, 3)
check(not ia_more2, "ia: no more on last page")
local DOABp = require("providers_doab")
local doab_entries, doab_more = DOABp.parse({
    { name = "Open Book", metadata = { { key = "dc.contributor.author", value = "Someone" },
        { key = "dc.description.abstract", value = "About things." },
        { key = "dc.date.issued", value = "2021-05-01" }, { key = "dc.language", value = "English" } },
      bitstreams = { { bundleName = "ORIGINAL", mimeType = "application/pdf", retrieveLink = "/rest/b/1" },
                     { bundleName = "THUMBNAIL", retrieveLink = "/rest/t/1" } } },
}, 1)
eq(doab_entries[1].format, "pdf", "doab: pdf fallback")
eq(doab_entries[1].locator.url, "https://directory.doabooks.org/rest/b/1", "doab: absolute locator")
eq(doab_entries[1].year, "2021", "doab: year")
eq(doab_entries[1].cover_url, "https://directory.doabooks.org/rest/t/1", "doab: thumbnail")
check(doab_more, "doab: full page -> maybe more")
local doab_both = DOABp.parse({
    { name = "Both", metadata = {}, bitstreams = {
        { bundleName = "ORIGINAL", mimeType = "application/pdf", retrieveLink = "/rest/b/pdf" },
        { bundleName = "ORIGINAL", mimeType = "application/epub+zip", retrieveLink = "/rest/b/epub" } } },
}, 5)
eq(doab_both[1].format, "epub", "doab: epub preferred as primary")
eq(doab_both[1].alternates[1].format, "pdf", "doab: pdf offered as alternate")
eq(doab_both[1].alternates[1].locator.url, "https://directory.doabooks.org/rest/b/pdf", "doab: alternate locator")

print("== Catalog ==")
local Catalog = require("catalog")
eq(#Catalog.providerNames(), 3, "three providers")
eq(Catalog.resolve(gut_entries[1]), "https://g/158.epub", "catalog resolve dispatches by source")
local u, cerr = Catalog.resolve({ source = "Nope", locator = {} })
check(u == nil and cerr ~= nil, "unknown source -> error")
local groups = Catalog.group({ gut_entries[1], ia_entries[1] })
eq(#groups, 1, "single download group")
eq(groups[1].glyph, "download", "group carries a glyph name")

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
local plugin_dir = this .. "../openshelf.koplugin"
local ls = io.popen('ls "' .. plugin_dir .. '"')
local n = 0
for file in ls:lines() do
    local mod = file:match("^(.-)%.lua$")
    if mod then
        n = n + 1
        check(not RESERVED[mod], "module name not taken by KOReader: " .. mod)
    end
end
ls:close()
check(n >= 10, "listed the plugin modules", n)
local ver = require("openshelf_version")
check(type(ver) == "string" and ver:match("^%d+%.%d+") ~= nil, "openshelf_version is a dotted string", ver)

print(("RESULT: %s (%d checks, %d failed)"):format(
    failures == 0 and "PASS" or "FAIL", checks, failures))
os.exit(failures == 0 and 0 or 1)
