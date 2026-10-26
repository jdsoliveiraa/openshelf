# OpenShelf

A [KOReader](https://github.com/koreader/koreader) plugin that lets you **search
free & public-domain ebook catalogs and download them straight to your device** —
no PC, no cable, no Calibre round-trip.

```
Main menu → OpenShelf → home (search · recents · My books · browse shelves)
   → results (list or grid) → book detail → Download → Open
```

## Sources

OpenShelf only integrates **legal, openly-licensed, or public-domain, DRM-free**
catalogs.

| Provider          | What it is                                        | Status |
| ----------------- | ------------------------------------------------- | ------ |
| Project Gutenberg | ~70k public-domain classics (Gutendex API); also feeds the Popular / New shelves | ✅ working |
| Internet Archive  | Public-domain texts with EPUBs, sorted by downloads; lending-library (borrow-only) items are excluded¹ | ✅ working |
| DOAB              | Open-access scholarly books (DSpace REST), EPUB or PDF | ⚠️ 403 since 2026-10² |

¹ Most Internet Archive hits for popular titles are borrow-only: they list an
EPUB that answers 401 without an archive.org login. The query excludes
`access-restricted-item:true` and `resolve()` refuses one that slips through.
² DOAB's legacy `/rest` search currently answers 403 Forbidden, from the Kobo
as well as from a laptop; the source shows as errored and never blocks the
others. Being investigated (see `TODO_CLARA_HD.md`).

**Why not Standard Ebooks / Feedbooks?** Standard Ebooks bans scrapers (its
download links are honeypots) and gates its OPDS feed behind a patron login; it
may return as an opt-in authenticated-OPDS provider (`opds.lua` is kept for
that). Feedbooks discontinued its free public-domain OPDS.

> OpenShelf never touches Adobe-DRM'd books (library/purchase). Those stay in
> the stock Kobo reader.

## Screens (v0.5)

The full design record with every decision is in [DESIGN.md](DESIGN.md).

- **Home** — a search row, recent searches (tap to re-run, hold to remove), a
  *My books* shelf, and *Popular on Gutenberg* / *New on Gutenberg* shelves
  served from a 24-hour cache. Gear → settings, X → leave.
- **Results** — replace the home body; back returns to home. A toolbar shows
  the count and per-source status, a **filter** (sources, format) and a
  **list/grid** toggle. Tap a book for its detail page; **hold to download it
  on the spot**, with progress drawn on the row. "Load more" fetches the next
  page from every source that has one.
- **Detail** — large cover, title, author, source · format · language · year
  (only what the source knows), description, and one button: Download →
  progress with Cancel → Open / Done. EPUB/PDF chips when both exist.
- **My books** — everything you downloaded, shelved by KOReader's own reading
  status: Reading now (with progress), Not started, Finished. Files deleted
  outside OpenShelf stay listed, dimmed, with *Download again*; hold to remove.
- **Settings** — sources, default view, results per source, clear recents,
  home mode, About.
- **Home mode** — OpenShelf opens when KOReader starts and again after every
  book, so it behaves like the app; X on the home screen shows KOReader's file
  manager underneath. Off by default (gear → Home mode).

Downloaded books are also added to a KOReader **Collection** named "OpenShelf".

## Where books are saved

`OpenShelf/` at the root of the device (`/mnt/onboard/OpenShelf` on Kobo), a
visible folder, so books show in the stock Kobo library as well as in KOReader.
Files are named `Author - Title.epub` (or `.pdf`).

## Architecture

Flat module layout — KOReader puts a plugin's folder on the Lua path, so
siblings `require` each other by filename. Names are chosen not to collide with
KOReader's own modules (`test/unit.lua` checks).

```
openshelf.koplugin/
  main.lua                 plugin entry: main-menu item, Dispatcher action, dev hooks
  app.lua                  shared context: library singleton, view stack, book status, helpers
  view_base.lua            full-screen view base: title bar, rows + hit-testing, paging
  view_home.lua            home + results modes
  view_detail.lua          book detail / download
  view_list.lua            "See all" list/grid
  view_mybooks.lua         My books by reading status
  pane_results.lua         list rows / grid cells for a page of entries
  widget_shelf.lua         shelf = header + one row of covers
  dialog_filter.lua        sources + format filter (ButtonDialog)
  settings_menu.lua        settings (stock Menu)
  uiparts.lua              widget builders (text, rows, buttons, covers, progress)
  glyphs.lua               Nerd Font glyphs (KOReader bundles no emoji font)
  layout.lua               grid / shelf / paging math (pure)
  entry.lua                result model: plain data + locator (pure)
  results.lua              slot-ordered results, filter, dedupe (pure)
  dedupe.lua               collapse duplicate editions, prefer best quality (pure)
  catalog.lua              provider registry, searchOne/searchAll, resolve, browse, group
  searcher.lua             one subprocess per provider, results land in slots
  jobs.lua                 forked background jobs polled by the UI (inline on the macOS emulator)
  downloader.lua           download queue (one at a time), progress by file-size polling
  covers.lua               cover disk cache + subprocess fetch + decode
  browse.lua               Gutenberg popular/new shelves with a 24 h TTL cache
  library.lua              My books records (pure; JSON file via jsonfile.lua)
  collection.lua           KOReader Collection + reading-status bridge
  settings.lua             sources, default view, per-source count, recents
  ttlcache.lua, hashkey.lua, jsonfile.lua, http_util.lua, opds.lua
  providers_gutendex.lua, providers_internetarchive.lua, providers_doab.lua
```

### Entries are plain data
Every result is an entry with a `locator` (`{url=…}` or `{identifier=…}`);
its provider's `resolve(locator)` turns that into a file URL at download time.
Entries cross subprocess pipes as JSON and are what My books persists.

### Adding a provider
Create `providers_<name>.lua` exposing `name`, `search(query, limit, page) ->
entries, has_more`, `resolve(locator) -> url`, and optionally `browse(kind,
limit)`. Build entries with `Entry.download{…}`. Register it in `catalog.lua`
and give it a `quality` in `entry.lua`.

## Install

1. Install KOReader on your device.
2. Copy `openshelf.koplugin/` into KOReader's `plugins/` directory
   (`.adds/koreader/plugins/` on Kobo), or use `scripts/deploy.sh` over SSH.
3. Restart KOReader → **OpenShelf** appears in the main menu. You can also bind
   the *OpenShelf* action to a gesture (it is registered with the Dispatcher).
4. Kobo, optional: `scripts/deploy-launcher.sh` installs a KFMon watch, its
   script, an icon and an *Import books* NickelMenu entry (`kobo/`). After one
   reboot, **OpenShelf** shows in NickelMenu and starts KOReader with OpenShelf
   as the home screen for that session (`OPENSHELF_AUTOOPEN=1`). Nickel only
   imports new files after a USB session, so tap *Import books* once for the
   library tile, and whenever you want Wi-Fi downloads to show in the stock
   library. Turn on *Home mode* in the settings to get the same behaviour when
   KOReader is launched normally.

## Development

```bash
luacheck .                                   # lint (std = luajit)
luajit test/unit.lua                         # offline unit test, no network
eval "$(luarocks --lua-version=5.1 path)"; luajit test/headless_providers.lua "pride and prejudice"   # live APIs
scripts/emu.sh                               # KOReader emulator with the plugin (see CLAUDE.md)
scripts/emu.sh --walk tools/emu-walkthrough.lua --shots /tmp/shots   # scripted UI walkthrough + screenshots
```

## Roadmap

- [ ] Standard Ebooks via **authenticated OPDS** (opt-in, patron token)
- [ ] **Discovery bridge**: surface borrow (library) / buy availability as
      `borrow`/`buy` entries that deep-link to the Kobo/Libby app (no DRM in-app)
- [ ] More sources (reliable + DRM-free only)

## License

MIT — see [LICENSE](LICENSE). KOReader itself is AGPL-3.0.
