--[[
The offline-first folder cache (DESIGN.md §12.6, decisions 76–77, ticket #18).
Pure Lua, storage injected like ttlcache.lua; Folders.cache() keeps the one
instance over openshelf_folders.json in the settings dir.

  local c = FolderCache.new{ load = fn() -> table|nil, save = fn(table),
                             now = fn() -> epoch, cap = 500 }
  FolderCache.key(id, locator)        -> "<id>|<locator identity>" ("<id>|" = the root)
  c:has(id, locator)                  -> whether the folder was ever listed
  c:open(id, locator)                 -> { entries, has_more, pages, at } | nil, and marks it opened
  c:putPage(id, locator, page, entries, has_more)   a page fetched (first open, Load more)
  c:putPages(id, locator, pages)      a refresh: { { entries, has_more }, … } replaces every page
  c:clearProvider(id)                 a provider's settings changed
  FolderCache.staleDays(at, now)      -> nil within 24 h, else whole days (>= 1)

Folders never expire: a copy older than 24 h is still shown, and refreshed
when Wi-Fi is already on. Only folders the user opened are stored, every
page loaded with its has_more and fetch time; at most `cap` folders, the
least recently opened dropped first. Rows are stored as the provider gave
them (the #19 directory is stamped when rows are shown: a folder without
`path` gets a route-dependent directory, and the key is only its locator).

Opening a folder only marks it in memory; the next write saves it, so a
cached folder opened offline costs no rewrite of the whole file.

File: { [key] = { opened = epoch, pages = { { entries, has_more, at }, … } } }
--]]
local Entry = require("entry")

local FolderCache = {}
FolderCache.__index = FolderCache

FolderCache.CAP = 500
FolderCache.REFRESH_AGE = 24 * 3600

function FolderCache.new(opts)
    local self = setmetatable({}, FolderCache)
    self._load = opts.load or function() return nil end
    self._save = opts.save or function() end
    self._now = opts.now or os.time
    self.cap = opts.cap or FolderCache.CAP
    self.data = nil
    return self
end

--- The cache key of a folder: its identity in the Entry.id space (the root,
--- locator nil, is "<id>|").
function FolderCache.key(id, locator)
    return id .. "|" .. Entry.locatorKey(locator)
end

--- Whole days a copy fetched at `at` is old, or nil while it is within the
--- refresh age (24 h). Drives "Updated N d ago" and the background refresh.
function FolderCache.staleDays(at, now)
    local age = now - (at or 0)
    if age <= FolderCache.REFRESH_AGE then return nil end
    return math.max(1, math.floor(age / 86400))
end

function FolderCache:_ensure()
    if self.data then return end
    local d = self._load()
    if type(d) ~= "table" then d = {} end
    self.data = d
end

-- A stored folder with at least one page, or nil (a hand-edited or
-- half-written record reads as never listed).
function FolderCache:_folder(id, locator)
    self:_ensure()
    local f = self.data[FolderCache.key(id, locator)]
    if type(f) ~= "table" or type(f.pages) ~= "table" or #f.pages == 0 then return nil end
    for __, p in ipairs(f.pages) do
        if type(p) ~= "table" then return nil end
    end
    return f
end

-- Drop the least recently opened folders until at most `cap` are left,
-- never `keep` (the folder just stored, even when the clock went back).
function FolderCache:_evict(keep)
    local keys = {}
    for k in pairs(self.data) do
        if k ~= keep then keys[#keys + 1] = k end
    end
    if #keys < self.cap then return end
    local function opened(k)
        local f = self.data[k]
        return type(f) == "table" and tonumber(f.opened) or 0
    end
    table.sort(keys, function(a, b)
        local oa, ob = opened(a), opened(b)
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    for i = 1, #keys - self.cap + 1 do self.data[keys[i]] = nil end
end

function FolderCache:_store(id, locator, pages)
    local key = FolderCache.key(id, locator)
    self.data[key] = { opened = self._now(), pages = pages }
    self:_evict(key)
    self._save(self.data)
end

local function page_of(entries, has_more, at)
    return { entries = type(entries) == "table" and entries or {}, has_more = has_more == true, at = at }
end

function FolderCache:has(id, locator)
    return self:_folder(id, locator) ~= nil
end

--- A cached folder: every page's rows in order, the last page's has_more,
--- how many pages, and the oldest page's fetch time (how old the copy is).
--- nil when the folder was never listed. Marks it opened.
function FolderCache:open(id, locator)
    local f = self:_folder(id, locator)
    if not f then return nil end
    f.opened = self._now()
    local entries, at = {}, nil
    for __, p in ipairs(f.pages) do
        for ___, e in ipairs(type(p.entries) == "table" and p.entries or {}) do entries[#entries + 1] = e end
        local t = tonumber(p.at) or 0
        if not at or t < at then at = t end
    end
    return { entries = entries, has_more = f.pages[#f.pages].has_more == true, pages = #f.pages, at = at }
end

--- Page `page` of a folder was fetched. Page 1 starts the copy afresh; page
--- N follows the N - 1 already stored and drops any stored after it (they
--- belonged to an older listing). A page with nothing before it (the copy
--- was cleared or evicted meanwhile) is not stored. Returns whether it was.
function FolderCache:putPage(id, locator, page, entries, has_more)
    self:_ensure()
    local pages = {}
    if page > 1 then
        local f = self:_folder(id, locator)
        if not f or #f.pages < page - 1 then return false end
        for i = 1, page - 1 do pages[i] = f.pages[i] end
    end
    pages[page] = page_of(entries, has_more, self._now())
    self:_store(id, locator, pages)
    return true
end

--- A refresh fetched pages 1..n again: they replace the whole copy.
function FolderCache:putPages(id, locator, fetched)
    self:_ensure()
    local now, pages = self._now(), {}
    for i, p in ipairs(fetched) do pages[i] = page_of(p.entries, p.has_more, now) end
    if #pages == 0 then return end
    self:_store(id, locator, pages)
end

--- Forget every folder of provider `id` (its settings changed, so its tree
--- may have too).
function FolderCache:clearProvider(id)
    self:_ensure()
    local prefix, gone = id .. "|", false
    for k in pairs(self.data) do
        if k:sub(1, #prefix) == prefix then
            self.data[k] = nil
            gone = true
        end
    end
    if gone then self._save(self.data) end
end

return FolderCache
