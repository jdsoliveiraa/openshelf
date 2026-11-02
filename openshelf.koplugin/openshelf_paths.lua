--[[
Where a download lands (DESIGN.md §12.8, decisions 79–81, ticket #19). Pure:
the file-name sanitizer is injected (KOReader's util.getSafeFilename on the
device, a copy of it in the tests).

  local paths = Paths.new(safe)          safe(name, nil, limit) -> a name safe on vfat
  paths:segment(title)                   -> one directory name ("_" when it ends up empty)
  paths:rootDir(provider_name)           -> a provider's root directory, "<provider name>"
  paths:dirOf(entry, listing_dir)        -> the directory of a row (below OpenShelf/, "" = flat);
                                            listing_dir = the directory of the folder whose
                                            list() returned it, nil for any other row
  paths:dirFor(entry)                    -> its stamped `dir`, else dirOf(entry)
  paths:stamped(entries, listing_dir)    -> copies of the rows with `dir` stamped
  paths:fileName(entry, in_dir)          -> "<Title>.<ext>" in a directory, "<Author> - <Title>.<ext>" flat
  Paths.withSuffix(name, n)              -> "Aula 1 (2).pdf"
  paths:target(entry, root, owned)       -> the absolute target of an entry without a record
  paths:targetIn(entry, root, library)   -> its record's path, else target() against the others
  paths:status(entry, root, library, size_of) -> { target, downloaded (✓), missing, record }

Directories, with P = "<provider name>" (DESIGN.md §12.8):
  the root -> P (the root title is never a segment)
  a folder row with `path` -> P/<path…>/<title>
  a folder row without `path` that list() returned -> the listing folder's directory/<title>
  any other folder row without `path` (search, shelf, scoped search) -> P/<title>
  a file with `path` -> P/<path…>; else, listed by list() -> that folder's directory; else flat.
An empty `path` ({}) means directly under the root: P.

Only rows a folder view lists need a stamp (their directory depends on the
route that reached the folder); every other row's directory follows from
the row alone. Caches keep rows unstamped: `stamped` returns copies.
--]]
local Entry = require("entry")

local Paths = {}
Paths.__index = Paths

Paths.NAME_LIMIT = 120   -- bytes, before the extension; keeps names readable in file browsers
local EXT_LIMIT = 10     -- longer than this after the last dot: not an extension (util.getSafeFilename's rule)

function Paths.new(safe)
    return setmetatable({ safe = safe }, Paths)
end

-- name -> stem, ext (ext nil when there is none).
local function split(name)
    local stem, ext = name:match("^(.*)%.([^.]*)$")
    if not stem or ext == "" or #ext > EXT_LIMIT then return name, nil end
    return stem, ext
end

local function join(a, b)
    if a == "" then return b end
    return a .. "/" .. b
end

-- A directory has no extension, but the sanitizer splits one off at the
-- last dot ("Notes. " -> "Notes."): trailing dots and spaces go here
-- (vfat drops them anyway), and a name left empty ("", ".", "..") is "_".
function Paths:segment(title)
    local s = self.safe(tostring(title or ""), nil, Paths.NAME_LIMIT):gsub("[.%s]+$", "")
    if s == "" then return "_" end
    return s
end

function Paths:rootDir(provider_name)
    return self:segment(provider_name)
end

function Paths:dirOf(entry, listing_dir)
    local p = self:rootDir(entry.source or entry.provider)
    local with_path
    if type(entry.path) == "table" then
        with_path = p
        for __, t in ipairs(entry.path) do with_path = join(with_path, self:segment(t)) end
    end
    if entry.action == Entry.ACTION.FOLDER then
        local title = self:segment(entry.title)
        if with_path then return join(with_path, title) end
        if listing_dir then return join(listing_dir, title) end
        return join(p, title)
    end
    return with_path or listing_dir or ""
end

function Paths:dirFor(entry)
    if type(entry.dir) == "string" then return entry.dir end
    return self:dirOf(entry, nil)
end

function Paths:stamped(entries, listing_dir)
    local out = {}
    for i, e in ipairs(entries or {}) do
        local copy = {}
        for k, v in pairs(e) do copy[k] = v end
        copy.dir = self:dirOf(e, listing_dir)
        out[i] = copy
    end
    return out
end

function Paths:fileName(entry, in_dir)
    local ext = entry.format or "epub"
    -- trailing dots and spaces would go anyway ("Aula 1.pdf." is Aula 1.pdf)
    local title = (entry.title or (in_dir and "" or "book")):gsub("[.%s]+$", "")
    local base = in_dir and title or string.format("%s - %s", entry.author or "Unknown", title)
    local dot_ext = "." .. ext:lower()
    if base:lower():sub(-#dot_ext) ~= dot_ext then base = base .. "." .. ext end
    local name = self.safe(base, nil, Paths.NAME_LIMIT)
    local stem, e = split(name)
    if stem == "" then return "_" .. (e and ("." .. e) or "") end
    return name
end

function Paths.withSuffix(name, n)
    local stem, ext = split(name)
    return stem .. " (" .. n .. ")" .. (ext and ("." .. ext) or "")
end

--- The target of an entry with no record: `root`/<its directory>/<name>, or
--- the first of Name (2), Name (3)… when `owned` (another record's path,
--- lower-cased) has it. Paths compare case-insensitively: the Kobo's
--- storage is vfat.
function Paths:target(entry, root, owned)
    local dir = self:dirFor(entry)
    local base = dir == "" and root or (root .. "/" .. dir)
    local name = self:fileName(entry, dir ~= "")
    local path, n = base .. "/" .. name, 1
    while owned[path:lower()] do
        n = n + 1
        path = base .. "/" .. Paths.withSuffix(name, n)
    end
    return path
end

--- The target of `entry` given the library (library.lua): its record's path
--- whenever it has one, wherever the row was found (Download again, hold,
--- Download all); else target() against every other record's path.
--- Returns the path and the record.
function Paths:targetIn(entry, root, library)
    local rec = library:find(entry)
    if rec and type(rec.path) == "string" then return rec.path, rec end
    return self:target(entry, root, library:ownedPaths(Entry.id(entry))), rec
end

--- ✓ for a file row: a non-empty file at its target (size_of(path) ->
--- bytes|nil). An unrecorded file there is this entry's own copy; the twin
--- of a recorded same-named file has its own target, " (2)", so no ✓.
--- missing = recorded, but nothing at the recorded path.
function Paths:status(entry, root, library, size_of)
    local target, rec = self:targetIn(entry, root, library)
    local size = size_of(target)
    return { target = target, downloaded = size ~= nil, missing = rec ~= nil and size == nil, record = rec }
end

return Paths
