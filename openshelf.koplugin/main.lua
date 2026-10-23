--[[
OpenShelf — search free & public-domain ebook catalogs and download them
straight onto your device, no PC in the loop.

Flow: main menu -> search box -> aggregated results -> confirm -> download -> read.
Network work is wrapped in Trapper so the UI shows a spinner and stays responsive.
--]]
local Catalog = require("catalog")
local Downloader = require("downloader")
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
        callback = function() self:showSearchDialog() end,
    }
end

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
        local results, errors = Catalog.search(query, 20)
        Trapper:clear()

        if not results or #results == 0 then
            local msg = _("No results found.")
            if errors and #errors > 0 then
                msg = msg .. "\n\n" .. table.concat(errors, "\n")
            end
            UIManager:show(InfoMessage:new{ text = msg })
            return
        end
        self:showResults(query, results)
    end)
end

function OpenShelf:showResults(query, results)
    local menu
    local items = {}
    for _, entry in ipairs(results) do
        table.insert(items, {
            text = T("%1  ·  %2  [%3]",
                entry.title, entry.author or _("Unknown"), entry.source),
            callback = function()
                UIManager:close(menu)
                self:confirmDownload(entry)
            end,
        })
    end
    menu = Menu:new{
        title = T(_("Results for “%1”"), query),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(menu)
end

function OpenShelf:confirmDownload(entry)
    UIManager:show(ConfirmBox:new{
        text = T(_("Download “%1”?\n\nFrom: %2"), entry.title, entry.source),
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

return OpenShelf
