#!/bin/bash
set -e

echo "downloading kitty agents..."
curl -fsSL -o /tmp/kitty-agents-latest.zip \
  "https://github.com/laboyangelik/kitty-agents/releases/latest/download/kitty-agents-latest.zip"

echo "installing..."
unzip -o /tmp/kitty-agents-latest.zip -d /tmp/kitty-agents-install/ > /dev/null
rm -rf "/Applications/kitty agents.app"
ditto "/tmp/kitty-agents-install/kitty agents.app" "/Applications/kitty agents.app"
xattr -cr "/Applications/kitty agents.app"

echo "cleaning up..."
rm -rf /tmp/kitty-agents-install/ /tmp/kitty-agents-latest.zip

echo "done! launching kitty agents..."
open "/Applications/kitty agents.app"
