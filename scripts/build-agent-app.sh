#!/bin/zsh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

swift build -c release

app_name="Screen Sharing Paste Helper.app"
app_path="$repo_root/dist/$app_name"
binary_name="Screen Sharing Paste Helper"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS"
cp "$repo_root/.build/release/wispr-screen-share-paste-fix" "$app_path/Contents/MacOS/$binary_name"

cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Screen Sharing Paste Helper</string>
  <key>CFBundleIdentifier</key>
  <string>org.unofficial.screen-sharing-paste-helper</string>
  <key>CFBundleName</key>
  <string>Screen Sharing Paste Helper</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Used to type the current Wispr Flow transcript into Apple Screen Sharing when Wispr Flow's own paste fails.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$app_path" >/dev/null 2>&1 || true
chmod +x "$app_path/Contents/MacOS/$binary_name"

echo "$app_path"
