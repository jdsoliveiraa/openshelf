--[[
Resolves a catalog entry to a URL and streams it into the OpenShelf library
folder (under KOReader's data dir). Filename: "Author - Title.<format>".
--]]
local DataStorage = require("datastorage")
local HttpUtil = require("http_util")
local lfs = require("libs/libkoreader-lfs")

local Downloader = {}

function Downloader.getDir()
    local dir = ("%s/openshelf"):format(DataStorage:getDataDir())
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

local function sanitize(name)
    return (name:gsub('[/\\%?%%%*:|"<>]', "_")
                :gsub("%s+", " ")
                :gsub("^%s+", "")
                :gsub("%s+$", "")
                :sub(1, 120))
end

-- Returns the saved path, or nil + error message.
function Downloader.download(entry)
    local url, err = entry.resolve()
    if not url then
        return nil, err or "could not resolve a download URL"
    end
    local base = sanitize(string.format("%s - %s",
        entry.author or "Unknown", entry.title or "book"))
    local ext = entry.format or "epub"
    local target = ("%s/%s.%s"):format(Downloader.getDir(), base, ext)
    return HttpUtil.download(url, target)
end

return Downloader
