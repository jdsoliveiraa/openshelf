--[[
Book detail page (DESIGN.md §2.4): large cover, title, author, one metadata
line (only what the provider returned), scrollable description, and the
primary action — Download → progress with Cancel → Open / Done. Opens over
the results, which survive underneath.

Borrow rows run the same pipeline behind a "Borrow" button; buy rows
(decision 49) show the store page as text plus a QR code (KOReader's
QRMessage) and never download — the price joins the metadata line.
--]]
local ConfirmBox = require("ui/widget/confirmbox")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local Screen = require("device").screen
local _ = require("gettext")
local T = require("ffi/util").template

local App = require("app")
local Covers = require("covers")
local Downloader = require("downloader")
local Entry = require("entry")
local Glyphs = require("glyphs")
local ViewBase = require("view_base")
local P = require("uiparts")

local DetailView = ViewBase:extend{
    entry = nil,
    on_change = nil,   -- called when the book's state changed (downloaded)
    self_paged = true,
}

function DetailView:setup()
    App.push(self)
    self.just_saved = false
    self.dl_listener = function(event, entry, state) self:onDownloadEvent(event, entry, state) end
    Downloader.subscribe(self.dl_listener)
end

function DetailView:teardown()
    Downloader.unsubscribe(self.dl_listener)
    if self.cover_job then self.cover_job:cancel(); self.cover_job = nil end
    App.pop(self)
end

function DetailView:titleBarSpec()
    return {
        title = self.entry.title or "",
        left_icon = "chevron.left",
        on_left = function() UIManager:close(self) end,
    }
end

function DetailView:onExit()
    App.exitAll()
end

-- No paging here; swipes inside the description belong to the scroller.
function DetailView:onSwipe()
    return false
end

function DetailView:onPageBuilt()
    local url = self.entry.cover_url
    if not url or self.cover_job or Covers.isCached(url) then return end
    self.cover_job = Covers.fetch({ url }, function(got)
        self.cover_job = nil
        if #got > 0 then self:rebuild() end
    end)
end

local function meta_text(e)
    local parts = {}
    if e.source then parts[#parts + 1] = e.source end
    parts[#parts + 1] = (e.format or "epub"):upper()
    if e.language then parts[#parts + 1] = e.language end
    if e.year then parts[#parts + 1] = e.year end
    if e.price then parts[#parts + 1] = e.price end   -- buy rows (PROVIDERS.md §4.3)
    return table.concat(parts, "  ·  ")
end

function DetailView:headerRow(st)
    local w, pad = self.screen_w, Size.padding.large
    local e = self.entry
    local cover_w = math.floor(w * 0.34)
    local cover_h = math.floor(cover_w * 1.5)
    local text_w = w - 2 * pad - cover_w - pad

    local title_face = P.face(20, "tfont")
    local title = TextBoxWidget:new{ text = e.title or "", face = title_face, bold = true, width = text_w }
    local max_title_h = Screen:scaleBySize(20 * 1.45 * 4)
    if title:getSize().h > max_title_h then
        title:free()
        title = TextBoxWidget:new{
            text = e.title or "", face = title_face, bold = true, width = text_w,
            height = max_title_h, height_overflow_show_ellipsis = true,
        }
    end

    local col = VerticalGroup:new{
        align = "left",
        title,
        P.vspace(Screen:scaleBySize(6)),
        P.text(e.author or "", 16, { max_width = text_w }),
        P.vspace(Screen:scaleBySize(6)),
        P.text(meta_text(e), 14, { color = P.DARK_GRAY, max_width = text_w }),
    }

    local line, color
    if st.dl and st.dl.status == "active" then
        line = nil
    elseif self.just_saved then
        line, color = Glyphs.check .. "  " .. _("Saved to the OpenShelf folder"), P.BLACK
    elseif st.downloaded then
        line, color = Glyphs.check .. "  " .. _("On this device"), P.DARK_GRAY
    elseif st.missing then
        line, color = Glyphs.warning .. "  " .. _("No longer on this device"), P.DARK_GRAY
    end
    if line then
        table.insert(col, P.vspace(Screen:scaleBySize(10)))
        table.insert(col, P.text(line, 13, { color = color, max_width = text_w }))
    end

    local header = HorizontalGroup:new{
        align = "top",
        P.cover(e.cover_url, cover_w, cover_h, { letter = P.letterFor(e), dim = st.missing }),
        P.hspace(pad),
        col,
    }
    local h = math.max(cover_h, col:getSize().h) + 2 * pad
    return { widget = P.row(w, h, header, { pad = pad }), h = h, hits = {} }
end

function DetailView:actionRow(st)
    local w, pad = self.screen_w, Size.padding.large
    local e = self.entry
    local bh = Screen:scaleBySize(44)
    local row_h = bh + 2 * Size.padding.large
    local items, hits

    if st.dl and (st.dl.status == "active" or st.dl.status == "queued") then
        local cancel_w = Screen:scaleBySize(110)
        local bar_w = w - 2 * pad - cancel_w - pad
        local label
        local pct = 0
        if st.dl.status == "queued" then
            label = _("Queued — waiting for the current download to finish")
        elseif st.dl.total and st.dl.total > 0 then
            pct = math.min(1, (st.dl.done or 0) / st.dl.total)
            label = T(_("%1% · %2 of %3"), math.floor(pct * 100),
                P.friendlySize(st.dl.done), P.friendlySize(st.dl.total))
        else
            label = T(_("%1 received…"), P.friendlySize(st.dl.done))
        end
        local bar = VerticalGroup:new{
            align = "left",
            P.progress(bar_w, Screen:scaleBySize(10), pct),
            P.vspace(Screen:scaleBySize(5)),
            P.text(label, 13, { color = P.DARK_GRAY, max_width = bar_w }),
        }
        items = { P.box(bar_w, bh, bar), P.hspace(pad), P.button(_("Cancel"), cancel_w, bh) }
        hits = { { x = w - pad - cancel_w, w = cancel_w, on_tap = function()
            Downloader.cancel(e)
            self:rebuild()
        end } }
    else
        local label, cb, hold
        if e.action == Entry.ACTION.BUY then
            -- nothing to download: the QR carries the store page
            label = _("Show QR code")
            cb = function() self:showQR() end
        elseif st.downloaded then
            label = _("Open")
            cb = function() App.openBook(st.path) end
            hold = function() self:confirmRedownload() end
        elseif st.missing then
            label = _("Download again")
            cb = function() self:startDownload() end
        elseif e.action == Entry.ACTION.BORROW then
            label = _("Borrow")
            cb = function() self:startDownload() end
        else
            label = _("Download")
            cb = function() self:startDownload() end
        end
        local bw = math.floor((w - 2 * pad) * 0.58)
        items = { P.button(label, bw, bh, { filled = true }) }
        hits = { { x = pad, w = bw, on_tap = cb, on_hold = hold } }
        local x = pad + bw + pad
        if self.just_saved then
            local dw = w - pad - x
            items[#items + 1] = P.hspace(pad)
            items[#items + 1] = P.button(_("Done"), dw, bh)
            hits[#hits + 1] = { x = x, w = dw, on_tap = function() UIManager:close(self) end }
        elseif e.alternates and #e.alternates > 0 then
            local chip_w = Screen:scaleBySize(64)
            local formats = { e.format }
            for __, alt in ipairs(e.alternates) do formats[#formats + 1] = alt.format end
            for __, fmt in ipairs(formats) do
                items[#items + 1] = P.hspace(Size.padding.default)
                items[#items + 1] = P.button(fmt:upper(), chip_w, bh, { filled = fmt == e.format, size = 14 })
                x = x + Size.padding.default
                local this_fmt = fmt
                hits[#hits + 1] = { x = x, w = chip_w, on_tap = function() self:switchFormat(this_fmt) end }
                x = x + chip_w
            end
        end
    end
    return {
        widget = P.row(w, row_h, HorizontalGroup:new{ align = "center", unpack(items) }, { pad = pad }),
        h = row_h, hits = hits,
    }
end

-- Buy rows (decision 49): the store page as text under the button; tapping
-- it shows the same URL as a QR code to scan with a phone.
function DetailView:buyUrl()
    local loc = self.entry.locator
    if type(loc) == "table" and type(loc.url) == "string" and loc.url ~= "" then return loc.url end
    return nil
end

function DetailView:buyRow()
    local w, pad = self.screen_w, Size.padding.large
    local url = self:buyUrl()
    local text = url and (_("Buy at") .. "  " .. url) or _("The store did not provide a link.")
    local box = TextBoxWidget:new{ text = text, face = P.face(14), fgcolor = P.DARK_GRAY, width = w - 2 * pad }
    local h = box:getSize().h + 2 * Size.padding.default
    return {
        widget = P.row(w, h, box, { pad = pad }),
        h = h,
        hits = url and { { on_tap = function() self:showQR() end } } or {},
    }
end

function DetailView:showQR()
    local url = self:buyUrl()
    if not url then return end
    local QRMessage = require("ui/widget/qrmessage")
    UIManager:show(QRMessage:new{ title = self.entry.title or "", text = url })
end

function DetailView:buildRows()
    local e = self.entry
    -- Buy rows never reach the downloader, so they carry no download state.
    local st = e.action == Entry.ACTION.BUY and {} or App.bookStatus(e)
    self.status = st
    local rows = { self:headerRow(st), self:actionRow(st) }
    if e.action == Entry.ACTION.BUY then rows[#rows + 1] = self:buyRow() end

    local used = 0
    for __, r in ipairs(rows) do used = used + r.h end
    local pad = Size.padding.large
    local desc_h = self.content_h - used
    if desc_h > Screen:scaleBySize(48) then
        local text = self.entry.description or _("No description available for this book.")
        local scroller = ScrollTextWidget:new{
            text = text, face = P.face(15),
            width = self.screen_w - 2 * pad, height = desc_h - 2 * pad,
            dialog = self,
        }
        rows[#rows + 1] = { widget = P.row(self.screen_w, desc_h, scroller, { pad = pad }), h = desc_h, hits = {} }
    end
    return rows
end

function DetailView:switchFormat(fmt)
    local e = self.entry
    if fmt == e.format then return end
    for i, alt in ipairs(e.alternates or {}) do
        if alt.format == fmt then
            local new = {}
            for k, v in pairs(e) do new[k] = v end
            new.format, new.locator = alt.format, alt.locator
            local alts = { { format = e.format, locator = e.locator } }
            for j, a in ipairs(e.alternates) do
                if j ~= i then alts[#alts + 1] = a end
            end
            new.alternates = alts
            self.entry = new
            self.just_saved = false
            self:rebuild()
            return
        end
    end
end

function DetailView:startDownload()
    local e = self.entry
    NetworkMgr:runWhenOnline(function()
        Downloader.enqueue(e)
        self:rebuild()
    end)
end

function DetailView:confirmRedownload()
    UIManager:show(ConfirmBox:new{
        text = T(_("Download “%1” again and replace the copy on this device?"), self.entry.title or ""),
        ok_text = _("Download again"),
        ok_callback = function() self:startDownload() end,
    })
end

function DetailView:onDownloadEvent(event, entry, state)
    if Entry.id(entry) ~= Entry.id(self.entry) then return end
    if event == "progress" then
        if App.progressWorthRepaint(self, entry, state) then self:rebuild() end
        return
    end
    if event == "done" then
        self.just_saved = true
    elseif event == "error" then
        UIManager:show(InfoMessage:new{ text = T(_("Download failed:\n%1"), state and state.err or "") })
    end
    self:rebuild()
    if (event == "done" or event == "cancel") and self.on_change then self.on_change() end
end

return DetailView
