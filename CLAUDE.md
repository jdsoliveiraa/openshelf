# OpenShelf — KOReader plugin (Kobo Clara HD)

Searches free / public-domain ebook catalogs (Gutenberg, Internet Archive, DOAB)
and downloads straight onto the device. Plugin code lives in `openshelf.koplugin/`
(flat modules; siblings `require` each other by filename). `DESIGN.md` is the UI
spec (57 grilled decisions — don't relitigate; §9 = modular providers).
`PROVIDERS.md` is the provider contract (api 1) third-party authors read.
`TODO_CLARA_HD.md` is the device log: roadmap, decisions, and hard-won gotchas —
read §6–7 before changing network, UI, or source-related behaviour.

## Commands

```bash
luacheck .                                   # lint (std = luajit)
luajit test/unit.lua                         # offline unit test, no network
eval "$(luarocks --lua-version=5.1 path)"; luajit test/headless_providers.lua "pride and prejudice"   # live APIs
for f in openshelf.koplugin/*.lua test/*.lua; do luajit -e "assert(loadfile('$f'))"; done
scripts/emu.sh                               # emulator, opens straight into OpenShelf
scripts/emu.sh --walk tools/emu-walkthrough.lua --shots /tmp/shots   # scripted walkthrough + PNGs
scripts/emu.sh --no-autoopen --walk tools/emu-walkthrough-3.lua --shots /tmp/shots   # home mode (needs OPENSHELF_TEST_EPUB)
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

## Emulator (macOS)

KOReader built from source at `../koreader` (sibling checkout). One-time:
`brew install autoconf automake bash binutils cmake coreutils findutils gettext
gnu-getopt libtool make meson nasm ninja pkgconf sdl3 util-linux wget` (wget is
missing from KOReader's own list), `git clone https://github.com/koreader/koreader
../koreader`, then with Homebrew bash first on PATH: `./kodev fetch-thirdparty &&
./kodev build` (cold build ≈ 6 min). `scripts/emu.sh` symlinks the plugin into
`.kohome/plugins/` and runs at half Clara scale (536×724 @150 dpi — identical
proportions, fits a laptop). `--clara` gives the exact 1072×1448.

- `OPENSHELF_AUTOOPEN=1` = home mode for the session (open at start and after
  every book; `scripts/emu.sh` sets it unless `--no-autoopen`).
  `OPENSHELF_DEV_SCRIPT=file.lua` runs a script inside KOReader once per
  process (see `tools/emu-walkthrough*.lua`) and `Screen:shot(path)` saves
  PNGs — macOS `screencapture` is refused for the terminal, so this is how
  screens are reviewed.
- Plugin `init()` runs for every file-manager and reader instance, and the
  file manager is rebuilt after each book. The emulator only reaches the file
  manager once `quickstart_shown_version` in `.kohome/settings.reader.lua` is
  huge (a from-source build normalizes its version to 0).
- **Forked jobs die on the macOS emulator** as soon as the child touches the
  network (the same fork + HTTPS works in a plain luajit; it's the Cocoa/SDL
  process state). `jobs.lua` therefore runs inline there; devices use real
  subprocesses. The subprocess path can only be verified on the Kobo.
- The emulator has keys, so stock `Menu`s show shortcut letters; the Kobo doesn't.

## Constraints

- **Device = LuaJIT (Lua 5.1 semantics).** No `//`, no `\u{}` escapes, no integer
  subtype; `goto` is fine. `%w`/`%a` match ASCII only — keep bytes ≥128 when
  normalising text. `require()` returns two values on 5.3+ locally, so bind
  requires to locals before putting them in tables.
- **Never use `_` as a loop variable** in a file that has `local _ = require("gettext")`
  — it shadows gettext and the next `_("…")` call crashes. Use `__`/`___`.
- **KOReader's bundled JSON (LuaJSON) decodes `null` as a function**, not nil.
  `Entry.download` coerces non-strings; keep that guard when parsing APIs.
- **Flat require namespace with KOReader**: a module named like one of KOReader's
  (`version`, `util`, `cache`, `json`, …) is silently shadowed. `test/unit.lua`
  keeps a reserved list; prefix generic names (`openshelf_version`).
- **Entries are plain data** (`locator`, no closures): they cross subprocess
  pipes as JSON and are persisted in the library. Providers expose
  `resolve(locator)`.
- **Widget sizing**: `FrameContainer`'s `width/height` fields don't fix its size —
  size the child (`P.box`, exact `dimen`) and add border/padding yourself.
  Gesture events reach children first, then the view; views hit-test taps
  against the rows they built (`view_base.lua`), so every row needs an exact
  height.
- **KOReader UI modules cannot run locally.** `view_*`, `uiparts`, `covers`,
  `downloader`, `jobs`, `settings`, `collection`, `app` are only verified in the
  emulator / on-device. Keep `entry`, `results`, `layout`, `library`, `ttlcache`,
  `catalog`, providers and parsers free of KOReader dependencies so the tests can
  load them.
- **HTTP:** go through `http_util.lua` (socketutil timeouts + timeout-aware sinks).
  Never scrape Standard Ebooks (honeypot links ban the home IP). DOAB 403s from
  datacenter IPs — that failure is expected off-device.
- **DRM is a hard boundary.** Only DRM-free files are ever downloaded or opened.
- Downloads go to `<home_dir>/OpenShelf` (`/mnt/onboard/OpenShelf` on Kobo), a
  visible folder shared with the stock Kobo library.

## Deploy

Bump `openshelf.koplugin/openshelf_version.lua`, then `scripts/deploy.sh` over
SSH: the Kobo must have its SSH server started (Settings → Network → SSH server;
on-demand, key-only, `Host kobo` in `~/.ssh/config`). The script stages, swaps,
syncs and md5-verifies the plugin folder; KOReader must then be restarted on the
device (Exit → Restart KOReader). USB fallback per `TODO_CLARA_HD.md` §5 — always
`cp … && sync && sync` in one command (§6: the USB volume drops mid-operation).
`scripts/deploy-launcher.sh` installs the Kobo launcher (`kobo/`: KFMon watch +
script + icon, listed by NickelMenu's kfmon generator); KFMon only reads it
after a reboot.
