#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$SCRIPT_DIR/kitty agents.app"
APP_DEST="/Applications/kitty agents.app"

echo "installing kitty agents..."
cp -R "$APP_SRC" "$APP_DEST"
xattr -cr "$APP_DEST"
echo "done! opening kitty agents..."
open "$APP_DEST"
