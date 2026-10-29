--[[
Browse shelves for the home screen (DESIGN.md §2.2, §3.6): every shelf a
registered provider declares (Catalog.shelves(); Gutenberg "popular" and
"new" today), cached on disk for 24 h under the shelf id
"<provider id>:<key>", refreshed in a subprocess when stale.

  local entries, stale, has_more = Browse.get("gutendex:popular")  -- nil when nothing cached
  Browse.refresh("gutendex:popular", function(entries) … end)
  Browse.fetchPage("gutendex:popular", 2, on_done(entries, has_more), on_error(err))

Every page is SHELF_SIZE rows, so page 1 is the cached home shelf and "See
all" pages on from there (ticket #12); only page 1 is cached, with its
has_more.
--]]
local DataStorage = require("datastorage")
local Catalog = require("catalog")
local Jobs = require("jobs")
local JsonFile = require("jsonfile")
local ShelfPager = require("shelf_pager")
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

--- Cached page 1 → entries, stale, has_more. A cache written before #12
-- (a bare entry list) reads as stale, so it is refreshed and gains has_more.
function Browse.get(kind)
    local value, stale = c():get(kind)
    local entries, has_more, legacy = ShelfPager.unpack(value)
    return entries, stale or legacy, has_more
end

local function page_task(kind, size, page)
    return function()
        local entries, more_or_err = Catalog.browse(kind, size, page)
        if not entries then error(more_or_err or "browse failed", 0) end
        return { entries = entries, has_more = more_or_err and true or false }
    end
end

local inflight = {}

function Browse.refresh(kind, on_done)
    if inflight[kind] then return inflight[kind] end
    local size = Browse.SHELF_SIZE
    inflight[kind] = Jobs.run{
        timeout = Jobs.DEADLINE,
        task = page_task(kind, size, 1),
        on_done = function(res)
            inflight[kind] = nil
            local entries = type(res) == "table" and res.entries or nil
            if entries and #entries > 0 then c():set(kind, ShelfPager.pack(entries, res.has_more)) end
            if on_done then on_done(entries) end
        end,
        on_error = function()
            inflight[kind] = nil
            if on_done then on_done(nil) end
        end,
    }
    return inflight[kind]
end

--- Page `page` (>= 2) of a shelf for "See all", in a job under the usual
-- deadline. Not cached. Returns the job handle (cancel it on close).
function Browse.fetchPage(kind, page, on_done, on_error)
    return Jobs.run{
        timeout = Jobs.DEADLINE,
        task = page_task(kind, Browse.SHELF_SIZE, page),
        on_done = function(res)
            if type(res) ~= "table" or type(res.entries) ~= "table" then
                on_error("browse failed")
                return
            end
            on_done(res.entries, res.has_more == true)
        end,
        on_error = function(err) on_error(err) end,
    }
end

return Browse
