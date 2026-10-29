--[[
Persistent plugin settings (LuaSettings-backed, <settings>/openshelf.lua).
Everything about a source is keyed by its provider id (DESIGN.md §9.2, §9.5):
  - disabled_sources  { [id] = true }  default-on providers the user switched off
  - enabled_sources   { [id] = true }  default-off providers the user switched on
  - provider_settings { [id] = { key = value } }  per-provider fields (PROVIDERS.md §7)
  - source_order      { id, … }        user-arranged order (Catalog.orderIds merges it)
  - default_view ("list" | "grid"), per_source (page size), recents (newest
    first, max 8), home_mode (open at start and after each book)
A v0.5 file keyed disabled_sources by display name; it is rewritten to ids
the first time it is opened (openshelf_migrate.sourceSet).
--]]
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Catalog = require("catalog")
local Fields = require("openshelf_fields")
local Migrate = require("openshelf_migrate")

local Settings = {}
local store

Settings.MAX_RECENTS = 8
Settings.PER_SOURCE_CHOICES = { 10, 15, 30 }

local function s()
    if not store then
        store = LuaSettings:open(DataStorage:getSettingsDir() .. "/openshelf.lua")
        local disabled, changed = Migrate.sourceSet(store:readSetting("disabled_sources"))
        if changed then
            store:saveSetting("disabled_sources", disabled)
            store:flush()
        end
    end
    return store
end

local function save(key, value)
    s():saveSetting(key, value)
    s():flush()
end

---------------------------------------------------------------------------
-- Sources. `p` is a registered provider table ({ id, enabled_by_default });
-- its default decides which list the user's choice lives in.
---------------------------------------------------------------------------
local function default_on(p)
    return p.enabled_by_default ~= false
end

function Settings.isEnabled(p)
    if default_on(p) then
        local disabled = s():readSetting("disabled_sources") or {}
        return not disabled[p.id]
    end
    local enabled = s():readSetting("enabled_sources") or {}
    return enabled[p.id] == true
end

function Settings.setEnabled(p, on)
    if default_on(p) then
        local disabled = s():readSetting("disabled_sources") or {}
        disabled[p.id] = (not on) and true or nil
        save("disabled_sources", disabled)
    else
        local enabled = s():readSetting("enabled_sources") or {}
        enabled[p.id] = on and true or nil
        save("enabled_sources", enabled)
    end
end

function Settings.toggle(p)
    Settings.setEnabled(p, not Settings.isEnabled(p))
end

-- Ids of the enabled providers that are ready to search, in the order given
-- (slot order). A source in Needs setup is skipped silently: no slot, no
-- error in the status strip (PROVIDERS.md §7).
function Settings.enabledIds(providers)
    local ids = {}
    for __, p in ipairs(providers) do
        if Settings.isEnabled(p) and not Settings.needsSetup(p) then ids[#ids + 1] = p.id end
    end
    return ids
end

---------------------------------------------------------------------------
-- Source order (Sources -> Arrange sources): source_order = { id, … }.
-- Catalog.orderIds merges it with what is registered, so new sources append
-- and vanished ones drop out without rewriting the file.
---------------------------------------------------------------------------
function Settings.sourceOrder()
    return s():readSetting("source_order")
end

function Settings.setSourceOrder(ids)
    local list = {}
    for __, id in ipairs(ids) do list[#list + 1] = id end
    save("source_order", list)
end

-- Every registered provider in the arranged order: the one list result
-- slots (with enabledIds), the filter dialog and Sources iterate.
function Settings.orderedProviders()
    return Catalog.ordered(Settings.sourceOrder())
end

---------------------------------------------------------------------------
-- Per-provider settings: provider_settings[id] = { key = value }, the raw
-- values the user saved (plain text, PROVIDERS.md §7). The provider's field
-- schema (openshelf_fields) turns them into what ctx.settings holds.
---------------------------------------------------------------------------
function Settings.providerSettings(id)
    local all = s():readSetting("provider_settings") or {}
    return all[id] or {}
end

-- ctx.settings for provider `p`: declared keys, defaults applied, empty text nil.
function Settings.values(p)
    return Fields.values(p.settings, Settings.providerSettings(p.id))
end

-- Key of the first required field left empty (the source is in Needs setup),
-- or nil when the source is ready.
function Settings.needsSetup(p)
    return Fields.missing(p.settings, Settings.providerSettings(p.id))
end

function Settings.setProviderSetting(id, key, value)
    local all = s():readSetting("provider_settings") or {}
    all[id] = all[id] or {}
    all[id][key] = value
    save("provider_settings", all)
end

-- Every ctx the catalog builds reads the saved values through here.
Catalog.setSettingsSource(Settings.providerSettings)

---------------------------------------------------------------------------
-- Views
---------------------------------------------------------------------------
function Settings.defaultView()
    local v = s():readSetting("default_view")
    if v == "grid" then return "grid" end
    return "list"
end

function Settings.setDefaultView(v)
    save("default_view", v == "grid" and "grid" or "list")
end

function Settings.perSource()
    return tonumber(s():readSetting("per_source")) or 15
end

function Settings.setPerSource(n)
    save("per_source", tonumber(n) or 15)
end

---------------------------------------------------------------------------
-- Home mode (see main.lua): OpenShelf as the screen KOReader lands on
---------------------------------------------------------------------------
function Settings.homeMode()
    return s():readSetting("home_mode") == true
end

function Settings.setHomeMode(on)
    save("home_mode", on and true or false)
end

---------------------------------------------------------------------------
-- Recent searches
---------------------------------------------------------------------------
function Settings.recents()
    local list = s():readSetting("recents")
    if type(list) ~= "table" then return {} end
    return list
end

function Settings.addRecent(query)
    query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then return end
    local list = { query }
    for __, q in ipairs(Settings.recents()) do
        if q ~= query and #list < Settings.MAX_RECENTS then list[#list + 1] = q end
    end
    save("recents", list)
end

function Settings.removeRecent(query)
    local list = {}
    for __, q in ipairs(Settings.recents()) do
        if q ~= query then list[#list + 1] = q end
    end
    save("recents", list)
end

function Settings.clearRecents()
    save("recents", {})
end

return Settings
