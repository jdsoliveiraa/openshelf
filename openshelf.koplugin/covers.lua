--[[
Cover thumbnails with a disk cache (DESIGN.md §3.4).

  Covers.fetch(urls, on_done)   -- subprocess downloads the missing ones into
                                   <data>/cache/openshelf/<hash>.img; on_done(got_urls)
  Covers.isCached(url)          -- file on disk?
  Covers.load(url, box_w, box_h)-- BlitBuffer fitted inside the box (aspect kept),
                                   decoded from disk, memoised per size; nil if absent
  Covers.freeAll()              -- drop decoded buffers (page/view closed)

Why decode native then scale once: renderImageFile(..., w, h) stretches to
exactly w×h. Fitting ourselves is the only way to keep the aspect ratio.
--]]
local DataStorage = require("datastorage")
local RenderImage = require("ui/renderimage")
local HttpUtil = require("http_util")
local Hash = require("hashkey")
local Jobs = require("jobs")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local logger = require("logger")

local Covers = {}

local FETCH_OPTS = { block_timeout = 5, total_timeout = 15 }
local MAX_DECODED = 80

local decoded = {}        -- key -> BlitBuffer
local decoded_count = 0
local failed = {}         -- url -> true (this session)

function Covers.dir()
    local dir = DataStorage:getDataDir() .. "/cache/openshelf"
    if lfs.attributes(dir, "mode") ~= "directory" then
        util.makePath(dir)
    end
    return dir
end

function Covers.fileFor(url)
    return Covers.dir() .. "/" .. Hash.hex(url) .. ".img"
end

function Covers.isCached(url)
    if not url or url == "" then return false end
    local size = lfs.attributes(Covers.fileFor(url), "size")
    return size ~= nil and size > 0
end

-- Download every uncached URL in `urls` (child process). on_done(got) lists
-- the URLs now on disk. Returns a job handle (or nil when nothing to do).
function Covers.fetch(urls, on_done)
    local todo = {}
    local seen = {}
    for __, url in ipairs(urls or {}) do
        if url and url ~= "" and not seen[url] and not failed[url] and not Covers.isCached(url) then
            seen[url] = true
            todo[#todo + 1] = url
        end
    end
    if #todo == 0 then
        if on_done then on_done({}) end
        return nil
    end
    local dir = Covers.dir()   -- create in the parent; the child must not race on it
    return Jobs.run{
        task = function()
            local got = {}
            for __, url in ipairs(todo) do
                local target = dir .. "/" .. Hash.hex(url) .. ".img"
                local tmp = target .. ".part"
                local ok = HttpUtil.download(url, tmp, FETCH_OPTS)
                local size = ok and lfs.attributes(tmp, "size") or 0
                if ok and size > 0 and os.rename(tmp, target) then
                    got[#got + 1] = url
                else
                    os.remove(tmp)
                end
            end
            return got
        end,
        on_done = function(got)
            local ok = {}
            for __, url in ipairs(got or {}) do ok[url] = true end
            for __, url in ipairs(todo) do
                if not ok[url] then failed[url] = true end
            end
            if on_done then on_done(got or {}) end
        end,
        on_error = function(err)
            logger.dbg("OpenShelf: cover batch failed", err)
            if on_done then on_done({}) end
        end,
    }
end

local function fit(native, box_w, box_h)
    local w, h = native:getWidth(), native:getHeight()
    if w == 0 or h == 0 then return nil end
    local scale = math.min(box_w / w, box_h / h)
    if scale >= 1 then return native end
    -- scaleBlitBuffer frees the native bb for us
    return RenderImage:scaleBlitBuffer(native,
        math.max(1, math.floor(w * scale)), math.max(1, math.floor(h * scale)))
end

function Covers.load(url, box_w, box_h)
    if not url or url == "" then return nil end
    local key = url .. "|" .. box_w .. "x" .. box_h
    local hit = decoded[key]
    if hit ~= nil then return hit or nil end
    local path = Covers.fileFor(url)
    local size = lfs.attributes(path, "size")
    if not size or size == 0 then return nil end
    if decoded_count >= MAX_DECODED then Covers.freeAll() end
    local ok, bb = pcall(function()
        local native = RenderImage:renderImageFile(path, false)
        return native and fit(native, box_w, box_h) or nil
    end)
    if not ok or not bb then
        logger.dbg("OpenShelf: cover decode failed", path, not ok and bb or "")
        os.remove(path)   -- corrupt file: let a later fetch retry
        decoded[key] = false
        return nil
    end
    decoded[key] = bb
    decoded_count = decoded_count + 1
    return bb
end

function Covers.freeAll()
    for __, bb in pairs(decoded) do
        if bb and bb.free then pcall(function() bb:free() end) end
    end
    decoded = {}
    decoded_count = 0
end

return Covers
