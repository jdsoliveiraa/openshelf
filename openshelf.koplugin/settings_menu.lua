--[[
Settings behind the gear (DESIGN.md §2.6, §8, §10): sources, default results
view, results per source, clear recent searches, home mode, updates, About. A stock KOReader Menu;
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
local SourceMenu = require("settings_source")
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

--- Sources -> Arrange sources (DESIGN.md §9.5, decision 44): the stock
-- SortWidget over every registered source, enabled or not, in the current
-- order. Saving stores the id list; slots, the filter dialog and home shelves
-- read it through Settings.orderedProviders / Catalog.shelves.
function SettingsMenu.arrange(on_saved)
    local SortWidget = require("ui/widget/sortwidget")
    local item_table = {}
    for __, p in ipairs(Settings.orderedProviders()) do
        item_table[#item_table + 1] = { text = p.name, id = p.id }
    end
    UIManager:show(SortWidget:new{
        title = _("Arrange sources"),
        item_table = item_table,
        callback = function()
            local ids = {}
            for i, item in ipairs(item_table) do ids[i] = item.id end
            Settings.setSourceOrder(ids)
            if on_saved then on_saved() end
        end,
    })
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
        t[#t + 1] = {
            text = "      " .. _("Arrange sources"),
            callback = function() SettingsMenu.arrange(refresh) end,
        }
        for __, p in ipairs(Settings.orderedProviders()) do
            t[#t + 1] = SourceMenu.row(p, refresh)   -- tap opens the source's submenu
        end
        -- Providers that failed to load or validate, or lost an id clash:
        -- dimmed with the reason (PROVIDERS.md §8.5); tap shows it in full.
        for __, inv in ipairs(Catalog.invalid()) do
            local name, reason = tostring(inv.name or inv.id or "?"), tostring(inv.reason)
            t[#t + 1] = {
                text = "      " .. name .. " — " .. reason,
                dim = true,
                callback = function()
                    UIManager:show(InfoMessage:new{ text = name .. "\n\n" .. reason })
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
        t[#t + 1] = { text = _("Home mode"), dim = true, select_enabled = false }
        t[#t + 1] = {
            text = "      " .. _("Open at start and after each book"),
            mandatory = Settings.homeMode() and Glyphs.check or "",
            callback = function()
                Settings.setHomeMode(not Settings.homeMode())
                refresh()
            end,
        }
        t[#t + 1] = { text = _("Updates"), dim = true, select_enabled = false }
        t[#t + 1] = {
            text = "      " .. _("Check for updates"),
            mandatory = require("openshelf_updater").runningVersion(),
            callback = function() require("openshelf_updater").check{ manual = true } end,
        }
        t[#t + 1] = {
            text = "      " .. _("Check for updates automatically"),
            mandatory = Settings.updateState().auto and Glyphs.check or "",
            callback = function()
                Settings.setUpdateAuto(not Settings.updateState().auto)
                refresh()
            end,
        }
        t[#t + 1] = {
            text = _("About OpenShelf"),
            callback = function()
                local names = {}
                for __, id in ipairs(Catalog.ids()) do names[#names + 1] = Catalog.nameOf(id) end
                UIManager:show(InfoMessage:new{
                    text = T(_("OpenShelf %1\n\nSearch free & public-domain ebook catalogs and download them on-device.\n\nSources: %2\n\nBooks are saved to:\n%3\n\nOnly DRM-free, openly-licensed books are downloaded in-app."),
                        Version,
                        table.concat(names, ", "),
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
