# OpenShelf

A [KOReader](https://github.com/koreader/koreader) plugin that lets you **search
free & public-domain ebook catalogs and download them straight to your device** —
no PC, no cable, no Calibre round-trip.

Built for e-ink readers (Kobo, Kindle, PocketBook, …) where KOReader runs.

```
Main menu → OpenShelf → type a query → pick a result → Download → Read
```

## Sources

OpenShelf aggregates **legal, openly-licensed, or public-domain** catalogs:

| Provider          | What it is                                   | API |
| ----------------- | -------------------------------------------- | --- |
| Project Gutenberg | ~70k public-domain classics                  | [Gutendex](https://gutendex.com) |
| Internet Archive  | Public-domain texts & scanned books          | [advancedsearch + metadata](https://archive.org/advancedsearch.php) |

> **Scope:** OpenShelf only integrates sources that are legal to redistribute.
> It intentionally does **not** support shadow libraries or sites that
> distribute copyrighted books without authorization. Adding such a provider is
> out of scope for this project.

## Architecture

Flat module layout — KOReader puts a plugin's own folder on the Lua path, so
siblings `require` each other by filename.

```
openshelf.koplugin/
  _meta.lua                     plugin manifest (name, description)
  main.lua                      UI: menu, search box, results, download/read flow
  catalog.lua                   fans a query across providers, merges results
  providers_gutendex.lua        Project Gutenberg provider
  providers_internetarchive.lua Internet Archive provider
  downloader.lua                resolves an entry → streams EPUB to disk
  http_util.lua                 GET / getJSON / download over LuaSocket
```

**Adding a provider:** create `providers_<name>.lua` exposing
`search(query, limit) -> results, err`, where each result is
`{ title, author, source, resolve = function() return url[, err] end }`.
Then add it to the list in `catalog.lua`. `resolve` is lazy, so a provider can
defer per-item lookups (as Internet Archive does) until the user actually picks
a book.

## Install

1. Install KOReader on your device.
2. Copy the `openshelf.koplugin/` folder into KOReader's `plugins/` directory.
3. Restart KOReader. OpenShelf appears in the main menu.

## Status

Early scaffold — the two providers work end-to-end. Network/API behavior is best
verified on-device; see the roadmap for what's next.

## Roadmap

- [ ] More providers: Standard Ebooks, Feedbooks, DOAB (open-access academic), OPDS feeds
- [ ] Cover thumbnails in the results list
- [ ] Format choice (EPUB / PDF / text) when an item has several
- [ ] Configurable download folder + duplicate detection
- [ ] Paging / "load more" on search results
- [ ] Download history & "already in library" badges

## License

MIT — see [LICENSE](LICENSE). KOReader itself is AGPL-3.0.
