--[[
External providers (PROVIDERS.md §8.2–8.5, DESIGN.md §9.3, decisions 37/43/48/54):
KOReader plugins registering under the core Provider registry's `openshelf`
feature, and drop-in files in <settings>/openshelf/providers/*.lua.

  External.new{ catalog, listDir, loadFile }  -> a scanner (pure; I/O injected)
  scanner:scan(registry, dir)                 -> registers what is new since the last scan
  External.open()                             -> KOReader wiring: folder + README, registry, scan

Called when OpenShelf opens, never from init(): plugin instances are created
in path order, so `openshelf` inits before any `provider-*` plugin has
registered. The scan runs on every open; each registry entry and each file is
taken once per process (a reopen must not re-register and trip "duplicate id").
Order within one scan: plugins by id, then drop-ins by id, all after the
built-ins. Everything goes through Catalog.register, so an invalid table or a
duplicate id is listed dimmed in Sources with the reason; a file that fails to
load is listed the same way under its file name. Never raises, never a modal.

The scanner is KOReader-free so test/unit.lua can drive it; only open()
requires KOReader modules, lazily.
--]]
local logger = require("logger")

local External = {}

local Scanner = {}
Scanner.__index = Scanner

function External.new(opts)
    return setmetatable({
        catalog  = opts.catalog or require("catalog"),
        listDir  = opts.listDir,
        loadFile = opts.loadFile or dofile,
        seen_plugins = {},   -- registry name -> true once taken (once per process)
        seen_files   = {},   -- path -> true (loaded once per process)
    }, Scanner)
end

local function sort_key(p, fallback)
    if type(p) == "table" and type(p.id) == "string" then return p.id end
    return fallback
end

local function by_key(a, b)
    if a.key ~= b.key then return a.key < b.key end
    return a.label < b.label
end

-- Registry entries not taken yet, sorted by id.
function Scanner:pluginsFrom(registry)
    local found = {}
    for name, impl in pairs(type(registry) == "table" and registry or {}) do
        -- Taken by registry name, not table identity: a plugin's init()
        -- re-runs after every book and re-registers a fresh dofile()d
        -- table under the same name; that must stay silent.
        if not self.seen_plugins[name] then
            self.seen_plugins[name] = true
            local label = tostring(name)
            found[#found + 1] = { key = sort_key(impl, label), label = label, provider = impl }
        end
    end
    table.sort(found, by_key)
    return found
end

-- New *.lua files in the drop-in folder, loaded and sorted by id.
function Scanner:dropInsFrom(dir)
    local found = {}
    if not dir or not self.listDir then return found end
    local ok, names = pcall(self.listDir, dir)
    if not ok or type(names) ~= "table" then return found end
    for __, name in ipairs(names) do
        local path = dir .. "/" .. name
        if name:match("%.lua$") and not self.seen_files[path] then
            self.seen_files[path] = true
            local loaded, value = pcall(self.loadFile, path)
            if loaded then
                found[#found + 1] = { key = sort_key(value, name), label = name, provider = value }
            else
                -- "…/providers/x.lua:2: msg" -> "x.lua:2: msg" (fits the row)
                local msg = tostring(value):gsub("^[^\n]-([^/\n]+%.lua:)", "%1")
                found[#found + 1] = { key = name, label = name, error = "load error: " .. msg }
            end
        end
    end
    table.sort(found, by_key)
    return found
end

function Scanner:scan(registry, dir)
    local plugins = self:pluginsFrom(registry)
    local dropins = self:dropInsFrom(dir)
    for __, list in ipairs({ plugins, dropins }) do
        for ___, item in ipairs(list) do
            if item.error then
                self.catalog.reject(item.label, item.error)
            else
                -- The label (registry name / file name) names a rejected
                -- table that has no usable name of its own in Sources.
                self.catalog.register(item.provider, item.label)
            end
        end
    end
end

---------------------------------------------------------------------------
-- KOReader wiring (lazy requires; not loaded by the offline tests).
---------------------------------------------------------------------------
External.README = [[
OpenShelf drop-in providers
===========================

Copy a Lua file that returns an OpenShelf provider table (api 1 or 2) into
this folder. The file name does not matter; the provider's id comes from the table.

Files are scanned every time OpenShelf opens, but each file is loaded only
once per KOReader process: restart KOReader after adding or editing one.

A provider that fails to load or validate is listed dimmed in
OpenShelf > Settings > Sources with the reason.

The provider contract is PROVIDERS.md in the OpenShelf repository:
https://github.com/jdsoliveiraa/openshelf/blob/main/PROVIDERS.md
]]

local default_scanner

--- The drop-in folder, created with its README on first use. Tolerates a
-- missing or unwritable settings dir: returns the path anyway (the scan
-- then simply finds nothing).
function External.folder()
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    local root = DataStorage:getSettingsDir() .. "/openshelf"
    local dir = root .. "/providers"
    if lfs.attributes(dir, "mode") ~= "directory" then
        if lfs.attributes(root, "mode") ~= "directory" then lfs.mkdir(root) end
        if not lfs.mkdir(dir) then
            logger.warn("OpenShelf: could not create", dir)
            return dir
        end
    end
    local readme = dir .. "/README.txt"
    if lfs.attributes(readme, "mode") == nil then
        local f = io.open(readme, "w")
        if f then
            f:write(External.README)
            f:close()
        else
            logger.warn("OpenShelf: could not write", readme)
        end
    end
    return dir
end

local function list_dir(dir)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then return {} end
    local names = {}
    for name in lfs.dir(dir) do
        if lfs.attributes(dir .. "/" .. name, "mode") == "file" then names[#names + 1] = name end
    end
    return names
end

--- Read the core registry and scan the drop-in folder. Call on every open.
function External.open()
    local ok, err = pcall(function()
        local Provider = require("provider")
        -- Same feature-slot line as the plugins (§8.2): the core whitelist
        -- only knows "exporter".
        Provider.features.openshelf = Provider.features.openshelf or {}
        default_scanner = default_scanner or External.new{ listDir = list_dir }
        default_scanner:scan(Provider:getProvidersTable("openshelf"), External.folder())
    end)
    if not ok then logger.warn("OpenShelf: external provider scan failed", err) end
end

return External
