--[[
Thin HTTP helpers over LuaSocket, matching the patterns KOReader itself uses
(socketutil timeouts, http/https picked by scheme).

Why socketutil's sinks instead of plain ltn12 ones: LuaSocket resets its own
timer on every chunk, so a slow trickle never trips the "total" timeout.
socketutil.table_sink / file_sink enforce a real wall-clock limit on the body.
--]]
local socket = require("socket")
local socketutil = require("socketutil")
local http = require("socket.http")
local https = require("ssl.https")
local JSON = require("json")
local logger = require("logger")
local VERSION = require("version")

local UA = "OpenShelf/" .. VERSION .. " (KOReader; +https://github.com/jdsoliveiraa/openshelf)"

local HttpUtil = {}

local function requester_for(url)
    return url:match("^https://") and https or http
end

-- Human-readable failure message; socketutil knows the timeout codes.
local function describe(code, status, block_t, total_t)
    local msg = socketutil.describe_error and socketutil.describe_error(code, block_t, total_t)
    return msg or status or tostring(code)
end

--- GET the raw body of a URL. Returns body string, or nil + error message.
-- opts.block_timeout / opts.total_timeout (seconds) override the LARGE_* defaults.
function HttpUtil.getBody(url, opts)
    opts = opts or {}
    local chunks = {}
    local block_t, total_t = socketutil:set_timeout(
        opts.block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
        opts.total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    local request = {
        url = url,
        method = "GET",
        headers = { ["User-Agent"] = UA },
        -- built after set_timeout: the sink reads the total timeout when created
        sink = socketutil.table_sink(chunks),
    }
    local code, _headers, status = socket.skip(1, requester_for(url).request(request))
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.warn("OpenShelf: GET failed", url, code, status)
        return nil, describe(code, status, block_t, total_t)
    end
    return table.concat(chunks)
end

--- GET + JSON-decode. Returns a Lua table, or nil + error message.
function HttpUtil.getJSON(url, opts)
    local body, err = HttpUtil.getBody(url, opts)
    if not body then return nil, err end
    local ok, decoded = pcall(JSON.decode, body)
    if not ok or type(decoded) ~= "table" then
        return nil, "invalid JSON response"
    end
    return decoded
end

--- Stream a URL to disk. Returns the target path, or nil + error message.
function HttpUtil.download(url, target_path)
    local f, ferr = io.open(target_path, "wb")
    if not f then return nil, ferr end
    local block_t, total_t = socketutil:set_timeout(
        socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local request = {
        url = url,
        method = "GET",
        headers = { ["User-Agent"] = UA },
        sink = socketutil.file_sink(f), -- closes the handle at end-of-stream
    }
    local code, _headers, status = socket.skip(1, requester_for(url).request(request))
    socketutil:reset_timeout()
    -- The sink only closes the handle once it sees end-of-stream; a connection
    -- failure before any body arrives would otherwise leak it.
    if io.type(f) == "file" then f:close() end
    if code ~= 200 then
        os.remove(target_path)
        logger.warn("OpenShelf: download failed", url, code, status)
        return nil, describe(code, status, block_t, total_t)
    end
    return target_path
end

return HttpUtil
