--[[
OpenShelf — search free & public-domain ebook catalogs and download them
straight onto your device.

Screens (see DESIGN.md):
  Main menu ▸ OpenShelf  (or a gesture via the Dispatcher action)
    └─ Home: search · recent searches · My books · browse shelves
         ├─ Results (same screen): toolbar · list/grid · load more
         │     └─ Detail: cover · metadata · description · Download/Open
         ├─ My books: Reading now · Not started · Finished
         └─ Settings (gear): sources · default view · per-source · recents · About

Network work (search, covers, downloads) runs in forked subprocesses and the
views poll them, so the UI never blocks. Entries are plain data; see entry.lua.
--]]
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local App = require("app")
local Downloader = require("downloader")

local OpenShelf = WidgetContainer:extend{
    name = "openshelf",
    is_doc_only = false,
}

function OpenShelf:onDispatcherRegisterActions()
    Dispatcher:registerAction("openshelf_open", {
        category = "none",
        event = "OpenShelfOpen",
        title = _("OpenShelf"),
        general = true,
    })
end

function OpenShelf:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    Downloader.on_complete = App.recordDownload
    -- Dev conveniences for the emulator (no effect unless the env vars are set):
    -- open straight into OpenShelf, and run a Lua script that drives the UI
    -- (used to walk every screen and take screenshots without a mouse).
    if os.getenv("OPENSHELF_AUTOOPEN") then
        UIManager:scheduleIn(1, function() self:onOpenShelfOpen() end)
    end
    local dev_script = os.getenv("OPENSHELF_DEV_SCRIPT")
    if dev_script then
        UIManager:scheduleIn(2, function()
            local ok, err = pcall(dofile, dev_script)
            if not ok then require("logger").err("OpenShelf dev script failed:", err) end
        end)
    end
end

function OpenShelf:addToMainMenu(menu_items)
    menu_items.openshelf = {
        text = _("OpenShelf"),
        keep_menu_open = false,
        callback = function() self:onOpenShelfOpen() end,
    }
end

function OpenShelf:onOpenShelfOpen()
    if App.homeView() then return true end   -- already open
    local HomeView = require("view_home")
    UIManager:show(HomeView:new{ ui = self.ui })
    return true
end

return OpenShelf
