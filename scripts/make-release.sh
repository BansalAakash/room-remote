#!/bin/bash
# Builds the app and packs releases/RoomRemote-<version>.zip: the app, the helpers and install.sh in one folder.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: make-release.sh <version>}"
./scripts/build.sh build
STAGE="build/RoomRemote-$VERSION"
rm -rf "$STAGE"
mkdir -p "$STAGE" releases
cp -R build/RoomRemote.app "$STAGE/"
cp -R tv room "$STAGE/"
rm -rf "$STAGE"/tv/__pycache__ "$STAGE"/room/__pycache__
cp scripts/install.sh scripts/uninstall.sh README.md LICENSE "$STAGE/"
xattr -cr "$STAGE"
(cd build && ditto -c -k --norsrc --noextattr --keepParent "RoomRemote-$VERSION" "../releases/RoomRemote-$VERSION.zip")
echo "Wrote releases/RoomRemote-$VERSION.zip"
