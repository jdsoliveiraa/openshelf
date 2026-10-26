--[[
Downloads (DESIGN.md §2.4, §3.3): a queue, one active download at a time, each
in a subprocess streaming to "<target>.part" with Content-Length in a sidecar
so the parent can show bytes/percent by polling file sizes. Cancel kills the
child and removes the partial.

Location: <home_dir>/OpenShelf — /mnt/onboard/OpenShelf on Kobo — a visible,
top-level folder so downloads show up in the stock Kobo library as well.
Filename: "Author - Title.<format>" via util.getSafeFilename.

Views subscribe to be repainted:
  Downloader.subscribe(fn(event, entry, state))  -- "queued"|"start"|"progress"|"done"|"error"|"cancel"
  Downloader.state(entry) -> { status = "queued"|"active", done = bytes, total = bytes|nil } | nil
main.lua sets Downloader.on_complete(entry, path) to record the book.
--]]
local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local Catalog = require("catalog")
local Entry = require("entry")
local HttpUtil = require("http_util")
local Jobs = require("jobs")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local logger = require("logger")

local Downloader = {}

local FOLDER = "OpenShelf"
local NAME_LIMIT = 120   -- bytes; keeps names readable in file browsers
local TICK = 0.5

local queue = {}          -- list of { entry = … }
local active = nil        -- { entry, id, job, part, sizefile, done, total }
local listeners = {}

---------------------------------------------------------------------------
-- Paths
---------------------------------------------------------------------------
function Downloader.dirPath()
    return (Device.home_dir or DataStorage:getDataDir()) .. "/" .. FOLDER
end

function Downloader.getDir()
    local dir = Downloader.dirPath()
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

function Downloader.targetPath(entry)
    local name = string.format("%s - %s.%s",
        entry.author or "Unknown", entry.title or "book", entry.format or "epub")
    return Downloader.dirPath() .. "/" .. util.getSafeFilename(name, nil, NAME_LIMIT)
end

--- Path if this entry's file is on disk (non-empty), else nil.
function Downloader.exists(entry)
    local path = Downloader.targetPath(entry)
    local size = lfs.attributes(path, "size")
    if size and size > 0 then return path end
    return nil
end

---------------------------------------------------------------------------
-- Observers
---------------------------------------------------------------------------
function Downloader.subscribe(fn)
    listeners[fn] = true
end

function Downloader.unsubscribe(fn)
    listeners[fn] = nil
end

local function notify(event, entry, state)
    for fn in pairs(listeners) do
        local ok, err = pcall(fn, event, entry, state)
        if not ok then logger.warn("OpenShelf: download listener failed", err) end
    end
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
function Downloader.state(entry)
    local id = Entry.id(entry)
    if active and active.id == id then
        return { status = "active", done = active.done or 0, total = active.total }
    end
    for i, item in ipairs(queue) do
        if item.id == id then return { status = "queued", position = i } end
    end
    return nil
end

function Downloader.isBusy(entry)
    return Downloader.state(entry) ~= nil
end

local function read_size_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = tonumber(f:read("*a"))
    f:close()
    return n
end

local function tick()
    if not active then return end
    active.done = lfs.attributes(active.part, "size") or active.done or 0
    if not active.total then active.total = read_size_file(active.sizefile) end
    notify("progress", active.entry, Downloader.state(active.entry))
    UIManager:scheduleIn(TICK, tick)
end

local function cleanup(part, sizefile)
    os.remove(part)
    os.remove(sizefile)
end

local start_next

local function finish(event, entry, payload)
    local a = active
    active = nil
    if a then UIManager:unschedule(tick) end
    notify(event, entry, payload)
    start_next()
end

start_next = function()
    if active or #queue == 0 then return end
    local item = table.remove(queue, 1)
    local entry = item.entry
    local target = Downloader.targetPath(entry)
    local part = target .. ".part"
    local sizefile = part .. ".size"
    Downloader.getDir()
    cleanup(part, sizefile)

    active = { entry = entry, id = item.id, part = part, sizefile = sizefile, done = 0 }
    active.job = Jobs.run{
        interval = 0.5,
        task = function()
            local url, err = Catalog.resolve(entry)
            if not url then error(err or "could not resolve a download URL", 0) end
            local total = HttpUtil.contentLength(url)
            if total then
                local f = io.open(sizefile, "wb")
                if f then f:write(tostring(total)); f:close() end
            end
            local ok, derr = HttpUtil.download(url, part)
            if not ok then error(derr or "download failed", 0) end
            local size = lfs.attributes(part, "size") or 0
            if size == 0 then error("empty file received", 0) end
            return { size = size, total = total }
        end,
        on_done = function(result)
            os.remove(target)
            local renamed = os.rename(part, target)
            os.remove(sizefile)
            if not renamed then
                cleanup(part, sizefile)
                finish("error", entry, { err = "could not move the file into place" })
                return
            end
            if Downloader.on_complete then
                local ok, err = pcall(Downloader.on_complete, entry, target)
                if not ok then logger.warn("OpenShelf: on_complete failed", err) end
            end
            finish("done", entry, { path = target, size = result and result.size })
        end,
        on_error = function(err)
            cleanup(part, sizefile)
            finish("error", entry, { err = err })
        end,
    }
    notify("start", entry, Downloader.state(entry))
    UIManager:scheduleIn(TICK, tick)
end

---------------------------------------------------------------------------
-- Queue API
---------------------------------------------------------------------------
function Downloader.enqueue(entry)
    if Downloader.isBusy(entry) then return false end
    queue[#queue + 1] = { entry = entry, id = Entry.id(entry) }
    notify("queued", entry, Downloader.state(entry))
    start_next()
    return true
end

function Downloader.cancel(entry)
    local id = Entry.id(entry)
    for i, item in ipairs(queue) do
        if item.id == id then
            table.remove(queue, i)
            notify("cancel", entry, nil)
            return true
        end
    end
    if active and active.id == id then
        local a = active
        if a.job then a.job:cancel() end
        cleanup(a.part, a.sizefile)
        finish("cancel", entry, nil)
        return true
    end
    return false
end

function Downloader.cancelAll()
    queue = {}
    if active then Downloader.cancel(active.entry) end
end

return Downloader
