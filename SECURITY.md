# Security Policy

This helper is local-only and does not make network requests. It requires
macOS Accessibility permission because it watches for a specific Wispr Flow
paste path and types into Apple Screen Sharing when that paste path fails.
During Screen Sharing dictation/paste, it also hides Wispr Flow's floating
`Status` overlay so that local overlay windows do not pause Screen Sharing
frame updates.

Please do not include dictated text, Wispr Flow databases, local logs, or other
private user data in public issue reports. If a bug requires logs, reproduce it
with non-sensitive sample text and leave verbose logging disabled unless the
extra timing details are necessary.

## Local Data Access

The helper reads:

- `~/Library/Logs/Wispr Flow/accessibility.log`
- `~/Library/Application Support/Wispr Flow/flow.sqlite`

Default helper logs do not include transcript text, transcript IDs, local
database paths, or Wispr history timestamps.

## Reporting

Open a private security advisory or a minimal public issue that describes the
behavior without attaching private logs or transcript data.
