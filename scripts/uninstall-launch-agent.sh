#!/bin/zsh
set -eu

labels=("org.unofficial.screen-sharing-paste-helper")
domain="gui/$(id -u)"
install_root="$HOME/Library/Application Support/Screen Sharing Paste Helper"

for label in "${labels[@]}"; do
  plist_path="$HOME/Library/LaunchAgents/$label.plist"
  service="gui/$(id -u)/$label"

  if launchctl print "$service" >/dev/null 2>&1; then
    launchctl bootout "$domain" "$plist_path" >/dev/null 2>&1 || true
  fi

  rm -f "$plist_path"
  echo "Uninstalled $label"
done

rm -rf "$install_root"
echo "Removed $install_root"
