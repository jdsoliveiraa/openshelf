--[[
Thin HTTP helpers over LuaSocket, matching the patterns KOReader itself uses
(socketutil timeouts, http/https picked by scheme).

Why socketutil's sinks instead of plain ltn12 ones: LuaSocket resets its own
timer on every chunk, so a slow trickle never trips the "total" timeout.
socketutil.table_sink / file_sink enforce a real wall-clock limit on the body.

These run inside forked subprocesses too (search, covers, downloads): nothing
here may touch UIManager or widgets.
--]]
local socket = require("socket")
local socketutil = require("socketutil")
local http = require("socket.http")
local socket_url = require("socket.url")
local https = require("ssl.https")
local JSON = require("json")
local logger = require("logger")
local VERSION = require("openshelf_version")

local UA = "OpenShelf/" .. VERSION .. " (KOReader; +https://github.com/jdsoliveiraa/openshelf)"

local HttpUtil = {}

local function requester_for(url)
    return url:match("^https://") and https or http
end

-- Request headers: the User-Agent, with opts.headers merged over it
-- (PROVIDERS.md §3) — how a provider's Authorization reaches the server.
local function headers_for(opts)
    local headers = { ["User-Agent"] = UA }
    if type(opts.headers) == "table" then
        for k, v in pairs(opts.headers) do
            if type(k) == "string" and v ~= nil then headers[k] = tostring(v) end
        end
    end
    return headers
end

-- Redirects are followed here, not by LuaSocket, so provider-supplied
-- headers (Authorization, cookies, …) never follow a redirect to another
-- host: LuaSocket would re-send reqt.headers to any Location. Same-host hops
-- keep them; after the first host change only the User-Agent goes on.
local MAX_REDIRECTS = 5
local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

local function authority(url)
    local u = socket_url.parse(url) or {}
    local scheme = (u.scheme or ""):lower()
    local port = u.port or (scheme == "https" and "443" or "80")
    return (u.host or ""):lower() .. ":" .. tostring(port)
end

-- One request with manual redirects. opts.allow_url(url) -> bool, when
-- given, vets every redirect target (the self-updater's https-only rule);
-- callers that don't pass it behave exactly as before. `make_sink()` gives a fresh sink per hop
-- (a redirect's small body lands in it and is thrown away by the caller's
-- next sink). Returns code, headers, status like socket.skip(1, request()).
local function request(method, url, opts, make_sink)
    local headers = headers_for(opts)
    local origin = authority(url)
    for __ = 0, MAX_REDIRECTS do
        local code, resp_headers, status = socket.skip(1, requester_for(url).request{
            url = url,
            method = method,
            headers = headers,
            sink = make_sink and make_sink() or nil,
            redirect = false,
        })
        local location = REDIRECT[code] and type(resp_headers) == "table" and resp_headers.location
        if not location then return code, resp_headers, status end
        url = socket_url.absolute(url, location)
        if opts.allow_url and not opts.allow_url(url) then
            return nil, nil, "redirect to a disallowed URL refused: " .. tostring(url)
        end
        if authority(url) ~= origin then headers = headers_for({}) end
    end
    return nil, nil, "too many redirects"
end

-- Human-readable failure message; socketutil knows the timeout codes.
local function describe(code, status, block_t, total_t)
    local msg = socketutil.describe_error and socketutil.describe_error(code, block_t, total_t)
    return msg or status or tostring(code)
end

--- GET the raw body of a URL. Returns body string, or nil + error message.
-- opts.block_timeout / opts.total_timeout (seconds) override the LARGE_* defaults;
-- opts.headers adds request headers (every helper here takes it).
function HttpUtil.getBody(url, opts)
    opts = opts or {}
    local chunks = {}
    local block_t, total_t = socketutil:set_timeout(
        opts.block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
        opts.total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    -- sinks built after set_timeout: they read the total timeout when created
    local code, _headers, status = request("GET", url, opts, function()
        chunks = {}
        return socketutil.table_sink(chunks)
    end)
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

--- HEAD a URL. Returns the response headers (lower-case keys) or nil + error.
-- Used to learn Content-Length before a download so progress can be a
-- percentage. Many hosts answer HEAD; when one doesn't, callers fall back to
-- an indeterminate bar.
function HttpUtil.head(url, opts)
    opts = opts or {}
    local block_t, total_t = socketutil:set_timeout(
        opts.block_timeout or 10, opts.total_timeout or 20)
    local code, headers, status = request("HEAD", url, opts)
    socketutil:reset_timeout()
    if code ~= 200 or type(headers) ~= "table" then
        return nil, describe(code, status, block_t, total_t)
    end
    return headers
end

--- Content-Length for a URL via HEAD, or nil. opts as for head().
function HttpUtil.contentLength(url, opts)
    local headers = HttpUtil.head(url, opts)
    local len = headers and (headers["content-length"] or headers["Content-Length"])
    return tonumber(len)
end

--- Stream a URL to disk. Returns the target path, or nil + error message.
-- opts.block_timeout / opts.total_timeout (seconds) override the FILE_* defaults.
function HttpUtil.download(url, target_path, opts)
    opts = opts or {}
    local f, ferr = io.open(target_path, "wb")
    if not f then return nil, ferr end
    local block_t, total_t = socketutil:set_timeout(
        opts.block_timeout or socketutil.FILE_BLOCK_TIMEOUT,
        opts.total_timeout or socketutil.FILE_TOTAL_TIMEOUT)
    local code, _headers, status = request("GET", url, opts, function()
        -- each hop truncates the file: a redirect's body is discarded
        if io.type(f) == "file" then f:close() end
        f = io.open(target_path, "wb")
        if not f then return function() return nil, "cannot reopen " .. target_path end end
        return socketutil.file_sink(f) -- closes the handle at end-of-stream
    end)
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
