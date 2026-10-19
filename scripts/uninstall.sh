#!/bin/bash
# Removes the app and its helpers. Your TV pairing and plug keys are deleted with them.
set -euo pipefail
ROOT="${ROOM_REMOTE_HOME:-$HOME/Library/Application Support/RoomRemote}"
pkill -x TVRemote 2>/dev/null || true
rm -rf "$HOME/Applications/RoomRemote.app" "$ROOT"
echo "Removed."
