--[[
Scoped search results (DESIGN.md §12.7, decision 78, ticket #21): what a
provider's search_in found in one folder and everything below it, as a
stacked view titled `“sso” in Software Seguro`. It is the paged list
(view_list.lua) fed by Catalog.searchIn, with one provider slot: page 1 is
fetched when the view opens, Load more fetches the rest, each page a job
under the 60 s deadline at the search page size (Results per source: 10, 15
or 30). A failed first page shows the reason and Retry; a failed Load more
shows in the toolbar.

  App.openSearchIn{ provider_id, folder = row|nil (root), folder_title, query }

Rows may be folders: a tap opens a folder view with no folder views below
it, like search. Folder rows show their `path` as the second line. Files
without `path` download flat and folders without `path` get
OpenShelf/<provider name>/<title>/ (openshelf_paths.lua: these rows are not
listed by list()). Results are not cached, not deduped and not added to
recent searches; App.openSearchIn asked for Wi-Fi first.
--]]
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local Folders = require("openshelf_folders")
local Glyphs = require("glyphs")
local Jobs = require("jobs")
local ListView = require("view_list")
local Settings = require("settings")
local ShelfPager = require("shelf_pager")

local SearchInView = ListView:extend{
    provider_id = nil,
    folder = nil,       -- the folder row searched; nil = the provider's root
    query = nil,
}

function SearchInView:setup()
    ListView.setup(self)
    self.limit = Settings.perSource()   -- one page size for the whole search
    self.pager = ShelfPager.new{ page = 0, has_more = true }
    self.entries = self.pager.entries
    self:fetch(self.pager:begin())
end

function SearchInView:fetchPage(page, on_done, on_error)
    local task = Folders.searchTask(self.provider_id, self.folder and self.folder.locator, self.query, self.limit, page)
    return Jobs.runPage(task, on_done, on_error)
end

function SearchInView:countText()
    local n = #self.entries
    return T(N_("1 result", "%1 results", n), n)
end

function SearchInView:loadingText()
    if not self.pager:loaded() then return _("Searching…") end
    return ListView.loadingText(self)
end

function SearchInView:failedText()
    return Glyphs.warning .. " " .. _("failed")
end

function SearchInView:statusDetail(err)
    if not self.pager:loaded() then
        return T(_("Could not search this folder:\n%1\n\nTap Retry to try again."), err)
    end
    return T(_("Could not load more results:\n%1\n\nTap Load more to try again."), err)
end

function SearchInView:emptyText()
    return _("Nothing found.")
end

function SearchInView:failedMessage()
    return _("Could not search this folder.")
end

return SearchInView
