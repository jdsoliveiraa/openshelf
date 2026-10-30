--[[
Slot-ordered results model (DESIGN.md §2.3, decision 24).

Providers finish in any order, but rows keep a fixed provider order: every
provider owns a slot; flatten() concatenates the slots in order, applies the
optional filter, then dedupes (prefer-best-edition, first position kept). A
late provider therefore fills its slot without reshuffling the others, and a
duplicate with higher quality upgrades the existing row in place.

Slots are keyed by provider id (DESIGN.md §9.2); the only place a display
name enters is the label function the view hands to errors().

Pure Lua — no KOReader dependencies.
--]]
local Dedupe = require("dedupe")
local Entry = require("entry")

local Results = {}
Results.__index = Results

-- provider_order: list of provider ids, slot order.
function Results.new(provider_order)
    local self = setmetatable({}, Results)
    self.order = {}
    self.slots = {}
    for i, id in ipairs(provider_order or {}) do
        self.order[i] = id
        self.slots[id] = { entries = {}, has_more = false, done = false, err = nil, page = 0 }
    end
    return self
end

function Results:setProvider(id, entries, has_more)
    local s = self.slots[id]
    if not s then return end
    s.entries = entries or {}
    s.has_more = has_more and true or false
    s.done = true
    s.err = nil
    s.page = 1
end

function Results:appendProvider(id, entries, has_more)
    local s = self.slots[id]
    if not s then return end
    for __, e in ipairs(entries or {}) do s.entries[#s.entries + 1] = e end
    s.has_more = has_more and true or false
    s.done = true
    s.err = nil
    s.page = s.page + 1
end

function Results:setError(id, err)
    local s = self.slots[id]
    if not s then return end
    s.done = true
    s.has_more = false
    s.err = tostring(err or "unknown error")
end

-- Mark a slot as fetching again (load more).
function Results:setPending(id)
    local s = self.slots[id]
    if s then s.done = false end
end

function Results:isComplete()
    for __, id in ipairs(self.order) do
        if not self.slots[id].done then return false end
    end
    return true
end

-- Ids of the providers still fetching, in slot order.
function Results:pending()
    local out = {}
    for __, id in ipairs(self.order) do
        if not self.slots[id].done then out[#out + 1] = id end
    end
    return out
end

-- "<label>: <error>" per failed provider, in slot order. label_of(id) turns
-- the id into what the user should read (Catalog.nameOf); without it the id
-- itself is used.
function Results:errors(label_of)
    local out = {}
    for __, id in ipairs(self.order) do
        local s = self.slots[id]
        if s.err then
            local label = label_of and label_of(id) or id
            out[#out + 1] = label .. ": " .. s.err
        end
    end
    return out
end

-- Providers that reported more pages (candidates for "Load more").
function Results:withMore()
    local out = {}
    for __, id in ipairs(self.order) do
        if self.slots[id].has_more then out[#out + 1] = id end
    end
    return out
end

function Results:hasMore()
    return #self:withMore() > 0
end

function Results:pageOf(id)
    local s = self.slots[id]
    return s and s.page or 0
end

-- filter.sources is a set of provider ids (nil = all); filter.format is
-- "any" | "epub" | "pdf". Folder rows have no format and pass any.
local function passes(e, filter)
    if not filter then return true end
    if filter.sources and not filter.sources[e.provider] then return false end
    if filter.format and filter.format ~= "any" and e.action ~= Entry.ACTION.FOLDER
        and (e.format or "epub") ~= filter.format then
        return false
    end
    return true
end

-- Ordered, filtered, deduped entries + number of duplicates collapsed.
-- Filtering happens BEFORE dedupe so "only Internet Archive" shows IA's own
-- edition rather than hiding it under a better one from elsewhere.
function Results:flatten(filter)
    local all = {}
    for __, id in ipairs(self.order) do
        for ___, e in ipairs(self.slots[id].entries) do
            if passes(e, filter) then all[#all + 1] = e end
        end
    end
    return Dedupe.run(all)
end

-- Total raw entries across slots (before dedupe/filter).
function Results:rawCount()
    local n = 0
    for __, id in ipairs(self.order) do n = n + #self.slots[id].entries end
    return n
end

return Results
