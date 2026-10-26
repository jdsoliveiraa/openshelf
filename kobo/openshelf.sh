#!/bin/sh
# OpenShelf launcher, run by KFMon (installed at /mnt/onboard/.adds/openshelf/openshelf.sh,
# see kobo/kfmon/openshelf.ini and scripts/deploy-launcher.sh).
#
# Starts KOReader with OpenShelf as the home screen for this session: it opens
# at start and again whenever a book is closed (openshelf.koplugin/main.lua
# reads OPENSHELF_AUTOOPEN). Everything else is KOReader's own start script,
# so Wi-Fi, sleep and the return to Nickel behave exactly as for KOReader.
export OPENSHELF_AUTOOPEN=1
exec /mnt/onboard/.adds/koreader/koreader.sh "$@"
