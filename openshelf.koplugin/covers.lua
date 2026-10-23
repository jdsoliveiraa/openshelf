--[[
Cover thumbnails: download image bytes and decode them into BlitBuffers scaled to
a target size, with an in-memory cache keyed by URL. Call Covers.clearCache() when
the results view closes to free the BlitBuffers.

Decoding uses KOReader's RenderImage (C-backed: JPEG/PNG/GIF/…), so this path can
only run inside KOReader — the headless test validates the URLs/bytes, not decode.
--]]
local HttpUtil = require("http_util")
local RenderImage = require("ui/renderimage")
local logger = require("logger")

local Covers = {}
local cache = {}   -- url -> BlitBuffer (or false if known-failed)

-- Returns a scaled BlitBuffer for the cover at `url`, or nil.
-- width/height are the target thumbnail box (fit, aspect preserved by caller).
function Covers.get(url, width, height)
    if not url or url == "" then return nil end
    local hit = cache[url]
    if hit ~= nil then
        return hit or nil
    end

    local body, err = HttpUtil.getBody(url)
    if not body or #body == 0 then
        logger.dbg("OpenShelf: cover fetch failed", url, err)
        cache[url] = false
        return nil
    end

    local ok, bb = pcall(function()
        return RenderImage:renderImageData(body, #body, false, width, height)
    end)
    if not ok or not bb then
        logger.dbg("OpenShelf: cover decode failed", url)
        cache[url] = false
        return nil
    end
    cache[url] = bb
    return bb
end

function Covers.clearCache()
    for _, bb in pairs(cache) do
        if bb and bb.free then
            pcall(function() bb:free() end)
        end
    end
    cache = {}
end

return Covers
