#!/usr/bin/env bash
# Fake GitHub release endpoint for the self-updater emulator check
# (tools/emu-update-check.lua). Builds one release JSON per scenario from the
# current checkout, then serves DIR over plain HTTP on 127.0.0.1:PORT.
#
#   tools/emu-update-serve.sh DIR [PORT]      # default port 8765; Ctrl-C stops
#
# Scenarios (GET /<name>.json; assets under /<name>/):
#   ok        v0.6.2  good zip + matching .sha256           -> installs
#   ok3       v0.6.3  good zip + matching .sha256           -> installs (replaces the .old backup)
#   badsum    v0.6.2  .sha256 of some other bytes           -> "checksum mismatch"
#   trunc     v0.6.2  zip cut in half, JSON size = full     -> "download incomplete"
#   badzip    v0.6.2  random bytes, matching .sha256        -> "not a valid archive"
#   wrongver  v0.6.2  zip whose openshelf_version.lua = 0.6.1 -> "update contains version 0.6.1"
#   nosum     v0.6.2  no .sha256 asset                      -> "no checksum file"
#   evil      v0.6.2  zip with an entry outside the plugin folder -> "unexpected archive content"
#   tar       v0.6.2  a tar (not a zip), matching .sha256   -> "not a zip file"
#   insecure  v0.6.2  zip asset URL is plain http to a remote host -> "refusing non-https download"
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:?usage: emu-update-serve.sh DIR [PORT]}"; PORT="${2:-8765}"
mkdir -p "$DIR"; DIR="$(cd "$DIR" && pwd)"
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# build_zip <version> <out.zip> [extra-file-at-zip-root]
build_zip() {
  rm -rf "$WORK/src"; mkdir -p "$WORK/src"
  cp -R "$HERE/openshelf.koplugin" "$WORK/src/openshelf.koplugin"
  find "$WORK/src" \( -name '.DS_Store' -o -name '._*' \) -delete
  printf -- '-- emu-update-serve.sh build\nreturn "%s"\n' "$1" > "$WORK/src/openshelf.koplugin/openshelf_version.lua"
  [ -z "${3:-}" ] || echo "stray" > "$WORK/src/$3"
  rm -f "$2"
  (cd "$WORK/src" && zip -qr "$2" openshelf.koplugin ${3:+"$3"})
}
sha() { shasum -a 256 "$1" | awk -v n="$2" '{ print $1 "  " n }'; }
size() { wc -c < "$1" | tr -d ' '; }

# release_json <scenario> <tag> <zip-size> <with-sha:0|1>
release_json() {
  local s="$1" tag="$2" zsize="$3" withsha="$4" zip="openshelf-$2.zip" shaasset=""
  [ "$withsha" = 1 ] && shaasset=",
    { \"name\": \"$zip.sha256\", \"size\": 90, \"browser_download_url\": \"$BASE/$s/$zip.sha256\" }"
  cat > "$DIR/$s.json" <<EOF
{ "tag_name": "$tag", "draft": false, "prerelease": false,
  "html_url": "$BASE/$s",
  "body": "## Scenario $s\n\n* Fake release for the updater emulator check.\n* **Bold** line two.",
  "assets": [
    { "name": "$zip", "size": $zsize, "browser_download_url": "$BASE/$s/$zip" }$shaasset
  ] }
EOF
}

for s in ok ok3 badsum trunc badzip wrongver nosum evil tar insecure; do mkdir -p "$DIR/$s"; done

build_zip 0.6.2 "$DIR/ok/openshelf-v0.6.2.zip"
sha "$DIR/ok/openshelf-v0.6.2.zip" openshelf-v0.6.2.zip > "$DIR/ok/openshelf-v0.6.2.zip.sha256"
release_json ok v0.6.2 "$(size "$DIR/ok/openshelf-v0.6.2.zip")" 1

build_zip 0.6.3 "$DIR/ok3/openshelf-v0.6.3.zip"
sha "$DIR/ok3/openshelf-v0.6.3.zip" openshelf-v0.6.3.zip > "$DIR/ok3/openshelf-v0.6.3.zip.sha256"
release_json ok3 v0.6.3 "$(size "$DIR/ok3/openshelf-v0.6.3.zip")" 1

cp "$DIR/ok/openshelf-v0.6.2.zip" "$DIR/badsum/"
echo "not the zip" > "$WORK/other"; sha "$WORK/other" openshelf-v0.6.2.zip > "$DIR/badsum/openshelf-v0.6.2.zip.sha256"
release_json badsum v0.6.2 "$(size "$DIR/badsum/openshelf-v0.6.2.zip")" 1

FULL="$(size "$DIR/ok/openshelf-v0.6.2.zip")"
head -c $((FULL / 2)) "$DIR/ok/openshelf-v0.6.2.zip" > "$DIR/trunc/openshelf-v0.6.2.zip"
cp "$DIR/ok/openshelf-v0.6.2.zip.sha256" "$DIR/trunc/"
release_json trunc v0.6.2 "$FULL" 1

head -c 50000 /dev/urandom > "$DIR/badzip/openshelf-v0.6.2.zip"
sha "$DIR/badzip/openshelf-v0.6.2.zip" openshelf-v0.6.2.zip > "$DIR/badzip/openshelf-v0.6.2.zip.sha256"
release_json badzip v0.6.2 50000 1

build_zip 0.6.1 "$DIR/wrongver/openshelf-v0.6.2.zip"
sha "$DIR/wrongver/openshelf-v0.6.2.zip" openshelf-v0.6.2.zip > "$DIR/wrongver/openshelf-v0.6.2.zip.sha256"
release_json wrongver v0.6.2 "$(size "$DIR/wrongver/openshelf-v0.6.2.zip")" 1

cp "$DIR/ok/openshelf-v0.6.2.zip" "$DIR/nosum/"
release_json nosum v0.6.2 "$FULL" 0

build_zip 0.6.2 "$DIR/evil/openshelf-v0.6.2.zip" evil.lua
sha "$DIR/evil/openshelf-v0.6.2.zip" openshelf-v0.6.2.zip > "$DIR/evil/openshelf-v0.6.2.zip.sha256"
release_json evil v0.6.2 "$(size "$DIR/evil/openshelf-v0.6.2.zip")" 1

(cd "$WORK/src" && tar -cf "$DIR/tar/openshelf-v0.6.2.zip" openshelf.koplugin)
sha "$DIR/tar/openshelf-v0.6.2.zip" openshelf-v0.6.2.zip > "$DIR/tar/openshelf-v0.6.2.zip.sha256"
release_json tar v0.6.2 "$(size "$DIR/tar/openshelf-v0.6.2.zip")" 1

cp "$DIR/ok/openshelf-v0.6.2.zip" "$DIR/ok/openshelf-v0.6.2.zip.sha256" "$DIR/insecure/"
release_json insecure v0.6.2 "$FULL" 1
sed -i.bak 's|"browser_download_url": "http://127.0.0.1:[0-9]*/insecure/openshelf-v0.6.2.zip"|"browser_download_url": "http://example.com/openshelf-v0.6.2.zip"|' "$DIR/insecure.json"
rm -f "$DIR/insecure.json.bak"

echo "serving $DIR on $BASE (scenarios: ok ok3 badsum trunc badzip wrongver nosum evil tar insecure)"
rm -rf "$WORK"; trap - EXIT
cd "$DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1
