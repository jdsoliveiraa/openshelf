#!/usr/bin/env bash
# Install the OpenShelf launcher on the Kobo over SSH: the KFMon watch, its
# script, the icon and an "Import books" NickelMenu entry (kobo/). Afterwards
# "OpenShelf" appears in NickelMenu (its kfmon generator lists every watch) and
# starts KOReader with OpenShelf as the home screen for that session; the tile
# in the Kobo library appears once Nickel has imported the PNG.
#
# KFMon reads new watch configs at boot / after a USB session, and Nickel
# imports new files (the icon, books OpenShelf downloaded) only after a USB
# session — real or faked by NickelMenu → Import books. So afterwards: reboot
# once (NickelMenu → Reboot), then NickelMenu → Import books for the tile.
# Same prereqs as scripts/deploy.sh (SSH server started, `Host kobo` in
# ~/.ssh/config). Only files named openshelf* are written; nothing of yours is touched.
#
# Usage: scripts/deploy-launcher.sh [ssh-host]      (default host alias: kobo)
set -euo pipefail

HOST="${1:-kobo}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST")
cd "$(dirname "$0")/.."

# src → destination pairs (macOS ships bash 3.2, so no associative arrays)
SRCS=(kobo/openshelf.sh kobo/kfmon/openshelf.ini kobo/openshelf.png kobo/nm/openshelf-import)
DSTS=(/mnt/onboard/.adds/openshelf/openshelf.sh /mnt/onboard/.adds/kfmon/config/openshelf.ini /mnt/onboard/openshelf.png /mnt/onboard/.adds/nm/openshelf-import)

echo "Installing the OpenShelf launcher on $HOST ..."
"${SSH[@]}" "mkdir -p /mnt/onboard/.adds/openshelf /mnt/onboard/.adds/kfmon/config"
for i in "${!SRCS[@]}"; do
  scp -q "${SRCS[$i]}" "$HOST:${DSTS[$i]}"
done
"${SSH[@]}" "chmod +x /mnt/onboard/.adds/openshelf/openshelf.sh && sync"

for i in "${!SRCS[@]}"; do
  if command -v md5sum >/dev/null; then local_sum="$(md5sum "${SRCS[$i]}" | awk '{print $1}')"
  else local_sum="$(md5 -q "${SRCS[$i]}")"; fi
  remote_sum="$("${SSH[@]}" "md5sum ${DSTS[$i]}" | awk '{print $1}')"
  if [ "$local_sum" != "$remote_sum" ]; then
    echo "CHECKSUM MISMATCH for ${DSTS[$i]}" >&2; exit 1
  fi
  echo "  ok  ${DSTS[$i]}"
done
echo "Installed. If the KFMon watch is new, reboot the Kobo (NickelMenu → Reboot); then NickelMenu → Import books makes the icon show in the library."
echo "If the entry is missing afterwards: ssh $HOST /mnt/onboard/.adds/kfmon/bin/kfmon-printlog.sh | tail"
