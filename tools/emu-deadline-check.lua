-- Job deadline check (issue #3, DESIGN.md §9.6, decision 45): a dev-script
-- provider whose search() and resolve() sleep for minutes without touching
-- the network, so its forked child survives on macOS. Run with
-- OPENSHELF_INLINE_JOBS=0 so jobs really fork (inline mode ignores the
-- deadline by design). Expected: the Quick provider's row lands at once, the
-- Sleepy slot reads "Sleepy: timed out" just after 60 s, the killed children
-- are reaped (no zombies left under KOReader), and a download of a Sleepy
-- entry fails with "timed out" from its resolve job. Built-in sources are
-- disabled for the run (their forked children die on macOS) and restored.
-- Run via OPENSHELF_INLINE_JOBS=0 scripts/emu.sh --walk tools/emu-deadline-check.lua --shots <dir>. Dev only.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local Catalog = require("catalog")
local Downloader = require("downloader")
local Entry = require("entry")
local Jobs = require("jobs")
local Settings = require("settings")
local ffiutil = require("ffi/util")
local OUT = os.getenv("OPENSHELF_SHOT_DIR")
local step = 0
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

local sleepy = {
    api = 1, id = "sleepy", name = "Sleepy", quality = 10,
    search = function() ffiutil.sleep(300); return {}, false end,
    resolve = function() ffiutil.sleep(300); return "https://example.invalid/never.epub" end,
}
local quick = {
    api = 1, id = "quick", name = "Quick", quality = 20,
    search = function(_q, _l, _p, ctx)
        return { ctx.Entry.new{ title = "Instant Classic", author = "Quick",
            locator = { url = "https://example.invalid/quick.epub" } } }, false
    end,
    resolve = function(loc) return loc.url end,
}
log("register sleepy", Catalog.register(sleepy))
log("register quick", Catalog.register(quick))
log("inline jobs?", Jobs.inline, "deadline", Jobs.DEADLINE)

local was = {}
for __, id in ipairs({ "gutendex", "internetarchive", "doab" }) do
    local p = Catalog.byId(id)
    was[id] = Settings.isEnabled(p)
    Settings.setEnabled(p, false)
end
local function restore()
    for id, enabled in pairs(was) do Settings.setEnabled(Catalog.byId(id), enabled) end
end

-- Child processes of KOReader (the io.popen shell's $PPID is KOReader).
local function children()
    local p = io.popen("ps -axo pid=,ppid=,stat=,etime=,command= | awk -v p=$PPID '$2==p'")
    local s = p:read("*a"); p:close()
    return (s:gsub("%s+$", ""))
end
local function dump_state(tag)
    local h = home()
    if not h.results then log(tag, "no results yet"); return end
    log(tag, "pending=[" .. table.concat(h.results:pending(), ",") .. "]",
        "errors=[" .. table.concat(h.results:errors(), " | ") .. "]", "rows=" .. #h.entries,
        "searching=" .. tostring(h:isSearching()))
    for i, e in ipairs(h.entries) do log(tag, "ROW", i, e.title, e.source) end
end
local sleepy_entry = Catalog.stamp(sleepy, { Entry.new{ title = "Never Arrives", author = "Sleepy",
    format = "epub", locator = { url = "https://example.invalid/never.epub" } } })[1]
Downloader.subscribe(function(event, entry, state)
    if event ~= "progress" then log("EVENT", entry.title, event, state and (state.err or state.path) or "") end
end)
local search_pid

at(1,  function() shot("home") end, "home")
at(2,  function() home():startSearch("anything") end, "search")
at(3,  function()
    local job = home().searcher and home().searcher.jobs["Sleepy"]
    search_pid = job and job.pid
    log("sleepy search job pid", tostring(search_pid))
    log("enqueue sleepy download", Downloader.enqueue(sleepy_entry))
end, "pids")
at(6,  function() dump_state("T+4"); shot("searching"); log("CHILDREN\n" .. children()) end, "mid")
at(35, function() dump_state("T+33"); log("CHILDREN\n" .. children()) end, "still waiting")
at(64, function() dump_state("T+62"); shot("timed-out"); log("CHILDREN\n" .. children()) end, "after deadline")
at(65, function() home():showStatusDetail() end, "status detail")
at(67, function() shot("status-detail"); log("CHILDREN\n" .. children()) end)
at(68, function() UIManager:close(UIManager:getTopmostVisibleWidget()) end, "close detail")
at(69, function() restore(); log("done"); os.exit(0) end, "exit")
