--[[
Cheap, stable string hash for cache file names (not cryptographic). Two
independent 32-bit hashes (djb2 + sdbm) → 16 hex chars; collisions among a
few thousand cover URLs are practically impossible and harmless anyway.
Pure Lua 5.1 arithmetic (no bit ops), so it runs under LuaJIT and plain Lua.
--]]
local M = {}

local MOD = 4294967296  -- 2^32

function M.hex(s)
    local h1, h2 = 5381, 0
    for i = 1, #s do
        local c = s:byte(i)
        h1 = (h1 * 33 + c) % MOD
        h2 = (c + h2 * 65599) % MOD
    end
    return string.format("%08x%08x", h1, h2)
end

return M
