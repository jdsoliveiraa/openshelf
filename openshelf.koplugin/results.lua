--[[
Slot-ordered results model (DESIGN.md §2.3, decision 24).

Providers finish in any order, but rows keep a fixed provider order: every
provider owns a slot; flatten() concatenates the slots in order, applies the
optional filter, then dedupes (prefer-best-edition, first position kept). A
late provider therefore fills its slot without reshuffling the others, and a
duplicate with higher quality upgrades the existing row in place.

Pure Lua — no KOReader dependencies.
--]]
local Dedupe = require("dedupe")

local Results = {}
Results.__index = Results

function Results.new(provider_order)
    local self = setmetatable({}, Results)
    self.order = {}
    self.slots = {}
    for i, name in ipairs(provider_order or {}) do
        self.order[i] = name
        self.slots[name] = { entries = {}, has_more = false, done = false, err = nil, page = 0 }
    end
    return self
end

function Results:setProvider(name, entries, has_more)
    local s = self.slots[name]
    if not s then return end
    s.entries = entries or {}
    s.has_more = has_more and true or false
    s.done = true
    s.err = nil
    s.page = 1
end

function Results:appendProvider(name, entries, has_more)
    local s = self.slots[name]
    if not s then return end
    for __, e in ipairs(entries or {}) do s.entries[#s.entries + 1] = e end
    s.has_more = has_more and true or false
    s.done = true
    s.err = nil
    s.page = s.page + 1
end

function Results:setError(name, err)
    local s = self.slots[name]
    if not s then return end
    s.done = true
    s.has_more = false
    s.err = tostring(err or "unknown error")
end

-- Mark a slot as fetching again (load more).
function Results:setPending(name)
    local s = self.slots[name]
    if s then s.done = false end
end

function Results:isComplete()
    for __, name in ipairs(self.order) do
        if not self.slots[name].done then return false end
    end
    return true
end

function Results:pending()
    local out = {}
    for __, name in ipairs(self.order) do
        if not self.slots[name].done then out[#out + 1] = name end
    end
    return out
end

function Results:errors()
    local out = {}
    for __, name in ipairs(self.order) do
        local s = self.slots[name]
        if s.err then out[#out + 1] = name .. ": " .. s.err end
    end
    return out
end

-- Providers that reported more pages (candidates for "Load more").
function Results:withMore()
    local out = {}
    for __, name in ipairs(self.order) do
        if self.slots[name].has_more then out[#out + 1] = name end
    end
    return out
end

function Results:hasMore()
    return #self:withMore() > 0
end

function Results:pageOf(name)
    local s = self.slots[name]
    return s and s.page or 0
end

local function passes(e, filter)
    if not filter then return true end
    if filter.sources and not filter.sources[e.source] then return false end
    if filter.format and filter.format ~= "any" and (e.format or "epub") ~= filter.format then
        return false
    end
    return true
end

-- Ordered, filtered, deduped entries + number of duplicates collapsed.
-- Filtering happens BEFORE dedupe so "only Internet Archive" shows IA's own
-- edition rather than hiding it under a better one from elsewhere.
function Results:flatten(filter)
    local all = {}
    for __, name in ipairs(self.order) do
        for ___, e in ipairs(self.slots[name].entries) do
            if passes(e, filter) then all[#all + 1] = e end
        end
    end
    return Dedupe.run(all)
end

-- Total raw entries across slots (before dedupe/filter).
function Results:rawCount()
    local n = 0
    for __, name in ipairs(self.order) do n = n + #self.slots[name].entries end
    return n
end

return Results
