--[[
Internet Archive provider.
Search uses advancedsearch (returns identifiers); the EPUB filename is only known
per-item, so resolve() lazily hits the metadata API when the user picks a result.
Constrained to text items that actually ship an EPUB.
--]]
local HttpUtil = require("http_util")
local Entry = require("entry")
local url_escape = require("socket.url").escape

local InternetArchive = { name = "Internet Archive" }

local function first(value)
    if type(value) == "table" then return value[1] end
    return value
end

function InternetArchive.search(query, limit)
    limit = limit or 20
    local q = url_escape(string.format(
        "(%s) AND mediatype:texts AND format:(EPUB)", query))
    local url = string.format(
        "https://archive.org/advancedsearch.php?q=%s"
        .. "&fl[]=identifier&fl[]=title&fl[]=creator"
        .. "&rows=%d&page=1&output=json",
        q, limit)

    local data, err = HttpUtil.getJSON(url)
    if not data then return nil, err end

    local docs = data.response and data.response.docs or {}
    local results = {}
    for _, doc in ipairs(docs) do
        local identifier = doc.identifier
        if identifier then
            results[#results + 1] = Entry.download{
                title  = first(doc.title) or identifier,
                author = first(doc.creator) or "Unknown",
                source = InternetArchive.name,
                resolve = function()
                    local meta = HttpUtil.getJSON(
                        "https://archive.org/metadata/" .. identifier)
                    if not meta or not meta.files then
                        return nil, "no metadata for item"
                    end
                    local epub
                    for _, file in ipairs(meta.files) do
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
                end,
            }
        end
    end
    return results
end

return InternetArchive
