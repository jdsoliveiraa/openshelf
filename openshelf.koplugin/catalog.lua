--[[
Aggregator: fans a query across the enabled providers, merges, dedupes
(prefer-best-edition), and groups by action for the results view. One dead
provider never kills the search — errors are collected per-source.
--]]
local Entry = require("entry")
local Dedupe = require("dedupe")
local logger = require("logger")

-- Bind requires to locals first: require() can return a second value (loader
-- path on Lua 5.3+) that would leak into the table if it sat in the last slot.
local Gutendex        = require("providers_gutendex")
local InternetArchive = require("providers_internetarchive")
local DOAB            = require("providers_doab")

local Catalog = {}

-- All known providers, in default display/relevance order.
-- (Standard Ebooks + Feedbooks were removed: SE actively bans scrapers' IPs and
-- its OPDS needs a patron token; Feedbooks killed its free public-domain API.
-- SE may return later as an opt-in authenticated-OPDS provider — see opds.lua.)
Catalog.providers = {
    Gutendex,
    InternetArchive,
    DOAB,
}

function Catalog.providerNames()
    local names = {}
    for _, p in ipairs(Catalog.providers) do names[#names + 1] = p.name end
    return names
end

--- Search enabled providers.
-- opts.enabled : optional set {["Source"]=true} of sources to include (default all)
-- opts.per_provider : max results per provider
-- Returns (entries, errors). entries are deduped and carry an `action`.
function Catalog.search(query, opts)
    opts = opts or {}
    local enabled = opts.enabled
    local per_provider = opts.per_provider or 20

    local all, errors = {}, {}
    for _, provider in ipairs(Catalog.providers) do
        if type(provider) ~= "table" or type(provider.search) ~= "function" then
            logger.warn("OpenShelf: skipping invalid provider entry")
            goto continue
        end
        if enabled and not enabled[provider.name] then
            goto continue
        end
        local ok, res, err = pcall(provider.search, query, per_provider)
        if ok and res then
            for _, entry in ipairs(res) do all[#all + 1] = entry end
        else
            local msg = (not ok and res) or err or "unknown error"
            logger.warn("OpenShelf: provider failed", provider.name, msg)
            errors[#errors + 1] = string.format("%s: %s", provider.name, tostring(msg))
        end
        ::continue::
    end

    local deduped, collapsed = Dedupe.run(all)
    return deduped, errors, collapsed
end

--- Group entries by action in display order. Returns an ordered list of
--- { action=, heading=, items={...} }, skipping empty groups.
function Catalog.group(entries)
    local buckets = {}
    for _, e in ipairs(entries) do
        local a = e.action or Entry.ACTION.DOWNLOAD
        buckets[a] = buckets[a] or {}
        table.insert(buckets[a], e)
    end
    local groups = {}
    for _, action in ipairs(Entry.ACTION_ORDER) do
        local items = buckets[action]
        if items and #items > 0 then
            groups[#groups + 1] = {
                action  = action,
                heading = Entry.ACTION_HEADING[action],
                items   = items,
            }
        end
    end
    return groups
end

return Catalog
