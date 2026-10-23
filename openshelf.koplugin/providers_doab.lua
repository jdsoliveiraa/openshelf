--[[
DOAB provider — Directory of Open Access Books (open-access scholarly books).
Uses the DSpace REST search at directory.doabooks.org.

NOTE: DOAB blocks datacenter IPs (403 "address not allowed"), so this can only
be verified from a residential connection (e.g. the Kobo itself). The catalog
isolates provider failures, so if DOAB is ever unreachable it degrades quietly.

Books are often PDF rather than EPUB; we prefer EPUB and fall back to PDF, and
tag the entry's format accordingly (KOReader reads both).
--]]
local HttpUtil = require("http_util")
local Entry = require("entry")
local url_escape = require("socket.url").escape

local DOAB = { name = "DOAB" }
local BASE = "https://directory.doabooks.org"

local function meta_value(item, key)
    for _, m in ipairs(item.metadata or {}) do
        if m.key == key then return m.value end
    end
    return nil
end

-- Pick the best downloadable bitstream: prefer EPUB, else PDF.
local function pick_bitstream(item)
    local pdf
    for _, b in ipairs(item.bitstreams or {}) do
        local mime = b.mimeType or ""
        if (b.bundleName == nil or b.bundleName == "ORIGINAL") and b.retrieveLink then
            if mime:find("epub", 1, true) then
                return b.retrieveLink, "epub"
            elseif mime:find("pdf", 1, true) and not pdf then
                pdf = b.retrieveLink
            end
        end
    end
    if pdf then return pdf, "pdf" end
    return nil
end

-- Cover thumbnail: DSpace puts generated thumbnails in the THUMBNAIL bundle.
local function pick_cover(item)
    for _, b in ipairs(item.bitstreams or {}) do
        if b.bundleName == "THUMBNAIL" and b.retrieveLink then
            return BASE .. b.retrieveLink
        end
    end
    return nil
end

function DOAB.search(query, limit)
    limit = limit or 20
    local url = BASE .. "/rest/search?expand=metadata,bitstreams&query="
        .. url_escape(query)
    local data, err = HttpUtil.getJSON(url)
    if not data then return nil, err end

    local results = {}
    for _, item in ipairs(data) do
        local title = item.name or meta_value(item, "dc.title")
        if title then
            local link, fmt = pick_bitstream(item)
            if link then
                local href = BASE .. link
                results[#results + 1] = Entry.download{
                    title  = title,
                    author = meta_value(item, "dc.contributor.author") or "Unknown",
                    source = DOAB.name,
                    format = fmt,
                    cover  = pick_cover(item),
                    resolve = function() return href end,
                }
                if #results >= limit then break end
            end
        end
    end
    return results
end

return DOAB
