--[[
A folder view (DESIGN.md §12.4, decisions 72–73, 83): one full-screen view
per folder, stacked over whatever opened it. It is the paged See all list
(view_list.lua) fed by the provider's list() instead of browse: page 1 is
fetched when the view opens, 50 rows per page, Load more for the rest, each
page in a job under the 60 s deadline.

  App.openFolder{ provider_id, title, folder = row|nil (root), parent = view|nil }

Title = folder name; a tap on it lists the folder views this one was listed
from (root first, nearest last), and picking one closes every view above it.
A folder opened from home, search, a shelf or See all has none, so the tap
does nothing (#18 adds Refresh there). Back / chevron = up one level (the
list's on_left closes the view), X = leave OpenShelf. Toolbar `N items ·
⚠ failed` (tap for the reason) and list/grid; no filter, a folder has one
source. Empty → "This folder is empty."; a failed first page → a message
and Retry.

The view keeps `folder` (the row it was opened from, nil for a root) and
`parent` (the folder view it was listed from, if any): #19 builds folder
directories from that chain. Not cached yet (#18): every open fetches.
--]]
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local Size = require("ui/size")
local Screen = require("device").screen
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local App = require("app")
local Folders = require("openshelf_folders")
local Glyphs = require("glyphs")
local Jobs = require("jobs")
local ListView = require("view_list")
local ShelfPager = require("shelf_pager")
local P = require("uiparts")

local FolderView = ListView:extend{
    provider_id = nil,
    folder = nil,       -- the folder row this view was opened from; nil = the root
    parent = nil,       -- the folder view it was listed from, if any
    in_folder = true,
}

function FolderView:setup()
    ListView.setup(self)
    self.pager = ShelfPager.new{ page = 0, has_more = true }
    self.entries = self.pager.entries
    self:fetch(self.pager:begin())
end

function FolderView:fetchPage(page, on_done, on_error)
    return Jobs.runPage(Folders.pageTask(self.provider_id, self.folder and self.folder.locator, page),
        on_done, on_error)
end

function FolderView:countText()
    local n = #self.entries
    return T(N_("1 item", "%1 items", n), n)
end

function FolderView:failedText()
    return Glyphs.warning .. " " .. _("failed")
end

function FolderView:statusDetail(err)
    if not self.pager:loaded() then
        return T(_("Could not open this folder:\n%1\n\nTap Retry to try again."), err)
    end
    return T(_("Could not load more of this folder:\n%1\n\nTap Load more to try again."), err)
end

function FolderView:emptyRows()
    local w, pad = self.screen_w, Size.padding.default
    local h = Screen:scaleBySize(60)
    local function line(text)
        return {
            widget = P.row(w, h, P.text(text, 15, { color = P.DARK_GRAY, max_width = w - 2 * pad })),
            h = h, hits = {},
        }
    end
    if self.pager:loaded() then return { line(_("This folder is empty.")) } end
    if not self.pager.err then return { line(_("Loading…")) } end
    local bw, bh = Screen:scaleBySize(120), Screen:scaleBySize(36)
    local bh_row = bh + 2 * pad
    return {
        line(_("Could not open this folder.")),
        {
            widget = P.row(w, bh_row, P.button(_("Retry"), bw, bh, { size = 15 }), { align = "center" }),
            h = bh_row,
            hits = { { x = math.floor((w - bw) / 2), w = bw, on_tap = function() self:loadMore() end } },
        },
    }
end

-- Rows listed here open their folders on top, with this view as their parent.
function FolderView:openEntry(entry)
    App.openEntry(entry, self, self)
end

function FolderView:onTitleTap()
    local ancestors = Folders.ancestors(self)
    if #ancestors == 0 then return end
    local dialog
    local buttons = {}
    for __, v in ipairs(ancestors) do
        buttons[#buttons + 1] = { {
            text = Glyphs.folder .. "  " .. (v.title or ""),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                App.closeAbove(v)
            end,
        } }
    end
    dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(dialog)
end

return FolderView
