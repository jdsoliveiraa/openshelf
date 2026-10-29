--[[
Self-update from GitHub Releases (ticket #6, DESIGN.md §10).

  Updater.autoCheck()       -- OpenShelf opened: at most once per 24 h, silent
  Updater.check{ manual }   -- Settings -> Check for updates: always reports

Check: one job asks GitHub for the latest release (Logic.parseRelease) and,
when it is newer than the running version, offers it (current -> new, start
of the release notes, Update / Later).

Install: a job with a deadline downloads openshelf-vX.Y.Z.zip and its .sha256
through http_util into <plugin>.staging beside the plugin, checks size and
SHA-256 (ffi/sha2), vets every zip entry and extracts it with ffi/archiver,
then validates the staged plugin (_meta.lua, main.lua, version == tag). Only
then does the UI side swap folders: live -> <plugin>.old (one backup),
staged -> live, restoring the live folder if the second rename fails. Any
failure leaves the live plugin untouched and says why. Success offers
KOReader's restart prompt; the new code loads after the restart.

Only the plugin folder and its .staging / .old siblings are ever written:
settings/openshelf*, drop-in providers and downloaded books live elsewhere.

Dev overrides (emulator tests; never set on a device):
  OPENSHELF_FAKE_VERSION=0.6.0      pretend to run this version
  OPENSHELF_UPDATE_API=<url>        release JSON instead of GitHub's latest
  OPENSHELF_UPDATE_PLUGIN_DIR=<dir> install into this folder instead of our own
A plugin folder that is a symlink (scripts/emu.sh links the dev checkout) is
never updated.
--]]
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Jobs = require("jobs")
local Logic = require("openshelf_updater_logic")
local Settings = require("settings")
local Version = require("openshelf_version")

local Updater = {}

Updater.INSTALL_DEADLINE = 300   -- seconds for download + verify + extract
Updater.busy = false

function Updater.runningVersion()
    return os.getenv("OPENSHELF_FAKE_VERSION") or Version
end

local function api_url()
    return os.getenv("OPENSHELF_UPDATE_API") or Logic.API_LATEST
end

--- The live plugin folder: the directory this file was loaded from (the
-- path KOReader's plugin loader put on package.path), whatever it is named
-- and wherever KOReader lives.
function Updater.pluginDir()
    local override = os.getenv("OPENSHELF_UPDATE_PLUGIN_DIR")
    if override and override ~= "" then return (override:gsub("/+$", "")) end
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) ~= "@" then return nil end
    local dir = src:sub(2):match("^(.*)/[^/]+$")
    if dir then dir = dir:gsub("//+", "/"):gsub("/%./", "/"):gsub("/%.$", "") end
    return dir
end

---------------------------------------------------------------------------
-- Filesystem helpers (also run in the job's child process)
---------------------------------------------------------------------------
local function exists(path)
    return lfs.symlinkattributes(path, "mode") ~= nil
end

-- rm -r that never follows a link: a symlink is removed, not its target.
local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if not mode then return true end
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                local ok, err = remove_tree(path .. "/" .. name)
                if not ok then return nil, err end
            end
        end
    end
    return os.remove(path)
end
Updater.removeTree = remove_tree

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function fail(msg) error(msg, 0) end

---------------------------------------------------------------------------
-- Install steps that run inside the job
---------------------------------------------------------------------------
local function extract(zip, dest)
    local Archiver = require("ffi/archiver")
    local arc = Archiver.Reader:new()
    if not arc:open(zip) then fail(T(_("not a valid archive (%1)"), tostring(arc.err))) end
    -- vet every entry before anything is written
    local count = 0
    for entry in arc:iterate() do
        local ok, why = Logic.archiveEntryOk(entry.path, entry.mode)
        if not ok then arc:close(); fail(T(_("unexpected archive content: %1"), why)) end
        count = count + 1
    end
    if arc.err or count == 0 then
        local err = arc.err or "empty"
        arc:close()
        fail(T(_("not a valid archive (%1)"), err))
    end
    for entry in arc:iterate() do
        if not arc:extractToPath(entry.path, dest .. "/" .. entry.path) then
            local err = arc.err or "?"
            arc:close()
            fail(T(_("could not extract %1 (%2)"), entry.path, err))
        end
    end
    local err = arc.err
    arc:close()
    if err then fail(T(_("not a valid archive (%1)"), err)) end
end

--- Download, verify, extract and validate into `staging`. Returns the staged
-- plugin folder; raises a user-facing message on any failure.
function Updater.prepare(rel, staging)
    local HttpUtil = require("http_util")
    local sha2 = require("ffi/sha2")
    remove_tree(staging)
    if exists(staging) then fail(T(_("cannot clear %1"), staging)) end
    local ok, err = lfs.mkdir(staging)
    if not ok then fail(T(_("cannot create %1 (%2)"), staging, tostring(err))) end

    local zip = staging .. "/" .. rel.zip.name
    ok, err = HttpUtil.download(rel.zip.url, zip, { block_timeout = 30, total_timeout = 240 })
    if not ok then fail(T(_("download failed (%1)"), tostring(err))) end
    local size = lfs.attributes(zip, "size") or 0
    if rel.zip.size and size ~= rel.zip.size then
        fail(T(_("download incomplete (%1 of %2 bytes)"), size, rel.zip.size))
    end

    local sum_text, serr = HttpUtil.getBody(rel.sha256.url, { block_timeout = 15, total_timeout = 30 })
    if not sum_text then fail(T(_("checksum download failed (%1)"), tostring(serr))) end
    local expected, perr = Logic.parseChecksum(sum_text, rel.zip.name)
    if not expected then fail(perr) end
    local data = read_file(zip)
    if not data then fail(_("cannot read the downloaded file")) end
    local actual = sha2.sha256(data):lower()
    if actual ~= expected then fail(_("checksum mismatch: the download is corrupt")) end

    extract(zip, staging)
    os.remove(zip)

    local staged = staging .. "/" .. Logic.ROOT
    local function has(name) return lfs.attributes(staged .. "/" .. name, "mode") == "file" end
    local valid, why = Logic.validateStaged(has, read_file(staged .. "/openshelf_version.lua"), rel.version)
    if not valid then fail(why) end
    return staged
end

--- Swap the staged plugin in (UI side, after the job succeeded).
function Updater.swap(live, staged)
    return Logic.swap({
        exists = exists,
        remove_tree = remove_tree,
        rename = os.rename,
    }, live, staged)
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
local function show_error(text)
    UIManager:show(InfoMessage:new{ text = text })
end

local function install_failed(err)
    show_error(T(_("Update failed: %1\n\nOpenShelf %2 is unchanged."), tostring(err), Updater.runningVersion()))
end

local function installed(rel)
    pcall(os.execute, "sync")
    Settings.setUpdateSkipped(nil)
    logger.info("OpenShelf: updated to", rel.version)
    local Device = require("device")
    if Device:canRestart() then
        UIManager:askForRestart(T(_("OpenShelf %1 is installed.\n\nRestart KOReader now to load it?"), rel.version))
    else
        UIManager:show(InfoMessage:new{
            text = T(_("OpenShelf %1 is installed.\n\nRestart KOReader to load it."), rel.version),
        })
    end
end

function Updater.install(rel)
    if Updater.busy then return end
    if not rel.sha256 then
        install_failed(T(_("release %1 has no checksum file; install it manually"), rel.tag))
        return
    end
    local live = Updater.pluginDir()
    if not live or lfs.attributes(live, "mode") ~= "directory" then
        install_failed(T(_("cannot find the plugin folder (%1)"), tostring(live)))
        return
    end
    if lfs.symlinkattributes(live, "mode") == "link" then
        install_failed(T(_("%1 is a link to a development checkout; not replacing it"), live))
        return
    end
    local staging = live .. ".staging"
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        Updater.busy = true
        local progress = InfoMessage:new{
            text = T(_("Downloading OpenShelf %1…"), rel.version),
            dismissable = false,
        }
        UIManager:show(progress)
        UIManager:forceRePaint()
        local function done()
            Updater.busy = false
            UIManager:close(progress)
        end
        Jobs.run{
            task = function() return { staged = Updater.prepare(rel, staging) } end,
            timeout = Updater.INSTALL_DEADLINE,
            interval = 0.5,
            on_done = function(res)
                done()
                local ok, err = Updater.swap(live, res and res.staged)
                remove_tree(staging)
                if ok then installed(rel) else install_failed(err) end
            end,
            on_error = function(err)
                done()
                remove_tree(staging)
                logger.warn("OpenShelf: update failed:", err)
                install_failed(err)
            end,
        }
    end)
end

local function offer(rel, manual)
    local notes = Logic.notesExcerpt(rel.notes, 400)
    local text = T(_("OpenShelf %1 is available.\nYou have %2."), rel.version, Updater.runningVersion())
    if notes ~= "" then text = text .. "\n\n" .. notes end
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Update"),
        cancel_text = _("Later"),
        ok_callback = function() Updater.install(rel) end,
        cancel_callback = function()
            -- quiet automatic checks for this version (manual ones still offer it)
            Settings.setUpdateSkipped(rel.version)
            logger.dbg("OpenShelf: update", rel.version, "postponed", manual and "(manual)" or "(auto)")
        end,
    })
end

local function fetch_latest()
    local HttpUtil = require("http_util")
    local json, err = HttpUtil.getJSON(api_url(), {
        headers = { Accept = "application/vnd.github+json" },
        block_timeout = 15, total_timeout = 30,
    })
    if not json then fail(err) end
    local rel, perr = Logic.parseRelease(json)
    if not rel then fail(perr) end
    return rel
end

--- opts.manual: report every outcome. Otherwise errors and "up to date" are
-- silent and a version answered "Later" is not offered again.
function Updater.check(opts)
    opts = opts or {}
    local manual = opts.manual
    if Updater.busy then return end
    local checking
    local function start()
        Updater.busy = true
        if manual then
            checking = InfoMessage:new{ text = _("Checking for updates…"), dismissable = false }
            UIManager:show(checking)
            UIManager:forceRePaint()
        end
        local function done()
            Updater.busy = false
            if checking then UIManager:close(checking) end
        end
        Jobs.run{
            task = fetch_latest,
            timeout = Jobs.DEADLINE,
            on_done = function(rel)
                done()
                local current = Updater.runningVersion()
                if type(rel) ~= "table" or not Logic.isNewer(rel.version, current) then
                    logger.info("OpenShelf: up to date", current, rel and rel.version)
                    if manual then
                        UIManager:show(InfoMessage:new{
                            text = T(_("You're on the latest version (%1)."), current),
                        })
                    end
                    return
                end
                if Logic.shouldPrompt(Settings.updateState(), rel.version, manual) then
                    offer(rel, manual)
                end
            end,
            on_error = function(err)
                done()
                logger.warn("OpenShelf: update check failed:", err)
                if manual then show_error(T(_("Couldn't check for updates: %1"), tostring(err))) end
            end,
        }
    end
    if manual then
        Settings.setUpdateSkipped(nil)   -- a manual check lifts "Later"
        require("ui/network/manager"):runWhenOnline(start)
    else
        start()
    end
end

--- OpenShelf opened: check in the background when due and online. Never
-- turns Wi-Fi on, never shows anything unless there is an update to offer.
function Updater.autoCheck()
    if Updater.busy then return end
    if not Logic.shouldAutoCheck(Settings.updateState(), os.time()) then return end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then return end   -- offline: try again next open
    Settings.setUpdateLastCheck(os.time())
    Updater.check{ manual = false }
end

return Updater
