--[[
OpenShelf — search free & public-domain ebook catalogs and download them
straight onto your device.

UI map:
  Main menu ▸ OpenShelf
    ├─ Search free ebooks          -> search dialog -> grouped results
    ├─ Sources                     -> per-provider on/off toggles
    ├─ Show cover thumbnails       -> cover view (default) / plain text list
    └─ About
  Results view (grouped by action; both views end with the same footer note for
  merged duplicates + source errors, tap it for details):
    ⬇ Download  -> confirm (or "already downloaded": open / re-download)
                   -> download (progress) -> read
    📚 Borrow / 🛒 Buy             -> reserved; handoff info (no sources yet)

Network work is wrapped in Trapper so the UI shows a spinner and stays responsive.
--]]
local Catalog = require("catalog")
local Downloader = require("downloader")
local Settings = require("settings")
local CoverBrowser = require("coverbrowser")
local Version = require("openshelf_version")
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
            text = _("Show cover thumbnails"),
            checked_func = function() return Settings.coversEnabled() end,
            callback = function()
                Settings.setCoversEnabled(not Settings.coversEnabled())
            end,
            keep_menu_open = true,
        },
        {
            text = _("About OpenShelf"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("OpenShelf %1\n\nSearch free & public-domain ebook catalogs and download them on-device.\n\nSources: %2\n\nBooks are saved to:\n%3\n\nOnly DRM-free, openly-licensed books are downloaded in-app."),
                        Version,
                        table.concat(Catalog.providerNames(), ", "),
                        Downloader.dirPath()),
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
    for __, name in ipairs(Catalog.providerNames()) do
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

-- Footer shared by both results views: merged duplicates + source errors.
-- Returns (note, detail) — note is the one-liner, detail what a tap shows —
-- or nil when there is nothing to report.
local function resultNotes(errors, collapsed)
    local notes = {}
    if collapsed and collapsed > 0 then
        notes[#notes + 1] = T(_("%1 duplicate edition(s) merged"), collapsed)
    end
    if errors and #errors > 0 then
        notes[#notes + 1] = T(_("⚠ %1 source(s) errored — tap for details"), #errors)
    end
    if #notes == 0 then return nil end
    local detail = (errors and #errors > 0)
        and (_("Sources that errored:") .. "\n\n" .. table.concat(errors, "\n"))
        or _("No source errors.")
    return table.concat(notes, "   ·   "), detail
end

function OpenShelf:showResults(query, entries, errors, collapsed)
    if Settings.coversEnabled() then
        self:showResultsCovers(query, entries, errors, collapsed)
    else
        self:showResultsText(query, entries, errors, collapsed)
    end
end

-- Cover-thumbnail results view (custom widget).
function OpenShelf:showResultsCovers(query, entries, errors, collapsed)
    local note, detail = resultNotes(errors, collapsed)
    local browser
    browser = CoverBrowser:new{
        results_title = T(_("“%1” — %2 results"), query, #entries),
        groups = Catalog.group(entries),
        footer_note = note,
        footer_detail = detail,
        on_select = function(entry)
            UIManager:close(browser)
            if entry.action == "download" then
                self:confirmDownload(entry)
            else
                self:showHandoff(entry)
            end
        end,
    }
    UIManager:show(browser)
end

-- Plain text results view (fallback when cover thumbnails are off).
function OpenShelf:showResultsText(query, entries, errors, collapsed)
    local menu
    local items = {}
    local groups = Catalog.group(entries)

    for __, group in ipairs(groups) do
        -- group header (non-selectable)
        items[#items + 1] = {
            text = T("%1  (%2)", group.heading, #group.items),
            bold = true,
            enabled_func = function() return false end,
        }
        for ___, entry in ipairs(group.items) do
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

    local note, detail = resultNotes(errors, collapsed)
    if note then
        items[#items + 1] = {
            text = note,
            dim = true,
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{ text = detail })
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
    local existing = Downloader.exists(entry)
    if existing then
        UIManager:show(ConfirmBox:new{
            text = T(_("Already downloaded:\n%1\n\nOpen it?"), existing),
            ok_text = _("Open"),
            ok_callback = function() self:openBook(existing) end,
            other_buttons = {{
                {
                    text = _("Download again"),
                    callback = function() self:doDownload(entry) end,
                },
            }},
        })
        return
    end
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
            ok_callback = function() self:openBook(path) end,
        })
    end)
end

function OpenShelf:openBook(path)
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
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
