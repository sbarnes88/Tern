#!/bin/sh
# Builds "Tern Browser.app" in this folder.  Usage: ./build.sh  (then: open "Tern Browser.app")
set -e
cd "$(dirname "$0")"

swift build -c release --product TernBrowser
swift build -c release --product tern

APP="Tern Browser.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TernBrowser "$APP/Contents/MacOS/TernBrowser"
cp -R Pages "$APP/Contents/Resources/Pages"
cp Info.plist "$APP/Contents/Info.plist"

ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET"
swift tools/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
# Tell Finder this app opens .tern files.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
echo "Built $APP"
