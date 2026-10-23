# OpenShelf

A [KOReader](https://github.com/koreader/koreader) plugin that lets you **search
free & public-domain ebook catalogs and download them straight to your device** —
no PC, no cable, no Calibre round-trip.

```
Main menu → OpenShelf → Search → results grouped by action → Download → Read
```

## Sources

OpenShelf only integrates **legal, openly-licensed, or public-domain, DRM-free**
catalogs.

| Provider          | What it is                                   | Status |
| ----------------- | -------------------------------------------- | ------ |
| Project Gutenberg | ~70k public-domain classics (Gutendex API)   | ✅ working |
| Internet Archive  | Public-domain texts with EPUBs               | ✅ working |
| DOAB              | Open-access scholarly books (DSpace REST)     | ✅ on-device¹ |

¹ DOAB blocks datacenter IPs (403), so it only works from a residential
connection like the Kobo itself; the catalog isolates it if it's ever blocked.

**Why not Standard Ebooks / Feedbooks?** Testing against their live endpoints
ruled both out:
- **Standard Ebooks** actively bans scrapers — its direct download links are
  honeypots ("following this link will ban your IP for 24 hours"), and its OPDS
  feed requires a patron login. A scraper would risk banning your home IP. It may
  return later as an **opt-in authenticated-OPDS provider** (needs a patron
  token) — the OPDS parser (`opds.lua`) is kept for that.
- **Feedbooks** discontinued its free public-domain OPDS; only the commercial
  store (sample/paid links) remains.

> OpenShelf never touches Adobe-DRM'd books (library/purchase). Those stay in the
> stock Kobo reader. See the roadmap for the planned borrow/buy *discovery bridge*.

## Architecture

Flat module layout — KOReader puts a plugin's own folder on the Lua path, so
siblings `require` each other by filename.

```
openshelf.koplugin/
  _meta.lua                     plugin manifest
  main.lua                      UI: menu, search, grouped results, download/read
  catalog.lua                   fans query across providers → merge → dedupe → group
  entry.lua                     result model: actions (download/borrow/buy), quality, dedup keys
  dedupe.lua                    collapse duplicate editions, prefer best quality
  opds.lua                      minimal OPDS/Atom parser (for future OPDS sources)
  settings.lua                  persistent per-source enable/disable
  downloader.lua                resolve entry → stream file to disk
  http_util.lua                 GET / getJSON / download over LuaSocket
  providers_gutendex.lua        Project Gutenberg
  providers_internetarchive.lua Internet Archive
  providers_doab.lua            DOAB
```

### The pluggable result model
Every result is an **entry** carrying an `action` — `download`, `borrow`, or
`buy`. Today providers only emit `download`; the results view already **groups by
action** (⬇ Download / 📚 Borrow / 🛒 Buy), so library/purchase sources can slot
in later with zero UI changes. See `entry.lua`.

### Dedupe + prefer-best-edition
When the same work appears in several sources, `dedupe.lua` collapses them —
keeping the position of first appearance but upgrading to the highest-`quality`
edition (e.g. Standard Ebooks > raw Gutenberg, once SE is back).

### Adding a provider
Create `providers_<name>.lua` exposing `search(query, limit) -> entries, err`,
where each entry comes from `Entry.download{title, author, source, format?, resolve}`.
`resolve()` returns the file URL (can be lazy — IA defers its metadata lookup
until the user taps). Register it in `catalog.lua` and give it a `quality` in
`entry.lua`.

## Install

1. Install KOReader on your device.
2. Copy `openshelf.koplugin/` into KOReader's `plugins/` directory
   (`.adds/koreader/plugins/` on Kobo).
3. Restart KOReader → **OpenShelf** appears in the main menu.

## Testing

`test/headless_providers.lua` runs the real catalog/dedupe/provider/http code
against the live APIs, stubbing only the KOReader-specific modules:

```
brew install lua luarocks
luarocks install luasocket luasec dkjson
eval "$(luarocks path)"
lua test/headless_providers.lua "pride and prejudice"
```

Exits non-zero on failure. DOAB's 403 from datacenter IPs is treated as expected.

## Cover thumbnails

Results show cover thumbnails in a custom paged view (`coverbrowser.lua`) —
the base KOReader Menu is text-only, so covers needed a dedicated widget. Covers
are downloaded + decoded (`covers.lua` via `RenderImage`) and cached per session.
Providers supply `cover_url`: Gutenberg (`image/jpeg`), Internet Archive
(`/services/img/<id>`), DOAB (THUMBNAIL bitstream). A **Show cover thumbnails**
toggle in the menu falls back to the plain text list.

## Roadmap

- [ ] Standard Ebooks via **authenticated OPDS** (opt-in, patron token)
- [ ] **Discovery bridge**: surface borrow (library) / buy availability as
      `borrow`/`buy` entries that deep-link to the Kobo/Libby app (no DRM in-app)
- [ ] Async cover loading (currently fetched synchronously per page)
- [ ] Format choice when an item has several (EPUB / PDF)
- [ ] "Already in library" badges

## License

MIT — see [LICENSE](LICENSE). KOReader itself is AGPL-3.0.
