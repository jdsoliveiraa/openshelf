--[[
In-tree providers, in registration (= default source) order. Each is a
contract-shaped table (PROVIDERS.md, api 1); catalog.lua registers them
through Catalog.register exactly like plugins and drop-ins (DESIGN.md §9.3).
Add a built-in by dropping providers/<id>.lua and listing it here.
--]]
-- Bind requires to locals first: require() can return a second value (the
-- loader path on Lua 5.3+) that would leak into the list's last slot.
local Gutendex        = require("providers/gutendex")
local InternetArchive = require("providers/internetarchive")
local DOAB            = require("providers/doab")

return { Gutendex, InternetArchive, DOAB }
