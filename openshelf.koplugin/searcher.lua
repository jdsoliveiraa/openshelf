--[[
Parallel search (DESIGN.md §3.2): one subprocess per enabled provider, each
running Catalog.searchOne; results land in a slot-ordered Results model and
the view is told after every change.

  local s = Searcher.new{
      query = "emma", names = { "Project Gutenberg", … }, per_source = 15,
      on_update = function(results, name) end,   -- after each provider lands/fails
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
    self.names = opts.names or Catalog.providerNames()
    self.per_source = opts.per_source or 15
    self.on_update = opts.on_update or function() end
    self.on_complete = opts.on_complete or function() end
    self.results = Results.new(self.names)
    self.jobs = {}
    self.cancelled = false
    return self
end

function Searcher:_run(name, page, append)
    local query, per_source = self.query, self.per_source
    self.results:setPending(name)
    self.jobs[name] = Jobs.run{
        task = function()
            local entries, more_or_err = Catalog.searchOne(name, query, per_source, page)
            if not entries then error(more_or_err or "unknown error", 0) end
            return { entries = entries, has_more = more_or_err and true or false }
        end,
        on_done = function(res)
            if self.cancelled then return end
            self.jobs[name] = nil
            if append then
                self.results:appendProvider(name, res and res.entries, res and res.has_more)
            else
                self.results:setProvider(name, res and res.entries, res and res.has_more)
            end
            self:_changed(name)
        end,
        on_error = function(err)
            if self.cancelled then return end
            self.jobs[name] = nil
            self.results:setError(name, err)
            self:_changed(name)
        end,
    }
end

function Searcher:_changed(name)
    self.on_update(self.results, name)
    if self.results:isComplete() then self.on_complete(self.results) end
end

function Searcher:start()
    for __, name in ipairs(self.names) do
        self:_run(name, 1, false)
    end
    if #self.names == 0 then self.on_complete(self.results) end
end

function Searcher:isSearching()
    return not self.results:isComplete()
end

-- Fetch the next page from every provider that reported more.
function Searcher:loadMore()
    local names = self.results:withMore()
    for __, name in ipairs(names) do
        if not self.jobs[name] then
            self:_run(name, self.results:pageOf(name) + 1, true)
        end
    end
    return #names
end

function Searcher:cancel()
    self.cancelled = true
    for name, job in pairs(self.jobs) do
        job:cancel()
        self.jobs[name] = nil
    end
end

return Searcher
