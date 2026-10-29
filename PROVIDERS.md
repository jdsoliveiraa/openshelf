# OpenShelf provider contract — api 1

> Normative spec for provider authors. Design record and host-side plan:
> `DESIGN.md` §9 (decisions 37–57, grilled 2026-10-26). Status: **implemented**
> as of v0.6.0 — the built-ins and the host both use api 1.

A **provider** turns one catalog into OpenShelf search results and download
URLs. Project Gutenberg, Internet Archive and DOAB are providers; so is
anything you write against this file. A provider is one Lua table. It can
ship three ways (§8): inside OpenShelf, as its own KOReader plugin, or as a
single file dropped into a folder on the device.

Everything runs on the device's **LuaJIT (Lua 5.1 semantics)**: no `//`, no
`\u{}` escapes, `%w`/`%a` match ASCII only.

## 1. A complete example

```lua
-- A fictional catalog at https://books.example.org with a JSON API.
local P = {
    api  = 1,
    id   = "examplebooks",
    name = "Example Books",
    quality = 70,
    enabled_by_default = true,
    shelves = {
        { key = "popular", title = "Popular on Example Books" },
    },
    settings = {
        { key = "token", title = "API token", type = "secret", required = true,
          hint = "From your account page on books.example.org" },
        { key = "lang", title = "Language", type = "choice",
          choices = { "any", "en", "pt" }, default = "any" },
    },
}

local BASE = "https://books.example.org/api"

local function headers(ctx)
    return { ["Authorization"] = "Bearer " .. ctx.settings.token }
end

-- Pure: API payload -> entries. Keeping this separate makes it unit-testable.
function P.parse(data, ctx)
    local entries = {}
    for __, book in ipairs(data.items or {}) do
        if type(book.epub_url) == "string" then
            entries[#entries + 1] = ctx.Entry.new{
                title       = book.title,
                author      = book.author,
                format      = "epub",
                cover       = book.cover_url,
                locator     = { url = book.epub_url },
                description = book.summary,
                language    = book.lang,
                year        = book.year,
            }
        end
    end
    return entries
end

function P.search(query, limit, page, ctx)
    local url = string.format("%s/search?q=%s&limit=%d&page=%d&lang=%s",
        BASE, ctx.url_escape(query), limit, page, ctx.settings.lang or "any")
    local data, err = ctx.http.getJSON(url, { headers = headers(ctx) })
    if not data then return nil, err end
    -- JSON null decodes to a *function* on the device (§4.4): test the type.
    return P.parse(data, ctx), type(data.next_page) == "number"
end

function P.browse(key, limit, ctx)
    local url = string.format("%s/%s?limit=%d", BASE, key, limit)
    local data, err = ctx.http.getJSON(url, { headers = headers(ctx) })
    if not data then return nil, err end
    return P.parse(data, ctx)
end

function P.resolve(locator, ctx)
    if type(locator) == "table" and locator.url then
        return { url = locator.url, headers = headers(ctx) }
    end
    return nil, "no download URL for this book"
end

function P.check(ctx)
    local data, err = ctx.http.getJSON(BASE .. "/me", { headers = headers(ctx) })
    if not data then return false, err end
    return true, "Signed in as " .. tostring(data.name)
end

return P
```

## 2. The provider table

| Field | Type | Required | Meaning |
|---|---|---|---|
| `api` | integer | yes | Contract version. Must be exactly `1`. Anything else is rejected (§8.5). |
| `id` | string | yes | Stable key, `^[a-z][a-z0-9_]*$`, at most 32 bytes. Keys settings, result slots, library records and `Entry.id`. **Never change it** once released: records on users' devices carry it. |
| `name` | string | yes | Display name, at most 60 bytes. Shown in rows, the detail page, Sources and the filter dialog. May change freely. |
| `quality` | number | no | Prefer-best-edition rank, default `0`. Used for rows that set no `quality` of their own. Built-ins: Gutenberg 80, Internet Archive 60, DOAB 50; 100 is reserved for Standard Ebooks. |
| `enabled_by_default` | boolean | no | Default `true`. Set `false` for sources that need setup first; the user turns them on in Sources. |
| `shelves` | list | no | `{ { key = "popular", title = "Popular on …" }, … }`. `key` follows the `id` pattern. Requires `browse`. |
| `settings` | list | no | Field schema rendered in the source's submenu (§7). |
| `search` | function | yes | §5.1 |
| `resolve` | function | yes | §5.2 |
| `browse` | function | if `shelves` | §5.3 |
| `check` | function | no | §5.4 |

Unknown fields are ignored, so you may keep helpers (like `parse` above) on
the table.

## 3. `ctx` — everything the host hands you

Every function receives `ctx` as its last argument. **Do not `require`
OpenShelf modules**; when KOReader loads a `provider-*` plugin, OpenShelf's
folder is not yet on `package.path`, and in-tree providers must stay loadable
by the offline tests. `ctx` is the whole API:

| Member | What it is |
|---|---|
| `ctx.http.getBody(url, opts)` | GET → body string, or `nil, err`. |
| `ctx.http.getJSON(url, opts)` | GET + decode → table, or `nil, err`. |
| `ctx.http.head(url, opts)` | HEAD → headers table (lower-case keys), or `nil, err`. |
| `ctx.http.download(url, path, opts)` | Stream to disk. Providers normally never call this; the host downloads. |
| `opts` | `{ headers = {…}, block_timeout = s, total_timeout = s }`, all optional. The User-Agent is set for you. |
| `ctx.json.decode(s)` / `ctx.json.encode(t)` | KOReader's JSON. See §4.4 for the `null` quirk. |
| `ctx.url_escape(s)` | Percent-encode a query-string value. |
| `ctx.settings` | The user's values for your `settings` fields, keyed by field `key`, defaults applied. Empty text is `nil`. |
| `ctx.Entry` | Entry constructors (§4). |
| `ctx.OPDS.parse(xml)` / `ctx.OPDS.acquisition_href(links, mime)` | Minimal OPDS/Atom parser for feeds. |
| `ctx.log(...)` | Writes to KOReader's log (`crash.log` on the Kobo), prefixed with your `id`. |

## 4. Entries

### 4.1 Constructor
```lua
ctx.Entry.new{
    action      = "download",      -- "download" (default) | "borrow" | "buy"
    title       = "…",             -- missing → "Untitled"
    author      = "…",             -- missing → "Unknown"
    format      = "epub",          -- "epub" (default) | "pdf" | … ≤ 8 bytes; becomes the file extension
    quality     = 70,              -- optional; default = your provider's quality
    cover       = "https://…jpg",  -- optional; unauthenticated JPEG/PNG URL
    locator     = { url = "…" },   -- required; see 4.2
    alternates  = { { format = "pdf", locator = { url = "…" } } },  -- optional
    description = "…", language = "en", year = "1813",            -- optional
    price       = "€4.99",         -- buy rows only, optional
}
```
`ctx.Entry.download{…}` is `new` with `action = "download"`. Every string is
trimmed, whitespace-collapsed and length-capped; non-strings (including JSON
`null`) become absent.

The host then **stamps** `provider = <your id>` and `source = <your name>` on
every row, fills `quality` from your provider when a row has none, and computes
`dedup_key` from title + author. You cannot label rows as another source.

### 4.2 Locator
A locator is a plain table of **strings and numbers only** that your
`resolve` can turn into a file URL later, in another process. The host never
interprets it, except for identity: `locator.url`, else `locator.identifier`,
else `locator.id`, else every field sorted by name. At least one field is
required; rows without a usable locator are dropped with a log line.

`Entry.id = provider .. "|" .. locator identity`. Two rows with the same id are
the same file. The "downloaded ✓" and My books records key on it, so a
locator must be **stable across searches** for the same file.

### 4.3 Actions
- **download** — `resolve` gives a DRM-free file; the detail button reads
  *Download*. Hold on a row downloads immediately.
- **borrow** — same pipeline, the provider does whatever auth its catalog
  needs inside `resolve` (token in `ctx.settings`, headers in the result). The
  button reads *Borrow*; the file is recorded in My books like any download.
  There is no expiry or return concept.
- **buy** — `locator.url` is a **web page**. OpenShelf shows it as text plus a
  QR code (the Kobo has no browser) and never downloads. `price` is shown in
  the metadata line when present. `resolve` is not called for buy rows.

Results group by action only when more than one action is present. For
dedupe, borrow and buy rows are ranked **below any download** of the same
work: a free edition always wins; a store row shows only when no free one
exists.

### 4.4 JSON and the `null` quirk
Rows cross a pipe as JSON and are persisted, so they must contain only
strings, numbers, booleans and tables — **no functions, no cycles**. The
constructor guarantees that if you pass it plain values.

KOReader's JSON decodes `null` as a **function**, not `nil`. `if data.x then`
is true for a null `x`. Test types (`type(v) == "string"`) when reading API
payloads; the constructor already does this for every field you pass it.

## 5. Functions

All four run **in a forked child process** on the device (inline on the macOS
emulator) under a **60-second deadline**. When the deadline hits, the child is
killed and the source's slot reads "timed out". Return normally or return
`nil, "message"`; throwing with `error()` is also caught and shown as the
source's error. Never touch UI, never write to disk, keep no state between
calls (every call may be a fresh process copy; module-level sockets or caches
will not behave).

### 5.1 `search(query, limit, page, ctx) → entries, has_more`
`query` is the user's text as typed; sanitize it for your backend (see the
Internet Archive provider for a Lucene example). `limit` is the page size the
user chose (10, 15 or 30); return at most that many. `page` starts at 1 and
increases by one on *Load more*. `has_more` is a boolean; when unsure, a full
page means "maybe more". No results is `{}, false`, not an error.

### 5.2 `resolve(locator, ctx) → url | { url =, headers = }, err`
Called at download time, once per file. Return a plain URL string, or a table
with `url` and optional `headers` (e.g. `Authorization`) that the host sends
with the GET. A borrow row resolves here too. Return `nil, "reason"` when the
file is not available; the reason is shown to the user verbatim.

### 5.3 `browse(key, limit, ctx, page) → entries, has_more`
`key` is one of your `shelves` keys. `limit` is the browse page size (32
today), the same on every page; return up to `limit` rows (fewer is fine).
The home row shows only as many covers as fit; *See all* shows the whole
page. `page` starts at 1 and is optional: absent or `nil` means 1. Page 1 is
cached on disk for 24 h under `<id>:<key>` and shown as a home shelf while
the source is enabled and its "Shelves on home" toggle is on; the shelf's
*See all* opens on that cached page.

`has_more` is a boolean, as in §5.1: `true` when another page exists. *See
all* then ends in *Load more*, which calls `browse` again with `page + 1`.
The host asks for page N+1 only after page N returned `has_more == true`.
On failure return `nil, "message"` as before (second value = error).

**Older providers keep working.** A `browse(key, limit, ctx)` that ignores
`page` and returns entries alone (or anything but `true` as the second value)
is a single-page shelf: the home row is unchanged and *See all* lists those
rows with no *Load more*. Return `has_more = true` only when you honour
`page`, or *See all* would append the same rows again.

### 5.4 `check(ctx) → ok, message`
Optional. Shown as **Test connection** in your source's submenu. Make one
cheap request that proves the settings work and return `true, "Signed in as
…"` or `false, "reason"`. The message is shown as a toast.

## 6. Rules that are policy, not code

- **DRM-free only.** OpenShelf downloads and opens only files the user may
  keep and read without a DRM client. A provider that would hand over Adobe
  or LCP-protected files, `.acsm` tickets, or borrow-only lending files does
  not belong here. The host does not inspect files; you are trusted to honor
  this.
- **Be a good client.** Use the catalog's API where one exists; never scrape
  a site that forbids it. Standard Ebooks in particular bans IPs that follow
  its honeypot links — use its authenticated OPDS feed, never its HTML.
- **Only openly licensed or public-domain catalogs** for download rows.
  Borrow and buy rows exist so legitimate libraries and stores can be
  *discovered*; they still deliver DRM-free files or link out.
- Providers run with the same rights as any KOReader plugin. The host guards
  against bugs (pcall, deadline, row normalization), not against malice.

## 7. Settings and setup

Each `settings` field:

```lua
{ key = "token",            -- ^[a-z][a-z0-9_]*$; the name in ctx.settings
  title = "API token",      -- row label
  type = "text" | "secret" | "toggle" | "choice",
  required = true,          -- optional, text/secret/choice only
  default = "any",          -- optional
  choices = { "any", "en" },-- choice only; tapping cycles through them
  hint = "…" }              -- optional one-liner under the input
```

- `text` opens the stock input dialog; the value shows in the row's right
  column. `secret` is the same but masked with dots. `toggle` shows a check
  mark. `choice` cycles on tap, like *Results per source*.
- Values are stored in OpenShelf's settings file under
  `provider_settings[<id>]`, **in plain text**, like every other KOReader
  plugin credential. Say so in your `hint` if that matters for your service.
- A source with a `required` field left empty is **not searched** and takes
  no result slot. Its row in Sources reads *Needs setup*; opening it lands on
  the empty field. Nothing is logged to the status strip.
- The submenu for a source is: *Enabled* toggle · your fields in declared
  order · *Test connection* when you define `check` · *Shelves on home* when
  you declare `shelves`.

## 8. Shipping a provider

Three ways in. All three go through the same registration and validation, so
a provider file is the same in each.

### 8.1 In-tree (pull request)
Put `openshelf.koplugin/providers/<id>.lua` next to the built-ins and add it
to the ordered list in `openshelf.koplugin/openshelf_providers.lua`. Keep a
pure `parse(data, ctx)` and cover it in `test/unit.lua`, then add it to the
`BUILTINS` list in `test/headless_providers.lua`, which runs
`tools/provider_check.lua` live over every built-in. Mark known quirks there
(DOAB, for example, 403s from datacenter IPs).

### 8.2 Your own KOReader plugin
Folder name **`provider-openshelf-<id>.koplugin`**. KOReader loads folders
whose name starts with `provider` before all other plugins and offers them in
*Plugin management* like any plugin. Three files. Start by copying
`provider-openshelf-template.koplugin/` from the OpenShelf repo; it has all
three:

```lua
-- _meta.lua
local _ = require("gettext")
return {
    fullname = _("OpenShelf: Example Books"),
    description = _("Adds the Example Books catalog to OpenShelf."),
}
```

```lua
-- main.lua
local Provider = require("provider")          -- KOReader core registry
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Plugin = WidgetContainer:extend{ name = "provider-openshelf-examplebooks" }

function Plugin:init()
    -- KOReader's registry only accepts features on its built-in list, and
    -- "openshelf" is not on it, so create the slot first. Required.
    Provider.features.openshelf = Provider.features.openshelf or {}
    Provider:register("openshelf", "examplebooks",
        dofile(self.path .. "/openshelf_examplebooks.lua"))
end

return Plugin
```

```lua
-- openshelf_examplebooks.lua : the provider table from §1
```

Load the provider file with `dofile(self.path .. …)`, not `require`: KOReader
has **one flat `require` namespace** across core and every plugin, and a
module called `provider`, `util`, `json` or `version` would silently be
KOReader's own. Prefix any extra module you do `require` with
`openshelf_<id>_`.

OpenShelf reads the registry when it opens, not at startup, so registering in
`init()` is fine whatever the plugin load order. If OpenShelf is not installed,
the `require("provider")` line still works and the registration is simply
never read.

### 8.3 Drop-in file
Copy a file that `return`s the provider table into
`<KOReader settings>/openshelf/providers/` — on a Kobo:
`/mnt/onboard/.adds/koreader/settings/openshelf/providers/`. OpenShelf creates
the folder on first open and leaves a `README.txt` pointing here. The file
name does not matter; the `id` comes from the table. Files are scanned every
time OpenShelf opens but each is loaded **once per KOReader process**, so
restart KOReader after editing.

### 8.4 Order, defaults, duplicates
- Registration order: built-ins, then plugins (by id), then drop-ins (by id).
  New sources append to the end of the user's arranged order; the user can
  move them in *Sources → Arrange sources*.
- `enabled_by_default` is honored for every provider. Installing is the
  opt-in.
- A second provider with an already-registered `id` is rejected and shown
  dimmed in Sources as *duplicate id <id>*. Nothing can silently replace a
  source.

### 8.5 Invalid providers
A table that fails validation — wrong `api`, bad `id`, missing `search` or
`resolve`, `shelves` without `browse`, a load error in the file — is **listed
dimmed in Sources with the reason** and logged. It never blocks the others
and never shows a modal.

## 9. What the host does with your provider

- One **result slot** per enabled source, in the arranged order; your rows
  stay in your slot however early or late your child returns. A failure or
  timeout shows as `<name>: <reason>` in the status strip, never a dialog.
- *Load more* calls `search` again with `page + 1` for every source that said
  `has_more`.
- A shelf's *See all* opens on the cached page 1; when that page said
  `has_more`, *Load more* calls `browse` with `page + 1` and appends the rows
  (rows already shown are skipped). A failed page shows in the list's status
  strip and *Load more* stays to retry.
- The **filter dialog** lists sources in the same order; filtering happens
  before dedupe so "only Example Books" shows your edition even when a
  higher-quality one exists elsewhere.
- Downloads go to `/mnt/onboard/OpenShelf/<Author> - <Title>.<format>` and
  are recorded in My books with your `id`, `name` and the locator.
- Covers are fetched by URL in a background job and cached on disk. They must
  be reachable **without headers** in api 1.

## 10. Testing

```bash
# offline contract + live round trip, no KOReader needed
eval "$(luarocks --lua-version=5.1 path)"
luajit tools/provider_check.lua path/to/openshelf_examplebooks.lua "pride and prejudice" \
    --set token=abc123
```

```
luajit tools/provider_check.lua <provider.lua> ["query"] [flags]
  --set key=value   a value for one of your settings fields (repeatable)
  --limit N         page size passed to search (default 10)
  --download        also download the resolved file and check it is an EPUB or PDF
  --offline         skip the tool's own network steps (HEAD, cover, download)
```

The query defaults to `"pride and prejudice"`; pick one your catalog has hits
for. `provider_check` runs, in order:

1. **load + validate** — `dofile`s the file and applies the §2 rules
   (including the §7 field schema).
2. **settings** — `--set` values go through the host's own rules: undeclared
   keys are ignored with a warning, defaults apply, empty text is `nil`,
   toggles take `true`/`false`. A `required` field left out fails here.
3. **check** — your `check(ctx)`, when you define one.
4. **search** — `search(query, limit, 1, ctx)` with the shims the headless
   test uses. Fails on an error, no rows, more rows than `limit`, or a
   non-boolean `has_more`.
5. **rows** — every row must be plain data (no functions, no cycles), have a
   locator of strings and numbers with a usable identity (§4.2), a known
   `action`, and keep that identity through a JSON round trip.
6. **shelves** — `browse(key, 32, ctx, 1)` (32 = the browse page size) for
   every shelf, same row checks; fails on more rows than that `limit` or a
   `has_more` that is neither a boolean nor absent. When page 1 says `has_more = true`, page 2 is fetched and checked
   the same way, and fails if it repeats a row of page 1 (`page` ignored).
7. **resolve** — the first row that is not a buy row, from its *round-tripped*
   locator (as a fresh process would), through the host's normalization.
8. **head** — HEADs the URL with the resolved headers; reports content type and
   size.
9. **cover** — the first row's cover must load **without headers** and be a
   JPEG, PNG or GIF.
10. **download** — only with `--download`: the whole file, checked for EPUB
    (zip) or PDF magic, then deleted.

Exit status: `0` on pass, `1` on any failure, `2` on a usage error.
`--offline` stops after step 7. Your own `ctx.http` calls still go out, so
`--offline` is for checking a stub or a recorded-payload provider.

The repo ships two starting points that pass the tool:
`provider-openshelf-template.koplugin/` (the §8.2 plugin folder with a stub
provider that searches a built-in list, so it works offline) and
`examples/gutenberg_pt.lua` (a §8.3 drop-in against a live API).

On the emulator (`scripts/emu.sh`), a drop-in file in `.kohome/settings/…`
or a plugin folder in `.kohome/plugins/` is picked up like on the device.
`scripts/emu.sh --template` links the template plugin.
`tools/emu-external-check.lua` drives the external path (template, example,
and a broken drop-in) and takes screenshots.

Unit-test your `parse` with recorded payloads, the way the built-ins do.

## 11. Versioning

`api` is an integer. The host accepts exactly the versions it implements
(today: `1`) and dims anything else. Adding optional fields to the contract
does **not** bump the version; changing or removing behaviour does. The
changelog lives at the bottom of this file.

## 12. Checklist before you publish

- [ ] `id` is final and lower-case; `name` reads well in a 2-cm badge
- [ ] `search` sanitizes the query for your backend and returns `{}, false` on no hits
- [ ] every row has a stable locator; `resolve` works from a *fresh process*
- [ ] rows are download / borrow only for DRM-free files; buy rows link to a page
- [ ] `required` settings declared; `check` proves them
- [ ] `tools/provider_check.lua` passes against the live service
- [ ] no `require` of OpenShelf or KOReader modules inside the provider file

---

### Changelog
- **api 1** (spec 2026-10-26, shipped in v0.6.0) — initial contract.
- **api 1, additive** (#12, 2026-10-29) — `browse` takes an optional 4th
  argument `page` and may return `has_more` (§5.3); *See all* pages with
  *Load more*. Providers without it are single-page shelves, as before.
