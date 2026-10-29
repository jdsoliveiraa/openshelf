--[[
Which panel refresh an OpenShelf view enqueues when it closes (#25). Pure: no
KOReader requires, so test/unit.lua covers it.

KOReader's UIManager:close without a refresh type repaints the windows below
into the framebuffer and then drops the refresh, so the e-ink panel keeps
showing the closed view. Stock full-screen widgets (Menu:onCloseWidget) enqueue
their own "ui" refresh; ViewBase:onCloseWidget does the same through mode().

No refresh when:
  - OpenShelf is leaving to open a book (App.openBook): the reader does its
    own full refresh right after;
  - the host (file manager / reader) is tearing down or absent, like Menu.
--]]
local CloseRefresh = {}

local leaving_for_book = false

--- fm, reader: FileManager.instance / ReaderUI.instance (either may be nil).
--- Returns "ui", or nil for no refresh.
function CloseRefresh.mode(fm, reader)
    if leaving_for_book then return nil end
    local live = (fm and not fm.tearing_down) or (reader and not reader.tearing_down)
    if not live then return nil end
    return "ui"
end

--- Run fn (which closes the views) with close refreshes suppressed.
function CloseRefresh.leavingForBook(fn)
    leaving_for_book = true
    local ok, err = pcall(fn)
    leaving_for_book = false
    if not ok then error(err, 0) end
end

return CloseRefresh
