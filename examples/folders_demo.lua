--[[
Example api-2 drop-in (PROVIDERS.md §4.5, §5.5, §5.6): folders. A small fake
course tree held in this file, so it works offline; its files resolve to
real Project Gutenberg EPUBs, so downloads work on the device and in the
emulator.

  Demo courses                       (the root: a Browse chip on home)
  ├── Literature 101
  │   ├── Week 1                     Pride and Prejudice, Emma
  │   └── Week 2                     Frankenstein
  ├── Literature 201
  │   ├── Week 1                     Pride and Prejudice (another edition:
  │   │                              same name, other folder)
  │   └── Seminar
  │       └── Gothic                 Dracula
  └── The Elements of Style          (a file directly under the root)

What it shows:
- `api = 2`, `root`, and `list(locator, limit, page, ctx)`, where a nil
  locator is the root;
- folder rows from ctx.Entry.folder with `count` and `size`; folder and file
  locators that can never share an identity ({ folder = … } / { file = … });
- `search` and `search_in` return folders and files with `path` filled, so a
  file lands in the same directory wherever it was found; `list` rows leave
  `path` out, and the host places them under the folder that listed them;
- `dedupe = false`: the two Pride and Prejudice editions stay two rows.

Install: copy this file into <KOReader settings>/openshelf/providers/
(on a Kobo: /mnt/onboard/.adds/koreader/settings/openshelf/providers/) and
restart KOReader. Needs OpenShelf v0.8.0 or later (api 2).

Check it without KOReader:
    luajit tools/provider_check.lua examples/folders_demo.lua --offline

Everything comes from `ctx`; a drop-in never require()s anything.
--]]
local P = {
    api    = 2,
    id     = "folders_demo",
    name   = "Folders demo",
    root   = "Demo courses",
    dedupe = false,               -- same-named files in different folders stay apart
    enabled_by_default = true,
}

-- The catalog. `gutenberg` is the book id; `size` is the EPUB's size in
-- bytes (approximate, it changes when Gutenberg rebuilds the file).
local TREE = {
    { folder = "lit101", title = "Literature 101", items = {
        { folder = "lit101-w1", title = "Week 1", items = {
            { file = "lit101-w1-pp", title = "Pride and Prejudice", author = "Jane Austen",
              year = "1813", gutenberg = 1342, size = 609138 },
            { file = "lit101-w1-emma", title = "Emma", author = "Jane Austen",
              year = "1815", gutenberg = 158, size = 494782 },
        } },
        { folder = "lit101-w2", title = "Week 2", items = {
            { file = "lit101-w2-frank", title = "Frankenstein", author = "Mary Wollstonecraft Shelley",
              year = "1818", gutenberg = 84, size = 294175 },
        } },
    } },
    { folder = "lit201", title = "Literature 201", items = {
        { folder = "lit201-w1", title = "Week 1", items = {
            { file = "lit201-w1-pp", title = "Pride and Prejudice", author = "Jane Austen",
              year = "1813", gutenberg = 42671, size = 354141 },
        } },
        { folder = "lit201-sem", title = "Seminar", items = {
            { folder = "lit201-sem-gothic", title = "Gothic", items = {
                { file = "lit201-gothic-dracula", title = "Dracula", author = "Bram Stoker",
                  year = "1897", gutenberg = 345, size = 433654 },
            } },
        } },
    } },
    { file = "style", title = "The Elements of Style", author = "William Strunk",
      year = "1920", gutenberg = 37134, size = 73000 },
}

-- A new path: `path` plus one more folder title.
local function below(path, title)
    local out = {}
    for i, t in ipairs(path) do out[i] = t end
    out[#out + 1] = title
    return out
end

-- Every node under `items`, depth first, with the folder titles above it
-- (outermost first, without the root: what `path` wants).
local function walk(items, path, visit)
    for __, node in ipairs(items) do
        visit(node, path)
        if node.items then walk(node.items, below(path, node.title), visit) end
    end
end

-- Lookups by locator, built once from the constant tree above.
local FOLDERS, FILES = {}, {}
walk(TREE, {}, function(node, path)
    if node.items then FOLDERS[node.folder] = { node = node, path = path }
    else FILES[node.file] = node end
end)

-- Pure: one node → one row. A folder's count and size cover the files
-- directly inside it: what Download all fetches.
local function row(node, path, ctx)
    if node.items then
        local count, size = 0, 0
        for __, child in ipairs(node.items) do
            if not child.items then count, size = count + 1, size + child.size end
        end
        return ctx.Entry.folder{
            title   = node.title,
            locator = { folder = node.folder },
            path    = path,
            count   = count > 0 and count or nil,
            size    = size > 0 and size or nil,
        }
    end
    return ctx.Entry.new{
        title   = node.title,
        author  = node.author,
        format  = "epub",
        year    = node.year,
        cover   = ("https://www.gutenberg.org/cache/epub/%d/pg%d.cover.medium.jpg"):format(node.gutenberg, node.gutenberg),
        locator = { file = node.file },
        size    = node.size,
        path    = path,
    }
end

-- One page of a list: rows first..first+limit-1, has_more.
local function page_of(all, limit, page)
    local first = (page - 1) * limit + 1
    local slice = {}
    for i = first, math.min(#all, first + limit - 1) do slice[#slice + 1] = all[i] end
    return slice, #all > first + limit - 1
end

-- The items of a folder locator (nil = the root) and the titles above them.
local function folder_items(locator)
    if locator == nil then return TREE, {} end
    local hit = type(locator) == "table" and FOLDERS[locator.folder]
    if not hit then return nil end
    return hit.node.items, below(hit.path, hit.node.title)
end

local function find(items, path, query, limit, page, ctx)
    local q = query:lower()
    local hits = {}
    walk(items, path, function(node, above)
        local hay = (node.title .. " " .. (node.author or "")):lower()
        if q ~= "" and hay:find(q, 1, true) then hits[#hits + 1] = row(node, above, ctx) end
    end)
    return page_of(hits, limit, page)
end

function P.search(query, limit, page, ctx)
    return find(TREE, {}, query, limit, page, ctx)
end

function P.list(locator, limit, page, ctx)
    local items = folder_items(locator)
    if not items then return nil, "this folder is gone" end
    local nodes, more = page_of(items, limit, page)
    local rows = {}
    -- No path: the host saves these files under the folder that listed them.
    for i, node in ipairs(nodes) do rows[i] = row(node, nil, ctx) end
    return rows, more
end

function P.search_in(locator, query, limit, page, ctx)
    local items, path = folder_items(locator)
    if not items then return nil, "this folder is gone" end
    return find(items, path, query, limit, page, ctx)
end

function P.resolve(locator, _ctx)
    local node = type(locator) == "table" and FILES[locator.file]
    if not node then return nil, "no such file" end
    return ("https://www.gutenberg.org/ebooks/%d.epub.noimages"):format(node.gutenberg)
end

return P
