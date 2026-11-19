#!/bin/bash
# Install both LaunchAgents from this checkout: launchd/install.sh [--uninstall]. Do not run while the old Hammerspoon player is on.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
for k in daemon ui; do
  label=com.erik.tunarr-pip.$k; dest="$HOME/Library/LaunchAgents/$label.plist"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  [ "${1:-}" = --uninstall ] && { rm -f "$dest"; continue; }
  sed -e "s#__REPO__#$repo#g" -e "s#__HOME__#$HOME#g" "$repo/launchd/$label.plist" > "$dest"
  launchctl bootstrap "gui/$(id -u)" "$dest"
done
