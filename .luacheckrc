-- luacheck config. The device runs LuaJIT (Lua 5.1 + goto), so lint against that.
std = "luajit"
max_line_length = false
files = { "openshelf.koplugin", "provider-openshelf-template.koplugin", "examples", "test", "tools" }
exclude_files = { ".kohome", ".claude/**" }   -- emulator home: a symlinked second copy of the plugin
-- Unused locals / args / loop vars whose name starts with "_" are deliberate
-- throwaways (KOReader convention; `_` is also the gettext binding).
ignore = { "21[1-3]/_.*" }
-- KOReader widgets are called method-style; handlers that don't touch `self`
-- are normal (onCloseWidget, menu builders, …).
self = false
