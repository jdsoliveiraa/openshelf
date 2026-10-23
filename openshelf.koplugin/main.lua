--[[
OpenShelf — search free & public-domain ebook catalogs and download them
straight onto your device.

UI map:
  Main menu ▸ OpenShelf
    ├─ Search free ebooks          -> search dialog -> grouped results
    ├─ Sources                     -> per-provider on/off toggles
    └─ About
  Results view (grouped by action):
    ⬇ Download  -> confirm -> download (progress) -> read
    📚 Borrow / 🛒 Buy             -> reserved; handoff info (no sources yet)

Network work is wrapped in Trapper so the UI shows a spinner and stays responsive.
--]]
local Catalog = require("catalog")
local Downloader = require("downloader")
local Settings = require("settings")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = require("device").screen
local _ = require("gettext")
local T = require("ffi/util").template

local OpenShelf = WidgetContainer:extend{
    name = "openshelf",
    is_doc_only = false,
}

function OpenShelf:init()
    self.ui.menu:registerToMainMenu(self)
end

function OpenShelf:addToMainMenu(menu_items)
    menu_items.openshelf = {
        text = _("OpenShelf"),
        sub_item_table_func = function() return self:mainMenu() end,
    }
end

function OpenShelf:mainMenu()
    return {
        {
            text = _("Search free ebooks"),
            keep_menu_open = false,
            callback = function() self:showSearchDialog() end,
        },
        {
            text = _("Sources"),
            sub_item_table_func = function() return self:sourcesMenu() end,
        },
        {
            text = _("About OpenShelf"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("OpenShelf\n\nSearch free & public-domain ebook catalogs and download them on-device.\n\nSources: Standard Ebooks, Project Gutenberg, Feedbooks, Internet Archive, DOAB.\n\nOnly DRM-free, openly-licensed books are downloaded in-app."),
                })
            end,
        },
    }
end

---------------------------------------------------------------------------
-- Sources toggle screen
---------------------------------------------------------------------------
function OpenShelf:sourcesMenu()
    local items = {}
    for _, name in ipairs(Catalog.providerNames()) do
        items[#items + 1] = {
            text = name,
            checked_func = function() return Settings.isEnabled(name) end,
            callback = function() Settings.toggle(name) end,
            keep_menu_open = true,
        }
    end
    return items
end

---------------------------------------------------------------------------
-- Search
---------------------------------------------------------------------------
function OpenShelf:showSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("OpenShelf — search free ebooks"),
        input = "",
        input_hint = _("Title, author, keyword…"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = dialog:getInputText()
                    UIManager:close(dialog)
                    if query and query ~= "" then
                        self:runSearch(query)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function OpenShelf:runSearch(query)
    Trapper:wrap(function()
        Trapper:info(T(_("Searching for “%1”…"), query))
        local enabled = Settings.enabledSet(Catalog.providerNames())
        local entries, errors, collapsed =
            Catalog.search(query, { enabled = enabled, per_provider = 15 })
        Trapper:clear()

        if not entries or #entries == 0 then
            local msg = _("No results found.")
            if errors and #errors > 0 then
                msg = msg .. "\n\n" .. _("Some sources errored:") .. "\n" ..
                    table.concat(errors, "\n")
            end
            UIManager:show(InfoMessage:new{ text = msg })
            return
        end
        self:showResults(query, entries, errors, collapsed)
    end)
end

---------------------------------------------------------------------------
-- Results (grouped by action)
---------------------------------------------------------------------------
function OpenShelf:showResults(query, entries, errors, collapsed)
    local menu
    local items = {}
    local groups = Catalog.group(entries)

    for _, group in ipairs(groups) do
        -- group header (non-selectable)
        items[#items + 1] = {
            text = T("%1  (%2)", group.heading, #group.items),
            bold = true,
            enabled_func = function() return false end,
        }
        for _, entry in ipairs(group.items) do
            local e = entry
            items[#items + 1] = {
                text = T("%1 — %2", e.title, e.author or _("Unknown")),
                mandatory = e.source,
                callback = function()
                    UIManager:close(menu)
                    if e.action == "download" then
                        self:confirmDownload(e)
                    else
                        self:showHandoff(e)
                    end
                end,
            }
        end
    end

    -- footer note: collapsed duplicates + source errors
    local notes = {}
    if collapsed and collapsed > 0 then
        notes[#notes + 1] = T(_("%1 duplicate edition(s) merged"), collapsed)
    end
    if errors and #errors > 0 then
        notes[#notes + 1] = T(_("⚠ %1 source(s) errored — tap for details"), #errors)
    end
    if #notes > 0 then
        items[#items + 1] = {
            text = table.concat(notes, "   ·   "),
            dim = true,
            keep_menu_open = true,
            callback = function()
                local msg = (errors and #errors > 0)
                    and (_("Sources that errored:") .. "\n\n" .. table.concat(errors, "\n"))
                    or _("No source errors.")
                UIManager:show(InfoMessage:new{ text = msg })
            end,
        }
    end

    menu = Menu:new{
        title = T(_("“%1” — %2 results"), query, #entries),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(menu)
end

---------------------------------------------------------------------------
-- Download → read
---------------------------------------------------------------------------
function OpenShelf:confirmDownload(entry)
    UIManager:show(ConfirmBox:new{
        text = T(_("Download “%1”?\n\nBy: %2\nFrom: %3  (%4)"),
            entry.title, entry.author or _("Unknown"),
            entry.source, (entry.format or "epub"):upper()),
        ok_text = _("Download"),
        ok_callback = function() self:doDownload(entry) end,
    })
end

function OpenShelf:doDownload(entry)
    Trapper:wrap(function()
        Trapper:info(T(_("Downloading “%1”…"), entry.title))
        local path, err = Downloader.download(entry)
        Trapper:clear()

        if not path then
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed:\n%1"), tostring(err)),
            })
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("Saved to:\n%1\n\nOpen now?"), path),
            ok_text = _("Read"),
            ok_callback = function()
                local ReaderUI = require("apps/reader/readerui")
                ReaderUI:showReader(path)
            end,
        })
    end)
end

---------------------------------------------------------------------------
-- Borrow / Buy handoff (reserved — no such sources yet)
---------------------------------------------------------------------------
function OpenShelf:showHandoff(entry)
    local verb = entry.action == "borrow" and _("borrow") or _("buy")
    UIManager:show(InfoMessage:new{
        text = T(_("“%1” is available to %2 via %3.\n\nThis book is DRM-protected, so it can't be opened in OpenShelf — complete it in the Kobo/Libby app."),
            entry.title, verb, entry.source),
    })
end

return OpenShelf
