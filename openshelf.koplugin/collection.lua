--[[
KOReader integration for My books (DESIGN.md §2.5, §3.5):
  - add downloaded files to a KOReader Collection named "OpenShelf" so they
    also show in the stock file manager's Collections;
  - read a book's reading status from KOReader's own per-book sidecar
    (BookList caches it): "new" | "reading" | "abandoned" | "complete",
    plus percent_finished.
Everything is pcall-guarded: a KOReader API drift must never break a download.
--]]
local logger = require("logger")

local Collection = {}
Collection.NAME = "OpenShelf"

function Collection.add(path)
    local ok, err = pcall(function()
        local RC = require("readcollection")
        if not RC.coll then RC:_read() end
        if not RC.coll[Collection.NAME] then
            RC:addCollection(Collection.NAME)
        end
        if not RC:isFileInCollection(path, Collection.NAME) then
            RC:addItem(path, Collection.NAME)
        end
        RC:write({ [Collection.NAME] = true })
    end)
    if not ok then logger.warn("OpenShelf: could not add to collection", err) end
    return ok
end

function Collection.remove(path)
    local ok, err = pcall(function()
        local RC = require("readcollection")
        if not RC.coll then RC:_read() end
        if RC.coll[Collection.NAME] and RC:isFileInCollection(path, Collection.NAME) then
            RC:removeItem(path, Collection.NAME)
        end
    end)
    if not ok then logger.warn("OpenShelf: could not remove from collection", err) end
    return ok
end

-- Returns { status = "new"|"reading"|"abandoned"|"complete", percent = 0..1|nil }
function Collection.status(path)
    local out = { status = "new", percent = nil }
    pcall(function()
        local BookList = require("ui/widget/booklist")
        local info = BookList.getBookInfo(path)
        if info and info.been_opened then
            out.status = info.status or "reading"
            out.percent = tonumber(info.percent_finished)
        end
    end)
    return out
end

-- Shelf bucket for My books: "reading" | "new" | "finished".
function Collection.bucket(status)
    if status == "complete" then return "finished" end
    if status == "reading" or status == "abandoned" then return "reading" end
    return "new"
end

return Collection
