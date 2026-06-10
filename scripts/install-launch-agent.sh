#!/bin/zsh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
label="org.unofficial.screen-sharing-paste-helper"
app_name="Screen Sharing Paste Helper.app"
binary_name="Screen Sharing Paste Helper"
install_root="$HOME/Library/Application Support/Screen Sharing Paste Helper"
launch_agents_dir="$HOME/Library/LaunchAgents"
log_dir="$HOME/Library/Logs/Screen Sharing Paste Helper"
plist_path="$launch_agents_dir/$label.plist"
service="gui/$(id -u)/$label"
domain="gui/$(id -u)"

"$repo_root/scripts/build-agent-app.sh" >/dev/null

mkdir -p "$install_root" "$launch_agents_dir" "$log_dir"

if launchctl print "$service" >/dev/null 2>&1; then
  launchctl bootout "$domain" "$plist_path" >/dev/null 2>&1 || true
fi

rm -rf "$install_root/$app_name"
ditto "$repo_root/dist/$app_name" "$install_root/$app_name"

cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$install_root/$app_name/Contents/MacOS/$binary_name</string>
    <string>exact-type</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>$log_dir/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/launchd.err.log</string>
</dict>
</plist>
PLIST

plutil -lint "$plist_path" >/dev/null

launchctl bootstrap "$domain" "$plist_path"
launchctl enable "$service" >/dev/null 2>&1 || true
launchctl kickstart -k "$service" >/dev/null

echo "Installed $label"
echo "$install_root/$app_name"
echo "$plist_path"
echo "Check permission status with:"
echo "  tail -n 12 \"$log_dir/helper.log\""
echo "If AXIsProcessTrusted=false, grant Accessibility to the installed app and rerun this script."
