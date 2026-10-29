--[[
My books: the persisted record of everything OpenShelf downloaded
(DESIGN.md §3.5). One record per edition (Entry.id). Storage is injected
(load/save/backup callbacks) so this module stays pure and unit-testable;
app.lua wires it to a JSON file in KOReader's settings dir.

File: { version = 2, records = { … } }. Record shape:
  { id,                      -- Entry.id: "<provider id>|<locator identity>"
    provider, source,        -- provider id (the key) and its display name at download time
    title, author, format, quality, locator, dedup_key, cover_url, cover_file,
    path, downloaded_at, description, language, year }

A version-1 file (v0.5: ids keyed by display name, no provider/quality) is
migrated once on load: `backup` receives the untouched v1 data first (app.lua
writes it to <file>.v1.bak), then the rewritten file is saved as version 2.
--]]
local Entry = require("entry")
local Migrate = require("openshelf_migrate")

local Library = {}
Library.__index = Library

-- opts.load() -> table|nil ; opts.save(table) ; opts.backup(table) (v1 data,
-- called once before the migration is saved) ; opts.now() -> epoch seconds
function Library.new(opts)
    local self = setmetatable({}, Library)
    self._load = opts.load or function() return nil end
    self._save = opts.save or function() end
    self._backup = opts.backup or function() end
    self._now = opts.now or os.time
    self.data = nil
    return self
end

function Library:_ensure()
    if self.data then return end
    local d = self._load()
    if type(d) ~= "table" or type(d.records) ~= "table" then
        self.data = { version = Migrate.LIBRARY_VERSION, records = {} }
    elseif (tonumber(d.version) or 1) < Migrate.LIBRARY_VERSION then
        self.data = Migrate.library(d)
        self._backup(d)
        self:_flush()
    else
        self.data = d
    end
end

function Library:_flush()
    self._save(self.data)
end

function Library:count()
    self:_ensure()
    return #self.data.records
end

-- All records, newest download first.
function Library:all()
    self:_ensure()
    local out = {}
    for i, r in ipairs(self.data.records) do out[i] = r end
    table.sort(out, function(a, b)
        if a.downloaded_at == b.downloaded_at then return (a.title or "") < (b.title or "") end
        return (a.downloaded_at or 0) > (b.downloaded_at or 0)
    end)
    return out
end

function Library:findById(id)
    self:_ensure()
    for __, r in ipairs(self.data.records) do
        if r.id == id then return r end
    end
    return nil
end

function Library:find(entry)
    return self:findById(Entry.id(entry))
end

function Library:findByPath(path)
    self:_ensure()
    for __, r in ipairs(self.data.records) do
        if r.path == path then return r end
    end
    return nil
end

-- Upsert a record for a downloaded entry. Returns the record.
function Library:add(entry, path, cover_file)
    self:_ensure()
    local id = Entry.id(entry)
    local rec = self:findById(id)
    if not rec then
        rec = { id = id }
        self.data.records[#self.data.records + 1] = rec
    end
    rec.title       = entry.title
    rec.author      = entry.author
    rec.provider    = entry.provider
    rec.source      = entry.source
    rec.format      = entry.format
    rec.quality     = entry.quality
    rec.locator     = entry.locator
    rec.dedup_key   = entry.dedup_key
    rec.cover_url   = entry.cover_url
    rec.cover_file  = cover_file or rec.cover_file
    rec.path        = path
    rec.description = entry.description
    rec.language    = entry.language
    rec.year        = entry.year
    rec.downloaded_at = self._now()
    self:_flush()
    return rec
end

function Library:remove(id)
    self:_ensure()
    for i, r in ipairs(self.data.records) do
        if r.id == id then
            table.remove(self.data.records, i)
            self:_flush()
            return true
        end
    end
    return false
end

-- Turn a record back into an entry-like table for the detail page.
function Library.toEntry(rec)
    return {
        title = rec.title, author = rec.author, provider = rec.provider, source = rec.source,
        action = Entry.ACTION.DOWNLOAD, format = rec.format,
        quality = rec.quality or 0, dedup_key = rec.dedup_key,
        cover_url = rec.cover_url, locator = rec.locator,
        description = rec.description, language = rec.language, year = rec.year,
    }
end

return Library
