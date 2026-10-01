#!/bin/zsh
# Builds StemSplitter.app into ~/Applications
set -e
cd "${0:A:h}"
swift build -c release
APP=~/Applications/StemSplitter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/StemSplitter "$APP/Contents/MacOS/"
cp Resources/worker.py "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Stem Splitter</string>
  <key>CFBundleDisplayName</key><string>Stem Splitter</string>
  <key>CFBundleIdentifier</key><string>com.cihan.stemsplitter</string>
  <key>CFBundleExecutable</key><string>StemSplitter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
