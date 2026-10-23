--[[
Thin HTTP helpers over LuaSocket, matching the patterns KOReader itself uses
(socketutil timeouts, http/https picked by scheme, ltn12 sinks).
--]]
local socket = require("socket")
local socketutil = require("socketutil")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local JSON = require("json")
local logger = require("logger")

local UA = "OpenShelf/0.1 (KOReader)"

local HttpUtil = {}

local function requester_for(url)
    return url:match("^https://") and https or http
end

-- GET the raw body of a URL. Returns body string, or nil + error message.
function HttpUtil.getBody(url)
    local sink = {}
    local request = {
        url = url,
        method = "GET",
        headers = { ["User-Agent"] = UA },
        sink = ltn12.sink.table(sink),
    }
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _headers, status = socket.skip(1, requester_for(url).request(request))
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.warn("OpenShelf: GET failed", url, code, status)
        return nil, status or tostring(code)
    end
    return table.concat(sink)
end

-- GET + JSON-decode. Returns a Lua table, or nil + error message.
function HttpUtil.getJSON(url)
    local body, err = HttpUtil.getBody(url)
    if not body then return nil, err end
    local ok, decoded = pcall(JSON.decode, body)
    if not ok or type(decoded) ~= "table" then
        return nil, "invalid JSON response"
    end
    return decoded
end

-- Stream a URL to disk. Returns the target path, or nil + error message.
function HttpUtil.download(url, target_path)
    local f, ferr = io.open(target_path, "w")
    if not f then return nil, ferr end
    local request = {
        url = url,
        method = "GET",
        headers = { ["User-Agent"] = UA },
        sink = ltn12.sink.file(f), -- closes the file handle for us
    }
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, _headers, status = socket.skip(1, requester_for(url).request(request))
    socketutil:reset_timeout()
    if code ~= 200 then
        os.remove(target_path)
        logger.warn("OpenShelf: download failed", url, code, status)
        return nil, status or tostring(code)
    end
    return target_path
end

return HttpUtil
