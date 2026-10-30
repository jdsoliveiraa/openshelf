--[[
Dedupe + prefer-best-edition.

Collapses entries that refer to the same work (same dedup_key). Preserves the
order of first appearance (so provider relevance ordering survives), but upgrades
the kept entry to the highest-quality edition seen — e.g. a Standard Ebooks
edition replaces a raw Gutenberg one for the same title, in place.

Folder rows and rows stamped `dedupe = false` (their provider opted out,
DESIGN.md §12.5) never merge with other rows: their key is their Entry.id, so
only the very same row seen twice collapses.
--]]
local Entry = require("entry")

local Dedupe = {}

local function key_of(e)
    if e.action == Entry.ACTION.FOLDER or e.dedupe == false then
        return "\0" .. Entry.id(e)   -- no dedup_key contains a NUL byte
    end
    return e.dedup_key
end

function Dedupe.run(entries)
    local result = {}
    local seen = {}            -- key_of(e) -> index in result
    local collapsed = 0
    for __, e in ipairs(entries) do
        local k = key_of(e)
        local idx = seen[k]
        if not idx then
            result[#result + 1] = e
            seen[k] = #result
        else
            collapsed = collapsed + 1
            if (e.quality or 0) > (result[idx].quality or 0) then
                result[idx] = e   -- keep position, upgrade edition
            end
        end
    end
    return result, collapsed
end

return Dedupe
