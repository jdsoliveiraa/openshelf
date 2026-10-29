#!/usr/bin/env bash
# Deploy openshelf.koplugin to the Kobo over SSH (KOReader's bundled dropbear).
#
# Prereqs (see TODO_CLARA_HD.md §1/§5):
#   - `Host kobo` in ~/.ssh/config (root@<kobo-ip>, port 2222, your key in
#     the device's .adds/koreader/settings/SSH/authorized_keys)
#   - on the device: Settings (gear) → Network → SSH server → started
#
# Usage: scripts/deploy.sh [--dev] [ssh-host]   (default host alias: kobo)
#        SKIP_CHECKS=1 scripts/deploy.sh       (skip luacheck + unit test)
# The device runs release tags (vX.Y.Z). An untagged or dirty checkout is
# refused unless --dev is given (main carries in-progress work).
#
# Stages the folder next to the live one, swaps it in, syncs, then compares
# every file's md5 with the local copy. Restart KOReader afterwards
# (top menu → Exit → Restart KOReader) so the new version is loaded.
set -euo pipefail

DEV=""
if [ "${1:-}" = "--dev" ]; then DEV=1; shift; fi
HOST="${1:-kobo}"
PLUGINS=/mnt/onboard/.adds/koreader/plugins
NAME=openshelf.koplugin
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST")

cd "$(dirname "$0")/.."

tag="$(git describe --tags --exact-match 2>/dev/null || true)"
if [ -z "$tag" ] || [ -n "$(git status --porcelain -- openshelf.koplugin)" ]; then
  if [ -z "$DEV" ]; then
    echo "deploy: HEAD is not a clean release tag (${tag:-untagged}). Check out a vX.Y.Z tag, or pass --dev." >&2
    exit 1
  fi
  echo "deploy: --dev: deploying untagged $(git rev-parse --short HEAD)" >&2
fi

if [ -z "${SKIP_CHECKS:-}" ]; then
  if command -v luacheck >/dev/null && command -v luajit >/dev/null; then
    luacheck . --quiet
    luajit test/unit.lua
  else
    echo "note: luacheck/luajit not installed, skipping checks" >&2
  fi
fi

find "$NAME" \( -name '.DS_Store' -o -name '._*' \) -delete

version="$(sed -n 's/^return "\(.*\)"/\1/p' "$NAME/openshelf_version.lua")"
echo "Deploying $NAME v$version to $HOST ..."

"${SSH[@]}" "rm -rf $PLUGINS/$NAME.new"
scp -q -r "$NAME" "$HOST:$PLUGINS/$NAME.new"
"${SSH[@]}" "cd $PLUGINS && rm -rf $NAME && mv $NAME.new $NAME && sync"

# Top-level modules and one folder down (providers/*.lua): a truncated
# built-in provider would otherwise pass and OpenShelf would fail to load.
if command -v md5sum >/dev/null; then
  local_sums="$(cd "$NAME" && md5sum -- *.lua */*.lua | awk '{print $1, $2}' | sort -k2)"
else
  local_sums="$(cd "$NAME" && md5 -r -- *.lua */*.lua | awk '{print $1, $2}' | sort -k2)"
fi
remote_sums="$("${SSH[@]}" "cd $PLUGINS/$NAME && md5sum *.lua */*.lua" | awk '{print $1, $2}' | sort -k2)"

if [ "$local_sums" != "$remote_sums" ]; then
  echo "CHECKSUM MISMATCH between local and device:" >&2
  diff <(echo "$local_sums") <(echo "$remote_sums") >&2 || true
  exit 1
fi

echo "OK: $(echo "$remote_sums" | wc -l | tr -d ' ') files verified on $HOST."
echo "Now restart KOReader on the device (top menu → Exit → Restart KOReader)."
