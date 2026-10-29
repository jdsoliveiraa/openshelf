--[[
Filter dialog for results (DESIGN.md decision 12): a checkbox per source and
a format row (Any / EPUB / PDF). Applies instantly; no sort.
Built on KOReader's ButtonDialog: each tap rebuilds the dialog with the new
state so the check marks stay current.
--]]
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Glyphs = require("glyphs")

local FilterDialog = {}

local FORMATS = {
    { "any",  _("Any format") },
    { "epub", "EPUB" },
    { "pdf",  "PDF" },
}

-- opts.sources (ordered list of { id = provider id, name = display name }),
-- opts.selected (set of ids, or nil = all), opts.format,
-- opts.on_change(filter) with filter = { sources = id set|nil, format = string }
function FilterDialog.show(opts)
    local selected = {}
    for __, src in ipairs(opts.sources) do
        selected[src.id] = (opts.selected == nil) or (opts.selected[src.id] == true)
    end
    local format = opts.format or "any"
    local dialog

    local function emit()
        local all = true
        local set = {}
        for __, src in ipairs(opts.sources) do
            if selected[src.id] then set[src.id] = true else all = false end
        end
        opts.on_change({ sources = (not all) and set or nil, format = format })
    end

    local build
    local function reopen()
        UIManager:close(dialog)
        emit()
        dialog = build()
        UIManager:show(dialog)
    end

    build = function()
        local rows = {}
        for __, src in ipairs(opts.sources) do
            local id = src.id
            rows[#rows + 1] = { {
                text = (selected[id] and Glyphs.check or "    ") .. "   " .. src.name,
                align = "left",
                callback = function()
                    selected[id] = not selected[id]
                    reopen()
                end,
            } }
        end
        local frow = {}
        for __, f in ipairs(FORMATS) do
            local key = f[1]
            frow[#frow + 1] = {
                text = (format == key and (Glyphs.check .. " ") or "") .. f[2],
                callback = function()
                    format = key
                    reopen()
                end,
            }
        end
        rows[#rows + 1] = frow
        rows[#rows + 1] = {
            {
                text = _("Reset"),
                callback = function()
                    for __, src in ipairs(opts.sources) do selected[src.id] = true end
                    format = "any"
                    reopen()
                end,
            },
            {
                text = _("Done"),
                callback = function() UIManager:close(dialog) end,
            },
        }
        return ButtonDialog:new{ title = _("Filter results"), buttons = rows }
    end

    dialog = build()
    UIManager:show(dialog)
end

return FilterDialog
