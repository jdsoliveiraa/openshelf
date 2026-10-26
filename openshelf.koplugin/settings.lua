--[[
Persistent plugin settings (LuaSettings-backed, <settings>/openshelf.lua):
  - which sources are disabled (sources are on by default)
  - default results view ("list" | "grid")
  - results per source (page size per provider)
  - recent searches (newest first, max 8)
  - home mode: open OpenShelf when KOReader starts and after a book closes
--]]
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Settings = {}
local store

Settings.MAX_RECENTS = 8
Settings.PER_SOURCE_CHOICES = { 10, 15, 30 }

local function s()
    if not store then
        store = LuaSettings:open(DataStorage:getSettingsDir() .. "/openshelf.lua")
    end
    return store
end

local function save(key, value)
    s():saveSetting(key, value)
    s():flush()
end

---------------------------------------------------------------------------
-- Sources
---------------------------------------------------------------------------
function Settings.isEnabled(name)
    local disabled = s():readSetting("disabled_sources") or {}
    return not disabled[name]
end

function Settings.setEnabled(name, enabled)
    local disabled = s():readSetting("disabled_sources") or {}
    if enabled then disabled[name] = nil else disabled[name] = true end
    save("disabled_sources", disabled)
end

function Settings.toggle(name)
    Settings.setEnabled(name, not Settings.isEnabled(name))
end

-- Build an {["Source"]=true} set of enabled sources from a list of all names.
function Settings.enabledSet(allNames)
    local set = {}
    for __, n in ipairs(allNames) do
        if Settings.isEnabled(n) then set[n] = true end
    end
    return set
end

function Settings.enabledList(allNames)
    local list = {}
    for __, n in ipairs(allNames) do
        if Settings.isEnabled(n) then list[#list + 1] = n end
    end
    return list
end

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
