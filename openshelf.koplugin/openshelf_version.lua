-- Single source of truth for the plugin version (User-Agent, About dialog).
-- Prefixed name on purpose: KOReader already has a `version` module loaded
-- before plugins start, and require() returns the cached one — a sibling
-- called version.lua is never seen (v0.4 failed to load because of this).
return "0.4.2"
