-- luacheck config. The device runs LuaJIT (Lua 5.1 + goto), so lint against that.
std = "luajit"
max_line_length = false
files = { "openshelf.koplugin", "test" }
-- Unused locals / args / loop vars whose name starts with "_" are deliberate
-- throwaways (KOReader convention; `_` is also the gettext binding).
ignore = { "21[1-3]/_.*" }
-- KOReader widgets are called method-style; handlers that don't touch `self`
-- are normal (onCloseWidget, menu builders, …).
self = false
