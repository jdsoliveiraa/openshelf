# OpenShelf — KOReader plugin (Kobo Clara HD)

Searches free / public-domain ebook catalogs (Gutenberg, Internet Archive, DOAB)
and downloads straight onto the device. Plugin code lives in `openshelf.koplugin/`
(flat modules; siblings `require` each other by filename). `TODO_CLARA_HD.md` is
the device log: roadmap, decisions, and hard-won gotchas — read §6–7 before
changing network, UI, or source-related behaviour.

## Commands

```bash
luacheck .                                   # lint (std = luajit)
luajit test/unit.lua                         # offline unit test, no network
eval "$(luarocks --lua-version=5.1 path)"; luajit test/headless_providers.lua "pride and prejudice"   # live APIs
for f in openshelf.koplugin/*.lua test/*.lua; do luajit -e "assert(loadfile('$f'))"; done
```

Everything runs under LuaJIT (the device runtime). One-time setup:
`brew install luajit luarocks luacheck`, then install the rocks for LuaJIT's
5.1 ABI (they go to `~/.luarocks`; Homebrew's `lua` is 5.5 and unrelated):

```bash
LJ="$(brew --prefix luajit)"
luarocks --lua-version=5.1 --lua-dir="$LJ" install luasocket
luarocks --lua-version=5.1 --lua-dir="$LJ" install dkjson
luarocks --lua-version=5.1 --lua-dir="$LJ" install luasec OPENSSL_DIR="$(brew --prefix openssl@3)"
```

CI runs the lint, a LuaJIT load-check of every file, and the unit test.

## Constraints

- **Device = LuaJIT (Lua 5.1 semantics).** No `//`, no `\u{}` escapes, no integer
  subtype; `goto` is fine. `%w`/`%a` match ASCII only — keep bytes ≥128 when
  normalising text. `require()` returns two values on 5.3+ locally, so bind
  requires to locals before putting them in tables.
- **KOReader UI modules cannot run locally.** `coverbrowser.lua`, `covers.lua`,
  `main.lua`, `downloader.lua`, `settings.lua` are only verified on-device. Keep
  the text-list fallback working; keep provider/catalog/entry/opds code free of
  KOReader dependencies so the tests can load them.
- **HTTP:** go through `http_util.lua` (socketutil timeouts + timeout-aware sinks).
  Never scrape Standard Ebooks (honeypot links ban the home IP). DOAB 403s from
  datacenter IPs — that failure is expected off-device.
- **DRM is a hard boundary.** Only DRM-free files are ever downloaded or opened.
- Downloads go to `<home_dir>/OpenShelf` (`/mnt/onboard/OpenShelf` on Kobo), a
  visible folder shared with the stock Kobo library.

## Deploy

Bump `openshelf.koplugin/version.lua`, then `scripts/deploy.sh` over SSH: the Kobo
must have its SSH server started (Settings → Network → SSH server; on-demand,
key-only, `Host kobo` in `~/.ssh/config`). The script stages, swaps, syncs and
md5-verifies the plugin folder; KOReader must then be restarted on the device
(Exit → Restart KOReader). USB fallback per `TODO_CLARA_HD.md` §5 — always
`cp … && sync && sync` in one command (§6: the USB volume drops mid-operation).
