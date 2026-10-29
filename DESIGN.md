# OpenShelf UI redesign — design record (v0.5)

> Outcome of a grilling session on 2026-10-26. Thirty-six decisions, every branch
> visited, nothing silently assumed. §9 adds decisions 37–57 (modular
> providers, a second session the same day; contract in `PROVIDERS.md`); §10 adds 58–63 (self-update);
> §11 adds 64–67 (shelf paging);
> §12 adds 68–86 (folders, api 2). **Don't relitigate without a reason**; if
> something here turns out to be wrong on-device, change it and note why.
> Device facts (Kobo Clara HD, 1072×1448 @ 300 dpi, e-ink) live in
> `TODO_CLARA_HD.md`. Project constraints live in `CLAUDE.md`.

## 1. Principles

- **Native chrome, custom content.** Stock KOReader TitleBar, Menu, dialogs,
  keyboard and gestures everywhere. Custom layouts only where KOReader has
  nothing: result rows/cells with covers, the book detail page, the shelves.
- **The screen never blocks on the network.** Anything that talks to a server
  runs in a forked subprocess and the UI polls it. Placeholders first, data
  swapped in when it lands.
- **Results survive.** Opening a book, downloading it, cancelling — none of
  that destroys the results you were looking at.
- **No emoji.** KOReader bundles no emoji font (📚 and 🛒 render as tofu on the
  Clara). Icons are Nerd Font glyphs from KOReader's bundled `symbols.ttf`,
  the same idiom the stock OPDS browser uses.
- **Single release, verified on the emulator first**, then the device.

## 2. Screens

### 2.1 Entry
- The **main-menu item "OpenShelf" opens the home screen directly**. The old
  submenu (Search / Sources / Covers / About) is gone.
- A **Dispatcher action** ("OpenShelf") is registered so the home screen can be
  bound to a gesture or shortcut. Works from both the file manager and the reader.

### 2.2 Home
Title bar: **gear (left) · "OpenShelf" · X (right)**. Body, top to bottom:

1. **Search row** — looks like a text field with a search glyph. Tap opens the
   stock InputDialog with the keyboard up. After a search the row shows the last
   query.
2. **Recent searches** — up to 8 rows. Tap re-runs; hold deletes.
3. **My books shelf** — header "My books" + "See all" on the right; one row of
   covers sized to fit the width (no horizontal scrolling). Tap a cover → detail.
   "See all" → the My books screen (§2.5). Hidden when empty.
4. **Browse shelves** — "Popular on Gutenberg" and "New on Gutenberg" (Gutendex
   default popularity sort, and newest-first). Same shelf layout. Data + covers
   come from a **disk cache with a 24 h TTL**: render instantly from cache; if
   stale and online, refresh in a background subprocess and repaint. Offline with
   no cache → shelf hidden. Only Gutenberg for now (Internet Archive's popular
   texts are noisy; DOAB has no useful browse).

Home must open instantly offline. Searching triggers KOReader's usual
"turn on Wi-Fi?" prompt.

### 2.3 Results
Results **replace the home body**; the search row stays visible on top so the
query can be refined. **Back arrow returns to home** with the last query shown.

Chrome:
- Title bar: **back (left) · query · X (right)**.
- **Toolbar strip** under the title bar: left side shows `23 results` and, while
  searching, `Searching Internet Archive…` (per-provider status) and the
  errors/duplicates note (tap for details). Right side: **Filter** glyph and
  **List/Grid** glyph.
- Filter opens a dialog: a checkbox per source, format EPUB / PDF / any. Applies
  instantly to the loaded results (no re-search). No sort — there is no sane
  cross-provider relevance key.

Layouts (toggle in the toolbar; **list is the default**, remembered in settings):
- **List row**: cover (left) · **bold title** · author · small right-aligned
  `Source · FORMAT` badge · ✓ when downloaded. Title and author truncate with an
  ellipsis on one line each.
- **Grid**: **3 columns × 3 rows** on the Clara (columns derive from screen
  width; no separate landscape design). Cover ~300 px wide; title + author
  caption under each (truncated). Source badge and ✓ overlay a cover corner.

Behaviour:
- **Group headers only when more than one action type exists** (today: never).
  When they do appear they use Nerd Font glyphs (download / cart), not emoji.
- **Fixed provider order**: Gutenberg block, then Internet Archive, then DOAB,
  regardless of which subprocess finishes first. A late provider fills its slot;
  a higher-quality duplicate **upgrades the existing row in place**
  (dedupe + prefer-best-edition is unchanged).
- A **"Load more"** row ends the list; it fetches the next page from every
  provider that reported more, dedupes against what is shown, and appends.
- **Tap → detail. Hold → download immediately**, with progress drawn on the row
  (thin bar under the text, badge becomes a percentage) or cell (bar under the
  cover). On completion the ✓ appears. Tapping a row mid-download opens detail
  with Cancel.
- Leaving the results screen **kills in-flight provider subprocesses**; rows
  already shown stay until you leave.
- The "downloaded" ✓ marks the **exact edition** (same source + locator), not
  any edition of the same work.

### 2.4 Detail
Opens **over** results (results survive). Title bar: back · title · X.
- Large cover, title, author.
- **One metadata line with only the fields the provider returned**
  (`Source · FORMAT · language · year`), missing fields hidden — never "Unknown".
- Scrollable description when the provider has one (Gutendex `summaries`,
  IA `description`, DOAB abstract).
- **Format picker** when both EPUB and PDF exist.
- **Primary button**: `Download` → `Open` once on disk (hold = re-download) →
  `Download again` when the record exists but the file is gone.
- **Progress bar** (ProgressWidget) under the button with bytes / percent when
  Content-Length is known, plus **Cancel**.
- Success: a small "Saved to OpenShelf folder" line, buttons **Open / Done**.
  The on-device path is never shown. The results row behind gets its ✓.

### 2.5 My books (dedicated screen)
Title bar: back · "My books" · X. Three shelves, same shelf component as home:
- **Reading now** — covers with KOReader's reading progress (%) underneath.
- **Not started**
- **Finished**

Status comes from **KOReader's per-book sidecar** (percent read, finished
flag); OpenShelf tracks nothing of its own. Each shelf's "See all" opens the
list/grid view sorted by download date, newest first.

Missing file (deleted outside OpenShelf): **record stays**, cover dimmed with a
"not on device" marker, detail button reads `Download again`. Hold on the row →
`Remove from My books`.

### 2.6 Settings (behind the gear)
- Sources: a toggle per provider.
- Default results view: list / grid.
- Results per source: 10 / 15 / 30.
- Clear recent searches.
- About: version, sources, download folder.

**Removed:** the "Show cover thumbnails" toggle and the text-only results
fallback. Covers are always on; a missing cover shows a placeholder.

## 3. Data and architecture

### 3.1 Entries are plain data
Subprocess results cross a pipe as text, and My books records are persisted, so
an entry can no longer carry a `resolve` closure. Each entry carries a
**`locator`** (`{url=…}` for Gutenberg/DOAB, `{identifier=…}` for Internet
Archive) and every provider gains **`resolve(locator) → url, err`**, run at
download time. `Entry.ACTION_HEADING` loses its emoji.

### 3.2 Search
One **forked subprocess per enabled provider** (`ffi/util.runInSubProcess`
with a pipe, the mechanism behind `Trapper:dismissableRunInSubprocess`). The main
process polls on a UIManager schedule, parses each provider's JSON as it lands,
inserts it into that provider's slot, dedupes, repaints. Status strip updates per
provider. Per-provider errors go to the strip note, never a modal.

### 3.3 Download
A subprocess streams to `<target>.part`. The main process polls the partial's
size every ~0.5 s against Content-Length (written by the subprocess to a sidecar
after the first response). Cancel kills the subprocess and deletes the partial.
On success the file is renamed into place. **Queue, one at a time**: holding
several rows queues them; queued rows say "Queued".

Files go to **`/mnt/onboard/OpenShelf`** (as in v0.4).

### 3.4 Covers
Covers are fetched **per page in a subprocess** into a **disk cache**
(`<KOReader cache dir>/openshelf/<sha1(url)>.jpg`). A page renders at once with
placeholders; rows repaint as files land. The main process decodes from disk
(native size, scaled once, as in v0.4). My books records point at cached cover
files, so they show offline. Cache is bounded (LRU by mtime, size cap in settings
later if needed).

### 3.5 Library (My books)
On first successful download, OpenShelf:
1. Appends a record to its own JSON library file
   (`title, author, source, format, locator, dedup_key, cover_file, path, downloaded_at`).
2. Adds the file to a **KOReader Collection named "OpenShelf"** so it also shows
   in the stock file manager's Collections.

Downloaded state in results = a library record with the same source + locator,
and the file present on disk.

### 3.6 Browse cache
Gutendex popular + newest responses are cached on disk with a 24 h TTL alongside
their covers. Refresh runs in a subprocess when stale and online.

## 4. Verification and release
- **Single release** (v0.5). No on-device checkpoint until the whole flow works
  on the emulator.
- **Emulator**: KOReader built from source on this Mac with `kodev`, run as
  `./kodev run -s kobo-clara` (1072×1448 @ 300 dpi, Emulator device class with
  e-ink flags, fake Wi-Fi toggle, subprocesses and HTTPS work). The plugin is
  symlinked into a dev `KO_HOME` plugins dir so the repo stays the source of
  truth. Known caveat: an open KOReader issue on Apple Silicon where mouse
  clicks can register as long-presses; verify tap-vs-hold on the device too.
- Then deploy over SSH (`scripts/deploy.sh`) and check `crash.log`.
- Unit tests cover the pure modules: entry/locators, dedupe, slot ordering,
  pagination math, library records, cache TTL.

## 5. Decision log

| # | Decision |
|---|----------|
| 1 | Full flow redesign, results view as centrepiece |
| 2 | Native KOReader chrome; custom layouts only for results, detail, shelves |
| 3 | Main-menu item opens home directly; Dispatcher action registered |
| 4 | Rich home: search, recents, My books, browse shelves |
| 5 | Library = own JSON record + KOReader Collection "OpenShelf" |
| 6 | Home order: search → recents → My books → browse shelves |
| 7 | Results: list and grid, toggle in toolbar |
| 8 | Detail page; tap = detail, hold = download |
| 9 | Results survive; detail on top; success state in detail |
| 10 | Parallel search via one subprocess per provider |
| 11 | Group header only when >1 action type; Nerd Font glyphs, no emoji |
| 12 | Filter dialog: sources + format; no sort |
| 13 | Progress bar in detail; success = "Saved to OpenShelf folder", Open/Done |
| 14 | Shelves = one row of covers fitting the width, "See all"; no horizontal scroll |
| 15 | Browse shelves: Gutenberg popular + new only |
| 16 | Grid 3×3 with captions; badge + ✓ overlays |
| 17 | Detail: full metadata, description, format picker |
| 18 | Missing file: keep record, dim, offer re-download; hold → remove |
| 19 | Settings: sources, default view, per-source count, clear recents, About |
| 20 | "Load more" row at the end of results |
| 21 | Entries are data with `locator`; providers gain `resolve(locator)` |
| 22 | Download in subprocess; progress by file-size polling; Cancel |
| 23 | Covers via subprocess per page + disk cache |
| 24 | Fixed provider order; late providers fill their slot |
| 25 | Search row opens keyboard on tap; 8 recents, hold deletes |
| 26 | My books is a dedicated screen |
| 27 | Toolbar strip under the title bar for status, Filter, List/Grid |
| 28 | Single release |
| 29 | My books shelves by reading status from KOReader sidecars |
| 30 | Verify on the KOReader emulator first |
| 31 | Browse data: disk cache, 24 h TTL, background refresh |
| 32 | Hold-to-download progress drawn on the row/cell |
| 33 | Download queue, one at a time |
| 34 | List default; ✓ = exact edition; no landscape design; title-bar icon layout |
| 35 | Leaving results kills subprocesses; sidecar reading status; Collection name; hide missing metadata |
| 36 | Emulator built from source, `kodev run -s kobo-clara` |
| 37 | Providers are modular: in-tree, `provider-openshelf-*.koplugin` via KOReader's Provider registry, drop-in files under `<settings>/openshelf/providers` |
| 38 | Stable `id` per provider, separate from display `name`; one-time migration of library records and source settings (library v1 → v2, `.v1.bak` kept) |
| 39 | Providers build entries through `ctx.Entry`; the host overwrites `provider`/`source` and defaults `quality` |
| 40 | Provider functions receive `ctx` (http, json, url_escape, settings, Entry, OPDS, log); no `require` of OpenShelf modules |
| 41 | api 1 covers search, resolve, browse shelves, settings schema, authenticated downloads (`resolve` → `{url, headers}`), borrow/buy actions, `check` |
| 42 | Built-ins stay in-tree under `providers/`, registered through the same path as externals |
| 43 | External providers honor their own `enabled_by_default`; installing is the opt-in |
| 44 | User arranges source order with the stock SortWidget; one order drives result slots, home shelves and the filter dialog; new sources append |
| 45 | 60 s deadline on search/browse/resolve/check jobs in subprocess mode; slot reads "timed out"; downloads exempt |
| 46 | DRM-free is policy in `PROVIDERS.md`, not enforced in code |
| 47 | Provider plugins create the `openshelf` slot in KOReader's Provider registry themselves (one line in the template); no upstream KOReader change (upstream PR dropped 2026-10-29, #11) |
| 48 | Invalid providers (shape, api, load error, duplicate id) show dimmed in Sources with the reason; the later registrant loses |
| 49 | Borrow rows resolve and download like downloads (button "Borrow"); buy rows show URL + QR via QRMessage, never download; optional `price` |
| 50 | Borrow/buy rows dedupe under any free download of the same work |
| 51 | Settings fields: text, secret, toggle, choice; `required` left empty → "Needs setup", source skipped |
| 52 | Optional `check(ctx)` → "Test connection" in the source submenu |
| 53 | Home shows shelves from every enabled provider in source order; per-source "Shelves on home" toggle |
| 54 | Registry read and drop-in folder scanned lazily on each open; files loaded once per process |
| 55 | Dev kit: `PROVIDERS.md`, `tools/provider_check.lua`, template plugin (also loaded by the emulator walkthrough), example drop-in |
| 56 | One release, v0.6.0; spec written and reviewed before code |
| 57 | `api = 1` integer, exact match; `Entry.new{action}` constructor with `Entry.download` as alias; covers unauthenticated |

## 6. Out of scope
Other content types. Standard Ebooks (authenticated OPDS, never scraped), the
borrow/buy bridge and further sources were parked here in v0.5; §9 turns them
into providers built on one contract, so they are no longer out of scope, just
not built yet.

## 7. Build notes (2026-10-26)

Built in one pass and verified on the macOS KOReader emulator with scripted
walkthroughs (`tools/emu-walkthrough*.lua`, screenshots via `Screen:shot`).
Deviations and findings, all deliberate:

- **Recent searches render as two-column chips** (8 fit in four short rows)
  instead of eight full rows, so the shelves still fit on the first page.
- **Internet Archive results are sorted by download count** — its relevance
  ranking put fan fiction and scripts above real editions. Borrow-only items
  are excluded (merged from v0.4.2).
- **Title bars carry no subtitle**; auto-paged screens (home, My books) show a
  slim "1 / 2" footer instead, and shelf headers stay with their covers.
- **Forked jobs on the macOS emulator**: a child of the Cocoa/SDL process dies
  as soon as it touches the network, while the same fork + HTTPS works in a
  bare luajit. `jobs.lua` runs tasks inline on that platform (same callbacks,
  one tick later) and uses real subprocesses on devices. The subprocess path
  is therefore **verified only by code review until the first device run**.
- **DOAB offers EPUB + PDF chips** when both bitstreams exist (`alternates`).
- The `hold` gesture could not be exercised on the emulator (no touch); the
  walkthrough calls the handlers directly. Verify tap-vs-hold on the Clara.

## 8. Home mode (added 2026-10-26, after the v0.5 deploy)

Question raised: should OpenShelf become a standalone app, since closing a
book lands in KOReader's file manager rather than back in OpenShelf?

**Decision: stay a plugin.** A standalone Kobo app would need its own
framebuffer/touch/Wi-Fi stack and an EPUB renderer, and it would still hand
off to KOReader to read, which returns to its own file manager, not to the
app. KOReader has no "plugin as shell" option, but its lifecycle is enough:
the file manager and every plugin in it are torn down while a book is open
and rebuilt when it closes, so a plugin that opens its home view from
`init()` in the file-manager context is on screen at start and after every
book.

- **Setting** "Home mode → Open at start and after each book", off by
  default, in the gear menu. `OPENSHELF_AUTOOPEN=1` turns it on for one
  session (the Kobo launcher and `scripts/emu.sh` set it).
- **X on the home screen reveals the file manager** (the escape hatch); the
  setting is reversible from the gear, and opening a book from the file
  manager still returns to OpenShelf while the mode is on.
- KOReader's own "Start with: last file" wins at boot; OpenShelf then appears
  when that book is closed.
- **Kobo launcher** (`kobo/`): a KFMon watch (`kfmon/openshelf.ini`) whose
  action (`openshelf.sh`) exports the env var and execs KOReader's own start
  script, plus `openshelf.png` (drawn by `tools/make-icon.py`). NickelMenu's
  kfmon generator lists it by label, so no NickelMenu config changes; a
  separate NickelMenu file adds "Import books" (`nickel_misc :
  rescan_books_full`), because Nickel imports new files, the icon and Wi-Fi
  downloads alike, only after a USB session. Installed by
  `scripts/deploy-launcher.sh`; KFMon picks the watch up after one reboot,
  and NickelMenu launches it through KFMon's IPC even before the icon is
  imported.
- Verified on the emulator with `tools/emu-walkthrough-3.lua`: home at start
  from the setting alone → open a book → KOReader "Home" → OpenShelf is back
  → X → file manager. The same run with the setting off and the env var set
  passes too.


## 9. Modular providers (v0.6 design, 2026-10-26)

Question: how do we let any developer add a catalog to OpenShelf? Grilled the
same way as the redesign; the normative contract for authors is `PROVIDERS.md`
(api 1). This section records the host-side design and why.

### 9.1 Shape
A provider is one Lua table: `api`, `id`, `name`, `quality`,
`enabled_by_default`, optional `shelves` and `settings`, and the functions
`search`, `resolve`, optional `browse` and `check`. Every function gets a
`ctx` with the HTTP helpers, JSON, `url_escape`, the user's settings values,
the `Entry` constructors, the OPDS parser and a logger — so a provider never
`require`s an OpenShelf module. That matters twice: KOReader loads
`provider-*` plugins before OpenShelf is on `package.path`, and in-tree
providers must stay loadable by the offline tests.

Providers build their own entries (`ctx.Entry.new`) so they can rank rows
individually; the host then **overwrites `provider` and `source`** on every
row and fills `quality` from the provider when a row has none, so routing and
labels are always right.

### 9.2 Identity
`id` replaces the display name as the key everywhere: result slots,
`disabled_sources`, `Entry.id` (`provider|locator`), library records. The
three built-ins get `gutendex`, `internetarchive`, `doab`; the library JSON
migrates v1 → v2 once on load, after writing a `.v1.bak`, and the browse
cache is simply invalidated by its new `id:key` keys. Locator identity gains a
fallback for third-party shapes: `url`, else `identifier`, else `id`, else all
fields sorted.

### 9.3 Three ways in
1. **In-tree**: `openshelf.koplugin/providers/<id>.lua`, listed in order in
   `openshelf_providers.lua`. Built-ins move there and register through the
   same `Catalog.register` as everything else, so parity is structural.
2. **KOReader plugin** `provider-openshelf-<id>.koplugin`: registers with
   KOReader's core `Provider` singleton (`frontend/provider.lua`, in KOReader
   since Dec 2024, so present on the Clara's v2026.07.2). The registry's
   feature list is a hardcoded whitelist that only knows `exporter`; the
   template adds the `openshelf` slot itself (one line). That line is the
   permanent mechanism; no upstream KOReader change is planned. Plugin instances are created in *path order*, so `openshelf`
   inits before any `provider-*` plugin — OpenShelf therefore reads the
   registry **lazily when it opens**, never at `init()`.
3. **Drop-in file** under `<settings>/openshelf/providers/`
   (`/mnt/onboard/.adds/koreader/settings/openshelf/providers/` on the Kobo),
   created on first open with a README. Scanned on each open, each file
   loaded once per process.

Registration order is built-ins, plugins by id, drop-ins by id. A duplicate
`id` loses and is shown dimmed as such; invalid providers (shape, `api`, load
error) are likewise **dimmed in Sources with the reason**, never a modal.
`enabled_by_default` is honored for externals: installing is the opt-in.

### 9.4 What the contract covers (api 1)
Everything parked in §6 comes in through the contract: browse shelves,
per-provider settings (text / secret / toggle / choice, `required` → the
source reads *Needs setup* and is skipped), authenticated downloads
(`resolve` may return `{url, headers}`; http_util and the downloader pass
headers through), an optional `check(ctx)` surfaced as *Test connection*, and
the borrow / buy actions. **Borrow** rows resolve and download like downloads
with a *Borrow* button and are recorded in My books; **buy** rows carry a web
URL shown as text + QR (KOReader's `QRMessage`) and never download. Non-
download rows are capped below any download in dedupe, so a free edition
always wins. Cover URLs stay unauthenticated in api 1.

### 9.5 UI
- **Sources** gains *Arrange sources* (stock `SortWidget`, as Dispatcher and
  Collections use); the stored `source_order` of ids drives result slots,
  home shelf order and the filter dialog. New sources append.
- Each source becomes a **submenu**: *Enabled* · declared fields · *Test
  connection* when `check` exists · *Shelves on home* when it declares
  shelves. Home shows shelves from every enabled provider in source order.
- Settings storage: `source_order`, `enabled_sources` (for default-off
  providers, beside today's `disabled_sources`), `provider_settings[id]`.

### 9.6 Hardening
`jobs.lua` gets a per-job deadline, 60 s for search / browse / resolve /
check, in subprocess mode only (inline emulator mode cannot interrupt a
blocking call); the slot reads "timed out". Downloads are exempt: they stream
with progress and have their own socket timeouts. DRM-free stays a **policy**
in `PROVIDERS.md`; the host does not inspect files (decision 46).

### 9.7 Dev kit and release
`PROVIDERS.md`; `tools/provider_check.lua` (validate → search → JSON
round-trip → resolve → HEAD, the headless test becomes a thin wrapper over
it); a template `provider-openshelf-template.koplugin` that `scripts/emu.sh`
also symlinks so a walkthrough exercises the external path; one example
drop-in file. **One release, v0.6.0.** The spec is written and reviewed
before code; the KOReader PR is opened only on explicit go.

## 10. Self-update (ticket #6, 2026-10-29)

| # | Decision |
|---|----------|
| 58 | OpenShelf updates itself from the latest non-prerelease GitHub Release (`/releases/latest`, anonymous); tag `vX.Y.Z` compared numerically with `openshelf_version.lua`; suffixed or malformed tags ignored |
| 59 | Settings → Updates: *Check for updates* (always reports) and *Check for updates automatically* (default on): at most once per 24 h, in the background when OpenShelf opens, only when already connected, silent unless an update is offered |
| 60 | Offer = current → new + start of the release notes, *Update* / *Later*; *Later* mutes that version for automatic checks until a manual check or a newer release |
| 61 | Install never trusts the download: https only (API, assets, every redirect; plain http only to localhost via the dev override), zip size vs the asset, SHA-256 vs `openshelf-vX.Y.Z.zip.sha256` (a release without it is refused), the file must start with the zip signature `PK\3\4`, every zip entry must be a file/dir under `openshelf.koplugin/`, staged plugin needs `_meta.lua`, `main.lua` and version == tag. Download/verify/extract run in a job (300 s deadline) into `<plugin>.staging`; `sync` before the swap |
| 62 | Swap = `<plugin>.old` (one backup, replaced each time) ← live, live ← staged; a failed second rename renames live back. Then KOReader's restart prompt; new code loads only after restart. Only the plugin folder and its two siblings are written; settings, drop-in providers and books are never touched |
| 63 | A symlinked plugin folder (the emulator's dev checkout) is never updated; dev overrides `OPENSHELF_FAKE_VERSION`, `OPENSHELF_UPDATE_API`, `OPENSHELF_UPDATE_PLUGIN_DIR` exist for emulator tests only |

Pure logic lives in `openshelf_updater_logic.lua` (unit-tested); the
KOReader side is `openshelf_updater.lua`. Until the restart, modules OpenShelf
requires lazily would load from the new files beside old ones already in
memory — hence the immediate restart prompt.

## 11. Shelves: See all pages with Load more (ticket #12, 2026-10-29)

| # | Decision |
|---|----------|
| 64 | `browse(key, limit, ctx, page) → entries, has_more` (PROVIDERS.md §5.3), additive in api 1: `page` optional (absent = 1); only a second return of exactly `true` is `has_more`, so a provider that ignores `page` is a single-page shelf with no Load more. The host asks for page N+1 only after page N said `has_more` |
| 65 | Every browse call uses the browse page size (32, one Gutendex page) as `limit`, for the home shelf fetch and every Load more page, so page 1 is the cached home shelf; the home row still shows only the covers that fit. The 24 h cache stores page 1 with its `has_more` and the page size it was fetched at (`{ entries, has_more, size }`); a cache at another size (or without one) or a pre-#12 bare list reads as stale and is refreshed. Home row layout and the TTL are unchanged |
| 66 | See all opens instantly on the cached page 1 and ends in Load more like search results: the next page is fetched in a job under the 60 s deadline and appended, skipping rows already shown. While it runs the button reads "Loading…"; a failure shows "⚠ Load more failed" in the status strip (tap for the reason) and Load more stays to retry. The view lands on the page holding the first new book: refreshed in place ("ui") when the last page had room, otherwise turned to the next page ("partial") |
| 67 | Gutenberg shelf page N is exactly Gutendex page N: one request, every EPUB row in it (up to `limit`), `has_more` from Gutendex's `next`; Popular gets about 30 per page, New about 12–20 (its newest books often have no EPUB yet). Page 1 keeps the plain `?sort=…` URL and later pages use Gutendex's own `next`-link shape (`?page=N&sort=…`): those are the URLs its CDN has cached, and uncached ones can take a minute |

The paging state (`shelf_pager.lua`) and the provider side are pure and
unit-tested; the list view (`view_list.lua`) is verified in the emulator.

## 12. Folders (api 2, 2026-10-29)

Question: how does a provider expose nested structure instead of a flat
result list? Prompted by a private UCStudent provider (University of Coimbra
course materials, its own repo): per course unit one general repository plus
one per teaching profile, folders nested several levels deep
(`Lab01-Authentication/Part01-SSO`), one GET per folder, folder items carrying
`{files, size, folders}` so empty ones can be pruned, 240×240 thumbnails
without auth. In api 1 a row is only download / borrow / buy and shelves are a
static list, so a provider cannot show a folder. Grilled like §9. §11 (ticket
#12, shelf See all paging) is the base folders build on. Contract:
`PROVIDERS.md` §4.5, §5.5, §5.6, §11.

### 12.1 Model
A row can be a **folder**: `action = "folder"`, built with
`ctx.Entry.folder{…}` (`ctx.Entry.new{action = "folder", …}` builds the same
row). The api-2 provider function
**`list(locator, limit, page, ctx) → rows, has_more`** lists one folder
lazily, one call per folder (one GET for UCStudent). Folder rows may come
from every function that returns rows: `search`, `browse`, `list` and
`search_in`.

Rejected: file rows tagged with a path from which the host builds a virtual
tree (the provider would have to list the whole tree up front, about 22
requests for one UCStudent year and impossible for Internet Archive
collections), and provider-defined dynamic shelves (one level only, deeper
folders flattened).

### 12.2 Versioning: api 2
A host from before this feature turns an unknown `action` into a download
(`Entry.new`), so folder rows on an old host would look like books and fail
at resolve time. A provider that uses folders therefore declares **`api =
2`**: api 1 plus folders, nothing else. New hosts accept 1 and 2; old hosts
dim an api-2 provider in Sources ("api must be 1"), a clean refusal instead
of broken rows. This is the one deliberate exception to "optional additions
don't bump" (`PROVIDERS.md` §11): an old host would not just ignore the
addition, it would misuse it. An api-2 provider must define `list`; `root`,
`search_in` and `dedupe` are optional. Everything api 2 adds is read only
from an api-2 provider: on api 1, `root`, `list`, `search_in` and `dedupe`
stay unknown fields (ignored, never validated, so existing helpers with
those names keep working), and `Catalog.stamp` drops folder rows (with a log
line) and strips `size` and `path` from rows, so an api-1 provider behaves
exactly as before.

Argument order: `list(locator, limit, page, ctx)` and
`search_in(locator, query, limit, page, ctx)` keep `ctx` last, like `search`.
`browse(key, limit, ctx, page)` (§11, page after ctx for compatibility) stays
the one documented exception, unchanged in api 2.

### 12.3 Reaching folders
- **Root.** A provider may declare `root = "Course materials"`; `list(nil, …)`
  returns its top level. Home gains a **Browse** section after My books and
  before the shelves: one chip per enabled, set-up source with a root,
  labelled with the root title, in source order, styled like the
  recent-search chips. No separate toggle. Chips show offline too; opening
  a root (or any folder) that was never listed asks for Wi-Fi like search
  does.
- **Search and shelves** may return folder rows: searching "theoretical" can
  land in a folder directly, and a shelf may hold folder tiles (cached with
  the shelf like any row).

### 12.4 Navigation and the folder view
- One full-screen **view per folder**, stacked over whatever opened it (home,
  results, See all, another folder). Views below survive; a running search
  keeps going underneath, as it does under the detail page.
- Title = folder name. **Tapping the title** opens a menu: the folder views
  stacked below this one, nearest last (tapping one closes every view above
  it), then *Refresh*. A folder opened from search or a shelf has no folder
  views below it, so its menu is just *Refresh*; the `path` titles of its row
  are not openable and are not listed. Back / chevron = up one level, X =
  leave OpenShelf. Each Back costs one full e-ink refresh, like every view
  close.
- Toolbar: `43 items · Updated 3 d ago · ⚠ 1 failed` (tap for details), a
  search glyph when the provider has `search_in`, the list/grid toggle. No
  filter: a folder has one source.
- Footer: page label, **Load more**, **Download all**. The folder view is
  §11's paged See all list fed by `list` instead of `browse`: 50 rows per
  page; Load more fetches page + 1 in a job under the 60 s deadline.
- Empty → "This folder is empty." A failure with a cached copy shows the
  cached rows and the error in the strip; without one, a message and
  *Retry*. `list` and `search_in` jobs get the usual 60 s deadline
  (subprocess mode).

### 12.5 Folder rows
- **Fields**: `ctx.Entry.folder{ title, locator, cover?, subtitle?, path?,
  count?, size? }`. `path` = the ancestors' titles (`{"Software Seguro",
  "T"}`), `count` = files (shown as "N files"), `size` = bytes. File rows gain
  optional `size` (summed by Download all) and `path` too. An empty `path`
  (`{}`) means "directly under the root" and is kept, not turned into nil.
- **Look**: the provider's cover when given, else a **folder tile**: the
  folder glyph with the title written on it, so bare shelf tiles and grid
  cells stay readable. Second line = `subtitle`, else `path` joined with ›
  (outside folder views only: inside one it would repeat the title bar on
  every row), else nothing, never "Unknown". Meta: `UCStudent · 43 files · 120 MB` (from
  `count` / `size` when given), else `UCStudent · Folder`. No ✓.
- **Tap opens** the folder (no detail page); **hold = Download all**. File
  rows inside folders behave like books: tap → detail, hold → download, ✓
  when on the device, *Open* once downloaded.
- In mixed lists folders form their own group, **first**, under a "Folders"
  header (headers still appear only when there is more than one group). They
  pass any format filter and obey the source filter.
- **Dedupe**: folder rows never merge (identity is `Entry.id`); rows inside
  folder views and scoped-search results are never deduped; an api-2
  provider may set `dedupe = false` so none of its rows merge (two "Aula 1"
  files in different repositories stay two rows in search). Folders and
  files share the `Entry.id` space (cache keys, pager dedupe, records), so a
  provider must keep a folder's locator identity distinct from every file's.

### 12.6 Offline-first cache
The Kobo is offline most of the time, so folder listings are kept on disk and
**never expire**:
- `openshelf_folders.json` in the settings dir, keyed
  `<id>|<locator identity>` (the root is `<id>|`), holding every loaded page,
  its `has_more` and the fetch time.
- A cached folder opens instantly, online or off; the toolbar reads "Updated
  3 d ago" once the copy is more than 24 h old. When Wi-Fi is **already on**
  and the copy is older than 24 h it refreshes in the background and repaints
  (it never turns Wi-Fi on for that); *Refresh* in the title menu forces it.
  A refresh refetches the pages that were cached. A folder never listed
  asks for Wi-Fi when opened offline, like search.
- **Only folders you opened** are cached; nothing is prefetched. *Download
  all* on a folder counts as opening it: it reads the cached pages and
  caches the ones it fetches. Pages per folder are not capped; the 500-folder
  cap bounds the file for UCStudent-sized trees, and Internet Archive
  collections (later) must revisit it. A
  downloaded file came from a folder you opened (or from search, placed by
  its own `path`), and it is also in My books and under `OpenShelf/` in
  KOReader's file manager.
- Changing a provider's settings clears its folders (UCStudent's "All years"
  changes the whole tree). At most 500 folders; the least recently opened go
  first.
- Shelves follow the same rule and it is now written down: the browse cache
  already keeps its data forever and 24 h is only the refresh age. Covers stay
  in their disk cache.

### 12.7 Scoped search
Optional **`search_in(locator, query, limit, page, ctx) → rows, has_more`**.
When a provider defines it, its folder views (and its root, locator `nil`)
show a search glyph; results open as a stacked view `“sso” in Software
Seguro` with one provider slot and Load more, and may include folders.
`limit` is the search page size (10, 15 or 30), as for `search`. Not
cached, not added to recent searches, needs Wi-Fi.

### 12.8 Files on the device
- **The host mirrors the browse path**:
  `OpenShelf/<provider name>/<ancestors…>/<folder>/<Title>.<ext>`. With
  `P` = `OpenShelf/<provider name>/`, every folder has a **directory**,
  defined recursively:
  - the root's directory is `P` (the root title is never a segment);
  - a folder row with `path` → `P/<path…>/<title>`;
  - a folder row without `path` that `list` returned → the directory of
    the folder it was listed from, plus `<title>` (so the tree mirrors at
    any depth, also below a folder that search found);
  - any other folder row without `path` (search, shelf, scoped search) →
    `P/<title>`.

  A file **without a record** goes, first match wins:
  1. the file row's own `path` → `P/<path…>/`;
  2. a file that `list` returned (shown in a folder view, or fetched by
     *Download all* on that folder) → that folder's directory;
  3. otherwise (search, shelf, scoped search, no `path`) flat in
     `OpenShelf/`, as today.

  A file **with a record** always goes to its recorded path (*Download
  again*, hold, Download all), wherever it was found; 1–3 apply only when
  there is no record. A file therefore has one place while it is in My
  books; without `path`, where it first lands depends on where it was found.

  Every segment is made safe like a file name; a segment that ends up empty
  (`.`, `..`) becomes `_`. Directories are created recursively. The host
  stamps the resolved directory on the rows it shows (folder rows included),
  so detail, hold and Download all agree.
- **Names**: `<Title>.<ext>` inside folder directories (a title that already
  ends in `.<ext>`, any case, is not extended again: "Aula 1.pdf" stays
  `Aula 1.pdf`); flat downloads keep `<Author> - <Title>.<ext>`. An entry's
  **target** is its recorded path when it has a record; otherwise the first
  of `Name`, `Name (2)`, `Name (3)`… that no other entry's record owns. ✓ =
  a file exists at the target, and a download writes the target, replacing
  whatever is there. A file OpenShelf has no record of thus counts as this
  entry's own copy when it sits at the entry's target (✓, *Open*, *Download
  again* replaces it); ` (2)` appears only when another record owns the
  name. That fixes today's hazard: two same-named files overwrite each other
  and the never-downloaded twin shows ✓.
- **My books** records these files like books (record + KOReader Collection
  "OpenShelf"); the record keeps the full path, folder directory included.
  Folder rows are never recorded.
- **Download all** (footer button, or hold on a folder row anywhere): the
  files directly in that folder, not its subfolders. Fetches the remaining
  pages first, skips files already on the device and buy rows, confirms
  `Download 43 files (120 MB)?` (size when known), then queues them on the
  existing one-at-a-time queue. While that folder's files are queued the
  button reads *Cancel downloads*.

### 12.9 Scope, dev kit and release
- **First release = host + api 2 contract + dev kit.** Built-ins are
  unchanged. Internet Archive collections (`list` over `collection:<id>`)
  and OPDS navigation (navigation entries, `rel="next"` paging, relative
  hrefs in `ctx.OPDS`) are later tickets. UCStudent is the first real api-2
  provider.
- The template plugin stays api 1. A new offline drop-in
  `examples/folders_demo.lua` (api 2: a root, a small nested fake tree,
  `search_in`) is the reference and feeds the emulator check.
- `tools/provider_check.lua`, for api 2: lists the root (if declared) and
  the first folder row found with `list(…, 50, 1, ctx)`, under the search
  step's failure rules (error, more rows than `limit`, non-boolean
  `has_more`; an empty folder passes), runs the row checks and JSON round
  trip on what comes back, page 2 when `has_more` (fails on a repeated row),
  `search_in` once when defined (search page size), and resolves the first
  file found inside when search returned none (skipped with a warning when
  no file is found anywhere). An api-1 provider that returns folder rows
  fails the row step.
- Unit tests for the pure parts: folder rows and stamping, api-2 validation,
  dedupe / filter / group rules, directory and name building with the
  collision suffix, the folder cache (keys, eviction, settings clear).
  `tools/emu-folders-check.lua`, modelled on `emu-borrow-buy.lua`: Browse
  chip → nested folders → Back → title menu → Download all → the cached view
  offline, with screenshots.
- Built on §11 (#12): its paged See all list (`shelf_pager.lua`,
  the Load more in `view_list.lua`). One release, **v0.8.0**.

### 12.10 Host notes (from the seam survey)
Today every row is assumed to be a file. Places that need folder handling:
the `Entry.ACTION*` tables plus a folder glyph that exists in the bundled
`symbols.ttf`; `Catalog.validate` (api 2 only: `list` / `search_in`
functions, `root` string, `dedupe` boolean; api 1 never looks at them);
`Catalog.stamp` (for api-1 providers drop folder rows and strip `size` /
`path`; it also re-runs `Entry.new` on rows without a `dedup_key`, so folder
rows must survive that, either with a key or by `Entry.new` dispatching
`action = "folder"` to `Entry.folder`); `Catalog.group` (actions missing
from `ACTION_ORDER` vanish silently, so "folder" goes first in it, and
`Entry.new`'s `ACTION_SET` is built from the same list); `Results.flatten` and
`Dedupe` exemptions; one tap dispatcher (`App.openEntry`) for results, lists,
shelves and My books; folder guards in `App.holdDownload`,
`Downloader.enqueue` and `DetailView`; no `App.bookStatus` for folder rows;
`Downloader.targetPath` gains the directory, the name rule and the suffix
(recursive `util.makePath`). List, detail and My books set `on_left =
close` directly, so overriding `onBack` alone does not change the chevron.
An entry's `path` (a list of folder titles) is not the library record's
`path` (the absolute file path, also in `App.bookStatus()`): `Library.add` /
`toEntry` must keep the two apart. New modules get `openshelf_` names
(`cache` is KOReader's).

| # | Decision |
|---|----------|
| 68 | Folders are rows: `action = "folder"` via `ctx.Entry.folder`, listed lazily by the api-2 function `list(locator, limit, page, ctx) → rows, has_more`; folder rows may come from search, browse, list and search_in. Rejected: path-tagged files with a host-built tree, dynamic shelves |
| 69 | api 2 = api 1 + folders. Hosts accept 1 and 2; old hosts dim api-2 providers instead of showing folder rows as downloads. api 2 requires `list`; `root`, `search_in`, `dedupe` optional. On api 1 those fields stay unknown (never read or validated), folder rows are dropped and `size` / `path` stripped. The one exception to "optional additions don't bump" |
| 70 | `list(locator, limit, page, ctx)` and `search_in(locator, query, limit, page, ctx)` keep ctx last like search; `browse(key, limit, ctx, page)` (decision 64) stays the documented exception in both api versions |
| 71 | `root = "<title>"` + `list(nil, …)` = a provider's top level. Home *Browse* section after My books, before shelves: one chip per enabled, set-up source with a root, in source order; no toggle; shown offline |
| 72 | One stacked view per folder over whatever opened it; views below survive; title = folder name, title tap = ancestors menu + Refresh; Back = up one level, X = leave OpenShelf |
| 73 | The folder view is §11's paged list fed by `list`: 50 rows per page, Load more; toolbar `N items · Updated … · ⚠ failed`, search glyph (with `search_in`), list/grid, no filter; footer Load more + Download all |
| 74 | Folder rows: optional cover, `subtitle`, `path`, `count`, `size`; a folder tile with glyph + title when there is no cover; second line subtitle, else path (outside folder views), never "Unknown"; meta `Source · N files · size` or `Source · Folder`; tap opens, hold = Download all, no detail page, no ✓. File rows gain optional `size` and `path` |
| 75 | Folders group first ("Folders" header when mixed), pass any format filter, obey the source filter and never merge; folder views and scoped results are never deduped; provider `dedupe = false` keeps all its rows unmerged |
| 76 | Offline-first folder cache `openshelf_folders.json`: every loaded page, never expires; background refresh only when Wi-Fi is already on and the copy is > 24 h old; title-menu Refresh; "Updated N d ago" |
| 77 | Only opened folders are cached, no prefetch; a provider's settings change clears its folders; cap 500 folders, least recently opened dropped. Shelves documented the same way (data kept, 24 h = refresh age) |
| 78 | Scoped search: optional `search_in`; a search glyph in that provider's folder views and root; results in a stacked view with Load more; not cached, not in recents |
| 79 | Disk mirrors the browse path, `OpenShelf/<provider name>/<ancestors…>/<folder>/`. A folder's directory is recursive: `path` + title, else (listed by `list`) its parent folder's directory + title, else `<provider name>/<title>`; the root is not a segment. A file without a record: its `path` → the directory of the folder that listed it → flat. A file with a record always uses its recorded path. The host stamps directories on shown rows |
| 80 | Names: `<Title>.<ext>` inside folder directories (no doubled extension), `<Author> - <Title>.<ext>` flat. Target = the recorded path, else the first of `Name`, `Name (2)`… no other record owns; ✓ = a file at the target; a download replaces it. An unrecorded file at the target is this entry's copy |
| 81 | Files from folders are recorded in My books like books (record + Collection), with their full path; folder rows are never recorded |
| 82 | Download all: one folder, no recursion; footer button and hold on a folder row; fetches remaining pages, skips on-device files and buy rows, confirms with count (+ size), queues; *Cancel downloads* while queued |
| 83 | Empty folder → "This folder is empty."; failure → cached rows + strip error, else message + Retry; `list` / `search_in` under the 60 s deadline |
| 84 | Shelves may hold folder rows: cached with the shelf, drawn as titled folder tiles, tap opens |
| 85 | First release = host + api 2 + dev kit: `examples/folders_demo.lua` (api 2, offline), template stays api 1, provider_check api-2 steps, unit tests, `tools/emu-folders-check.lua`; built-ins unchanged; IA collections and OPDS navigation later |
| 86 | Built on #12's paged See all list; one release, v0.8.0 |
