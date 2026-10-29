--[[
Self-update decisions (ticket #6, DESIGN.md §10): everything about an update
that doesn't need KOReader, so test/unit.lua can drive it.

  Logic.parseVersion("0.6.1") / ("v0.6.1")  -> { 0, 6, 1 } or nil
  Logic.compare(a, b)                       -> -1 | 0 | 1 (strings or parsed)
  Logic.parseRelease(json)                  -> release or nil, err
  Logic.parseChecksum(text, filename)       -> lower-case hex or nil, err
  Logic.notesExcerpt(body, max_chars)       -> the start of the release notes
  Logic.stagedVersion(text)                 -> version from openshelf_version.lua
  Logic.archiveEntryOk(path, mode)          -> true or false, reason
  Logic.shouldAutoCheck(state, now)         -> bool (24 h throttle)
  Logic.shouldPrompt(state, version, manual) -> bool ("Later" suppression)
  Logic.swap(fs, live, staged)              -> true or nil, err (folder swap)
  Logic.isZip(head)                         -> bool (zip signature PK\3\4)
  Logic.urlAllowed(url, allow_local_http)   -> bool (https only)
  Logic.releaseUrlsOk(rel, allow_local_http) -> true or nil, err

`state` is the plain table the updater keeps in settings:
  { auto = bool|nil (nil = on), last_check = os.time()|nil, skipped = "x.y.z"|nil }

A release here is plain data:
  { version = "0.6.2", tag = "v0.6.2", notes = "…",
    zip = { name, url, size }, sha256 = { name, url } | nil }
--]]
local Logic = {}

Logic.REPO = "jdsoliveiraa/openshelf"
Logic.API_LATEST = "https://api.github.com/repos/" .. Logic.REPO .. "/releases/latest"
Logic.CHECK_INTERVAL = 24 * 60 * 60     -- automatic checks: at most once per 24 h
Logic.ROOT = "openshelf.koplugin"       -- the zip's single top-level folder

-- KOReader's LuaJSON decodes `null` as a function: only real strings count.
local function str(v)
    return type(v) == "string" and v or nil
end

--- "x.y.z" or "vx.y.z" (nothing else) -> { x, y, z }, or nil. Prerelease and
-- build suffixes ("0.7.0-rc1", "0.7.0+abc") are rejected on purpose: they are
-- never offered.
function Logic.parseVersion(s)
    if type(s) ~= "string" then return nil end
    local a, b, c = s:match("^v?(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
end

--- Numeric comparison, field by field ("0.10.0" > "0.9.9"). Unparsable
-- versions compare as nil.
function Logic.compare(a, b)
    local va = type(a) == "table" and a or Logic.parseVersion(a)
    local vb = type(b) == "table" and b or Logic.parseVersion(b)
    if not va or not vb then return nil end
    for i = 1, 3 do
        if va[i] ~= vb[i] then return va[i] < vb[i] and -1 or 1 end
    end
    return 0
end

function Logic.isNewer(candidate, current)
    return Logic.compare(candidate, current) == 1
end

function Logic.zipName(tag) return "openshelf-" .. tag .. ".zip" end
function Logic.checksumName(tag) return Logic.zipName(tag) .. ".sha256" end

local function find_asset(assets, name)
    if type(assets) ~= "table" then return nil end
    for __, a in ipairs(assets) do
        if type(a) == "table" and str(a.name) == name and str(a.browser_download_url) then
            return { name = name, url = a.browser_download_url, size = tonumber(a.size) }
        end
    end
end

--- GitHub's /releases/latest JSON -> release, or nil + why it is unusable.
-- Drafts, prereleases and tags that aren't exactly vX.Y.Z are ignored, as is
-- a release without the plugin zip. A missing checksum asset is reported
-- (sha256 = nil) and refused at install time, not here: the check can still
-- tell the user a newer version exists.
function Logic.parseRelease(json)
    if type(json) ~= "table" then return nil, "no release data" end
    if json.draft == true or json.prerelease == true then return nil, "latest release is a prerelease" end
    local tag = str(json.tag_name)
    local v = Logic.parseVersion(tag)
    if not v or tag:sub(1, 1) ~= "v" then return nil, "unrecognised release tag " .. tostring(tag) end
    local zip = find_asset(json.assets, Logic.zipName(tag))
    if not zip then return nil, "release " .. tag .. " has no " .. Logic.zipName(tag) end
    return {
        version = table.concat(v, "."),
        tag = tag,
        notes = str(json.body) or "",
        url = str(json.html_url),
        zip = zip,
        sha256 = find_asset(json.assets, Logic.checksumName(tag)),
    }
end

--- A `sha256sum` line ("<64 hex>  <name>", or "<hex> *<name>", or just the
-- hash) -> the lower-case digest. When the line names a file it must be
-- `filename`.
function Logic.parseChecksum(text, filename)
    if type(text) ~= "string" then return nil, "empty checksum file" end
    local line = text:match("^%s*([^\r\n]*)") or ""
    local hex, rest = line:match("^(%x+)%s*(.-)%s*$")
    if not hex or #hex ~= 64 then return nil, "malformed checksum file" end
    local named = rest:gsub("^%*", "")
    if named ~= "" and filename and named ~= filename then
        return nil, "checksum is for " .. named .. ", not " .. filename
    end
    return hex:lower()
end

--- Start of the release notes for the offer dialog: markdown headings and
-- emphasis markers dropped, blank runs squeezed, cut at `max` characters on
-- a line or word boundary.
function Logic.notesExcerpt(body, max)
    max = max or 400
    if type(body) ~= "string" then return "" end
    local lines = {}
    for line in (body:gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("^%s*#+%s*", ""):gsub("%*%*", ""):gsub("%s+$", "")
        if line ~= "" or (lines[#lines] and lines[#lines] ~= "") then lines[#lines + 1] = line end
    end
    while lines[#lines] == "" do lines[#lines] = nil end
    local text = table.concat(lines, "\n")
    if #text <= max then return text end
    local cut = text:sub(1, max)
    local at = cut:match("^.*()\n") or cut:match("^.*() ")
    if at and at > max / 2 then cut = cut:sub(1, at - 1) end
    -- never end inside a UTF-8 sequence
    cut = cut:gsub("[\192-\255][\128-\191]*$", "")
    return cut .. " …"
end

--- The version string in a staged openshelf_version.lua, read as text (the
-- staged code is never run before it is validated).
function Logic.stagedVersion(text)
    if type(text) ~= "string" then return nil end
    for line in text:gmatch("[^\n]+") do
        local v = line:match('^%s*return%s+"([^"]+)"%s*$')
        if v then return v end
    end
end

--- Staged plugin check: required files present and the version equals the
-- release's. `has(name)` says whether a file exists in the staged folder;
-- `version_text` is its openshelf_version.lua.
function Logic.validateStaged(has, version_text, release_version)
    for __, f in ipairs({ "_meta.lua", "main.lua", "openshelf_version.lua" }) do
        if not has(f) then return false, "update is missing " .. f end
    end
    local v = Logic.stagedVersion(version_text)
    if v ~= release_version then
        return false, "update contains version " .. tostring(v) .. ", expected " .. tostring(release_version)
    end
    return true
end

--- Zip entries allowed into the staging folder: files and directories under
-- openshelf.koplugin/ only, no absolute paths, no "..", no links/devices.
function Logic.archiveEntryOk(path, mode)
    if type(path) ~= "string" or path == "" then return false, "empty entry name" end
    if mode ~= "file" and mode ~= "directory" then return false, path .. ": " .. tostring(mode) .. " not allowed" end
    if path:sub(1, 1) == "/" or path:find("\\", 1, true) then return false, path .. ": bad path" end
    for part in path:gmatch("[^/]+") do
        if part == ".." then return false, path .. ": bad path" end
    end
    local root = path:match("^([^/]+)")
    if root ~= Logic.ROOT then return false, path .. ": outside " .. Logic.ROOT end
    return true
end

--- Automatic check due? Only when enabled (default on) and the last one is
-- 24 h old, never, or in the future (clock reset).
function Logic.shouldAutoCheck(state, now)
    state = state or {}
    if state.auto == false then return false end
    local last = tonumber(state.last_check)
    if not last or last > now then return true end
    return now - last >= Logic.CHECK_INTERVAL
end

--- Offer the update dialog? A manual check always does; an automatic one
-- stays quiet for the version the user answered "Later" to.
function Logic.shouldPrompt(state, version, manual)
    if manual then return true end
    return not (state and state.skipped == version)
end

--- The download must be a zip (local file header "PK\3\4"): anything else,
-- e.g. a tar whose hardlink entries KOReader's archiver reports as plain
-- files, never reaches libarchive (which opens every format).
function Logic.isZip(head)
    return type(head) == "string" and head:sub(1, 4) == "PK\3\4"
end

local LOCAL_HOSTS = { ["localhost"] = true, ["127.0.0.1"] = true }

--- Update traffic is https only: the API URL, asset URLs and every redirect
-- they follow. Plain http is accepted only for localhost / 127.0.0.1 and
-- only when the caller says so (the OPENSHELF_UPDATE_API dev override for
-- the emulator's fake release server).
function Logic.urlAllowed(url, allow_local_http)
    if type(url) ~= "string" then return false end
    local lower = url:lower()
    if lower:match("^https://[^/]") then return true end
    if not allow_local_http then return false end
    local host = lower:match("^http://([^/:?#]+)")
    return host ~= nil and LOCAL_HOSTS[host] == true
end

function Logic.releaseUrlsOk(rel, allow_local_http)
    for __, asset in ipairs({ rel and rel.zip, rel and rel.sha256 }) do
        if asset and not Logic.urlAllowed(asset.url, allow_local_http) then
            return nil, "refusing non-https download " .. tostring(asset.url)
        end
    end
    return true
end

--- Put the staged plugin in place of the live one, keeping one backup:
--   <live>.old removed -> live renamed to <live>.old -> staged renamed to live.
-- If the last rename fails the live folder is renamed back, so a failure
-- never leaves the plugin missing. `fs` = { exists(p), remove_tree(p),
-- rename(a, b) } (os.rename-style returns), injected so this is testable.
function Logic.swap(fs, live, staged)
    if type(live) ~= "string" or type(staged) ~= "string" then return nil, "nothing to install" end
    if not fs.exists(staged) then return nil, "staged update is gone" end
    local old = live .. ".old"
    if fs.exists(old) then
        fs.remove_tree(old)
        if fs.exists(old) then return nil, "cannot remove the previous backup " .. old end
    end
    local ok, err = fs.rename(live, old)
    if not ok then return nil, "cannot move the current version aside (" .. tostring(err) .. ")" end
    ok, err = fs.rename(staged, live)
    if not ok then
        local back, berr = fs.rename(old, live)
        if not back then
            return nil, "cannot install (" .. tostring(err) .. ") nor restore (" .. tostring(berr)
                .. "); the previous version is in " .. old
        end
        return nil, "cannot move the new version into place (" .. tostring(err) .. ")"
    end
    return true
end

return Logic
