#!/usr/bin/env bash
# Builds the launcher with SwiftPM alone (no Xcode needed) and wraps it in an
# ad-hoc signed development bundle, build/dev/Gizlet Dev.app. Pass --open to
# start it. Releases are built from App/ with xcodebuild (scripts/release.sh).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
version=${GIZLET_VERSION:-0.0.0}
cd "${root}/GizletKit"
swift build -c debug --product GizletDev
binary=$(swift build -c debug --show-bin-path)/GizletDev

app="${root}/build/dev/Gizlet Dev.app"
rm -rf "${app}"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources"
cp "${binary}" "${app}/Contents/MacOS/Gizlet"
cat > "${app}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Gizlet</string>
  <key>CFBundleIdentifier</key><string>io.gizlet.macos.dev</string>
  <key>CFBundleName</key><string>Gizlet Dev</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "${app}"
echo "${app}"
if [ "${1:-}" = --open ]; then open "${app}"; fi
