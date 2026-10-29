-- Ticket #6 check for the KOReader emulator: self-update from GitHub Releases.
-- Runs against a KO_HOME holding a *copy* of the plugin (never the symlinked
-- dev checkout) and a fake release server (tools/emu-update-serve.sh).
--
--   tools/emu-update-serve.sh /tmp/osu 8765 &          # fake releases
--   H=/tmp/osu-home
--   OPENSHELF_UPDATE_BASE=http://127.0.0.1:8765 \
--     scripts/emu.sh --home $H --copy --walk tools/emu-update-check.lua --shots <dir>
--   OPENSHELF_UPDATE_PHASE=2 OPENSHELF_UPDATE_BASE=http://127.0.0.1:8765 \
--     scripts/emu.sh --home $H --walk tools/emu-update-check.lua --shots <dir>
--
-- Phase 1 (fresh copy, version from the checkout):
--   Settings rows -> manual check vs the real GitHub release ("latest")
--   -> faked older version offers the real release, which has no checksum
--   -> a symlinked plugin folder is refused -> checksum mismatch, truncated
--   download, bad archive, entry outside the plugin, wrong staged version:
--   each aborts with a message, live folder byte-identical, no .old/.staging
--   -> automatic check: offline = silent + not counted, server down = silent,
--   24 h throttle, toggle off, "Later" suppresses auto but not manual
--   -> good v0.6.2 installs: live = 0.6.2, .old = previous, restart offered.
-- Phase 2 (KOReader restarted on the same home): 0.6.2 is running; v0.6.3
--   installs and replaces the single .old backup (now 0.6.2).
-- Every assertion logs "CHECK ok|FAIL"; the run ends with a summary line.
local ffi = require("ffi")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local lfs = require("libs/libkoreader-lfs")
local sha2 = require("ffi/sha2")
local Settings = require("settings")
local Updater = require("openshelf_updater")

ffi.cdef[[
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
]]
local function setenv(k, v)
    if v then ffi.C.setenv(k, v, 1) else ffi.C.unsetenv(k) end
end

local OUT = os.getenv("OPENSHELF_SHOT_DIR") or "/tmp"
local PHASE = os.getenv("OPENSHELF_UPDATE_PHASE") or "1"
local BASE = os.getenv("OPENSHELF_UPDATE_BASE") or "http://127.0.0.1:8765"
local step = PHASE == "2" and 50 or 0
local fails, checks = 0, 0
local function log(...) print("DEVSCRIPT", os.date("%H:%M:%S"), ...) end
local function check(cond, label, got)
    checks = checks + 1
    if not cond then fails = fails + 1 end
    log("CHECK", cond and "ok  " or "FAIL", label, got ~= nil and ("(got: " .. tostring(got) .. ")") or "")
end
local function shot(name)
    step = step + 1
    local path = string.format("%s/%02d-%s.png", OUT, step, name)
    local ok, err = pcall(function() return Screen:shot(path) end)
    log("shot", path, ok, err)
end
local function topmost() return UIManager:getTopmostVisibleWidget() end
-- the open "OpenShelf settings" menu, wherever it sits in the window stack
local function settings_menu()
    for __, w in ipairs(UIManager._window_stack or {}) do
        if w.widget and w.widget.title == "OpenShelf settings" then return w.widget end
    end
end
local function top_text()
    local w = topmost()
    return w and w.text or ""
end
local function close_top() UIManager:close(topmost()) end
local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
end
local function version_in(dir)
    return (read(dir .. "/openshelf_version.lua") or ""):match('return%s+"([^"]+)"')
end
-- Content fingerprint of a folder: sorted relative paths + md5 of each file.
local function fingerprint(dir)
    local items = {}
    local function walk(d, rel)
        for name in lfs.dir(d) do
            if name ~= "." and name ~= ".." then
                local p, r = d .. "/" .. name, rel .. name
                local mode = lfs.symlinkattributes(p, "mode")
                if mode == "directory" then walk(p, r .. "/")
                else items[#items + 1] = r .. ":" .. sha2.md5(read(p) or "") end
            end
        end
    end
    walk(dir, "")
    table.sort(items)
    return sha2.md5(table.concat(items, "\n")), #items
end

-- Sequential steps: each returns the seconds to wait before the next.
local steps = {}
local function add(label, fn) steps[#steps + 1] = { label = label, fn = fn } end
local function run(i)
    local s = steps[i]
    if not s then
        log("SUMMARY", fails == 0 and "PASS" or "FAIL", checks, "checks", fails, "failed")
        os.exit(0)
    end
    local ok, wait = pcall(s.fn)
    log("step", s.label, ok and "ok" or ("ERR " .. tostring(wait)))
    if not ok then fails = fails + 1; wait = 1 end
    UIManager:scheduleIn(wait or 1, function() run(i + 1) end)
end

local live = Updater.pluginDir()
local old, staging = live .. ".old", live .. ".staging"
local function exists(p) return lfs.symlinkattributes(p, "mode") ~= nil end
log("plugin dir", live, lfs.symlinkattributes(live, "mode"))

-- Manual check of scenario `s` (nil = the real GitHub API); returns after
-- the result is on screen.
local function manual(s)
    setenv("OPENSHELF_UPDATE_API", s and (BASE .. "/" .. s .. ".json") or nil)
    Updater.check{ manual = true }
    return 4
end
local function press_update()
    local box = topmost()
    check(box and box.ok_text == "Update", "offer dialog is on top", box and box.ok_text)
    UIManager:close(box)
    box.ok_callback()
    return 6
end
local function press_later()
    local box = topmost()
    check(box and box.cancel_text == "Later", "offer dialog is on top (Later)", box and box.cancel_text)
    UIManager:close(box)
    box.cancel_callback()
    return 1
end
local function settled()
    check(not exists(staging), "no staging folder left behind")
end

local fp0, nfiles
local step_top
if PHASE == "1" then
    fp0, nfiles = fingerprint(live)
    log("live fingerprint", fp0, nfiles, "files, version", version_in(live))
    check(lfs.symlinkattributes(live, "mode") == "directory", "plugin under test is a real folder, not the dev symlink")
    check(not exists(old), "no .old before the first update")

    add("settings rows", function()
        require("settings_menu").show()
        return 2
    end)
    add("settings shot", function()
        shot("settings-updates")
        local labels = {}
        local menu = settings_menu()
        for __, item in ipairs(menu and menu.item_table or {}) do
            labels[#labels + 1] = item.text .. "=" .. tostring(item.mandatory)
        end
        local all = table.concat(labels, "|")
        log("settings rows", all)
        check(all:find("Check for updates=" .. Updater.runningVersion(), 1, true) ~= nil,
              "Settings lists Check for updates with the running version")
        check(all:find("Check for updates automatically=", 1, true) ~= nil, "Settings lists the automatic toggle")
        check(Settings.updateState().auto == true, "automatic checks default on")
        -- an unrelated KOReader first-run notice may sit on top: clear it
        if topmost() ~= menu then close_top() end
        return 1
    end)

    -- Real GitHub: running = latest
    add("real latest", function() return manual(nil) end)
    add("real latest result", function()
        shot("real-up-to-date")
        check(top_text():find("latest version", 1, true) ~= nil, "real GitHub: up to date on the current version", top_text())
        close_top()
        return 1
    end)
    -- Real GitHub, faked older version: offered; v0.6.1 has no checksum
    add("real older", function() setenv("OPENSHELF_FAKE_VERSION", "0.6.0"); return manual(nil) end)
    add("real older offer", function()
        shot("real-offer")
        check(top_text():find("0.6.1", 1, true) and top_text():find("0.6.0", 1, true),
              "real GitHub: offer shows current -> new", top_text())
        return press_update()
    end)
    add("real older result", function()
        shot("real-no-checksum")
        check(top_text():find("no checksum", 1, true) ~= nil, "real v0.6.1 refused: no checksum asset", top_text())
        close_top()
        setenv("OPENSHELF_FAKE_VERSION", nil)
        return 1
    end)

    -- Symlinked plugin folder is never replaced
    local link = live .. ".devlink"
    add("symlink guard", function()
        os.remove(link)
        os.execute(string.format("ln -s %q %q", live, link))
        setenv("OPENSHELF_UPDATE_PLUGIN_DIR", link)
        return manual("ok")
    end)
    add("symlink guard result", function()
        press_update()
        return 3
    end)
    add("symlink guard check", function()
        shot("symlink-refused")
        check(top_text():find("link to a development checkout", 1, true) ~= nil, "symlinked plugin folder refused", top_text())
        close_top()
        setenv("OPENSHELF_UPDATE_PLUGIN_DIR", nil)
        os.remove(link)
        check(fingerprint(live) == fp0 and not exists(old), "symlink target untouched")
        return 1
    end)

    -- Failure scenarios: message, live intact
    local cases = {
        { "badsum", "checksum mismatch" },
        { "trunc", "download incomplete" },
        { "badzip", "not a valid archive" },
        { "evil", "unexpected archive content" },
        { "wrongver", "contains version 0.6.1" },
        { "nosum", "no checksum file" },
    }
    for __, c in ipairs(cases) do
        local s, needle = c[1], c[2]
        add(s .. " check", function() return manual(s) end)
        add(s .. " update", function() return press_update() end)
        add(s .. " result", function()
            shot("fail-" .. s)
            local t = top_text()
            check(t:find(needle, 1, true) ~= nil and t:find("unchanged", 1, true) ~= nil,
                  s .. ": aborts with a message", t)
            close_top()
            check(fingerprint(live) == fp0, s .. ": live plugin byte-identical")
            check(not exists(old), s .. ": no .old created")
            settled()
            return 1
        end)
    end

    -- Automatic checks
    local NetworkMgr = require("ui/network/manager")
    local real_connected = NetworkMgr.isConnected
    add("auto offline", function()
        Settings.setUpdateLastCheck(nil)
        setenv("OPENSHELF_UPDATE_API", BASE .. "/ok.json")
        NetworkMgr.isConnected = function() return false end
        local before = topmost()
        Updater.autoCheck()
        check(Settings.updateState().last_check == nil, "auto offline: not counted as a check")
        check(not Updater.busy, "auto offline: no job started")
        NetworkMgr.isConnected = real_connected
        check(topmost() == before, "auto offline: nothing shown")
        return 1
    end)
    add("auto server down", function()
        setenv("OPENSHELF_UPDATE_API", "http://127.0.0.1:9/none.json")
        step_top = topmost()
        Updater.autoCheck()
        check(Settings.updateState().last_check ~= nil, "auto: check time recorded")
        return 4
    end)
    add("auto server down result", function()
        check(topmost() == step_top, "auto with the server down: silent (no error dialog)")
        shot("auto-silent")
        return 1
    end)
    add("auto throttle", function()
        setenv("OPENSHELF_UPDATE_API", BASE .. "/ok.json")
        local before = topmost()
        Updater.autoCheck()
        check(not Updater.busy, "auto within 24 h: no job started")
        UIManager:scheduleIn(3, function()
            check(topmost() == before, "auto within 24 h: nothing offered")
        end)
        return 4
    end)
    add("auto toggle off", function()
        Settings.setUpdateAuto(false)
        Settings.setUpdateLastCheck(nil)
        local before = topmost()
        Updater.autoCheck()
        check(not Updater.busy and Settings.updateState().last_check == nil, "auto off: no check")
        UIManager:scheduleIn(3, function() check(topmost() == before, "auto off: nothing offered") end)
        return 4
    end)
    add("auto offers", function()
        Settings.setUpdateAuto(true)
        Settings.setUpdateLastCheck(nil)
        Updater.autoCheck()
        return 4
    end)
    add("auto later", function()
        shot("auto-offer")
        check(top_text():find("0.6.2", 1, true) ~= nil, "auto check offers v0.6.2", top_text())
        press_later()
        check(Settings.updateState().skipped == "0.6.2", "Later remembers 0.6.2")
        Settings.setUpdateLastCheck(nil)
        step_top = topmost()
        Updater.autoCheck()
        return 4
    end)
    add("auto suppressed", function()
        check(topmost() == step_top, "auto check after Later: not offered again")
        return manual("ok")
    end)
    add("manual after later", function()
        check(top_text():find("0.6.2", 1, true) ~= nil, "manual check still offers the postponed version", top_text())
        check(Settings.updateState().skipped == nil, "manual check lifted Later")
        return press_update()   -- install it
    end)
    add("installed", function()
        shot("installed-restart")
        check(top_text():find("0.6.2 is installed", 1, true) ~= nil, "success offers a restart", top_text())
        close_top()
        check(version_in(live) == "0.6.2", "live folder now holds 0.6.2", version_in(live))
        check(exists(old) and fingerprint(old) == fp0, "previous version kept byte-identical as .old")
        settled()
        return 1
    end)
else
    local running = require("openshelf_version")
    check(running == "0.6.2", "after restart the new version is running", running)
    check(version_in(old) == "0.6.1", ".old holds the previous version", version_in(old))
    add("settings rows", function()
        require("settings_menu").show()
        return 2
    end)
    add("settings shot", function()
        shot("p2-settings-0.6.2")
        if topmost() ~= settings_menu() then close_top() end
        return 1
    end)
    add("ok3 check", function() return manual("ok3") end)
    add("ok3 offer", function()
        shot("p2-offer-0.6.3")
        check(top_text():find("You have 0.6.2", 1, true) ~= nil, "offer: current 0.6.2 -> 0.6.3", top_text())
        return press_update()
    end)
    add("ok3 installed", function()
        shot("p2-installed")
        check(top_text():find("0.6.3 is installed", 1, true) ~= nil, "0.6.3 installed", top_text())
        close_top()
        check(version_in(live) == "0.6.3", "live folder now holds 0.6.3", version_in(live))
        check(version_in(old) == "0.6.2", "the single .old backup was replaced (now 0.6.2)", version_in(old))
        local siblings = {}
        for name in lfs.dir(live:match("^(.*)/[^/]+$")) do
            if name:find("^openshelf") then siblings[#siblings + 1] = name end
        end
        table.sort(siblings)
        log("plugins dir", table.concat(siblings, " "))
        check(#siblings == 2, "plugins dir holds only the live folder and one .old", table.concat(siblings, " "))
        settled()
        return 1
    end)
end

UIManager:scheduleIn(3, function() run(1) end)
