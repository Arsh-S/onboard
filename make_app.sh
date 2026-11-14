#!/bin/zsh
# Build Onboard.app (a bundle is needed for the microphone, accessibility and reminders permissions).
set -e
cd "$(dirname "$0")"
swift build -c release --product Onboard
APP=build/Onboard.app
[ -d "$APP" ] && trash "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Onboard "$APP/Contents/MacOS/Onboard"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
setopt +o nomatch; for b in .build/release/*.bundle(N); do cp -R "$b" "$APP/Contents/MacOS/"; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Onboard</string>
  <key>CFBundleDisplayName</key><string>Onboard</string>
  <key>CFBundleIdentifier</key><string>net.arshsingh.onboard</string>
  <key>CFBundleExecutable</key><string>Onboard</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Onboard listens when you hold the talk key. Audio is transcribed on this Mac and never leaves it.</string>
  <key>NSContactsUsageDescription</key><string>Onboard looks up a contact's number when you ask it to draft a message to them.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Onboard adds reminders when you ask it to.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Onboard adds calendar events when you ask it to.</string>
  <key>NSAppleEventsUsageDescription</key><string>Onboard opens apps and drafts when you ask it to.</string>
</dict></plist>
PLIST
# A stable signing identity keeps the Accessibility and Microphone grants across rebuilds.
IDENT=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
codesign --force --deep --sign "${IDENT:--}" "$APP" >/dev/null 2>&1 || true
echo "built $APP"
# Keep a real copy in /Applications (launchers such as Raycast ignore symlinks).
if [ -d /Applications ]; then [ -e /Applications/Onboard.app ] && trash /Applications/Onboard.app; ditto "$APP" /Applications/Onboard.app && echo "installed /Applications/Onboard.app"; fi
