--[[
One-time migrations of what v0.5 stored under display names to the provider
ids of v0.6 (DESIGN.md §9.2, decision 38). Pure Lua, no KOReader modules;
library.lua and settings.lua call these on load.

V1_SOURCES freezes what v0.5 called its three sources and the per-source
quality rank it used, so a rename of a provider later never changes how old
files are read. Nothing else should key on display names.
--]]
local Entry = require("entry")

local Migrate = {}

Migrate.LIBRARY_VERSION = 2

Migrate.V1_SOURCES = {
    ["Project Gutenberg"] = { id = "gutendex",        quality = 80 },
    ["Internet Archive"]  = { id = "internetarchive", quality = 60 },
    ["DOAB"]              = { id = "doab",            quality = 50 },
}

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

--- Library file v1 → v2: every record gains `provider` and `quality` and is
-- rekeyed to `<provider id>|<locator>`. Returns a NEW table; the input is left
-- untouched so the caller can write it out as the `.v1.bak` first. Records
-- from a source v0.5 never had keep their old id and get no provider.
function Migrate.library(data)
    local records = {}
    for i, rec in ipairs(type(data) == "table" and data.records or {}) do
        local r = copy(rec)
        local legacy = r.provider == nil and Migrate.V1_SOURCES[r.source]
        if legacy then
            r.provider = legacy.id
            if r.quality == nil then r.quality = legacy.quality end
            r.id = legacy.id .. "|" .. Entry.locatorKey(r.locator)
        end
        records[i] = r
    end
    return { version = Migrate.LIBRARY_VERSION, records = records }
end

local ID_PATTERN = "^[a-z][a-z0-9_]*$"

--- A set of sources keyed by v0.5 display names (`disabled_sources`) → the
-- same set keyed by provider id. Keys that already are ids pass through, so
-- running this on every open is harmless; names v0.5 never had are dropped
-- rather than guessed. Returns the new set and whether anything changed.
function Migrate.sourceSet(set)
    local out, changed = {}, false
    for key, on in pairs(type(set) == "table" and set or {}) do
        if type(key) == "string" and key:match(ID_PATTERN) then
            out[key] = on
        else
            changed = true
            local legacy = Migrate.V1_SOURCES[key]
            if legacy then out[legacy.id] = on end
        end
    end
    return out, changed
end

return Migrate
