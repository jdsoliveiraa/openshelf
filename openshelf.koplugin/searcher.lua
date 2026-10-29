--[[
Parallel search (DESIGN.md §3.2): one subprocess per enabled provider, each
running Catalog.searchOne; results land in a slot-ordered Results model and
the view is told after every change. Providers are named by id throughout
(DESIGN.md §9.2); the view turns ids into display names with Catalog.nameOf.

  local s = Searcher.new{
      query = "emma", ids = { "gutendex", … }, per_source = 15,
      on_update = function(results, id) end,     -- after each provider lands/fails
      on_complete = function(results) end,       -- when no provider is pending
  }
  s:start();  s:loadMore();  s:cancel()
--]]
local Catalog = require("catalog")
local Jobs = require("jobs")
local Results = require("results")

local Searcher = {}
Searcher.__index = Searcher

function Searcher.new(opts)
    local self = setmetatable({}, Searcher)
    self.query = opts.query
    self.ids = opts.ids or Catalog.ids()
    self.per_source = opts.per_source or 15
    self.on_update = opts.on_update or function() end
    self.on_complete = opts.on_complete or function() end
    self.results = Results.new(self.ids)
    self.jobs = {}
    self.cancelled = false
    return self
end

function Searcher:_run(id, page, append)
    local query, per_source = self.query, self.per_source
    self.results:setPending(id)
    self.jobs[id] = Jobs.run{
        timeout = Jobs.DEADLINE,   -- slot reads "<name>: timed out" on expiry
        task = function()
            local entries, more_or_err = Catalog.searchOne(id, query, per_source, page)
            if not entries then error(more_or_err or "unknown error", 0) end
            return { entries = entries, has_more = more_or_err and true or false }
        end,
        on_done = function(res)
            if self.cancelled then return end
            self.jobs[id] = nil
            if append then
                self.results:appendProvider(id, res and res.entries, res and res.has_more)
            else
                self.results:setProvider(id, res and res.entries, res and res.has_more)
            end
            self:_changed(id)
        end,
        on_error = function(err)
            if self.cancelled then return end
            self.jobs[id] = nil
            self.results:setError(id, err)
            self:_changed(id)
        end,
    }
end

function Searcher:_changed(id)
    self.on_update(self.results, id)
    if self.results:isComplete() then self.on_complete(self.results) end
end

function Searcher:start()
    for __, id in ipairs(self.ids) do
        self:_run(id, 1, false)
    end
    if #self.ids == 0 then self.on_complete(self.results) end
end

function Searcher:isSearching()
    return not self.results:isComplete()
end

-- Fetch the next page from every provider that reported more.
function Searcher:loadMore()
    local ids = self.results:withMore()
    for __, id in ipairs(ids) do
        if not self.jobs[id] then
            self:_run(id, self.results:pageOf(id) + 1, true)
        end
    end
    return #ids
end

function Searcher:cancel()
    self.cancelled = true
    for id, job in pairs(self.jobs) do
        job:cancel()
        self.jobs[id] = nil
    end
end

return Searcher
