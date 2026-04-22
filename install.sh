#!/bin/bash
set -e

TMPZIP=$(mktemp /tmp/kitty-agents-XXXXXX.zip)
TMPDIR=$(mktemp -d /tmp/kitty-agents-XXXXXX)

cleanup() { rm -rf "$TMPZIP" "$TMPDIR"; }
trap cleanup EXIT

echo "downloading kitty agents..."
curl -fsSL -o "$TMPZIP" \
  "https://github.com/laboyangelik/kitty-agents/releases/latest/download/kitty-agents-latest.zip"

echo "installing..."
unzip -q "$TMPZIP" -d "$TMPDIR"
rm -rf "/Applications/kitty agents.app"
cp -a "$TMPDIR/kitty agents.app" "/Applications/"
xattr -cr "/Applications/kitty agents.app"

echo "done! launching kitty agents..."
# Reset onboarding so the welcome message always shows on a fresh install.
# Sparkle auto-updates don't run this script, so existing users aren't affected.
defaults delete com.lilagents.app hasCompletedOnboarding 2>/dev/null || true
open "/Applications/kitty agents.app"
