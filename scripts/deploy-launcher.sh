#!/usr/bin/env bash
# Install the OpenShelf launcher on the Kobo over SSH: the KFMon watch, its
# script and the icon (kobo/). Afterwards "OpenShelf" appears in NickelMenu
# (its kfmon generator lists every watch) and, once Nickel has indexed the PNG,
# as a tappable icon in the Kobo library. Tapping either starts KOReader with
# OpenShelf as the home screen for that session.
#
# KFMon only reads its config at boot / after a USB session and Nickel indexes
# new files on the same occasions, so REBOOT the Kobo afterwards
# (NickelMenu → Reboot). Same prereqs as scripts/deploy.sh (SSH server started,
# `Host kobo` in ~/.ssh/config).
#
# Usage: scripts/deploy-launcher.sh [ssh-host]      (default host alias: kobo)
set -euo pipefail

HOST="${1:-kobo}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST")
cd "$(dirname "$0")/.."

# src → destination pairs (macOS ships bash 3.2, so no associative arrays)
SRCS=(kobo/openshelf.sh kobo/kfmon/openshelf.ini kobo/openshelf.png)
DSTS=(/mnt/onboard/.adds/openshelf/openshelf.sh /mnt/onboard/.adds/kfmon/config/openshelf.ini /mnt/onboard/openshelf.png)

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
echo "Installed. Reboot the Kobo (NickelMenu → Reboot) so KFMon loads the watch and Nickel indexes the icon."
echo "If the entry is missing afterwards: ssh $HOST /mnt/onboard/.adds/kfmon/bin/kfmon-printlog.sh | tail"
