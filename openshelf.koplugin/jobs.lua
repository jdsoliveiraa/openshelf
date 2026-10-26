--[[
Background jobs in a forked subprocess (DESIGN.md §1, §3.2–3.4).

LuaSocket blocks, so anything that talks to a server runs in a child process
and the UI polls it on a UIManager schedule. The child runs `task()`, JSON-
encodes its return value, writes it to a pipe and exits; the parent reads the
pipe when data shows up (or the child is gone). This mirrors
Trapper:dismissableRunInSubprocess minus the coroutine/trap widget, so several
jobs can run at once and views stay fully interactive.

  local h = Jobs.run{
      task     = function() return { … } end,  -- runs in the child; JSON-safe return
      on_done  = function(result) end,         -- parent, on success
      on_error = function(err) end,            -- parent, on failure/no result
      interval = 0.2,                          -- poll period (seconds)
  }
  h:cancel()   -- kills the child; callbacks are not called

If fork is unavailable the task runs inline (blocking) so the feature still works.
--]]
local ffiutil = require("ffi/util")
local UIManager = require("ui/uimanager")
local JSON = require("json")
local logger = require("logger")

local Jobs = {}

-- Inline mode runs every task in-process (blocking, deferred one tick).
-- On the macOS emulator a forked child of the Cocoa/SDL process dies as soon
-- as it touches the network (verified 2026-10-26: the same fork + HTTPS works
-- in a plain luajit), so inline is the default there. Devices (Linux) use the
-- real subprocess path — the one KOReader's own plugins rely on.
-- Override with OPENSHELF_INLINE_JOBS=1 / =0.
local function default_inline()
    local env = os.getenv("OPENSHELF_INLINE_JOBS")
    if env == "1" then return true end
    if env == "0" then return false end
    local ok, Device = pcall(require, "device")
    local is_mac = jit and jit.os == "OSX"
    return ok and is_mac and Device:isEmulator() or false
end
Jobs.inline = default_inline()
if Jobs.inline then logger.info("OpenShelf: background jobs run inline on this platform") end

local function encode_result(ok, value)
    local payload
    if ok then
        payload = { ok = true, result = value }
    else
        payload = { ok = false, err = tostring(value) }
    end
    local eok, str = pcall(JSON.encode, payload)
    if not eok then
        str = JSON.encode({ ok = false, err = "cannot serialize result: " .. tostring(str) })
    end
    return str
end

local function run_inline(spec, handle)
    local ok, value = pcall(spec.task)
    handle.done = true
    if ok then
        if spec.on_done then spec.on_done(value) end
    else
        if spec.on_error then spec.on_error(tostring(value)) end
    end
    return handle
end

function Jobs.run(spec)
    local handle = { done = false, cancelled = false }
    if Jobs.inline then
        -- defer to the next tick so callers see the same async shape
        UIManager:nextTick(function()
            if not handle.cancelled then run_inline(spec, handle) end
        end)
        function handle.cancel(h) h.cancelled = true end
        return handle
    end

    local pid, read_fd = ffiutil.runInSubProcess(function(child_pid, child_write_fd)
        io.stderr:write("OpenShelf: child ", tostring(child_pid), " started\n")
        -- The child is a copy of the whole app: a GC cycle here would run
        -- finalizers on inherited UI/SDL objects. It lives for one task and
        -- _exit()s, so just don't collect.
        collectgarbage("stop")
        local ok, value = pcall(spec.task)
        local payload = encode_result(ok, value)
        io.stderr:write("OpenShelf: child ", tostring(child_pid), " finished ok=", tostring(ok),
            " bytes=", tostring(#payload), "\n")
        local written = ffiutil.writeToFD(child_write_fd, payload, true)
        io.stderr:write("OpenShelf: child ", tostring(child_pid), " wrote=", tostring(written), "\n")
    end, true)
    logger.dbg("OpenShelf: job forked pid", pid, "fd", read_fd)

    if not pid then
        logger.warn("OpenShelf: subprocess unavailable, running inline:", read_fd)
        return run_inline(spec, handle)
    end
    handle.pid, handle.fd = pid, read_fd
    local interval = spec.interval or 0.2

    -- Reap a child that is still exiting (or was killed) so it never lingers
    -- as a zombie; drain its pipe so a blocked write() can finish.
    local function collect()
        if ffiutil.isSubProcessDone(pid) then return end
        if handle.fd and ffiutil.getNonBlockingReadSize(handle.fd) ~= 0 then
            ffiutil.readAllFromFD(handle.fd)
            handle.fd = nil
        end
        UIManager:scheduleIn(2, collect)
    end

    local poll
    poll = function()
        if handle.cancelled then return end
        local finished = ffiutil.isSubProcessDone(pid)
        local avail = handle.fd and ffiutil.getNonBlockingReadSize(handle.fd)
        local readable = avail ~= nil and avail ~= 0
        logger.dbg("OpenShelf: job poll pid", pid, "finished", finished, "avail", avail)
        if not finished and not readable then
            UIManager:scheduleIn(interval, poll)
            return
        end
        local str = ""
        if handle.fd then
            str = ffiutil.readAllFromFD(handle.fd)   -- reads to EOF and closes the fd
            handle.fd = nil
        end
        if not finished then UIManager:scheduleIn(1, collect) end
        handle.done = true
        local ok, msg = pcall(JSON.decode, str)
        if ok and type(msg) == "table" and msg.ok then
            if spec.on_done then spec.on_done(msg.result) end
        else
            local err = (ok and type(msg) == "table" and msg.err) or "no result from background task"
            logger.warn("OpenShelf: job failed:", err)
            if spec.on_error then spec.on_error(err) end
        end
    end
    UIManager:scheduleIn(interval, poll)

    function handle.cancel(h)
        if h.done or h.cancelled then return end
        h.cancelled = true
        UIManager:unschedule(poll)
        ffiutil.terminateSubProcess(pid)
        UIManager:scheduleIn(1, collect)
    end
    return handle
end

return Jobs
