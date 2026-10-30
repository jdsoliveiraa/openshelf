--[[
Folder views, the pure part (DESIGN.md §12.3–12.5, ticket #17). No KOReader:
view_folder.lua draws the view and runs pageTask in a job; pane_results.lua
uses secondLine and metaLine for folder rows.

  Folders.PAGE_SIZE                        rows per list() call (50)
  Folders.pageTask(id, locator, page)      -> function for Jobs.run: { entries, has_more }
  Folders.secondLine(entry, in_folder)     -> a folder row's second line ("" for none)
  Folders.metaLine(entry, label, words)    -> its meta line, "Source · 43 files · 120 MB"
  Folders.ancestors(view)                  -> the folder views it was listed from, root first

A folder view keeps `parent`, the folder view it was listed from (nil when
it was opened from home, search, a shelf or See all), and `folder`, the row
it was opened from (nil for a root).
--]]
local Catalog = require("catalog")

local Folders = {}

Folders.PAGE_SIZE = 50

--- One page of a folder (locator nil = the provider's root), for Jobs.run:
--- raises the provider's reason on failure.
function Folders.pageTask(id, locator, page)
    return function()
        local entries, more_or_err = Catalog.list(id, locator, Folders.PAGE_SIZE, page)
        if not entries then error(more_or_err or "list failed", 0) end
        return { entries = entries, has_more = more_or_err == true }
    end
end

--- subtitle, else the ancestors' titles joined with › (outside folder views
--- only: inside one they repeat the title bar on every row), else "".
function Folders.secondLine(entry, in_folder)
    if entry.subtitle then return entry.subtitle end
    if not in_folder and type(entry.path) == "table" and #entry.path > 0 then
        return table.concat(entry.path, " › ")
    end
    return ""
end

--- `label · N files · size` from count / size when given, else
--- `label · Folder`. words = { files = fn(n), size = fn(bytes), folder = "…" }:
--- the view's translated wording (this module has no gettext).
function Folders.metaLine(entry, label, words)
    local parts = { label }
    if entry.count then parts[#parts + 1] = words.files(entry.count) end
    if entry.size then parts[#parts + 1] = words.size(entry.size) end
    if #parts == 1 then parts[2] = words.folder end
    return table.concat(parts, " · ")
end

--- The chain of folder views below `view` that listed it, root first,
--- nearest last (its title-tap menu).
function Folders.ancestors(view)
    local chain = {}
    local v = view.parent
    while v do
        table.insert(chain, 1, v)
        v = v.parent
    end
    return chain
end

return Folders
