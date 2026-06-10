# Screen Sharing Paste Helper for Wispr Flow

Unofficial macOS helper for using Wispr Flow with Apple Screen Sharing.

This project is not affiliated with, endorsed by, or supported by Wispr Flow or
Apple.

Wispr Flow places dictated text on the local clipboard, but its automatic paste
path can fail in Apple Screen Sharing and send a literal `v`. This helper
watches Wispr Flow's local accessibility log. When it sees Wispr attempt to
paste into Apple Screen Sharing, it removes the stray `v`, correlates the
current dictation to Wispr Flow's local history database, and types the exact
matching transcript into the remote session.

The helper only triggers when Wispr's log indicates `com.apple.ScreenSharing`.

## Build

```zsh
swift build -c release
```

To build a hidden agent app bundle that does not appear in the Dock or app
switcher:

```zsh
scripts/build-agent-app.sh
```

The generated bundle is written to `dist/Screen Sharing Paste Helper.app` and
sets `LSUIElement=true`.

## Run

```zsh
.build/release/wispr-screen-share-paste-fix
```

To keep it running all the time for the current macOS user:

```zsh
scripts/install-launch-agent.sh
```

That command builds the hidden app bundle, copies it into
`~/Library/Application Support/Screen Sharing Paste Helper/`, and installs a
LaunchAgent at
`~/Library/LaunchAgents/org.unofficial.screen-sharing-paste-helper.plist` with
`RunAtLoad` and `KeepAlive` enabled.

After installing, check the helper log:

```zsh
tail -n 12 ~/Library/Logs/Screen\ Sharing\ Paste\ Helper/helper.log
```

If it shows `AXIsProcessTrusted=false`, grant Accessibility permission to
`~/Library/Application Support/Screen Sharing Paste Helper/Screen Sharing Paste Helper.app`
and run `scripts/install-launch-agent.sh` again. Until Accessibility is granted,
the LaunchAgent stays alive but skips paste handling so it does not interfere
with Wispr Flow.

To remove the always-on runner:

```zsh
scripts/uninstall-launch-agent.sh
```

The uninstall script removes the LaunchAgent and installed app bundle. Logs
remain in `~/Library/Logs/Screen Sharing Paste Helper/` unless you delete them.

Optional strategy argument:

```zsh
.build/release/wispr-screen-share-paste-fix exact-type
.build/release/wispr-screen-share-paste-fix provider-applescript
.build/release/wispr-screen-share-paste-fix applescript
.build/release/wispr-screen-share-paste-fix cgevent
.build/release/wispr-screen-share-paste-fix cgevent-sequence
```

The default strategy is `exact-type`. It uses Wispr's dictation-start timestamp
and the `History` table timestamp to select the current transcript
deterministically instead of guessing from the clipboard. Paste text length is
used as a validation signal, but exact timestamp matches are accepted even when
Wispr's stored formatted text length differs from the paste log length.

## Permissions

The process that runs this helper needs macOS Accessibility permission:

`System Settings > Privacy & Security > Accessibility`

If you run it from Terminal, grant Terminal permission. If you use
`scripts/install-launch-agent.sh`, grant Accessibility permission to the
installed hidden app bundle in
`~/Library/Application Support/Screen Sharing Paste Helper/`.

For the `applescript` strategy, macOS may also ask for permission to control
System Events.

## Privacy and Security

This helper is intentionally local-only:

- It does not make network requests.
- It does not include telemetry or analytics.
- It does not store dictated text.
- It does not log dictated text.

It does read local Wispr Flow data:

- `~/Library/Logs/Wispr Flow/accessibility.log`
- `~/Library/Application Support/Wispr Flow/flow.sqlite`

Those files are used only to detect Wispr Flow paste attempts into Apple Screen
Sharing and select the matching transcript from Wispr Flow's local history. The
default logs record operational events such as permission status, paste-cycle
state, and whether a matching transcript was found. They do not include
transcript IDs, transcript text, local database paths, or Wispr history
timestamps by default.

For debugging, set `WISPR_HELPER_VERBOSE_LOGS=1` before launching the helper.
Verbose logs may include transcript lengths, local file paths, and Wispr history
timestamps, but still do not log transcript text.

The always-on installer creates a user LaunchAgent with `RunAtLoad` and
`KeepAlive`. To remove it:

```zsh
scripts/uninstall-launch-agent.sh
```

The uninstall script removes the LaunchAgent and installed app bundle. Logs
remain in `~/Library/Logs/Screen Sharing Paste Helper/` unless you delete them.

## Notes

- The helper does not log dictated text.
- It reads Wispr Flow's local log at `~/Library/Logs/Wispr Flow/accessibility.log`.
- It reads Wispr Flow's local history database at
  `~/Library/Application Support/Wispr Flow/flow.sqlite`.
- It depends on Wispr Flow implementation details and may break after Wispr Flow
  updates.
- `provider-applescript`, `applescript`, `cgevent`, and `cgevent-sequence` are
  retained as experimental fallback strategies.

## License

MIT
