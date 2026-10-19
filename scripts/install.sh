#!/bin/bash
# Installs Room Remote: the app into ~/Applications and its helpers into ~/Library/Application Support/RoomRemote.
# Run it from the folder you downloaded (or from the repo root). Safe to run again: it updates the scripts and keeps your settings.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -d "$HERE/tv" ] || HERE="$(cd "$HERE/.." && pwd)"
ROOT="${ROOM_REMOTE_HOME:-$HOME/Library/Application Support/RoomRemote}"
APPS="${ROOM_REMOTE_APPS:-$HOME/Applications}"

command -v python3 >/dev/null || { echo "python3 is missing. Run: xcode-select --install"; exit 1; }

echo "Installing helpers into: $ROOT"
mkdir -p "$ROOT/tv" "$ROOT/room"
cp "$HERE"/tv/*.py "$HERE"/tv/requirements.txt "$ROOT/tv/"
cp "$HERE"/room/room.py "$HERE"/room/requirements.txt "$ROOT/room/"

for part in tv room; do
  if [ ! -x "$ROOT/$part/.venv/bin/python" ]; then
    echo "Setting up Python for $part (first time only, about a minute)..."
    python3 -m venv "$ROOT/$part/.venv"
  fi
  "$ROOT/$part/.venv/bin/pip" install --quiet --upgrade pip
  "$ROOT/$part/.venv/bin/pip" install --quiet -r "$ROOT/$part/requirements.txt"
done

APP_SRC="$HERE/RoomRemote.app"
[ -d "$APP_SRC" ] || APP_SRC="$HERE/build/RoomRemote.app"
if [ -d "$APP_SRC" ]; then
  mkdir -p "$APPS"
  [ -n "${ROOM_REMOTE_APPS:-}" ] || pkill -x TVRemote 2>/dev/null || true
  rm -rf "$APPS/RoomRemote.app"
  cp -R "$APP_SRC" "$APPS/RoomRemote.app"
  xattr -dr com.apple.quarantine "$APPS/RoomRemote.app" 2>/dev/null || true
  echo "App installed: $APPS/RoomRemote.app"
else
  echo "No RoomRemote.app next to this script. Build one with scripts/build.sh, then run this again."
fi

cat <<MSG

Done. Next:
  1. TV:    "$ROOT/tv/.venv/bin/python" "$ROOT/tv/pair.py" <your-tv-ip>
  2. Plugs: see the README, section "Set up your plugs"
  3. Open:  open ~/Applications/RoomRemote.app   (it lives in the menu bar)
MSG
