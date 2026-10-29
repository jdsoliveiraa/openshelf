--[[
Browse shelves for the home screen (DESIGN.md §2.2, §3.6): every shelf a
registered provider declares (Catalog.shelves(); Gutenberg "popular" and
"new" today), cached on disk for 24 h under the shelf id
"<provider id>:<key>", refreshed in a subprocess when stale.

  local entries, stale = Browse.get("gutendex:popular")  -- nil when nothing cached
  Browse.refresh("gutendex:popular", function(entries) … end)
--]]
local DataStorage = require("datastorage")
local Catalog = require("catalog")
local Jobs = require("jobs")
local JsonFile = require("jsonfile")
local TTLCache = require("ttlcache")

local Browse = {}

Browse.SHELF_SIZE = 12
local TTL = 24 * 3600

local cache
local function c()
    if not cache then
        local path = DataStorage:getSettingsDir() .. "/openshelf_browse.json"
        cache = TTLCache.new{
            load = function() return JsonFile.read(path) end,
            save = function(d) JsonFile.write(path, d) end,
            ttl = TTL,
        }
    end
    return cache
end

function Browse.get(kind)
    return c():get(kind)
end

local inflight = {}

function Browse.refresh(kind, on_done)
    if inflight[kind] then return inflight[kind] end
    local size = Browse.SHELF_SIZE
    inflight[kind] = Jobs.run{
        timeout = Jobs.DEADLINE,
        task = function()
            local entries, err = Catalog.browse(kind, size)
            if not entries then error(err or "browse failed", 0) end
            return entries
        end,
        on_done = function(entries)
            inflight[kind] = nil
            if entries and #entries > 0 then c():set(kind, entries) end
            if on_done then on_done(entries) end
        end,
        on_error = function()
            inflight[kind] = nil
            if on_done then on_done(nil) end
        end,
    }
    return inflight[kind]
end

return Browse
