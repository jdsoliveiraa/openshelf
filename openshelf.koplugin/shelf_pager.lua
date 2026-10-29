--[[
Paging state for a browse shelf's "See all" (PROVIDERS.md §5.3, ticket #12).
Pure Lua, no KOReader: the list view owns one, browse.lua stores page 1 in
the cache through pack/unpack.

  local pager = ShelfPager.new{ entries = page1, has_more = true }
  if pager:canLoadMore() then
      local page = pager:begin()           -- 2; nil when not allowed
      … fetch page …
      pager:append(rows, has_more)         -- -> rows actually added (deduped)
      pager:fail(err)                      -- keeps has_more: Load more retries
  end

The host asks for page N+1 only after page N said has_more == true, and
never while a fetch is running.

Cache value (openshelf_browse.json): { entries = {…}, has_more = bool,
size = browse page size it was fetched at }. unpack(value, size) flags a
value as `outdated` when its size differs (or is missing: the first #12
draft cached 12-row pages without it) or when it is a bare entry list
(before #12, read as has_more = false), so the caller refreshes it.
--]]
local Entry = require("entry")

local ShelfPager = {}
ShelfPager.__index = ShelfPager

function ShelfPager.new(opts)
    local self = setmetatable({}, ShelfPager)
    self.entries = {}
    self.seen = {}
    self.page = 1
    self.has_more = opts and opts.has_more == true or false
    self.loading = false
    self.err = nil
    for __, e in ipairs(opts and opts.entries or {}) do self:_add(e) end
    return self
end

function ShelfPager:_add(e)
    local id = Entry.id(e)
    if id and self.seen[id] then return false end
    if id then self.seen[id] = true end
    self.entries[#self.entries + 1] = e
    return true
end

function ShelfPager:canLoadMore()
    return self.has_more and not self.loading
end

--- Start fetching the next page. Returns its number, or nil when the last
--- page said no more or a fetch is already running.
function ShelfPager:begin()
    if not self:canLoadMore() then return nil end
    self.loading = true
    self.err = nil
    return self.page + 1
end

--- The next page arrived: append the rows not shown yet (a popularity list
--- can shift between requests) and take its has_more. Returns how many
--- rows were added.
function ShelfPager:append(entries, has_more)
    local added = 0
    for __, e in ipairs(type(entries) == "table" and entries or {}) do
        if self:_add(e) then added = added + 1 end
    end
    self.page = self.page + 1
    self.has_more = has_more == true
    self.loading = false
    self.err = nil
    return added
end

--- The fetch failed: remember why, keep has_more so Load more can retry.
function ShelfPager:fail(err)
    self.loading = false
    self.err = tostring(err or "failed")
end

--- Page 1 as stored in the browse cache, with the page size it was fetched at.
function ShelfPager.pack(entries, has_more, size)
    return { entries = entries or {}, has_more = has_more == true, size = size }
end

--- Cached value -> entries, has_more, outdated (fetched at another page size
--- than `size`, or a pre-#12 bare list).
function ShelfPager.unpack(value, size)
    if type(value) ~= "table" then return nil, false, false end
    if type(value.entries) == "table" then
        return value.entries, value.has_more == true, value.size ~= size
    end
    return value, false, true
end

return ShelfPager
