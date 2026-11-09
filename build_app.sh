#!/bin/zsh
set -euo pipefail

source_dir="${0:A:h}"
app_dir="$source_dir/dist/AI Usage.app"
contents="$app_dir/Contents"
rm -rf "$app_dir"
mkdir -p "$contents/MacOS" "$contents/Resources" "$source_dir/.build/module-cache"

swiftc -module-cache-path "$source_dir/.build/module-cache" \
  -o "$contents/MacOS/AIUsageMenu" "$source_dir/AIUsageMenu.swift"
cp "$source_dir/codex_usage.py" "$source_dir/claude_usage.py" "$contents/Resources/"
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
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "$app_dir"
