--[[
Minimal OPDS/Atom parser — just enough to pull acquisition entries out of an
OPDS feed without a full XML library. Used by the Feedbooks provider (and any
future OPDS source).

Returns a list of:
  { title=, author=, summary=, links = { {rel=, href=, type=}, ... } }
--]]
local OPDS = {}

local ENTITIES = {
    ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">",
    ["&quot;"] = '"', ["&apos;"] = "'", ["&#39;"] = "'",
}

local function unescape(s)
    if not s then return s end
    s = s:gsub("&#(%d+);", function(n) return string.char(tonumber(n) % 256) end)
    s = s:gsub("(&%a-;)", function(e) return ENTITIES[e] or e end)
    return s
end

local function strip_tags(s)
    return (s:gsub("<[^>]->", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Pull the first <tag>...</tag> inner text from a block.
local function first_tag(block, tag)
    local v = block:match("<" .. tag .. "[^>]->(.-)</" .. tag .. ">")
    return v and unescape(strip_tags(v)) or nil
end

-- Parse all <link .../> elements in a block into {rel, href, type}.
local function parse_links(block)
    local links = {}
    for tag in block:gmatch("<link%s+(.-)/?>") do
        links[#links + 1] = {
            rel  = tag:match('rel%s*=%s*"(.-)"'),
            href = unescape(tag:match('href%s*=%s*"(.-)"') or ""),
            type = tag:match('type%s*=%s*"(.-)"'),
        }
    end
    return links
end

function OPDS.parse(xml)
    local entries = {}
    if not xml then return entries end
    for block in xml:gmatch("<entry[%s>](.-)</entry>") do
        local author = block:match("<author>(.-)</author>")
        entries[#entries + 1] = {
            title   = first_tag(block, "title"),
            author  = author and first_tag(author, "name") or nil,
            summary = first_tag(block, "summary") or first_tag(block, "content"),
            links   = parse_links(block),
        }
    end
    return entries
end

-- Find the first acquisition link whose type matches `mime` (default epub).
-- Skips paid ("buy") acquisition links so only free downloads come through.
function OPDS.acquisition_href(links, mime)
    mime = mime or "application/epub+zip"
    for _, l in ipairs(links or {}) do
        local rel = l.rel or ""
        local is_acq = rel:find("acquisition", 1, true) ~= nil
        local is_buy = rel:find("buy", 1, true) ~= nil
        if is_acq and not is_buy and l.type and l.type:find(mime, 1, true) then
            return l.href
        end
    end
    return nil
end

return OPDS
