# OpenShelf UI redesign — design record (v0.5)

> Outcome of a grilling session on 2026-10-26. Thirty-six decisions, every branch
> visited, nothing silently assumed. **Don't relitigate without a reason**; if
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

## 6. Out of scope (parked, unchanged from the roadmap)
Standard Ebooks via authenticated OPDS · borrow/buy discovery bridge · more
sources · other content types. The `action` field and group-by-action code stay
so these can slot in later.

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
  kfmon generator lists it by label, so no NickelMenu config changes.
  Installed by `scripts/deploy-launcher.sh`; KFMon and Nickel pick it up
  after one reboot.
- Verified on the emulator with `tools/emu-walkthrough-3.lua`: home at start
  from the setting alone → open a book → KOReader "Home" → OpenShelf is back
  → X → file manager. The same run with the setting off and the env var set
  passes too.

