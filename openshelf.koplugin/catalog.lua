--[[
Provider registry + the few catalog operations that are not UI:
  Catalog.providers / providerNames()
  Catalog.searchOne(name, query, limit, page) -> entries, has_more | nil, err
  Catalog.searchAll(query, opts)              -> entries, errors, collapsed (sequential; tests)
  Catalog.resolve(entry)                      -> url | nil, err
  Catalog.browse(kind, limit)                 -> entries | nil, err
  Catalog.group(entries)                      -> { {action, heading, items}, … }

The parallel, subprocess-based search lives in searcher.lua (KOReader only);
it calls searchOne inside each forked child.
--]]
local Entry = require("entry")
local Results = require("results")
local logger = require("logger")

-- Bind requires to locals first: require() can return a second value (loader
-- path on Lua 5.3+) that would leak into the table if it sat in the last slot.
local Gutendex        = require("providers_gutendex")
local InternetArchive = require("providers_internetarchive")
local DOAB            = require("providers_doab")

local Catalog = {}

-- All known providers, in display/slot order.
Catalog.providers = {
    Gutendex,
    InternetArchive,
    DOAB,
}

-- Home-screen browse shelves: { key, title, provider }.
Catalog.BROWSE = {
    { key = "popular", title = Gutendex.BROWSE.popular.title, provider = Gutendex },
    { key = "new",     title = Gutendex.BROWSE.new.title,     provider = Gutendex },
}

function Catalog.providerNames()
    local names = {}
    for __, p in ipairs(Catalog.providers) do names[#names + 1] = p.name end
    return names
end

function Catalog.byName(name)
    for __, p in ipairs(Catalog.providers) do
        if p.name == name then return p end
    end
    return nil
end

--- One provider, one page. Safe to call inside a subprocess.
function Catalog.searchOne(name, query, limit, page)
    local provider = Catalog.byName(name)
    if not provider then return nil, "unknown source " .. tostring(name) end
    local ok, res, extra = pcall(provider.search, query, limit, page)
    if not ok then return nil, tostring(res) end
    if not res then return nil, extra or "unknown error" end
    return res, extra and true or false
end

--- Sequential search across enabled providers (used by the headless test and
--- as a fallback when subprocesses are unavailable).
-- opts.enabled : optional set {["Source"]=true}; opts.per_provider : page size
-- Returns entries (deduped, slot-ordered), errors (list), collapsed (count).
function Catalog.searchAll(query, opts)
    opts = opts or {}
    local names = {}
    for __, p in ipairs(Catalog.providers) do
        if not opts.enabled or opts.enabled[p.name] then names[#names + 1] = p.name end
    end
    local results = Results.new(names)
    for __, name in ipairs(names) do
        local entries, more_or_err = Catalog.searchOne(name, query, opts.per_provider or 20, 1)
        if entries then
            results:setProvider(name, entries, more_or_err)
        else
            logger.warn("OpenShelf: provider failed", name, more_or_err)
            results:setError(name, more_or_err)
        end
    end
    local entries, collapsed = results:flatten()
    return entries, results:errors(), collapsed, results
end

--- Entry → download URL, via its provider's resolve(locator).
function Catalog.resolve(entry)
    local provider = Catalog.byName(entry.source)
    if not provider or not provider.resolve then
        return nil, "no provider for " .. tostring(entry.source)
    end
    local ok, url, err = pcall(provider.resolve, entry.locator)
    if not ok then return nil, tostring(url) end
    return url, err
end

--- Browse feed → entries (nil, err on failure).
function Catalog.browse(kind, limit)
    for __, feed in ipairs(Catalog.BROWSE) do
        if feed.key == kind then
            local ok, entries, err = pcall(feed.provider.browse, kind, limit)
            if not ok then return nil, tostring(entries) end
            return entries, err
        end
    end
    return nil, "unknown browse feed " .. tostring(kind)
end

--- Group entries by action in display order. Returns an ordered list of
--- { action=, heading=, items={...} }, skipping empty groups.
function Catalog.group(entries)
    local buckets = {}
    for __, e in ipairs(entries) do
        local a = e.action or Entry.ACTION.DOWNLOAD
        buckets[a] = buckets[a] or {}
        table.insert(buckets[a], e)
    end
    local groups = {}
    for __, action in ipairs(Entry.ACTION_ORDER) do
        local items = buckets[action]
        if items and #items > 0 then
            groups[#groups + 1] = {
                action  = action,
                heading = Entry.ACTION_HEADING[action],
                glyph   = Entry.ACTION_GLYPH[action],
                items   = items,
            }
        end
    end
    return groups
end

return Catalog
