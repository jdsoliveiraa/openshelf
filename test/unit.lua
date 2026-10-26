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
