--[[
Persistent plugin settings (LuaSettings-backed). Currently: which sources are
enabled. Sources are enabled by default; we only store the disabled ones.
--]]
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Settings = {}
local store

local function s()
    if not store then
        store = LuaSettings:open(DataStorage:getSettingsDir() .. "/openshelf.lua")
    end
    return store
end

function Settings.isEnabled(name)
    local disabled = s():readSetting("disabled_sources") or {}
    return not disabled[name]
end

function Settings.setEnabled(name, enabled)
    local disabled = s():readSetting("disabled_sources") or {}
    if enabled then disabled[name] = nil else disabled[name] = true end
    s():saveSetting("disabled_sources", disabled)
    s():flush()
end

function Settings.toggle(name)
    Settings.setEnabled(name, not Settings.isEnabled(name))
end

-- Build an {["Source"]=true} set of enabled sources from a list of all names.
function Settings.enabledSet(allNames)
    local set = {}
    for _, n in ipairs(allNames) do
        if Settings.isEnabled(n) then set[n] = true end
    end
    return set
end

return Settings
