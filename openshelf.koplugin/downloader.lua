--[[
Resolves a catalog entry to a URL and streams it into the OpenShelf folder.

Location: <home_dir>/OpenShelf — /mnt/onboard/OpenShelf on Kobo — a visible,
top-level folder so downloads show up in the stock Kobo library as well as in
KOReader. Falls back to KOReader's data dir on devices without a home_dir.

Filename: "Author - Title.<format>", made filesystem-safe by util.getSafeFilename
(VFAT-safe characters, UTF-8-safe truncation).
--]]
local DataStorage = require("datastorage")
local Device = require("device")
local HttpUtil = require("http_util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Downloader = {}

local FOLDER = "OpenShelf"
local NAME_LIMIT = 120   -- bytes; keeps names readable in file browsers

--- Where books go (pure; does not create the directory).
function Downloader.dirPath()
    return (Device.home_dir or DataStorage:getDataDir()) .. "/" .. FOLDER
end

--- Ensure the folder exists and return it.
function Downloader.getDir()
    local dir = Downloader.dirPath()
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

--- Target path for an entry (pure; no network, no resolve()).
-- Passing no path to getSafeFilename keeps it strict (VFAT rules) everywhere.
function Downloader.targetPath(entry)
    local name = string.format("%s - %s.%s",
        entry.author or "Unknown", entry.title or "book", entry.format or "epub")
    return Downloader.dirPath() .. "/" .. util.getSafeFilename(name, nil, NAME_LIMIT)
end

--- Returns the path if this entry was already downloaded (non-empty file), else nil.
function Downloader.exists(entry)
    local path = Downloader.targetPath(entry)
    local size = lfs.attributes(path, "size")
    if size and size > 0 then return path end
    return nil
end

--- Download the entry. Returns the saved path, or nil + error message.
function Downloader.download(entry)
    local url, err = entry.resolve()
    if not url then
        return nil, err or "could not resolve a download URL"
    end
    Downloader.getDir()
    return HttpUtil.download(url, Downloader.targetPath(entry))
end

return Downloader
