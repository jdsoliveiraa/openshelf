#!/usr/bin/env bash
# Run the KOReader emulator with this plugin side-loaded (DESIGN.md §4).
#
# One-time setup (macOS): see CLAUDE.md "Emulator". The emulator is a from-source
# KOReader checkout at ../koreader (sibling of this repo), built with ./kodev build.
#
# Usage:
#   scripts/emu.sh                     # open KOReader straight into OpenShelf
#   scripts/emu.sh --walk tools/emu-walkthrough.lua --shots /tmp/shots
#                                      # drive the UI with a script, save screenshots
#   scripts/emu.sh --clara             # exact Kobo Clara HD geometry (1072x1448 @300dpi, needs a tall screen)
#   scripts/emu.sh --no-autoopen       # start in KOReader's file manager (tests the home-mode *setting*)
#   scripts/emu.sh --template          # also load provider-openshelf-template.koplugin (external provider path);
#                                      # without the flag a previously linked template is unlinked
# Env: OPENSHELF_INLINE_JOBS=1|0 forces inline/forked background jobs (macOS defaults to inline).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KOREADER="${KOREADER_SRC:-$HERE/../koreader}"
KOHOME="$HERE/.kohome"
WALK=""; SHOTS=""; AUTOOPEN=1; TEMPLATE=""; GEOM=(-W 536 -H 724 -D 150)   # half-scale Clara: same proportions, fits a laptop screen
while [ $# -gt 0 ]; do
  case "$1" in
    --walk) WALK="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
    --shots) SHOTS="$2"; mkdir -p "$SHOTS"; SHOTS="$(cd "$SHOTS" && pwd)"; shift 2 ;;
    --clara) GEOM=(-s kobo-clara); shift ;;
    --no-autoopen) AUTOOPEN=""; shift ;;
    --template) TEMPLATE=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -x "$KOREADER/kodev" ] || { echo "KOReader source not found at $KOREADER (set KOREADER_SRC)" >&2; exit 1; }
mkdir -p "$KOHOME/plugins"
ln -sfn "$HERE/openshelf.koplugin" "$KOHOME/plugins/openshelf.koplugin"
TPL="$KOHOME/plugins/provider-openshelf-template.koplugin"
if [ -n "$TEMPLATE" ]; then
  ln -sfn "$HERE/provider-openshelf-template.koplugin" "$TPL"
elif [ -L "$TPL" ]; then
  rm "$TPL"
fi
P="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PATH="$P/bin:$P/opt/findutils/libexec/gnubin:$P/opt/gnu-getopt/bin:$P/opt/make/libexec/gnubin:$P/opt/coreutils/libexec/gnubin:$PATH"
export KO_HOME="$KOHOME" KOREADER_WINDOW_POS_X=0 KOREADER_WINDOW_POS_Y=60
[ -n "$AUTOOPEN" ] && export OPENSHELF_AUTOOPEN=1
[ -n "$WALK" ] && export OPENSHELF_DEV_SCRIPT="$WALK"
[ -n "$SHOTS" ] && export OPENSHELF_SHOT_DIR="$SHOTS"
cd "$KOREADER"
exec ./kodev run -b "${GEOM[@]}"
