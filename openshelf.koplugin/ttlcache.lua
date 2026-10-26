--[[
Tiny key→value cache with a time-to-live, storage injected (DESIGN.md §3.6:
browse shelves render from cache instantly, refresh when stale). Pure Lua.

  local c = TTLCache.new{ load = fn() -> table|nil, save = fn(table),
                          now = fn() -> epoch, ttl = seconds }
  local value, stale = c:get("popular")   -- nil when absent
  c:set("popular", value)
--]]
local TTLCache = {}
TTLCache.__index = TTLCache

function TTLCache.new(opts)
    local self = setmetatable({}, TTLCache)
    self._load = opts.load or function() return nil end
    self._save = opts.save or function() end
    self._now = opts.now or os.time
    self.ttl = opts.ttl or 86400
    self.data = nil
    return self
end

function TTLCache:_ensure()
    if self.data then return end
    local d = self._load()
    if type(d) ~= "table" then d = {} end
    self.data = d
end

-- Returns value, is_stale. value is nil when nothing is cached.
function TTLCache:get(key)
    self:_ensure()
    local item = self.data[key]
    if not item or item.value == nil then return nil, true end
    local age = self._now() - (item.at or 0)
    return item.value, age > self.ttl
end

function TTLCache:set(key, value)
    self:_ensure()
    self.data[key] = { at = self._now(), value = value }
    self._save(self.data)
end

function TTLCache:clear()
    self.data = {}
    self._save(self.data)
end

return TTLCache
