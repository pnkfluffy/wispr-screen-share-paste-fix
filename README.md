# Screen Sharing Paste Helper for Wispr Flow

Unofficial macOS helper for using Wispr Flow with Apple Screen Sharing.

Wispr Flow can fail to paste into Apple Screen Sharing and send a literal `v`.
This helper watches Wispr's local logs, detects that failure path, removes the
stray `v`, finds the matching local Wispr transcript, and types it into the
remote Mac.

Not affiliated with Wispr Flow or Apple.

## Install

```zsh
scripts/install-launch-agent.sh
```

This builds a hidden app bundle and installs a user LaunchAgent with
`RunAtLoad` and `KeepAlive`.

Grant Accessibility permission to:

```text
~/Library/Application Support/Screen Sharing Paste Helper/Screen Sharing Paste Helper.app
```

Check status:

```zsh
tail -n 12 ~/Library/Logs/Screen\ Sharing\ Paste\ Helper/helper.log
```

## Uninstall

```zsh
scripts/uninstall-launch-agent.sh
```

The uninstall script removes the LaunchAgent and installed app bundle. Logs stay
in `~/Library/Logs/Screen Sharing Paste Helper/` unless you delete them.

## Manual Build

```zsh
swift build -c release
scripts/build-agent-app.sh
```

## Notes

- Only triggers for `com.apple.ScreenSharing`.
- Requires macOS Accessibility permission.
- Local-only: no network requests, telemetry, or analytics.
- Does not log dictated text.
- Reads Wispr's local log and history database:
  - `~/Library/Logs/Wispr Flow/accessibility.log`
  - `~/Library/Application Support/Wispr Flow/flow.sqlite`
- Converts Wispr-generated HTML list markup to plain text.
- Uses Shift+Return between lines so chat boxes do not treat newlines as send.
- Depends on Wispr Flow implementation details and may break after Wispr
  updates.

## License

MIT
