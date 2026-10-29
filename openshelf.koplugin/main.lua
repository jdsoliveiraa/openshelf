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
local Settings = require("settings")

local dev_script_started = false

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
    -- Home mode: OpenShelf is the screen KOReader lands on at start and again
    -- every time a book is closed, so it feels like the app and the file
    -- manager becomes the escape hatch (X on the home screen reveals it).
    -- KOReader tears the file manager and its plugins down while a book is
    -- open and rebuilds them afterwards, so opening home from init() in the
    -- file-manager context covers both moments. OPENSHELF_AUTOOPEN=1 does the
    -- same for one session: the Kobo launcher (kobo/openshelf.sh) and
    -- scripts/emu.sh set it.
    if not self.ui.document and (Settings.homeMode() or os.getenv("OPENSHELF_AUTOOPEN")) then
        UIManager:nextTick(function() self:onOpenShelfOpen() end)
    end
    -- Dev convenience for the emulator: run a Lua script that drives the UI
    -- (used to walk every screen and take screenshots without a mouse). Once
    -- per process: init() runs again for every file manager / reader instance.
    local dev_script = os.getenv("OPENSHELF_DEV_SCRIPT")
    if dev_script and not dev_script_started then
        dev_script_started = true
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
    -- External providers: read lazily on every open, never in init() (plugin
    -- instances are created in path order, so provider-* plugins register
    -- after us). Each registration / file is taken once per process.
    require("openshelf_external").open()
    local HomeView = require("view_home")
    UIManager:show(HomeView:new{ ui = self.ui })
    return true
end

return OpenShelf
