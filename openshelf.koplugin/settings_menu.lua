--[[
Settings behind the gear (DESIGN.md §2.6): sources, default results view,
results per source, clear recent searches, About. A stock KOReader Menu;
the right column shows the current value.
--]]
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local _ = require("gettext")
local T = require("ffi/util").template

local Catalog = require("catalog")
local Downloader = require("downloader")
local Glyphs = require("glyphs")
local Settings = require("settings")
local Version = require("openshelf_version")

local SettingsMenu = {}

local function next_per_source()
    local cur = Settings.perSource()
    local choices = Settings.PER_SOURCE_CHOICES
    for i, n in ipairs(choices) do
        if n == cur then return choices[(i % #choices) + 1] end
    end
    return choices[1]
end

function SettingsMenu.show(opts)
    opts = opts or {}
    local menu
    local items

    local function refresh()
        menu:switchItemTable(nil, items())
    end

    items = function()
        local t = {}
        t[#t + 1] = { text = _("Sources"), dim = true, select_enabled = false }
        for __, name in ipairs(Catalog.providerNames()) do
            local n = name
            t[#t + 1] = {
                text = "      " .. n,
                mandatory = Settings.isEnabled(n) and Glyphs.check or "",
                callback = function()
                    Settings.toggle(n)
                    refresh()
                end,
            }
        end
        t[#t + 1] = { text = _("Results"), dim = true, select_enabled = false }
        t[#t + 1] = {
            text = "      " .. _("Default view"),
            mandatory = Settings.defaultView() == "grid" and _("Grid") or _("List"),
            callback = function()
                Settings.setDefaultView(Settings.defaultView() == "grid" and "list" or "grid")
                refresh()
            end,
        }
        t[#t + 1] = {
            text = "      " .. _("Results per source"),
            mandatory = tostring(Settings.perSource()),
            callback = function()
                Settings.setPerSource(next_per_source())
                refresh()
            end,
        }
        t[#t + 1] = {
            text = "      " .. _("Clear recent searches"),
            mandatory = tostring(#Settings.recents()),
            callback = function()
                if #Settings.recents() == 0 then return end
                UIManager:show(ConfirmBox:new{
                    text = _("Clear all recent searches?"),
                    ok_text = _("Clear"),
                    ok_callback = function()
                        Settings.clearRecents()
                        refresh()
                    end,
                })
            end,
        }
        t[#t + 1] = {
            text = _("About OpenShelf"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("OpenShelf %1\n\nSearch free & public-domain ebook catalogs and download them on-device.\n\nSources: %2\n\nBooks are saved to:\n%3\n\nOnly DRM-free, openly-licensed books are downloaded in-app."),
                        Version,
                        table.concat(Catalog.providerNames(), ", "),
                        Downloader.dirPath()),
                })
            end,
        }
        return t
    end

    menu = Menu:new{
        title = _("OpenShelf settings"),
        item_table = items(),
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    local orig_close = menu.onCloseWidget
    menu.onCloseWidget = function(m)
        if orig_close then orig_close(m) end
        if opts.on_close then opts.on_close() end
    end
    UIManager:show(menu)
end

return SettingsMenu
