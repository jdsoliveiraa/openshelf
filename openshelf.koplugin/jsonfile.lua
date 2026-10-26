--[[
Read/write a Lua table as a JSON file, atomically (write to .tmp, rename).
Used for the library and the browse cache. Returns nil when the file is
missing or unreadable rather than raising.
--]]
local JSON = require("json")
local logger = require("logger")

local JsonFile = {}

function JsonFile.read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    if not body or body == "" then return nil end
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" then
        logger.warn("OpenShelf: unreadable JSON file", path)
        return nil
    end
    return data
end

function JsonFile.write(path, data)
    local ok, body = pcall(JSON.encode, data)
    if not ok then
        logger.warn("OpenShelf: cannot encode JSON for", path, body)
        return false
    end
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then
        logger.warn("OpenShelf: cannot write", tmp, err)
        return false
    end
    f:write(body)
    f:close()
    os.remove(path)
    local renamed = os.rename(tmp, path)
    if not renamed then os.remove(tmp) end
    return renamed and true or false
end

return JsonFile
