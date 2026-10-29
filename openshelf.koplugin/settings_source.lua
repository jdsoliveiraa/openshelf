--[[
One source's submenu (PROVIDERS.md §7, DESIGN.md §9.5, decisions 51–52):

  Enabled · the provider's declared fields (text, secret, toggle, choice; a
  dim hint row under each that has one) · Test connection when the provider
  defines check · Shelves on home when the provider declares shelves
  (default on; off hides its home shelves, never its search slot)

  SourceMenu.row(provider, refresh) -> the item for the Sources list in
                                       settings_menu.lua (name + state)
  SourceMenu.show(provider, opts)   -> push the submenu; opts.on_close

A required field left empty puts the source in Needs setup: its Sources row
says so, it is skipped from search (Settings.enabledIds), and opening it lands
on the empty field. Values are saved under provider_settings[id] (plain text)
and reach the provider as ctx.settings (catalog.lua).
--]]
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local _ = require("gettext")

local Catalog = require("catalog")
local Fields = require("openshelf_fields")
local Glyphs = require("glyphs")
local Jobs = require("jobs")
local Settings = require("settings")

local SourceMenu = {}

local INDENT = "      "
local HINT_INDENT = "         "
local MASK = string.rep(Glyphs.utf8(0x2022), 8)   -- fixed length: never leaks the secret's
local MAX_VALUE = 18                               -- bytes of a text value in the right column
local TOAST_SECONDS = 4

local function shorten(s)
    if #s <= MAX_VALUE then return s end
    -- cut on a UTF-8 boundary
    local cut = MAX_VALUE
    while cut > 1 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do
        cut = cut - 1
    end
    return s:sub(1, cut) .. "…"
end

-- Right-column text for a field, from the effective values (defaults applied).
local function shown_value(field, value)
    if field.type == "toggle" then return value and Glyphs.check or "" end
    if value == nil then return field.required and _("Required") or "" end
    if field.type == "secret" then return MASK end
    return shorten(tostring(value))
end

--- Item for the Sources list: tapping opens the submenu. The right column
-- reads "Needs setup", a check mark (enabled) or nothing (disabled).
function SourceMenu.row(provider, refresh)
    local mandatory = ""
    if Settings.isEnabled(provider) then
        mandatory = Settings.needsSetup(provider) and _("Needs setup") or Glyphs.check
    end
    return {
        text = INDENT .. provider.name,
        mandatory = mandatory,
        callback = function()
            SourceMenu.show(provider, { on_close = refresh })
        end,
    }
end

local function edit_text(provider, field, refresh)
    local current = Settings.providerSettings(provider.id)[field.key]
    if type(current) ~= "string" then current = field.default or "" end
    local dialog
    dialog = InputDialog:new{
        title = field.title,
        input = current,
        input_hint = field.required and _("Required") or "",
        description = field.hint,
        text_type = field.type == "secret" and "password" or nil,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                id = "save",
                is_enter_default = true,
                callback = function()
                    local v = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(dialog)
                    -- An explicit empty value stays empty (nil in ctx.settings), even over a default.
                    Settings.setProviderSetting(provider.id, field.key, v)
                    refresh()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local testing = {}   -- provider id -> true while its check job runs

local function test_connection(provider)
    if testing[provider.id] then return end
    testing[provider.id] = true
    local waiting = InfoMessage:new{ text = _("Testing connection…") }
    UIManager:show(waiting)
    local function finish(text)
        testing[provider.id] = nil
        UIManager:close(waiting)
        UIManager:show(InfoMessage:new{ text = text, timeout = TOAST_SECONDS })
    end
    -- Inline jobs run on the next tick, so the waiting message is painted first.
    Jobs.run{
        task = function()
            local ok, message = Catalog.check(provider.id)
            return { ok = ok, message = message }
        end,
        timeout = Jobs.DEADLINE,
        on_done = function(r)
            r = type(r) == "table" and r or {}
            finish(tostring(r.message or (r.ok and _("Connection OK") or _("Connection failed"))))
        end,
        on_error = function(err)
            finish(_("Connection failed: ") .. tostring(err))
        end,
    }
end

local function items_for(provider, refresh)
    local t = {}
    t[#t + 1] = {
        text = _("Enabled"),
        mandatory = Settings.isEnabled(provider) and Glyphs.check or "",
        callback = function()
            Settings.toggle(provider)
            refresh()
        end,
    }
    local values = Settings.values(provider)
    for __, f in ipairs(provider.settings or {}) do
        local field = f
        local callback
        if field.type == "toggle" then
            callback = function()
                Settings.setProviderSetting(provider.id, field.key, not values[field.key])
                refresh()
            end
        elseif field.type == "choice" then
            callback = function()
                Settings.setProviderSetting(provider.id, field.key, Fields.nextChoice(field, values[field.key]))
                refresh()
            end
        else
            callback = function() edit_text(provider, field, refresh) end
        end
        t[#t + 1] = {
            text = field.title,
            mandatory = shown_value(field, values[field.key]),
            callback = callback,
        }
        if field.hint and field.hint ~= "" then
            t[#t + 1] = { text = HINT_INDENT .. field.hint, dim = true, select_enabled = false }
        end
    end
    if type(provider.check) == "function" then
        t[#t + 1] = {
            text = _("Test connection"),
            callback = function() test_connection(provider) end,
        }
    end
    if type(provider.shelves) == "table" and #provider.shelves > 0 then
        t[#t + 1] = {
            text = _("Shelves on home"),
            mandatory = Settings.shelvesOnHome(provider) and Glyphs.check or "",
            callback = function()
                Settings.setShelvesOnHome(provider, not Settings.shelvesOnHome(provider))
                refresh()
            end,
        }
    end
    return t
end

function SourceMenu.show(provider, opts)
    opts = opts or {}
    local menu
    local function refresh()
        menu:switchItemTable(nil, items_for(provider, refresh))
    end
    menu = Menu:new{
        title = provider.name,
        item_table = items_for(provider, refresh),   -- refresh only runs on a tap, once menu exists
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
    -- Needs setup: land on the empty field (text/secret open their input;
    -- a choice is one tap away in the list).
    local missing = Settings.needsSetup(provider)
    if missing then
        for __, field in ipairs(provider.settings or {}) do
            if field.key == missing and (field.type == "text" or field.type == "secret") then
                edit_text(provider, field, refresh)
            end
        end
    end
    return menu
end

return SourceMenu
