--[[
Cover thumbnails: fetch image bytes (short timeouts), decode at native size and
scale ONCE to fit inside the thumbnail box, preserving aspect ratio. Cached per
URL (false = known failure). Call Covers.clearCache() when the results view
closes to free the BlitBuffers.

Why not ask RenderImage for the box size directly: renderImageData(..., w, h)
scales to EXACTLY w×h, i.e. it stretches. Decoding native and fitting ourselves
is the only way to keep the aspect ratio.

Decoding uses KOReader's RenderImage (C-backed), so this path only runs inside
KOReader — the headless test validates the URLs/bytes, not the decode.
--]]
local HttpUtil = require("http_util")
local RenderImage = require("ui/renderimage")
local logger = require("logger")

local Covers = {}
local cache = {}   -- url -> BlitBuffer (or false if known-failed)

-- Covers are decoration: fail fast rather than stall a page build.
local FETCH_OPTS = { block_timeout = 5, total_timeout = 10 }

local function fit(native, box_w, box_h)
    local w, h = native:getWidth(), native:getHeight()
    if w == 0 or h == 0 then return nil end
    local scale = math.min(box_w / w, box_h / h)
    if scale >= 1 then return native end
    -- scaleBlitBuffer frees the native bb for us
    return RenderImage:scaleBlitBuffer(native,
        math.max(1, math.floor(w * scale)), math.max(1, math.floor(h * scale)))
end

--- Returns a BlitBuffer that fits inside box_w × box_h (aspect preserved), or nil.
function Covers.get(url, box_w, box_h)
    if not url or url == "" then return nil end
    local hit = cache[url]
    if hit ~= nil then
        return hit or nil
    end

    local body, err = HttpUtil.getBody(url, FETCH_OPTS)
    if not body or #body == 0 then
        logger.dbg("OpenShelf: cover fetch failed", url, err)
        cache[url] = false
        return nil
    end

    local ok, bb = pcall(function()
        local native = RenderImage:renderImageData(body, #body, false)
        return native and fit(native, box_w, box_h) or nil
    end)
    if not ok or not bb then
        logger.dbg("OpenShelf: cover decode failed", url, not ok and bb or "")
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
