--[[
DOAB provider — Directory of Open Access Books (open-access scholarly books).
Uses the DSpace REST search at directory.doabooks.org.

NOTE: DOAB blocks datacenter IPs (403 "address not allowed"), so this can only
be verified from a residential connection (e.g. the Kobo itself). The catalog
isolates provider failures, so if DOAB is ever unreachable it degrades quietly.

Books are often PDF rather than EPUB; we prefer EPUB and fall back to PDF, and
tag the entry's format accordingly (KOReader reads both).

Contract: PROVIDERS.md (api 1). Everything from the host arrives in `ctx`;
this file must not require() any OpenShelf module.
--]]
local P = {
    api     = 1,
    id      = "doab",
    name    = "DOAB",
    quality = 50,
}

local BASE = "https://directory.doabooks.org"

local function meta_value(item, key)
    for __, m in ipairs(item.metadata or {}) do
        if m.key == key then return m.value end
    end
    return nil
end

-- Downloadable bitstreams: the primary (EPUB preferred, else PDF) and the
-- other format as an alternate, so the detail page can offer both.
local function pick_bitstreams(item)
    local epub, pdf
    for __, b in ipairs(item.bitstreams or {}) do
        local mime = type(b.mimeType) == "string" and b.mimeType or ""
        if (b.bundleName == nil or b.bundleName == "ORIGINAL") and type(b.retrieveLink) == "string" then
            if mime:find("epub", 1, true) and not epub then
                epub = b.retrieveLink
            elseif mime:find("pdf", 1, true) and not pdf then
                pdf = b.retrieveLink
            end
        end
    end
    if epub then
        return epub, "epub", pdf and { { format = "pdf", locator = { url = BASE .. pdf } } } or nil
    end
    if pdf then return pdf, "pdf", nil end
    return nil
end

-- Cover thumbnail: DSpace puts generated thumbnails in the THUMBNAIL bundle.
local function pick_cover(item)
    for __, b in ipairs(item.bitstreams or {}) do
        if b.bundleName == "THUMBNAIL" and type(b.retrieveLink) == "string" then
            return BASE .. b.retrieveLink
        end
    end
    return nil
end

--- Pure: DSpace search response (list of items) → entries, has_more.
function P.parse(data, limit, ctx)
    limit = limit or 20
    local results = {}
    local seen = 0
    for __, item in ipairs(data) do
        seen = seen + 1
        local title = item.name or meta_value(item, "dc.title")
        if title then
            local link, fmt, alternates = pick_bitstreams(item)
            if link then
                local issued = meta_value(item, "dc.date.issued")
                results[#results + 1] = ctx.Entry.new{
                    title       = title,
                    author      = meta_value(item, "dc.contributor.author"),
                    format      = fmt,
                    cover       = pick_cover(item),
                    locator     = { url = BASE .. link },
                    alternates  = alternates,
                    description = meta_value(item, "dc.description.abstract"),
                    language    = meta_value(item, "dc.language"),
                    year        = type(issued) == "string" and issued:match("^(%d%d%d%d)") or nil,
                }
                if #results >= limit then break end
            end
        end
    end
    -- DSpace gives no total; a full page means there may be more.
    return results, seen >= limit
end

function P.search(query, limit, page, ctx)
    limit = limit or 20
    page = page or 1
    local url = string.format(
        "%s/rest/search?expand=metadata,bitstreams&query=%s&limit=%d&offset=%d",
        BASE, ctx.url_escape(query), limit, (page - 1) * limit)
    local data, err = ctx.http.getJSON(url)
    if not data then return nil, err end
    return P.parse(data, limit, ctx)
end

function P.resolve(locator)
    if type(locator) == "table" and type(locator.url) == "string" then return locator.url end
    return nil, "no download URL for this book"
end

return P
