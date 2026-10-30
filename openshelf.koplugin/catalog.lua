--[[
Provider registry (PROVIDERS.md api 1 and 2, DESIGN.md §9, §12) + the catalog operations
that are not UI:
  Catalog.register(p)                         -> true | false, reason   (validates; duplicates lose)
  Catalog.validate(p)                         -> true | false, reason   (pure contract check)
  Catalog.providers / ids() / byId(id) / nameOf(id) / invalid()
  Catalog.orderIds(stored, registered)        -> ids in the user's arranged order (pure merge)
  Catalog.ordered(stored)                     -> provider tables in that order
  Catalog.ctxFor(provider)                    -> the ctx handed to every provider function
  Catalog.setSettingsSource(fn) / settingsFor(p) -> where ctx.settings comes from / its values
  Catalog.check(id)                           -> ok, message   (Test connection)
  Catalog.stamp(provider, entries)            -> rows with provider/source/quality set by the host
  Catalog.searchOne(id, query, limit, page)   -> entries, has_more | nil, err
  Catalog.list(id, locator, limit, page)      -> entries, has_more | nil, err   (api 2; nil locator = root)
  Catalog.searchIn(id, locator, query, limit, page) -> entries, has_more | nil, err   (api 2)
  Catalog.searchAll(query, opts)              -> entries, errors, collapsed (sequential; tests)
  Catalog.resolve(entry)                      -> { url, headers } | nil, err
  Catalog.normalizeResolve(value, err)        -> the same, from a provider's raw return (pure)
  Catalog.shelves(stored)                     -> { {id="<provider id>:<key>", key, title, provider}, … }
  Catalog.browse(shelf_id, limit, page)       -> entries, has_more | nil, err
  Catalog.roots(stored)                       -> { {title, provider}, … }   (api-2 roots, source order)
  Catalog.group(entries)                      -> { {action, heading, items}, … }

Built-ins are listed in openshelf_providers.lua and registered at load through
the same register() as plugins and drop-in files. The provider `id` is the key
everywhere (DESIGN.md §9.2): slots, settings, Entry.id, library records, browse
cache; display names only reach the user through nameOf().

The parallel, subprocess-based search lives in searcher.lua (KOReader only);
it calls searchOne inside each forked child.
--]]
local Entry = require("entry")
local Fields = require("openshelf_fields")
local OPDS = require("opds")
local Results = require("results")
local logger = require("logger")

local Catalog = {}

-- Registered (valid) providers, in registration = slot order.
Catalog.providers = {}

-- Providers that failed validation or lost an id clash: { id, name, reason }.
-- Listed dimmed in Sources with the reason (PROVIDERS.md §8.5), never a modal.
local invalid = {}

--- Check a provider table against the contract (PROVIDERS.md §2).
-- Pure. Returns true, or false + a human-readable reason.
local ID_PATTERN = "^[a-z][a-z0-9_]*$"

local function valid_id(id)
    return type(id) == "string" and #id <= 32 and id:match(ID_PATTERN) ~= nil
end

function Catalog.validate(p)
    if type(p) ~= "table" then return false, "not a table" end
    if not valid_id(p.id) then
        return false, "bad id " .. tostring(p.id) .. " (want ^[a-z][a-z0-9_]*$, max 32 bytes)"
    end
    if type(p.api) ~= "number" or (p.api ~= 1 and p.api ~= 2) then
        return false, "api must be 1 or 2 (got " .. tostring(p.api) .. ")"
    end
    if type(p.name) ~= "string" or p.name == "" or #p.name > 60 then
        return false, "bad name (want a string of at most 60 bytes)"
    end
    if p.quality ~= nil and type(p.quality) ~= "number" then
        return false, "quality must be a number"
    end
    if p.enabled_by_default ~= nil and type(p.enabled_by_default) ~= "boolean" then
        return false, "enabled_by_default must be true or false"
    end
    if type(p.search) ~= "function" then return false, "missing search function" end
    if type(p.resolve) ~= "function" then return false, "missing resolve function" end
    for __, fn in ipairs({ "browse", "check" }) do
        if p[fn] ~= nil and type(p[fn]) ~= "function" then
            return false, fn .. " must be a function"
        end
    end
    if p.shelves ~= nil then
        if type(p.shelves) ~= "table" then return false, "shelves must be a list" end
        if #p.shelves > 0 and type(p.browse) ~= "function" then
            return false, "shelves need a browse function"
        end
        for __, shelf in ipairs(p.shelves) do
            if type(shelf) ~= "table" or not valid_id(shelf.key) then
                return false, "bad shelf key " .. tostring(type(shelf) == "table" and shelf.key)
            end
            if type(shelf.title) ~= "string" or shelf.title == "" then
                return false, "shelf " .. shelf.key .. " needs a title"
            end
        end
    end
    -- api 2 (folders): on api 1 these are unknown fields, never read here.
    if p.api == 2 then
        if type(p.list) ~= "function" then return false, "missing list function (api 2)" end
        if p.search_in ~= nil and type(p.search_in) ~= "function" then
            return false, "search_in must be a function"
        end
        if p.root ~= nil and (type(p.root) ~= "string" or p.root == "" or #p.root > 60) then
            return false, "bad root (want a non-empty string of at most 60 bytes)"
        end
        if p.dedupe ~= nil and type(p.dedupe) ~= "boolean" then
            return false, "dedupe must be true or false"
        end
    end
    return Fields.validate(p.settings)
end

local function label_of(p, fallback)
    if type(p) == "table" and type(p.name) == "string" and p.name ~= "" then return p.name end
    if fallback then return fallback end
    if type(p) ~= "table" then return "?" end
    return tostring(p.id or "?")
end

--- Remember a provider that could not be registered (load error, bad shape,
-- duplicate id) so Sources lists it dimmed with the reason, and log it.
function Catalog.reject(name, reason, id)
    invalid[#invalid + 1] = { id = id, name = name, reason = reason }
    logger.warn("OpenShelf: provider rejected", name, reason)
end

--- Register one provider. Built-ins, plugins and drop-ins all come through
-- here (DESIGN.md §9.3). Returns true, or false + reason; the rejected
-- provider is remembered for Sources (Catalog.invalid()). `label` (a
-- registry name or file name) names a rejected table without a name.
function Catalog.register(p, label)
    local ok, reason = Catalog.validate(p)
    if ok and Catalog.byId(p.id) then
        ok, reason = false, "duplicate id " .. p.id
    end
    if not ok then
        Catalog.reject(label_of(p, label), reason, type(p) == "table" and p.id or nil)
        return false, reason
    end
    Catalog.providers[#Catalog.providers + 1] = p
    return true
end

function Catalog.invalid()
    return invalid
end

--- Registered provider ids in slot order.
function Catalog.ids()
    local ids = {}
    for __, p in ipairs(Catalog.providers) do ids[#ids + 1] = p.id end
    return ids
end

function Catalog.byId(id)
    for __, p in ipairs(Catalog.providers) do
        if p.id == id then return p end
    end
    return nil
end

--- Display name for a provider id, nil when no such provider is registered
-- (callers showing a stored row fall back to the row's own `source`).
function Catalog.nameOf(id)
    local p = Catalog.byId(id)
    return p and p.name or nil
end

--- Where ctx.settings comes from: a function id -> the raw stored
-- provider_settings[id] table. settings.lua (KOReader-only) installs it; the
-- catalog stays pure. Read when ctx is built, i.e. in the parent for inline
-- jobs and in the forked child (from the parent's in-memory copy) otherwise.
local settings_source

function Catalog.setSettingsSource(fn)
    settings_source = fn
end

--- The values a provider sees in ctx.settings: declared keys only, defaults
-- applied, empty text nil (PROVIDERS.md §3, §7).
function Catalog.settingsFor(provider)
    local stored = settings_source and settings_source(provider.id) or nil
    return Fields.values(provider.settings, stored)
end

--- Source order (DESIGN.md §9.5, decision 44): the user's arranged id list
-- merged with what is registered now. Stored ids that are still registered
-- come first, in stored order; ids registered since are appended in
-- registration order; ids that vanished drop out silently. Pure; neither
-- list is modified. `stored` may be nil or junk (nothing arranged yet).
function Catalog.orderIds(stored, registered)
    local present, used, out = {}, {}, {}
    for __, id in ipairs(registered) do present[id] = true end
    local function take(id)
        if present[id] and not used[id] then
            used[id] = true
            out[#out + 1] = id
        end
    end
    if type(stored) == "table" then
        for __, id in ipairs(stored) do take(id) end
    end
    for __, id in ipairs(registered) do take(id) end
    return out
end

--- Registered providers in the arranged order (Catalog.orderIds over the
-- stored id list). Result slots, the filter dialog and home shelves all
-- iterate this; Catalog.providers / ids() stay in registration order.
function Catalog.ordered(stored)
    local out = {}
    for __, id in ipairs(Catalog.orderIds(stored, Catalog.ids())) do
        out[#out + 1] = Catalog.byId(id)
    end
    return out
end

--- The API a provider sees (PROVIDERS.md §3): the only way it reaches
-- OpenShelf, so it never require()s a module of ours. Built per call (the
-- KOReader-only modules are required lazily so this file stays loadable by
-- the offline tests).
function Catalog.ctxFor(provider)
    local HttpUtil = require("http_util")
    local JSON = require("json")
    local url_escape = require("socket.url").escape
    local prefix = "OpenShelf[" .. tostring(provider.id) .. "]:"
    return {
        http = {
            getBody  = HttpUtil.getBody,
            getJSON  = HttpUtil.getJSON,
            head     = HttpUtil.head,
            download = HttpUtil.download,
        },
        json       = { decode = JSON.decode, encode = JSON.encode },
        url_escape = url_escape,
        settings   = Catalog.settingsFor(provider),
        Entry      = Entry,
        OPDS       = OPDS,
        log        = function(...) logger.info(prefix, ...) end,
    }
end

--- Decision 50: a borrow/buy row never outranks a download of the same
-- work. Downloads keep their quality (0 or more); non-download rows are
-- mapped into [-1000, -1], so the lowest download still wins in dedupe while
-- the rows' own order survives (a quality-70 borrow still beats a quality-60
-- buy of the same work).
local NON_DOWNLOAD_FLOOR = -1000
local function cap_non_download(quality)
    return NON_DOWNLOAD_FLOOR + math.max(0, math.min(quality, -NON_DOWNLOAD_FLOOR - 1))
end

--- Host pass over the rows a provider returned (PROVIDERS.md §4.1–4.3):
-- `provider`/`source` are always the registered ones, a missing `quality`
-- becomes the provider's (then capped below any download for borrow/buy
-- rows), and a row without a usable locator is dropped with a log line.
-- Rows that skipped ctx.Entry are normalised first (a raw `action =
-- "folder"` row becomes a folder row). api 1 knows nothing of folders: its
-- folder rows are dropped with a log line and `size` / `path` stripped.
function Catalog.stamp(provider, entries)
    local out = {}
    local api2 = provider.api == 2
    for __, e in ipairs(type(entries) == "table" and entries or {}) do
        if type(e) == "table" then
            if e.dedup_key == nil then
                e.cover = e.cover or e.cover_url
                e = Entry.new(e)
            end
            if Entry.locatorKey(e.locator) == "" then
                logger.warn("OpenShelf: dropped row without a locator", provider.id, e.title)
            elseif e.action == Entry.ACTION.FOLDER and not api2 then
                logger.warn("OpenShelf: dropped a folder row (folders need api 2)", provider.id, e.title)
            else
                if not api2 then e.size, e.path = nil, nil end
                -- Dedupe reads this: false = never merged (api 2 `dedupe = false`)
                if api2 and provider.dedupe == false then e.dedupe = false else e.dedupe = nil end
                e.provider = provider.id
                e.source = provider.name
                if e.quality == nil then e.quality = provider.quality or 0 end
                if e.action ~= Entry.ACTION.DOWNLOAD then e.quality = cap_non_download(e.quality) end
                out[#out + 1] = e
            end
        end
    end
    return out
end

--- One provider (by id), one page. Safe to call inside a subprocess.
function Catalog.searchOne(id, query, limit, page)
    local provider = Catalog.byId(id)
    if not provider then return nil, "unknown source " .. tostring(id) end
    local ok, res, extra = pcall(provider.search, query, limit, page, Catalog.ctxFor(provider))
    if not ok then return nil, tostring(res) end
    if not res then return nil, extra or "unknown error" end
    return Catalog.stamp(provider, res), extra and true or false
end

--- An api-2 provider by id that defines function `name` (list / search_in),
-- or nil + reason. api-1 tables are never asked: those fields are theirs.
local function folder_provider(id, name)
    local provider = Catalog.byId(id)
    if not provider then return nil, "unknown source " .. tostring(id) end
    if provider.api ~= 2 or type(provider[name]) ~= "function" then
        return nil, provider.name .. " has no " .. name
    end
    return provider
end

-- A pcall'd provider page → stamped rows, boolean has_more | nil, err.
local function stamped_page(provider, ok, res, extra)
    if not ok then return nil, tostring(res) end
    if not res then return nil, extra or "unknown error" end
    return Catalog.stamp(provider, res), extra and true or false
end

--- One folder, one page (PROVIDERS.md §5.5); `locator` nil = the root.
-- Safe inside a subprocess, like searchOne.
function Catalog.list(id, locator, limit, page)
    local provider, err = folder_provider(id, "list")
    if not provider then return nil, err end
    return stamped_page(provider, pcall(provider.list, locator, limit, page, Catalog.ctxFor(provider)))
end

--- Scoped search in one folder and below (PROVIDERS.md §5.6); `locator`
-- nil = the root. Safe inside a subprocess.
function Catalog.searchIn(id, locator, query, limit, page)
    local provider, err = folder_provider(id, "search_in")
    if not provider then return nil, err end
    return stamped_page(provider,
        pcall(provider.search_in, locator, query, limit, page, Catalog.ctxFor(provider)))
end

--- Sequential search across enabled providers (used by the headless test and
--- as a fallback when subprocesses are unavailable).
-- opts.enabled : optional set of provider ids {gutendex=true}; opts.per_provider : page size
-- Returns entries (deduped, slot-ordered), errors ("<name>: <err>" list), collapsed (count).
function Catalog.searchAll(query, opts)
    opts = opts or {}
    local ids = {}
    for __, p in ipairs(Catalog.providers) do
        if not opts.enabled or opts.enabled[p.id] then ids[#ids + 1] = p.id end
    end
    local results = Results.new(ids)
    for __, id in ipairs(ids) do
        local entries, more_or_err = Catalog.searchOne(id, query, opts.per_provider or 20, 1)
        if entries then
            results:setProvider(id, entries, more_or_err)
        else
            logger.warn("OpenShelf: provider failed", id, more_or_err)
            results:setError(id, more_or_err)
        end
    end
    local entries, collapsed = results:flatten()
    return entries, results:errors(Catalog.nameOf), collapsed, results
end

--- Normalize what a provider's resolve() returned (PROVIDERS.md §5.2): a
-- bare URL string or `{ url =, headers = }` both become `{ url, headers }`
-- with string-only header values (JSON null arrives as a function), so the
-- downloader never sees a bare table and the result survives the job pipe.
-- Pure. Returns the table, or nil + reason.
function Catalog.normalizeResolve(value, err)
    local url, headers
    if type(value) == "string" then
        url = value
    elseif type(value) == "table" then
        url = value.url
        if type(value.headers) == "table" then
            for k, v in pairs(value.headers) do
                if type(k) == "string" and (type(v) == "string" or type(v) == "number") then
                    headers = headers or {}
                    headers[k] = tostring(v)
                end
            end
        end
    elseif value == nil then
        return nil, err or "could not resolve a download URL"
    end
    if type(url) ~= "string" or url == "" then
        return nil, err or "resolve returned no URL"
    end
    return { url = url, headers = headers }
end

--- Entry → { url, headers } via its provider's resolve(locator), or nil + err.
-- Routing is by `entry.provider` only; v0.5 records were rekeyed on load (openshelf_migrate).
function Catalog.resolve(entry)
    local provider = entry.provider and Catalog.byId(entry.provider)
    if not provider or not provider.resolve then
        return nil, "no provider for " .. tostring(entry.provider or entry.source)
    end
    local ok, value, err = pcall(provider.resolve, entry.locator, Catalog.ctxFor(provider))
    if not ok then return nil, tostring(value) end
    return Catalog.normalizeResolve(value, err)
end

--- Test connection (PROVIDERS.md §5.4): the provider's check(ctx) with the
-- current settings. Safe inside a subprocess. Always returns a boolean and a
-- message string fit for a toast.
function Catalog.check(id)
    local provider = Catalog.byId(id)
    if not provider then return false, "unknown source " .. tostring(id) end
    if type(provider.check) ~= "function" then return false, "this source has no connection test" end
    local ok, res, msg = pcall(provider.check, Catalog.ctxFor(provider))
    if not ok then return false, tostring(res) end
    if type(msg) ~= "string" or msg == "" then
        msg = res and "Connection OK" or "Connection failed"
    end
    return res and true or false, msg
end

--- Home shelves declared by the registered providers, in source order
-- (`stored` = the arranged id list, see Catalog.ordered; nil = registration
-- order). Each is { id = "<provider id>:<key>", key, title, provider }; `id` is the
-- browse-cache key (PROVIDERS.md §5.3), `key` is what the provider sees.
function Catalog.shelves(stored)
    local out = {}
    for __, p in ipairs(Catalog.ordered(stored)) do
        for ___, shelf in ipairs(p.shelves or {}) do
            out[#out + 1] = { id = p.id .. ":" .. shelf.key, key = shelf.key,
                              title = shelf.title, provider = p }
        end
    end
    return out
end

--- Browse roots (DESIGN.md §12.3): { {title, provider}, … } for every
-- registered api-2 provider that declares `root`, in source order
-- (`stored` as in Catalog.shelves). Enabled / set-up filtering is the
-- caller's, as for shelves.
function Catalog.roots(stored)
    local out = {}
    for __, p in ipairs(Catalog.ordered(stored)) do
        if p.api == 2 and p.root ~= nil then
            out[#out + 1] = { title = p.root, provider = p }
        end
    end
    return out
end

--- Shelf id → stamped entries, has_more (nil, err on failure). `page`
-- defaults to 1 (PROVIDERS.md §5.3). The provider's second return counts as
-- has_more only when it is exactly `true`: a pre-#12 provider returns entries
-- alone (or ignores `page`), so it reads as a single page.
function Catalog.browse(shelf_id, limit, page)
    page = page or 1
    for __, shelf in ipairs(Catalog.shelves()) do
        if shelf.id == shelf_id then
            local p = shelf.provider
            local ok, entries, more_or_err = pcall(p.browse, shelf.key, limit, Catalog.ctxFor(p), page)
            if not ok then return nil, tostring(entries) end
            if not entries then return nil, more_or_err or "browse failed" end
            return Catalog.stamp(p, entries), more_or_err == true
        end
    end
    return nil, "unknown shelf " .. tostring(shelf_id)
end

--- Group entries by action in display order. Returns an ordered list of
--- { action=, heading=, items={...} }, skipping empty groups.
function Catalog.group(entries)
    local buckets = {}
    for __, e in ipairs(entries) do
        local a = e.action or Entry.ACTION.DOWNLOAD
        buckets[a] = buckets[a] or {}
        table.insert(buckets[a], e)
    end
    local groups = {}
    for __, action in ipairs(Entry.ACTION_ORDER) do
        local items = buckets[action]
        if items and #items > 0 then
            groups[#groups + 1] = {
                action  = action,
                heading = Entry.ACTION_HEADING[action],
                glyph   = Entry.ACTION_GLYPH[action],
                items   = items,
            }
        end
    end
    return groups
end

-- Built-ins register through the same door as plugins and drop-ins.
for __, p in ipairs(require("openshelf_providers")) do Catalog.register(p) end

return Catalog
