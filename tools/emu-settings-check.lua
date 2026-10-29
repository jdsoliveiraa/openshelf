-- Ticket #4 check for the KOReader emulator: per-source submenu, settings
-- fields, Needs setup and Test connection (PROVIDERS.md §7, §5.4).
-- Registers an offline dev provider "Dev Keyed" declaring all four field
-- types, a required secret and a check(ctx) whose outcome follows its
-- "Check result" choice (pass / fail / hang). Built-ins are switched off.
--
-- Phase 1 (default, inline jobs):
--   Sources shows "Needs setup" -> search skips the source (no slot, no strip
--   error) -> open it: lands on the empty token input -> save -> submenu with
--   mask / default / toggle / choice / hints -> toggle + cycle -> Test
--   connection pass, then fail -> search shows the settings echoed in a row.
--     scripts/emu.sh --walk tools/emu-settings-check.lua --shots <dir>
-- Phase 2 (real forks, after phase 1 in a fresh process):
--   values reloaded from disk -> forked search echoes them -> "hang" check
--   times out after Jobs.DEADLINE -> phase-1 state restored.
--     OPENSHELF_INLINE_JOBS=0 OPENSHELF_SETTINGS_PHASE=2 scripts/emu.sh --walk tools/emu-settings-check.lua --shots <dir>
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local Catalog = require("catalog")
local Jobs = require("jobs")
local Settings = require("settings")
local ffiutil = require("ffi/util")
local OUT = os.getenv("OPENSHELF_SHOT_DIR")
local PHASE = os.getenv("OPENSHELF_SETTINGS_PHASE") or "1"
local step = PHASE == "2" and 50 or 0
local function log(...) print("DEVSCRIPT", os.date("%H:%M:%S"), ...) end
local function shot(name)
    step = step + 1
    local path = string.format("%s/%02d-%s.png", OUT, step, name)
    local ok, err = pcall(function() return Screen:shot(path) end)
    log("shot", path, ok, err)
end
local function at(t, fn, label)
    UIManager:scheduleIn(t, function()
        local ok, err = pcall(fn)
        log(label or "", ok and "ok" or ("ERR " .. tostring(err)))
    end)
end
local function home() return App.homeView() end
local function topmost() return UIManager:getTopmostVisibleWidget() end
local function row(menu, label)
    for __, item in ipairs(menu.item_table or {}) do
        if item.text and item.text:find(label, 1, true) then return item end
    end
    log("ROW MISSING", label)
end
local function dump_menu(tag)
    for __, item in ipairs(topmost().item_table or {}) do
        log(tag, "ITEM", item.text, "|", tostring(item.mandatory), item.dim and "(dim)" or "")
    end
end

local keyed = {
    api = 1, id = "devkeyed", name = "Dev Keyed", quality = 10,
    settings = {
        { key = "token", title = "API token", type = "secret", required = true,
          hint = "Stored in plain text on the device" },
        { key = "user", title = "User name", type = "text", default = "guest" },
        { key = "covers", title = "Show covers", type = "toggle", default = true,
          hint = "Off saves data" },
        { key = "check_mode", title = "Check result", type = "choice",
          choices = { "pass", "fail", "hang" }, default = "pass", hint = "Dev only: outcome of the connection check" },
    },
    search = function(q, _l, _p, ctx)
        local s = ctx.settings
        return { ctx.Entry.new{ title = string.format("%s: token=%s user=%s covers=%s mode=%s",
            q, tostring(s.token), tostring(s.user), tostring(s.covers), tostring(s.check_mode)),
            author = "Dev Keyed", locator = { url = "https://dev/keyed/1" } } }, false
    end,
    resolve = function(l) return l.url end,
    check = function(ctx)
        local mode = ctx.settings.check_mode
        if mode == "hang" then ffiutil.sleep(300) end
        if mode == "fail" then return false, "Token rejected by the server" end
        return true, "Signed in as " .. tostring(ctx.settings.user)
    end,
}
local quick = {   -- a ready source so the result list is never empty
    api = 1, id = "devquick", name = "Dev Quick", quality = 20,
    search = function(q, _l, _p, ctx)
        return { ctx.Entry.new{ title = "Quick " .. q, author = "Quick",
            locator = { url = "https://dev/quick/1" } } }, false
    end,
    resolve = function(l) return l.url end,
}
log("register keyed", Catalog.register(keyed))
log("register quick", Catalog.register(quick))
log("phase", PHASE, "inline jobs?", Jobs.inline)
for __, id in ipairs({ "gutendex", "internetarchive", "doab" }) do
    Settings.setEnabled(Catalog.byId(id), false)
end

local function dump_search(tag)
    local h = home()
    log(tag, "pending=[" .. table.concat(h.results:pending(), ",") .. "]",
        "errors=[" .. table.concat(h.results:errors(), " | ") .. "]",
        "slots=[" .. table.concat(h.results.order or {}, ",") .. "]")
    for i, e in ipairs(h.entries) do log(tag, "ROW", i, e.provider, e.title) end
end
local function open_source()
    home():goHome()
    home():openSettings()
    UIManager:scheduleIn(1, function() row(topmost(), "Dev Keyed").callback() end)
end

if PHASE == "1" then
    -- start clean: nothing saved for the dev provider
    for __, f in ipairs(keyed.settings) do Settings.setProviderSetting("devkeyed", f.key, nil) end
    log("needsSetup", tostring(Settings.needsSetup(keyed)))

    at(1, function() home():openSettings() end, "settings")
    at(3, function() dump_menu("SOURCES"); shot("sources-needs-setup"); UIManager:close(topmost()) end)
    at(4, function() home():startSearch("emma") end, "search while needs setup")
    at(7, function() dump_search("NEEDS-SETUP"); shot("search-skips-needs-setup") end)
    at(8, function() open_source() end, "open Dev Keyed")
    at(11, function() shot("lands-on-token-input") end)
    at(12, function()
        local dlg = topmost()
        log("DIALOG title", tostring(dlg.title))
        dlg:setInputText("s3cret-token")
        dlg.button_table:getButtonById("save").callback()
    end, "save token")
    at(14, function() dump_menu("SUBMENU"); shot("submenu-filled") end)
    at(15, function()
        row(topmost(), "Show covers").callback()
        log("COVERS now", tostring(Settings.values(keyed).covers))
        for __ = 1, 3 do                            -- pass -> fail -> hang -> pass
            row(topmost(), "Check result").callback()
            log("CYCLE", row(topmost(), "Check result").mandatory)
        end
    end, "toggle + cycle")
    at(17, function() dump_menu("CYCLED"); shot("submenu-toggled-cycled") end)
    at(18, function() row(topmost(), "Test connection").callback() end, "test pass")
    at(19, function() shot("test-pass-toast") end)
    at(24, function() row(topmost(), "Check result").callback() end, "-> fail")
    at(25, function() row(topmost(), "Test connection").callback() end, "test fail")
    at(26, function() shot("test-fail-toast") end)
    at(31, function()
        row(topmost(), "Check result").callback()   -- fail -> hang (left for phase 2)
        UIManager:close(topmost())                  -- submenu
    end, "close submenu")
    at(32, function() dump_menu("SOURCES-READY"); shot("sources-ready"); UIManager:close(topmost()) end)
    at(33, function() home():startSearch("emma") end, "search when ready")
    at(36, function() dump_search("READY"); shot("search-echoes-settings") end)
    at(37, function()
        local f = io.open(require("datastorage"):getSettingsDir() .. "/openshelf.lua")
        local s = f and f:read("*a") or ""
        if f then f:close() end
        log("FILE provider_settings", ((s:match('%["provider_settings"%] = (%b{})') or "?"):gsub("%s+", " ")))
        log("done"); os.exit(0)
    end, "exit")
else
    log("RELOADED", "token", tostring(Settings.providerSettings("devkeyed").token),
        "values covers", tostring(Settings.values(keyed).covers), "mode", tostring(Settings.values(keyed).check_mode))
    at(1, function() home():startSearch("emma") end, "forked search")
    at(5, function() dump_search("FORKED"); shot("forked-search-echoes-settings") end)
    at(6, function() open_source() end, "open Dev Keyed")
    at(8, function() dump_menu("PHASE2"); shot("submenu-reloaded") end)
    at(9, function() row(topmost(), "Test connection").callback() end, "test hang")
    at(11, function() shot("test-hang-waiting") end)
    at(9 + Jobs.DEADLINE + 3, function() shot("test-hang-timed-out") end)
    at(9 + Jobs.DEADLINE + 5, function()
        Settings.setProviderSetting("devkeyed", "check_mode", "pass")
        for __, id in ipairs({ "gutendex", "internetarchive", "doab" }) do
            Settings.setEnabled(Catalog.byId(id), true)
        end
        log("done"); os.exit(0)
    end, "restore + exit")
end
