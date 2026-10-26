--[[
Dedupe + prefer-best-edition.

Collapses entries that refer to the same work (same dedup_key). Preserves the
order of first appearance (so provider relevance ordering survives), but upgrades
the kept entry to the highest-quality edition seen — e.g. a Standard Ebooks
edition replaces a raw Gutenberg one for the same title, in place.
--]]
local Dedupe = {}

function Dedupe.run(entries)
    local result = {}
    local seen = {}            -- dedup_key -> index in result
    local collapsed = 0
    for __, e in ipairs(entries) do
        local k = e.dedup_key
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
