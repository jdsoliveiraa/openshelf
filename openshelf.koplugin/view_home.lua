--[[
The home screen (DESIGN.md §2.2) and, in the same widget, the results screen
(§2.3): a search lands its rows in this view's body so the query stays one
tap away and "back" returns to the shelves.

Modes:
  "home"    — search row, recent searches, My books shelf, browse shelves
  "results" — toolbar strip (status · filter · list/grid), rows, load more
--]]
local ConfirmBox = require("ui/widget/confirmbox")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Size = require("ui/size")
local Screen = require("device").screen
local _ = require("gettext")
local T = require("ffi/util").template

local App = require("app")
local Browse = require("browse")
local Catalog = require("catalog")
local Covers = require("covers")
local Downloader = require("downloader")
local Entry = require("entry")
local Glyphs = require("glyphs")
local Library = require("library")
local Pane = require("pane_results")
local Searcher = require("searcher")
local Settings = require("settings")
local Shelf = require("widget_shelf")
local ViewBase = require("view_base")
local P = require("uiparts")

local HomeView = ViewBase:extend{
    ui = nil,
}

function HomeView:setup()
    self.mode = "home"
    self.view_mode = Settings.defaultView()
    self.filter = { sources = nil, format = "any" }
    self.entries = {}
    self.collapsed = 0
    self.page_entries = {}
    self.wanted_covers = {}
    self.browse_requested = {}
    self.browse_failed = {}
    self.dl_listener = function(event, entry, state) self:onDownloadEvent(event, entry, state) end
    Downloader.subscribe(self.dl_listener)
    App.push(self)
end

function HomeView:teardown()
    Downloader.unsubscribe(self.dl_listener)
    if self.searcher then self.searcher:cancel(); self.searcher = nil end
    if self.cover_job then self.cover_job:cancel(); self.cover_job = nil end
    Covers.freeAll()
    App.pop(self)
end

function HomeView:titleBarSpec()
    if self.mode == "results" then
        return {
            title = self.query or "",
            left_icon = "chevron.left",
            on_left = function() self:goHome() end,
        }
    end
    return {
        title = _("OpenShelf"),
        left_icon = "appbar.settings",
        on_left = function() self:openSettings() end,
    }
end

function HomeView:onTitleTap()
    self:openSearchDialog(self.mode == "results" and self.query or nil)
end

function HomeView:onBack()
    if self.mode == "results" then self:goHome() else UIManager:close(self) end
end

function HomeView:onExit()
    App.exitAll()
end

function HomeView:buildRows()
    if self.mode == "results" then return self:resultsRows() end
    return self:homeRows()
end

function HomeView:onPageBuilt()
    self:prefetchCovers(self.wanted_covers or {})
end

function HomeView:prefetchCovers(urls)
    if self.cover_job or #urls == 0 then return end
    self.cover_job = Covers.fetch(urls, function(got)
        self.cover_job = nil
        if #got > 0 then self:rebuild() end
    end)
end

---------------------------------------------------------------------------
-- Home mode
---------------------------------------------------------------------------
function HomeView:sectionRow(title)
    local h = Screen:scaleBySize(26)
    return {
        widget = P.row(self.screen_w, h, P.text(title, 13, { color = P.DARK_GRAY, bold = true })),
        h = h, hits = {}, keep_with_next = true,
    }
end

function HomeView:searchRow()
    local w, pad = self.screen_w, Size.padding.default
    local sh = Screen:scaleBySize(44)
    local b = Size.border.default
    local inner_w, inner_h = w - 2 * pad - 2 * b, sh - 2 * b
    local has_query = self.query and self.query ~= ""
    local label = has_query and self.query or _("Search free ebooks…")
    local glyph = P.text(Glyphs.search, 16, { color = P.DARK_GRAY })
    local glyph_w = glyph:getSize().w
    local field = FrameContainer:new{
        bordersize = b, padding = 0, margin = 0, radius = Screen:scaleBySize(6),
        color = P.GRAY, background = P.WHITE,
        P.box(inner_w, inner_h, HorizontalGroup:new{
            align = "center",
            P.hspace(pad * 2), glyph, P.hspace(pad * 2),
            P.text(label, 16, {
                color = has_query and P.BLACK or P.DARK_GRAY,
                max_width = inner_w - 5 * pad - glyph_w,
            }),
        }),
    }
    local row_h = sh + 2 * pad
    return {
        widget = P.row(w, row_h, field, { pad = pad }),
        h = row_h,
        hits = { { on_tap = function() self:openSearchDialog(self.query) end } },
    }
end

function HomeView:recentRows()
    local rows = {}
    local recents = Settings.recents()
    if #recents == 0 then return rows end
    local w, pad = self.screen_w, Size.padding.default
    rows[#rows + 1] = self:sectionRow(_("Recent searches"))
    local chip_h = Screen:scaleBySize(34)
    local gap = Screen:scaleBySize(8)
    local chip_w = math.floor((w - 2 * pad - gap) / 2)
    local tb = Size.border.thin
    local hglyph_w = P.textWidth(Glyphs.history, 13)
    for r = 1, math.ceil(#recents / 2) do
        local cells, hits = {}, {}
        for c = 1, 2 do
            local q = recents[(r - 1) * 2 + c]
            if q then
                cells[#cells + 1] = FrameContainer:new{
                    bordersize = tb, color = P.GRAY, radius = Screen:scaleBySize(6),
                    padding = 0, margin = 0, background = P.WHITE,
                    P.box(chip_w - 2 * tb, chip_h - 2 * tb, HorizontalGroup:new{
                        align = "center",
                        P.hspace(pad), P.text(Glyphs.history, 13, { color = P.DARK_GRAY }), P.hspace(pad),
                        P.text(q, 14, { max_width = chip_w - 2 * tb - 3 * pad - hglyph_w }),
                    }),
                }
                if c == 1 then cells[#cells + 1] = P.hspace(gap) end
                hits[#hits + 1] = {
                    x = pad + (c - 1) * (chip_w + gap), w = chip_w,
                    on_tap = function() self:runSearch(q) end,
                    on_hold = function() self:confirmRemoveRecent(q) end,
                }
            end
        end
        local rh = chip_h + gap
        rows[#rows + 1] = {
            widget = P.row(w, rh, HorizontalGroup:new{ align = "center", unpack(cells) }, { pad = pad }),
            h = rh, hits = hits,
        }
    end
    return rows
end

function HomeView:homeRows()
    local rows = { self:searchRow() }
    local urls, visible = {}, {}
    local function add_shelf(shelf_rows, entries)
        for __, r in ipairs(shelf_rows) do rows[#rows + 1] = r end
        for __, e in ipairs(Shelf.visible(self, entries)) do
            visible[#visible + 1] = e
            if e.cover_url then urls[#urls + 1] = e.cover_url end
        end
    end

    for __, r in ipairs(self:recentRows()) do rows[#rows + 1] = r end

    -- My books
    local lib = App.library()
    if lib:count() > 0 then
        local entries = {}
        for i, rec in ipairs(lib:all()) do
            if i > 12 then break end
            entries[#entries + 1] = Library.toEntry(rec)
        end
        add_shelf(Shelf.rows(self, {
            title = _("My books"), entries = entries,
            on_see_all = function() self:openMyBooks() end,
            on_tap = function(e) self:openDetail(e) end,
            status = function(e) return App.bookStatus(e) end,
        }), entries)
    end

    -- Browse shelves of enabled, set-up sources with "Shelves on home" on, in
    -- source order (Settings.homeShelves; cached under "<provider id>:<key>",
    -- refreshed in the background when stale)
    for __, shelf in ipairs(Settings.homeShelves()) do
        local entries, stale = Browse.get(shelf.id)
        if (not entries or stale) and not self.browse_requested[shelf.id] and NetworkMgr:isConnected() then
            self.browse_requested[shelf.id] = true
            Browse.refresh(shelf.id, function(res)
                if not res then self.browse_failed[shelf.id] = true end
                if self.mode == "home" then self:rebuild() end
            end)
        end
        if entries and #entries > 0 then
            add_shelf(Shelf.rows(self, {
                title = shelf.title, entries = entries, mark_downloaded = true,
                on_see_all = function() self:openList(shelf.title, entries) end,
                on_tap = function(e) self:openDetail(e) end,
                on_hold = function(e) App.holdDownload(e, self) end,
                status = function(e) return App.bookStatus(e) end,
            }), entries)
        elseif self.browse_requested[shelf.id] and not self.browse_failed[shelf.id] then
            rows[#rows + 1] = Shelf.header(self, shelf.title, nil)
            local h = Screen:scaleBySize(36)
            rows[#rows + 1] = {
                widget = P.row(self.screen_w, h, P.text(_("Loading…"), 14, { color = P.DARK_GRAY })),
                h = h, hits = {},
            }
        end
    end

    if #rows == 1 then
        local h = Screen:scaleBySize(70)
        rows[#rows + 1] = {
            widget = P.row(self.screen_w, h, P.text(_("Search for a title, author or keyword to get started."), 14,
                { color = P.DARK_GRAY, max_width = self.screen_w - 2 * Size.padding.default })),
            h = h, hits = {},
        }
    end

    self.page_entries = visible
    self.wanted_covers = urls
    return rows
end

function HomeView:confirmRemoveRecent(q)
    UIManager:show(ConfirmBox:new{
        text = T(_("Remove “%1” from recent searches?"), q),
        ok_text = _("Remove"),
        ok_callback = function()
            Settings.removeRecent(q)
            self:rebuild()
        end,
    })
end

---------------------------------------------------------------------------
-- Results mode
---------------------------------------------------------------------------
function HomeView:isSearching()
    return self.searcher ~= nil and self.searcher:isSearching()
end

function HomeView:filterActive()
    return self.filter.sources ~= nil or (self.filter.format ~= nil and self.filter.format ~= "any")
end

function HomeView:activeFilter()
    if not self:filterActive() then return nil end
    return self.filter
end

function HomeView:statusLine()
    local parts = {}
    local n = #self.entries
    if self:isSearching() then
        if n > 0 then parts[#parts + 1] = T(_("%1 so far"), n) end
        local pending = {}
        for i, id in ipairs(self.results and self.results:pending() or {}) do
            pending[i] = Catalog.nameOf(id) or id
        end
        parts[#parts + 1] = T(_("Searching %1…"), table.concat(pending, ", "))
    else
        parts[#parts + 1] = T(_("%1 results"), n)
    end
    if self.results then
        local errs = self.results:errors(Catalog.nameOf)
        if #errs > 0 then parts[#parts + 1] = Glyphs.warning .. " " .. T(_("%1 failed"), #errs) end
    end
    if self.collapsed and self.collapsed > 0 then
        parts[#parts + 1] = T(_("%1 merged"), self.collapsed)
    end
    return table.concat(parts, "  ·  ")
end

function HomeView:showStatusDetail()
    if not self.results then return end
    local lines = {}
    local errs = self.results:errors(Catalog.nameOf)
    if #errs > 0 then
        lines[#lines + 1] = _("Sources that failed:") .. "\n" .. table.concat(errs, "\n")
    end
    if self.collapsed and self.collapsed > 0 then
        lines[#lines + 1] = T(_("%1 duplicate edition(s) merged into the best available one."), self.collapsed)
    end
    if #lines == 0 then lines[1] = _("All sources answered.") end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n\n") })
end

function HomeView:resultsRows()
    local rows = {}
    local w, pad = self.screen_w, Size.padding.default

    -- toolbar strip: status · filter · list/grid
    local tb_h = Screen:scaleBySize(36)
    local btn_w = Screen:scaleBySize(44)
    local left_w = w - 2 * pad - 2 * btn_w - pad
    local toolbar = HorizontalGroup:new{
        align = "center",
        P.box(left_w, tb_h, P.text(self:statusLine(), 13, { color = P.DARK_GRAY, max_width = left_w })),
        P.hspace(pad),
        P.glyphButton(Glyphs.filter, btn_w, tb_h, { color = self:filterActive() and P.BLACK or P.DARK_GRAY }),
        P.glyphButton(self.view_mode == "grid" and Glyphs.list or Glyphs.grid, btn_w, tb_h),
    }
    rows[#rows + 1] = {
        widget = P.row(w, tb_h, toolbar, { pad = pad, line = true }),
        h = tb_h,
        hits = {
            { x = 0, w = pad + left_w, on_tap = function() self:showStatusDetail() end },
            { x = w - pad - 2 * btn_w, w = btn_w, on_tap = function() self:openFilter() end },
            { x = w - pad - btn_w, w = btn_w, on_tap = function() self:toggleView() end },
        },
    }

    local footer_h = Screen:scaleBySize(40)
    local avail = self.content_h - tb_h - footer_h
    local prows, total, page_entries = Pane.rows(self, self.entries, {
        mode = self.view_mode, page = self.page, avail_h = avail,
        status = function(e) return App.bookStatus(e) end,
        on_tap = function(e) self:openDetail(e) end,
        on_hold = function(e) App.holdDownload(e, self) end,
    })
    self.total_pages = total
    if self.page > total then self.page = total end
    self.page_entries = page_entries
    for __, r in ipairs(prows) do rows[#rows + 1] = r end

    if #self.entries == 0 then
        local h = Screen:scaleBySize(60)
        local msg
        if self:isSearching() then
            msg = _("Searching…")
        elseif self:filterActive() then
            msg = _("Nothing matches the current filter.")
        else
            msg = _("No results found.")
        end
        rows[#rows + 1] = {
            widget = P.row(w, h, P.text(msg, 15, { color = P.DARK_GRAY, max_width = w - 2 * pad })),
            h = h, hits = {},
        }
    end

    -- footer: page label, "Load more" on the last page
    local label
    if total > 1 then
        label = T(_("Page %1 of %2"), self.page, total)
    elseif #self.entries > 0 then
        label = T(_("%1 results"), #self.entries)
    else
        label = ""
    end
    local items = { P.text(label, 13, { color = P.DARK_GRAY }) }
    local hits = {}
    local can_load = self.results and self.results:hasMore() and not self:isSearching()
        and self.page == total
    if can_load then
        local bw, bh = Screen:scaleBySize(120), Screen:scaleBySize(32)
        local lw = items[1]:getSize().w
        items[#items + 1] = P.hspace(math.max(0, w - 2 * pad - lw - bw))
        items[#items + 1] = P.button(_("Load more"), bw, bh, { size = 14 })
        hits[#hits + 1] = { x = w - pad - bw, w = bw, on_tap = function() self:loadMore() end }
    end
    rows[#rows + 1] = {
        widget = P.row(w, footer_h, HorizontalGroup:new{ align = "center", unpack(items) }, { pad = pad }),
        h = footer_h, hits = hits,
    }

    self.wanted_covers = Pane.coverUrls(page_entries)
    return rows
end

---------------------------------------------------------------------------
-- Search
---------------------------------------------------------------------------
function HomeView:openSearchDialog(prefill)
    local dialog
    dialog = InputDialog:new{
        title = _("Search free ebooks"),
        input = prefill or "",
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
                    local q = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(dialog)
                    if q ~= "" then self:runSearch(q) end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function HomeView:runSearch(query)
    NetworkMgr:runWhenOnline(function() self:startSearch(query) end)
end

function HomeView:startSearch(query)
    local ids = Settings.enabledIds(Settings.orderedProviders())
    if #ids == 0 then
        UIManager:show(InfoMessage:new{ text = _("All sources are disabled. Enable one in settings.") })
        return
    end
    if self.searcher then self.searcher:cancel() end
    Settings.addRecent(query)
    self.query = query
    self.mode = "results"
    self.self_paged = true
    self.page = 1
    self.entries, self.collapsed, self.results = {}, 0, nil
    self.searcher = Searcher.new{
        query = query, ids = ids, per_source = Settings.perSource(),
        on_update = function(results) self:onResults(results) end,
        on_complete = function(results) self:onResults(results) end,
    }
    self.searcher:start()
    self:rebuild("partial")
end

function HomeView:onResults(results)
    if self.mode ~= "results" then return end
    self.results = results
    self.entries, self.collapsed = results:flatten(self:activeFilter())
    self:rebuild()
end

function HomeView:goHome()
    if self.searcher then self.searcher:cancel(); self.searcher = nil end
    self.mode = "home"
    self.self_paged = false
    self.page = 1
    self.results, self.entries, self.collapsed = nil, {}, 0
    self:rebuild("partial")
end

function HomeView:toggleView()
    self.view_mode = self.view_mode == "grid" and "list" or "grid"
    self.page = 1
    self:rebuild("partial")
end

function HomeView:loadMore()
    if not self.searcher then return end
    NetworkMgr:runWhenOnline(function()
        self.searcher:loadMore()
        self:rebuild()
    end)
end

function HomeView:openFilter()
    local FilterDialog = require("dialog_filter")
    local sources = {}
    for __, id in ipairs(Settings.enabledIds(Settings.orderedProviders())) do
        sources[#sources + 1] = { id = id, name = Catalog.nameOf(id) or id }
    end
    FilterDialog.show{
        sources = sources,
        selected = self.filter.sources,
        format = self.filter.format,
        on_change = function(f)
            self.filter = f
            self.page = 1
            if self.results then self:onResults(self.results) else self:rebuild() end
        end,
    }
end

---------------------------------------------------------------------------
-- Navigation to other screens
---------------------------------------------------------------------------
function HomeView:openDetail(entry)
    local DetailView = require("view_detail")
    UIManager:show(DetailView:new{ entry = entry, on_change = function() self:rebuild() end })
end

function HomeView:openMyBooks()
    local MyBooksView = require("view_mybooks")
    UIManager:show(MyBooksView:new{ on_change = function() self:rebuild() end })
end

function HomeView:openList(title, entries)
    local ListView = require("view_list")
    UIManager:show(ListView:new{ title = title, entries = entries, on_change = function() self:rebuild() end })
end

function HomeView:openSettings()
    local SettingsMenu = require("settings_menu")
    SettingsMenu.show{ on_close = function() self:rebuild() end }
end

---------------------------------------------------------------------------
-- Downloads
---------------------------------------------------------------------------
function HomeView:isOnPage(entry)
    local id = Entry.id(entry)
    for __, e in ipairs(self.page_entries or {}) do
        if Entry.id(e) == id then return true end
    end
    return false
end

function HomeView:onDownloadEvent(event, entry, state)
    if event == "progress" then
        if self:isOnPage(entry) and App.progressWorthRepaint(self, entry, state) then
            self:rebuild()
        end
        return
    end
    if event == "error" then
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed: %1\n\n%2"), entry.title or "", state and state.err or ""),
        })
    end
    self:rebuild()
end

return HomeView
