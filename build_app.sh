#!/bin/zsh
# Usage: zsh build_app.sh [--notarize]
# Signs with a "Developer ID Application" certificate when one is installed (or DEVELOPER_ID names one),
# otherwise ad-hoc for this Mac only. --notarize also notarizes, staples, and writes dist/AI Usage.zip
# using the notarytool keychain profile in NOTARY_PROFILE (default: AI-Usage-Notary).
set -euo pipefail

source_dir="${0:A:h}"
app_dir="$source_dir/dist/AI Usage.app"
contents="$app_dir/Contents"
build_dir="$source_dir/.build"
notarize=false
[[ "${1:-}" == "--notarize" ]] && notarize=true
identity="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
if $notarize && [[ -z "$identity" ]]; then
  echo "No Developer ID Application certificate found; cannot notarize." >&2
  exit 1
fi

rm -rf "$app_dir"
mkdir -p "$contents/MacOS" "$contents/Resources" "$build_dir/module-cache"

for arch in arm64 x86_64; do
  swiftc -module-cache-path "$build_dir/module-cache" -target "$arch-apple-macos11" \
    -o "$build_dir/AIUsageMenu-$arch" "$source_dir/AIUsageMenu.swift"
done
lipo -create -output "$contents/MacOS/AIUsageMenu" "$build_dir/AIUsageMenu-arm64" "$build_dir/AIUsageMenu-x86_64"
cp "$source_dir/codex_usage.py" "$source_dir/claude_usage.py" "$source_dir/claude_statusline.py" "$contents/Resources/"
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AI Usage</string>
  <key>CFBundleDisplayName</key><string>AI Usage</string>
  <key>CFBundleIdentifier</key><string>local.ai.usage.menu</string>
  <key>CFBundleExecutable</key><string>AIUsageMenu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if [[ -z "$identity" ]]; then
  codesign --force --sign - "$app_dir"
  codesign --verify --deep --strict "$app_dir"
  echo "$app_dir (ad-hoc signed: runs on this Mac only)"
  exit 0
fi

codesign --force --options runtime --timestamp --sign "$identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"
if ! $notarize; then
  echo "$app_dir (signed by $identity; run with --notarize to share it)"
  exit 0
fi

zip="$source_dir/dist/AI Usage.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app_dir" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "${NOTARY_PROFILE:-AI-Usage-Notary}" --wait
xcrun stapler staple "$app_dir"
rm -f "$zip"
ditto -c -k --keepParent "$app_dir" "$zip"
spctl --assess --type execute -vv "$app_dir"
echo "$zip"
