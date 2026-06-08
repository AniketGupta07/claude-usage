#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="ClaudeUsage"
BUILD_DIR="build"
BUNDLE="$BUILD_DIR/$APP.app"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "Compiling…"
swiftc -O Sources/main.swift -o "$BUNDLE/Contents/MacOS/$APP" -framework Cocoa

# Ad-hoc sign so SMAppService (launch-at-login) works reliably for a local build.
codesign --force --deep -s - "$BUNDLE" 2>/dev/null && echo "Ad-hoc signed."

echo "Built $BUNDLE"
echo "Run with: open \"$BUNDLE\"   (or double-click it in Finder)"
