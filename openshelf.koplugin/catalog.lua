--[[
Aggregator: fans a query out across every registered provider, merges the
results, and collects per-provider errors so one dead source doesn't kill the
whole search. Add new providers by dropping a module in and listing it here.
--]]
local logger = require("logger")

-- Bind to locals first: require() can return a second value (the loader path on
-- Lua 5.3+), which would leak into the table if require sat in the last slot of
-- the constructor. Locals keep each provider a single clean value.
local Gutendex = require("providers_gutendex")
local InternetArchive = require("providers_internetarchive")

local Catalog = {}

Catalog.providers = {
    Gutendex,
    InternetArchive,
}

-- Returns (results_table, errors_table). errors is a list of "Name: message".
function Catalog.search(query, per_provider)
    local all, errors = {}, {}
    for _, provider in ipairs(Catalog.providers) do
        if type(provider) ~= "table" or type(provider.search) ~= "function" then
            logger.warn("OpenShelf: skipping invalid provider entry", tostring(provider))
            goto continue
        end
        local ok, res, err = pcall(provider.search, query, per_provider)
        if ok and res then
            for _, entry in ipairs(res) do
                table.insert(all, entry)
            end
        else
            local msg = (not ok and res) or err or "unknown error"
            logger.warn("OpenShelf: provider failed", provider.name, msg)
            table.insert(errors, string.format("%s: %s", provider.name, tostring(msg)))
        end
        ::continue::
    end
    return all, errors
end

return Catalog
