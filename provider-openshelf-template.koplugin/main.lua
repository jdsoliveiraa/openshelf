--[[
Template OpenShelf provider plugin (PROVIDERS.md §8.2). Registers the
provider table from openshelf_template.lua under the core registry's
"openshelf" feature; OpenShelf reads the registry each time it opens.

To make your own: rename the folder to provider-openshelf-<id>.koplugin,
rename openshelf_template.lua to openshelf_<id>.lua, and change `name` here,
the registry key below and the strings in _meta.lua.
--]]
local Provider = require("provider")          -- KOReader core registry
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Plugin = WidgetContainer:extend{ name = "provider-openshelf-template" }

function Plugin:init()
    -- KOReader's registry only accepts features on its built-in list, and
    -- "openshelf" is not on it, so create the slot first. Required.
    Provider.features.openshelf = Provider.features.openshelf or {}
    -- dofile, not require: one flat require namespace across KOReader and
    -- every plugin (PROVIDERS.md §8.2).
    Provider:register("openshelf", "template",
        dofile(self.path .. "/openshelf_template.lua"))
end

return Plugin
