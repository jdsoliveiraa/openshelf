--[[
Internet Archive provider.
Search uses advancedsearch (returns identifiers); the EPUB filename is only known
per-item, so resolve() hits the metadata API at download time. Constrained to
text items that actually ship an EPUB and are freely downloadable:
lending-library items (`access-restricted-item`) list an EPUB too, but the
file answers 401 without an archive.org login, so they are excluded (v0.4.2).
Results are sorted by download count: IA's relevance ranking surfaces fan
fiction and scripts above real editions of popular titles.
--]]
local HttpUtil = require("http_util")
local Entry = require("entry")
local url_escape = require("socket.url").escape

local InternetArchive = { name = "Internet Archive" }

local function first(value)
    if type(value) == "table" then return value[1] end
    return value
end

-- Lucene/Solr treat these as syntax: a stray ":" or "(" in user text makes the
-- whole query invalid and IA answers with an error (seen as zero results).
local LUCENE_SPECIALS = "[%+%-&|!%(%){}%[%]%^\"~%*%?:\\/]"

--- Make free text safe to embed in the advancedsearch query.
-- Lowercasing also defuses the AND / OR / NOT operators. Returns nil when
-- nothing searchable is left.
function InternetArchive.sanitizeQuery(query)
    local q = (query or ""):lower():gsub(LUCENE_SPECIALS, " ")
    q = q:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return nil end
    return q
end

--- True when an advancedsearch doc or a metadata block marks the item as
-- borrow-only (the field arrives as the string "true", sometimes a boolean).
function InternetArchive.isRestricted(fields)
    local v = type(fields) == "table" and fields["access-restricted-item"]
    return v == true or (type(v) == "string" and v:lower() == "true")
end

--- Full Lucene query for a sanitized free-text string.
function InternetArchive.buildQuery(clean)
    return string.format(
        "(%s) AND mediatype:texts AND format:(EPUB) AND NOT access-restricted-item:true",
        clean)
end

local RESTRICTED_MSG = "borrow-only on the Internet Archive (needs an archive.org login)"

--- Pure: advancedsearch response → entries, has_more.
function InternetArchive.parse(data, limit, page)
    limit = limit or 20
    page = page or 1
    local resp = data.response or {}
    local docs = resp.docs or {}
    local results = {}
    for __, doc in ipairs(docs) do
        local identifier = doc.identifier
        -- second line of defence should the index lag behind the flag
        if identifier and not InternetArchive.isRestricted(doc) then
            local date = first(doc.date)
            results[#results + 1] = Entry.download{
                title       = first(doc.title) or identifier,
                author      = first(doc.creator) or "Unknown",
                source      = InternetArchive.name,
                cover       = "https://archive.org/services/img/" .. identifier,
                locator     = { identifier = identifier },
                description = first(doc.description),
                language    = first(doc.language),
                year        = type(date) == "string" and date:match("^(%d%d%d%d)") or nil,
            }
        end
    end
    local found = tonumber(resp.numFound) or 0
    local has_more = found > page * limit
    return results, has_more
end

function InternetArchive.search(query, limit, page)
    limit = limit or 20
    page = page or 1
    local clean = InternetArchive.sanitizeQuery(query)
    if not clean then return {}, false end
    local q = url_escape(InternetArchive.buildQuery(clean))
    local url = string.format(
        "https://archive.org/advancedsearch.php?q=%s"
        .. "&fl[]=identifier&fl[]=title&fl[]=creator&fl[]=description"
        .. "&fl[]=date&fl[]=language&fl[]=access-restricted-item"
        .. "&sort[]=downloads+desc"
        .. "&rows=%d&page=%d&output=json",
        q, limit, page)

    local data, err = HttpUtil.getJSON(url)
    if not data then return nil, err end
    return InternetArchive.parse(data, limit, page)
end

--- Locator → EPUB URL via the item's metadata (one request).
function InternetArchive.resolve(locator)
    local identifier = type(locator) == "table" and locator.identifier
    if not identifier then return nil, "no Internet Archive identifier" end
    local meta = HttpUtil.getJSON("https://archive.org/metadata/" .. identifier)
    if not meta or not meta.files then
        return nil, "no metadata for item"
    end
    if InternetArchive.isRestricted(meta.metadata) then
        return nil, RESTRICTED_MSG
    end
    local epub
    for __, file in ipairs(meta.files) do
        local fname = file.name or ""
        if fname:lower():match("%.epub$") then
            epub = fname
            break
        end
    end
    if not epub then
        return nil, "no EPUB available in this item"
    end
    return string.format("https://archive.org/download/%s/%s",
        identifier, url_escape(epub))
end

return InternetArchive
