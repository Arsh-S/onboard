#!/bin/zsh
# Build StandIn.app. The bundle id matches the call spike, so the "record system audio" permission carries over.
set -e
cd "$(dirname "$0")"
swift build -c release --product standin
APP=build/StandIn.app
[ -d "$APP" ] && trash "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/standin "$APP/Contents/MacOS/StandIn"
setopt +o nomatch; for b in .build/release/*.bundle(N); do cp -R "$b" "$APP/Contents/MacOS/"; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>StandIn</string>
  <key>CFBundleIdentifier</key><string>net.arshsingh.standin.callspike</string>
  <key>CFBundleExecutable</key><string>StandIn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDisplayName</key><string>Stand-In</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemindersFullAccessUsageDescription</key><string>Stand-In can save the result of a call (a price, a date, a confirmation number) to your Reminders.</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSAudioCaptureUsageDescription</key><string>Stand-In listens to the phone call so the on-device agent can hear the other person.</string>
  <key>NSMicrophoneUsageDescription</key><string>Stand-In uses audio devices for the phone call.</string>
</dict></plist>
PLIST
IDENT=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: Arsh Singh (5SLT5WM7VV)"' | head -1 | tr -d '"')
codesign --force --deep --sign "${IDENT:--}" "$APP" >/dev/null 2>&1
echo "built $APP"
